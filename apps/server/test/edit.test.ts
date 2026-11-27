// SPDX-License-Identifier: MPL-2.0
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, statSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import type { Hono } from "hono";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { ChosenArtwork } from "../src/artwork/chosen.ts";
import { FrameMaker } from "../src/artwork/frames.ts";
import { ArtworkStore } from "../src/artwork/serve.ts";
import { Devices } from "../src/auth/devices.ts";
import { Database } from "../src/db/database.ts";
import { Enricher } from "../src/enrich/index.ts";
import { createApp, type AppEnv } from "../src/http/app.ts";
import { Catalogue } from "../src/library/catalogue.ts";
import { Categories } from "../src/library/categories.ts";
import { ItemReader, type ApiItem } from "../src/library/items.ts";
import { Scanner } from "../src/library/scanner.ts";
import { ProgressStore } from "../src/progress.ts";
import { makeTempDir, makeVideo, removeDir } from "./support/media.ts";
import { LocalTmdb, movieAnswer, seasonAnswer, showAnswer } from "./support/tmdb.ts";

interface Field {
  automatic: unknown;
  overridden: boolean;
  override: unknown;
  effective: unknown;
}
interface Option {
  source: string;
  artworkId: string | null;
  path: string | null;
  previewUrl: string;
  selected: boolean;
  chosen: boolean;
}
interface Edit {
  item: ApiItem;
  revision: number;
  fields: Record<string, Field>;
  artwork: Record<string, Option[]>;
  match: { status: string; chosen: boolean; reason: string | null; candidates: unknown[] };
  error?: { code: string; message: string };
}

const JPEG = execFileSync("ffmpeg", [
  ..."-v error -f lavfi -i testsrc2=size=640x960 -frames:v 1 -f image2 -c:v mjpeg -".split(" "),
]);

/** How many uploads an item keeps here; the server keeps 10. */
const KEPT = 3;

let dir: string;
let movies: string;
let series: string;
let db: Database;
let scanner: Scanner;
let catalogue: Catalogue;
let enricher: Enricher;
let frames: FrameMaker;
let tmdb: LocalTmdb;
let app: Hono<AppEnv>;
let manager: string;
let viewer: string;
let clock: { now: number };

beforeEach(async () => {
  dir = makeTempDir();
  movies = join(dir, "Movies");
  series = join(dir, "Series");
  mkdirSync(movies);
  mkdirSync(series);
  clock = { now: 1_800_000_000_000 };
  const now = (): number => clock.now;
  db = new Database(join(dir, "lobby.db"));
  catalogue = new Catalogue(db, now);
  scanner = newScanner();
  scanner.syncSources([
    { path: movies, name: "Pixar", hint: "movies" },
    { path: series, name: "Kids Series", hint: "series" },
  ]);
  const categories = new Categories(db);
  categories.change(categories.revision, () => {
    categories.createCategory(categories.createGroup({ name: "Adults" }), { name: "Grown-up" });
  });
  tmdb = await LocalTmdb.start(JPEG);
  enricher = new Enricher({
    db,
    catalogue,
    key: "0123456789abcdef0123456789abcdef",
    language: "en-US",
    artworkDir: join(dir, "artwork", "tmdb"),
    baseUrl: `${tmdb.origin}/3`,
    imageBaseUrl: `${tmdb.origin}/t/p`,
    limits: { minIntervalMs: 0, backoffMs: 5, retries: 1, timeoutMs: 2_000 },
    now,
  });
  frames = new FrameMaker(db, catalogue, { dir: join(dir, "artwork"), ffmpegPath: "ffmpeg" });
  app = makeApp(enricher);
  const claimed = await call<{ token: string }>("POST", "/v1/pairing/claim", {
    token: "",
    body: { setupSecret: "secret", deviceName: "Mac", platform: "macos" },
  });
  manager = claimed.body.token;
  const request = await call<{ id: string; code: string; pollSecret: string }>(
    "POST",
    "/v1/pairing/requests",
    { token: "", body: { deviceName: "TV", platform: "tvos" } },
  );
  await call("POST", "/v1/pairing/approve", {
    body: { code: request.body.code, role: "viewer" },
  });
  viewer = (
    await call<{ token: string }>("POST", `/v1/pairing/requests/${request.body.id}/collect`, {
      token: "",
      body: { pollSecret: request.body.pollSecret },
    })
  ).body.token;
});

afterEach(async () => {
  frames.stop();
  await enricher.stop();
  await tmdb.stop();
  db.close();
  removeDir(dir);
});

function newScanner(): Scanner {
  return new Scanner(db, catalogue, {
    stabilityMs: 0,
    probeConcurrency: 2,
    ffprobePath: "ffprobe",
    now: () => clock.now,
    forgetAfterMs: 0,
  });
}

