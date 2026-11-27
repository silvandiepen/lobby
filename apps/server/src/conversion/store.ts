// SPDX-License-Identifier: MPL-2.0
import { randomUUID } from "node:crypto";
import type { Database } from "../db/database.ts";
import type { Playability, ProbeResult, Track } from "../library/probe.ts";
import type { ConversionKind } from "./convert.ts";

export type JobState =
  | "queued"
  | "claimed"
  | "converting"
  | "uploaded"
  | "verifying"
  | "done"
  | "failed"
  | "skipped"
  | "cancelled";

export const ACTIVE_STATES: readonly JobState[] = [
  "queued",
  "claimed",
  "converting",
  "uploaded",
  "verifying",
];

/** One file in the conversion queue, as a manager sees it. Documented in docs/api.md. */
export interface ConversionJob {
  id: string;
  assetId: string;
  itemId: string | null;
  kind: ConversionKind | null;
  /** Who may do it: `any`, or `mac` when it is too heavy for the server. */
  worker: "any" | "mac";
  state: JobState;
  /** 1 is done first. */
  position: number;
  /** 0 to 1 within the current state. */
  progress: number;
  /** A sentence: why it was skipped or failed, or what it is waiting for. */
  reason: string | null;
  originalBytes: number;
  /** The device that has claimed it, for a job a Mac is doing. */
  claimedBy: string | null;
  leaseExpiresAt: number | null;
  /** `server`, or the id of the device that converted it. */
  doneBy: string | null;
  proof: unknown;
  requestedBy: string | null;
  createdAt: number;
  updatedAt: number;
}

export interface JobRow {
  id: string;
  asset_id: string;
  item_id: string | null;
  source_id: string;
  rel_path: string;
  kind: ConversionKind | null;
  worker: "any" | "mac";
  state: JobState;
  position: number;
  progress: number;
  reason: string | null;
  original_size: number;
  original_mtime_ms: number;
  original_fingerprint: string | null;
  claimed_by: string | null;
  lease_expires_at: number | null;
  done_by: string | null;
  proof_json: string | null;
  requested_by: string | null;
  created_at: number;
  updated_at: number;
}

export interface Replacement {
  id: string;
  jobId: string;
  assetId: string;
  itemId: string | null;
  state: "replaced" | "undone" | "purged";
  originalBytes: number;
  newBytes: number;
  replacedAt: number;
  undoneAt: number | null;
  purgedAt: number | null;
}

export interface ReplacementRow {
  id: string;
  job_id: string;
  asset_id: string;
  item_id: string | null;
  source_id: string;
  original_rel_path: string;
  new_rel_path: string;
  kept_path: string;
  set_aside_path: string | null;
  original_size: number;
  original_mtime_ms: number;
  original_fingerprint: string | null;
  new_size: number;
  new_mtime_ms: number;
  state: Replacement["state"];
  replaced_at: number;
  undone_at: number | null;
  purged_at: number | null;
}

/** A library file with what the catalogue knows about it. */
export interface AssetInfo {
  id: string;
  sourceId: string;
  sourcePath: string;
  relPath: string;
  size: number;
  mtimeMs: number;
  fingerprint: string | null;
  probed: boolean;
  available: boolean;
  itemId: string | null;
  /** True when the file is one part of a film kept in several files. */
  multiPart: boolean;
  /** How many episodes share the file. */
  episodes: number;
  probe: ProbeResult;
}

