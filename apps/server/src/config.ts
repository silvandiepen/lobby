// SPDX-License-Identifier: MPL-2.0
import { readPushConfig, readPushRoute, type PushConfig, type PushRoute } from "./push/service.ts";
import { randomBytes } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { isIP } from "node:net";
import { basename, isAbsolute, join, resolve } from "node:path";
import { parseRemoteAddresses } from "./addresses.ts";
import { LOGO_PATH } from "./artwork/logos.ts";
import type { SourceHint } from "./library/parse.ts";
import { readOutsideConfig, type OutsideConfig } from "./outside/config.ts";
import { MUSIC_HINTS, type MusicHint, type MusicRootConfig } from "./music/types.ts";
import { readSettings, withSettings } from "./settings/store.ts";

export interface RootConfig {
  path: string;
  /**
   * The category this folder's titles are in, e.g. "Pixar". Defaults to the folder name. Like
   * `group` and `logo` it counts once, when the folder is new: after that managers decide.
   */
  name: string;
  hint: SourceHint;
  /** The part of the library this category belongs to, e.g. "Kids". Without one it is in the main part. */
  group?: string | null;
  /** A studio logo for the category: its picture path on TMDB, e.g. "/abc123def.png". */
  logo?: string | null;
}

export interface Config {
  /** Shown on the Connect screen so the family can check they found the right server. */
  serverName: string;
  /** Catalogue, cache and secrets. Must be on a reliable local volume, not the media drive. */
  dataDir: string;
  /** Interfaces to listen on. Never a public interface: LAN and tailnet only. */
  host: string;
  port: number;
  /** Announce the server on the home network (Bonjour) so the apps find it. Off when it only listens locally. */
  advertise: boolean;
  /**
   * "open" (default): the first device to connect sets the server up. "secret": it
   * also needs the setup secret. Either way this only matters until there is a manager.
   */
  claim: "open" | "secret";
  /** The folders with films, series and videos. Audio folders are in `music`. */
  roots: RootConfig[];
  music: MusicConfig;
  /** Language for titles, summaries and artwork, as a TMDB locale. */
  language: string;
  /** A file younger than this may still be being copied, and is left for the next scan. */
  stabilityMs: number;
  /** How many files are probed at once. Kept low so playback stays smooth on a Pi. */
  probeConcurrency: number;
  /** Minutes between full reconciliation scans, which catch changes the watcher missed. */
  rescanMinutes: number;
  ffprobePath: string;
  ffmpegPath: string;
  playback: PlaybackConfig;
  /** Intros and credits (docs/decisions.md, "Skip Intro"). */
  markers: MarkersConfig;
  backup: BackupConfig;
  /** What is watched, when and by whom (docs/decisions.md, "Statistics"). */
  statistics: StatisticsConfig;
  addresses: AddressesConfig;
  conversion: ConversionConfig;
  /** Import folders and uploads (docs/imports.md). */
  imports: ImportsConfig;
  /** The way in for devices outside the home (docs/outside.md). Null: there is none. */
  outside: OutsideConfig | null;
  /** Waking Apple TVs with pyatv (docs/operations.md). Null: not set up, and nothing is woken. */
  wake: WakeConfig | null;
  /** Apple's push service (`push.apns`): where the team's key is. Null: no pushes. */
  push: PushConfig | null;
  /** How pushes go out (`push.mode`, `push.relay`): through the relay, directly, or not. */
  pushRoute: PushRoute;
  /** The file this config was read from; a copy goes into every backup. */
  configPath: string;
}

export interface ConversionConfig {
  /**
   * Lobby's own folder on the drive the library is on. Converted files are staged
   * here, and the originals they replace are kept here. Outside every library
   * folder. Null (not configured) turns converting off altogether: nothing is
   * converted and no file in the library is ever moved.
   */
  dir: string | null;
  /** The hours the server itself converts in, as minutes after local midnight. Null: any hour. */
  hours: { from: number; to: number } | null;
  /** Whether MKV files with a good picture may be repackaged into MP4. Off by default. */
  repackage: boolean;
  /** Whether the server converts by itself. When off, only Macs take jobs. */
  server: boolean;
  /** Space that must stay free on the drive. */
  minFreeGb: number;
}

