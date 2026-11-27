// SPDX-License-Identifier: MPL-2.0
import { createHash, randomUUID } from "node:crypto";
import { createReadStream } from "node:fs";
import {
  mkdir,
  open,
  readdir,
  readFile,
  readlink,
  rename,
  rm,
  stat,
  statfs,
} from "node:fs/promises";
import { basename, dirname, extname, join, sep } from "node:path";
import type { Database } from "../db/database.ts";
import type { Catalogue } from "../library/catalogue.ts";
import { TEXT_SUBTITLES } from "../library/probe.ts";
import { revisionOf } from "../library/scanner.ts";
import { errorMessage, log, wholeLines, withoutPaths } from "../log.ts";
import {
  audioIsCopyable,
  conversionArguments,
  runConversion,
  targetFor,
  type ConversionKind,
  type ConversionTarget,
  type RunningConversion,
} from "./convert.ts";
import {
  Journal,
  syncDir,
  syncFile,
  writeDurably,
  writeManifest,
  type FaultPoint,
  type Operation,
} from "./moves.ts";
import {
  ACTIVE_STATES,
  ConversionStore,
  toJob,
  toReplacement,
  type AssetInfo,
  type ConversionJob,
  type JobRow,
  type JobState,
  type Replacement,
  type ReplacementRow,
  type Scope,
} from "./store.ts";
import { proveConversion, type Proof } from "./verify.ts";

/** A refusal the HTTP layer turns into a status, with a sentence that can be shown as it is. */
export class ConversionError extends Error {
  readonly code: "invalid_request" | "not_found" | "conflict" | "gone" | "unavailable";
  readonly extra: Record<string, unknown>;

  constructor(code: ConversionError["code"], message: string, extra: Record<string, unknown> = {}) {
    super(message);
    this.code = code;
    this.extra = extra;
  }
}

/** The hours of the day the server itself may convert in, as minutes after local midnight. */
export interface Hours {
  from: number;
  to: number;
}

export interface ConversionOptions {
  db: Database;
  catalogue: Catalogue;
  /**
   * Lobby's own folder on the drive the library is on: staging, the journal, and the
   * originals that were replaced. Null turns the whole feature off.
   */
  dir: string | null;
  ffmpegPath?: string;
  ffprobePath?: string;
  /** Null: at any hour. */
  hours?: Hours | null;
  /** Whether MKV files may be repackaged into MP4. Off unless the household turns it on. */
  repackage?: boolean;
  /** Whether the server converts by itself. Off leaves the queue to Macs. */
  serverConverts?: boolean;
  /** Space that must stay free on the drive. Default 5 GB. */
  minFreeBytes?: number;
  /** The server converts only after nobody has played or downloaded anything for this long. Default 5 minutes. */
  quietMs?: number;
  /** How often the queue is looked at. Default 15 s. */
  intervalMs?: number;
  /** How long a Mac may be silent before its job goes back into the queue. Default 5 minutes. */
  leaseMs?: number;
  now?: () => number;
  /** Minutes after local midnight; replaced in tests. */
  minuteOfDay?: (now: number) => number;
  /** The volume a path is on; replaced in tests like the scanner's. */
  volumeOf?: (path: string) => Promise<number>;
  /** Whether a copy of the file is being prepared for someone right now. */
  isPreparing?: (assetId: string) => boolean;
  /** Whether another program has the file open, as far as that can be seen. */
  isOpenElsewhere?: (path: string) => Promise<boolean>;
  /** Called after a file took another's place, so the library is read again at once. */
  onReplaced?: () => void | Promise<void>;
  /** For the statistics: a converter (a Mac, or the server itself) began a job. */
  onStarted?: (jobId: string) => void;
  /** For the statistics: a converted file took its original's place. */
  onConverted?: (jobId: string, assetId: string, savedBytes: number) => void;
  /** Stops a replacement at a chosen step. For tests of what a crash leaves behind. */
  fault?: (point: FaultPoint, operation: Operation<OperationData>) => void;
}

interface ReplaceData {
  type: "replace";
  jobId: string;
  assetId: string;
  itemId: string | null;
  sourceId: string;
  originalRelPath: string;
  newRelPath: string;
  /** Inside Lobby's folder. */
  keptPath: string;
  original: { size: number; mtimeMs: number; fingerprint: string | null };
  newSize: number;
  newMtimeMs: number;
  kind: ConversionKind;
  doneBy: string;
  proof: Proof;
  at: number;
}

interface UndoData {
  type: "undo";
  replacementId: string;
  setAsidePath: string;
  at: number;
}

export type OperationData = ReplaceData | UndoData;

type Verdict =
  | { ok: true; kind: ConversionKind; worker: "any" | "mac"; target: ConversionTarget }
  | { ok: false; kind: ConversionKind | null; reason: string; wait?: boolean };

export interface ConversionStatus {
  /** False when no folder is configured: nothing below does anything. */
  enabled: boolean;
  /** False while the drive with Lobby's folder is not connected. */
  driveConnected: boolean;
  paused: boolean;
  serverConverts: boolean;
  hours: Hours | null;
  /** Whether the server would convert right now, and if not, why not. */
  serverIdleBecause: string | null;
  repackage: boolean;
  counts: Record<JobState, number>;
  /** Replacements that were interrupted and that Lobby will not finish or undo by itself. */
  needsAttention: { id: string; reason: string }[];
  jobs: ConversionJob[];
}

const MB = 1024 * 1024;
/** Folders whose files may still be in the hands of a download program. */
export const DOWNLOAD_FOLDER =
  /^(?:downloads?|torrents?|incomplete|incoming|seeding|seeds?|sabnzbd|nzbget|qbittorrent|transmission|deluge|utorrent|jdownloader|_?unpack(?:ed)?)$/i;
export const DOWNLOAD_MARKER = /\.(?:torrent|!qb|part|aria2|crdownload|nzb)$/i;
/** A file is left alone for this long after someone last played or fetched it. */
const IN_USE_MS = 10 * 60_000;
const MARKER = "lobby-folder.json";

async function exists(path: string): Promise<boolean> {
  try {
    await stat(path);
    return true;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw error;
  }
}

