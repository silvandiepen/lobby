// SPDX-License-Identifier: MPL-2.0
import type { Database } from "../db/database.ts";
import type { KidsView } from "../kids/limits.ts";
import { ratingOf, renown, type ItemReader } from "./items.ts";
import { effectiveSortTitle, readOverrides } from "./overrides.ts";

/**
 * Filters and orders the films, shows and videos of a list (docs/api.md, "Filters and order").
 * The apps do the same on their own copy of the catalogue (LobbyKit `TitleQuery`): change both.
 */

export const TITLE_KINDS = ["movie", "show", "personal"] as const;
export const WATCH_STATES = ["unwatched", "in_progress", "watched"] as const;
export const LENGTHS = ["short", "standard", "long"] as const;
export const ADDED = ["week", "month", "year"] as const;
export const QUALITIES = ["4k"] as const;
export const SORT_KEYS = ["title", "year", "added", "popular", "length", "rating"] as const;

export type TitleKind = (typeof TITLE_KINDS)[number];
export type WatchState = (typeof WATCH_STATES)[number];
export type Length = (typeof LENGTHS)[number];
export type Added = (typeof ADDED)[number];
export type Quality = (typeof QUALITIES)[number];
export type SortKey = (typeof SORT_KEYS)[number];

/** Shorter than this is short. */
export const SHORT_MS = 40 * 60_000;
/** Longer than this is long. */
export const LONG_MS = 150 * 60_000;
/** A picture at least this wide is 4K (3840 × 2160, or 3840 × 1600 for a wide film). */
export const UHD_WIDTH = 3_200;
export const ADDED_DAYS: Readonly<Record<Added, number>> = { week: 7, month: 30, year: 365 };
const DAY_MS = 86_400_000;

/** Each part narrows the list; several values in one part are any of them. Empty: all. */
export interface TitleFilter {
  kinds: TitleKind[];
  yearFrom: number | null;
  yearTo: number | null;
  genres: string[];
  studios: string[];
  categories: string[];
  watch: WatchState[];
  lengths: Length[];
  added: Added | null;
  quality: Quality[];
  languages: string[];
  /** Search's: a length in whole minutes, both ends in. Unknown length: in no range. */
  minutesFrom?: number | null;
  minutesTo?: number | null;
}

export interface TitleSort {
  key: SortKey;
  ascending: boolean;
}

export const NO_FILTER: TitleFilter = {
  kinds: [],
  yearFrom: null,
  yearTo: null,
  genres: [],
  studios: [],
  categories: [],
  watch: [],
  lengths: [],
  added: null,
  quality: [],
  languages: [],
};

/** The way each order goes by itself: A to Z, and the newest, most watched, best rated first. */
export function ascendingByDefault(key: SortKey): boolean {
  return key === "title" || key === "length";
}

export function lengthOf(ms: number): Length {
  return ms < SHORT_MS ? "short" : ms > LONG_MS ? "long" : "standard";
}

/** A film, or an episode of a show. */
interface Leaf {
  id: string;
  lengthMs: number | null;
  addedAt: number;
  uhd: boolean;
  languages: string[];
}

interface Facts {
  id: string;
  kind: TitleKind;
  sortTitle: string;
  year: number | null;
  /** Lower case. */
  genres: string[];
  studios: string[];
  rating: number | null;
  renown: number | null;
  addedAt: number;
  leaves: Leaf[];
}

interface TitleRow {
  id: string;
  kind: TitleKind;
  sort_title: string;
  year: number | null;
  override_json: string | null;
  vote_average: number | null;
  vote_count: number | null;
  popularity: number | null;
  added_at: number;
}

interface LeafRow {
  title: string;
  id: string;
  runtime_ms: number | null;
  added_at: number;
}

interface FileRow {
  item_id: string;
  part: number | null;
  start_ms: number | null;
  end_ms: number | null;
  duration_ms: number | null;
  width: number | null;
  languages: string | null;
}

export interface QueryContext {
  view: KidsView | null;
  /** Whose progress `watch` is about. */
  profileId: string | null;
  /** Titles by how much they were watched, most first. */
  popular: readonly string[];
  now: number;
}

const collator = new Intl.Collator("en", { sensitivity: "base", numeric: true });

/**
 * Knows, per library revision, what every film, show and video is (a few grouped queries over
 * the whole catalogue), and filters and orders those for a list in memory.
 */
export class TitleQueries {
  private readonly db: Database;
  private readonly items: ItemReader;
  private cached: { revision: number; facts: Facts[] } | null = null;

  constructor(db: Database, items: ItemReader) {
    this.db = db;
    this.items = items;
  }