export interface ImportsConfig {
  /** Folders whose finished files are moved into the library or listed where they are. None by default. */
  folders: { path: string; mode: "move" | "index"; name: string | null }[];
  /** A file must keep its size and date this long before it is touched. */
  waitMinutes: number;
  /** Whether a file on another drive than its library folder may be copied, proven and removed. */
  copyAcrossDrives: boolean;
  /** The largest file an app may upload. */
  maxFileGb: number;
  /** What unfinished uploads may take together. */
  quotaGb: number;
}

/**
 * `remote.wake` in the file. Where pyatv is, and so which program runs, is set in the file only;
 * whether TVs are woken (`enabled`) is a setting managers change in the app.
 */
export interface WakeConfig {
  /** The `bin` folder of a virtual environment with pyatv in it: its `python3` runs the helper. */
  pyatv: string;
  /** pyatv's file with the TVs' credentials. Default: `~/.pyatv.conf` of the user Lobby runs as. */
  storage: string | null;
  /** Addresses to ask instead of looking on the whole network, where multicast does not reach. */
  hosts: string[];
  /** The app that is opened on the TV. */
  app: string;
  enabled: boolean;
  /** A child's device, or the kids screens, may wake a TV too ("Kids can turn on the TV"). */
  kids: boolean;
  /**
   * When Lobby does not come up after waking (tvOS asks who is watching first), press select
   * once on the TV: that picks whichever profile is focused, normally the last one used.
   */
  pickProfile: boolean;
  /** How long a play that waits for a woken TV is kept, in seconds (`holdPlaySeconds`). */
  holdPlaySeconds: number;
  /**
   * HomePods and other AirPlay speakers on the server's network are in Play On for music and
   * stories, which the server streams to them itself (docs/decisions.md, "Play on a speaker").
   */
  speakers: boolean;
}

export interface AddressesConfig {
  /**
   * Where this server can be reached from outside the home network, e.g. its name in the
   * household's tailnet: `["http://media.example.ts.net:8674"]`. Paired devices are told
   * these and try them when the home address does not answer. Listing an address opens
   * nothing: the road itself (Tailscale, a tunnel) is set up outside Lobby.
   */
  remote: string[];
}

export interface BackupConfig {
  /** Where catalogue backups are written. Defaults to `backups` in the data folder. */
  dir: string;
  /** How many backups are kept; older ones are deleted. */
  keep: number;
  /** Hours between automatic backups while the server runs. 0 turns them off. */
  everyHours: number;
}

export interface StatisticsConfig {
  /** Days a viewer's history and the server's statistics are kept. Older ones are deleted. */
  keepDays: number;
}

export interface PlaybackConfig {
  /**
   * Where repackaged copies are kept. They can be rebuilt at any time. Defaults to
   * `cache/playback` in the data folder; never inside a library root.
   */
  cacheDir: string;
  /** The oldest copies are deleted once the cache passes this size. */
  maxCacheGb: number;
  /** Nothing new is prepared when the cache's volume has less than this free. */
  minFreeGb: number;
  /** How many files are repackaged at once. */
  maxConcurrent: number;
}

export interface MarkersConfig {
  /**
   * Where the sound fingerprints of episodes are kept, about 55 KB an episode. They can be
   * made again. Defaults to `cache/markers` in the data folder; never inside a library root.
   */
  cacheDir: string;
}

export interface MusicConfig {
  /** The entries of "roots" whose hint is "music" or "audiobooks". */
  roots: MusicRootConfig[];
  /** Where compact and converted copies are kept. Defaults to `cache/music` in the data folder. */
  cacheDir: string;
  /** The copies used longest ago are deleted once they pass this size together. */
  maxCacheGb: number;
  /** No copy is made when the cache's volume has less than this free. */
  minFreeGb: number;
}

export interface Secrets {
  /** Claims the first manager device. Shown once in the server log and kept in the data folder. */
  setupSecret: string;
  tmdbApiKey: string | null;
  /** OMDb's, for IMDb, Rotten Tomatoes and Metacritic ratings. Only ever set by the owner. */
  omdbApiKey: string | null;
}