/** Linux only, and only for processes of the same user: whether any has the file open. */
export async function openElsewhereOnLinux(path: string): Promise<boolean> {
  if (process.platform !== "linux") return false;
  let pids: string[];
  try {
    pids = (await readdir("/proc")).filter((name) => /^\d+$/.test(name));
  } catch {
    return false;
  }
  for (const pid of pids) {
    if (Number(pid) === process.pid) continue;
    let fds: string[];
    try {
      fds = await readdir(`/proc/${pid}/fd`);
    } catch {
      // Another user's process: not ours to look into.
      continue;
    }
    for (const fd of fds) {
      try {
        if ((await readlink(`/proc/${pid}/fd/${fd}`)) === path) return true;
      } catch {
        // The descriptor closed while we looked.
      }
    }
  }
  return false;
}

/**
 * Converts old files into ones Apple devices play, and puts the result in the
 * original's place once it is proven good.
 *
 * - A manager fills a queue. The server works through it one file at a time, at
 *   the lowest priority, only while nobody watches and inside the hours set for
 *   it. A Mac can take jobs too: it fetches the original, converts it and sends
 *   the result back.
 * - Whoever converted, the server proves the result (`verify.ts`) before it
 *   touches the library.
 * - Replacing is two renames on the drive, written to a journal first: the
 *   original goes into Lobby's folder, the new file takes its name. Nothing is
 *   overwritten or deleted. A replacement can be undone, and an original only
 *   goes for good when a person asks for exactly that.
 */
export class ConversionService {
  readonly store: ConversionStore;
  private readonly options: ConversionOptions;
  private readonly dir: string | null;
  private readonly now: () => number;
  private readonly journal: Journal<OperationData> | null;
  private readonly lastUsed = new Map<string, number>();
  private readonly waitUntil = new Map<string, number>();
  private lastActivityAt = 0;
  private timer: NodeJS.Timeout | null = null;
  private lane: Promise<void> | null = null;
  private running: { jobId: string; process: RunningConversion | null; cancelled: boolean } | null =
    null;
  private recovered = false;
  private attention: { id: string; reason: string }[] = [];
  private stopped = false;

  constructor(options: ConversionOptions) {
    this.options = options;
    this.dir = options.dir;
    this.now = options.now ?? Date.now;
    this.store = new ConversionStore(options.db, this.now);
    this.journal = this.dir
      ? new Journal<OperationData>(join(this.dir, "journal"), {
          commit: (operation) => this.commit(operation),
          abandon: (operation, reason) => {
            this.abandon(operation, reason);
          },
          ...(options.fault ? { fault: options.fault } : {}),
        })
      : null;
  }

  get enabled(): boolean {
    return this.dir !== null;
  }

  /**
   * Takes new hours and choices while it runs. A job under way finishes as it started; the next
   * one is chosen under the new ones. Lobby's folder is not among them: that needs a restart.
   */
  configure(
    change: Pick<ConversionOptions, "hours" | "repackage" | "serverConverts" | "minFreeBytes">,
  ): void {
    Object.assign(this.options, change);
  }

  /**
   * Finishes or takes back whatever an earlier run left halfway, then starts
   * looking at the queue. Call it before the library is scanned.
   */
  async start(): Promise<void> {
    if (!this.enabled) return;
    this.stopped = false;
    // What the server itself was doing when it stopped starts again from the beginning.
    for (const job of this.store.jobs(["converting", "verifying"], 1000)) {
      if (job.claimed_by !== null || job.state === "verifying") {
        this.store.update(job.id, { state: "uploaded", progress: 0 });
      } else {
        this.store.update(job.id, { state: "queued", progress: 0, reason: null });
      }
    }
    await this.recover();
    if (this.timer) return;
    this.timer = setInterval(() => void this.tick(), this.options.intervalMs ?? 15_000);
    this.timer.unref();
  }

  async stop(): Promise<void> {
    this.stopped = true;
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    if (this.running) {
      this.running.cancelled = true;
      this.running.process?.cancel();
    }
    // A check of a long film is not waited for: it starts again after the restart, and a
    // replacement caught halfway is finished or taken back from its journal.
    await Promise.race([this.lane, new Promise((resolve) => setTimeout(resolve, 5000).unref())]);
  }

  // ---- The drive ----

  private volumeOf(path: string): Promise<number> {
    return this.options.volumeOf
      ? this.options.volumeOf(path)
      : stat(path).then((info) => info.dev);
  }

  /**
   * Whether Lobby's folder is there. An unplugged drive leaves an empty mount point
   * behind; a folder made there would land on the system disk. So the folder is
   * only ever created on a volume the library is known to be on, it gets a marker
   * file, and afterwards only a folder with that marker counts.
   */
  async driveConnected(): Promise<boolean> {
    if (!this.dir) return false;
    const known = this.store.db.getMeta("conversion_folder_id");
    try {
      if (known !== undefined) {
        const marker = JSON.parse(await readFile(join(this.dir, MARKER), "utf8")) as {
          id?: string;
        };
        return marker.id === known;
      }
      const volume = await this.volumeOf(dirname(this.dir));
      if (!this.store.knownVolumes().has(String(volume))) return false;
      const id = randomUUID();
      await mkdir(this.dir, { recursive: true });
      await writeDurably(
        join(this.dir, MARKER),
        `${JSON.stringify({ id, note: "Lobby keeps converted files' originals here. Do not put anything else in this folder." }, null, 2)}\n`,
      );
      this.store.db.setMeta("conversion_folder_id", id);
      return true;
    } catch {
      return false;
    }
  }

  private path(...parts: string[]): string {
    if (!this.dir) throw new ConversionError("unavailable", "Converting is not set up.");
    return join(this.dir, ...parts);
  }

  private staged(jobId: string): string {
    return this.path("staging", `${jobId}.mp4`);
  }

  private upload(jobId: string): string {
    return this.path("staging", `${jobId}.upload`);
  }

  private async removeStaged(jobId: string): Promise<void> {
    for (const path of [this.staged(jobId), `${this.staged(jobId)}.partial`, this.upload(jobId)]) {
      await rm(path, { force: true }).catch(() => undefined);
    }
  }

