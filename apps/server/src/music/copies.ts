// SPDX-License-Identifier: MPL-2.0
import { spawn } from "node:child_process";
import { mkdir, readdir, rename, rm, stat, statfs, utimes } from "node:fs/promises";
import { setPriority } from "node:os";
import { join } from "node:path";
import { errorMessage, log } from "../log.ts";
import { SAFE_INPUT } from "./probe.ts";

export const COMPACT_KBPS = [256, 128] as const;
export type CompactKbps = (typeof COMPACT_KBPS)[number];

interface Sound {
  playability: "direct" | "convert";
  lossless: boolean;
  bitRate: number | null;
}

/** A file that is this small already is sent as it is: converting it would only lose quality. */
export function isCompactAlready(sound: Sound, kbps: CompactKbps): boolean {
  return (
    sound.playability === "direct" &&
    !sound.lossless &&
    sound.bitRate !== null &&
    sound.bitRate <= kbps * 1100
  );
}

export interface CopySource {
  id: string;
  revision: string;
  durationMs: number | null;
  sizeBytes: number;
  /** Finds the file, refusing when it cannot be opened (any more). */
  open: () => Promise<{ path: string; size: number }>;
}

export interface CopyStatus {
  state: "ready" | "preparing" | "queued" | "failed" | "does_not_fit" | "busy";
  /** 0 to 1. */
  progress: number;
  bytes: number | null;
}

export interface CopiesOptions {
  /** A folder Lobby owns completely. Everything in it can be deleted and made again. */
  dir: string;
  maxBytes: number;
  minFreeBytes: number;
  ffmpegPath: string;
  now?: () => number;
}

interface Entry {
  bytes: number;
  madeAt: number;
  lastUsedAt: number;
}

interface Job {
  name: string;
  source: CopySource;
  kbps: CompactKbps;
  urgent: boolean;
  progress: number;
}

const NAME = /^[0-9a-f-]{36}\.[0-9a-f]{16}\.(?:256|128)\.m4a$/;
/** A copy used this recently is being played or downloaded, and stays. */
const IN_USE_MS = 2 * 60_000;
const TOUCH_INTERVAL_MS = 60_000;
/** Asking again this soon after a failure is answered with it. */
const RETRY_AFTER_MS = 30_000;
const STALLED_MS = 120_000;
const MAX_QUEUED = 500;

/**
 * Compact AAC copies: small enough for mobile data, and the way to play what AVPlayer does
 * not. One is made at a time, behind everything else on the Pi, and the ones used longest
 * ago make room for new ones.
 */
export class AudioCopies {
  private readonly options: CopiesOptions;
  private readonly now: () => number;
  private readonly entries = new Map<string, Entry>();
  private readonly queue: Job[] = [];
  private readonly failures = new Map<string, { state: "failed" | "does_not_fit"; at: number }>();
  private current: Job | null = null;
  private working: Promise<void> = Promise.resolve();
  private readonly closing = new AbortController();

  constructor(options: CopiesOptions) {
    this.options = options;
    this.now = options.now ?? Date.now;
  }

  /** Reads what is there and deletes what a crash left half-written. */
  async start(): Promise<void> {
    await mkdir(this.options.dir, { recursive: true });
    for (const name of await readdir(this.options.dir)) {
      const path = join(this.options.dir, name);
      if (!NAME.test(name)) {
        // Only its own leftovers: the folder may have been pointed somewhere by mistake.
        if (name.endsWith(".m4a.part")) await rm(path, { force: true });
        continue;
      }
      const info = await stat(path);
      this.entries.set(name, {
        bytes: info.size,
        madeAt: Math.round(info.birthtimeMs),
        lastUsedAt: info.mtimeMs,
      });
    }
  }

  async close(): Promise<void> {
    this.queue.length = 0;
    this.closing.abort();
    await this.working;
  }

  totalBytes(): number {
    let total = 0;
    for (const entry of this.entries.values()) total += entry.bytes;
    return total;
  }

  private nameOf(id: string, revision: string, kbps: CompactKbps): string {
    return `${id}.${revision}.${kbps}.m4a`;
  }

  /** The finished copy, noting that it is used. Null when there is none (any more). */
  file(id: string, revision: string, kbps: CompactKbps): { path: string; etag: string } | null {
    const name = this.nameOf(id, revision, kbps);
    const entry = NAME.test(name) ? this.entries.get(name) : undefined;
    if (!entry) return null;
    const path = join(this.options.dir, name);
    const now = this.now();
    if (now - entry.lastUsedAt > TOUCH_INTERVAL_MS) {
      void utimes(path, new Date(now), new Date(now)).catch(() => undefined);
    }
    entry.lastUsedAt = now;
    // Made again it is another file, so a download of the old one starts over.
    return { path, etag: `${revision}-${kbps}-${entry.madeAt.toString(36)}` };
  }

  /** Asks for a copy; the same call reports on it. An urgent one is wanted by a listener now. */
  request(source: CopySource, kbps: CompactKbps, urgent: boolean): CopyStatus {
    const name = this.nameOf(source.id, source.revision, kbps);
    const entry = this.entries.get(name);
    if (entry) {
      entry.lastUsedAt = this.now();
      return { state: "ready", progress: 1, bytes: entry.bytes };
    }
    if (this.current?.name === name) {
      return { state: "preparing", progress: this.current.progress, bytes: null };
    }
    const failure = this.failures.get(name);
    if (failure && this.now() - failure.at < RETRY_AFTER_MS) {
      return { state: failure.state, progress: 0, bytes: null };
    }
    this.failures.delete(name);
    const queued = this.queue.find((job) => job.name === name);
    if (queued) {
      if (urgent && !queued.urgent) {
        this.queue.splice(this.queue.indexOf(queued), 1);
        this.enqueue({ ...queued, urgent });
      }
      return { state: "queued", progress: 0, bytes: null };
    }
    if (this.queue.length >= MAX_QUEUED) return { state: "busy", progress: 0, bytes: null };
    this.enqueue({ name, source, kbps, urgent, progress: 0 });
    return { state: "queued", progress: 0, bytes: null };
  }

