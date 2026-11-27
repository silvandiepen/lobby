// SPDX-License-Identifier: MPL-2.0
import { randomUUID } from "node:crypto";
import { readFile, realpath } from "node:fs/promises";
import { join, resolve } from "node:path";
import type { Devices } from "../auth/devices.ts";
import {
  dataDirOf,
  parseConfig,
  readConfigFile,
  saveOmdbApiKey,
  saveTmdbApiKey,
  tmdbKeyFromEnvironment,
  type Config,
} from "../config.ts";
import type { Database } from "../db/database.ts";
import { log } from "../log.ts";
import { BrowseError, type FolderBrowser } from "./browse.ts";
import { DEFINITIONS, SECTIONS, SETTINGS, type ApplyMode } from "./schema.ts";
import {
  readSettings,
  settingsFromFile,
  settingsHistory,
  settingsVersion,
  valueAt,
  withSettings,
  writeSettings,
  WITHIN_FILE,
  SETTING_KEYS,
  type StoredSettings,
} from "./store.ts";
import { checkOmdbKey, looksLikeOmdbKey } from "../search/omdb.ts";
import { checkTmdbKey, looksLikeTmdbKey, type KeyCheck } from "./tmdb.ts";

/** A refusal that says what is wrong in words that can be shown as they are. */
export class SettingsError extends Error {
  readonly code: "invalid_request" | "conflict" | "unavailable" | "not_found" | "forbidden";
  readonly problems: { key: string | null; message: string }[];

  constructor(
    code: SettingsError["code"],
    message: string,
    problems: { key: string | null; message: string }[] = [],
  ) {
    super(message);
    this.code = code;
    this.problems = problems;
  }
}

/** What one change will do, for the manager to read before it is made. */
export interface Effect {
  key: string;
  title: string;
  apply: ApplyMode;
  message: string;
}

export interface Plan {
  effects: Effect[];
  /** The server restarts to take the change. */
  restart: boolean;
  /** Folders that will be looked through because they are new or read differently. */
  rescanFolders: number;
  changed: string[];
}

export interface SetupState {
  needed: boolean;
  steps: { id: "name" | "folders" | "tmdb" | "scan"; done: boolean; skipped: boolean }[];
}

export interface SettingsHooks {
  /**
   * Makes the running server use `next`, which already is in the config object, for the keys in
   * `changed` that are taken live. Throwing undoes the change: it is called again with the two
   * the other way round.
   */
  apply: (next: Config, previous: Config, changed: string[]) => Promise<void>;
  /** Restarts the whole server, after the answer has gone out. */
  restart: () => void;
  /** Uses another TMDB key from now on. */
  setTmdbKey: (key: string | null) => void;
  /** Uses another OMDb key from now on, or none. */
  setOmdbKey?: (key: string | null) => void;
  /** The setup is finished: start looking through the folders. */
  startScanning: () => void;
}

export interface SettingsOptions {
  configPath: string;
  /** The config the server runs with. Changed in place, so everything holding it sees the change. */
  config: Config;
  db: Database;
  devices: Devices;
  browser: FolderBrowser;
  hooks: SettingsHooks;
  /** Whether a TMDB key is kept now. */
  hasTmdbKey: boolean;
  tmdbBaseUrl?: string;
  checkKey?: (key: string) => Promise<KeyCheck>;
  /** Whether an OMDb key is kept now. */
  hasOmdbKey?: boolean;
  checkOmdbKey?: (key: string) => Promise<KeyCheck>;
  now?: () => number;
}

const SETUP_META = "setup_state";

interface SetupMeta {
  needed: boolean;
  name: boolean;
  tmdb: "done" | "skipped" | null;
  finishedAt: number | null;
}

const MUSIC = new Set(["music", "audiobooks"]);

interface Root {
  path: string;
  hint: string;
  name?: string;
  group?: string;
}

function same(a: unknown, b: unknown): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

