// SPDX-License-Identifier: MPL-2.0
import { join } from "node:path";
import type { Hono } from "hono";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { Devices } from "../src/auth/devices.ts";
import { Database } from "../src/db/database.ts";
import { createApp, type AppEnv } from "../src/http/app.ts";
import { Catalogue } from "../src/library/catalogue.ts";
import { ItemReader, type ApiItem } from "../src/library/items.ts";
import { parseMediaPath, type SourceHint } from "../src/library/parse.ts";
import { ProgressStore } from "../src/progress.ts";
import { makeTempDir, removeDir } from "./support/media.ts";

const NOW = new Date(2027, 5, 15, 12).getTime();
const MINUTE = 60_000;
const DAY = 86_400_000;

interface Answer {
  total: number;
  offset: number;
  items: ApiItem[];
}

let dir: string;
let db: Database;
let catalogue: Catalogue;
let devices: Devices;
let app: Hono<AppEnv>;
let manager: string;
let files: number;

beforeEach(() => {
  dir = makeTempDir();
  db = new Database(join(dir, "lobby.db"));
  catalogue = new Catalogue(db, () => NOW);
  files = 0;
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
  app = createApp({
    db,
    devices,
    items: new ItemReader(db),
    progress: new ProgressStore(db, () => NOW),
    serverName: "Test",
    version: "0",
    isScanning: () => false,
    now: () => NOW,
  });
  for (const id of ["one", "two"]) {
    db.run("insert into profile (id, name, color, created_at) values (?, ?, 'red', 0)", [id, id]);
  }
});

afterEach(() => {
  db.close();
  removeDir(dir);
});

interface FileOptions {
  minutes?: number;
  width?: number;
  languages?: string[];
  addedDaysAgo?: number;
}

function addFile(relPath: string, hint: SourceHint, options: FileOptions = {}): string {
  const asset = `asset${String((files += 1))}`;
  const added = NOW - (options.addedDaysAgo ?? 400) * DAY;
  db.run(
    `insert into asset (id, source_id, rel_path, size, mtime_ms, revision, state, duration_ms, playability,
       container, first_seen_at, updated_at) values (?, ?, ?, 1, 1, '1', 'probed', ?, 'direct', 'mp4', ?, 0)`,
    [asset, hint, relPath, (options.minutes ?? 100) * MINUTE, added],
  );
  db.run(
    "insert into track (asset_id, idx, kind, codec, width, height, pix_fmt) values (?, 0, 'video', 'h264', ?, ?, 'yuv420p')",
    [asset, options.width ?? 1920, Math.round(((options.width ?? 1920) * 9) / 16)],
  );
  (options.languages ?? ["eng"]).forEach((language, index) => {
    db.run(
      "insert into track (asset_id, idx, kind, codec, language) values (?, ?, 'audio', 'aac', ?)",
      [asset, index + 1, language],
    );
  });
  const parsed = parseMediaPath(relPath, hint);
  db.run("update asset set parsed_json = ? where id = ?", [JSON.stringify(parsed), asset]);
  const ids = catalogue.linkAsset(asset, parsed, hint);
  for (const id of ids) {
    db.run("update item set added_at = ? where id = ?", [added, id]);
  }
  return ids[0] ?? "";
}

function genres(itemId: string, ...names: string[]): void {
  for (const name of names) {
    db.run("insert or ignore into genre (name) values (?)", [name]);
    db.run("insert into item_genre (item_id, genre_id) select ?, id from genre where name = ?", [
      itemId,
      name,
    ]);
  }
}

function studio(itemId: string, id: string, name: string): void {
  const [kind, number] = id.split(":");
  db.run(`insert or ignore into studio (id, kind, tmdb_id, name, seen_at) values (?, ?, ?, ?, 0)`, [
    id,
    kind ?? "company",
    Number(number),
    name,
  ]);
  db.run("insert into item_studio (item_id, studio_id, position) values (?, ?, 0)", [itemId, id]);
}

function votes(itemId: string, average: number, count: number, popularity = 10): void {
  db.run("update item set vote_average = ?, vote_count = ?, popularity = ? where id = ?", [
    average,
    count,
    popularity,
    itemId,
  ]);
}

function watched(profile: string, itemId: string, position: number, completed: boolean): void {
  db.run(
    `insert into progress (profile_id, item_id, position_ms, duration_ms, completed, revision, updated_at)
     values (?, ?, ?, ?, ?, 1, ?)`,
    [profile, itemId, position, 100 * MINUTE, completed ? 1 : 0, NOW],
  );
}