function makeApp(using: Enricher): Hono<AppEnv> {
  return createApp({
    db,
    devices: new Devices(db, "secret", () => clock.now),
    items: new ItemReader(db),
    progress: new ProgressStore(db, () => clock.now),
    artwork: new ArtworkStore(db, join(dir, "cache"), "ffmpeg"),
    edit: {
      catalogue,
      enricher: using,
      chosen: new ChosenArtwork(db, {
        dir: join(dir, "artwork", "chosen"),
        ffmpegPath: "ffmpeg",
        ffprobePath: "ffprobe",
        // Small, so the test of the bound needs few uploads (each one runs ffmpeg).
        kept: KEPT,
      }),
    },
    serverName: "Test",
    version: "0",
    isScanning: () => false,
    now: () => clock.now,
  });
}

async function call<T = Edit>(
  method: string,
  path: string,
  options: { token?: string; body?: unknown; bytes?: Uint8Array<ArrayBuffer> } = {},
): Promise<{ status: number; body: T }> {
  const response = await app.request(path, {
    method,
    headers: {
      Authorization: `Bearer ${options.token ?? manager}`,
      ...(options.body === undefined ? {} : { "Content-Type": "application/json" }),
    },
    ...(options.bytes ? { body: options.bytes } : {}),
    ...(options.body === undefined ? {} : { body: JSON.stringify(options.body) }),
  });
  const text = await response.text();
  return { status: response.status, body: (text === "" ? null : JSON.parse(text)) as T };
}

async function scan(): Promise<void> {
  clock.now += 1;
  await scanner.scanAll();
  await scanner.processQueue();
}

async function rescan(): Promise<void> {
  await scan();
  await scan();
}

function idOf(kind: string, title?: string): string {
  const found = db.get<{ id: string }>(
    "select id from item where kind = ? and (? is null or title = ?) order by season_number, episode_number",
    [kind, title ?? null, title ?? null],
  );
  if (!found) throw new Error(`no ${kind} ${title ?? ""}`);
  return found.id;
}

async function film(name = "Up (2009)"): Promise<string> {
  makeVideo(join(movies, `${name}.mp4`), { seconds: 4 });
  await scan();
  return idOf("movie");
}

async function edit(id: string): Promise<Edit> {
  return (await call("GET", `/v1/items/${id}/edit`)).body;
}

async function patch(id: string, set: unknown, reset: string[] = []): Promise<Edit> {
  const { revision } = await edit(id);
  const reply = await call("PATCH", `/v1/items/${id}`, { body: { revision, set, reset } });
  expect(reply.status).toBe(200);
  return reply.body;
}

async function synced(since: string): Promise<{ ids: string[]; cursor: string }> {
  const { body } = await call<{ items: ApiItem[]; cursor: string }>(
    "GET",
    `/v1/library?cursor=${since}`,
  );
  return { ids: body.items.map((item) => item.id), cursor: body.cursor };
}

function setProgress(itemId: string): void {
  db.run("insert or ignore into profile (id, name, color, created_at) values ('p', 'P', 'red', 0)");
  db.run(
    "insert into progress (profile_id, item_id, position_ms, revision, updated_at) values ('p', ?, 1234, 1, 1)",
    [itemId],
  );
}
function progressItems(): string[] {
  return db.all<{ item_id: string }>("select item_id from progress").map((one) => one.item_id);
}

function offerMovie(id: number, title: string, date: string, extra = {}): Record<string, unknown> {
  tmdb.answers.set(`/3/movie/${id}`, {
    body: movieAnswer(id, title, date, { runtime: 0, ...extra }),
  });
  return { id, title, original_title: title, release_date: date, poster_path: `/poster${id}.jpg` };
}

function offerShow(
  id: number,
  name: string,
  seasons: Record<number, string[]>,
): Record<string, unknown> {
  const numbers = Object.keys(seasons).map(Number);
  tmdb.answers.set(`/3/tv/${id}`, {
    body: showAnswer(
      id,
      name,
      "2015-01-01",
      numbers,
      numbers.map((n) => seasons[n]?.length ?? 0),
    ),
  });
  for (const number of numbers) {
    tmdb.answers.set(`/3/tv/${id}/season/${number}`, {
      body: seasonAnswer(id, number, seasons[number] ?? [], 0),
    });
  }
  return { id, name, original_name: name, first_air_date: "2015-01-01" };
}

describe("who may edit", () => {
  it("refuses viewers and strangers on every route", async () => {
    const id = await film();
    const before = db.all("select * from item");
    for (const [method, path] of [
      ["GET", "edit"],
      ["PATCH", ""],
      ["GET", "artwork-options?kind=poster"],
      ["GET", "artwork-options/preview?kind=poster&path=/a.jpg"],
      ["POST", "artwork"],
      ["POST", "artwork/upload?kind=poster&revision=0"],
      ["DELETE", "artwork?kind=poster&revision=0"],
      ["GET", "match?query=a"],
      ["PUT", "match"],
      ["DELETE", "match?revision=0"],
      ["POST", "match/automatic"],
    ] as [string, string][]) {
      const path_ = `/v1/items/${id}${path === "" ? "" : `/${path}`}`;
      const asViewer = await call(method, path_, {
        token: viewer,
        body: method === "GET" ? undefined : {},
      });
      expect([method, path, asViewer.status]).toEqual([method, path, 403]);
      const asNobody = await call(method, path_, { token: "nonsense" });
      expect(asNobody.status).toBe(401);
    }
    expect(db.all("select * from item")).toEqual(before);
    expect(tmdb.received).toHaveLength(0);
    expect((await call("GET", "/v1/items/nothing/edit")).status).toBe(404);
  });
});

