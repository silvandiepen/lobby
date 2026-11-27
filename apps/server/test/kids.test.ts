// SPDX-License-Identifier: MPL-2.0
import { execFileSync } from "node:child_process";
import {
  cpSync,
  mkdirSync,
  renameSync,
  rmSync,
  statSync,
  truncateSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import type { Hono } from "hono";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { ChosenArtwork } from "../src/artwork/chosen.ts";
import { LogoStore } from "../src/artwork/logos.ts";
import { ArtworkStore } from "../src/artwork/serve.ts";
import { Devices, type Device } from "../src/auth/devices.ts";
import type { RootConfig } from "../src/config.ts";
import { ConversionService } from "../src/conversion/index.ts";
import { MarkerService } from "../src/markers/service.ts";
import { Database } from "../src/db/database.ts";
import { migrations } from "../src/db/migrations.ts";
import { DeviceDownloads, type DeviceList } from "../src/devices-downloads/index.ts";
import { Enricher } from "../src/enrich/index.ts";
import { createApp, type AppDeps, type AppEnv } from "../src/http/app.ts";
import { createAssetLookup } from "../src/http/playback-assets.ts";
import { KIDS_ROUTES } from "../src/kids/guard.ts";
import { importsFor } from "./support/imports.ts";
import { settingsFor } from "./support/settings.ts";
import type { KidsSettings } from "../src/kids/limits.ts";
import { Catalogue } from "../src/library/catalogue.ts";
import type { CategoryView, FolderEntry } from "../src/library/categories.ts";
import { ItemReader, type ApiItem } from "../src/library/items.ts";
import { Scanner } from "../src/library/scanner.ts";
import { MusicLibrary } from "../src/music/index.ts";
import { OutsideEntrance } from "../src/outside/index.ts";
import { PlaybackService } from "../src/playback/index.ts";
import { RemoteHub, WakeService } from "../src/remote/index.ts";
import { ProgressStore, type Progress } from "../src/progress.ts";
import { makeMkv } from "./playback-support.ts";
import { makeAudio } from "./support/audio.ts";
import { makeTempDir, makeVideo, removeDir } from "./support/media.ts";
import { block, writePgs } from "./support/pgs.ts";

interface Reply<T> {
  status: number;
  body: T;
  text: string;
}
interface LibraryPage {
  items: ApiItem[];
  removed: string[];
  cursor: string;
  more: boolean;
  reset: boolean;
}
interface ProfileReply {
  id: string;
  name: string;
  color: string;
  avatar: string | null;
  kids: KidsSettings | null;
  subtitles?: unknown;
  playback?: unknown;
}

let dir: string;
let db: Database;
let scanner: Scanner;
let playback: PlaybackService;
let downloads: DeviceDownloads;
let conversion: ConversionService;
let music: MusicLibrary;
let devices: Devices;
let app: Hono<AppEnv>;
let deps: AppDeps;
let manager: { id: string; token: string };
let child: { id: string; token: string };
let viewer: { id: string; token: string };
let kid: string;
let parent: string;
let all: ApiItem[];

const nothing: KidsSettings = {
  allowedGroupIds: [],
  allowedCategoryIds: [],
  allowedItemIds: [],
  blockedItemIds: [],
  blockedCategoryIds: [],
};

async function call<T = { error: { code: string } }>(
  token: string | null,
  method: string,
  path: string,
  body?: unknown,
  headers: Record<string, string> = {},
): Promise<Reply<T>> {
  const response = await app.request(path, {
    method,
    headers: { ...headers, ...(token === null ? {} : { Authorization: `Bearer ${token}` }) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const text = await response.text();
  const json = (response.headers.get("Content-Type") ?? "").includes("json") && text !== "";
  return { status: response.status, body: (json ? JSON.parse(text) : null) as T, text };
}

function pair(name: string): { id: string; token: string } {
  const waiting = devices.startPairing(name, "ipados");
  devices.approve(waiting.code, "viewer", "cli");
  const done = devices.collect(waiting.id, waiting.pollSecret);
  if (done.status !== "approved") throw new Error("not paired");
  return { id: done.device.id, token: done.token };
}

async function library(token: string, cursor = "", limit = 1000): Promise<LibraryPage> {
  const reply = await call<LibraryPage>(
    token,
    "GET",
    `/v1/library?limit=${String(limit)}&cursor=${cursor}`,
  );
  expect(reply.status).toBe(200);
  return reply.body;
}

/** What an app would hold after following the library from `cursor`. */
class Copy {
  readonly items = new Map<string, ApiItem>();
  cursor = "";
  async refresh(token: string, limit = 2): Promise<string[]> {
    const removed: string[] = [];
    let page: LibraryPage;
    do {
      page = await library(token, this.cursor, limit);
      expect(page.reset).toBe(false);
      for (const id of page.removed) this.items.delete(id);
      for (const item of page.items) this.items.set(item.id, item);
      removed.push(...page.removed);
      this.cursor = page.cursor;
    } while (page.more);
    return removed;
  }
  titles(): string[] {
    return [...this.items.values()]
      .filter((item) => item.parentId === null)
      .map((item) => item.title)
      .sort();
  }
}

async function limit(kids: Partial<KidsSettings> | null): Promise<void> {
  const reply = await call(manager.token, "PATCH", `/v1/profiles/${kid}`, {
    kids: kids === null ? null : { ...nothing, ...kids },
  });
  expect(reply.status).toBe(200);
}

async function bind(profileId: string | null, device = child): Promise<Reply<Device>> {
  return call<Device>(manager.token, "PATCH", `/v1/devices/${device.id}`, {
    kidsProfileId: profileId,
  });
}

function item(title: string, kind?: string): ApiItem {
  const found = all.find((one) => one.title === title && (!kind || one.kind === kind));
  if (!found) throw new Error(`no ${title} in ${all.map((one) => one.title).join(", ")}`);
  return found;
}
const asset = (one: ApiItem): string => one.files[0]?.assetId ?? "";
async function setup(): Promise<CategoryView & { folders: FolderEntry[] }> {
  return (
    await call<CategoryView & { folders: FolderEntry[] }>(
      manager.token,
      "GET",
      "/v1/categories/edit",
    )
  ).body;
}
async function category(name: string): Promise<string> {
  const found = (await setup()).groups.flatMap((g) => g.entries).find((one) => one.name === name);
  if (!found) throw new Error(`no category ${name}`);
  return found.id;
}
async function group(name: string | null): Promise<string> {
  const found = (await setup()).groups.find((one) => one.name === name);
  if (!found) throw new Error(`no group ${name ?? "main"}`);
  return found.id;
}
async function scan(): Promise<void> {
  await scanner.scanAll();
  await scanner.processQueue();
  all = (await library(manager.token)).items;
}

let roots: RootConfig[];
/** The household's files, made once. Every test works on its own copy. */
let files: string;

beforeAll(() => {
  files = makeTempDir("lobby-kids-files-");
  makeVideo(join(files, "Cartoons/Balloon (2009)/Balloon (2009).mp4"), { seed: 1 });
  makeVideo(join(files, "Cartoons/Balloon (2009)/Trailers/Balloon trailer.mp4"), { seed: 2 });
  makeVideo(join(files, "Cartoons/Robot (2008)/Robot (2008).mp4"), { seed: 3 });
  makeVideo(join(files, "Late/Scary (1999)/Scary (1999).mp4"), { seed: 4 });
  makeVideo(join(files, "Films/Garden (2001)/Garden (2001).mp4"), { seed: 5 });
  makeVideo(join(files, "Series/Zoo/Season 1/Zoo S01E01.mp4"), { seed: 6 });
  makeVideo(join(files, "Series/Zoo/Season 1/Zoo S01E02-E03.mp4"), { seed: 7 });
  makeVideo(join(files, "Series/Zoo/Season 1/Zoo S01E04.mp4"), { seed: 8 });
}, 60_000);
afterAll(() => {
  removeDir(files);
});

beforeEach(async () => {
  dir = makeTempDir("lobby-kids-");
  db = new Database(join(dir, "lobby.db"));
  const catalogue = new Catalogue(db);
  scanner = new Scanner(db, catalogue, {
    stabilityMs: 0,
    probeConcurrency: 2,
    ffprobePath: "ffprobe",
    volumeOf: () => Promise.resolve(1),
  });
  roots = [
    { path: join(dir, "Cartoons"), name: "Cartoons", hint: "movies", group: "Small" },
    { path: join(dir, "Late"), name: "Late", hint: "movies", group: "Grown-ups" },
    { path: join(dir, "Films"), name: "Films", hint: "movies" },
    { path: join(dir, "Series"), name: "Series", hint: "series" },
  ];
  for (const root of roots) mkdirSync(root.path);
  scanner.syncSources(roots);
  cpSync(files, dir, { recursive: true });

  playback = new PlaybackService({ cacheDir: join(dir, "cache"), minFreeBytes: 0 });
  await playback.start();
  devices = new Devices(db, "secret");
  downloads = new DeviceDownloads({ db, playback, lookupAsset: createAssetLookup(db) });
  conversion = new ConversionService({ db, catalogue, dir: null });
  await conversion.start();
  mkdirSync(join(dir, "Music"));
  music = new MusicLibrary(db, {
    dataDir: join(dir, "data"),
    music: {
      roots: [{ path: join(dir, "Music"), name: "Music", hint: "music" }],
      cacheDir: join(dir, "music-cache"),
      maxCacheGb: 1,
      minFreeGb: 0,
    },
    stabilityMs: 0,
    rescanMinutes: 60,
    ffmpegPath: "ffmpeg",
    ffprobePath: "ffprobe",
  });
  await music.copies.start();
  deps = {
    db,
    devices,
    items: new ItemReader(db),
    progress: new ProgressStore(db),
    playback,
    downloads,
    conversion,
    markers: new MarkerService({ db, catalogue, dir: join(dir, "markers") }),
    music,
    artwork: new ArtworkStore(db, join(dir, "art-cache"), "ffmpeg"),
    logos: new LogoStore(db, join(dir, "logos")),
    edit: {
      catalogue,
      enricher: new Enricher({
        db,
        catalogue,
        key: null,
        language: "en-US",
        artworkDir: join(dir, "artwork"),
      }),
      chosen: new ChosenArtwork(db, {
        dir: join(dir, "chosen"),
        ffmpegPath: "ffmpeg",
        ffprobePath: "ffprobe",
      }),
    },
    serverName: "Test",
    version: "0",
    isScanning: () => false,
  };
  deps.outside = new OutsideEntrance({ db, devices, name: null });
  deps.remote = new RemoteHub({ db, devices });
  // Not set up (no remote.wake), so its routes are there and no helper runs.
  deps.wake = new WakeService({ db, devices, config: () => null });
  deps.settings = settingsFor(db, devices, dir);
  deps.imports = importsFor(db, dir);
  app = createApp(deps);
  const made = devices.createLocalManager("Mac");
  manager = { id: made.device.id, token: made.token };
  child = pair("Tablet");
  viewer = pair("TV");
  const profile = async (body: unknown): Promise<string> =>
    (await call<ProfileReply>(manager.token, "POST", "/v1/profiles", body)).body.id;
  kid = await profile({ name: "Small one", kids: nothing });
  parent = await profile({ name: "Tall one" });
  await scan();
}, 60_000);

afterEach(async () => {
  await downloads.stop();
  await conversion.stop();
  await music.stop();
  await playback.close();
  db.close();
  removeDir(dir);
});

describe("a decision for every route", () => {
  const registered = (): Set<string> =>
    new Set(
      app.routes
        .filter((route) => route.method !== "ALL")
        .map((route) => `${route.method === "HEAD" ? "GET" : route.method} ${route.path}`),
    );

  it("is there, and none is left over", () => {
    expect([...registered()].filter((key) => KIDS_ROUTES[key] === undefined)).toEqual([]);
    expect(Object.keys(KIDS_ROUTES).filter((key) => !registered().has(key))).toEqual([]);
  });

  it("refuses a route that has none", async () => {
    app = createApp(deps);
    // Added the way a new feature would be, without a decision.
    app.get("/v1/something-new", (c) => c.json({ secret: true }));
    await limit({ allowedGroupIds: [await group("Small")] });
    await bind(kid);
    expect((await call(child.token, "GET", "/v1/something-new")).status).toBe(404);
    expect((await call(viewer.token, "GET", "/v1/something-new")).status).toBe(200);
  });

  it("answers 404 wherever the decision is no", async () => {
    await limit({ allowedItemIds: all.map((one) => one.id) });
    await bind(kid);
    const film = item("Balloon");
    const closed = Object.entries(KIDS_ROUTES).filter(([, decision]) => decision === "none");
    expect(closed.length).toBeGreaterThan(60);
    for (const [key] of closed) {
      const [method = "", pattern = ""] = key.split(" ");
      const path = pattern
        .replace(":profile", kid)
        .replace("devices/:id", `devices/${child.id}`)
        .replace("profiles/:id", `profiles/${kid}`)
        .replace(/:[a-zA-Z]+/g, film.id);
      const reply = await call(
        child.token,
        method,
        path,
        ["GET", "DELETE"].includes(method) ? undefined : { kidsProfileId: null, kids: null },
      );
      expect([key, reply.status]).toEqual([key, 404]);
    }
    const me = await call<{ device: Device }>(child.token, "GET", "/v1/me");
    expect(me.body.device.kidsProfileId).toBe(kid);
  });

  it("names every title route a decision needs to be tested for", async () => {
    execFileSync("ffmpeg", [
      ..."-v error -f lavfi -i color=c=red:size=300x450 -frames:v 1 -update 1".split(" "),
      join(dir, "art.jpg"),
    ]);
    const art = (one: ApiItem): string => `art-${one.id.slice(0, 8)}`;
    for (const title of ["Balloon", "Scary"]) {
      db.run(
        `insert into artwork (id, item_id, kind, provider, local_path, width, height, selected)
         values (?, ?, 'poster', 'frame', ?, 300, 450, 1)`,
        [art(item(title)), item(title).id, join(dir, "art.jpg")],
      );
    }
    // One subtitle and one prepared copy for each, so a 404 is about the limits alone.
    for (const [folder, name] of [
      ["Cartoons", "Boat (2010)"],
      ["Late", "Blood (2010)"],
    ] as const) {
      makeMkv(join(dir, folder, `${name}.mkv`));
      writeFileSync(join(dir, folder, `${name}.srt`), "1\n00:00:00,000 --> 00:00:00,500\nHello\n");
      writePgs(join(dir, folder, `${name}.sup`), [
        { startMs: 0, endMs: 500, picture: block(100, 20) },
      ]);
    }
    await scan();
    const prepare = async (id: string): Promise<string> => {
      for (let attempt = 0; attempt < 200; attempt += 1) {
        const reply = await call<{ state: string; revision: string }>(
          manager.token,
          "POST",
          `/v1/assets/${id}/playback`,
        );
        if (reply.body.state === "ready") return reply.body.revision;
        await new Promise((done) => setTimeout(done, 50));
      }
      throw new Error("never ready");
    };
    await limit({ allowedCategoryIds: [await category("Cartoons")] });
    await bind(kid);

    const requests = async (
      film: ApiItem,
      mkv: ApiItem,
      profile: string,
    ): Promise<Record<string, [string, string, unknown?]>> => {
      const revision = await prepare(asset(mkv));
      const prepared = `/v1/assets/${asset(mkv)}/prepared/${revision}`;
      const subtitle = mkv.files[0]?.subtitles.find((one) => one.isText)?.id ?? "none";
      const pictures =
        mkv.files[0]?.subtitles.find((one) => one.codec === "hdmv_pgs_subtitle")?.id ?? "none";
      return {
        "GET /v1/items/:id": ["GET", `/v1/items/${film.id}`],
        "GET /v1/artwork/:id": ["GET", `/v1/artwork/${art(film)}`],
        "GET /v1/assets/:id/content": ["GET", `/v1/assets/${asset(film)}/content`],
        "POST /v1/assets/:id/playback": ["POST", `/v1/assets/${asset(film)}/playback`],
        "POST /v1/assets/:id/airplay": ["POST", `/v1/assets/${asset(film)}/airplay`, {}],
        "GET /v1/assets/:id/prepared/:revision/master.m3u8": ["GET", `${prepared}/master.m3u8`],
        "GET /v1/assets/:id/prepared/:revision/:file": ["GET", `${prepared}/media.mp4`],
        "GET /v1/assets/:id/prepared/:revision/subtitles/:playlist{[A-Za-z0-9_-]+\\.m3u8}": [
          "GET",
          `${prepared}/subtitles/${subtitle}.m3u8`,
        ],
        "GET /v1/assets/:id/subtitles/:subtitle{[A-Za-z0-9_-]+\\.vtt}": [
          "GET",
          `/v1/assets/${asset(mkv)}/subtitles/${subtitle}.vtt`,
        ],
        "GET /v1/assets/:id/subtitles/:subtitle{[A-Za-z0-9_-]+\\.json}": [
          "GET",
          `/v1/assets/${asset(mkv)}/subtitles/${pictures}.json`,
        ],
        "GET /v1/profiles/:id/progress": ["GET", `/v1/profiles/${profile}/progress`],
        "PUT /v1/profiles/:id/avatar": ["PUT", `/v1/profiles/${profile}/avatar`, { avatar: "fox" }],
        "PUT /v1/profiles/:id/subtitles": [
          "PUT",
          `/v1/profiles/${profile}/subtitles`,
          { languages: ["nl"] },
        ],
        "GET /v1/profiles/:id/subtitle-offsets/:item": [
          "GET",
          `/v1/profiles/${profile}/subtitle-offsets/${film.id}`,
        ],
        "PUT /v1/profiles/:id/subtitle-offsets/:item": [
          "PUT",
          `/v1/profiles/${profile}/subtitle-offsets/${film.id}`,
          { offsetMs: 500 },
        ],
        "PUT /v1/profiles/:id/progress/:item": [
          "PUT",
          `/v1/profiles/${profile}/progress/${film.id}`,
          {
            opId: `op-${film.id}-${profile}`,
            baseRevision: null,
            positionMs: 5,
            durationMs: 1000,
            completed: false,
            updatedAt: 1,
          },
        ],
      };
    };
    const good = await requests(item("Balloon"), item("Boat"), kid);
    const bad = await requests(item("Scary"), item("Blood"), parent);
    const named = ["item", "asset", "artwork", "viewer", "viewer_item"];
    expect(Object.keys(good).sort()).toEqual(
      Object.entries(KIDS_ROUTES)
        .filter(([, decision]) => named.includes(decision))
        .map(([key]) => key)
        .sort(),
    );
    for (const [key, [method, path, body]] of Object.entries(good)) {
      expect([key, (await call(child.token, method, path, body)).status]).toEqual([key, 200]);
    }
    for (const [key, [method, path, body]] of Object.entries(bad)) {
      expect([key, (await call(child.token, method, path, body)).status]).toEqual([key, 404]);
      if (method === "GET") {
        const head = await call(child.token, "HEAD", path);
        expect([key, head.status]).toEqual([key, 404]);
      }
      // The same request is fine from a device without limits.
      expect([key, (await call(viewer.token, method, path, body)).status]).toEqual([key, 200]);
    }
    // Its own viewer, and a title that is not allowed.
    const put = bad["PUT /v1/profiles/:id/progress/:item"]?.[2];
    const scary = `/v1/profiles/${kid}/progress/${item("Scary").id}`;
    expect((await call(child.token, "PUT", scary, put)).status).toBe(404);
    // A URL that worked a moment ago stops working.
    await limit({ blockedItemIds: all.filter((one) => one.parentId === null).map((o) => o.id) });
    for (const [key, [method, path, body]] of Object.entries(good)) {
      // The viewer's own, whatever may be watched.
      if (KIDS_ROUTES[key] === "viewer") continue;
      expect([key, (await call(child.token, method, path, body)).status]).toEqual([key, 404]);
    }
  }, 60_000);

  it("is not fooled by an encoded id", async () => {
    await limit({ allowedCategoryIds: [await category("Cartoons")] });
    await bind(kid);
    const id = item("Scary").id;
    const encoded = `%${id.charCodeAt(0).toString(16)}${id.slice(1)}`;
    const twice = encoded.replace("%", "%25");
    for (const one of [encoded, twice, `${item("Balloon").id}/../${id}`]) {
      expect((await call(child.token, "GET", `/v1/items/${one}`)).status).toBe(404);
    }
  });
});

describe("what a kids viewer may see", () => {
  const seen = async (): Promise<string[]> => {
    const copy = new Copy();
    await copy.refresh(child.token);
    return copy.titles();
  };
  beforeEach(async () => {
    expect((await bind(kid)).status).toBe(200);
  });

  it("is nothing when nothing is allowed", async () => {
    expect((await library(child.token)).items).toEqual([]);
    const categories = await call<CategoryView>(child.token, "GET", "/v1/categories");
    expect(categories.body.groups.map((one) => [one.name, one.entries])).toEqual([[null, []]]);
    expect(categories.body.logos).toEqual({});
  });

  it("follows groups, categories, titles and blocks", async () => {
    await limit({ allowedGroupIds: [await group("Small")] });
    expect(await seen()).toEqual(["Balloon", "Robot"]);
    await limit({ allowedCategoryIds: [await category("Late")] });
    expect(await seen()).toEqual(["Scary"]);
    await limit({
      allowedGroupIds: [await group("Small")],
      allowedItemIds: [item("Garden").id, item("Robot").id],
      blockedItemIds: [item("Robot").id],
    });
    expect(await seen()).toEqual(["Balloon", "Garden"]);
    const names = (await call<CategoryView>(child.token, "GET", "/v1/categories")).body.groups;
    expect(names.map((one) => [one.name, one.categories])).toEqual([
      [null, ["Films"]],
      ["Small", ["Cartoons"]],
    ]);
    await limit({ allowedGroupIds: [await group(null)] });
    expect(await seen()).toEqual(["Garden", "Zoo"]);
  });

  it("takes everything under a film along, allowed or blocked", async () => {
    const film = item("Balloon");
    const trailer = all.find((one) => one.parentId === film.id);
    if (!trailer) throw new Error("no trailer");
    await limit({ allowedItemIds: [film.id] });
    expect((await call(child.token, "GET", `/v1/items/${trailer.id}`)).status).toBe(200);
    const content = `/v1/assets/${asset(trailer)}/content`;
    expect((await call(child.token, "GET", content)).status).toBe(200);
    await limit({ allowedGroupIds: [await group("Small")], blockedItemIds: [film.id] });
    expect((await call(child.token, "GET", `/v1/items/${trailer.id}`)).status).toBe(404);
    expect((await call(child.token, "GET", content)).status).toBe(404);
  });

  it("shows a show for one episode, without the others", async () => {
    const show = item("Zoo", "show");
    const episodes = all
      .filter((one) => one.kind === "episode")
      .sort((a, b) => (a.episodeNumber ?? 0) - (b.episodeNumber ?? 0));
    await limit({ allowedItemIds: [episodes[0]?.id ?? ""] });
    const ids = (await library(child.token)).items.map((one) => one.kind).sort();
    expect(ids).toEqual(["episode", "season", "show"]);
    const read = await call<{ item: ApiItem; children: ApiItem[] }>(
      child.token,
      "GET",
      `/v1/items/${episodes[0]?.parentId ?? ""}`,
    );
    expect(read.body.children.map((one) => one.id)).toEqual([episodes[0]?.id]);
    // A blocked episode takes the file it shares along: the file holds it.
    await limit({ allowedItemIds: [show.id], blockedItemIds: [episodes[2]?.id ?? ""] });
    const left = (await library(child.token)).items.filter((one) => one.kind === "episode");
    expect(left.map((one) => one.episodeNumber).sort()).toEqual([1, 2, 4]);
    expect(left.find((one) => one.episodeNumber === 2)).toMatchObject({
      files: [],
      available: false,
    });
    const shared = `/v1/assets/${asset(episodes[1] ?? show)}/content`;
    expect((await call(child.token, "GET", shared)).status).toBe(404);
    // With every episode blocked the show is not an empty shell.
    await limit({ allowedItemIds: [show.id], blockedItemIds: episodes.map((one) => one.id) });
    expect((await library(child.token)).items).toEqual([]);
  });

  it("keeps a title that is being read again in its own category", async () => {
    await limit({ allowedGroupIds: [await group(null)] });
    db.run("update asset set state = 'discovered' where id = ?", [asset(item("Scary"))]);
    db.nextRevision();
    expect(await seen()).toEqual(["Garden", "Zoo"]);
  });

  it("serves only the logos of what it shows", async () => {
    for (const [id, name] of [
      ["logo-small", "Cartoons"],
      ["logo-late", "Late"],
    ] as const) {
      db.run("insert into logo (id, data, width, height) values (?, ?, 1, 1)", [
        id,
        Buffer.from("png"),
      ]);
      db.run("update category set logo_id = ? where name = ?", [id, name]);
    }
    await limit({ allowedCategoryIds: [await category("Cartoons")] });
    expect((await call(child.token, "GET", "/v1/logos/logo-small")).status).toBe(200);
    expect((await call(child.token, "GET", "/v1/logos/logo-late")).status).toBe(404);
    expect((await call(viewer.token, "GET", "/v1/logos/logo-late")).status).toBe(200);
    const reply = await call<CategoryView>(child.token, "GET", "/v1/categories");
    expect(Object.keys(reply.body.logos)).toEqual(["Cartoons"]);
  });
});

describe("viewers and devices", () => {
  it("keeps kids limits with a viewer and refuses malformed ones", async () => {
    const list = await call<{ profiles: ProfileReply[] }>(manager.token, "GET", "/v1/profiles");
    expect(list.body.profiles.map((one) => one.kids)).toEqual([nothing, null]);
    const path = `/v1/profiles/${kid}`;
    for (const kids of [1, [], {}, { ...nothing, blockedItemIds: [3] }, "x"]) {
      expect((await call(manager.token, "PATCH", path, { kids })).status).toBe(400);
    }
    const changed = await call<ProfileReply>(manager.token, "PATCH", path, {
      kids: { ...nothing, allowedItemIds: ["a", "a"] },
    });
    expect(changed.body.kids).toEqual({ ...nothing, allowedItemIds: ["a"] });
    const renamed = await call<ProfileReply>(manager.token, "PATCH", path, { name: "New" });
    expect(renamed.body.kids?.allowedItemIds).toEqual(["a"]);
    expect((await call(viewer.token, "PATCH", path, { kids: null })).status).toBe(403);
  });

  it("lets a child's device change its own viewer's picture, and nothing else", async () => {
    await bind(kid);
    const own = `/v1/profiles/${kid}/avatar`;
    const changed = await call<ProfileReply>(child.token, "PUT", own, {
      avatar: "panda",
      name: "Boss",
      color: "pink",
      kids: null,
    });
    expect(changed.status).toBe(200);
    const list = await call<{ profiles: ProfileReply[] }>(manager.token, "GET", "/v1/profiles");
    const before = {
      id: kid,
      name: "Small one",
      color: "red",
      kids: nothing,
      // Off, forced subtitles on, as for every viewer.
      subtitles: { languages: [], forced: true, size: "medium", background: true },
      // As for every viewer, but "Still watching?" after two episodes.
      playback: {
        filmSuggestions: true,
        filmAutoplay: false,
        episodeAutoplay: true,
        countdownSeconds: 10,
        startAtCredits: true,
        stillWatchingEpisodes: 2,
        stillWatchingHours: 0,
      },
      skipping: { intro: "show", credits: "show" },
    };
    expect(list.body.profiles[0]).toEqual({ ...before, avatar: "panda" });
    expect(changed.body).toEqual({ ...before, avatar: "panda" });
    const me = await call<{ device: Device }>(child.token, "GET", "/v1/me");
    expect(me.body.device.kidsProfileId).toBe(kid);

    for (const other of [parent, "nobody", parent.replace("-", "%2D")]) {
      const reply = await call(child.token, "PUT", `/v1/profiles/${other}/avatar`, {
        avatar: "fox",
      });
      expect([other, reply.status]).toEqual([other, 404]);
    }
    const patch = await call(child.token, "PATCH", `/v1/profiles/${kid}`, { avatar: "fox" });
    expect(patch.status).toBe(404);
    const after = await call<{ profiles: ProfileReply[] }>(manager.token, "GET", "/v1/profiles");
    expect(after.body.profiles.map((one) => one.avatar)).toEqual(["panda", null]);

    await bind(null);
    expect((await call(child.token, "PUT", own, { avatar: null })).status).toBe(200);
  });

  it("leaves what happens at intros to a grown-up, not to the child's device", async () => {
    await bind(kid);
    const own = `/v1/profiles/${kid}/skipping`;
    expect((await call(child.token, "PUT", own, { intro: "off" })).status).toBe(404);
    // A grown-up, from a device that is not the child's: their own phone, or the manager's page.
    const set = await call<ProfileReply & { skipping: unknown }>(viewer.token, "PUT", own, {
      intro: "skip",
    });
    expect(set.status).toBe(200);
    expect(set.body.skipping).toEqual({ intro: "skip", credits: "show" });
    const patched = await call<ProfileReply & { skipping: unknown }>(
      manager.token,
      "PATCH",
      `/v1/profiles/${kid}`,
      { skipping: { credits: "off" } },
    );
    expect(patched.body.skipping).toEqual({ intro: "skip", credits: "off" });
    // The child's device reads it, to act on it.
    const seen = await call<{ profiles: (ProfileReply & { skipping: unknown })[] }>(
      child.token,
      "GET",
      "/v1/profiles",
    );
    expect(seen.body.profiles.map((one) => one.skipping)).toEqual([
      { intro: "skip", credits: "off" },
    ]);
  });

  it("lets a child's device choose its own viewer's subtitles, and no one else's", async () => {
    await bind(kid);
    const own = `/v1/profiles/${kid}/subtitles`;
    const changed = await call<ProfileReply>(child.token, "PUT", own, {
      languages: ["nl"],
      forced: false,
      name: "Boss",
    });
    expect(changed.status).toBe(200);
    expect(changed.body).toMatchObject({
      name: "Small one",
      kids: nothing,
      subtitles: { languages: ["nl"], forced: false, size: "medium", background: true },
    });
    for (const other of [parent, "nobody"]) {
      const reply = await call(child.token, "PUT", `/v1/profiles/${other}/subtitles`, {
        languages: ["en"],
      });
      expect([other, reply.status]).toEqual([other, 404]);
    }
    const parents = await call<{ profiles: ProfileReply[] }>(manager.token, "GET", "/v1/profiles");
    expect(parents.body.profiles.find((one) => one.id === parent)).toMatchObject({
      subtitles: { languages: [] },
    });
  });

  it("leaves what happens at the end of a child's film to the grown-ups", async () => {
    await bind(kid);
    const own = `/v1/profiles/${kid}/playback`;
    expect((await call(child.token, "PUT", own, { filmAutoplay: true })).status).toBe(404);
    // An ordinary device that watches as the child may not either; a manager may.
    expect((await call(viewer.token, "PUT", own, { filmAutoplay: true })).status).toBe(403);
    const chosen = await call<ProfileReply>(manager.token, "PUT", own, {
      stillWatchingEpisodes: 0,
    });
    expect(chosen.body).toMatchObject({
      playback: { stillWatchingEpisodes: 0, filmAutoplay: false },
    });
    const seen = await call<{ profiles: ProfileReply[] }>(child.token, "GET", "/v1/profiles");
    expect(seen.body.profiles[0]).toMatchObject({ playback: { stillWatchingEpisodes: 0 } });
  });

  it("binds a device, only for a manager, and never a manager's", async () => {
    expect((await bind(kid, manager)).status).toBe(409);
    expect((await bind(parent)).status).toBe(409);
    expect((await bind("nobody")).status).toBe(404);
    expect((await bind(kid, { id: "nothing", token: "" })).status).toBe(404);
    const path = `/v1/devices/${child.id}`;
    expect((await call(manager.token, "PATCH", path, {})).status).toBe(400);
    expect((await call(child.token, "PATCH", path, { kidsProfileId: kid })).status).toBe(403);
    expect((await bind(kid)).body).toMatchObject({ id: child.id, kidsProfileId: kid });
    expect((await call(child.token, "PATCH", path, { kidsProfileId: null })).status).toBe(404);
    const list = await call<{ devices: Device[] }>(manager.token, "GET", "/v1/devices");
    expect(list.body.devices.find((one) => one.id === child.id)?.kidsProfileId).toBe(kid);
    const own = await call<{ profiles: ProfileReply[] }>(child.token, "GET", "/v1/profiles");
    expect(own.body.profiles.map((one) => one.id)).toEqual([kid]);
    for (const token of [viewer.token, manager.token]) {
      const me = await call<{ device: Device }>(token, "GET", "/v1/me");
      expect(me.body.device.kidsProfileId).toBeNull();
    }
    expect((await bind(null)).body.kidsProfileId).toBeNull();
    expect((await library(child.token)).items.length).toBe(all.length);
  });

  it("never gives a device everything because its viewer went away", async () => {
    await limit({ allowedGroupIds: [await group("Small")] });
    await bind(kid);
    const copy = new Copy();
    await copy.refresh(child.token);
    const path = `/v1/profiles/${kid}`;
    expect((await call(manager.token, "DELETE", path)).status).toBe(409);
    expect((await call(manager.token, "PATCH", path, { kids: null })).status).toBe(409);
    // Even when it happens some other way: nothing, not everything.
    db.run("update profile set kids_json = null where id = ?", [kid]);
    expect((await library(child.token)).items).toEqual([]);
    const content = `/v1/assets/${asset(item("Balloon"))}/content`;
    expect((await call(child.token, "GET", content)).status).toBe(404);
    await copy.refresh(child.token);
    expect(copy.titles()).toEqual([]);
    db.run("update profile set deleted_at = 1 where id = ?", [kid]);
    expect((await library(child.token)).items).toEqual([]);
    const own = await call<{ profiles: ProfileReply[] }>(child.token, "GET", "/v1/profiles");
    expect(own.body.profiles).toEqual([]);
    db.run("update profile set deleted_at = null, kids_json = ? where id = ?", [
      JSON.stringify(nothing),
      kid,
    ]);
    await bind(null);
    expect((await call(manager.token, "DELETE", path)).status).toBe(204);
  });
});

describe("a refresh of what the device already has", () => {
  it("takes away what a device bound meanwhile may not have, in small pages too", async () => {
    const copy = new Copy();
    await copy.refresh(child.token, 1000);
    expect(copy.items.size).toBe(all.length);
    await limit({ allowedGroupIds: [await group("Small")] });
    await bind(kid);
    const removed = await copy.refresh(child.token);
    expect(copy.titles()).toEqual(["Balloon", "Robot"]);
    expect(removed).toContain(item("Scary").id);
    expect(await copy.refresh(child.token)).toEqual([]);
    // And gives it back when the limits end.
    await bind(null);
    await copy.refresh(child.token);
    expect(copy.items.size).toBe(all.length);
  });

  it("goes from one kids viewer to another", async () => {
    await limit({ allowedGroupIds: [await group("Small")] });
    await bind(kid);
    const copy = new Copy();
    await copy.refresh(child.token);
    const second = await call<ProfileReply>(manager.token, "POST", "/v1/profiles", {
      name: "Second",
      kids: { ...nothing, allowedItemIds: [item("Garden").id] },
    });
    await bind(second.body.id);
    await copy.refresh(child.token);
    expect(copy.titles()).toEqual(["Garden"]);
  });

  it("follows the limits, the categories, the folders and the titles", async () => {
    const cartoons = await category("Cartoons");
    await limit({ allowedCategoryIds: [cartoons] });
    await bind(kid);
    const copy = new Copy();
    await copy.refresh(child.token);
    const after = async (): Promise<string[]> => {
      await copy.refresh(child.token);
      return copy.titles();
    };
    expect(await after()).toEqual(["Balloon", "Robot"]);

    // Only the limits.
    await limit({ allowedCategoryIds: [cartoons], blockedItemIds: [item("Robot").id] });
    expect(await after()).toEqual(["Balloon"]);
    await limit({ allowedCategoryIds: [cartoons], allowedItemIds: [item("Garden").id] });
    expect(await after()).toEqual(["Balloon", "Garden", "Robot"]);
    await limit({ allowedCategoryIds: [cartoons] });

    // A title's category.
    const edit = async (title: string, ids: string[]): Promise<void> => {
      const path = `/v1/items/${item(title).id}`;
      const { revision } = (await call<{ revision: number }>(manager.token, "GET", `${path}/edit`))
        .body;
      const reply = await call(manager.token, "PATCH", path, {
        revision,
        set: { categoryIds: ids },
      });
      expect(reply.status).toBe(200);
    };
    await edit("Robot", [await category("Late")]);
    await edit("Scary", [cartoons]);
    expect(await after()).toEqual(["Balloon", "Scary"]);

    // A category moved between groups.
    await limit({ allowedGroupIds: [await group("Small")] });
    expect(await after()).toEqual(["Balloon", "Scary"]);
    let { revision } = await setup();
    let reply = await call(manager.token, "PATCH", `/v1/categories/${cartoons}`, {
      revision,
      groupId: await group("Grown-ups"),
    });
    expect(reply.status).toBe(200);
    expect(await after()).toEqual([]);

    // A folder given to another category.
    await limit({ allowedCategoryIds: [await category("Films")] });
    const folder = (await setup()).folders.find((one) => one.name === "Cartoons");
    ({ revision } = await setup());
    reply = await call(manager.token, "PUT", `/v1/categories/folders/${folder?.id ?? ""}`, {
      revision,
      categoryId: await category("Films"),
    });
    expect(reply.status).toBe(200);
    expect(await after()).toEqual(["Balloon", "Garden"]);

    // A file that is gone.
    rmSync(join(dir, "Films/Garden (2001)"), { recursive: true });
    new Catalogue(db).removeAsset(asset(item("Garden")));
    expect(await after()).toEqual(["Balloon"]);
  });

  it("keeps a title blocked when its file is renamed, or leaves and comes back", async () => {
    await limit({
      allowedGroupIds: [await group("Small")],
      blockedItemIds: [item("Robot").id, item("Balloon").id],
    });
    await bind(kid);
    renameSync(join(dir, "Cartoons/Robot (2008)"), join(dir, "Cartoons/Machine (2008)"));
    renameSync(
      join(dir, "Cartoons/Machine (2008)/Robot (2008).mp4"),
      join(dir, "Cartoons/Machine (2008)/Machine (2008).mp4"),
    );
    const old = item("Balloon");
    new Catalogue(db).removeAsset(asset(old));
    for (const extra of all.filter((one) => one.parentId === old.id)) {
      new Catalogue(db).removeAsset(asset(extra));
    }
    expect(db.get("select 1 as x from item where id = ?", [old.id])).toBeUndefined();
    await scan();
    expect(item("Machine").id).not.toBe("");
    expect(item("Balloon").id).not.toBe(old.id);
    expect((await library(child.token)).items.filter((one) => one.parentId === null)).toEqual([]);
  });

  describe("a block", () => {
    const forget = (...ids: string[]): void => {
      for (const id of ids) new Catalogue(db).removeAsset(id);
    };
    const blockedNow = (): string[] =>
      (
        JSON.parse(
          db.get<{ kids_json: string }>("select kids_json from profile where id = ?", [kid])
            ?.kids_json ?? "{}",
        ) as KidsSettings
      ).blockedItemIds;
    const seen = async (): Promise<ApiItem[]> => (await library(child.token)).items;
    const episode = (title: RegExp): ApiItem => {
      const found = all.find((one) => one.kind === "episode" && title.test(one.title));
      if (!found) throw new Error("no such episode");
      return found;
    };
    const everything = async (blocked: string[]): Promise<void> => {
      await limit({
        allowedGroupIds: [await group("Small"), await group(null), await group("Grown-ups")],
        blockedItemIds: blocked,
      });
      await bind(kid);
    };

    it("on one episode survives its show being removed and added again", async () => {
      const first = episode(/Episode 1/);
      await everything([first.id]);
      forget(...new Set(all.filter((one) => one.kind === "episode").map(asset)));
      expect(db.get("select 1 as x from item where kind = 'show'")).toBeUndefined();
      await scan();
      const again = episode(/Episode 1/);
      expect(again.id).not.toBe(first.id);
      expect((await seen()).some((one) => one.id === again.id)).toBe(false);
      expect((await seen()).some((one) => one.title === "Episode 4")).toBe(true);
      expect((await call(child.token, "GET", `/v1/assets/${asset(again)}/content`)).status).toBe(
        404,
      );
    });

    it("on one episode survives another file, another season folder and another show name", async () => {
      const first = episode(/Episode 1/);
      await everything([first.id]);
      const old = join(dir, "Series/Zoo/Season 1/Zoo S01E01.mp4");
      forget(...new Set(all.filter((one) => one.kind === "episode").map(asset)));
      // Encoded again: only the place in the show says what it is.
      rmSync(old);
      makeVideo(old, { seed: 77 });
      await scan();
      expect((await seen()).some((one) => one.title === "Episode 1")).toBe(false);
      expect((await seen()).some((one) => one.title === "Episode 4")).toBe(true);

      // The same file under another name: only the file says what it is.
      forget(...new Set(all.filter((one) => one.kind === "episode").map(asset)));
      renameSync(join(dir, "Series/Zoo"), join(dir, "Series/Animals"));
      renameSync(
        join(dir, "Series/Animals/Season 1/Zoo S01E01.mp4"),
        join(dir, "Series/Animals/Season 1/Animals S01E09.mp4"),
      );
      await scan();
      expect(episode(/Episode 9/)).toBeDefined();
      expect((await seen()).some((one) => one.title === "Episode 9")).toBe(false);
      expect((await seen()).some((one) => one.title === "Episode 4")).toBe(true);
    });

    it("on a season survives its show being removed and added again", async () => {
      const season = all.find((one) => one.kind === "season");
      await everything([season?.id ?? ""]);
      forget(...new Set(all.filter((one) => one.kind === "episode").map(asset)));
      await scan();
      expect((await seen()).some((one) => one.kind === "episode")).toBe(false);
      // And all of it ends when a manager unblocks the new one.
      await everything([]);
      forget(...new Set(all.filter((one) => one.kind === "episode").map(asset)));
      await scan();
      expect((await seen()).some((one) => one.kind === "episode")).toBe(true);
    });

    it("on an extra survives its removal, with its film and as another file", async () => {
      const extra = item("Balloon trailer", "extra");
      const film = item("Balloon", "movie");
      await everything([extra.id]);
      forget(asset(extra), asset(film));
      await scan();
      expect(item("Balloon trailer", "extra").id).not.toBe(extra.id);
      expect(
        (await seen()).filter((one) => /^Balloon/.test(one.title)).map((one) => one.title),
      ).toEqual(["Balloon"]);
      forget(asset(item("Balloon trailer", "extra")));
      const path = join(dir, "Cartoons/Balloon (2009)/Trailers/Balloon trailer.mp4");
      rmSync(path);
      makeVideo(path, { seed: 78 });
      await scan();
      expect((await seen()).some((one) => one.kind === "extra")).toBe(false);
    });

    it("on a file nobody recognised or a home video survives its removal and a new name", async () => {
      makeVideo(join(dir, "Films/[a].mp4"), { seed: 21 });
      mkdirSync(join(dir, "Own"));
      roots = [...roots, { path: join(dir, "Own"), name: "Own", hint: "personal" }];
      scanner.syncSources(roots);
      makeVideo(join(dir, "Own/Beach.mp4"), { seed: 22 });
      await scan();
      const unknown = db.get<{ id: string }>(
        "select id from item where ident_key like 'unknown:%'",
      );
      const strange = all.find((one) => one.id === unknown?.id);
      const own = item("Beach");
      if (!strange) throw new Error("no strange file");
      await everything([strange.id, own.id]);
      forget(asset(strange), asset(own));
      renameSync(join(dir, "Films/[a].mp4"), join(dir, "Films/Nice Cartoon (2011).mp4"));
      await scan();
      expect(item("Beach").id).not.toBe(own.id);
      const titles = (await seen()).map((one) => one.title);
      expect(titles).not.toContain("Beach");
      expect(titles).not.toContain("Nice Cartoon");
      expect(titles).toContain("Garden");
    });

    it("covers a copy that arrives before the blocked file leaves", async () => {
      const extra = item("Balloon trailer", "extra");
      await everything([extra.id]);
      cpSync(
        join(dir, "Cartoons/Balloon (2009)/Trailers/Balloon trailer.mp4"),
        join(dir, "Films/Friendly (2012)/Friendly (2012).mp4"),
      );
      await scan();
      expect(item("Friendly")).toBeDefined();
      expect((await seen()).some((one) => one.title === "Friendly")).toBe(false);
    });

    it("is never off for a moment while a show is renamed file by file", async () => {
      const show = item("Zoo", "show");
      await everything([show.id]);
      const one = all.find((entry) => entry.kind === "episode" && /Episode 1$/.test(entry.title));
      mkdirSync(join(dir, "Series/Park/Season 1"), { recursive: true });
      renameSync(
        join(dir, "Series/Zoo/Season 1/Zoo S01E01.mp4"),
        join(dir, "Series/Park/Season 1/Park S01E01.mp4"),
      );
      // Two looks: one that misses it, one that finds it elsewhere.
      await scan();
      await scan();
      expect(item("Park", "show").id).not.toBe(one?.id);
      expect((await seen()).some((entry) => entry.kind === "episode")).toBe(false);
      expect(blockedNow()).toContain(item("Park", "show").id);
    });

    it("does not come back by itself once a manager took it away", async () => {
      const first = episode(/Episode 1/);
      await everything([first.id]);
      forget(...new Set(all.filter((one) => one.kind === "episode").map(asset)));
      await scan();
      const again = episode(/Episode 1/);
      expect(blockedNow()).toContain(again.id);
      await everything([]);
      forget(...new Set(all.filter((one) => one.kind === "episode").map(asset)));
      await scan();
      expect((await seen()).some((one) => one.title === "Episode 1")).toBe(true);
      expect(db.get("select count(*) as n from kids_blocked_trace")).toEqual({ n: 0 });
    });

    it("says nothing about what was not blocked", async () => {
      await everything([item("Scary").id]);
      forget(...new Set(all.map(asset).filter((id) => id !== "")));
      await scan();
      const titles = (await seen()).map((one) => one.title);
      expect(titles).not.toContain("Scary");
      for (const title of ["Balloon", "Balloon trailer", "Robot", "Garden", "Zoo", "Episode 1"]) {
        expect(titles).toContain(title);
      }
    });
  });

  it("starts over for a cursor it cannot read", async () => {
    await limit({ allowedGroupIds: [await group("Small")] });
    await bind(kid);
    const page = await library(child.token, "nonsense");
    expect(page.reset).toBe(true);
    expect(page.removed).toEqual([]);
    expect(page.items.some((one) => one.title === "Scary")).toBe(false);
  });

  it("changes nothing for other devices", async () => {
    const before = await library(viewer.token);
    await limit({ allowedGroupIds: [await group("Small")] });
    await bind(kid);
    await library(child.token);
    const after = await library(viewer.token, before.cursor);
    expect([after.items, after.removed]).toEqual([[], []]);
    expect((await library(viewer.token)).items).toEqual(before.items);
  });
});

describe("downloads and progress", () => {
  it("leaves out of the device's list what is not allowed", async () => {
    const show = item("Zoo", "show");
    const episodes = all
      .filter((one) => one.kind === "episode")
      .sort((a, b) => (a.episodeNumber ?? 0) - (b.episodeNumber ?? 0));
    await limit({
      allowedItemIds: [show.id, item("Balloon").id],
      blockedItemIds: [episodes[0]?.id ?? ""],
    });
    await bind(kid);
    const want = async (body: unknown): Promise<void> => {
      const path = `/v1/devices/${child.id}/wanted`;
      expect((await call(manager.token, "POST", path, body)).status).toBe(201);
    };
    await want({ kind: "item", itemId: item("Scary").id });
    await want({ kind: "item", itemId: item("Balloon").id });
    // The next one counts from what is allowed.
    await want({ kind: "next_unwatched", showId: show.id, profileId: kid, count: 1 });
    const list = await call<DeviceList>(child.token, "GET", "/v1/me/wanted");
    expect(list.body.assets.map((one) => one.itemId)).toEqual([
      item("Balloon").id,
      episodes[1]?.id,
    ]);
    await limit({ allowedItemIds: [show.id] });
    const later = await call<DeviceList>(child.token, "GET", "/v1/me/wanted");
    expect(later.body.revision).not.toBe(list.body.revision);
    expect(later.body.assets.map((one) => one.itemId)).toEqual([episodes[0]?.id]);
    const report = await call(child.token, "POST", "/v1/me/downloads", { downloads: [] });
    expect(report.status).toBe(200);
  });

  it("tells only the progress of allowed titles, and all of it once they are allowed", async () => {
    const put = async (token: string, title: string, op: string): Promise<number> =>
      (
        await call(token, "PUT", `/v1/profiles/${kid}/progress/${item(title).id}`, {
          opId: op,
          baseRevision: null,
          positionMs: 7,
          durationMs: 1000,
          completed: false,
          updatedAt: 1,
        })
      ).status;
    expect(await put(viewer.token, "Scary", "a")).toBe(200);
    await limit({ allowedGroupIds: [await group("Small")] });
    await bind(kid);
    expect(await put(child.token, "Robot", "b")).toBe(200);
    // Replaying someone else's operation is no way around it.
    expect(await put(child.token, "Scary", "a")).toBe(404);
    const read = async (since: number): Promise<{ progress: Progress[]; revision: number }> =>
      (
        await call<{ progress: Progress[]; revision: number }>(
          child.token,
          "GET",
          `/v1/profiles/${kid}/progress?since=${String(since)}`,
        )
      ).body;
    const first = await read(0);
    expect(first.progress.map((one) => one.itemId)).toEqual([item("Robot").id]);
    await limit({ allowedItemIds: [item("Scary").id] });
    const second = await read(first.revision);
    expect(second.progress.map((one) => one.itemId)).toEqual([item("Scary").id]);
    await bind(null);
    const third = await read(second.revision);
    expect(third.progress.length).toBe(2);
  });
});

describe("what is already running", () => {
  it.each(["blocked", "bound"])("stops sending a film that is %s meanwhile", async (how) => {
    const film = item("Balloon");
    const path = join(dir, "Cartoons/Balloon (2009)/Balloon (2009).mp4");
    // Long enough that nothing between the disk and the device holds all of it.
    truncateSync(path, 64 * 1024 * 1024);
    db.run("update asset set size = ?, mtime_ms = ? where id = ?", [
      statSync(path).size,
      Math.round(statSync(path).mtimeMs),
      asset(film),
    ]);
    if (how === "blocked") {
      await limit({ allowedItemIds: [film.id] });
      await bind(kid);
    }
    const content = `/v1/assets/${asset(film)}/content`;
    const response = await app.request(content, {
      headers: { Authorization: `Bearer ${child.token}` },
    });
    expect(response.status).toBe(200);
    const reader = response.body?.getReader();
    if (!reader) throw new Error("no body");
    expect((await reader.read()).done).toBe(false);
    if (how === "blocked") await limit({});
    else await bind(kid);
    await new Promise((done) => setTimeout(done, 1_100));
    await expect(
      (async () => {
        while (!(await reader.read()).done);
      })(),
    ).rejects.toThrow();
    expect((await call(child.token, "GET", content)).status).toBe(404);
  });

  it("goes on sending what is allowed", async () => {
    await limit({ allowedItemIds: [item("Balloon").id] });
    await bind(kid);
    const content = `/v1/assets/${asset(item("Balloon"))}/content`;
    const ranged = await app.request(content, {
      headers: { Authorization: `Bearer ${child.token}`, Range: "bytes=0-99" },
    });
    expect(ranged.status).toBe(206);
    expect((await ranged.arrayBuffer()).byteLength).toBe(100);
  });
});

describe("music", () => {
  it("is there for a kids device until a grown-up turns it off", async () => {
    makeAudio(join(dir, "Music/Song.mp3"), { tags: { title: "Song", artist: "One" } });
    await music.scanner.scanAll();
    await music.scanner.processQueue();
    const open = await call<{ tracks: { id: string }[] }>(viewer.token, "GET", "/v1/music/library");
    const track = open.body.tracks[0]?.id ?? "";
    await limit({ allowedItemIds: [track] });
    await bind(kid);
    const paths = [
      "library",
      `tracks/${track}`,
      `tracks/${track}/content`,
      `profiles/${kid}/progress`,
    ];
    for (const path of paths) {
      expect((await call(viewer.token, "GET", `/v1/music/${path}`)).status).toBe(200);
      expect((await call(child.token, "GET", `/v1/music/${path}`)).status).toBe(200);
    }
    // Another viewer's music is not the child's.
    expect((await call(child.token, "GET", `/v1/music/profiles/${parent}/progress`)).status).toBe(
      404,
    );
    const off = await call(manager.token, "PUT", `/v1/profiles/${kid}/kids/plan`, {
      plan: { music: false },
    });
    expect(off.status).toBe(200);
    for (const path of paths) {
      expect((await call(child.token, "GET", `/v1/music/${path}`)).status).toBe(404);
    }
  });
});

describe("the code for grown-ups", () => {
  const check = (token: string, code: unknown) =>
    call<{ correct: boolean; error: { code: string } }>(token, "POST", "/v1/kids/code/check", {
      code,
    });

  it("is chosen by a manager only, and not told to anybody", async () => {
    expect((await call(viewer.token, "GET", "/v1/kids/code")).body).toEqual({ set: false });
    expect((await check(viewer.token, "1234")).status).toBe(409);
    expect((await call(viewer.token, "PUT", "/v1/kids/code", { code: "1234" })).status).toBe(403);
    for (const bad of ["123", "12345", "12a4", 1234, undefined]) {
      const reply = await call(manager.token, "PUT", "/v1/kids/code", { code: bad });
      expect([bad, reply.status]).toEqual([bad, 400]);
    }
    const set = await call(manager.token, "PUT", "/v1/kids/code", { code: "1234" });
    expect([set.status, set.text]).toEqual([200, '{"set":true}']);
    expect((await call(viewer.token, "GET", "/v1/kids/code")).text).toBe('{"set":true}');
    expect(db.getMeta("kids_code")).not.toContain("1234");
    expect((await check(viewer.token, "4321")).body).toEqual({ correct: false });
    expect((await check(viewer.token, "1234")).body).toEqual({ correct: true });
    expect((await check(viewer.token, 1234)).status).toBe(400);

    // The same digits are kept as something else the next time.
    const kept = db.getMeta("kids_code");
    await call(manager.token, "PUT", "/v1/kids/code", { code: "1234" });
    expect(db.getMeta("kids_code")).not.toBe(kept);
    expect((await call(manager.token, "PUT", "/v1/kids/code", { code: null })).text).toBe(
      '{"set":false}',
    );
    expect((await check(viewer.token, "1234")).status).toBe(409);
  });

  it("counts wrong guesses per device, also when they come at once", async () => {
    await call(manager.token, "PUT", "/v1/kids/code", { code: "0007" });
    const replies = await Promise.all(
      Array.from({ length: 12 }, (_, one) => check(viewer.token, `100${String(one % 10)}`)),
    );
    expect(replies.filter((one) => one.status === 200)).toHaveLength(5);
    expect(replies.filter((one) => one.status === 429)).toHaveLength(7);
    // Also the right one now, and only for that device.
    expect((await check(viewer.token, "0007")).status).toBe(429);
    expect((await check(manager.token, "0007")).body).toEqual({ correct: true });
  });

  it("is not there for a device that belongs to a child", async () => {
    await call(manager.token, "PUT", "/v1/kids/code", { code: "1234" });
    await bind(kid);
    expect((await check(child.token, "1234")).status).toBe(404);
  });
});

describe("the upgrade", () => {
  it("leaves the devices and viewers of an older catalogue without limits", () => {
    const path = join(dir, "old.db");
    const old = new DatabaseSync(path);
    old.exec(
      "create table schema_migration (version integer primary key, name text not null, applied_at integer not null) strict",
    );
    for (const migration of migrations.filter((one) => one.version < 7)) {
      old.exec(migration.sql);
      old.exec(`insert into schema_migration values (${String(migration.version)}, 'x', 1)`);
    }
    old.exec("insert into profile (id, name, color, created_at) values ('p', 'P', 'red', 1)");
    old.exec(
      "insert into device (id, name, platform, role, token_hash, created_at) values ('d', 'D', 'ios', 'viewer', 'h', 1)",
    );
    old.exec(
      "insert into item (id, kind, ident_key, title, sort_title, added_at, revision) values ('i', 'movie', 'm', 'M', 'm', 1, 1)",
    );
    old.close();
    const upgraded = new Database(path);
    expect(upgraded.get("select kids_json, avatar from profile")).toEqual({
      kids_json: null,
      avatar: null,
    });
    expect(new Devices(upgraded, "s").find("d")?.kidsProfileId).toBeNull();
    expect(upgraded.get("select title from item")).toEqual({ title: "M" });
    upgraded.close();
  });
});
