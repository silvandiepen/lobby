// SPDX-License-Identifier: MPL-2.0
import type { TitleKind, WatchState } from "../library/query.ts";

/**
 * The small query language of search (docs/api.md, Search): free words, and filters such as
 * `actor:"Tom Hanks" year:1990..1999 rt>80`. The apps build the same from their filter chips
 * (LobbyKit `SearchQuery`): change both.
 */

export const RATING_SOURCES = ["tmdb", "imdb", "rottenTomatoes", "metacritic"] as const;
export type RatingSource = (typeof RATING_SOURCES)[number];
/** The highest score of each source: TMDB and IMDb out of 10, the others out of 100. */
export const RATING_SCALE: Readonly<Record<RatingSource, number>> = {
  tmdb: 10,
  imdb: 10,
  rottenTomatoes: 100,
  metacritic: 100,
};

export type PersonRole = "any" | "cast" | "director" | "writer";

export interface RatingBound {
  source: RatingSource;
  min: number | null;
  max: number | null;
}

export interface PersonWanted {
  /** A name as typed, or null when the id was given. */
  name: string | null;
  /** A TMDB person id, when known. */
  id: number | null;
  role: PersonRole;
}

/** One filter that was understood, for the app to show as a chip. */
export interface Understood {
  key: string;
  /** "Year 1990–1999", "Rotten Tomatoes ≥ 80%". */
  label: string;
  /** How it is written in the query, to take it out again. */
  token: string;
}

export interface SearchSpec {
  /** The free words, as typed. */
  text: string;
  titleContains: string[];
  titleExact: string | null;
  yearFrom: number | null;
  yearTo: number | null;
  ratings: RatingBound[];
  /** Minutes. */
  runtimeFrom: number | null;
  runtimeTo: number | null;
  people: PersonWanted[];
  genres: string[];
  studios: string[];
  collections: string[];
  kinds: TitleKind[];
  watch: WatchState[];
  understood: Understood[];
}

export function emptySpec(): SearchSpec {
  return {
    text: "",
    titleContains: [],
    titleExact: null,
    yearFrom: null,
    yearTo: null,
    ratings: [],
    runtimeFrom: null,
    runtimeTo: null,
    people: [],
    genres: [],
    studios: [],
    collections: [],
    kinds: [],
    watch: [],
    understood: [],
  };
}

/** Whether anything but the free words narrows the search. */
export function hasFilters(spec: SearchSpec): boolean {
  return spec.understood.length > 0;
}

const KEYS: Readonly<Record<string, string>> = {
  title: "title",
  t: "title",
  name: "title",
  exact: "exact",
  year: "year",
  y: "year",
  decade: "decade",
  actor: "cast",
  actress: "cast",
  cast: "cast",
  star: "cast",
  stars: "cast",
  director: "director",
  dir: "director",
  directed: "director",
  writer: "writer",
  writers: "writer",
  written: "writer",
  person: "person",
  people: "person",
  with: "person",
  rating: "tmdb",
  tmdb: "tmdb",
  imdb: "imdb",
  rt: "rottenTomatoes",
  tomatoes: "rottenTomatoes",
  tomatometer: "rottenTomatoes",
  rottentomatoes: "rottenTomatoes",
  mc: "metacritic",
  metacritic: "metacritic",
  metascore: "metacritic",
  runtime: "runtime",
  length: "runtime",
  minutes: "runtime",
  genre: "genre",
  g: "genre",
  studio: "studio",
  network: "studio",
  collection: "collection",
  kind: "kind",
  type: "kind",
  is: "is",
};

const KINDS: Readonly<Record<string, TitleKind>> = {
  movie: "movie",
  movies: "movie",
  film: "movie",
  films: "movie",
  show: "show",
  shows: "show",
  series: "show",
  tv: "show",
  video: "personal",
  videos: "personal",
  home: "personal",
  personal: "personal",
};

const STATES: Readonly<Record<string, WatchState>> = {
  watched: "watched",
  seen: "watched",
  unwatched: "unwatched",
  unseen: "unwatched",
  new: "unwatched",
  started: "in_progress",
  in_progress: "in_progress",
  inprogress: "in_progress",
  watching: "in_progress",
};

const SOURCE_LABEL: Readonly<Record<RatingSource, string>> = {
  tmdb: "TMDB",
  imdb: "IMDb",
  rottenTomatoes: "Rotten Tomatoes",
  metacritic: "Metacritic",
};

const ROLE_LABEL: Readonly<Record<PersonRole, string>> = {
  any: "With",
  cast: "Actor",
  director: "Director",
  writer: "Writer",
};

const MAX_QUERY = 500;
const MAX_FILTERS = 20;