function describeValue(value: unknown): string {
  if (value === null || value === undefined) return "none";
  if (typeof value === "boolean") return value ? "on" : "off";
  if (Array.isArray(value)) return `${String(value.length)} entries`;
  if (typeof value === "string") return value;
  if (typeof value === "number") return String(value);
  return JSON.stringify(value);
}

/** Why a setting inside a part only the file sets up cannot be changed yet. */
const UNAVAILABLE: Readonly<Record<string, string>> = {
  "outside.direct": "Set up the direct connection in lobby.config.json first.",
  "remote.wake":
    "Install pyatv and add remote.wake to lobby.config.json first (docs/operations.md).",
};

const withoutPrefix = (message: string): string => message.replace(/^Lobby config: /, "");

/**
 * The server's settings as managers see and change them: what there is, what a change will do,
 * making it (live where the server can, with a restart where it must), the versions before, the
 * audit log, the TMDB key and the first setup.
 */
export class SettingsService {
  readonly bootId = randomUUID();
  private readonly options: SettingsOptions;
  private readonly now: () => number;
  private readonly dataDir: string;
  private lane: Promise<unknown> = Promise.resolve();
  private hasKey: boolean;
  private hasOmdb: boolean;
  private restarting = false;

  constructor(options: SettingsOptions) {
    this.options = options;
    this.now = options.now ?? Date.now;
    this.dataDir = options.config.dataDir;
    this.hasKey = options.hasTmdbKey;
    this.hasOmdb = options.hasOmdbKey ?? false;
  }

  /**
   * On every start: makes the store from the file the first time, so nothing changes then, and
   * says which keys of the file are no longer read. Notes whether the first setup is still to do.
   */
  ensure(): StoredSettings {
    const file = readConfigFile(this.options.configPath);
    let stored = readSettings(this.dataDir);
    if (!stored) {
      stored = {
        version: 1,
        at: this.now(),
        by: null,
        reason: "imported from lobby.config.json",
        changed: [],
        values: settingsFromFile(file),
      };
      writeSettings(this.dataDir, stored);
      log.info("The server's settings are kept in the data folder from now on", {
        version: stored.version,
      });
    } else {
      const ignored = SETTING_KEYS.filter((key) => {
        const inFile = valueAt(file, key);
        return inFile !== undefined && !same(inFile, stored?.values[key]);
      });
      if (ignored.length > 0) {
        log.warn("lobby.config.json has settings that are changed in the app now; the app's win", {
          keys: ignored.join(", "),
        });
      }
    }
    if (this.options.db.getMeta(SETUP_META) === undefined) {
      const config = this.options.config;
      const fresh = config.roots.length + config.music.roots.length === 0;
      this.writeSetup({
        needed: fresh,
        name: !fresh,
        tmdb: null,
        finishedAt: fresh ? null : this.now(),
      });
    }
    return stored;
  }

  get current(): StoredSettings {
    const stored = readSettings(this.dataDir);
    if (!stored) throw new SettingsError("unavailable", "The settings are not ready yet.");
    return stored;
  }

  get isRestarting(): boolean {
    return this.restarting;
  }

  // ---- Reading ----

  describe(): Record<string, unknown> {
    const stored = this.current;
    const config = this.options.config;
    const file = readConfigFile(this.options.configPath);
    return {
      version: stored.version,
      updatedAt: stored.at,
      updatedBy: this.deviceName(stored.by),
      bootId: this.bootId,
      restarting: this.restarting,
      sections: SECTIONS,
      settings: SETTINGS.map((one) => {
        const parent = WITHIN_FILE[one.key];
        const available = parent === undefined || valueAt(file, parent) !== undefined;
        return {
          key: one.key,
          section: one.section,
          title: one.title,
          help: one.help,
          type: one.type,
          apply: one.apply,
          default: one.default,
          nullable: one.nullable === true,
          ...(one.min === undefined ? {} : { min: one.min }),
          ...(one.max === undefined ? {} : { max: one.max }),
          value: Object.hasOwn(stored.values, one.key) ? stored.values[one.key] : one.default,
          available,
          ...(available
            ? {}
            : {
                unavailableReason: UNAVAILABLE[parent] ?? "Set it up in lobby.config.json first.",
              }),
        };
      }),
      secrets: { tmdbKey: this.tmdbStatus(), omdbKey: this.omdbStatus() },
      // Shown, not changed here: the file holds them.
      fixed: {
        configFile: this.options.configPath,
        dataDir: config.dataDir,
        host: config.host,
        port: config.port,
        claim: config.claim,
        outside:
          config.outside === null
            ? null
            : {
                name: config.outside.name,
                relay: config.outside.tls !== null,
                direct: config.outside.direct !== null,
              },
      },
      setup: this.setup(),
    };
  }

