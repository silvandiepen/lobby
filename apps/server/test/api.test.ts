// SPDX-License-Identifier: MPL-2.0
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Hono } from "hono";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { Devices } from "../src/auth/devices.ts";
import { Database } from "../src/db/database.ts";
import { createApp, MIN_APP_VERSION, type AppEnv } from "../src/http/app.ts";
import { Catalogue } from "../src/library/catalogue.ts";
import { ItemReader, type ApiItem } from "../src/library/items.ts";
import { Scanner } from "../src/library/scanner.ts";
import { ProgressStore, type Progress } from "../src/progress.ts";
import { makeTempDir, makeVideo, removeDir } from "./support/media.ts";

const SETUP_SECRET = "test-setup-secret";

interface Fixture {
  dir: string;
  movies: string;
  series: string;
  db: Database;
  scanner: Scanner;
  app: Hono<AppEnv>;
  clock: { now: number };
  unplugged: Set<string>;
}

interface Reply<T> {
  status: number;
  body: T;
  headers: Headers;
}

function setUp(): Fixture {
  const dir = makeTempDir();
  const movies = join(dir, "Movies");
  const series = join(dir, "Series");
  mkdirSync(movies);
  mkdirSync(series);
  const clock = { now: 1_800_000_000_000 };
  const now = (): number => clock.now;
  const unplugged = new Set<string>();
  const db = new Database(join(dir, "lobby.db"));
  const scanner = new Scanner(db, new Catalogue(db, now), {
    stabilityMs: 0,
    probeConcurrency: 2,
    ffprobePath: "ffprobe",
    now,
    volumeOf: (path) => Promise.resolve(unplugged.has(path) ? 2 : 1),
  });
  scanner.syncSources([
    { path: movies, name: "Pixar", hint: "movies" },
    { path: series, name: "Kids Series", hint: "series" },
  ]);
  const app = createApp({
    db,
    devices: new Devices(db, SETUP_SECRET, now),
    items: new ItemReader(db),
    progress: new ProgressStore(db, now),
    serverName: "Test Lobby",
    version: "0.0.0-test",
    isScanning: () => scanner.isScanning,
    now,
  });
  return { dir, movies, series, db, scanner, app, clock, unplugged };
}

async function call<T = Record<string, unknown>>(
  fixture: Fixture,
  method: string,
  path: string,
  options: { token?: string; body?: unknown; headers?: Record<string, string> } = {},
): Promise<Reply<T>> {
  const headers: Record<string, string> = { ...options.headers };
  if (options.token) headers["Authorization"] = `Bearer ${options.token}`;
  if (options.body !== undefined) headers["Content-Type"] = "application/json";
  const response = await fixture.app.request(path, {
    method,
    headers,
    ...(options.body === undefined ? {} : { body: JSON.stringify(options.body) }),
  });
  const text = await response.text();
  let body: unknown = null;
  if (text !== "") {
    try {
      body = JSON.parse(text);
    } catch {
      body = text;
    }
  }
  return { status: response.status, body: body as T, headers: response.headers };
}

async function claim(fixture: Fixture): Promise<string> {
  const reply = await call<{ token: string }>(fixture, "POST", "/v1/pairing/claim", {
    body: { setupSecret: SETUP_SECRET, deviceName: "Manager Mac", platform: "macos" },
  });
  expect(reply.status).toBe(201);
  return reply.body.token;
}

/** Pairs a new device the way the apps do: request, approve, collect. */
async function pair(
  fixture: Fixture,
  manager: string,
  role: "viewer" | "manager" = "viewer",
): Promise<string> {
  const request = await call<{ id: string; code: string; pollSecret: string }>(
    fixture,
    "POST",
    "/v1/pairing/requests",
    {
      body: { deviceName: "Kids iPad", platform: "ipados" },
    },
  );
  expect(request.status).toBe(201);
  const approved = await call(fixture, "POST", "/v1/pairing/approve", {
    token: manager,
    body: { code: request.body.code, role },
  });
  expect(approved.status).toBe(200);
  const collected = await call<{ token: string }>(
    fixture,
    "POST",
    `/v1/pairing/requests/${request.body.id}/collect`,
    {
      body: { pollSecret: request.body.pollSecret },
    },
  );
  expect(collected.status).toBe(200);
  return collected.body.token;
}

async function scan(fixture: Fixture): Promise<void> {
  await fixture.scanner.scanAll();
  await fixture.scanner.processQueue();
}

interface LibraryPage {
  items: ApiItem[];
  removed: string[];
  cursor: string;
  more: boolean;
  reset: boolean;
}

async function syncAll(
  fixture: Fixture,
  token: string,
  cursor?: string,
  limit = 500,
): Promise<LibraryPage> {
  const all: LibraryPage = {
    items: [],
    removed: [],
    cursor: cursor ?? "",
    more: true,
    reset: false,
  };
  let first = true;
  while (all.more) {
    const query = new URLSearchParams({ limit: String(limit) });
    if (all.cursor) query.set("cursor", all.cursor);
    const page = await call<LibraryPage>(fixture, "GET", `/v1/library?${query.toString()}`, {
      token,
    });
    expect(page.status).toBe(200);
    all.items.push(...page.body.items);
    all.removed.push(...page.body.removed);
    all.cursor = page.body.cursor;
    all.more = page.body.more;
    if (first) all.reset = page.body.reset;
    first = false;
  }
  return all;
}

let fixture: Fixture;
beforeEach(() => {
  fixture = setUp();
});
afterEach(() => {
  fixture.db.close();
  removeDir(fixture.dir);
});

