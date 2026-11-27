// SPDX-License-Identifier: MPL-2.0
import type { CreditRole, TitleType } from "../enrich/provider.ts";
import { ProviderUnavailable } from "../enrich/provider.ts";
import {
  TMDB_ATTRIBUTION,
  type OutsideHit,
  type OutsidePerson,
  type OutsideTitleHit,
  type TmdbProvider,
} from "../enrich/tmdb.ts";
import { errorMessage, log } from "../log.ts";
import { OMDB_ATTRIBUTION, type OmdbRatings } from "./omdb.ts";
import { NO_RATINGS, passes, type Ratings } from "./service.ts";
import type { SearchSpec } from "./syntax.ts";

/**
 * Search beyond the library, at TMDB with the owner's key (docs/decisions.md, "Search"): films, shows and people that
 * are not in the library, with their links to TMDB and IMDb. Nothing of it can be played and none
 * of it becomes a library item; answers are kept in memory for a while, so typing the same again
 * asks TMDB nothing. IMDb itself has no open API and is never asked.
 */

export interface OutsideTitle {
  tmdb: { type: TitleType; id: number };
  title: string;
  originalTitle: string;
  year: number | null;
  overview: string | null;
  /** For `GET /v1/search/picture?path=`. */
  poster: string | null;
  ratings: Ratings;
  votes: number;
  imdbId: string | null;
  links: Links;
  /** Set when the title is in the library after all (seen by its TMDB id): its item id. */
  itemId: string | null;
}

export interface OutsidePersonHit {
  id: number;
  name: string;
  knownFor: string | null;
  knownForTitles: string[];
  picture: string | null;
  links: Links;
}

export interface Links {
  tmdb: string;
  imdb: string | null;
}

export type OutsideReason = "no_key" | "unavailable" | "rate_limited";

export interface OutsideAnswer {
  available: boolean;
  reason: OutsideReason | null;
  films: OutsideTitle[];
  series: OutsideTitle[];
  people: OutsidePersonHit[];
  /** Filters that could not be applied out there: ratings from OMDb are not known before. */
  notApplied: string[];
  attribution: string[];
}

export interface OutsideTitleAnswer extends OutsideTitle {
  genres: string[];
  runtimeMinutes: number | null;
  people: {
    id: number;
    name: string;
    role: CreditRole;
    character: string | null;
    picture: string | null;
  }[];
  attribution: string[];
}

export interface PersonPageOutside {
  id: number;
  name: string;
  biography: string | null;
  birthday: string | null;
  deathday: string | null;
  knownFor: string | null;
  picture: string | null;
  links: Links;
  /** What they were in that is not in the library, most popular first. */
  elsewhere: (OutsideTitle & { roles: string[] })[];
}

const ANSWER_MS = 60 * 60_000;
const IDS_MS = 7 * 86_400_000;
const MAX_KEPT = 300;
const PER_GROUP = 12;
/** For this many of the first results their IMDb id is looked up as well. */
const WITH_IMDB = 6;

export const tmdbLink = (kind: "movie" | "tv" | "person", id: number): string =>
  `https://www.themoviedb.org/${kind}/${String(id)}`;
export const imdbLink = (id: string | null): string | null =>
  id === null
    ? null
    : id.startsWith("nm")
      ? `https://www.imdb.com/name/${id}/`
      : `https://www.imdb.com/title/${id}/`;

/** A small map that forgets what is old or was used longest ago. */
class Kept<T> {
  private readonly entries = new Map<string, { at: number; value: T }>();
  private readonly ms: number;
  private readonly now: () => number;

  constructor(ms: number, now: () => number) {
    this.ms = ms;
    this.now = now;
  }

  get(key: string): T | undefined {
    const found = this.entries.get(key);
    if (!found) return undefined;
    if (this.now() - found.at > this.ms) {
      this.entries.delete(key);
      return undefined;
    }
    this.entries.delete(key);
    this.entries.set(key, found);
    return found.value;
  }

