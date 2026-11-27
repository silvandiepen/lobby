// SPDX-License-Identifier: MPL-2.0
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { Devices } from "../src/auth/devices.ts";
import { Database } from "../src/db/database.ts";
import { Enricher, type EnricherOptions } from "../src/enrich/index.ts";
import { createApp } from "../src/http/app.ts";
import { Catalogue } from "../src/library/catalogue.ts";
import { ItemReader, type ApiItem } from "../src/library/items.ts";
import { parseMediaPath, type SourceHint } from "../src/library/parse.ts";
import { Scanner } from "../src/library/scanner.ts";
import { Studios } from "../src/library/studios.ts";
import { ProgressStore } from "../src/progress.ts";
import { makeTempDir, makeVideo, removeDir } from "./support/media.ts";
import { LocalTmdb, movieAnswer, seasonAnswer, showAnswer } from "./support/tmdb.ts";

const V3_KEY = "0123456789abcdef0123456789abcdef";
const V4_TOKEN = "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJ0ZXN0In0.c2lnbmF0dXJl";
const START = 1_800_000_000_000;
const DAY = 86_400_000;

interface Row {
  id: string;
  kind: string;
  title: string;
  sort_title: string;
  year: number | null;
  overview: string | null;
  ident_key: string;
  match_status: string;
  tmdb_type: string | null;
  tmdb_id: number | null;
  imdb_id: string | null;
  candidates_json: string | null;
  enrich_next_attempt_at: number | null;
  enriched_at: number | null;
  revision: number;
}

let jpeg: Buffer;
let dir: string;
let db: Database;
let catalogue: Catalogue;
let tmdb: LocalTmdb;
let clock: { now: number };
let enrichers: Enricher[];
let logged: string[];

beforeAll(() => {
  jpeg = execFileSync("ffmpeg", [
    ..."-v error -f lavfi -i testsrc2=size=78x116 -frames:v 1 -f image2 -c:v mjpeg -".split(" "),
  ]);
});

beforeEach(async () => {
  dir = makeTempDir();
  clock = { now: START };
  db = new Database(join(dir, "lobby.db"));
  catalogue = new Catalogue(db, () => clock.now);
  for (const hint of ["movies", "series", "personal"]) {
    db.run("insert into source (id, path, name, hint, created_at) values (?, ?, ?, ?, 0)", [
      hint,
      `/${hint}`,
      hint,
      hint,
    ]);
  }
  tmdb = await LocalTmdb.start(jpeg);
  enrichers = [];
  logged = [];
  for (const level of ["log", "warn", "error"] as const) {
    vi.spyOn(console, level).mockImplementation((line: unknown) => {
      logged.push(String(line));
    });
  }
});

afterEach(async () => {
  for (const enricher of enrichers) await enricher.stop();
  vi.restoreAllMocks();
  await tmdb.stop();
  db.close();
  removeDir(dir);
});

/** A probed file, filed by the real parser and catalogue. */
function addFile(
  relPath: string,
  hint: SourceHint = "movies",
  minutes: number | null = 90,
): string[] {
  const id = randomUUID();
  const parsed = parseMediaPath(relPath, hint);
  db.run(
    `insert into asset (id, source_id, rel_path, size, mtime_ms, revision, state, duration_ms, parsed_json,
       first_seen_at, updated_at) values (?, ?, ?, 1, 1, '1', 'probed', ?, ?, 0, 0)`,
    [id, hint, relPath, minutes === null ? null : minutes * 60_000, JSON.stringify(parsed)],
  );
  return catalogue.linkAsset(id, parsed, hint);
}

function enricher(options: Partial<EnricherOptions> = {}): Enricher {
  const made = new Enricher({
    db,
    catalogue,
    key: V3_KEY,
    language: "en-US",
    artworkDir: join(dir, "artwork"),
    baseUrl: `${tmdb.origin}/3`,
    imageBaseUrl: `${tmdb.origin}/t/p`,
    now: () => clock.now,
    ...options,
    limits: { minIntervalMs: 0, backoffMs: 5, retries: 2, timeoutMs: 2_000, ...options.limits },
  });
  enrichers.push(made);
  return made;
}

function row(id: string | undefined): Row {
  const found = db.get<Row>("select * from item where id = ?", [id ?? ""]);
  if (!found) throw new Error("no such item");
  return found;
}

function api(id: string | undefined): ApiItem {
  const [item] = new ItemReader(db).read([id ?? ""]);
  if (!item) throw new Error("no such item");
  return item;
}

function review(id: string | undefined): {
  reason: string;
  candidates: { id: number; title: string; year: number | null; evidence: string[] }[];
} {
  return JSON.parse(row(id).candidates_json ?? "null") as ReturnType<typeof review>;
}

function offerMovie(id: number, title: string, date: string, extra = {}): Record<string, unknown> {
  tmdb.answers.set(`/3/movie/${id}`, { body: movieAnswer(id, title, date, extra) });
  return {
    adult: false,
    backdrop_path: `/backdrop${id}.jpg`,
    genre_ids: [16],
    id,
    original_language: "en",
    original_title: title,
    overview: `About ${title}.`,
    popularity: 10,
    poster_path: `/poster${id}.jpg`,
    release_date: date,
    title,
    video: false,
    vote_average: 7,
    vote_count: 50,
  };
}

