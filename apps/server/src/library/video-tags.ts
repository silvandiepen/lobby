// SPDX-License-Identifier: MPL-2.0
import { join } from "node:path";
import type { Database } from "../db/database.ts";
import { errorMessage, log } from "../log.ts";
import type { Catalogue } from "./catalogue.ts";
import { classify, probeFile, type ProbeResult, type Track } from "./probe.ts";

export interface VideoTagsOptions {
  ffprobePath: string;
  /** Told when a file's judgement changes, so the apps fetch its items again. */
  catalogue?: Catalogue;
  probe?: (path: string, ffprobePath: string) => Promise<ProbeResult>;
}

/**
 * Reads the HEVC sample entry (`hvc1`, `hev1`) of files that were probed before Lobby kept it.
 *
 * Apple devices show HEVC in MP4 only under `hvc1`: a `hev1` file plays its sound over a black
 * picture. The catalogue judged such files "direct" while it did not know the tag, so until a
 * file's tag is read it cannot be trusted to play as it is. Only MP4 and MOV files with HEVC
 * that are judged "direct" are in question: everything else is repackaged or converted anyway,
 * and the copy is always labelled `hvc1`. Matroska has no sample entries; its tag is "".
 */
export class VideoTags {
  private readonly running = new Map<string, Promise<void>>();
  private readonly db: Database;
  private readonly options: VideoTagsOptions;

  constructor(db: Database, options: VideoTagsOptions) {
    this.db = db;
    this.options = options;
  }

  /** Whether the file's playability waits for its tag to be read. */
  unchecked(assetId: string): boolean {
    return (
      this.db.get<{ n: number }>(`select 1 as n from asset where id = ? and ${UNCHECKED}`, [
        assetId,
      ]) !== undefined
    );
  }

  /** The files that wait for it, in no particular order. */
  pending(): string[] {
    return this.db
      .all<{ id: string }>(`select id from asset where ${UNCHECKED}`)
      .map((row) => row.id);
  }

  /**
   * Reads the file's tags when they are not known and judges the file again. A file that cannot
   * be read keeps its old judgement and is tried again next time. Calls for one file share one read.
   */
  ensure(assetId: string): Promise<void> {
    if (!this.unchecked(assetId)) return Promise.resolve();
    let running = this.running.get(assetId);
    if (!running) {
      running = this.check(assetId).finally(() => this.running.delete(assetId));
      this.running.set(assetId, running);
    }
    return running;
  }

  /**
   * Reads every file still in question, one at a time: headers only, a fraction of a second each.
   * @returns how many files are now repackaged instead of played as they are
   */
  async checkPending(shouldStop: () => boolean = () => false): Promise<number> {
    const ids = this.pending();
    if (ids.length === 0) return 0;
    let relabel = 0;
    for (const id of ids) {
      if (shouldStop()) break;
      await this.ensure(id);
      if (this.db.get("select 1 from asset where id = ? and playability = 'remux'", [id])) {
        relabel += 1;
      }
    }
    log.info("Read the picture labels of older files", { files: ids.length, relabel });
    return relabel;
  }

  private async check(assetId: string): Promise<void> {
    const row = this.db.get<{
      rel_path: string;
      source_path: string;
      container: string;
      playability: string;
    }>(
      `select asset.rel_path, source.path as source_path, asset.container, asset.playability
       from asset join source on source.id = asset.source_id
       where asset.id = ? and asset.available = 1 and source.available = 1`,
      [assetId],
    );
    if (!row) return;
    let probe: ProbeResult;
    try {
      probe = await (this.options.probe ?? probeFile)(
        join(row.source_path, row.rel_path),
        this.options.ffprobePath,
      );
    } catch (error) {
      log.warn("Could not read a file's picture label", {
        asset: assetId,
        error: errorMessage(error).slice(0, 200),
      });
      return;
    }
    const changed = this.db.transaction(() => {
      for (const track of probe.tracks) {
        this.db.run("update track set codec_tag = ? where asset_id = ? and idx = ?", [
          track.codecTag,
          assetId,
          track.index,
        ]);
      }
      // A track that the new read does not have keeps no unknown tag, or the file stays in question.
      this.db.run(
        "update track set codec_tag = '' where asset_id = ? and kind = 'video' and codec_tag is null",
        [assetId],
      );
      const verdict = classify(row.container, this.tracks(assetId));
      if (verdict.playability === row.playability) return false;
      this.db.run(
        "update asset set playability = ?, playability_reason = ?, updated_at = ? where id = ?",
        [verdict.playability, verdict.playabilityReason, Date.now(), assetId],
      );
      return true;
    });
    if (changed) {
      this.options.catalogue?.touchAsset(assetId);
      log.info("A file has to be repackaged for its picture to show", { asset: assetId });
    }
  }

  private tracks(assetId: string): Track[] {
    return this.db
      .all<{
        idx: number;
        kind: Track["kind"];
        codec: string;
        profile: string | null;
        language: string | null;
        title: string | null;
        channels: number | null;
        width: number | null;
        height: number | null;
        pix_fmt: string | null;
        codec_tag: string | null;
        is_default: number;
        is_forced: number;
      }>("select * from track where asset_id = ? order by idx", [assetId])
      .map((track) => ({
        index: track.idx,
        kind: track.kind,
        codec: track.codec,
        profile: track.profile,
        language: track.language,
        title: track.title,
        channels: track.channels,
        width: track.width,
        height: track.height,
        pixFmt: track.pix_fmt,
        codecTag: track.codec_tag,
        isDefault: track.is_default === 1,
        isForced: track.is_forced === 1,
      }));
  }
}

/** Probed MP4 or MOV files judged "direct" whose HEVC picture has no known tag. */
const UNCHECKED = `state = 'probed' and playability = 'direct' and container in ('mp4', 'mov', 'm4v')
  and exists (select 1 from track where track.asset_id = asset.id and track.kind = 'video'
    and track.codec = 'hevc' and track.codec_tag is null)`;