describe("fields", () => {
  it("shows automatic, override and effective values, and puts them back", async () => {
    const id = await film();
    const changed = await patch(id, {
      title: "Oben",
      sortTitle: "Pixar 10",
      year: 2010,
      overview: "Ballonnen.",
      genres: ["Family", "Adventure"],
    });
    expect(changed.fields["title"]).toEqual({
      automatic: "Up",
      overridden: true,
      override: "Oben",
      effective: "Oben",
    });
    expect(changed.item).toMatchObject({
      id,
      title: "Oben",
      sortTitle: "pixar 10",
      year: 2010,
      overview: "Ballonnen.",
      genres: ["Family", "Adventure"],
    });
    const back = await patch(id, {}, ["title", "sortTitle", "year", "overview", "genres"]);
    expect(back.item).toMatchObject({
      title: "Up",
      sortTitle: "up",
      year: 2009,
      overview: null,
      genres: [],
    });
    expect(db.get("select override_json from item where id = ?", [id])).toEqual({
      override_json: null,
    });
  });

  it("orders by a changed title unless the order title says otherwise", async () => {
    const id = await film();
    expect((await patch(id, { title: "The Zebra" })).item.sortTitle).toBe("zebra");
    expect((await patch(id, { sortTitle: "The Aardvark" })).item.sortTitle).toBe("the aardvark");
  });

  it("can empty a field, which is not the same as putting it back", async () => {
    const id = await film();
    const changed = await patch(id, { year: null, overview: "" });
    expect(changed.item).toMatchObject({ year: null, overview: null });
    expect(changed.fields["year"]).toMatchObject({
      automatic: 2009,
      overridden: true,
      override: null,
    });
  });

  it("refuses what does not fit", async () => {
    const id = await film();
    const refused = async (body: Record<string, unknown>): Promise<void> => {
      const reply = await call("PATCH", `/v1/items/${id}`, { body: { revision: 0, ...body } });
      expect([JSON.stringify(body).slice(0, 60), reply.status]).toEqual([
        JSON.stringify(body).slice(0, 60),
        400,
      ]);
    };
    for (const set of [
      { title: "" },
      { title: 5 },
      { title: "x".repeat(301) },
      { title: "a\nb" },
      { title: null },
      { year: "2009" },
      { year: 20.5 },
      { year: 99_999 },
      { overview: "x".repeat(10_001) },
      { genres: "Family" },
      { genres: [""] },
      { genres: Array.from({ length: 21 }, (_, n) => `g${n}`) },
      { categories: [] },
      { categories: ["Nope"] },
      { identKey: "x" },
      { __proto__x: 1 },
      [],
    ]) {
      await refused({ set });
    }
    await refused({ reset: ["id"] });
    await refused({ reset: "title" });
    await refused({ set: { title: "A" }, reset: ["title"] });
    await refused({ revision: "0" });
    expect((await edit(id)).revision).toBe(0);
  });

  it("refuses a change based on an older revision and answers with what is there now", async () => {
    const id = await film();
    const { revision } = await edit(id);
    await patch(id, { title: "First" });
    const late = await call("PATCH", `/v1/items/${id}`, {
      body: { revision, set: { title: "Second" } },
    });
    expect(late.status).toBe(409);
    expect(late.body.error?.code).toBe("conflict");
    expect(late.body.item.title).toBe("First");
    expect(late.body.revision).toBe(revision + 1);
  });

  it("does not call a scan or lookup a conflict", async () => {
    const id = await film();
    const { revision } = await edit(id);
    tmdb.search("movie", [offerMovie(1, "Up", "2009-05-28")]);
    await enricher.run();
    const reply = await call("PATCH", `/v1/items/${id}`, {
      body: { revision, set: { title: "Mine" } },
    });
    expect(reply.status).toBe(200);
  });

  it("reaches every app through the library sync", async () => {
    const id = await film();
    const { cursor } = await synced("");
    expect((await synced(cursor)).ids).toEqual([]);
    await patch(id, { title: "Changed" });
    expect((await synced(cursor)).ids).toEqual([id]);
  });

  it("survives a rescan, newer parsing rules and a lookup, with the same identity and progress", async () => {
    const id = await film();
    setProgress(id);
    const key = db.get("select ident_key from item where id = ?", [id]);
    await patch(id, { title: "Mine", categories: ["Grown-up"] });
    await rescan();
    db.setMeta("parser_version", "0");
    await rescan();
    tmdb.search("movie", [offerMovie(1, "Up", "2009-05-28")]);
    await enricher.run();
    clock.now += 91 * 86_400_000;
    await enricher.run();
    const after = await edit(id);
    expect(after.item).toMatchObject({
      title: "Mine",
      categories: ["Grown-up"],
      matchStatus: "matched",
    });
    expect(after.fields["title"]?.automatic).toBe("Up");
    expect(after.item.overview).toBe("About Up.");
    expect(db.get("select ident_key from item where id = ?", [id])).toEqual(key);
    expect(progressItems()).toEqual([id]);
  });

  it("moves along when a renamed file becomes another item, pictures included", async () => {
    const id = await film("Upp (2009)");
    setProgress(id);
    await patch(id, { title: "Mine" });
    await call("POST", `/v1/items/${id}/artwork/upload?kind=poster&revision=1`, {
      bytes: new Uint8Array(JPEG),
    });
    const poster = (await edit(id)).item.artwork.poster?.id;
    renameSync(join(movies, "Upp (2009).mp4"), join(movies, "Up (2009).mp4"));
    await rescan();
    const now = idOf("movie");
    expect(now).not.toBe(id);
    const after = await edit(now);
    expect(after.item).toMatchObject({ title: "Mine" });
    expect(after.fields["title"]?.automatic).toBe("Up");
    expect(after.item.artwork.poster?.id).toBe(poster);
    expect(progressItems()).toEqual([now]);
  });

  it("moves a show's edits and match along when its whole folder is renamed", async () => {
    for (const n of [1, 2]) makeVideo(join(series, `Exmple/Season 1/S01E0${n}.mp4`), { seed: n });
    await scan();
    const show = idOf("show");
    offerShow(5, "Example", { 1: ["One", "Two"] });
    await patch(show, { title: "Mine" });
    await call("PUT", `/v1/items/${show}/match`, {
      body: { revision: 1, tmdbType: "tv", tmdbId: 5 },
    });
    await enricher.settled();
    renameSync(join(series, "Exmple"), join(series, "Example"));
    await rescan();
    const now = idOf("show");
    expect(now).not.toBe(show);
    expect((await edit(now)).item).toMatchObject({
      title: "Mine",
      matchStatus: "locked",
      tmdb: { type: "tv", id: 5 },
    });
    expect(db.get("select count(*) as n from item where kind = 'show'")).toEqual({ n: 1 });
  });
});

