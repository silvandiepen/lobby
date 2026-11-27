// SPDX-License-Identifier: MPL-2.0
import { spawn, type ChildProcess } from "node:child_process";
import { readFile, rename, rm, stat } from "node:fs/promises";
import { setPriority } from "node:os";
import { basename, join } from "node:path";
import { createInterface } from "node:readline";
import { BusyError, Gate } from "../gate.ts";
import { errorMessage, log, wholeLines, withoutPaths } from "../log.ts";
import { preparedFileType, PreparedCache } from "./cache.ts";
import {
  audioRenditionFiles,
  ffmpegArguments,
  MEDIA_FILE,
  planPreparation,
  STREAM_PLAYLIST,
  TEXT_SUBTITLE_CODECS,
  type PlannedAudio,
  type PreparationPlan,
  type SubtitleOutput,
} from "./plan.ts";
import { readStreamPlaylist } from "./playlist.ts";
import { PICTURE_SUBTITLE_CODECS, writePictureSubtitles } from "./pictures.ts";
import { convertSubtitle } from "./subtitles.ts";
import type {
  PlaybackAsset,
  PlaybackSubtitle,
  Preparation,
  PreparationState,
  PreparedAudio,
} from "./types.ts";

export interface PlaybackServiceOptions {
  /** A folder Lobby owns completely. Never inside a library folder. */
  cacheDir: string;
  /** Default 20 GB. */
  maxCacheBytes?: number;
  /** Space to leave free on the cache's volume. Default 2 GB. */
  minFreeBytes?: number;
  /** How many files are prepared at once. Default 2. The rest wait in a queue. */
  maxConcurrent?: number;
  /**
   * How many of those may convert video at the same time. Default 1: one conversion
   * uses every core of a Pi, and two would both fall behind playback.
   */
  maxConversions?: number;
  /** How many files may wait to be prepared for someone. Default 200, a long series. */
  maxQueued?: number;
  ffmpegPath?: string;
  /** Unix niceness for ffmpeg, so playback of other files and the rest of the Pi come first. */
  niceness?: number;
  /** Niceness for a copy prepared ahead of need (`prepare` with `background`). Default 19, the lowest. */
  backgroundNiceness?: number;
  /**
   * Niceness for an ffmpeg that converts video. Default 5 above `niceness` (at most 19),
   * so repackaging another file, which a viewer is also waiting for, is not held up by it.
   */
  conversionNiceness?: number;
  now?: () => number;
  /** For the statistics: a copy is ready, and what it took. */
  onPrepared?: (event: {
    assetId: string;
    elapsedMs: number;
    bytes: number;
    converted: boolean;
    background: boolean;
  }) => void;
}

export type PlaybackErrorCode =
  "unsupported" | "unsupported_subtitle" | "not_found" | "unavailable" | "busy";

/** A refusal with a sentence that can be shown to the viewer as it is. */
export class PlaybackError extends Error {
  readonly code: PlaybackErrorCode;

  constructor(code: PlaybackErrorCode, message: string) {
    super(message);
    this.code = code;
  }
}

export interface ResolvedFile {
  path: string;
  contentType: string;
  /** False while ffmpeg is still appending to the file. */
  complete: boolean;
}

interface Job {
  asset: PlaybackAsset;
  plan: PreparationPlan;
  state: "queued" | "preparing" | "failed";
  /** How far ffmpeg has written, in media time. */
  outTimeMs: number;
  /** When the running ffmpeg started, on the `performance.now()` clock. */
  startedAt: number | null;
  /** From where `speed` is measured: the start, or the moment a background job became an ordinary one. */
  measuredFrom: { at: number; preparedMs: number } | null;
  /** How much the playlist listed when it was last read. */
  lastPreparedMs: number;
  streamable: boolean;
  error: string | null;
  child: ChildProcess | null;
  cancelled: boolean;
  /**
   * True for a copy nobody is waiting for yet. It runs alone, at the lowest priority,
   * outside the limit on preparations, and stands still while anything else is prepared
   * or the service is told that someone is watching.
   */
  background: boolean;
  /** Whether the job is counted in `running` and `converting` (a background job is not). */
  counted: boolean;
  /** True while its ffmpeg is stopped with SIGSTOP. */
  stopped: boolean;
  /** Ids of the subtitles this run writes as WebVTT. */
  subtitleIds: Set<string>;
  /** Settles when the job has finished, failed or been cancelled. Never rejects. */
  done: Promise<void>;
  finish: () => void;
}