function offerShow(
  id: number,
  name: string,
  date: string,
  seasons: Record<number, string[]>,
  extra = {},
): Record<string, unknown> {
  const numbers = Object.keys(seasons).map(Number);
  tmdb.answers.set(`/3/tv/${id}`, {
    body: showAnswer(
      id,
      name,
      date,
      numbers,
      numbers.map((number) => seasons[number]?.length ?? 0),
      extra,
    ),
  });
  for (const number of numbers) {
    const titles = seasons[number] ?? [];
    tmdb.answers.set(`/3/tv/${id}/season/${number}`, { body: seasonAnswer(id, number, titles) });
    titles.forEach((_, index) => {
      tmdb.answers.set(`/3/tv/${id}/season/${number}/episode/${index + 1}/external_ids`, {
        body: { id: 1, imdb_id: `tt${9_000_000 + number * 100 + index + 1}`, tvdb_id: 1 },
      });
    });
  }
  return { id, name, original_name: name, first_air_date: date, overview: "", poster_path: null };
}

describe("films", () => {
  it("fills in a film with a year, and keeps its identity", async () => {
    tmdb.search("movie", [
      offerMovie(101, "The Jungle Book", "1967-10-18"),
      offerMovie(102, "The Jungle Book", "2016-04-07"),
    ]);
    const [id] = addFile("The Jungle Book (1967)/movie.mkv");
    const before = row(id);
    expect(await enricher().run()).toMatchObject({ matched: 1, needsReview: 0, failed: 0 });

    const after = api(id);
    expect(after).toMatchObject({
      title: "The Jungle Book",
      year: 1967,
      overview: "About The Jungle Book.",
      airDate: "1967-10-18",
      runtimeMs: 90 * 60_000,
      genres: ["Animation", "Family"],
      matchStatus: "matched",
      imdbId: "tt0000101",
      tmdb: { type: "movie", id: 101 },
      trailer: { provider: "youtube", key: "official0001" },
    });
    expect(after.artwork.poster).toMatchObject({ width: 78, height: 116 });
    expect(after.artwork.backdrop).not.toBeNull();
    expect(row(id).ident_key).toBe(before.ident_key);
    expect(row(id).revision).toBeGreaterThan(before.revision);

    const art = db.all<{ local_path: string; remote_path: string; kind: string }>(
      "select local_path, remote_path, kind from artwork order by kind",
    );
    // English poster for an English household, a backdrop without words.
    expect(art.map((one) => one.remote_path)).toEqual(["/backdrop101.jpg", "/poster101.jpg"]);
    for (const one of art) expect(readFileSync(one.local_path).equals(jpeg)).toBe(true);
    expect(tmdb.requests("/t/p/w780/poster101.jpg")).toHaveLength(1);
    expect(tmdb.requests("/t/p/original/backdrop101.jpg")).toHaveLength(1);
  });

  it("leaves a remake pair without a year to a manager, with both as candidates", async () => {
    tmdb.search("movie", [
      offerMovie(1, "Aladdin", "1992-11-25"),
      offerMovie(2, "Aladdin", "2019-05-22", { runtime: 128 }),
    ]);
    const [unsure] = addFile("Aladdin.mkv");
    const [remake] = addFile("Aladdin (2019).mkv", "movies", 128);
    await enricher().run();
    expect(row(unsure)).toMatchObject({ match_status: "needs_review", tmdb_id: null });
    expect(review(unsure).candidates.map((one) => [one.id, one.year])).toEqual([
      [1, 1992],
      [2, 2019],
    ]);
    expect(row(remake)).toMatchObject({ match_status: "matched", tmdb_id: 2 });
  });

  it("does not guess between two films of the same name and year", async () => {
    tmdb.search("movie", [
      offerMovie(1, "Twin", "2010-01-01"),
      offerMovie(2, "Twin", "2010-09-01"),
    ]);
    const [id] = addFile("Twin (2010).mkv");
    await enricher().run();
    expect(row(id).match_status).toBe("needs_review");
  });

  it("tells a film from a short of the same name and year by its running time", async () => {
    tmdb.search("movie", [
      offerMovie(1, "Twin", "2010-01-01"),
      offerMovie(2, "Twin", "2010-09-01", { runtime: 48 }),
      offerMovie(3, "The Twin", "2010-03-01", { runtime: 91 }),
    ]);
    const [id] = addFile("Twin (2010).mkv");
    await enricher().run();
    expect(row(id)).toMatchObject({ match_status: "matched", tmdb_id: 1 });
  });

  it("takes the film everyone means over a namesake nobody knows", async () => {
    tmdb.search("movie", [
      offerMovie(1, "Alice", "2010-03-03", { runtime: 92, vote_count: 15_000 }),
      offerMovie(2, "Alice", "2010-01-01", { runtime: 84, vote_count: 3 }),
    ]);
    const [id] = addFile("Alice (2010).mkv");
    await enricher().run();
    expect(row(id)).toMatchObject({ match_status: "matched", tmdb_id: 1 });
  });

  it("looks again at what needs review once the matching rules changed", async () => {
    tmdb.search("movie", []);
    const [id] = addFile("Later (2001).mkv");
    const one = enricher();
    await one.run();
    tmdb.search("movie", [offerMovie(1, "Later", "2001-01-01")]);
    await one.run();
    expect(row(id).match_status).toBe("needs_review");
    db.setMeta("matcher_version", "0");
    await one.run();
    expect(row(id).match_status).toBe("matched");
  });

  it("asks a manager about a title with no match, and does not ask TMDB again each scan", async () => {
    tmdb.search("movie", []);
    const [id] = addFile("Grandpa Sings (2011).mkv");
    const first = enricher();
    expect(await first.run()).toMatchObject({ needsReview: 1 });
    expect(review(id).candidates).toEqual([]);
    const asked = tmdb.received.length;
    await first.run();
    expect(tmdb.received).toHaveLength(asked);
    clock.now += 15 * DAY;
    await first.run();
    expect(tmdb.received.length).toBeGreaterThan(asked);
  });

  it("needs the running time to agree when the year is one off or missing", async () => {
    tmdb.search("movie", [
      offerMovie(1, "Near Miss", "2001-01-03"),
      offerMovie(2, "Yearless", "1999-01-01"),
    ]);
    const [near] = addFile("Near Miss (2000).mkv", "movies", 92);
    const [yearless] = addFile("Yearless.mkv", "movies", 89);
    const [other] = addFile("Near Miss (2002).mkv", "movies", 70);
    await enricher().run();
    expect(row(near)).toMatchObject({ match_status: "matched", tmdb_id: 1, year: 2001 });
    expect(row(yearless)).toMatchObject({ match_status: "matched", tmdb_id: 2 });
    expect(row(other).match_status).toBe("needs_review");
  });

  it("does not accept a film whose running time is nothing like the file's", async () => {
    tmdb.search("movie", [offerMovie(1, "Short", "2001-01-03")]);
    const [id] = addFile("Short (2001).mkv", "movies", 6);
    await enricher().run();
    expect(row(id).match_status).toBe("needs_review");
  });

  it("counts a film split over discs as one", async () => {
    tmdb.search("movie", [offerMovie(1, "Epic", "2001-01-03", { runtime: 200 })]);
    const [id] = addFile("Epic (2001)/Epic cd1.mkv", "movies", 99);
    addFile("Epic (2001)/Epic cd2.mkv", "movies", 99);
    await enricher().run();
    expect(row(id).match_status).toBe("matched");
  });

  it("knows a film by an alias", async () => {
    const hit = offerMovie(1, "Spirited Away", "2001-07-20", {
      alternative_titles: {
        titles: [{ iso_3166_1: "NL", title: "De reis van Chihiro", type: "" }],
      },
    });
    tmdb.search("movie", [{ ...hit, aka: ["De reis van Chihiro"] }]);
    const [id] = addFile("De reis van Chihiro (2001).mkv");
    await enricher().run();
    expect(row(id)).toMatchObject({ title: "Spirited Away", match_status: "matched" });
    expect(row(id).ident_key).toBe("movie:de reis van chihiro:2001");
  });

  it("trusts an id in the file name over the title", async () => {
    offerMovie(354912, "Coco", "2017-10-27");
    const [byTmdb] = addFile("Kokos (2017) [tmdbid-354912].mkv");
    offerMovie(5, "Found", "2010-01-01");
    tmdb.answers.set("/3/find/tt1234567", {
      body: {
        movie_results: [{ id: 5, media_type: "movie", title: "Found" }],
        person_results: [],
        tv_results: [],
        tv_episode_results: [],
        tv_season_results: [],
      },
    });
    const [byImdb] = addFile("Whatever (2010) tt1234567.mkv");
    await enricher().run();
    expect(row(byTmdb)).toMatchObject({ tmdb_id: 354912, title: "Coco", match_status: "matched" });
    expect(row(byImdb)).toMatchObject({ tmdb_id: 5, match_status: "matched" });
    expect(tmdb.requests("/3/search/movie")).toHaveLength(0);
  });

  it("reviews ids that contradict each other", async () => {
    offerMovie(7, "One", "2010-01-01");
    offerMovie(8, "Two", "2010-01-01");
    tmdb.answers.set("/3/find/tt1234567", { body: { movie_results: [{ id: 8 }], tv_results: [] } });
    const [id] = addFile("One (2010) [tmdbid-7] tt1234567.mkv");
    await enricher().run();
    expect(review(id).candidates.map((one) => one.id)).toEqual([7, 8]);
  });

  it("falls back to the original language for a poster and summary", async () => {
    const hit = offerMovie(1, "Ponyo", "2008-07-19", {
      original_language: "ja",
      overview: "",
      images: { posters: [{ file_path: "/any.jpg", iso_639_1: null }], backdrops: [] },
      translations: {
        translations: [
          { iso_3166_1: "JP", iso_639_1: "ja", name: "", data: { title: "", overview: "Umi." } },
        ],
      },
    });
    tmdb.answers.set("/3/movie/1/images", {
      body: { posters: [{ file_path: "/japanese.jpg", iso_639_1: "ja" }], backdrops: [] },
    });
    tmdb.search("movie", [hit]);
    const [id] = addFile("Ponyo (2008).mkv");
    await enricher({ language: "nl-NL" }).run();
    expect(api(id).overview).toBe("Umi.");
    expect(db.get("select remote_path, language from artwork where kind = 'poster'")).toEqual({
      remote_path: "/japanese.jpg",
      language: "ja",
    });
    expect(tmdb.requests("/3/movie/1")[0]?.query.get("language")).toBe("nl-NL");
  });
});

