// SPDX-License-Identifier: MPL-2.0
import type { Database } from "../db/database.ts";
import type { CreditRole } from "../enrich/provider.ts";
import type { KidsView } from "../kids/limits.ts";
import { ratingOf, type ApiItem, type ItemReader } from "../library/items.ts";
import { readOverrides } from "../library/overrides.ts";
import { TitleQueries, type TitleFilter, type TitleSort } from "../library/query.ts";
import { fold, words } from "./normalize.ts";
import type { OmdbRating, OmdbRatings } from "./omdb.ts";
import { SearchIndex, type MatchField } from "./search-index.ts";
import {
  RATING_SOURCES,
  type PersonRole,
  type RatingBound,
  type RatingSource,
  type SearchSpec,
  type Understood,
} from "./syntax.ts";

/** Every rating a title has, each on its own source's scale. */
export interface Ratings {
  /** TMDB's average, 0 to 10; null with fewer than 10 votes. */
  tmdb: number | null;
  /** IMDb's, 0 to 10, from OMDb. */
  imdb: number | null;
  /** Rotten Tomatoes' critics score (Tomatometer), 0 to 100, from OMDb. */
  rottenTomatoes: number | null;
  /** Metacritic's Metascore, 0 to 100, from OMDb. */
  metacritic: number | null;
}

export const NO_RATINGS: Ratings = {
  tmdb: null,
  imdb: null,
  rottenTomatoes: null,
  metacritic: null,
};

export interface SearchMatch {
  field: MatchField;
  text: string | null;
}

export interface SearchTitle {
  item: ApiItem;
  ratings: Ratings;
  /** Why it is here; null when only filters chose it. */
  match: SearchMatch | null;
}

export interface SearchEpisode {
  item: ApiItem;
  showId: string | null;
  match: SearchMatch | null;
}

export interface SearchPerson {
  id: number;
  name: string;
  /** For `GET /v1/search/picture?path=`. */
  picture: string | null;
  /** Their titles in the library, as far as the device may see. */
  titles: number;
  roles: CreditRole[];
}

export interface SearchCollection {
  id: number;
  name: string;
  itemIds: string[];
}

export interface Group<T> {
  total: number;
  items: T[];
}

export interface SearchAnswer {
  query: string;
  /** The free words that were left after the filters. */
  text: string;
  understood: Understood[];
  /** People named in a filter that nobody in the library is. */
  unknownPeople: string[];
  /** The sources this server has ratings from. */
  ratingSources: RatingSource[];
  films: Group<SearchTitle>;
  series: Group<SearchTitle>;
  videos: Group<SearchTitle>;
  episodes: Group<SearchEpisode>;
  people: Group<SearchPerson>;
  collections: Group<SearchCollection>;
}

export interface SearchContext {
  view: KidsView | null;
  profileId: string | null;
  now: number;
}

export interface PersonInLibrary {
  person: { id: number; name: string; picture: string | null };
  titles: {
    item: ApiItem;
    ratings: Ratings;
    roles: { role: CreditRole; character: string | null }[];
  }[];
}

interface TitleRow {
  id: string;
  kind: string;
  title: string;
  override_json: string | null;
  vote_average: number | null;
  vote_count: number | null;
  imdb_id: string | null;
  collection_id: number | null;
  collection_name: string | null;
}

/** Searches the library: words through the index, filters through the lists' own rules. */
export class SearchService {
  private readonly db: Database;
  private readonly items: ItemReader;
  private readonly queries: TitleQueries;
  readonly index: SearchIndex;
  private readonly omdb: OmdbRatings | null;

  constructor(db: Database, items: ItemReader, omdb: OmdbRatings | null) {
    this.db = db;
    this.items = items;
    this.queries = new TitleQueries(db, items);
    this.index = new SearchIndex(db);
    this.omdb = omdb;
  }