describe("categories", () => {
  it("moves a show and everything below it, and puts it back", async () => {
    makeVideo(join(series, "Example/Season 1/S01E01.mp4"));
    await scan();
    const show = idOf("show");
    const { cursor } = await synced("");
    await patch(show, { categories: ["Grown-up", "Pixar"] });
    const changed = await synced(cursor);
    expect(changed.ids.sort()).toEqual([show, idOf("season"), idOf("episode")].sort());
    for (const id of changed.ids) {
      expect((await edit(id)).item.categories).toEqual(["Grown-up", "Pixar"]);
    }
    expect((await edit(show)).fields["categories"]?.automatic).toEqual(["Kids Series"]);
    await patch(show, {}, ["categories"]);
    expect((await edit(idOf("episode"))).item.categories).toEqual(["Kids Series"]);
    const { revision } = await edit(idOf("episode"));
    const below = await call("PATCH", `/v1/items/${idOf("episode")}`, {
      body: { revision, set: { categories: ["Pixar"] } },
    });
    expect(below.status).toBe(400);
  });

  it("takes ids as well as names, and shows both", async () => {
    const id = await film();
    const all = new Categories(db).all();
    const grown = all.find((one) => one.name === "Grown-up")?.id ?? "";
    const changed = await patch(id, { categoryIds: [grown] });
    expect(changed.item).toMatchObject({ categories: ["Grown-up"], categoryIds: [grown] });
    expect(changed.fields["categories"]).toMatchObject({
      automatic: ["Pixar"],
      overridden: true,
      override: ["Grown-up"],
    });
    for (const set of [
      { categoryIds: ["nope"] },
      { categoryIds: [grown], categories: ["Pixar"] },
    ]) {
      const { revision } = await edit(id);
      expect((await call("PATCH", `/v1/items/${id}`, { body: { revision, set } })).status).toBe(
        400,
      );
    }
  });
});

