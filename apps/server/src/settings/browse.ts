// SPDX-License-Identifier: MPL-2.0
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { opendir, readdir, realpath, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve, sep } from "node:path";
import { isIgnoredName, isVideoFile } from "../library/parse.ts";
import { isAudioFile } from "../music/names.ts";

/**
 * Looking through the server's folders, to pick a library folder or Lobby's own folder.
 *
 * Only below the mounted drives and the home folder of the user the server runs as, read only,
 * without hidden files, and never through a link to elsewhere. Nothing is opened but folders.
 */

/** Mount points that are the system itself, not a drive of the household's. */
const SYSTEM = new Set([
  "/",
  "/boot",
  "/boot/efi",
  "/boot/firmware",
  "/efi",
  "/usr",
  "/var",
  "/etc",
  "/opt",
  "/tmp",
  "/root",
  "/snap",
]);
// "/etc/": in a container, the files Docker puts there (hosts, resolv.conf) are mounts too.
const SYSTEM_BELOW = [
  "/proc",
  "/sys",
  "/dev",
  "/run",
  "/var/",
  "/usr/",
  "/snap/",
  "/boot/",
  "/etc/",
];
/** Folders a drive carries for its system, never media. */
const HIDDEN = new Set(["lost+found", "$RECYCLE.BIN", "System Volume Information", "@eaDir"]);

/** `\040` in /proc/mounts is a space. */
const unescape = (field: string): string =>
  field.replace(/\\([0-7]{3})/g, (_m, code: string) => String.fromCharCode(parseInt(code, 8)));

/** The mount points of drives, from `/proc/mounts` on Linux and `/Volumes` on a Mac. */
export function mountedDrives(): string[] {
  if (process.platform === "linux" && existsSync("/proc/mounts")) {
    const found: string[] = [];
    for (const line of readFileSync("/proc/mounts", "utf8").split("\n")) {
      const [device = "", point = ""] = line.split(" ");
      const path = unescape(point);
      // A drive is a device; tmpfs, proc, cgroups and the like are not.
      if (!device.startsWith("/dev/") || !isAbsolute(path)) continue;
      if (SYSTEM.has(path) || SYSTEM_BELOW.some((below) => path.startsWith(below))) {
        // But a drive mounted for a user, such as /run/media/<user>/<drive>, is one.
        if (!path.startsWith("/run/media/")) continue;
      }
      if (!found.includes(path)) found.push(path);
    }
    return found;
  }
  if (process.platform === "darwin" && existsSync("/Volumes")) {
    return readdirSync("/Volumes", { withFileTypes: true })
      .filter((entry) => entry.isDirectory() && !entry.name.startsWith("."))
      .map((entry) => join("/Volumes", entry.name));
  }
  return [];
}

/** Where looking is allowed: the drives and the home folder. */
export function defaultBases(): string[] {
  return [...new Set([...mountedDrives(), homedir()])];
}

export interface FolderEntry {
  name: string;
  path: string;
  /** Video files in it and below it, counted up to a limit. */
  videoFiles: number;
  audioFiles: number;
  /** The count stopped at its limit: there are more. */
  more: boolean;
}

export interface FolderListing {
  /** Null for the list of places to start from. */
  path: string | null;
  /** Null at a place to start from, and above it. */
  parent: string | null;
  folders: FolderEntry[];
  /** Video files right in this folder. */
  videoFiles: number;
  /** There were more folders than are listed. */
  truncated: boolean;
}

export class BrowseError extends Error {
  readonly code: "forbidden" | "not_found" | "invalid_request";
  constructor(code: BrowseError["code"], message: string) {
    super(message);
    this.code = code;
  }
}

const NOT_ALLOWED =
  "Only folders on the server's drives and in its home folder can be looked through.";
const MAX_FOLDERS = 500;
/** Entries looked at to count one folder's files; a whole library folder would take too long. */
const COUNT_BUDGET = 4000;
const COUNT_DEPTH = 6;

const within = (path: string, base: string): boolean =>
  path === base || path.startsWith(base.endsWith(sep) ? base : `${base}${sep}`);

export class FolderBrowser {
  private readonly bases: () => string[];

  constructor(bases: () => string[] = defaultBases) {
    this.bases = bases;
  }

  /** The places to start from, as they really are (links resolved), that exist. */
  private async realBases(): Promise<string[]> {
    const found: string[] = [];
    for (const base of this.bases()) {
      try {
        const real = await realpath(base);
        // A link to the system disk's root (a Mac's "Macintosh HD") is no drive.
        if (real === "/" || found.includes(real)) continue;
        if ((await stat(real)).isDirectory()) found.push(real);
      } catch {
        // A drive that is not there now.
      }
    }
    return found;
  }

