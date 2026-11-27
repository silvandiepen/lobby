// SPDX-License-Identifier: MPL-2.0
import type { Database } from "./db/database.ts";
import { PlayLog } from "./plays.ts";

export interface Progress {
  itemId: string;
  positionMs: number;
  durationMs: number | null;
  completed: boolean;
  revision: number;
  updatedAt: number;
}

export interface ProgressUpdate {
  opId: string;
  baseRevision: number | null;
  positionMs: number;
  durationMs: number | null;
  completed: boolean;
  updatedAt: number;
}

export type ProgressResult =
  | { outcome: "accepted"; progress: Progress }
  | { outcome: "conflict"; progress: Progress }
  | { outcome: "not_found" };

interface ProgressRow {
  item_id: string;
  position_ms: number;
  duration_ms: number | null;
  completed: number;
  revision: number;
  updated_at: number;
}

/** Where one kind of progress is kept: films in one set of tables, audio in another. */
export interface ProgressTables {
  progress: string;
  ops: string;
  revisionKey: string;
  /** Finds a row when the id in its one parameter is something to have progress in. */
  itemExists: string;
}

const VIDEO_PROGRESS: ProgressTables = {
  progress: "progress",
  ops: "progress_op",
  revisionKey: "progress_revision",
  itemExists: "select 1 as x from item where id = ?",
};

const OP_MEMORY_MS = 60 * 24 * 3_600_000;

function toProgress(row: ProgressRow): Progress {
  return {
    itemId: row.item_id,
    positionMs: row.position_ms,
    durationMs: row.duration_ms,
    completed: row.completed === 1,
    revision: row.revision,
    updatedAt: row.updated_at,
  };
}

/**
 * Each viewer's place in each film and episode.
 *
 * Devices go offline for days and then send what happened. Every change has an
 * operation id, so a retry is answered exactly as the first attempt was, and a
 * change made against an old view of the progress only wins when the viewer
 * really did it later.
 */
export class ProgressStore {
  private readonly db: Database;
  private readonly now: () => number;
  private readonly tables: ProgressTables;
  /** Audio has a log of its own, kept by the apps. */
  private readonly plays: PlayLog | null;

  constructor(db: Database, now: () => number = Date.now, tables: ProgressTables = VIDEO_PROGRESS) {
    this.db = db;
    this.now = now;
    this.tables = tables;
    this.plays = tables === VIDEO_PROGRESS ? new PlayLog(db, now) : null;
  }

  get revision(): number {
    return Number(this.db.getMeta(this.tables.revisionKey) ?? "0");
  }

  list(profileId: string, since: number): Progress[] {
    return this.db
      .all<ProgressRow>(
        `select * from ${this.tables.progress} where profile_id = ? and revision > ? order by revision`,
        [profileId, since],
      )
      .map(toProgress);
  }

  /** Counts everything of a viewer as changed, for devices that were not told all of it. */
  touch(profileId: string): void {
    this.db.transaction(() => {
      const revision = this.revision + 1;
      this.db.setMeta(this.tables.revisionKey, String(revision));
      this.db.run(`update ${this.tables.progress} set revision = ? where profile_id = ?`, [
        revision,
        profileId,
      ]);
    });
  }

  /**
   * @param noted told of a place that was taken, inside the same transaction: the statistics'
   */
  put(
    profileId: string,
    itemId: string,
    update: ProgressUpdate,
    noted?: (profileId: string, itemId: string, before: Progress | null, after: Progress) => void,
  ): ProgressResult {
    return this.db.transaction((): ProgressResult => {
      const seen = this.db.get<{ profile_id: string; item_id: string; result_json: string }>(
        `select profile_id, item_id, result_json from ${this.tables.ops} where op_id = ?`,
        [update.opId],
      );
      if (seen && seen.profile_id === profileId && seen.item_id === itemId) {
        return JSON.parse(seen.result_json) as ProgressResult;
      }

      const profile = this.db.get(
        "select 1 as x from profile where id = ? and deleted_at is null",
        [profileId],
      );
      const item = this.db.get(this.tables.itemExists, [itemId]);
      if (!profile || !item) return { outcome: "not_found" };

      // A device with a fast clock must not be able to win every future conflict.
      const updatedAt = Math.min(update.updatedAt, this.now());
      const current = this.db.get<ProgressRow>(
        `select * from ${this.tables.progress} where profile_id = ? and item_id = ?`,
        [profileId, itemId],
      );

      let result: ProgressResult;
      if (current && current.revision !== update.baseRevision && updatedAt < current.updated_at) {
        result = { outcome: "conflict", progress: toProgress(current) };
      } else {
        const revision = this.revision + 1;
        this.db.setMeta(this.tables.revisionKey, String(revision));
        const row: ProgressRow = {
          item_id: itemId,
          position_ms: Math.max(0, Math.round(update.positionMs)),
          duration_ms:
            update.durationMs === null ? null : Math.max(0, Math.round(update.durationMs)),
          completed: update.completed ? 1 : 0,
          revision,
          updated_at: updatedAt,
        };
        this.db.run(
          `insert into ${this.tables.progress} (profile_id, item_id, position_ms, duration_ms, completed, revision, updated_at)
           values (?, ?, ?, ?, ?, ?, ?)
           on conflict (profile_id, item_id) do update set position_ms = excluded.position_ms,
             duration_ms = excluded.duration_ms, completed = excluded.completed,
             revision = excluded.revision, updated_at = excluded.updated_at`,
          [
            profileId,
            itemId,
            row.position_ms,
            row.duration_ms,
            row.completed,
            row.revision,
            row.updated_at,
          ],
        );
        result = { outcome: "accepted", progress: toProgress(row) };
        this.plays?.note(profileId, itemId, current ? toProgress(current) : null, toProgress(row));
        noted?.(profileId, itemId, current ? toProgress(current) : null, toProgress(row));
      }

      this.db.run(
        `insert into ${this.tables.ops} (op_id, profile_id, item_id, result_json, created_at) values (?, ?, ?, ?, ?)`,
        [update.opId, profileId, itemId, JSON.stringify(result), this.now()],
      );
      return result;
    });
  }

  /** Forgets acknowledged operations no device will retry any more. */
  prune(): void {
    this.db.run(`delete from ${this.tables.ops} where created_at < ?`, [this.now() - OP_MEMORY_MS]);
  }
}