describe("access", () => {
  it("answers server info without a credential, and nothing else", async () => {
    const info = await call(fixture, "GET", "/v1/server");
    expect(info.status).toBe(200);
    expect(info.body).toMatchObject({ name: "Test Lobby", apiVersion: 1, claimed: false });
    // The oldest app it works with: an older app tells its manager to update it.
    expect(info.body).toMatchObject({ version: "0.0.0-test", minAppVersion: MIN_APP_VERSION });
    expect(MIN_APP_VERSION).toMatch(/^\d+\.\d+\.\d+$/);

    for (const [method, path] of [
      ["GET", "/v1/me"],
      ["GET", "/v1/status"],
      ["GET", "/v1/library"],
      ["GET", "/v1/items/anything"],
      ["GET", "/v1/profiles"],
      ["POST", "/v1/profiles"],
      ["GET", "/v1/profiles/p/progress"],
      ["PUT", "/v1/profiles/p/progress/i"],
      ["PUT", "/v1/profiles/p/avatar"],
      ["GET", "/v1/devices"],
      ["DELETE", "/v1/devices/d"],
      ["GET", "/v1/pairing/requests"],
      ["POST", "/v1/pairing/approve"],
      ["GET", "/v1/assets/a/content"],
      ["HEAD", "/v1/assets/a/content"],
      ["GET", "/v1/nothing-here"],
    ] as const) {
      const reply = await call(fixture, method, path, {
        body: method === "GET" || method === "HEAD" ? undefined : {},
      });
      expect(reply.status, `${method} ${path}`).toBe(401);
    }
    const wrong = await call(fixture, "GET", "/v1/me", { token: "not-a-real-token" });
    expect(wrong.status).toBe(401);
    expect(wrong.body).toMatchObject({ error: { code: "unauthorized" } });
  });

  it("lets the first device set up an open server without a secret, once", async () => {
    const dir = makeTempDir();
    const db = new Database(join(dir, "lobby.db"));
    try {
      const app = createApp({
        db,
        devices: new Devices(db, SETUP_SECRET, Date.now, "open"),
        items: new ItemReader(db),
        progress: new ProgressStore(db),
        serverName: "Open Lobby",
        version: "0.0.0-test",
        isScanning: () => false,
      });
      const post = (name: string): Promise<Response> =>
        Promise.resolve(
          app.request("/v1/pairing/claim", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ deviceName: name, platform: "macos" }),
          }),
        );
      const info = (await (await app.request("/v1/server")).json()) as Record<string, unknown>;
      expect(info).toMatchObject({ claimed: false, claim: "open" });

      const first = await post("Family Mac");
      expect(first.status).toBe(201);
      const body = (await first.json()) as { device: { role: string }; token: string };
      expect(body.device.role).toBe("manager");
      expect(body.token.length).toBeGreaterThan(20);

      const second = await post("Someone else");
      expect(second.status).toBe(403);
    } finally {
      db.close();
      removeDir(dir);
    }
  });

  it("lets the first manager claim the server once, with the setup secret", async () => {
    const wrong = await call(fixture, "POST", "/v1/pairing/claim", {
      body: { setupSecret: "guess", deviceName: "Stranger", platform: "macos" },
    });
    expect(wrong.status).toBe(403);

    const token = await claim(fixture);
    const me = await call<{
      device: { role: string; name: string };
      server: Record<string, unknown>;
    }>(fixture, "GET", "/v1/me", { token });
    expect(me.body.device).toMatchObject({ role: "manager", name: "Manager Mac" });
    expect(me.body.server).toMatchObject({ version: "0.0.0-test", minAppVersion: MIN_APP_VERSION });
    expect((await call(fixture, "GET", "/v1/server")).body).toMatchObject({ claimed: true });

    const again = await call(fixture, "POST", "/v1/pairing/claim", {
      body: { setupSecret: SETUP_SECRET, deviceName: "Second", platform: "macos" },
    });
    expect(again.status).toBe(403);
  });

  it("locks out repeated wrong setup secrets", async () => {
    for (let attempt = 0; attempt < 5; attempt += 1) {
      const reply = await call(fixture, "POST", "/v1/pairing/claim", {
        body: { setupSecret: `guess-${attempt}`, deviceName: "Stranger", platform: "macos" },
      });
      expect(reply.status).toBe(403);
    }
    const locked = await call(fixture, "POST", "/v1/pairing/claim", {
      body: { setupSecret: SETUP_SECRET, deviceName: "Manager Mac", platform: "macos" },
    });
    expect(locked.status).toBe(429);
    expect(Number(locked.headers.get("Retry-After"))).toBeGreaterThan(0);

    fixture.clock.now += 11 * 60_000;
    await claim(fixture);
  });

  it("accepts the credential as a cookie, for the media player", async () => {
    const token = await claim(fixture);
    const reply = await call(fixture, "GET", "/v1/me", {
      headers: { Cookie: `lobby_device=${token}` },
    });
    expect(reply.status).toBe(200);
  });

  it("stores only a hash of the credential", async () => {
    const token = await claim(fixture);
    const stored = fixture.db.all<{ token_hash: string }>("select token_hash from device");
    expect(stored).toEqual([{ token_hash: createHash("sha256").update(token).digest("hex") }]);
    expect(readFileSync(join(fixture.dir, "lobby.db")).includes(token)).toBe(false);
  });
});

