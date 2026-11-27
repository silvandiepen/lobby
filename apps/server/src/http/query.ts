// SPDX-License-Identifier: MPL-2.0
import type { Hono } from "hono";
import { compress } from "hono/compress";
import type { Database } from "../db/database.ts";
import type { ItemReader } from "../library/items.ts";
import {
  ADDED,
  ascendingByDefault,
  LENGTHS,
  QUALITIES,
  SORT_KEYS,
  TITLE_KINDS,
  TitleQueries,
  WATCH_STATES,
  type TitleFilter,
} from "../library/query.ts";
import type { PlayLog } from "../plays.ts";
import { ApiError, type AppEnv } from "./app.ts";

export interface QueryDeps {
  db: Database;
  items: ItemReader;
  plays: PlayLog;
  /** Throws `not_found` for a viewer there is not. */
  profile: (id: string) => unknown;
  now: () => number;
}

const MAX_VALUES = 100;
const YEAR = /^[0-9]{4}$/;

function values(query: (key: string) => string[] | undefined, key: string): string[] {
  const found = query(key) ?? [];
  if (found.length > MAX_VALUES) {
    throw new ApiError("invalid_request", `At most ${String(MAX_VALUES)} values of "${key}".`);
  }
  for (const one of found) {
    if (one === "" || one.length > 200) {
      throw new ApiError("invalid_request", `"${key}" must be 1 to 200 characters.`);
    }
  }
  return found;
}

function chosen<T extends string>(
  query: (key: string) => string[] | undefined,
  key: string,
  allowed: readonly T[],
): T[] {
  const found = values(query, key);
  for (const one of found) {
    if (!(allowed as readonly string[]).includes(one)) {
      throw new ApiError("invalid_request", `"${key}" must be one of ${allowed.join(", ")}.`);
    }
  }
  return found as T[];
}

function year(value: string | undefined, key: string): number | null {
  if (value === undefined) return null;
  if (!YEAR.test(value)) throw new ApiError("invalid_request", `"${key}" must be a year.`);
  return Number(value);
}

function whole(value: string | undefined, key: string, fallback: number, most: number): number {
  if (value === undefined) return fallback;
  const number = Number(value);
  if (!/^[0-9]+$/.test(value) || number > most) {
    throw new ApiError(
      "invalid_request",
      `"${key}" must be a whole number from 0 to ${String(most)}.`,
    );
  }
  return number;
}

/** A parameter that may be sent once. */
export function onceFrom(
  query: (key: string) => string[] | undefined,
): (key: string) => string | undefined {
  return (key) => {
    const found = values(query, key);
    if (found.length > 1) throw new ApiError("invalid_request", `Send "${key}" once.`);
    return found[0];
  };
}

/** The filters of `GET /v1/library/query`, also taken by `GET /v1/search`. */
export function readTitleFilter(query: (key: string) => string[] | undefined): TitleFilter {
  const one = onceFrom(query);
  const filter: TitleFilter = {
    kinds: chosen(query, "kind", TITLE_KINDS),
    yearFrom: year(one("yearFrom"), "yearFrom"),
    yearTo: year(one("yearTo"), "yearTo"),
    genres: values(query, "genre"),
    studios: values(query, "studio"),
    categories: values(query, "category"),
    watch: chosen(query, "watch", WATCH_STATES),
    lengths: chosen(query, "length", LENGTHS),
    added: chosen(query, "added", ADDED)[0] ?? null,
    quality: chosen(query, "quality", QUALITIES),
    languages: values(query, "language"),
  };
  if (values(query, "added").length > 1) {
    throw new ApiError("invalid_request", `Send "added" once.`);
  }
  return filter;
}

export { chosen, values, whole };

/** `GET /v1/library/query`: the films, shows and videos of a list, filtered and in order. */
export function registerQueryRoutes(app: Hono<AppEnv>, deps: QueryDeps): void {
  const queries = new TitleQueries(deps.db, deps.items);

  app.use("/v1/library/query", compress());
  app.get("/v1/library/query", (c) => {
    const query = (key: string): string[] | undefined => c.req.queries(key);
    const one = onceFrom(query);
    const filter = readTitleFilter(query);
    const [key = "title", ...more] = chosen(query, "sort", SORT_KEYS);
    const [order, ...orders] = chosen(query, "order", ["asc", "desc"] as const);
    if (more.length > 0 || orders.length > 0) {
      throw new ApiError("invalid_request", `Send "sort" and "order" once.`);
    }
    const offset = whole(one("offset"), "offset", 0, 1_000_000);
    const limit = whole(one("limit"), "limit", 100, 500);

    const view = c.get("kids");
    const device = c.get("device");
    const profileId = one("profile") ?? null;
    if (filter.watch.length > 0 && profileId === null) {
      throw new ApiError("invalid_request", `"watch" needs the viewer in "profile".`);
    }
    if (profileId !== null) {
      // A kids device knows its own viewer only.
      if (device.kidsProfileId !== null && profileId !== device.kidsProfileId) {
        throw new ApiError("not_found", "There is no such viewer.");
      }
      deps.profile(profileId);
    }
    const popular =
      key === "popular" ? deps.plays.popular(view).titles.map((title) => title.itemId) : [];
    const ids = queries.run(
      filter,
      { key, ascending: order === undefined ? ascendingByDefault(key) : order === "asc" },
      { view, profileId, popular, now: deps.now() },
    );
    return c.json({
      total: ids.length,
      offset,
      items: limit === 0 ? [] : deps.items.read(ids.slice(offset, offset + limit), view),
    });
  });
}
