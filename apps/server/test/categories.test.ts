// SPDX-License-Identifier: MPL-2.0
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { crc32 } from "node:zlib";
import type { Hono } from "hono";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ChosenArtwork } from "../src/artwork/chosen.ts";
import { LogoStore } from "../src/artwork/logos.ts";
import { Devices } from "../src/auth/devices.ts";
import { createBackup, restoreBackup } from "../src/backup.ts";
import { loadConfig, type RootConfig } from "../src/config.ts";
import { Database } from "../src/db/database.ts";
import { Enricher } from "../src/enrich/index.ts";
import { createApp, type AppEnv } from "../src/http/app.ts";
import { Catalogue } from "../src/library/catalogue.ts";
import {
  Categories,
  type CategoryGroupEntry,
  type CategoryView,
  type FolderEntry,
} from "../src/library/categories.ts";
import { ItemReader, type ApiItem } from "../src/library/items.ts";
import { Scanner } from "../src/library/scanner.ts";
import { ProgressStore } from "../src/progress.ts";
import { makeTempDir, makeVideo, removeDir } from "./support/media.ts";

type Setup = CategoryView & {
  folders: FolderEntry[];
  colors: string[];
  error?: { code: string; message: string };
};
interface Reply<T> {
  status: number;
  body: T;
}

let dir: string;
let db: Database;
let scanner: Scanner;
let reader: ItemReader;
let app: Hono<AppEnv>;
let manager: string;
let viewer: string;
let roots: RootConfig[];
let web: Server;
let webAnswers: Map<string, Buffer | object>;
let logos: LogoStore;
let enricher: Enricher;

const PNG = execFileSync("ffmpeg", [
  ..."-v error -f lavfi -i color=c=white:size=300x120,format=rgba -vf drawbox=x=0:y=0:w=100:h=120:c=black@0:t=fill:replace=1 -frames:v 1 -f image2 -c:v png -".split(
    " ",
  ),
]);