describe("shows", () => {
  it("fills in a show, its seasons and its episodes", async () => {
    tmdb.search("tv", [
      offerShow(82728, "Bluey", "2018-10-01", { 2: ["Dance Mode", "Hammerbarn", "Featherwand"] }),
    ]);
    const [second] = addFile("Bluey/Season 02/S02E02.mkv", "series", 7);
    const [third] = addFile("Bluey/Season 02/Bluey - S02E03 - Featherwand.mkv", "series", 7);
    const keys = db.all("select id, ident_key from item order by id");
    expect(await enricher().run()).toMatchObject({ matched: 4, needsReview: 0 });

    const season = api(api(second).parentId ?? "");
    const show = api(season.parentId ?? "");
    expect(show).toMatchObject({
      year: 2018,
      matchStatus: "matched",
      tmdb: { type: "tv", id: 82728 },
    });
    expect(show.artwork.poster).not.toBeNull();
    expect(season).toMatchObject({ title: "Season 2", overview: "Season 2 in short." });
    expect(season.artwork.poster).not.toBeNull();
    expect(api(second)).toMatchObject({
      title: "Hammerbarn",
      seasonNumber: 2,
      episodeNumber: 2,
      overview: "In Hammerbarn.",
      airDate: "2020-03-18",
      imdbId: "tt9000202",
      tmdb: null,
    });
    expect(api(second).artwork.still).not.toBeNull();
    expect(row(third).tmdb_id).toBe(82728 * 10_000 + 203);
    expect(db.all("select id, ident_key from item order by id")).toEqual(keys);
    // Once to recognise the show and once to fill it in, however many episodes.
    expect(tmdb.requests("/3/tv/82728/season/2")).toHaveLength(2);
  });

  it("gives both halves of a combined episode their own title", async () => {
    tmdb.search("tv", [offerShow(1, "Example", "2015-01-01", { 1: ["First", "Second"] })]);
    const ids = addFile("Example/Season 1/Example S01E01E02 First and Second.mkv", "series", 14);
    await enricher().run();
    expect(ids.map((id) => row(id).title)).toEqual(["First", "Second"]);
  });

  it("tells two shows of one name apart by their episodes", async () => {
    tmdb.search("tv", [
      offerShow(1, "Bluey", "1976-01-01", { 1: ["A Case", "Another Case"] }),
      offerShow(2, "Bluey", "2018-10-01", { 1: ["Magic Xylophone", "Hospital"] }),
    ]);
    const [id] = addFile("Bluey/Season 1/Bluey S01E01 Magic Xylophone.mkv", "series", 7);
    addFile("Bluey/Season 1/Bluey S01E02 Hospital.mkv", "series", 7);
    await enricher().run();
    expect(row(id)).toMatchObject({ match_status: "matched", tmdb_id: 20_101 });
  });

  it("does not choose between two shows of one name without evidence", async () => {
    tmdb.search("tv", [
      offerShow(1, "Bluey", "1976-01-01", { 1: ["A Case"] }),
      offerShow(2, "Bluey", "2018-10-01", { 1: ["Magic Xylophone"] }),
    ]);
    addFile("Bluey/Season 1/S01E01.mkv", "series", 7);
    await enricher().run();
    const show = db.get<Row>("select * from item where kind = 'show'");
    expect(show?.match_status).toBe("needs_review");
    expect(review(show?.id).candidates).toHaveLength(2);
    // Nothing below it is guessed.
    expect(db.get<Row>("select * from item where kind = 'episode'")?.match_status).toBe(
      "unmatched",
    );
  });

  it("recognises a show by its episode titles when the order is another one", async () => {
    tmdb.search(
      "tv",
      [
        offerShow(1, "Ducks", "1987-01-01", { 1: ["Alpha", "Beta", "Gamma", "Delta"] }),
        offerShow(2, "Ducks", "2017-01-01", { 1: ["Other", "Things"] }),
      ],
      5,
    );
    addFile("Ducks/Season 1/Ducks S01E01 Delta.mkv", "series", 7);
    addFile("Ducks/Season 1/Ducks S01E02 Gamma.mkv", "series", 7);
    await enricher().run();
    expect(db.get<Row>("select * from item where kind = 'show'")?.tmdb_id).toBe(1);
  });

  it("recognises a show from files without numbers, by their titles", async () => {
    tmdb.search("tv", [
      offerShow(1, "George", "1980-01-01", { 1: ["Nothing Alike"] }),
      offerShow(2, "George", "2006-01-01", { 1: ["Quick", "Skunk Problem"] }),
    ]);
    const [id] = addFile("George/Quick.mkv", "series", 7);
    addFile("George/Skunk Problem.mkv", "series", 7);
    await enricher().run();
    expect(row(id)).toMatchObject({ match_status: "matched", title: "Quick" });
  });

  it("recognises the only show of its name with this many episodes", async () => {
    const six = ["A", "B", "C", "D", "E", "F"];
    tmdb.search("tv", [
      offerShow(1, "Bait", "2021-01-01", { 1: six.slice(0, 4) }),
      offerShow(2, "Bait", "2026-01-01", { 1: six }),
    ]);
    for (let n = 1; n <= 6; n += 1) {
      addFile(`Bait/Season 1/Bait S01E0${n} 1080p x265-GROUP.mkv`, "series", 7);
    }
    await enricher().run();
    expect(db.get<Row>("select * from item where kind = 'show'")?.tmdb_id).toBe(2);
    expect(db.all("select title from item where kind = 'episode' order by episode_number")).toEqual(
      six.map((title) => ({ title })),
    );
  });

  it("does not trust an obscure show on its number of episodes alone", async () => {
    const six = ["A", "B", "C", "D", "E", "F"];
    tmdb.search("tv", [
      offerShow(1, "Bait", "2021-01-01", { 1: six.slice(0, 4) }),
      offerShow(2, "Bait", "2026-01-01", { 1: six }, { vote_count: 0 }),
    ]);
    for (let n = 1; n <= 6; n += 1) addFile(`Bait/Season 1/S01E0${n}.mkv`, "series", 7);
    await enricher().run();
    expect(db.get<Row>("select * from item where kind = 'show'")?.match_status).toBe(
      "needs_review",
    );
  });

  it("asks a manager when an episode's number and title point to different episodes", async () => {
    tmdb.search("tv", [
      offerShow(1, "Firefly", "2002-09-20", { 1: ["The Train Job", "Bushwhacked", "Serenity"] }),
    ]);
    const [id] = addFile("Firefly (2002)/Season 1/Firefly S01E01 Serenity.mkv", "series", 7);
    const [missing] = addFile("Firefly (2002)/Season 1/Firefly S01E09.mkv", "series", 7);
    await enricher().run();
    expect(row(id)).toMatchObject({ match_status: "needs_review", title: "Serenity" });
    expect(review(id).candidates.map((one) => one.title)).toEqual(["The Train Job", "Serenity"]);
    expect(review(missing).reason).toContain("no episode with this number");
  });

  it("finds an episode without a number by its title, and keeps it in place", async () => {
    tmdb.search("tv", [
      offerShow(1, "Example", "2015-01-01", { 1: ["The Long Walk", "Home"], 2: ["Away"] }),
    ]);
    const [id] = addFile("Example/The Long Walk.mkv", "series", 7);
    const [unknown] = addFile("Example/Something Else Entirely.mkv", "series", 7);
    const key = row(id).ident_key;
    await enricher().run();
    expect(row(id)).toMatchObject({ match_status: "matched", tmdb_id: 10_101, ident_key: key });
    expect(api(id)).toMatchObject({ seasonNumber: null, episodeNumber: null });
    expect(row(unknown).match_status).toBe("needs_review");
  });

  it("keeps the file's episode title when TMDB has only a placeholder", async () => {
    tmdb.search("tv", [offerShow(1, "Example", "2015-01-01", { 1: ["Episode 1"] })]);
    const [id] = addFile("Example/Season 1/Example S01E01 A Fine Day.mkv", "series", 7);
    await enricher().run();
    expect(row(id)).toMatchObject({ match_status: "matched", title: "A Fine Day" });
  });

  it("reads new episodes of a show it already knows", async () => {
    tmdb.search("tv", [offerShow(1, "Example", "2015-01-01", { 1: ["One", "Two"] })]);
    addFile("Example/Season 1/S01E01.mkv", "series", 7);
    const one = enricher();
    await one.run();
    const [added] = addFile("Example/Season 1/S01E02.mkv", "series", 7);
    expect(await one.run()).toMatchObject({ matched: 1 });
    expect(row(added).title).toBe("Two");
    expect(tmdb.requests("/3/search/tv")).toHaveLength(1);
  });

  it("finds the show from an episode's IMDb id", async () => {
    offerShow(1, "Example", "2015-01-01", { 1: ["One"] });
    tmdb.answers.set("/3/find/tt7654321", {
      body: { movie_results: [], tv_results: [], tv_episode_results: [{ id: 10_101, show_id: 1 }] },
    });
    const [id] = addFile("Exmpl/Season 1/S01E01 tt7654321.mkv", "series", 7);
    await enricher().run();
    expect(row(id)).toMatchObject({ match_status: "matched", title: "One" });
  });
});