  history(): Record<string, unknown>[] {
    const current = this.current;
    return [current, ...settingsHistory(this.dataDir)].map((one) => ({
      version: one.version,
      at: one.at,
      by: this.deviceName(one.by),
      reason: one.reason,
      changed: one.changed,
      current: one.version === current.version,
    }));
  }

  audit(limit: number): Record<string, unknown>[] {
    return this.options.db
      .all<{
        id: number;
        at: number;
        device_id: string | null;
        action: string;
        version: number | null;
        keys_json: string;
        note: string | null;
      }>("select * from settings_audit order by id desc limit ?", [limit])
      .map((row) => ({
        id: row.id,
        at: row.at,
        by: this.deviceName(row.device_id),
        action: row.action,
        version: row.version,
        keys: JSON.parse(row.keys_json) as string[],
        note: row.note,
      }));
  }

  private deviceName(id: string | null): { id: string; name: string } | null {
    if (id === null) return null;
    const device = this.options.devices.list().find((one) => one.id === id);
    return { id, name: device?.name ?? "A removed device" };
  }

  private note(
    deviceId: string | null,
    action: string,
    version: number | null,
    keys: string[],
    note: string | null,
  ): void {
    this.options.db.run(
      "insert into settings_audit (at, device_id, action, version, keys_json, note) values (?, ?, ?, ?, ?, ?)",
      [this.now(), deviceId, action, version, JSON.stringify(keys), note],
    );
  }

  // ---- Changing ----

  /** One change at a time: two managers at once must not each undo the other's half. */
  private serially<T>(work: () => Promise<T>): Promise<T> {
    const run = this.lane.then(work, work);
    this.lane = run.catch(() => undefined);
    return run;
  }

  /**
   * Checks `changes` and, unless `dryRun`, makes them.
   *
   * @param baseVersion the version the manager saw; a change on top of another is refused
   */
  change(
    deviceId: string,
    changes: Record<string, unknown>,
    options: { dryRun: boolean; baseVersion: number | null },
  ): Promise<{ plan: Plan; version: number }> {
    return this.serially(async () => {
      const current = this.current;
      if (options.baseVersion !== null && options.baseVersion !== current.version) {
        throw new SettingsError(
          "conflict",
          "The settings were changed meanwhile. Look at them again and make the change once more.",
        );
      }
      const problems: { key: string | null; message: string }[] = [];
      const values = structuredClone(current.values);
      for (const [key, value] of Object.entries(changes)) {
        const definition = DEFINITIONS.get(key);
        if (!definition) {
          problems.push({ key, message: `There is no setting "${key}" that can be changed here.` });
          continue;
        }
        try {
          values[key] = definition.check(value);
        } catch (error) {
          problems.push({ key, message: `${definition.title} ${(error as Error).message}` });
        }
      }
      if (problems.length > 0) return this.refuse(deviceId, Object.keys(changes), problems);
      return this.make(deviceId, current, values, "changed", options.dryRun, "change");
    });
  }

  /** Makes an earlier version the one in use again, as a new version. */
  restore(
    deviceId: string,
    version: number,
    dryRun: boolean,
  ): Promise<{ plan: Plan; version: number }> {
    return this.serially(async () => {
      const current = this.current;
      const earlier = settingsVersion(this.dataDir, version);
      if (!earlier) throw new SettingsError("not_found", "That version is no longer kept.");
      return this.make(
        deviceId,
        current,
        structuredClone(earlier.values),
        `restored ${String(version)}`,
        dryRun,
        "restore",
      );
    });
  }

