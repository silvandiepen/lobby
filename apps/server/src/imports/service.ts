// SPDX-License-Identifier: MPL-2.0
import { createHash, randomUUID } from "node:crypto";
import { createReadStream, createWriteStream, watch, type FSWatcher } from "node:fs";
import { mkdir, opendir, readdir, rm, rmdir, stat } from "node:fs/promises";
import { basename, dirname, join, relative, sep } from "node:path";
import { pipeline } from "node:stream/promises";
import type { RootConfig } from "../config.ts";
import { DOWNLOAD_FOLDER, openElsewhereOnLinux } from "../conversion/service.ts";
import {
  Inconsistent,
  Journal,
  moveWithoutReplacing,
  syncDir,
  syncFile,
  type FaultPoint,
  type Operation,
} from "../conversion/moves.ts";
import type { Database } from "../db/database.ts";
import { extensionOf, parseMediaPath, type SourceHint } from "../library/parse.ts";
import { probeFile } from "../library/probe.ts";
import { errorMessage, log } from "../log.ts";
import { episodeTarget, filmTarget, subtitleTarget } from "./naming.ts";
import {
  DEFAULT_LIMITS,
  judgeFiles,
  nameOf,
  unfinishedByName,
  type RuleLimits,
  type SeenFile,
  type Verdict,
} from "./rules.ts";

export type ImportMode = "move" | "index";

/** One import folder as a manager set it up (`import.folders`). */
export interface ImportFolder {
  path: string;
  mode: ImportMode;
  /** Shown in the app; the folder's own name when there is none. */
  name?: string | null;
}

export type ItemState =
  "waiting" | "inbox" | "moving" | "imported" | "listed" | "ignored" | "failed" | "dismissed";

/** What TMDB says a file is: a title it accepts, or candidates for a manager to choose from. */
export interface Identified {
  accepted: { title: string; year: number | null; tmdbId: number } | null;
  reason: string;
  candidates: { title: string; year: number | null; tmdbId: number }[];
}

export interface Wanted {
  type: "movie" | "tv";
  title: string;
  year: number | null;
  runtimeMinutes: number | null;
  season: number | null;
  episode: number | null;
  episodeTitle: string | null;
}

/** Answers null when there is no TMDB key. Throws when TMDB cannot be reached. */
export type Matcher = (wanted: Wanted) => Promise<Identified | null>;

export interface ImportOptions {
  db: Database;
  folders: ImportFolder[];
  /** The video library's folders; imports go into these only. */
  roots: () => RootConfig[];
  /** Lobby's folder on the media drive (`conversion.dir`): the journal and the uploads. */
  lobbyDir: string | null;
  /** Whether Lobby's folder is there, with its marker (the conversion service knows). */
  driveConnected: () => Promise<boolean>;
  /** A file must keep its size and date this long before it is touched. */
  waitMs: number;
  /** Whether a file on another drive than its library folder is copied, proven and removed. */
  copyAcrossDrives: boolean;
  matcher: Matcher | null;
  ffprobePath?: string;
  limits?: Partial<RuleLimits>;
  now?: () => number;
  volumeOf?: (path: string) => Promise<number>;
  isOpenElsewhere?: (path: string) => Promise<boolean>;
  /** Called after a file arrived in the library or became listed, so the library is read again. */
  onLibraryChanged?: () => void | Promise<void>;
  /** Called after an item changed, for the live channel. */
  onChange?: (item: ApiImportItem) => void;
  /** How often the folders are looked at besides when they change. Default a minute. */
  intervalMs?: number;
  /** Stops a move at a chosen step: for tests of what a crash leaves. */
  fault?: (point: FaultPoint, operation: Operation<MoveData>) => void;
}

export interface MoveData {
  itemId: string;
  targetPath: string;
  removeAfter: { path: string; size: number }[];
}

interface ItemRow {
  id: string;
  origin: "folder" | "upload";
  folder_path: string | null;
  path: string;
  rel_path: string;
  size: number;
  mtime_ms: number;
  state: ItemState;
  reason: string | null;
  kind: "movie" | "episode" | null;
  title: string | null;
  year: number | null;
  season: number | null;
  episode: number | null;
  episode_end: number | null;
  episode_title: string | null;
  tmdb_id: number | null;
  candidates_json: string;
  destination: string | null;
  target_path: string | null;
  subtitles_json: string;
  leftovers_json: string;
  remove_after_json: string;
  upload_id: string | null;
  decided_by: string | null;
  first_seen_at: number;
  stable_since: number;
  updated_at: number;
  done_at: number | null;
}

export interface Leftovers {
  /** The folder below the import folder the film came in. */
  dir: string;
  /** What is left in it that may go: everything there is. */
  files: string[];
}

export interface ApiImportItem {
  id: string;
  origin: "folder" | "upload";
  folder: string | null;
  name: string;
  relPath: string;
  sizeBytes: number;
  state: ItemState;
  reason: string | null;
  kind: "movie" | "episode" | null;
  title: string | null;
  year: number | null;
  season: number | null;
  episode: number | null;
  episodeTitle: string | null;
  tmdbId: number | null;
  candidates: Identified["candidates"];
  destination: string | null;
  targetPath: string | null;
  subtitles: string[];
  leftovers: Leftovers | null;
  uploadId: string | null;
  /** Its format is one Apple devices do not play as it is: it can be offered for converting. */
  convertible: boolean;
  /** What a manager can do with it now. */
  actions: ("move" | "list" | "dismiss" | "cleanUp" | "convert")[];
  firstSeenAt: number;
  updatedAt: number;
  doneAt: number | null;
}

export interface FolderStatus {
  path: string;
  name: string;
  mode: ImportMode;
  /** Its name says a download program may use it: moved only when a manager chooses to. */
  looksLikeDownloads: boolean;
  connected: boolean;
  counts: Record<ItemState, number>;
  lastLookAt: number | null;
  problem: string | null;
}

export interface Decision {
  action: "move" | "list";
  kind?: "movie" | "episode";
  title?: string;
  year?: number | null;
  season?: number | null;
  episode?: number | null;
  episodeTitle?: string | null;
  /** A library folder; null: the films' or series' folder. */
  destination?: string | null;
}