interface Token {
  raw: string;
  key: string | null;
  op: string | null;
  value: string;
}

/** Splits a query into words and `key:value` filters; quotes keep words together. */
function tokens(query: string): Token[] {
  const found: Token[] = [];
  let index = 0;
  const readValue = (): string => {
    if (query[index] === '"') {
      const end = query.indexOf('"', index + 1);
      const value = query.slice(index + 1, end === -1 ? undefined : end);
      index = end === -1 ? query.length : end + 1;
      return value;
    }
    const start = index;
    while (index < query.length && !/\s/.test(query[index] ?? "")) index += 1;
    return query.slice(start, index);
  };
  while (index < query.length) {
    while (index < query.length && /\s/.test(query[index] ?? "")) index += 1;
    if (index >= query.length) break;
    const start = index;
    const head = /^([A-Za-z_]+)(:=|:>=|:<=|:>|:<|>=|<=|:|=|>|<)/.exec(query.slice(index));
    if (head?.[1] !== undefined && head[2] !== undefined && KEYS[head[1].toLowerCase()]) {
      index += head[0].length;
      const value = readValue();
      found.push({
        raw: query.slice(start, index),
        key: head[1].toLowerCase(),
        op: head[2].replace(/^:(?=[<>=])/, ""),
        value,
      });
    } else {
      const value = readValue();
      found.push({ raw: query.slice(start, index), key: null, op: null, value });
    }
  }
  return found;
}

const NUMBER = /^[0-9]+(?:[.,][0-9]+)?%?$/;
const num = (text: string): number => Number(text.replace("%", "").replace(",", "."));

/** A range from `1990..1999`, `1990-1999`, `>=7`, `..1999`, `7.5`; null when it is none. */
function range(op: string, value: string): { min: number | null; max: number | null } | null {
  const parts = /^([0-9.,%]*)(?:\.\.|–|-)([0-9.,%]*)$/.exec(value);
  if ((op === ":" || op === "=") && parts) {
    const [, low = "", high = ""] = parts;
    if (low === "" && high === "") return null;
    if ((low !== "" && !NUMBER.test(low)) || (high !== "" && !NUMBER.test(high))) return null;
    return { min: low === "" ? null : num(low), max: high === "" ? null : num(high) };
  }
  if (!NUMBER.test(value)) return null;
  const n = num(value);
  switch (op) {
    case ">":
    case ">=":
      // Whole scores: "rt>80" is 81 and up; a fraction counts from just above it.
      return { min: op === ">" ? (Number.isInteger(n) ? n + 1 : n + 0.01) : n, max: null };
    case "<":
    case "<=":
      return { min: null, max: op === "<" ? (Number.isInteger(n) ? n - 1 : n - 0.01) : n };
    default:
      return { min: n, max: n };
  }
}

function decade(value: string): number | null {
  const match = /^(?:([12][0-9])?([0-9]0))'?s?$/i.exec(value);
  if (!match?.[2]) return null;
  if (match[1]) return Number(`${match[1]}${match[2]}`);
  const short = Number(match[2]);
  return short >= 30 ? 1900 + short : 2000 + short;
}

