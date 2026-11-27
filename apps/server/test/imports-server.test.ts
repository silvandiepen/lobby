// SPDX-License-Identifier: MPL-2.0
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.ts";
import { Catalogue } from "../src/library/catalogue.ts";
import { Database } from "../src/db/database.ts";
import { ImportService } from "../src/imports/service.ts";
import { Scanner } from "../src/library/scanner.ts";
import { startServer, type RunningServer } from "../src/server.ts";
import { makeTempDir, makeVideo, removeDir } from "./support/media.ts";

interface Reply {
  status: number;
  body: Record<string, unknown>;
  headers: Headers;
}

let dir: string;
let running: RunningServer | null;
let manager: string;

beforeEach(() => {
  dir = makeTempDir("lobby-imports-server-");
  for (const one of ["drive/Movies", "drive/Series", "drive/Downloads", "drive/Lobby"]) {
    mkdirSync(join(dir, one), { recursive: true });
  }
  running = null;
});

afterEach(async () => {
  await running?.close();
  removeDir(dir);
});

async function start(extra: Record<string, unknown> = {}): Promise<void> {
  const configPath = join(dir, "lobby.config.json");
  writeFileSync(
    configPath,
    JSON.stringify({
      host: "127.0.0.1",
      port: 0,
      stabilityMs: 0,
      advertise: false,
      dataDir: join(dir, "data"),
      roots: [
        { path: join(dir, "drive", "Movies"), name: "Movies", hint: "movies" },
        { path: join(dir, "drive", "Series"), name: "Series", hint: "series" },
      ],
      conversion: { dir: join(dir, "drive", "Lobby"), minFreeGb: 1 },
      ...extra,
    }),
  );
  running = await startServer(loadConfig(configPath), { browseBases: () => [join(dir, "drive")] });
  manager = running.services.devices.createLocalManager("Mac").token;
}

async function ask(
  method: string,
  path: string,
  options: { body?: unknown; bytes?: Uint8Array; headers?: Record<string, string> } = {},
): Promise<Reply> {
  if (!running) throw new Error("not running");
  const headers: Record<string, string> = {
    Host: "127.0.0.1",
    Authorization: `Bearer ${manager}`,
    ...options.headers,
  };
  let body: string | Uint8Array | undefined;
  if (options.bytes) {
    body = options.bytes;
    headers["Content-Length"] = String(options.bytes.length);
  } else if (options.body !== undefined) {
    body = JSON.stringify(options.body);
    headers["Content-Type"] = "application/json";
  }
  const response = await running.app.request(`http://127.0.0.1${path}`, {
    method,
    headers,
    ...(body === undefined ? {} : { body }),
  });
  const text = await response.text();
  return {
    status: response.status,
    body: text === "" ? {} : (JSON.parse(text) as Record<string, unknown>),
    headers: response.headers,
  };
}