/** A refusal the routes turn into a status, with a sentence that can be shown. */
export class ImportError extends Error {
  readonly code: "invalid_request" | "not_found" | "conflict" | "unavailable";

  constructor(code: ImportError["code"], message: string) {
    super(message);
    this.code = code;
  }
}

const STATES: ItemState[] = [
  "waiting",
  "inbox",
  "moving",
  "imported",
  "listed",
  "ignored",
  "failed",
  "dismissed",
];
/** Formats Apple devices do not play as they are. */
const OLD_FORMATS = new Set(["avi", "wmv", "mpg", "mpeg", "divx", "flv", "3gp", "ogv", "vob"]);
const MAX_DEPTH = 10;
const MAX_FILES = 50_000;
const WATCH_DEBOUNCE_MS = 5_000;
const COPY_SUFFIX = ".lobby-copy";

export function looksLikeDownloads(path: string): boolean {
  return path.split("/").some((segment) => DOWNLOAD_FOLDER.test(segment));
}

export function folderName(folder: ImportFolder): string {
  return folder.name?.trim() || basename(folder.path) || folder.path;
}

function parseJson<T>(text: string, fallback: T): T {
  try {
    return JSON.parse(text) as T;
  } catch {
    return fallback;
  }
}

async function exists(path: string): Promise<boolean> {
  try {
    await stat(path);
    return true;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw error;
  }
}

/** Whether `path` is `root` or below it. */
function within(root: string, path: string): boolean {
  const rel = relative(root, path);
  return rel === "" || (!rel.startsWith("..") && !rel.startsWith(sep) && rel !== "..");
}

async function sha256Of(path: string): Promise<string> {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(path)) hash.update(chunk as Buffer);
  return hash.digest("hex");
}

/**
 * Import folders and uploads (docs/imports.md): finds finished files in the folders a manager
 * chose, works out what each is, and puts it in the library under a neat name, or lists it where
 * it is, or leaves it in the Inbox for a manager. Every move is journalled, on one drive, and
 * never replaces anything.
 */
export class ImportService {
  private readonly db: Database;
  private readonly options: ImportOptions;
  private readonly now: () => number;
  private readonly limits: RuleLimits;
  private readonly journal: Journal<MoveData> | null;
  private folders: ImportFolder[];
  private lane: Promise<unknown> = Promise.resolve();
  private watchers: FSWatcher[] = [];
  private timer: NodeJS.Timeout | null = null;
  private debounce: NodeJS.Timeout | null = null;
  private stopped = true;
  private readonly lastLook = new Map<string, number>();
  private readonly problems = new Map<string, string>();

  constructor(options: ImportOptions) {
    this.db = options.db;
    this.options = options;
    this.now = options.now ?? Date.now;
    this.limits = { ...DEFAULT_LIMITS, ...options.limits };
    this.folders = options.folders;
    this.journal = options.lobbyDir
      ? new Journal<MoveData>(join(options.lobbyDir, "imports", "journal"), {
          commit: (operation) => {
            this.committed(operation.data);
          },
          abandon: (operation, reason) => {
            this.toInbox(this.row(operation.data.itemId), reason);
          },
          ...(options.fault ? { fault: options.fault } : {}),
        })
      : null;
  }

  /** How titles are checked on TMDB; set once the enricher exists. */
  setMatcher(matcher: Matcher | null): void {
    this.options.matcher = matcher;
  }

  /** Lobby's folder, for the uploads. */
  get lobbyDir(): string | null {
    return this.options.lobbyDir;
  }

  driveConnected(): Promise<boolean> {
    return this.options.lobbyDir ? this.options.driveConnected() : Promise.resolve(false);
  }

  /** Takes changed settings while it runs. */
  configure(change: {
    folders?: ImportFolder[];
    waitMs?: number;
    copyAcrossDrives?: boolean;
  }): void {
    if (change.folders) this.folders = change.folders;
    if (change.waitMs !== undefined) this.options.waitMs = change.waitMs;
    if (change.copyAcrossDrives !== undefined) {
      this.options.copyAcrossDrives = change.copyAcrossDrives;
    }
    if (change.folders && !this.stopped) {
      this.watch();
      this.schedule(0);
    }
  }

  /** The index folders, as library folders for the scanner. */
  indexSources(): RootConfig[] {
    return this.folders
      .filter((folder) => folder.mode === "index")
      .map((folder) => ({
        path: folder.path,
        name: folderName(folder),
        hint: "mixed",
      }));
  }

  /** Whether the scanner may list this file of an index folder. */
  isListed(folderPath: string, relPath: string): boolean {
    if (relPath.split("/").length > 1 && this.isSubtitleOfListed(folderPath, relPath)) return true;
    return (
      this.db.get<{ one: number }>(
        "select 1 as one from import_item where folder_path = ? and rel_path = ? and state = 'listed'",
        [folderPath, relPath],
      ) !== undefined
    );
  }

  private isSubtitleOfListed(folderPath: string, relPath: string): boolean {
    const path = join(folderPath, relPath);
    return this.db
      .all<{ subtitles_json: string }>(
        "select subtitles_json from import_item where folder_path = ? and state = 'listed'",
        [folderPath],
      )
      .some((row) => parseJson<string[]>(row.subtitles_json, []).includes(path));
  }

  // ---- Running ----

  /** Finishes or takes back moves an earlier run left halfway, then starts looking. */
  async start(): Promise<void> {
    this.stopped = false;
    await this.serial(() => this.recover());
    this.watch();
    this.timer = setInterval(() => {
      this.schedule(0);
    }, this.options.intervalMs ?? 60_000);
    this.timer.unref();
    this.schedule(0);
  }

  async stop(): Promise<void> {
    this.stopped = true;
    if (this.timer) clearInterval(this.timer);
    if (this.debounce) clearTimeout(this.debounce);
    this.timer = null;
    this.debounce = null;
    for (const watcher of this.watchers.splice(0)) watcher.close();
    await this.lane.catch(() => undefined);
  }

