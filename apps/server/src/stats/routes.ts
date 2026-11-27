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

/** Per device: a person looks at a page now and then, and a page asks once. */
export const STATS_RATE = { burst: 30, perMinute: 20 } as const;

export interface StatsRouteDeps {
  db: Database;
  stats: Statistics;
  /** How full the server's caches and drive are, for the server page. */
  storage?: () => Record<string, number | null>;
  requireManager: (c: Ctx, action: string) => Device;
  requireHouseholdAdmin: (c: Ctx, action: string) => Device;
  now: () => number;
}

/**
 * Statistics (docs/api.md, Statistics). Each viewer's for whoever may be that viewer on a device
 * of the household; the server's for its admins. The guards keep a viewer to their household
 * and a child's device to its own child.
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

  const viewer = (
    c: Ctx,
  ): {
    id: string;
    name: string;
    color: string;
    avatar: string | null;
    kids: boolean;
  } => {
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
    // The household guard lets one that is nobody's through: it is not there either.
    if (!row || row.household_id !== c.get("device").householdId) {
      throw new ApiError("not_found", "There is no such viewer.");
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
    const device = c.get("device");
    const range = rangeOf(name, clock, now(), stats.oldest);
    const simple = device.kidsProfileId !== null;
    return c.json({
      viewer: who,
      keptDays: stats.kept,
      simple,
      ...reader.viewer(who.id, range, clock, {
        view: c.get("kids"),
        simple,
        oldest: stats.oldest,
      }),
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

  app.get("/v1/stats/server", (c) => {
    deps.requireManager(c, "see the server's statistics");
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