  private async recover(): Promise<boolean> {
    if (!this.journal || !(await this.driveConnected())) {
      this.recovered = false;
      return false;
    }
    try {
      this.attention = await this.journal.recover();
      this.recovered = true;
      if (this.attention.length > 0) {
        log.error("An interrupted replacement needs a person to look at it", {
          operations: this.attention.map((entry) => entry.id).join(","),
        });
      }
    } catch (error) {
      this.recovered = false;
      log.warn("Could not check for interrupted replacements", { error: errorMessage(error) });
    }
    return this.recovered;
  }

  // ---- What may be converted ----

  /** Decides from the catalogue alone what a file needs. Nothing on disk is looked at. */
  private classify(asset: AssetInfo): Verdict {
    const no = (reason: string, kind: ConversionKind | null = null): Verdict => ({
      ok: false,
      kind,
      reason,
    });
    if (!asset.probed) return no("This file has not been read yet.");
    const { tracks } = asset.probe;
    const video = tracks.find((track) => track.kind === "video");
    if (!video) return no("This file has no picture.");
    if (asset.probe.playability === "direct") return no("This file plays as it is.");

    let kind: ConversionKind;
    if (video.codec === "mpeg4" || video.codec === "msmpeg4v3") kind = "h264";
    else if (video.codec === "av1") kind = "hevc";
    else if (asset.probe.playability === "remux") kind = "repackage";
    else return no("Lobby does not convert this kind of video.");

    if (kind === "repackage") {
      if (!this.options.repackage) {
        return no("Repackaging files that already have a good picture is turned off.", kind);
      }
      if (!audioIsCopyable(tracks)) {
        return no(
          "Its sound would have to be converted, which is not a change without loss.",
          kind,
        );
      }
    }
    if (tracks.some((track) => track.kind === "subtitle" && !TEXT_SUBTITLES.has(track.codec))) {
      return no("It has subtitles stored as pictures, which an MP4 file cannot keep.", kind);
    }
    if (asset.multiPart) return no("It is one part of a film kept in several files.", kind);
    if (asset.episodes > 1) return no("It holds several episodes in one file.", kind);
    const target = targetFor(kind, tracks);
    if (!target) return no("This file has no picture.", kind);
    return { ok: true, kind, worker: kind === "hevc" ? "mac" : "any", target };
  }

  /**
   * The whole judgement: the catalogue's view, then the file itself and where it
   * lives. Files that are hard to judge are left alone, with the reason.
   */
  private async judge(asset: AssetInfo, queueing = false): Promise<Verdict> {
    const verdict = this.classify(asset);
    if (!verdict.ok) return verdict;
    const no = (reason: string, wait = false): Verdict => ({
      ok: false,
      kind: verdict.kind,
      reason,
      ...(wait ? { wait: true } : {}),
    });
    if (!asset.available) return no("The drive this file is on is not connected.", true);
    const path = join(asset.sourcePath, asset.relPath);

    let info;
    try {
      info = await stat(path);
    } catch {
      return no("The file is not where the library last saw it.", true);
    }
    if (!info.isFile()) return no("It is not an ordinary file.");
    if (info.size !== asset.size || Math.round(info.mtimeMs) !== asset.mtimeMs) {
      return no("The file changed since the library last read it.", true);
    }
    if (info.nlink > 1) {
      return no(
        "The file has a second name somewhere (a hard link), so something else may use it.",
      );
    }
    const segments = [basename(asset.sourcePath), ...asset.relPath.split("/").slice(0, -1)];
    if (segments.some((segment) => DOWNLOAD_FOLDER.test(segment))) {
      return no("It is in a download folder, where a download program may still use it.");
    }
    const folder = dirname(path);
    const stem = basename(path, extname(path)).toLowerCase();
    for (const name of await readdir(folder)) {
      if (DOWNLOAD_MARKER.test(name) && name.toLowerCase().startsWith(stem)) {
        return no("A download program still has a file beside it.");
      }
    }
    const targetPath = join(folder, `${basename(path, extname(path))}.mp4`);
    if (targetPath !== path && (await exists(targetPath))) {
      return no("There is already an MP4 file with the same name beside it.");
    }

    if (!this.dir) return no("Converting is not set up.");
    if (!(await this.driveConnected())) {
      return no("The drive Lobby's folder is on is not connected.", true);
    }
    if ((await this.volumeOf(folder)) !== (await this.volumeOf(this.dir))) {
      return no("It is not on the drive Lobby's folder is on.");
    }
    const volume = await statfs(this.dir);
    const needed = asset.size * 1.5 + (this.options.minFreeBytes ?? 5 * 1024 * MB);
    if (volume.bavail * volume.bsize < needed) {
      return no("There is not enough free space on the drive.", true);
    }
    // Looked at when the work starts and again before the replacement, not for every file
    // of a long list that is only being queued.
    if (!queueing && (await (this.options.isOpenElsewhere ?? openElsewhereOnLinux)(path))) {
      return no("Another program has the file open.", true);
    }
    return verdict;
  }

  private inUse(assetId: string): boolean {
    return (
      this.now() - (this.lastUsed.get(assetId) ?? 0) < IN_USE_MS ||
      this.options.isPreparing?.(assetId) === true
    );
  }

  // ---- For managers ----

  /** Someone is playing or fetching something; `assetId` when it is known which file. */
  noteActivity(assetId?: string): void {
    this.lastActivityAt = this.now();
    if (assetId !== undefined) this.lastUsed.set(assetId, this.now());
    this.running?.process?.setPaused(true);
  }

  private serverIdleBecause(): string | null {
    if (this.options.serverConverts === false) {
      return "The server is set not to convert by itself.";
    }
    if (this.store.paused) return "Converting is paused.";
    return this.quietBecause();
  }

  /**
   * Why work in the background should wait now: it is outside the hours set for converting, or
   * someone watched or downloaded something a moment ago. Null: it may go on. Finding intros
   * (`markers/`) keeps to the same hours as converting.
   */
  quietBecause(): string | null {
    const hours = this.options.hours ?? null;
    if (hours) {
      const minute = (
        this.options.minuteOfDay ??
        ((now: number): number => {
          const date = new Date(now);
          return date.getHours() * 60 + date.getMinutes();
        })
      )(this.now());
      const inside =
        hours.from <= hours.to
          ? minute >= hours.from && minute < hours.to
          : minute >= hours.from || minute < hours.to;
      if (!inside) return "It is outside the hours set for converting.";
    }
    if (this.now() - this.lastActivityAt < (this.options.quietMs ?? 5 * 60_000)) {
      return "Someone is watching or downloading.";
    }
    return null;
  }