  private refuse(
    deviceId: string,
    keys: string[],
    problems: { key: string | null; message: string }[],
  ): never {
    this.note(
      deviceId,
      "refused",
      null,
      keys,
      problems
        .map((one) => one.message)
        .join(" ")
        .slice(0, 1000),
    );
    throw new SettingsError(
      "invalid_request",
      problems[0]?.message ?? "That change cannot be made.",
      problems,
    );
  }

  private async make(
    deviceId: string,
    current: StoredSettings,
    values: Record<string, unknown>,
    reason: string,
    dryRun: boolean,
    action: "change" | "restore",
  ): Promise<{ plan: Plan; version: number }> {
    const changedKeys = (): string[] =>
      SETTING_KEYS.filter((key) => !same(current.values[key], values[key]));
    try {
      // Also puts each new folder as it really is, without links on the way.
      await this.checkPlaces(current.values, values, changedKeys());
    } catch (error) {
      if (error instanceof SettingsError && error.code === "invalid_request") {
        return this.refuse(deviceId, changedKeys(), error.problems);
      }
      throw error;
    }
    const changed = changedKeys();
    const file = readConfigFile(this.options.configPath);
    let next: Config;
    try {
      next = parseConfig(withSettings(file, values), this.options.configPath);
    } catch (error) {
      return this.refuse(deviceId, changed, [
        {
          key: changed.length === 1 ? (changed[0] ?? null) : null,
          message: withoutPrefix((error as Error).message),
        },
      ]);
    }
    if (dataDirOf(file, this.options.configPath) !== this.dataDir) {
      throw new SettingsError(
        "conflict",
        "The config file names another data folder. Restart the server first.",
      );
    }
    const plan = this.plan(current.values, values, changed);
    if (dryRun || changed.length === 0) return { plan, version: current.version };

    const config = this.options.config;
    const previous = structuredClone(config);
    const live = changed.filter((key) => DEFINITIONS.get(key)?.apply === "live");
    Object.assign(config, next);
    try {
      await this.options.hooks.apply(config, previous, live);
    } catch (error) {
      Object.assign(config, previous);
      await this.options.hooks.apply(config, next, live).catch(() => undefined);
      this.note(
        deviceId,
        "refused",
        null,
        changed,
        `The server could not take it: ${(error as Error).message}`.slice(0, 1000),
      );
      throw new SettingsError(
        "conflict",
        `Nothing was changed: the server could not take it. ${(error as Error).message}`,
      );
    }
    const stored: StoredSettings = {
      version: current.version + 1,
      at: this.now(),
      by: deviceId,
      reason,
      changed,
      values,
    };
    try {
      writeSettings(this.dataDir, stored);
    } catch (error) {
      // Not kept, so not used either: the server goes back to what is kept.
      Object.assign(config, previous);
      await this.options.hooks.apply(config, next, live).catch(() => undefined);
      this.note(deviceId, "refused", null, changed, "The settings could not be written.");
      throw new SettingsError(
        "unavailable",
        `Nothing was changed: the settings could not be written (${(error as NodeJS.ErrnoException).code ?? "error"}).`,
      );
    }
    this.note(deviceId, action, stored.version, changed, plan.restart ? "restart" : null);
    log.info("A manager changed the server's settings", {
      by: deviceId,
      version: stored.version,
      keys: changed.join(", "),
      restart: plan.restart,
    });
    if (changed.includes("serverName")) this.markSetup({ name: true });
    return { plan, version: stored.version };
  }

  /** Restarts the server once the answer is out. */
  restartSoon(): void {
    if (this.restarting) return;
    this.restarting = true;
    log.info("The server restarts to take its new settings");
    setTimeout(() => {
      this.options.hooks.restart();
    }, 300).unref();
  }