const GB = 1024 * 1024 * 1024;
/**
 * A stream is offered once this much of the film is written. AVPlayer treats a
 * playlist that is still growing like a broadcast and waits for a buffer before
 * its first frame: offered with 19 s written, it took 19 s to start on the Pi;
 * offered with 37 s, 1.6 s (docs/playback.md).
 */
const MIN_STREAM_MS = 30_000;
const MAX_SUBTITLES_WAITING = 50;
const FAILED_MESSAGE = "This file could not be prepared for playback.";
/**
 * A converted copy is reserved at this multiple of the original's size. On the
 * Pi the copies came out at 0.5 to 1.1 times the original (docs/playback.md).
 */
const CONVERTED_SIZE_RATIO = 1.5;

/**
 * Whether a viewer who starts the film now, from the beginning, stays behind what
 * is written until the end. Copying video is always far faster than playback.
 * Converting it can be slower on a busy Pi, and then the stream is held back
 * until the head start is large enough, instead of stalling halfway.
 *
 * `speed` is how many seconds of film are written per second.
 */
export function staysAhead(preparedMs: number, durationMs: number | null, speed: number): boolean {
  if (preparedMs < MIN_STREAM_MS) return false;
  // The measured speed wobbles from scene to scene: count on nine tenths of it.
  const safe = speed * 0.9;
  if (safe >= 1) return true;
  if (durationMs === null || safe <= 0) return false;
  // Until the copy is finished the viewer gains on it.
  const finishedInMs = Math.max(0, durationMs - preparedMs) / safe;
  return preparedMs - (1 - safe) * finishedInMs >= MIN_STREAM_MS;
}

/**
 * Prepares files Apple's player cannot open into a fragmented MP4 with an HLS
 * playlist. MKV files (and MP4 with DTS sound) are repackaged without touching
 * the video. Old AVI films in MPEG-4 Part 2 get their video converted to H.264.
 *
 * One ffmpeg pass writes `media.mp4` and `index.m3u8` into the cache. The playlist
 * grows while ffmpeg runs, so playback can start after a few seconds; when ffmpeg
 * is done the same `media.mp4` is the file a device downloads for offline use.
 * A file with several sound tracks also gets each further track as its own
 * `audio-N.mp4` and playlist, so the stream can switch to it.
 */
export class PlaybackService {
  private readonly cache: PreparedCache;
  private readonly ffmpegPath: string;
  private readonly maxConcurrent: number;
  private readonly maxConversions: number;
  private readonly maxQueued: number;
  private readonly niceness: number;
  private readonly conversionNiceness: number;
  private readonly jobs = new Map<string, Job>();
  private readonly queue: Job[] = [];
  private readonly conversions = new Map<string, Promise<void>>();
  /** Reading a subtitle out of a film reads the whole film: one at a time. */
  private readonly embeddedSubtitles = new Gate(1, MAX_SUBTITLES_WAITING);
  private readonly sidecarSubtitles = new Gate(4, MAX_SUBTITLES_WAITING);
  private running = 0;
  private converting = 0;
  private backgroundJob: Job | null = null;
  private held = false;
  private guarded: ReadonlySet<string> = new Set();
  private readonly backgroundNiceness: number;
  private closed = false;
  private readonly onPrepared: PlaybackServiceOptions["onPrepared"];

  constructor(options: PlaybackServiceOptions) {
    this.onPrepared = options.onPrepared;
    this.cache = new PreparedCache({
      dir: options.cacheDir,
      maxBytes: options.maxCacheBytes ?? 20 * GB,
      minFreeBytes: options.minFreeBytes ?? 2 * GB,
      now: options.now ?? Date.now,
    });
    this.ffmpegPath = options.ffmpegPath ?? "ffmpeg";
    this.maxConcurrent = Math.max(1, options.maxConcurrent ?? 2);
    this.maxConversions = Math.max(1, options.maxConversions ?? 1);
    this.maxQueued = options.maxQueued ?? 200;
    this.niceness = options.niceness ?? 10;
    this.conversionNiceness = options.conversionNiceness ?? Math.min(19, this.niceness + 5);
    this.backgroundNiceness = options.backgroundNiceness ?? 19;
  }