export function toJob(row: JobRow): ConversionJob {
  return {
    id: row.id,
    assetId: row.asset_id,
    itemId: row.item_id,
    kind: row.kind,
    worker: row.worker,
    state: row.state,
    position: row.position,
    progress: row.progress,
    reason: row.reason,
    originalBytes: row.original_size,
    claimedBy: row.claimed_by,
    leaseExpiresAt: row.lease_expires_at,
    doneBy: row.done_by,
    proof: row.proof_json === null ? null : (JSON.parse(row.proof_json) as unknown),
    requestedBy: row.requested_by,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

export function toReplacement(row: ReplacementRow): Replacement {
  return {
    id: row.id,
    jobId: row.job_id,
    assetId: row.asset_id,
    itemId: row.item_id,
    state: row.state,
    originalBytes: row.original_size,
    newBytes: row.new_size,
    replacedAt: row.replaced_at,
    undoneAt: row.undone_at,
    purgedAt: row.purged_at,
  };
}

export type Scope =
  { kind: "item"; itemId: string } | { kind: "category"; categoryId: string } | { kind: "old" };

/** The most files one request may put in the queue. */
export const MAX_SCOPE_FILES = 5000;

const placeholders = (values: readonly unknown[]): string => values.map(() => "?").join(", ");

/** The queue and the record of replacements, in the database. */
export class ConversionStore {
  readonly db: Database;
  private readonly now: () => number;

  constructor(db: Database, now: () => number) {
    this.db = db;
    this.now = now;
  }

  get paused(): boolean {
    return this.db.getMeta("conversion_paused") === "1";
  }

  set paused(value: boolean) {
    this.db.setMeta("conversion_paused", value ? "1" : "0");
  }

  /** The files a request stands for. Null when the title or category does not exist. */
  assetsOf(scope: Scope): string[] | null {
    if (scope.kind === "old") {
      return this.db
        .all<{ id: string }>(
          `select distinct asset.id from asset join track on track.asset_id = asset.id
           where asset.state = 'probed' and track.kind = 'video'
             and track.codec in ('mpeg4', 'msmpeg4v3', 'av1')
           order by asset.rel_path limit ?`,
          [MAX_SCOPE_FILES],
        )
        .map((row) => row.id);
    }
    if (scope.kind === "category") {
      if (!this.db.get("select 1 as x from category where id = ?", [scope.categoryId])) return null;
      return this.db
        .all<{ id: string }>(
          `select asset.id from asset join source on source.id = asset.source_id
           where (source.category_id in (select id from category where id = ?1 or parent_id = ?1)
             or asset.id in (
               with recursive below (id) as (
                 select item_studio.item_id from category
                   cross join json_each(category.rule_json, '$.studioIds') as wanted
                   join item_studio on item_studio.studio_id = wanted.value
                   where category.id = ?1 or category.parent_id = ?1
                 union select item.id from item join below on item.parent_id = below.id)
               select item_asset.asset_id from below
                 join item_asset on item_asset.item_id = below.id and item_asset.role = 'main'))
             and asset.state = 'probed' order by asset.rel_path limit ?2`,
          [scope.categoryId, MAX_SCOPE_FILES],
        )
        .map((row) => row.id);
    }
    if (!this.db.get("select 1 as x from item where id = ?", [scope.itemId])) return null;
    return this.db
      .all<{ id: string }>(
        `with recursive below (id, season_number, episode_number, sort_title) as (
           select id, season_number, episode_number, sort_title from item where id = ?
           union all
           select item.id, item.season_number, item.episode_number, item.sort_title
           from item join below on item.parent_id = below.id
         )
         select distinct asset.id, below.season_number, below.episode_number, below.sort_title
         from below join item_asset on item_asset.item_id = below.id and item_asset.role = 'main'
         join asset on asset.id = item_asset.asset_id
         order by below.season_number, below.episode_number, below.sort_title, asset.rel_path
         limit ?`,
        [scope.itemId, MAX_SCOPE_FILES],
      )
      .map((row) => row.id);
  }

  asset(assetId: string): AssetInfo | null {
    const row = this.db.get<{
      id: string;
      source_id: string;
      source_path: string;
      rel_path: string;
      size: number;
      mtime_ms: number;
      fingerprint: string | null;
      state: string;
      available: number;
      source_available: number;
      container: string | null;
      duration_ms: number | null;
      bit_rate: number | null;
      playability: Playability | null;
      playability_reason: string | null;
    }>(
      `select asset.id, asset.source_id, source.path as source_path, asset.rel_path, asset.size,
         asset.mtime_ms, asset.fingerprint, asset.state, asset.available,
         source.available as source_available, asset.container, asset.duration_ms, asset.bit_rate,
         asset.playability, asset.playability_reason
       from asset join source on source.id = asset.source_id where asset.id = ?`,
      [assetId],
    );
    if (!row) return null;
    const tracks = this.db
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
      .map((track): Track => ({
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
    const links = this.db.all<{ item_id: string; part: number | null; kind: string }>(
      `select item_asset.item_id, item_asset.part, item.kind from item_asset
       join item on item.id = item_asset.item_id
       where item_asset.asset_id = ? and item_asset.role = 'main' order by item.id`,
      [assetId],
    );
    return {
      id: row.id,
      sourceId: row.source_id,
      sourcePath: row.source_path,
      relPath: row.rel_path,
      size: row.size,
      mtimeMs: row.mtime_ms,
      fingerprint: row.fingerprint,
      probed: row.state === "probed",
      available: row.available === 1 && row.source_available === 1,
      itemId: links[0]?.item_id ?? null,
      multiPart: links.some((link) => link.part !== null),
      episodes: links.filter((link) => link.kind === "episode").length,
      probe: {
        container: row.container ?? "",
        durationMs: row.duration_ms,
        bitRate: row.bit_rate,
        tracks,
        playability: row.playability ?? "unsupported",
        playabilityReason: row.playability_reason,
      },
    };
  }

  job(id: string): JobRow | null {
    return this.db.get<JobRow>("select * from conversion_job where id = ?", [id]) ?? null;
  }

  activeJobFor(assetId: string): JobRow | null {
    return (
      this.db.get<JobRow>(
        `select * from conversion_job where asset_id = ? and state in (${placeholders(ACTIVE_STATES)})`,
        [assetId, ...ACTIVE_STATES],
      ) ?? null
    );
  }

  jobs(states: readonly JobState[] | null, limit: number): JobRow[] {
    if (states === null) {
      return this.db.all<JobRow>(
        `select * from conversion_job order by
           state in (${placeholders(ACTIVE_STATES)}) desc, position, updated_at desc limit ?`,
        [...ACTIVE_STATES, limit],
      );
    }
    return this.db.all<JobRow>(
      `select * from conversion_job where state in (${placeholders(states)}) order by position limit ?`,
      [...states, limit],
    );
  }

  counts(): Record<JobState, number> {
    const counts: Record<JobState, number> = {
      queued: 0,
      claimed: 0,
      converting: 0,
      uploaded: 0,
      verifying: 0,
      done: 0,
      failed: 0,
      skipped: 0,
      cancelled: 0,
    };
    for (const row of this.db.all<{ state: JobState; n: number }>(
      "select state, count(*) as n from conversion_job group by state",
    )) {
      counts[row.state] = row.n;
    }
    return counts;
  }

  /** Adds a file to the queue, or records why it is not converted. Earlier verdicts on the file go. */
  add(
    asset: AssetInfo,
    verdict:
      | { kind: ConversionKind; worker: "any" | "mac" }
      | { kind: ConversionKind | null; skip: string },
    requestedBy: string,
  ): JobRow {
    return this.db.transaction(() => {
      this.db.run(
        "delete from conversion_job where asset_id = ? and state in ('skipped', 'failed', 'cancelled')",
        [asset.id],
      );
      const position =
        (this.db.get<{ last: number | null }>("select max(position) as last from conversion_job")
          ?.last ?? 0) + 1;
      const id = randomUUID();
      const skipped = "skip" in verdict;
      this.db.run(
        `insert into conversion_job (id, asset_id, item_id, source_id, rel_path, kind, worker, state, position,
           reason, original_size, original_mtime_ms, original_fingerprint, requested_by, created_at, updated_at)
         values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [
          id,
          asset.id,
          asset.itemId,
          asset.sourceId,
          asset.relPath,
          verdict.kind,
          skipped ? "any" : verdict.worker,
          skipped ? "skipped" : "queued",
          position,
          skipped ? verdict.skip : null,
          asset.size,
          asset.mtimeMs,
          asset.fingerprint,
          requestedBy,
          this.now(),
          this.now(),
        ],
      );
      const row = this.job(id);
      if (!row) throw new Error("The job vanished.");
      return row;
    });
  }

  update(id: string, fields: Partial<Omit<JobRow, "id">>): void {
    const names = Object.keys(fields) as (keyof typeof fields)[];
    if (names.length === 0) return;
    this.db.run(
      `update conversion_job set ${names.map((name) => `${name} = ?`).join(", ")}, updated_at = ? where id = ?`,
      [...names.map((name) => fields[name] ?? null), this.now(), id],
    );
  }

  /** Puts a job first or last among the ones that wait. */
  move(id: string, to: "top" | "bottom"): void {
    const edge = this.db.get<{ low: number | null; high: number | null }>(
      "select min(position) as low, max(position) as high from conversion_job",
    );
    this.update(id, {
      position: to === "top" ? (edge?.low ?? 1) - 1 : (edge?.high ?? 0) + 1,
    });
  }

  replacement(id: string): ReplacementRow | null {
    return (
      this.db.get<ReplacementRow>("select * from conversion_replacement where id = ?", [id]) ?? null
    );
  }

  replacements(limit: number): ReplacementRow[] {
    return this.db.all<ReplacementRow>(
      "select * from conversion_replacement order by replaced_at desc, id limit ?",
      [limit],
    );
  }

  sourcePath(sourceId: string): string | null {
    return (
      this.db.get<{ path: string }>("select path from source where id = ?", [sourceId])?.path ??
      null
    );
  }

  /** The volumes library folders were last seen on, as the scanner noted them. */
  knownVolumes(): Set<string> {
    return new Set(
      this.db
        .all<{ value: string }>("select value from meta where key like 'source_volume:%'")
        .map((row) => row.value),
    );
  }
}
