// SPDX-License-Identifier: MPL-2.0
import { BlockList, isIPv6 } from "node:net";
import type { Hono } from "hono";
import type { Device } from "../auth/devices.ts";
import type { Database } from "../db/database.ts";
import { ApiError, type AppEnv, type Ctx } from "../http/app.ts";
import { peerAddress } from "../http/home.ts";
import { OWNER_HOUSEHOLD } from "../households/owner.ts";
import { RateLimiter } from "../outside/limits.ts";
import { RANGES, rangeOf, StatsReader, type RangeName } from "./aggregate.ts";
import type { Road, Statistics } from "./recorder.ts";
import { Clock, isTimeZone, serverTimeZone } from "./time.ts";

const TAILNET = new BlockList();
TAILNET.addSubnet("100.64.0.0", 10, "ipv4");
TAILNET.addSubnet("fd7a:115c:a1e0::", 48, "ipv6");

/** Which way a request came in. */
export function roadOf(c: { env: AppEnv["Bindings"] | undefined }): Road {
  const outside = c.env?.outside;
  if (outside) {
    if (outside.transport === "direct") return "direct";
    if (outside.transport === "relay") return "relay";
    return "unknown";
  }
  const peer = peerAddress(c);
  if (peer === null) return "home";
  return TAILNET.check(peer, isIPv6(peer) ? "ipv6" : "ipv4") ? "tailnet" : "home";
}

/**
 * What of the server's page a household's overview has: its own watching, and nothing of the
 * server, its drive or other households. A list of what goes in, so a new part stays out.
 */
const HOUSEHOLD_FIELDS = [
  "range",
  "household",
  "totals",
  "days",
  "heatmap",
  "hours",
  "topTitles",
  "viewers",
  "devices",
  "roads",
  "deliveries",
  "traffic",
  "playOn",
] as const;

/** Per device: a person looks at a page now and then, and a page asks once. */
export const STATS_RATE = { burst: 30, perMinute: 20 } as const;

export interface StatsRouteDeps {
  db: Database;
  stats: Statistics;
  /** How full the server's caches and drive are, for the server page. */
  storage?: () => Record<string, number | null>;
  requireManager: (c: Ctx, action: string) => Device;
  requireHouseholdAdmin: (c: Ctx, action: string) => Device;
  /**
   * The viewer a device's app last said was in front (the live channel), or null. A device
   * that is not an admin sees only that viewer's statistics.
   */
  inFront: (deviceId: string) => string | null;
  now: () => number;
}

/**
 * Statistics (docs/api.md, Statistics; docs/decisions.md, "Who sees which statistics"). A server
 * admin sees every viewer's and the server's; a household admin their household's viewers and
 * its overview; anyone else only the viewer in front on their device, never a child's. A kids
 * device, and a device while a child is in front, sees none.
 */