  private enqueue(job: Job): void {
    const behind = job.urgent ? this.queue.findIndex((other) => !other.urgent) : -1;
    if (behind === -1) this.queue.push(job);
    else this.queue.splice(behind, 0, job);
    this.working = this.working.then(() => this.next());
  }

  private async next(): Promise<void> {
    const job = this.queue.shift();
    if (!job || this.isClosing()) return;
    this.current = job;
    try {
      if (await this.makeRoom(this.estimate(job))) {
        await this.convert(job);
      } else {
        this.fail(job, "does_not_fit");
      }
    } catch (error) {
      if (this.isClosing()) return;
      this.fail(job, "failed");
      log.warn("Could not make a compact copy", {
        track: job.source.id,
        error: errorMessage(error).slice(0, 100),
      });
    } finally {
      this.current = null;
    }
  }

  private isClosing(): boolean {
    return this.closing.signal.aborted;
  }

  private fail(job: Job, state: "failed" | "does_not_fit"): void {
    if (this.failures.size > 1000) this.failures.clear();
    this.failures.set(job.name, { state, at: this.now() });
  }

  private estimate(job: Job): number {
    const { durationMs, sizeBytes } = job.source;
    return durationMs === null
      ? sizeBytes
      : Math.ceil((durationMs / 1000) * job.kbps * 125 * 1.05) + indexBytes(durationMs);
  }

  private async makeRoom(bytes: number): Promise<boolean> {
    const { maxBytes, minFreeBytes, dir } = this.options;
    if (bytes > maxBytes) return false;
    const now = this.now();
    const idle = [...this.entries]
      .filter(([, entry]) => now - entry.lastUsedAt >= IN_USE_MS)
      .sort((a, b) => a[1].lastUsedAt - b[1].lastUsedAt);
    const volume = await statfs(dir);
    let total = this.totalBytes();
    let free = volume.bavail * volume.bsize;
    const evict: string[] = [];
    while (total + bytes > maxBytes || free - bytes < minFreeBytes) {
      const oldest = idle.shift();
      if (!oldest) return false;
      evict.push(oldest[0]);
      total -= oldest[1].bytes;
      free += oldest[1].bytes;
    }
    for (const name of evict) {
      this.entries.delete(name);
      await rm(join(dir, name), { force: true });
    }
    return true;
  }

  private async convert(job: Job): Promise<void> {
    const { source } = job;
    const opened = await source.open();
    const target = join(this.options.dir, job.name);
    const part = `${target}.part`;
    try {
      await this.encode(job, opened.path, part);
      // A drive pulled out halfway can look like the end of the file.
      if ((await source.open()).size !== opened.size) throw new Error("the file changed meanwhile");
      const { size } = await stat(part);
      await rename(part, target);
      const now = this.now();
      this.entries.set(job.name, { bytes: size, madeAt: now, lastUsedAt: now });
    } finally {
      await rm(part, { force: true });
    }
  }

  private encode(job: Job, input: string, output: string): Promise<void> {
    const { durationMs } = job.source;
    return new Promise((resolve, reject) => {
      const child = spawn(
        this.options.ffmpegPath,
        [
          ...["-v", "error", "-nostdin", "-progress", "pipe:1", ...SAFE_INPUT, "-i", input],
          ...["-map", "0:a:0", "-map_metadata", "-1", "-map_chapters", "-1"],
          ...["-threads", "1", "-c:a", "aac", "-b:a", `${job.kbps}k`, "-ac", "2"],
          // Apple's players and the encoder share these rates; DSD and 192 kHz come down to 48.
          ...["-af", "aformat=sample_rates=44100|48000"],
          // The index goes in front without writing the file twice, as "faststart" would.
          ...(durationMs === null
            ? ["-movflags", "+faststart"]
            : ["-moov_size", String(indexBytes(durationMs))]),
          ...["-f", "ipod", "-y", output],
        ],
        { stdio: ["ignore", "pipe", "pipe"], signal: this.closing.signal, killSignal: "SIGKILL" },
      );
      if (child.pid !== undefined) {
        try {
          setPriority(child.pid, 10);
        } catch {
          // It already finished.
        }
      }
      let stalled: NodeJS.Timeout | undefined;
      const alive = (): void => {
        clearTimeout(stalled);
        stalled = setTimeout(() => child.kill("SIGKILL"), STALLED_MS);
      };
      alive();
      child.stdout.on("data", (chunk: Buffer) => {
        alive();
        const done = /out_time_us=(\d+)/.exec(chunk.toString())?.[1];
        if (done !== undefined && durationMs) {
          job.progress = Math.min(0.99, Number(done) / 1000 / durationMs);
        }
      });
      child.stderr.resume();
      child.on("error", (error) => {
        clearTimeout(stalled);
        reject(error);
      });
      child.on("close", (code) => {
        clearTimeout(stalled);
        if (code === 0) resolve();
        else reject(new Error(`ffmpeg ended with ${String(code)}`));
      });
    });
  }
}

/** Room for the index: ten bytes for each of 47 frames a second at most. */
function indexBytes(durationMs: number): number {
  return 65_536 + Math.ceil(durationMs / 1000) * 470;
}
