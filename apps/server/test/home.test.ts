// SPDX-License-Identifier: MPL-2.0
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import type { Hono } from "hono";
import { afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { ChosenArtwork } from "../src/artwork/chosen.ts";
import { ArtworkStore } from "../src/artwork/serve.ts";
import { Devices } from "../src/auth/devices.ts";
import { Database } from "../src/db/database.ts";
import { migrations } from "../src/db/migrations.ts";
import { Enricher, type EnricherOptions } from "../src/enrich/index.ts";
import { createApp, type AppEnv } from "../src/http/app.ts";
import { Catalogue } from "../src/library/catalogue.ts";
import { ItemReader, renown, type ApiItem } from "../src/library/items.ts";
import { parseMediaPath, type SourceHint } from "../src/library/parse.ts";
import type { Popular } from "../src/plays.ts";
import { ProgressStore } from "../src/progress.ts";
import { makeTempDir, removeDir } from "./support/media.ts";
import { LocalTmdb, movieAnswer } from "./support/tmdb.ts";

const START = new Date(2027, 0, 15, 12).getTime();
const MINUTE = 60_000;
const DAY = 86_400_000;

function picture(size: string, codec: "mjpeg" | "png", pixels = "rgba"): Buffer {
  const source =
    codec === "png" ? `color=c=red@0.5:size=${size},format=${pixels}` : `testsrc2=size=${size}`;
  return execFileSync("ffmpeg", [
    ...["-v", "error", "-f", "lavfi", "-i", source, "-frames:v", "1"],
    ...["-f", "image2pipe", "-c:v", codec, "-"],
  ]);
}

let wide: Buffer;
let narrow: Buffer;
let clear: Buffer;
let opaque: Buffer;

let dir: string;
let db: Database;
let catalogue: Catalogue;
let tmdb: LocalTmdb;
let clock: { now: number };
let enrichers: Enricher[];
let pictures: Map<string, Buffer>;
let files: number;

beforeAll(() => {
  wide = picture("2560x1440", "mjpeg");
  narrow = picture("1280x720", "mjpeg");
  clear = picture("1200x300", "png");
  opaque = picture("1200x300", "png", "rgb24");
});

beforeEach(async () => {
  dir = makeTempDir();
  clock = { now: START };
  files = 0;
  db = new Database(join(dir, "lobby.db"));
  catalogue = new Catalogue(db, () => clock.now);
  for (const hint of ["movies", "series"]) {
    db.run("insert into source (id, path, name, hint, created_at) values (?, ?, ?, ?, 0)", [
      hint,
      `/${hint}`,
      hint,
      hint,
    ]);
  }
  tmdb = await LocalTmdb.start(narrow);
  pictures = new Map([
    ["/clear.png", clear],
    ["/opaque.png", opaque],
  ]);
  tmdb.intercept = ({ path }) => {
    if (!path.startsWith("/t/p/")) return null;
    const name = path.slice(path.lastIndexOf("/"));
    const body = pictures.get(name) ?? (path.includes("/original/") ? wide : undefined);
    return body ? { body } : null;
  };
  enrichers = [];
});

afterEach(async () => {
  for (const one of enrichers) await one.stop();
  await tmdb.stop();
  db.close();
  removeDir(dir);
});

function enricher(options: Partial<EnricherOptions> = {}): Enricher {
  const made = new Enricher({
    db,
    catalogue,
    key: "0123456789abcdef0123456789abcdef",
    language: "nl-NL",
    artworkDir: join(dir, "artwork"),
    baseUrl: `${tmdb.origin}/3`,
    imageBaseUrl: `${tmdb.origin}/t/p`,
    now: () => clock.now,
    ...options,
    limits: { minIntervalMs: 0, backoffMs: 5, retries: 0, timeoutMs: 5_000 },
  });
  enrichers.push(made);
  return made;
}

function link(assetId: string, relPath: string, hint: SourceHint): string[] {
  const parsed = parseMediaPath(relPath, hint);
  db.run("update asset set rel_path = ?, parsed_json = ? where id = ?", [
    relPath,
    JSON.stringify(parsed),
    assetId,
  ]);
  return catalogue.linkAsset(assetId, parsed, hint);
}

function addFile(relPath: string, hint: SourceHint = "movies"): { asset: string; id: string } {
  const asset = `asset${String((files += 1))}`;
  db.run(
    `insert into asset (id, source_id, rel_path, size, mtime_ms, revision, state, duration_ms, playability,
       container, first_seen_at, updated_at) values (?, ?, ?, 1, 1, '1', 'probed', ?, 'direct', 'mp4', ?, 0)`,
    [asset, hint, relPath, 90 * MINUTE, clock.now],
  );
  return { asset, id: link(asset, relPath, hint)[0] ?? "" };
}

function api(id: string): ApiItem {
  const [item] = new ItemReader(db).read([id]);
  if (!item) throw new Error("no such item");
  return item;
}

interface Pictures {
  logos?: Record<string, unknown>[];
  backdrops?: Record<string, unknown>[];
}

function offer(id: number, title: string, images: Pictures = {}, extra = {}): void {
  const answer = movieAnswer(id, title, "2001-01-01", {
    tagline: "One  line.",
    popularity: 40,
    vote_average: 7.5,
    vote_count: 3000,
    images: {
      posters: [{ file_path: `/poster${String(id)}.jpg`, iso_639_1: "nl" }],
      backdrops: images.backdrops ?? [],
      logos: images.logos ?? [],
    },
    ...extra,
  });
  tmdb.answers.set(`/3/movie/${String(id)}`, { body: answer });
  tmdb.search("movie", [...offered.values()].concat(answer));
  offered.set(id, answer);
}
const offered = new Map<number, Record<string, unknown>>();
beforeEach(() => {
  offered.clear();
});

const logo = (path: string, language: string | null, width = 1200, height = 300): object => ({
  file_path: path,
  iso_639_1: language,
  width,
  height,
});
const backdrop = (path: string, language: string | null, width: number, count = 0): object => ({
  file_path: path,
  iso_639_1: language,
  width,
  height: Math.round((width * 9) / 16),
  vote_average: 8,
  vote_count: count,
});
const images = (logos: object[], backdrops: object[] = []): Pictures => ({
  logos: logos as Record<string, unknown>[],
  backdrops: backdrops as Record<string, unknown>[],
});

describe("pictures for a banner", () => {
  it("takes a logo in the household's language, then English, then without one; never an SVG", async () => {
    offer(
      1,
      "Alpha",
      images([logo("/bare.png", null), logo("/en.png", "en"), logo("/nl.png", "nl")]),
    );
    offer(
      2,
      "Beta",
      images([logo("/fr.png", "fr"), logo("/bare.png", null), logo("/en.png", "en")]),
    );
    offer(3, "Gamma", images([logo("/bare.png", null), logo("/drawn.svg", "nl")]));
    offer(4, "Delta", images([logo("/tiny.png", "nl", 90, 30), logo("/tall.png", "nl", 300, 900)]));
    for (const name of ["nl", "en", "bare"]) pictures.set(`/${name}.png`, clear);
    const ids = ["Alpha", "Beta", "Gamma", "Delta"].map((one) => addFile(`${one} (2001).mkv`).id);
    await enricher().run();
    const path = (id = ""): unknown =>
      db.get<{ remote_path: string }>(
        "select remote_path from artwork where item_id = ? and kind = 'logo' and selected = 1",
        [id],
      )?.remote_path;
    expect(ids.map(path)).toEqual(["/nl.png", "/en.png", "/bare.png", undefined]);
    expect(api(ids[3] ?? "").artwork.logo).toBeNull();
    expect(tmdb.received.some((one) => one.path.endsWith(".svg"))).toBe(false);
    expect(tmdb.requests("/3/movie/1")[0]?.query.get("include_image_language")).toBe("nl,en,null");
  });

  it("keeps a logo as a PNG of a bounded width, and passes over an opaque one", async () => {
    offer(1, "Alpha", images([logo("/opaque.png", "nl"), logo("/clear.png", "nl")]));
    const { id } = addFile("Alpha (2001).mkv");
    await enricher().run();
    expect(api(id).artwork.logo).toMatchObject({ width: 800, height: 200 });
    const row = db.get<{ local_path: string }>(
      "select local_path from artwork where kind = 'logo' and selected = 1",
    );
    expect(row?.local_path).toMatch(/\.png$/);
    const bytes = readFileSync(row?.local_path ?? "");
    // Colour with transparency.
    expect(bytes[25]).toBe(6);
  });

  it("takes the best rated wide picture without words, at 1920 wide", async () => {
    offer(
      1,
      "Alpha",
      images(
        [],
        [
          backdrop("/words.jpg", "nl", 3840, 90),
          backdrop("/small.jpg", null, 1000, 80),
          backdrop("/one.jpg", null, 3840, 1),
          backdrop("/best.jpg", null, 3840, 30),
        ],
      ),
    );
    const { id } = addFile("Alpha (2001).mkv");
    await enricher().run();
    expect(api(id).artwork.backdrop).toMatchObject({ width: 1920, height: 1080 });
    expect(tmdb.requests("/t/p/original/best.jpg")).toHaveLength(1);
    expect(tmdb.requests("/t/p/w1280/best.jpg")).toHaveLength(0);
  });

  it("takes the ordinary size when the large one cannot be had", async () => {
    offer(1, "Alpha", images([], [backdrop("/best.jpg", null, 3840)]));
    const { id } = addFile("Alpha (2001).mkv");
    await enricher({ ffmpegPath: "/nowhere/ffmpeg" }).run();
    expect(api(id).artwork.backdrop).toMatchObject({ width: 1280, height: 720 });
  });
});

describe("what was matched before", () => {
  /** The library as it was: matched, with a narrow picture and none of the rest. */
  async function old(count: number): Promise<string[]> {
    const ids: string[] = [];
    for (let n = 1; n <= count; n += 1) {
      offer(
        n,
        `Film ${"abcdefgh"[n] ?? ""}`,
        images([], [backdrop(`/back${String(n)}.jpg`, null, 1280)]),
        { tagline: "", vote_count: 0, popularity: 0 },
      );
      ids.push(addFile(`Film ${"abcdefgh"[n] ?? ""} (2001).mkv`).id);
    }
    expect(await enricher().run()).toMatchObject({ matched: count });
    db.run(
      "update item set facts_at = null, tagline = null, vote_count = null, vote_average = null, popularity = null",
    );
    for (let n = 1; n <= count; n += 1) {
      offer(
        n,
        `Film ${"abcdefgh"[n] ?? ""}`,
        images([logo("/clear.png", "en")], [backdrop(`/back${String(n)}.jpg`, null, 3840)]),
      );
    }
    tmdb.received.length = 0;
    return ids;
  }

  it("gets logos, wide pictures and numbers, a few per run, and goes on after a restart", async () => {
    const ids = await old(5);
    const pictureIds = ids.map((id) => api(id).artwork.backdrop?.id);
    const revision = db.currentRevision();
    expect(await enricher({ factsPerRun: 2 }).run()).toMatchObject({ matched: 0, failed: 0 });
    const done = (): number => ids.filter((id) => api(id).artwork.logo !== null).length;
    expect(done()).toBe(2);
    expect(db.currentRevision()).toBe(revision + 1);
    expect(tmdb.mostAtOnce).toBeLessThanOrEqual(4);
    // Another process, as after a restart.
    const again = enricher({ factsPerRun: 2 });
    await again.run();
    await again.run();
    expect(done()).toBe(5);
    // Nothing was asked for twice, and nothing else about the titles was.
    expect(
      tmdb.received
        .filter((one) => one.path.startsWith("/3/"))
        .map((one) => one.path)
        .sort(),
    ).toEqual([1, 2, 3, 4, 5].map((n) => `/3/movie/${String(n)}`));
    for (const [index, id] of ids.entries()) {
      const item = api(id);
      expect(item).toMatchObject({ tagline: "One line.", matchStatus: "matched" });
      expect(item.renown).toBeGreaterThan(0.5);
      // The same picture, only more of it.
      expect(item.artwork.backdrop).toMatchObject({ id: pictureIds[index], width: 1920 });
    }
    await again.run();
    expect(tmdb.received.filter((one) => one.path.startsWith("/3/"))).toHaveLength(5);
  });

  it("leaves alone what a manager chose", async () => {
    const [id = ""] = await old(1);
    db.run("update artwork set locked = 1 where kind = 'backdrop'");
    offer(1, "Film b", images([], [backdrop("/other.jpg", null, 3840)]));
    const chosen = api(id).artwork.backdrop;
    await enricher().run();
    expect(api(id).artwork.backdrop).toEqual(chosen);
  });

  it("tries again later when TMDB is away", async () => {
    const [id = ""] = await old(1);
    const { intercept } = tmdb;
    tmdb.intercept = () => ({ status: 500 });
    const one = enricher();
    expect(await one.run()).toMatchObject({ failed: 1 });
    expect(api(id).artwork.logo).toBeNull();
    tmdb.intercept = intercept;
    clock.now += 5 * MINUTE;
    await one.run();
    expect(api(id).artwork.logo).not.toBeNull();
  });

  it("looks at the numbers again after a month, and touches nothing when they are the same", async () => {
    const [id = ""] = await old(1);
    const one = enricher();
    await one.run();
    const before = api(id).renown ?? 0;
    const revision = db.currentRevision();
    clock.now += 29 * DAY;
    await one.run();
    expect(tmdb.requests("/3/movie/1")).toHaveLength(1);
    clock.now += 2 * DAY;
    await one.run();
    expect(tmdb.requests("/3/movie/1")).toHaveLength(2);
    expect(db.currentRevision()).toBe(revision);
    offer(1, "Film b", images([]), { vote_count: 15_000 });
    clock.now += 31 * DAY;
    await one.run();
    expect(api(id).renown).toBeGreaterThan(before);
    expect(api(id).artwork.logo).not.toBeNull();
  });
});

it("says how well known a title is without making it up", () => {
  expect(renown(null, 8, 10)).toBeNull();
  expect(renown(0, null, 10)).toBeNull();
  const obscure = renown(1, 10, 0) ?? 0;
  const known = renown(3000, 7, 20) ?? 0;
  const famous = renown(30_000, 8.5, 500) ?? 0;
  expect(obscure).toBeLessThan(0.1);
  expect(known).toBeGreaterThan(obscure);
  expect(famous).toBeGreaterThan(known);
  expect(famous).toBeLessThanOrEqual(1);
});

describe("when something was added", () => {
  it("stays where it was when a file is replaced, renamed or joined by another", () => {
    const film = addFile("Alpha (2001).mkv");
    clock.now += DAY;
    const later = addFile("Beta (2001).mkv");
    clock.now += DAY;
    // Read again, converted, another edition, and an extra.
    link(film.asset, "Alpha (2001).mkv", "movies");
    link(film.asset, "Alpha (2001).mp4", "movies");
    expect(addFile("Alpha (2001) - Director's Cut.mkv").id).toBe(film.id);
    addFile("Alpha (2001)/Trailers/Alpha trailer.mkv");
    expect(api(film.id).addedAt).toBe(START);
    expect(api(later.id).addedAt).toBe(START + DAY);
    // Another title by its name: a new item, but not a new film.
    const other = addFile("Gamma (2001).mkv");
    clock.now += DAY;
    const [renamed = ""] = link(other.asset, "Gamma Rays (2001).mkv", "movies");
    expect(renamed).not.toBe(other.id);
    expect(api(renamed).addedAt).toBe(START + 2 * DAY);
  });

  it("is when the newest episode came, for a series", () => {
    const one = addFile("Zoo/Season 1/Zoo S01E01.mkv", "series");
    const show = api(api(one.id).parentId ?? "").parentId ?? "";
    expect(api(show)).toMatchObject({ addedAt: START, newEpisodesAt: null });
    clock.now += 2 * DAY;
    const two = addFile("Zoo/Season 1/Zoo S01E02.mkv", "series");
    db.run("update item set air_date = '2027-01-10' where id = ?", [two.id]);
    const there = { addedAt: clock.now, newEpisodesAt: clock.now, latestAirDate: "2027-01-10" };
    expect(api(show)).toMatchObject(there);
    clock.now += 2 * DAY;
    addFile("Zoo/Season 1/Zoo S01E01 1080p.mkv", "series");
    expect(api(show)).toMatchObject(there);
    // The whole folder under another name.
    const renamed = [
      link(one.asset, "Great Zoo/Season 1/Great Zoo S01E01.mkv", "series"),
      link(two.asset, "Great Zoo/Season 1/Great Zoo S01E02.mkv", "series"),
    ];
    const now = api(api(renamed[0]?.[0] ?? "").parentId ?? "").parentId ?? "";
    expect(now).not.toBe(show);
    expect(api(now)).toMatchObject({ ...there, latestAirDate: null });
  });
});

describe("what the household watches", () => {
  let app: Hono<AppEnv>;
  let devices: Devices;
  let manager: string;
  let child: string;
  let progress: ProgressStore;

  beforeEach(() => {
    devices = new Devices(db, "secret", () => clock.now);
    progress = new ProgressStore(db, () => clock.now);
    manager = devices.createLocalManager("Mac").token;
    app = createApp({
      db,
      devices,
      items: new ItemReader(db),
      progress,
      artwork: new ArtworkStore(db, join(dir, "cache"), "ffmpeg"),
      edit: {
        catalogue,
        enricher: enricher(),
        chosen: new ChosenArtwork(db, {
          dir: join(dir, "artwork", "chosen"),
          ffmpegPath: "ffmpeg",
          ffprobePath: "ffprobe",
        }),
      },
      serverName: "Test",
      version: "0",
      isScanning: () => false,
      now: () => clock.now,
    });
    for (const id of ["one", "two", "kid"]) {
      db.run(
        "insert into profile (id, name, color, created_at, kids_json) values (?, ?, 'red', 0, ?)",
        [id, id, null],
      );
    }
    const paired = devices.createLocalManager("Tablet");
    child = paired.token;
  });

  const send = (
    method: string,
    path: string,
    body?: unknown,
    token = manager,
    headers: Record<string, string> = {},
  ): Promise<Response> =>
    Promise.resolve(
      app.request(path, {
        method,
        headers: { Authorization: `Bearer ${token}`, ...headers },
        ...(body === undefined
          ? {}
          : { body: Buffer.isBuffer(body) ? new Uint8Array(body) : JSON.stringify(body) }),
      }),
    );
  async function popular(token = manager, query = ""): Promise<Popular> {
    const reply = await send("GET", `/v1/popular${query}`, undefined, token);
    expect(reply.status).toBe(200);
    return (await reply.json()) as Popular;
  }
  function put(
    profile: string,
    item: string,
    minutes: number,
    options: { completed?: boolean; duration?: number | null; opId?: string } = {},
  ): void {
    const { duration = 90 } = options;
    const result = progress.put(profile, item, {
      opId: options.opId ?? randomUUID(),
      baseRevision: progress.revision,
      positionMs: minutes * MINUTE,
      durationMs: duration === null ? null : duration * MINUTE,
      completed: options.completed ?? false,
      updatedAt: clock.now,
    });
    expect(result.outcome).toBe("accepted");
  }
  /** Watches on, as fast as the clock goes. */
  function watch(profile: string, item: string, from: number, to: number, duration = 90): void {
    for (let at = from; at <= to; at += 1) {
      clock.now += MINUTE;
      put(profile, item, at, { duration });
    }
  }
  async function makeKid(allowed: string[]): Promise<void> {
    const kids = {
      allowedGroupIds: [],
      allowedCategoryIds: [],
      allowedItemIds: allowed,
      blockedItemIds: [],
    };
    expect((await send("PATCH", "/v1/profiles/kid", { kids })).status).toBe(200);
  }
  const bind = (): void => {
    db.run("update device set kids_profile_id = 'kid', role = 'viewer' where name = 'Tablet'");
  };

  it("counts ten minutes or a quarter, once a day for each viewer", async () => {
    const film = addFile("Alpha (2001).mkv").id;
    const short = addFile("Short (2001).mkv").id;
    watch("one", film, 0, 9);
    expect((await popular()).titles).toEqual([]);
    watch("one", film, 10, 40);
    expect((await popular()).titles).toEqual([{ itemId: film, plays: 1 }]);
    watch("two", film, 0, 30);
    expect((await popular()).titles).toEqual([{ itemId: film, plays: 2 }]);
    watch("one", short, 0, 2, 7);
    expect((await popular()).titles).toEqual([
      { itemId: film, plays: 2 },
      { itemId: short, plays: 1 },
    ]);
    clock.now += DAY;
    watch("one", film, 41, 60);
    expect((await popular()).titles[0]).toEqual({ itemId: film, plays: 3 });
    const told = await popular();
    expect(Object.keys(told).sort()).toEqual(["days", "titles", "viewers"]);
    expect(Object.keys(told.titles[0] ?? {}).sort()).toEqual(["itemId", "plays"]);
  });

  it("counts a series once, whichever episodes", async () => {
    const a = addFile("Zoo/Season 1/Zoo S01E01.mkv", "series").id;
    const b = addFile("Zoo/Season 2/Zoo S02E01.mkv", "series").id;
    const show = api(api(a).parentId ?? "").parentId ?? "";
    watch("one", a, 0, 12);
    watch("one", b, 0, 12);
    expect((await popular()).titles).toEqual([{ itemId: show, plays: 1 }]);
  });

  it("does not take jumping, marking or a retry for watching", async () => {
    const film = addFile("Alpha (2001).mkv").id;
    put("one", film, 0);
    for (const to of [30, 60, 20, 80, 10, 85]) {
      clock.now += 10_000;
      put("one", film, to);
    }
    put("one", film, 85, { completed: true });
    put("one", film, 0);
    put("two", film, 0, { completed: true });
    expect((await popular()).titles).toEqual([]);
    put("two", film, 0);
    watch("two", film, 0, 8);
    clock.now += 2 * MINUTE;
    for (let n = 0; n < 3; n += 1) {
      progress.put("two", film, {
        opId: "same",
        baseRevision: progress.revision,
        positionMs: 9 * MINUTE,
        durationMs: null,
        completed: false,
        updatedAt: clock.now,
      });
    }
    expect((await popular()).titles).toEqual([]);
  });

  it("counts a film that was watched away from home, and watching it again", async () => {
    const film = addFile("Alpha (2001).mkv").id;
    put("one", film, 88, { completed: true });
    expect((await popular()).titles).toEqual([{ itemId: film, plays: 1 }]);
    clock.now += 3 * DAY;
    watch("one", film, 1, 11);
    expect((await popular()).titles).toEqual([{ itemId: film, plays: 2 }]);
  });

  it("forgets after half a year, and at once with the viewer", async () => {
    const film = addFile("Alpha (2001).mkv").id;
    const other = addFile("Beta (2001).mkv").id;
    put("one", film, 60);
    clock.now += 170 * DAY;
    put("two", other, 60);
    expect((await popular()).titles).toHaveLength(2);
    clock.now += 20 * DAY;
    expect((await popular()).titles).toEqual([{ itemId: other, plays: 1 }]);
    put("kid", other, 60);
    expect(db.get("select count(*) as n from play where profile_id = 'one'")).toEqual({ n: 0 });
    expect((await send("DELETE", "/v1/profiles/two")).status).toBe(204);
    expect((await popular()).titles).toEqual([{ itemId: other, plays: 1 }]);
    expect(db.get("select count(*) as n from play where profile_id = 'two'")).toEqual({ n: 0 });
  });

  it("moves along when a file gets another name", async () => {
    const film = addFile("Alpha (2001).mkv");
    put("one", film.id, 60);
    const [renamed = ""] = link(film.asset, "Alpha Beta (2001).mkv", "movies");
    expect((await popular()).titles).toEqual([{ itemId: renamed, plays: 1 }]);
  });

  it("shows a kids device only what kids watched, of what it may see", async () => {
    const film = addFile("Alpha (2001).mkv").id;
    const late = addFile("Late (2001).mkv").id;
    const a = addFile("Zoo/Season 1/Zoo S01E01.mkv", "series").id;
    const b = addFile("Zoo/Season 1/Zoo S01E02.mkv", "series").id;
    const show = api(api(a).parentId ?? "").parentId ?? "";
    put("one", film, 60);
    put("one", a, 60);
    put("kid", late, 60);
    put("kid", b, 60);
    await makeKid([film, a]);
    bind();
    const none = { days: 180, viewers: "kids", titles: [] };
    expect(await popular(child)).toEqual(none);
    expect(await popular(child, "?viewers=all")).toEqual(none);
    put("kid", film, 60);
    put("kid", a, 60);
    expect((await popular(child)).titles.map((one) => one.itemId).sort()).toEqual(
      [film, show].sort(),
    );
    expect((await popular(child)).titles.every((one) => one.plays === 1)).toBe(true);
    // Kids mode on a device without limits: the app shows what its viewer may see of these.
    expect((await popular(manager, "?viewers=kids")).titles).toHaveLength(3);
    expect((await popular()).titles.find((one) => one.itemId === film)?.plays).toBe(2);
    expect((await send("GET", "/v1/popular?viewers=one")).status).toBe(400);
  });

  it("answers 304 while nothing changed, and needs a device", async () => {
    const film = addFile("Alpha (2001).mkv").id;
    put("one", film, 60);
    const first = await send("GET", "/v1/popular");
    const tag = first.headers.get("ETag") ?? "";
    const again = await send("GET", "/v1/popular", undefined, manager, { "If-None-Match": tag });
    expect(again.status).toBe(304);
    put("two", film, 60);
    expect(
      (await send("GET", "/v1/popular", undefined, manager, { "If-None-Match": tag })).status,
    ).toBe(200);
    expect((await app.request("/v1/popular")).status).toBe(401);
  });

  it("shows a kids device the series' dates of the episodes it may see", async () => {
    const a = addFile("Zoo/Season 1/Zoo S01E01.mkv", "series").id;
    clock.now += 2 * DAY;
    addFile("Zoo/Season 1/Zoo S01E02.mkv", "series");
    const show = api(api(a).parentId ?? "").parentId ?? "";
    await makeKid([a]);
    bind();
    const { item } = (await (await send("GET", `/v1/items/${show}`, undefined, child)).json()) as {
      item: ApiItem;
    };
    expect(item).toMatchObject({ addedAt: START, newEpisodesAt: null });
  });

  describe("a manager's logo", () => {
    interface Edit {
      item: ApiItem;
      revision: number;
      withoutLogo: boolean;
      artwork: Record<string, { source: string; path: string | null; chosen: boolean }[]>;
    }
    let id: string;
    beforeEach(async () => {
      offer(1, "Alpha", images([logo("/clear.png", "nl")]));
      id = addFile("Alpha (2001).mkv").id;
      await enricher().run();
      pictures.set("/second.png", picture("600x200", "png"));
      tmdb.answers.set("/3/movie/1/images", {
        body: {
          logos: [
            logo("/bare.png", null),
            logo("/drawn.svg", "nl"),
            logo("/second.png", "en"),
            logo("/clear.png", "nl"),
          ],
        },
      });
    });
    const edit = async (): Promise<Edit> =>
      (await (await send("GET", `/v1/items/${id}/edit`)).json()) as Edit;
    const choose = async (body: object): Promise<Edit> => {
      const { revision } = await edit();
      const reply = await send("POST", `/v1/items/${id}/artwork`, {
        revision,
        kind: "logo",
        ...body,
      });
      expect(reply.status).toBe(200);
      return (await reply.json()) as Edit;
    };

    it("can be another one, none at all, and the automatic one again", async () => {
      const automatic = api(id).artwork.logo?.id;
      const listed = (await (
        await send("GET", `/v1/items/${id}/artwork-options?kind=logo`)
      ).json()) as { options: { path: string; previewUrl: string }[] };
      expect(listed.options.map((one) => one.path)).toEqual([
        "/clear.png",
        "/second.png",
        "/bare.png",
      ]);
      const preview = await send("GET", listed.options[1]?.previewUrl ?? "");
      expect(preview.headers.get("Content-Type")).toBe("image/png");

      const other = await choose({ source: "tmdb", path: "/second.png" });
      expect(other.item.artwork.logo).toMatchObject({ width: 600, height: 200 });
      expect(other.artwork["logo"]?.[0]).toMatchObject({ path: "/second.png", chosen: true });

      const none = await choose({ source: "none" });
      expect(none.withoutLogo).toBe(true);
      expect(none.item.artwork.logo).toBeNull();
      // What is listed is pictures only, for apps that expect a preview of each.
      expect(none.artwork["logo"]).toHaveLength(2);
      clock.now += 31 * DAY;
      await enricher().run();
      expect(api(id).artwork.logo).toBeNull();
      await choose({ source: "none" });

      const { revision } = await edit();
      const back = await send(
        "DELETE",
        `/v1/items/${id}/artwork?kind=logo&revision=${String(revision)}`,
      );
      expect((await back.json()) as Edit).toMatchObject({
        withoutLogo: false,
        item: { artwork: { logo: { id: automatic } } },
      });
    });

    it("can come from a device, and is not made from a film", async () => {
      const { revision } = await edit();
      const reply = await send(
        "POST",
        `/v1/items/${id}/artwork/upload?kind=logo&revision=${String(revision)}`,
        picture("1600x80", "png"),
      );
      expect(reply.status).toBe(200);
      const { item } = (await reply.json()) as Edit;
      expect(item.artwork.logo).toMatchObject({ width: 800, height: 40 });
      const served = await send("GET", `/v1/artwork/${item.artwork.logo?.id ?? ""}`);
      expect(served.headers.get("Content-Type")).toBe("image/png");
      for (const body of [
        { kind: "logo", source: "frame", positionMs: 0 },
        { kind: "poster", source: "none" },
        { kind: "logo", source: "tmdb", path: "/drawn.svg" },
      ]) {
        const refused = await send("POST", `/v1/items/${id}/artwork`, {
          revision: revision + 1,
          ...body,
        });
        expect(refused.status).toBe(400);
      }
    });

    it("is served small as a PNG, and to a kids device only with its title", async () => {
      const path = `/v1/artwork/${api(id).artwork.logo?.id ?? ""}`;
      const small = await send("GET", `${path}?w=200`);
      const bytes = Buffer.from(await small.arrayBuffer());
      expect(small.headers.get("Content-Type")).toBe("image/png");
      expect(small.headers.get("Cache-Control")).toContain("immutable");
      expect(bytes.readUInt32BE(16)).toBe(200);
      expect(bytes[25]).toBe(6);
      await makeKid([]);
      bind();
      expect((await send("GET", path, undefined, child)).status).toBe(404);
      await makeKid([id]);
      expect((await send("GET", path, undefined, child)).status).toBe(200);
    });

    it("goes with the match it came with", async () => {
      const { revision } = await edit();
      const reply = await send("DELETE", `/v1/items/${id}/match?revision=${String(revision)}`);
      expect((await reply.json()) as Edit).toMatchObject({
        item: { artwork: { logo: null }, tagline: null, renown: null },
      });
    });
  });
});

describe("the upgrade", () => {
  it("keeps pictures, starts the plays from what is known, and puts dates right", () => {
    const path = join(dir, "old.db");
    const old = new DatabaseSync(path);
    old.exec(
      "create table schema_migration (version integer primary key, name text not null, applied_at integer not null) strict",
    );
    for (const migration of migrations.filter((one) => one.version < 10)) {
      old.exec(migration.sql);
      old.exec(`insert into schema_migration values (${String(migration.version)}, 'x', 1)`);
    }
    const recent = Date.now() - DAY;
    old.exec(`
      insert into source (id, path, name, hint, created_at) values ('s', '/s', 'S', 'movies', 0);
      insert into asset (id, source_id, rel_path, size, mtime_ms, revision, state, first_seen_at, updated_at)
        values ('a', 's', 'a', 1, 1, '1', 'probed', 100, 0), ('b', 's', 'b', 1, 1, '1', 'probed', 900, 0);
      insert into item (id, kind, parent_id, ident_key, title, sort_title, added_at, revision) values
        ('film', 'movie', null, 'f', 'F', 'f', 900, 1), ('show', 'show', null, 's', 'S', 's', 900, 1),
        ('season', 'season', 'show', 'se', 'S', 's', 900, 1), ('ep', 'episode', 'season', 'e', 'E', 'e', 900, 1);
      insert into item_asset (item_id, asset_id) values ('film', 'a'), ('film', 'b'), ('ep', 'a');
      insert into artwork (id, item_id, kind, provider, remote_path, local_path, selected, locked, automatic)
        values ('p', 'film', 'poster', 'tmdb', '/p.jpg', '/x/p.jpg', 1, 1, 0);
      insert into profile (id, name, color, created_at, deleted_at) values ('v', 'V', 'red', 1, null);
      insert into progress (profile_id, item_id, position_ms, duration_ms, completed, revision, updated_at) values
        ('v', 'film', 1200000, 5400000, 0, 1, ${String(recent)}), ('v', 'ep', 0, 5400000, 1, 2, ${String(recent)});
    `);
    old.close();
    const upgraded = new Database(path);
    expect(upgraded.all("select id, kind, selected, locked, automatic from artwork")).toEqual([
      { id: "p", kind: "poster", selected: 1, locked: 1, automatic: 0 },
    ]);
    expect(upgraded.all("select id, added_at from item order by id")).toEqual([
      { id: "ep", added_at: 100 },
      { id: "film", added_at: 100 },
      { id: "season", added_at: 100 },
      { id: "show", added_at: 100 },
    ]);
    // Marked as watched by hand says nothing about watching.
    expect(upgraded.all("select item_id, counted from play")).toEqual([
      { item_id: "film", counted: 1 },
    ]);
    upgraded.run("delete from item where id = 'film'");
    expect(upgraded.all("select * from artwork union all select * from artwork")).toEqual([]);
    expect(upgraded.all("pragma foreign_key_check")).toEqual([]);
    upgraded.close();
  });

  it("does not mind a lower number that comes later", () => {
    const other = { version: 10, name: "x", sql: "alter table profile add column avatar text" };
    const path = join(dir, "order.db");
    new Database(path).close();
    const known = migrations.findIndex((one) => one.version === 10);
    if (known !== -1) return;
    const at = migrations.findIndex((one) => one.version === 11);
    migrations.splice(at, 0, other);
    try {
      for (const name of ["order.db", "fresh.db"]) {
        const opened = new Database(join(dir, name));
        expect(
          opened
            .all<{ version: number }>(
              "select version from schema_migration where version <= 11 order by version",
            )
            .slice(-2),
        ).toEqual([{ version: 10 }, { version: 11 }]);
        expect(opened.all("select avatar from profile")).toEqual([]);
        opened.close();
      }
    } finally {
      migrations.splice(at, 1);
    }
  });
});
