// SPDX-License-Identifier: MPL-2.0
import { createHash, randomUUID } from "node:crypto";
import { opendir, stat } from "node:fs/promises";
import { join } from "node:path";
import type { Database } from "../db/database.ts";
import { isIgnoredName } from "../library/parse.ts";
import { fingerprintFile } from "../library/probe.ts";
import { RETRY_DELAYS_MS, revisionOf, type ScanSummary } from "../library/scanner.ts";
import { errorMessage, log } from "../log.ts";
import type { MusicCatalogue } from "./catalogue.ts";
import { albumDirOf, coverRank, dirOf, isAudioFile, nameKey } from "./names.ts";
import { probeAudio, type AudioProbe } from "./probe.ts";
import type { MusicHint, MusicRootConfig } from "./types.ts";

interface SourceRow {
  id: string;
  path: string;
  name: string;
  hint: MusicHint;
  available: number;
}

interface FileRow {
  id: string;
  source_id: string;
  rel_path: string;
  size: number;
  mtime_ms: number;
  fingerprint: string | null;
  attempts: number;
  available: number;
  missing_since: number | null;
}

type QueueRow = FileRow & { source_path: string; hint: MusicHint };

interface SeenFile {
  size: number;
  mtimeMs: number;
}

type Read =
  { row: QueueRow; fingerprint: string; probe: AudioProbe } | { row: QueueRow; error: string };

export interface MusicScannerOptions {
  stabilityMs: number;
  probeConcurrency: number;
  ffprobePath: string;
  /** A file missing for longer than this is forgotten, with its place in playlists. */
  forgetAfterMs?: number;
  now?: () => number;
  /** The id of the volume a folder is on. Replaceable so tests can unplug a drive. */
  volumeOf?: (path: string) => Promise<number>;
}

const THIRTY_DAYS_MS = 30 * 24 * 3_600_000;
/** Files read before they are written to the catalogue together: the Pi's disk is slow. */
const BATCH = 100;

/** How a file sounds, for recognising it after it was tagged again and renamed at once. */
function soundKey(probe: AudioProbe): string | null {
  if (probe.durationMs === null || probe.durationMs < 5000) return null;
  return [
    probe.codec,
    probe.sampleRate,
    probe.channels,
    probe.durationMs,
    nameKey(probe.tags.title),
  ].join(":");
}

/**
 * Keeps the audio tables equal to what is in the audio folders. It follows the film
 * scanner's rules (a file must hold still first, a moved file keeps its id, a missing drive
 * is not an emptied folder) over tables of its own. It only ever reads the folders.
 */
export class MusicScanner {
  private readonly db: Database;
  private readonly catalogue: MusicCatalogue;
  private readonly options: MusicScannerOptions;
  private readonly now: () => number;
  private readonly volumeOf: (path: string) => Promise<number>;
  private readonly settling = new Map<string, SeenFile & { firstSeenAt: number }>();
  private scanning: Promise<ScanSummary> | null = null;
  private reading: Promise<number> | null = null;
  private stopped = false;

  constructor(db: Database, catalogue: MusicCatalogue, options: MusicScannerOptions) {
    this.db = db;
    this.catalogue = catalogue;
    this.options = options;
    this.now = options.now ?? Date.now;
    this.volumeOf = options.volumeOf ?? (async (path) => (await stat(path)).dev);
  }

  get isScanning(): boolean {
    return this.scanning !== null || this.reading !== null;
  }

  /** Stops reading after the files that are being read now, and waits for them. */
  async stop(): Promise<void> {
    this.stopped = true;
    await Promise.allSettled([this.scanning, this.reading]);
  }

