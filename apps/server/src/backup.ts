// SPDX-License-Identifier: MPL-2.0
import { copyFileSync, existsSync, mkdirSync, readdirSync, renameSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { CLAIM_NEEDS_SECRET } from "./auth/devices.ts";
import { Database } from "./db/database.ts";
import { OUTSIDE_SWITCH } from "./outside/entrance.ts";
import { readRevocations, writeRevocations, type Revocations } from "./revocations.ts";
import { SETTINGS_DIR, SETTINGS_FILE } from "./settings/store.ts";

export const CATALOGUE_FILE = "lobby.db";
const CONFIG_FILE = "lobby.config.json";
const NAME = /^\d{8}-\d{6}$/;

export interface Backup {
  name: string;
  path: string;
  at: number;
}

function stamp(at: number): string {
  const iso = new Date(at).toISOString();
  return `${iso.slice(0, 10).replaceAll("-", "")}-${iso.slice(11, 19).replaceAll(":", "")}`;
}

function timeOf(name: string): number {
  return Date.parse(
    `${name.slice(0, 4)}-${name.slice(4, 6)}-${name.slice(6, 8)}T${name.slice(9, 11)}:${name.slice(11, 13)}:${name.slice(13, 15)}Z`,
  );
}

/** Finished backups in `dir`, newest first. */
export function listBackups(dir: string): Backup[] {
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { withFileTypes: true })
    .filter(
      (entry) =>
        entry.isDirectory() &&
        NAME.test(entry.name) &&
        existsSync(join(dir, entry.name, CATALOGUE_FILE)),
    )
    .map((entry) => ({ name: entry.name, path: join(dir, entry.name), at: timeOf(entry.name) }))
    .sort((a, b) => b.at - a.at);
}

/**
 * Writes a consistent copy of the catalogue, and the config beside it, into a
 * new folder in `dir`. Safe while the server runs. Secrets are left out on
 * purpose: paired devices are in the catalogue (as hashes), and the provider
 * key is entered again after a restore.
 */
export async function createBackup(
  db: Database,
  dir: string,
  configPath: string | null,
  now: number = Date.now(),
  /** The data folder, whose settings (`settings/settings.json`) go into the backup too. */
  dataDir: string | null = null,
): Promise<Backup> {
  const name = stamp(now);
  const path = join(dir, name);
  if (existsSync(path)) throw new Error(`A backup named ${name} already exists.`);
  // Built under another name, so a half-written backup is never taken for a finished one.
  const building = join(dir, `.${name}.building`);
  rmSync(building, { recursive: true, force: true });
  mkdirSync(building, { recursive: true });
  try {
    await db.backupTo(join(building, CATALOGUE_FILE));
    if (configPath !== null && existsSync(configPath)) {
      copyFileSync(configPath, join(building, CONFIG_FILE));
    }
    // The settings managers changed, without a secret in them; not their history.
    const settings = dataDir === null ? null : join(dataDir, SETTINGS_DIR, SETTINGS_FILE);
    if (settings !== null && existsSync(settings)) {
      copyFileSync(settings, join(building, SETTINGS_FILE));
    }
    renameSync(building, path);
  } catch (error) {
    rmSync(building, { recursive: true, force: true });
    throw error;
  }
  return { name, path, at: timeOf(name) };
}

/** Deletes all but the newest `keep` backups. Returns the names it removed. */
export function pruneBackups(dir: string, keep: number): string[] {
  const removed: string[] = [];
  for (const backup of listBackups(dir).slice(Math.max(1, keep))) {
    rmSync(backup.path, { recursive: true });
    removed.push(backup.name);
  }
  return removed;
}

/**
 * Puts a backed-up catalogue into `dataDir`. Refuses when a catalogue is
 * already there: the server must be stopped and the old file moved away by
 * hand, so a restore can never silently replace a household's history.
 *
 * What was taken away since the backup stays taken away, as far as that is known: devices that
 * were removed, and everything about the outside entrance.
 *
 * @returns what a person should know about it
 */