  /** New folders must be on the server's drives or in its home folder, and Lobby's folder too. */
  private async checkPlaces(
    before: Record<string, unknown>,
    after: Record<string, unknown>,
    changed: string[],
  ): Promise<void> {
    const browser = this.options.browser;
    const problems: { key: string; message: string }[] = [];
    if (changed.includes("roots")) {
      const known = new Set(
        ((before["roots"] as { path: string }[] | undefined) ?? []).map((one) => one.path),
      );
      for (const root of (after["roots"] as { path: string }[] | undefined) ?? []) {
        // One there already may be on a drive that is away now; that does not stop other changes.
        if (known.has(root.path)) continue;
        try {
          await browser.allowed(root.path);
          // As picked, without "..": the config compares folders by their paths.
          root.path = resolve(root.path);
        } catch (error) {
          problems.push({ key: "roots", message: `${root.path}: ${(error as Error).message}` });
        }
      }
    }
    const dir = after["conversion.dir"];
    if (changed.includes("conversion.dir") && typeof dir === "string") {
      try {
        const real = await browser.allowed(dir, true);
        after["conversion.dir"] = resolve(dir);
        // Also as they really are, so that a link does not hide that one is inside the other.
        for (const root of (after["roots"] as { path: string }[] | undefined) ?? []) {
          let rootReal: string;
          try {
            rootReal = await realpath(root.path);
          } catch {
            continue;
          }
          if (
            real === rootReal ||
            real.startsWith(`${rootReal}/`) ||
            rootReal.startsWith(`${real}/`)
          ) {
            problems.push({
              key: "conversion.dir",
              message: "Lobby's folder must be outside every library folder, and hold none.",
            });
          }
        }
        const known = this.options.db.getMeta("conversion_folder_id");
        if (known !== undefined) {
          let id: unknown = null;
          try {
            id = (
              JSON.parse(await readFile(join(real, "lobby-folder.json"), "utf8")) as {
                id?: unknown;
              }
            ).id;
          } catch {
            // Not Lobby's folder.
          }
          if (id !== known) {
            problems.push({
              key: "conversion.dir",
              message:
                "Lobby's folder is elsewhere already, with the originals of converted files in it. Pick that folder again; moving it is done by hand (see docs/conversion.md).",
            });
          }
        }
      } catch (error) {
        if (!(error instanceof BrowseError)) throw error;
        problems.push({ key: "conversion.dir", message: error.message });
      }
    }
    if (problems.length > 0) {
      throw new SettingsError("invalid_request", problems[0]?.message ?? "", problems);
    }
  }