const HINTS: SourceHint[] = ["movies", "series", "personal", "mixed"];

function isMusicHint(hint: string): hint is MusicHint {
  return MUSIC_HINTS.some((one) => one === hint);
}

function fail(message: string): never {
  throw new Error(`Lobby config: ${message}`);
}

/** The file as it was written, before the settings managers changed are put over it. */
export type RawConfig = Record<string, unknown>;

/** Reads `lobby.config.json` without checking what is in it. */
export function readConfigFile(configPath: string): RawConfig {
  if (!existsSync(configPath)) fail(`no config file at ${configPath}.`);
  let raw: unknown;
  try {
    raw = JSON.parse(readFileSync(configPath, "utf8"));
  } catch {
    fail(`${configPath} is not valid JSON.`);
  }
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    fail(`${configPath} must hold a JSON object.`);
  }
  return raw as RawConfig;
}

/** The data folder a config file names. It is read from the file only: the settings live in it. */
export function dataDirOf(raw: RawConfig, configPath: string): string {
  const base = resolve(configPath, "..");
  return typeof raw["dataDir"] === "string" && raw["dataDir"] !== ""
    ? resolve(base, raw["dataDir"])
    : join(base, "data");
}

/**
 * The config the server runs with: the file, with the settings managers changed in the app put
 * over it (`settings/store.ts`). Those win for the keys they hold; the file keeps the rest.
 */
export function loadConfig(configPath: string): Config {
  const file = readConfigFile(configPath);
  const stored = readSettings(dataDirOf(file, configPath));
  return parseConfig(stored ? withSettings(file, stored.values) : file, configPath);
}

/**
 * Checks a whole config and fills in its defaults.
 *
 * @throws Error with a sentence that names what is wrong
 */
