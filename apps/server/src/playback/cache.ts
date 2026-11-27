// SPDX-License-Identifier: MPL-2.0
import { createHash } from "node:crypto";
import {
  mkdir,
  readdir,
  readFile,
  rename,
  rm,
  stat,
  statfs,
  utimes,
  writeFile,
} from "node:fs/promises";
import { join } from "node:path";
import type { PreparedAudio } from "./types.ts";

const PLAYLIST_NAME = /^(?:index|audio-[1-9][0-9]?)\.m3u8$/;
const MEDIA_NAME = /^(?:media|audio-[1-9][0-9]?)\.mp4$/;

/**
 * The media type of one of a prepared copy's files, or null for any other name.
 * Only these names are ever opened: the stream playlist and its MP4, and the
 * playlist and MP4 of each further sound track.
 */
export function preparedFileType(name: string): string | null {
  if (PLAYLIST_NAME.test(name)) return "application/vnd.apple.mpegurl";
  if (MEDIA_NAME.test(name)) return name === "media.mp4" ? "video/mp4" : "audio/mp4";
  return null;
}

export interface CacheEntry {
  assetId: string;
  revision: string;
  /** False while ffmpeg is still writing. A folder found like that at start is a crash leftover. */
  complete: boolean;
  /** Bytes the folder takes once complete; the expected size (the original's) before that. */
  sizeBytes: number;
  /** Size of `media.mp4` alone, which is what a device downloads. */
  mediaBytes: number;
  durationMs: number | null;
  audio: PreparedAudio[];
  /** True when the copy's picture was converted to H.264. */
  videoConverted: boolean;
  createdAt: number;
  lastUsedAt: number;
}

export interface CacheOptions {
  /** A folder Lobby owns completely. Everything in it can be deleted and rebuilt. */
  dir: string;
  /** Prepared copies are evicted, least recently used first, to stay below this. */
  maxBytes: number;
  /** Space that must stay free on the cache's volume after a new copy is written. */
  minFreeBytes: number;
  now: () => number;
}

/** Who is asking for room, and which copies must be left alone. */
export interface ReservePolicy {
  /** Assets with a preparation queued or running. Their copies are never evicted. */
  busy?: ReadonlySet<string>;
  /**
   * Assets whose copy a device still has to download. Evicted only for someone who
   * wants to watch something now, and only after every other copy.
   */
  guarded?: ReadonlySet<string>;
  /**
   * True for a copy prepared ahead of need. It may only replace copies nobody is
   * waiting for and nobody used for a day, so preparing ahead never takes away what
   * someone watches, and two wanted copies can never push each other out in turns.
   */
  background?: boolean;
}

export type Reservation =
  { ok: true; dir: string } | { ok: false; reason: "too_large" | "disk_full" };

const META_FILE = "meta.json";
const TOUCH_INTERVAL_MS = 60_000;
/** A copy used this recently is being played or downloaded and is never evicted. */
const IN_USE_MS = 2 * 60_000;
/** A copy prepared ahead of need only replaces copies left unused for this long. */
const BACKGROUND_EVICT_IDLE_MS = 24 * 60 * 60_000;
const SUBTITLE_MAX_AGE_MS = 90 * 24 * 60 * 60 * 1000;

function hash(...parts: string[]): string {
  const digest = createHash("sha256");
  for (const part of parts) digest.update(part).update("\0");
  return digest.digest("hex").slice(0, 32);
}

/**
 * The folder of prepared copies and converted subtitles.
 *
 * Layout: `prepared/<hash of asset id>/{meta.json, media.mp4, index.m3u8, audio-N.*}`
 * and `subtitles/<hash>.vtt`. Folder names are hashes and file names come from a
 * fixed pattern, so a request cannot name a path outside the cache.
 */
export class PreparedCache {
  private readonly options: CacheOptions;
  private readonly entries = new Map<string, CacheEntry>();
  private readonly touchedAt = new Map<string, number>();

  constructor(options: CacheOptions) {
    this.options = options;
  }

  private get preparedDir(): string {
    return join(this.options.dir, "prepared");
  }

  private get subtitleDir(): string {
    return join(this.options.dir, "subtitles");
  }

  /** The folder that holds an asset's prepared copy. */
  entryDir(assetId: string): string {
    return join(this.preparedDir, hash(assetId));
  }

