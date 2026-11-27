// SPDX-License-Identifier: MPL-2.0
import { mkdirSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import type { Hono } from "hono";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { Devices } from "../src/auth/devices.ts";
import { Database } from "../src/db/database.ts";
import { CACHE_IS_FULL, DOES_NOT_FIT_CACHE } from "../src/devices-downloads/ahead.ts";
import {
  DeviceDownloads,
  type DeviceList,
  type DeviceOverview,
  type WantedEntry,
} from "../src/devices-downloads/index.ts";
import { createApp, type AppEnv } from "../src/http/app.ts";
import { createAssetLookup } from "../src/http/playback-assets.ts";
import { Catalogue } from "../src/library/catalogue.ts";
import { ItemReader, type ApiItem } from "../src/library/items.ts";
import { Scanner } from "../src/library/scanner.ts";
import { PlaybackService } from "../src/playback/index.ts";
import { ProgressStore } from "../src/progress.ts";
import { makeMkv, waitFor } from "./playback-support.ts";
import { makeTempDir, makeVideo, removeDir } from "./support/media.ts";

const SETUP_SECRET = "test-setup-secret";
const HOUR = 3_600_000;

interface Fixture {
  dir: string;
  movies: string;
  series: string;
  db: Database;
  scanner: Scanner;
  playback: PlaybackService;
  downloads: DeviceDownloads;
  app: Hono<AppEnv>;
  clock: { now: number };
}

interface Reply<T> {
  status: number;
  body: T;
  headers: Headers;
}

interface ErrorBody {
  error: { code: string; message: string };
}

async function setUp(options: { maxCacheBytes?: number } = {}): Promise<Fixture> {
  const dir = makeTempDir("lobby-downloads-");
  const movies = join(dir, "Movies");
  const series = join(dir, "Series");
  mkdirSync(movies);
  mkdirSync(series);
  const clock = { now: 1_800_000_000_000 };
  const now = (): number => clock.now;
  const db = new Database(join(dir, "lobby.db"));
  const scanner = new Scanner(db, new Catalogue(db, now), {
    stabilityMs: 0,
    probeConcurrency: 2,
    ffprobePath: "ffprobe",
    now,
    volumeOf: () => Promise.resolve(1),
  });
  scanner.syncSources([
    { path: movies, name: "Films", hint: "movies" },
    { path: series, name: "Series", hint: "series" },
  ]);
  const playback = new PlaybackService({
    cacheDir: join(dir, "cache"),
    minFreeBytes: 0,
    now,
    ...(options.maxCacheBytes !== undefined ? { maxCacheBytes: options.maxCacheBytes } : {}),
  });
  await playback.start();
  const devices = new Devices(db, SETUP_SECRET, now);
  // Not started: the tests call `ahead.tick()` themselves. No quiet time, so a tick acts at once.
  const downloads = new DeviceDownloads({
    db,
    playback,
    lookupAsset: createAssetLookup(db),
    now,
    aheadQuietMs: 0,
  });
  const app = createApp({
    db,
    devices,
    items: new ItemReader(db),
    progress: new ProgressStore(db, now),
    playback,
    downloads,
    serverName: "Test Lobby",
    version: "0.0.0-test",
    isScanning: () => scanner.isScanning,
    now,
  });
  return { dir, movies, series, db, scanner, playback, downloads, app, clock };
}

describe("what a manager puts on each device", () => {
  let fixture: Fixture;

  afterEach(async () => {
    await fixture.downloads.stop();
    await fixture.playback.close();
    fixture.db.close();
    removeDir(fixture.dir);
  });

  async function call<T = Record<string, unknown>>(
    method: string,
    path: string,
    options: {
      token?: string;
      body?: unknown;
      headers?: Record<string, string>;
      raw?: string;
    } = {},
  ): Promise<Reply<T>> {
    const headers: Record<string, string> = { ...options.headers };
    if (options.token) headers["Authorization"] = `Bearer ${options.token}`;
    const text =
      options.raw ?? (options.body === undefined ? undefined : JSON.stringify(options.body));
    if (text !== undefined) headers["Content-Type"] = "application/json";
    const response = await fixture.app.request(path, {
      method,
      headers,
      ...(text === undefined ? {} : { body: text }),
    });
    const replied = await response.text();
    return {
      status: response.status,
      body: (replied === "" ? null : JSON.parse(replied)) as T,
      headers: response.headers,
    };
  }

  async function claim(): Promise<string> {
    const reply = await call<{ token: string }>("POST", "/v1/pairing/claim", {
      body: { setupSecret: SETUP_SECRET, deviceName: "Manager Mac", platform: "macos" },
    });
    expect(reply.status).toBe(201);
    return reply.body.token;
  }

  /** Pairs a device the way the apps do and returns its credential and id. */
  async function pair(
    manager: string,
    name: string,
    role: "viewer" | "manager" = "viewer",
  ): Promise<{ token: string; id: string }> {
    const request = await call<{ id: string; code: string; pollSecret: string }>(
      "POST",
      "/v1/pairing/requests",
      { body: { deviceName: name, platform: "ipados" } },
    );
    await call("POST", "/v1/pairing/approve", {
      token: manager,
      body: { code: request.body.code, role },
    });
    const collected = await call<{ token: string; device: { id: string } }>(
      "POST",
      `/v1/pairing/requests/${request.body.id}/collect`,
      { body: { pollSecret: request.body.pollSecret } },
    );
    expect(collected.status).toBe(200);
    return { token: collected.body.token, id: collected.body.device.id };
  }

  async function scan(): Promise<ApiItem[]> {
    await fixture.scanner.scanAll();
    await fixture.scanner.processQueue();
    const page = await call<{ items: ApiItem[] }>("GET", "/v1/library?limit=1000", {
      token: managerToken,
    });
    return page.body.items;
  }

  function find(items: ApiItem[], kind: string, title?: string): ApiItem {
    const item = items.find(
      (candidate) => candidate.kind === kind && (title === undefined || candidate.title === title),
    );
    if (!item) throw new Error(`no ${kind} ${title ?? ""} in the library`);
    return item;
  }

  function episodes(items: ApiItem[]): ApiItem[] {
    return items
      .filter((item) => item.kind === "episode")
      .sort((a, b) => (a.episodeNumber ?? 0) - (b.episodeNumber ?? 0));
  }

  async function want(deviceId: string, body: unknown): Promise<Reply<{ entry: WantedEntry }>> {
    return call<{ entry: WantedEntry }>("POST", `/v1/devices/${deviceId}/wanted`, {
      token: managerToken,
      body,
    });
  }

  async function ownList(token: string): Promise<DeviceList> {
    const reply = await call<DeviceList>("GET", "/v1/me/wanted", { token });
    expect(reply.status).toBe(200);
    return reply.body;
  }

  async function overview(deviceId: string): Promise<DeviceOverview> {
    const reply = await call<DeviceOverview>("GET", `/v1/devices/${deviceId}/wanted`, {
      token: managerToken,
    });
    expect(reply.status).toBe(200);
    return reply.body;
  }

  let managerToken: string;

  describe("with files that play as they are", () => {
    let items: ApiItem[];
    let ipad: { token: string; id: string };
    let phone: { token: string; id: string };

    beforeEach(async () => {
      fixture = await setUp();
      managerToken = await claim();
      makeVideo(join(fixture.movies, "Up (2009)/Up (2009).mp4"));
      for (const number of [1, 2, 3, 4]) {
        makeVideo(join(fixture.series, `Bluey/Season 01/Bluey S01E0${number}.mp4`), {
          seed: number,
        });
      }
      makeVideo(join(fixture.series, "Bluey/Season 02/Bluey S02E01.mp4"), { seed: 9 });
      items = await scan();
      ipad = await pair(managerToken, "Kids iPad");
      phone = await pair(managerToken, "A phone");
    });

    it("lets only a manager read or change a device's list", async () => {
      const film = find(items, "movie");
      const added = await want(ipad.id, { kind: "item", itemId: film.id });
      expect(added.status).toBe(201);

      // A viewer device: not another device's list, and not its own through the manager's routes.
      for (const target of [ipad.id, phone.id]) {
        for (const [method, path, body] of [
          ["GET", "/v1/devices/wanted", undefined],
          ["GET", `/v1/devices/${target}/wanted`, undefined],
          ["POST", `/v1/devices/${target}/wanted`, { kind: "item", itemId: film.id }],
          ["DELETE", `/v1/devices/${target}/wanted/${added.body.entry.id}`, undefined],
        ] as const) {
          const reply = await call<ErrorBody>(method, path, { token: phone.token, body });
          expect(reply.status, `${method} ${path}`).toBe(403);
          expect(reply.body.error.code).toBe("forbidden");
        }
      }
      // Nothing changed.
      expect((await overview(ipad.id)).wanted).toHaveLength(1);
      expect((await overview(phone.id)).wanted).toHaveLength(0);

      // Its own view holds its own list only, whatever the request says.
      expect((await ownList(ipad.token)).assets).toHaveLength(1);
      expect((await ownList(phone.token)).assets).toHaveLength(0);
      const sneaky = await call<DeviceList>("GET", `/v1/me/wanted?deviceId=${ipad.id}`, {
        token: phone.token,
        headers: { "X-Device-Id": ipad.id },
      });
      expect(sneaky.body.assets).toHaveLength(0);

      // A report lands on the device that sent it, even when it names another.
      const report = await call("POST", "/v1/me/downloads", {
        token: phone.token,
        body: { deviceId: ipad.id, freeBytes: 5, totalBytes: 10, downloads: [] },
      });
      expect(report.status).toBe(200);
      expect((await overview(ipad.id)).storage).toBeNull();
      expect((await overview(phone.id)).storage).toMatchObject({ freeBytes: 5, totalBytes: 10 });

      // Without a credential there is nothing at all.
      for (const [method, path] of [
        ["GET", "/v1/me/wanted"],
        ["POST", "/v1/me/downloads"],
        ["GET", `/v1/devices/${ipad.id}/wanted`],
        ["POST", `/v1/devices/${ipad.id}/wanted`],
      ] as const) {
        const body = method === "POST" ? { body: {} } : {};
        expect((await call(method, path, body)).status, path).toBe(401);
      }
    });

    it("turns a film and a season into an ordered list of files to fetch", async () => {
      const film = find(items, "movie");
      const season = find(items, "season", "Season 1");
      expect((await want(ipad.id, { kind: "item", itemId: season.id })).status).toBe(201);
      expect((await want(ipad.id, { kind: "item", itemId: film.id })).status).toBe(201);
      // Saying it again changes nothing.
      const again = await want(ipad.id, { kind: "item", itemId: film.id });
      expect(again.status).toBe(200);

      const first = await call<DeviceList>("GET", "/v1/me/wanted", { token: ipad.token });
      expect(first.status).toBe(200);
      const list = first.body;
      const seasonOne = episodes(items).filter((episode) => episode.seasonNumber === 1);
      expect(list.assets.map((asset) => asset.itemId)).toEqual([
        ...seasonOne.map((episode) => episode.id),
        film.id,
      ]);
      expect(list.assets.map((asset) => asset.order)).toEqual([1, 2, 3, 4, 5]);
      const filmFile = film.files[0];
      expect(list.assets[4]).toEqual({
        assetId: filmFile?.assetId,
        itemId: film.id,
        revision: filmFile?.revision,
        order: 5,
        bytes: statSync(join(fixture.movies, "Up (2009)/Up (2009).mp4")).size,
        bytesExact: true,
        state: "ready",
        mode: "direct",
        downloadUrl: `/v1/assets/${filmFile?.assetId ?? ""}/content`,
        message: null,
        why: [{ wantedId: again.body.entry.id, kind: "item" }],
      });
      // The URL is the real file.
      const head = await call("HEAD", list.assets[4]?.downloadUrl ?? "", { token: ipad.token });
      expect(Number(head.headers.get("Content-Length"))).toBe(list.assets[4]?.bytes);

      // Polling is cheap while nothing changes.
      const etag = first.headers.get("ETag") ?? "";
      expect(etag).toBe(`"${list.revision}"`);
      const unchanged = await call("GET", "/v1/me/wanted", {
        token: ipad.token,
        headers: { "If-None-Match": etag },
      });
      expect(unchanged.status).toBe(304);
      expect(unchanged.body).toBeNull();

      // Taking the film off changes the list and its revision.
      const removed = await call("DELETE", `/v1/devices/${ipad.id}/wanted/${again.body.entry.id}`, {
        token: managerToken,
      });
      expect(removed.status).toBe(204);
      const changed = await call<DeviceList>("GET", "/v1/me/wanted", {
        token: ipad.token,
        headers: { "If-None-Match": etag },
      });
      expect(changed.status).toBe(200);
      expect(changed.body.assets).toHaveLength(4);
      expect(changed.body.revision).not.toBe(list.revision);
      // An entry of another device cannot be removed through this one.
      const other = await want(phone.id, { kind: "item", itemId: film.id });
      const wrong = await call("DELETE", `/v1/devices/${ipad.id}/wanted/${other.body.entry.id}`, {
        token: managerToken,
      });
      expect(wrong.status).toBe(404);
      expect((await overview(phone.id)).wanted).toHaveLength(1);
    });

    it("keeps the next unwatched episodes for a viewer, moving on as they are watched", async () => {
      const show = find(items, "show");
      const profile = await call<{ id: string }>("POST", "/v1/profiles", {
        token: managerToken,
        body: { name: "Kid" },
      });
      const rule = await want(ipad.id, {
        kind: "next_unwatched",
        showId: show.id,
        profileId: profile.body.id,
        count: 2,
      });
      expect(rule.status).toBe(201);
      expect(rule.body.entry).toMatchObject({
        kind: "next_unwatched",
        itemId: show.id,
        itemKind: "show",
        profileId: profile.body.id,
        count: 2,
      });

      const all = [
        ...episodes(items).filter((episode) => episode.seasonNumber === 1),
        ...episodes(items).filter((episode) => episode.seasonNumber === 2),
      ];
      const before = await ownList(ipad.token);
      expect(before.assets.map((asset) => asset.itemId)).toEqual([all[0]?.id, all[1]?.id]);
      expect(before.assets[0]?.why).toEqual([
        { wantedId: rule.body.entry.id, kind: "next_unwatched" },
      ]);

      // The first episode is watched to the end, on any device.
      const watched = await call("PUT", `/v1/profiles/${profile.body.id}/progress/${all[0]?.id}`, {
        token: phone.token,
        body: {
          opId: "op-1",
          baseRevision: null,
          positionMs: 1000,
          durationMs: 1000,
          completed: true,
          updatedAt: fixture.clock.now,
        },
      });
      expect(watched.status).toBe(200);
      const after = await ownList(ipad.token);
      expect(after.assets.map((asset) => asset.itemId)).toEqual([all[1]?.id, all[2]?.id]);
      expect(after.revision).not.toBe(before.revision);

      // Asking for the same rule again changes how far it looks ahead; it crosses into season 2.
      const wider = await want(ipad.id, {
        kind: "next_unwatched",
        showId: show.id,
        profileId: profile.body.id,
        count: 10,
      });
      expect(wider.status).toBe(200);
      expect(wider.body.entry.id).toBe(rule.body.entry.id);
      expect((await ownList(ipad.token)).assets.map((asset) => asset.itemId)).toEqual(
        all.slice(1).map((episode) => episode.id),
      );

      // A removed viewer watches nothing next: the rule stays on the list and asks for nothing.
      await call("DELETE", `/v1/profiles/${profile.body.id}`, { token: managerToken });
      expect((await overview(ipad.id)).wanted.map((entry) => entry.profileId)).toEqual([
        profile.body.id,
      ]);
      expect((await ownList(ipad.token)).assets).toEqual([]);
    });

    it("refuses requests that do not make sense", async () => {
      const film = find(items, "movie");
      const show = find(items, "show");
      const profile = await call<{ id: string }>("POST", "/v1/profiles", {
        token: managerToken,
        body: { name: "Kid" },
      });
      const rule = { kind: "next_unwatched", showId: show.id, profileId: profile.body.id };
      for (const [body, status] of [
        [{}, 400],
        [{ kind: "everything" }, 400],
        [{ kind: "item" }, 400],
        [{ kind: "item", itemId: "../../etc" }, 400],
        [{ kind: "item", itemId: "a".repeat(65) }, 400],
        [{ kind: "item", itemId: "no-such-item" }, 404],
        [{ ...rule, count: 0 }, 400],
        [{ ...rule, count: 51 }, 400],
        [{ ...rule, count: 1.5 }, 400],
        [{ ...rule, showId: film.id, count: 2 }, 400],
        [{ ...rule, profileId: "no-such-viewer", count: 2 }, 404],
      ] as const) {
        const reply = await want(ipad.id, body);
        expect(reply.status, JSON.stringify(body)).toBe(status);
      }
      expect((await want("no-such-device", { kind: "item", itemId: film.id })).status).toBe(404);
      expect(
        (await call("GET", "/v1/devices/no-such-device/wanted", { token: managerToken })).status,
      ).toBe(404);
      expect((await overview(ipad.id)).wanted).toHaveLength(0);
    });

    it("takes a device's report, bounded and checked, and shows it to the manager", async () => {
      const film = find(items, "movie");
      const season = find(items, "season", "Season 1");
      await want(ipad.id, { kind: "item", itemId: film.id });
      await want(ipad.id, { kind: "item", itemId: season.id });
      const list = await ownList(ipad.token);
      const [filmAsset, first, second] = list.assets;
      if (!filmAsset || !first || !second) throw new Error("expected three files");
      const extra = episodes(items).find((episode) => episode.seasonNumber === 2)?.files[0];

      const good = {
        freeBytes: filmAsset.bytes + first.bytes,
        totalBytes: 64_000_000_000,
        downloads: [
          {
            assetId: filmAsset.assetId,
            revision: filmAsset.revision,
            state: "downloaded",
            bytesDone: filmAsset.bytes,
            bytesTotal: filmAsset.bytes,
          },
          {
            assetId: first.assetId,
            revision: first.revision,
            state: "downloading",
            bytesDone: 10,
            bytesTotal: first.bytes,
          },
          {
            assetId: second.assetId,
            revision: second.revision,
            state: "failed",
            bytesDone: 0,
            bytesTotal: null,
            error: "no_space",
          },
          // Something the person on the device downloaded themselves.
          {
            assetId: extra?.assetId,
            revision: extra?.revision,
            state: "downloaded",
            bytesDone: extra?.sizeBytes,
            bytesTotal: extra?.sizeBytes,
            own: true,
          },
        ],
      };
      const entry = good.downloads[0];
      for (const bad of [
        { ...good, downloads: "all of them" },
        { ...good, downloads: [null] },
        { ...good, downloads: [{ ...entry, assetId: "has spaces" }] },
        { ...good, downloads: [{ ...entry, state: "exploded" }] },
        { ...good, downloads: [{ ...entry, bytesDone: -1 }] },
        { ...good, downloads: [{ ...entry, bytesDone: 1.5 }] },
        { ...good, downloads: [{ ...entry, bytesDone: 2 ** 60 }] },
        { ...good, downloads: [{ ...entry, bytesDone: 11, bytesTotal: 10 }] },
        { ...good, downloads: [{ ...entry, revision: "r".repeat(101) }] },
        { ...good, downloads: [{ ...entry, state: "failed", error: "<script>" }] },
        { ...good, downloads: [{ ...entry, own: "yes" }] },
        { ...good, downloads: [entry, entry] },
        {
          ...good,
          downloads: Array.from({ length: 5001 }, (_, n) => ({ ...entry, assetId: `a${n}` })),
        },
        { ...good, freeBytes: -5 },
        { ...good, freeBytes: 10, totalBytes: 5 },
      ]) {
        const reply = await call<ErrorBody>("POST", "/v1/me/downloads", {
          token: ipad.token,
          body: bad,
        });
        expect(reply.status, JSON.stringify(bad).slice(0, 120)).toBe(400);
        expect(reply.body.error.code).toBe("invalid_request");
      }
      const huge = await call("POST", "/v1/me/downloads", {
        token: ipad.token,
        raw: JSON.stringify({ ...good, padding: "x".repeat(1024 * 1024) }),
      });
      expect(huge.status).toBe(400);
      expect((await overview(ipad.id)).storage).toBeNull();

      const reply = await call<{ accepted: number; wantedRevision: string }>(
        "POST",
        "/v1/me/downloads",
        { token: ipad.token, body: good },
      );
      expect(reply.status).toBe(200);
      expect(reply.body).toEqual({ accepted: 4, wantedRevision: list.revision });

      const seen = await overview(ipad.id);
      expect(seen.storage).toEqual({
        freeBytes: good.freeBytes,
        totalBytes: 64_000_000_000,
        reportedAt: fixture.clock.now,
      });
      expect(seen.assets.map((asset) => asset.device?.state ?? null)).toEqual([
        "downloaded",
        "downloading",
        "failed",
        null,
        null,
      ]);
      expect(seen.assets[2]?.device).toMatchObject({ error: "no_space", bytesTotal: null });
      // Everything but the finished film still has to come, less the ten bytes that are there.
      const rest = seen.assets.slice(1).reduce((sum, asset) => sum + asset.bytes, 0) - 10;
      expect(seen.bytesToFetch).toBe(rest);
      // It was given room for two files and needs four.
      expect(seen.fits).toBe(false);
      // The person's own download is kept apart from what the manager wants.
      expect(seen.other).toEqual([
        {
          assetId: extra?.assetId,
          revision: extra?.revision,
          state: "downloaded",
          bytesDone: extra?.sizeBytes,
          bytesTotal: extra?.sizeBytes,
          error: null,
          own: true,
          reportedAt: fixture.clock.now,
          itemId: episodes(items).find((episode) => episode.seasonNumber === 2)?.id,
        },
      ]);

      const summaries = await call<{ devices: Record<string, unknown>[] }>(
        "GET",
        "/v1/devices/wanted",
        { token: managerToken },
      );
      expect(summaries.body.devices).toHaveLength(3);
      expect(summaries.body.devices.find((device) => device["id"] === ipad.id)).toMatchObject({
        name: "Kids iPad",
        entries: 2,
        files: 5,
        downloaded: 1,
        failed: 1,
        ownDownloads: 1,
        bytesToFetch: rest,
      });

      // The next report replaces the last one.
      await call("POST", "/v1/me/downloads", {
        token: ipad.token,
        body: { downloads: [] },
      });
      const cleared = await overview(ipad.id);
      expect(cleared.other).toEqual([]);
      expect(cleared.storage).toMatchObject({ freeBytes: null, totalBytes: null });
      expect(cleared.fits).toBeNull();
    });

    it("drops a device's list when the device is removed", async () => {
      const film = find(items, "movie");
      await want(ipad.id, { kind: "item", itemId: film.id });
      await call("POST", "/v1/me/downloads", {
        token: ipad.token,
        body: { freeBytes: 1, totalBytes: 2, downloads: [] },
      });
      await want(phone.id, { kind: "item", itemId: film.id });

      expect((await call("DELETE", `/v1/devices/${ipad.id}`, { token: managerToken })).status).toBe(
        204,
      );
      const count = (table: string): number =>
        fixture.db.get<{ n: number }>(`select count(*) as n from ${table} where device_id = ?`, [
          ipad.id,
        ])?.n ?? -1;
      expect(count("device_wanted")).toBe(0);
      expect(count("device_storage")).toBe(0);
      expect(count("device_download")).toBe(0);
      expect(
        (await call("GET", `/v1/devices/${ipad.id}/wanted`, { token: managerToken })).status,
      ).toBe(404);
      expect(
        (await want(ipad.id, { kind: "item", itemId: film.id })).status,
        "a removed device takes nothing new",
      ).toBe(404);
      expect((await call("GET", "/v1/me/wanted", { token: ipad.token })).status).toBe(401);
      // The other device keeps its list.
      expect((await overview(phone.id)).wanted).toHaveLength(1);
    });
  });

  describe("with files that have to be prepared", () => {
    let ipad: { token: string; id: string };

    async function library(names: string[]): Promise<ApiItem[]> {
      names.forEach((name, index) => {
        makeMkv(join(fixture.movies, `${name} (20${10 + index})/${name} (20${10 + index}).mkv`), {
          seconds: 4,
        });
      });
      const items = await scan();
      return names.map((name) => find(items, "movie", name));
    }

    function copies(): string[] {
      return readdirSync(join(fixture.dir, "cache", "prepared"));
    }

    it(
      "prepares a wanted file ahead, so the device finds it ready",
      { timeout: 120_000 },
      async () => {
        fixture = await setUp();
        managerToken = await claim();
        ipad = await pair(managerToken, "Kids iPad");
        const [film] = await library(["Brave"]);
        if (!film) throw new Error("no film");
        await want(ipad.id, { kind: "item", itemId: film.id });

        const file = film.files[0];
        const base = `/v1/assets/${file?.assetId ?? ""}/prepared/${file?.revision ?? ""}`;
        const done = await waitFor(async () => {
          await fixture.downloads.ahead?.tick();
          const list = await ownList(ipad.token);
          return list.assets[0]?.state === "ready" ? list : null;
        });
        expect(done.assets[0]).toMatchObject({
          state: "ready",
          mode: "prepared",
          bytesExact: true,
          downloadUrl: `${base}/media.mp4`,
        });
        const head = await call("HEAD", `${base}/media.mp4`, { token: ipad.token });
        expect(head.status).toBe(200);
        expect(Number(head.headers.get("Content-Length"))).toBe(done.assets[0]?.bytes);
        expect((await overview(ipad.id)).assets[0]?.prepareProgress).toBe(1);

        expect(copies()).toHaveLength(1);
      },
    );

    it("waits while someone is watching", { timeout: 120_000 }, async () => {
      fixture = await setUp();
      managerToken = await claim();
      ipad = await pair(managerToken, "Kids iPad");
      const [film] = await library(["Brave"]);
      if (!film) throw new Error("no film");
      // A real quiet time for this test.
      const downloads = new DeviceDownloads({
        db: fixture.db,
        playback: fixture.playback,
        lookupAsset: createAssetLookup(fixture.db),
        now: () => fixture.clock.now,
        aheadQuietMs: 90_000,
      });
      downloads.add(ipad.id, { kind: "item", itemId: film.id }, "test");
      // The add above looks at the list once by itself.
      await downloads.ahead?.tick();
      expect(downloads.list(ipad.id).assets[0]?.state).toBe("preparing");
      await waitFor(() => downloads.list(ipad.id).assets[0]?.state === "ready");

      // Now with someone watching: a second device's file is left alone until it is quiet.
      const phone = await pair(managerToken, "A phone");
      makeMkv(join(fixture.movies, "Cars (2006)/Cars (2006).mkv"), { seconds: 4 });
      const cars = find(await scan(), "movie", "Cars");
      downloads.ahead?.noteActivity();
      downloads.add(phone.id, { kind: "item", itemId: cars.id }, "test");
      await downloads.ahead?.tick();
      fixture.clock.now += 60_000;
      await downloads.ahead?.tick();
      expect(downloads.list(phone.id).assets[0]?.state).toBe("waiting");
      fixture.clock.now += 31_000;
      await downloads.ahead?.tick();
      expect(downloads.list(phone.id).assets[0]?.state).toBe("preparing");
      await waitFor(() => downloads.list(phone.id).assets[0]?.state === "ready");
      await downloads.stop();
    });

    it(
      "says plainly when a file is larger than the cache, and does no work for it",
      { timeout: 120_000 },
      async () => {
        fixture = await setUp({ maxCacheBytes: 1000 });
        managerToken = await claim();
        ipad = await pair(managerToken, "Kids iPad");
        const [film] = await library(["Brave"]);
        if (!film) throw new Error("no film");
        await want(ipad.id, { kind: "item", itemId: film.id });
        expect((await ownList(ipad.token)).assets[0]?.state).toBe("waiting");
        for (let round = 0; round < 3; round += 1) {
          await fixture.downloads.ahead?.tick();
          fixture.clock.now += 2 * HOUR;
        }
        const list = await ownList(ipad.token);
        expect(list.assets[0]).toMatchObject({
          state: "does_not_fit",
          downloadUrl: null,
          message: DOES_NOT_FIT_CACHE,
        });
        expect(copies()).toEqual([]);
        expect((await overview(ipad.id)).assets[0]).toMatchObject({ state: "does_not_fit" });
      },
    );

    it(
      "never evicts one wanted copy for another, and goes on when there is room",
      { timeout: 180_000 },
      async () => {
        const probe = makeTempDir("lobby-size-");
        makeMkv(join(probe, "size.mkv"), { seconds: 4 });
        const size = statSync(join(probe, "size.mkv")).size;
        removeDir(probe);
        // Room for one copy, not for two.
        fixture = await setUp({ maxCacheBytes: Math.round(size * 1.6) });
        managerToken = await claim();
        ipad = await pair(managerToken, "Kids iPad");
        const [brave, cars] = await library(["Brave", "Cars"]);
        if (!brave || !cars) throw new Error("no films");
        await want(ipad.id, { kind: "item", itemId: brave.id });
        await want(ipad.id, { kind: "item", itemId: cars.id });

        await waitFor(async () => {
          await fixture.downloads.ahead?.tick();
          return (await ownList(ipad.token)).assets[0]?.state === "ready";
        });
        const firstCopy = copies();
        expect(firstCopy).toHaveLength(1);

        // Days pass. The first copy is still waited for, so the second never pushes it out.
        for (let round = 0; round < 6; round += 1) {
          fixture.clock.now += 30 * HOUR;
          await fixture.downloads.ahead?.tick();
          expect(copies()).toEqual(firstCopy);
        }
        const stuck = await ownList(ipad.token);
        expect(stuck.assets.map((asset) => asset.state)).toEqual(["ready", "does_not_fit"]);
        expect(stuck.assets[1]?.message).toBe(CACHE_IS_FULL);

        // The device fetches the first file. Its copy is no longer waited for, but it was just used.
        const first = stuck.assets[0];
        if (!first) throw new Error("no first file");
        const fetched = await call("HEAD", first.downloadUrl ?? "", { token: ipad.token });
        expect(fetched.status).toBe(200);
        await call("POST", "/v1/me/downloads", {
          token: ipad.token,
          body: {
            downloads: [
              {
                assetId: first.assetId,
                revision: first.revision,
                state: "downloaded",
                bytesDone: first.bytes,
                bytesTotal: first.bytes,
              },
            ],
          },
        });
        fixture.clock.now += HOUR;
        await fixture.downloads.ahead?.tick();
        expect(copies()).toEqual(firstCopy);
        expect((await ownList(ipad.token)).assets[1]?.state).toBe("does_not_fit");

        // A day later nobody has used it: now it makes room for the second.
        fixture.clock.now += 25 * HOUR;
        await waitFor(async () => {
          await fixture.downloads.ahead?.tick();
          return (await ownList(ipad.token)).assets[1]?.state === "ready";
        });
        expect(copies()).toHaveLength(1);
        expect(copies()).not.toEqual(firstCopy);
        // The first file is on the device, so nothing prepares it again: no back and forth.
        for (let round = 0; round < 3; round += 1) {
          fixture.clock.now += 30 * HOUR;
          await fixture.downloads.ahead?.tick();
        }
        expect((await ownList(ipad.token)).assets.map((asset) => asset.state)).toEqual([
          "waiting",
          "ready",
        ]);
      },
    );
  });
});