  private plan(
    before: Record<string, unknown>,
    after: Record<string, unknown>,
    changed: string[],
  ): Plan {
    const effects: Effect[] = [];
    let rescanFolders = 0;
    for (const key of changed) {
      const definition = DEFINITIONS.get(key);
      if (!definition) continue;
      const effect = (message: string, apply: ApplyMode = definition.apply): void => {
        effects.push({ key, title: definition.title, apply, message });
      };
      const old = Object.hasOwn(before, key) ? before[key] : definition.default;
      const now = Object.hasOwn(after, key) ? after[key] : definition.default;
      switch (key) {
        case "roots": {
          const was = new Map(((old as Root[] | null) ?? []).map((one) => [one.path, one]));
          const is = new Map(((now as Root[] | null) ?? []).map((one) => [one.path, one]));
          const added = [...is.values()].filter((one) => !was.has(one.path));
          const removed = [...was.values()].filter((one) => !is.has(one.path));
          const reread = [...is.values()].filter((one) => {
            const earlier = was.get(one.path);
            return earlier !== undefined && earlier.hint !== one.hint;
          });
          const renamed = [...is.values()].filter((one) => {
            const earlier = was.get(one.path);
            return earlier !== undefined && earlier.hint === one.hint && !same(earlier, one);
          });
          const audio = (list: Root[]): boolean => list.some((one) => MUSIC.has(one.hint));
          const audioChanged =
            audio(added) ||
            audio(removed) ||
            reread.some((one) => MUSIC.has(one.hint) || MUSIC.has(was.get(one.path)?.hint ?? ""));
          const video = (list: Root[]): Root[] => list.filter((one) => !MUSIC.has(one.hint));
          rescanFolders = video(added).length + video(reread).length;
          if (added.length > 0) {
            effect(
              `Will look through ${String(added.length)} new ${added.length === 1 ? "folder" : "folders"}.`,
              "live",
            );
          }
          if (reread.length > 0) {
            effect(
              `${String(reread.length)} ${reread.length === 1 ? "folder is" : "folders are"} read again as another kind.`,
              "live",
            );
          }
          if (renamed.length > 0)
            effect(
              `${String(renamed.length)} ${renamed.length === 1 ? "folder gets" : "folders get"} a new name or group.`,
              "live",
            );
          if (removed.length > 0) {
            effect(
              `The titles in ${String(removed.length)} ${removed.length === 1 ? "folder leave" : "folders leave"} the library. Watch history is kept and comes back if the folder is added again. Nothing on the drive is touched.`,
              "live",
            );
          }
          if (audioChanged)
            effect("Music and audiobook folders are taken after a restart.", "restart");
          break;
        }
        case "import.folders": {
          interface Folder {
            path: string;
            mode: string;
          }
          const was = new Map(((old as Folder[] | null) ?? []).map((one) => [one.path, one]));
          const is = (now as Folder[] | null) ?? [];
          const added = is.filter((one) => !was.has(one.path));
          const removed = [...was.values()].filter(
            (one) => !is.some((other) => other.path === one.path),
          );
          const moving = is.filter(
            (one) => one.mode === "move" && was.get(one.path)?.mode === "index",
          );
          for (const one of added) {
            effect(
              one.mode === "move"
                ? `Finished files in ${one.path} will be moved into the library.`
                : `Finished files in ${one.path} will be listed where they are; nothing there is moved.`,
            );
          }
          for (const one of moving) {
            effect(`Files in ${one.path} will be moved into the library from now on.`);
          }
          if (removed.length > 0) {
            effect(
              `${String(removed.length)} ${removed.length === 1 ? "folder is" : "folders are"} no longer watched. Nothing in ${removed.length === 1 ? "it" : "them"} is touched; what was listed from there leaves the library.`,
            );
          }
          if (added.length + moving.length + removed.length === 0)
            effect("The import folders change.");
          break;
        }
        case "conversion.dir":
          effect(
            now === null
              ? "Converting stops. Originals that were kept stay where they are."
              : `Converting uses ${describeValue(now)} after a restart. Converted files' originals are kept there.`,
          );
          break;
        case "conversion.hours":
          effect(
            now === null
              ? "The server converts at any hour, when nobody is watching."
              : `The server converts between ${describeValue(now).replace("-", " and ")}.`,
          );
          break;
        case "conversion.server":
          effect(
            now === true
              ? "The server converts by itself again."
              : "The server stops converting; Macs can still take jobs. A job under way finishes first.",
          );
          break;
        case "serverName":
          effect(`Devices will show “${describeValue(now)}”.`);
          break;
        case "addresses.remote":
          effect(
            `Paired devices are told ${describeValue(now)} to try away from home. This opens nothing.`,
          );
          break;
        case "remote.wake.enabled":
          effect(
            now === false
              ? "Play On no longer turns Apple TVs on. They stay connected."
              : "Play On turns connected Apple TVs on and opens Lobby on them.",
          );
          break;
        case "remote.wake.kids":
          effect(
            now === true
              ? "In kids mode, Play On may turn a connected Apple TV on."
              : "In kids mode, Play On shows only TVs that are on with Lobby open.",
          );
          break;
        case "remote.wake.pickProfile":
          effect(
            now === false
              ? "A woken Apple TV that asks who is watching waits for someone to pick a profile."
              : "A woken Apple TV that asks who is watching takes the profile that is focused.",
          );
          break;
        case "backup.everyHours":
          effect(
            now === 0
              ? "The server no longer backs up by itself."
              : `The server backs up every ${describeValue(now)} hours.`,
          );
          break;
        default:
          effect(`${definition.title}: ${describeValue(old)} → ${describeValue(now)}.`);
      }
    }
    const restart = effects.some((one) => one.apply === "restart");
    if (restart) {
      effects.push({
        key: "",
        title: "Restart",
        apply: "restart",
        message:
          "The server restarts to take this. Playing stops for a few seconds, and devices reconnect by themselves.",
      });
    }
    return { effects, restart, rescanFolders, changed };
  }