  /** Call once before use. Deletes what a crash left half-written and reads the cache. */
  async start(): Promise<void> {
    await this.cache.open();
  }

  /** Stops every running ffmpeg and deletes its unfinished output. */
  async close(): Promise<void> {
    this.closed = true;
    await Promise.all([...this.jobs.values()].map((job) => this.cancel(job)));
  }

  /** Bytes the prepared copies take, including the expected size of copies in progress. */
  cacheBytes(): number {
    return this.cache.totalBytes();
  }

  /**
   * Starts repackaging an asset, or reports on the copy that exists or is being made.
   * A copy of another revision is deleted, and a failed attempt is started again.
   *
   * With `background` the copy is prepared ahead of need: one at a time, at the lowest
   * priority, standing still while anyone else is served, and without evicting anything
   * that is in use or waited for. Asking again without `background` (someone wants to
   * watch it now) turns such a job into an ordinary one.
   */
  async prepare(
    asset: PlaybackAsset,
    options: { background?: boolean } = {},
  ): Promise<Preparation> {
    if (this.closed) throw new Error("The playback service is closed.");
    const planned = planPreparation(asset);
    if (!planned.ok) throw new PlaybackError("unsupported", planned.reason);
    const background = options.background === true;

    const existing = await this.status(asset);
    if (existing && existing.state !== "failed") {
      const current = this.jobs.get(asset.id);
      if (current?.background && !background) {
        if (current.state === "queued") this.requireRoom();
        this.promote(current);
        return this.describe(current);
      }
      return existing;
    }
    if (!asset.available) {
      throw new PlaybackError(
        "unavailable",
        "The drive this file is on is not connected right now.",
      );
    }

    if (!background) this.requireRoom();
    const stale = this.jobs.get(asset.id);
    if (stale) await this.cancel(stale);

    let finish = (): void => undefined;
    const done = new Promise<void>((resolve) => {
      finish = resolve;
    });
    const job: Job = {
      asset,
      plan: planned.plan,
      state: "queued",
      outTimeMs: 0,
      startedAt: null,
      measuredFrom: null,
      lastPreparedMs: 0,
      streamable: false,
      error: null,
      child: null,
      cancelled: false,
      background,
      counted: false,
      stopped: false,
      subtitleIds: new Set(),
      done,
      finish,
    };
    this.jobs.set(asset.id, job);
    this.queue.push(job);
    this.pump();
    return this.describe(job);
  }

  private requireRoom(): void {
    if (this.queue.filter((job) => !job.background).length < this.maxQueued) return;
    throw new PlaybackError("busy", "The server is preparing a lot right now. Try again later.");
  }

  /**
   * Tells the service that someone is watching or downloading right now (true) or
   * that the house is quiet (false). While held, a copy prepared ahead stands still.
   */
  holdBackground(held: boolean): void {
    if (this.held === held) return;
    this.held = held;
    this.pump();
  }

  /**
   * The assets whose copies a device still has to fetch. They are the last to be
   * evicted, and never for another copy prepared ahead.
   */
  guard(assetIds: ReadonlySet<string>): void {
    this.guarded = assetIds;
  }

  /** Stops a preparation that was started ahead of need and is still only that. */
  async cancelBackground(assetId: string): Promise<void> {
    const job = this.jobs.get(assetId);
    if (job?.background) await this.cancel(job);
  }