async function until(check: () => boolean | Promise<boolean>, ms = 30_000): Promise<void> {
  const end = Date.now() + ms;
  while (!(await check())) {
    if (Date.now() > end) throw new Error("timed out");
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
}

async function titles(): Promise<string[]> {
  const library = await ask("GET", "/v1/library?limit=1000");
  return ((library.body["items"] as { kind: string; title: string }[] | undefined) ?? [])
    .filter((one) => one.kind === "movie")
    .map((one) => one.title)
    .sort();
}

describe("import folders in the server's settings", () => {
  it("are none at first; a Downloads folder is indexed where it is unless chosen otherwise", async () => {
    makeVideo(join(dir, "drive", "Movies", "Old (1990)", "Old (1990).mkv"));
    await start();
    expect((await ask("GET", "/v1/imports")).body).toMatchObject({ folders: [], moving: true });
    const downloads = join(dir, "drive", "Downloads");
    const changed = await ask("PATCH", "/v1/settings", {
      body: { changes: { "import.folders": [{ path: downloads }] } },
    });
    expect(changed.status).toBe(200);
    expect(changed.body["restart"]).toBe(false);
    const status = await ask("GET", "/v1/imports");
    expect(status.body["folders"]).toEqual([
      expect.objectContaining({
        path: downloads,
        name: "Downloads",
        mode: "index",
        looksLikeDownloads: true,
        connected: true,
      }),
    ]);
    expect(status.body["destinations"]).toEqual([
      { path: join(dir, "drive", "Movies"), name: "Movies", hint: "movies" },
      { path: join(dir, "drive", "Series"), name: "Series", hint: "series" },
    ]);
  });

  it("refuses a folder inside the library or Lobby's folder", async () => {
    await start();
    for (const path of [
      join(dir, "drive", "Movies", "New"),
      join(dir, "drive"),
      join(dir, "drive", "Lobby"),
    ]) {
      const refused = await ask("PATCH", "/v1/settings", {
        body: { changes: { "import.folders": [{ path, mode: "move" }] } },
      });
      expect(refused.status, path).toBe(400);
    }
  });
});

describe("an upload, from the app's first piece to the library", () => {
  it("arrives, waits for a title, and is in the library under its neat name", async () => {
    // Lobby's folder is only made on a drive the library is known to be on.
    makeVideo(join(dir, "drive", "Movies", "Old (1990)", "Old (1990).mkv"));
    await start();
    await until(async () => (await ask("GET", "/v1/imports")).body["driveConnected"] === true);
    const path = join(dir, "phone", "Holiday.2018.1080p.mkv");
    makeVideo(path, { seconds: 2 });
    const bytes = readFileSync(path);
    const created = await ask("POST", "/v1/uploads", {
      body: {
        relPath: "Holiday.2018.1080p.mkv",
        sizeBytes: bytes.length,
        sha256: createHash("sha256").update(bytes).digest("hex"),
        destination: { kind: "movies" },
      },
    });
    expect(created.status).toBe(201);
    const id = (created.body["upload"] as { id: string }).id;
    const sent = await ask("PATCH", `/v1/uploads/${id}`, {
      bytes,
      headers: { "Upload-Offset": "0" },
    });
    expect(sent.status).toBe(204);
    const done = await ask("POST", `/v1/uploads/${id}/complete`, { body: {} });
    const itemId = (done.body["upload"] as { itemId: string }).itemId;
    // A test film of a few kilobytes is far too small for one: it is left out, with its reason,
    // and a manager can still import it.
    const ignored = await ask("GET", "/v1/imports/items?view=ignored");
    const [left] = ignored.body["items"] as { id: string; state: string; reason: string }[];
    expect(left).toMatchObject({ id: itemId, state: "ignored" });
    expect(left?.reason).toMatch(/too small for a film/);
    // What its name says is kept, for the manager who imports it all the same.
    expect(left).toMatchObject({ kind: "movie", title: "Holiday", year: 2018 });
    await ask("POST", `/v1/imports/items/${itemId}/confirm`, {
      body: { kind: "movie", title: "Holiday", year: 2018 },
    });
    expect(existsSync(join(dir, "drive", "Movies", "Holiday (2018)", "Holiday (2018).mkv"))).toBe(
      true,
    );
    await until(async () => (await titles()).includes("Holiday"));
    const activity = await ask("GET", "/v1/imports/activity");
    expect((activity.body["entries"] as { action: string }[]).map((one) => one.action)).toEqual([
      "imported",
      "confirmed",
      "uploaded",
    ]);
  }, 60_000);
});

describe("a folder indexed where it is", () => {
  it("lists only what passed the rules", async () => {
    const db = new Database(join(dir, "lobby.db"));
    const downloads = join(dir, "drive", "Downloads");
    makeVideo(join(downloads, "Kept.2011", "Kept.2011.mkv"), { seconds: 2 });
    makeVideo(join(downloads, "Kept.2011", "Kept.2011.sample.mkv"), { seed: 1 });
    makeVideo(join(downloads, "Later.2012.mkv"), { seed: 2 });
    let clock = 1_000_000;
    const imports = new ImportService({
      db,
      folders: [{ path: downloads, mode: "index" }],
      roots: () => [],
      lobbyDir: null,
      driveConnected: () => Promise.resolve(false),
      waitMs: 60_000,
      copyAcrossDrives: false,
      matcher: null,
      limits: { minFilmBytes: 1000, minEpisodeBytes: 1000 },
      now: () => clock,
      isOpenElsewhere: () => Promise.resolve(false),
    });
    const scanner = new Scanner(db, new Catalogue(db), {
      stabilityMs: 0,
      probeConcurrency: 1,
      ffprobePath: "ffprobe",
    });
    for (const source of imports.indexSources()) {
      scanner.setFilter(source.path, (rel) => imports.isListed(source.path, rel));
    }
    scanner.syncSources(imports.indexSources());
    await imports.scanNow();
    clock += 61_000;
    await imports.scanNow();
    await scanner.scanAll();
    await scanner.processQueue();
    const assets = db.all<{ rel_path: string }>("select rel_path from asset order by rel_path");
    expect(assets.map((one) => one.rel_path)).toEqual([
      "Kept.2011/Kept.2011.mkv",
      "Later.2012.mkv",
    ]);
    db.close();
  }, 60_000);
});