  set(key: string, value: T): void {
    this.entries.delete(key);
    this.entries.set(key, { at: this.now(), value });
    while (this.entries.size > MAX_KEPT) {
      const oldest = this.entries.keys().next().value;
      if (oldest === undefined) break;
      this.entries.delete(oldest);
    }
  }
}

export class OutsideSearch {
  private readonly provider: () => TmdbProvider | null;
  private readonly omdb: OmdbRatings | null;
  private readonly answers: Kept<
    Omit<OutsideAnswer, "films" | "series"> & { films: OutsideTitle[]; series: OutsideTitle[] }
  >;
  private readonly imdbIds: Kept<string | null>;
  private readonly people: Kept<OutsidePerson | null>;
  private readonly titles: Kept<OutsideTitleAnswer | null>;
  private readonly pictures: Kept<Uint8Array<ArrayBuffer> | null>;

  constructor(
    provider: () => TmdbProvider | null,
    omdb: OmdbRatings | null,
    now: () => number = Date.now,
  ) {
    this.provider = provider;
    this.omdb = omdb;
    this.answers = new Kept(ANSWER_MS, now);
    this.imdbIds = new Kept(IDS_MS, now);
    this.people = new Kept(ANSWER_MS, now);
    this.titles = new Kept(ANSWER_MS, now);
    this.pictures = new Kept(IDS_MS, now);
  }

  private attribution(): string[] {
    return this.omdb?.isConfigured === true
      ? [TMDB_ATTRIBUTION, OMDB_ATTRIBUTION]
      : [TMDB_ATTRIBUTION];
  }

  private empty(reason: OutsideReason | null): OutsideAnswer {
    return {
      available: reason === null,
      reason,
      films: [],
      series: [],
      people: [],
      notApplied: [],
      attribution: this.attribution(),
    };
  }

  /** A failure that is TMDB's: said in the answer, never a failed search. */
  private failed(error: unknown): OutsideReason {
    if (error instanceof ProviderUnavailable) {
      log.warn("TMDB could not be asked for search", { error: errorMessage(error).slice(0, 200) });
      return "unavailable";
    }
    throw error;
  }

  /**
   * Films, shows and people at TMDB for these words, those in the library (`library`, by
   * "movie:<id>" or "tv:<id>") marked with their item id.
   */
  async search(spec: SearchSpec, library: ReadonlyMap<string, string>): Promise<OutsideAnswer> {
    const provider = this.provider();
    if (!provider) return this.empty("no_key");
    const text = (spec.titleExact ?? [spec.text, ...spec.titleContains].join(" ")).trim();
    const year = spec.yearFrom !== null && spec.yearFrom === spec.yearTo ? spec.yearFrom : null;
    const wantsMovies = spec.kinds.length === 0 || spec.kinds.includes("movie");
    const wantsShows = spec.kinds.length === 0 || spec.kinds.includes("show");
    const key = JSON.stringify([text, year, wantsMovies, wantsShows, spec.people]);
    let found = this.answers.get(key);
    if (!found) {
      try {
        if (text !== "") {
          const [movies, shows, people] = await Promise.all([
            wantsMovies ? provider.searchOutside("movie", text, year) : Promise.resolve([]),
            wantsShows ? provider.searchOutside("tv", text, year) : Promise.resolve([]),
            spec.kinds.length === 0 && spec.people.length === 0
              ? provider.searchOutside("person", text, null)
              : Promise.resolve([]),
          ]);
          found = {
            ...this.empty(null),
            films: titlesOf(movies),
            series: titlesOf(shows),
            people: people.flatMap((one) =>
              one.kind === "person"
                ? [
                    {
                      id: one.id,
                      name: one.name,
                      knownFor: one.knownFor,
                      knownForTitles: one.knownForTitles,
                      picture: one.profilePath,
                      links: { tmdb: tmdbLink("person", one.id), imdb: null },
                    },
                  ]
                : [],
            ),
          };
        } else if (spec.people.length > 0) {
          found = await this.byPeople(provider, spec);
        } else {
          found = this.empty(null);
        }
      } catch (error) {
        return this.empty(this.failed(error));
      }
      this.answers.set(key, found);
    }
    const inRange = (one: OutsideTitle): boolean =>
      (spec.yearFrom === null || (one.year !== null && one.year >= spec.yearFrom)) &&
      (spec.yearTo === null || (one.year !== null && one.year <= spec.yearTo)) &&
      spec.ratings.every((bound) => bound.source !== "tmdb" || passes(one.ratings, bound));
    const mark = (one: OutsideTitle): OutsideTitle => ({
      ...one,
      itemId: library.get(`${one.tmdb.type}:${String(one.tmdb.id)}`) ?? null,
    });
    const answer: OutsideAnswer = {
      ...found,
      // What is in the library is not "elsewhere"; it is in the library's own results.
      films: found.films
        .map(mark)
        .filter((one) => one.itemId === null && inRange(one))
        .slice(0, PER_GROUP),
      series: found.series
        .map(mark)
        .filter((one) => one.itemId === null && inRange(one))
        .slice(0, PER_GROUP),
      people: found.people.slice(0, PER_GROUP),
      notApplied: [
        ...new Set(spec.ratings.filter((one) => one.source !== "tmdb").map((one) => one.source)),
      ],
    };
    await this.addImdb(provider, [
      ...answer.films.slice(0, WITH_IMDB),
      ...answer.series.slice(0, WITH_IMDB),
    ]);
    this.addKnownRatings([...answer.films, ...answer.series]);
    return answer;
  }