  private watch(): void {
    for (const watcher of this.watchers.splice(0)) watcher.close();
    for (const folder of this.folders) {
      try {
        const watcher = watch(folder.path, { recursive: true }, () => {
          this.schedule(WATCH_DEBOUNCE_MS);
        });
        watcher.on("error", () => {
          // The timed look still covers it.
        });
        this.watchers.push(watcher);
      } catch {
        // Not there now (a drive that is out): the timed look finds it when it is back.
      }
    }
  }

  private schedule(delayMs: number): void {
    if (this.stopped) return;
    if (this.debounce) clearTimeout(this.debounce);
    this.debounce = setTimeout(() => {
      this.debounce = null;
      void this.scanNow().catch((error: unknown) => {
        log.error("Looking through the import folders failed", { error: errorMessage(error) });
      });
    }, delayMs);
    this.debounce.unref();
  }

  /** One thing at a time: a look, a move, a manager's choice. */
  private serial<T>(work: () => Promise<T>): Promise<T> {
    const next = this.lane.then(work, work);
    this.lane = next.catch(() => undefined);
    return next;
  }

  /** Looks through every import folder now. */
  scanNow(): Promise<void> {
    return this.serial(async () => {
      let changed = false;
      for (const folder of this.folders) {
        try {
          changed = (await this.scanFolder(folder)) || changed;
          this.problems.delete(folder.path);
        } catch (error) {
          this.problems.set(folder.path, "The folder could not be read.");
          log.warn("Could not look through an import folder", { error: errorMessage(error) });
        }
      }
      if (changed) await this.libraryChanged();
    });
  }

  private async libraryChanged(): Promise<void> {
    try {
      await this.options.onLibraryChanged?.();
    } catch (error) {
      log.error("Reading the library after an import failed", { error: errorMessage(error) });
    }
  }

  private volumeOf(path: string): Promise<number> {
    return this.options.volumeOf
      ? this.options.volumeOf(path)
      : stat(path).then((info) => info.dev);
  }

  // ---- Looking through a folder ----

  private async walk(root: string): Promise<SeenFile[]> {
    const found: SeenFile[] = [];
    const pending: { rel: string; depth: number }[] = [{ rel: "", depth: 0 }];
    const lobby = this.options.lobbyDir;
    while (pending.length > 0 && found.length < MAX_FILES) {
      const { rel: relDir, depth } = pending.pop() ?? { rel: "", depth: 0 };
      const directory = await opendir(join(root, relDir));
      for await (const entry of directory) {
        const rel = relDir ? `${relDir}/${entry.name}` : entry.name;
        // Symbolic links are not followed: one could point anywhere.
        if (entry.isDirectory()) {
          if (entry.name.startsWith(".") || depth >= MAX_DEPTH) continue;
          if (lobby && within(lobby, join(root, rel))) continue;
          pending.push({ rel, depth: depth + 1 });
        } else if (entry.isFile()) {
          try {
            const info = await stat(join(root, rel));
            found.push({ rel, size: info.size, mtimeMs: Math.round(info.mtimeMs) });
          } catch {
            // Gone while we looked.
          }
        }
      }
    }
    return found;
  }

  private episodeLike(rel: string): boolean {
    const parsed = parseMediaPath(rel, "mixed");
    return parsed.kind === "episode" && parsed.episode !== null;
  }

  /** @returns whether what the library lists changed */
  private async scanFolder(folder: ImportFolder): Promise<boolean> {
    if (!(await exists(folder.path))) {
      this.problems.set(folder.path, "The folder is not there. Is its drive connected?");
      return false;
    }
    const files = await this.walk(folder.path);
    this.lastLook.set(folder.path, this.now());
    const verdicts = judgeFiles(files, (rel) => this.episodeLike(rel), this.limits);
    const byRel = new Map(files.map((file) => [file.rel, file]));
    const known = new Map(
      this.db
        .all<ItemRow>("select * from import_item where folder_path = ? and state <> 'imported'", [
          folder.path,
        ])
        .map((row) => [row.rel_path, row]),
    );
    let changed = false;
    const now = this.now();

    for (const [rel, verdict] of verdicts) {
      if (verdict.status === "skip") continue;
      const file = byRel.get(rel);
      if (!file) continue;
      // A control file of a video is said on the video; it needs no line of its own.
      if (
        verdict.status === "unfinished" &&
        !/\.(?:mkv|mp4|m4v|avi|mov|wmv|mpg|mpeg|ts|m2ts|webm)\b/i.test(rel)
      ) {
        continue;
      }
      let row = known.get(rel) ?? null;
      known.delete(rel);
      const fresh = row === null || row.size !== file.size || row.mtime_ms !== file.mtimeMs;
      if (row && fresh) {
        if (row.state === "listed") changed = true;
        this.update(row.id, {
          size: file.size,
          mtime_ms: file.mtimeMs,
          stable_since: now,
          state: "waiting",
          reason: null,
        });
        row = this.row(row.id);
      }
      if (!row) {
        row = this.insert(folder, file, now);
      }
      changed = (await this.consider(folder, row, verdict)) || changed;
    }

    // What is no longer there.
    for (const [, row] of known) {
      if (row.state === "moving") continue;
      if (byRel.has(row.rel_path)) continue;
      if (row.state === "listed") changed = true;
      if (row.state === "inbox" || row.state === "listed") {
        this.activity(
          "gone",
          row.id,
          null,
          `“${nameOf(row.rel_path)}” is no longer in the folder.`,
        );
      }
      this.db.run("delete from import_item where id = ?", [row.id]);
    }
    return changed;
  }

  private insert(folder: ImportFolder, file: SeenFile, now: number): ItemRow {
    const id = randomUUID();
    this.db.run(
      `insert into import_item (id, origin, folder_path, path, rel_path, size, mtime_ms, state,
         first_seen_at, stable_since, updated_at)
       values (?, 'folder', ?, ?, ?, ?, ?, 'waiting', ?, ?, ?)`,
      [
        id,
        folder.path,
        join(folder.path, file.rel),
        file.rel,
        file.size,
        file.mtimeMs,
        now,
        now,
        now,
      ],
    );
    return this.row(id);
  }