export function parseConfig(input: RawConfig, configPath: string): Config {
  const raw = input as Partial<Config>;
  const base = resolve(configPath, "..");

  // None yet: a fresh server, whose folders a manager picks in the app. Nothing is scanned.
  if (raw.roots !== undefined && !Array.isArray(raw.roots)) {
    fail(`"roots" must be a list of folders.`);
  }
  const musicRoots: MusicRootConfig[] = [];
  const roots = (raw.roots ?? []).flatMap((root, index): RootConfig[] => {
    // As the file has it, which need not be what the type says.
    const fields = root as unknown as Record<string, unknown> | null;
    if (typeof fields !== "object" || fields === null) fail(`roots[${index}] must be an object.`);
    if (typeof root.path !== "string" || !isAbsolute(root.path)) {
      fail(`roots[${index}].path must be an absolute path.`);
    }
    const { name, group } = fields;
    if (name != null && (typeof name !== "string" || name.length > 100)) {
      fail(`roots[${index}].name must be a name of at most 100 characters.`);
    }
    if (group != null && (typeof group !== "string" || group.length > 100)) {
      fail(`roots[${index}].group must be a name of at most 100 characters.`);
    }
    if (
      fields["logo"] != null &&
      (typeof fields["logo"] !== "string" || !LOGO_PATH.test(fields["logo"]))
    ) {
      fail(`roots[${index}].logo must be a TMDB picture path like "/abc123def.png".`);
    }
    if (isMusicHint(root.hint)) {
      const path = root.path.replace(/\/+$/, "");
      musicRoots.push({ path, name: root.name || basename(path), hint: root.hint });
      return [];
    }
    if (!HINTS.includes(root.hint)) {
      fail(`roots[${index}].hint must be one of ${[...HINTS, ...MUSIC_HINTS].join(", ")}.`);
    }
    return [
      {
        path: root.path.replace(/\/+$/, ""),
        name: root.name || basename(root.path),
        hint: root.hint,
        group: root.group?.trim() || null,
        logo: root.logo ?? null,
      },
    ];
  });
  for (const root of musicRoots) {
    const overlap = musicRoots.find(
      (other) => other !== root && `${root.path}/`.startsWith(`${other.path}/`),
    );
    // The same file would be two tracks.
    if (overlap) fail(`the audio folders ${overlap.path} and ${root.path} overlap.`);
  }
  const allRoots: { path: string }[] = [...roots, ...musicRoots];

  // An item only knows its categories' names, so one name cannot be in two groups.
  const groupOf = new Map<string, string | null>();
  for (const root of roots) {
    const group = root.group ?? null;
    const known = groupOf.get(root.name);
    if (known !== undefined && known !== group) {
      fail(`the category "${root.name}" is in two groups.`);
    }
    groupOf.set(root.name, group);
  }

  const dataDir = dataDirOf(input, configPath);
  for (const root of allRoots) {
    if (dataDir === root.path || dataDir.startsWith(`${root.path}/`)) {
      fail(`dataDir (${dataDir}) must not be inside a library root.`);
    }
  }

  const rawPlayback: Partial<PlaybackConfig> = raw.playback ?? {};
  const cacheDir = rawPlayback.cacheDir
    ? resolve(base, rawPlayback.cacheDir)
    : join(dataDir, "cache", "playback");
  for (const root of allRoots) {
    if (cacheDir === root.path || cacheDir.startsWith(`${root.path}/`)) {
      fail(`playback.cacheDir (${cacheDir}) must not be inside a library root.`);
    }
  }

  const rawMusic: Partial<MusicConfig> = raw.music ?? {};
  const musicCacheDir = rawMusic.cacheDir
    ? resolve(base, rawMusic.cacheDir)
    : join(dataDir, "cache", "music");
  for (const root of allRoots) {
    if (musicCacheDir === root.path || musicCacheDir.startsWith(`${root.path}/`)) {
      fail(`music.cacheDir (${musicCacheDir}) must not be inside a library root.`);
    }
  }

  const rawMarkers: Partial<MarkersConfig> = raw.markers ?? {};
  if (rawMarkers.cacheDir !== undefined && typeof rawMarkers.cacheDir !== "string") {
    fail(`markers.cacheDir must be a path.`);
  }
  const markersCacheDir = rawMarkers.cacheDir
    ? resolve(base, rawMarkers.cacheDir)
    : join(dataDir, "cache", "markers");
  for (const root of allRoots) {
    if (markersCacheDir === root.path || markersCacheDir.startsWith(`${root.path}/`)) {
      fail(`markers.cacheDir (${markersCacheDir}) must not be inside a library root.`);
    }
  }

  const host = raw.host ?? "127.0.0.1";
  const rawBackup: Partial<BackupConfig> = raw.backup ?? {};
  const rawStatistics: Partial<StatisticsConfig> = raw.statistics ?? {};
  const keepDays = rawStatistics.keepDays ?? 730;
  if (!Number.isInteger(keepDays) || keepDays < 30 || keepDays > 3650) {
    fail("statistics.keepDays must be a whole number of days from 30 to 3650.");
  }
  const backupDir = rawBackup.dir ? resolve(base, rawBackup.dir) : join(dataDir, "backups");
  for (const root of allRoots) {
    if (backupDir === root.path || backupDir.startsWith(`${root.path}/`)) {
      fail(`backup.dir (${backupDir}) must not be inside a library root.`);
    }
  }

  const rawConversion = ((raw.conversion as unknown) ?? {}) as Partial<
    Omit<ConversionConfig, "hours">
  > & { hours?: unknown };
  let conversionDir: string | null = null;
  if (rawConversion.dir !== undefined && rawConversion.dir !== null) {
    if (typeof rawConversion.dir !== "string" || !isAbsolute(rawConversion.dir)) {
      fail(`conversion.dir must be an absolute path.`);
    }
    conversionDir = rawConversion.dir.replace(/\/+$/, "");
    for (const root of allRoots) {
      if (conversionDir === root.path || conversionDir.startsWith(`${root.path}/`)) {
        fail(`conversion.dir (${conversionDir}) must not be inside a library root.`);
      }
      if (root.path.startsWith(`${conversionDir}/`)) {
        fail(`conversion.dir (${conversionDir}) must not contain a library root.`);
      }
    }
    if (conversionDir === dataDir || conversionDir.startsWith(`${dataDir}/`)) {
      fail(`conversion.dir must be on the drive the library is on, not in the data folder.`);
    }
  }
  const imports = readImports((raw as { import?: unknown }).import, uploadsOf(raw), [
    ...allRoots.map((root) => ({ path: root.path, what: "a library folder" })),
    { path: dataDir, what: "the data folder" },
    ...(conversionDir === null ? [] : [{ path: conversionDir, what: "Lobby's folder" }]),
  ]);

  let conversionHours: ConversionConfig["hours"] = null;
  if (rawConversion.hours !== undefined && rawConversion.hours !== null) {
    const match =
      typeof rawConversion.hours === "string"
        ? /^([01]\d|2[0-3]):([0-5]\d)-([01]\d|2[0-3]):([0-5]\d)$/.exec(rawConversion.hours)
        : null;
    if (!match) fail(`conversion.hours must look like "01:00-07:00".`);
    conversionHours = {
      from: Number(match[1]) * 60 + Number(match[2]),
      to: Number(match[3]) * 60 + Number(match[4]),
    };
    if (conversionHours.from === conversionHours.to) {
      fail(`conversion.hours must not start and end at the same time; leave it out for any hour.`);
    }
  }

  let remote: string[];
  try {
    remote = parseRemoteAddresses((raw.addresses as Partial<AddressesConfig> | undefined)?.remote);
  } catch (error) {
    fail(error instanceof Error ? error.message : String(error));
  }

  let outside: OutsideConfig | null;
  try {
    outside = readOutsideConfig(raw.outside, { host, port: raw.port ?? 8674 }, (path) =>
      resolve(base, path),
    );
  } catch (error) {
    fail(error instanceof Error ? error.message : String(error));
  }

  const wake = readWakeConfig((raw as { remote?: unknown }).remote, base);
  let push: PushConfig | null;
  let pushRoute: PushRoute;
  try {
    push = readPushConfig((raw as { push?: unknown }).push, (path) => resolve(base, path));
    pushRoute = readPushRoute((raw as { push?: unknown }).push, push);
  } catch (error) {
    fail(error instanceof Error ? error.message : String(error));
  }

  return {
    configPath,
    outside,
    wake,
    push,
    pushRoute,
    addresses: { remote },
    conversion: {
      dir: conversionDir,
      hours: conversionHours,
      repackage: rawConversion.repackage === true,
      server: rawConversion.server !== false,
      minFreeGb: Math.max(1, rawConversion.minFreeGb ?? 5),
    },
    imports,
    backup: {
      dir: backupDir,
      keep: Math.max(1, rawBackup.keep ?? 7),
      everyHours: Math.max(0, rawBackup.everyHours ?? 24),
    },
    statistics: { keepDays },
    serverName: raw.serverName ?? "Lobby",
    dataDir,
    host,
    port: raw.port ?? 8674,
    claim: raw.claim === "secret" ? "secret" : "open",
    advertise: (raw.advertise ?? true) && !["127.0.0.1", "::1", "localhost"].includes(host),
    roots,
    music: {
      roots: musicRoots,
      cacheDir: musicCacheDir,
      maxCacheGb: Math.max(0.1, rawMusic.maxCacheGb ?? 5),
      minFreeGb: Math.max(0, rawMusic.minFreeGb ?? 2),
    },
    language: raw.language ?? "en-US",
    stabilityMs: raw.stabilityMs ?? 30_000,
    probeConcurrency: Math.max(1, Math.min(raw.probeConcurrency ?? 2, 8)),
    rescanMinutes: Math.max(1, raw.rescanMinutes ?? 30),
    ffprobePath: raw.ffprobePath ?? "ffprobe",
    ffmpegPath: raw.ffmpegPath ?? "ffmpeg",
    playback: {
      cacheDir,
      maxCacheGb: Math.max(1, rawPlayback.maxCacheGb ?? 20),
      minFreeGb: Math.max(0, rawPlayback.minFreeGb ?? 2),
      maxConcurrent: Math.max(1, Math.min(rawPlayback.maxConcurrent ?? 2, 4)),
    },
    markers: { cacheDir: markersCacheDir },
  };
}