  /** Titles of the people asked for, at TMDB: for "actor:…" without other words. */
  private async byPeople(provider: TmdbProvider, spec: SearchSpec): Promise<OutsideAnswer> {
    const sets: OutsideTitle[][] = [];
    for (const wanted of spec.people) {
      const [hit] = await provider.searchOutside("person", wanted.name ?? "", null);
      if (hit?.kind !== "person") return this.empty(null);
      const person = await this.person(hit.id);
      if (!person) return this.empty(null);
      sets.push(
        person.titles
          .filter((title) =>
            wanted.role === "any"
              ? true
              : wanted.role === "cast"
                ? title.asCast
                : wanted.role === "director"
                  ? title.roles.includes("Director")
                  : title.roles.some((role) => /writ|screenplay|story|novel|creator/i.test(role)),
          )
          .sort((a, b) => b.popularity - a.popularity)
          .map((one) => titleOf(one)),
      );
    }
    const [first = [], ...rest] = sets;
    const shared = first.filter((one) =>
      rest.every((set) =>
        set.some((other) => other.tmdb.type === one.tmdb.type && other.tmdb.id === one.tmdb.id),
      ),
    );
    return {
      ...this.empty(null),
      films: shared.filter((one) => one.tmdb.type === "movie"),
      series: shared.filter((one) => one.tmdb.type === "tv"),
    };
  }

  /** Looks up the IMDb ids of a few titles, kept for a week. */
  private async addImdb(provider: TmdbProvider, titles: OutsideTitle[]): Promise<void> {
    await Promise.all(
      titles.map(async (one) => {
        const key = `${one.tmdb.type}:${String(one.tmdb.id)}`;
        let id = this.imdbIds.get(key);
        if (id === undefined) {
          try {
            id = (await provider.outsideTitle(one.tmdb.type, one.tmdb.id))?.imdbId ?? null;
          } catch (error) {
            // One title without its IMDb link costs only that link.
            if (!(error instanceof ProviderUnavailable)) throw error;
            return;
          }
          this.imdbIds.set(key, id);
        }
        one.imdbId = id;
        one.links = { ...one.links, imdb: imdbLink(id) };
      }),
    );
  }

  /** OMDb's ratings where they are known already; this asks OMDb nothing. */
  private addKnownRatings(titles: OutsideTitle[]): void {
    const ids = titles.flatMap((one) => (one.imdbId === null ? [] : [one.imdbId]));
    const known = this.omdb?.known(ids);
    if (!known) return;
    for (const one of titles) {
      const found = one.imdbId === null ? undefined : known.get(one.imdbId);
      if (found) {
        one.ratings = {
          ...one.ratings,
          imdb: found.imdb,
          rottenTomatoes: found.rottenTomatoes,
          metacritic: found.metacritic,
        };
      }
    }
  }

