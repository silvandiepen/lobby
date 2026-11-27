// SPDX-License-Identifier: MPL-2.0
import {
  closeSync,
  existsSync,
  fsyncSync,
  mkdirSync,
  openSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeSync,
} from "node:fs";
import { join } from "node:path";

/**
 * What managers changed in the app, in the data folder:
 *
 * - `settings/settings.json`: the version in use.
 * - `settings/history/<version>.json`: every version before it, the newest `KEEP_HISTORY`.
 *
 * The file `lobby.config.json` stays where the server starts from (port, host, data folder, the
 * programs it runs). For every key in `SETTINGS` (`schema.ts`) the store wins over the file once
 * it exists; it is made from the file the first time the server starts, so nothing changes then.
 * A secret is never in here: those stay in `secrets.json`.
 */
export interface StoredSettings {
  version: number;
  /** When this version was made, in ms. */
  at: number;
  /** The device that made it; null for one the server made itself (the first, from the file). */
  by: string | null;
  /** What it was made for: "imported", "changed", "restored 3". */
  reason: string;
  /** The keys this version changed against the one before it. */
  changed: string[];
  /**
   * The value of each key, as it is written in the config file. A key that is missing has its
   * default; `null` is a value of its own where the key allows it (no conversion folder).
   */
  values: Record<string, unknown>;
}

export const SETTINGS_DIR = "settings";
export const SETTINGS_FILE = "settings.json";
const CURRENT = SETTINGS_FILE;
const HISTORY = "history";
const KEEP_HISTORY = 50;

export function settingsDir(dataDir: string): string {
  return join(dataDir, SETTINGS_DIR);
}

function isStored(value: unknown): value is StoredSettings {
  if (typeof value !== "object" || value === null) return false;
  const one = value as Record<string, unknown>;
  return (
    typeof one["version"] === "number" &&
    typeof one["at"] === "number" &&
    typeof one["values"] === "object" &&
    one["values"] !== null &&
    !Array.isArray(one["values"])
  );
}

function readOne(path: string): StoredSettings | null {
  if (!existsSync(path)) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    // Written whole and renamed into place, so this is a file someone else broke.
    throw new Error(`Lobby settings: ${path} is not valid JSON. Restore it from history/.`);
  }
  if (!isStored(parsed)) throw new Error(`Lobby settings: ${path} is not a settings file.`);
  return {
    version: parsed.version,
    at: parsed.at,
    by: typeof parsed.by === "string" ? parsed.by : null,
    reason: typeof parsed.reason === "string" ? parsed.reason : "",
    changed: Array.isArray(parsed.changed)
      ? parsed.changed.filter((k) => typeof k === "string")
      : [],
    values: parsed.values,
  };
}

/** The version in use; null before the server first started with a store. */
export function readSettings(dataDir: string): StoredSettings | null {
  return readOne(join(settingsDir(dataDir), CURRENT));
}

/** Written beside the target, flushed, then renamed over it: a reader sees the old or the new. */
function writeAtomically(path: string, text: string): void {
  const temporary = `${path}.${String(process.pid)}.writing`;
  const handle = openSync(temporary, "w", 0o600);
  try {
    writeSync(handle, text);
    fsyncSync(handle);
  } finally {
    closeSync(handle);
  }
  try {
    renameSync(temporary, path);
  } catch (error) {
    rmSync(temporary, { force: true });
    throw error;
  }
  try {
    const folder = openSync(join(path, ".."), "r");
    try {
      fsyncSync(folder);
    } finally {
      closeSync(folder);
    }
  } catch {
    // Not every system lets a folder be flushed; the rename itself is atomic all the same.
  }
}

const historyName = (version: number): string => `${String(version).padStart(6, "0")}.json`;

/**
 * Makes `next` the version in use. The one it replaces goes into the history first, so a crash
 * between the two leaves the old version in use and a copy of it in the history.
 */
export function writeSettings(dataDir: string, next: StoredSettings): void {
  const dir = settingsDir(dataDir);
  const history = join(dir, HISTORY);
  mkdirSync(history, { recursive: true, mode: 0o700 });
  const current = readSettings(dataDir);
  if (current) {
    writeAtomically(
      join(history, historyName(current.version)),
      `${JSON.stringify(current, null, 2)}\n`,
    );
  }
  writeAtomically(join(dir, CURRENT), `${JSON.stringify(next, null, 2)}\n`);
  const old = readdirSync(history)
    .filter((name) => /^\d{6}\.json$/.test(name))
    .sort()
    .reverse()
    .slice(KEEP_HISTORY);
  for (const name of old) rmSync(join(history, name), { force: true });
}