  private facts(): Facts[] {
    const revision = this.db.currentRevision();
    if (this.cached?.revision === revision) return this.cached.facts;
    const titles = this.db.all<TitleRow>(
      `select id, kind, sort_title, year, override_json, vote_average, vote_count, popularity, added_at
       from item where parent_id is null and kind in ('movie', 'show', 'personal')`,
    );
    const genres = new Map<string, string[]>();
    for (const row of this.db.all<{ item_id: string; name: string }>(
      `select item_genre.item_id, genre.name from item_genre
       join genre on genre.id = item_genre.genre_id
       join item on item.id = item_genre.item_id and item.parent_id is null`,
    )) {
      genres.set(row.item_id, [...(genres.get(row.item_id) ?? []), row.name.toLowerCase()]);
    }
    const studios = new Map<string, string[]>();
    for (const row of this.db.all<{ item_id: string; studio_id: string }>(
      "select item_id, studio_id from item_studio order by item_id, position",
    )) {
      studios.set(row.item_id, [...(studios.get(row.item_id) ?? []), row.studio_id]);
    }
    // A film or video is its own leaf; a show's leaves are its episodes.
    const leafRows = this.db.all<LeafRow>(
      `select id as title, id, runtime_ms, added_at from item
         where parent_id is null and kind in ('movie', 'personal')
       union all
       select show.id, episode.id, episode.runtime_ms, episode.added_at
       from item as show
       cross join item as season on season.parent_id = show.id and season.kind = 'season'
       cross join item as episode on episode.parent_id = season.id and episode.kind = 'episode'
       where show.parent_id is null and show.kind = 'show'`,
    );
    const files = new Map<string, FileRow[]>();
    for (const row of this.db.all<FileRow>(
      `select item_asset.item_id, item_asset.part, item_asset.start_ms, item_asset.end_ms,
         asset.duration_ms,
         (select max(width) from track where track.asset_id = asset.id and track.kind = 'video') as width,
         (select json_group_array(distinct lower(language)) from track
            where track.asset_id = asset.id and track.kind = 'audio' and language is not null) as languages
       from item_asset
       join asset on asset.id = item_asset.asset_id
       join item on item.id = item_asset.item_id
       where item_asset.role = 'main' and asset.state = 'probed'
         and item.kind in ('movie', 'personal', 'episode')
       order by item_asset.item_id, item_asset.part, asset.rel_path`,
    )) {
      files.set(row.item_id, [...(files.get(row.item_id) ?? []), row]);
    }
    const leaves = new Map<string, Leaf[]>();
    for (const row of leafRows) {
      const own = files.get(row.id) ?? [];
      const first = own[0];
      const fileLength =
        first === undefined
          ? null
          : first.start_ms !== null && first.end_ms !== null && first.end_ms > first.start_ms
            ? first.end_ms - first.start_ms
            : first.duration_ms;
      const leaf: Leaf = {
        id: row.id,
        lengthMs: row.runtime_ms ?? fileLength,
        addedAt: row.added_at,
        uhd: own.some((file) => (file.width ?? 0) >= UHD_WIDTH),
        languages: [
          ...new Set(own.flatMap((file) => JSON.parse(file.languages ?? "[]") as string[])),
        ],
      };
      leaves.set(row.title, [...(leaves.get(row.title) ?? []), leaf]);
    }
    const facts = titles.map((row): Facts => {
      const overrides = readOverrides(row.override_json);
      return {
        id: row.id,
        kind: row.kind,
        sortTitle: effectiveSortTitle(overrides, row.sort_title),
        year: overrides.year === undefined ? row.year : overrides.year,
        genres: overrides.genres?.map((name) => name.toLowerCase()) ?? genres.get(row.id) ?? [],
        studios: studios.get(row.id) ?? [],
        rating: ratingOf(row.vote_count, row.vote_average),
        renown: renown(row.vote_count, row.vote_average, row.popularity),
        addedAt: row.added_at,
        leaves: leaves.get(row.id) ?? [],
      };
    });
    this.cached = { revision, facts };
    return facts;
  }