function uploadsOf(raw: RawConfig | Partial<Config>): Record<string, unknown> {
  const uploads = (raw as { uploads?: unknown }).uploads;
  if (uploads === undefined || uploads === null) return {};
  if (typeof uploads !== "object" || Array.isArray(uploads)) fail(`"uploads" must be an object.`);
  return uploads as Record<string, unknown>;
}

const overlaps = (a: string, b: string): boolean =>
  a === b || a.startsWith(`${b}/`) || b.startsWith(`${a}/`);

function readImports(
  value: unknown,
  uploads: Record<string, unknown>,
  others: { path: string; what: string }[],
): ImportsConfig {
  if (
    value !== undefined &&
    value !== null &&
    (typeof value !== "object" || Array.isArray(value))
  ) {
    fail(`"import" must be an object.`);
  }
  const raw = (value ?? {}) as Record<string, unknown>;
  const list = raw["folders"] ?? [];
  if (!Array.isArray(list)) fail(`import.folders must be a list of folders.`);
  const folders = list.map((one: unknown, index) => {
    const at = `import.folders[${String(index)}]`;
    if (typeof one !== "object" || one === null) fail(`${at} must be an object.`);
    const { path, mode, name } = one as Record<string, unknown>;
    if (typeof path !== "string" || !isAbsolute(path)) fail(`${at}.path must be an absolute path.`);
    if (mode !== undefined && mode !== "move" && mode !== "index") {
      fail(`${at}.mode must be move or index.`);
    }
    if (name !== undefined && name !== null && (typeof name !== "string" || name.length > 100)) {
      fail(`${at}.name must be a name of at most 100 characters.`);
    }
    const clean = path.replace(/\/+$/, "") || "/";
    if (clean === "/") fail(`${at} cannot be the whole disk.`);
    for (const other of others) {
      // A file there would be in the library twice, or Lobby would move its own files about.
      if (overlaps(clean, other.path))
        fail(`the import folder ${clean} overlaps ${other.what} ${other.path}.`);
    }
    return {
      path: clean,
      mode: mode === "index" ? ("index" as const) : ("move" as const),
      name: typeof name === "string" && name.trim() !== "" ? name.trim() : null,
    };
  });
  for (const folder of folders) {
    const other = folders.find((one) => one !== folder && overlaps(one.path, folder.path));
    if (other) fail(`the import folders ${other.path} and ${folder.path} overlap.`);
  }
  const number = (key: string, given: unknown, fallback: number, min: number): number => {
    if (given === undefined || given === null) return fallback;
    if (typeof given !== "number" || !Number.isFinite(given) || given < min) {
      fail(`${key} must be a number of at least ${String(min)}.`);
    }
    return given;
  };
  return {
    folders,
    waitMinutes: number("import.waitMinutes", raw["waitMinutes"], 10, 1),
    copyAcrossDrives: raw["copyAcrossDrives"] === true,
    maxFileGb: number("uploads.maxFileGb", uploads["maxFileGb"], 100, 0.001),
    quotaGb: number("uploads.quotaGb", uploads["quotaGb"], 500, 0.001),
  };
}