  /** What to do with one file whose verdict is known. @returns whether the library changed */
  private async consider(folder: ImportFolder, row: ItemRow, verdict: Verdict): Promise<boolean> {
    if (verdict.status === "unfinished") {
      if (row.state !== "waiting" || row.reason !== verdict.reason) {
        this.update(row.id, { state: "waiting", reason: verdict.reason });
      }
      return false;
    }
    if (verdict.status === "excluded") {
      if (row.state === "dismissed" || row.state === "failed") return false;
      const wasListed = row.state === "listed";
      if (row.state !== "ignored" || row.reason !== verdict.reason) {
        // A manager may still choose to import it, from the ignored view.
        if (row.state !== "inbox" || row.decided_by === null) {
          this.update(row.id, {
            ...parsedFields(row.rel_path, "mixed", null),
            state: "ignored",
            reason: verdict.reason,
          });
          if (row.state !== "ignored") this.activity("ignored", row.id, null, verdict.reason);
        }
      }
      return wasListed;
    }
    if (verdict.status !== "candidate") return false;
    const subtitles = verdict.subtitles.map((rel) => join(folder.path, rel));
    if (JSON.stringify(subtitles) !== row.subtitles_json) {
      this.update(row.id, { subtitles_json: JSON.stringify(subtitles) });
    }
    if (row.state !== "waiting") return false;
    if (this.now() - row.stable_since < this.options.waitMs) {
      if (row.reason !== WAITING_FOR_QUIET) this.update(row.id, { reason: WAITING_FOR_QUIET });
      return false;
    }
    if (await (this.options.isOpenElsewhere ?? openElsewhereOnLinux)(row.path)) {
      this.update(row.id, { reason: "Another program has it open." });
      return false;
    }
    if (folder.mode === "index") {
      this.update(row.id, { state: "listed", reason: null });
      this.activity("listed", row.id, null, `“${nameOf(row.rel_path)}” is listed where it is.`);
      return true;
    }
    return this.decide(this.row(row.id), "mixed", null);
  }

  // ---- Working out what a file is ----

  /**
   * Proposes a title for a stable file and moves it when the proposal is strong; otherwise it
   * waits in the Inbox with what is known. @returns whether the library changed
   */
  private async decide(
    row: ItemRow,
    hint: SourceHint,
    destination: string | null,
  ): Promise<boolean> {
    const parsed = parseMediaPath(row.rel_path, hint);
    const fields = parsedFields(row.rel_path, hint, destination);
    this.update(row.id, fields);
    if (fields.kind === null || !parsed.title) {
      this.toInbox(this.row(row.id), "Lobby cannot tell from its name what this is.");
      return false;
    }
    const noKey = (): boolean => {
      this.toInbox(
        this.row(row.id),
        "Without a TMDB key Lobby cannot check what this is. Confirm the title.",
      );
      return false;
    };
    if (!this.options.matcher) return noKey();
    let identified: Identified | null;
    try {
      const runtime = await probeFile(row.path, this.options.ffprobePath ?? "ffprobe")
        .then((probe) => (probe.durationMs === null ? null : Math.round(probe.durationMs / 60_000)))
        .catch(() => null);
      identified = await this.options.matcher({
        type: fields.kind === "movie" ? "movie" : "tv",
        title: parsed.title,
        year: parsed.year,
        runtimeMinutes: runtime,
        season: parsed.season,
        episode: parsed.episode,
        episodeTitle: parsed.episodeTitle,
      });
    } catch {
      // Not the file's fault: it is looked at again on the next round.
      this.update(row.id, {
        state: "waiting",
        reason: "TMDB could not be reached. Lobby tries again.",
      });
      return false;
    }
    if (identified === null) return noKey();
    if (!identified.accepted) {
      this.update(row.id, { candidates_json: JSON.stringify(identified.candidates.slice(0, 8)) });
      this.toInbox(this.row(row.id), identified.reason);
      return false;
    }
    this.update(row.id, {
      title: identified.accepted.title,
      year: fields.kind === "movie" ? identified.accepted.year : (fields.year ?? null),
      tmdb_id: identified.accepted.tmdbId,
      candidates_json: "[]",
    });
    return this.move(this.row(row.id), null);
  }

  private toInbox(row: ItemRow, reason: string): void {
    this.update(row.id, { state: "inbox", reason });
    this.activity("inbox", row.id, null, reason);
  }

  // ---- Moving into the library ----

  private rootFor(kind: "movie" | "episode", destination: string | null): RootConfig | string {
    const roots = this.options.roots();
    if (destination !== null) {
      const chosen = roots.find((root) => root.path === destination);
      if (!chosen) return "That library folder is not in the library any more.";
      return chosen;
    }
    const wanted: SourceHint[] = kind === "movie" ? ["movies", "mixed"] : ["series", "mixed"];
    for (const hint of wanted) {
      const root = roots.find((one) => one.hint === hint);
      if (root) return root;
    }
    return kind === "movie"
      ? "There is no films folder in the library to put it in."
      : "There is no series folder in the library to put it in.";
  }