  /** The ids of what passes `filter`, in the order of `sort`. Kids limits come first. */
  run(filter: TitleFilter, sort: TitleSort, context: QueryContext): string[] {
    const { view } = context;
    const all = view ? this.facts().filter((one) => view.items.has(one.id)) : this.facts();
    const categories = filter.categories.length > 0 ? this.items.titleCategories(view) : null;
    const wanted = categories === null ? null : this.withInside(filter.categories);
    const progress = new Map<string, { position: number; completed: boolean }>();
    if (filter.watch.length > 0 && context.profileId !== null) {
      for (const row of this.db.all<{ item_id: string; position_ms: number; completed: number }>(
        "select item_id, position_ms, completed from progress where profile_id = ?",
        [context.profileId],
      )) {
        progress.set(row.item_id, { position: row.position_ms, completed: row.completed === 1 });
      }
    }
    const genres = new Set(filter.genres.map((name) => name.toLowerCase()));
    const languages = new Set(filter.languages.map((code) => code.toLowerCase()));
    const since = filter.added === null ? null : context.now - ADDED_DAYS[filter.added] * DAY_MS;

    interface Seen {
      facts: Facts;
      leaves: Leaf[];
      addedAt: number;
      lengthMs: number | null;
    }
    const passed: Seen[] = [];
    for (const facts of all) {
      // What a kids viewer may not see of a show is not part of it for them.
      const leaves = view ? facts.leaves.filter((leaf) => view.items.has(leaf.id)) : facts.leaves;
      const seen: Seen = {
        facts,
        leaves,
        addedAt:
          facts.kind === "show" && leaves.length > 0
            ? Math.max(...leaves.map((leaf) => leaf.addedAt))
            : facts.addedAt,
        lengthMs: lengthMs(facts.kind, leaves),
      };
      if (filter.kinds.length > 0 && !filter.kinds.includes(facts.kind)) continue;
      if (filter.yearFrom !== null && (facts.year === null || facts.year < filter.yearFrom))
        continue;
      if (filter.yearTo !== null && (facts.year === null || facts.year > filter.yearTo)) continue;
      if (genres.size > 0 && !facts.genres.some((name) => genres.has(name))) continue;
      if (filter.studios.length > 0 && !facts.studios.some((id) => filter.studios.includes(id)))
        continue;
      if (wanted !== null && categories !== null) {
        const own = categories.get(facts.id);
        if (!own || ![...own].some((id) => wanted.has(id))) continue;
      }
      if (filter.watch.length > 0 && !filter.watch.includes(watchState(leaves, progress))) continue;
      if (
        filter.lengths.length > 0 &&
        (seen.lengthMs === null || !filter.lengths.includes(lengthOf(seen.lengthMs)))
      )
        continue;
      if (
        (filter.minutesFrom != null || filter.minutesTo != null) &&
        (seen.lengthMs === null ||
          (filter.minutesFrom != null && seen.lengthMs < filter.minutesFrom * 60_000) ||
          (filter.minutesTo != null && seen.lengthMs >= (filter.minutesTo + 1) * 60_000))
      )
        continue;
      if (since !== null && seen.addedAt < since) continue;
      if (filter.quality.includes("4k") && !leaves.some((leaf) => leaf.uhd)) continue;
      if (
        languages.size > 0 &&
        !leaves.some((leaf) => leaf.languages.some((code) => languages.has(code)))
      )
        continue;
      passed.push(seen);
    }

    const rank = new Map(context.popular.map((id, index) => [id, index]));
    const count = Math.max(1, context.popular.length);
    const value = (one: Seen): number | null => {
      switch (sort.key) {
        case "title":
          return 0;
        case "year":
          return one.facts.year;
        case "added":
          return one.addedAt;
        case "length":
          return one.lengthMs;
        case "rating":
          return one.facts.rating;
        case "popular": {
          // Watched here first, by how much; then how well known.
          const place = rank.get(one.facts.id);
          return place === undefined ? one.facts.renown : 1 + (count - place) / count;
        }
      }
    };
    const byTitle = (a: Seen, b: Seen): number =>
      collator.compare(a.facts.sortTitle, b.facts.sortTitle) ||
      (a.facts.sortTitle < b.facts.sortTitle
        ? -1
        : a.facts.sortTitle > b.facts.sortTitle
          ? 1
          : 0) ||
      (a.facts.id < b.facts.id ? -1 : a.facts.id > b.facts.id ? 1 : 0);
    const keyed = passed.map((one) => ({ one, key: value(one) }));
    keyed.sort((a, b) => {
      if (sort.key === "title")
        return sort.ascending ? byTitle(a.one, b.one) : byTitle(b.one, a.one);
      // Unknown goes last, either way.
      if (a.key === null || b.key === null) {
        if (a.key !== b.key) return a.key === null ? 1 : -1;
        return byTitle(a.one, b.one);
      }
      return (sort.ascending ? a.key - b.key : b.key - a.key) || byTitle(a.one, b.one);
    });
    return keyed.map(({ one }) => one.facts.id);
  }

  /** The categories asked for, and those inside them. */
  private withInside(ids: string[]): Set<string> {
    const wanted = new Set(ids);
    for (const row of this.db.all<{ id: string }>(
      "select id from category where parent_id in (select value from json_each(?))",
      [JSON.stringify(ids)],
    )) {
      wanted.add(row.id);
    }
    return wanted;
  }
}

/** A film's own length; of a show, the average of its episodes whose length is known. */
function lengthMs(kind: TitleKind, leaves: Leaf[]): number | null {
  const known = leaves.flatMap((leaf) => (leaf.lengthMs === null ? [] : [leaf.lengthMs]));
  if (known.length === 0) return null;
  if (kind !== "show") return known[0] ?? null;
  return Math.round(known.reduce((sum, one) => sum + one, 0) / known.length);
}

/** Finished when every part is; started when one part is, or was finished. */
function watchState(
  leaves: Leaf[],
  progress: ReadonlyMap<string, { position: number; completed: boolean }>,
): WatchState {
  let finished = 0;
  let touched = 0;
  for (const leaf of leaves) {
    const own = progress.get(leaf.id);
    if (!own) continue;
    if (own.completed) finished += 1;
    if (own.completed || own.position > 0) touched += 1;
  }
  if (leaves.length > 0 && finished === leaves.length) return "watched";
  return touched > 0 ? "in_progress" : "unwatched";
}