  async status(limit = 200): Promise<ConversionStatus> {
    return {
      enabled: this.enabled,
      driveConnected: await this.driveConnected(),
      paused: this.store.paused,
      serverConverts: this.options.serverConverts ?? true,
      hours: this.options.hours ?? null,
      serverIdleBecause: this.enabled ? this.serverIdleBecause() : "Converting is not set up.",
      repackage: this.options.repackage ?? false,
      counts: this.store.counts(),
      needsAttention: this.attention,
      jobs: this.store.jobs(null, limit).map(toJob),
    };
  }

  private requireEnabled(): void {
    if (!this.enabled) {
      throw new ConversionError(
        "unavailable",
        "Converting is not set up on this server (no conversion folder in its config).",
      );
    }
  }

  /**
   * Puts the files of a title, a category or everything old into the queue. Files
   * that will not be converted are recorded as skipped, with the reason.
   */
  async enqueue(
    scope: Scope,
    requestedBy: string,
  ): Promise<{ queued: number; skipped: number; alreadyQueued: number; jobs: ConversionJob[] }> {
    this.requireEnabled();
    const assetIds = this.store.assetsOf(scope);
    if (assetIds === null) {
      throw new ConversionError("not_found", "That title or category is not in the library.");
    }
    const result = { queued: 0, skipped: 0, alreadyQueued: 0, jobs: [] as ConversionJob[] };
    for (const assetId of assetIds) {
      const active = this.store.activeJobFor(assetId);
      if (active) {
        result.alreadyQueued += 1;
        result.jobs.push(toJob(active));
        continue;
      }
      const asset = this.store.asset(assetId);
      if (!asset) continue;
      const verdict = await this.judge(asset, true);
      // "Everything old" is about old files: what plays as it is is not worth a line.
      if (!verdict.ok && scope.kind !== "item" && verdict.kind === null) continue;
      const row = this.store.add(
        asset,
        verdict.ok
          ? { kind: verdict.kind, worker: verdict.worker }
          : verdict.wait
            ? // Something that passes by itself: it waits in the queue and is judged again.
              { kind: verdict.kind ?? "h264", worker: verdict.kind === "hevc" ? "mac" : "any" }
            : { kind: verdict.kind, skip: verdict.reason },
        requestedBy,
      );
      if (row.state === "queued") result.queued += 1;
      else result.skipped += 1;
      result.jobs.push(toJob(row));
    }
    void this.tick();
    return result;
  }

  setPaused(paused: boolean): void {
    this.requireEnabled();
    this.store.paused = paused;
    if (paused) this.running?.process?.setPaused(true);
    else void this.tick();
  }

  private requireJob(jobId: string): JobRow {
    const job = this.store.job(jobId);
    if (!job) throw new ConversionError("not_found", "There is no such job.");
    return job;
  }

  /** Takes a job out of the queue. A file that already took its original's place stays; undo that instead. */
  async cancel(jobId: string): Promise<ConversionJob> {
    this.requireEnabled();
    const job = this.requireJob(jobId);
    if (!ACTIVE_STATES.includes(job.state)) {
      throw new ConversionError("conflict", "This job is not waiting or running any more.");
    }
    if (this.running?.jobId === jobId) {
      this.running.cancelled = true;
      this.running.process?.cancel();
      await this.lane;
    }
    // The replacement may have been made while we waited.
    if (ACTIVE_STATES.includes(this.requireJob(jobId).state)) {
      this.store.update(jobId, {
        state: "cancelled",
        claimed_by: null,
        lease_expires_at: null,
        reason: "A manager cancelled it.",
      });
      if (await this.driveConnected()) await this.removeStaged(jobId);
    }
    return toJob(this.requireJob(jobId));
  }

  move(jobId: string, to: "top" | "bottom"): ConversionJob {
    this.requireEnabled();
    const job = this.requireJob(jobId);
    if (job.state !== "queued") {
      throw new ConversionError("conflict", "Only a job that is waiting can be moved.");
    }
    this.store.move(jobId, to);
    return toJob(this.requireJob(jobId));
  }

  // ---- For a Mac that takes jobs ----

  /** Gives the next waiting job to a device, for `leaseMs`. Null when there is none for it. */
  async claim(
    deviceId: string,
    kinds: readonly ConversionKind[],
  ): Promise<{ job: ConversionJob; target: ConversionTarget; asset: AssetInfo } | null> {
    this.requireEnabled();
    if (this.store.paused) return null;
    if (!(await this.recover()) || this.attention.length > 0) {
      throw new ConversionError("unavailable", "The drive Lobby's folder is on is not ready.");
    }
    await this.expireLeases();
    // The Mac asks again for a job it already holds, after losing its connection.
    const held = this.store.jobs(["claimed"], 1000).find((job) => job.claimed_by === deviceId);
    const candidates = held ? [held] : this.store.jobs(["queued"], 1000);
    for (const job of candidates) {
      if (job.kind === null || !kinds.includes(job.kind)) continue;
      if ((this.waitUntil.get(job.id) ?? 0) > this.now()) continue;
      const asset = this.store.asset(job.asset_id);
      const verdict = asset ? await this.judge(asset) : null;
      if (!asset || !verdict) {
        this.store.update(job.id, {
          state: "skipped",
          reason: "The file is no longer in the library.",
        });
        continue;
      }
      if (!verdict.ok) {
        if (verdict.wait) {
          this.waitUntil.set(job.id, this.now() + 5 * 60_000);
          this.store.update(job.id, { reason: verdict.reason });
        } else {
          this.store.update(job.id, { state: "skipped", reason: verdict.reason });
        }
        continue;
      }
      this.store.update(job.id, {
        state: "claimed",
        claimed_by: deviceId,
        lease_expires_at: this.now() + (this.options.leaseMs ?? 5 * 60_000),
        reason: null,
        original_size: asset.size,
        original_mtime_ms: asset.mtimeMs,
        original_fingerprint: asset.fingerprint,
      });
      if (!held) this.options.onStarted?.(job.id);
      return { job: toJob(this.requireJob(job.id)), target: verdict.target, asset };
    }
    return null;
  }

