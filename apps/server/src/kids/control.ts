// SPDX-License-Identifier: MPL-2.0
import {
  createPrivateKey,
  generateKeyPairSync,
  randomUUID,
  sign,
  type KeyObject,
} from "node:crypto";
import type { Device, Devices } from "../auth/devices.ts";
import type { Database } from "../db/database.ts";
import { managesHousehold } from "../auth/devices.ts";
import { kidsLimits } from "./limits.ts";
import {
  localDay,
  NO_PLAN,
  nextSwitch,
  rank,
  resolve,
  serverTimeZone,
  type AnswerMode,
  type Grant,
  type KidsPlan,
  type Mode,
  type ModeNow,
  type Override,
  type PlaceState,
  type PlanContext,
} from "./plan.ts";

/** How long a question waits for a grown-up. */
export const REQUEST_MS = 10 * 60_000;
/** Questions a child may ask in an hour. */
export const REQUESTS_PER_HOUR = 6;
/** An answer or override at most runs this long. */
const LONGEST_MS = 24 * 3_600_000;
/** An answer runs this long when nothing else is said. */
export const DEFAULT_ANSWER_MINUTES = 60;
/** A signed copy of the plan holds this long without the server. */
export const SIGNED_PLAN_MS = 7 * 86_400_000;
/** A place reported longer ago than this is not known any more. */
const PLACE_FRESH_MS = 6 * 3_600_000;
/** Progress reports further apart than this are not one stretch of watching. */
const WATCH_GAP_MS = 120_000;
/** Kept for the screen time of the days before, and for questions. */
const KEEP_MS = 14 * 86_400_000;

export type RequestKind = "open" | "title";

/** What a device said of its lock: Screen Time allowed there, not (yet), or not an iPhone or iPad. */
export const LOCK_STATUSES = ["ready", "notSetUp", "unsupported"] as const;
export type LockStatus = (typeof LOCK_STATUSES)[number];

/** Whether a device of a child is to be locked to Lobby in kids mode, and why. */
export interface LockWish {
  wanted: boolean;
  /** `viewer`: the child's plan says; `device`: a grown-up chose for this device. */
  source: "viewer" | "device";
}

/** A device of a child as its grown-ups see it for Lock to Lobby. */
export interface LockDevice extends LockWish {
  deviceId: string;
  name: string;
  platform: string;
  /** What a grown-up chose for this device; null: as the plan says. */
  choice: boolean | null;
  /** What the device said last; null: nothing yet. */
  status: LockStatus | null;
  /** Whether it said it shields the other apps now. */
  locked: boolean;
  reportedAt: number | null;
}
export type RequestState = "waiting" | "allowed" | "declined" | "expired" | "cancelled";
export type Answer = "watch" | "listen" | "no";

export interface KidsRequest {
  id: string;
  profileId: string;
  deviceId: string;
  kind: RequestKind;
  itemId: string | null;
  state: RequestState;
  createdAt: number;
  expiresAt: number;
  answer: Answer | null;
  answeredBy: string | null;
  answeredAt: number | null;
  grantId: string | null;
}

interface RequestRow {
  id: string;
  profile_id: string;
  device_id: string;
  kind: RequestKind;
  item_id: string | null;
  state: RequestState;
  created_at: number;
  expires_at: number;
  answer: Answer | null;
  answered_by: string | null;
  answered_at: number | null;
  grant_id: string | null;
}

const toRequest = (row: RequestRow): KidsRequest => ({
  id: row.id,
  profileId: row.profile_id,
  deviceId: row.device_id,
  kind: row.kind,
  itemId: row.item_id,
  state: row.state,
  createdAt: row.created_at,
  expiresAt: row.expires_at,
  answer: row.answer,
  answeredBy: row.answered_by,
  answeredAt: row.answered_at,
  grantId: row.grant_id,
});

/** Why something about kids control was refused; the routes say it as an `ApiError`. */
export class ControlError extends Error {
  readonly code: "not_found" | "conflict" | "forbidden" | "rate_limited" | "invalid_request";
  readonly reason: string;
  readonly retryAfterSeconds: number | null;