function episode(show: string, season: number, number: number, options: FileOptions = {}): string {
  const code = `S${String(season).padStart(2, "0")}E${String(number).padStart(2, "0")}`;
  addFile(`${show}/Season ${String(season)}/${show} ${code}.mkv`, "series", options);
  const row = db.get<{ id: string }>(
    `select episode.id from item as episode join item as season on season.id = episode.parent_id
     join item as show on show.id = season.parent_id
     where show.title = ? and season.season_number = ? and episode.episode_number = ?`,
    [show, season, number],
  );
  return row?.id ?? "";
}

function showId(title: string): string {
  return db.get<{ id: string }>("select id from item where kind = 'show' and title = ?", [title])
    ?.id as string;
}

async function ask(query: string, token = manager): Promise<{ status: number; body: Answer }> {
  const reply = await app.request(`/v1/library/query${query}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  return { status: reply.status, body: (await reply.json()) as Answer };
}

async function titles(query: string, token = manager): Promise<string[]> {
  const reply = await ask(query, token);
  expect(reply.status).toBe(200);
  expect(reply.body.total).toBe(reply.body.items.length);
  return reply.body.items.map((item) => item.title);
}

describe("filters", () => {
  let up: string;
  let heat: string;
  let short: string;
  let epic: string;
  let old: string;

  beforeEach(() => {
    up = addFile("Up (2009).mkv", "movies", { minutes: 96, addedDaysAgo: 3 });
    heat = addFile("Heat (1995).mkv", "movies", {
      minutes: 170,
      width: 3840,
      languages: ["eng", "fre"],
    });
    short = addFile("Piper (2016).mkv", "movies", { minutes: 6, addedDaysAgo: 20 });
    epic = addFile("Dune (2021).mkv", "movies", { minutes: 155, width: 3840, addedDaysAgo: 200 });
    old = addFile("Metropolis.mkv", "movies", { minutes: 120, languages: ["ger"] });
    genres(up, "Animation", "Adventure");
    genres(short, "Animation");
    genres(heat, "Crime", "Thriller");
    genres(epic, "Science Fiction", "Adventure");
    studio(up, "company:3", "Pixar");
    studio(short, "company:3", "Pixar");
    studio(epic, "company:923", "Legendary");
    votes(up, 7.96, 20_000, 80);
    votes(heat, 8.25, 9_000, 30);
    votes(epic, 7.8, 12_000, 150);
    votes(short, 8, 5);
    episode("Bluey", 1, 1, { minutes: 7, addedDaysAgo: 10 });
    episode("Bluey", 1, 2, { minutes: 8, addedDaysAgo: 2 });
    db.nextRevision();
  });

  it("lists every title by title without any", async () => {
    expect(await titles("")).toEqual(["Bluey", "Dune", "Heat", "Metropolis", "Piper", "Up"]);
  });

  it("narrows by kind, year, genre and studio", async () => {
    expect(await titles("?kind=show")).toEqual(["Bluey"]);
    expect(await titles("?kind=movie&yearFrom=2000&yearTo=2016")).toEqual(["Piper", "Up"]);
    // A decade is a range; without a year a title is not in any.
    expect(await titles("?yearFrom=1990&yearTo=1999")).toEqual(["Heat"]);
    expect(await titles("?yearTo=2100")).not.toContain("Metropolis");
    // Any of the genres asked for, whatever their case.
    expect(await titles("?genre=animation&genre=Crime")).toEqual(["Heat", "Piper", "Up"]);
    expect(await titles("?genre=Adventure&yearFrom=2015")).toEqual(["Dune"]);
    expect(await titles("?studio=company:3")).toEqual(["Piper", "Up"]);
  });

  it("narrows by length, when it came, quality and language", async () => {
    // A show's length is that of its episodes.
    expect(await titles("?length=short")).toEqual(["Bluey", "Piper"]);
    expect(await titles("?length=long")).toEqual(["Dune", "Heat"]);
    expect(await titles("?length=standard")).toEqual(["Metropolis", "Up"]);
    // A show came when its newest episode did.
    expect(await titles("?added=week")).toEqual(["Bluey", "Up"]);
    expect(await titles("?added=month")).toEqual(["Bluey", "Piper", "Up"]);
    expect(await titles("?added=year")).toEqual(["Bluey", "Dune", "Piper", "Up"]);
    expect(await titles("?quality=4k")).toEqual(["Dune", "Heat"]);
    expect(await titles("?language=FRE&language=ger")).toEqual(["Heat", "Metropolis"]);
  });

  it("narrows by what a viewer watched", async () => {
    watched("one", up, 100 * MINUTE, true);
    watched("one", heat, 20 * MINUTE, false);
    const [first = "", second = ""] = db
      .all<{ id: string }>("select id from item where kind = 'episode' order by episode_number")
      .map((row) => row.id);
    watched("one", first, 7 * MINUTE, true);
    watched("two", first, 7 * MINUTE, true);
    watched("two", second, 8 * MINUTE, true);
    expect(await titles("?watch=watched&profile=one")).toEqual(["Up"]);
    expect(await titles("?watch=in_progress&profile=one")).toEqual(["Bluey", "Heat"]);
    expect(await titles("?watch=unwatched&profile=one")).toEqual(["Dune", "Metropolis", "Piper"]);
    expect(await titles("?watch=watched&profile=two")).toEqual(["Bluey"]);
    expect(await titles("?watch=watched&watch=unwatched&profile=one&kind=show")).toEqual([]);
    expect((await ask("?watch=watched")).status).toBe(400);
    expect((await ask("?watch=watched&profile=nobody")).status).toBe(404);
  });

  it("narrows by category, with those inside it", async () => {
    db.run("insert into category_group (id, name, position) values ('main', null, 0)");
    db.run(
      "insert into category (id, group_id, name, position) values ('studios', 'main', 'Studios', 0)",
    );
    db.run(
      "insert into category (id, group_id, name, position, parent_id) values ('pixar', 'main', 'Pixar', 1, 'studios')",
    );
    db.run(
      `insert into category (id, group_id, name, position, rule_json)
       values ('big', 'main', 'Big', 2, '{"studioIds":["company:923"]}')`,
    );
    db.run("update item set override_json = ? where id = ?", [
      JSON.stringify({ categoryIds: ["pixar"] }),
      up,
    ]);
    db.nextRevision();
    expect(await titles("?category=pixar")).toEqual(["Up"]);
    expect(await titles("?category=studios")).toEqual(["Up"]);
    // A studio's rule takes it in too.
    expect(await titles("?category=big&category=pixar")).toEqual(["Dune", "Up"]);
  });

  it("orders, with what is not known last either way", async () => {
    expect(await titles("?sort=year")).toEqual([
      "Dune",
      "Piper",
      "Up",
      "Heat",
      "Bluey",
      "Metropolis",
    ]);
    expect(await titles("?sort=year&order=asc")).toEqual([
      "Heat",
      "Up",
      "Piper",
      "Dune",
      "Bluey",
      "Metropolis",
    ]);
    expect(await titles("?sort=added")).toEqual([
      "Bluey",
      "Up",
      "Piper",
      "Dune",
      "Heat",
      "Metropolis",
    ]);
    expect(await titles("?sort=length&kind=movie")).toEqual([
      "Piper",
      "Up",
      "Metropolis",
      "Dune",
      "Heat",
    ]);
    // Too few votes to say: Piper has no rating.
    expect(await titles("?sort=rating&kind=movie")).toEqual([
      "Heat",
      "Up",
      "Dune",
      "Metropolis",
      "Piper",
    ]);
    expect(await titles("?sort=title&order=desc&kind=movie")).toEqual([
      "Up",
      "Piper",
      "Metropolis",
      "Heat",
      "Dune",
    ]);
  });

  it("orders by what the household watches, then by how well known", async () => {
    db.run(
      "insert into play (profile_id, item_id, day, watched_ms, counted) values ('one', ?, ?, 1, 1)",
      [old, new Date(NOW - DAY).toISOString().slice(0, 10)],
    );
    const order = await titles("?sort=popular&kind=movie");
    expect(order[0]).toBe("Metropolis");
    expect(order.slice(1, 4)).toEqual(["Up", "Dune", "Heat"]);
  });

  it("pages, and says how many there are", async () => {
    const page = await ask("?limit=2&offset=1");
    expect(page.status).toBe(200);
    expect(page.body.total).toBe(6);
    expect(page.body.offset).toBe(1);
    expect(page.body.items.map((item) => item.title)).toEqual(["Dune", "Heat"]);
    expect((await ask("?limit=0")).body).toEqual({ total: 6, offset: 0, items: [] });
  });

  it("refuses what it does not know", async () => {
    for (const query of [
      "?kind=episode",
      "?yearFrom=90",
      "?sort=size",
      "?order=up",
      "?limit=501",
      "?length=tiny",
      "?added=week&added=year",
      "?sort=year&sort=title",
      "?quality=8k",
    ]) {
      expect((await ask(query)).status, query).toBe(400);
    }
  });

  it("says who made a title and how it was rated", () => {
    const [item] = new ItemReader(db).read([up]);
    expect(item?.studios).toEqual([{ id: "company:3", name: "Pixar" }]);
    expect(item?.rating).toBe(8);
    expect(new ItemReader(db).read([short])[0]?.rating).toBeNull();
    expect(new ItemReader(db).read([episode("Bluey", 1, 3)])[0]?.studios).toEqual([]);
  });

  describe("for a kids device", () => {
    let child: string;

    beforeEach(async () => {
      const reply = await app.request("/v1/profiles/two", {
        method: "PATCH",
        headers: { Authorization: `Bearer ${manager}` },
        body: JSON.stringify({
          kids: {
            allowedGroupIds: [],
            allowedCategoryIds: [],
            allowedItemIds: [up, short, showId("Bluey")],
            blockedItemIds: [short],
          },
        }),
      });
      expect(reply.status).toBe(200);
      const waiting = devices.startPairing("iPad", "ipados");
      devices.approve(waiting.code, "viewer", "cli");
      const done = devices.collect(waiting.id, waiting.pollSecret);
      if (done.status !== "approved") throw new Error("not paired");
      devices.bindToKids(done.device.id, "two");
      child = done.token;
    });

    it("filters only what its viewer may see", async () => {
      expect(await titles("", child)).toEqual(["Bluey", "Up"]);
      expect(await titles("?genre=Animation", child)).toEqual(["Up"]);
      expect(await titles("?studio=company:3", child)).toEqual(["Up"]);
      expect(await titles("?length=long", child)).toEqual([]);
      expect(await titles("?sort=popular", child)).toEqual(["Up", "Bluey"]);
      watched("two", up, 100 * MINUTE, true);
      expect(await titles("?watch=unwatched&profile=two", child)).toEqual(["Bluey"]);
    });

    it("knows its own viewer only", async () => {
      expect((await ask("?watch=watched&profile=one", child)).status).toBe(404);
    });
  });
});

describe("a large library", () => {
  it("answers 3,000 titles quickly", async () => {
    const genreNames = ["Drama", "Comedy", "Action", "Animation", "Horror", "Family"];
    db.transaction(() => {
      for (let index = 0; index < 3_000; index += 1) {
        const id = addFile(
          `Title ${String(index)} (${String(1950 + (index % 75))}).mkv`,
          "movies",
          {
            minutes: 20 + (index % 160),
            width: index % 7 === 0 ? 3840 : 1920,
            languages: index % 3 === 0 ? ["eng", "fre"] : ["eng"],
            addedDaysAgo: index % 500,
          },
        );
        genres(id, genreNames[index % genreNames.length] ?? "Drama");
        if (index % 4 === 0) votes(id, 5 + (index % 50) / 10, 100 + index);
        if (index % 5 === 0) watched("one", id, MINUTE, index % 10 === 0);
      }
    });
    db.nextRevision();
    const query =
      "?kind=movie&yearFrom=1980&yearTo=2009&genre=Drama&genre=Comedy&length=standard&watch=unwatched&profile=one&sort=rating&limit=50";
    const cold = performance.now();
    const first = await ask(query);
    const coldMs = performance.now() - cold;
    expect(first.status).toBe(200);
    expect(first.body.total).toBeGreaterThan(50);
    expect(first.body.items).toHaveLength(50);
    const warm = performance.now();
    for (const one of ["?sort=title&limit=50", "?quality=4k&sort=added&limit=50", query]) {
      expect((await ask(one)).status).toBe(200);
    }
    const warmMs = (performance.now() - warm) / 3;
    // Measured on a Mac at about a fifth of these; the Pi is some times slower.
    expect(coldMs).toBeLessThan(2_000);
    expect(warmMs).toBeLessThan(250);
  }, 120_000);
});