  /**
   * What exists for an asset, without touching the file system, counting as use, or
   * starting anything. Null when there is neither a copy nor a job for this revision.
   */
  peek(
    assetId: string,
    revision: string,
  ): {
    state: PreparationState;
    background: boolean;
    progress: number;
    bytes: number | null;
  } | null {
    const ready = this.cache.ready(assetId, revision);
    if (ready) return { state: "ready", background: false, progress: 1, bytes: ready.mediaBytes };
    const job = this.jobs.get(assetId);
    if (job?.asset.revision !== revision) return null;
    const duration = job.asset.durationMs;
    return {
      state: job.state,
      background: job.background,
      progress: duration !== null && duration > 0 ? Math.min(0.99, job.outTimeMs / duration) : 0,
      bytes: null,
    };
  }

  /**
   * Whether a copy prepared ahead of need would fit right now, by the rules such a copy
   * has to keep (see `ReservePolicy`). `too_large`: larger than the whole cache.
   * `disk_full`: no room without taking something that is in use or waited for.
   */
  async roomAhead(asset: PlaybackAsset): Promise<"ok" | "too_large" | "disk_full"> {
    const planned = planPreparation(asset);
    const room = await this.cache.room(
      asset.id,
      expectedBytes(asset, planned.ok && planned.plan.videoConverted),
      { busy: new Set(this.jobs.keys()), guarded: this.guarded, background: true },
    );
    return room.ok ? "ok" : room.reason;
  }

  private promote(job: Job): void {
    job.background = false;
    if (this.backgroundJob === job) {
      // It keeps running, now as one of the ordinary preparations.
      this.backgroundJob = null;
      this.count(job, 1);
      // It may have stood still for a long time: its speed counts from now.
      job.measuredFrom = { at: performance.now(), preparedMs: job.lastPreparedMs };
      if (job.stopped) job.child?.kill("SIGCONT");
      job.stopped = false;
      if (job.child?.pid !== undefined) {
        this.setNiceness(
          job.child.pid,
          job.plan.videoConverted ? this.conversionNiceness : this.niceness,
        );
      }
    }
    this.pump();
  }

  private count(job: Job, by: 1 | -1): void {
    if (by === 1 && job.counted) return;
    if (by === -1 && !job.counted) return;
    job.counted = by === 1;
    this.running += by;
    if (job.plan.videoConverted) this.converting += by;
  }

  private setNiceness(pid: number, niceness: number): void {
    try {
      setPriority(pid, niceness);
    } catch (error) {
      // The process can be gone already; a priority is not worth failing for.
      log.warn("Could not change ffmpeg's priority", { error: errorMessage(error) });
    }
  }

  /** Stops or continues the ffmpeg of the copy prepared ahead, as the rest of the work asks. */
  private yieldBackground(): void {
    const job = this.backgroundJob;
    if (!job?.child) return;
    const shouldStop =
      this.held || this.running > 0 || this.queue.some((queued) => !queued.background);
    if (shouldStop === job.stopped) return;
    job.stopped = shouldStop;
    job.child.kill(shouldStop ? "SIGSTOP" : "SIGCONT");
  }

  /** The state of an asset's copy without starting anything. Null when there is none. */
  async status(asset: PlaybackAsset): Promise<Preparation | null> {
    const ready = this.cache.ready(asset.id, asset.revision);
    if (ready) {
      this.cache.touch(asset.id);
      return {
        assetId: asset.id,
        revision: asset.revision,
        state: "ready",
        progress: 1,
        preparedMs: ready.durationMs ?? asset.durationMs ?? 0,
        durationMs: ready.durationMs ?? asset.durationMs,
        streamable: true,
        videoConverted: ready.videoConverted,
        speed: null,
        sizeBytes: ready.mediaBytes,
        audio: ready.audio,
        error: null,
      };
    }
    const job = this.jobs.get(asset.id);
    if (job?.asset.revision !== asset.revision) return null;
    return this.describe(job);
  }

