// SPDX-License-Identifier: MPL-2.0
import { looksLikeDownloads } from "../imports/service.ts";
import { MUSIC_HINTS } from "../music/types.ts";
import type { SettingKey } from "./store.ts";

/**
 * What a manager can change in the app, described for the app: where it is shown, what it means
 * in plain words, what values it takes, and whether the server takes it at once or restarts.
 *
 * Deliberately not here, and so only in `lobby.config.json`: where the server listens (`host`,
 * `port`), its data folder, the programs it runs (`ffmpegPath`, `ffprobePath`,
 * `outside.direct.binary`), how a server is claimed, files with keys and certificates, and the
 * outside entrance's set-up. A wrong one of those can lock everyone out, or run a program of
 * someone's choosing; they are set by whoever has the machine in hand.
 */

export type SectionId =
  "general" | "library" | "imports" | "converting" | "away" | "backups" | "advanced";

export const SECTIONS: readonly { id: SectionId; title: string }[] = [
  { id: "general", title: "General" },
  { id: "library", title: "Library folders" },
  { id: "imports", title: "Import folders and uploads" },
  { id: "converting", title: "Converting" },
  { id: "away", title: "Away from home" },
  { id: "backups", title: "Backups" },
  { id: "advanced", title: "Advanced" },
];

export type SettingType =
  | "text"
  | "toggle"
  | "integer"
  | "number"
  | "hours"
  | "folder"
  | "folders"
  | "importFolders"
  | "addresses"
  | "language";

/** "live": the server takes it at once. "restart": the server restarts itself, which takes seconds. */
export type ApplyMode = "live" | "restart";

export interface SettingDefinition {
  key: SettingKey;
  section: SectionId;
  title: string;
  /** What it does, in a sentence or two. */
  help: string;
  type: SettingType;
  apply: ApplyMode;
  default: unknown;
  /** Whether null is a value of its own: "none" for a folder, "any hour" for hours. */
  nullable?: boolean;
  min?: number;
  max?: number;
  /**
   * Checks a value as a manager sent it and gives it back as it is stored.
   *
   * @throws Error with a sentence that can be shown as it is
   */
  check: (value: unknown) => unknown;
}

const HOURS = /^([01]\d|2[0-3]):([0-5]\d)-([01]\d|2[0-3]):([0-5]\d)$/;
const LANGUAGE = /^[a-z]{2}(-[A-Z]{2})?$/;

function toggle(value: unknown): boolean {
  if (typeof value !== "boolean") throw new Error("must be on or off (true or false).");
  return value;
}

function whole(min: number, max: number): (value: unknown) => number {
  return (value) => {
    if (typeof value !== "number" || !Number.isInteger(value) || value < min || value > max) {
      throw new Error(`must be a whole number from ${String(min)} to ${String(max)}.`);
    }
    return value;
  };
}

function amount(min: number, max: number): (value: unknown) => number {
  return (value) => {
    if (typeof value !== "number" || !Number.isFinite(value) || value < min || value > max) {
      throw new Error(`must be a number from ${String(min)} to ${String(max)}.`);
    }
    return value;
  };
}

function folderPath(value: unknown): string {
  if (typeof value !== "string" || !value.startsWith("/") || value.length > 1024) {
    throw new Error("must be a folder on the server, picked from its drives.");
  }
  if (value.includes("\0")) throw new Error("must be a folder on the server.");
  return value.replace(/\/+$/, "") || "/";
}

const ROOT_HINTS = ["movies", "series", "personal", "mixed", ...MUSIC_HINTS] as const;
const MAX_ROOTS = 64;

