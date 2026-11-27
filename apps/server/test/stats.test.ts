// SPDX-License-Identifier: MPL-2.0
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Hono } from "hono";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { Devices } from "../src/auth/devices.ts";
import { Database } from "../src/db/database.ts";
import { createApp, type AppEnv } from "../src/http/app.ts";
import { ItemReader } from "../src/library/items.ts";
import { ProgressStore } from "../src/progress.ts";
import { RemoteHub } from "../src/remote/hub.ts";
import { rangeOf, StatsReader, streaks } from "../src/stats/aggregate.ts";
import { Statistics } from "../src/stats/recorder.ts";
import { roadOf } from "../src/stats/routes.ts";
import { Clock } from "../src/stats/time.ts";
import { makeTempDir, removeDir } from "./support/media.ts";

const SETUP_SECRET = "test-setup-secret";
const DAY = 86_400_000;
const MINUTE = 60_000;
/** Thursday 2027-01-14 12:00 UTC. */
const NOW = Date.UTC(2027, 0, 14, 12, 0, 0);

interface Reply<T> {
  status: number;
  body: T;
}

interface Fixture {
  dir: string;
  db: Database;
  app: Hono<AppEnv>;
  stats: Statistics;
  remote: RemoteHub;
  clock: { now: number };
  keepDays: { value: number };
}

function setUp(): Fixture {
  const dir = makeTempDir();
  const clock = { now: NOW };
  const now = (): number => clock.now;
  const keepDays = { value: 730 };
  const db = new Database(join(dir, "lobby.db"));
  const stats = new Statistics(db, { now, keepDays: () => keepDays.value });
  const devices = new Devices(db, SETUP_SECRET, now);
  const remote = new RemoteHub({ db, devices, now });
  const app = createApp({
    db,
    devices,
    remote,
    items: new ItemReader(db),
    progress: new ProgressStore(db, now),
    stats,
    storage: () => ({ playbackCacheBytes: 1234 }),
    serverName: "Test Lobby",
    version: "0.0.0-test",
    isScanning: () => false,
    now,
  });
  return { dir, db, app, stats, remote, clock, keepDays };
}

async function call<T = Record<string, unknown>>(
  f: Fixture,
  token: string,
  method: string,
  path: string,
  body?: unknown,
): Promise<Reply<T>> {
  const headers: Record<string, string> = { Authorization: `Bearer ${token}` };
  if (body !== undefined) headers["Content-Type"] = "application/json";
  const response = await f.app.request(path, {
    method,
    headers,
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const text = await response.text();
  return { status: response.status, body: (text === "" ? null : JSON.parse(text)) as T };
}

async function claim(f: Fixture): Promise<string> {
  const response = await f.app.request("/v1/pairing/claim", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ setupSecret: SETUP_SECRET, deviceName: "Mac", platform: "macos" }),
  });
  expect(response.status).toBe(201);
  return ((await response.json()) as { token: string }).token;
}

