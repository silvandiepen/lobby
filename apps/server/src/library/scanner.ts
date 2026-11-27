// SPDX-License-Identifier: MPL-2.0
import { createHash, randomUUID } from "node:crypto";
import { opendir, stat } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import type { RootConfig } from "../config.ts";
import type { Database } from "../db/database.ts";
import { errorMessage, log } from "../log.ts";
import { Categories } from "./categories.ts";
import type { Catalogue } from "./catalogue.ts";
import {
  extensionOf,
  isIgnoredName,
  isSubtitleFile,
  isVideoFile,
  parseMediaPath,
  PARSER_VERSION,
  type SourceHint,
} from "./parse.ts";
import { fingerprintFile, probeFile, type ProbeResult } from "./probe.ts";

interface SourceRow {
  id: string;
  path: string;
  name: string;
  hint: SourceHint;
  available: number;
}

interface AssetRow {
  id: string;
  source_id: string;
  rel_path: string;
  size: number;
  mtime_ms: number;
  fingerprint: string | null;
  state: string;
  attempts: number;
  available: number;
  missing_since: number | null;
}

interface SeenFile {
  size: number;
  mtimeMs: number;
}

export interface ScannerOptions {
  /** A new or changed file is indexed once it has kept its size and date for this long. */
  stabilityMs: number;
  probeConcurrency: number;
  ffprobePath: string;
  /** A file missing for longer than this is forgotten, with its watch history. */
  forgetAfterMs?: number;
  now?: () => number;
  probe?: (path: string, ffprobePath: string) => Promise<ProbeResult>;
  /** The id of the volume a folder is on. Replaceable so tests can unplug a drive. */
  volumeOf?: (path: string) => Promise<number>;
}

export interface ScanSummary {
  /** Files seen that are waiting to prove they are finished copying. */
  settling: number;
  added: number;
  changed: number;
  missing: number;
  restored: number;
  unavailableSources: string[];
}

// Wait longer after each failed probe: a file may still be arriving, or may simply be broken.
export const RETRY_DELAYS_MS = [60_000, 5 * 60_000, 30 * 60_000, 6 * 3_600_000, 24 * 3_600_000];
const THIRTY_DAYS_MS = 30 * 24 * 3_600_000;

const LANGUAGE_NAMES: Record<string, string> = {
  english: "en",
  eng: "en",
  en: "en",
  dutch: "nl",
  nederlands: "nl",
  dut: "nl",
  nld: "nl",
  nl: "nl",
  german: "de",
  deutsch: "de",
  ger: "de",
  deu: "de",
  de: "de",
  french: "fr",
  fre: "fr",
  fra: "fr",
  fr: "fr",
  spanish: "es",
  spa: "es",
  es: "es",
  italian: "it",
  ita: "it",
  it: "it",
  armenian: "hy",
  arm: "hy",
  hye: "hy",
  hy: "hy",
  russian: "ru",
  rus: "ru",
  ru: "ru",
};

export function revisionOf(size: number, mtimeMs: number): string {
  return createHash("sha256").update(`${size}:${mtimeMs}`).digest("hex").slice(0, 16);
}

function stemOf(name: string): string {
  const dot = name.lastIndexOf(".");
  return dot <= 0 ? name : name.slice(0, dot);
}

/**
 * What a subtitle file's name says after the video's: its language and whether it is forced
 * ("Film.en.srt", "Film.eng.forced.srt", "Film.Dutch.srt").
 */
export function sidecarName(suffix: string): { language: string | null; isForced: boolean } {
  const tokens = suffix
    .toLowerCase()
    .split(/[^a-z]+/)
    .filter(Boolean);
  let language: string | null = null;
  for (const token of tokens) {
    const code = LANGUAGE_NAMES[token];
    if (code) {
      language = code;
      break;
    }
  }
  return { language, isForced: tokens.includes("forced") };
}

/**
 * Walks the library roots and keeps the `asset` table equal to what is on
 * disk, then probes new files and hands them to the catalogue.
 *
 * It only ever reads the roots. Nothing here writes, renames or deletes a
 * media file.
 */
export class Scanner {
  private readonly db: Database;
  private readonly catalogue: Catalogue;
  private readonly options: ScannerOptions;
  private readonly now: () => number;
  private readonly probe: (path: string, ffprobePath: string) => Promise<ProbeResult>;
  private readonly volumeOf: (path: string) => Promise<number>;
  /** New or changed files, remembered until they have stopped changing. */
  private readonly settling = new Map<string, SeenFile & { firstSeenAt: number }>();
  private running: Promise<ScanSummary> | null = null;
  private queueRunning: Promise<number> | null = null;