  /** One film or show at TMDB, with its people, and its ratings from OMDb when there is a key. */
  async title(
    type: TitleType,
    id: number,
    library: ReadonlyMap<string, string>,
  ): Promise<OutsideTitleAnswer | null | OutsideReason> {
    const provider = this.provider();
    if (!provider) return "no_key";
    const key = `${type}:${String(id)}`;
    let found = this.titles.get(key);
    if (found === undefined) {
      try {
        const details = await provider.outsideTitle(type, id);
        found =
          details === null
            ? null
            : {
                ...titleOf(details),
                imdbId: details.imdbId,
                links: { tmdb: tmdbLink(type, id), imdb: imdbLink(details.imdbId) },
                genres: details.genres,
                runtimeMinutes: details.runtimeMinutes,
                people: details.credits.slice(0, 20).map((one) => ({
                  id: one.personId,
                  name: one.name,
                  role: one.role,
                  character: one.character,
                  picture: one.profilePath,
                })),
                attribution: this.attribution(),
              };
      } catch (error) {
        return this.failed(error);
      }
      this.titles.set(key, found);
    }
    if (found === null) return null;
    const ratings = found.imdbId === null ? null : await this.omdb?.one(found.imdbId);
    return {
      ...found,
      ratings: ratings
        ? {
            ...found.ratings,
            imdb: ratings.imdb,
            rottenTomatoes: ratings.rottenTomatoes,
            metacritic: ratings.metacritic,
          }
        : found.ratings,
      itemId: library.get(key) ?? null,
      attribution: this.attribution(),
    };
  }

  private async person(id: number): Promise<OutsidePerson | null> {
    const provider = this.provider();
    if (!provider) return null;
    let found = this.people.get(String(id));
    if (found === undefined) {
      found = await provider.person(id);
      this.people.set(String(id), found);
    }
    return found;
  }

  /** A person at TMDB and what they were in that is not in the library. */
  async personPage(
    id: number,
    library: ReadonlyMap<string, string>,
  ): Promise<PersonPageOutside | null | OutsideReason> {
    if (!this.provider()) return "no_key";
    let person: OutsidePerson | null;
    try {
      person = await this.person(id);
    } catch (error) {
      return this.failed(error);
    }
    if (!person) return null;
    const elsewhere = person.titles
      .filter((one) => !library.has(`${one.kind}:${String(one.id)}`))
      .sort((a, b) => b.popularity - a.popularity)
      .slice(0, 60)
      .map((one) => ({ ...titleOf(one), roles: one.roles }));
    this.addKnownRatings(elsewhere);
    return {
      id: person.id,
      name: person.name,
      biography: person.biography,
      birthday: person.birthday,
      deathday: person.deathday,
      knownFor: person.knownFor,
      picture: person.profilePath,
      links: { tmdb: tmdbLink("person", person.id), imdb: imdbLink(person.imdbId) },
      elsewhere,
    };
  }

  /** A poster or a person's picture from TMDB, small, kept for a week. */
  async picture(path: string): Promise<Uint8Array<ArrayBuffer> | null | OutsideReason> {
    const provider = this.provider();
    if (!provider) return "no_key";
    let found = this.pictures.get(path);
    if (found === undefined) {
      try {
        found = await provider.image("poster", path, "preview");
      } catch (error) {
        return this.failed(error);
      }
      this.pictures.set(path, found);
    }
    return found;
  }
}

function titlesOf(hits: OutsideHit[]): OutsideTitle[] {
  return hits.flatMap((one) => (one.kind === "person" ? [] : [titleOf(one)]));
}

function titleOf(hit: OutsideTitleHit): OutsideTitle {
  return {
    tmdb: { type: hit.kind, id: hit.id },
    title: hit.title,
    originalTitle: hit.originalTitle,
    year: hit.year,
    overview: hit.overview,
    poster: hit.posterPath,
    ratings: { ...NO_RATINGS, tmdb: hit.rating },
    votes: hit.votes,
    imdbId: null,
    links: { tmdb: tmdbLink(hit.kind, hit.id), imdb: null },
    itemId: null,
  };
}