export function registerStatsRoutes(app: Hono<AppEnv>, deps: StatsRouteDeps): void {
  const { db, stats, now } = deps;
  const reader = new StatsReader(db);
  const limiter = new RateLimiter(STATS_RATE, now);

  const take = (c: Ctx): void => {
    const wait = limiter.take(c.get("device").id);
    if (wait > 0) {
      c.header("Retry-After", String(wait));
      throw new ApiError("rate_limited", "Statistics were asked for often. Try again in a moment.");
    }
  };

  interface Viewer {
    id: string;
    name: string;
    color: string;
    avatar: string | null;
    kids: boolean;
  }

  const isKids = (profileId: string): boolean =>
    db.get<{ kids: number }>("select kids_json is not null as kids from profile where id = ?", [
      profileId,
    ])?.kids === 1;

  /** No statistics on a child's device, nor while a child is in front on a grown-up's. */
  const notAsChild = (c: Ctx): void => {
    const device = c.get("device");
    // The kids guard has already said 404 to a kids device; this is in case it ever does not.
    if (device.kidsProfileId !== null) throw new ApiError("not_found", "There is no such viewer.");
    const front = deps.inFront(device.id);
    if (front !== null && isKids(front)) {
      throw new ApiError("forbidden", "There are no statistics in kids mode.");
    }
  };

  /** The viewer `:id`, if this device may see their statistics. */
  const viewer = (c: Ctx): Viewer => {
    notAsChild(c);
    const device = c.get("device");
    const row = db.get<{
      id: string;
      name: string;
      color: string;
      avatar: string | null;
      kids: number;
      household_id: string;
    }>(
      `select id, name, color, avatar, kids_json is not null as kids, household_id from profile
       where id = ? and deleted_at is null`,
      [c.req.param("id") ?? ""],
    );
    // The household guard lets one that is nobody's through: it is not there either. A server
    // admin sees the viewers of every household.
    if (!row || (row.household_id !== device.householdId && device.access !== "admin")) {
      throw new ApiError("not_found", "There is no such viewer.");
    }
    if (device.access === "viewer") {
      if (row.kids === 1) {
        throw new ApiError("forbidden", "A child's statistics are for the household's admins.");
      }
      if (deps.inFront(device.id) !== row.id) {
        throw new ApiError(
          "forbidden",
          "Only your own statistics: choose yourself as the viewer on this device.",
        );
      }
    }
    return {
      id: row.id,
      name: row.name,
      color: row.color,
      avatar: row.avatar,
      kids: row.kids === 1,
    };
  };

  const clockOf = (c: Ctx): Clock => {
    const zone = c.req.query("tz") ?? serverTimeZone();
    if (!isTimeZone(zone)) {
      throw new ApiError("invalid_request", `"tz" must be a time zone such as Europe/Amsterdam.`);
    }
    return new Clock(zone);
  };

  const rangeName = (c: Ctx): RangeName => {
    const name = c.req.query("range") ?? "month";
    if (!(RANGES as readonly string[]).includes(name)) {
      throw new ApiError("invalid_request", `"range" must be one of: ${RANGES.join(", ")}.`);
    }
    return name as RangeName;
  };

  app.get("/v1/stats/viewers/:id", (c) => {
    const who = viewer(c);
    const name = rangeName(c);
    const clock = clockOf(c);
    take(c);
    stats.prune();
    const range = rangeOf(name, clock, now(), stats.oldest);
    return c.json({
      viewer: who,
      keptDays: stats.kept,
      // Always false: older apps read it, from when a child's device had a page of its own.
      simple: false,
      ...reader.viewer(who.id, range, clock, { view: c.get("kids"), oldest: stats.oldest }),
    });
  });

  app.delete("/v1/stats/viewers/:id/history/:session", (c) => {
    const who = viewer(c);
    if (!stats.remove(who.id, c.req.param("session"))) {
      throw new ApiError("not_found", "That is not in this viewer's history.");
    }
    return c.body(null, 204);
  });

  app.delete("/v1/stats/viewers/:id", (c) => {
    deps.requireHouseholdAdmin(c, "forget a viewer's history");
    const who = viewer(c);
    stats.forget(who.id);
    return c.body(null, 204);
  });

  app.get("/v1/stats/household", (c) => {
    const device = deps.requireHouseholdAdmin(c, "see the household's statistics");
    notAsChild(c);
    const name = rangeName(c);
    const clock = clockOf(c);
    const asked = c.req.query("household") ?? device.householdId;
    // A household admin has their own; a server admin opens any.
    if (asked !== device.householdId && device.access !== "admin") {
      throw new ApiError("not_found", "There is no such household.");
    }
    if (!db.get("select 1 as x from household where id = ? and removed_at is null", [asked])) {
      throw new ApiError("not_found", "There is no such household.");
    }
    take(c);
    stats.prune();
    const range = rangeOf(name, clock, now(), stats.oldest);
    const all = reader.server(range, clock, {
      householdId: asked,
      ownerHouseholdId: OWNER_HOUSEHOLD,
      storage: {},
      only: asked,
      view: asked === device.householdId ? c.get("kids") : null,
    });
    return c.json({
      keptDays: stats.kept,
      ...Object.fromEntries(HOUSEHOLD_FIELDS.map((key) => [key, all[key]])),
    });
  });

  app.get("/v1/stats/server", (c) => {
    deps.requireManager(c, "see the server's statistics");
    notAsChild(c);
    const name = rangeName(c);
    const clock = clockOf(c);
    const asked = c.req.query("household");
    let householdId: string | null = null;
    if (asked !== undefined && asked !== OWNER_HOUSEHOLD) {
      const known = db.get("select 1 as x from household where id = ?", [asked]);
      if (!known) throw new ApiError("not_found", "There is no such household.");
      householdId = asked;
    }
    take(c);
    stats.prune();
    const range = rangeOf(name, clock, now(), stats.oldest);
    return c.json({
      keptDays: stats.kept,
      ...reader.server(range, clock, {
        householdId,
        ownerHouseholdId: OWNER_HOUSEHOLD,
        storage: deps.storage?.() ?? {},
      }),
    });
  });
}