function roots(value: unknown): unknown[] {
  if (!Array.isArray(value) || value.length > MAX_ROOTS) {
    throw new Error(`must be a list of at most ${String(MAX_ROOTS)} folders.`);
  }
  const seen = new Set<string>();
  return value.map((one: unknown, index) => {
    const at = `Folder ${String(index + 1)}`;
    if (typeof one !== "object" || one === null || Array.isArray(one)) {
      throw new Error(`${at} must have a path and a kind.`);
    }
    const { path, name, hint, group, logo, ...rest } = one as Record<string, unknown>;
    if (Object.keys(rest).length > 0)
      throw new Error(`${at} has something unknown: ${Object.keys(rest).join(", ")}.`);
    let checked: string;
    try {
      checked = folderPath(path);
    } catch (error) {
      throw new Error(`${at} ${(error as Error).message}`, { cause: error });
    }
    if (seen.has(checked)) throw new Error(`${at} is in the list twice.`);
    seen.add(checked);
    if (typeof hint !== "string" || !(ROOT_HINTS as readonly string[]).includes(hint)) {
      throw new Error(`${at} must say what is in it: ${ROOT_HINTS.join(", ")}.`);
    }
    const root: Record<string, unknown> = { path: checked, hint };
    if (name !== undefined && name !== null) {
      if (typeof name !== "string" || name.trim() === "" || name.length > 100) {
        throw new Error(`${at} must have a name of at most 100 characters.`);
      }
      root["name"] = name.trim();
    }
    if (group !== undefined && group !== null) {
      if (typeof group !== "string" || group.length > 100) {
        throw new Error(`${at}'s group must be a name of at most 100 characters.`);
      }
      if (group.trim() !== "") root["group"] = group.trim();
    }
    if (logo !== undefined && logo !== null) root["logo"] = logo;
    return root;
  });
}

const MAX_IMPORT_FOLDERS = 16;

/**
 * Import folders. A folder whose name says a download program may use it is indexed where it is
 * unless the manager chose otherwise: moving a file such a program still needs would break it.
 */
function importFolders(value: unknown): unknown[] {
  if (!Array.isArray(value) || value.length > MAX_IMPORT_FOLDERS) {
    throw new Error(`must be a list of at most ${String(MAX_IMPORT_FOLDERS)} folders.`);
  }
  const seen = new Set<string>();
  return value.map((one: unknown, index) => {
    const at = `Folder ${String(index + 1)}`;
    if (typeof one !== "object" || one === null || Array.isArray(one)) {
      throw new Error(`${at} must have a path.`);
    }
    const { path, mode, name, ...rest } = one as Record<string, unknown>;
    if (Object.keys(rest).length > 0)
      throw new Error(`${at} has something unknown: ${Object.keys(rest).join(", ")}.`);
    let checked: string;
    try {
      checked = folderPath(path);
    } catch (error) {
      throw new Error(`${at} ${(error as Error).message}`, { cause: error });
    }
    if (checked === "/") throw new Error(`${at} cannot be the whole disk.`);
    if (seen.has(checked)) throw new Error(`${at} is in the list twice.`);
    seen.add(checked);
    if (mode !== undefined && mode !== null && mode !== "move" && mode !== "index") {
      throw new Error(`${at} must be moved into the library (move) or listed where it is (index).`);
    }
    const folder: Record<string, unknown> = {
      path: checked,
      mode: mode ?? (looksLikeDownloads(checked) ? "index" : "move"),
    };
    if (name !== undefined && name !== null) {
      if (typeof name !== "string" || name.length > 100) {
        throw new Error(`${at} must have a name of at most 100 characters.`);
      }
      if (name.trim() !== "") folder["name"] = name.trim();
    }
    return folder;
  });
}

function addresses(value: unknown): string[] {
  // The config checks each one; here only the shape.
  if (!Array.isArray(value) || !value.every((one) => typeof one === "string")) {
    throw new Error("must be a list of addresses such as https://lobby.example.ts.net.");
  }
  return value;
}