beforeEach(async () => {
  dir = makeTempDir();
  db = new Database(join(dir, "lobby.db"));
  const catalogue = new Catalogue(db);
  scanner = makeScanner(db);
  roots = [
    { path: join(dir, "Pixar"), name: "Pixar", hint: "movies", group: "Kids" },
    { path: join(dir, "Movies"), name: "Movies", hint: "movies" },
    { path: join(dir, "Disney"), name: "Disney", hint: "movies", group: "Kids" },
    { path: join(dir, "Disney more"), name: "Disney", hint: "movies", group: "Kids" },
    { path: join(dir, "Series"), name: "Series", hint: "series" },
  ];
  for (const root of roots) mkdirSync(root.path);
  scanner.syncSources(roots);
  webAnswers = new Map();
  web = createServer((request, response) => {
    const url = new URL(request.url ?? "/", "http://localhost");
    const answer = webAnswers.get(url.pathname);
    if (answer === undefined) response.writeHead(404).end("{}");
    else response.end(Buffer.isBuffer(answer) ? answer : JSON.stringify(answer));
  });
  await new Promise<void>((resolve) => web.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${(web.address() as AddressInfo).port}`;
  logos = new LogoStore(db, join(dir, "logos"), `${origin}/img`);
  enricher = new Enricher({
    db,
    catalogue,
    key: "0123456789abcdef0123456789abcdef",
    language: "en-US",
    artworkDir: join(dir, "artwork"),
    baseUrl: `${origin}/3`,
    limits: { retries: 0 },
  });
  reader = new ItemReader(db);
  const devices = new Devices(db, "secret");
  app = createApp({
    db,
    devices,
    items: reader,
    progress: new ProgressStore(db),
    logos,
    edit: {
      catalogue,
      enricher,
      chosen: new ChosenArtwork(db, {
        dir: join(dir, "chosen"),
        ffmpegPath: "ffmpeg",
        ffprobePath: "ffprobe",
      }),
    },
    serverName: "Test",
    version: "0",
    isScanning: () => false,
  });
  manager = devices.createLocalManager("Mac").token;
  const waiting = devices.startPairing("TV", "tvos");
  devices.approve(waiting.code, "viewer", "cli");
  const collected = devices.collect(waiting.id, waiting.pollSecret);
  viewer = collected.status === "approved" ? collected.token : "";
});

afterEach(async () => {
  logos.stop();
  await enricher.stop();
  web.closeAllConnections();
  web.close();
  db.close();
  removeDir(dir);
});

function makeScanner(database: Database): Scanner {
  return new Scanner(database, new Catalogue(database), {
    stabilityMs: 0,
    probeConcurrency: 1,
    ffprobePath: "ffprobe",
  });
}

async function scan(): Promise<void> {
  await scanner.scanAll();
  await scanner.scanAll();
  await scanner.processQueue();
}

async function call<T = Setup>(
  method: string,
  path: string,
  body?: unknown,
  token = manager,
): Promise<Reply<T>> {
  const bytes = Buffer.isBuffer(body) ? new Uint8Array(body) : null;
  const response = await app.request(path, {
    method,
    headers: { Authorization: `Bearer ${token}` },
    ...(body === undefined ? {} : { body: bytes ?? JSON.stringify(body) }),
  });
  const text = await response.text();
  return { status: response.status, body: (text === "" ? null : JSON.parse(text)) as T };
}

async function setup(): Promise<Setup> {
  return (await call("GET", "/v1/categories/edit")).body;
}

/** Makes a change with the current revision, which has to succeed. */
async function change(method: string, path: string, body: object = {}): Promise<Setup> {
  const { revision } = await setup();
  const reply = await call(method, path, { revision, ...body });
  expect([reply.status, reply.body.error]).toEqual([200, undefined]);
  return reply.body;
}
async function remove(path: string): Promise<Reply<Setup>> {
  const { revision } = await setup();
  return call("DELETE", `${path}${path.includes("?") ? "&" : "?"}revision=${revision}`);
}

function layout(view: { groups: CategoryGroupEntry[] }): [string | null, string[]][] {
  return view.groups.map((group) => [group.name, group.categories]);
}
function idOf(view: CategoryView, name: string): string {
  const entry = view.groups.flatMap((group) => group.entries).find((one) => one.name === name);
  if (!entry) throw new Error(`no category ${name}`);
  return entry.id;
}
function groupId(view: CategoryView, name: string | null): string {
  const group = view.groups.find((one) => one.name === name);
  if (!group) throw new Error("no such group");
  return group.id;
}
function item(title: string): ApiItem {
  const row = db.get<{ id: string }>("select id from item where title = ?", [title]);
  const [found] = reader.read([row?.id ?? ""]);
  if (!found) throw new Error(`no ${title}`);
  return found;
}
async function library(
  cursor = "",
): Promise<{ titles: string[]; cursor: string; removed: string[] }> {
  const { body } = await call<{ items: ApiItem[]; cursor: string; removed: string[] }>(
    "GET",
    `/v1/library?cursor=${cursor}`,
  );
  return {
    titles: body.items.map((one) => one.title).sort(),
    cursor: body.cursor,
    removed: body.removed,
  };
}

describe("taking over from the config", () => {
  it("keeps groups, order, folders and the old shape", async () => {
    const { body } = await call<CategoryView>("GET", "/v1/categories", undefined, viewer);
    expect(layout(body)).toEqual([
      [null, ["Movies", "Series"]],
      ["Kids", ["Pixar", "Disney"]],
    ]);
    expect(body.logos).toEqual({});
    const view = await setup();
    expect(view.folders.map((one) => [one.name, one.categoryId])).toEqual([
      ["Disney", idOf(view, "Disney")],
      ["Disney more", idOf(view, "Disney")],
      ["Movies", idOf(view, "Movies")],
      ["Pixar", idOf(view, "Pixar")],
      ["Series", idOf(view, "Series")],
    ]);
    // Nothing on disk is shown: a folder's name is enough.
    expect(JSON.stringify(view)).not.toContain(dir);
  });

  it("counts once: what the config says later about a known folder is ignored, and said so", async () => {
    const before = await setup();
    const info = vi.spyOn(console, "log").mockImplementation(() => undefined);
    scanner.syncSources(roots);
    expect(info.mock.calls.flat().join("\n")).not.toContain("ignored");
    scanner.syncSources(
      roots.map((root) => ({
        ...root,
        name: `${root.name}!`,
        group: "Other",
        logo: "/abcdefgh1.png",
      })),
    );
    expect(info.mock.calls.flat().join("\n")).toContain("in the config are ignored");
    info.mockRestore();
    expect(await setup()).toEqual(before);
  });

  it("gives a folder that is new its category, in a group that may exist already", async () => {
    const before = await setup();
    const added = [
      { path: join(dir, "Old"), name: "pixar", hint: "movies" as const, logo: "/otherlogo1.png" },
      { path: join(dir, "Anime"), name: "Anime", hint: "series" as const, group: "kids" },
    ];
    scanner.syncSources([...roots, ...added]);
    const view = await setup();
    expect(layout(view)[1]).toEqual(["Kids", ["Pixar", "Disney", "Anime"]]);
    expect(view.folders.find((one) => one.name === "Old")?.categoryId).toBe(idOf(before, "Pixar"));
    expect(db.get("select logo_id from category where name = 'Pixar'")).toEqual({ logo_id: null });
  });

  it("upgrades a catalogue from before, with titles that were placed by name", async () => {
    makeVideo(join(dir, "Movies", "Up (2009).mp4"));
    makeVideo(join(dir, "Pixar", "Cars (2006).mp4"), { seed: 1 });
    await scan();
    db.run("update item set override_json = ? where title = 'Up'", [
      JSON.stringify({ title: "Oben", categories: ["Disney", "Gone"] }),
    ]);
    db.run("update item set override_json = ? where title = 'Cars'", [
      JSON.stringify({ categories: ["Gone"] }),
    ]);
    db.close();
    const raw = new DatabaseSync(join(dir, "lobby.db"));
    // What came after categories refers to them, so it is undone first.
    for (const trigger of raw
      .prepare(
        "select name from sqlite_master where type = 'trigger' and name like 'kids@_%' escape '@'",
      )
      .all()) {
      raw.exec(`drop trigger ${String(trigger["name"])}`);
    }
    raw.exec(`drop table category_undo; drop table studio_dismissed; drop table item_studio;
      drop table studio; alter table item drop column studios_at;
      delete from schema_migration where version = 14`);
    raw.exec(`drop table kids_item; drop table kids_blocked_gone;
      alter table device drop column kids_profile_id; alter table profile drop column kids_json;
      delete from meta where key = 'kids_epoch'; delete from schema_migration where version = 7`);
    raw.exec(`drop index source_category;
      alter table source drop column category_id; alter table source drop column category_seeded;
      drop table category; drop table category_group; drop table logo;
      delete from schema_migration where version = 4; delete from meta where key = 'categories_revision'`);
    raw.close();

    db = new Database(join(dir, "lobby.db"));
    const cursor = db.currentRevision();
    makeScanner(db).syncSources([
      { ...roots[0], logo: "/studiologo1.png" } as RootConfig,
      ...roots.slice(1),
    ]);
    const categories = new Categories(db);
    expect(layout(categories.view())).toEqual([
      [null, ["Movies", "Series"]],
      ["Kids", ["Pixar", "Disney"]],
    ]);
    const items = new ItemReader(db).page({ revision: cursor, id: "￿" }, 100).items;
    const up = items.find((one) => one.title === "Oben");
    expect(up?.categories).toEqual(["Disney"]);
    expect(up?.categoryIds).toEqual([idOf(categories.view(), "Disney")]);
    expect(items.find((one) => one.title === "Cars")?.categories).toEqual(["Pixar"]);
    expect(db.get("select id, remote_path from logo")).toEqual({
      id: "studiologo1",
      remote_path: "/studiologo1.png",
    });
    expect(db.get("select override_json from item where title = 'Cars'")).toEqual({
      override_json: null,
    });
  });

  it("refuses a config with one category in two groups", () => {
    const path = join(dir, "lobby.config.json");
    writeFileSync(
      path,
      JSON.stringify({
        roots: [
          { path: "/m/A", name: "Disney", hint: "movies", group: "Kids" },
          { path: "/m/B", name: "Disney", hint: "movies" },
        ],
      }),
    );
    expect(() => loadConfig(path)).toThrow(/two groups/);
  });
});

describe("who may change them", () => {
  it("refuses viewers everywhere and managers with an older revision", async () => {
    const view = await setup();
    const id = idOf(view, "Pixar");
    const kids = groupId(view, "Kids");
    const requests: [string, string, object?][] = [
      ["GET", "/v1/categories/edit"],
      ["POST", "/v1/categories/groups", { name: "X" }],
      ["PUT", "/v1/categories/groups/order", { ids: [kids] }],
      ["PATCH", `/v1/categories/groups/${kids}`, { name: "X" }],
      ["DELETE", `/v1/categories/groups/${kids}?revision=999&moveTo=${groupId(view, null)}`],
      ["PUT", `/v1/categories/folders/${view.folders[0]?.id ?? ""}`, { categoryId: null }],
      ["GET", "/v1/categories/logo-search?query=a"],
      ["GET", "/v1/categories/logo-search/preview?path=/abcdefgh1.png"],
      ["PUT", `/v1/categories/${id}/logo`, { path: "/abcdefgh1.png" }],
      ["POST", `/v1/categories/${id}/logo/upload?revision=999`],
      ["DELETE", `/v1/categories/${id}/logo?revision=999`],
      ["PUT", `/v1/categories/groups/${kids}/logo`, { path: "/abcdefgh1.png" }],
      ["POST", `/v1/categories/groups/${kids}/logo/upload?revision=999`],
      ["DELETE", `/v1/categories/groups/${kids}/logo?revision=999`],
      ["POST", "/v1/categories", { groupId: kids, name: "X" }],
      ["PUT", "/v1/categories/order", { groupId: kids, ids: [] }],
      ["PATCH", `/v1/categories/${id}`, { name: "X" }],
      ["DELETE", `/v1/categories/${id}?revision=999&foldersTo=none`],
    ];
    for (const [method, path, body] of requests) {
      const payload = body ? { revision: 999, ...body } : undefined;
      const asViewer = await call(method, path, payload, viewer);
      expect([method, path, asViewer.status]).toEqual([method, path, 403]);
      if (method === "GET") continue;
      const late = await call(method, path, payload);
      expect([method, path, late.status]).toEqual([method, path, 409]);
      expect(late.body.revision).toBe(view.revision);
      expect(late.body.groups).toEqual(view.groups);
    }
    expect(await setup()).toEqual(view);
  });
});

describe("changing them", () => {
  beforeEach(async () => {
    makeVideo(join(dir, "Pixar", "Cars (2006).mp4"));
    makeVideo(join(dir, "Movies", "Up (2009).mp4"), { seed: 1 });
    makeVideo(join(dir, "Series", "Bluey/Season 1/S01E01.mp4"), { seed: 2 });
    await scan();
  });

  it("renames a category without losing its titles, places, logo or anyone's progress", async () => {
    webAnswers.set("/img/studiologo1.png", PNG);
    const before = await setup();
    const id = idOf(before, "Pixar");
    await change("PUT", `/v1/categories/${id}/logo`, { path: "/studiologo1.png" });
    const up = item("Up");
    const edit = await call<{ revision: number }>("GET", `/v1/items/${up.id}/edit`);
    await call("PATCH", `/v1/items/${up.id}`, {
      revision: edit.body.revision,
      set: { categoryIds: [id] },
    });
    db.run("insert into profile (id, name, color, created_at) values ('p', 'P', 'red', 0)");
    db.run(
      "insert into progress (profile_id, item_id, position_ms, revision, updated_at) values ('p', ?, 5, 1, 1)",
      [up.id],
    );
    const { cursor } = await library();
    const view = await change("PATCH", `/v1/categories/${id}`, { name: "Studio P" });
    expect(layout(view)[1]).toEqual(["Kids", ["Studio P", "Disney"]]);
    expect(Object.keys(view.logos)).toEqual(["Studio P"]);
    expect(item("Cars")).toMatchObject({ categories: ["Studio P"], categoryIds: [id] });
    expect(item("Up")).toMatchObject({ id: up.id, categories: ["Studio P"], categoryIds: [id] });
    expect((await library(cursor)).titles).toEqual(["Cars", "Up"]);
    expect(db.get("select count(*) as n from progress where item_id = ?", [up.id])).toEqual({
      n: 1,
    });
    // A restart with the old config changes nothing.
    scanner.syncSources(roots);
    expect((await setup()).groups).toEqual(view.groups);
  });

  it("creates, decorates, moves and orders", async () => {
    let view = await change("POST", "/v1/categories/groups", {
      name: "Teens",
      icon: "star.fill",
      color: "teal",
    });
    const teens = groupId(view, "Teens");
    view = await change("POST", "/v1/categories", { groupId: teens, name: "Anime" });
    const anime = idOf(view, "Anime");
    view = await change("PATCH", `/v1/categories/${anime}`, { icon: "sparkles", color: "pink" });
    view = await change("PATCH", `/v1/categories/${idOf(view, "Disney")}`, { groupId: teens });
    view = await change("PUT", "/v1/categories/order", {
      groupId: teens,
      ids: [idOf(view, "Disney"), anime],
    });
    view = await change("PUT", "/v1/categories/groups/order", {
      ids: [teens, groupId(view, "Kids")],
    });
    expect(layout(view)).toEqual([
      [null, ["Movies", "Series"]],
      ["Teens", ["Disney", "Anime"]],
      ["Kids", ["Pixar"]],
    ]);
    expect(view.groups[1]).toMatchObject({
      id: teens,
      icon: "star.fill",
      color: "teal",
      logo: null,
    });
    expect(view.groups[1]?.entries[1]).toEqual({
      id: anime,
      parentId: null,
      name: "Anime",
      icon: "sparkles",
      color: "pink",
      logo: null,
      rule: null,
    });
    view = await change("PATCH", `/v1/categories/${anime}`, { icon: null, color: null });
    expect(view.groups[1]?.entries[1]).toMatchObject({ icon: null, color: null });
    view = await change("PATCH", `/v1/categories/groups/${groupId(view, "Kids")}`, {
      name: "Kinder",
    });
    expect(view.groups[2]?.name).toBe("Kinder");
  });

  it("assigns folders, and their titles follow with everything below", async () => {
    const view = await setup();
    const series = view.folders.find((one) => one.name === "Series")?.id ?? "";
    const { cursor } = await library();
    await change("PUT", `/v1/categories/folders/${series}`, { categoryId: idOf(view, "Disney") });
    expect(item("Bluey").categories).toEqual(["Disney"]);
    expect((await library(cursor)).titles).toEqual(["Bluey", "Episode 1", "Season 1"]);
    await change("PUT", `/v1/categories/folders/${series}`, { categoryId: null });
    expect(item("Bluey")).toMatchObject({ categories: [], categoryIds: [], available: true });
    scanner.syncSources(roots);
    expect(item("Bluey").categories).toEqual([]);
  });

  it("removes a category and never a title", async () => {
    const view = await setup();
    const pixar = idOf(view, "Pixar");
    const disney = idOf(view, "Disney");
    for (const [title, ids] of [
      ["Up", [pixar]],
      ["Bluey", [pixar, disney]],
    ] as [string, string[]][]) {
      await call("PATCH", `/v1/items/${item(title).id}`, {
        revision: 0,
        set: { title, categoryIds: ids },
      });
    }
    const count = db.get("select count(*) as n from item");
    const unsure = await remove(`/v1/categories/${pixar}`);
    expect(unsure.status).toBe(400);
    expect((await remove(`/v1/categories/${pixar}?foldersTo=${pixar}`)).status).toBe(400);
    expect((await remove(`/v1/categories/${pixar}?foldersTo=nope`)).status).toBe(404);
    const { cursor } = await library();
    const gone = await remove(`/v1/categories/${pixar}?foldersTo=${disney}`);
    expect(gone.status).toBe(200);
    expect(layout(gone.body)[1]).toEqual(["Kids", ["Disney"]]);
    // By folder: along. By hand: back to its folder, or what is left.
    expect(item("Cars").categories).toEqual(["Disney"]);
    expect(item("Up").categories).toEqual(["Movies"]);
    expect(item("Bluey").categories).toEqual(["Disney"]);
    const synced = await library(cursor);
    expect(synced.titles).toEqual(["Bluey", "Cars", "Episode 1", "Season 1", "Up"]);
    expect(synced.removed).toEqual([]);
    expect(db.get("select count(*) as n from item")).toEqual(count);
    // What someone had open in the editor is out of date now.
    const stale = await call("PATCH", `/v1/items/${item("Up").id}`, {
      revision: 1,
      set: { year: 2000 },
    });
    expect(stale.status).toBe(409);

    expect((await remove(`/v1/categories/${disney}?foldersTo=none`)).status).toBe(200);
    expect(item("Cars").categories).toEqual([]);
  });

  it("removes a group only when it is said where its categories go", async () => {
    const view = await setup();
    const kids = groupId(view, "Kids");
    const main = groupId(view, null);
    expect((await remove(`/v1/categories/groups/${kids}`)).status).toBe(400);
    expect((await remove(`/v1/categories/groups/${kids}?moveTo=${kids}`)).status).toBe(400);
    expect((await remove(`/v1/categories/groups/${main}?moveTo=${kids}`)).status).toBe(400);
    const gone = await remove(`/v1/categories/groups/${kids}?moveTo=${main}`);
    expect(layout(gone.body)).toEqual([[null, ["Movies", "Series", "Pixar", "Disney"]]]);
    expect(idOf(gone.body, "Pixar")).toBe(idOf(view, "Pixar"));
    const empty = await change("POST", "/v1/categories/groups", { name: "Empty" });
    expect((await remove(`/v1/categories/groups/${groupId(empty, "Empty")}`)).status).toBe(200);
  });

  it("refuses what does not fit", async () => {
    const view = await setup();
    const id = idOf(view, "Pixar");
    const kids = groupId(view, "Kids");
    const main = groupId(view, null);
    const bad: [string, string, object][] = [
      ["POST", "/v1/categories", { groupId: kids, name: "" }],
      ["POST", "/v1/categories", { groupId: kids, name: "x".repeat(61) }],
      ["POST", "/v1/categories", { groupId: kids, name: "a\nb" }],
      ["POST", "/v1/categories", { groupId: kids, name: " movies " }],
      ["POST", "/v1/categories", { name: "X" }],
      ["PATCH", `/v1/categories/${id}`, { name: "DISNEY" }],
      ["PATCH", `/v1/categories/${id}`, { icon: "../x" }],
      ["PATCH", `/v1/categories/${id}`, { icon: "Star Fill" }],
      ["PATCH", `/v1/categories/${id}`, { icon: "a".repeat(65) }],
      ["PATCH", `/v1/categories/${id}`, { color: "#ff0000" }],
      ["PATCH", `/v1/categories/${id}`, { groupId: 3 }],
      ["PATCH", `/v1/categories/groups/${main}`, { name: "Main" }],
      ["POST", "/v1/categories/groups", { name: "kids" }],
      ["PUT", "/v1/categories/groups/order", { ids: [] }],
      ["PUT", "/v1/categories/groups/order", { ids: [main, kids] }],
      ["PUT", "/v1/categories/order", { groupId: kids, ids: [id, id] }],
      ["PUT", `/v1/categories/folders/${view.folders[0]?.id ?? ""}`, { categoryId: 4 }],
      ["PUT", `/v1/categories/${id}/logo`, { path: "/../secret.png" }],
    ];
    for (const [method, path, body] of bad) {
      const reply = await call(method, path, { revision: view.revision, ...body });
      expect([method, JSON.stringify(body).slice(0, 50), reply.status]).toEqual([
        method,
        JSON.stringify(body).slice(0, 50),
        400,
      ]);
    }
    for (const [method, path, body] of [
      ["PATCH", "/v1/categories/nope", { name: "X" }],
      ["PATCH", "/v1/categories/groups/nope", { name: "X" }],
      ["POST", "/v1/categories", { groupId: "nope", name: "X" }],
      ["PUT", "/v1/categories/folders/nope", { categoryId: null }],
      ["PUT", `/v1/categories/folders/${view.folders[0]?.id ?? ""}`, { categoryId: "nope" }],
    ] as [string, string, object][]) {
      expect((await call(method, path, { revision: view.revision, ...body })).status).toBe(404);
    }
    expect((await call("PATCH", `/v1/categories/${id}`, { name: "X" })).status).toBe(400);
    expect(await setup()).toEqual(view);
    // Its own name in another case is not taken by another.
    await change("PATCH", `/v1/categories/${id}`, { name: "PIXAR" });
  });
});

describe("logos", () => {
  it("finds a studio's logo at TMDB and keeps it", async () => {
    webAnswers.set("/3/search/company", {
      page: 1,
      results: [
        { id: 3, logo_path: "/studiologo1.png", name: "Pixar", origin_country: "US" },
        { id: 4, logo_path: null, name: "Pixar Talking Pictures", origin_country: "" },
        { id: 5, logo_path: "/bad path.png", name: "Odd", origin_country: "" },
      ],
      total_pages: 1,
      total_results: 3,
    });
    webAnswers.set("/img/studiologo1.png", PNG);
    const found = await call<{ results: { path: string; previewUrl: string }[] }>(
      "GET",
      "/v1/categories/logo-search?query=Pixar",
    );
    expect(found.body.results).toEqual([
      {
        name: "Pixar",
        country: "US",
        path: "/studiologo1.png",
        previewUrl: "/v1/categories/logo-search/preview?path=%2Fstudiologo1.png",
      },
    ]);
    const preview = await app.request(found.body.results[0]?.previewUrl ?? "", {
      headers: { Authorization: `Bearer ${manager}` },
    });
    expect(Buffer.from(await preview.arrayBuffer()).equals(PNG)).toBe(true);
    const view = await setup();
    const id = idOf(view, "Pixar");
    const { cursor } = await library();
    const chosen = await change("PUT", `/v1/categories/${id}/logo`, { path: "/studiologo1.png" });
    expect(chosen.logos).toEqual({ Pixar: { id: "studiologo1", width: 300, height: 120 } });
    expect((await library(cursor)).cursor).not.toBe(cursor);
    const group = await change("PUT", `/v1/categories/groups/${groupId(view, "Kids")}/logo`, {
      path: "/studiologo1.png",
    });
    expect(group.groups[1]?.logo).toMatchObject({ id: "studiologo1", transparent: true });
    // One picture for two places goes when the last one lets go.
    await remove(`/v1/categories/${id}/logo`);
    expect(logos.read("studiologo1")).not.toBeNull();
    await remove(`/v1/categories/groups/${groupId(view, "Kids")}/logo`);
    expect(logos.read("studiologo1")).toBeNull();
  });

  it("says so when TMDB is away", async () => {
    web.close();
    web.closeAllConnections();
    const view = await setup();
    expect((await call("GET", "/v1/categories/logo-search?query=Pixar")).status).toBe(503);
    const put = await call("PUT", `/v1/categories/${idOf(view, "Pixar")}/logo`, {
      revision: view.revision,
      path: "/studiologo1.png",
    });
    expect(put.status).toBe(503);
  });

  it("takes an own picture, checked and written again with its transparency", async () => {
    const view = await setup();
    const id = idOf(view, "Pixar");
    const upload = (bytes: Buffer, revision: number): Promise<Reply<Setup>> =>
      call("POST", `/v1/categories/${id}/logo/upload?revision=${revision}`, bytes);
    const marked = Buffer.concat([
      PNG.subarray(0, 33),
      pngText("Comment", "SECRET-LOCATION"),
      PNG.subarray(33),
    ]);
    const done = await upload(marked, view.revision);
    expect(done.status).toBe(200);
    const logo = done.body.groups[1]?.entries[0]?.logo;
    expect(logo).toMatchObject({ width: 300, height: 120, transparent: true });
    const served = await app.request(`/v1/logos/${logo?.id ?? ""}`, {
      headers: { Authorization: `Bearer ${viewer}` },
    });
    expect(served.headers.get("content-type")).toBe("image/png");
    const stored = Buffer.from(await served.arrayBuffer());
    expect(stored.includes("SECRET-LOCATION")).toBe(false);
    writeFileSync(join(dir, "stored.png"), stored);
    const pixels = execFileSync("ffmpeg", [
      ...["-v", "error", "-i", join(dir, "stored.png")],
      ...["-f", "rawvideo", "-pix_fmt", "rgba", "-"],
    ]);
    expect(pixels[3]).toBe(0);
    expect(pixels[299 * 4 + 3]).toBe(255);

    const jpeg = execFileSync("ffmpeg", [
      ..."-v error -f lavfi -i testsrc2=size=1800x900 -frames:v 1 -f image2 -c:v mjpeg -".split(
        " ",
      ),
    ]);
    const opaque = await upload(jpeg, done.body.revision);
    expect(opaque.body.groups[1]?.entries[0]?.logo).toMatchObject({
      width: 600,
      height: 300,
      transparent: false,
    });
    const clear = execFileSync("ffmpeg", [
      ..."-v error -f lavfi -i color=c=black@0:size=200x200,format=rgba -frames:v 1 -f image2 -c:v png -".split(
        " ",
      ),
    ]);
    const video = join(dir, "v.mp4");
    makeVideo(video);
    for (const bytes of [
      clear,
      readFileSync(video),
      Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"/>'),
      PNG.subarray(0, 60),
      Buffer.alloc(0),
    ]) {
      const bad = await upload(bytes, opaque.body.revision);
      expect(bad.status).toBe(400);
    }
    expect((await setup()).revision).toBe(opaque.body.revision);
  });
});

it("travels with a backup, pictures included", async () => {
  const view = await setup();
  const id = idOf(view, "Pixar");
  await call("POST", `/v1/categories/${id}/logo/upload?revision=${view.revision}`, PNG);
  await change("PATCH", `/v1/categories/${id}`, {
    name: "Studio P",
    icon: "lamp.desk",
    color: "blue",
  });
  const before = await setup();
  const backup = await createBackup(db, join(dir, "backups"), null);
  const elsewhere = join(dir, "elsewhere");
  restoreBackup(backup.path, elsewhere);
  const restored = new Database(join(elsewhere, "lobby.db"));
  try {
    makeScanner(restored).syncSources(roots);
    expect(new Categories(restored).view()).toEqual({
      revision: before.revision,
      groups: before.groups,
      logos: before.logos,
    });
    const logo = before.logos["Studio P"]?.id ?? "";
    expect(new LogoStore(restored, join(elsewhere, "logos")).read(logo)).toEqual(logos.read(logo));
  } finally {
    restored.close();
  }
});

/** A PNG text chunk. */
function pngText(key: string, value: string): Buffer {
  const data = Buffer.from(`${key}\0${value}`, "latin1");
  const body = Buffer.concat([Buffer.from("tEXt"), data]);
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const sum = Buffer.alloc(4);
  sum.writeUInt32BE(crc32(body));
  return Buffer.concat([length, body, sum]);
}