describe("what people chose", () => {
  it("fills in a locked match by its id, and leaves locked items without one alone", async () => {
    offerMovie(1, "Official Title", "2001-01-01");
    tmdb.search("movie", []);
    const [locked] = addFile("Ours (2000).mkv");
    const [bare] = addFile("Bare (2000).mkv");
    db.run(
      "update item set match_status = 'locked', tmdb_type = 'movie', tmdb_id = 1 where id = ?",
      [locked ?? ""],
    );
    db.run("update item set match_status = 'locked' where id = ?", [bare ?? ""]);
    const before = row(bare);
    await enricher().run();
    expect(row(locked)).toMatchObject({
      match_status: "locked",
      title: "Official Title",
      overview: "About Official Title.",
      ident_key: "movie:ours:2000",
      tmdb_id: 1,
    });
    expect(row(bare)).toEqual(before);
    expect(tmdb.requests("/3/search/movie")).toHaveLength(0);
  });

  it("keeps edits and chosen artwork through a refresh, and refreshes what is under them", async () => {
    tmdb.search("movie", [offerMovie(1, "Film", "2001-01-01")]);
    const [id = ""] = addFile("Film (2001).mkv");
    const one = enricher();
    await one.run();
    db.run('update item set override_json = \'{"title":"Mine"}\' where id = ?', [id]);
    db.run("update artwork set locked = 1 where item_id = ? and kind = 'poster'", [id]);
    const chosen = api(id).artwork;
    tmdb.answers.set("/3/movie/1", {
      body: movieAnswer(1, "New Title", "2001-01-01", {
        overview: "Better words.",
        images: {
          posters: [{ file_path: "/new.jpg", iso_639_1: "en" }],
          backdrops: [{ file_path: "/newback.jpg", iso_639_1: null }],
        },
      }),
    });
    clock.now += 91 * DAY;
    await one.run();
    const after = api(id);
    expect(after).toMatchObject({ title: "Mine", overview: "Better words." });
    expect(row(id).title).toBe("New Title");
    expect(after.artwork.poster).toEqual(chosen.poster);
    // A new picture is a new id.
    expect(after.artwork.backdrop?.id).not.toBe(chosen.backdrop?.id);
    expect(tmdb.requests("/3/search/movie")).toHaveLength(1);
  });

  it("keeps who made a film and a show, and reads it for what was settled before", async () => {
    const companies = {
      production_companies: [
        {
          id: 7,
          name: "Glow Animation Studios",
          logo_path: "/glowlogo07.png",
          origin_country: "US",
        },
        { id: 8, name: "Small House", logo_path: null, origin_country: "" },
        {
          id: 7,
          name: "Glow Animation Studios",
          logo_path: "/glowlogo07.png",
          origin_country: "US",
        },
        { name: "No id" },
      ],
    };
    tmdb.search("movie", [offerMovie(1, "Film", "2001-01-01", companies)]);
    tmdb.search("tv", [
      offerShow(
        2,
        "Show",
        "2010-01-01",
        { 1: ["One"] },
        {
          production_companies: [{ id: 7, name: "Glow Animation Studios", logo_path: "/../x.png" }],
          networks: [{ id: 7, name: "Glow Channel", logo_path: null, origin_country: "GB" }],
        },
      ),
    ]);
    const [film] = addFile("Film (2001).mkv");
    addFile("Show/Season 1/Show S01E01.mkv", "series", 20);
    const one = enricher();
    await one.run();
    const show = db.get<{ id: string }>("select id from item where kind = 'show'")?.id ?? "";
    const studios = new Studios(db);
    expect(studios.of(film ?? "")).toEqual(["company:7", "company:8"]);
    expect(studios.of(show)).toEqual(["company:7", "network:7"]);
    expect(db.all("select id, name, logo_path from studio order by id")).toEqual([
      { id: "company:7", name: "Glow Animation Studios", logo_path: "/glowlogo07.png" },
      { id: "company:8", name: "Small House", logo_path: null },
      { id: "network:7", name: "Glow Channel", logo_path: null },
    ]);

    // A catalogue from before: settled, its facts fresh, and no studios yet.
    db.run("delete from item_studio");
    db.run("update item set studios_at = null");
    const asked = tmdb.requests("/3/movie/1").length;
    clock.now += DAY;
    await one.run();
    expect(tmdb.requests("/3/movie/1")).toHaveLength(asked + 1);
    expect(studios.of(film ?? "")).toEqual(["company:7", "company:8"]);
    expect(studios.of(show)).toEqual(["company:7", "network:7"]);
    clock.now += DAY;
    await one.run();
    expect(tmdb.requests("/3/movie/1")).toHaveLength(asked + 1);
  });

  it("keeps a title's people, other names and collection for search, also for one matched before", async () => {
    tmdb.search("movie", [
      offerMovie(1, "Film", "2001-01-01", {
        alternative_titles: { titles: [{ title: "Le Film" }] },
        belongs_to_collection: { id: 10, name: "Film Collection" },
        credits: {
          cast: [
            { id: 31, name: "Tom Hanks", character: "Woody", order: 0, profile_path: "/tom.jpg" },
            { id: 32, name: "Second Lead", character: "Buzz", order: 1 },
          ],
          crew: [
            { id: 40, name: "A Director", job: "Director" },
            { id: 41, name: "A Writer", job: "Screenplay" },
            { id: 42, name: "A Grip", job: "Grip" },
          ],
        },
      }),
    ]);
    const [film] = addFile("Film (2001).mkv");
    const one = enricher();
    await one.run();
    expect(tmdb.requests("/3/movie/1")[0]?.query.get("append_to_response")).toContain("credits");
    const credits = (): unknown[] =>
      db.all(
        "select person_id, role, character, position from item_credit where item_id = ? order by role, position",
        [film ?? ""],
      );
    expect(credits()).toEqual([
      { person_id: 31, role: "cast", character: "Woody", position: 0 },
      { person_id: 32, role: "cast", character: "Buzz", position: 1 },
      { person_id: 40, role: "director", character: null, position: 0 },
      { person_id: 41, role: "writer", character: null, position: 0 },
    ]);
    expect(db.get("select name, profile_path from person where id = 31")).toEqual({
      name: "Tom Hanks",
      profile_path: "/tom.jpg",
    });
    expect(db.all("select title from item_alias where item_id = ?", [film ?? ""])).toEqual([
      { title: "Le Film" },
    ]);
    expect(db.get("select collection_name from item where id = ?", [film ?? ""])).toEqual({
      collection_name: "Film Collection",
    });
    // Search has its own index of them: the apps' sync does not change for it.
    expect(db.get("select count(*) as n from search_dirty")).toEqual({ n: 1 });

    // A catalogue from before: settled, and no people yet. The next refresh reads them.
    db.run("delete from item_credit");
    db.run("update item set credits_at = null");
    const revision = db.currentRevision();
    clock.now += DAY;
    await one.run();
    expect(credits()).toHaveLength(4);
    expect(db.currentRevision()).toBe(revision);
  });

  it("changes no revision when a refresh finds nothing new", async () => {
    tmdb.search("movie", [offerMovie(1, "Film", "2001-01-01")]);
    addFile("Film (2001).mkv");
    const one = enricher();
    await one.run();
    const revision = db.currentRevision();
    clock.now += 91 * DAY;
    expect(await one.run()).toMatchObject({ matched: 1 });
    expect(db.currentRevision()).toBe(revision);
    expect(tmdb.requests("/t/p/w780/poster1.jpg")).toHaveLength(1);
  });

  it("takes the place of a frame from the file", async () => {
    tmdb.search("movie", [offerMovie(1, "Film", "2001-01-01")]);
    const [id = ""] = addFile("Film (2001).mkv");
    db.run(
      "insert into artwork (id, item_id, kind, provider, remote_path, selected) values ('f', ?, 'backdrop', 'frame', 'x', 1)",
      [id],
    );
    await enricher().run();
    expect(db.get("select selected from artwork where id = 'f'")).toEqual({ selected: 0 });
    expect(api(id).artwork.backdrop?.id).not.toBe("f");
  });

  it("does not overwrite what a manager locked during the lookup", async () => {
    tmdb.search("movie", [offerMovie(1, "Film", "2001-01-01")]);
    const [id = ""] = addFile("Film (2001).mkv");
    tmdb.beforeAnswer = (request) => {
      if (request.path === "/3/movie/1") {
        db.run("update item set match_status = 'locked', title = 'Ours' where id = ?", [id]);
      }
      return Promise.resolve();
    };
    await enricher().run();
    expect(row(id)).toMatchObject({ match_status: "locked", title: "Ours", tmdb_id: null });
    expect(readdirSync(join(dir, "artwork"))).toEqual([]);
  });
});