  /** Makes the folders match the config. One that was removed keeps its catalogue. */
  syncSources(roots: MusicRootConfig[]): void {
    this.db.transaction(() => {
      for (const root of roots) {
        const existing = this.db.get<SourceRow>("select * from music_source where path = ?", [
          root.path,
        ]);
        if (!existing) {
          this.db.run(
            "insert into music_source (id, path, name, hint, available, created_at) values (?, ?, ?, ?, 1, ?)",
            [randomUUID(), root.path, root.name, root.hint, this.now()],
          );
        } else if (existing.name !== root.name || existing.hint !== root.hint) {
          this.db.run("update music_source set name = ?, hint = ? where id = ?", [
            root.name,
            root.hint,
            existing.id,
          ]);
          if (existing.hint !== root.hint) this.relink(existing.id);
        }
      }
      const configured = new Set(roots.map((root) => root.path));
      for (const source of this.db.all<SourceRow>("select * from music_source")) {
        if (!configured.has(source.path)) this.setAvailable(source, false);
      }
    });
  }

  /** The folder now holds books instead of music, or the other way round. */
  private relink(sourceId: string): void {
    this.catalogue.change(() => {
      for (const row of this.db.all<{ id: string }>(
        "select id from music_track where source_id = ? and tags_json is not null",
        [sourceId],
      )) {
        this.catalogue.link(row.id);
      }
    });
  }

  private setAvailable(source: SourceRow, available: boolean): void {
    if ((source.available === 1) === available) return;
    this.db.transaction(() => {
      this.db.run("update music_source set available = ? where id = ?", [
        available ? 1 : 0,
        source.id,
      ]);
      this.catalogue.touchSource(source.id);
    });
    log.warn(available ? "Audio folder is back" : "Audio folder is unavailable", {
      source: source.name,
    });
  }

  /** Scans every configured folder. Calls that overlap share one scan. */
  scanAll(): Promise<ScanSummary> {
    this.scanning ??= this.runScan().finally(() => {
      this.scanning = null;
    });
    return this.scanning;
  }

  private async runScan(): Promise<ScanSummary> {
    const summary: ScanSummary = {
      settling: 0,
      added: 0,
      changed: 0,
      missing: 0,
      restored: 0,
      unavailableSources: [],
    };
    for (const source of this.db.all<SourceRow>("select * from music_source order by name")) {
      if (this.stopped) break;
      try {
        await this.scanSource(source, summary);
      } catch (error) {
        log.error("Scan of an audio folder failed", {
          source: source.name,
          error: errorMessage(error),
        });
      }
    }
    summary.settling = this.settling.size;
    return summary;
  }

  private async walk(
    root: string,
  ): Promise<{ files: Map<string, SeenFile>; images: Map<string, SeenFile> }> {
    const files = new Map<string, SeenFile>();
    const images = new Map<string, SeenFile>();
    const pending = [""];
    while (pending.length > 0) {
      const relDir = pending.pop() ?? "";
      const directory = await opendir(join(root, relDir));
      for await (const entry of directory) {
        if (isIgnoredName(entry.name)) continue;
        const rel = relDir ? `${relDir}/${entry.name}` : entry.name;
        // Symbolic links are not followed: a link could point outside the root.
        if (entry.isDirectory()) {
          pending.push(rel);
        } else if (entry.isFile()) {
          const audio = isAudioFile(entry.name);
          if (!audio && coverRank(entry.name) === null) continue;
          const info = await stat(join(root, rel));
          if (info.size === 0) continue;
          (audio ? files : images).set(rel, {
            size: info.size,
            mtimeMs: Math.round(info.mtimeMs),
          });
        }
      }
    }
    return { files, images };
  }

  /** True once a file kept its size and date over two looks: a copy in progress does not. */
  private hasSettled(key: string, seen: SeenFile): boolean {
    const now = this.now();
    const candidate = this.settling.get(key);
    if (candidate?.size !== seen.size || candidate.mtimeMs !== seen.mtimeMs) {
      if (this.options.stabilityMs > 0) {
        this.settling.set(key, { ...seen, firstSeenAt: now });
        return false;
      }
    } else if (now - candidate.firstSeenAt < this.options.stabilityMs) {
      return false;
    }
    this.settling.delete(key);
    return true;
  }

