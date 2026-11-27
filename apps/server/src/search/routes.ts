// SPDX-License-Identifier: MPL-2.0
import type { Hono } from "hono";
import { compress } from "hono/compress";
import { imagePath } from "../enrich/tmdb.ts";
import { ApiError, type AppEnv, type Ctx } from "../http/app.ts";
import { chosen, onceFrom, readTitleFilter, values, whole } from "../http/query.ts";
import { kidsLimits, type KidsView } from "../kids/limits.ts";
import { ascendingByDefault, SORT_KEYS, type TitleSort } from "../library/query.ts";
import { RateLimiter } from "../outside/limits.ts";
import type { OutsideReason, OutsideSearch } from "./outside.ts";
import type { SearchService } from "./service.ts";
import { parseQuery } from "./syntax.ts";
import type { Database } from "../db/database.ts";

export interface SearchRouteDeps {
  db: Database;
  search: SearchService;
  outside: OutsideSearch;
  /** Throws `not_found` for a viewer there is not. */
  profile: (id: string) => unknown;
  now: () => number;
}

/** Per device: TMDB is asked on the household's behalf, and typing asks often. */
export const OUTSIDE_RATE = { burst: 40, perMinute: 30 } as const;
const ROLES = ["any", "cast", "director", "writer"] as const;

const REASONS: Readonly<Record<OutsideReason, string>> = {
  no_key: "This server has no TMDB key, so it cannot look beyond the library.",
  unavailable: "TMDB cannot be reached right now.",
  rate_limited: "That was a lot at once. Try again in a moment.",
};

/**
 * `/v1/search…` (docs/api.md, Search): the library by words and filters, people, and films and
 * shows beyond the library at TMDB. A kids device, and any device searching as a kids viewer,
 * gets only the library within its limits: nothing from outside, no person beyond their titles.
 */
