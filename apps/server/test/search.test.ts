// SPDX-License-Identifier: MPL-2.0
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { join } from "node:path";
import type { Hono } from "hono";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { Devices } from "../src/auth/devices.ts";
import { Database } from "../src/db/database.ts";
import { LimitedFetch, DEFAULT_LIMITS } from "../src/enrich/http.ts";
import type { Credit } from "../src/enrich/provider.ts";
import { TmdbProvider } from "../src/enrich/tmdb.ts";
import { createApp, type AppEnv } from "../src/http/app.ts";
import { Catalogue } from "../src/library/catalogue.ts";
import { ItemReader } from "../src/library/items.ts";
import { parseMediaPath, type SourceHint } from "../src/library/parse.ts";
import { ProgressStore } from "../src/progress.ts";
import { saveSearchFacts } from "../src/search/credits.ts";
import { editDistance, fold } from "../src/search/normalize.ts";
import { OmdbRatings, readRatings } from "../src/search/omdb.ts";
import { OutsideSearch, type OutsideAnswer } from "../src/search/outside.ts";
import type { SearchAnswer } from "../src/search/service.ts";
import { SearchService } from "../src/search/service.ts";
import { parseQuery } from "../src/search/syntax.ts";
import { makeTempDir, removeDir } from "./support/media.ts";
import { LocalTmdb } from "./support/tmdb.ts";

const NOW = new Date(2027, 5, 15, 12).getTime();
const MINUTE = 60_000;

let dir: string;
let db: Database;
let catalogue: Catalogue;
let devices: Devices;
let items: ItemReader;
let app: Hono<AppEnv>;
let manager: string;
let files: number;
let tmdb: LocalTmdb | null;
let omdbServer: Server | null;

beforeEach(() => {
  dir = makeTempDir();
  db = new Database(join(dir, "lobby.db"));
  catalogue = new Catalogue(db, () => NOW);
  files = 0;
  tmdb = null;
  omdbServer = null;
  for (const hint of ["movies", "series"]) {
    db.run("insert into source (id, path, name, hint, created_at) values (?, ?, ?, ?, 0)", [
      hint,
      `/${hint}`,
      hint,
      hint,
    ]);
  }
  devices = new Devices(db, "secret", () => NOW);
  manager = devices.createLocalManager("Mac").token;
  items = new ItemReader(db);
  app = makeApp(null, null);
});

afterEach(async () => {
  await tmdb?.stop();
  await new Promise<void>((resolve) => {
    if (!omdbServer) resolve();
    else
      omdbServer.close(() => {
        resolve();
      });
  });
  db.close();
  removeDir(dir);
});

function makeApp(provider: TmdbProvider | null, omdb: OmdbRatings | null): Hono<AppEnv> {
  return createApp({
    db,
    devices,
    items,
    progress: new ProgressStore(db, () => NOW),
    ...(omdb ? { omdb } : {}),
    search: {
      service: new SearchService(db, items, omdb),
      outside: new OutsideSearch(
        () => provider,
        omdb,
        () => NOW,
      ),
    },
    serverName: "Test",
    version: "0",
    isScanning: () => false,
    now: () => NOW,
  });
}

function addFile(relPath: string, hint: SourceHint, minutes = 100): string {
  const asset = `asset${String((files += 1))}`;
  db.run(
    `insert into asset (id, source_id, rel_path, size, mtime_ms, revision, state, duration_ms, playability,
       container, first_seen_at, updated_at) values (?, ?, ?, 1, 1, '1', 'probed', ?, 'direct', 'mp4', 0, 0)`,
    [asset, hint, relPath, minutes * MINUTE],
  );
  const parsed = parseMediaPath(relPath, hint);
  db.run("update asset set parsed_json = ? where id = ?", [JSON.stringify(parsed), asset]);
  return catalogue.linkAsset(asset, parsed, hint)[0] ?? "";
}

function film(title: string, year: number, minutes = 100): string {
  return addFile(`${title} (${String(year)}).mkv`, "movies", minutes);
}

function matched(
  itemId: string,
  tmdbId: number,
  average: number,
  imdbId: string | null = null,
): void {
  db.run(
    `update item set match_status = 'matched', tmdb_type = 'movie', tmdb_id = ?, vote_average = ?,
       vote_count = 100, imdb_id = ? where id = ?`,
    [tmdbId, average, imdbId, itemId],
  );
}