  private heldBy(jobId: string, deviceId: string): JobRow {
    const job = this.requireJob(jobId);
    if (job.state !== "claimed" || job.claimed_by !== deviceId) {
      throw new ConversionError("gone", "This job is not yours any more. Ask for the next one.");
    }
    if ((job.lease_expires_at ?? 0) < this.now()) {
      void this.expireLeases();
      throw new ConversionError("gone", "This job was given back after too long without a word.");
    }
    return job;
  }

  private renew(jobId: string, fields: Partial<JobRow> = {}): void {
    this.store.update(jobId, {
      ...fields,
      lease_expires_at: this.now() + (this.options.leaseMs ?? 5 * 60_000),
    });
  }

  heartbeat(jobId: string, deviceId: string, progress: number): ConversionJob {
    this.heldBy(jobId, deviceId);
    this.renew(jobId, { progress: Math.max(0, Math.min(1, progress)) });
    return toJob(this.requireJob(jobId));
  }

  /** How many bytes of the result have arrived. */
  async uploadOffset(jobId: string, deviceId: string): Promise<number> {
    this.heldBy(jobId, deviceId);
    try {
      return (await stat(this.upload(jobId))).size;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return 0;
      throw new ConversionError("unavailable", "The drive Lobby's folder is on is not connected.");
    }
  }

  /**
   * Appends bytes to the result. `offset` must be where the last piece ended, so a
   * piece sent twice or out of order is refused instead of corrupting the file.
   *
   * @returns the new offset
   */
  async uploadChunk(
    jobId: string,
    deviceId: string,
    offset: number,
    body: AsyncIterable<Uint8Array>,
  ): Promise<number> {
    const job = this.heldBy(jobId, deviceId);
    if (!(await this.driveConnected())) {
      throw new ConversionError("unavailable", "The drive Lobby's folder is on is not connected.");
    }
    const current = await this.uploadOffset(jobId, deviceId);
    if (offset !== current) {
      throw new ConversionError("conflict", "The upload is at another position.", {
        offset: current,
      });
    }
    // The proof refuses a file more than three times the original's size anyway.
    const limit = job.original_size * 3 + 16 * MB;
    await mkdir(this.path("staging"), { recursive: true });
    const handle = await open(this.upload(jobId), "a");
    let written = current;
    try {
      for await (const chunk of body) {
        if (written + chunk.length > limit) {
          throw new ConversionError(
            "invalid_request",
            "The result is far larger than the original. It will not be used.",
          );
        }
        await handle.write(chunk);
        written += chunk.length;
      }
      await handle.sync();
    } catch (error) {
      if (error instanceof ConversionError) throw error;
      const code = (error as NodeJS.ErrnoException).code;
      throw new ConversionError(
        "unavailable",
        code === "ENOSPC"
          ? "The drive is full."
          : "The upload was interrupted. Ask where it is and continue from there.",
      );
    } finally {
      await handle.close();
    }
    this.renew(jobId);
    return written;
  }

  /** The Mac says the result is all there. The server proves it before anything else happens. */
  async complete(
    jobId: string,
    deviceId: string,
    claim: { sizeBytes: number; sha256: string | null },
  ): Promise<ConversionJob> {
    this.heldBy(jobId, deviceId);
    const size = await this.uploadOffset(jobId, deviceId);
    if (size !== claim.sizeBytes || size === 0) {
      throw new ConversionError("conflict", "Not all of the result has arrived.", { offset: size });
    }
    if (claim.sha256 !== null) {
      const hash = createHash("sha256");
      for await (const chunk of createReadStream(this.upload(jobId))) hash.update(chunk as Buffer);
      if (hash.digest("hex") !== claim.sha256.toLowerCase()) {
        await rm(this.upload(jobId), { force: true });
        throw new ConversionError(
          "conflict",
          "The result arrived damaged. Send it again from the start.",
          { offset: 0 },
        );
      }
    }
    await rename(this.upload(jobId), this.staged(jobId));
    await syncDir(this.path("staging"));
    this.store.update(jobId, { state: "uploaded", progress: 0, lease_expires_at: null });
    void this.tick();
    return toJob(this.requireJob(jobId));
  }

  /** The Mac gives a job back: it goes to the end of nothing, it simply waits again. */
  async release(jobId: string, deviceId: string): Promise<ConversionJob> {
    this.heldBy(jobId, deviceId);
    this.store.update(jobId, {
      state: "queued",
      claimed_by: null,
      lease_expires_at: null,
      progress: 0,
    });
    if (await this.driveConnected()) await this.removeStaged(jobId);
    return toJob(this.requireJob(jobId));
  }

  private async expireLeases(): Promise<void> {
    for (const job of this.store.jobs(["claimed"], 1000)) {
      if ((job.lease_expires_at ?? 0) >= this.now()) continue;
      this.store.update(job.id, {
        state: "queued",
        claimed_by: null,
        lease_expires_at: null,
        progress: 0,
        reason: "The Mac that had it went silent.",
      });
      await this.removeStaged(job.id).catch(() => undefined);
    }
  }

  // ---- The server's own work ----

  /** One look at the queue. Work that is going on is joined, not doubled. */
  tick(): Promise<void> {
    if (!this.enabled || this.stopped) return Promise.resolve();
    this.lane ??= this.work()
      .catch((error: unknown) => {
        log.error("Converting failed unexpectedly", { error: errorMessage(error) });
      })
      .finally(() => {
        this.lane = null;
        this.running = null;
      });
    return this.lane;
  }