describe("pairing", () => {
  it("pairs a new device with a code a manager approves", async () => {
    const manager = await claim(fixture);
    const request = await call<{ id: string; code: string; pollSecret: string; expiresAt: number }>(
      fixture,
      "POST",
      "/v1/pairing/requests",
      { body: { deviceName: "Living room Apple TV", platform: "tvos" } },
    );
    expect(request.body.code).toMatch(/^\d{6}$/);
    expect(request.body.expiresAt).toBe(fixture.clock.now + 10 * 60_000);

    const pending = await call(fixture, "POST", `/v1/pairing/requests/${request.body.id}/collect`, {
      body: { pollSecret: request.body.pollSecret },
    });
    expect(pending.status).toBe(202);
    expect(pending.body).toMatchObject({ status: "pending" });

    const waiting = await call<{ requests: Record<string, unknown>[] }>(
      fixture,
      "GET",
      "/v1/pairing/requests",
      {
        token: manager,
      },
    );
    expect(waiting.body.requests).toMatchObject([
      { deviceName: "Living room Apple TV", platform: "tvos", code: request.body.code },
    ]);
    // Managers compare the code; nobody else may see it.
    const viewer = await pair(fixture, manager);
    for (const token of [undefined, viewer]) {
      const refused = await call(fixture, "GET", "/v1/pairing/requests", token ? { token } : {});
      expect(refused.status).toBe(token ? 403 : 401);
      expect(JSON.stringify(refused.body)).not.toContain(request.body.code);
    }

    const approved = await call(fixture, "POST", "/v1/pairing/approve", {
      token: manager,
      body: { code: request.body.code, role: "viewer" },
    });
    expect(approved.body).toEqual({
      deviceName: "Living room Apple TV",
      platform: "tvos",
      role: "viewer",
      access: "viewer",
      awaitsAdmin: false,
    });

    const collected = await call<{ status: string; token: string; device: { role: string } }>(
      fixture,
      "POST",
      `/v1/pairing/requests/${request.body.id}/collect`,
      { body: { pollSecret: request.body.pollSecret } },
    );
    expect(collected.status).toBe(200);
    expect(collected.body.device.role).toBe("viewer");
    expect((await call(fixture, "GET", "/v1/me", { token: collected.body.token })).status).toBe(
      200,
    );

    // The credential is handed out once, and the code cannot be approved again.
    const second = await call(fixture, "POST", `/v1/pairing/requests/${request.body.id}/collect`, {
      body: { pollSecret: request.body.pollSecret },
    });
    expect(second.status).toBe(410);
    const reuse = await call(fixture, "POST", "/v1/pairing/approve", {
      token: manager,
      body: { code: request.body.code, role: "manager" },
    });
    expect(reuse.status).toBe(404);
  });

  it("approves a device picked from the waiting list, once, and only for a manager", async () => {
    const manager = await claim(fixture);
    const viewer = await pair(fixture, manager);
    const start = (): Promise<Reply<{ id: string; pollSecret: string }>> =>
      call(fixture, "POST", "/v1/pairing/requests", {
        body: { deviceName: "Family iPhone", platform: "ios" },
      });
    const approve = async (token: string, requestId: string): Promise<number> =>
      (
        await call(fixture, "POST", "/v1/pairing/approve", {
          token,
          body: { requestId, role: "viewer" },
        })
      ).status;

    const request = await start();
    expect(await approve(viewer, request.body.id)).toBe(403);
    expect(await approve(manager, "no-such-request")).toBe(404);
    expect(await approve(manager, request.body.id)).toBe(200);
    expect(await approve(manager, request.body.id)).toBe(404);
    const collected = await call<{ device: { role: string } }>(
      fixture,
      "POST",
      `/v1/pairing/requests/${request.body.id}/collect`,
      { body: { pollSecret: request.body.pollSecret } },
    );
    expect(collected.body.device.role).toBe("viewer");

    const late = await start();
    fixture.clock.now += 11 * 60_000;
    expect(await approve(manager, late.body.id)).toBe(404);
  });

  it("refuses a wrong poll secret and an expired code", async () => {
    const manager = await claim(fixture);
    const request = await call<{ id: string; code: string; pollSecret: string }>(
      fixture,
      "POST",
      "/v1/pairing/requests",
      {
        body: { deviceName: "Kids iPad", platform: "ipados" },
      },
    );
    const stolen = await call(fixture, "POST", `/v1/pairing/requests/${request.body.id}/collect`, {
      body: { pollSecret: "someone-else" },
    });
    expect(stolen.status).toBe(404);

    fixture.clock.now += 10 * 60_000 + 1;
    const late = await call(fixture, "POST", "/v1/pairing/approve", {
      token: manager,
      body: { code: request.body.code, role: "viewer" },
    });
    expect(late.status).toBe(404);
    const expired = await call(fixture, "POST", `/v1/pairing/requests/${request.body.id}/collect`, {
      body: { pollSecret: request.body.pollSecret },
    });
    expect(expired.status).toBe(410);
  });

  it("locks a manager out after five wrong codes", async () => {
    const manager = await claim(fixture);
    const request = await call<{ code: string }>(fixture, "POST", "/v1/pairing/requests", {
      body: { deviceName: "Kids iPad", platform: "ipados" },
    });
    const wrongCode = request.body.code === "000000" ? "000001" : "000000";
    for (let attempt = 0; attempt < 5; attempt += 1) {
      const reply = await call(fixture, "POST", "/v1/pairing/approve", {
        token: manager,
        body: { code: wrongCode, role: "viewer" },
      });
      expect(reply.status).toBe(404);
    }
    const locked = await call(fixture, "POST", "/v1/pairing/approve", {
      token: manager,
      body: { code: request.body.code, role: "viewer" },
    });
    expect(locked.status).toBe(429);
  });

  it("keeps a viewer out of every manager route", async () => {
    const manager = await claim(fixture);
    const viewer = await pair(fixture, manager);
    for (const [method, path] of [
      ["GET", "/v1/status"],
      ["GET", "/v1/devices"],
      ["DELETE", "/v1/devices/anything"],
      ["GET", "/v1/pairing/requests"],
      ["POST", "/v1/pairing/approve"],
      ["POST", "/v1/profiles"],
      ["PATCH", "/v1/profiles/anything"],
      ["DELETE", "/v1/profiles/anything"],
    ] as const) {
      const reply = await call(fixture, method, path, {
        token: viewer,
        body: method === "GET" ? undefined : { code: "123456", role: "manager", name: "X" },
      });
      expect(reply.status, `${method} ${path}`).toBe(403);
      expect(reply.body).toMatchObject({ error: { code: "forbidden" } });
    }
    expect((await call(fixture, "GET", "/v1/profiles", { token: viewer })).status).toBe(200);
  });

  it("refuses a revoked device at its next request, and keeps the last manager", async () => {
    const manager = await claim(fixture);
    const viewer = await pair(fixture, manager);
    const list = await call<{ devices: { id: string; role: string }[]; currentDeviceId: string }>(
      fixture,
      "GET",
      "/v1/devices",
      { token: manager },
    );
    const viewerId = list.body.devices.find((device) => device.role === "viewer")?.id ?? "";

    expect(
      (await call(fixture, "DELETE", `/v1/devices/${viewerId}`, { token: manager })).status,
    ).toBe(204);
    const refused = await call(fixture, "GET", "/v1/me", { token: viewer });
    expect(refused.status).toBe(401);
    expect(refused.body).toMatchObject({ error: { code: "device_revoked" } });

    const self = await call(fixture, "DELETE", `/v1/devices/${list.body.currentDeviceId}`, {
      token: manager,
    });
    expect(self.status).toBe(409);
    expect((await call(fixture, "GET", "/v1/me", { token: manager })).status).toBe(200);
  });
});