function cast(name: string, id: number, character: string | null = null, order = 0): Credit {
  return { personId: id, name, role: "cast", character, order, profilePath: null };
}

function people(
  itemId: string,
  credits: Credit[],
  aliases: string[] = [],
  collection: string | null = null,
): void {
  saveSearchFacts(
    db,
    itemId,
    {
      credits,
      aliases,
      collection: collection === null ? null : { id: collection.length, name: collection },
    },
    NOW,
  );
}

function genre(itemId: string, name: string): void {
  db.run("insert or ignore into genre (name) values (?)", [name]);
  db.run("insert into item_genre (item_id, genre_id) select ?, id from genre where name = ?", [
    itemId,
    name,
  ]);
}

async function get<T>(path: string, token = manager): Promise<{ status: number; body: T }> {
  const response = await app.request(path, { headers: { authorization: `Bearer ${token}` } });
  return { status: response.status, body: (await response.json()) as T };
}

const search = async (q: string, token = manager): Promise<SearchAnswer> => {
  const reply = await get<SearchAnswer>(`/v1/search?q=${encodeURIComponent(q)}`, token);
  expect(reply.status).toBe(200);
  return reply.body;
};

const titles = (answer: SearchAnswer): string[] =>
  [...answer.films.items, ...answer.series.items].map((one) => one.item.title);

/** A family's small library with people, ratings and other names. */
function library(): { toy: string; toy2: string; amelie: string; matrix: string; gump: string } {
  const toy = film("Toy Story", 1995, 81);
  const toy2 = film("Toy Story 2", 1999, 92);
  const amelie = film("Amélie", 2001, 122);
  const matrix = film("The Matrix", 1999, 136);
  const gump = film("Forrest Gump", 1994, 142);
  matched(toy, 862, 8.0, "tt0114709");
  matched(toy2, 863, 7.6, "tt0120363");
  matched(amelie, 194, 7.9, "tt0211915");
  matched(matrix, 603, 8.2, "tt0133093");
  matched(gump, 13, 8.5, "tt0109830");
  people(
    toy,
    [cast("Tom Hanks", 31, "Woody", 0), cast("Tim Allen", 12898, "Buzz Lightyear", 1)],
    [],
    "Toy Story Collection",
  );
  people(
    toy2,
    [cast("Tom Hanks", 31, "Woody", 0), cast("Tim Allen", 12898, "Buzz Lightyear", 1)],
    [],
    "Toy Story Collection",
  );
  people(
    amelie,
    [cast("Audrey Tautou", 3127, "Amélie Poulain", 0)],
    ["Le Fabuleux Destin d'Amélie Poulain"],
  );
  people(matrix, [
    cast("Keanu Reeves", 6384, "Neo", 0),
    {
      personId: 9340,
      name: "Lana Wachowski",
      role: "director",
      character: null,
      order: 0,
      profilePath: null,
    },
  ]);
  people(gump, [
    cast("Tom Hanks", 31, "Forrest Gump", 0),
    cast("Robin Wright", 32, "Jenny Curran", 1),
  ]);
  genre(toy, "Animation");
  genre(toy2, "Animation");
  genre(matrix, "Science Fiction");
  genre(gump, "Drama");
  genre(amelie, "Comedy");
  return { toy, toy2, amelie, matrix, gump };
}