  private async describe(job: Job): Promise<Preparation> {
    const { asset } = job;
    let preparedMs = 0;
    let sizeBytes = 0;
    const from = job.measuredFrom;
    const elapsedMs = from === null ? 0 : performance.now() - from.at;
    let speed: number | null = null;
    if (job.state === "preparing") {
      const dir = this.cache.entryDir(asset.id);
      try {
        const playlist = readStreamPlaylist(await readFile(join(dir, STREAM_PLAYLIST), "utf8"));
        preparedMs = playlist.durationMs;
        // Measured on what a player can fetch: ffmpeg's own progress report runs behind it.
        job.lastPreparedMs = preparedMs;
        if (from !== null && elapsedMs > 0) speed = (preparedMs - from.preparedMs) / elapsedMs;
        // Once offered it stays offered: a player may be on it already.
        job.streamable ||=
          playlist.ended || staysAhead(playlist.durationMs, asset.durationMs, speed ?? 0);
        sizeBytes = (await stat(join(dir, MEDIA_FILE))).size;
      } catch (error) {
        // ffmpeg has not written its first segment yet.
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      }
    }
    const duration = asset.durationMs;
    return {
      assetId: asset.id,
      revision: asset.revision,
      state: job.state,
      progress: duration !== null && duration > 0 ? Math.min(0.99, job.outTimeMs / duration) : 0,
      preparedMs,
      durationMs: duration,
      streamable: job.state === "preparing" && job.streamable,
      videoConverted: job.plan.videoConverted,
      speed: job.state === "preparing" && speed !== null ? Math.round(speed * 10) / 10 : null,
      sizeBytes,
      audio: job.plan.audio.map(preparedAudio),
      error: job.error,
    };
  }

  /**
   * The path of one of a copy's files, for the given revision only. `name` is
   * matched against the fixed pattern of prepared file names, so no other request
   * text ever becomes part of a path.
   */
  resolveFile(assetId: string, revision: string, name: string): ResolvedFile | null {
    const contentType = preparedFileType(name);
    if (contentType === null) return null;
    const entry = this.cache.entry(assetId);
    if (entry?.revision !== revision) return null;
    if (!entry.complete && this.jobs.get(assetId)?.state !== "preparing") return null;
    this.cache.touch(assetId);
    return {
      path: join(this.cache.entryDir(assetId), name),
      contentType,
      complete: entry.complete,
    };
  }

  /**
   * The WebVTT file for one of an asset's text subtitles, converting it first
   * when needed. Works for any asset, also one that plays directly.
   */
  async subtitle(asset: PlaybackAsset, subtitleId: string): Promise<string> {
    return this.convertedSubtitle(asset, subtitleId, "text");
  }

  /**
   * The cues of one of an asset's picture subtitles (PGS, DVD, DVB) as placed PNGs in JSON,
   * read from the file first when needed (docs/decisions.md, "Subtitles per viewer"). The app draws them over the picture.
   */
  async pictureSubtitle(asset: PlaybackAsset, subtitleId: string): Promise<string> {
    return this.convertedSubtitle(asset, subtitleId, "pictures");
  }

  private async convertedSubtitle(
    asset: PlaybackAsset,
    subtitleId: string,
    kind: "text" | "pictures",
  ): Promise<string> {
    const subtitle = asset.subtitles.find((candidate) => candidate.id === subtitleId);
    if (!subtitle) throw new PlaybackError("not_found", "This file has no such subtitle track.");
    if (kind === "text" && !TEXT_SUBTITLE_CODECS.has(subtitle.codec)) {
      throw new PlaybackError(
        "unsupported_subtitle",
        `This subtitle track is stored as pictures (${subtitle.codec}): ask for its pictures.`,
      );
    }
    if (kind === "pictures" && !PICTURE_SUBTITLE_CODECS.has(subtitle.codec)) {
      throw new PlaybackError(
        "unsupported_subtitle",
        `This subtitle track is not stored as pictures (${subtitle.codec}).`,
      );
    }
    // A subtitle converted earlier is served even while the drive is away.
    const path = await this.subtitleCachePath(asset, subtitle, kind === "text" ? "vtt" : "json");
    if (await exists(path)) return path;
    if (!asset.available) {
      throw new PlaybackError(
        "unavailable",
        "The drive this file is on is not connected right now.",
      );
    }

    // A running preparation writes the embedded text subtitles in the same pass over the file.
    const job = this.jobs.get(asset.id);
    if (
      kind === "text" &&
      job?.asset.revision === asset.revision &&
      job.subtitleIds.has(subtitle.id)
    ) {
      await job.done;
      if (await exists(path)) return path;
    }

    let conversion = this.conversions.get(path);
    if (!conversion) {
      const { source } = subtitle;
      const input =
        source.kind === "sidecar"
          ? ({ kind: "sidecar", path: source.path } as const)
          : ({ kind: "embedded", path: asset.path, streamIndex: source.streamIndex } as const);
      const convert = (): Promise<void> =>
        kind === "text"
          ? convertSubtitle(input, path, this.ffmpegPath)
          : writePictureSubtitles(input, path, {
              ffmpegPath: this.ffmpegPath,
              durationMs: asset.durationMs,
            });
      if (source.kind === "sidecar") {
        conversion = this.sidecarSubtitles.run(convert);
      } else {
        conversion = this.embeddedSubtitles.run(convert);
      }
      conversion = conversion.finally(() => this.conversions.delete(path));
      this.conversions.set(path, conversion);
    }
    try {
      await conversion;
    } catch (error) {
      if (error instanceof BusyError) {
        throw new PlaybackError("busy", "The server is busy with other subtitles. Try again.");
      }
      log.warn("A subtitle could not be converted", {
        asset: asset.id,
        subtitle: subtitle.id,
        error: this.redact(errorMessage(error), asset, subtitle),
      });
      throw new PlaybackError("unsupported_subtitle", "This subtitle track could not be read.");
    }
    return path;
  }

