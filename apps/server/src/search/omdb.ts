// SPDX-License-Identifier: MPL-2.0
import type { Database } from "../db/database.ts";
import { DEFAULT_LIMITS, LimitedFetch, type FetchLimits } from "../enrich/http.ts";
import { ProviderUnavailable } from "../enrich/provider.ts";
import { errorMessage, log } from "../log.ts";

/**
 * Ratings from OMDb: IMDb's, Rotten Tomatoes' critics score (the Tomatometer) and Metacritic's.
 * Only with an OMDb key the owner set (docs/decisions.md, "Search"): without one nothing is ever asked. OMDb's free key
 * allows 1,000 requests a day and its data is CC BY-NC 4.0 (non-commercial), so every answer is
 * kept per IMDb id and asked again only after a month, a few hundred a day at most.
 */

export const OMDB_BASE_URL = "https://www.omdbapi.com/";
export const OMDB_ATTRIBUTION =
  "IMDb, Rotten Tomatoes and Metacritic ratings come from OMDb (omdbapi.com), which is not endorsed by them.";
const DAY_MS = 86_400_000;

export interface OmdbRating {
  imdb: number | null;
  imdbVotes: number | null;
  rottenTomatoes: number | null;
  metacritic: number | null;
}

interface Row {
  imdb_id: string;
  imdb_rating: number | null;
  imdb_votes: number | null;
  rotten_tomatoes: number | null;
  metacritic: number | null;
  found: number;
  fetched_at: number;
}

export interface OmdbOptions {
  key: string | null;
  baseUrl?: string;
  now?: () => number;
  /** Requests a day, below OMDb's 1,000 for a free key. */
  perDay?: number;
  /** How many library titles one refresh asks about. */
  perRun?: number;
  /** How long an answer stands. */
  refreshAfterMs?: number;
  limits?: Partial<FetchLimits>;
}

/** What OMDb's key check found. */
export type OmdbCheck = "accepted" | "refused" | "unreachable";

export function looksLikeOmdbKey(key: string): boolean {
  return /^[A-Za-z0-9]{6,40}$/.test(key);
}

export class OmdbRatings {
  private readonly db: Database;
  private readonly baseUrl: string;
  private readonly now: () => number;
  private readonly perDay: number;
  private readonly perRun: number;
  private readonly refreshAfterMs: number;
  private readonly http: LimitedFetch;
  private readonly stopping = new AbortController();
  #key: string | null;
  private pausedUntil = 0;
  private running: Promise<number> | null = null;

  constructor(db: Database, options: OmdbOptions) {
    this.db = db;
    this.#key = cleanKey(options.key);
    this.baseUrl = options.baseUrl ?? OMDB_BASE_URL;
    this.now = options.now ?? Date.now;
    this.perDay = options.perDay ?? 900;
    this.perRun = options.perRun ?? 100;
    this.refreshAfterMs = options.refreshAfterMs ?? 30 * DAY_MS;
    this.http = new LimitedFetch(
      {
        ...DEFAULT_LIMITS,
        maxConcurrent: 2,
        minIntervalMs: 200,
        retries: 1,
        maxBackoffMs: 5_000,
        ...options.limits,
      },
      this.stopping.signal,
    );
  }

  get isConfigured(): boolean {
    return this.#key !== null;
  }

  setKey(key: string | null): void {
    this.#key = cleanKey(key);
    this.pausedUntil = 0;
  }

  stop(): void {
    this.stopping.abort();
  }

  /** What is known of these IMDb ids. Asks nobody. */
  known(imdbIds: readonly string[]): Map<string, OmdbRating> {
    const found = new Map<string, OmdbRating>();
    if (imdbIds.length === 0) return found;
    for (const row of this.db.all<Row>(
      "select * from omdb_rating where found = 1 and imdb_id in (select value from json_each(?))",
      [JSON.stringify(imdbIds)],
    )) {
      found.set(row.imdb_id, rating(row));
    }
    return found;
  }

  /**
   * Asks OMDb about the library's titles that have an IMDb id and no answer yet, or an old one.
   * A few at a time, within the day's allowance. Without a key it does nothing.
   */
  refresh(): Promise<number> {
    this.running ??= this.refreshOnce().finally(() => {
      this.running = null;
    });
    return this.running;
  }