describe("the query language", () => {
  it("reads filters and leaves the rest as words", () => {
    const spec = parseQuery('actor:"Tom Hanks" year:1990..1999 rt>80 toy');
    expect(spec.text).toBe("toy");
    expect(spec.people).toEqual([{ name: "Tom Hanks", id: null, role: "cast" }]);
    expect([spec.yearFrom, spec.yearTo]).toEqual([1990, 1999]);
    expect(spec.ratings).toEqual([{ source: "rottenTomatoes", min: 81, max: null }]);
    expect(spec.understood.map((one) => one.token)).toEqual([
      'actor:"Tom Hanks"',
      "year:1990..1999",
      "rt>80",
    ]);
  });

  it("knows years, decades, exact titles, ratings, lengths and kinds", () => {
    expect(parseQuery("year:1994")).toMatchObject({ yearFrom: 1994, yearTo: 1994 });
    expect(parseQuery("year>=2000")).toMatchObject({ yearFrom: 2000, yearTo: null });
    expect(parseQuery("year:..1980")).toMatchObject({ yearFrom: null, yearTo: 1980 });
    expect(parseQuery("year:90s")).toMatchObject({ yearFrom: 1990, yearTo: 1999 });
    expect(parseQuery("decade:2010s")).toMatchObject({ yearFrom: 2010, yearTo: 2019 });
    expect(parseQuery('title="Toy Story"').titleExact).toBe("Toy Story");
    expect(parseQuery("exact:Up").titleExact).toBe("Up");
    expect(parseQuery("imdb:7.5..9").ratings).toEqual([{ source: "imdb", min: 7.5, max: 9 }]);
    expect(parseQuery("metacritic<=60").ratings).toEqual([
      { source: "metacritic", min: null, max: 60 },
    ]);
    expect(parseQuery("rating>=7").ratings).toEqual([{ source: "tmdb", min: 7, max: null }]);
    expect(parseQuery("runtime<90")).toMatchObject({ runtimeFrom: null, runtimeTo: 89 });
    expect(parseQuery("kind:series is:unwatched")).toMatchObject({
      kinds: ["show"],
      watch: ["unwatched"],
    });
    expect(parseQuery("director:Nolan").people).toEqual([
      { name: "Nolan", id: null, role: "director" },
    ]);
  });

  it("reads what the apps' chips write (LobbyKit SearchFilters)", () => {
    const spec = parseQuery(
      'story kind:film year:1990..1999 rt>=80 actor:"Tom Hanks" director:Nolan genre:"Science Fiction"',
    );
    expect(spec).toMatchObject({
      text: "story",
      kinds: ["movie"],
      yearFrom: 1990,
      yearTo: 1999,
      ratings: [{ source: "rottenTomatoes", min: 80, max: null }],
      people: [
        { name: "Tom Hanks", role: "cast" },
        { name: "Nolan", role: "director" },
      ],
      genres: ["Science Fiction"],
    });
    expect(parseQuery("year>=2000 imdb>=7.5 tmdb>=7")).toMatchObject({
      yearFrom: 2000,
      ratings: [
        { source: "imdb", min: 7.5 },
        { source: "tmdb", min: 7 },
      ],
    });
    expect(parseQuery('title="Toy Story"').titleExact).toBe("Toy Story");
  });

  it("keeps what makes no sense as words", () => {
    expect(parseQuery("rt>500 year:soon colour:red").text).toBe("rt>500 year:soon colour:red");
    expect(parseQuery("rt>500").ratings).toEqual([]);
  });
});

describe("comparing words", () => {
  it("folds accents and punctuation", () => {
    expect(fold("Amélie Poulain")).toBe("amelie poulain");
    expect(fold("WALL·E")).toBe("wall e");
  });

  it("counts letters that differ, a swap as one", () => {
    expect(editDistance("matrix", "matirx", 2)).toBe(1);
    expect(editDistance("hanks", "hnaks", 2)).toBe(1);
    expect(editDistance("story", "stroy", 2)).toBe(1);
    expect(editDistance("toy", "matrix", 2)).toBe(3);
  });
});