  /** Which ratings there can be: OMDb's only with its key. */
  ratingSources(): RatingSource[] {
    return this.omdb?.isConfigured === true ? [...RATING_SOURCES] : ["tmdb"];
  }

  search(
    query: string,
    spec: SearchSpec,
    base: TitleFilter,
    sort: TitleSort | null,
    context: SearchContext,
    limit: number,
    personIds: { id: number; role: PersonRole }[] = [],
  ): SearchAnswer {
    this.index.sync();
    const answer: SearchAnswer = {
      query,
      text: spec.text,
      understood: spec.understood,
      unknownPeople: [],
      ratingSources: this.ratingSources(),
      films: { total: 0, items: [] },
      series: { total: 0, items: [] },
      videos: { total: 0, items: [] },
      episodes: { total: 0, items: [] },
      people: { total: 0, items: [] },
      collections: { total: 0, items: [] },
    };
    const filtered = spec.understood.length > 0 || personIds.length > 0 || !isEmptyFilter(base);
    if (spec.text === "" && !filtered) return answer;

    // People by name, each to the ids they stand for. Nobody: nothing passes.
    const wantedPeople: { ids: number[]; role: PersonRole }[] = personIds.map((one) => ({
      ids: [one.id],
      role: one.role,
    }));
    for (const one of spec.people) {
      const ids = one.id !== null ? [one.id] : this.index.resolvePerson(one.name ?? "");
      if (ids.length === 0) answer.unknownPeople.push(one.name ?? "");
      wantedPeople.push({ ids, role: one.role });
    }
    const filter = this.combine(base, spec);
    if (filter === null || answer.unknownPeople.length > 0) return answer;

    const order: TitleSort = sort ?? defaultSort(spec);
    const passing = this.queries.run(filter, order, {
      view: context.view,
      profileId: context.profileId,
      popular: [],
      now: context.now,
    });
    const rows = this.titleRows(passing);
    const ratings = this.ratingsOf(rows);
    const kept = passing.filter((id) => {
      const row = rows.get(id);
      if (!row) return false;
      const title = fold(readOverrides(row.override_json).title ?? row.title);
      if (spec.titleExact !== null && title !== fold(spec.titleExact)) return false;
      if (
        spec.titleContains.some(
          (part) => !` ${title}`.includes(` ${fold(part)}`) && !title.includes(fold(part)),
        )
      ) {
        return false;
      }
      if (
        spec.collections.length > 0 &&
        !spec.collections.some(
          (name) => row.collection_name !== null && fold(row.collection_name).includes(fold(name)),
        )
      ) {
        return false;
      }
      return spec.ratings.every((bound) => passes(ratings.get(id) ?? NO_RATINGS, bound));
    });
    const withPeople = wantedPeople.length === 0 ? kept : this.withPeople(kept, wantedPeople);
    if (spec.ratings.length > 0 && sort === null) {
      const first = spec.ratings[0]?.source ?? "tmdb";
      withPeople.sort((a, b) => (ratings.get(b)?.[first] ?? -1) - (ratings.get(a)?.[first] ?? -1));
    }

    let titles: { id: string; match: SearchMatch | null }[];
    if (spec.text !== "") {
      const allowed = new Set(withPeople);
      const matches = this.index.matchTitles(spec.text);
      titles = matches
        .filter((one) => allowed.has(one.itemId))
        .map((one) => ({ id: one.itemId, match: { field: one.field, text: one.text } }));
      // Ordered by how well they match, unless the viewer chose an order.
      if (sort !== null) {
        const place = new Map(withPeople.map((id, index) => [id, index]));
        titles.sort((a, b) => (place.get(a.id) ?? 0) - (place.get(b.id) ?? 0));
      }
      const episodes = this.episodes(matches, allowed, context.view);
      answer.episodes = {
        total: episodes.length,
        items: this.items
          .read(
            episodes.slice(0, limit).map((one) => one.id),
            context.view,
          )
          .map((item) => ({
            item,
            showId: this.showOf(item.id),
            match: episodes.find((one) => one.id === item.id)?.match ?? null,
          })),
      };
      if (wantedPeople.length === 0) {
        answer.people = this.people(spec.text, context.view, limit);
        answer.collections = this.collections(spec.text, context.view, limit);
      }
    } else {
      titles = withPeople.map((id) => ({ id, match: null }));
    }
    if (wantedPeople.length > 0) {
      const ids = [...new Set(wantedPeople.flatMap((one) => one.ids))];
      answer.people = this.peopleById(ids, context.view, limit);
    }

    const groups: Record<string, { id: string; match: SearchMatch | null }[]> = {
      movie: [],
      show: [],
      personal: [],
    };
    for (const one of titles) groups[rows.get(one.id)?.kind ?? ""]?.push(one);
    const read = (list: { id: string; match: SearchMatch | null }[]): Group<SearchTitle> => {
      const page = list.slice(0, limit);
      const matchOf = new Map(page.map((one) => [one.id, one.match]));
      return {
        total: list.length,
        items: this.items
          .read(
            page.map((one) => one.id),
            context.view,
          )
          .map((item) => ({
            item,
            ratings: ratings.get(item.id) ?? NO_RATINGS,
            match: matchOf.get(item.id) ?? null,
          })),
      };
    };
    answer.films = read(groups["movie"] ?? []);
    answer.series = read(groups["show"] ?? []);
    answer.videos = read(groups["personal"] ?? []);
    return answer;
  }