  private async scanSource(source: SourceRow, summary: ScanSummary): Promise<void> {
    const startedAt = this.now();
    let walked: Awaited<ReturnType<MusicScanner["walk"]>>;
    let volume: number;
    try {
      volume = await this.volumeOf(source.path);
      walked = await this.walk(source.path);
    } catch (error) {
      // An unreadable root is a missing mount, not an empty library.
      summary.unavailableSources.push(source.name);
      this.setAvailable(source, false);
      log.warn("Could not read an audio folder", {
        source: source.name,
        reason: (error as NodeJS.ErrnoException).code ?? "unreadable",
      });
      return;
    }

    const existing = new Map(
      this.db
        .all<FileRow>(
          `select id, source_id, rel_path, size, mtime_ms, fingerprint, attempts, available, missing_since
           from music_track where source_id = ?`,
          [source.id],
        )
        .map((row) => [row.rel_path, row]),
    );
    const volumeKey = `music_source_volume:${source.id}`;
    const knownVolume = this.db.getMeta(volumeKey);
    if (walked.files.size === 0 && existing.size > 0 && knownVolume !== String(volume)) {
      // An unplugged drive leaves its empty mount point behind, on another volume.
      summary.unavailableSources.push(source.name);
      this.setAvailable(source, false);
      return;
    }

    this.catalogue.change(() => {
      if (walked.files.size > 0 && knownVolume !== String(volume)) {
        this.db.setMeta(volumeKey, String(volume));
      }
      this.setAvailable(source, true);
      for (const [relPath, seen] of walked.files) {
        this.compare(source, relPath, seen, existing.get(relPath), summary);
      }
      const forgetBefore = this.now() - (this.options.forgetAfterMs ?? THIRTY_DAYS_MS);
      for (const [relPath, row] of existing) {
        if (walked.files.has(relPath)) continue;
        if (row.available === 1) {
          this.db.run(
            "update music_track set available = 0, missing_since = ?, updated_at = ? where id = ?",
            [this.now(), this.now(), row.id],
          );
          this.catalogue.touchTrack(row.id);
          summary.missing += 1;
        } else if (row.missing_since !== null && row.missing_since < forgetBefore) {
          this.catalogue.removeTrack(row.id);
        }
      }
      this.syncImages(source, walked.images);
      this.db.run(
        "update music_source set last_scan_started_at = ?, last_scan_finished_at = ? where id = ?",
        [startedAt, this.now(), source.id],
      );
    });

    // What disappeared before it settled is not waited for.
    for (const key of this.settling.keys()) {
      const rel = key.startsWith(`${source.id}:`) ? key.slice(source.id.length + 1) : null;
      if (rel !== null && !walked.files.has(rel) && !walked.images.has(rel)) {
        this.settling.delete(key);
      }
    }
  }

  private compare(
    source: SourceRow,
    relPath: string,
    seen: SeenFile,
    row: FileRow | undefined,
    summary: ScanSummary,
  ): void {
    const key = `${source.id}:${relPath}`;
    const revision = revisionOf(seen.size, seen.mtimeMs);
    if (!row) {
      if (!this.hasSettled(key, seen)) return;
      const dir = dirOf(relPath);
      this.db.run(
        `insert into music_track (id, source_id, rel_path, dir, album_dir, size, mtime_ms, revision, state,
           first_seen_at, updated_at) values (?, ?, ?, ?, ?, ?, ?, ?, 'discovered', ?, ?)`,
        [
          randomUUID(),
          source.id,
          relPath,
          dir,
          albumDirOf(dir),
          seen.size,
          seen.mtimeMs,
          revision,
          this.now(),
          this.now(),
        ],
      );
      summary.added += 1;
    } else if (row.size !== seen.size || row.mtime_ms !== seen.mtimeMs) {
      if (!this.hasSettled(key, seen)) return;
      this.db.run(
        `update music_track set size = ?, mtime_ms = ?, revision = ?, state = 'discovered', attempts = 0,
           next_attempt_at = null, failure = null, available = 1, missing_since = null, updated_at = ?
         where id = ?`,
        [seen.size, seen.mtimeMs, revision, this.now(), row.id],
      );
      this.catalogue.touchTrack(row.id);
      summary.changed += 1;
    } else if (row.available === 0) {
      this.db.run(
        "update music_track set available = 1, missing_since = null, updated_at = ? where id = ?",
        [this.now(), row.id],
      );
      this.catalogue.touchTrack(row.id);
      summary.restored += 1;
    }
  }