describe("the index", () => {
  it("finds titles by their start, without accents, by other names and by parts", async () => {
    library();
    expect(titles(await search("toy"))).toEqual(["Toy Story", "Toy Story 2"]);
    expect(titles(await search("amelie"))).toEqual(["Amélie"]);
    expect(titles(await search("fabuleux destin"))).toEqual(["Amélie"]);
    expect((await search("fabuleux")).films.items[0]?.match).toMatchObject({ field: "alias" });
    expect(titles(await search("atrix"))).toEqual(["The Matrix"]);
  });

  it("finds a title typed wrong", async () => {
    library();
    expect(titles(await search("matirx"))).toEqual(["The Matrix"]);
    expect(titles(await search("forest gmup"))).toEqual(["Forrest Gump"]);
  });

  it("finds titles by their people and whom they played", async () => {
    library();
    const hanks = await search("tom hanks");
    expect(titles(hanks).sort()).toEqual(["Forrest Gump", "Toy Story", "Toy Story 2"]);
    expect(hanks.films.items[0]?.match).toEqual({ field: "person", text: "Tom Hanks" });
    expect(hanks.people.items).toEqual([
      { id: 31, name: "Tom Hanks", picture: null, titles: 3, roles: ["cast"] },
    ]);
    expect((await search("buzz lightyear")).films.items[0]?.match).toEqual({
      field: "character",
      text: "Buzz Lightyear",
    });
    expect((await search("tom hnaks")).people.items.map((one) => one.name)).toEqual(["Tom Hanks"]);
  });

  it("finds collections, and ranks a title that is what was typed first", async () => {
    library();
    const found = await search("toy story");
    expect(found.films.items[0]?.item.title).toBe("Toy Story");
    expect(found.collections.items).toMatchObject([{ name: "Toy Story Collection" }]);
    expect(found.collections.items[0]?.itemIds).toHaveLength(2);
  });

  it("follows the library: new, renamed and removed titles, and new people", async () => {
    const { toy } = library();
    await search("toy");
    const up = film("Up", 2009);
    expect(titles(await search("up"))).toEqual(["Up"]);
    db.run("update item set override_json = ?, revision = ? where id = ?", [
      JSON.stringify({ title: "Toy Tale" }),
      db.nextRevision(),
      toy,
    ]);
    expect(titles(await search("toy tale"))).toEqual(["Toy Tale"]);
    // The old name still finds it: it is one of its names.
    expect(titles(await search("toy story")).sort()).toEqual(["Toy Story 2", "Toy Tale"]);
    people(up, [cast("Ed Asner", 5502, "Carl Fredricksen", 0)]);
    expect(titles(await search("asner"))).toEqual(["Up"]);
    db.run("delete from item where id = ?", [up]);
    db.nextRevision();
    expect(titles(await search("up"))).toEqual([]);
  });

  it("is made in batches, so a whole library never holds the server up", async () => {
    library();
    const index = new SearchService(db, items, null).index;
    const rounds = [index.sync(2), index.sync(2), index.sync(2)];
    expect(rounds).toEqual([false, false, true]);
    expect(index.matchTitles("toy").length).toBe(2);
    await index.syncAll();
    expect(index.sync()).toBe(true);
  });

  it("finds episodes by their title and their show's", async () => {
    addFile("Bluey/Season 1/Bluey - S01E01 - Magic Xylophone.mkv", "series", 7);
    db.run("update item set title = 'Magic Xylophone', revision = ? where kind = 'episode'", [
      db.nextRevision(),
    ]);
    const found = await search("xylophone");
    expect(found.episodes.items.map((one) => one.item.title)).toEqual(["Magic Xylophone"]);
    const show = db.get<{ id: string }>("select id from item where kind = 'show'")?.id;
    expect(found.episodes.items[0]?.showId).toBe(show);
    expect(titles(await search("bluey"))).toEqual(["Bluey"]);
  });
});

describe("filters", () => {
  it("narrows by year, person, rating, runtime, genre and collection", async () => {
    library();
    expect(titles(await search("year:1990..1999")).sort()).toEqual([
      "Forrest Gump",
      "The Matrix",
      "Toy Story",
      "Toy Story 2",
    ]);
    expect(titles(await search('actor:"Tom Hanks" year:1990..1995')).sort()).toEqual([
      "Forrest Gump",
      "Toy Story",
    ]);
    expect(titles(await search("director:wachowski"))).toEqual(["The Matrix"]);
    expect(titles(await search("actor:wachowski"))).toEqual([]);
    // Best rated first when a rating is asked for.
    expect(titles(await search("rating>=8"))).toEqual(["Forrest Gump", "The Matrix", "Toy Story"]);
    expect(titles(await search("runtime<90"))).toEqual(["Toy Story"]);
    expect(titles(await search("genre:animation year:1999"))).toEqual(["Toy Story 2"]);
    expect(titles(await search('collection:"toy story"')).sort()).toEqual([
      "Toy Story",
      "Toy Story 2",
    ]);
    expect(titles(await search('title="toy story"'))).toEqual(["Toy Story"]);
    expect(titles(await search("title:story"))).toEqual(["Toy Story", "Toy Story 2"]);
    const nobody = await search('actor:"Zzyzx Qwerty"');
    expect(nobody.unknownPeople).toEqual(["Zzyzx Qwerty"]);
    expect(titles(nobody)).toEqual([]);
  });

  it("filters by OMDb's ratings only where they are known, and says which sources there are", async () => {
    const { matrix, gump } = library();
    expect((await search("rt>=80")).ratingSources).toEqual(["tmdb"]);
    const omdb = new OmdbRatings(db, { key: "abc123", now: () => NOW });
    app = makeApp(null, omdb);
    db.run(
      `insert into omdb_rating (imdb_id, imdb_rating, imdb_votes, rotten_tomatoes, metacritic, found, fetched_at)
       values ('tt0133093', 8.7, 2000000, 83, 73, 1, ?), ('tt0109830', 8.8, 2200000, 71, 82, 1, ?)`,
      [NOW, NOW],
    );
    const fresh = await search("rt>80");
    expect(fresh.ratingSources).toEqual(["tmdb", "imdb", "rottenTomatoes", "metacritic"]);
    expect(fresh.films.items.map((one) => one.item.id)).toEqual([matrix]);
    expect(fresh.films.items[0]?.ratings).toEqual({
      tmdb: 8.2,
      imdb: 8.7,
      rottenTomatoes: 83,
      metacritic: 73,
    });
    expect((await search("metacritic>=80")).films.items.map((one) => one.item.id)).toEqual([gump]);
    expect(titles(await search("imdb:8.7..8.8 tom"))).toEqual(["Forrest Gump"]);
  });

  it("takes the library's own filters as parameters too", async () => {
    library();
    const reply = await get<SearchAnswer>("/v1/search?q=toy&yearFrom=1998");
    expect(titles(reply.body)).toEqual(["Toy Story 2"]);
    expect((await get("/v1/search?q=is:watched")).status).toBe(400);
    const byId = await get<SearchAnswer>("/v1/search?person=31&role=cast&yearTo=1994");
    expect(titles(byId.body)).toEqual(["Forrest Gump"]);
  });
});

