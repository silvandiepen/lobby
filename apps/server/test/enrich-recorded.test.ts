// SPDX-License-Identifier: MPL-2.0
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, beforeEach, expect, it } from "vitest";
import { Database } from "../src/db/database.ts";
import { Enricher } from "../src/enrich/index.ts";
import { Catalogue } from "../src/library/catalogue.ts";
import { ItemReader, type ApiItem } from "../src/library/items.ts";
import { parseMediaPath, type SourceHint } from "../src/library/parse.ts";
import { makeTempDir, removeDir } from "./support/media.ts";
import { LocalTmdb } from "./support/tmdb.ts";

/** Runs the matcher against answers recorded from the real TMDB API. */
const recorded = JSON.parse(
  readFileSync(join(import.meta.dirname, "fixtures", "tmdb-recorded.json"), "utf8"),
) as { answers: Record<string, unknown> };

let dir: string;
let db: Database;
let catalogue: Catalogue;
let tmdb: LocalTmdb;
let enricher: Enricher;

beforeEach(async () => {
  dir = makeTempDir();
  db = new Database(join(dir, "lobby.db"));
  catalogue = new Catalogue(db);
  for (const hint of ["movies", "series"]) {
    db.run("insert into source (id, path, name, hint, created_at) values (?, ?, ?, ?, 0)", [
      hint,
      `/${hint}`,
      hint,
      hint,
    ]);
  }
  const jpeg = execFileSync("ffmpeg", [
    ..."-v error -f lavfi -i testsrc2=size=80x120 -frames:v 1 -f image2 -c:v mjpeg -".split(" "),
  ]);
  tmdb = await LocalTmdb.start(jpeg);
  tmdb.intercept = ({ path, query }) => {
    const asked = ["query", "page", "primary_release_year", "first_air_date_year"]
      .filter((name) => query.has(name))
      .map((name) => `${name}=${query.get(name) ?? ""}`)
      .join("&");
    const body = recorded.answers[asked === "" ? path : `${path}?${asked}`];
    return body === undefined ? null : { body };
  };
  enricher = new Enricher({
    db,
    catalogue,
    key: "0123456789abcdef0123456789abcdef",
    language: "en-US",
    artworkDir: join(dir, "artwork"),
    baseUrl: `${tmdb.origin}/3`,
    imageBaseUrl: `${tmdb.origin}/t/p`,
    limits: { minIntervalMs: 0 },
  });
});

afterEach(async () => {
  await enricher.stop();
  await tmdb.stop();
  db.close();
  removeDir(dir);
});

function addFile(relPath: string, hint: SourceHint, minutes: number): string[] {
  const id = randomUUID();
  const parsed = parseMediaPath(relPath, hint);
  db.run(
    `insert into asset (id, source_id, rel_path, size, mtime_ms, revision, state, duration_ms, parsed_json,
       first_seen_at, updated_at) values (?, ?, ?, 1, 1, '1', 'probed', ?, ?, 0, 0)`,
    [id, hint, relPath, minutes * 60_000, JSON.stringify(parsed)],
  );
  return catalogue.linkAsset(id, parsed, hint);
}

function read(id: string | undefined): ApiItem {
  const [item] = new ItemReader(db).read([id ?? ""]);
  if (!item) throw new Error("no such item");
  return item;
}

it("matches a film with a year, and both of a remake pair", async () => {
  const [first] = addFile("The Jungle Book (1967).mkv", "movies", 78);
  const [remake] = addFile("The Jungle Book (2016).mkv", "movies", 106);
  expect(await enricher.run()).toMatchObject({ matched: 2, needsReview: 0 });
  expect(read(first)).toMatchObject({
    matchStatus: "matched",
    year: 1967,
    airDate: "1967-10-18",
    imdbId: "tt0061852",
    tmdb: { type: "movie", id: 9325 },
    genres: ["Adventure", "Animation", "Family"],
  });
  expect(read(remake)).toMatchObject({ year: 2016, imdbId: "tt3040964" });
  expect(read(remake).trailer).toMatchObject({ provider: "youtube" });
  expect(read(first).artwork.poster).not.toBeNull();
  expect(read(first).artwork.backdrop).not.toBeNull();
});

it("leaves a much-used title without a year to a manager", async () => {
  const [id] = addFile("Aladdin.mkv", "movies", 90);
  await enricher.run();
  expect(read(id)).toMatchObject({ matchStatus: "needs_review", tmdb: null });
  const row = db.get<{ candidates_json: string }>("select candidates_json from item");
  const stored = JSON.parse(row?.candidates_json ?? "") as {
    candidates: { title: string; year: number | null }[];
  };
  const years = stored.candidates.map((one) => one.year);
  expect(years).toContain(1992);
  expect(years).toContain(2019);
});

it("matches a show of two by its episodes, and a combined episode", async () => {
  const [one] = addFile("Bluey/Season 01/Bluey S01E01 Magic Xylophone.mkv", "series", 7);
  addFile("Bluey/Season 01/Bluey S01E02 Hospital.mkv", "series", 7);
  const both = addFile("Bluey/Season 01/Bluey S01E03E04.mkv", "series", 14);
  expect(await enricher.run()).toMatchObject({ matched: 6, needsReview: 0 });
  expect(both.map((id) => read(id).title)).toEqual(["Keepy Uppy", "Daddy Robot"]);
  const episode = read(one);
  expect(episode).toMatchObject({ imdbId: "tt8865002", matchStatus: "matched" });
  expect(episode.artwork.still).not.toBeNull();
  const season = read(episode.parentId ?? "");
  expect(season.title).toBe("Season 1");
  expect(read(season.parentId ?? "")).toMatchObject({
    year: 2018,
    tmdb: { type: "tv", id: 82728 },
  });
});

it("asks a manager about a title TMDB does not have", async () => {
  const [id] = addFile("Zxqv Family Puppet Show (2011).mkv", "movies", 10);
  expect(await enricher.run()).toMatchObject({ matched: 0, needsReview: 1 });
  expect(read(id)).toMatchObject({ matchStatus: "needs_review", title: "Zxqv Family Puppet Show" });
});