  private async work(): Promise<void> {
    if (!(await this.recover())) return;
    await this.expireLeases();
    if (this.attention.length > 0) return;

    // What a Mac sent in is proven first: it is waiting for its answer.
    const uploaded = this.store
      .jobs(["uploaded"], 1000)
      .find((job) => (this.waitUntil.get(job.id) ?? 0) <= this.now());
    if (uploaded) {
      await this.proveAndReplace(uploaded, uploaded.done_by ?? uploaded.claimed_by ?? "mac");
      return;
    }
    if (this.serverIdleBecause() !== null) return;
    for (const job of this.store.jobs(["queued"], 1000)) {
      if (job.worker !== "any" || job.kind === "hevc") continue;
      if ((this.waitUntil.get(job.id) ?? 0) > this.now()) continue;
      if (await this.convertOnServer(job)) return;
    }
  }

  /** @returns false when the job could not be started and the next one may be tried */
  private async convertOnServer(job: JobRow): Promise<boolean> {
    const asset = this.store.asset(job.asset_id);
    if (!asset) {
      this.store.update(job.id, {
        state: "skipped",
        reason: "The file is no longer in the library.",
      });
      return false;
    }
    const verdict = await this.judge(asset);
    if (!verdict.ok) {
      if (verdict.wait) {
        this.waitUntil.set(job.id, this.now() + 5 * 60_000);
        this.store.update(job.id, { reason: verdict.reason });
      } else {
        this.store.update(job.id, { state: "skipped", reason: verdict.reason });
      }
      return false;
    }

    this.running = { jobId: job.id, process: null, cancelled: false };
    this.store.update(job.id, {
      state: "converting",
      progress: 0,
      reason: null,
      original_size: asset.size,
      original_mtime_ms: asset.mtimeMs,
      original_fingerprint: asset.fingerprint,
    });
    this.options.onStarted?.(job.id);
    const partial = `${this.staged(job.id)}.partial`;
    await mkdir(this.path("staging"), { recursive: true });
    const duration = asset.probe.durationMs ?? 0;
    let lastWritten = 0;
    const process = runConversion(
      this.options.ffmpegPath ?? "ffmpeg",
      conversionArguments(join(asset.sourcePath, asset.relPath), verdict.target, partial),
      {
        niceness: 19,
        onProgress: (outTimeMs) => {
          // The database is on a slow disk: a few writes a minute are enough.
          if (this.now() - lastWritten < 5000 || duration <= 0) return;
          lastWritten = this.now();
          this.store.update(job.id, { progress: Math.min(0.99, outTimeMs / duration) });
        },
      },
    );
    this.running.process = process;
    // It stands still whenever the server should not be converting, and goes on afterwards.
    const watch = setInterval(() => {
      process.setPaused(this.serverIdleBecause() !== null);
    }, 2000);
    const result = await process.done;
    clearInterval(watch);

    if (this.running.cancelled) {
      await rm(partial, { force: true }).catch(() => undefined);
      if (this.stopped) this.store.update(job.id, { state: "queued", progress: 0 });
      return true;
    }
    if (result.code !== 0) {
      const connected = await this.driveConnected();
      if (connected) await rm(partial, { force: true }).catch(() => undefined);
      if (!connected) {
        // Nothing is wrong with the file: it is tried again when the drive is back.
        this.store.update(job.id, {
          state: "queued",
          progress: 0,
          reason: "The drive was disconnected while converting.",
        });
      } else {
        this.store.update(job.id, {
          state: "failed",
          reason: /No space left/i.test(result.stderr)
            ? "The drive ran out of space while converting."
            : "ffmpeg could not convert this file.",
        });
        log.warn("A file could not be converted", {
          job: job.id,
          error: withoutPaths(wholeLines(result.stderr)).slice(-400),
        });
      }
      return true;
    }
    await syncFile(partial);
    await rename(partial, this.staged(job.id));
    await syncDir(this.path("staging"));
    const fresh = this.store.job(job.id);
    if (fresh) await this.proveAndReplace(fresh, "server");
    return true;
  }

  /** Waits while someone is watching, so the checks do not compete with playback. */
  private async whileQuiet(): Promise<void> {
    while (
      !this.stopped &&
      this.now() - this.lastActivityAt < (this.options.quietMs ?? 5 * 60_000)
    ) {
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }
  }

  private async proveAndReplace(job: JobRow, doneBy: string): Promise<void> {
    this.running ??= { jobId: job.id, process: null, cancelled: false };
    const fail = async (reason: string, proof?: Proof): Promise<void> => {
      this.store.update(job.id, {
        state: "failed",
        reason,
        claimed_by: null,
        proof_json: proof ? JSON.stringify(proof) : null,
      });
      await this.removeStaged(job.id);
    };
    const asset = this.store.asset(job.asset_id);
    const staged = this.staged(job.id);
    if (!asset || !(await exists(staged))) {
      await fail("The converted file or its original is no longer there.");
      return;
    }
    // Seen at once, before anything else is asked of the file.
    const current = await stat(join(asset.sourcePath, asset.relPath)).catch(() => null);
    if (
      current &&
      (current.size !== job.original_size || Math.round(current.mtimeMs) !== job.original_mtime_ms)
    ) {
      await fail("The original changed while it was being converted.");
      return;
    }
    const verdict = await this.judge(asset);
    if (!verdict.ok) {
      if (verdict.wait) {
        this.waitUntil.set(job.id, this.now() + 60_000);
        this.store.update(job.id, { state: "uploaded", reason: verdict.reason });
        return;
      }
      await fail(verdict.reason);
      return;
    }

    this.store.update(job.id, { state: "verifying", progress: 0, done_by: doneBy });
    const originalPath = join(asset.sourcePath, asset.relPath);
    const proof = await proveConversion({
      originalPath,
      original: {
        size: job.original_size,
        mtimeMs: job.original_mtime_ms,
        fingerprint: job.original_fingerprint,
      },
      originalProbe: asset.probe,
      newPath: staged,
      target: verdict.target,
      ffmpegPath: this.options.ffmpegPath ?? "ffmpeg",
      ffprobePath: this.options.ffprobePath ?? "ffprobe",
      pause: () => this.whileQuiet(),
    });
    if (this.stopped || this.running.cancelled) {
      // Proven again after the restart; a cancelled job is cleaned up by `cancel`.
      if (this.stopped) this.store.update(job.id, { state: "uploaded" });
      return;
    }
    if (!proof.ok) {
      if (!(await this.driveConnected())) {
        this.store.update(job.id, {
          state: "uploaded",
          reason: "The drive was disconnected while the result was being checked.",
        });
        return;
      }
      await fail(proof.reason ?? "The converted file did not pass the checks.", proof);
      log.warn("A converted file was refused", {
        job: job.id,
        check: proof.checks.find((check) => !check.ok)?.name ?? "",
      });
      return;
    }

    // A title is not replaced while it is playing.
    if (this.inUse(asset.id)) {
      this.waitUntil.set(job.id, this.now() + 60_000);
      this.store.update(job.id, {
        state: "uploaded",
        reason: "Waiting until nobody is watching this title.",
      });
      return;
    }
    await this.replace(job, asset, verdict.kind, doneBy, proof);
  }