describe("kids and households", () => {
  function kidsDevice(allowed: string[]): string {
    db.run(
      "insert into profile (id, name, color, created_at, kids_json) values ('kid', 'Kid', 'red', 0, ?)",
      [
        JSON.stringify({
          allowedGroupIds: [],
          allowedCategoryIds: [],
          allowedItemIds: allowed,
          blockedItemIds: [],
        }),
      ],
    );
    const made = devices.createOutsideDevice("Tablet", "ios", "viewer");
    db.run("update device set kids_profile_id = 'kid' where id = ?", [made.device.id]);
    db.nextRevision();
    return made.token;
  }

  it("gives a kids device only what its viewer may see, and nothing beyond", async () => {
    const { toy, gump } = library();
    const child = kidsDevice([toy]);
    expect(titles(await search("tom hanks", child))).toEqual(["Toy Story"]);
    expect((await search("tom hanks", child)).people.items[0]?.titles).toBe(1);
    expect(titles(await search("forrest", child))).toEqual([]);
    expect(titles(await search("year:1994", child))).toEqual([]);
    expect((await search("robin wright", child)).people.items).toEqual([]);
    expect((await get("/v1/search/outside?q=toy", child)).status).toBe(404);
    expect((await get("/v1/search/outside/movie/862", child)).status).toBe(404);
    expect((await get("/v1/search/picture?path=/a.jpg", child)).status).toBe(404);
    // A person only through the titles the child may see.
    const hanks = await get<{ titles: { item: { id: string } }[]; outside: unknown }>(
      "/v1/search/people/31",
      child,
    );
    expect(hanks.body.titles.map((one) => one.item.id)).toEqual([toy]);
    expect(hanks.body.outside).toBeNull();
    expect((await get("/v1/search/people/32", child)).status).toBe(404);
    expect(gump).toBeTruthy();
  });

  it("keeps kids mode on a grown-up device within that viewer's limits", async () => {
    const { toy } = library();
    kidsDevice([toy]);
    const reply = await get<SearchAnswer>("/v1/search?q=tom&profile=kid");
    expect(titles(reply.body)).toEqual(["Toy Story"]);
    expect((await get("/v1/search/outside?q=toy&profile=kid")).status).toBe(404);
  });

  it("gives a guest household only its part of the library", async () => {
    const { gump } = library();
    db.run(
      "insert into household (id, name, owner, scope_json, created_at) values ('guest', 'Guests', 0, ?, 0)",
      [
        JSON.stringify({
          allowedGroupIds: [],
          allowedCategoryIds: [],
          allowedItemIds: [gump],
          blockedItemIds: [],
        }),
      ],
    );
    const guest = devices.createOutsideDevice("Phone", "ios", "viewer", "guest").token;
    db.nextRevision();
    expect(titles(await search("tom hanks", guest))).toEqual(["Forrest Gump"]);
    expect(titles(await search("toy", guest))).toEqual([]);
  });
});