const quote = (value: string): string =>
  /[\s"]/.test(value) ? `"${value.replace(/"/g, "")}"` : value;

/** Reads a query. What is not a filter it knows stays a free word. */
export function parseQuery(query: string): SearchSpec {
  const spec = emptySpec();
  const free: string[] = [];
  for (const token of tokens(query.slice(0, MAX_QUERY))) {
    if (token.key === null || spec.understood.length >= MAX_FILTERS || !apply(spec, token)) {
      free.push(token.raw);
    }
  }
  spec.text = free
    .map((word) => word.replace(/^"|"$/g, ""))
    .join(" ")
    .trim();
  return spec;
}

/** Puts one filter in; false when it does not make sense, so it is read as words. */
function apply(spec: SearchSpec, token: Token): boolean {
  const key = KEYS[token.key ?? ""];
  const op = token.op ?? ":";
  const value = token.value.trim();
  if (key === undefined || value === "") return false;
  const note = (label: string): true => {
    spec.understood.push({ key, label, token: token.raw });
    return true;
  };
  switch (key) {
    case "title":
      if (op === "=") {
        spec.titleExact = value;
        return note(`Title is “${value}”`);
      }
      if (op !== ":") return false;
      spec.titleContains.push(value);
      return note(`Title has “${value}”`);
    case "exact":
      spec.titleExact = value;
      return note(`Title is “${value}”`);
    case "year": {
      const found = range(op, value) ?? (op === ":" ? decadeRange(value) : null);
      if (!found || !wholeYears(found)) return false;
      if (found.min !== null) spec.yearFrom = Math.max(spec.yearFrom ?? found.min, found.min);
      if (found.max !== null) spec.yearTo = Math.min(spec.yearTo ?? found.max, found.max);
      return note(yearLabel(found.min, found.max));
    }
    case "decade": {
      const found = decadeRange(value);
      if (!found) return false;
      spec.yearFrom = found.min;
      spec.yearTo = found.max;
      return note(`${String(found.min)}s`);
    }
    case "cast":
    case "director":
    case "writer":
    case "person": {
      const role: PersonRole = key === "person" ? "any" : key;
      spec.people.push({ name: value, id: null, role });
      return note(`${ROLE_LABEL[role]} ${value}`);
    }
    case "tmdb":
    case "imdb":
    case "rottenTomatoes":
    case "metacritic": {
      const source = key;
      const found = range(op, value);
      if (!found) return false;
      const scale = RATING_SCALE[source];
      const fits = (n: number | null): boolean => n === null || (n >= 0 && n <= scale);
      if (!fits(found.min) || !fits(found.max)) return false;
      spec.ratings.push({ source, ...found });
      return note(ratingLabel(source, found.min, found.max));
    }
    case "runtime": {
      const found = range(op, value.replace(/m(in)?$/i, ""));
      if (!found) return false;
      if (op === ":" && found.min === found.max && !value.includes("..")) {
        // "runtime:90" is about an hour and a half, not exactly 90 minutes.
        found.min = Math.max(0, (found.min ?? 0) - 5);
        found.max = (found.max ?? 0) + 5;
      }
      spec.runtimeFrom = found.min;
      spec.runtimeTo = found.max;
      return note(runtimeLabel(found.min, found.max));
    }
    case "genre":
      if (op !== ":" && op !== "=") return false;
      spec.genres.push(value);
      return note(value);
    case "studio":
      if (op !== ":" && op !== "=") return false;
      spec.studios.push(value);
      return note(`Studio ${value}`);
    case "collection":
      if (op !== ":" && op !== "=") return false;
      spec.collections.push(value);
      return note(`Collection ${value}`);
    case "kind": {
      const kind = KINDS[value.toLowerCase()];
      if (!kind) return false;
      if (!spec.kinds.includes(kind)) spec.kinds.push(kind);
      return note(kind === "movie" ? "Films" : kind === "show" ? "Series" : "Home videos");
    }
    case "is": {
      const kind = KINDS[value.toLowerCase()];
      if (kind) {
        if (!spec.kinds.includes(kind)) spec.kinds.push(kind);
        return note(kind === "movie" ? "Films" : kind === "show" ? "Series" : "Home videos");
      }
      const state = STATES[value.toLowerCase()];
      if (!state) return false;
      if (!spec.watch.includes(state)) spec.watch.push(state);
      return note(
        state === "watched" ? "Watched" : state === "unwatched" ? "Unwatched" : "In progress",
      );
    }
    default:
      return false;
  }
}

function decadeRange(value: string): { min: number; max: number } | null {
  const start = decade(value);
  if (start === null || !/s$|'s$/i.test(value)) return null;
  return { min: start, max: start + 9 };
}

function wholeYears(found: { min: number | null; max: number | null }): boolean {
  const year = (n: number | null): boolean =>
    n === null || (Number.isInteger(n) && n >= 1800 && n <= 2200);
  return year(found.min) && year(found.max);
}

function yearLabel(min: number | null, max: number | null): string {
  if (min !== null && max !== null)
    return min === max ? `Year ${String(min)}` : `Year ${String(min)}–${String(max)}`;
  return min !== null ? `From ${String(min)}` : `Until ${String(max)}`;
}

function score(source: RatingSource, n: number): string {
  return RATING_SCALE[source] === 100 ? `${String(n)}%` : String(n);
}

function ratingLabel(source: RatingSource, min: number | null, max: number | null): string {
  const name = SOURCE_LABEL[source];
  if (min !== null && max !== null) {
    return min === max
      ? `${name} ${score(source, min)}`
      : `${name} ${score(source, min)}–${score(source, max)}`;
  }
  return min !== null ? `${name} ≥ ${score(source, min)}` : `${name} ≤ ${score(source, max ?? 0)}`;
}

function runtimeLabel(min: number | null, max: number | null): string {
  if (min !== null && max !== null) return `${String(min)}–${String(max)} min`;
  return min !== null ? `${String(min)} min or longer` : `Up to ${String(max)} min`;
}

/** Writes a person filter as the query language has it, for an app that offers a person page. */
export function personToken(role: PersonRole, name: string): string {
  const key = role === "any" ? "person" : role === "cast" ? "actor" : role;
  return `${key}:${quote(name)}`;
}