  /**
   * The text subtitles that can go into the stream's master playlist right now:
   * sidecar files (converted here, which is quick) and embedded tracks that were
   * already written out. An embedded track is not converted for this, because
   * that would hold up the start of playback by a read of the whole file.
   */
  async streamSubtitles(asset: PlaybackAsset): Promise<PlaybackSubtitle[]> {
    const result: PlaybackSubtitle[] = [];
    for (const subtitle of asset.subtitles) {
      if (!TEXT_SUBTITLE_CODECS.has(subtitle.codec)) continue;
      if (subtitle.source.kind === "sidecar") {
        try {
          await this.subtitle(asset, subtitle.id);
          result.push(subtitle);
        } catch (error) {
          if (!(error instanceof PlaybackError)) throw error;
        }
      } else if (await exists(await this.subtitleCachePath(asset, subtitle))) {
        result.push(subtitle);
      }
    }
    return result;
  }

  private async subtitleCachePath(
    asset: PlaybackAsset,
    subtitle: PlaybackSubtitle,
    extension: "vtt" | "json" = "vtt",
  ): Promise<string> {
    let variant = "";
    if (subtitle.source.kind === "sidecar") {
      try {
        const info = await stat(subtitle.source.path);
        variant = `${info.size}-${info.mtimeMs}`;
      } catch {
        throw new PlaybackError("not_found", "This subtitle file is no longer in the library.");
      }
    }
    return this.cache.subtitlePath(asset.id, asset.revision, subtitle.id, variant, extension);
  }

  private pump(): void {
    while (!this.closed && this.running < this.maxConcurrent) {
      // A conversion waits for the one that is running; files that are only repackaged pass it.
      const next = this.queue.findIndex(
        (queued) =>
          !queued.background &&
          (!queued.plan.videoConverted || this.converting < this.maxConversions),
      );
      const job = next < 0 ? undefined : this.queue.splice(next, 1)[0];
      if (!job) break;
      this.count(job, 1);
      this.launch(job);
    }

    // A copy prepared ahead starts only when nothing else is running, waiting or watched.
    if (
      !this.closed &&
      this.backgroundJob === null &&
      !this.held &&
      this.running === 0 &&
      !this.queue.some((queued) => !queued.background)
    ) {
      const job = this.queue.shift();
      if (job) {
        this.backgroundJob = job;
        this.launch(job);
      }
    }
    this.yieldBackground();
  }

  private launch(job: Job): void {
    void this.run(job)
      .catch((error: unknown) => {
        this.fail(job, errorMessage(error));
      })
      .finally(() => {
        this.count(job, -1);
        if (this.backgroundJob === job) this.backgroundJob = null;
        job.finish();
        this.pump();
      });
  }