/** TMDB's answers for search beyond the library, written by hand from its reference. */
async function outsideTmdb(): Promise<TmdbProvider> {
  tmdb = await LocalTmdb.start(Buffer.from([0xff, 0xd8, 0xff, 0xd9]));
  const hit = (id: number, title: string, date: string, votes = 500): Record<string, unknown> => ({
    id,
    title,
    original_title: title,
    release_date: date,
    overview: `About ${title}.`,
    poster_path: `/p${String(id)}.jpg`,
    vote_average: 7.4,
    vote_count: votes,
    popularity: 50,
  });
  tmdb.answers.set("/3/search/movie", {
    body: {
      results: [
        hit(862, "Toy Story", "1995-11-22"),
        hit(301528, "Toy Story 4", "2019-06-19"),
        hit(9999, "Toy Soldiers", "1991-04-26", 5),
      ],
    },
  });
  tmdb.answers.set("/3/search/tv", { body: { results: [] } });
  tmdb.answers.set("/3/search/person", {
    body: {
      results: [
        {
          id: 31,
          name: "Tom Hanks",
          known_for_department: "Acting",
          profile_path: "/tom.jpg",
          popularity: 60,
          known_for: [{ title: "Forrest Gump" }],
        },
      ],
    },
  });
  tmdb.answers.set("/3/movie/301528", {
    body: {
      ...hit(301528, "Toy Story 4", "2019-06-19"),
      external_ids: { imdb_id: "tt1979376" },
      credits: { cast: [{ id: 31, name: "Tom Hanks", character: "Woody", order: 0 }], crew: [] },
    },
  });
  tmdb.answers.set("/3/movie/9999", {
    body: { ...hit(9999, "Toy Soldiers", "1991-04-26", 5), external_ids: { imdb_id: "tt0103112" } },
  });
  tmdb.answers.set("/3/person/31", {
    body: {
      id: 31,
      name: "Tom Hanks",
      biography: "An actor.",
      known_for_department: "Acting",
      profile_path: "/tom.jpg",
      external_ids: { imdb_id: "nm0000158" },
      combined_credits: {
        cast: [
          { ...hit(13, "Forrest Gump", "1994-06-23"), media_type: "movie", character: "Forrest" },
          { ...hit(301528, "Toy Story 4", "2019-06-19"), media_type: "movie", character: "Woody" },
          { ...hit(862, "Toy Story", "1995-11-22"), media_type: "movie", character: "Woody" },
        ],
        crew: [
          {
            ...hit(9591, "That Thing You Do!", "1996-10-04"),
            media_type: "movie",
            job: "Director",
          },
        ],
      },
    },
  });
  return new TmdbProvider(
    new LimitedFetch(
      { ...DEFAULT_LIMITS, minIntervalMs: 0, retries: 0 },
      new AbortController().signal,
    ),
    {
      key: "0123456789abcdef0123456789abcdef",
      language: "en-US",
      baseUrl: `${tmdb.origin}/3`,
      imageBaseUrl: `${tmdb.origin}/t/p`,
    },
  );
}