  constructor(
    code: ControlError["code"],
    reason: string,
    message: string,
    retryAfterSeconds: number | null = null,
  ) {
    super(message);
    this.code = code;
    this.reason = reason;
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

export type KidsEvent =
  | { type: "changed"; profileId: string }
  | { type: "request"; request: KidsRequest }
  | { type: "requestClosed"; request: KidsRequest };

/** How long an answer or override runs: minutes, until a moment, or until the plan switches. */
export type Length = { minutes: number } | { until: number } | { next: true };

/** The signed copy of a plan for a child's device (docs/api.md, Kids control). */
export interface SignedPlan {
  payload: string;
  signature: string;
}

interface ProfileRow {
  household_id: string;
  kids: number;
  name: string;
}

/**
 * Plans, overrides, answers, questions and screen time of the kids viewers, and what that makes
 * of the moment (docs/kids-control.md). One per catalogue, shared by both entrances.
 */
export class KidsControl {
  private readonly db: Database;
  private readonly devices: Devices;
  private readonly now: () => number;
  private readonly listeners = new Set<(event: KidsEvent) => void>();
  /** Whether each device came in last from away: the outside entrance, the tailnet. */
  private readonly roads = new Map<string, boolean>();
  /** What each device said of the places, and when. Never coordinates; only the last one. */
  private readonly places = new Map<string, { profileId: string; place: PlaceState; at: number }>();
  /** The last progress report per viewer, to count what was watched. */
  private readonly watching = new Map<string, { itemId: string; positionMs: number; at: number }>();
  private readonly told = new Map<string, string>();
  private key: KeyObject | null = null;
  private timer: NodeJS.Timeout | null = null;

  constructor(db: Database, devices: Devices, now: () => number = Date.now) {
    this.db = db;
    this.devices = devices;
    this.now = now;
  }

  on(listener: (event: KidsEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private emit(event: KidsEvent): void {
    for (const listener of this.listeners) listener(event);
  }

  private changed(profileId: string): void {
    this.emit({ type: "changed", profileId });
  }

  // ---- Who ----

  private profile(profileId: string): ProfileRow | null {
    return (
      this.db.get<ProfileRow>(
        `select household_id, kids_json is not null as kids, name from profile
         where id = ? and deleted_at is null`,
        [profileId],
      ) ?? null
    );
  }

  /** Whether this is a kids viewer that is there. */
  isKids(profileId: string): boolean {
    return this.profile(profileId)?.kids === 1;
  }

  /** Grown-ups' devices that may decide for this child: its household's admins. */
  deciders(profileId: string, everyone = false): Device[] {
    const profile = this.profile(profileId);
    if (!profile) return [];
    const asked = new Set(everyone ? [] : this.plan(profileId).askDevices);
    // The child's household's admins, and the server's admins, also for a guest's child.
    return this.devices
      .list()
      .filter(
        (one) =>
          one.revokedAt === null &&
          one.kidsProfileId === null &&
          (one.access === "admin" ||
            (one.householdId === profile.household_id && managesHousehold(one.access))) &&
          (asked.size === 0 || asked.has(one.id)),
      );
  }

  /** Who the child's screen says it asks: the chosen grown-ups, else all of its household's. */
  askNames(profileId: string): string[] {
    const profile = this.profile(profileId);
    if (!profile) return [];
    const chosen = this.plan(profileId).askers.map((one) => one.profileId);
    return this.grownUps(profile.household_id)
      .filter((one) => chosen.length === 0 || chosen.includes(one.profileId))
      .map((one) => one.name);
  }

  /** The household's viewers that are no kids viewers. */
  grownUps(householdId: string): { profileId: string; name: string }[] {
    return this.db.all<{ profileId: string; name: string }>(
      `select id as profileId, name from profile
       where household_id = ? and deleted_at is null and kids_json is null order by created_at, rowid`,
      [householdId],
    );
  }

  /** The name a grown-up's answer goes by: the asker the device belongs to, else the device. */
  nameOf(profileId: string, deviceId: string): string | null {
    const asker = this.plan(profileId).askers.find((one) => one.deviceIds.includes(deviceId));
    if (asker) {
      const name = this.db.get<{ name: string }>("select name from profile where id = ?", [
        asker.profileId,
      ])?.name;
      if (name) return name;
    }
    return this.devices.find(deviceId)?.name ?? null;
  }

  /** Whether this device may set the plan of, and answer for, this child. */
  mayDecide(device: Device, profileId: string): boolean {
    const profile = this.profile(profileId);
    return (
      profile !== null &&
      profile.kids === 1 &&
      device.kidsProfileId === null &&
      (device.access === "admin" || device.householdId === profile.household_id) &&
      managesHousehold(device.access)
    );
  }

  // ---- The plan ----

  hasPlan(profileId: string): boolean {
    return (
      this.db.get("select 1 as x from kids_plan where profile_id = ?", [profileId]) !== undefined
    );
  }

  plan(profileId: string): KidsPlan {
    const row = this.db.get<{ plan_json: string }>(
      "select plan_json from kids_plan where profile_id = ?",
      [profileId],
    );
    return row ? { ...NO_PLAN, ...(JSON.parse(row.plan_json) as KidsPlan) } : NO_PLAN;
  }

  setPlan(profileId: string, plan: KidsPlan, by: string): void {
    this.db.run(
      `insert into kids_plan (profile_id, plan_json, updated_at, updated_by) values (?, ?, ?, ?)
       on conflict (profile_id) do update set plan_json = excluded.plan_json,
         updated_at = excluded.updated_at, updated_by = excluded.updated_by`,
      [profileId, JSON.stringify(plan), this.now(), by],
    );
    this.changed(profileId);
  }

  timeZone(householdId: string): string {
    return (
      this.db.get<{ time_zone: string | null }>("select time_zone from household where id = ?", [
        householdId,
      ])?.time_zone ?? serverTimeZone()
    );
  }

  setTimeZone(householdId: string, timeZone: string | null): void {
    this.db.run("update household set time_zone = ? where id = ?", [timeZone, householdId]);
    for (const row of this.db.all<{ id: string }>(
      "select id from profile where household_id = ? and deleted_at is null and kids_json is not null",
      [householdId],
    )) {
      this.changed(row.id);
    }
  }

  /** Forgets everything of a viewer that is gone. */
  forget(profileId: string): void {
    for (const table of [
      "kids_lock",
      "kids_plan",
      "kids_override",
      "kids_grant",
      "kids_request",
      "kids_screen_time",
    ]) {
      this.db.run(`delete from ${table} where profile_id = ?`, [profileId]);
    }
    for (const [id, one] of this.places) if (one.profileId === profileId) this.places.delete(id);
    this.watching.delete(profileId);
  }

  // ---- Lock to Lobby ----

  private lockRow(
    profileId: string,
    deviceId: string,
  ):
    | {
        wanted: number | null;
        status: LockStatus | null;
        locked: number;
        reported_at: number | null;
      }
    | undefined {
    return this.db.get(
      "select wanted, status, locked, reported_at from kids_lock where profile_id = ? and device_id = ?",
      [profileId, deviceId],
    );
  }

  /** Whether this device is to be locked to Lobby while this child is in front in kids mode. */
  lockWish(profileId: string, deviceId: string): LockWish {
    if (!this.isKids(profileId)) return { wanted: false, source: "viewer" };
    const chosen = this.lockRow(profileId, deviceId)?.wanted ?? null;
    if (chosen !== null) return { wanted: chosen === 1, source: "device" };
    return { wanted: this.plan(profileId).lockToLobby, source: "viewer" };
  }

  /**
   * The devices a child uses, for the grown-ups' switches: those bound to it, and those that
   * said something of their lock while it was in front.
   */
  lockDevices(profileId: string): LockDevice[] {
    const profile = this.profile(profileId);
    if (!profile) return [];
    const rows = new Map(
      this.db
        .all<{
          device_id: string;
          wanted: number | null;
          status: LockStatus | null;
          locked: number;
          reported_at: number | null;
        }>(
          "select device_id, wanted, status, locked, reported_at from kids_lock where profile_id = ?",
          [profileId],
        )
        .map((row) => [row.device_id, row]),
    );
    return this.devices
      .list()
      .filter(
        (one) =>
          one.revokedAt === null &&
          one.householdId === profile.household_id &&
          (one.kidsProfileId === profileId || (one.kidsProfileId === null && rows.has(one.id))),
      )
      .map((one) => {
        const row = rows.get(one.id);
        return {
          deviceId: one.id,
          name: one.name,
          platform: one.platform,
          ...this.lockWish(profileId, one.id),
          choice: row?.wanted === null || row?.wanted === undefined ? null : row.wanted === 1,
          status: row?.status ?? null,
          locked: row?.locked === 1,
          reportedAt: row?.reported_at ?? null,
        };
      });
  }

  /** Whether a grown-up may switch this device's lock for this child. */
  isLockDevice(profileId: string, deviceId: string): boolean {
    return this.lockDevices(profileId).some((one) => one.deviceId === deviceId);
  }

  /** A grown-up's choice for one device: locked, not locked, or (null) as the plan says. */
  setLock(profileId: string, deviceId: string, wanted: boolean | null): void {
    const value = wanted === null ? null : wanted ? 1 : 0;
    this.db.run(
      `insert into kids_lock (profile_id, device_id, wanted, updated_at) values (?, ?, ?, ?)
       on conflict (profile_id, device_id) do update set wanted = excluded.wanted,
         updated_at = excluded.updated_at`,
      [profileId, deviceId, value, this.now()],
    );
    this.changed(profileId);
  }

  /** What a device says of its lock. Kept, so that the grown-ups see it after a restart too. */
  reportLock(profileId: string, deviceId: string, status: LockStatus, locked: boolean): void {
    const now = this.now();
    this.db.run(
      `insert into kids_lock (profile_id, device_id, status, locked, reported_at, updated_at)
       values (?, ?, ?, ?, ?, ?)
       on conflict (profile_id, device_id) do update set status = excluded.status,
         locked = excluded.locked, reported_at = excluded.reported_at,
         updated_at = excluded.updated_at`,
      [profileId, deviceId, status, locked ? 1 : 0, now, now],
    );
  }

  // ---- Where ----

  /** Notes the road a device came in by: at home, or away (outside, the tailnet). */
  noteRoad(deviceId: string, away: boolean): void {
    if (this.roads.get(deviceId) === away) return;
    this.roads.set(deviceId, away);
    const device = this.devices.find(deviceId);
    if (device?.kidsProfileId) this.changed(device.kidsProfileId);
  }

  /** Away unless it came in at home last. A device never seen is away: fail closed. */
  isAway(deviceId: string, outside = false): boolean {
    return outside || (this.roads.get(deviceId) ?? true);
  }

  /** What a child's device says of the places: never where it is, only inside which. */
  reportPlace(deviceId: string, profileId: string, place: PlaceState): void {
    const before = this.places.get(deviceId);
    this.places.set(deviceId, { profileId, place, at: this.now() });
    if (JSON.stringify(before?.place) !== JSON.stringify(place)) this.changed(profileId);
  }

  private placeOf(deviceId: string | null, profileId: string): PlaceState {
    const known = deviceId === null ? undefined : this.places.get(deviceId);
    if (!known || known.profileId !== profileId || this.now() - known.at > PLACE_FRESH_MS) {
      return { state: "unknown" };
    }
    return known.place;
  }

  // ---- Now ----

  private override(profileId: string): Override | null {
    const row = this.db.get<{ mode: Mode; until: number; set_by: string; set_at: number }>(
      "select mode, until, set_by, set_at from kids_override where profile_id = ? and until > ?",
      [profileId, this.now()],
    );
    return row ? { mode: row.mode, until: row.until, setBy: row.set_by, setAt: row.set_at } : null;
  }

  grants(profileId: string): Grant[] {
    return this.db
      .all<{
        id: string;
        mode: AnswerMode;
        item_id: string | null;
        until: number;
        by: string;
        at: number;
      }>(
        "select id, mode, item_id, until, by, at from kids_grant where profile_id = ? and until > ? order by at",
        [profileId, this.now()],
      )
      .map((row) => ({
        id: row.id,
        mode: row.mode,
        itemId: row.item_id,
        until: row.until,
        by: row.by,
        at: row.at,
      }));
  }

  private videoSeconds(profileId: string, day: string): number {
    return (
      this.db.get<{ seconds: number }>(
        "select seconds from kids_screen_time where profile_id = ? and day = ?",
        [profileId, day],
      )?.seconds ?? 0
    );
  }

  context(profileId: string, deviceId: string | null, away: boolean): PlanContext {
    const profile = this.profile(profileId);
    return {
      timeZone: this.timeZone(profile?.household_id ?? ""),
      away,
      place: this.placeOf(deviceId, profileId),
      videoSeconds: (day) => this.videoSeconds(profileId, day),
      override: this.override(profileId),
      grants: this.grants(profileId),
    };
  }

  /**
   * What this child may do now, on this device and road. For a viewer that is gone or no longer
   * a kids viewer the plan says nothing: its limits already give it nothing (docs/decisions.md, "Kids limits").
   */
  state(profileId: string, deviceId: string | null, away: boolean): ModeNow {
    const now = this.now();
    if (!this.isKids(profileId)) return resolve(NO_PLAN, this.context(profileId, null, away), now);
    return resolve(this.plan(profileId), this.context(profileId, deviceId, away), now);
  }

  /** For a device bound to a child: what it may do now. Null for any other device. */
  stateOf(device: Device, outside = false): ModeNow | null {
    if (device.kidsProfileId === null) return null;
    return this.state(device.kidsProfileId, device.id, this.isAway(device.id, outside));
  }

  /** For a grown-up's glance: the strictest of the child's own devices, else as it is known. */
  glance(profileId: string): ModeNow {
    const bound = this.devices
      .list()
      .filter((one) => one.kidsProfileId === profileId && one.revokedAt === null);
    const states = bound.map((one) => this.state(profileId, one.id, this.isAway(one.id)));
    if (states.length === 0) return this.state(profileId, null, false);
    return states.reduce((a, b) => (rank(b.mode) > rank(a.mode) ? b : a));
  }

  // ---- Grown-ups ----

  private length(profileId: string, length: Length | undefined, fallbackMinutes: number): number {
    const now = this.now();
    let until: number;
    if (!length) {
      // Until the plan's next switch when that is today, else for a while.
      const next = nextSwitch(this.plan(profileId), this.context(profileId, null, false), now);
      const zone = this.timeZone(this.profile(profileId)?.household_id ?? "");
      until =
        next !== null && localDay(zone, next) === localDay(zone, now) && next - now <= LONGEST_MS
          ? next
          : now + fallbackMinutes * 60_000;
    } else if ("minutes" in length) until = now + length.minutes * 60_000;
    else if ("until" in length) until = length.until;
    else {
      const next = nextSwitch(this.plan(profileId), this.context(profileId, null, false), now);
      if (next === null) {
        throw new ControlError("conflict", "no_switch", "The plan does not switch within a week.");
      }
      until = next;
    }
    if (until <= now || until > now + LONGEST_MS) {
      throw new ControlError("invalid_request", "length", "That must end within a day.");
    }
    return until;
  }

  setOverride(profileId: string, mode: Mode, length: Length | undefined, by: string): Override {
    const until = this.length(profileId, length, DEFAULT_ANSWER_MINUTES);
    const override = { mode, until, setBy: by, setAt: this.now() };
    this.db.run(
      `insert into kids_override (profile_id, mode, until, set_by, set_at) values (?, ?, ?, ?, ?)
       on conflict (profile_id) do update set mode = excluded.mode, until = excluded.until,
         set_by = excluded.set_by, set_at = excluded.set_at`,
      [profileId, mode, until, by, override.setAt],
    );
    this.changed(profileId);
    return override;
  }

  endOverride(profileId: string): void {
    this.db.run("delete from kids_override where profile_id = ?", [profileId]);
    this.changed(profileId);
  }

  /** Changes what the running answer for the whole app gives, Watch to Listen or back. */
  switchGrant(profileId: string, mode: AnswerMode): Grant {
    const running = this.grants(profileId).filter((one) => one.itemId === null);
    const latest = running.at(-1);
    if (!latest) throw new ControlError("conflict", "no_answer", "No answer is running.");
    this.db.run("update kids_grant set mode = ? where id = ?", [mode, latest.id]);
    this.changed(profileId);
    return { ...latest, mode };
  }

  /** Ends every answer that runs: the child asks again. */
  endGrants(profileId: string): void {
    this.db.run("update kids_grant set until = ? where profile_id = ? and until > ?", [
      this.now(),
      profileId,
      this.now(),
    ]);
    this.changed(profileId);
  }

  // ---- Questions ----

  request(id: string): KidsRequest | null {
    this.expire();
    const row = this.db.get<RequestRow>("select * from kids_request where id = ?", [id]);
    return row ? toRequest(row) : null;
  }

  /** The questions that wait for this grown-up. */
  waitingFor(device: Device): KidsRequest[] {
    this.expire();
    return this.db
      .all<RequestRow>("select * from kids_request where state = 'waiting' order by created_at")
      .map(toRequest)
      .filter((one) => this.deciders(one.profileId).some((d) => d.id === device.id));
  }

  /**
   * A child asks. One question at a time: the same question again is the one that waits, another
   * one takes its place. Only when the mode is Ask first, and only for a title it may see.
   */
  ask(profileId: string, deviceId: string, kind: RequestKind, itemId: string | null): KidsRequest {
    this.expire();
    if (!this.isKids(profileId)) {
      throw new ControlError("not_found", "not_found", "There is no such viewer.");
    }
    const state = this.state(profileId, deviceId, this.isAway(deviceId));
    if (state.mode !== "ask") {
      throw new ControlError("conflict", "not_asking", "Nothing needs asking now.");
    }
    if (kind === "title") {
      if (itemId === null || !kidsLimits(this.db).view(profileId).items.has(itemId)) {
        throw new ControlError("not_found", "not_found", "There is no such title.");
      }
    } else itemId = null;
    const waiting = this.db.get<RequestRow>(
      "select * from kids_request where profile_id = ? and state = 'waiting'",
      [profileId],
    );
    if (waiting && waiting.kind === kind && waiting.item_id === itemId) return toRequest(waiting);
    const now = this.now();
    const asked = this.db.all<{ created_at: number }>(
      "select created_at from kids_request where profile_id = ? and created_at > ? order by created_at",
      [profileId, now - 3_600_000],
    );
    if (asked.length >= REQUESTS_PER_HOUR) {
      const first = asked[0]?.created_at ?? now;
      const wait = Math.max(1, Math.ceil((first + 3_600_000 - now) / 1000));
      throw new ControlError("rate_limited", "asked_too_often", "That was a lot of asking.", wait);
    }
    if (waiting) this.close(waiting.id, "cancelled");
    const request: KidsRequest = {
      id: randomUUID(),
      profileId,
      deviceId,
      kind,
      itemId,
      state: "waiting",
      createdAt: now,
      expiresAt: now + REQUEST_MS,
      answer: null,
      answeredBy: null,
      answeredAt: null,
      grantId: null,
    };
    this.db.run(
      `insert into kids_request (id, profile_id, device_id, kind, item_id, state, created_at, expires_at)
       values (?, ?, ?, ?, ?, 'waiting', ?, ?)`,
      [request.id, profileId, deviceId, kind, itemId, now, request.expiresAt],
    );
    this.emit({ type: "request", request });
    return request;
  }

  /** The child takes its question back. */
  cancel(id: string, profileId: string): KidsRequest {
    const request = this.request(id);
    if (!request || request.profileId !== profileId) {
      throw new ControlError("not_found", "not_found", "There is no such question.");
    }
    return request.state === "waiting" ? this.close(id, "cancelled") : request;
  }

  private close(id: string, state: RequestState, answer?: Partial<RequestRow>): KidsRequest {
    this.db.run(
      `update kids_request set state = ?, answer = ?, answered_by = ?, answered_at = ?, grant_id = ?
       where id = ? and state = 'waiting'`,
      [
        state,
        answer?.answer ?? null,
        answer?.answered_by ?? null,
        answer?.answered_at ?? null,
        answer?.grant_id ?? null,
        id,
      ],
    );
    const row = this.db.get<RequestRow>("select * from kids_request where id = ?", [id]);
    if (!row) throw new ControlError("not_found", "not_found", "There is no such question.");
    const request = toRequest(row);
    this.emit({ type: "requestClosed", request });
    return request;
  }

  /**
   * A grown-up answers. The first answer counts: a question that was answered, taken back or
   * expired is `409` with what came of it.
   */
  answer(
    id: string,
    by: Device,
    answer: Answer,
    options: { length?: Length; titleOnly?: boolean } = {},
  ): KidsRequest {
    const request = this.request(id);
    if (!request || !this.deciders(request.profileId).some((one) => one.id === by.id)) {
      throw new ControlError("not_found", "not_found", "There is no such question.");
    }
    if (request.state !== "waiting") {
      throw new ControlError("conflict", request.state, "This question was answered already.");
    }
    const now = this.now();
    if (answer === "no") {
      return this.close(id, "declined", { answer, answered_by: by.id, answered_at: now });
    }
    const titleOnly = request.kind === "title" && options.titleOnly !== false;
    if (request.kind === "title" && answer === "listen") {
      throw new ControlError("invalid_request", "answer", "A title is answered with watch or no.");
    }
    const until = this.length(request.profileId, options.length, DEFAULT_ANSWER_MINUTES);
    const grant: Grant = {
      id: randomUUID(),
      mode: answer === "watch" ? "everything" : "listening",
      itemId: titleOnly ? request.itemId : null,
      until,
      by: by.id,
      at: now,
    };
    this.db.run(
      `insert into kids_grant (id, profile_id, mode, item_id, until, by, at, request_id)
       values (?, ?, ?, ?, ?, ?, ?, ?)`,
      [grant.id, request.profileId, grant.mode, grant.itemId, until, by.id, now, id],
    );
    const closed = this.close(id, "allowed", {
      answer,
      answered_by: by.id,
      answered_at: now,
      grant_id: grant.id,
    });
    this.changed(request.profileId);
    return closed;
  }

  private expire(): void {
    const now = this.now();
    for (const row of this.db.all<{ id: string }>(
      "select id from kids_request where state = 'waiting' and expires_at <= ?",
      [now],
    )) {
      this.close(row.id, "expired");
    }
  }

  // ---- Screen time ----

  /** A progress report of a kids viewer: what lies between two close ones was watched. */
  countProgress(profileId: string, itemId: string, positionMs: number): void {
    if (!this.isKids(profileId)) return;
    const now = this.now();
    const before = this.watching.get(profileId);
    this.watching.set(profileId, { itemId, positionMs, at: now });
    if (!before || before.itemId !== itemId) return;
    const elapsed = now - before.at;
    const moved = positionMs - before.positionMs;
    if (elapsed <= 0 || elapsed > WATCH_GAP_MS || moved <= 0) return;
    // Never more than the time that passed: seeking ahead is not watching.
    this.addVideo(profileId, Math.min(moved, elapsed) / 1000);
  }

  private addVideo(profileId: string, seconds: number): void {
    const profile = this.profile(profileId);
    if (!profile || seconds <= 0) return;
    const day = localDay(this.timeZone(profile.household_id), this.now());
    const before = this.videoSeconds(profileId, day);
    this.db.run(
      `insert into kids_screen_time (profile_id, day, seconds) values (?, ?, ?)
       on conflict (profile_id, day) do update set seconds = seconds + excluded.seconds`,
      [profileId, day, Math.round(seconds)],
    );
    const limit = this.plan(profileId).screenTime;
    if (limit) {
      // Told when the day's minutes run out.
      const state = this.state(profileId, null, false);
      const used = state.screenTime?.limitMinutes;
      if (
        used !== null &&
        used !== undefined &&
        before < used * 60 &&
        before + seconds >= used * 60
      ) {
        this.changed(profileId);
      }
    }
  }

  /** What a device counted offline: the larger of the two counts holds. */
  reportScreenTime(profileId: string, day: string, seconds: number): void {
    this.db.run(
      `insert into kids_screen_time (profile_id, day, seconds) values (?, ?, ?)
       on conflict (profile_id, day) do update set seconds = max(seconds, excluded.seconds)`,
      [profileId, day, Math.round(seconds)],
    );
    this.changed(profileId);
  }

  // ---- For the device, offline ----

  private signingKey(): KeyObject {
    if (this.key) return this.key;
    let pem = this.db.getMeta("kids_plan_key");
    if (pem === undefined) {
      const { privateKey } = generateKeyPairSync("ed25519");
      pem = privateKey.export({ type: "pkcs8", format: "pem" }).toString();
      this.db.setMeta("kids_plan_key", pem);
    }
    this.key = createPrivateKey(pem);
    return this.key;
  }

  /** The key a device checks the signed plan with: Ed25519, raw, base64url. */
  publicKey(): string {
    const jwk = this.signingKey().export({ format: "jwk" });
    return String(jwk.x);
  }

  /** What the device keeps for when it is offline, signed. */
  signed(profileId: string, deviceId: string): SignedPlan {
    const now = this.now();
    const profile = this.profile(profileId);
    const timeZone = this.timeZone(profile?.household_id ?? "");
    const day = localDay(timeZone, now);
    const payload = Buffer.from(
      JSON.stringify({
        v: 1,
        profileId,
        deviceId,
        issuedAt: now,
        validUntil: now + SIGNED_PLAN_MS,
        timeZone,
        plan: this.isKids(profileId)
          ? this.plan(profileId)
          : { ...NO_PLAN, defaultMode: "nothing" },
        override: this.override(profileId),
        grants: this.grants(profileId),
        screenTime: { day, seconds: this.videoSeconds(profileId, day) },
        // Offline too: a lock switched on stays on until the device hears otherwise.
        lock: this.lockWish(profileId, deviceId).wanted,
      }),
    );
    return {
      payload: payload.toString("base64url"),
      signature: sign(null, payload, this.signingKey()).toString("base64url"),
    };
  }

  // ---- The clock ----

  /** Looks whether anything switched by the clock, and tells who needs to know. */
  tick(): void {
    this.expire();
    const now = this.now();
    const kids = this.db.all<{ id: string }>(
      "select id from profile where deleted_at is null and kids_json is not null",
    );
    for (const { id } of kids) {
      const state = this.glance(id);
      const key = JSON.stringify([
        state.mode,
        state.browse,
        state.video,
        state.listening,
        state.titles,
        state.until,
      ]);
      if (this.told.get(id) !== key) {
        this.told.set(id, key);
        this.changed(id);
      }
    }
    this.db.run("delete from kids_request where created_at < ?", [now - KEEP_MS]);
    this.db.run("delete from kids_grant where until < ?", [now - KEEP_MS]);
    this.db.run("delete from kids_override where until < ?", [now]);
    this.db.run("delete from kids_screen_time where day < ?", [
      new Date(now - KEEP_MS).toISOString().slice(0, 10),
    ]);
  }

  start(everyMs = 5_000): void {
    if (this.timer) return;
    this.timer = setInterval(() => {
      try {
        this.tick();
      } catch {
        // The catalogue was closed: nothing more to look at.
        this.stop();
      }
    }, everyMs);
    this.timer.unref();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }
}

const controls = new WeakMap<Database, KidsControl>();

/** The kids control of this catalogue, shared by everything that answers from it. */
export function kidsControl(db: Database, devices: Devices, now?: () => number): KidsControl {
  let found = controls.get(db);
  if (!found) {
    found = new KidsControl(db, devices, now);
    controls.set(db, found);
  }
  return found;
}
