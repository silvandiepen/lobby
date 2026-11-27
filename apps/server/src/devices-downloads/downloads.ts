// SPDX-License-Identifier: MPL-2.0
import { createHash } from "node:crypto";
import type { Database } from "../db/database.ts";
import type { VideoTags } from "../library/video-tags.ts";
import { errorMessage, log } from "../log.ts";
import type { PlaybackAsset, PlaybackService } from "../playback/index.ts";
import { AheadPreparer } from "./ahead.ts";
import {
  WantedStore,
  type DeviceStorage,
  type ReportedDownload,
  type StoredDownload,
  type WantedEntry,
  type WantedFile,
  type WantedInput,
} from "./wanted.ts";

/**
 * Where the server is with one wanted file.
 *
 * - `ready`: `downloadUrl` can be fetched now.
 * - `waiting`: a copy has to be prepared and it is not this file's turn yet.
 * - `preparing`: the copy is being written (or is next in line).
 * - `does_not_fit`: the server's cache has no room for the copy. See `message`.
 * - `unsupported`: this file cannot be made playable on Apple devices.
 * - `failed`: preparing went wrong; the server tries again later by itself.
 * - `unavailable`: the drive the file is on is not connected.
 */
export type ServerState =
  "ready" | "waiting" | "preparing" | "does_not_fit" | "unsupported" | "failed" | "unavailable";

/** One file on a device's list, as the device needs it. Documented in docs/api.md. */
export interface WantedAsset {
  assetId: string;
  itemId: string;
  revision: string;
  /** 1 is fetched first. */
  order: number;
  /** The size of the download: exact once `state` is `ready`, the original's size before. */
  bytes: number;
  bytesExact: boolean;
  state: ServerState;
  /** `direct`: the original file. `prepared`: a repackaged or converted copy. */
  mode: "direct" | "prepared" | null;
  downloadUrl: string | null;
  message: string | null;
  why: WantedFile["why"];
}

export interface DeviceList {
  /** Changes when anything in `assets` does. Also the ETag of the device's own view. */
  revision: string;
  assets: WantedAsset[];
  /** Files beyond the limit of what one device is told to hold. */
  leftOut: number;
}

/** A wanted file as a manager sees it: the device's list plus both sides' progress. */
export interface OverviewAsset extends WantedAsset {
  /** 0 to 1: how far the server is with the copy. 1 when nothing has to be prepared. */
  prepareProgress: number;
  /** What the device last said about this file. Null when it has not mentioned it. */
  device: Omit<StoredDownload, "assetId" | "own"> | null;
}

export interface DeviceOverview {
  deviceId: string;
  wanted: WantedEntry[];
  assets: OverviewAsset[];
  leftOut: number;
  storage: DeviceStorage | null;
  /** Bytes of wanted files the device does not have completely yet. */
  bytesToFetch: number;
  /** Whether those bytes fit in the free space the device reported. Null when it reported none. */
  fits: boolean | null;
  /** What the device holds or fetches that is on no list: the person's own downloads, and leftovers. */
  other: (StoredDownload & { itemId: string | null })[];
}

export interface DeviceSummary {
  deviceId: string;
  entries: number;
  files: number;
  downloaded: number;
  failed: number;
  bytesToFetch: number;
  ownDownloads: number;
  storage: DeviceStorage | null;
}

export interface DeviceDownloadsOptions {
  db: Database;
  /** Without it nothing is prepared ahead, and only files that play as they are can be fetched. */
  playback?: PlaybackService;
  lookupAsset?: (assetId: string) => PlaybackAsset | null | Promise<PlaybackAsset | null>;
  /** Reads the picture label of an older HEVC file before it is offered as it is. */
  videoTags?: VideoTags;
  now?: () => number;
  aheadIntervalMs?: number;
  aheadQuietMs?: number;
}

/**
 * What a manager wants on each device, what each device has, and the preparing
 * ahead that connects the two.
 */
export class DeviceDownloads {
  readonly store: WantedStore;
  readonly ahead: AheadPreparer | null;
  private readonly playback: PlaybackService | null;
  private readonly videoTags: VideoTags | null;

  constructor(options: DeviceDownloadsOptions) {
    this.store = new WantedStore(options.db, options.now);
    this.playback = options.playback ?? null;
    this.videoTags = options.videoTags ?? null;
    this.ahead =
      options.playback && options.lookupAsset
        ? new AheadPreparer({
            store: this.store,
            playback: options.playback,
            lookupAsset: options.lookupAsset,
            ...(options.now ? { now: options.now } : {}),
            ...(options.aheadIntervalMs !== undefined
              ? { intervalMs: options.aheadIntervalMs }
              : {}),
            ...(options.aheadQuietMs !== undefined ? { quietMs: options.aheadQuietMs } : {}),
          })
        : null;
  }

  /** Starts preparing ahead. Without this the lists work and nothing is prepared before it is asked for. */
  start(): void {
    this.ahead?.start();
  }

  async stop(): Promise<void> {
    await this.ahead?.stop();
  }

  add(
    deviceId: string,
    input: WantedInput,
    addedBy: string,
  ): { entry: WantedEntry; created: boolean } {
    const result = this.store.add(deviceId, input, addedBy);
    void this.ahead?.tick();
    return result;
  }

  remove(deviceId: string, wantedId: string): boolean {
    const removed = this.store.remove(deviceId, wantedId);
    if (removed) void this.ahead?.tick();
    return removed;
  }

  report(
    deviceId: string,
    report: { freeBytes: number | null; totalBytes: number | null; downloads: ReportedDownload[] },
  ): void {
    this.store.saveReport(deviceId, report);
  }