const BUNDLE_ID = /^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/;

function readWakeConfig(remote: unknown, base: string): WakeConfig | null {
  if (remote === undefined || remote === null) return null;
  if (typeof remote !== "object" || Array.isArray(remote)) fail(`"remote" must be an object.`);
  const wake = (remote as Record<string, unknown>)["wake"];
  if (wake === undefined || wake === null) return null;
  if (typeof wake !== "object" || Array.isArray(wake)) {
    fail(`remote.wake must be an object such as { "pyatv": "/home/me/lobby/pyatv/bin" }.`);
  }
  const {
    pyatv,
    storage,
    hosts,
    app,
    enabled,
    kids,
    pickProfile,
    holdPlaySeconds,
    speakers,
    ...rest
  } = wake as Record<string, unknown>;
  if (Object.keys(rest).length > 0) {
    fail(`remote.wake has something unknown: ${Object.keys(rest).join(", ")}.`);
  }
  if (typeof pyatv !== "string" || pyatv === "") {
    fail(`remote.wake.pyatv must be the bin folder of a virtual environment with pyatv in it.`);
  }
  if (
    storage !== undefined &&
    storage !== null &&
    (typeof storage !== "string" || storage === "")
  ) {
    fail(`remote.wake.storage must be a file path.`);
  }
  if (
    hosts !== undefined &&
    (!Array.isArray(hosts) ||
      hosts.length > 16 ||
      !hosts.every((one) => typeof one === "string" && isIP(one) === 4))
  ) {
    fail(`remote.wake.hosts must be a list of at most 16 IPv4 addresses.`);
  }
  if (app !== undefined && (typeof app !== "string" || !BUNDLE_ID.test(app))) {
    fail(`remote.wake.app must be an app's bundle id, such as mt.sil.lobby.`);
  }
  if (enabled !== undefined && typeof enabled !== "boolean") {
    fail(`remote.wake.enabled must be true or false.`);
  }
  if (kids !== undefined && typeof kids !== "boolean") {
    fail(`remote.wake.kids must be true or false.`);
  }
  if (pickProfile !== undefined && typeof pickProfile !== "boolean") {
    fail(`remote.wake.pickProfile must be true or false.`);
  }
  if (speakers !== undefined && typeof speakers !== "boolean") {
    fail(`remote.wake.speakers must be true or false.`);
  }
  if (
    holdPlaySeconds !== undefined &&
    (typeof holdPlaySeconds !== "number" ||
      !Number.isInteger(holdPlaySeconds) ||
      holdPlaySeconds < 15 ||
      holdPlaySeconds > 900)
  ) {
    fail(`remote.wake.holdPlaySeconds must be a whole number of seconds from 15 to 900.`);
  }
  return {
    pyatv: resolve(base, pyatv),
    storage: typeof storage === "string" ? resolve(base, storage) : null,
    hosts: (hosts as string[] | undefined) ?? [],
    app: app ?? "mt.sil.lobby",
    enabled: enabled !== false,
    kids: kids === true,
    pickProfile: pickProfile !== false,
    holdPlaySeconds: holdPlaySeconds ?? 180,
    speakers: speakers !== false,
  };
}

