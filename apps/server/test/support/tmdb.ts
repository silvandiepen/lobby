// SPDX-License-Identifier: MPL-2.0
import { createServer, type IncomingHttpHeaders, type Server } from "node:http";
import type { AddressInfo } from "node:net";

/**
 * A local HTTP server that answers the way TMDB's v3 reference documents.
 *
 * The titles, ids and answers in here and in enrich.test.ts are WRITTEN BY HAND from
 * TMDB's documentation (https://developer.themoviedb.org/reference). They are not
 * recordings. Recorded answers are in fixtures/tmdb-recorded.json (enrich-recorded.test.ts).
 */
export interface Received {
  path: string;
  query: URLSearchParams;
  headers: IncomingHttpHeaders;
}

export interface Answer {
  status?: number;
  headers?: Record<string, string>;
  body?: unknown;
}

export class LocalTmdb {
  readonly received: Received[] = [];
  /** Answers by path, e.g. "/3/movie/1". A missing path answers 404 as TMDB does. */
  readonly answers = new Map<string, Answer | ((query: URLSearchParams) => Answer)>();
  /** Runs before an answer; returning one replaces it. */
  intercept: ((request: Received) => Answer | null) | null = null;
  beforeAnswer: ((request: Received) => Promise<void>) | null = null;
  mostAtOnce = 0;
  jpeg: Buffer;
  private atOnce = 0;
  private server: Server;

  private constructor(jpeg: Buffer) {
    this.jpeg = jpeg;
    this.server = createServer((request, response) => {
      void (async () => {
        const url = new URL(request.url ?? "/", "http://localhost");
        const received = {
          path: url.pathname,
          query: url.searchParams,
          headers: request.headers,
        };
        this.received.push(received);
        this.atOnce += 1;
        this.mostAtOnce = Math.max(this.mostAtOnce, this.atOnce);
        await this.beforeAnswer?.(received);
        const answer = this.intercept?.(received) ?? this.answer(received);
        this.atOnce -= 1;
        response.writeHead(answer.status ?? 200, answer.headers);
        response.end(
          Buffer.isBuffer(answer.body) ? answer.body : JSON.stringify(answer.body ?? {}),
        );
      })();
    });
  }

  static async start(jpeg: Buffer): Promise<LocalTmdb> {
    const tmdb = new LocalTmdb(jpeg);
    await new Promise<void>((resolve) => tmdb.server.listen(0, "127.0.0.1", resolve));
    return tmdb;
  }

  get origin(): string {
    return `http://127.0.0.1:${(this.server.address() as AddressInfo).port}`;
  }

  stop(): Promise<void> {
    this.server.closeAllConnections();
    return new Promise((resolve) => {
      this.server.close(() => {
        resolve();
      });
    });
  }

  requests(path: string): Received[] {
    return this.received.filter((one) => one.path === path);
  }

  private answer(request: Received): Answer {
    if (request.path.startsWith("/t/p/")) return { body: this.jpeg };
    const found = this.answers.get(request.path);
    if (typeof found === "function") return found(request.query);
    return (
      found ?? {
        status: 404,
        body: {
          success: false,
          status_code: 34,
          status_message: "The resource you requested could not be found.",
        },
      }
    );
  }

  /** `GET /search/movie` and `/search/tv`: filtered by the documented year parameter. */
  search(type: "movie" | "tv", results: Record<string, unknown>[], totalPages = 1): void {
    this.answers.set(`/3/search/${type}`, (query) => {
      const year = query.get(type === "movie" ? "primary_release_year" : "first_air_date_year");
      const dateField = type === "movie" ? "release_date" : "first_air_date";
      const titleField = type === "movie" ? "title" : "name";
      const words = (query.get("query") ?? "").toLowerCase();
      const fitting = results.filter(
        (one) =>
          (year === null || String(one[dateField]).startsWith(year)) &&
          [one[titleField], ...((one["aka"] as string[] | undefined) ?? [])].some((title) =>
            String(title).toLowerCase().includes(words),
          ),
      );
      return {
        body: {
          page: Number(query.get("page") ?? 1),
          results: fitting,
          total_pages: totalPages,
          total_results: fitting.length,
        },
      };
    });
  }
}

/** A `GET /movie/{id}` answer with the appended parts Lobby asks for. */
export function movieAnswer(
  id: number,
  title: string,
  date: string,
  extra: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    adult: false,
    backdrop_path: `/backdrop${id}.jpg`,
    genres: [
      { id: 16, name: "Animation" },
      { id: 10751, name: "Family" },
    ],
    id,
    imdb_id: `tt${String(id).padStart(7, "0")}`,
    original_language: "en",
    original_title: title,
    overview: `About ${title}.`,
    poster_path: `/poster${id}.jpg`,
    release_date: date,
    runtime: 90,
    title,
    vote_count: 50,
    external_ids: { imdb_id: `tt${String(id).padStart(7, "0")}` },
    videos: {
      results: [
        {
          iso_639_1: "en",
          name: "Fan edit",
          key: "fanfanfan11",
          site: "YouTube",
          type: "Trailer",
          official: false,
          published_at: "2020-01-01T00:00:00.000Z",
        },
        {
          iso_639_1: "en",
          name: "Official Trailer",
          key: "official0001",
          site: "YouTube",
          type: "Trailer",
          official: true,
          published_at: "2019-01-01T00:00:00.000Z",
        },
      ],
    },
    images: {
      backdrops: [{ file_path: `/backdrop${id}.jpg`, iso_639_1: null, width: 1920, height: 1080 }],
      logos: [],
      posters: [
        { file_path: `/plain${id}.jpg`, iso_639_1: null, width: 1000, height: 1500 },
        { file_path: `/poster${id}.jpg`, iso_639_1: "en", width: 1000, height: 1500 },
      ],
    },
    alternative_titles: { titles: [] },
    translations: { translations: [] },
    ...extra,
  };
}

/** A `GET /tv/{id}` answer. */
export function showAnswer(
  id: number,
  name: string,
  date: string,
  seasons: number[],
  episodeCounts: number[],
  extra: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    ...movieAnswer(id, name, date),
    title: undefined,
    original_title: undefined,
    release_date: undefined,
    imdb_id: undefined,
    runtime: undefined,
    name,
    original_name: name,
    first_air_date: date,
    episode_run_time: [],
    seasons: seasons.map((number, index) => ({
      id: id * 100 + number,
      season_number: number,
      episode_count: episodeCounts[index] ?? 0,
    })),
    alternative_titles: { results: [] },
    ...extra,
  };
}

/** A `GET /tv/{id}/season/{n}` answer. */
export function seasonAnswer(
  showId: number,
  number: number,
  titles: string[],
  runtime = 7,
): Record<string, unknown> {
  return {
    _id: "0123456789abcdef01234567",
    air_date: "2020-03-17",
    id: showId * 100 + number,
    name: `Season ${number}`,
    overview: `Season ${number} in short.`,
    poster_path: `/season${showId}x${number}.jpg`,
    season_number: number,
    images: { posters: [] },
    episodes: titles.map((name, index) => ({
      air_date: `2020-03-${String(17 + index).padStart(2, "0")}`,
      episode_number: index + 1,
      episode_type: "standard",
      id: showId * 10_000 + number * 100 + index + 1,
      name,
      overview: `In ${name}.`,
      production_code: "",
      runtime,
      season_number: number,
      show_id: showId,
      still_path: `/still${showId}x${number}x${index + 1}.jpg`,
      vote_average: 8,
      vote_count: 10,
      crew: [],
      guest_stars: [],
    })),
  };
}