  /**
   * Moves a file whose title is known into the library.
   *
   * @param by the manager who chose it; null when Lobby did by itself
   * @returns whether the library changed
   */
  private async move(row: ItemRow, by: string | null): Promise<boolean> {
    if (!this.journal || !this.options.lobbyDir) {
      this.toInbox(row, "Moving needs Lobby's folder, set under Converting.");
      return false;
    }
    if (!(await this.options.driveConnected())) {
      this.toInbox(row, "The drive with Lobby's folder is not connected.");
      return false;
    }
    if (row.kind === null || !row.title) {
      this.toInbox(row, "Lobby cannot tell from its name what this is.");
      return false;
    }
    const root = this.rootFor(row.kind, row.destination);
    if (typeof root === "string") {
      this.toInbox(row, root);
      return false;
    }
    if (!(await exists(root.path))) {
      this.toInbox(row, "The library folder is not there. Is its drive connected?");
      return false;
    }
    const extension = extensionOf(row.rel_path);
    const parsed = parseMediaPath(row.rel_path, "mixed");
    const rel =
      row.kind === "movie"
        ? filmTarget(
            { title: row.title, year: row.year, edition: parsed.edition, part: parsed.part },
            extension,
          )
        : episodeTarget(
            {
              show: row.title,
              season: row.season ?? 1,
              episode: row.episode ?? 1,
              episodeEnd: row.episode_end,
              episodeTitle: row.episode_title,
            },
            extension,
          );
    const target = join(root.path, rel);
    if (!within(root.path, target)) {
      this.toInbox(row, "That name would put it outside the library folder.");
      return false;
    }
    if (await exists(target)) {
      this.toInbox(row, `There is already a file named “${nameOf(rel)}” in ${root.name}.`);
      return false;
    }

    let info;
    try {
      info = await stat(row.path);
    } catch {
      this.update(row.id, { state: "failed", reason: "The file is no longer there." });
      return false;
    }
    if (info.size !== row.size || Math.round(info.mtimeMs) !== row.mtime_ms) {
      this.update(row.id, {
        state: "waiting",
        size: info.size,
        mtime_ms: Math.round(info.mtimeMs),
        stable_since: this.now(),
        reason: WAITING_FOR_QUIET,
      });
      return false;
    }

    const files: { from: string; to: string; size: number }[] = [
      { from: row.path, to: target, size: info.size },
    ];
    for (const subtitle of parseJson<string[]>(row.subtitles_json, [])) {
      const to = join(
        dirname(target),
        nameOf(subtitleTarget(rel, nameOf(row.rel_path), nameOf(subtitle))),
      );
      if (files.some((one) => one.to === to) || (await exists(to))) continue;
      try {
        files.push({ from: subtitle, to, size: (await stat(subtitle)).size });
      } catch {
        // A subtitle that went is no reason to stop.
      }
    }

    const sameDrive = (await this.volumeOf(row.path)) === (await this.volumeOf(root.path));
    if (!sameDrive && !this.options.copyAcrossDrives) {
      this.toInbox(
        row,
        `It is on another drive than ${root.name}. Lobby only moves files within one drive, unless copying between drives is turned on in Server Settings.`,
      );
      return false;
    }

    this.update(row.id, { state: "moving", target_path: target, decided_by: by, reason: null });
    this.emit(row.id);
    const removeAfter: MoveData["removeAfter"] = [];
    let moves = files.map((one) => ({ from: one.from, to: one.to, size: one.size }));
    try {
      if (!sameDrive) {
        moves = [];
        for (const one of files) {
          const copy = join(dirname(one.to), `.${nameOf(one.to)}${COPY_SUFFIX}`);
          await this.copyAndProve(one.from, copy, one.size);
          moves.push({ from: copy, to: one.to, size: one.size });
          removeAfter.push({ path: one.from, size: one.size });
        }
      }
      await this.journal.run({
        id: `${row.id}-${String(this.now())}`,
        kind: "import",
        moves,
        data: { itemId: row.id, targetPath: target, removeAfter },
      });
    } catch (error) {
      if (error instanceof Inconsistent) {
        await this.recoverOne();
        const now = this.row(row.id);
        if (now.state === "moving") this.toInbox(now, "Another file was in the way.");
        return false;
      }
      if (this.options.fault) throw error;
      // Copies that were made are Lobby's own, and go.
      for (const one of moves) {
        if (one.from.endsWith(COPY_SUFFIX))
          await rm(one.from, { force: true }).catch(() => undefined);
      }
      const code = (error as NodeJS.ErrnoException).code;
      this.update(row.id, {
        state: "failed",
        reason:
          code === "ENOSPC"
            ? "The drive is full."
            : code === "EACCES" || code === "EPERM"
              ? "Lobby may not write in that library folder."
              : "Moving it failed. Nothing was replaced.",
      });
      this.activity("failed", row.id, by, "Moving it failed. Nothing was replaced.");
      log.error("An import failed", { error: errorMessage(error) });
      return false;
    }
    await this.afterImport(this.row(row.id));
    return true;
  }

  /** Copies a file to another drive and proves the copy is the same, byte for byte. */
  private async copyAndProve(from: string, to: string, size: number): Promise<void> {
    await mkdir(dirname(to), { recursive: true });
    const hash = createHash("sha256");
    const source = createReadStream(from);
    source.on("data", (chunk) => hash.update(chunk as Buffer));
    await pipeline(source, createWriteStream(to, { flags: "wx" }));
    await syncFile(to);
    const copied = await stat(to);
    if (copied.size !== size || (await sha256Of(to)) !== hash.digest("hex")) {
      await rm(to, { force: true });
      throw new Error("The copy is not the same as the original.");
    }
  }

  private async recoverOne(): Promise<void> {
    await this.journal?.recover().catch(() => undefined);
  }

  /** The journal's note in the database: run once, or again after a crash, with the same result. */
  private committed(data: MoveData): void {
    const row = this.db.get<ItemRow>("select * from import_item where id = ?", [data.itemId]);
    if (!row || row.state === "imported") return;
    this.db.transaction(() => {
      this.update(row.id, {
        state: "imported",
        target_path: data.targetPath,
        reason: null,
        done_at: this.now(),
        remove_after_json: JSON.stringify(data.removeAfter),
      });
      this.activity(
        "imported",
        row.id,
        row.decided_by,
        `“${nameOf(row.rel_path)}” is in the library as “${nameOf(data.targetPath)}”.`,
      );
    });
  }

  /** Removes the originals of proven copies, notes leftovers, tidies Lobby's own staging. */
  private async afterImport(row: ItemRow): Promise<void> {
    for (const one of parseJson<MoveData["removeAfter"]>(row.remove_after_json, [])) {
      try {
        const info = await stat(one.path);
        if (info.size === one.size) await rm(one.path);
      } catch {
        // Already gone.
      }
    }
    if (row.remove_after_json !== "[]") this.update(row.id, { remove_after_json: "[]" });
    if (row.origin === "folder" && row.folder_path) {
      const leftovers = await this.leftoversOf(row.folder_path, row.rel_path);
      this.update(row.id, { leftovers_json: JSON.stringify(leftovers) });
    } else if (row.origin === "upload" && this.options.lobbyDir) {
      // An upload's folder in Lobby's own staging goes once it is empty.
      const staging = join(this.options.lobbyDir, "uploads");
      let dir = dirname(row.path);
      while (within(staging, dir) && dir !== staging) {
        try {
          await rmdir(dir);
        } catch {
          break;
        }
        dir = dirname(dir);
      }
    }
    this.emit(row.id);
  }