  /** Pictures beside the files. Another picture is another id, so apps can keep them forever. */
  private syncImages(source: SourceRow, images: Map<string, SeenFile>): void {
    const known = new Map(
      this.db
        .all<{ id: string; rel_path: string; dir: string; size: number; mtime_ms: number }>(
          "select id, rel_path, dir, size, mtime_ms from music_image where source_id = ?",
          [source.id],
        )
        .map((row) => [row.rel_path, row]),
    );
    const dirs = new Set<string>();
    for (const [relPath, row] of known) {
      if (images.has(relPath)) continue;
      this.db.run("delete from music_image where id = ?", [row.id]);
      dirs.add(row.dir);
    }
    for (const [relPath, seen] of images) {
      const row = known.get(relPath);
      if (row?.size === seen.size && row.mtime_ms === seen.mtimeMs) continue;
      if (!this.hasSettled(`${source.id}:${relPath}`, seen)) continue;
      const dir = dirOf(relPath);
      if (row) this.db.run("delete from music_image where id = ?", [row.id]);
      this.db.run(
        "insert into music_image (id, source_id, rel_path, dir, size, mtime_ms) values (?, ?, ?, ?, ?, ?)",
        [
          createHash("sha256")
            .update(`${source.id}:${relPath}:${seen.size}:${seen.mtimeMs}`)
            .digest("hex")
            .slice(0, 32),
          source.id,
          relPath,
          dir,
          seen.size,
          seen.mtimeMs,
        ],
      );
      dirs.add(dir);
    }
    for (const dir of dirs) this.catalogue.refreshDir(source.id, dir);
  }

  /**
   * Reads the tags of every file that is waiting, a few at a time, and writes what was read
   * in batches. A restart carries on with what is still waiting.
   */
  processQueue(): Promise<number> {
    this.reading ??= this.runQueue().finally(() => {
      this.reading = null;
    });
    return this.reading;
  }

  private async runQueue(): Promise<number> {
    let handled = 0;
    while (!this.stopped) {
      const batch = this.db.all<QueueRow>(
        `select music_track.id, source_id, rel_path, size, mtime_ms, fingerprint, attempts,
           music_track.available, missing_since, music_source.path as source_path, music_source.hint
         from music_track join music_source on music_source.id = music_track.source_id
         where music_track.available = 1 and music_source.available = 1
           and (state = 'discovered' or (state = 'failed' and next_attempt_at <= ?))
         order by rel_path limit ${BATCH}`,
        [this.now()],
      );
      if (batch.length === 0) return handled;
      const results: Read[] = [];
      let next = 0;
      const worker = async (): Promise<void> => {
        while (!this.stopped) {
          const row = batch[next];
          next += 1;
          if (!row) return;
          results.push(await this.read(row));
        }
      };
      await Promise.all(Array.from({ length: this.options.probeConcurrency }, worker));
      this.catalogue.change(() => {
        for (const result of results) this.store(result);
      });
      handled += results.length;
    }
    return handled;
  }

  private async read(row: QueueRow): Promise<Read> {
    const path = join(row.source_path, row.rel_path);
    try {
      const info = await stat(path);
      // Still changing: the next scan sees the new size and waits for it to settle.
      if (info.size !== row.size) throw new Error("The file changed while it was being read.");
      const fingerprint = await fingerprintFile(path, row.size);
      const probe = await probeAudio(path, row.rel_path, this.options.ffprobePath);
      // A song's comment is never shown.
      if (row.hint === "music") probe.tags.description = null;
      return { row, fingerprint, probe };
    } catch (error) {
      return { row, error: errorMessage(error).slice(0, 500) };
    }
  }