  private describe(file: WantedFile, order: number): { asset: WantedAsset; progress: number } {
    const base = {
      assetId: file.assetId,
      itemId: file.itemId,
      revision: file.revision,
      order,
      why: file.why,
    };
    const waiting = (
      state: ServerState,
      message: string | null,
      progress = 0,
    ): { asset: WantedAsset; progress: number } => ({
      asset: {
        ...base,
        bytes: file.sizeBytes,
        bytesExact: file.playability === "direct",
        state,
        mode: null,
        downloadUrl: null,
        message,
      },
      progress,
    });
    const id = encodeURIComponent(file.assetId);

    if (file.playability === "direct") {
      if (!file.available)
        return waiting("unavailable", "The drive this file is on is not connected.");
      // An older HEVC file whose label is not read yet may need relabelling: not offered until
      // it is known. The read takes a moment; the list changes once it is done.
      if (this.videoTags?.unchecked(file.assetId) === true) {
        void this.videoTags
          .ensure(file.assetId)
          .then(() => this.ahead?.tick())
          .catch((error: unknown) => {
            log.warn("Could not read a file's picture label", { error: errorMessage(error) });
          });
        return waiting("waiting", "Lobby is checking this file first.");
      }
      return {
        asset: {
          ...base,
          bytes: file.sizeBytes,
          bytesExact: true,
          state: "ready",
          mode: "direct",
          downloadUrl: `/v1/assets/${id}/content`,
          message: null,
        },
        progress: 1,
      };
    }
    if (file.playability === "unsupported" || !this.playback) {
      return waiting(
        "unsupported",
        file.playabilityReason ?? "This file cannot be played on Apple devices.",
      );
    }

    const copy = this.playback.peek(file.assetId, file.revision);
    if (copy?.state === "ready") {
      return {
        asset: {
          ...base,
          bytes: copy.bytes ?? file.sizeBytes,
          bytesExact: true,
          state: "ready",
          mode: "prepared",
          downloadUrl: `/v1/assets/${id}/prepared/${encodeURIComponent(file.revision)}/media.mp4`,
          message: null,
        },
        progress: 1,
      };
    }
    if (copy?.state === "preparing" || copy?.state === "queued") {
      return waiting("preparing", null, copy.progress);
    }
    const note = this.ahead?.note(file.assetId, file.revision);
    if (note) return waiting(note.state, note.message);
    if (copy?.state === "failed") return waiting("failed", "This file could not be prepared.");
    if (!file.available)
      return waiting("unavailable", "The drive this file is on is not connected.");
    return waiting("waiting", null);
  }

  private resolve(deviceId: string): {
    assets: WantedAsset[];
    progress: Map<string, number>;
    leftOut: number;
  } {
    const { files, leftOut } = this.store.files(deviceId);
    const progress = new Map<string, number>();
    const assets = files.map((file, index) => {
      const described = this.describe(file, index + 1);
      progress.set(file.assetId, described.progress);
      return described.asset;
    });
    return { assets, progress, leftOut };
  }

  /** A device's own list. Its `revision` only changes when something the device acts on does. */
  list(deviceId: string): DeviceList {
    const { assets, leftOut } = this.resolve(deviceId);
    const revision = createHash("sha256")
      .update(JSON.stringify([assets, leftOut]))
      .digest("hex")
      .slice(0, 24);
    return { revision, assets, leftOut };
  }

  /** Everything a manager sees about one device. */
  overview(deviceId: string): DeviceOverview {
    this.store.requireDevice(deviceId);
    const { assets, progress, leftOut } = this.resolve(deviceId);
    const reported = new Map(this.store.reported(deviceId).map((entry) => [entry.assetId, entry]));
    const storage = this.store.storage(deviceId);

    let bytesToFetch = 0;
    const overview = assets.map((asset): OverviewAsset => {
      const said = reported.get(asset.assetId);
      reported.delete(asset.assetId);
      const current = said?.revision === asset.revision ? said : undefined;
      if (current?.state !== "downloaded") {
        bytesToFetch += Math.max(0, asset.bytes - (current?.bytesDone ?? 0));
      }
      return {
        ...asset,
        prepareProgress: progress.get(asset.assetId) ?? 0,
        device: said
          ? {
              revision: said.revision,
              state: said.state,
              bytesDone: said.bytesDone,
              bytesTotal: said.bytesTotal,
              error: said.error,
              reportedAt: said.reportedAt,
            }
          : null,
      };
    });
    const free = storage?.freeBytes ?? null;
    return {
      deviceId,
      wanted: this.store.list(deviceId),
      assets: overview,
      leftOut,
      storage,
      bytesToFetch,
      fits: free === null ? null : bytesToFetch <= free,
      other: [...reported.values()].map((entry) => ({
        ...entry,
        itemId: this.store.itemOfAsset(entry.assetId),
      })),
    };
  }

  /** One line per device for the list of devices. */
  summary(deviceId: string): DeviceSummary {
    const overview = this.overview(deviceId);
    return {
      deviceId,
      entries: overview.wanted.length,
      files: overview.assets.length,
      downloaded: overview.assets.filter(
        (asset) => asset.device?.state === "downloaded" && asset.device.revision === asset.revision,
      ).length,
      failed: overview.assets.filter(
        (asset) =>
          asset.device?.state === "failed" ||
          asset.state === "failed" ||
          asset.state === "does_not_fit" ||
          asset.state === "unsupported",
      ).length,
      bytesToFetch: overview.bytesToFetch,
      ownDownloads: overview.other.filter((entry) => entry.own).length,
      storage: overview.storage,
    };
  }
}
