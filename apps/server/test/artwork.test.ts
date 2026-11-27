// SPDX-License-Identifier: MPL-2.0
import { mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { afterEach, beforeEach, expect, it } from "vitest";
import { FrameMaker } from "../src/artwork/frames.ts";
import { ArtworkStore, roundWidth } from "../src/artwork/serve.ts";
import { Devices } from "../src/auth/devices.ts";
import { Database } from "../src/db/database.ts";
import { createApp } from "../src/http/app.ts";
import { Catalogue } from "../src/library/catalogue.ts";
import { ItemReader, type ApiItem } from "../src/library/items.ts";
import { Scanner } from "../src/library/scanner.ts";
import { ProgressStore } from "../src/progress.ts";
import { makeTempDir, makeVideo, removeDir } from "./support/media.ts";

let dir: string;
let db: Database;

beforeEach(() => {
  dir = makeTempDir();
  db = new Database(join(dir, "lobby.db"));
});

afterEach(() => {
  db.close();
  removeDir(dir);
});

it("makes pictures for films, episodes and shows, serves them, and renews them", async () => {
  const movies = join(dir, "Movies");
  const series = join(dir, "Series");
  mkdirSync(movies);
  mkdirSync(join(series, "The Bear", "Season 1"), { recursive: true });
  makeVideo(join(movies, "Up (2009).mp4"));
  makeVideo(join(series, "The Bear", "Season 1", "The Bear S01E01.mp4"));
  const catalogue = new Catalogue(db);
  const scanner = new Scanner(db, catalogue, {
    stabilityMs: 0,
    probeConcurrency: 1,
    ffprobePath: "ffprobe",
  });
  scanner.syncSources([
    { path: movies, name: "Movies", hint: "movies" },
    { path: series, name: "Series", hint: "series" },
  ]);
  const scan = async (): Promise<void> => {
    await scanner.scanAll();
    await scanner.scanAll();
    await scanner.processQueue();
  };
  await scan();
  const frames = new FrameMaker(db, catalogue, { dir: join(dir, "artwork"), ffmpegPath: "ffmpeg" });
  const before = db.currentRevision();
  expect(await frames.run()).toBe(2);
  expect(db.currentRevision()).toBeGreaterThan(before);
  expect(await frames.run()).toBe(0);

  const reader = new ItemReader(db);
  const items = (): ApiItem[] => reader.page(null, 100).items;
  const find = (kind: string): ApiItem => {
    const item = items().find((each) => each.kind === kind);
    if (!item) throw new Error(`no ${kind}`);
    return item;
  };
  expect(find("movie").artwork.backdrop).not.toBeNull();
  expect(find("movie").artwork.poster).toBeNull();
  expect(find("episode").artwork.still).not.toBeNull();
  expect(find("show").artwork.backdrop).not.toBeNull();

  const devices = new Devices(db, "secret");
  const { token } = devices.createLocalManager("Mac");
  const app = createApp({
    db,
    devices,
    items: reader,
    progress: new ProgressStore(db),
    artwork: new ArtworkStore(db, join(dir, "cache"), "ffmpeg"),
    serverName: "Test",
    version: "0",
    isScanning: () => false,
  });
  const id = find("movie").artwork.backdrop?.id ?? "";
  const headers = { Authorization: `Bearer ${token}` };
  expect((await app.request(`/v1/artwork/${id}?w=400`)).status).toBe(401);
  const small = await app.request(`/v1/artwork/${id}?w=390`, { headers });
  expect(small.status).toBe(200);
  expect(small.headers.get("content-type")).toBe("image/jpeg");
  const bytes = Buffer.from(await small.arrayBuffer());
  expect(bytes.subarray(0, 2).toString("hex")).toBe("ffd8");
  const large = await app.request(`/v1/artwork/${id}?w=1600`, { headers });
  expect((await large.arrayBuffer()).byteLength).toBeGreaterThan(bytes.length);
  expect((await app.request("/v1/artwork/none?w=400", { headers })).status).toBe(404);
  expect((await app.request(`/v1/artwork/${id}?w=x`, { headers })).status).toBe(400);

  rmSync(join(movies, "Up (2009).mp4"));
  makeVideo(join(movies, "Up (2009).mp4"), { seconds: 3 });
  await scan();
  expect(await frames.run()).toBe(1);
  expect(find("movie").artwork.backdrop?.id).not.toBe(id);
});

it("rounds widths up to the offered ones", () => {
  expect([1, 200, 201, 900, 1300, 1700, 5000].map(roundWidth)).toEqual([
    200, 200, 400, 1280, 1600, 1920, 1920,
  ]);
});