  private store(result: Read): void {
    const { row } = result;
    // A scan may have seen the file change or go meanwhile; then it is read again.
    const current = this.db.get<{ size: number; mtime_ms: number; available: number }>(
      "select size, mtime_ms, available from music_track where id = ?",
      [row.id],
    );
    if (
      current?.size !== row.size ||
      current.mtime_ms !== row.mtime_ms ||
      current.available !== 1
    ) {
      return;
    }
    if ("error" in result) {
      const attempts = row.attempts + 1;
      const delay = RETRY_DELAYS_MS[Math.min(attempts, RETRY_DELAYS_MS.length) - 1] ?? 60_000;
      this.db.run(
        "update music_track set state = 'failed', failure = ?, attempts = ?, next_attempt_at = ?, updated_at = ? where id = ?",
        [result.error, attempts, this.now() + delay, this.now(), row.id],
      );
      // Without the message: ffprobe's names the file.
      log.warn("Could not read an audio file", { track: row.id, attempts });
      return;
    }
    const { fingerprint, probe } = result;
    const sound = soundKey(probe);
    const id = this.adopt(row, fingerprint, sound);
    this.db.run(
      `update music_track set fingerprint = ?, sound_key = ?, state = 'probed', failure = null, attempts = 0,
         next_attempt_at = null, container = ?, codec = ?, lossless = ?, duration_ms = ?, bit_rate = ?,
         sample_rate = ?, bit_depth = ?, channels = ?, playability = ?, chapters_json = ?, cover_id = ?,
         cover_stream = ?, tags_json = ?, updated_at = ? where id = ?`,
      [
        fingerprint,
        sound,
        probe.container,
        probe.codec,
        probe.lossless ? 1 : 0,
        probe.durationMs,
        probe.bitRate,
        probe.sampleRate,
        probe.bitDepth,
        probe.channels,
        probe.playability,
        JSON.stringify(probe.chapters),
        probe.coverStream === null
          ? null
          : createHash("sha256").update(`${id}:${fingerprint}`).digest("hex").slice(0, 32),
        probe.coverStream,
        JSON.stringify(probe.tags),
        this.now(),
        id,
      ],
    );
    this.catalogue.link(id);
  }

  /**
   * A new path with the fingerprint of a missing file is that file, moved. A new path that
   * sounds and is called the same as exactly one missing file is that file, tagged again
   * and renamed. Either way the old track goes on, with its place in playlists.
   */
  private adopt(row: QueueRow, fingerprint: string, sound: string | null): string {
    if (row.fingerprint !== null) return row.id;
    const moved = this.db.get<{ id: string }>(
      "select id from music_track where fingerprint = ? and size = ? and available = 0 and id != ? limit 1",
      [fingerprint, row.size, row.id],
    );
    const alike =
      moved || sound === null
        ? []
        : this.db.all<{ id: string }>(
            "select id from music_track where sound_key = ? and available = 0 and id != ? limit 2",
            [sound, row.id],
          );
    const old = moved ?? (alike.length === 1 ? alike[0] : undefined);
    if (!old) return row.id;
    const dir = dirOf(row.rel_path);
    this.db.run("delete from music_track where id = ?", [row.id]);
    this.db.run(
      `update music_track set source_id = ?, rel_path = ?, dir = ?, album_dir = ?, size = ?, mtime_ms = ?,
         available = 1, missing_since = null, updated_at = ? where id = ?`,
      [
        row.source_id,
        row.rel_path,
        dir,
        albumDirOf(dir),
        row.size,
        row.mtime_ms,
        this.now(),
        old.id,
      ],
    );
    if (!moved) {
      // Other bytes: copies on devices are stale. A plain move keeps its revision.
      this.db.run("update music_track set revision = ? where id = ?", [
        revisionOf(row.size, row.mtime_ms),
        old.id,
      ]);
    }
    log.info("An audio file moved and kept its identity", { track: old.id });
    return old.id;
  }
}