  /**
   * What is left of the folder a film came in, when all of it may go: names Lobby knows as
   * leftovers (descriptions, pictures, checksums, samples, small videos) and empty folders.
   */
  private async leftoversOf(folderPath: string, rel: string): Promise<Leftovers | null> {
    const top = rel.split("/")[0];
    if (!top || top === rel) return null;
    const dir = join(folderPath, top);
    if (!(await exists(dir))) return null;
    const files = (await this.walk(dir)).map((file) => ({ ...file }));
    const verdicts = judgeFiles(files, (one) => this.episodeLike(one), this.limits);
    const all: string[] = [];
    for (const file of files) {
      const verdict = verdicts.get(file.rel);
      if (verdict?.status === "skip") {
        all.push(`${top}/${file.rel}`);
        continue;
      }
      if (verdict?.status !== "excluded" || !verdict.leftover) return null;
      all.push(`${top}/${file.rel}`);
    }
    return { dir: top, files: all.sort() };
  }

  // ---- Uploads ----

  /**
   * An upload that arrived whole: it goes the same way as a file in an import folder, except
   * that it is complete by definition and always goes into the library.
   */
  addUpload(upload: {
    uploadId: string;
    path: string;
    relPath: string;
    size: number;
    mtimeMs: number;
    hint: SourceHint;
    destination: string | null;
    subtitles: string[];
    by: string;
  }): Promise<ApiImportItem> {
    return this.serial(async () => {
      const id = randomUUID();
      const now = this.now();
      this.db.run(
        `insert into import_item (id, origin, path, rel_path, size, mtime_ms, state, upload_id,
           subtitles_json, decided_by, first_seen_at, stable_since, updated_at)
         values (?, 'upload', ?, ?, ?, ?, 'waiting', ?, ?, ?, ?, ?, ?)`,
        [
          id,
          upload.path,
          upload.relPath,
          upload.size,
          upload.mtimeMs,
          upload.uploadId,
          JSON.stringify(upload.subtitles),
          upload.by,
          now,
          now,
          now,
        ],
      );
      this.activity("uploaded", id, upload.by, `“${nameOf(upload.relPath)}” was uploaded.`);
      const verdicts = judgeFiles(
        [{ rel: upload.relPath, size: upload.size, mtimeMs: upload.mtimeMs }],
        (rel) => this.episodeLike(rel) || upload.hint === "series",
        this.limits,
      );
      const verdict = verdicts.get(upload.relPath);
      if (verdict?.status === "excluded") {
        // What the name says is kept, for a manager who imports it all the same.
        this.update(id, {
          ...parsedFields(upload.relPath, upload.hint, upload.destination),
          state: "ignored",
          reason: verdict.reason,
        });
      } else if (verdict?.status === "unfinished") {
        this.toInbox(this.row(id), verdict.reason);
      } else if (await this.decide(this.row(id), upload.hint, upload.destination)) {
        await this.libraryChanged();
      }
      this.emit(id);
      return this.toApi(this.row(id));
    });
  }

  /**
   * A subtitle that arrived after its video was already moved: it goes beside it, under its name.
   * @returns whether it was placed
   */
  placeLateSubtitle(videoItemId: string, subtitlePath: string): Promise<boolean> {
    return this.serial(async () => {
      const row = this.db.get<ItemRow>("select * from import_item where id = ?", [videoItemId]);
      if (!row) return false;
      if (row.state !== "imported" || !row.target_path) {
        const list = [...parseJson<string[]>(row.subtitles_json, []), subtitlePath];
        this.update(row.id, { subtitles_json: JSON.stringify(list) });
        return true;
      }
      const to = join(
        dirname(row.target_path),
        nameOf(subtitleTarget(row.target_path, nameOf(row.rel_path), nameOf(subtitlePath))),
      );
      if (await exists(to)) return false;
      if ((await this.volumeOf(subtitlePath)) !== (await this.volumeOf(dirname(row.target_path)))) {
        return false;
      }
      await moveWithoutReplacing({ from: subtitlePath, to });
      await this.libraryChanged();
      return true;
    });
  }

  // ---- A manager's choices ----

  confirm(id: string, by: string, decision: Decision): Promise<ApiImportItem> {
    return this.serial(async () => {
      const row = this.requireRow(id);
      if (row.state === "moving" || row.state === "imported") {
        throw new ImportError("conflict", "It is already in the library.");
      }
      const folder = this.folders.find((one) => one.path === row.folder_path) ?? null;
      if (row.origin === "folder" && !folder) {
        throw new ImportError("conflict", "Its import folder is no longer set up.");
      }
      if (decision.action === "list") {
        if (!folder || folder.mode !== "index") {
          throw new ImportError(
            "invalid_request",
            "Only a file in a folder that is indexed where it is can be listed there.",
          );
        }
        await this.checkStill(row);
        this.update(row.id, { state: "listed", reason: null, decided_by: by });
        this.activity("listed", row.id, by, `“${nameOf(row.rel_path)}” is listed where it is.`);
        await this.libraryChanged();
        this.emit(row.id);
        return this.toApi(this.row(row.id));
      }

      const kind = decision.kind;
      if (kind !== "movie" && kind !== "episode") {
        throw new ImportError("invalid_request", `"kind" must be movie or episode.`);
      }
      const title = decision.title?.trim();
      if (!title) throw new ImportError("invalid_request", `"title" must be the title.`);
      if (kind === "episode" && (!decision.season || !decision.episode)) {
        throw new ImportError("invalid_request", "An episode needs its season and episode number.");
      }
      const destination = decision.destination ?? null;
      if (destination !== null) {
        const root = this.options.roots().find((one) => one.path === destination);
        if (!root) throw new ImportError("invalid_request", "That is not a library folder.");
      }
      await this.checkStill(row);
      const wasListed = row.state === "listed";
      this.update(row.id, {
        kind,
        title,
        year: decision.year ?? null,
        season: kind === "episode" ? (decision.season ?? null) : null,
        episode: kind === "episode" ? (decision.episode ?? null) : null,
        episode_end: null,
        episode_title: kind === "episode" ? decision.episodeTitle?.trim() || null : null,
        tmdb_id: null,
        destination,
        decided_by: by,
      });
      this.activity("confirmed", row.id, by, `A manager confirmed “${title}”.`);
      const moved = await this.move(this.row(row.id), by);
      if (moved || wasListed) await this.libraryChanged();
      this.emit(row.id);
      return this.toApi(this.row(row.id));
    });
  }