  // ---- The TMDB key ----

  tmdbStatus(): { set: boolean; source: "settings" | "environment" | null } {
    if (tmdbKeyFromEnvironment()) return { set: true, source: "environment" };
    return { set: this.hasKey, source: this.hasKey ? "settings" : null };
  }

  /** Checks the key with TMDB and keeps it. The key is never logged, stored elsewhere or sent back. */
  async setTmdbKey(deviceId: string, key: unknown): Promise<void> {
    if (tmdbKeyFromEnvironment()) {
      throw new SettingsError(
        "conflict",
        "The server's TMDB key is set in its environment (LOBBY_TMDB_API_KEY). Change it there.",
      );
    }
    if (typeof key !== "string" || !looksLikeTmdbKey(key.trim())) {
      throw new SettingsError(
        "invalid_request",
        "That is not a TMDB key. Copy the “API Key” or the “API Read Access Token” from themoviedb.org → Settings → API.",
      );
    }
    const trimmed = key.trim();
    const check =
      this.options.checkKey ?? ((one: string) => checkTmdbKey(one, this.options.tmdbBaseUrl));
    const answer = await check(trimmed);
    if (answer === "refused") {
      this.note(deviceId, "refused", null, ["tmdbKey"], "TMDB did not accept the key.");
      throw new SettingsError(
        "invalid_request",
        "TMDB does not accept this key. Copy it again from themoviedb.org → Settings → API; it may also have been revoked there.",
      );
    }
    if (answer === "unreachable") {
      throw new SettingsError(
        "unavailable",
        "TMDB could not be reached to check the key. Nothing was changed; try again in a while.",
      );
    }
    saveTmdbApiKey(this.dataDir, trimmed);
    this.hasKey = true;
    this.options.hooks.setTmdbKey(trimmed);
    this.note(deviceId, "tmdb_set", null, ["tmdbKey"], null);
    this.markSetup({ tmdb: "done" });
    log.info("A manager set the TMDB key", { by: deviceId });
  }

  removeTmdbKey(deviceId: string): void {
    if (tmdbKeyFromEnvironment()) {
      throw new SettingsError(
        "conflict",
        "The server's TMDB key is set in its environment (LOBBY_TMDB_API_KEY). Remove it there.",
      );
    }
    saveTmdbApiKey(this.dataDir, null);
    this.hasKey = false;
    this.options.hooks.setTmdbKey(null);
    this.note(deviceId, "tmdb_removed", null, ["tmdbKey"], null);
    log.info("A manager removed the TMDB key", { by: deviceId });
  }

  // ---- The OMDb key ----

  /** Off until the owner sets a key: without one OMDb is never asked anything. */
  omdbStatus(): { set: boolean; source: "settings" | null } {
    return { set: this.hasOmdb, source: this.hasOmdb ? "settings" : null };
  }

  /** Checks the key with OMDb and keeps it. Like the TMDB key, never logged or sent back. */
  async setOmdbKey(deviceId: string, key: unknown): Promise<void> {
    if (typeof key !== "string" || !looksLikeOmdbKey(key.trim())) {
      throw new SettingsError(
        "invalid_request",
        "That is not an OMDb key. Copy the key from the email omdbapi.com sent.",
      );
    }
    const trimmed = key.trim();
    const check = this.options.checkOmdbKey ?? ((one: string) => checkOmdbKey(one));
    const answer = await check(trimmed);
    if (answer === "refused") {
      this.note(deviceId, "refused", null, ["omdbKey"], "OMDb did not accept the key.");
      throw new SettingsError(
        "invalid_request",
        "OMDb does not accept this key. Check that it was activated with the link in OMDb's email.",
      );
    }
    if (answer === "unreachable") {
      throw new SettingsError(
        "unavailable",
        "OMDb could not be reached to check the key. Nothing was changed; try again in a while.",
      );
    }
    saveOmdbApiKey(this.dataDir, trimmed);
    this.hasOmdb = true;
    this.options.hooks.setOmdbKey?.(trimmed);
    this.note(deviceId, "omdb_set", null, ["omdbKey"], null);
    log.info("A manager set the OMDb key", { by: deviceId });
  }

