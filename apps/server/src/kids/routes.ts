// SPDX-License-Identifier: MPL-2.0
import type { Hono } from "hono";
import { AuthError, type Device } from "../auth/devices.ts";
import type { Database } from "../db/database.ts";
import { ApiError, readBody, type AppEnv, type Ctx } from "../http/app.ts";
import {
  ControlError,
  type Answer,
  type KidsControl,
  type KidsRequest,
  type Length,
  type RequestKind,
} from "./control.ts";
import {
  ANSWER_MODES,
  isTimeZone,
  MODES,
  PlanError,
  readPlan,
  type AnswerMode,
  type Mode,
  type PlaceState,
} from "./plan.ts";

const MAX_SMALL_BODY = 16 * 1024;
const MAX_PLAN_BODY = 64 * 1024;
const ID = /^[A-Za-z0-9_-]{1,128}$/;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
/** Lengths a grown-up can choose, in minutes. */
const MINUTES = { min: 5, max: 24 * 60 } as const;

export interface KidsRouteDeps {
  db: Database;
  control: KidsControl;
  /** Whether the request came from away (outside, the tailnet). */
  isAway: (c: Ctx) => boolean;
}

/** A question as the grown-ups see it: who asks, for what, and who answered what. */
export function describeRequest(
  db: Database,
  control: KidsControl,
  request: KidsRequest,
): Record<string, unknown> {
  const viewer = db.get<{ name: string; avatar: string | null; color: string }>(
    "select name, avatar, color from profile where id = ?",
    [request.profileId],
  );
  const title =
    request.itemId === null
      ? null
      : (db.get<{ id: string; title: string }>(
          `select id, coalesce(json_extract(override_json, '$.title'), title) as title
           from item where id = ?`,
          [request.itemId],
        ) ?? null);
  const grant =
    request.grantId === null
      ? null
      : (db.get<{ mode: string; until: number; itemId: string | null }>(
          "select mode, until, item_id as itemId from kids_grant where id = ?",
          [request.grantId],
        ) ?? null);
  return {
    ...request,
    viewer: viewer ?? null,
    title,
    answeredByName:
      request.answeredBy === null ? null : control.nameOf(request.profileId, request.answeredBy),
    grant,
  };
}

/** The music libraries there are, for choosing which a child hears. */
function musicLibraries(db: Database): { id: string; name: string; hint: string }[] {
  return db.all("select id, name, hint from music_source order by name, id");
}

function fail(error: unknown): never {
  if (error instanceof ControlError && error.code === "rate_limited") {
    throw new AuthError("rate_limited", error.message, error.retryAfterSeconds ?? 60);
  }
  if (error instanceof ControlError) {
    throw new ApiError(error.code, error.message, {
      reason: error.reason,
      ...(error.retryAfterSeconds === null ? {} : { retryAfter: error.retryAfterSeconds }),
    });
  }
  if (error instanceof PlanError) throw new ApiError("invalid_request", error.message);
  throw error;
}

const attempt = <T>(run: () => T): T => {
  try {
    return run();
  } catch (error) {
    fail(error);
  }
};

function oneOf<T extends string>(value: unknown, allowed: readonly T[], key: string): T {
  if (typeof value !== "string" || !allowed.includes(value as T)) {
    throw new ApiError("invalid_request", `"${key}" must be one of: ${allowed.join(", ")}.`);
  }
  return value as T;
}

/** `minutes`, `until` or `untilNext`; none of them: the default length. */
function length(body: Record<string, unknown>): Length | undefined {
  const { minutes, until, untilNext } = body;
  const given = [minutes, until, untilNext].filter((one) => one !== undefined && one !== null);
  if (given.length > 1) {
    throw new ApiError("invalid_request", `Say one of "minutes", "until" or "untilNext".`);
  }
  if (minutes !== undefined && minutes !== null) {
    if (
      typeof minutes !== "number" ||
      !Number.isInteger(minutes) ||
      minutes < MINUTES.min ||
      minutes > MINUTES.max
    ) {
      throw new ApiError(
        "invalid_request",
        `"minutes" must be whole minutes from ${String(MINUTES.min)} to ${String(MINUTES.max)}.`,
      );
    }
    return { minutes };
  }
  if (until !== undefined && until !== null) {
    if (typeof until !== "number" || !Number.isInteger(until)) {
      throw new ApiError("invalid_request", `"until" must be a time in milliseconds.`);
    }
    return { until };
  }
  if (untilNext === true) return { next: true };
  if (untilNext !== undefined) throw new ApiError("invalid_request", `"untilNext" must be true.`);
  return undefined;
}