  /** Refuses a choice about a file that is not finished, or changed since it was looked at. */
  private async checkStill(row: ItemRow): Promise<void> {
    let info;
    try {
      info = await stat(row.path);
    } catch {
      throw new ImportError("conflict", "The file is no longer there.");
    }
    if (info.size !== row.size || Math.round(info.mtimeMs) !== row.mtime_ms) {
      throw new ImportError(
        "conflict",
        "The file changed since Lobby looked. It is looked at again.",
      );
    }
    if (unfinishedByName(nameOf(row.path))) {
      throw new ImportError("conflict", "The file is not finished yet.");
    }
    if (row.origin === "folder") {
      const siblings = await readdir(dirname(row.path));
      const verdict = judgeFiles(
        siblings.map((name) => ({
          rel: name,
          size: name === nameOf(row.path) ? info.size : 0,
          mtimeMs: 0,
        })),
        () => true,
        { minFilmBytes: 0, minEpisodeBytes: 0 },
      ).get(nameOf(row.path));
      if (verdict?.status === "unfinished") {
        throw new ImportError("conflict", "A program still keeps a file beside it.");
      }
      if (await (this.options.isOpenElsewhere ?? openElsewhereOnLinux)(row.path)) {
        throw new ImportError("conflict", "Another program has it open. Try again later.");
      }
    }
  }

  dismiss(id: string, by: string): Promise<ApiImportItem> {
    return this.serial(async () => {
      const row = this.requireRow(id);
      if (row.state === "moving" || row.state === "imported") {
        throw new ImportError("conflict", "It is already in the library.");
      }
      const wasListed = row.state === "listed";
      if (
        row.origin === "upload" &&
        this.options.lobbyDir &&
        within(join(this.options.lobbyDir, "uploads"), row.path)
      ) {
        // Lobby's own copy of an upload; the original is still on the device it came from.
        await rm(row.path, { force: true });
        for (const subtitle of parseJson<string[]>(row.subtitles_json, [])) {
          if (within(join(this.options.lobbyDir, "uploads"), subtitle))
            await rm(subtitle, { force: true });
        }
      }
      this.update(row.id, { state: "dismissed", reason: null, decided_by: by });
      this.activity("dismissed", row.id, by, `“${nameOf(row.rel_path)}” is left alone.`);
      if (wasListed) await this.libraryChanged();
      this.emit(row.id);
      return this.toApi(this.row(row.id));
    });
  }

  /**
   * Deletes what is left of a film's folder after it was moved, when a manager says so. Each file
   * is judged again first: only leftovers go, and only below the import folder.
   */
  cleanUp(id: string, by: string): Promise<ApiImportItem> {
    return this.serial(async () => {
      const row = this.requireRow(id);
      const leftovers = parseJson<Leftovers | null>(row.leftovers_json, null);
      if (row.state !== "imported" || !row.folder_path || !leftovers || Array.isArray(leftovers)) {
        throw new ImportError("conflict", "There is nothing left to clean up.");
      }
      const now = await this.leftoversOf(row.folder_path, `${leftovers.dir}/x`);
      if (!now) {
        this.update(row.id, { leftovers_json: "null" });
        throw new ImportError("conflict", "Something else is in that folder now, so it stays.");
      }
      const dir = join(row.folder_path, leftovers.dir);
      if (!within(row.folder_path, dir) || dir === row.folder_path) {
        throw new ImportError("conflict", "There is nothing left to clean up.");
      }
      for (const rel of now.files) {
        const path = join(row.folder_path, rel);
        if (within(dir, path)) await rm(path, { force: true });
      }
      await this.removeEmpty(dir);
      await syncDir(row.folder_path).catch(() => undefined);
      this.update(row.id, { leftovers_json: "null" });
      this.activity(
        "cleaned",
        row.id,
        by,
        `Removed what was left of “${leftovers.dir}” (${String(now.files.length)} ${now.files.length === 1 ? "file" : "files"}).`,
      );
      this.emit(row.id);
      return this.toApi(this.row(row.id));
    });
  }

  private async removeEmpty(dir: string): Promise<void> {
    for (const entry of await readdir(dir, { withFileTypes: true })) {
      if (entry.isDirectory()) await this.removeEmpty(join(dir, entry.name));
    }
    try {
      await rmdir(dir);
    } catch {
      // Not empty: something stays.
    }
  }

  // ---- After a crash ----

  private async recover(): Promise<void> {
    if (this.journal && (await this.driveConnected())) {
      try {
        const unclear = await this.journal.recover();
        for (const one of unclear) {
          log.error("An interrupted import needs a person to look at it", { operation: one.id });
        }
      } catch (error) {
        log.warn("Could not check for interrupted imports", { error: errorMessage(error) });
      }
    }
    for (const row of this.db.all<ItemRow>("select * from import_item where state = 'moving'")) {
      // The journal put it back or never started it: the copies Lobby made go, and it is looked at again.
      if (row.target_path) {
        const copy = join(dirname(row.target_path), `.${nameOf(row.target_path)}${COPY_SUFFIX}`);
        await rm(copy, { force: true }).catch(() => undefined);
      }
      const there = await exists(row.path);
      this.update(row.id, {
        state: there ? "waiting" : "failed",
        reason: there ? null : "The file is no longer there.",
        stable_since: this.now(),
      });
    }
    for (const row of this.db.all<ItemRow>(
      "select * from import_item where state = 'imported' and remove_after_json <> '[]'",
    )) {
      await this.afterImport(row);
    }
  }

  // ---- Reading ----

  status(): Promise<{
    folders: FolderStatus[];
    moving: boolean;
    driveConnected: boolean;
    counts: Record<ItemState, number>;
  }> {
    return (async () => {
      const counts = this.counts(null);
      const folders: FolderStatus[] = [];
      for (const folder of this.folders) {
        folders.push({
          path: folder.path,
          name: folderName(folder),
          mode: folder.mode,
          looksLikeDownloads: looksLikeDownloads(folder.path),
          connected: await exists(folder.path),
          counts: this.counts(folder.path),
          lastLookAt: this.lastLook.get(folder.path) ?? null,
          problem: this.problems.get(folder.path) ?? null,
        });
      }
      return {
        folders,
        moving: this.journal !== null,
        driveConnected: await this.driveConnected(),
        counts,
      };
    })();
  }