  /**
   * A free path inside Lobby's folder: `<kind>/<date>/<library folder>/<path in the library>`.
   * A second one on the same day gets a numbered date folder.
   */
  private async freePath(
    kind: "originals" | "undone",
    sourcePath: string,
    relPath: string,
  ): Promise<string> {
    const date = new Date(this.now()).toISOString().slice(0, 10);
    for (let attempt = 1; ; attempt += 1) {
      const day = attempt === 1 ? date : `${date}-${String(attempt)}`;
      const path = join(kind, day, basename(sourcePath), ...relPath.split("/"));
      if (!(await exists(this.path(path))) && !(await exists(`${this.path(path)}.lobby.json`))) {
        return path;
      }
    }
  }

  private async replace(
    job: JobRow,
    asset: AssetInfo,
    kind: ConversionKind,
    doneBy: string,
    proof: Proof,
  ): Promise<void> {
    if (!this.journal) return;
    const originalPath = join(asset.sourcePath, asset.relPath);
    const stem = asset.relPath.slice(0, asset.relPath.length - extname(asset.relPath).length);
    const newRelPath = `${stem}.mp4`;
    const staged = this.staged(job.id);
    const keptPath = await this.freePath("originals", asset.sourcePath, asset.relPath);
    const stagedInfo = await stat(staged);
    await syncFile(staged);

    const operation: Operation<OperationData> = {
      id: randomUUID(),
      kind: "replace",
      moves: [
        { from: originalPath, to: this.path(keptPath), size: job.original_size },
        { from: staged, to: join(asset.sourcePath, newRelPath), size: stagedInfo.size },
      ],
      data: {
        type: "replace",
        jobId: job.id,
        assetId: asset.id,
        itemId: asset.itemId,
        sourceId: asset.sourceId,
        originalRelPath: asset.relPath,
        newRelPath,
        keptPath,
        original: {
          size: job.original_size,
          mtimeMs: job.original_mtime_ms,
          fingerprint: job.original_fingerprint,
        },
        newSize: stagedInfo.size,
        newMtimeMs: Math.round(stagedInfo.mtimeMs),
        kind,
        doneBy,
        proof,
        at: this.now(),
      },
    };
    try {
      await this.journal.run(operation);
    } catch (error) {
      log.error("A replacement was interrupted", { job: job.id, error: errorMessage(error) });
      // Whatever happened, the journal knows: finish it or take it back now if the drive allows.
      const recovered = await this.recover();
      const after = this.store.job(job.id);
      if (after?.state === "verifying") {
        this.store.update(job.id, {
          state: recovered ? "failed" : "uploaded",
          reason: recovered
            ? "The file could not be put in place. Nothing was changed."
            : "The drive was disconnected while the file was being put in place.",
        });
      }
      return;
    }
    await this.options.onReplaced?.();
  }

  private async commit(operation: Operation<OperationData>): Promise<void> {
    const { data } = operation;
    const { db } = this.store;
    if (data.type === "replace") {
      await writeManifest(`${this.path(data.keptPath)}.lobby.json`, {
        replacement: operation.id,
        whatThisIs:
          "The original of a file Lobby converted. Lobby's undo puts it back where it was.",
        originalPath: join(this.store.sourcePath(data.sourceId) ?? "", data.originalRelPath),
        replacedBy: join(this.store.sourcePath(data.sourceId) ?? "", data.newRelPath),
        original: data.original,
        newSize: data.newSize,
        kind: data.kind,
        convertedBy: data.doneBy,
        replacedAt: new Date(data.at).toISOString(),
        proof: data.proof.checks,
      });
      db.transaction(() => {
        // The scanner may have met the new file first, as a stranger. The old row is the title's.
        const stranger = db.get<{ id: string }>(
          "select id from asset where source_id = ? and rel_path = ? and id != ?",
          [data.sourceId, data.newRelPath, data.assetId],
        );
        if (stranger) this.options.catalogue.removeAsset(stranger.id);
        db.run(
          `update asset set rel_path = ?, size = ?, mtime_ms = ?, revision = ?, state = 'discovered',
             fingerprint = null, failure = null, attempts = 0, next_attempt_at = null, available = 1,
             missing_since = null, updated_at = ? where id = ?`,
          [
            data.newRelPath,
            data.newSize,
            data.newMtimeMs,
            revisionOf(data.newSize, data.newMtimeMs),
            this.now(),
            data.assetId,
          ],
        );
        this.options.catalogue.touchAsset(data.assetId);
        db.run(
          `insert or ignore into conversion_replacement (id, job_id, asset_id, item_id, source_id,
             original_rel_path, new_rel_path, kept_path, original_size, original_mtime_ms,
             original_fingerprint, new_size, new_mtime_ms, state, replaced_at)
           values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'replaced', ?)`,
          [
            operation.id,
            data.jobId,
            data.assetId,
            data.itemId,
            data.sourceId,
            data.originalRelPath,
            data.newRelPath,
            data.keptPath,
            data.original.size,
            data.original.mtimeMs,
            data.original.fingerprint,
            data.newSize,
            data.newMtimeMs,
            data.at,
          ],
        );
        this.store.update(data.jobId, {
          state: "done",
          progress: 1,
          reason: null,
          done_by: data.doneBy,
          lease_expires_at: null,
          proof_json: JSON.stringify(data.proof),
        });
      });
      this.options.onConverted?.(data.jobId, data.assetId, data.original.size - data.newSize);
      log.info("A converted file took its original's place", {
        job: data.jobId,
        asset: data.assetId,
        kind: data.kind,
        by: data.doneBy,
      });
      return;
    }

    const replacement = this.store.replacement(data.replacementId);
    if (!replacement) return;
    db.transaction(() => {
      db.run(
        `update asset set rel_path = ?, size = ?, mtime_ms = ?, revision = ?, state = 'discovered',
           fingerprint = null, failure = null, attempts = 0, next_attempt_at = null, available = 1,
           missing_since = null, updated_at = ? where id = ?`,
        [
          replacement.original_rel_path,
          replacement.original_size,
          replacement.original_mtime_ms,
          revisionOf(replacement.original_size, replacement.original_mtime_ms),
          this.now(),
          replacement.asset_id,
        ],
      );
      this.options.catalogue.touchAsset(replacement.asset_id);
      db.run(
        "update conversion_replacement set state = 'undone', set_aside_path = ?, undone_at = ? where id = ? and state = 'replaced'",
        [data.setAsidePath, data.at, replacement.id],
      );
    });
    await rm(`${this.path(replacement.kept_path)}.lobby.json`, { force: true });
    log.info("A replacement was undone", { replacement: replacement.id });
  }