/** The versions before the one in use, newest first. */
export function settingsHistory(dataDir: string): StoredSettings[] {
  const history = join(settingsDir(dataDir), HISTORY);
  if (!existsSync(history)) return [];
  return readdirSync(history)
    .filter((name) => /^\d{6}\.json$/.test(name))
    .sort()
    .reverse()
    .flatMap((name) => {
      try {
        const one = readOne(join(history, name));
        return one ? [one] : [];
      } catch {
        return [];
      }
    });
}

/** One earlier version, or null when it is not kept (any more). */
export function settingsVersion(dataDir: string, version: number): StoredSettings | null {
  if (!Number.isInteger(version) || version < 1) return null;
  const current = readSettings(dataDir);
  if (current?.version === version) return current;
  try {
    return readOne(join(settingsDir(dataDir), HISTORY, historyName(version)));
  } catch {
    return null;
  }
}

/** A key is a path in the config file: "conversion.hours" is `conversion` → `hours`. */
export function valueAt(raw: Record<string, unknown>, key: string): unknown {
  let at: unknown = raw;
  for (const part of key.split(".")) {
    if (typeof at !== "object" || at === null || Array.isArray(at)) return undefined;
    at = (at as Record<string, unknown>)[part];
  }
  return at;
}

function setAt(raw: Record<string, unknown>, key: string, value: unknown): void {
  const parts = key.split(".");
  let at = raw;
  for (const part of parts.slice(0, -1)) {
    const next = at[part];
    if (typeof next !== "object" || next === null || Array.isArray(next)) {
      if (value === undefined) return;
      at[part] = {};
    } else {
      // A copy: the file's own object is not changed.
      at[part] = { ...(next as Record<string, unknown>) };
    }
    at = at[part] as Record<string, unknown>;
  }
  const last = parts.at(-1) ?? "";
  if (value === undefined) Reflect.deleteProperty(at, last);
  else at[last] = value;
}

/**
 * The file with the stored settings put over it. Every key in `keys` takes the stored value, or
 * its default when the store has none; keys that are not settings stay as the file has them.
 */
export function withSettings(
  file: Record<string, unknown>,
  values: Record<string, unknown>,
  keys: readonly string[] = SETTING_KEYS,
): Record<string, unknown> {
  const merged: Record<string, unknown> = { ...file };
  for (const key of keys) {
    const parent = WITHIN_FILE[key];
    // Part of something only the file sets up: without that, the value means nothing.
    if (parent !== undefined && !isObject(valueAt(file, parent))) continue;
    setAt(merged, key, Object.hasOwn(values, key) ? values[key] : undefined);
  }
  return merged;
}

function isObject(value: unknown): boolean {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Keys inside a part of the config that only the file sets up. */
export const WITHIN_FILE: Readonly<Record<string, string>> = {
  "outside.direct.maxUploadMbit": "outside.direct",
  "remote.wake.enabled": "remote.wake",
  "remote.wake.kids": "remote.wake",
  "remote.wake.pickProfile": "remote.wake",
  "remote.wake.speakers": "remote.wake",
};

/** The keys a manager can change. `schema.ts` describes each; the list is here so the config can merge without it. */
export const SETTING_KEYS = [
  "serverName",
  "advertise",
  "language",
  "roots",
  "rescanMinutes",
  "stabilityMs",
  "probeConcurrency",
  "import.folders",
  "import.waitMinutes",
  "import.copyAcrossDrives",
  "uploads.maxFileGb",
  "uploads.quotaGb",
  "conversion.dir",
  "conversion.hours",
  "conversion.server",
  "conversion.repackage",
  "conversion.minFreeGb",
  "addresses.remote",
  "outside.direct.maxUploadMbit",
  "remote.wake.enabled",
  "remote.wake.kids",
  "remote.wake.pickProfile",
  "remote.wake.speakers",
  "backup.keep",
  "backup.everyHours",
  "statistics.keepDays",
  "playback.maxCacheGb",
  "playback.maxConcurrent",
  "music.maxCacheGb",
] as const;

export type SettingKey = (typeof SETTING_KEYS)[number];

/** The values of the settings keys a file has. Made into the first version on first start. */
export function settingsFromFile(file: Record<string, unknown>): Record<string, unknown> {
  const values: Record<string, unknown> = {};
  for (const key of SETTING_KEYS) {
    const value = valueAt(file, key);
    if (value !== undefined) values[key] = structuredClone(value);
  }
  return values;
}