  private fail(job: Job, detail: string): void {
    if (job.cancelled) return;
    job.state = "failed";
    job.error ??= FAILED_MESSAGE;
    log.warn("A file could not be prepared for playback", {
      asset: job.asset.id,
      error: this.redact(detail, job.asset),
    });
  }

  /** ffmpeg's messages name the file it reads. Household file names stay out of the log. */
  private redact(text: string, asset: PlaybackAsset, subtitle?: PlaybackSubtitle): string {
    let result = wholeLines(text)
      .replaceAll(asset.path, "<source>")
      .replaceAll(basename(asset.path), "<source>");
    if (subtitle?.source.kind === "sidecar") {
      result = result
        .replaceAll(subtitle.source.path, "<subtitle>")
        .replaceAll(basename(subtitle.source.path), "<subtitle>");
    }
    return withoutPaths(result).slice(-600);
  }

  private async run(job: Job): Promise<void> {
    if (wasCancelled(job)) return;
    const { asset, plan } = job;
    job.state = "preparing";

    const reservation = await this.cache.reserve(
      asset,
      expectedBytes(asset, plan.videoConverted),
      plan.audio.map(preparedAudio),
      { busy: new Set(this.jobs.keys()), guarded: this.guarded, background: job.background },
      plan.videoConverted,
    );
    if (!reservation.ok) {
      job.error =
        reservation.reason === "too_large"
          ? "This file is larger than the space set aside for prepared copies."
          : "There is not enough free space on the server to prepare this file.";
      this.fail(job, reservation.reason);
      return;
    }
    const dir = reservation.dir;

    const embedded = asset.subtitles.filter(
      (subtitle) => subtitle.source.kind === "embedded" && TEXT_SUBTITLE_CODECS.has(subtitle.codec),
    );
    const outputs: { subtitle: PlaybackSubtitle; output: SubtitleOutput; finalPath: string }[] = [];
    for (const subtitle of embedded) {
      if (subtitle.source.kind !== "embedded") continue;
      const finalPath = await this.subtitleCachePath(asset, subtitle);
      outputs.push({
        subtitle,
        finalPath,
        output: { streamIndex: subtitle.source.streamIndex, path: `${finalPath}.partial` },
      });
    }

    const playlists = [
      STREAM_PLAYLIST,
      ...plan.audio.slice(1).map((_, index) => audioRenditionFiles(index + 1).playlist),
    ].map((name) => join(dir, name));
    job.subtitleIds = new Set(outputs.map((entry) => entry.subtitle.id));
    let result = await this.runFfmpeg(
      job,
      ffmpegArguments(
        asset.path,
        plan,
        dir,
        outputs.map((entry) => entry.output),
      ),
    );
    if (result.code !== 0 && !wasCancelled(job) && outputs.length > 0) {
      // A subtitle track ffmpeg cannot convert must not cost the family the film:
      // the copy is made again without the subtitles, which then report their own error.
      log.warn("Preparing again without the embedded subtitles", {
        asset: asset.id,
        error: this.redact(result.stderr, asset),
      });
      for (const entry of outputs) await rm(entry.output.path, { force: true });
      await this.cache.clear(asset.id);
      job.subtitleIds = new Set();
      job.outTimeMs = 0;
      job.streamable = false;
      outputs.length = 0;
      result = await this.runFfmpeg(job, ffmpegArguments(asset.path, plan, dir));
    }

    if (wasCancelled(job)) return;
    let finished = result.code === 0;
    for (const playlist of playlists) {
      // Every playlist must carry its end marker, or a player would wait for more.
      finished &&= readStreamPlaylist(await readFile(playlist, "utf8").catch(() => "")).ended;
    }
    if (!finished) {
      for (const entry of outputs) await rm(entry.output.path, { force: true });
      await this.cache.remove(asset.id);
      this.fail(job, result.stderr || `ffmpeg ended with code ${String(result.code)}`);
      return;
    }
    for (const entry of outputs) await rename(entry.output.path, entry.finalPath);
    const entry = await this.cache.complete(asset.id);
    this.jobs.delete(asset.id);
    try {
      this.onPrepared?.({
        assetId: asset.id,
        elapsedMs: result.elapsedMs,
        bytes: entry.sizeBytes,
        converted: plan.videoConverted,
        background: job.background,
      });
    } catch (error) {
      log.warn("Could not note a prepared copy", { error: errorMessage(error) });
    }
    log.info("Prepared a file for playback", {
      asset: asset.id,
      videoConverted: plan.videoConverted,
      bytes: entry.sizeBytes,
      seconds: Math.round(result.elapsedMs / 1000),
    });
  }