describe("artwork", () => {
  it("offers what TMDB has, and takes a choice that stays", async () => {
    const id = await film();
    tmdb.search("movie", [offerMovie(1, "Up", "2009-05-28")]);
    await enricher.run();
    tmdb.answers.set("/3/movie/1/images", {
      body: {
        posters: Array.from({ length: 80 }, (_, n) => ({
          file_path: `/choice${n}.jpg`,
          iso_639_1: n % 2 ? "en" : "fr",
          width: 2000,
          height: 3000,
        })),
      },
    });
    const { body } = await call<{ options: Option[]; revision: number; tmdbAvailable: boolean }>(
      "GET",
      `/v1/items/${id}/artwork-options?kind=poster`,
    );
    expect(body.options).toHaveLength(31);
    expect(body.options[0]).toMatchObject({
      source: "tmdb",
      path: "/poster1.jpg",
      selected: true,
      chosen: false,
    });
    const wanted = body.options[1];
    expect(wanted).toMatchObject({ source: "tmdb", artworkId: null, path: "/choice1.jpg" });

    const preview = await app.request(wanted?.previewUrl ?? "", {
      headers: { Authorization: `Bearer ${manager}` },
    });
    expect(preview.status).toBe(200);
    expect(preview.headers.get("content-type")).toBe("image/jpeg");
    expect(tmdb.requests("/t/p/w185/choice1.jpg")).toHaveLength(1);

    const automatic = (await edit(id)).item.artwork.poster?.id;
    const { cursor } = await synced("");
    const chosen = await call("POST", `/v1/items/${id}/artwork`, {
      body: { revision: body.revision, kind: "poster", source: "tmdb", path: wanted?.path },
    });
    expect(chosen.status).toBe(200);
    expect(chosen.body.artwork["poster"]?.[0]).toMatchObject({
      path: "/choice1.jpg",
      chosen: true,
    });
    expect((await synced(cursor)).ids).toEqual([id]);

    clock.now += 91 * 86_400_000;
    await enricher.run();
    await frames.run();
    expect((await edit(id)).artwork["poster"]?.[0]).toMatchObject({
      path: "/choice1.jpg",
      chosen: true,
    });

    const back = await call(
      "DELETE",
      `/v1/items/${id}/artwork?kind=poster&revision=${chosen.body.revision}`,
    );
    expect(back.body.item.artwork.poster?.id).toBe(automatic);
    // The choice is still there to take again, without a download.
    const again = await call("POST", `/v1/items/${id}/artwork`, {
      body: {
        revision: back.body.revision,
        kind: "poster",
        source: "existing",
        artworkId: chosen.body.item.artwork.poster?.id,
      },
    });
    expect(again.body.item.artwork.poster?.id).toBe(chosen.body.item.artwork.poster?.id);
  });

  it("offers stills for an episode of a matched show", async () => {
    makeVideo(join(series, "Example/Season 1/S01E01.mp4"));
    await scan();
    tmdb.search("tv", [offerShow(5, "Example", { 1: ["One"] })]);
    await enricher.run();
    tmdb.answers.set("/3/tv/5/season/1/episode/1/images", {
      body: { stills: [{ file_path: "/still-b.jpg", iso_639_1: null, width: 1920, height: 1080 }] },
    });
    const { body } = await call<{ options: Option[] }>(
      "GET",
      `/v1/items/${idOf("episode")}/artwork-options?kind=still`,
    );
    expect(body.options.map((one) => one.path)).toEqual(["/still5x1x1.jpg", "/still-b.jpg"]);
  });

  it("makes a frame at the chosen moment without touching the file", async () => {
    const id = await film();
    const path = join(movies, "Up (2009).mp4");
    const before = [
      readFileSync(path).toString("base64"),
      statSync(path).mtimeMs,
      readdirSync(movies),
    ];
    await frames.run();
    const automatic = (await edit(id)).item.artwork.backdrop?.id;
    const made = await call("POST", `/v1/items/${id}/artwork`, {
      body: { revision: 0, kind: "backdrop", source: "frame", positionMs: 2500 },
    });
    expect(made.status).toBe(200);
    expect(made.body.item.artwork.backdrop).toMatchObject({ width: 1280, height: 720 });
    expect(made.body.item.artwork.backdrop?.id).not.toBe(automatic);
    const poster = await call("POST", `/v1/items/${id}/artwork`, {
      body: { revision: 1, kind: "poster", source: "frame", positionMs: 500 },
    });
    expect(poster.body.item.artwork.poster).toMatchObject({ width: 720, height: 1080 });
    const served = await app.request(
      `/v1/artwork/${poster.body.item.artwork.poster?.id ?? ""}?w=200`,
      {
        headers: { Authorization: `Bearer ${viewer}` },
      },
    );
    expect(served.status).toBe(200);
    for (const positionMs of [-1, 1.5, 99_000, "1"]) {
      const refused = await call("POST", `/v1/items/${id}/artwork`, {
        body: { revision: 2, kind: "poster", source: "frame", positionMs },
      });
      expect(refused.status).toBe(400);
    }
    const foreign = await call("POST", `/v1/items/${id}/artwork`, {
      body: { revision: 2, kind: "poster", source: "frame", positionMs: 1, assetId: "other" },
    });
    expect(foreign.status).toBe(404);
    const back = await call("DELETE", `/v1/items/${id}/artwork?kind=backdrop&revision=2`);
    expect(back.body.item.artwork.backdrop?.id).toBe(automatic);
    expect([
      readFileSync(path).toString("base64"),
      statSync(path).mtimeMs,
      readdirSync(movies),
    ]).toEqual(before);
  });

  describe("from a device", () => {
    const upload = async (
      id: string,
      bytes: Uint8Array,
      kind = "poster",
    ): Promise<{ status: number; body: Edit }> => {
      const { revision } = await edit(id);
      return call("POST", `/v1/items/${id}/artwork/upload?kind=${kind}&revision=${revision}`, {
        bytes: new Uint8Array(bytes),
      });
    };
    const stored = (): string[] => readdirSync(join(dir, "artwork", "chosen"));

    it("takes a JPEG, and keeps a re-encoded copy without what else was in it", async () => {
      const id = await film();
      const marked = Buffer.concat([
        JPEG.subarray(0, 2),
        Buffer.from([0xff, 0xfe, 0, 18]),
        Buffer.from("SECRET-LOCATION!"),
        JPEG.subarray(2),
      ]);
      const reply = await upload(id, marked);
      expect(reply.status).toBe(200);
      expect(reply.body.item.artwork.poster).toMatchObject({ width: 640, height: 960 });
      expect(reply.body.artwork["poster"]?.[0]).toMatchObject({ source: "upload", chosen: true });
      const [name = ""] = stored();
      expect(readFileSync(join(dir, "artwork", "chosen", name)).includes("SECRET-LOCATION")).toBe(
        false,
      );
      expect(stored()).toHaveLength(1);
      // The same picture again is the same picture.
      const again = await upload(id, marked);
      expect(again.body.item.artwork.poster?.id).toBe(reply.body.item.artwork.poster?.id);
    });

    it("takes a PNG with transparency, and scales a large picture down", async () => {
      const id = await film();
      const png = execFileSync("ffmpeg", [
        ..."-v error -f lavfi -i color=c=red@0.5:size=3000x2000,format=rgba -frames:v 1 -f image2 -c:v png -".split(
          " ",
        ),
      ]);
      const reply = await upload(id, png, "backdrop");
      expect(reply.status).toBe(200);
      expect(reply.body.item.artwork.backdrop).toMatchObject({ width: 1600, height: 1066 });
    });

    it("turns a photo upright", async () => {
      const id = await film();
      const tiff = Buffer.from("4d4d002a00000008000101120003000000010006000000000000", "hex");
      const exif = Buffer.concat([Buffer.from("Exif\0\0", "latin1"), tiff]);
      const length = Buffer.alloc(2);
      length.writeUInt16BE(exif.length + 2);
      const sideways = Buffer.concat([
        JPEG.subarray(0, 2),
        Buffer.from([0xff, 0xe1]),
        length,
        exif,
        JPEG.subarray(2),
      ]);
      const reply = await upload(id, sideways);
      expect(reply.body.item.artwork.poster).toMatchObject({ width: 960, height: 640 });
    });

    // sips is how a Mac makes a HEIC; elsewhere there is no encoder to make one with.
    it.runIf(existsSync("/usr/bin/sips"))("puts a tiled HEIC together", async () => {
      const id = await film();
      const large = join(dir, "large.jpg");
      const heic = join(dir, "large.heic");
      execFileSync(
        "ffmpeg",
        `-v error -f lavfi -i testsrc2=size=1500x1200 -frames:v 1 ${large}`.split(" "),
      );
      execFileSync("sips", ["-s", "format", "heic", large, "--out", heic], { stdio: "ignore" });
      const reply = await upload(id, readFileSync(heic), "backdrop");
      expect(reply.status).toBe(200);
      expect(reply.body.item.artwork.backdrop).toMatchObject({ width: 1500, height: 1200 });
      // The right tiles in the right places: it looks like the original.
      const [name = ""] = stored();
      const compared = spawnSync(
        "ffmpeg",
        [
          ...["-i", large, "-i", join(dir, "artwork", "chosen", name)],
          ...["-filter_complex", "ssim", "-f", "null", "-"],
        ],
        { encoding: "utf8" },
      );
      expect(Number(/All:([\d.]+)/.exec(compared.stderr)?.[1])).toBeGreaterThan(0.9);
    });

    it("refuses anything that is not a picture it knows", async () => {
      const id = await film();
      const video = readFileSync(join(movies, "Up (2009).mp4"));
      const playlist = Buffer.from("#EXTM3U\n#EXTINF:1,\nfile:///etc/passwd\n");
      const svg = Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200"/>');
      const disguised = Buffer.concat([JPEG.subarray(0, 20), Buffer.from("x".repeat(5000))]);
      const tiny = execFileSync("ffmpeg", [
        ..."-v error -f lavfi -i testsrc2=size=40x40 -frames:v 1 -f image2 -c:v mjpeg -".split(" "),
      ]);
      const gif = Buffer.from("GIF89a".padEnd(100, "\0"));
      for (const bytes of [video, playlist, svg, disguised, tiny, gif, Buffer.alloc(0)]) {
        const reply = await upload(id, bytes);
        expect(reply.status).toBe(400);
      }
      expect((await edit(id)).item.artwork.poster).toBeNull();
      expect(existsSync(join(dir, "artwork", "chosen")) ? stored() : []).toEqual([]);
    });

    it("refuses a picture with too many bytes or too many pixels", async () => {
      const id = await film();
      const heavy = Buffer.alloc(20 * 1024 * 1024 + 1);
      JPEG.copy(heavy);
      expect((await upload(id, heavy)).body.error?.message).toContain("larger than");
      // A small file that says it is 60000 pixels wide.
      const png = execFileSync("ffmpeg", [
        ..."-v error -f lavfi -i color=c=black:size=200x200 -frames:v 1 -f image2 -c:v png -".split(
          " ",
        ),
      ]);
      png.writeUInt32BE(60_000, 16);
      png.writeUInt32BE(60_000, 20);
      expect((await upload(id, png)).status).toBe(400);
    });

    it("keeps a bounded number of them, and never drops the chosen one", async () => {
      const id = await film();
      for (let n = 0; n <= KEPT; n += 1) {
        const jpeg = execFileSync("ffmpeg", [
          ..."-v error -f lavfi -i".split(" "),
          `testsrc2=size=${200 + n * 2}x300`,
          ..."-frames:v 1 -f image2 -c:v mjpeg -".split(" "),
        ]);
        expect((await upload(id, jpeg)).status).toBe(200);
      }
      const view = await edit(id);
      expect(view.artwork["poster"]).toHaveLength(KEPT);
      expect(view.item.artwork.poster).toMatchObject({ width: 200 + KEPT * 2 });
    });
  });
});