describe("beyond the library", () => {
  it("says there is no TMDB key", async () => {
    library();
    const reply = await get<OutsideAnswer>("/v1/search/outside?q=toy");
    expect(reply.body).toMatchObject({ available: false, reason: "no_key", films: [] });
  });

  it("finds films and people at TMDB that are not in the library, with their links, and keeps the answer", async () => {
    library();
    app = makeApp(await outsideTmdb(), null);
    const reply = await get<OutsideAnswer>("/v1/search/outside?q=toy%20year:1990..2020");
    expect(reply.status).toBe(200);
    const { films, people: found } = reply.body;
    // Toy Story is in the library: not out here.
    expect(films.map((one) => one.title)).toEqual(["Toy Story 4", "Toy Soldiers"]);
    expect(films[0]).toMatchObject({
      tmdb: { type: "movie", id: 301528 },
      year: 2019,
      poster: "/p301528.jpg",
      ratings: { tmdb: 7.4, imdb: null, rottenTomatoes: null, metacritic: null },
      imdbId: "tt1979376",
      links: {
        tmdb: "https://www.themoviedb.org/movie/301528",
        imdb: "https://www.imdb.com/title/tt1979376/",
      },
      itemId: null,
    });
    // Few votes say nothing.
    expect(films[1]?.ratings.tmdb).toBeNull();
    expect(found).toMatchObject([
      { id: 31, name: "Tom Hanks", links: { tmdb: "https://www.themoviedb.org/person/31" } },
    ]);
    const asked = tmdb?.received.length ?? 0;
    await get("/v1/search/outside?q=toy%20year:1990..2020");
    expect(tmdb?.received.length).toBe(asked);
    // Only the words go to TMDB.
    expect(tmdb?.requests("/3/search/movie")[0]?.query.get("query")).toBe("toy");
    // Nothing of it became a library item.
    expect(db.get<{ n: number }>("select count(*) as n from item where tmdb_id = 301528")?.n).toBe(
      0,
    );
  });

  it("filters outside by TMDB's rating and says what it could not filter", async () => {
    library();
    app = makeApp(await outsideTmdb(), null);
    const reply = await get<OutsideAnswer>("/v1/search/outside?q=toy%20rating>=7%20rt>90");
    expect(reply.body.films.map((one) => one.title)).toEqual(["Toy Story 4"]);
    expect(reply.body.notApplied).toEqual(["rottenTomatoes"]);
  });

  it("shows a person: their titles here first, then the others", async () => {
    const { toy, toy2, gump } = library();
    app = makeApp(await outsideTmdb(), null);
    const reply = await get<{
      person: { name: string };
      titles: { item: { id: string }; roles: { role: string; character: string | null }[] }[];
      outside: { links: { imdb: string | null }; elsewhere: { title: string; roles: string[] }[] };
    }>("/v1/search/people/31");
    expect(reply.body.person.name).toBe("Tom Hanks");
    expect(reply.body.titles.map((one) => one.item.id).sort()).toEqual([toy, toy2, gump].sort());
    expect(reply.body.titles.find((one) => one.item.id === gump)?.roles).toEqual([
      { role: "cast", character: "Forrest Gump" },
    ]);
    expect(reply.body.outside.links.imdb).toBe("https://www.imdb.com/name/nm0000158/");
    expect(reply.body.outside.elsewhere.map((one) => one.title).sort()).toEqual([
      "That Thing You Do!",
      "Toy Story 4",
    ]);
  });

  it("finds a person's other titles for a person filter without words", async () => {
    library();
    app = makeApp(await outsideTmdb(), null);
    const reply = await get<OutsideAnswer>('/v1/search/outside?q=director:"Tom Hanks"');
    expect(reply.body.films.map((one) => one.title)).toEqual(["That Thing You Do!"]);
  });

  it("limits how often a device asks", async () => {
    library();
    app = makeApp(await outsideTmdb(), null);
    let refused = 0;
    for (let index = 0; index < 45; index += 1) {
      const reply = await app.request(`/v1/search/outside?q=toy${String(index % 3)}`, {
        headers: { authorization: `Bearer ${manager}` },
      });
      if (reply.status === 429) {
        refused += 1;
        expect(reply.headers.get("retry-after")).toBeTruthy();
      }
    }
    expect(refused).toBeGreaterThan(0);
  });

  it("sends pictures through the server", async () => {
    app = makeApp(await outsideTmdb(), null);
    const response = await app.request("/v1/search/picture?path=/p862.jpg", {
      headers: { authorization: `Bearer ${manager}` },
    });
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("image/jpeg");
    expect((await get("/v1/search/picture?path=../etc/passwd")).status).toBe(400);
  });
});