  private runFfmpeg(
    job: Job,
    args: string[],
  ): Promise<{ code: number | null; stderr: string; elapsedMs: number }> {
    return new Promise((resolve) => {
      const startedAt = performance.now();
      const child = spawn(this.ffmpegPath, args, { stdio: ["ignore", "pipe", "pipe"] });
      job.child = child;
      job.startedAt = startedAt;
      job.measuredFrom = { at: startedAt, preparedMs: 0 };
      job.lastPreparedMs = 0;
      job.stopped = false;
      let stderr = "";
      let settled = false;
      const settle = (code: number | null): void => {
        if (settled) return;
        settled = true;
        job.child = null;
        resolve({ code, stderr, elapsedMs: performance.now() - startedAt });
      };

      child.once("spawn", () => {
        if (child.pid === undefined) return;
        this.setNiceness(
          child.pid,
          job.background
            ? this.backgroundNiceness
            : job.plan.videoConverted
              ? this.conversionNiceness
              : this.niceness,
        );
        // Someone may have started watching between the decision to start and the start.
        this.yieldBackground();
      });
      // ffmpeg -progress writes key=value lines about twice a second.
      createInterface({ input: child.stdout }).on("line", (line) => {
        const match = /^out_time_us=(\d+)/.exec(line);
        if (match) job.outTimeMs = Math.round(Number(match[1]) / 1000);
      });
      child.stderr.setEncoding("utf8");
      child.stderr.on("data", (chunk: string) => {
        stderr = (stderr + chunk).slice(-4000);
      });
      child.once("error", (error) => {
        stderr += errorMessage(error);
        settle(null);
      });
      child.once("close", (code) => {
        settle(code);
      });
      if (job.cancelled) child.kill("SIGTERM");
    });
  }

  /** Stops a job, waits until its ffmpeg is gone and deletes what it wrote. */
  private async cancel(job: Job): Promise<void> {
    job.cancelled = true;
    const queued = this.queue.indexOf(job);
    if (queued >= 0) {
      this.queue.splice(queued, 1);
      job.finish();
    }
    const child = job.child;
    if (child) {
      // A stopped process does not see SIGTERM until it is continued.
      if (job.stopped) child.kill("SIGCONT");
      job.stopped = false;
      child.kill("SIGTERM");
      const forced = setTimeout(() => child.kill("SIGKILL"), 5000);
      await job.done;
      clearTimeout(forced);
    } else if (job.state === "preparing") {
      await job.done;
    }
    if (this.jobs.get(job.asset.id) === job) this.jobs.delete(job.asset.id);
    for (const subtitle of job.asset.subtitles) {
      if (!job.subtitleIds.has(subtitle.id)) continue;
      await rm(`${await this.subtitleCachePath(job.asset, subtitle)}.partial`, { force: true });
    }
    const entry = this.cache.entry(job.asset.id);
    if (entry && !entry.complete) await this.cache.remove(job.asset.id);
  }
}

/** Read through a function because a job is cancelled from outside while `run` is waiting. */
function wasCancelled(job: Job): boolean {
  return job.cancelled;
}

/** The room a copy is given before it is written. A repackaged file is about as large as the original. */
function expectedBytes(asset: PlaybackAsset, videoConverted: boolean): number {
  return videoConverted ? Math.ceil(asset.sizeBytes * CONVERTED_SIZE_RATIO) : asset.sizeBytes;
}

function preparedAudio(track: PlannedAudio): PreparedAudio {
  return {
    index: track.index,
    codec: track.codec,
    converted: track.converted,
    language: track.language,
    title: track.title,
    channels: track.channels,
    isDefault: track.isDefault,
  };
}

async function exists(path: string): Promise<boolean> {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}