describe("talking to TMDB", () => {
  beforeEach(() => {
    tmdb.search("movie", [offerMovie(1, "Film", "2001-01-01")]);
  });

  it("sends a v3 key in the query and a v4 token as a bearer credential", async () => {
    addFile("Film (2001).mkv");
    await enricher({ key: V3_KEY }).run();
    const search = tmdb.requests("/3/search/movie")[0];
    expect(search?.query.get("api_key")).toBe(V3_KEY);
    expect(search?.headers.authorization).toBeUndefined();
    db.run("update item set match_status = 'unmatched', enriched_at = null, tmdb_id = null");
    tmdb.received.length = 0;
    await enricher({ key: ` ${V4_TOKEN}\n` }).run();
    const again = tmdb.requests("/3/search/movie")[0];
    expect(again?.headers.authorization).toBe(`Bearer ${V4_TOKEN}`);
    expect(again?.query.get("api_key")).toBeNull();
    // Pictures come from another host, which has no business with the key.
    for (const request of tmdb.received.filter((one) => one.path.startsWith("/t/p/"))) {
      expect(request.query.get("api_key")).toBeNull();
      expect(request.headers.authorization).toBeUndefined();
    }
  });

  it("sends titles, never paths, file names or personal videos", async () => {
    addFile("Secret Folder/Film (2001) 1080p BluRay x264-GROUP.mkv");
    addFile("Holiday in Gozo.mp4", "personal");
    await enricher().run();
    const sent = tmdb.received.map((one) => `${one.path}?${one.query.toString()}`).join("\n");
    expect(tmdb.requests("/3/search/movie")[0]?.query.get("query")).toBe("Film");
    for (const private_ of ["Secret", "GROUP", "BluRay", "mkv", "Gozo"]) {
      expect(sent).not.toContain(private_);
    }
  });

  it("never logs the key, whatever goes wrong", async () => {
    addFile("Film (2001).mkv");
    for (const key of [V3_KEY, V4_TOKEN, "broken\nkey-with-newline"]) {
      for (const status of [401, 403, 404, 429, 500]) {
        db.run(
          "update item set match_status = 'unmatched', candidates_json = null, enrich_next_attempt_at = null",
        );
        tmdb.intercept = () => ({ status, body: { status_message: "no" } });
        const one = enricher({ key, limits: { retries: 0 } });
        await one.run();
        expect(JSON.stringify(one)).not.toContain(key);
      }
    }
    tmdb.intercept = () => ({ status: 302, headers: { location: "https://example.invalid/" } });
    db.run(
      "update item set match_status = 'unmatched', candidates_json = null, enrich_next_attempt_at = null",
    );
    await enricher({ limits: { retries: 0 } }).run();
    expect(logged.length).toBeGreaterThan(5);
    const all = logged.join("\n");
    for (const key of [V3_KEY, V4_TOKEN, "key-with-newline"]) expect(all).not.toContain(key);
    expect(all).not.toContain("Film");
  });

  it("does nothing without a key", async () => {
    addFile("Film (2001).mkv");
    expect(await enricher({ key: null }).run()).toMatchObject({ matched: 0 });
    expect(tmdb.received).toHaveLength(0);
  });

  it("stops asking when the key is refused", async () => {
    for (let n = 0; n < 10; n += 1) addFile(`Film ${n} (2001).mkv`);
    tmdb.intercept = () => ({
      status: 401,
      body: { status_code: 7, status_message: "Invalid API key: You must be granted a valid key." },
    });
    const one = enricher({ limits: { maxConcurrent: 1 } });
    expect(await one.run()).toMatchObject({ interrupted: true });
    expect(tmdb.received).toHaveLength(1);
    await one.run();
    expect(tmdb.received).toHaveLength(1);
  });

  it("waits as long as Retry-After asks, and tries 5xx again", async () => {
    const [id] = addFile("Film (2001).mkv");
    let calls = 0;
    let firstAt = 0;
    let secondAt = 0;
    tmdb.intercept = () => {
      calls += 1;
      if (calls === 1) {
        firstAt = Date.now();
        return { status: 429, headers: { "retry-after": "1" }, body: { status_code: 25 } };
      }
      if (calls === 2) {
        secondAt = Date.now();
        return { status: 503 };
      }
      return null;
    };
    await enricher().run();
    expect(secondAt - firstAt).toBeGreaterThanOrEqual(950);
    expect(row(id).match_status).toBe("matched");
  });

  it("keeps the number of requests at once bounded", async () => {
    const hits = Array.from({ length: 25 }, (_, n) =>
      offerMovie(n + 10, `Title ${n}x`, "2001-01-01"),
    );
    tmdb.search("movie", hits);
    for (let n = 0; n < 25; n += 1) addFile(`Title ${n}x (2001).mkv`);
    tmdb.beforeAnswer = () => new Promise((resolve) => setTimeout(resolve, 5));
    const before = db.currentRevision();
    expect(await enricher({ limits: { maxConcurrent: 3 } }).run()).toMatchObject({ matched: 25 });
    expect(tmdb.mostAtOnce).toBeLessThanOrEqual(3);
    // 25 films, in batches of 20: two revisions, not 25.
    expect(db.currentRevision() - before).toBe(2);
  });

  it("uses the original when a size does not exist, and survives a picture that is no picture", async () => {
    const [id] = addFile("Film (2001).mkv");
    tmdb.intercept = (request) =>
      request.path === "/t/p/w780/poster1.jpg"
        ? { status: 404 }
        : request.path.endsWith("/backdrop1.jpg")
          ? { body: Buffer.from("<html>not a picture</html>") }
          : null;
    await enricher().run();
    expect(api(id)).toMatchObject({ matchStatus: "matched", artwork: { backdrop: null } });
    expect(tmdb.requests("/t/p/original/poster1.jpg")).toHaveLength(1);
    expect(api(id).artwork.poster).not.toBeNull();
  });

  it("gets lost pictures back under the same id and removes unused files", async () => {
    const [id] = addFile("Film (2001).mkv");
    await enricher().run();
    const art = db.get<{ id: string; local_path: string }>(
      "select id, local_path from artwork where kind = 'poster'",
    );
    rmSync(art?.local_path ?? "");
    execFileSync("touch", [
      join(dir, "artwork", "tmdb-orphan.jpg"),
      join(dir, "artwork", "other.jpg"),
    ]);
    await enricher().run();
    expect(existsSync(art?.local_path ?? "")).toBe(true);
    expect(api(id).artwork.poster?.id).toBe(art?.id);
    expect(existsSync(join(dir, "artwork", "tmdb-orphan.jpg"))).toBe(false);
    // Not ours.
    expect(existsSync(join(dir, "artwork", "other.jpg"))).toBe(true);
  });

  it("stops in the middle without touching the database again", async () => {
    addFile("Film (2001).mkv");
    const one = enricher();
    let entered: () => void = () => undefined;
    const waiting = new Promise<void>((resolve) => (entered = resolve));
    tmdb.beforeAnswer = () => {
      entered();
      return new Promise((resolve) => setTimeout(resolve, 200));
    };
    const running = one.run();
    await waiting;
    const stopped = one.stop();
    const before = db.all("select * from item");
    // As the server does: the database may close right after.
    await stopped;
    await running;
    expect(db.all("select * from item")).toEqual(before);
    expect(await one.run()).toMatchObject({ matched: 0 });
  });
});