export function restoreBackup(backupPath: string, dataDir: string): string[] {
  const source = backupPath.endsWith(".db") ? backupPath : join(backupPath, CATALOGUE_FILE);
  if (!existsSync(source)) throw new Error(`There is no catalogue at ${source}.`);
  const target = join(dataDir, CATALOGUE_FILE);
  if (existsSync(target)) {
    throw new Error(
      `${target} already exists. Stop the server and move it (and its -wal and -shm files) away first.`,
    );
  }

  const copy = new DatabaseSync(source, { readOnly: true });
  try {
    const check = copy.prepare("pragma quick_check").get() as Record<string, unknown> | undefined;
    if (check?.["quick_check"] !== "ok") throw new Error("The backup is damaged.");
    const versions = copy.prepare("select count(*) as n from schema_migration").get() as
      { n: number } | undefined;
    if (!versions || versions.n === 0) throw new Error("That file is not a Lobby catalogue.");
  } finally {
    copy.close();
  }

  mkdirSync(dataDir, { recursive: true });
  const arriving = `${target}.restoring`;
  const notes: string[] = [];
  const revoked = revokedSince(source, dataDir, notes);
  for (const rest of ["", "-wal", "-shm"]) rmSync(`${arriving}${rest}`, { force: true });
  copyFileSync(source, arriving);
  try {
    const db = new Database(arriving);
    try {
      keepTakenAway(db, revoked, notes);
    } finally {
      db.close();
    }
    if (revoked.size > 0) writeRevocations(dataDir, revoked);
  } catch (error) {
    rmSync(arriving, { force: true });
    throw error;
  }
  renameSync(arriving, target);
  // The settings of then, unless the data folder has its own.
  const settings = join(dirname(resolve(source)), SETTINGS_FILE);
  const settingsTarget = join(dataDir, SETTINGS_DIR, SETTINGS_FILE);
  if (!backupPath.endsWith(".db") && existsSync(settings) && !existsSync(settingsTarget)) {
    mkdirSync(join(dataDir, SETTINGS_DIR), { recursive: true, mode: 0o700 });
    copyFileSync(settings, settingsTarget);
    notes.push("The server's settings came back from the backup too.");
  }
  return notes;
}

/** Devices that were removed, from every place that may know of one. */
function revokedSince(source: string, dataDir: string, notes: string[]): Revocations {
  const folder = dirname(resolve(source));
  const backups = dirname(folder);
  const all: Revocations = new Map();
  const add = (more: Iterable<[string, number]>): void => {
    for (const [id, at] of more) all.set(id, Math.min(at, all.get(id) ?? at));
  };
  for (const dir of new Set([resolve(dataDir), folder, backups])) add(readRevocations(dir));
  // Every backup, also an older one: once removed, a device never comes back by itself.
  for (const backup of listBackups(backups)) {
    try {
      const other = new DatabaseSync(join(backup.path, CATALOGUE_FILE), { readOnly: true });
      try {
        const rows = other
          .prepare("select id, revoked_at from device where revoked_at is not null")
          .all() as { id: string; revoked_at: number }[];
        add(rows.map((row) => [row.id, row.revoked_at]));
      } finally {
        other.close();
      }
    } catch {
      notes.push(`The backup ${backup.name} could not be read for devices removed later.`);
    }
  }
  return all;
}

function keepTakenAway(db: Database, revoked: Revocations, notes: string[]): void {
  db.transaction(() => {
    const managers = (): number =>
      db.get<{ n: number }>(
        // The server's managers: a guest household's manage only their own.
        "select count(*) as n from device where access = 'admin' and revoked_at is null",
      )?.n ?? 0;
    const before = managers();
    let removed = 0;
    for (const [id, at] of revoked) {
      removed += db.run("update device set revoked_at = ? where id = ? and revoked_at is null", [
        at,
        id,
      ]);
    }
    if (removed > 0)
      notes.push(`Devices removed since the backup stay removed: ${String(removed)}.`);
    if (before > 0 && managers() === 0) {
      db.setMeta(CLAIM_NEEDS_SECRET, "yes");
      notes.push(
        "No manager is left. Claim the server with the setup secret (lobby setup-secret).",
      );
    }
    db.setMeta(OUTSIDE_SWITCH, "off");
    const outside = db.run("update device set allow_outside = 0 where allow_outside = 1");
    db.run("update device set remote_outside = 0");
    if (outside > 0) {
      notes.push(
        "The outside entrance is off, and no device is let in there until a manager says so.",
      );
    }
    db.run("delete from pairing_request");
    // Devices enrol again at home. Their old secrets may be in somebody's copy of the backup.
    db.run("delete from direct_device");
  });
}