describe("library", () => {
  it("returns the catalogue, then only what changed", async () => {
    const token = await claim(fixture);
    makeVideo(join(fixture.movies, "Up (2009)/Up (2009).mp4"));
    makeVideo(join(fixture.series, "Bluey/Season 02/Bluey - S02E04 - Trains.mkv"), { seed: 1 });
    await scan(fixture);

    const first = await syncAll(fixture, token);
    expect(first.reset).toBe(false);
    expect(first.removed).toEqual([]);
    expect(first.items.map((item) => `${item.kind}:${item.title}`).sort()).toEqual([
      "episode:Trains",
      "movie:Up",
      "season:Season 2",
      "show:Bluey",
    ]);

    const movie = first.items.find((item) => item.kind === "movie");
    expect(movie).toMatchObject({
      title: "Up",
      year: 2009,
      parentId: null,
      categories: ["Pixar"],
      available: true,
      matchStatus: "unmatched",
      artwork: { poster: null, backdrop: null, still: null },
    });
    expect(movie?.files).toMatchObject([
      {
        role: "main",
        container: "mp4",
        playability: "direct",
        playabilityReason: null,
        available: true,
        sharedBy: 1,
        video: { codec: "h264", width: 160, height: 90, bitDepth: 8 },
        audio: [{ codec: "aac" }],
      },
    ]);
    expect(movie?.files[0]?.sizeBytes).toBeGreaterThan(0);
    const show = first.items.find((item) => item.kind === "show");
    const episode = first.items.find((item) => item.kind === "episode");
    expect(show).toMatchObject({ categories: ["Kids Series"], available: true, files: [] });
    expect(episode).toMatchObject({ seasonNumber: 2, episodeNumber: 4 });
    expect(episode?.files[0]).toMatchObject({
      container: "mkv",
      playability: "remux",
      convertible: false,
    });
    expect(episode?.files[0]?.playabilityReason).toContain("MKV");

    // Nothing changed: an empty page.
    const idle = await syncAll(fixture, token, first.cursor);
    expect(idle).toMatchObject({ items: [], removed: [], more: false, reset: false });

    // A new episode: itself, plus its season and show, which now have a newer "added" date.
    makeVideo(join(fixture.series, "Bluey/Season 02/Bluey - S02E05 - Flat Pack.mkv"), { seed: 2 });
    await scan(fixture);
    const added = await syncAll(fixture, token, first.cursor);
    expect(added.items.map((item) => `${item.kind}:${item.title}`).sort()).toEqual([
      "episode:Flat Pack",
      "season:Season 2",
      "show:Bluey",
    ]);

    // A film that is gone for good is reported as removed.
    rmSync(join(fixture.movies, "Up (2009)"), { recursive: true });
    await scan(fixture);
    const missing = await syncAll(fixture, token, added.cursor);
    expect(missing.items).toMatchObject([{ title: "Up", available: false }]);
    fixture.clock.now += 31 * 24 * 3_600_000;
    await scan(fixture);
    const gone = await syncAll(fixture, token, missing.cursor);
    expect(gone.removed).toEqual([movie?.id]);
    expect(gone.items).toEqual([]);
  });

  it("pages through a full fetch without losing or repeating anything", async () => {
    const token = await claim(fixture);
    for (let number = 1; number <= 5; number += 1) {
      makeVideo(join(fixture.series, `Bluey/Season 01/Bluey S01E0${number}.mkv`), { seed: number });
    }
    await scan(fixture);
    const whole = await syncAll(fixture, token);
    const paged = await syncAll(fixture, token, undefined, 2);
    expect(paged.items.map((item) => item.id).sort()).toEqual(
      whole.items.map((item) => item.id).sort(),
    );
    expect(new Set(paged.items.map((item) => item.id)).size).toBe(7);
    expect((await syncAll(fixture, token, paged.cursor)).items).toEqual([]);
  });

  it("starts over when the cursor is not this server's", async () => {
    const token = await claim(fixture);
    makeVideo(join(fixture.movies, "Up (2009)/Up (2009).mp4"));
    await scan(fixture);
    const foreign = Buffer.from(JSON.stringify(["another-server", 99, ""])).toString("base64url");
    for (const cursor of [foreign, "not-a-cursor"]) {
      const reply = await syncAll(fixture, token, cursor);
      expect(reply.reset).toBe(true);
      expect(reply.items).toHaveLength(1);
    }
  });

  it("marks everything on a missing drive unavailable without removing it", async () => {
    const token = await claim(fixture);
    makeVideo(join(fixture.movies, "Up (2009)/Up (2009).mp4"));
    await scan(fixture);
    const first = await syncAll(fixture, token);

    renameSync(fixture.movies, join(fixture.dir, "Unplugged"));
    mkdirSync(fixture.movies);
    fixture.unplugged.add(fixture.movies);
    await scan(fixture);
    const unplugged = await syncAll(fixture, token, first.cursor);
    expect(unplugged.removed).toEqual([]);
    expect(unplugged.items).toMatchObject([{ title: "Up", available: false }]);
    expect(unplugged.items[0]?.files[0]?.available).toBe(false);
    const content = await call(
      fixture,
      "GET",
      `/v1/assets/${first.items[0]?.files[0]?.assetId ?? ""}/content`,
      { token },
    );
    expect(content.status).toBe(503);
  });

  it("gives an item with its children", async () => {
    const token = await claim(fixture);
    makeVideo(join(fixture.series, "Bluey/Season 02/Bluey - S02E04 - Trains.mkv"));
    makeVideo(join(fixture.series, "Bluey/Season 02/Bluey - S02E03 - Fruit Bat.mkv"), { seed: 1 });
    await scan(fixture);
    const all = await syncAll(fixture, token);
    const season = all.items.find((item) => item.kind === "season");
    const detail = await call<{ item: ApiItem; children: ApiItem[] }>(
      fixture,
      "GET",
      `/v1/items/${season?.id ?? ""}`,
      {
        token,
      },
    );
    expect(detail.body.item.title).toBe("Season 2");
    expect(detail.body.children.map((child) => child.title)).toEqual(["Fruit Bat", "Trains"]);
    expect((await call(fixture, "GET", "/v1/items/no-such-item", { token })).status).toBe(404);
  });

  it("reports the scan to a manager", async () => {
    const token = await claim(fixture);
    makeVideo(join(fixture.movies, "Up (2009)/Up (2009).mp4"));
    makeVideo(join(fixture.series, "Bluey/Season 02/Bluey - S02E04 - Trains.mkv"), { seed: 1 });
    writeFileSync(join(fixture.movies, "Broken (2001).mp4"), "not a video");
    await scan(fixture);
    const status = await call(fixture, "GET", "/v1/status", { token });
    expect(status.body).toMatchObject({
      scanning: false,
      files: { total: 3, waiting: 0, failed: 1, missing: 0 },
      playability: { direct: 1, remux: 1, transcode: 0, unsupported: 0 },
      items: { movies: 1, shows: 1, episodes: 1, needsReview: 0, unmatched: 2 },
    });
  });
});