export function registerKidsControlRoutes(app: Hono<AppEnv>, deps: KidsRouteDeps): void {
  const { db, control } = deps;

  const notFound = (): ApiError => new ApiError("not_found", "There is no such viewer.");

  /** The child a device speaks for: its own, or the kids viewer its kids screens show. */
  const childOf = (c: Ctx, named: unknown): string => {
    const device = c.get("device");
    if (device.kidsProfileId !== null) return device.kidsProfileId;
    if (typeof named !== "string" || !ID.test(named)) {
      throw new ApiError("invalid_request", `"profileId" must be the id of a kids viewer.`);
    }
    const row = db.get<{ household_id: string }>(
      "select household_id from profile where id = ? and deleted_at is null and kids_json is not null",
      [named],
    );
    if (row?.household_id !== device.householdId) throw notFound();
    return named;
  };

  /** A kids viewer of the device's household that the device may decide for. */
  const decided = (c: Ctx): { device: Device; profileId: string } => {
    const device = c.get("device");
    const profileId = c.req.param("id") ?? "";
    if (!control.isKids(profileId)) throw notFound();
    if (!control.mayDecide(device, profileId)) {
      throw new ApiError("forbidden", "Only an admin of this household can change this.");
    }
    return { device, profileId };
  };

  const view = (profileId: string): Record<string, unknown> => {
    const profile = db.get<{ household_id: string }>(
      "select household_id from profile where id = ?",
      [profileId],
    );
    return {
      profileId,
      plan: control.plan(profileId),
      planned: control.hasPlan(profileId),
      timeZone: control.timeZone(profile?.household_id ?? ""),
      now: control.glance(profileId),
      grants: control.grants(profileId),
      musicLibraries: musicLibraries(db),
      grownUps: control.grownUps(profile?.household_id ?? ""),
      adminDevices: control
        .deciders(profileId, true)
        .filter((one) => one.householdId === profile?.household_id)
        .map((one) => ({ id: one.id, name: one.name })),
    };
  };

  // ---- The child's device, or a grown-up's in kids mode ----

  app.get("/v1/me/kids", (c) => {
    const device = c.get("device");
    const profileId = childOf(c, c.req.query("profileId"));
    const now = control.state(profileId, device.id, deps.isAway(c));
    const waiting = db.get<{ id: string }>(
      `select id from kids_request where profile_id = ? and device_id = ?
       order by created_at desc limit 1`,
      [profileId, device.id],
    );
    const request = waiting ? control.request(waiting.id) : null;
    const profile = db.get<{ household_id: string }>(
      "select household_id from profile where id = ?",
      [profileId],
    );
    return c.json({
      profileId,
      now,
      plan: control.plan(profileId),
      timeZone: control.timeZone(profile?.household_id ?? ""),
      request,
      askNames: control.askNames(profileId),
      musicLibraries: musicLibraries(db),
      signed: control.signed(profileId, device.id),
      publicKey: control.publicKey(),
      serverTime: Date.now(),
    });
  });

  // Where the device is, as far as the places go: never coordinates.
  app.put("/v1/me/kids/place", async (c) => {
    const body = await readBody(c, MAX_SMALL_BODY);
    const profileId = childOf(c, body["profileId"]);
    const allowed = new Set(["state", "placeId", "profileId"]);
    // Anything more, coordinates above all, is refused rather than ignored.
    if (Object.keys(body).some((key) => !allowed.has(key))) {
      throw new ApiError("invalid_request", `Only "state" and "placeId" are told here.`);
    }
    const state = oneOf(body["state"], ["inside", "outside", "unknown"] as const, "state");
    let place: PlaceState;
    if (state === "inside") {
      const placeId = body["placeId"];
      if (typeof placeId !== "string" || !ID.test(placeId)) {
        throw new ApiError("invalid_request", `"placeId" must be the id of a place.`);
      }
      place = { state, placeId };
    } else place = { state };
    control.reportPlace(c.get("device").id, profileId, place);
    return c.json({ now: control.state(profileId, c.get("device").id, deps.isAway(c)) });
  });

  // What was watched offline, counted on the device.
  app.post("/v1/me/kids/screen-time", async (c) => {
    const body = await readBody(c, MAX_SMALL_BODY);
    const profileId = childOf(c, body["profileId"]);
    const { day, seconds } = body;
    if (typeof day !== "string" || !DAY.test(day)) {
      throw new ApiError("invalid_request", `"day" must be a day "YYYY-MM-DD".`);
    }
    if (
      typeof seconds !== "number" ||
      !Number.isFinite(seconds) ||
      seconds < 0 ||
      seconds > 86_400
    ) {
      throw new ApiError("invalid_request", `"seconds" must be seconds of one day.`);
    }
    control.reportScreenTime(profileId, day, seconds);
    return c.body(null, 204);
  });

  app.post("/v1/me/kids/requests", async (c) => {
    const body = await readBody(c, MAX_SMALL_BODY);
    const profileId = childOf(c, body["profileId"]);
    const kind = oneOf<RequestKind>(body["kind"] ?? "open", ["open", "title"], "kind");
    const itemId = body["itemId"];
    if (kind === "title" && (typeof itemId !== "string" || !ID.test(itemId))) {
      throw new ApiError("invalid_request", `"itemId" must be the id of a title.`);
    }
    const request = attempt(() =>
      control.ask(
        profileId,
        c.get("device").id,
        kind,
        kind === "title" ? (itemId as string) : null,
      ),
    );
    return c.json({ request }, 201);
  });

  const ownRequest = (c: Ctx): KidsRequest => {
    const device = c.get("device");
    const request = control.request(c.req.param("id") ?? "");
    if (!request || request.deviceId !== device.id) {
      throw new ApiError("not_found", "There is no such question.");
    }
    return request;
  };

  app.get("/v1/me/kids/requests/:id", (c) => c.json({ request: ownRequest(c) }));

  app.delete("/v1/me/kids/requests/:id", (c) => {
    const request = ownRequest(c);
    return c.json({ request: attempt(() => control.cancel(request.id, request.profileId)) });
  });

  // ---- Grown-ups ----

  app.get("/v1/kids/now", (c) => {
    const { householdId } = c.get("device");
    const kids = db.all<{ id: string }>(
      `select id from profile where household_id = ? and deleted_at is null and kids_json is not null
       order by created_at, id`,
      [householdId],
    );
    return c.json({ viewers: kids.map(({ id }) => ({ profileId: id, now: control.glance(id) })) });
  });

  app.get("/v1/kids/requests", (c) => {
    const device = c.get("device");
    return c.json({
      requests: control.waitingFor(device).map((one) => describeRequest(db, control, one)),
    });
  });

  app.post("/v1/kids/requests/:id/answer", async (c) => {
    const body = await readBody(c, MAX_SMALL_BODY);
    const answer = oneOf<Answer>(body["answer"], ["watch", "listen", "no"], "answer");
    const titleOnly = body["titleOnly"];
    if (titleOnly !== undefined && typeof titleOnly !== "boolean") {
      throw new ApiError("invalid_request", `"titleOnly" must be true or false.`);
    }
    const given = length(body);
    const request = attempt(() =>
      control.answer(c.req.param("id"), c.get("device"), answer, {
        ...(given ? { length: given } : {}),
        ...(titleOnly === undefined ? {} : { titleOnly }),
      }),
    );
    return c.json({ request: describeRequest(db, control, request) });
  });

  app.put("/v1/household/time-zone", async (c) => {
    const device = c.get("device");
    if (device.access === "viewer" || device.kidsProfileId !== null) {
      throw new ApiError("forbidden", "Only an admin of this household can change this.");
    }
    const body = await readBody(c, MAX_SMALL_BODY);
    const zone = body["timeZone"];
    if (zone !== null && (typeof zone !== "string" || !isTimeZone(zone))) {
      throw new ApiError(
        "invalid_request",
        `"timeZone" must be a time zone such as "Europe/Amsterdam", or null.`,
      );
    }
    control.setTimeZone(device.householdId, zone);
    return c.json({ timeZone: control.timeZone(device.householdId) });
  });

  app.get("/v1/profiles/:id/kids/plan", (c) => {
    const profileId = c.req.param("id");
    if (!control.isKids(profileId)) throw notFound();
    return c.json(view(profileId));
  });

  app.put("/v1/profiles/:id/kids/plan", async (c) => {
    const body = await readBody(c, MAX_PLAN_BODY);
    const { device, profileId } = decided(c);
    const plan = attempt(() => readPlan(body["plan"]));
    control.setPlan(profileId, plan, device.id);
    return c.json(view(profileId));
  });

  app.put("/v1/profiles/:id/kids/override", async (c) => {
    const body = await readBody(c, MAX_SMALL_BODY);
    const { device, profileId } = decided(c);
    const mode = oneOf<Mode>(body["mode"], MODES, "mode");
    const given = length(body);
    attempt(() => control.setOverride(profileId, mode, given, device.id));
    return c.json(view(profileId));
  });

  app.delete("/v1/profiles/:id/kids/override", (c) => {
    const { profileId } = decided(c);
    control.endOverride(profileId);
    return c.json(view(profileId));
  });

  // Watch to Listen and back, for the answer that runs.
  app.patch("/v1/profiles/:id/kids/answer", async (c) => {
    const body = await readBody(c, MAX_SMALL_BODY);
    const { profileId } = decided(c);
    const answer = oneOf(body["answer"], ["watch", "listen"] as const, "answer");
    const mode: AnswerMode = answer === "watch" ? ANSWER_MODES[0] : ANSWER_MODES[1];
    attempt(() => control.switchGrant(profileId, mode));
    return c.json(view(profileId));
  });

  app.delete("/v1/profiles/:id/kids/answer", (c) => {
    const { profileId } = decided(c);
    control.endGrants(profileId);
    return c.json(view(profileId));
  });
}