  constructor(db: Database, catalogue: Catalogue, options: ScannerOptions) {
    this.db = db;
    this.catalogue = catalogue;
    this.options = options;
    this.now = options.now ?? Date.now;
    this.probe = options.probe ?? probeFile;
    this.volumeOf = options.volumeOf ?? (async (path) => (await stat(path)).dev);
  }

  get isScanning(): boolean {
    return this.running !== null || this.queueRunning !== null;
  }

  /**
   * Roots whose files are listed only when this says so: import folders that are indexed where
   * they are, where a file is listed once it passed the import rules (src/imports).
   */
  private readonly filters = new Map<string, (relPath: string) => boolean>();

  /** Lists only the files `accept` agrees to under `root`; null lists everything again. */
  setFilter(root: string, accept: ((relPath: string) => boolean) | null): void {
    if (accept) this.filters.set(root, accept);
    else this.filters.delete(root);
  }

  /** Files still waiting to prove they are complete. */
  get settlingCount(): number {
    return this.settling.size;
  }

  /** Makes the `source` table match the configured roots. A root that was removed keeps its catalogue. */
  syncSources(roots: RootConfig[]): void {
    this.db.transaction(() => {
      for (const root of roots) {
        const existing = this.db.get<SourceRow>("select * from source where path = ?", [root.path]);
        if (existing) {
          this.db.run("update source set name = ?, hint = ? where id = ?", [
            root.name,
            root.hint,
            existing.id,
          ]);
        } else {
          this.db.run(
            "insert into source (id, path, name, hint, available, created_at) values (?, ?, ?, ?, 1, ?)",
            [randomUUID(), root.path, root.name, root.hint, this.now()],
          );
        }
      }
      const configured = new Set(roots.map((root) => root.path));
      for (const source of this.db.all<SourceRow>("select * from source")) {
        if (!configured.has(source.path) && source.available === 1)
          this.setAvailable(source, false);
      }
      new Categories(this.db).seed(roots);
    });
  }

  /** Scans every configured root. Calls that overlap share one scan. */
  scanAll(): Promise<ScanSummary> {
    this.running ??= this.runScan().finally(() => {
      this.running = null;
    });
    return this.running;
  }

  /**
   * Reads every known file's name again after the parser changed. No file is
   * opened: the tracks are already known, only the mapping to items is redone.
   */
  private reparseIfNeeded(): void {
    if (this.db.getMeta("parser_version") === String(PARSER_VERSION)) return;
    const assets = this.db.all<{ id: string; rel_path: string; hint: SourceHint }>(
      `select asset.id, asset.rel_path, source.hint from asset
       join source on source.id = asset.source_id where asset.state = 'probed'`,
    );
    this.db.transaction(() => {
      for (const asset of assets) {
        if (isIgnoredName(asset.rel_path.slice(asset.rel_path.lastIndexOf("/") + 1))) continue;
        const parsed = parseMediaPath(asset.rel_path, asset.hint);
        this.db.run("update asset set parsed_json = ? where id = ?", [
          JSON.stringify(parsed),
          asset.id,
        ]);
        this.catalogue.linkAsset(asset.id, parsed, asset.hint);
      }
      this.db.setMeta("parser_version", String(PARSER_VERSION));
    });
    if (assets.length > 0)
      log.info("File names were read again with newer rules", { files: assets.length });
  }

  private async runScan(): Promise<ScanSummary> {
    this.reparseIfNeeded();
    const summary: ScanSummary = {
      settling: 0,
      added: 0,
      changed: 0,
      missing: 0,
      restored: 0,
      unavailableSources: [],
    };
    for (const source of this.db.all<SourceRow>("select * from source order by name")) {
      try {
        await this.scanSource(source, summary);
      } catch (error) {
        log.error("Scan of a library folder failed", {
          source: source.name,
          error: errorMessage(error),
        });
      }
    }
    summary.settling = this.settling.size;
    return summary;
  }

  private setAvailable(source: SourceRow, available: boolean): void {
    if ((source.available === 1) === available) return;
    this.db.transaction(() => {
      this.db.run("update source set available = ? where id = ?", [available ? 1 : 0, source.id]);
      this.catalogue.touchSource(source.id);
    });
    log.warn(available ? "Library folder is back" : "Library folder is unavailable", {
      source: source.name,
    });
  }