describe("profiles and progress", () => {
  async function setUpProgress(): Promise<{
    manager: string;
    viewer: string;
    a: string;
    b: string;
    item: string;
  }> {
    const manager = await claim(fixture);
    const viewer = await pair(fixture, manager);
    makeVideo(join(fixture.movies, "Up (2009)/Up (2009).mp4"));
    await scan(fixture);
    const a = await call<{ id: string }>(fixture, "POST", "/v1/profiles", {
      token: manager,
      body: { name: "Alex" },
    });
    const b = await call<{ id: string }>(fixture, "POST", "/v1/profiles", {
      token: manager,
      body: { name: "Robin", color: "teal" },
    });
    const library = await syncAll(fixture, viewer);
    return { manager, viewer, a: a.body.id, b: b.body.id, item: library.items[0]?.id ?? "" };
  }

  function update(
    opId: string,
    positionMs: number,
    baseRevision: number | null,
    extra: Record<string, unknown> = {},
  ): Record<string, unknown> {
    return {
      opId,
      baseRevision,
      positionMs,
      durationMs: 6_000_000,
      completed: false,
      updatedAt: fixture.clock.now,
      ...extra,
    };
  }

  it("creates, renames and removes viewers", async () => {
    const { manager, viewer, a } = await setUpProgress();
    const list = await call<{ profiles: { name: string; color: string }[] }>(
      fixture,
      "GET",
      "/v1/profiles",
      {
        token: viewer,
      },
    );
    expect(list.body.profiles).toMatchObject([
      { name: "Alex", color: "red" },
      { name: "Robin", color: "teal" },
    ]);
    const renamed = await call(fixture, "PATCH", `/v1/profiles/${a}`, {
      token: manager,
      body: { name: "Alex v." },
    });
    expect(renamed.body).toMatchObject({ name: "Alex v.", color: "red" });
    expect((await call(fixture, "DELETE", `/v1/profiles/${a}`, { token: manager })).status).toBe(
      204,
    );
    expect(
      (await call(fixture, "GET", `/v1/profiles/${a}/progress`, { token: viewer })).status,
    ).toBe(404);
  });

  it("keeps a viewer's picture: any id of the right form, for every device", async () => {
    const { manager, viewer, a, b } = await setUpProgress();
    const as = async (
      token: string,
      method: string,
      path: string,
      body?: unknown,
    ): Promise<{ status: number; body: { avatar: string | null } }> =>
      call<{ avatar: string | null }>(fixture, method, path, {
        token,
        ...(body === undefined ? {} : { body }),
      });
    const avatars = async (): Promise<(string | null)[]> =>
      (
        await call<{ profiles: { avatar: string | null }[] }>(fixture, "GET", "/v1/profiles", {
          token: viewer,
        })
      ).body.profiles.map((one) => one.avatar);
    expect(await avatars()).toEqual([null, null]);

    // A picture only a newer app has is kept too.
    expect(
      (await as(viewer, "PUT", `/v1/profiles/${a}/avatar`, { avatar: "viking-man" })).body,
    ).toEqual({
      id: a,
      name: "Alex",
      color: "red",
      avatar: "viking-man",
      kids: null,
      subtitles: { languages: [], forced: true, size: "medium", background: true },
      playback: {
        filmSuggestions: true,
        filmAutoplay: false,
        episodeAutoplay: true,
        countdownSeconds: 10,
        startAtCredits: true,
        stillWatchingEpisodes: 3,
        stillWatchingHours: 0,
      },
      skipping: { intro: "show", credits: "show" },
    });
    expect((await as(viewer, "PUT", `/v1/profiles/${b}/avatar`, { avatar: "x-9" })).status).toBe(
      200,
    );
    expect(await avatars()).toEqual(["viking-man", "x-9"]);

    const wrong = ["", "Panda", "../x", "a b", "a--b", "-a", "a-", "x".repeat(41), 3, {}, true];
    for (const avatar of [...wrong, undefined]) {
      const put = await as(viewer, "PUT", `/v1/profiles/${a}/avatar`, { avatar });
      expect([avatar, put.status]).toEqual([avatar, 400]);
    }
    for (const avatar of wrong) {
      const patch = await as(manager, "PATCH", `/v1/profiles/${a}`, { avatar });
      const post = await as(manager, "POST", "/v1/profiles", { name: "N", avatar });
      expect([avatar, patch.status, post.status]).toEqual([avatar, 400, 400]);
    }
    const none = await as(viewer, "PUT", "/v1/profiles/no-such-profile/avatar", { avatar: null });
    expect(none.status).toBe(404);
    const long = { avatar: "fox", padding: "x".repeat(20_000) };
    expect((await as(viewer, "PUT", `/v1/profiles/${a}/avatar`, long)).status).toBe(400);

    // An app that does not know the field leaves it alone.
    const renamed = { name: "Alex v.", color: "blue" };
    expect((await as(manager, "PATCH", `/v1/profiles/${a}`, renamed)).body.avatar).toBe(
      "viking-man",
    );
    expect((await as(viewer, "PATCH", `/v1/profiles/${a}`, { avatar: "fox" })).status).toBe(403);
    expect(await avatars()).toEqual(["viking-man", "x-9"]);

    const made = await as(manager, "POST", "/v1/profiles", { name: "New", avatar: "owl" });
    expect([made.status, made.body.avatar]).toEqual([201, "owl"]);
    expect((await as(manager, "PATCH", `/v1/profiles/${a}`, { avatar: "cat" })).body.avatar).toBe(
      "cat",
    );
    expect(
      (await as(viewer, "PUT", `/v1/profiles/${a}/avatar`, { avatar: null })).body.avatar,
    ).toBeNull();
    expect(await avatars()).toEqual([null, "x-9", "owl"]);
  });

  it("keeps each viewer's subtitles: off and forced on until they choose", async () => {
    const { manager, viewer, a, b } = await setUpProgress();
    const as = async (
      token: string,
      method: string,
      path: string,
      body?: unknown,
    ): Promise<{ status: number; body: { subtitles: Record<string, unknown> } }> =>
      call<{ subtitles: Record<string, unknown> }>(fixture, method, path, {
        token,
        ...(body === undefined ? {} : { body }),
      });
    const off = { languages: [], forced: true, size: "medium", background: true };
    const listed = await call<{ profiles: { subtitles: unknown }[] }>(
      fixture,
      "GET",
      "/v1/profiles",
      {
        token: viewer,
      },
    );
    expect(listed.body.profiles.map((one) => one.subtitles)).toEqual([off, off]);

    // Any device that watches as the viewer chooses; what is left out stays.
    const chosen = await as(viewer, "PUT", `/v1/profiles/${a}/subtitles`, {
      languages: ["NL", "eng", "nl"],
      size: "large",
    });
    expect(chosen.status).toBe(200);
    expect(chosen.body.subtitles).toEqual({
      languages: ["nl", "eng"],
      forced: true,
      size: "large",
      background: true,
    });
    const later = await as(viewer, "PUT", `/v1/profiles/${a}/subtitles`, {
      forced: false,
      background: false,
    });
    expect(later.body.subtitles).toEqual({
      languages: ["nl", "eng"],
      forced: false,
      size: "large",
      background: false,
    });
    // Another viewer is not touched; a rename by a manager keeps them.
    const renamed = await as(manager, "PATCH", `/v1/profiles/${a}`, { name: "Alex v." });
    expect(renamed.body.subtitles).toEqual(later.body.subtitles);
    const again = await call<{ profiles: { subtitles: unknown }[] }>(
      fixture,
      "GET",
      "/v1/profiles",
      {
        token: viewer,
      },
    );
    expect(again.body.profiles.map((one) => one.subtitles)).toEqual([later.body.subtitles, off]);

    // A manager may set them too, also on a new viewer.
    const patched = await as(manager, "PATCH", `/v1/profiles/${b}`, {
      subtitles: { languages: ["hy"] },
    });
    expect(patched.body.subtitles).toEqual({ ...off, languages: ["hy"] });
    const made = await as(manager, "POST", "/v1/profiles", {
      name: "New",
      subtitles: { size: "small" },
    });
    expect([made.status, made.body.subtitles]).toEqual([201, { ...off, size: "small" }]);
    // Off again: no languages.
    expect(
      (await as(viewer, "PUT", `/v1/profiles/${a}/subtitles`, { languages: [] })).body.subtitles[
        "languages"
      ],
    ).toEqual([]);

    const wrong = [
      { languages: "nl" },
      { languages: ["dutch"] },
      { languages: ["n"] },
      { languages: [3] },
      { languages: Array.from({ length: 9 }, (_, n) => `a${String.fromCharCode(97 + n)}`) },
      { forced: "yes" },
      { background: 1 },
      { size: "huge" },
    ];
    for (const body of wrong) {
      const put = await as(viewer, "PUT", `/v1/profiles/${a}/subtitles`, body);
      const patch = await as(manager, "PATCH", `/v1/profiles/${a}`, { subtitles: body });
      expect([body, put.status, patch.status]).toEqual([body, 400, 400]);
    }
    expect((await as(manager, "PATCH", `/v1/profiles/${a}`, { subtitles: null })).status).toBe(400);
    expect(
      (await as(viewer, "PUT", "/v1/profiles/no-such-profile/subtitles", { size: "small" })).status,
    ).toBe(404);
  });

  it("keeps per viewer what happens when something ends", async () => {
    const { manager, viewer, a, b } = await setUpProgress();
    interface Reply {
      status: number;
      body: { playback: Record<string, unknown> };
    }
    const as = async (
      token: string,
      method: string,
      path: string,
      body?: unknown,
    ): Promise<Reply> =>
      call<{ playback: Record<string, unknown> }>(fixture, method, path, {
        token,
        ...(body === undefined ? {} : { body }),
      });
    const defaults = {
      filmSuggestions: true,
      filmAutoplay: false,
      episodeAutoplay: true,
      countdownSeconds: 10,
      startAtCredits: true,
      stillWatchingEpisodes: 3,
      stillWatchingHours: 0,
    };
    const listed = async (): Promise<unknown[]> =>
      (
        await call<{ profiles: { playback: unknown }[] }>(fixture, "GET", "/v1/profiles", {
          token: viewer,
        })
      ).body.profiles.map((one) => one.playback);
    expect(await listed()).toEqual([defaults, defaults]);

    // Any device that watches as an ordinary viewer chooses; what is left out stays.
    const chosen = await as(viewer, "PUT", `/v1/profiles/${a}/playback`, {
      countdownSeconds: 5,
      stillWatchingEpisodes: 0,
    });
    expect([chosen.status, chosen.body.playback]).toEqual([
      200,
      { ...defaults, countdownSeconds: 5, stillWatchingEpisodes: 0 },
    ]);
    const later = await as(viewer, "PUT", `/v1/profiles/${a}/playback`, {
      filmAutoplay: true,
      stillWatchingHours: 2,
    });
    expect(later.body.playback).toEqual({
      ...defaults,
      countdownSeconds: 5,
      stillWatchingEpisodes: 0,
      filmAutoplay: true,
      stillWatchingHours: 2,
    });
    // A rename keeps them; the other viewer is not touched.
    const renamed = await as(manager, "PATCH", `/v1/profiles/${a}`, { name: "Alex v." });
    expect(renamed.body.playback).toEqual(later.body.playback);
    expect(await listed()).toEqual([later.body.playback, defaults]);

    // A manager may set them too, also on a new viewer.
    const made = await as(manager, "POST", "/v1/profiles", {
      name: "New",
      playback: { episodeAutoplay: false },
    });
    expect([made.status, made.body.playback]).toEqual([
      201,
      { ...defaults, episodeAutoplay: false },
    ]);

    // A kids viewer is asked sooner, unless the grown-ups chose; only they may choose.
    const kids = {
      allowedGroupIds: [],
      allowedCategoryIds: [],
      allowedItemIds: [],
      blockedItemIds: [],
    };
    const child = await as(manager, "PATCH", `/v1/profiles/${b}`, { kids });
    expect(child.body.playback).toEqual({ ...defaults, stillWatchingEpisodes: 2 });
    const refused = await as(viewer, "PUT", `/v1/profiles/${b}/playback`, { filmAutoplay: true });
    expect(refused.status).toBe(403);
    const grownUp = await as(manager, "PUT", `/v1/profiles/${b}/playback`, {
      stillWatchingEpisodes: 4,
    });
    expect(grownUp.body.playback).toEqual({ ...defaults, stillWatchingEpisodes: 4 });
    // What was chosen stays chosen when the viewer is no kids viewer any more; the rest follows.
    const grown = await as(manager, "PATCH", `/v1/profiles/${b}`, { kids: null });
    expect(grown.body.playback).toEqual({ ...defaults, stillWatchingEpisodes: 4 });

    const wrong = [
      { filmSuggestions: "yes" },
      { filmAutoplay: 1 },
      { episodeAutoplay: null },
      { startAtCredits: "true" },
      { countdownSeconds: 7 },
      { countdownSeconds: "10" },
      { stillWatchingEpisodes: 1 },
      { stillWatchingEpisodes: 6 },
      { stillWatchingHours: 5 },
      { stillWatchingHours: 1.5 },
    ];
    for (const body of wrong) {
      const put = await as(viewer, "PUT", `/v1/profiles/${a}/playback`, body);
      const patch = await as(manager, "PATCH", `/v1/profiles/${a}`, { playback: body });
      expect([body, put.status, patch.status]).toEqual([body, 400, 400]);
    }
    for (const body of [null, [], "x"]) {
      expect((await as(manager, "PATCH", `/v1/profiles/${a}`, { playback: body })).status).toBe(
        400,
      );
    }
    expect((await as(viewer, "PUT", `/v1/profiles/${a}/playback`, [])).status).toBe(400);
    expect(
      (await as(viewer, "PUT", "/v1/profiles/no-such-profile/playback", { filmAutoplay: true }))
        .status,
    ).toBe(404);
    // Nothing that was refused changed anything.
    expect((await listed())[0]).toEqual(later.body.playback);
  });

  it("remembers per viewer and title how far the subtitles were moved", async () => {
    const { viewer, a, b, item } = await setUpProgress();
    const offset = async (
      method: string,
      profile: string,
      title: string,
      body?: unknown,
    ): Promise<{ status: number; body: { offsetMs: number } }> =>
      call<{ offsetMs: number }>(
        fixture,
        method,
        `/v1/profiles/${profile}/subtitle-offsets/${title}`,
        {
          token: viewer,
          ...(body === undefined ? {} : { body }),
        },
      );
    expect((await offset("GET", a, item)).body).toEqual({ offsetMs: 0 });
    expect((await offset("PUT", a, item, { offsetMs: -1500 })).body).toEqual({ offsetMs: -1500 });
    expect((await offset("GET", a, item)).body).toEqual({ offsetMs: -1500 });
    expect((await offset("GET", b, item)).body).toEqual({ offsetMs: 0 });
    expect((await offset("PUT", a, item, { offsetMs: 250 })).body).toEqual({ offsetMs: 250 });
    expect((await offset("GET", a, item)).body).toEqual({ offsetMs: 250 });
    // Zero forgets it.
    expect((await offset("PUT", a, item, { offsetMs: 0 })).status).toBe(200);
    expect(fixture.db.get<{ n: number }>("select count(*) as n from subtitle_offset")?.n).toBe(0);

    for (const body of [{}, { offsetMs: 1.5 }, { offsetMs: "100" }, { offsetMs: 600_001 }]) {
      expect([body, (await offset("PUT", a, item, body)).status]).toEqual([body, 400]);
    }
    expect((await offset("GET", a, "no-such-title")).status).toBe(404);
    expect((await offset("PUT", a, "no-such-title", { offsetMs: 100 })).status).toBe(404);
    expect((await offset("GET", "no-such-profile", item)).status).toBe(404);
  });

  it("keeps each viewer's place separate", async () => {
    const { viewer, a, b, item } = await setUpProgress();
    const saved = await call<{ progress: Progress }>(
      fixture,
      "PUT",
      `/v1/profiles/${a}/progress/${item}`,
      {
        token: viewer,
        body: update("op-1", 1_264_000, null),
      },
    );
    expect(saved.status).toBe(200);
    expect(saved.body.progress).toMatchObject({
      itemId: item,
      positionMs: 1_264_000,
      completed: false,
    });

    const mine = await call<{ progress: Progress[]; revision: number }>(
      fixture,
      "GET",
      `/v1/profiles/${a}/progress`,
      {
        token: viewer,
      },
    );
    expect(mine.body.progress).toHaveLength(1);
    const theirs = await call<{ progress: Progress[] }>(
      fixture,
      "GET",
      `/v1/profiles/${b}/progress`,
      { token: viewer },
    );
    expect(theirs.body.progress).toEqual([]);

    // Only what changed since the last look.
    const idle = await call<{ progress: Progress[] }>(
      fixture,
      "GET",
      `/v1/profiles/${a}/progress?since=${mine.body.revision}`,
      { token: viewer },
    );
    expect(idle.body.progress).toEqual([]);
  });

  it("answers a retried change the same way and applies it once", async () => {
    const { viewer, a, item } = await setUpProgress();
    const body = update("op-retry", 500_000, null);
    const first = await call<{ progress: Progress }>(
      fixture,
      "PUT",
      `/v1/profiles/${a}/progress/${item}`,
      {
        token: viewer,
        body,
      },
    );
    const next = await call<{ progress: Progress }>(
      fixture,
      "PUT",
      `/v1/profiles/${a}/progress/${item}`,
      {
        token: viewer,
        body: update("op-next", 900_000, first.body.progress.revision),
      },
    );
    // The first request's reply was lost on the way; the device sends it again.
    const retry = await call<{ progress: Progress }>(
      fixture,
      "PUT",
      `/v1/profiles/${a}/progress/${item}`,
      {
        token: viewer,
        body,
      },
    );
    expect(retry.status).toBe(200);
    expect(retry.body).toEqual(first.body);
    const stored = await call<{ progress: Progress[] }>(
      fixture,
      "GET",
      `/v1/profiles/${a}/progress`,
      { token: viewer },
    );
    expect(stored.body.progress).toEqual([next.body.progress]);
  });

  it("does not let a stale offline position undo a newer mark-unwatched", async () => {
    const { viewer, a, item } = await setUpProgress();
    const lastWeek = fixture.clock.now - 7 * 24 * 3_600_000;
    const yesterday = fixture.clock.now - 24 * 3_600_000;

    // Both devices saw the film at 10 minutes.
    const seen = await call<{ progress: Progress }>(
      fixture,
      "PUT",
      `/v1/profiles/${a}/progress/${item}`,
      {
        token: viewer,
        body: update("op-seen", 600_000, null, { updatedAt: lastWeek - 1_000 }),
      },
    );
    const base = seen.body.progress.revision;

    // Yesterday, on the Mac: mark unwatched.
    const cleared = await call<{ progress: Progress }>(
      fixture,
      "PUT",
      `/v1/profiles/${a}/progress/${item}`,
      {
        token: viewer,
        body: update("op-clear", 0, base, { updatedAt: yesterday }),
      },
    );
    expect(cleared.status).toBe(200);

    // Today the iPad comes back online with a position from last week.
    const stale = await call<{ error: { code: string }; progress: Progress }>(
      fixture,
      "PUT",
      `/v1/profiles/${a}/progress/${item}`,
      { token: viewer, body: update("op-stale", 2_400_000, base, { updatedAt: lastWeek }) },
    );
    expect(stale.status).toBe(409);
    expect(stale.body.error.code).toBe("conflict");
    expect(stale.body.progress).toEqual(cleared.body.progress);
    // Its retry gets the same answer.
    const staleAgain = await call(fixture, "PUT", `/v1/profiles/${a}/progress/${item}`, {
      token: viewer,
      body: update("op-stale", 2_400_000, base, { updatedAt: lastWeek }),
    });
    expect(staleAgain.status).toBe(409);

    // Watching again after the mark-unwatched does win, even from the old view.
    const rewatch = await call<{ progress: Progress }>(
      fixture,
      "PUT",
      `/v1/profiles/${a}/progress/${item}`,
      {
        token: viewer,
        body: update("op-rewatch", 120_000, base, { updatedAt: fixture.clock.now }),
      },
    );
    expect(rewatch.status).toBe(200);
    expect(rewatch.body.progress.positionMs).toBe(120_000);
  });

  it("does not trust a device clock that runs ahead", async () => {
    const { viewer, a, item } = await setUpProgress();
    const future = await call<{ progress: Progress }>(
      fixture,
      "PUT",
      `/v1/profiles/${a}/progress/${item}`,
      {
        token: viewer,
        body: update("op-future", 1_000, null, {
          updatedAt: fixture.clock.now + 365 * 24 * 3_600_000,
        }),
      },
    );
    expect(future.body.progress.updatedAt).toBe(fixture.clock.now);
  });

  it("rejects malformed updates and unknown viewers or titles", async () => {
    const { viewer, a, item } = await setUpProgress();
    const bad = await call(fixture, "PUT", `/v1/profiles/${a}/progress/${item}`, {
      token: viewer,
      body: {
        opId: "x",
        positionMs: -5,
        baseRevision: null,
        durationMs: null,
        completed: false,
        updatedAt: 1,
      },
    });
    expect(bad.status).toBe(400);
    const noItem = await call(fixture, "PUT", `/v1/profiles/${a}/progress/no-such-item`, {
      token: viewer,
      body: update("op-a", 1, null),
    });
    expect(noItem.status).toBe(404);
    const noProfile = await call(fixture, "PUT", `/v1/profiles/no-such-profile/progress/${item}`, {
      token: viewer,
      body: update("op-b", 1, null),
    });
    expect(noProfile.status).toBe(404);
  });
});