export function registerSearchRoutes(app: Hono<AppEnv>, deps: SearchRouteDeps): void {
  const limits = kidsLimits(deps.db);
  const rate = new RateLimiter(OUTSIDE_RATE, deps.now);

  /** The viewer asked about, and what they may see: a kids viewer's limits on any device. */
  const viewOf = (c: Ctx, profileId: string | null): { view: KidsView | null; kids: boolean } => {
    const device = c.get("device");
    let view = c.get("kids");
    let kids = device.kidsProfileId !== null;
    if (profileId !== null) {
      if (device.kidsProfileId !== null && profileId !== device.kidsProfileId) {
        throw new ApiError("not_found", "There is no such viewer.");
      }
      deps.profile(profileId);
      const isKids =
        deps.db.get<{ kids: number }>(
          "select kids_json is not null as kids from profile where id = ? and household_id = ?",
          [profileId, device.householdId],
        )?.kids === 1;
      if (isKids) {
        // Kids mode on a device without limits: what that viewer may see, nothing more.
        view = limits.view(profileId);
        kids = true;
      }
    }
    return { view, kids };
  };

  /** Outside is for grown-ups, and a few requests a minute. */
  const outsideAllowed = (c: Ctx, kids: boolean): void => {
    if (kids) throw new ApiError("not_found", "There is no such thing here.");
    const wait = rate.take(c.get("device").id);
    if (wait > 0) {
      c.header("Retry-After", String(wait));
      throw new ApiError("rate_limited", REASONS.rate_limited);
    }
  };

  const reason = (found: OutsideReason): never => {
    throw new ApiError(found === "no_key" ? "conflict" : "unavailable", REASONS[found], {
      reason: found,
    });
  };

  app.use("/v1/search", compress());
  app.get("/v1/search", (c) => {
    const query = (key: string): string[] | undefined => c.req.queries(key);
    const one = onceFrom(query);
    const q = one("q") ?? "";
    const spec = parseQuery(q);
    const base = readTitleFilter(query);
    const [key, ...more] = chosen(query, "sort", SORT_KEYS);
    const [order, ...orders] = chosen(query, "order", ["asc", "desc"] as const);
    if (more.length > 0 || orders.length > 0) {
      throw new ApiError("invalid_request", `Send "sort" and "order" once.`);
    }
    const sort: TitleSort | null =
      key === undefined
        ? null
        : { key, ascending: order === undefined ? ascendingByDefault(key) : order === "asc" };
    const limit = whole(one("limit"), "limit", 30, 200);
    const [role = "any", ...roles] = chosen(query, "role", ROLES);
    if (roles.length > 0) throw new ApiError("invalid_request", `Send "role" once.`);
    const people = values(query, "person").map((id) => {
      if (!/^[1-9][0-9]{0,9}$/.test(id))
        throw new ApiError("invalid_request", `"person" must be a TMDB person id.`);
      return { id: Number(id), role };
    });
    const profileId = one("profile") ?? null;
    if ((base.watch.length > 0 || spec.watch.length > 0) && profileId === null) {
      throw new ApiError(
        "invalid_request",
        `"watch" and "is:watched" need the viewer in "profile".`,
      );
    }
    const { view } = viewOf(c, profileId);
    return c.json(
      deps.search.search(q, spec, base, sort, { view, profileId, now: deps.now() }, limit, people),
    );
  });

  app.get("/v1/search/outside", async (c) => {
    const query = (key: string): string[] | undefined => c.req.queries(key);
    const one = onceFrom(query);
    const { view, kids } = viewOf(c, one("profile") ?? null);
    outsideAllowed(c, kids);
    const spec = parseQuery(one("q") ?? "");
    return c.json(await deps.outside.search(spec, deps.search.libraryTmdb(view)));
  });

  app.get("/v1/search/outside/:type/:id", async (c) => {
    const type = c.req.param("type");
    const id = c.req.param("id");
    if ((type !== "movie" && type !== "tv") || !/^[1-9][0-9]{0,9}$/.test(id)) {
      throw new ApiError("not_found", "There is no such title.");
    }
    const { view, kids } = viewOf(c, c.req.query("profile") ?? null);
    outsideAllowed(c, kids);
    const found = await deps.outside.title(type, Number(id), deps.search.libraryTmdb(view));
    if (found === null) throw new ApiError("not_found", "TMDB does not know that title.");
    if (typeof found === "string") return reason(found);
    return c.json(found);
  });

  app.get("/v1/search/people/:id", async (c) => {
    const id = c.req.param("id");
    if (!/^[1-9][0-9]{0,9}$/.test(id)) throw new ApiError("not_found", "There is no such person.");
    const { view, kids } = viewOf(c, c.req.query("profile") ?? null);
    const inLibrary = deps.search.personInLibrary(Number(id), view);
    // A child sees a person only through the titles they may see, and nothing from outside.
    if (kids) {
      if (!inLibrary) throw new ApiError("not_found", "There is no such person.");
      return c.json({ ...inLibrary, outside: null, outsideReason: null });
    }
    const wantsOutside = c.req.query("outside") !== "false";
    let outside = null;
    let outsideReason: OutsideReason | null = null;
    if (wantsOutside) {
      const wait = rate.take(c.get("device").id);
      if (wait > 0) outsideReason = "rate_limited";
      else {
        const found = await deps.outside.personPage(Number(id), deps.search.libraryTmdb(view));
        if (typeof found === "string") outsideReason = found;
        else outside = found;
      }
    }
    if (!inLibrary && !outside) {
      if (outsideReason !== null && outsideReason !== "no_key") return reason(outsideReason);
      throw new ApiError("not_found", "There is no such person.");
    }
    return c.json({
      person: inLibrary?.person ?? {
        id: outside?.id ?? Number(id),
        name: outside?.name ?? "",
        picture: outside?.picture ?? null,
      },
      titles: inLibrary?.titles ?? [],
      outside,
      outsideReason,
    });
  });

  app.get("/v1/search/picture", async (c) => {
    const path = c.req.query("path") ?? "";
    if (!imagePath("poster", path))
      throw new ApiError("invalid_request", `"path" must be a TMDB picture path.`);
    const { kids } = viewOf(c, null);
    if (kids) throw new ApiError("not_found", "There is no such picture.");
    const found = await deps.outside.picture(path);
    if (found === null) throw new ApiError("not_found", "TMDB does not have that picture.");
    if (typeof found === "string") return reason(found);
    return c.body(found, 200, {
      "Content-Type": "image/jpeg",
      "Cache-Control": "private, max-age=604800, immutable",
    });
  });
}