  removeOmdbKey(deviceId: string): void {
    saveOmdbApiKey(this.dataDir, null);
    this.hasOmdb = false;
    this.options.hooks.setOmdbKey?.(null);
    this.note(deviceId, "omdb_removed", null, ["omdbKey"], null);
    log.info("A manager removed the OMDb key", { by: deviceId });
  }

  // ---- The first setup ----

  private readSetup(): SetupMeta {
    try {
      const parsed = JSON.parse(this.options.db.getMeta(SETUP_META) ?? "{}") as Partial<SetupMeta>;
      return {
        needed: parsed.needed === true,
        name: parsed.name === true,
        tmdb: parsed.tmdb === "done" || parsed.tmdb === "skipped" ? parsed.tmdb : null,
        finishedAt: typeof parsed.finishedAt === "number" ? parsed.finishedAt : null,
      };
    } catch {
      return { needed: false, name: true, tmdb: null, finishedAt: null };
    }
  }

  private writeSetup(meta: SetupMeta): void {
    this.options.db.setMeta(SETUP_META, JSON.stringify(meta));
  }

  private markSetup(change: Partial<SetupMeta>): void {
    this.writeSetup({ ...this.readSetup(), ...change });
  }

  /** Whether the folders wait for the setup to finish before they are looked through. */
  get holdsScanning(): boolean {
    return this.readSetup().needed;
  }

  setup(): SetupState {
    const meta = this.readSetup();
    const config = this.options.config;
    const tmdb = this.tmdbStatus().set;
    return {
      needed: meta.needed,
      steps: [
        { id: "name", done: meta.name, skipped: false },
        {
          id: "folders",
          done: config.roots.length + config.music.roots.length > 0,
          skipped: false,
        },
        {
          id: "tmdb",
          done: tmdb || meta.tmdb === "skipped",
          skipped: !tmdb && meta.tmdb === "skipped",
        },
        { id: "scan", done: meta.finishedAt !== null, skipped: false },
      ],
    };
  }

  /** A step the manager went through without changing anything: kept the name, or no key. */
  setupStep(deviceId: string, step: string, state: unknown): SetupState {
    if (step !== "name" && step !== "tmdb") {
      throw new SettingsError("not_found", "There is no such step to mark.");
    }
    if (state !== "done" && state !== "skipped") {
      throw new SettingsError("invalid_request", `"state" must be "done" or "skipped".`);
    }
    if (step === "name") this.markSetup({ name: true });
    else if (state === "skipped") this.markSetup({ tmdb: "skipped" });
    else if (!this.tmdbStatus().set)
      throw new SettingsError("conflict", "There is no TMDB key yet.");
    this.note(deviceId, "setup", null, [step], state);
    return this.setup();
  }

  /** Ends the first setup and starts looking through the folders. */
  finishSetup(deviceId: string): SetupState {
    const config = this.options.config;
    if (config.roots.length + config.music.roots.length === 0) {
      throw new SettingsError("conflict", "Pick at least one folder first.");
    }
    const meta = this.readSetup();
    if (meta.needed) {
      this.writeSetup({ ...meta, needed: false, name: true, finishedAt: this.now() });
      this.note(deviceId, "setup", null, ["scan"], "finished");
      log.info("The first setup is finished; the library is looked through", { by: deviceId });
      this.options.hooks.startScanning();
    }
    return this.setup();
  }
}