  /** The library's own filters and search's, together; null when they cannot both hold. */
  private combine(base: TitleFilter, spec: SearchSpec): TitleFilter | null {
    const kinds =
      base.kinds.length > 0 && spec.kinds.length > 0
        ? base.kinds.filter((kind) => spec.kinds.includes(kind))
        : [...base.kinds, ...spec.kinds];
    if (base.kinds.length > 0 && spec.kinds.length > 0 && kinds.length === 0) return null;
    const most = (a: number | null, b: number | null): number | null =>
      a === null ? b : b === null ? a : Math.max(a, b);
    const least = (a: number | null, b: number | null): number | null =>
      a === null ? b : b === null ? a : Math.min(a, b);
    let studios = base.studios;
    if (spec.studios.length > 0) {
      const all = this.db.all<{ id: string; name: string }>("select id, name from studio");
      const named = spec.studios.flatMap((name) =>
        all.filter((one) => fold(one.name).includes(fold(name))).map((one) => one.id),
      );
      if (named.length === 0) return null;
      studios = base.studios.length > 0 ? base.studios.filter((id) => named.includes(id)) : named;
      if (studios.length === 0) return null;
    }
    return {
      ...base,
      kinds,
      yearFrom: most(base.yearFrom, spec.yearFrom),
      yearTo: least(base.yearTo, spec.yearTo),
      genres: [...base.genres, ...spec.genres],
      studios,
      watch: [...base.watch, ...spec.watch],
      minutesFrom: spec.runtimeFrom,
      minutesTo: spec.runtimeTo,
    };
  }

  private titleRows(ids: string[]): Map<string, TitleRow> {
    return new Map(
      this.db
        .all<TitleRow>(
          `select id, kind, title, override_json, vote_average, vote_count, imdb_id, collection_id, collection_name
           from item where id in (select value from json_each(?))`,
          [JSON.stringify(ids)],
        )
        .map((row) => [row.id, row]),
    );
  }

  private ratingsOf(rows: Map<string, TitleRow>): Map<string, Ratings> {
    const imdbIds = [...rows.values()].flatMap((row) =>
      row.imdb_id === null ? [] : [row.imdb_id],
    );
    const omdb = this.omdb?.known(imdbIds) ?? new Map<string, OmdbRating>();
    const found = new Map<string, Ratings>();
    for (const row of rows.values()) {
      const other = row.imdb_id === null ? undefined : omdb.get(row.imdb_id);
      found.set(row.id, {
        tmdb: ratingOf(row.vote_count, row.vote_average),
        imdb: other?.imdb ?? null,
        rottenTomatoes: other?.rottenTomatoes ?? null,
        metacritic: other?.metacritic ?? null,
      });
    }
    return found;
  }

