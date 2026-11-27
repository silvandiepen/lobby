// SPDX-License-Identifier: MPL-2.0
import { watch, type FSWatcher } from "node:fs";
import { join } from "node:path";
import type { Config } from "../config.ts";
import type { Database } from "../db/database.ts";
import { isIgnoredName } from "../library/parse.ts";
import { errorMessage, log } from "../log.ts";
import { ProgressStore } from "../progress.ts";
import { MusicCatalogue } from "./catalogue.ts";
import { AudioCopies } from "./copies.ts";
import { CoverStore } from "./covers.ts";
import { MusicReader } from "./reader.ts";
import { MusicScanner } from "./scanner.ts";
import { MusicViewers } from "./viewers.ts";

const WATCH_DEBOUNCE_MS = 5_000;
/** After the films' first scan has begun, so a start of the server is not one burst of work. */
const FIRST_SCAN_MS = 10_000;

export type MusicConfigSlice = Pick<
  Config,
  "dataDir" | "music" | "stabilityMs" | "rescanMinutes" | "ffmpegPath" | "ffprobePath"
>;

export interface MusicLibraryOptions {
  now?: () => number;
  volumeOf?: (path: string) => Promise<number>;
  forgetAfterMs?: number;
}

/** The audio library: everything under src/music, put together. */
export class MusicLibrary {
  readonly scanner: MusicScanner;
  readonly catalogue: MusicCatalogue;
  readonly reader: MusicReader;
  readonly viewers: MusicViewers;
  /** Where each viewer is in books and long pieces, by the films' rules. */
  readonly progress: ProgressStore;
  readonly covers: CoverStore;
  readonly copies: AudioCopies;
  private readonly config: MusicConfigSlice;
  private readonly watchers: FSWatcher[] = [];
  private timer: NodeJS.Timeout | null = null;
  private interval: NodeJS.Timeout | null = null;
  private running = false;
  private again = false;
  private stopped = false;

  constructor(db: Database, config: MusicConfigSlice, options: MusicLibraryOptions = {}) {
    this.config = config;
    const now = options.now ?? Date.now;
    this.catalogue = new MusicCatalogue(db, now);
    this.scanner = new MusicScanner(db, this.catalogue, {
      stabilityMs: config.stabilityMs,
      // One file at a time: films are scanned beside it and someone may be watching.
      probeConcurrency: 1,
      ffprobePath: config.ffprobePath,
      now,
      ...(options.volumeOf ? { volumeOf: options.volumeOf } : {}),
      ...(options.forgetAfterMs === undefined ? {} : { forgetAfterMs: options.forgetAfterMs }),
    });
    this.scanner.syncSources(config.music.roots);
    this.reader = new MusicReader(db);
    this.viewers = new MusicViewers(db, now);
    this.progress = new ProgressStore(db, now, {
      progress: "music_progress",
      ops: "music_progress_op",
      revisionKey: "music_progress_revision",
      itemExists:
        "select 1 as x from music_change where id = ? and removed = 0 and kind in ('track', 'book')",
    });
    this.covers = new CoverStore(
      db,
      join(config.dataDir, "cache", "music-covers"),
      config.ffmpegPath,
    );
    const GB = 1024 ** 3;
    this.copies = new AudioCopies({
      dir: config.music.cacheDir,
      maxBytes: config.music.maxCacheGb * GB,
      minFreeBytes: config.music.minFreeGb * GB,
      ffmpegPath: config.ffmpegPath,
      now,
    });
  }

  /** Readies the caches and keeps the library in step with its folders. */
  async start(): Promise<void> {
    this.progress.prune();
    await this.copies.start();
    await this.covers.tidy();
    if (this.config.music.roots.length === 0) return;
    this.schedule(FIRST_SCAN_MS);
    this.interval = setInterval(() => {
      this.schedule(0);
    }, this.config.rescanMinutes * 60_000);
    for (const root of this.config.music.roots) {
      try {
        const watcher = watch(root.path, { recursive: true }, (_event, name) => {
          if (name === null || name.split("/").some(isIgnoredName)) return;
          this.schedule(WATCH_DEBOUNCE_MS);
        });
        watcher.on("error", () => {
          log.warn("Stopped watching an audio folder; the timed scan still covers it", {
            source: root.name,
          });
        });
        this.watchers.push(watcher);
      } catch {
        log.warn("Could not watch an audio folder; the timed scan still covers it", {
          source: root.name,
        });
      }
    }
  }

  private schedule(delayMs: number): void {
    if (this.stopped) return;
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      this.timer = null;
      void this.run();
    }, delayMs);
  }

  private async run(): Promise<void> {
    if (this.running) {
      this.again = true;
      return;
    }
    this.running = true;
    try {
      const summary = await this.scanner.scanAll();
      const read = await this.scanner.processQueue();
      if (summary.added + summary.changed + summary.missing + summary.restored + read > 0) {
        log.info("Audio scan finished", {
          added: summary.added,
          changed: summary.changed,
          missing: summary.missing,
          restored: summary.restored,
          read,
        });
      }
      // New files are only indexed once they have stopped changing, so look again after the wait.
      if (summary.settling > 0 && this.timer === null) {
        this.schedule(this.config.stabilityMs + 1_000);
      }
    } catch (error) {
      log.error("Audio scan failed", { error: errorMessage(error) });
    } finally {
      this.running = false;
      if (this.again) {
        this.again = false;
        if (this.timer === null) this.schedule(WATCH_DEBOUNCE_MS);
      }
    }
  }

  async stop(): Promise<void> {
    this.stopped = true;
    if (this.timer) clearTimeout(this.timer);
    if (this.interval) clearInterval(this.interval);
    for (const watcher of this.watchers) watcher.close();
    await Promise.all([this.scanner.stop(), this.copies.close()]);
  }
}