async function pair(
  f: Fixture,
  manager: string,
  name: string,
): Promise<{ id: string; token: string }> {
  const ask = async (path: string, body: unknown): Promise<Response> =>
    f.app.request(path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  const request = (await (
    await ask("/v1/pairing/requests", { deviceName: name, platform: "ios" })
  ).json()) as { id: string; code: string; pollSecret: string };
  expect(
    (await call(f, manager, "POST", "/v1/pairing/approve", { code: request.code, role: "viewer" }))
      .status,
  ).toBe(200);
  const collected = (await (
    await ask(`/v1/pairing/requests/${request.id}/collect`, { pollSecret: request.pollSecret })
  ).json()) as { device: { id: string }; token: string };
  return { id: collected.device.id, token: collected.token };
}

let lives = 0;
/** The device's app says, on its live channel, who is in front; null for nobody. */
async function inFront(f: Fixture, token: string, profileId: string | null): Promise<void> {
  lives += 1;
  const session = `live-${String(lives)}`;
  const opened = await f.app.request(`/v1/live?session=${session}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  expect(opened.status).toBe(200);
  await opened.body?.cancel();
  const said = await call(f, token, "POST", `/v1/live/${session}`, {
    order: 1,
    foreground: true,
    canPlay: true,
    profileId,
    capabilities: [],
  });
  expect(said.status).toBe(200);
}

let revision = 0;
function item(
  f: Fixture,
  id: string,
  kind: string,
  title: string,
  more: { parent?: string; season?: number; episode?: number; addedAt?: number } = {},
): string {
  revision += 1;
  f.db.run(
    `insert into item (id, kind, parent_id, ident_key, title, sort_title, season_number,
       episode_number, added_at, revision) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [
      id,
      kind,
      more.parent ?? null,
      `key:${id}`,
      title,
      title,
      more.season ?? null,
      more.episode ?? null,
      more.addedAt ?? NOW - 40 * DAY,
      revision,
    ],
  );
  return id;
}

function profile(f: Fixture, id: string, name: string, household = "owner", kids = false): string {
  f.db.run(
    `insert into profile (id, name, color, created_at, household_id, kids_json)
     values (?, ?, 'blue', ?, ?, ?)`,
    [
      id,
      name,
      NOW - 100 * DAY,
      household,
      kids
        ? JSON.stringify({
            allowedGroupIds: [],
            allowedCategoryIds: [],
            allowedItemIds: ["film", "show"],
            blockedItemIds: [],
            blockedCategoryIds: [],
          })
        : null,
    ],
  );
  return id;
}

let sessions = 0;
function session(
  f: Fixture,
  profileId: string,
  itemId: string,
  titleId: string,
  startedAt: number,
  watchedMs: number,
  more: { household?: string; device?: string | null; completed?: boolean; road?: string } = {},
): string {
  sessions += 1;
  const id = `s${String(sessions)}`;
  f.db.run(
    `insert into watch_session (id, profile_id, household_id, device_id, item_id, title_id,
       started_at, ended_at, timed, watched_ms, completed, road)
     values (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)`,
    [
      id,
      profileId,
      more.household ?? "owner",
      more.device ?? null,
      itemId,
      titleId,
      startedAt,
      startedAt + watchedMs,
      watchedMs,
      more.completed ? 1 : 0,
      more.road ?? "home",
    ],
  );
  return id;
}

/** A film, and a series with a season of three episodes. */
function library(f: Fixture): void {
  item(f, "film", "movie", "Balloon");
  item(f, "show", "show", "Boats");
  item(f, "s1", "season", "Season 1", { parent: "show", season: 1 });
  for (const n of [1, 2, 3]) {
    item(f, `e${String(n)}`, "episode", `Episode ${String(n)}`, {
      parent: "s1",
      season: 1,
      episode: n,
    });
  }
  f.db.run("insert into genre (id, name) values (1, 'Animation')");
  f.db.run("insert into item_genre (item_id, genre_id) values ('film', 1), ('show', 1)");
}

describe("statistics", () => {
  let f: Fixture;
  beforeEach(() => {
    f = setUp();
    library(f);
  });
  afterEach(() => {
    f.remote.stop();
    f.db.close();
    removeDir(f.dir);
  });

  it("makes sittings of the places a device reports", async () => {
    const manager = await claim(f);
    const me = profile(f, "me", "Me");
    const put = (
      at: number,
      positionMs: number,
      completed = false,
      itemId = "film",
    ): Promise<Reply<unknown>> =>
      call(f, manager, "PUT", `/v1/profiles/${me}/progress/${itemId}`, {
        opId: `op-${String(at)}-${itemId}`,
        baseRevision: null,
        positionMs,
        durationMs: 90 * MINUTE,
        completed,
        updatedAt: at,
      });
    const start = NOW - 3 * 3_600_000;
    f.clock.now = start;
    expect((await put(start, 0)).status).toBe(200);
    for (let n = 1; n <= 9; n += 1) {
      f.clock.now = start + n * 10 * MINUTE;
      expect((await put(f.clock.now, n * 10 * MINUTE, n === 9)).status).toBe(200);
    }
    // An hour later, the first episode: a new sitting.
    f.clock.now = start + 150 * MINUTE;
    await put(f.clock.now - 20 * MINUTE, 0, false, "e1");
    await put(f.clock.now, 20 * MINUTE, false, "e1");
    f.clock.now = NOW;

    const rows = f.db.all<{
      item_id: string;
      title_id: string;
      watched_ms: number;
      completed: number;
      road: string;
      device_id: string | null;
      delivery: string;
    }>(
      "select item_id, title_id, watched_ms, completed, road, device_id, delivery from watch_session order by started_at",
    );
    expect(rows.map((row) => [row.item_id, row.title_id, row.watched_ms, row.completed])).toEqual([
      ["film", "film", 90 * MINUTE, 1],
      ["e1", "show", 20 * MINUTE, 0],
    ]);
    expect(rows[0]?.road).toBe("home");
    expect(rows[0]?.delivery).toBe("unknown");
    expect(rows[0]?.device_id).not.toBeNull();

    const reply = await call<{
      totals: Record<string, number>;
      topTitles: { itemId: string; watchedMs: number }[];
      series: { itemId: string; episodes: number; episodesWatched: number; lastEpisode: string }[];
      genres: { name: string; watchedMs: number }[];
      history: { title: string; subtitle: string | null; device: string | null }[];
      devices: { name: string }[];
    }>(f, manager, "GET", `/v1/stats/viewers/${me}?range=week&tz=UTC`);
    expect(reply.status).toBe(200);
    expect(reply.body.totals["watchedMs"]).toBe(110 * MINUTE);
    expect(reply.body.totals["filmsFinished"]).toBe(1);
    expect(reply.body.topTitles.map((one) => one.itemId)).toEqual(["film", "show"]);
    expect(reply.body.series).toEqual([
      expect.objectContaining({
        itemId: "show",
        episodes: 3,
        episodesWatched: 0,
        lastEpisode: "S1 E1",
      }),
    ]);
    expect(reply.body.genres).toEqual([
      expect.objectContaining({ name: "Animation", watchedMs: 110 * MINUTE }),
    ]);
    expect(reply.body.history[0]).toEqual(
      expect.objectContaining({ title: "Boats", subtitle: "S1 E1 · Episode 1", device: "Mac" }),
    );
    expect(reply.body.devices.map((one) => one.name)).toEqual(["Mac"]);
  });

  it("makes one sitting per episode of a skipped intro and an Up Next at the credits", async () => {
    const manager = await claim(f);
    const me = profile(f, "me", "Me");
    const SECOND = 1000;
    const put = (itemId: string, at: number, positionMs: number, completed = false) => {
      f.clock.now = at;
      return call(f, manager, "PUT", `/v1/profiles/${me}/progress/${itemId}`, {
        opId: `op-${String(at)}-${itemId}`,
        baseRevision: null,
        positionMs,
        durationMs: 44 * MINUTE,
        completed,
        updatedAt: at,
      });
    };
    const start = NOW - 2 * 3_600_000;
    // The first episode: 30 s, then Skip Intro jumps from 0:30 to 2:00, and it plays on.
    await put("e1", start, 0);
    await put("e1", start + 30 * SECOND, 30 * SECOND);
    await put("e1", start + 40 * SECOND, 130 * SECOND);
    let at = start + 40 * SECOND;
    let position = 130 * SECOND;
    while (position < 40 * MINUTE) {
      at += MINUTE;
      position = Math.min(40 * MINUTE, position + MINUTE);
      await put("e1", at, position);
    }
    // The credits start at 40:00: Up Next counts down 10 s, and the next one starts by itself.
    // The first is finished there, not at its end.
    at += 10 * SECOND;
    await put("e1", at, 40 * MINUTE + 10 * SECOND, true);
    await put("e2", at + SECOND, 0);
    await put("e2", at + 5 * MINUTE, 5 * MINUTE);
    f.clock.now = NOW;

    const rows = f.db.all<{ item_id: string; watched_ms: number; completed: number }>(
      "select item_id, watched_ms, completed from watch_session order by started_at",
    );
    expect(rows.map((row) => [row.item_id, row.completed])).toEqual([
      ["e1", 1],
      ["e2", 0],
    ]);
    // The skipped intro is not counted as watched: at most the slack of one report.
    const wall = at - start;
    expect(rows[0]?.watched_ms).toBeLessThanOrEqual(wall + 15 * SECOND);
    expect(rows[0]?.watched_ms).toBeLessThan(40 * MINUTE + 10 * SECOND);
    expect(rows[1]?.watched_ms).toBe(5 * MINUTE);
    const reply = await call<{ totals: Record<string, number> }>(
      f,
      manager,
      "GET",
      `/v1/stats/viewers/${me}?range=week&tz=UTC`,
    );
    expect(reply.body.totals["episodesFinished"]).toBe(1);
    expect(reply.body.totals["watchedMs"]).toBe((rows[0]?.watched_ms ?? 0) + 5 * MINUTE);
  });

  it("buckets days and hours in the viewer's time zone", () => {
    const me = profile(f, "me", "Me");
    // Thursday 2027-01-14, 03:30 UTC: still Wednesday evening in New York, noon in Tokyo.
    session(f, me, "film", "film", Date.UTC(2027, 0, 14, 3, 30), 30 * MINUTE);
    const reader = new StatsReader(f.db);
    const at = (zone: string): Record<string, unknown> => {
      const clock = new Clock(zone);
      return reader.viewer(me, rangeOf("week", clock, NOW, f.stats.oldest), clock, {
        view: null,
        oldest: f.stats.oldest,
      });
    };
    const busy = (result: Record<string, unknown>): [string, number][] =>
      (result["days"] as { day: string; watchedMs: number }[])
        .filter((one) => one.watchedMs > 0)
        .map((one) => [one.day, one.watchedMs]);
    const cell = (result: Record<string, unknown>, weekday: number, hour: number): number =>
      (result["heatmap"] as number[][])[weekday]?.[hour] ?? 0;

    const york = at("America/New_York");
    expect(busy(york)).toEqual([["2027-01-13", 30 * MINUTE]]);
    expect(cell(york, 2, 22)).toBe(30 * MINUTE);
    expect((york["when"] as Record<string, number>)["evenings"]).toBe(30 * MINUTE);

    const tokyo = at("Asia/Tokyo");
    expect(busy(tokyo)).toEqual([["2027-01-14", 30 * MINUTE]]);
    expect(cell(tokyo, 3, 12)).toBe(30 * MINUTE);

    // Half an hour off: 09:00 to 09:30 in India.
    const india = at("Asia/Kolkata");
    expect(cell(india, 3, 9)).toBe(30 * MINUTE);

    // Across midnight in UTC: split between the two days.
    session(f, me, "film", "film", Date.UTC(2027, 0, 12, 23, 30), 60 * MINUTE);
    expect(busy(at("UTC"))).toEqual([
      ["2027-01-12", 30 * MINUTE],
      ["2027-01-13", 30 * MINUTE],
      ["2027-01-14", 30 * MINUTE],
    ]);
  });

  it("keeps the range to whole local days, and the days of a range dense", () => {
    const clock = new Clock("Europe/Amsterdam");
    const range = rangeOf("week", clock, NOW, NOW - 730 * DAY);
    expect(range.firstDay).toBe("2027-01-08");
    expect(range.lastDay).toBe("2027-01-14");
    expect(range.from).toBe(Date.UTC(2027, 0, 7, 23, 0));
    // Summer time: midnight is 22:00 UTC.
    expect(clock.startOf("2027-07-01")).toBe(Date.UTC(2027, 5, 30, 22, 0));
    expect(
      streaks(new Set(["2027-01-10", "2027-01-11", "2027-01-13", "2027-01-14"]), "2027-01-14"),
    ).toEqual({
      current: 2,
      longest: 2,
    });
    expect(streaks(new Set(["2027-01-12", "2027-01-13"]), "2027-01-14")).toEqual({
      current: 2,
      longest: 2,
    });
    expect(streaks(new Set(["2027-01-11"]), "2027-01-14").current).toBe(0);
  });

  it("keeps households apart, and other households to totals", async () => {
    const manager = await claim(f);
    f.db.run(
      "insert into household (id, name, owner, created_at) values ('guest', 'Neighbours', 0, ?)",
      [NOW],
    );
    const me = profile(f, "me", "Me");
    const them = profile(f, "them", "Them", "guest");
    const guest = await pair(f, manager, "Their iPad");
    f.db.run("update device set household_id = 'guest', access = 'household_admin' where id = ?", [
      guest.id,
    ]);
    session(f, me, "film", "film", NOW - DAY, 60 * MINUTE);
    session(f, them, "e1", "show", NOW - DAY, 40 * MINUTE, { household: "guest" });
    f.stats.noteSent("guest", "relay", 5_000_000, NOW - DAY);
    f.stats.noteSent("owner", "home", 7_000_000, NOW - DAY);

    // The owner's viewers are not there for the guest household; the server admin sees theirs.
    expect((await call(f, guest.token, "GET", `/v1/stats/viewers/${me}`)).status).toBe(404);
    expect((await call(f, manager, "GET", `/v1/stats/viewers/${them}`)).status).toBe(200);
    expect((await call(f, guest.token, "GET", "/v1/stats/server")).status).toBe(404);
    const theirs = await call<{ totals: { watchedMs: number } }>(
      f,
      guest.token,
      "GET",
      `/v1/stats/viewers/${them}`,
    );
    expect(theirs.body.totals.watchedMs).toBe(40 * MINUTE);

    interface Server {
      totals: { watchedMs: number };
      viewers: { id: string }[];
      topTitles: { itemId: string }[];
      households: { id: string; watchedMs: number; bytesSent: number }[];
      traffic: { homeBytes: number; awayBytes: number };
      storage: Record<string, number>;
      household: { id: string } | null;
    }
    const server = await call<Server>(f, manager, "GET", "/v1/stats/server?range=month&tz=UTC");
    expect(server.status).toBe(200);
    expect(server.body.totals.watchedMs).toBe(100 * MINUTE);
    expect(server.body.viewers.map((one) => one.id)).toEqual([me]);
    expect(server.body.topTitles.map((one) => one.itemId)).toEqual(["film"]);
    expect(server.body.households).toEqual([
      expect.objectContaining({ id: "owner", watchedMs: 60 * MINUTE, bytesSent: 7_000_000 }),
      expect.objectContaining({ id: "guest", watchedMs: 40 * MINUTE, bytesSent: 5_000_000 }),
    ]);
    expect(server.body.traffic).toEqual(
      expect.objectContaining({ homeBytes: 7_000_000, awayBytes: 5_000_000 }),
    );
    expect(server.body.storage).toEqual({ playbackCacheBytes: 1234 });

    // The owner opens the guest household.
    const opened = await call<Server>(f, manager, "GET", "/v1/stats/server?household=guest");
    expect(opened.body.household?.id).toBe("guest");
    expect(opened.body.viewers.map((one) => one.id)).toEqual([them]);
    expect((await call(f, manager, "GET", "/v1/stats/server?household=nobody")).status).toBe(404);
  });

  describe("who sees which statistics", () => {
    interface Roles {
      manager: string;
      me: string;
      partner: string;
      kid: string;
      them: string;
      theirKid: string;
      viewer: { id: string; token: string };
      householdAdmin: { id: string; token: string };
      guestAdmin: { id: string; token: string };
      child: { id: string; token: string };
      sittings: { mine: string; partners: string; kids: string };
    }

    /** Two households: the owner's with two grown-ups and a child, and a guest one. */
    async function roles(): Promise<Roles> {
      const manager = await claim(f);
      f.db.run(
        "insert into household (id, name, owner, created_at) values ('guest', 'Neighbours', 0, ?)",
        [NOW],
      );
      const me = profile(f, "me", "Me");
      const partner = profile(f, "partner", "Partner");
      const kid = profile(f, "kid", "Kid", "owner", true);
      const them = profile(f, "them", "Them", "guest");
      const theirKid = profile(f, "their-kid", "Their kid", "guest", true);
      const viewer = await pair(f, manager, "My iPhone");
      const householdAdmin = await pair(f, manager, "Living room");
      f.db.run("update device set access = 'household_admin' where id = ?", [householdAdmin.id]);
      const guestAdmin = await pair(f, manager, "Their iPad");
      f.db.run(
        "update device set household_id = 'guest', access = 'household_admin' where id = ?",
        [guestAdmin.id],
      );
      const child = await pair(f, manager, "Kid's iPad");
      expect(
        (await call(f, manager, "PATCH", `/v1/devices/${child.id}`, { kidsProfileId: kid })).status,
      ).toBe(200);
      const sittings = {
        mine: session(f, me, "film", "film", NOW - DAY, 60 * MINUTE, { device: viewer.id }),
        partners: session(f, partner, "e1", "show", NOW - DAY, 20 * MINUTE),
        kids: session(f, kid, "film", "film", NOW - 2 * DAY, 30 * MINUTE, { device: child.id }),
      };
      session(f, them, "e1", "show", NOW - DAY, 40 * MINUTE, { household: "guest" });
      session(f, theirKid, "film", "film", NOW - DAY, 10 * MINUTE, { household: "guest" });
      f.stats.noteSent("guest", "relay", 5_000_000, NOW - DAY);
      f.stats.noteSent("owner", "home", 7_000_000, NOW - DAY);
      return {
        manager,
        me,
        partner,
        kid,
        them,
        theirKid,
        viewer,
        householdAdmin,
        guestAdmin,
        child,
        sittings,
      };
    }

    const status = async (token: string, method: string, path: string): Promise<number> =>
      (await call(f, token, method, path)).status;

    it("shows a server admin every viewer of every household, children too", async () => {
      const r = await roles();
      for (const id of [r.me, r.partner, r.kid, r.them, r.theirKid]) {
        expect(await status(r.manager, "GET", `/v1/stats/viewers/${id}`)).toBe(200);
      }
      const child = await call(f, r.manager, "GET", `/v1/stats/viewers/${r.kid}`);
      expect(child.body["simple"]).toBe(false);
      expect(child.body["history"]).toBeDefined();
      expect(await status(r.manager, "GET", "/v1/stats/server")).toBe(200);
      const guest = await call<{ totals: { watchedMs: number }; household: { id: string } }>(
        f,
        r.manager,
        "GET",
        "/v1/stats/household?household=guest&range=month&tz=UTC",
      );
      expect(guest.status).toBe(200);
      expect(guest.body.household.id).toBe("guest");
      expect(guest.body.totals.watchedMs).toBe(50 * MINUTE);
      // And deletes from anyone's history, and forgets a guest's.
      expect(
        await status(
          r.manager,
          "DELETE",
          `/v1/stats/viewers/${r.partner}/history/${r.sittings.partners}`,
        ),
      ).toBe(204);
      expect(await status(r.manager, "DELETE", `/v1/stats/viewers/${r.them}`)).toBe(204);
    });

    it("shows a household admin their household's viewers and its overview, nothing else", async () => {
      const r = await roles();
      for (const id of [r.me, r.partner, r.kid]) {
        expect(await status(r.householdAdmin.token, "GET", `/v1/stats/viewers/${id}`)).toBe(200);
      }
      for (const id of [r.them, r.theirKid]) {
        expect(await status(r.householdAdmin.token, "GET", `/v1/stats/viewers/${id}`)).toBe(404);
      }
      for (const id of [r.me, r.kid]) {
        expect(await status(r.guestAdmin.token, "GET", `/v1/stats/viewers/${id}`)).toBe(404);
      }
      expect(await status(r.guestAdmin.token, "GET", `/v1/stats/viewers/${r.theirKid}`)).toBe(200);
      expect(await status(r.householdAdmin.token, "GET", "/v1/stats/server")).toBe(403);
      expect(await status(r.guestAdmin.token, "GET", "/v1/stats/server")).toBe(404);

      const overview = await call(
        f,
        r.guestAdmin.token,
        "GET",
        "/v1/stats/household?range=month&tz=UTC",
      );
      expect(overview.status).toBe(200);
      expect(Object.keys(overview.body).sort()).toEqual(
        [
          "keptDays",
          "range",
          "household",
          "totals",
          "days",
          "heatmap",
          "hours",
          "topTitles",
          "viewers",
          "devices",
          "roads",
          "deliveries",
          "traffic",
          "playOn",
        ].sort(),
      );
      expect((overview.body["totals"] as { watchedMs: number }).watchedMs).toBe(50 * MINUTE);
      expect((overview.body["viewers"] as { id: string }[]).map((one) => one.id).sort()).toEqual(
        [r.them, r.theirKid].sort(),
      );
      expect(overview.body["traffic"]).toEqual(
        expect.objectContaining({ homeBytes: 0, awayBytes: 5_000_000 }),
      );
      const home = await call<{ totals: { watchedMs: number } }>(
        f,
        r.householdAdmin.token,
        "GET",
        "/v1/stats/household?range=month&tz=UTC",
      );
      expect(home.body.totals.watchedMs).toBe(110 * MINUTE);
      expect(await status(r.guestAdmin.token, "GET", "/v1/stats/household?household=owner")).toBe(
        404,
      );
      expect(
        await status(r.householdAdmin.token, "GET", "/v1/stats/household?household=guest"),
      ).toBe(404);
      expect(await status(r.householdAdmin.token, "DELETE", `/v1/stats/viewers/${r.kid}`)).toBe(
        204,
      );
      expect(await status(r.guestAdmin.token, "DELETE", `/v1/stats/viewers/${r.me}`)).toBe(404);
    });

    it("shows a viewer only themselves, as the viewer in front on their device", async () => {
      const r = await roles();
      const mine = `/v1/stats/viewers/${r.me}`;
      // Before the app said who is in front, not even their own.
      expect(await status(r.viewer.token, "GET", mine)).toBe(403);
      await inFront(f, r.viewer.token, r.me);
      const own = await call<{ totals: { watchedMs: number } }>(f, r.viewer.token, "GET", mine);
      expect(own.status).toBe(200);
      expect(own.body.totals.watchedMs).toBe(60 * MINUTE);
      // Not the other grown-up, not the child, not another household's, not the overviews.
      expect(await status(r.viewer.token, "GET", `/v1/stats/viewers/${r.partner}`)).toBe(403);
      expect(await status(r.viewer.token, "GET", `/v1/stats/viewers/${r.kid}`)).toBe(403);
      expect(await status(r.viewer.token, "GET", `/v1/stats/viewers/${r.them}`)).toBe(404);
      expect(await status(r.viewer.token, "GET", "/v1/stats/household")).toBe(403);
      expect(await status(r.viewer.token, "GET", "/v1/stats/server")).toBe(403);
      // Deleting goes as seeing; forgetting is for admins.
      expect(
        await status(
          r.viewer.token,
          "DELETE",
          `/v1/stats/viewers/${r.partner}/history/${r.sittings.partners}`,
        ),
      ).toBe(403);
      expect(await status(r.viewer.token, "DELETE", `/v1/stats/viewers/${r.me}`)).toBe(403);
      expect(await status(r.viewer.token, "DELETE", `${mine}/history/${r.sittings.partners}`)).toBe(
        404,
      );
      expect(await status(r.viewer.token, "DELETE", `${mine}/history/${r.sittings.mine}`)).toBe(
        204,
      );

      // The partner takes the device: now theirs, and no longer mine.
      await inFront(f, r.viewer.token, r.partner);
      expect(await status(r.viewer.token, "GET", `/v1/stats/viewers/${r.partner}`)).toBe(200);
      expect(await status(r.viewer.token, "GET", mine)).toBe(403);
      // Nobody chosen: nobody's.
      await inFront(f, r.viewer.token, null);
      expect(await status(r.viewer.token, "GET", `/v1/stats/viewers/${r.partner}`)).toBe(403);
      // Another household's viewer named in front counts for nothing.
      await inFront(f, r.viewer.token, r.them);
      expect(f.remote.inFront(r.viewer.id)).toBeNull();

      await inFront(f, r.viewer.token, r.me);
      expect(await status(r.viewer.token, "GET", `${mine}?range=decade`)).toBe(400);
    });

    it("shows a child nothing, and a device in kids mode nothing", async () => {
      const r = await roles();
      for (const path of [
        `/v1/stats/viewers/${r.kid}`,
        `/v1/stats/viewers/${r.me}`,
        "/v1/stats/household",
        "/v1/stats/server",
      ]) {
        expect(await status(r.child.token, "GET", path)).toBe(404);
      }
      expect(
        await status(
          r.child.token,
          "DELETE",
          `/v1/stats/viewers/${r.kid}/history/${r.sittings.kids}`,
        ),
      ).toBe(404);

      // A grown-up's device in kids mode: the child is in front, admin or not.
      await inFront(f, r.householdAdmin.token, r.kid);
      expect(await status(r.householdAdmin.token, "GET", `/v1/stats/viewers/${r.kid}`)).toBe(403);
      expect(await status(r.householdAdmin.token, "GET", "/v1/stats/household")).toBe(403);
      await inFront(f, r.viewer.token, r.kid);
      expect(await status(r.viewer.token, "GET", `/v1/stats/viewers/${r.kid}`)).toBe(403);
      // Back as a grown-up, the admin sees the child again: they are the parent.
      await inFront(f, r.householdAdmin.token, r.partner);
      expect(await status(r.householdAdmin.token, "GET", `/v1/stats/viewers/${r.kid}`)).toBe(200);
    });
  });

  it("forgets a viewer's history, and keeps their places", async () => {
    const manager = await claim(f);
    const me = profile(f, "me", "Me");
    session(f, me, "film", "film", NOW - DAY, 60 * MINUTE);
    f.db.run(
      "insert into play (profile_id, item_id, day, watched_ms, counted) values (?, 'film', '2027-01-13', 1, 1)",
      [me],
    );
    f.db.run(
      `insert into progress (profile_id, item_id, position_ms, duration_ms, completed, revision, updated_at)
       values (?, 'film', 1000, 2000, 0, 1, ?)`,
      [me, NOW - DAY],
    );
    f.db.run(
      `insert into music_play (op_id, profile_id, track_id, played_at, played_ms, completed)
       values ('m1', ?, 'track', ?, 1000, 1)`,
      [me, NOW - DAY],
    );
    expect((await call(f, manager, "DELETE", `/v1/stats/viewers/${me}`)).status).toBe(204);
    const count = (table: string): number =>
      f.db.get<{ n: number }>(`select count(*) as n from ${table} where profile_id = ?`, [me])?.n ??
      -1;
    expect([count("watch_session"), count("play"), count("music_play"), count("progress")]).toEqual(
      [0, 0, 0, 1],
    );
  });

  it("keeps nothing longer than the household says", () => {
    const me = profile(f, "me", "Me");
    session(f, me, "film", "film", NOW - 40 * DAY, MINUTE);
    session(f, me, "film", "film", NOW - 10 * DAY, MINUTE);
    f.stats.noteSent("owner", "home", 10, NOW - 40 * DAY);
    f.db.run(
      `insert into music_play (op_id, profile_id, track_id, played_at, played_ms, completed)
       values ('old', ?, 'track', ?, 1000, 1)`,
      [me, NOW - 40 * DAY],
    );
    f.stats.prune(true);
    expect(f.db.get<{ n: number }>("select count(*) as n from watch_session")?.n).toBe(2);
    f.keepDays.value = 30;
    f.stats.prune(true);
    expect(f.db.get<{ n: number }>("select count(*) as n from watch_session")?.n).toBe(1);
    expect(f.db.get<{ n: number }>("select count(*) as n from stats_traffic")?.n).toBe(0);
    expect(f.db.get<{ n: number }>("select count(*) as n from music_play")?.n).toBe(0);
    // Nothing older than that is taken in, either.
    f.stats.noteWatch(
      me,
      "film",
      null,
      { positionMs: MINUTE, durationMs: DAY, completed: false, updatedAt: NOW - 31 * DAY },
      { deviceId: "d", householdId: "owner", road: "home" },
    );
    expect(f.db.get<{ n: number }>("select count(*) as n from watch_session")?.n).toBe(1);
  });

  it("says how it was sent and where it was sent from", () => {
    const me = profile(f, "me", "Me");
    f.db.run(
      `insert into source (id, path, name, hint, created_at) values ('src', '/x', 'X', 'movies', 0)`,
    );
    f.db.run(
      `insert into asset (id, source_id, rel_path, size, mtime_ms, revision, state, first_seen_at, updated_at)
       values ('a1', 'src', 'a.mp4', 1, 1, 'r', 'probed', 0, 0)`,
    );
    f.db.run("insert into item_asset (item_id, asset_id) values ('film', 'a1')");
    const place = (
      at: number,
      positionMs: number,
    ): { positionMs: number; durationMs: number; completed: boolean; updatedAt: number } => ({
      positionMs,
      durationMs: 90 * MINUTE,
      completed: false,
      updatedAt: at,
    });
    f.stats.notePlayback("tv", "a1", "prepared");
    f.stats.notePlayOn("phone", "tv", "film");
    f.stats.noteWatch(me, "film", place(NOW - 5 * MINUTE, 0), place(NOW, 5 * MINUTE), {
      deviceId: "tv",
      householdId: "owner",
      road: "tailnet",
    });
    const row = f.db.get<{ delivery: string; play_on_from: string; road: string }>(
      "select delivery, play_on_from, road from watch_session",
    );
    expect(row).toEqual({ delivery: "prepared", play_on_from: "phone", road: "tailnet" });

    expect(roadOf({ env: undefined })).toBe("home");
    const socket = (address: string): { env: AppEnv["Bindings"] } => ({
      env: { incoming: { socket: { remoteAddress: address } } } as unknown as AppEnv["Bindings"],
    });
    expect(roadOf(socket("100.101.102.103"))).toBe("tailnet");
    expect(roadOf(socket("192.168.1.20"))).toBe("home");
    const outside = (transport: string): { env: AppEnv["Bindings"] } => ({
      env: { outside: { transport } } as unknown as AppEnv["Bindings"],
    });
    expect(roadOf(outside("direct"))).toBe("direct");
    expect(roadOf(outside("relay"))).toBe("relay");
  });

  it("counts the bytes sent, by household and road", async () => {
    const manager = await claim(f);
    writeFileSync(join(f.dir, "a.mp4"), Buffer.alloc(100_000, 1));
    f.db.run(
      `insert into source (id, path, name, hint, created_at) values ('src', ?, 'X', 'movies', 0)`,
      [f.dir],
    );
    f.db.run(
      `insert into asset (id, source_id, rel_path, size, mtime_ms, revision, state, container,
         first_seen_at, updated_at)
       values ('a1', 'src', 'a.mp4', 100000, 1, 'r', 'probed', 'mov,mp4,m4a,3gp,3g2,mj2', 0, 0)`,
    );
    const whole = await f.app.request("/v1/assets/a1/content", {
      headers: { Authorization: `Bearer ${manager}` },
    });
    expect(whole.status).toBe(200);
    expect((await whole.arrayBuffer()).byteLength).toBe(100_000);
    const part = await f.app.request("/v1/assets/a1/content", {
      headers: { Authorization: `Bearer ${manager}`, Range: "bytes=0-999" },
    });
    expect(part.status).toBe(206);
    await part.arrayBuffer();
    expect(f.db.all("select household_id, road, bytes from stats_traffic")).toEqual([
      { household_id: "owner", road: "home", bytes: 101_000 },
    ]);
  });

  it("knows what was watched before, by the day", () => {
    const me = profile(f, "me", "Me");
    f.db.run(
      "insert into play (profile_id, item_id, day, watched_ms, counted) values (?, 'e2', '2027-01-10', 600000, 1)",
      [me],
    );
    // As if the statistics came later: the migration runs again on this catalogue.
    for (const sql of [
      "drop trigger profile_deleted_drops_sessions",
      "drop table watch_session",
      "drop table stats_traffic",
      "drop table stats_event",
      "drop index music_play_at",
      "delete from schema_migration where version = 24",
    ]) {
      f.db.run(sql);
    }
    f.db.close();
    f.db = new Database(join(f.dir, "lobby.db"));
    const rows = f.db.all<{ item_id: string; title_id: string; timed: number; watched_ms: number }>(
      "select item_id, title_id, timed, watched_ms from watch_session",
    );
    expect(rows).toEqual([{ item_id: "e2", title_id: "show", timed: 0, watched_ms: 600000 }]);
  });

  it("works out a year of 50,000 sittings quickly", () => {
    const viewers = Array.from({ length: 10 }, (_, n) =>
      profile(f, `p${String(n)}`, `P${String(n)}`),
    );
    f.db.transaction(() => {
      for (let n = 0; n < 50_000; n += 1) {
        const episode = `e${String((n % 3) + 1)}`;
        const film = n % 2 === 0;
        session(
          f,
          viewers[n % viewers.length] ?? "p0",
          film ? "film" : episode,
          film ? "film" : "show",
          NOW - Math.floor((n / 50_000) * 360 * DAY),
          20 * MINUTE,
          { device: `d${String(n % 7)}`, completed: n % 5 === 0 },
        );
      }
    });
    const reader = new StatsReader(f.db);
    const clock = new Clock("Europe/Amsterdam");
    const range = rangeOf("year", clock, NOW, f.stats.oldest);
    let started = performance.now();
    const one = reader.viewer("p0", range, clock, {
      view: null,
      oldest: f.stats.oldest,
    });
    const viewerMs = performance.now() - started;
    started = performance.now();
    const all = reader.server(range, clock, {
      householdId: null,
      ownerHouseholdId: "owner",
      storage: {},
    });
    const serverMs = performance.now() - started;
    expect((one["totals"] as Record<string, number>)["sessions"]).toBe(5_000);
    expect((all["totals"] as Record<string, number>)["sessions"]).toBe(50_000);
    expect(viewerMs).toBeLessThan(1_000);
    expect(serverMs).toBeLessThan(3_000);
    // The queries go by their indexes.
    const plan = f.db.all<{ detail: string }>(
      "explain query plan select id from watch_session where profile_id = ? and started_at >= ?",
      ["p0", 0],
    );
    expect(plan.map((row) => row.detail).join(" ")).toContain("watch_session_profile");
  }, 60_000);
});