  /** Titles with every person asked for, each in the role asked for. */
  private withPeople(ids: string[], wanted: { ids: number[]; role: PersonRole }[]): string[] {
    const sets = wanted.map(({ ids: people, role }) => {
      const rows = this.db.all<{ item_id: string }>(
        `select distinct item_id from item_credit where person_id in (select value from json_each(?))
         ${role === "any" ? "" : role === "writer" ? "and role in ('writer', 'creator')" : "and role = ?"}`,
        role === "any" || role === "writer"
          ? [JSON.stringify(people)]
          : [JSON.stringify(people), role],
      );
      return new Set(rows.map((row) => row.item_id));
    });
    return ids.filter((id) => sets.every((set) => set.has(id)));
  }

  /** Episodes that matched, of shows that pass, that the device may see. */
  private episodes(
    matches: ReturnType<SearchIndex["matchTitles"]>,
    shows: ReadonlySet<string>,
    view: KidsView | null,
  ): { id: string; match: SearchMatch }[] {
    const candidates = matches.filter((one) => !shows.has(one.itemId));
    if (candidates.length === 0) return [];
    const parents = new Map(
      this.db
        .all<{ id: string; show: string | null }>(
          `select episode.id, season.parent_id as show from item as episode
           join item as season on season.id = episode.parent_id
           where episode.kind = 'episode' and episode.id in (select value from json_each(?))`,
          [JSON.stringify(candidates.map((one) => one.itemId))],
        )
        .map((row) => [row.id, row.show]),
    );
    return candidates.flatMap((one) => {
      const show = parents.get(one.itemId);
      if (show === undefined || show === null || !shows.has(show)) return [];
      if (view && !view.items.has(one.itemId)) return [];
      return [{ id: one.itemId, match: { field: one.field, text: one.text } }];
    });
  }

  private showOf(episodeId: string): string | null {
    return (
      this.db.get<{ show: string | null }>(
        `select season.parent_id as show from item as episode join item as season on season.id = episode.parent_id
         where episode.id = ?`,
        [episodeId],
      )?.show ?? null
    );
  }

  /** People whose name has the words, with titles the device may see. */
  private people(text: string, view: KidsView | null, limit: number): Group<SearchPerson> {
    const found = this.index.matchPeople(text, 200);
    return this.peopleById(
      found.map((one) => one.personId),
      view,
      limit,
    );
  }

  private peopleById(ids: number[], view: KidsView | null, limit: number): Group<SearchPerson> {
    if (ids.length === 0) return { total: 0, items: [] };
    const rows = this.db.all<{
      id: number;
      name: string;
      profile_path: string | null;
      item_id: string;
      role: CreditRole;
    }>(
      `select person.id, person.name, person.profile_path, item_credit.item_id, item_credit.role
       from person join item_credit on item_credit.person_id = person.id
       join item on item.id = item_credit.item_id
       where person.id in (select value from json_each(?))`,
      [JSON.stringify(ids)],
    );
    const people = new Map<number, SearchPerson & { items: Set<string> }>();
    for (const row of rows) {
      if (view && !view.items.has(row.item_id)) continue;
      const known = people.get(row.id) ?? {
        id: row.id,
        name: row.name,
        picture: row.profile_path,
        titles: 0,
        roles: [],
        items: new Set<string>(),
      };
      known.items.add(row.item_id);
      if (!known.roles.includes(row.role)) known.roles.push(row.role);
      people.set(row.id, known);
    }
    const order = new Map(ids.map((id, index) => [id, index]));
    const list = [...people.values()]
      .map(({ items, ...one }) => ({ ...one, titles: items.size }))
      .sort((a, b) => (order.get(a.id) ?? 0) - (order.get(b.id) ?? 0));
    return { total: list.length, items: list.slice(0, limit) };
  }