describe("a TMDB outage", () => {
  it("leaves scanning, the catalogue and streaming working, and catches up later", async () => {
    const movies = join(dir, "Library");
    mkdirSync(movies);
    makeVideo(join(movies, "Film (2001).mp4"));
    const scanner = new Scanner(db, catalogue, {
      stabilityMs: 0,
      probeConcurrency: 1,
      ffprobePath: "ffprobe",
      now: () => clock.now,
    });
    scanner.syncSources([{ path: movies, name: "Library", hint: "movies" }]);
    await scanner.scanAll();
    await scanner.processQueue();

    // Accepts connections and never answers: the slowest kind of outage.
    let release: () => void = () => undefined;
    const held = new Promise<void>((resolve) => (release = resolve));
    tmdb.beforeAnswer = () => held;
    const one = enricher({ limits: { timeoutMs: 1_500, retries: 1 } });
    const running = one.run();

    makeVideo(join(movies, "Second (2002).mp4"), { seed: 3 });
    await scanner.scanAll();
    await scanner.processQueue();
    const devices = new Devices(db, "secret", () => clock.now);
    const app = createApp({
      db,
      devices,
      items: new ItemReader(db),
      progress: new ProgressStore(db, () => clock.now),
      serverName: "Test",
      version: "0",
      isScanning: () => false,
      now: () => clock.now,
    });
    const claimed = await app.request("/v1/pairing/claim", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ setupSecret: "secret", deviceName: "Mac", platform: "macos" }),
    });
    const { token } = (await claimed.json()) as { token: string };
    const headers = { Authorization: `Bearer ${token}` };
    const library = (await (await app.request("/v1/library", { headers })).json()) as {
      items: ApiItem[];
    };
    expect(library.items.map((item) => item.title).sort()).toEqual(["Film", "Second"]);
    const asset = library.items[0]?.files[0]?.assetId ?? "";
    const stream = await app.request(`/v1/assets/${asset}/content`, {
      headers: { ...headers, Range: "bytes=0-99" },
    });
    expect(stream.status).toBe(206);
    expect((await stream.arrayBuffer()).byteLength).toBe(100);

    expect(await running).toMatchObject({ matched: 0, failed: 1 });
    release();
    tmdb.beforeAnswer = null;
    tmdb.search("movie", [
      offerMovie(1, "Film", "2001-01-01", { runtime: 0 }),
      offerMovie(2, "Second", "2002-01-01", { runtime: 0 }),
    ]);
    clock.now += 120_000;
    expect(await one.run()).toMatchObject({ matched: 2 });
  });

  it("ends the run after a few failures in a row instead of trying everything", async () => {
    for (let n = 0; n < 30; n += 1) addFile(`Film ${n} (2001).mkv`);
    const one = enricher({ limits: { maxConcurrent: 1, retries: 0 } });
    await tmdb.stop();
    expect(await one.run()).toMatchObject({ interrupted: true, failed: 3 });
    expect(db.get("select count(*) as n from item where match_status != 'unmatched'")).toEqual({
      n: 0,
    });
    tmdb = await LocalTmdb.start(jpeg);
  });
});
