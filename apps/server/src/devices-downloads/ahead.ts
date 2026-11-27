// SPDX-License-Identifier: MPL-2.0
import { errorMessage, log } from "../log.ts";
import { PlaybackError, type PlaybackAsset, type PlaybackService } from "../playback/index.ts";
import type { WantedFile, WantedStore } from "./wanted.ts";

/** Why a wanted file has no copy yet and is not being worked on. */
export interface AheadNote {
  state: "does_not_fit" | "unsupported" | "failed" | "unavailable";
  /** A sentence for the manager. */
  message: string;
  revision: string;
  /** Not looked at again before this time. */
  retryAt: number;
  attempts: number;
}

export interface AheadOptions {
  store: WantedStore;
  playback: PlaybackService;
  lookupAsset: (assetId: string) => PlaybackAsset | null | Promise<PlaybackAsset | null>;
  now?: () => number;
  /** How often the list is looked at. Default 10 s. */
  intervalMs?: number;
  /** Nothing is prepared ahead until the house has been quiet for this long. Default 90 s. */
  quietMs?: number;
}

const MINUTE = 60_000;
export const DOES_NOT_FIT_CACHE =
  "This file is larger than the space the server has for prepared copies.";
export const CACHE_IS_FULL =
  "The server has no room to prepare this file until other downloads have finished.";

/**
 * Prepares the files devices are waiting for before they ask: repackaged or
 * converted copies of what is on a wanted list and not yet on the device.
 *
 * It works through the playback service with `background`, so one file at a time,
 * at the lowest priority, standing still while anyone watches or anything else is
 * prepared. It never evicts for its own sake what is in use or waited for: when the
 * cache has no room, the file is noted as not fitting and looked at again later.
 * Checking for room costs no work, so a full cache cannot turn into a loop of
 * preparing and evicting.
 */
export class AheadPreparer {
  private readonly options: AheadOptions;
  private readonly now: () => number;
  private readonly notes = new Map<string, AheadNote>();
  private timer: NodeJS.Timeout | null = null;
  private ticking: Promise<void> | null = null;
  private lastActivityAt = 0;
  /** The asset this preparer started and has not seen finish. */
  private current: { assetId: string; revision: string } | null = null;

  constructor(options: AheadOptions) {
    this.options = options;
    this.now = options.now ?? Date.now;
  }

  start(): void {
    if (this.timer) return;
    this.timer = setInterval(() => void this.tick(), this.options.intervalMs ?? 10_000);
    this.timer.unref();
  }

  async stop(): Promise<void> {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    await this.ticking;
  }

  /** Someone is playing or downloading something right now. */
  noteActivity(): void {
    this.lastActivityAt = this.now();
    this.options.playback.holdBackground(true);
  }

  /** What is known about a file that has no copy and no preparation. */
  note(assetId: string, revision: string): AheadNote | null {
    const note = this.notes.get(assetId);
    return note?.revision === revision ? note : null;
  }

  /** The files devices still have to fetch and that need a copy first, most urgent first. */
  private targets(): WantedFile[] {
    const targets = new Map<string, { file: WantedFile; order: number }>();
    for (const deviceId of this.options.store.devicesWithWanted()) {
      const has = new Map(
        this.options.store
          .reported(deviceId)
          .filter((download) => download.state === "downloaded")
          .map((download) => [download.assetId, download.revision]),
      );
      this.options.store.files(deviceId).files.forEach((file, order) => {
        if (file.playability !== "remux" && file.playability !== "transcode") return;
        if (has.get(file.assetId) === file.revision) return;
        const known = targets.get(file.assetId);
        if (!known || order < known.order) targets.set(file.assetId, { file, order });
      });
    }
    // The first file of every device before the second of any.
    return [...targets.values()].sort((a, b) => a.order - b.order).map((target) => target.file);
  }

  /** One look at the lists. Runs alone: a look that is still going on is joined. */
  tick(): Promise<void> {
    this.ticking ??= this.look()
      .catch((error: unknown) => {
        log.error("Preparing downloads ahead failed", { error: errorMessage(error) });
      })
      .finally(() => {
        this.ticking = null;
      });
    return this.ticking;
  }

  private async look(): Promise<void> {
    const { playback } = this.options;
    const now = this.now();
    const quiet = now - this.lastActivityAt >= (this.options.quietMs ?? 90_000);
    playback.holdBackground(!quiet);

    const targets = this.targets();
    const wanted = new Map(targets.map((file) => [file.assetId, file]));
    playback.guard(new Set(wanted.keys()));
    for (const assetId of this.notes.keys()) {
      if (!wanted.has(assetId)) this.notes.delete(assetId);
    }

    if (this.current) {
      const file = wanted.get(this.current.assetId);
      const state = playback.peek(this.current.assetId, this.current.revision);
      if (file?.revision !== this.current.revision) {
        // Nobody waits for it any more. If someone started watching it meanwhile it goes on.
        await playback.cancelBackground(this.current.assetId);
        this.current = null;
      } else if (state?.state === "queued" || state?.state === "preparing") {
        return;
      } else {
        if (state?.state === "failed") this.failed(file, "This file could not be prepared.");
        this.current = null;
      }
    }
    if (!quiet) return;

    for (const file of targets) {
      const state = playback.peek(file.assetId, file.revision);
      if (state?.state === "ready") {
        this.notes.delete(file.assetId);
        continue;
      }
      // Someone is watching it: that preparation is not ours to steer.
      if (state?.state === "queued" || state?.state === "preparing") continue;
      const note = this.note(file.assetId, file.revision);
      if (note && note.retryAt > now) continue;

      const asset = await this.options.lookupAsset(file.assetId);
      if (asset?.revision !== file.revision) continue;
      if (!asset.available) {
        this.setNote(file, "unavailable", "The drive this file is on is not connected.", MINUTE);
        continue;
      }
      try {
        const room = await playback.roomAhead(asset);
        if (room === "too_large") {
          this.setNote(file, "does_not_fit", DOES_NOT_FIT_CACHE, 60 * MINUTE);
          continue;
        }
        if (room === "disk_full") {
          this.setNote(file, "does_not_fit", CACHE_IS_FULL, MINUTE);
          continue;
        }
        await playback.prepare(asset, { background: true });
      } catch (error) {
        if (!(error instanceof PlaybackError)) throw error;
        if (error.code === "unsupported") {
          this.setNote(file, "unsupported", error.message, 24 * 60 * MINUTE);
        } else {
          this.setNote(file, "unavailable", error.message, MINUTE);
        }
        continue;
      }
      // Kept only for the retry count, should it fail.
      this.current = { assetId: file.assetId, revision: file.revision };
      return;
    }
  }

  private failed(file: WantedFile, message: string): void {
    const attempts = (this.note(file.assetId, file.revision)?.attempts ?? 0) + 1;
    // 5 minutes, then 10, 20, ... up to 6 hours: a broken file is not hammered.
    const wait = Math.min(6 * 60 * MINUTE, 5 * MINUTE * 2 ** (attempts - 1));
    this.setNote(file, "failed", message, wait, attempts);
  }

  private setNote(
    file: WantedFile,
    state: AheadNote["state"],
    message: string,
    retryInMs: number,
    attempts = this.note(file.assetId, file.revision)?.attempts ?? 0,
  ): void {
    this.notes.set(file.assetId, {
      state,
      message,
      revision: file.revision,
      retryAt: this.now() + retryInMs,
      attempts,
    });
  }
}
