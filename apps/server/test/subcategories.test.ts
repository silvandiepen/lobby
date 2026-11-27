// SPDX-License-Identifier: MPL-2.0
import { cpSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import type { Hono } from "hono";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { ChosenArtwork } from "../src/artwork/chosen.ts";
import { LogoStore } from "../src/artwork/logos.ts";
import { Devices } from "../src/auth/devices.ts";
import { createBackup, restoreBackup } from "../src/backup.ts";
import { ConversionStore } from "../src/conversion/store.ts";
import { Database } from "../src/db/database.ts";
import { migrations } from "../src/db/migrations.ts";
import { DeviceDownloads } from "../src/devices-downloads/index.ts";
import { Enricher } from "../src/enrich/index.ts";
import { createApp, type AppEnv } from "../src/http/app.ts";
import { createAssetLookup } from "../src/http/playback-assets.ts";
import type { KidsChange, KidsSettings } from "../src/kids/limits.ts";
import { Catalogue } from "../src/library/catalogue.ts";
import { Categories, type CategoryView, type FolderEntry } from "../src/library/categories.ts";
import { ItemReader, type ApiItem } from "../src/library/items.ts";
import { Scanner } from "../src/library/scanner.ts";
import { PlaybackService } from "../src/playback/index.ts";
import { ProgressStore } from "../src/progress.ts";
import { Studios, type Studio } from "../src/library/studios.ts";
import { makeTempDir, makeVideo, removeDir } from "./support/media.ts";

// Every name here is made up.
type Setup = CategoryView & {
  folders: FolderEntry[];
  undo: string | null;
  created?: Record<string, string>;
  dryRun?: boolean;
  needsConfirmation?: boolean;
  kidsChanges: KidsChange[];
  kidsToken: string;
  error?: { code: string; message: string };
};
interface Reply<T> {
  status: number;
  body: T;
}

const roots = ["Lantern", "Meadow", "Harbour", "Films"];
let files: string;
let dir: string;
let db: Database;
let app: Hono<AppEnv>;
let playback: PlaybackService;
let downloads: DeviceDownloads;
let manager: string;
let child: { id: string; token: string };
let kid: string;
let ids: Record<string, string>;
let groups: Record<string, string>;

beforeAll(() => {
  files = makeTempDir("lobby-sub-files-");
  // One film of the folder's name with "One" in each.
  for (const [index, name] of roots.entries()) {
    makeVideo(join(files, name, `${name} One (2001).mp4`), { seed: index + 1 });
  }
}, 60_000);
afterAll(() => {
  removeDir(files);
});

beforeEach(async () => {
  dir = makeTempDir("lobby-sub-");
  for (const name of roots) mkdirSync(join(dir, name));
  cpSync(files, dir, { recursive: true });
  db = new Database(join(dir, "lobby.db"));
  const catalogue = new Catalogue(db);
  const scanner = new Scanner(db, catalogue, {
    stabilityMs: 0,
    probeConcurrency: 2,
    ffprobePath: "ffprobe",
  });
  scanner.syncSources(
    roots.map((name) => ({
      path: join(dir, name),
      name,
      hint: "movies",
      ...(name === "Films" ? {} : { group: "Small" }),
    })),
  );
  playback = new PlaybackService({ cacheDir: join(dir, "cache"), minFreeBytes: 0 });
  await playback.start();
  downloads = new DeviceDownloads({ db, playback, lookupAsset: createAssetLookup(db) });
  const devices = new Devices(db, "secret");
  app = createApp({
    db,
    devices,
    items: new ItemReader(db),
    progress: new ProgressStore(db),
    downloads,
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
  });
  manager = devices.createLocalManager("Mac").token;
  const waiting = devices.startPairing("Tablet", "ipados");
  devices.approve(waiting.code, "viewer", "cli");
  const done = devices.collect(waiting.id, waiting.pollSecret);
  if (done.status !== "approved") throw new Error("not paired");
  child = { id: done.device.id, token: done.token };
  await scanner.scanAll();
  await scanner.scanAll();
  await scanner.processQueue();
  const view = await setup();
  ids = Object.fromEntries(view.groups.flatMap((g) => g.entries).map((one) => [one.name, one.id]));
  groups = Object.fromEntries(view.groups.map((one) => [one.name ?? "", one.id]));
  kid = (
    await call<{ id: string }>("POST", "/v1/profiles", {
      name: "Small one",
      kids: { allowedGroupIds: [], allowedCategoryIds: [], allowedItemIds: [], blockedItemIds: [] },
    })
  ).body.id;
  await call("PATCH", `/v1/devices/${child.id}`, { kidsProfileId: kid });
}, 60_000);

afterEach(async () => {
  await downloads.stop();
  await playback.close();
  db.close();
  removeDir(dir);
});

async function call<T = Setup>(
  method: string,
  path: string,
  body?: unknown,
  token = manager,
): Promise<Reply<T>> {
  const response = await app.request(path, {
    method,
    headers: { Authorization: `Bearer ${token}` },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const text = await response.text();
  return { status: response.status, body: (text === "" ? null : JSON.parse(text)) as T };
}
async function setup(): Promise<Setup> {
  return (await call("GET", "/v1/categories/edit")).body;
}
/** A change with the current revision, whatever comes of it. */
async function attempt(method: string, path: string, body: object = {}): Promise<Reply<Setup>> {
  const { revision } = await setup();
  if (method !== "DELETE") return call(method, path, { revision, ...body });
  const query = new URLSearchParams({ revision: String(revision), ...body });
  return call("DELETE", `${path}?${query.toString()}`);
}
async function change(method: string, path: string, body: object = {}): Promise<Setup> {
  const reply = await attempt(method, path, body);
  expect([reply.status, reply.body.error]).toEqual([200, undefined]);
  return reply.body;
}
async function status(method: string, path: string, body: object = {}): Promise<number> {
  return (await attempt(method, path, body)).status;
}
/** "Parent", and "Parent/Sub" after it. */
function tree(view: CategoryView): Record<string, string[]> {
  return Object.fromEntries(
    view.groups.map((group) => {
      const names = new Map(group.entries.map((one) => [one.id, one.name]));
      return [
        group.name ?? "",
        group.entries.map((one) =>
          one.parentId === null ? one.name : `${names.get(one.parentId) ?? "?"}/${one.name}`,
        ),
      ];
    }),
  );
}
const id = (name: string): string => ids[name] ?? `no ${name}`;
const nest = (name: string, parent: string | null): Promise<Setup> =>
  change("PATCH", `/v1/categories/${id(name)}`, { parentId: parent === null ? null : id(parent) });

async function limit(kids: Partial<KidsSettings>): Promise<void> {
  const reply = await call("PATCH", `/v1/profiles/${kid}`, {
    kids: {
      allowedGroupIds: [],
      allowedCategoryIds: [],
      allowedItemIds: [],
      blockedItemIds: [],
      blockedCategoryIds: [],
      ...kids,
    },
  });
  expect(reply.status).toBe(200);
}
/** What a manager chose for a title, which has to succeed. */
async function choose(item: ApiItem, categoryIds: (string | undefined)[]): Promise<void> {
  const path = `/v1/items/${item.id}`;
  const { revision } = (await call<{ revision: number }>("GET", `${path}/edit`)).body;
  expect((await call("PATCH", path, { revision, set: { categoryIds } })).status).toBe(200);
}
async function library(token: string): Promise<ApiItem[]> {
  return (await call<{ items: ApiItem[] }>("GET", "/v1/library", undefined, token)).body.items;
}
/** The folders of the films a child's device gets. */
async function seen(): Promise<string[]> {
  return (await library(child.token)).map((one) => one.title.replace(" One", "")).sort();
}
async function film(name: string): Promise<ApiItem> {
  const found = (await library(manager)).find((one) => one.title === `${name} One`);
  if (!found) throw new Error(`no ${name}`);
  return found;
}

describe("a category inside another", () => {
  it("keeps its id, look, folder, chosen titles and its titles' own categories", async () => {
    await change("PATCH", `/v1/categories/${id("Meadow")}`, { icon: "leaf", color: "green" });
    db.run("insert into logo (id, data, width, height) values ('pic', x'00', 3, 2)");
    db.run("update category set logo_id = 'pic' where id = ?", [id("Meadow")]);
    const chosen = await film("Films");
    await choose(chosen, [id("Meadow")]);
    const before = await setup();
    const view = await nest("Meadow", "Lantern");
    expect(tree(view)).toEqual({ "": ["Films"], Small: ["Lantern", "Lantern/Meadow", "Harbour"] });
    expect(view.groups[1]?.entries[1]).toEqual({
      id: id("Meadow"),
      parentId: id("Lantern"),
      name: "Meadow",
      icon: "leaf",
      color: "green",
      logo: { id: "pic", width: 3, height: 2, transparent: true },
      rule: null,
    });
    expect(view.folders).toEqual(before.folders);
    expect(view.logos).toEqual(before.logos);
    // Only its own: an app that sends back what it read puts nothing in the parent.
    for (const name of ["Meadow", "Films"]) {
      expect((await film(name)).categoryIds).toEqual([id("Meadow")]);
      expect((await film(name)).categories).toEqual(["Meadow"]);
    }
    expect((await film("Lantern")).categoryIds).toEqual([id("Lantern")]);
  });

  it("is made inside one, and goes in and out again", async () => {
    let view = await change("POST", "/v1/categories", { parentId: id("Lantern"), name: "Early" });
    expect(tree(view)["Small"]).toEqual(["Lantern", "Lantern/Early", "Meadow", "Harbour"]);
    ids["Early"] = view.groups[1]?.entries[1]?.id ?? "";
    view = await nest("Early", "Harbour");
    expect(tree(view)["Small"]).toEqual(["Lantern", "Meadow", "Harbour", "Harbour/Early"]);
    view = await nest("Early", null);
    expect(tree(view)["Small"]).toEqual(["Lantern", "Meadow", "Harbour", "Early"]);
  });

  it("is one level, in one group, and nothing else", async () => {
    await nest("Meadow", "Lantern");
    const before = await setup();
    const refused: [string, string, object, number][] = [
      ["PATCH", `/v1/categories/${id("Harbour")}`, { parentId: id("Meadow") }, 400],
      ["PATCH", `/v1/categories/${id("Lantern")}`, { parentId: id("Harbour") }, 400],
      ["PATCH", `/v1/categories/${id("Harbour")}`, { parentId: id("Harbour") }, 400],
      ["PATCH", `/v1/categories/${id("Harbour")}`, { parentId: "nope" }, 404],
      ["PATCH", `/v1/categories/${id("Harbour")}`, { parentId: 3 }, 400],
      [
        "PATCH",
        `/v1/categories/${id("Harbour")}`,
        { parentId: id("Lantern"), groupId: groups[""] },
        400,
      ],
      ["POST", "/v1/categories", { parentId: id("Meadow"), name: "Deep" }, 400],
      ["POST", "/v1/categories", { parentId: id("Lantern"), groupId: groups[""], name: "X" }, 400],
      ["POST", "/v1/categories", { parentId: null, name: "X" }, 400],
      ["POST", "/v1/categories", { parentId: id("Lantern"), name: "FILMS" }, 400],
      [
        "PUT",
        "/v1/categories/order",
        { groupId: groups["Small"], parentId: id("Lantern"), ids: [] },
        400,
      ],
      [
        "PUT",
        "/v1/categories/order",
        { groupId: groups[""], parentId: id("Lantern"), ids: [id("Meadow")] },
        400,
      ],
    ];
    for (const [method, path, body, expected] of refused) {
      expect([method, path, body, await status(method, path, body)]).toEqual([
        method,
        path,
        body,
        expected,
      ]);
    }
    expect(await setup()).toEqual(before);
  });

  it("goes along when its parent moves, and goes to its parent's group", async () => {
    await nest("Meadow", "Lantern");
    let view = await change("PATCH", `/v1/categories/${id("Lantern")}`, { groupId: groups[""] });
    expect(tree(view)).toEqual({ "": ["Films", "Lantern", "Lantern/Meadow"], Small: ["Harbour"] });
    view = await nest("Harbour", "Films");
    expect(tree(view)[""]).toEqual(["Films", "Films/Harbour", "Lantern", "Lantern/Meadow"]);
  });

  it("has an order among its neighbours", async () => {
    await nest("Meadow", "Lantern");
    await nest("Harbour", "Lantern");
    const groupId = groups["Small"];
    let view = await change("PUT", "/v1/categories/order", {
      groupId,
      parentId: id("Lantern"),
      ids: [id("Harbour"), id("Meadow")],
    });
    expect(tree(view)["Small"]).toEqual(["Lantern", "Lantern/Harbour", "Lantern/Meadow"]);
    view = await change("PUT", "/v1/categories/order", {
      groupId,
      parentId: null,
      ids: [id("Lantern")],
    });
    expect(tree(view)["Small"]).toEqual(["Lantern", "Lantern/Harbour", "Lantern/Meadow"]);
  });

  it("takes its parent's place when that is removed, and no title goes", async () => {
    await nest("Harbour", "Meadow");
    await change("POST", "/v1/categories", { parentId: id("Meadow"), name: "Early" });
    const titles = (await library(manager)).length;
    expect(await status("DELETE", `/v1/categories/${id("Meadow")}`)).toBe(400);
    const view = await change("DELETE", `/v1/categories/${id("Meadow")}`, {
      foldersTo: id("Harbour"),
    });
    expect(tree(view)["Small"]).toEqual(["Lantern", "Harbour", "Early"]);
    expect((await library(manager)).length).toBe(titles);
    expect((await film("Meadow")).categoryIds).toEqual([id("Harbour")]);
  });

  it("stays in its parent when their group is removed", async () => {
    await nest("Meadow", "Lantern");
    const view = await change("DELETE", `/v1/categories/groups/${groups["Small"] ?? ""}`, {
      moveTo: groups[""],
    });
    expect(tree(view)).toEqual({ "": ["Films", "Lantern", "Lantern/Meadow", "Harbour"] });
  });

  it("counts for its parent when files are converted", async () => {
    await nest("Meadow", "Lantern");
    await nest("Harbour", "Lantern");
    const store = new ConversionStore(db, Date.now);
    const of = (name: string): number =>
      store.assetsOf({ kind: "category", categoryId: id(name) })?.length ?? -1;
    expect([of("Lantern"), of("Meadow"), of("Films")]).toEqual([3, 1, 1]);
    expect(store.assetsOf({ kind: "category", categoryId: "nope" })).toBeNull();
  });

  it("brings the library to every app", async () => {
    const first = await call<{ cursor: string }>("GET", "/v1/library");
    const { revision } = await setup();
    const view = await nest("Meadow", "Lantern");
    expect(view.revision).toBe(revision + 1);
    const next = await call<{ cursor: string }>(
      "GET",
      `/v1/library?cursor=${encodeURIComponent(first.body.cursor)}`,
    );
    expect(next.body.cursor).not.toBe(first.body.cursor);
  });

  it("travels with a backup, and is nothing new for an older catalogue", async () => {
    const view = await nest("Meadow", "Lantern");
    const backup = await createBackup(db, join(dir, "backups"), null);
    restoreBackup(backup.path, join(dir, "elsewhere"));
    const restored = new Database(join(dir, "elsewhere", "lobby.db"));
    expect(tree(new Categories(restored).view())).toEqual(tree(view));
    restored.close();

    const path = join(dir, "old.db");
    const old = new DatabaseSync(path);
    old.exec(
      "create table schema_migration (version integer primary key, name text not null, applied_at integer not null) strict",
    );
    for (const migration of migrations.filter((one) => one.version < 14)) {
      old.exec(migration.sql);
      old.exec(`insert into schema_migration values (${String(migration.version)}, 'x', 1)`);
    }
    old.exec(`insert into category_group (id, name, position) values ('g', null, 0);
      insert into category (id, group_id, name, position) values ('c', 'g', 'Lantern', 0);
      insert into profile (id, name, color, created_at, kids_json) values ('p', 'P', 'red', 1,
        '{"allowedGroupIds":["g"],"allowedCategoryIds":[],"allowedItemIds":[],"blockedItemIds":[]}')`);
    old.close();
    const upgraded = new Database(path);
    expect(tree(new Categories(upgraded).view())).toEqual({ "": ["Lantern"] });
    expect(upgraded.all("pragma foreign_key_check")).toEqual([]);
    upgraded.close();
  });
});

describe("an app from before", () => {
  it("sees one list, and orders, moves and edits with it", async () => {
    await nest("Harbour", "Lantern");
    await nest("Meadow", "Lantern");
    const read = await call<CategoryView>("GET", "/v1/categories");
    // Without limits it reads the names and entries alone, and gets every title by its own.
    expect(read.body.groups[1]?.categories).toEqual(["Lantern", "Harbour", "Meadow"]);
    let view = await change("PUT", "/v1/categories/order", {
      groupId: groups["Small"],
      ids: [id("Meadow"), id("Lantern"), id("Harbour")],
    });
    expect(tree(view)["Small"]).toEqual(["Lantern", "Lantern/Meadow", "Lantern/Harbour"]);
    view = await change("PATCH", `/v1/categories/${id("Meadow")}`, { name: "Field" });
    expect(tree(view)["Small"]).toEqual(["Lantern", "Lantern/Field", "Lantern/Harbour"]);
    view = await change("PATCH", `/v1/categories/${id("Meadow")}`, { groupId: groups["Small"] });
    expect(tree(view)["Small"]).toEqual(["Lantern", "Lantern/Field", "Lantern/Harbour"]);
    // Out of the group is out of its parent.
    view = await change("PATCH", `/v1/categories/${id("Meadow")}`, { groupId: groups[""] });
    expect(tree(view)).toEqual({ "": ["Films", "Field"], Small: ["Lantern", "Lantern/Harbour"] });
  });

  it("does not take away what is blocked by category when it changes the limits", async () => {
    await limit({ allowedGroupIds: [groups["Small"] ?? ""], blockedCategoryIds: [id("Meadow")] });
    const reply = await call<{ kids: KidsSettings }>("PATCH", `/v1/profiles/${kid}`, {
      kids: {
        allowedGroupIds: [groups["Small"], groups[""]],
        allowedCategoryIds: [],
        allowedItemIds: [],
        blockedItemIds: [],
      },
    });
    expect(reply.body.kids.blockedCategoryIds).toEqual([id("Meadow")]);
    expect(await seen()).toEqual(["Films", "Harbour", "Lantern"]);
  });

  it("is refused, with words to show, what would let a kids viewer see more", async () => {
    await nest("Meadow", "Lantern");
    await limit({ allowedGroupIds: [groups[""] ?? ""] });
    const reply = await attempt("PATCH", `/v1/categories/${id("Lantern")}`, {
      groupId: groups[""],
    });
    expect(reply.status).toBe(409);
    expect(reply.body.error?.code).toBe("kids_confirmation");
    expect(reply.body.error?.message).toContain("Small one");
    // Where nothing is nested or blocked it goes on as it did.
    await change("PATCH", `/v1/categories/${id("Harbour")}`, { groupId: groups[""] });
    expect(await seen()).toEqual(["Films", "Harbour"]);
  });
});

describe("kids limits", () => {
  it("allow and block a category with those inside it, or one inside by itself", async () => {
    await nest("Meadow", "Lantern");
    await nest("Harbour", "Lantern");
    await limit({ allowedCategoryIds: [id("Lantern")] });
    expect(await seen()).toEqual(["Harbour", "Lantern", "Meadow"]);
    await limit({ allowedCategoryIds: [id("Meadow")] });
    expect(await seen()).toEqual(["Meadow"]);
    await limit({ allowedCategoryIds: [id("Lantern")], blockedCategoryIds: [id("Meadow")] });
    expect(await seen()).toEqual(["Harbour", "Lantern"]);
    // Blocked wins, whatever allows it.
    await limit({
      allowedGroupIds: [groups["Small"] ?? "", groups[""] ?? ""],
      allowedCategoryIds: [id("Meadow")],
      allowedItemIds: [(await film("Harbour")).id],
      blockedCategoryIds: [id("Lantern")],
    });
    expect(await seen()).toEqual(["Films"]);
    // A title in a blocked and an allowed category.
    const chosen = await film("Films");
    await choose(chosen, [id("Films"), id("Meadow")]);
    expect(await seen()).toEqual([]);
    const gone = await call("GET", `/v1/items/${chosen.id}`, undefined, child.token);
    expect(gone.status).toBe(404);
  });

  it("show the parent of what is allowed, with nothing else of it", async () => {
    await nest("Meadow", "Lantern");
    await nest("Harbour", "Lantern");
    for (const name of ["Lantern", "Meadow", "Harbour"]) {
      db.run("insert into logo (id, data, width, height) values (?, x'00', 1, 1)", [`l-${name}`]);
      db.run("update category set logo_id = ? where id = ?", [`l-${name}`, id(name)]);
    }
    await limit({ allowedCategoryIds: [id("Meadow")] });
    const view = await call<CategoryView>("GET", "/v1/categories", undefined, child.token);
    expect(tree(view.body)).toEqual({ "": [], Small: ["Lantern", "Lantern/Meadow"] });
    const logo = async (name: string): Promise<number> =>
      (
        await app.request(`/v1/logos/l-${name}`, {
          headers: { Authorization: `Bearer ${child.token}` },
        })
      ).status;
    expect([await logo("Lantern"), await logo("Meadow"), await logo("Harbour")]).toEqual([
      200, 200, 404,
    ]);
    for (const item of await library(child.token)) expect(item.categoryIds).toEqual([id("Meadow")]);
  });

  it("are the same for what a manager puts on the device", async () => {
    await nest("Meadow", "Lantern");
    for (const name of ["Meadow", "Harbour"]) {
      const added = await call("POST", `/v1/devices/${child.id}/wanted`, {
        kind: "item",
        itemId: (await film(name)).id,
      });
      expect(added.status).toBeLessThan(300);
    }
    await limit({ allowedCategoryIds: [id("Lantern")] });
    const wanted = await call<{ assets: { itemId: string }[] }>(
      "GET",
      "/v1/me/wanted",
      undefined,
      child.token,
    );
    expect(wanted.body.assets.map((one) => one.itemId)).toEqual([(await film("Meadow")).id]);
  });

  it("need a yes before a move lets a kids viewer see more", async () => {
    await limit({ allowedCategoryIds: [id("Lantern")] });
    const before = await setup();
    const path = `/v1/categories/${id("Meadow")}`;
    const tried = await attempt("PATCH", path, { parentId: id("Lantern"), dryRun: true });
    expect(tried.status).toBe(200);
    expect(tried.body).toMatchObject({ dryRun: true, needsConfirmation: true, undo: null });
    expect(tree(tried.body)["Small"]).toEqual(["Lantern", "Lantern/Meadow", "Harbour"]);
    expect(tried.body.kidsChanges).toEqual([
      {
        profileId: kid,
        name: "Small one",
        appearing: { count: 1, titles: [{ id: (await film("Meadow")).id, title: "Meadow One" }] },
        disappearing: { count: 0, titles: [] },
      },
    ]);
    // Nothing happened, and nothing of it is remembered.
    expect(await setup()).toEqual(before);
    expect(await seen()).toEqual(["Lantern"]);

    const refused = await attempt("PATCH", path, { parentId: id("Lantern") });
    expect([refused.status, refused.body.error?.code]).toEqual([409, "kids_confirmation"]);
    expect(refused.body.groups).toEqual(before.groups);
    expect(refused.body.kidsToken).toBe(tried.body.kidsToken);
    expect(await status("PATCH", path, { parentId: id("Lantern"), kidsToken: "other" })).toBe(409);
    expect(await setup()).toEqual(before);
    expect(await seen()).toEqual(["Lantern"]);

    // The yes is to what was shown, and to nothing more.
    const chosen = await film("Films");
    await choose(chosen, [id("Meadow")]);
    const { kidsToken } = tried.body;
    expect(await status("PATCH", path, { parentId: id("Lantern"), kidsToken })).toBe(409);
    const again = await attempt("PATCH", path, { parentId: id("Lantern") });
    const done = await change("PATCH", path, {
      parentId: id("Lantern"),
      kidsToken: again.body.kidsToken,
    });
    expect(done.kidsChanges[0]?.appearing.count).toBe(2);
    expect(await seen()).toEqual(["Films", "Lantern", "Meadow"]);
  });

  it("say what is no longer seen, and do not ask about it", async () => {
    await nest("Meadow", "Lantern");
    await limit({ allowedCategoryIds: [id("Lantern")] });
    expect(await seen()).toEqual(["Lantern", "Meadow"]);
    const view = await nest("Meadow", null);
    expect(view.kidsChanges[0]?.disappearing.titles.map((one) => one.title)).toEqual([
      "Meadow One",
    ]);
    expect(view.kidsChanges[0]?.appearing.count).toBe(0);
    expect(await seen()).toEqual(["Lantern"]);
  });

  it("ask before anything leaves what is blocked", async () => {
    await nest("Meadow", "Lantern");
    await limit({
      allowedGroupIds: [groups["Small"] ?? "", groups[""] ?? ""],
      blockedCategoryIds: [id("Lantern")],
    });
    expect(await seen()).toEqual(["Films", "Harbour"]);
    const lantern = `/v1/categories/${id("Lantern")}`;
    const folder = (await setup()).folders.find((one) => one.name === "Lantern")?.id ?? "";
    const asked: [string, string, object][] = [
      ["PATCH", `/v1/categories/${id("Meadow")}`, { parentId: null }],
      ["PATCH", `/v1/categories/${id("Meadow")}`, { groupId: groups[""] }],
      ["DELETE", lantern, { foldersTo: "none" }],
      ["DELETE", lantern, { foldersTo: id("Harbour") }],
      ["PUT", `/v1/categories/folders/${folder}`, { categoryId: id("Harbour") }],
      ["PUT", `/v1/categories/folders/${folder}`, { categoryId: null }],
    ];
    for (const [method, path, body] of asked) {
      expect([path, body, await status(method, path, body)]).toEqual([path, body, 409]);
      const tried = await change(method, path, { ...body, dryRun: true });
      expect(tried.needsConfirmation).toBe(true);
    }
    expect(await seen()).toEqual(["Films", "Harbour"]);
    // Into it needs no yes.
    await nest("Harbour", "Lantern");
    expect(await seen()).toEqual(["Films"]);
    const refused = await attempt("DELETE", lantern, { foldersTo: "none" });
    await change("DELETE", lantern, { foldersTo: "none", kidsToken: refused.body.kidsToken });
    expect(await seen()).toEqual(["Films", "Harbour", "Lantern", "Meadow"]);
  });

  it("hold with a token for what is not nested too", async () => {
    await limit({ allowedGroupIds: [groups[""] ?? ""] });
    const path = `/v1/categories/${id("Harbour")}`;
    const none = await change("PATCH", path, { color: "red", dryRun: true });
    expect(none).toMatchObject({ needsConfirmation: false, kidsChanges: [] });
    const { kidsToken } = none;
    expect(await status("PATCH", path, { groupId: groups[""], kidsToken })).toBe(409);
    const tried = await change("PATCH", path, { groupId: groups[""], dryRun: true });
    expect(tried.needsConfirmation).toBe(false);
    expect(tried.kidsChanges).toHaveLength(1);
    await change("PATCH", path, { groupId: groups[""], kidsToken: tried.kidsToken });
    expect(await seen()).toEqual(["Films", "Harbour"]);
  });

  it("say nothing of a viewer that was removed", async () => {
    await limit({ allowedCategoryIds: [id("Lantern")] });
    await call("PATCH", `/v1/devices/${child.id}`, { kidsProfileId: null });
    await call("DELETE", `/v1/profiles/${kid}`);
    expect((await nest("Meadow", "Lantern")).kidsChanges).toEqual([]);
  });
});

describe("arranging several at once", () => {
  const three = (): object => ({
    create: [{ key: "top", groupId: groups["Small"], name: "Lantern", icon: "star", color: "red" }],
    categories: [
      { id: id("Harbour"), parentId: "new:top", color: "teal" },
      { id: id("Lantern"), parentId: "new:top", name: "Early" },
      { id: id("Meadow"), parentId: "new:top" },
    ],
    order: [
      {
        groupId: groups["Small"],
        parentId: "new:top",
        ids: [id("Meadow"), id("Harbour"), id("Lantern")],
      },
    ],
  });

  it("puts three under a new one of a name that only then is free, and takes it back", async () => {
    const before = await setup();
    const view = await change("POST", "/v1/categories/arrange", three());
    expect(tree(view)["Small"]).toEqual([
      "Lantern",
      "Lantern/Meadow",
      "Lantern/Harbour",
      "Lantern/Early",
    ]);
    const top = view.groups[1]?.entries[0];
    expect(view.created).toEqual({ top: top?.id });
    expect(top).toMatchObject({ icon: "star", color: "red", parentId: null });
    expect((await film("Lantern")).categories).toEqual(["Early"]);
    expect(view.revision).toBe(before.revision + 1);
    expect((await setup()).undo).toBe(view.undo);

    const back = await change("POST", "/v1/categories/arrange/undo", { token: view.undo });
    expect(back.groups).toEqual(before.groups);
    expect(back.folders).toEqual(before.folders);
    expect(back.undo).toBeNull();
    expect((await film("Lantern")).categories).toEqual(["Lantern"]);
    expect(await status("POST", "/v1/categories/arrange/undo", { token: view.undo })).toBe(409);
  });

  it("looks only at the result: names change places, one level turns around", async () => {
    await nest("Meadow", "Lantern");
    const view = await change("POST", "/v1/categories/arrange", {
      categories: [
        { id: id("Lantern"), parentId: id("Meadow"), name: "Meadow" },
        { id: id("Meadow"), parentId: null, name: "Lantern" },
      ],
    });
    expect(tree(view)["Small"]).toEqual(["Harbour", "Lantern", "Lantern/Meadow"]);
    expect(view.groups[1]?.entries[1]?.id).toBe(id("Meadow"));
    const back = await change("POST", "/v1/categories/arrange/undo", { token: view.undo });
    expect(tree(back)["Small"]).toEqual(["Lantern", "Lantern/Meadow", "Harbour"]);
  });

  it("does all of it or nothing", async () => {
    const before = await setup();
    const small = groups["Small"];
    const refused: [object, number][] = [
      [{}, 400],
      [{ categories: [{ id: id("Meadow"), parentId: id("Lantern") }, { id: "nope" }] }, 404],
      [{ categories: [{ id: id("Meadow"), parentId: "new:none" }] }, 404],
      [{ categories: [{ id: id("Meadow") }, { id: id("Meadow") }] }, 400],
      [
        {
          categories: [
            { id: id("Meadow"), parentId: id("Lantern") },
            { id: id("Lantern"), parentId: id("Harbour") },
          ],
        },
        400,
      ],
      [
        {
          categories: [
            { id: id("Meadow"), parentId: id("Lantern") },
            { id: id("Lantern"), parentId: id("Meadow") },
          ],
        },
        400,
      ],
      [{ categories: [{ id: id("Meadow"), parentId: id("Lantern"), name: "harbour" }] }, 400],
      [{ create: [{ key: "a", groupId: small, name: "films" }] }, 400],
      [{ create: [{ key: "a b", groupId: small, name: "X" }] }, 400],
      [{ create: [{ key: "a", name: "X" }] }, 400],
      [
        {
          create: [
            { key: "a", groupId: small, name: "X" },
            { key: "a", groupId: small, name: "Y" },
          ],
        },
        400,
      ],
      [
        {
          categories: [{ id: id("Meadow"), parentId: id("Lantern") }],
          order: [{ groupId: small, ids: [id("Lantern")] }],
        },
        400,
      ],
      [{ create: "all" }, 400],
    ];
    for (const [body, expected] of refused) {
      expect([body, await status("POST", "/v1/categories/arrange", body)]).toEqual([
        body,
        expected,
      ]);
    }
    expect(await setup()).toEqual(before);
    const stale = { revision: before.revision + 1, categories: [{ id: id("Meadow") }] };
    expect((await call("POST", "/v1/categories/arrange", stale)).status).toBe(409);
    expect((await call("POST", "/v1/categories/arrange", stale, child.token)).status).toBe(404);
  });

  it("can be taken back until something else changes", async () => {
    const view = await change("POST", "/v1/categories/arrange", three());
    await change("PATCH", `/v1/categories/${id("Meadow")}`, { color: "pink" });
    expect((await setup()).undo).toBeNull();
    expect(await status("POST", "/v1/categories/arrange/undo", { token: view.undo })).toBe(409);
    expect(await status("POST", "/v1/categories/arrange/undo", {})).toBe(400);
  });

  it("asks about kids there and back", async () => {
    await limit({ allowedCategoryIds: [id("Lantern")], blockedCategoryIds: [id("Harbour")] });
    const body = {
      categories: [
        { id: id("Meadow"), parentId: id("Lantern") },
        { id: id("Harbour"), parentId: id("Lantern") },
      ],
    };
    const refused = await attempt("POST", "/v1/categories/arrange", body);
    expect(refused.body.error?.code).toBe("kids_confirmation");
    expect(refused.body.kidsChanges[0]?.appearing.titles.map((one) => one.title)).toEqual([
      "Meadow One",
    ]);
    const view = await change("POST", "/v1/categories/arrange", {
      ...body,
      kidsToken: refused.body.kidsToken,
    });
    expect(await seen()).toEqual(["Lantern", "Meadow"]);
    // Fewer again: no question. Then the other way around.
    await change("POST", "/v1/categories/arrange/undo", { token: view.undo });
    expect(await seen()).toEqual(["Lantern"]);

    await limit({
      allowedGroupIds: [groups["Small"] ?? ""],
      blockedCategoryIds: [id("Lantern")],
    });
    const less = await change("POST", "/v1/categories/arrange", body);
    expect(await seen()).toEqual([]);
    const undo = { token: less.undo };
    const dry = await change("POST", "/v1/categories/arrange/undo", { ...undo, dryRun: true });
    expect(dry.needsConfirmation).toBe(true);
    expect(await status("POST", "/v1/categories/arrange/undo", undo)).toBe(409);
    expect((await setup()).undo).toBe(less.undo);
    await change("POST", "/v1/categories/arrange/undo", { ...undo, kidsToken: dry.kidsToken });
    expect(await seen()).toEqual(["Harbour", "Meadow"]);
  });

  it("takes back a new one that titles were put in, and keeps the titles", async () => {
    const view = await change("POST", "/v1/categories/arrange", three());
    const chosen = await film("Films");
    await choose(chosen, [view.created?.["top"]]);
    const titles = (await library(manager)).length;
    await change("POST", "/v1/categories/arrange/undo", { token: view.undo });
    expect((await film("Films")).categoryIds).toEqual([id("Films")]);
    expect((await library(manager)).length).toBe(titles);
  });
});

describe("the household's own studio, in one step", () => {
  // Lantern stands for the studio's first folder, Meadow for its second, Harbour for its films
  // with actors; Films stays a category of its own.
  it("makes a parent with the old logo and colour, renames and moves three, and undoes it", async () => {
    db.run("insert into logo (id, data, width, height) values ('studio', x'00', 4, 2)");
    db.run("update category set logo_id = 'studio', color = 'blue' where id = ?", [id("Lantern")]);
    await change("PATCH", `/v1/categories/${id("Meadow")}`, { icon: "sparkles" });
    await choose(await film("Films"), [id("Meadow")]);
    await limit({ allowedCategoryIds: [id("Lantern"), id("Meadow")] });
    expect(await seen()).toEqual(["Films", "Lantern", "Meadow"]);
    const before = await setup();
    const small = groups["Small"];
    const body = {
      create: [
        { key: "studio", groupId: small, name: "Lantern", color: "blue", logoFrom: id("Lantern") },
      ],
      categories: [
        { id: id("Lantern"), parentId: "new:studio", name: "Classics" },
        { id: id("Meadow"), parentId: "new:studio", name: "Sequels" },
        { id: id("Harbour"), parentId: "new:studio", name: "With Actors" },
      ],
      order: [
        { groupId: small, parentId: null, ids: ["new:studio"] },
        {
          groupId: small,
          parentId: "new:studio",
          ids: [id("Lantern"), id("Meadow"), id("Harbour")],
        },
      ],
    };
    const tried = await change("POST", "/v1/categories/arrange", { ...body, dryRun: true });
    expect(tried).toMatchObject({ needsConfirmation: false, kidsChanges: [] });
    const view = await change("POST", "/v1/categories/arrange", body);
    expect(tree(view)).toEqual({
      "": ["Films"],
      Small: ["Lantern", "Lantern/Classics", "Lantern/Sequels", "Lantern/With Actors"],
    });
    const [parent, classics, sequels] = view.groups[1]?.entries ?? [];
    expect(parent).toMatchObject({ color: "blue", logo: { id: "studio" } });
    expect(classics).toMatchObject({ id: id("Lantern"), color: "blue", logo: { id: "studio" } });
    expect(sequels).toMatchObject({ id: id("Meadow"), icon: "sparkles" });
    expect(view.folders).toEqual(before.folders);
    expect((await film("Films")).categoryIds).toEqual([id("Meadow")]);
    expect((await film("Lantern")).categories).toEqual(["Classics"]);
    // The limits name the same categories, so the viewer sees exactly what they saw.
    expect(view.kidsChanges).toEqual([]);
    expect(await seen()).toEqual(["Films", "Lantern", "Meadow"]);

    const back = await change("POST", "/v1/categories/arrange/undo", { token: view.undo });
    expect(back.groups).toEqual(before.groups);
    expect(back.logos).toEqual(before.logos);
    expect(back.folders).toEqual(before.folders);
    expect(await seen()).toEqual(["Films", "Lantern", "Meadow"]);
    expect(db.get("select count(*) as n from logo")).toEqual({ n: 1 });
  });
});

/** As the enricher keeps them, and with a new library revision as it makes one. */
function studios(name: string, made: Studio[]): Promise<void> {
  return film(name).then((one) => {
    new Studios(db).save(one.id, made);
    db.run("update item set revision = ? where id = ?", [db.nextRevision(), one.id]);
  });
}
const studio = (id: number, name: string, kind: Studio["kind"] = "company"): Studio => ({
  kind,
  id,
  name,
  logoPath: `/studiologo${String(id)}.png`,
  country: null,
});

describe("a category that follows studios", () => {
  beforeEach(async () => {
    await studios("Lantern", [studio(11, "Glow Animation Studios"), studio(12, "Other Works")]);
    await studios("Meadow", [studio(13, "Glow Pictures")]);
    await studios("Films", [studio(11, "Glow Animation Studios")]);
  });

  it("takes in their titles beside its own, and takes none out of theirs", async () => {
    const view = await change("POST", "/v1/categories", {
      groupId: groups["Small"],
      name: "Glow",
      rule: { studioIds: ["company:13", "company:11"] },
    });
    const glow = view.groups[1]?.entries.find((one) => one.name === "Glow");
    expect(glow?.rule).toEqual({ studioIds: ["company:11", "company:13"] });
    for (const name of ["Lantern", "Meadow", "Films"]) {
      expect((await film(name)).ruleCategoryIds).toEqual([glow?.id]);
    }
    expect((await film("Films")).categoryIds).toEqual([id("Films")]);
    expect((await film("Harbour")).ruleCategoryIds).toEqual([]);
    const store = new ConversionStore(db, Date.now);
    expect(store.assetsOf({ kind: "category", categoryId: glow?.id ?? "" })).toHaveLength(3);
    await change("PATCH", `/v1/categories/${glow?.id ?? ""}`, { rule: null });
    expect((await film("Films")).ruleCategoryIds).toEqual([]);
    for (const rule of [{ studioIds: [] }, { studioIds: ["company:x"] }, { studioIds: "a" }, 3]) {
      expect(await status("PATCH", `/v1/categories/${glow?.id ?? ""}`, { rule })).toBe(400);
    }
  });

  it("brings titles to kids only when it is allowed itself, and blocks what it takes in", async () => {
    const view = await change("POST", "/v1/categories", {
      groupId: groups["Small"],
      name: "Glow",
      rule: { studioIds: ["company:11"] },
    });
    const glow = view.groups[1]?.entries.find((one) => one.name === "Glow")?.id ?? "";
    // Its group is allowed: that was for what was put there by hand.
    await limit({ allowedGroupIds: [groups["Small"] ?? ""] });
    expect(await seen()).toEqual(["Harbour", "Lantern", "Meadow"]);
    await limit({ allowedCategoryIds: [glow] });
    expect(await seen()).toEqual(["Films", "Lantern"]);
    const kidsFilm = (await library(child.token)).find((one) => one.title === "Films One");
    expect(kidsFilm).toMatchObject({ categoryIds: [id("Films")], ruleCategoryIds: [glow] });
    await limit({
      allowedGroupIds: [groups["Small"] ?? "", groups[""] ?? ""],
      blockedCategoryIds: [glow],
    });
    expect(await seen()).toEqual(["Harbour", "Meadow"]);
  });

  it("asks before a new rule lets a kids viewer see more", async () => {
    const view = await change("POST", "/v1/categories", { groupId: groups["Small"], name: "Glow" });
    const glow = view.groups[1]?.entries.find((one) => one.name === "Glow")?.id ?? "";
    await limit({ allowedCategoryIds: [glow] });
    const path = `/v1/categories/${glow}`;
    const refused = await attempt("PATCH", path, { rule: { studioIds: ["company:11"] } });
    expect(refused.body.error?.code).toBe("kids_confirmation");
    expect(refused.body.kidsChanges[0]?.appearing.count).toBe(2);
    await change("PATCH", path, {
      rule: { studioIds: ["company:11"] },
      kidsToken: refused.body.kidsToken,
    });
    expect(await seen()).toEqual(["Films", "Lantern"]);
  });

  it("is suggested for a studio with enough titles, with its companies together", async () => {
    const reply = await call<{ min: number; suggestions: Suggested[] }>(
      "GET",
      "/v1/categories/suggestions?min=2",
    );
    expect(reply.body.min).toBe(2);
    expect(reply.body.suggestions).toHaveLength(1);
    const [glow] = reply.body.suggestions;
    expect(glow).toMatchObject({
      name: "Glow Animation Studios",
      count: 3,
      logoPath: "/studiologo11.png",
      categoryId: null,
    });
    expect(glow?.studios.map((one) => [one.id, one.titles])).toEqual([
      ["company:11", 2],
      ["company:13", 1],
    ]);
    expect(glow?.titles.map((one) => one.title)).toEqual([
      "Films One",
      "Lantern One",
      "Meadow One",
    ]);
    // Eight by default.
    expect(
      (await call<{ suggestions: Suggested[] }>("GET", "/v1/categories/suggestions")).body
        .suggestions,
    ).toEqual([]);
    expect((await call("GET", "/v1/categories/suggestions?min=0")).status).toBe(400);
    expect((await call("GET", "/v1/categories/suggestions", undefined, child.token)).status).toBe(
      404,
    );

    const { revision } = await setup();
    const accepted = await call("POST", `/v1/categories/suggestions/${glow?.id ?? ""}/accept`, {
      revision,
      groupId: groups["Small"],
      name: "Glow",
    });
    expect(accepted.status).toBe(200);
    const made = accepted.body.groups[1]?.entries.find((one) => one.name === "Glow");
    expect(made?.rule).toEqual({ studioIds: ["company:11", "company:13"] });
    // No TMDB here: a category without a logo all the same.
    expect(made?.logo).toBeNull();
    const after = await call<{ suggestions: Suggested[] }>(
      "GET",
      "/v1/categories/suggestions?min=1",
    );
    expect(after.body.suggestions.map((one) => one.name)).toEqual(["Other Works"]);
  });

  it("forgets a suggestion that was waved away, and can give a rule to a category there is", async () => {
    const list = async (): Promise<Suggested[]> =>
      (await call<{ suggestions: Suggested[] }>("GET", "/v1/categories/suggestions?min=1")).body
        .suggestions;
    const other = (await list()).find((one) => one.name === "Other Works");
    const dismissed = await call<{ suggestions: Suggested[] }>(
      "POST",
      `/v1/categories/suggestions/${other?.id ?? ""}/dismiss?min=1`,
    );
    expect(dismissed.body.suggestions.map((one) => one.name)).toEqual(["Glow Animation Studios"]);
    expect((await call("POST", "/v1/categories/suggestions/nope/dismiss")).status).toBe(404);
    // Its studio comes with another title: still not suggested.
    await studios("Harbour", [studio(12, "Other Works")]);
    expect((await list()).map((one) => one.name)).toEqual(["Glow Animation Studios"]);

    const glow = (await list())[0];
    const { revision } = await setup();
    const reply = await call("POST", `/v1/categories/suggestions/${glow?.id ?? ""}/accept`, {
      revision,
      categoryId: id("Lantern"),
    });
    expect(reply.status).toBe(200);
    expect((await film("Meadow")).ruleCategoryIds).toEqual([id("Lantern")]);
    expect(await list()).toEqual([]);
  });

  it("joins a suggestion's studios to the rule a category has", async () => {
    const lantern = `/v1/categories/${id("Lantern")}`;
    await change("PATCH", lantern, { rule: { studioIds: ["company:12"] } });
    const glow = (
      await call<{ suggestions: Suggested[] }>("GET", "/v1/categories/suggestions?min=1")
    ).body.suggestions.find((one) => one.name === "Glow Animation Studios");
    const view = await change("POST", `/v1/categories/suggestions/${glow?.id ?? ""}/accept`, {
      categoryId: id("Lantern"),
    });
    const entry = view.groups[1]?.entries.find((one) => one.id === id("Lantern"));
    expect(entry?.rule).toEqual({ studioIds: ["company:11", "company:12", "company:13"] });
  });

  it("puts several suggestions in one place at once, never by itself at the top", async () => {
    const list = async (): Promise<Suggested[]> =>
      (await call<{ suggestions: Suggested[] }>("GET", "/v1/categories/suggestions?min=1")).body
        .suggestions;
    const both = (await list()).map((one) => one.id);
    expect(both).toHaveLength(2);
    const path = "/v1/categories/suggestions/accept";
    // A name for each of several is not one name.
    expect(await status("POST", path, { ids: both, groupId: groups["Small"], name: "X" })).toBe(
      400,
    );
    expect(await status("POST", path, { ids: [...both, "nope"], groupId: groups["Small"] })).toBe(
      404,
    );
    expect(await status("POST", path, { ids: [both[0], both[0]], groupId: groups["Small"] })).toBe(
      400,
    );

    // Each inside a category: none of them at the top.
    const tried = await change("POST", path, { ids: both, parentId: id("Lantern"), dryRun: true });
    expect(tried.dryRun).toBe(true);
    expect(tree(await setup())["Small"]).toEqual(["Lantern", "Meadow", "Harbour"]);
    const each = await change("POST", path, {
      ids: both,
      parentId: id("Lantern"),
      kidsToken: tried.kidsToken,
    });
    expect(tree(each)["Small"]).toEqual([
      "Lantern",
      "Lantern/Glow Animation Studios",
      "Lantern/Other Works",
      "Meadow",
      "Harbour",
    ]);
    expect((each as Setup & { categoryIds: string[] }).categoryIds).toHaveLength(2);
    expect(await list()).toEqual([]);
  });

  it("makes one category of several suggestions, or joins them to one there is", async () => {
    const both = (
      await call<{ suggestions: Suggested[] }>("GET", "/v1/categories/suggestions?min=1")
    ).body.suggestions.map((one) => one.id);
    const path = "/v1/categories/suggestions/accept";
    const one = await change("POST", path, {
      ids: both,
      groupId: groups["Small"],
      together: true,
      name: "Studios",
    });
    const made = one.groups[1]?.entries.find((entry) => entry.name === "Studios");
    expect(made).toMatchObject({
      parentId: null,
      rule: { studioIds: ["company:11", "company:12", "company:13"] },
    });
    // Undone by hand, then joined to Harbour instead.
    await change("DELETE", `/v1/categories/${made?.id ?? ""}`);
    const joined = await change("POST", path, { ids: both, categoryId: id("Harbour") });
    expect(joined.groups[1]?.entries.find((entry) => entry.id === id("Harbour"))?.rule).toEqual({
      studioIds: ["company:11", "company:12", "company:13"],
    });
    expect((await film("Lantern")).ruleCategoryIds).toEqual([id("Harbour")]);
  });

  it("asks before suggestions in a category let a kids viewer see more", async () => {
    await limit({ allowedCategoryIds: [id("Harbour")] });
    const both = (
      await call<{ suggestions: Suggested[] }>("GET", "/v1/categories/suggestions?min=1")
    ).body.suggestions.map((one) => one.id);
    const path = "/v1/categories/suggestions/accept";
    const tried = await change("POST", path, {
      ids: both,
      categoryId: id("Harbour"),
      dryRun: true,
    });
    expect(tried.needsConfirmation).toBe(true);
    const refused = await attempt("POST", path, { ids: both, categoryId: id("Harbour") });
    expect(refused.body.error?.code).toBe("kids_confirmation");
    expect(await seen()).toEqual(["Harbour"]);
    await change("POST", path, {
      ids: both,
      categoryId: id("Harbour"),
      kidsToken: tried.kidsToken,
    });
    expect(await seen()).toEqual(["Films", "Harbour", "Lantern", "Meadow"]);
  });
});

interface Suggested {
  id: string;
  name: string;
  count: number;
  studios: { id: string; name: string; titles: number }[];
  titles: { id: string; title: string }[];
  logoPath: string | null;
  categoryId: string | null;
}

describe("merging categories", () => {
  const merge = (into: string, names: string[], extra: object = {}): Promise<Reply<Setup>> =>
    attempt("POST", "/v1/categories/merge", { into: id(into), ids: names.map(id), ...extra });

  it("joins folders, chosen titles, rules and those inside into one, and removes no title", async () => {
    await nest("Meadow", "Harbour");
    await change("PATCH", `/v1/categories/${id("Harbour")}`, {
      rule: { studioIds: ["company:5"] },
    });
    await change("PATCH", `/v1/categories/${id("Lantern")}`, {
      rule: { studioIds: ["company:4"] },
    });
    const chosen = await film("Films");
    await choose(chosen, [id("Harbour"), id("Films")]);
    const before = (await library(manager)).length;

    const reply = await merge("Lantern", ["Harbour"], { dryRun: true });
    expect(reply.body).toMatchObject({ dryRun: true, needsConfirmation: false });
    expect(tree(await setup())["Small"]).toEqual(["Lantern", "Harbour", "Harbour/Meadow"]);

    const done = await merge("Lantern", ["Harbour"], { kidsToken: reply.body.kidsToken });
    expect(done.status).toBe(200);
    expect(tree(done.body)["Small"]).toEqual(["Lantern", "Lantern/Meadow"]);
    const lantern = done.body.groups[1]?.entries.find((one) => one.id === id("Lantern"));
    expect(lantern?.rule).toEqual({ studioIds: ["company:4", "company:5"] });
    expect(done.body.folders.find((one) => one.name === "Harbour")?.categoryId).toBe(id("Lantern"));
    expect((await film("Harbour")).categoryIds).toEqual([id("Lantern")]);
    expect((await film("Films")).categoryIds.toSorted()).toEqual(
      [id("Lantern"), id("Films")].sort(),
    );
    expect((await library(manager)).length).toBe(before);
  });

  it("is refused for what does not fit", async () => {
    await nest("Meadow", "Lantern");
    const refused = async (into: string, names: string[]): Promise<number> =>
      (await merge(into, names)).status;
    expect(await refused("Lantern", ["Lantern"])).toBe(400);
    expect(await refused("Lantern", [])).toBe(400);
    expect(await refused("Lantern", ["Harbour", "Harbour"])).toBe(400);
    // Into one inside it, or what is inside one into one that is inside another.
    expect(await refused("Meadow", ["Lantern"])).toBe(400);
    expect(await refused("Meadow", ["Lantern", "Harbour"])).toBe(400);
    await nest("Harbour", "Lantern");
    expect(await refused("Harbour", ["Lantern"])).toBe(400);
    expect((await call("POST", "/v1/categories/merge", { revision: 0, ids: [] })).status).toBe(400);
    expect(tree(await setup())["Small"]).toEqual(["Lantern", "Lantern/Meadow", "Lantern/Harbour"]);
  });

  it("needs a yes before a kids viewer allowed the one that stays sees more", async () => {
    await limit({ allowedCategoryIds: [id("Lantern")] });
    const refused = await merge("Lantern", ["Meadow"]);
    expect([refused.status, refused.body.error?.code]).toEqual([409, "kids_confirmation"]);
    expect(refused.body.kidsChanges[0]?.appearing.titles.map((one) => one.title)).toEqual([
      "Meadow One",
    ]);
    expect(await seen()).toEqual(["Lantern"]);
    expect((await merge("Lantern", ["Meadow"], { kidsToken: "other" })).status).toBe(409);
    const done = await merge("Lantern", ["Meadow"], { kidsToken: refused.body.kidsToken });
    expect(done.status).toBe(200);
    expect(await seen()).toEqual(["Lantern", "Meadow"]);
  });

  it("is for managers only", async () => {
    const { revision } = await setup();
    const reply = await call(
      "POST",
      "/v1/categories/merge",
      { revision, into: id("Lantern"), ids: [id("Meadow")] },
      child.token,
    );
    expect(reply.status).toBeGreaterThanOrEqual(403);
  });
});