export const SETTINGS: readonly SettingDefinition[] = [
  {
    key: "serverName",
    section: "general",
    title: "Name",
    help: "Shown when a device looks for servers, so everyone can tell they found the right one.",
    type: "text",
    apply: "live",
    default: "Lobby",
    check: (value) => {
      if (typeof value !== "string" || value.trim() === "" || value.trim().length > 60) {
        throw new Error("must be a name of 1 to 60 characters.");
      }
      if (
        Array.from({ length: value.length }, (_, at) => value.charCodeAt(at)).some(
          (code) => code < 32,
        )
      )
        throw new Error("must be a name without control characters.");
      return value.trim();
    },
  },
  {
    key: "advertise",
    section: "general",
    title: "Show on the home network",
    help: "Devices at home find the server by themselves. Off: they need its address typed in.",
    type: "toggle",
    apply: "restart",
    default: true,
    check: toggle,
  },
  {
    key: "language",
    section: "general",
    title: "Language of titles",
    help: "Titles, summaries and posters come from TMDB in this language, such as en-US or nl-NL.",
    type: "language",
    apply: "restart",
    default: "en-US",
    check: (value) => {
      if (typeof value !== "string" || !LANGUAGE.test(value)) {
        throw new Error("must be a language code such as en-US or nl-NL.");
      }
      return value;
    },
  },
  {
    key: "roots",
    section: "library",
    title: "Folders",
    help: "The folders with films, series, home videos, music and audiobooks. Lobby only reads them.",
    type: "folders",
    apply: "live",
    default: [],
    check: roots,
  },
  {
    key: "rescanMinutes",
    section: "library",
    title: "Look through everything every",
    help: "Minutes between full looks through the folders. New files are usually found at once anyway.",
    type: "integer",
    apply: "live",
    default: 30,
    min: 1,
    max: 1440,
    check: whole(1, 1440),
  },
  {
    key: "import.folders",
    section: "imports",
    title: "Import folders",
    help: "Folders where new films and episodes land. Finished files are moved into the library under a neat name, or listed where they are. A folder a download program uses is listed where it is, unless you choose to move.",
    type: "importFolders",
    apply: "live",
    default: [],
    check: importFolders,
  },
  {
    key: "import.waitMinutes",
    section: "imports",
    title: "Wait before importing (minutes)",
    help: "A file is only touched once its size and date have not changed for this long.",
    type: "integer",
    apply: "live",
    default: 10,
    min: 1,
    max: 1440,
    check: whole(1, 1440),
  },
  {
    key: "import.copyAcrossDrives",
    section: "imports",
    title: "Copy between drives",
    help: "Off: a file on another drive than its library folder waits in the Inbox. On: it is copied, checked byte for byte, and then removed where it was.",
    type: "toggle",
    apply: "live",
    default: false,
    check: toggle,
  },
  {
    key: "uploads.maxFileGb",
    section: "imports",
    title: "Largest upload (GB)",
    help: "Files larger than this are refused before anything is sent.",
    type: "number",
    apply: "live",
    default: 100,
    min: 0.1,
    max: 10_000,
    check: amount(0.1, 10_000),
  },
  {
    key: "uploads.quotaGb",
    section: "imports",
    title: "Room for unfinished uploads (GB)",
    help: "What uploads that are still arriving may take on the drive together.",
    type: "number",
    apply: "live",
    default: 500,
    min: 1,
    max: 100_000,
    check: amount(1, 100_000),
  },
  {
    key: "conversion.dir",
    section: "converting",
    title: "Lobby's folder",
    help: "A folder of Lobby's own on the drive the library is on, outside every library folder. Originals of converted files are kept here. None: nothing is converted.",
    type: "folder",
    apply: "restart",
    default: null,
    nullable: true,
    check: (value) => (value === null ? null : folderPath(value)),
  },
  {
    key: "conversion.hours",
    section: "converting",
    title: "Hours",
    help: "When the server itself converts, such as 01:00-07:00. Empty: any hour. It also waits until nobody is watching.",
    type: "hours",
    apply: "live",
    default: null,
    nullable: true,
    check: (value) => {
      if (value === null) return null;
      if (typeof value !== "string" || !HOURS.test(value)) {
        throw new Error(`must look like 01:00-07:00, or be empty for any hour.`);
      }
      return value;
    },
  },
  {
    key: "conversion.server",
    section: "converting",
    title: "The server converts",
    help: "Off: only Macs take converting jobs, and the server stays quiet.",
    type: "toggle",
    apply: "live",
    default: true,
    check: toggle,
  },
  {
    key: "conversion.repackage",
    section: "converting",
    title: "Repackage MKV files",
    help: "Also turn MKV files with a good picture into MP4, which plays everywhere without work.",
    type: "toggle",
    apply: "live",
    default: false,
    check: toggle,
  },
  {
    key: "conversion.minFreeGb",
    section: "converting",
    title: "Keep free on the drive (GB)",
    help: "Converting waits when the drive has less than this free.",
    type: "number",
    apply: "live",
    default: 5,
    min: 1,
    max: 10_000,
    check: amount(1, 10_000),
  },
  {
    key: "addresses.remote",
    section: "away",
    title: "Addresses away from home",
    help: "Where devices reach the server when they are not home, such as its Tailscale name. Listing one opens nothing.",
    type: "addresses",
    apply: "live",
    default: [],
    check: addresses,
  },
  {
    key: "outside.direct.maxUploadMbit",
    section: "away",
    title: "Upload limit (Mbit/s)",
    help: "Everything the direct connection sends together stays under this, so the home's internet stays usable. Empty: no limit.",
    type: "number",
    apply: "restart",
    default: null,
    nullable: true,
    min: 1,
    max: 10_000,
    check: (value) => (value === null ? null : amount(1, 10_000)(value)),
  },
  {
    key: "remote.wake.enabled",
    section: "general",
    title: "Wake Apple TVs",
    help: "Play On turns a connected Apple TV on and opens Lobby on it. The TVs are connected under Apple TVs.",
    type: "toggle",
    apply: "live",
    default: true,
    check: toggle,
  },
  {
    key: "remote.wake.kids",
    section: "general",
    title: "Kids can turn on the TV",
    help: "Off: in kids mode, Play On shows only TVs that are on with Lobby open. On: it may also wake a connected Apple TV.",
    type: "toggle",
    apply: "live",
    default: false,
    check: toggle,
  },
  {
    key: "remote.wake.pickProfile",
    section: "general",
    title: "Get past “Who is watching?”",
    help: "When the Apple TV asks who is watching after it wakes, Lobby Server presses select once, which picks whichever profile is focused (normally the last one used), and opens Lobby again. Off: someone picks a profile on the TV.",
    type: "toggle",
    apply: "live",
    default: true,
    check: toggle,
  },
  {
    key: "backup.everyHours",
    section: "backups",
    title: "Back up every (hours)",
    help: "How often the catalogue, watch history and devices are backed up. 0: never by itself.",
    type: "integer",
    apply: "live",
    default: 24,
    min: 0,
    max: 24 * 30,
    check: whole(0, 24 * 30),
  },
  {
    key: "backup.keep",
    section: "backups",
    title: "Backups to keep",
    help: "Older backups are deleted.",
    type: "integer",
    apply: "live",
    default: 7,
    min: 1,
    max: 365,
    check: whole(1, 365),
  },
  {
    key: "statistics.keepDays",
    section: "general",
    title: "Keep viewing history (days)",
    help: "How long what everyone watched and listened to is kept, for history and statistics. Older is deleted. Each viewer's place in a title stays.",
    type: "integer",
    apply: "live",
    default: 730,
    min: 30,
    max: 3650,
    check: whole(30, 3650),
  },
  {
    key: "stabilityMs",
    section: "advanced",
    title: "Wait for copies (ms)",
    help: "A new file is only read once its size has not changed for this long, so a copy is not read halfway.",
    type: "integer",
    apply: "restart",
    default: 30_000,
    min: 1_000,
    max: 3_600_000,
    check: whole(1_000, 3_600_000),
  },
  {
    key: "probeConcurrency",
    section: "advanced",
    title: "Files read at once",
    help: "More reads a new library faster and leaves less for playing.",
    type: "integer",
    apply: "restart",
    default: 2,
    min: 1,
    max: 8,
    check: whole(1, 8),
  },
  {
    key: "playback.maxCacheGb",
    section: "advanced",
    title: "Space for prepared copies (GB)",
    help: "Copies made for playing; the oldest go when they need more. They can always be made again.",
    type: "number",
    apply: "restart",
    default: 20,
    min: 1,
    max: 10_000,
    check: amount(1, 10_000),
  },
  {
    key: "playback.maxConcurrent",
    section: "advanced",
    title: "Copies prepared at once",
    help: "More lets more people start at once, and makes the server busier.",
    type: "integer",
    apply: "restart",
    default: 2,
    min: 1,
    max: 4,
    check: whole(1, 4),
  },
  {
    key: "music.maxCacheGb",
    section: "advanced",
    title: "Space for music copies (GB)",
    help: "Compact copies of songs; the ones used longest ago go first.",
    type: "number",
    apply: "restart",
    default: 5,
    min: 0.1,
    max: 10_000,
    check: amount(0.1, 10_000),
  },
];

export const DEFINITIONS: ReadonlyMap<string, SettingDefinition> = new Map(
  SETTINGS.map((one) => [one.key, one]),
);