  /**
   * Reads what is in the cache and deletes what a crash or a kill left half-written:
   * folders without a completed `meta.json`, and temporary subtitle files.
   */
  async open(): Promise<void> {
    await mkdir(this.preparedDir, { recursive: true });
    await mkdir(this.subtitleDir, { recursive: true });
    this.entries.clear();

    for (const name of await readdir(this.preparedDir)) {
      const dir = join(this.preparedDir, name);
      const entry = await this.readEntry(dir);
      if (entry?.complete && hash(entry.assetId) === name) {
        this.entries.set(entry.assetId, entry);
      } else {
        await rm(dir, { recursive: true, force: true });
      }
    }

    const now = this.options.now();
    for (const name of await readdir(this.subtitleDir)) {
      const path = join(this.subtitleDir, name);
      const info = await stat(path);
      if (!name.endsWith(".vtt") || now - info.mtimeMs > SUBTITLE_MAX_AGE_MS) {
        await rm(path, { recursive: true, force: true });
      }
    }
  }

  private async readEntry(dir: string): Promise<CacheEntry | null> {
    try {
      const metaPath = join(dir, META_FILE);
      const meta = JSON.parse(await readFile(metaPath, "utf8")) as Partial<CacheEntry>;
      if (typeof meta.assetId !== "string" || typeof meta.revision !== "string") return null;
      if (meta.complete !== true) return null;
      const media = await stat(join(dir, "media.mp4"));
      await stat(join(dir, "index.m3u8"));
      return {
        assetId: meta.assetId,
        revision: meta.revision,
        complete: true,
        sizeBytes: await folderBytes(dir),
        mediaBytes: media.size,
        durationMs: meta.durationMs ?? null,
        audio: meta.audio ?? [],
        videoConverted: meta.videoConverted ?? false,
        createdAt: meta.createdAt ?? media.mtimeMs,
        // The meta file's date is bumped when the copy is used.
        lastUsedAt: (await stat(metaPath)).mtimeMs,
      };
    } catch {
      return null;
    }
  }

  /** The entry for an asset, whatever its revision. Undefined when nothing is cached or reserved. */
  entry(assetId: string): CacheEntry | undefined {
    return this.entries.get(assetId);
  }

  /** A finished copy of exactly this revision. */
  ready(assetId: string, revision: string): CacheEntry | undefined {
    const entry = this.entries.get(assetId);
    return entry?.complete && entry.revision === revision ? entry : undefined;
  }

  list(): CacheEntry[] {
    return [...this.entries.values()];
  }

  totalBytes(): number {
    let total = 0;
    for (const entry of this.entries.values()) total += entry.sizeBytes;
    return total;
  }

  /**
   * Which finished copies would have to go to make room for `expectedBytes`, least
   * recently used first, or why there is no room. Never chosen: copies still being
   * written, the ones in `busy`, and copies used in the last two minutes (someone is
   * playing or downloading them). A background request is more careful still, see
   * `ReservePolicy`. Nothing is deleted here.
   */
  async room(
    assetId: string,
    expectedBytes: number,
    policy: ReservePolicy = {},
  ): Promise<{ ok: true; evict: string[] } | { ok: false; reason: "too_large" | "disk_full" }> {
    if (expectedBytes > this.options.maxBytes) return { ok: false, reason: "too_large" };
    const now = this.options.now();
    const guarded = policy.guarded ?? new Set<string>();
    const idleFor = (entry: CacheEntry): number => now - entry.lastUsedAt;
    const candidates = this.list()
      .filter(
        (entry) =>
          entry.assetId !== assetId &&
          entry.complete &&
          !policy.busy?.has(entry.assetId) &&
          idleFor(entry) >= IN_USE_MS &&
          (!policy.background ||
            (!guarded.has(entry.assetId) && idleFor(entry) >= BACKGROUND_EVICT_IDLE_MS)),
      )
      // Copies a device is still waiting for go last.
      .sort(
        (a, b) =>
          Number(guarded.has(a.assetId)) - Number(guarded.has(b.assetId)) ||
          a.lastUsedAt - b.lastUsedAt,
      );

    // Whatever is cached for this asset already is replaced, so its bytes come free.
    const own = this.entries.get(assetId)?.sizeBytes ?? 0;
    const volume = await statfs(this.options.dir);
    let total = this.totalBytes() - own;
    let free = volume.bavail * volume.bsize + (this.entries.get(assetId)?.complete ? own : 0);
    const evict: string[] = [];
    while (
      total + expectedBytes > this.options.maxBytes ||
      free - expectedBytes < this.options.minFreeBytes
    ) {
      const oldest = candidates.shift();
      if (!oldest) return { ok: false, reason: "disk_full" };
      evict.push(oldest.assetId);
      total -= oldest.sizeBytes;
      free += oldest.sizeBytes;
    }
    return { ok: true, evict };
  }