describe("OMDb", () => {
  async function fakeOmdb(): Promise<{ url: string; asked: URLSearchParams[] }> {
    const asked: URLSearchParams[] = [];
    omdbServer = createServer((request, response) => {
      const query = new URL(request.url ?? "/", "http://localhost").searchParams;
      asked.push(query);
      if (query.get("apikey") !== "goodkey1") {
        response.writeHead(401, { "content-type": "application/json" });
        response.end(JSON.stringify({ Response: "False", Error: "Invalid API key!" }));
        return;
      }
      const known: Record<string, unknown> = {
        tt0133093: {
          Response: "True",
          imdbRating: "8.7",
          imdbVotes: "2,100,000",
          Metascore: "73",
          Ratings: [
            { Source: "Internet Movie Database", Value: "8.7/10" },
            { Source: "Rotten Tomatoes", Value: "83%" },
            { Source: "Metacritic", Value: "73/100" },
          ],
        },
      };
      response.writeHead(200, { "content-type": "application/json" });
      response.end(
        JSON.stringify(
          known[query.get("i") ?? ""] ?? { Response: "False", Error: "Incorrect IMDb ID." },
        ),
      );
    });
    const server = omdbServer;
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    return {
      url: `http://127.0.0.1:${String((server.address() as AddressInfo).port)}/`,
      asked,
    };
  }

  it("reads OMDb's answer", () => {
    expect(
      readRatings({
        imdbRating: "N/A",
        Ratings: [
          { Source: "Internet Movie Database", Value: "7.1/10" },
          { Source: "Rotten Tomatoes", Value: "91%" },
        ],
      }),
    ).toEqual({ imdb: 7.1, imdbVotes: null, rottenTomatoes: 91, metacritic: null });
  });

  it("never asks without a key", async () => {
    library();
    const fake = await fakeOmdb();
    const omdb = new OmdbRatings(db, { key: null, baseUrl: fake.url, now: () => NOW });
    expect(await omdb.refresh()).toBe(0);
    expect(await omdb.one("tt0133093")).toBeNull();
    expect(fake.asked).toEqual([]);
  });

  it("keeps each title's ratings, asks again only after a while, and within the day's allowance", async () => {
    library();
    const fake = await fakeOmdb();
    let now = NOW;
    const omdb = new OmdbRatings(db, {
      key: "goodkey1",
      baseUrl: fake.url,
      now: () => now,
      perDay: 7,
      limits: { minIntervalMs: 0 },
    });
    expect(await omdb.refresh()).toBe(5);
    expect(omdb.known(["tt0133093"]).get("tt0133093")).toEqual({
      imdb: 8.7,
      imdbVotes: 2100000,
      rottenTomatoes: 83,
      metacritic: 73,
    });
    // Those OMDb does not know are kept as unknown, and not asked again soon.
    expect(await omdb.refresh()).toBe(0);
    expect(await omdb.one("tt0133093")).toMatchObject({ rottenTomatoes: 83 });
    expect(fake.asked).toHaveLength(5);
    now += 31 * 86_400_000;
    // Two left of the day's seven... it is another day now, so all five again.
    expect(await omdb.refresh()).toBe(5);
    const tight = new OmdbRatings(db, {
      key: "goodkey1",
      baseUrl: fake.url,
      now: () => now + 60 * 86_400_000,
      perDay: 2,
      limits: { minIntervalMs: 0 },
    });
    expect(await tight.refresh()).toBe(2);
    // The key never goes into a log or an answer; it goes to OMDb only.
    expect(fake.asked.every((one) => one.get("apikey") === "goodkey1")).toBe(true);
  });

  it("stops at a refused key", async () => {
    library();
    const fake = await fakeOmdb();
    const omdb = new OmdbRatings(db, {
      key: "wrongkey",
      baseUrl: fake.url,
      now: () => NOW,
      limits: { minIntervalMs: 0, retries: 0 },
    });
    expect(await omdb.refresh()).toBe(0);
    expect(fake.asked).toHaveLength(1);
    expect(await omdb.refresh()).toBe(0);
    expect(fake.asked).toHaveLength(1);
  });

  it("gives an outside title OMDb's ratings with a key", async () => {
    library();
    const fake = await fakeOmdb();
    const omdb = new OmdbRatings(db, {
      key: "goodkey1",
      baseUrl: fake.url,
      now: () => NOW,
      limits: { minIntervalMs: 0 },
    });
    const provider = await outsideTmdb();
    tmdb?.answers.set("/3/movie/301528", {
      body: {
        id: 301528,
        title: "Toy Story 4",
        release_date: "2019-06-19",
        vote_average: 7.5,
        vote_count: 9000,
        external_ids: { imdb_id: "tt0133093" },
      },
    });
    app = makeApp(provider, omdb);
    const reply = await get<{ ratings: Record<string, number | null>; attribution: string[] }>(
      "/v1/search/outside/movie/301528",
    );
    expect(reply.body.ratings).toEqual({
      tmdb: 7.5,
      imdb: 8.7,
      rottenTomatoes: 83,
      metacritic: 73,
    });
    expect(reply.body.attribution).toHaveLength(2);
  });
});