  /**
   * The folder as it really is, when it lies in an allowed place.
   *
   * @param mayBeMissing for a folder the server will make: then its parent must be allowed
   * @throws BrowseError
   */
  async allowed(path: string, mayBeMissing = false): Promise<string> {
    if (typeof path !== "string" || path === "" || path.length > 4096 || path.includes("\0")) {
      throw new BrowseError("invalid_request", `"path" must be the absolute path of a folder.`);
    }
    if (!isAbsolute(path)) {
      throw new BrowseError("invalid_request", `"path" must be the absolute path of a folder.`);
    }
    const asked = resolve(path);
    const bases = await this.realBases();
    // Looked at before anything on the disk is touched, so outside nothing is even checked.
    const lexical = [...new Set([...bases, ...this.bases().map((one) => resolve(one))])];
    const base = lexical.filter((one) => within(asked, one)).sort((a, b) => b.length - a.length)[0];
    if (base === undefined) throw new BrowseError("forbidden", NOT_ALLOWED);
    // Hidden folders are not shown, so they cannot be asked for either.
    if (
      asked
        .slice(base.length)
        .split(sep)
        .some((part) => part.startsWith(".") || HIDDEN.has(part))
    ) {
      throw new BrowseError("forbidden", NOT_ALLOWED);
    }
    let real: string;
    try {
      real = await realpath(asked);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        throw new BrowseError("not_found", "That folder cannot be read.");
      }
      if (!mayBeMissing) throw new BrowseError("not_found", "There is no such folder.");
      const parent = await this.allowed(dirname(asked));
      return join(parent, basename(asked));
    }
    // A link that leads out of the allowed places is as if it were not there.
    if (!bases.some((base) => within(real, base))) throw new BrowseError("forbidden", NOT_ALLOWED);
    let info;
    try {
      info = await stat(real);
    } catch {
      throw new BrowseError("not_found", "That folder cannot be read.");
    }
    if (!info.isDirectory()) throw new BrowseError("invalid_request", "That is not a folder.");
    return real;
  }

  async list(path: string | undefined): Promise<FolderListing> {
    const bases = await this.realBases();
    if (path === undefined || path === "") {
      const folders = await Promise.all(bases.map((base) => this.entry(base, base)));
      return { path: null, parent: null, folders, videoFiles: 0, truncated: false };
    }
    const real = await this.allowed(path);
    let names: { name: string; isDirectory: boolean; isFile: boolean; isLink: boolean }[];
    try {
      names = (await readdir(real, { withFileTypes: true })).map((entry) => ({
        name: entry.name,
        isDirectory: entry.isDirectory(),
        isFile: entry.isFile(),
        isLink: entry.isSymbolicLink(),
      }));
    } catch {
      throw new BrowseError("not_found", "That folder cannot be read.");
    }
    const visible = names.filter((one) => !one.name.startsWith(".") && !HIDDEN.has(one.name));
    const folders: FolderEntry[] = [];
    let truncated = false;
    for (const one of visible.sort((a, b) => a.name.localeCompare(b.name))) {
      if (!one.isDirectory && !one.isLink) continue;
      const child = join(real, one.name);
      let target = child;
      if (one.isLink) {
        try {
          target = await realpath(child);
          if (!bases.some((base) => within(target, base))) continue;
          if (!(await stat(target)).isDirectory()) continue;
        } catch {
          continue;
        }
      }
      if (folders.length >= MAX_FOLDERS) {
        truncated = true;
        break;
      }
      folders.push(await this.entry(target, one.name));
    }
    const parent = dirname(real);
    return {
      path: real,
      parent: real !== parent && bases.some((base) => within(parent, base)) ? parent : null,
      folders,
      videoFiles: visible.filter((one) => one.isFile && isVideoFile(one.name)).length,
      truncated,
    };
  }

  private async entry(path: string, name: string): Promise<FolderEntry> {
    const counted = await countFiles(path);
    return { name: name === path ? basename(path) || path : name, path, ...counted };
  }
}

/** Video and audio files in a folder and below it, without following links. */
async function countFiles(
  path: string,
): Promise<{ videoFiles: number; audioFiles: number; more: boolean }> {
  let videoFiles = 0;
  let audioFiles = 0;
  let budget = COUNT_BUDGET;
  const queue: { path: string; depth: number }[] = [{ path, depth: 0 }];
  while (queue.length > 0) {
    const next = queue.shift();
    if (!next) break;
    let dir;
    try {
      dir = await opendir(next.path);
    } catch {
      continue;
    }
    for await (const entry of dir) {
      budget -= 1;
      // Leaving the loop closes the folder.
      if (budget < 0) return { videoFiles, audioFiles, more: true };
      if (isIgnoredName(entry.name) || HIDDEN.has(entry.name)) continue;
      if (entry.isFile()) {
        if (isVideoFile(entry.name)) videoFiles += 1;
        else if (isAudioFile(entry.name)) audioFiles += 1;
      } else if (entry.isDirectory() && next.depth < COUNT_DEPTH) {
        queue.push({ path: join(next.path, entry.name), depth: next.depth + 1 });
      }
    }
  }
  return { videoFiles, audioFiles, more: false };
}