  private counts(folderPath: string | null): Record<ItemState, number> {
    const counts = Object.fromEntries(STATES.map((state) => [state, 0])) as Record<
      ItemState,
      number
    >;
    const rows = this.db.all<{ state: ItemState; n: number }>(
      folderPath === null
        ? "select state, count(*) as n from import_item group by state"
        : "select state, count(*) as n from import_item where folder_path = ? group by state",
      folderPath === null ? [] : [folderPath],
    );
    for (const row of rows) counts[row.state] = row.n;
    return counts;
  }

  items(states: ItemState[], limit: number): ApiImportItem[] {
    const marks = states.map(() => "?").join(", ");
    return this.db
      .all<ItemRow>(
        `select * from import_item where state in (${marks}) order by updated_at desc limit ?`,
        [...states, limit],
      )
      .map((row) => this.toApi(row));
  }

  item(id: string): ApiImportItem {
    return this.toApi(this.requireRow(id));
  }

  activityLog(limit: number): {
    id: number;
    at: number;
    itemId: string | null;
    deviceId: string | null;
    action: string;
    message: string;
  }[] {
    return this.db
      .all<{
        id: number;
        at: number;
        item_id: string | null;
        device_id: string | null;
        action: string;
        message: string;
      }>("select * from import_activity order by id desc limit ?", [limit])
      .map((row) => ({
        id: row.id,
        at: row.at,
        itemId: row.item_id,
        deviceId: row.device_id,
        action: row.action,
        message: row.message,
      }));
  }

  /** The library asset an imported file became, for the conversion queue. */
  assetPathOf(id: string): { path: string } | null {
    const row = this.requireRow(id);
    return row.state === "imported" && row.target_path ? { path: row.target_path } : null;
  }

  private toApi(row: ItemRow): ApiImportItem {
    const leftovers = parseJson<Leftovers | null>(row.leftovers_json, null);
    const shownLeftovers = leftovers && !Array.isArray(leftovers) ? leftovers : null;
    const folder = this.folders.find((one) => one.path === row.folder_path) ?? null;
    const convertible = OLD_FORMATS.has(extensionOf(row.rel_path));
    const actions: ApiImportItem["actions"] = [];
    if (["inbox", "listed", "ignored", "failed", "dismissed", "waiting"].includes(row.state)) {
      if (
        row.state !== "waiting" ||
        row.reason === "TMDB could not be reached. Lobby tries again."
      ) {
        actions.push("move");
      }
      if (folder?.mode === "index" && row.state !== "listed" && row.state !== "waiting")
        actions.push("list");
      if (row.state !== "dismissed") actions.push("dismiss");
    }
    if (row.state === "imported" && shownLeftovers) actions.push("cleanUp");
    if (row.state === "imported" && convertible) actions.push("convert");
    return {
      id: row.id,
      origin: row.origin,
      folder: row.folder_path,
      name: nameOf(row.rel_path),
      relPath: row.rel_path,
      sizeBytes: row.size,
      state: row.state,
      reason: row.reason,
      kind: row.kind,
      title: row.title,
      year: row.year,
      season: row.season,
      episode: row.episode,
      episodeTitle: row.episode_title,
      tmdbId: row.tmdb_id,
      candidates: parseJson(row.candidates_json, []),
      destination: row.destination,
      targetPath: row.target_path,
      subtitles: parseJson<string[]>(row.subtitles_json, []).map((path) =>
        row.folder_path ? relative(row.folder_path, path) : basename(path),
      ),
      leftovers: shownLeftovers,
      uploadId: row.upload_id,
      convertible,
      actions,
      firstSeenAt: row.first_seen_at,
      updatedAt: row.updated_at,
      doneAt: row.done_at,
    };
  }

  // ---- Rows ----

  private row(id: string): ItemRow {
    const row = this.db.get<ItemRow>("select * from import_item where id = ?", [id]);
    if (!row) throw new ImportError("not_found", "There is no such file to import.");
    return row;
  }

  private requireRow(id: string): ItemRow {
    return this.row(id);
  }

  private update(id: string, fields: Partial<ItemRow>): void {
    const entries = Object.entries({ ...fields, updated_at: this.now() });
    this.db.run(
      `update import_item set ${entries.map(([key]) => `${key} = ?`).join(", ")} where id = ?`,
      [...entries.map(([, value]) => value), id],
    );
    if (fields.state !== undefined) this.emit(id);
  }

  private emit(id: string): void {
    if (!this.options.onChange) return;
    const row = this.db.get<ItemRow>("select * from import_item where id = ?", [id]);
    if (row) this.options.onChange(this.toApi(row));
  }

  private activity(
    action: string,
    itemId: string | null,
    deviceId: string | null,
    message: string,
  ): void {
    this.db.run(
      "insert into import_activity (at, item_id, device_id, action, message) values (?, ?, ?, ?, ?)",
      [this.now(), itemId, deviceId, action, message],
    );
    // A year of a busy folder is a few thousand lines; older ones go.
    this.db.run(
      "delete from import_activity where id <= (select max(id) from import_activity) - 5000",
    );
  }
}

/** What a file's name says it is, as the item's fields. */
function parsedFields(
  relPath: string,
  hint: SourceHint,
  destination: string | null,
): Partial<ItemRow> {
  const parsed = parseMediaPath(relPath, hint);
  const kind =
    parsed.kind === "episode" && parsed.season !== null && parsed.episode !== null
      ? "episode"
      : parsed.kind === "movie"
        ? "movie"
        : null;
  return {
    kind,
    title: parsed.title || null,
    year: parsed.year,
    season: parsed.season,
    episode: parsed.episode,
    episode_end: parsed.episodeEnd,
    episode_title: parsed.episodeTitle,
    destination,
  };
}

const WAITING_FOR_QUIET = "Waiting until it has not changed for a while.";