describe("media", () => {
  async function setUpMedia(): Promise<{
    token: string;
    url: string;
    bytes: Buffer;
    revision: string;
  }> {
    const token = await claim(fixture);
    const path = join(fixture.movies, "Up (2009)/Up (2009).mp4");
    makeVideo(path, { seconds: 2 });
    await scan(fixture);
    const library = await syncAll(fixture, token);
    const file = library.items[0]?.files[0];
    return {
      token,
      url: `/v1/assets/${file?.assetId ?? ""}/content`,
      bytes: readFileSync(path),
      revision: file?.revision ?? "",
    };
  }

  async function bytesOf(
    url: string,
    token: string,
    headers: Record<string, string> = {},
  ): Promise<{ status: number; headers: Headers; data: Buffer }> {
    const response = await fixture.app.request(url, {
      headers: { Authorization: `Bearer ${token}`, ...headers },
    });
    return {
      status: response.status,
      headers: response.headers,
      data: Buffer.from(await response.arrayBuffer()),
    };
  }

  it("sends the whole file with its length, type and revision", async () => {
    const { token, url, bytes, revision } = await setUpMedia();
    const reply = await bytesOf(url, token);
    expect(reply.status).toBe(200);
    expect(reply.data.equals(bytes)).toBe(true);
    expect(reply.headers.get("Content-Length")).toBe(String(bytes.length));
    expect(reply.headers.get("Content-Type")).toBe("video/mp4");
    expect(reply.headers.get("Accept-Ranges")).toBe("bytes");
    expect(reply.headers.get("ETag")).toBe(`"${revision}"`);
  });

  it("answers HEAD with the same headers and no body", async () => {
    const { token, url, bytes } = await setUpMedia();
    const response = await fixture.app.request(url, {
      method: "HEAD",
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Length")).toBe(String(bytes.length));
    expect((await response.arrayBuffer()).byteLength).toBe(0);
  });

  it("serves byte ranges", async () => {
    const { token, url, bytes } = await setUpMedia();
    const size = bytes.length;

    const first = await bytesOf(url, token, { Range: "bytes=0-99" });
    expect(first.status).toBe(206);
    expect(first.headers.get("Content-Range")).toBe(`bytes 0-99/${size}`);
    expect(first.headers.get("Content-Length")).toBe("100");
    expect(first.data.equals(bytes.subarray(0, 100))).toBe(true);

    const middle = await bytesOf(url, token, { Range: "bytes=1000-1999" });
    expect(middle.data.equals(bytes.subarray(1000, 2000))).toBe(true);

    const openEnded = await bytesOf(url, token, { Range: `bytes=${size - 10}-` });
    expect(openEnded.headers.get("Content-Range")).toBe(`bytes ${size - 10}-${size - 1}/${size}`);
    expect(openEnded.data.equals(bytes.subarray(size - 10))).toBe(true);

    const suffix = await bytesOf(url, token, { Range: "bytes=-500" });
    expect(suffix.status).toBe(206);
    expect(suffix.data.equals(bytes.subarray(size - 500))).toBe(true);

    // A range that runs past the end is cut at the end.
    const long = await bytesOf(url, token, { Range: `bytes=${size - 5}-${size + 1000}` });
    expect(long.status).toBe(206);
    expect(long.data.length).toBe(5);
  });

  it("refuses a range outside the file", async () => {
    const { token, url, bytes } = await setUpMedia();
    const reply = await bytesOf(url, token, { Range: `bytes=${bytes.length}-` });
    expect(reply.status).toBe(416);
    expect(reply.headers.get("Content-Range")).toBe(`bytes */${bytes.length}`);
  });

  it("ignores a malformed or multi-part range and sends the whole file", async () => {
    const { token, url, bytes } = await setUpMedia();
    for (const range of ["bytes=abc", "bytes=0-10,20-30", "items=0-5", "bytes=20-10"]) {
      const reply = await bytesOf(url, token, { Range: range });
      expect(reply.status, range).toBe(200);
      expect(reply.data.length, range).toBe(bytes.length);
    }
  });

  it("starts a resumed download over when the file changed", async () => {
    const { token, url, bytes, revision } = await setUpMedia();
    const same = await bytesOf(url, token, { Range: "bytes=100-199", "If-Range": `"${revision}"` });
    expect(same.status).toBe(206);
    const changed = await bytesOf(url, token, {
      Range: "bytes=100-199",
      "If-Range": '"an-older-revision"',
    });
    expect(changed.status).toBe(200);
    expect(changed.data.length).toBe(bytes.length);
  });

  it("never opens a path that leaves the library folder", async () => {
    const { token, url } = await setUpMedia();
    const outside = join(fixture.dir, "private.mp4");
    writeFileSync(outside, "household secrets");
    // The indexed file is swapped for a link after the scan.
    const indexed = join(fixture.movies, "Up (2009)/Up (2009).mp4");
    rmSync(indexed);
    symlinkSync(outside, indexed);
    const reply = await bytesOf(url, token);
    expect(reply.status).toBe(503);
    expect(reply.data.toString()).not.toContain("household secrets");
  });

  it("answers 404 for a file it does not know", async () => {
    const { token } = await setUpMedia();
    expect((await bytesOf("/v1/assets/no-such-asset/content", token)).status).toBe(404);
  });
});
