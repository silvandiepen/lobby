// SPDX-License-Identifier: MPL-2.0
import { randomUUID } from "node:crypto";
import type { Database } from "../db/database.ts";
import { watched, type Place } from "../plays.ts";
import { DAY_MS } from "./time.ts";

/** How a film reached the device. */
export type Delivery = "direct" | "prepared" | "download" | "unknown";
/** Which way the device came in: at home, through the tailnet, the relay or the direct road. */
export type Road = "home" | "tailnet" | "relay" | "direct" | "unknown";

export const ROADS: readonly Road[] = ["home", "tailnet", "relay", "direct", "unknown"];
export const DELIVERIES: readonly Delivery[] = ["direct", "prepared", "download", "unknown"];

/** How long statistics are kept unless the household says otherwise: two years. */
export const DEFAULT_KEEP_DAYS = 730;
/** A pause longer than this starts a new sitting. */
export const SITTING_GAP_MS = 30 * 60_000;
/** How long a request to play, or a Play On, is remembered for the sitting that follows. */
const PLAYBACK_MEMORY_MS = 12 * 3_600_000;
const PLAY_ON_MEMORY_MS = 15 * 60_000;
const MAX_NOTES = 2000;

/** What is known about the request that moved a viewer's place. */
export interface WatchContext {
  deviceId: string;
  householdId: string;
  road: Road;
}

interface OpenSession {
  id: string;
  started_at: number;
  ended_at: number;
  completed: number;
}

/** A map that forgets its oldest entries, so a busy server never holds too much. */
class Notes<T> {
  private readonly entries = new Map<string, T & { at: number }>();
  private readonly memoryMs: number;

  constructor(memoryMs: number) {
    this.memoryMs = memoryMs;
  }

  set(key: string, value: T & { at: number }): void {
    this.entries.delete(key);
    this.entries.set(key, value);
    while (this.entries.size > MAX_NOTES) {
      const oldest = this.entries.keys().next().value;
      if (oldest === undefined) break;
      this.entries.delete(oldest);
    }
  }

  get(key: string, now: number): (T & { at: number }) | undefined {
    const entry = this.entries.get(key);
    if (!entry || now - entry.at > this.memoryMs) return undefined;
    return entry;
  }
}

/**
 * What the statistics are made of (docs/decisions.md, "Statistics"). Sittings with films and episodes,
 * from the places the apps report; bytes sent, per hour and road; and what the server prepared
 * and converted. Listening is the music library's own play history.
 *
 * Nothing here leaves the household it belongs to, and nothing is kept longer than
 * `keepDays`: whatever is older goes, once a day.
 */
export class Statistics {
  private readonly db: Database;
  private readonly now: () => number;
  private readonly keepDays: () => number;
  private readonly playbacks = new Notes<{ mode: "direct" | "prepared" }>(PLAYBACK_MEMORY_MS);
  private readonly playOns = new Notes<{ from: string }>(PLAY_ON_MEMORY_MS);
  private prunedAt = 0;

  constructor(db: Database, options: { now?: () => number; keepDays?: () => number } = {}) {
    this.db = db;
    this.now = options.now ?? Date.now;
    this.keepDays = options.keepDays ?? (() => DEFAULT_KEEP_DAYS);
  }

  get kept(): number {
    return this.keepDays();
  }

  /** The oldest moment that is kept. */
  get oldest(): number {
    return this.now() - this.keepDays() * DAY_MS;
  }

  // ---- Recording ----

  /** A device asked to play a file: the sitting that follows was sent as it is, or prepared. */
  notePlayback(deviceId: string, assetId: string, mode: "direct" | "prepared"): void {
    const at = this.now();
    for (const { item_id } of this.db.all<{ item_id: string }>(
      "select item_id from item_asset where asset_id = ?",
      [assetId],
    )) {
      this.playbacks.set(`${deviceId} ${item_id}`, { mode, at });
    }
  }

  /** A device sent a title to another one with Play On. */
  notePlayOn(fromDeviceId: string, targetDeviceId: string, itemId: string): void {
    this.playOns.set(`${targetDeviceId} ${itemId}`, { from: fromDeviceId, at: this.now() });
  }

  /**
   * A viewer's place moved. Call inside the transaction that saves it. A sitting goes on while
   * the same device reports the same title without a long pause; otherwise a new one begins.
   */
  noteWatch(
    profileId: string,
    itemId: string,
    before: Place | null,
    now: Place,
    context: WatchContext,
  ): void {
    this.prune();
    const amount = Math.round(watched(before, now));
    const finished = now.completed && !(before?.completed ?? false);
    if (amount <= 0 && !finished) return;
    const at = now.updatedAt;
    if (at < this.oldest) return;
    const item = this.db.get<{ title_id: string }>(
      `select coalesce(above.parent_id, item.parent_id, item.id) as title_id from item
       left join item as above on above.id = item.parent_id and item.kind = 'episode'
       where item.id = ? and item.kind in ('movie', 'episode', 'personal')`,
      [itemId],
    );
    if (!item) return;
    const open = this.db.get<OpenSession>(
      `select id, started_at, ended_at, completed from watch_session
       where profile_id = ? and item_id = ? and ended_at >= ? and device_id is ?
         and started_at <= ?
       order by ended_at desc limit 1`,
      [profileId, itemId, at - SITTING_GAP_MS, context.deviceId, at + SITTING_GAP_MS],
    );
    if (open) {
      this.db.run(
        `update watch_session set ended_at = max(ended_at, ?), started_at = min(started_at, ?),
           watched_ms = watched_ms + ?, position_ms = ?, duration_ms = ?,
           completed = max(completed, ?) where id = ?`,
        [at, at - amount, amount, now.positionMs, now.durationMs, finished ? 1 : 0, open.id],
      );
      return;
    }
    // Marked as watched without watching: that is no sitting.
    if (amount <= 0) return;
    const clock = this.now();
    const playback = this.playbacks.get(`${context.deviceId} ${itemId}`, clock);
    const delivery: Delivery = playback
      ? playback.mode
      : this.downloaded(context.deviceId, itemId)
        ? "download"
        : "unknown";
    const playOn = this.playOns.get(`${context.deviceId} ${itemId}`, clock);
    this.db.run(
      `insert into watch_session (id, profile_id, household_id, device_id, item_id, title_id,
         started_at, ended_at, timed, watched_ms, position_ms, duration_ms, completed, road,
         delivery, play_on_from)
       values (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?)`,
      [
        randomUUID(),
        profileId,
        context.householdId,
        context.deviceId,
        itemId,
        item.title_id,
        at - amount,
        at,
        amount,
        now.positionMs,
        now.durationMs,
        finished ? 1 : 0,
        context.road,
        delivery,
        playOn?.from ?? null,
      ],
    );
  }