  private async refreshOnce(): Promise<number> {
    if (this.#key === null || this.now() < this.pausedUntil) return 0;
    const due = this.db.all<{ imdb_id: string }>(
      `select distinct item.imdb_id from item
       left join omdb_rating on omdb_rating.imdb_id = item.imdb_id
       where item.kind in ('movie', 'show') and item.imdb_id is not null
         and (omdb_rating.imdb_id is null or omdb_rating.fetched_at <= ?)
       order by omdb_rating.fetched_at is not null, omdb_rating.fetched_at, item.added_at desc
       limit ?`,
      [this.now() - this.refreshAfterMs, this.perRun],
    );
    let asked = 0;
    for (const { imdb_id: id } of due) {
      if (this.stopping.signal.aborted) break;
      const answer = await this.ask(id);
      if (answer === "stop") break;
      asked += 1;
    }
    if (asked > 0) log.info("Read ratings from OMDb", { titles: asked });
    return asked;
  }

  /**
   * The ratings of one IMDb id: kept ones while they are fresh, else asked of OMDb when the
   * key and the day's allowance let it. Null when there are none.
   */
  async one(imdbId: string): Promise<OmdbRating | null> {
    const row = this.db.get<Row>("select * from omdb_rating where imdb_id = ?", [imdbId]);
    if (row && row.fetched_at > this.now() - this.refreshAfterMs) {
      return row.found === 1 ? rating(row) : null;
    }
    if (this.#key === null || this.now() < this.pausedUntil)
      return row?.found === 1 ? rating(row) : null;
    const answer = await this.ask(imdbId);
    if (answer === "stop" || answer === null) return row?.found === 1 ? rating(row) : null;
    return answer;
  }

  /** One request. "stop" when the key or the allowance is used up for now. */
  private async ask(imdbId: string): Promise<OmdbRating | null | "stop"> {
    const key = this.#key;
    if (key === null || !/^tt[0-9]{7,}$/.test(imdbId)) return null;
    if (!this.takeFromToday()) return "stop";
    const url = new URL(this.baseUrl);
    url.searchParams.set("i", imdbId);
    url.searchParams.set("apikey", key);
    let parsed: Record<string, unknown>;
    try {
      const { status, body } = await this.http.get(
        url,
        { accept: "application/json" },
        "Reading ratings",
      );
      if (status !== 200) return null;
      parsed = JSON.parse(new TextDecoder().decode(body)) as Record<string, unknown>;
    } catch (error) {
      if (this.stopping.signal.aborted) return "stop";
      // A refused key and "Request limit reached!" both answer 401: wait until tomorrow.
      const keyRefused = error instanceof ProviderUnavailable && error.keyRefused;
      this.pausedUntil = this.now() + (keyRefused ? DAY_MS : 15 * 60_000);
      log.warn("OMDb cannot be used now; ratings wait", {
        error: errorMessage(error).slice(0, 200),
        retryInMinutes: Math.round((this.pausedUntil - this.now()) / 60_000),
      });
      return "stop";
    }
    const found = parsed["Response"] === "True";
    const value: OmdbRating = found
      ? readRatings(parsed)
      : { imdb: null, imdbVotes: null, rottenTomatoes: null, metacritic: null };
    this.db.run(
      `insert into omdb_rating (imdb_id, imdb_rating, imdb_votes, rotten_tomatoes, metacritic, found, fetched_at)
       values (?, ?, ?, ?, ?, ?, ?)
       on conflict (imdb_id) do update set imdb_rating = excluded.imdb_rating, imdb_votes = excluded.imdb_votes,
         rotten_tomatoes = excluded.rotten_tomatoes, metacritic = excluded.metacritic,
         found = excluded.found, fetched_at = excluded.fetched_at`,
      [
        imdbId,
        value.imdb,
        value.imdbVotes,
        value.rottenTomatoes,
        value.metacritic,
        found ? 1 : 0,
        this.now(),
      ],
    );
    return found ? value : null;
  }

  /** Counts one request against today's allowance (UTC days, as OMDb counts). */
  private takeFromToday(): boolean {
    const today = new Date(this.now()).toISOString().slice(0, 10);
    const [day, count] = (this.db.getMeta("omdb_requests") ?? "").split(" ");
    const used = day === today ? Number(count ?? "0") : 0;
    if (used >= this.perDay) return false;
    this.db.setMeta("omdb_requests", `${today} ${String(used + 1)}`);
    return true;
  }
}

function cleanKey(key: string | null): string | null {
  const trimmed = key?.trim() ?? "";
  return trimmed === "" ? null : trimmed;
}

function rating(row: Row): OmdbRating {
  return {
    imdb: row.imdb_rating,
    imdbVotes: row.imdb_votes,
    rottenTomatoes: row.rotten_tomatoes,
    metacritic: row.metacritic,
  };
}

/** OMDb's answer: "8.8", "2,345,678", "87%", "74/100"; "N/A" for none. */
export function readRatings(answer: Record<string, unknown>): OmdbRating {
  const sources = Array.isArray(answer["Ratings"])
    ? (answer["Ratings"] as { Source?: unknown; Value?: unknown }[])
    : [];
  const of = (name: string): string | null => {
    const value = sources.find((one) => one.Source === name)?.Value;
    return typeof value === "string" ? value : null;
  };
  const number = (value: unknown, pattern: RegExp): number | null => {
    if (typeof value !== "string") return null;
    const match = pattern.exec(value.replace(/,/g, ""));
    if (!match?.[1]) return null;
    const n = Number(match[1]);
    return Number.isFinite(n) ? n : null;
  };
  const imdb =
    number(answer["imdbRating"], /^([0-9]+(?:\.[0-9]+)?)$/) ??
    number(of("Internet Movie Database"), /^([0-9.]+)\/10$/);
  const fits = (n: number | null, most: number): number | null =>
    n !== null && n >= 0 && n <= most ? n : null;
  return {
    imdb: fits(imdb, 10),
    imdbVotes: number(answer["imdbVotes"], /^([0-9]+)$/),
    rottenTomatoes: fits(number(of("Rotten Tomatoes"), /^([0-9]+)%$/), 100),
    metacritic: fits(
      number(answer["Metascore"], /^([0-9]+)$/) ?? number(of("Metacritic"), /^([0-9]+)\/100$/),
      100,
    ),
  };
}

/** Asks OMDb whether it takes a key, with one title. The key never goes into a log or an error. */
export async function checkOmdbKey(
  key: string,
  baseUrl: string = OMDB_BASE_URL,
  timeoutMs = 10_000,
): Promise<OmdbCheck> {
  const url = new URL(baseUrl);
  url.searchParams.set("i", "tt0111161");
  url.searchParams.set("apikey", key);
  try {
    const reply = await fetch(url, { signal: AbortSignal.timeout(timeoutMs), redirect: "error" });
    const text = await reply.text();
    if (reply.status === 401) return "refused";
    if (!reply.ok) return "unreachable";
    const parsed = JSON.parse(text) as { Response?: string };
    return parsed.Response === "True" ? "accepted" : "refused";
  } catch {
    return "unreachable";
  }
}