/** Reads the server's secrets, creating the file (owner-only) on first start. */
export function loadSecrets(dataDir: string): Secrets {
  mkdirSync(dataDir, { recursive: true });
  const path = join(dataDir, "secrets.json");
  let secrets: Partial<Secrets> = {};
  if (existsSync(path)) secrets = JSON.parse(readFileSync(path, "utf8")) as Partial<Secrets>;
  const complete: Secrets = {
    setupSecret: secrets.setupSecret ?? randomBytes(9).toString("base64url"),
    tmdbApiKey: tmdbKeyFromEnvironment()
      ? (process.env["LOBBY_TMDB_API_KEY"] ?? null)
      : (secrets.tmdbApiKey ?? null),
    omdbApiKey: secrets.omdbApiKey ?? null,
  };
  if (secrets.setupSecret === undefined) {
    writeFileSync(
      path,
      `${JSON.stringify({ setupSecret: complete.setupSecret, tmdbApiKey: secrets.tmdbApiKey ?? null }, null, 2)}\n`,
      { mode: 0o600 },
    );
  }
  chmodSync(path, 0o600);
  return complete;
}

/** Whether the TMDB key comes from the environment, which the app cannot change. */
export function tmdbKeyFromEnvironment(): boolean {
  return (process.env["LOBBY_TMDB_API_KEY"] ?? "") !== "";
}

/**
 * Keeps the TMDB key, or forgets it with null. Written beside the file and renamed over it, so
 * the setup secret is never lost halfway.
 */
export function saveTmdbApiKey(dataDir: string, key: string | null): void {
  saveSecret(dataDir, "tmdbApiKey", key);
}

/** Keeps the OMDb key, or forgets it with null. */
export function saveOmdbApiKey(dataDir: string, key: string | null): void {
  saveSecret(dataDir, "omdbApiKey", key);
}

function saveSecret(dataDir: string, name: "tmdbApiKey" | "omdbApiKey", key: string | null): void {
  const path = join(dataDir, "secrets.json");
  const secrets = JSON.parse(readFileSync(path, "utf8")) as Secrets;
  const temporary = `${path}.writing`;
  writeFileSync(temporary, `${JSON.stringify({ ...secrets, [name]: key }, null, 2)}\n`, {
    mode: 0o600,
  });
  chmodSync(temporary, 0o600);
  renameSync(temporary, path);
}