  /**
   * Makes room for a new copy and creates its folder. Whatever was cached for the
   * asset before (another revision, or a failed attempt) is deleted first. Which
   * copies may be evicted for it is decided by `room`.
   */
  async reserve(
    asset: { id: string; revision: string; durationMs: number | null },
    expectedBytes: number,
    audio: PreparedAudio[],
    policy: ReservePolicy = {},
    videoConverted = false,
  ): Promise<Reservation> {
    const room = await this.room(asset.id, expectedBytes, policy);
    await this.remove(asset.id);
    if (!room.ok) return room;
    for (const assetId of room.evict) await this.remove(assetId);

    const dir = this.entryDir(asset.id);
    await mkdir(dir, { recursive: true });
    const now = this.options.now();
    const entry: CacheEntry = {
      assetId: asset.id,
      revision: asset.revision,
      complete: false,
      sizeBytes: expectedBytes,
      mediaBytes: 0,
      durationMs: asset.durationMs,
      audio,
      videoConverted,
      createdAt: now,
      lastUsedAt: now,
    };
    await writeFile(join(dir, META_FILE), JSON.stringify(entry, null, 2));
    this.entries.set(asset.id, entry);
    return { ok: true, dir };
  }

  /** Marks a reserved copy as finished. Only from here on does it survive a restart. */
  async complete(assetId: string): Promise<CacheEntry> {
    const entry = this.entries.get(assetId);
    if (!entry) throw new Error("No reserved copy to complete.");
    const dir = this.entryDir(assetId);
    const finished: CacheEntry = {
      ...entry,
      complete: true,
      sizeBytes: await folderBytes(dir),
      mediaBytes: (await stat(join(dir, "media.mp4"))).size,
      lastUsedAt: this.options.now(),
    };
    // Written beside and renamed, so a crash here leaves either the old or the new meta file.
    const metaPath = join(dir, META_FILE);
    await writeFile(`${metaPath}.tmp`, JSON.stringify(finished, null, 2));
    await rename(`${metaPath}.tmp`, metaPath);
    this.entries.set(assetId, finished);
    return finished;
  }

  /** Empties a reserved folder for a second attempt, keeping the reservation. */
  async clear(assetId: string): Promise<void> {
    const dir = this.entryDir(assetId);
    for (const name of await readdir(dir)) {
      if (name !== META_FILE) await rm(join(dir, name), { recursive: true, force: true });
    }
  }

  /** Deletes an asset's copy, finished or not. */
  async remove(assetId: string): Promise<void> {
    this.entries.delete(assetId);
    this.touchedAt.delete(assetId);
    await rm(this.entryDir(assetId), { recursive: true, force: true });
  }

  /** Notes that a copy was just used, so it is the last to be evicted. */
  touch(assetId: string): void {
    const entry = this.entries.get(assetId);
    if (!entry) return;
    const now = this.options.now();
    entry.lastUsedAt = now;
    if (!entry.complete) return;
    // Persisted through the meta file's date, at most once a minute per copy.
    if (now - (this.touchedAt.get(assetId) ?? 0) < TOUCH_INTERVAL_MS) return;
    this.touchedAt.set(assetId, now);
    const time = new Date(now);
    void utimes(join(this.entryDir(assetId), META_FILE), time, time).catch(() => undefined);
  }

  /**
   * Where a converted subtitle lives. `variant` distinguishes versions of the same
   * subtitle id (a sidecar file that was replaced).
   */
  subtitlePath(
    assetId: string,
    revision: string,
    subtitleId: string,
    variant = "",
    extension: "vtt" | "json" = "vtt",
  ): string {
    return join(this.subtitleDir, `${hash(assetId, revision, subtitleId, variant)}.${extension}`);
  }
}

async function folderBytes(dir: string): Promise<number> {
  let total = 0;
  for (const name of await readdir(dir)) total += (await stat(join(dir, name))).size;
  return total;
}