  private downloaded(deviceId: string, itemId: string): boolean {
    return (
      this.db.get(
        `select 1 as x from device_download
         join item_asset on item_asset.asset_id = device_download.asset_id
         where device_download.device_id = ? and item_asset.item_id = ?
           and device_download.state = 'downloaded'`,
        [deviceId, itemId],
      ) !== undefined
    );
  }

  /** Bytes of a film or song that went to a device. */
  noteSent(householdId: string, road: Road, bytes: number, at = this.now()): void {
    if (bytes <= 0) return;
    this.db.run(
      `insert into stats_traffic (hour, household_id, road, bytes) values (?, ?, ?, ?)
       on conflict (hour, household_id, road) do update set bytes = bytes + excluded.bytes`,
      [Math.floor(at / 3_600_000), householdId, road, Math.round(bytes)],
    );
  }

  /** A copy for playback is ready. */
  notePrepared(event: {
    assetId: string;
    elapsedMs: number;
    bytes: number;
    converted: boolean;
    background: boolean;
  }): void {
    this.db.run(
      `insert into stats_event (kind, at, asset_id, elapsed_ms, bytes, converted, background)
       values ('prepared', ?, ?, ?, ?, ?, ?)`,
      [
        this.now(),
        event.assetId,
        Math.round(event.elapsedMs),
        Math.round(event.bytes),
        event.converted ? 1 : 0,
        event.background ? 1 : 0,
      ],
    );
  }

  /** A converter took a job: the time it takes is counted from here. */
  noteConversionClaimed(jobId: string): void {
    this.db.run("insert into stats_event (kind, at, job_id) values ('conversion_claimed', ?, ?)", [
      this.now(),
      jobId,
    ]);
  }

  /** A converted file took its original's place. */
  noteConverted(jobId: string, assetId: string, savedBytes: number): void {
    const at = this.now();
    const claimed = this.db.get<{ at: number }>(
      `select max(at) as at from stats_event where job_id = ? and kind = 'conversion_claimed'`,
      [jobId],
    );
    this.db.run(
      `insert into stats_event (kind, at, asset_id, job_id, elapsed_ms, saved_bytes, converted)
       values ('converted', ?, ?, ?, ?, ?, 1)`,
      [at, assetId, jobId, claimed?.at == null ? null : at - claimed.at, Math.round(savedBytes)],
    );
  }

  // ---- Forgetting ----

  /** Once a day: nothing is kept for longer than the household says. */
  prune(force = false): void {
    const now = this.now();
    if (!force && now - this.prunedAt < 3_600_000) return;
    this.prunedAt = now;
    const oldest = this.oldest;
    this.db.transaction(() => {
      this.db.run("delete from watch_session where started_at < ?", [oldest]);
      this.db.run("delete from stats_traffic where hour < ?", [Math.floor(oldest / 3_600_000)]);
      this.db.run("delete from stats_event where at < ?", [oldest]);
      this.db.run("delete from music_play where played_at < ?", [oldest]);
    });
  }

  /** Everything a viewer watched and listened to, as if it never was. Their places stay. */
  forget(profileId: string): void {
    this.db.transaction(() => {
      this.db.run("delete from watch_session where profile_id = ?", [profileId]);
      this.db.run("delete from play where profile_id = ?", [profileId]);
      this.db.run("delete from music_play where profile_id = ?", [profileId]);
    });
  }

  /**
   * One sitting out of a viewer's history. It no longer counts for what is popular either.
   *
   * @returns false when the viewer has no such sitting
   */
  remove(profileId: string, sessionId: string): boolean {
    return this.db.transaction(() => {
      const session = this.db.get<{ item_id: string; started_at: number; ended_at: number }>(
        "select item_id, started_at, ended_at from watch_session where id = ? and profile_id = ?",
        [sessionId, profileId],
      );
      if (!session) return false;
      this.db.run("delete from watch_session where id = ?", [sessionId]);
      // The popular titles count a viewer once a day; that day no longer counts for this one.
      this.db.run(
        `delete from play where profile_id = ? and item_id = ?
           and day between date(? / 1000, 'unixepoch', 'localtime')
             and date(? / 1000, 'unixepoch', 'localtime')`,
        [profileId, session.item_id, session.started_at, session.ended_at],
      );
      return true;
    });
  }
}