  private abandon(operation: Operation<OperationData>, reason: string): void {
    if (operation.data.type !== "replace") return;
    this.store.update(operation.data.jobId, {
      state: "failed",
      reason: `The replacement was interrupted and taken back. ${reason}`,
    });
  }

  // ---- What was replaced ----

  replacements(limit = 500): Replacement[] {
    return this.store.replacements(limit).map(toReplacement);
  }

  private requireReplacement(id: string): ReplacementRow {
    const row = this.store.replacement(id);
    if (!row) throw new ConversionError("not_found", "There is no such replacement.");
    return row;
  }

  private async requireDrive(): Promise<Journal<OperationData>> {
    this.requireEnabled();
    if (!this.journal || !(await this.recover())) {
      throw new ConversionError("unavailable", "The drive Lobby's folder is on is not connected.");
    }
    if (this.attention.length > 0) {
      throw new ConversionError(
        "conflict",
        "An earlier replacement was interrupted and has to be looked at first.",
      );
    }
    return this.journal;
  }

  /**
   * Puts the original back where it was. The converted file is not deleted: it is
   * set aside in Lobby's folder.
   */
  async undo(replacementId: string): Promise<Replacement> {
    const journal = await this.requireDrive();
    const row = this.requireReplacement(replacementId);
    if (row.state !== "replaced") {
      throw new ConversionError(
        "conflict",
        row.state === "undone"
          ? "This replacement was undone already."
          : "The original was deleted for good and cannot come back.",
      );
    }
    const source = this.store.sourcePath(row.source_id);
    if (!source) throw new ConversionError("gone", "The library folder is no longer configured.");
    if (this.inUse(row.asset_id)) {
      throw new ConversionError("conflict", "Someone is watching this title. Try again later.");
    }
    const newPath = join(source, row.new_rel_path);
    const originalPath = join(source, row.original_rel_path);
    const kept = this.path(row.kept_path);
    const [now, keptInfo] = await Promise.all([
      stat(newPath).catch(() => null),
      stat(kept).catch(() => null),
    ]);
    if (!keptInfo || keptInfo.size !== row.original_size) {
      throw new ConversionError("gone", "The original is no longer in Lobby's folder.");
    }
    if (!now || now.size !== row.new_size || Math.round(now.mtimeMs) !== row.new_mtime_ms) {
      throw new ConversionError(
        "conflict",
        "The converted file was changed or moved since. Lobby leaves it alone.",
      );
    }
    if (originalPath !== newPath && (await exists(originalPath))) {
      throw new ConversionError("conflict", "There is a file again where the original was.");
    }
    const setAside = await this.freePath("undone", source, row.new_rel_path);
    await journal.run({
      id: randomUUID(),
      kind: "undo",
      moves: [
        { from: newPath, to: this.path(setAside), size: row.new_size },
        { from: kept, to: originalPath, size: row.original_size },
      ],
      data: { type: "undo", replacementId: row.id, setAsidePath: setAside, at: this.now() },
    });
    await this.options.onReplaced?.();
    return toReplacement(this.requireReplacement(replacementId));
  }

  /**
   * Refuses unless the film itself is in the library, whole: the copy in Lobby's folder
   * may be the last one there is. Follows a file that was moved since.
   */
  private async requireOtherCopy(row: ReplacementRow): Promise<void> {
    const file = this.store.db.get<{ source: string; rel: string }>(
      `select source.path as source, asset.rel_path as rel from asset
       join source on source.id = asset.source_id where asset.id = ?`,
      [row.asset_id],
    );
    const expected = row.state === "replaced" ? row.new_size : row.original_size;
    const info = file ? await stat(join(file.source, file.rel)).catch(() => null) : null;
    if (!info?.isFile() || info.size !== expected) {
      throw new ConversionError(
        "conflict",
        "The film in the library is missing or has changed, so this copy is kept.",
      );
    }
  }

  /**
   * Deletes for good what Lobby keeps for a replacement: the original, or after an
   * undo the converted file that was set aside. Only ever on a person's explicit word.
   */
  async purge(replacementId: string): Promise<Replacement> {
    await this.requireDrive();
    const row = this.requireReplacement(replacementId);
    if (row.state === "purged") {
      throw new ConversionError("conflict", "This was deleted already.");
    }
    const kept = row.state === "replaced" ? row.kept_path : row.set_aside_path;
    // Checked to lie inside Lobby's own folder: nothing else is ever deleted.
    const path = kept === null ? null : this.path(kept);
    if (path !== null && !path.startsWith(this.path() + sep)) {
      throw new ConversionError("conflict", "That file is not in Lobby's folder.");
    }
    if (path !== null) {
      await this.requireOtherCopy(row);
      await rm(path, { force: true });
      await rm(`${path}.lobby.json`, { force: true });
      await syncDir(dirname(path)).catch(() => undefined);
    }
    this.store.db.run(
      "update conversion_replacement set state = 'purged', purged_at = ? where id = ?",
      [this.now(), row.id],
    );
    log.info("A kept file was deleted for good on a manager's word", { replacement: row.id });
    return toReplacement(this.requireReplacement(replacementId));
  }
}