describe("match", () => {
  it("searches, and fills a film in from the choice at once", async () => {
    const id = await film("Upp (2010)");
    setProgress(id);
    tmdb.search("movie", [offerMovie(1, "Up", "2009-05-28")]);
    await enricher.run();
    const view = await edit(id);
    expect(view.match).toMatchObject({ status: "needs_review", chosen: false });
    expect(view.match.reason).not.toBeNull();

    const found = await call<{
      results: { tmdb: { id: number }; title: string; previewUrl: string }[];
    }>("GET", `/v1/items/${id}/match?query=Up&year=2009`);
    expect(found.body.results).toMatchObject([
      { tmdb: { type: "movie", id: 1 }, title: "Up", year: 2009 },
    ]);
    const key = db.get("select ident_key from item where id = ?", [id]);
    const { cursor } = await synced("");
    const chosen = await call("PUT", `/v1/items/${id}/match`, {
      body: { revision: view.revision, tmdbType: "movie", tmdbId: 1 },
    });
    expect(chosen.status).toBe(200);
    expect(chosen.body.item).toMatchObject({
      id,
      title: "Up",
      year: 2009,
      matchStatus: "locked",
      tmdb: { type: "movie", id: 1 },
      imdbId: "tt0000001",
    });
    expect(chosen.body.item.artwork.poster).not.toBeNull();
    expect((await synced(cursor)).ids).toEqual([id]);
    expect(db.get("select ident_key from item where id = ?", [id])).toEqual(key);
    expect(progressItems()).toEqual([id]);

    db.setMeta("parser_version", "0");
    await rescan();
    clock.now += 91 * 86_400_000;
    await enricher.run();
    expect((await edit(id)).item).toMatchObject({ title: "Up", matchStatus: "locked" });
  });

  it("gives a show its seasons and episodes, and replaces a wrong match whole", async () => {
    for (const n of [1, 2]) makeVideo(join(series, `Example/Season 1/S01E0${n}.mp4`), { seed: n });
    await scan();
    const show = idOf("show");
    tmdb.search("tv", [offerShow(5, "Example", { 1: ["Wrong One", "Wrong Two"] })]);
    await enricher.run();
    const episodes = db.all<{ id: string; ident_key: string }>(
      "select id, ident_key from item where kind = 'episode' order by episode_number",
    );
    setProgress(episodes[0]?.id ?? "");
    const titles = async (): Promise<string[]> => {
      const all: string[] = [];
      for (const one of episodes) all.push((await edit(one.id)).item.title);
      return all;
    };
    expect(await titles()).toEqual(["Wrong One", "Wrong Two"]);
    // The manager named one by hand; that stays whatever the match.
    await patch(episodes[1]?.id ?? "", { title: "By Hand" });

    offerShow(6, "Example (right)", { 1: ["Right One", "Right Two"] });
    const reply = await call("PUT", `/v1/items/${show}/match`, {
      body: { revision: 0, tmdbType: "tv", tmdbId: 6 },
    });
    expect(reply.body.item).toMatchObject({ title: "Example (right)", matchStatus: "locked" });
    await enricher.settled();
    expect(await titles()).toEqual(["Right One", "By Hand"]);
    expect((await edit(episodes[1]?.id ?? "")).fields["title"]?.automatic).toBe("Right Two");
    expect(
      db.all("select id, ident_key from item where kind = 'episode' order by episode_number"),
    ).toEqual(episodes);
    expect(progressItems()).toEqual([episodes[0]?.id]);
    expect(db.get("select count(*) as n from artwork where remote_path like '/still5x%'")).toEqual({
      n: 0,
    });

    const none = await call("DELETE", `/v1/items/${show}/match?revision=1`);
    expect(none.body.item).toMatchObject({
      title: "Example",
      matchStatus: "locked",
      tmdb: null,
      overview: null,
      genres: [],
    });
    expect(await titles()).toEqual(["Episode 1", "By Hand"]);
    const asked = tmdb.received.length;
    clock.now += 400 * 86_400_000;
    await rescan();
    await enricher.run();
    expect(tmdb.received.length).toBe(asked);

    tmdb.search("tv", [offerShow(6, "Example", { 1: ["Right One", "Right Two"] })]);
    const automatic = await call("POST", `/v1/items/${show}/match/automatic`, {
      body: { revision: 2 },
    });
    expect(automatic.body.item).toMatchObject({
      matchStatus: "matched",
      tmdb: { type: "tv", id: 6 },
    });
    await enricher.settled();
    expect(await titles()).toEqual(["Right One", "By Hand"]);
  });

  it("is not undone by a lookup that was already under way", async () => {
    for (const n of [1, 2]) makeVideo(join(series, `Example/Season 1/S01E0${n}.mp4`), { seed: n });
    await scan();
    const show = idOf("show");
    tmdb.search("tv", [offerShow(5, "Example", { 1: ["Wrong One", "Wrong Two"] })]);
    offerShow(6, "Right", { 1: ["Right One", "Right Two"] });
    let release: () => void = () => undefined;
    const held = new Promise<void>((resolve) => (release = resolve));
    let reached: () => void = () => undefined;
    const waiting = new Promise<void>((resolve) => (reached = resolve));
    let first = true;
    tmdb.beforeAnswer = (request) => {
      if (!request.path.startsWith("/3/tv/5/season/1/episode") || !first) return Promise.resolve();
      first = false;
      reached();
      return held;
    };
    const running = enricher.run();
    await waiting;
    await call("PUT", `/v1/items/${show}/match`, {
      body: { revision: 0, tmdbType: "tv", tmdbId: 6 },
    });
    release();
    await running;
    await enricher.settled();
    expect(db.all("select title from item where kind = 'episode' order by episode_number")).toEqual(
      [{ title: "Right One" }, { title: "Right Two" }],
    );
  });

  it("refuses the wrong kind, an unknown id and an older revision", async () => {
    const id = await film();
    offerMovie(1, "Up", "2009-05-28");
    const put = async (body: unknown): Promise<number> =>
      (await call("PUT", `/v1/items/${id}/match`, { body })).status;
    expect(await put({ revision: 0, tmdbType: "tv", tmdbId: 1 })).toBe(400);
    expect(await put({ revision: 0, tmdbType: "movie", tmdbId: "1" })).toBe(400);
    expect(await put({ revision: 0, tmdbType: "movie", tmdbId: 404 })).toBe(404);
    expect(await put({ revision: 7, tmdbType: "movie", tmdbId: 1 })).toBe(409);
    expect((await edit(id)).item.matchStatus).toBe("unmatched");
  });

  it("says so when TMDB is away or there is no key, and edits go on", async () => {
    const id = await film();
    await tmdb.stop();
    expect((await call("GET", `/v1/items/${id}/match?query=Up`)).status).toBe(503);
    expect((await patch(id, { title: "Still works" })).item.title).toBe("Still works");
    const options = await call<{ options: Option[] }>(
      "GET",
      `/v1/items/${id}/artwork-options?kind=poster`,
    );
    expect(options.status).toBe(200);
    const keyless = new Enricher({ db, catalogue, key: null, language: "en-US", artworkDir: dir });
    app = makeApp(keyless);
    expect((await call("GET", `/v1/items/${id}/match?query=Up`)).status).toBe(503);
    expect((await call("DELETE", `/v1/items/${id}/match?revision=1`)).status).toBe(200);
    tmdb = await LocalTmdb.start(JPEG);
  });
});

it("upgrades a catalogue from before editing and knows its automatic pictures", () => {
  const path = join(dir, "old.db");
  const old = new Database(path);
  old.run("delete from schema_migration where version = 2");
  old.run(
    "insert into item (id, kind, ident_key, title, sort_title, added_at, revision) values ('i', 'movie', 'k', 'T', 't', 0, 1)",
  );
  old.run(
    "insert into artwork (id, item_id, kind, provider, remote_path, selected) values ('a', 'i', 'poster', 'tmdb', '/a.jpg', 1), ('b', 'i', 'backdrop', 'frame', 'f', 1)",
  );
  old.close();
  const raw = new DatabaseSync(path);
  raw.exec("alter table item drop column edit_revision; alter table artwork drop column automatic");
  raw.close();
  const upgraded = new Database(path);
  expect(upgraded.all("select id, automatic from artwork order by id")).toEqual([
    { id: "a", automatic: 1 },
    { id: "b", automatic: 0 },
  ]);
  upgraded.close();
});