  private async walk(
    root: string,
  ): Promise<{ videos: Map<string, SeenFile>; subtitles: Map<string, SeenFile> }> {
    const videos = new Map<string, SeenFile>();
    const subtitles = new Map<string, SeenFile>();
    const pending = [""];
    const accept = this.filters.get(root);
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
          const video = isVideoFile(entry.name);
          if (!video && !isSubtitleFile(entry.name)) continue;
          if (accept && !accept(rel)) continue;
          const info = await stat(join(root, rel));
          if (info.size === 0) continue;
          (video ? videos : subtitles).set(rel, {
            size: info.size,
            mtimeMs: Math.round(info.mtimeMs),
          });
        }
      }
    }
    return { videos, subtitles };
  }

  /**
   * True once a new or changed file has kept the same size and date for the
   * stability window. A copy in progress keeps growing, and Finder may stamp
   * the original date on a file before it is complete, so one look is not enough.
   */
  private hasSettled(key: string, seen: SeenFile): boolean {
    const now = this.now();
    const candidate = this.settling.get(key);
    if (!candidate || candidate.size !== seen.size || candidate.mtimeMs !== seen.mtimeMs) {
      this.settling.set(key, { ...seen, firstSeenAt: now });
      if (this.options.stabilityMs > 0) return false;
      this.settling.delete(key);
      return true;
    }
    if (now - candidate.firstSeenAt < this.options.stabilityMs) return false;
    this.settling.delete(key);
    return true;
  }

  private async scanSource(source: SourceRow, summary: ScanSummary): Promise<void> {
    const startedAt = this.now();
    let walked: Awaited<ReturnType<Scanner["walk"]>>;
    let volume: number;
    try {
      volume = await this.volumeOf(source.path);
      walked = await this.walk(source.path);
    } catch (error) {
      // An unreadable root is a missing mount, not an empty library.
      summary.unavailableSources.push(source.name);
      this.setAvailable(source, false);
      log.warn("Could not read a library folder", {
        source: source.name,
        error: errorMessage(error),
      });
      return;
    }

    const existing = new Map(
      this.db
        .all<AssetRow>("select * from asset where source_id = ?", [source.id])
        .map((row) => [row.rel_path, row]),
    );
    const volumeKey = `source_volume:${source.id}`;
    const knownVolume = this.db.getMeta(volumeKey);
    if (walked.videos.size === 0 && existing.size > 0 && knownVolume !== String(volume)) {
      // An unplugged drive leaves its empty mount point behind, on another volume.
      // That is a missing drive, not a library someone emptied. Keep everything.
      summary.unavailableSources.push(source.name);
      this.setAvailable(source, false);
      return;
    }
    if (walked.videos.size > 0 && knownVolume !== String(volume))
      this.db.setMeta(volumeKey, String(volume));
    this.setAvailable(source, true);

    // One transaction for the whole comparison: a first scan adds thousands of rows,
    // and a disk write per row is slow on a Pi.
    this.db.transaction(() => {
      for (const [relPath, seen] of walked.videos) {
        const row = existing.get(relPath);
        const key = `${source.id}:${relPath}`;
        if (!row) {
          if (!this.hasSettled(key, seen)) continue;
          this.db.run(
            `insert into asset (id, source_id, rel_path, size, mtime_ms, revision, state, first_seen_at, updated_at)
           values (?, ?, ?, ?, ?, ?, 'discovered', ?, ?)`,
            [
              randomUUID(),
              source.id,
              relPath,
              seen.size,
              seen.mtimeMs,
              revisionOf(seen.size, seen.mtimeMs),
              this.now(),
              this.now(),
            ],
          );
          summary.added += 1;
        } else if (row.size !== seen.size || row.mtime_ms !== seen.mtimeMs) {
          if (!this.hasSettled(key, seen)) continue;
          this.db.run(
            `update asset set size = ?, mtime_ms = ?, revision = ?, state = 'discovered', attempts = 0,
             next_attempt_at = null, failure = null, available = 1, missing_since = null, updated_at = ?
           where id = ?`,
            [seen.size, seen.mtimeMs, revisionOf(seen.size, seen.mtimeMs), this.now(), row.id],
          );
          this.catalogue.touchAsset(row.id);
          summary.changed += 1;
        } else if (row.available === 0) {
          this.db.run(
            "update asset set available = 1, missing_since = null, updated_at = ? where id = ?",
            [this.now(), row.id],
          );
          this.catalogue.touchAsset(row.id);
          summary.restored += 1;
        }
      }

      const forgetBefore = this.now() - (this.options.forgetAfterMs ?? THIRTY_DAYS_MS);
      for (const [relPath, row] of existing) {
        if (walked.videos.has(relPath)) continue;
        this.settling.delete(`${source.id}:${relPath}`);
        if (row.available === 1) {
          this.db.run(
            "update asset set available = 0, missing_since = ?, updated_at = ? where id = ?",
            [this.now(), this.now(), row.id],
          );
          this.catalogue.touchAsset(row.id);
          summary.missing += 1;
        } else if (row.missing_since !== null && row.missing_since < forgetBefore) {
          this.catalogue.removeAsset(row.id);
        }
      }
    });

    this.syncSidecars(source, walked.videos, walked.subtitles);
    this.db.run(
      "update source set last_scan_started_at = ?, last_scan_finished_at = ? where id = ?",
      [startedAt, this.now(), source.id],
    );
  }

  /** Attaches subtitle files to the video they sit beside. */
  private syncSidecars(
    source: SourceRow,
    videos: Map<string, SeenFile>,
    subtitles: Map<string, SeenFile>,
  ): void {
    const videosByDir = new Map<string, string[]>();
    for (const relPath of videos.keys()) {
      const dir = dirname(relPath);
      videosByDir.set(dir, [...(videosByDir.get(dir) ?? []), relPath]);
    }
    const assetIds = new Map(
      this.db
        .all<{ id: string; rel_path: string }>(
          "select id, rel_path from asset where source_id = ?",
          [source.id],
        )
        .map((row) => [row.rel_path, row.id]),
    );

    const wanted = new Map<
      string,
      { assetId: string; relPath: string; language: string | null; isForced: boolean } & SeenFile
    >();
    for (const [relPath, seen] of subtitles) {
      let dir = dirname(relPath);
      // Subtitles are often kept in a "Subs" folder beside the film.
      if (/^(?:subs?|subtitles?)$/i.test(basename(dir)) && !videosByDir.has(dir))
        dir = dirname(dir);
      const candidates = videosByDir.get(dir) ?? [];
      const stem = stemOf(basename(relPath)).toLowerCase();
      const match =
        candidates
          .filter((video) => stem.startsWith(stemOf(basename(video)).toLowerCase()))
          .sort((a, b) => b.length - a.length)[0] ??
        (candidates.length === 1 ? candidates[0] : undefined);
      const assetId = match ? assetIds.get(match) : undefined;
      if (!match || !assetId) continue;
      const suffix = stem.slice(stemOf(basename(match)).length);
      const id = createHash("sha256").update(`${assetId}:${relPath}`).digest("hex").slice(0, 24);
      wanted.set(id, { assetId, relPath, ...sidecarName(suffix), ...seen });
    }

    const current = this.db.all<{
      id: string;
      asset_id: string;
      size: number;
      mtime_ms: number;
      language: string | null;
      is_forced: number;
    }>(
      `select sidecar.id, asset_id, sidecar.size, sidecar.mtime_ms, sidecar.language, sidecar.is_forced
       from sidecar join asset on asset.id = sidecar.asset_id where asset.source_id = ?`,
      [source.id],
    );
    const changedAssets = new Set<string>();
    this.db.transaction(() => {
      for (const row of current) {
        const keep = wanted.get(row.id);
        if (keep && keep.size === row.size && keep.mtimeMs === row.mtime_ms) {
          wanted.delete(row.id);
          // Read from the name by an older Lobby, which knew fewer of its words.
          if (keep.language !== row.language || (keep.isForced ? 1 : 0) !== row.is_forced) {
            this.db.run("update sidecar set language = ?, is_forced = ? where id = ?", [
              keep.language,
              keep.isForced ? 1 : 0,
              row.id,
            ]);
            changedAssets.add(row.asset_id);
          }
        } else {
          this.db.run("delete from sidecar where id = ?", [row.id]);
          changedAssets.add(row.asset_id);
        }
      }
      for (const [id, sidecar] of wanted) {
        this.db.run(
          "insert into sidecar (id, asset_id, rel_path, format, language, is_forced, size, mtime_ms) values (?, ?, ?, ?, ?, ?, ?, ?)",
          [
            id,
            sidecar.assetId,
            sidecar.relPath,
            extensionOf(sidecar.relPath),
            sidecar.language,
            sidecar.isForced ? 1 : 0,
            sidecar.size,
            sidecar.mtimeMs,
          ],
        );
        changedAssets.add(sidecar.assetId);
      }
    });
    for (const assetId of changedAssets) this.catalogue.touchAsset(assetId);
  }

  /**
   * Probes every file that is waiting, a few at a time.
   *
   * Progress lives in the `asset` rows, so a restart simply carries on with
   * whatever is still waiting.
   *
   * @returns how many files were handled
   */
  processQueue(): Promise<number> {
    this.queueRunning ??= this.runQueue().finally(() => {
      this.queueRunning = null;
    });
    return this.queueRunning;
  }

  private async runQueue(): Promise<number> {
    let handled = 0;
    for (;;) {
      const batch = this.db.all<AssetRow & { source_path: string; hint: SourceHint }>(
        `select asset.*, source.path as source_path, source.hint as hint
         from asset join source on source.id = asset.source_id
         where asset.available = 1 and source.available = 1
           and (asset.state = 'discovered' or (asset.state = 'failed' and asset.next_attempt_at <= ?))
         order by asset.first_seen_at limit 200`,
        [this.now()],
      );
      if (batch.length === 0) return handled;
      let next = 0;
      const worker = async (): Promise<void> => {
        for (;;) {
          const row = batch[next];
          next += 1;
          if (!row) return;
          await this.probeAsset(row);
          handled += 1;
        }
      };
      await Promise.all(Array.from({ length: this.options.probeConcurrency }, worker));
    }
  }

  private async probeAsset(
    row: AssetRow & { source_path: string; hint: SourceHint },
  ): Promise<void> {
    const path = join(row.source_path, row.rel_path);
    try {
      const info = await stat(path);
      if (info.size !== row.size) {
        // Still changing. The next scan sees the new size and waits for it to settle.
        throw new Error("The file changed size while it was being read.");
      }
      const fingerprint = await fingerprintFile(path, row.size);
      const assetId = this.adoptMovedAsset(row, fingerprint);
      const probe = await this.probe(path, this.options.ffprobePath);

      this.db.transaction(() => {
        this.db.run(
          `update asset set fingerprint = ?, state = 'probed', failure = null, attempts = 0, next_attempt_at = null,
             container = ?, duration_ms = ?, bit_rate = ?, playability = ?, playability_reason = ?, updated_at = ?
           where id = ?`,
          [
            fingerprint,
            probe.container,
            probe.durationMs,
            probe.bitRate,
            probe.playability,
            probe.playabilityReason,
            this.now(),
            assetId,
          ],
        );
        this.db.run("delete from track where asset_id = ?", [assetId]);
        for (const track of probe.tracks) {
          this.db.run(
            `insert into track (asset_id, idx, kind, codec, profile, language, title, channels, width, height,
               pix_fmt, codec_tag, is_default, is_forced) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
            [
              assetId,
              track.index,
              track.kind,
              track.codec,
              track.profile,
              track.language,
              track.title,
              track.channels,
              track.width,
              track.height,
              track.pixFmt,
              track.codecTag,
              track.isDefault ? 1 : 0,
              track.isForced ? 1 : 0,
            ],
          );
        }
        const parsed = parseMediaPath(row.rel_path, row.hint);
        this.db.run("update asset set parsed_json = ? where id = ?", [
          JSON.stringify(parsed),
          assetId,
        ]);
        this.catalogue.linkAsset(assetId, parsed, row.hint);
      });
    } catch (error) {
      const attempts = row.attempts + 1;
      const delay = RETRY_DELAYS_MS[Math.min(attempts, RETRY_DELAYS_MS.length) - 1] ?? 60_000;
      this.db.run(
        "update asset set state = 'failed', failure = ?, attempts = ?, next_attempt_at = ?, updated_at = ? where id = ?",
        [errorMessage(error).slice(0, 500), attempts, this.now() + delay, this.now(), row.id],
      );
      log.warn("Could not read a media file", {
        asset: row.id,
        attempts,
        error: errorMessage(error).slice(0, 200),
      });
    }
  }

  /**
   * A new path with the fingerprint of a file that went missing is that file,
   * moved or renamed. The old asset takes over the new path, so its id, its
   * item and the family's progress stay.
   *
   * @returns the id to continue with
   */
  private adoptMovedAsset(row: AssetRow, fingerprint: string): string {
    if (row.fingerprint !== null) return row.id;
    const moved = this.db.get<AssetRow>(
      "select * from asset where fingerprint = ? and size = ? and available = 0 and id != ? limit 1",
      [fingerprint, row.size, row.id],
    );
    if (!moved) return row.id;
    this.db.transaction(() => {
      this.db.run("delete from asset where id = ?", [row.id]);
      this.db.run(
        // The bytes are the same, so the revision stays and copies on devices remain valid.
        `update asset set source_id = ?, rel_path = ?, mtime_ms = ?, available = 1,
           missing_since = null, updated_at = ? where id = ?`,
        [row.source_id, row.rel_path, row.mtime_ms, this.now(), moved.id],
      );
    });
    log.info("A file moved and kept its identity", { asset: moved.id });
    return moved.id;
  }
}