  /** Collections whose name has the words, of films the device may see. */
  private collections(text: string, view: KidsView | null, limit: number): Group<SearchCollection> {
    const typed = words(text);
    const rows = this.db.all<{ id: string; collection_id: number; collection_name: string }>(
      `select id, collection_id, collection_name from item
       where parent_id is null and collection_id is not null order by year, sort_title`,
    );
    const found = new Map<number, SearchCollection>();
    for (const row of rows) {
      if (view && !view.items.has(row.id)) continue;
      const name = ` ${fold(row.collection_name)}`;
      if (!typed.every((word) => name.includes(` ${word}`))) continue;
      const known = found.get(row.collection_id) ?? {
        id: row.collection_id,
        name: row.collection_name,
        itemIds: [],
      };
      known.itemIds.push(row.id);
      found.set(row.collection_id, known);
    }
    const list = [...found.values()];
    return { total: list.length, items: list.slice(0, limit) };
  }

  /** A person's titles in the library, as far as the device may see; null when there are none. */
  personInLibrary(personId: number, view: KidsView | null): PersonInLibrary | null {
    this.index.sync();
    const person = this.db.get<{ id: number; name: string; profile_path: string | null }>(
      "select id, name, profile_path from person where id = ?",
      [personId],
    );
    const credits = this.db.all<{ item_id: string; role: CreditRole; character: string | null }>(
      `select item_credit.item_id, item_credit.role, item_credit.character from item_credit
       join item on item.id = item_credit.item_id
       where item_credit.person_id = ? order by item.year desc, item.sort_title`,
      [personId],
    );
    const ids = [...new Set(credits.map((one) => one.item_id))].filter(
      (id) => !view || view.items.has(id),
    );
    if (!person || ids.length === 0) return null;
    const rows = this.titleRows(ids);
    const ratings = this.ratingsOf(rows);
    return {
      person: { id: person.id, name: person.name, picture: person.profile_path },
      titles: this.items.read(ids, view).map((item) => ({
        item,
        ratings: ratings.get(item.id) ?? NO_RATINGS,
        roles: credits
          .filter((one) => one.item_id === item.id)
          .map((one) => ({ role: one.role, character: one.character })),
      })),
    };
  }

  /** The TMDB ids of the films and shows the device sees, to tell what is in the library. */
  libraryTmdb(view: KidsView | null): Map<string, string> {
    const found = new Map<string, string>();
    for (const row of this.db.all<{ id: string; tmdb_type: string; tmdb_id: number }>(
      `select id, tmdb_type, tmdb_id from item where parent_id is null and kind in ('movie', 'show')
         and tmdb_id is not null and tmdb_type is not null`,
    )) {
      if (view && !view.items.has(row.id)) continue;
      found.set(`${row.tmdb_type}:${String(row.tmdb_id)}`, row.id);
    }
    return found;
  }
}

function isEmptyFilter(filter: TitleFilter): boolean {
  return (
    filter.kinds.length +
      filter.genres.length +
      filter.studios.length +
      filter.categories.length +
      filter.watch.length +
      filter.lengths.length +
      filter.quality.length +
      filter.languages.length ===
      0 &&
    filter.yearFrom === null &&
    filter.yearTo === null &&
    filter.added === null
  );
}

function defaultSort(spec: SearchSpec): TitleSort {
  return spec.ratings.length > 0
    ? { key: "rating", ascending: false }
    : { key: "title", ascending: true };
}

/** A title without that rating is in no range, as one without a year is in no years. */
export function passes(ratings: Ratings, bound: RatingBound): boolean {
  const value = ratings[bound.source];
  if (value === null) return false;
  if (bound.min !== null && value < bound.min) return false;
  return bound.max === null || value <= bound.max;
}
