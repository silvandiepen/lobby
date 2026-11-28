// SPDX-License-Identifier: MPL-2.0
import { createPublicKey, generateKeyPairSync, verify } from "node:crypto";
import { chmodSync, writeFileSync } from "node:fs";
import { createServer } from "node:http2";
import type { AddressInfo } from "node:net";
import { join } from "node:path";
import type { Hono } from "hono";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { Devices } from "../src/auth/devices.ts";
import { Database } from "../src/db/database.ts";
import { createApp, type AppDeps, type AppEnv } from "../src/http/app.ts";
import { Households } from "../src/households/store.ts";
import { invitesOf } from "../src/households/invites.ts";
import { kidsControl, REQUESTS_PER_HOUR, type KidsControl } from "../src/kids/control.ts";
import { KIDS_MODE_ROUTES, KIDS_ROUTES } from "../src/kids/guard.ts";
import { OUTSIDE_ROUTES } from "../src/outside/guard.ts";
import { HOUSEHOLD_LEVELS, HOUSEHOLD_ROUTES } from "../src/households/guard.ts";
import type { KidsPlan, PlanBlock } from "../src/kids/plan.ts";
import { Catalogue } from "../src/library/catalogue.ts";
import { ItemReader, type ApiItem } from "../src/library/items.ts";
import { Scanner } from "../src/library/scanner.ts";
import { MusicLibrary } from "../src/music/index.ts";
import { ProgressStore } from "../src/progress.ts";
import { PushService } from "../src/push/service.ts";
import { RemoteHub, WakeService } from "../src/remote/index.ts";
import type { Player } from "../src/remote/messages.ts";
import { makeAudio } from "./support/audio.ts";
import { makeTempDir, makeVideo, removeDir } from "./support/media.ts";
import { cpSync } from "node:fs";

/** Tuesday 2026-11-24, 16:00 in Amsterdam. */
const TUESDAY_4PM = Date.parse("2026-11-24T15:00:00Z");
const MINUTE = 60_000;
const ZONE = "Europe/Amsterdam";

let dir: string;
let files: string;
let db: Database;
let devices: Devices;
let app: Hono<AppEnv>;
let deps: AppDeps;
let hub: RemoteHub;
let control: KidsControl;
let music: MusicLibrary;
let clock: { now: number };
let admin: { id: string; token: string };
let viewer: { id: string; token: string };
let tablet: { id: string; token: string };
let tv: { id: string; token: string };
let kid: string;
let items: ApiItem[];

interface Reply<T> {
  status: number;
  body: T;
}

/** A request; `from` "tailnet" comes from an address of the tailnet, which is away. */
async function call<T = Record<string, unknown>>(
  token: string,
  method: string,
  path: string,
  body?: unknown,
  from: "home" | "tailnet" = "home",
): Promise<Reply<T>> {
  const env = {
    incoming: { socket: { remoteAddress: from === "home" ? "127.0.0.1" : "100.101.1.2" } },
  };
  const response = await app.request(
    path,
    {
      method,
      headers: { Authorization: `Bearer ${token}` },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    },
    env,
  );
  const text = await response.text();
  const json = (response.headers.get("Content-Type") ?? "").includes("json") && text !== "";
  return { status: response.status, body: (json ? JSON.parse(text) : null) as T };
}

function pair(name: string, access: "viewer" | "householdAdmin" = "viewer") {
  const waiting = devices.startPairing(name, "ipados");
  devices.approve(waiting.code, access, admin.id);
  const done = devices.collect(waiting.id, waiting.pollSecret);
  if (done.status !== "approved") throw new Error("not paired");
  return { id: done.device.id, token: done.token };
}

const item = (title: string): ApiItem => {
  const found = items.find((one) => one.title === title);
  if (!found) throw new Error(`no ${title}`);
  return found;
};
const asset = (title: string): string => item(title).files[0]?.assetId ?? "";

async function setPlan(plan: Partial<KidsPlan>): Promise<void> {
  const reply = await call(admin.token, "PUT", `/v1/profiles/${kid}/kids/plan`, {
    plan: { music: true, ...plan },
  });
  expect(reply.status, JSON.stringify(reply.body)).toBe(200);
}

const school: PlanBlock = {
  days: [1, 2, 3, 4, 5],
  start: "08:00",
  end: "15:00",
  mode: "nothing",
  label: "School",
};
const bedtime: PlanBlock = {
  days: [1, 2, 3, 4, 5, 6, 7],
  start: "19:30",
  end: "07:00",
  mode: "listening",
  label: "Bedtime",
};

beforeAll(() => {
  files = makeTempDir("lobby-kids-control-files-");
  makeVideo(join(files, "Films/Balloon (2009)/Balloon (2009).mp4"), { seed: 1 });
  makeVideo(join(files, "Films/Garden (2001)/Garden (2001).mp4"), { seed: 2 });
  makeVideo(join(files, "Late/Scary (1999)/Scary (1999).mp4"), { seed: 3 });
  makeAudio(join(files, "Music/Band/Album/1.flac"), {
    tags: { title: "Song", artist: "Band", album: "Album", track: "1" },
  });
}, 60_000);
afterAll(() => {
  removeDir(files);
});

beforeEach(async () => {
  dir = makeTempDir("lobby-kids-control-");
  cpSync(files, dir, { recursive: true });
  clock = { now: TUESDAY_4PM };
  const now = (): number => clock.now;
  db = new Database(join(dir, "lobby.db"));
  db.run("update household set time_zone = ? where id = 'owner'", [ZONE]);
  const catalogue = new Catalogue(db);
  const scanner = new Scanner(db, catalogue, {
    stabilityMs: 0,
    probeConcurrency: 2,
    ffprobePath: "ffprobe",
    volumeOf: () => Promise.resolve(1),
  });
  scanner.syncSources([
    { path: join(dir, "Films"), name: "Films", hint: "movies", group: "Small" },
    { path: join(dir, "Late"), name: "Late", hint: "movies", group: "Grown-ups" },
  ]);
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
  devices = new Devices(db, "secret", now);
  hub = new RemoteHub({ db, devices, now });
  deps = {
    db,
    devices,
    items: new ItemReader(db),
    progress: new ProgressStore(db, now),
    music,
    remote: hub,
    wake: new WakeService({ db, devices, config: () => null }),
    serverName: "Test",
    version: "0",
    isScanning: () => false,
    now,
  };
  app = createApp(deps);
  control = kidsControl(db, devices);
  control.stop();
  const made = devices.createLocalManager("Mac");
  admin = { id: made.device.id, token: made.token };
  viewer = pair("Phone");
  tablet = pair("Tablet");
  tv = pair("TV");
  await scanner.scanAll();
  await scanner.processQueue();
  await music.scanner.scanAll();
  await music.scanner.processQueue();
  items = (await call<{ items: ApiItem[] }>(admin.token, "GET", "/v1/library?limit=1000")).body
    .items;
  const groups = db.all<{ id: string; name: string | null }>("select id, name from category_group");
  const small = groups.find((one) => one.name === "Small")?.id;
  kid = (
    await call<{ id: string }>(admin.token, "POST", "/v1/profiles", {
      name: "Robin",
      kids: {
        allowedGroupIds: [small],
        allowedCategoryIds: [],
        allowedItemIds: [],
        blockedItemIds: [],
        blockedCategoryIds: [],
      },
    })
  ).body.id;
  expect(
    (await call(admin.token, "PATCH", `/v1/devices/${tablet.id}`, { kidsProfileId: kid })).status,
  ).toBe(200);
}, 180_000);

afterEach(async () => {
  hub.stop();
  control.stop();
  await music.stop();
  db.close();
  removeDir(dir);
});

/** What the tablet may reach now: films, playing one, music. */
async function reach(from: "home" | "tailnet" = "home") {
  const [library, play, songs] = await Promise.all([
    call(tablet.token, "GET", "/v1/library", undefined, from),
    call(tablet.token, "GET", `/v1/assets/${asset("Balloon")}/content`, undefined, from),
    call(tablet.token, "GET", "/v1/music/library", undefined, from),
  ]);
  return { library: library.status, play: play.status, music: songs.status };
}

describe("a mode for every route a child uses", () => {
  it("is there, and none is left over", () => {
    const used = Object.entries(KIDS_ROUTES)
      .filter(([, decision]) => decision !== "none" && decision !== "open")
      .map(([key]) => key);
    expect(used.filter((key) => KIDS_MODE_ROUTES[key] === undefined)).toEqual([]);
    expect(Object.keys(KIDS_MODE_ROUTES).filter((key) => !used.includes(key))).toEqual([]);
  });
});

describe("the modes on a child's device", () => {
  it("has no plan: films, and music, which is on unless turned off", async () => {
    expect(await reach()).toEqual({ library: 200, play: 200, music: 200 });
  });

  it("has no plan: Everything at every hour and place, nothing waits and nothing is blocked", async () => {
    const plan = await call<{ plan: { defaultMode: string; blocks: unknown[] } }>(
      admin.token,
      "GET",
      `/v1/profiles/${kid}/kids/plan`,
    );
    expect(plan.status).toBe(200);
    expect(plan.body.plan).toMatchObject({ defaultMode: "everything", blocks: [] });
    // School hours, bedtime, a Sunday night, and away from home: what a block would cover.
    for (const at of ["2026-11-24T09:00:00Z", "2026-11-24T20:00:00Z", "2026-11-29T23:30:00Z"]) {
      clock.now = Date.parse(at);
      for (const from of ["home", "tailnet"] as const) {
        expect(await reach(from), `${at} ${from}`).toEqual({ library: 200, play: 200, music: 200 });
        const me = await call<{ now: Record<string, unknown> }>(
          tablet.token,
          "GET",
          "/v1/me/kids",
          undefined,
          from,
        );
        expect(me.status).toBe(200);
        expect(me.body.now).toMatchObject({ mode: "everything", video: "all", waiting: false });
        for (const path of [
          "/v1/categories",
          "/v1/popular",
          `/v1/items/${item("Balloon").id}`,
          "/v1/search?q=balloon",
        ]) {
          expect((await call(tablet.token, "GET", path, undefined, from)).status, path).toBe(200);
        }
      }
    }
    // Nobody is asked: there is no question to send.
    expect((await call(admin.token, "GET", "/v1/kids/requests")).body).toMatchObject({
      requests: [],
    });
  });

  it("Everything: films and music", async () => {
    await setPlan({ blocks: [school, bedtime] });
    expect(await reach()).toEqual({ library: 200, play: 200, music: 200 });
  });

  it("Only listening: music only, and no music at all without the switch", async () => {
    clock.now = Date.parse("2026-11-24T20:00:00Z"); // 21:00, bedtime
    await setPlan({ blocks: [school, bedtime] });
    expect(await reach()).toEqual({ library: 403, play: 403, music: 200 });
    const refused = await call<{ error: { code: string }; now: { mode: string; until: number } }>(
      tablet.token,
      "GET",
      "/v1/library",
    );
    expect(refused.body.error.code).toBe("kids_mode");
    expect(refused.body.now.mode).toBe("listening");
    expect(refused.body.now.until).toBe(Date.parse("2026-11-25T06:00:00Z"));
    await setPlan({ blocks: [school, bedtime], music: false });
    expect((await reach()).music).toBe(404);
  });

  it("Nothing: only what keeps the app going", async () => {
    clock.now = Date.parse("2026-11-24T09:00:00Z"); // 10:00, school
    await setPlan({ blocks: [school, bedtime] });
    expect(await reach()).toEqual({ library: 403, play: 403, music: 403 });
    for (const [method, path] of [
      ["GET", "/v1/me"],
      ["GET", "/v1/me/kids"],
      ["GET", "/v1/profiles"],
      ["GET", "/v1/household"],
    ] as const) {
      expect((await call(tablet.token, method, path)).status, path).toBe(200);
    }
    for (const path of ["/v1/categories", "/v1/popular", `/v1/items/${item("Balloon").id}`]) {
      expect((await call(tablet.token, "GET", path)).status, path).toBe(403);
    }
    // Turning on a TV is watching too.
    const wake = await call<{ error: { code: string } }>(tablet.token, "POST", "/v1/remote/wake", {
      deviceId: tv.id,
    });
    expect(wake.body.error.code).toBe("kids_mode");
    // Where a film stopped is still saved.
    const saved = await call(
      tablet.token,
      "PUT",
      `/v1/profiles/${kid}/progress/${item("Balloon").id}`,
      {
        opId: "op-1",
        baseRevision: null,
        positionMs: 1000,
        durationMs: 5000,
        completed: false,
        updatedAt: clock.now,
      },
    );
    expect(saved.status).toBe(200);
  });

  it("keeps a title outside the limits out, whatever the mode", async () => {
    await setPlan({ defaultMode: "everything" });
    expect((await call(tablet.token, "GET", `/v1/assets/${asset("Scary")}/content`)).status).toBe(
      404,
    );
  });

  it("follows the clock: the same device is let in once the block ends", async () => {
    clock.now = Date.parse("2026-11-24T13:59:00Z"); // 14:59
    await setPlan({ blocks: [school] });
    expect((await reach()).library).toBe(403);
    clock.now += MINUTE;
    expect((await reach()).library).toBe(200);
  });

  it("applies the away rule to the tailnet", async () => {
    await setPlan({ away: "nothing" });
    expect((await reach("home")).library).toBe(200);
    expect(await reach("tailnet")).toEqual({ library: 403, play: 403, music: 403 });
  });

  it("lets an override win, and end early", async () => {
    clock.now = Date.parse("2026-11-24T09:00:00Z"); // school
    await setPlan({ blocks: [school] });
    const set = await call<{ now: { mode: string; until: number; reason: string } }>(
      admin.token,
      "PUT",
      `/v1/profiles/${kid}/kids/override`,
      { mode: "everything", minutes: 60 },
    );
    expect(set.status).toBe(200);
    expect(set.body.now).toMatchObject({
      mode: "everything",
      reason: "override",
      until: clock.now + 60 * MINUTE,
    });
    expect((await reach()).library).toBe(200);
    expect((await call(admin.token, "DELETE", `/v1/profiles/${kid}/kids/override`)).status).toBe(
      200,
    );
    expect((await reach()).library).toBe(403);
    // "Until the next switch": the end of school.
    const next = await call<{ now: { until: number } }>(
      admin.token,
      "PUT",
      `/v1/profiles/${kid}/kids/override`,
      {
        mode: "listening",
        untilNext: true,
      },
    );
    expect(next.body.now.until).toBe(Date.parse("2026-11-24T14:00:00Z"));
  });
});

describe("places", () => {
  const places = [
    {
      id: "school",
      name: "School",
      latitude: 52.37,
      longitude: 4.89,
      radiusMeters: 300,
      mode: "nothing",
    },
    {
      id: "gran",
      name: "Grandma's",
      latitude: 52.1,
      longitude: 5.1,
      radiusMeters: 200,
      mode: "listening",
    },
  ] as const;

  it("follows the schedule while the device cannot tell, unless asked otherwise", async () => {
    await setPlan({ places: [...places] });
    // Nothing said yet, and nothing chosen for that: the places do not apply.
    expect(await reach()).toEqual({ library: 200, play: 200, music: 200 });
  });

  it("fails closed until the device says, and when it cannot tell, when asked to", async () => {
    await setPlan({ places: [...places], whenPlaceUnknown: "strictest" });
    // Nothing said yet: the strictest place.
    expect((await reach()).library).toBe(403);
    const say = (body: unknown) =>
      call<{ now: { mode: string; detail: string | null } }>(
        tablet.token,
        "PUT",
        "/v1/me/kids/place",
        body,
      );
    expect((await say({ state: "outside" })).body.now.mode).toBe("everything");
    expect(await reach()).toEqual({ library: 200, play: 200, music: 200 });
    expect((await say({ state: "inside", placeId: "gran" })).body.now).toMatchObject({
      mode: "listening",
      detail: "Grandma's",
    });
    expect((await say({ state: "unknown" })).body.now.mode).toBe("nothing");
    // A chosen mode for not knowing.
    await setPlan({ places: [...places], whenPlaceUnknown: "listening" });
    expect((await reach()).music).toBe(200);
    // What was said grows old.
    await say({ state: "outside" });
    clock.now += 7 * 60 * MINUTE;
    expect((await reach()).library).toBe(403);
  });

  it("never takes coordinates", async () => {
    await setPlan({ places: [...places] });
    const sent = await call(tablet.token, "PUT", "/v1/me/kids/place", {
      state: "outside",
      latitude: 52.37,
      longitude: 4.89,
    });
    expect(sent.status).toBe(400);
    // Nothing of where a device is has a place to be kept.
    const kept = JSON.stringify(
      db.all("select name, sql from sqlite_master where name like 'kids_%'"),
    );
    expect(kept).not.toMatch(/latitude|longitude/);
  });
});

describe("screen time", () => {
  const watch = async (seconds: number, positionMs: number) => {
    clock.now += seconds * 1000;
    return call(tablet.token, "PUT", `/v1/profiles/${kid}/progress/${item("Balloon").id}`, {
      opId: `op-${String(positionMs)}`,
      baseRevision: null,
      positionMs,
      durationMs: 3_600_000,
      completed: false,
      updatedAt: clock.now,
    });
  };

  it("counts what plays, not what is skipped, and switches when it runs out", async () => {
    await setPlan({
      screenTime: { weekdayMinutes: 1, weekendMinutes: null, whenOut: "listening" },
    });
    await watch(0, 0);
    await watch(30, 30_000);
    // A seek forward is not watching.
    await watch(10, 600_000);
    expect(
      (
        await call<{ now: { screenTime: { usedSeconds: number } } }>(
          tablet.token,
          "GET",
          "/v1/me/kids",
        )
      ).body.now.screenTime.usedSeconds,
    ).toBe(40);
    expect((await reach()).library).toBe(200);
    await watch(20, 620_000);
    expect(await reach()).toEqual({ library: 403, play: 403, music: 200 });
  });

  it("takes the larger count from a device that was offline", async () => {
    await setPlan({ screenTime: { weekdayMinutes: 10, weekendMinutes: null, whenOut: "nothing" } });
    const day = "2026-11-24";
    expect(
      (await call(tablet.token, "POST", "/v1/me/kids/screen-time", { day, seconds: 700 })).status,
    ).toBe(204);
    expect((await reach()).library).toBe(403);
    await call(tablet.token, "POST", "/v1/me/kids/screen-time", { day, seconds: 10 });
    expect((await reach()).library).toBe(403);
  });
});

describe("Ask first", () => {
  it("asks to open: nothing until a grown-up answers Watch, Listen or No", async () => {
    await setPlan({ defaultMode: "ask" });
    expect(await reach()).toEqual({ library: 403, play: 403, music: 403 });
    const asked = await call<{ request: { id: string; state: string } }>(
      tablet.token,
      "POST",
      "/v1/me/kids/requests",
      { kind: "open" },
    );
    expect(asked.status).toBe(201);
    const { id } = asked.body.request;
    // The same question again is the one that waits.
    expect(
      (await call<{ request: { id: string } }>(tablet.token, "POST", "/v1/me/kids/requests", {}))
        .body.request.id,
    ).toBe(id);
    // The grown-ups see it, with who asks.
    const waiting = await call<{ requests: { id: string; viewer: { name: string } }[] }>(
      admin.token,
      "GET",
      "/v1/kids/requests",
    );
    expect(waiting.body.requests).toMatchObject([{ id, viewer: { name: "Robin" } }]);
    // Watch, with the default length.
    const answered = await call<{ request: { state: string; answer: string } }>(
      admin.token,
      "POST",
      `/v1/kids/requests/${id}/answer`,
      { answer: "watch" },
    );
    expect(answered.body.request).toMatchObject({ state: "allowed", answer: "watch" });
    expect(await reach()).toEqual({ library: 200, play: 200, music: 200 });
    // A second answer is too late.
    expect(
      (await call(admin.token, "POST", `/v1/kids/requests/${id}/answer`, { answer: "no" })).status,
    ).toBe(409);
    // Switched to Listen from the phone.
    expect(
      (await call(admin.token, "PATCH", `/v1/profiles/${kid}/kids/answer`, { answer: "listen" }))
        .status,
    ).toBe(200);
    expect(await reach()).toEqual({ library: 403, play: 403, music: 200 });
    // Ended early: asking again.
    expect((await call(admin.token, "DELETE", `/v1/profiles/${kid}/kids/answer`)).status).toBe(200);
    expect(
      (await call<{ now: { waiting: boolean } }>(tablet.token, "GET", "/v1/me/kids")).body.now
        .waiting,
    ).toBe(true);
    // An answer ends by itself.
    const again = (
      await call<{ request: { id: string } }>(tablet.token, "POST", "/v1/me/kids/requests", {})
    ).body.request.id;
    await call(admin.token, "POST", `/v1/kids/requests/${again}/answer`, {
      answer: "listen",
      minutes: 30,
    });
    expect((await reach()).music).toBe(200);
    clock.now += 30 * MINUTE;
    expect((await reach()).music).toBe(403);
  });

  it("says no, and lets a question expire", async () => {
    await setPlan({ defaultMode: "ask" });
    const ask = async () =>
      (await call<{ request: { id: string } }>(tablet.token, "POST", "/v1/me/kids/requests", {}))
        .body.request.id;
    const first = await ask();
    const no = await call<{ request: { state: string } }>(
      admin.token,
      "POST",
      `/v1/kids/requests/${first}/answer`,
      { answer: "no" },
    );
    expect(no.body.request.state).toBe("declined");
    expect((await reach()).library).toBe(403);
    const second = await ask();
    clock.now += 10 * MINUTE;
    const seen = await call<{ request: { state: string } }>(
      tablet.token,
      "GET",
      `/v1/me/kids/requests/${second}`,
    );
    expect(seen.body.request.state).toBe("expired");
    expect(
      (await call(admin.token, "POST", `/v1/kids/requests/${second}/answer`, { answer: "watch" }))
        .status,
    ).toBe(409);
  });

  it("is rate-limited", async () => {
    await setPlan({ defaultMode: "ask" });
    for (let n = 0; n < REQUESTS_PER_HOUR; n += 1) {
      const id = (
        await call<{ request: { id: string } }>(tablet.token, "POST", "/v1/me/kids/requests", {})
      ).body.request.id;
      await call(tablet.token, "DELETE", `/v1/me/kids/requests/${id}`);
    }
    const refused = await call(tablet.token, "POST", "/v1/me/kids/requests", {});
    expect(refused.status).toBe(429);
    clock.now += 61 * MINUTE;
    expect((await call(tablet.token, "POST", "/v1/me/kids/requests", {})).status).toBe(201);
  });

  it("asks per title, and never for a title outside the limits", async () => {
    await setPlan({ defaultMode: "ask", askStyle: "title" });
    expect(await reach()).toEqual({ library: 200, play: 403, music: 200 });
    const outside = await call(tablet.token, "POST", "/v1/me/kids/requests", {
      kind: "title",
      itemId: item("Scary").id,
    });
    expect(outside.status).toBe(404);
    const asked = await call<{ request: { id: string } }>(
      tablet.token,
      "POST",
      "/v1/me/kids/requests",
      { kind: "title", itemId: item("Balloon").id },
    );
    await call(admin.token, "POST", `/v1/kids/requests/${asked.body.request.id}/answer`, {
      answer: "watch",
    });
    expect((await call(tablet.token, "GET", `/v1/assets/${asset("Balloon")}/content`)).status).toBe(
      200,
    );
    expect((await call(tablet.token, "GET", `/v1/assets/${asset("Garden")}/content`)).status).toBe(
      403,
    );
  });

  it("is answered only by the child's household's admins", async () => {
    await setPlan({ defaultMode: "ask" });
    const id = (
      await call<{ request: { id: string } }>(tablet.token, "POST", "/v1/me/kids/requests", {})
    ).body.request.id;
    // A viewer's device may not.
    expect(
      (await call(viewer.token, "POST", `/v1/kids/requests/${id}/answer`, { answer: "watch" }))
        .status,
    ).toBe(403);
    expect(
      (await call(viewer.token, "PUT", `/v1/profiles/${kid}/kids/plan`, { plan: {} })).status,
    ).toBe(403);
    // The child's own device may not.
    expect(
      (await call(tablet.token, "POST", `/v1/kids/requests/${id}/answer`, { answer: "watch" }))
        .status,
    ).toBe(404);
    expect(
      (await call(tablet.token, "PUT", `/v1/profiles/${kid}/kids/override`, { mode: "everything" }))
        .status,
    ).toBe(404);
    // Another household's admin does not even see the child.
    const households = new Households(
      db,
      devices,
      invitesOf(db, () => clock.now),
      () => clock.now,
    );
    const guest = households.create("Neighbours", { requiresAdminApproval: false });
    const neighbour = pair("Neighbour", "householdAdmin");
    db.run("update device set household_id = ?, access = 'household_admin' where id = ?", [
      guest.id,
      neighbour.id,
    ]);
    expect(
      (await call(neighbour.token, "POST", `/v1/kids/requests/${id}/answer`, { answer: "watch" }))
        .status,
    ).toBe(404);
    expect((await call(neighbour.token, "GET", `/v1/profiles/${kid}/kids/plan`)).status).toBe(404);
    expect(
      (await call<{ requests: unknown[] }>(neighbour.token, "GET", "/v1/kids/requests")).body
        .requests,
    ).toEqual([]);
    // A grown-up's device cannot be bound to the child; and one that somehow is, whatever access
    // it has, speaks for the child and may not answer, not even No.
    const handedOver = pair("Old phone", "householdAdmin");
    expect(
      (await call(admin.token, "PATCH", `/v1/devices/${handedOver.id}`, { kidsProfileId: kid }))
        .status,
    ).toBe(409);
    db.run("update device set kids_profile_id = ? where id = ?", [kid, handedOver.id]);
    expect(
      (await call(handedOver.token, "POST", `/v1/kids/requests/${id}/answer`, { answer: "watch" }))
        .status,
    ).toBe(404);
    expect(
      (await call(handedOver.token, "POST", `/v1/kids/requests/${id}/answer`, { answer: "no" }))
        .status,
    ).toBe(404);
    // A household admin of the child's own household may.
    const mum = pair("Mum's phone", "householdAdmin");
    expect(
      (await call(mum.token, "POST", `/v1/kids/requests/${id}/answer`, { answer: "watch" })).status,
    ).toBe(200);
  });

  it("asks only the chosen grown-ups when some are chosen", async () => {
    const mum = pair("Mum's phone", "householdAdmin");
    await setPlan({ defaultMode: "ask", askDevices: [mum.id] });
    const id = (
      await call<{ request: { id: string } }>(tablet.token, "POST", "/v1/me/kids/requests", {})
    ).body.request.id;
    expect(
      (await call<{ requests: unknown[] }>(admin.token, "GET", "/v1/kids/requests")).body.requests,
    ).toEqual([]);
    expect(
      (await call(admin.token, "POST", `/v1/kids/requests/${id}/answer`, { answer: "watch" }))
        .status,
    ).toBe(404);
    expect(
      (await call(mum.token, "POST", `/v1/kids/requests/${id}/answer`, { answer: "watch" })).status,
    ).toBe(200);
  });

  it("answers Watch only until the plan gets stricter", async () => {
    clock.now = Date.parse("2026-11-24T18:00:00Z"); // 19:00
    await setPlan({ defaultMode: "ask", blocks: [bedtime] });
    const id = (
      await call<{ request: { id: string } }>(tablet.token, "POST", "/v1/me/kids/requests", {})
    ).body.request.id;
    await call(admin.token, "POST", `/v1/kids/requests/${id}/answer`, {
      answer: "watch",
      minutes: 120,
    });
    const now = (
      await call<{ now: { video: string; until: number; next: { mode: string } } }>(
        tablet.token,
        "GET",
        "/v1/me/kids",
      )
    ).body.now;
    expect(now).toMatchObject({
      video: "all",
      until: Date.parse("2026-11-24T18:30:00Z"),
      next: { mode: "listening" },
    });
  });
});

describe("the grown-ups' answers", () => {
  const ask = async () =>
    (await call<{ request: { id: string } }>(tablet.token, "POST", "/v1/me/kids/requests", {})).body
      .request.id;

  it("answers until the next switch when that is today, else for an hour", async () => {
    await setPlan({ defaultMode: "ask", blocks: [bedtime] });
    const id = await ask();
    const answered = await call<{ request: { grant: { until: number; mode: string } } }>(
      admin.token,
      "POST",
      `/v1/kids/requests/${id}/answer`,
      { answer: "watch" },
    );
    // 16:00 now; bedtime at 19:30 today.
    expect(answered.body.request.grant).toMatchObject({
      mode: "everything",
      until: Date.parse("2026-11-24T18:30:00Z"),
    });
    await call(admin.token, "DELETE", `/v1/profiles/${kid}/kids/answer`);
    // Late in the evening the next switch is tomorrow: an hour.
    clock.now = Date.parse("2026-11-24T22:00:00Z"); // 23:00, bedtime, but asking is not
    await setPlan({ defaultMode: "ask" });
    const late = await ask();
    const hour = await call<{ request: { grant: { until: number } } }>(
      admin.token,
      "POST",
      `/v1/kids/requests/${late}/answer`,
      { answer: "listen" },
    );
    expect(hour.body.request.grant.until).toBe(clock.now + 60 * MINUTE);
  });

  it("names who is asked, and who answered, to the others at once", async () => {
    const mum = pair("Mum's phone", "householdAdmin");
    const mother = (
      await call<{ id: string }>(admin.token, "POST", "/v1/profiles", { name: "Mum" })
    ).body.id;
    await call(admin.token, "POST", "/v1/profiles", { name: "Dad" });
    await setPlan({ defaultMode: "ask" });
    expect(
      (await call<{ askNames: string[] }>(tablet.token, "GET", "/v1/me/kids")).body.askNames,
    ).toEqual(["Mum", "Dad"]);
    await setPlan({
      defaultMode: "ask",
      askers: [{ profileId: mother, deviceIds: [mum.id, admin.id] }],
    });
    expect(
      (await call<{ askNames: string[] }>(tablet.token, "GET", "/v1/me/kids")).body.askNames,
    ).toEqual(["Mum"]);
    const plan = await call<{ grownUps: { name: string }[]; adminDevices: { id: string }[] }>(
      admin.token,
      "GET",
      `/v1/profiles/${kid}/kids/plan`,
    );
    expect(plan.body.grownUps.map((one) => one.name)).toEqual(["Mum", "Dad"]);
    expect(plan.body.adminDevices.map((one) => one.id).sort()).toEqual([admin.id, mum.id].sort());
    const id = await ask();
    const answered = await call<{ request: { answeredByName: string } }>(
      mum.token,
      "POST",
      `/v1/kids/requests/${id}/answer`,
      { answer: "watch", minutes: 60 },
    );
    expect(answered.body.request.answeredByName).toBe("Mum");
    // The other grown-up's sheet hears it was answered, and by whom.
    expect(
      (await call(admin.token, "POST", `/v1/kids/requests/${id}/answer`, { answer: "no" })).status,
    ).toBe(409);
  });

  it("lets the server's admins answer for a guest household's child too", async () => {
    const households = new Households(
      db,
      devices,
      invitesOf(db, () => clock.now),
      () => clock.now,
    );
    const guest = households.create("Neighbours", { requiresAdminApproval: false });
    const neighbour = pair("Neighbour", "householdAdmin");
    const theirTablet = pair("Their tablet");
    db.run("update device set household_id = ? where id in (?, ?)", [
      guest.id,
      neighbour.id,
      theirTablet.id,
    ]);
    db.run("update device set access = 'household_admin' where id = ?", [neighbour.id]);
    const theirKid = (
      await call<{ id: string }>(neighbour.token, "POST", "/v1/profiles", {
        name: "Noor",
        kids: {
          allowedGroupIds: [],
          allowedCategoryIds: [],
          allowedItemIds: [],
          blockedItemIds: [],
        },
      })
    ).body.id;
    await call(neighbour.token, "PATCH", `/v1/devices/${theirTablet.id}`, {
      kidsProfileId: theirKid,
    });
    expect(
      (
        await call(neighbour.token, "PUT", `/v1/profiles/${theirKid}/kids/plan`, {
          plan: { defaultMode: "ask" },
        })
      ).status,
    ).toBe(200);
    const id = (
      await call<{ request: { id: string } }>(theirTablet.token, "POST", "/v1/me/kids/requests", {})
    ).body.request.id;
    // Both see it; the server admin answers; a server admin may step in too.
    expect(
      (
        await call<{ requests: { id: string }[] }>(neighbour.token, "GET", "/v1/kids/requests")
      ).body.requests.map((one) => one.id),
    ).toEqual([id]);
    expect(
      (
        await call<{ requests: { id: string }[] }>(admin.token, "GET", "/v1/kids/requests")
      ).body.requests.map((one) => one.id),
    ).toContain(id);
    expect(
      (
        await call(admin.token, "POST", `/v1/kids/requests/${id}/answer`, {
          answer: "listen",
          minutes: 30,
        })
      ).status,
    ).toBe(200);
    expect(
      (
        await call(admin.token, "PUT", `/v1/profiles/${theirKid}/kids/override`, {
          mode: "nothing",
          minutes: 30,
        })
      ).status,
    ).toBe(200);
    // The guest's admin still cannot see the owner's child.
    expect((await call(neighbour.token, "GET", `/v1/profiles/${kid}/kids/plan`)).status).toBe(404);
  });

  it("opens answering and stepping in from outside, and nothing else of deciding", () => {
    for (const key of [
      "GET /v1/kids/requests",
      "POST /v1/kids/requests/:id/answer",
      "PUT /v1/profiles/:id/kids/override",
      "DELETE /v1/profiles/:id/kids/override",
      "PATCH /v1/profiles/:id/kids/answer",
      "DELETE /v1/profiles/:id/kids/answer",
    ]) {
      expect(OUTSIDE_ROUTES[key], key).toBe("kids");
    }
    expect(OUTSIDE_ROUTES["PUT /v1/profiles/:id/kids/plan"]).toBe("household");
  });

  it("plays only the music libraries chosen for the child", async () => {
    const source = db.get<{ id: string }>("select id from music_source")?.id ?? "";
    const track = db.get<{ id: string }>("select id from music_track")?.id ?? "";
    await setPlan({ musicSourceIds: [source] });
    expect((await call(tablet.token, "GET", `/v1/music/tracks/${track}/content`)).status).toBe(200);
    await setPlan({ musicSourceIds: [] });
    expect((await call(tablet.token, "GET", `/v1/music/tracks/${track}/content`)).status).toBe(404);
    const libraries = await call<{ musicLibraries: { id: string }[] }>(
      tablet.token,
      "GET",
      "/v1/me/kids",
    );
    expect(libraries.body.musicLibraries.map((one) => one.id)).toEqual([source]);
  });
});

describe("Lock to Lobby", () => {
  interface Wish {
    wanted: boolean;
    source: string;
  }
  interface LockDevice extends Wish {
    deviceId: string;
    name: string;
    choice: boolean | null;
    status: string | null;
    locked: boolean;
  }
  const wish = async (token = tablet.token, profileId?: string): Promise<Wish> =>
    (
      await call<{ lock: Wish }>(
        token,
        "GET",
        `/v1/me/kids${profileId === undefined ? "" : `?profileId=${profileId}`}`,
      )
    ).body.lock;
  const lockDevices = async (token = admin.token): Promise<LockDevice[]> =>
    (await call<{ lockDevices: LockDevice[] }>(token, "GET", `/v1/profiles/${kid}/kids/plan`)).body
      .lockDevices;
  const switchLock = (deviceId: string, lock: unknown, token = admin.token) =>
    call(token, "PUT", `/v1/profiles/${kid}/kids/lock/${deviceId}`, { lock });

  it("is off until a grown-up turns it on for the child, and a device can differ", async () => {
    expect(await wish()).toEqual({ wanted: false, source: "viewer" });
    await setPlan({ lockToLobby: true });
    expect(await wish()).toEqual({ wanted: true, source: "viewer" });
    // The device it is bound to is there for the grown-ups before it said anything.
    expect(await lockDevices()).toEqual([
      expect.objectContaining({
        deviceId: tablet.id,
        name: "Tablet",
        wanted: true,
        source: "viewer",
        choice: null,
        status: null,
        locked: false,
      }),
    ]);
    // Off for this device alone, then back to what the plan says.
    expect((await switchLock(tablet.id, false)).status).toBe(200);
    expect(await wish()).toEqual({ wanted: false, source: "device" });
    expect((await lockDevices())[0]).toMatchObject({ wanted: false, choice: false });
    await setPlan({ lockToLobby: false });
    expect((await switchLock(tablet.id, true)).status).toBe(200);
    expect(await wish()).toEqual({ wanted: true, source: "device" });
    expect((await switchLock(tablet.id, null)).status).toBe(200);
    expect(await wish()).toEqual({ wanted: false, source: "viewer" });
    // Only true or false.
    expect(
      (
        await call(admin.token, "PUT", `/v1/profiles/${kid}/kids/plan`, {
          plan: { lockToLobby: "yes" },
        })
      ).status,
    ).toBe(400);
    expect((await switchLock(tablet.id, "yes")).status).toBe(400);
  });

  it("is in the signed copy, so that it holds offline", async () => {
    await setPlan({ lockToLobby: true });
    const reply = await call<{ signed: { payload: string } }>(tablet.token, "GET", "/v1/me/kids");
    const copy = JSON.parse(
      Buffer.from(reply.body.signed.payload, "base64url").toString("utf8"),
    ) as {
      lock: boolean;
      plan: KidsPlan;
    };
    expect(copy.lock).toBe(true);
    expect(copy.plan.lockToLobby).toBe(true);
  });

  it("shows the grown-ups what the device said: not set up, locked, or no iPad", async () => {
    await setPlan({ lockToLobby: true });
    const told = await call<{ lock: Wish }>(tablet.token, "PUT", "/v1/me/kids/lock", {
      status: "notSetUp",
      locked: false,
    });
    expect(told.status).toBe(200);
    expect(told.body.lock).toEqual({ wanted: true, source: "viewer" });
    expect((await lockDevices())[0]).toMatchObject({ status: "notSetUp", locked: false });
    await call(tablet.token, "PUT", "/v1/me/kids/lock", { status: "ready", locked: true });
    expect((await lockDevices())[0]).toMatchObject({ status: "ready", locked: true });
    // What it says is checked.
    for (const body of [
      { status: "broken", locked: true },
      { status: "ready" },
      { status: "ready", locked: "no" },
    ]) {
      expect((await call(tablet.token, "PUT", "/v1/me/kids/lock", body)).status).toBe(400);
    }
    // Kept over a restart of the server: it is in the catalogue, not in memory.
    const stored = db.get<{ status: string }>("select status from kids_lock where device_id = ?", [
      tablet.id,
    ]);
    expect(stored?.status).toBe("ready");
  });

  it("lists a grown-up's device in kids mode once it said something for the child", async () => {
    await setPlan({ lockToLobby: true });
    // Not the child's device: nothing to switch.
    expect((await switchLock(viewer.id, true)).status).toBe(404);
    expect((await switchLock("no-such-device", true)).status).toBe(404);
    // The phone shows the kids screens for the child and says how its lock is.
    expect(await wish(viewer.token, kid)).toEqual({ wanted: true, source: "viewer" });
    expect(
      (
        await call(viewer.token, "PUT", "/v1/me/kids/lock", {
          profileId: kid,
          status: "ready",
          locked: true,
        })
      ).status,
    ).toBe(200);
    expect((await lockDevices()).map((one) => one.deviceId).sort()).toEqual(
      [tablet.id, viewer.id].sort(),
    );
    expect((await switchLock(viewer.id, false)).status).toBe(200);
    expect(await wish(viewer.token, kid)).toEqual({ wanted: false, source: "device" });
    // The bound tablet still follows the plan.
    expect(await wish()).toEqual({ wanted: true, source: "viewer" });
    // A device that is removed is not listed any more.
    devices.revoke(viewer.id);
    expect((await lockDevices()).map((one) => one.deviceId)).toEqual([tablet.id]);
  });

  it("is switched only by the child's household's admins, also from outside", async () => {
    // A viewer's device may read the plan, not switch the lock.
    expect((await switchLock(tablet.id, true, viewer.token)).status).toBe(403);
    // The child's own device does not even see the route.
    expect((await switchLock(tablet.id, false, tablet.token)).status).toBe(404);
    // Another household's admin does not see the child.
    const households = new Households(
      db,
      devices,
      invitesOf(db, () => clock.now),
      () => clock.now,
    );
    const guest = households.create("Neighbours", { requiresAdminApproval: false });
    const neighbour = pair("Neighbour", "householdAdmin");
    db.run("update device set household_id = ?, access = 'household_admin' where id = ?", [
      guest.id,
      neighbour.id,
    ]);
    expect((await switchLock(tablet.id, true, neighbour.token)).status).toBe(404);
    // A household admin of the child's household may.
    const mum = pair("Mum's phone", "householdAdmin");
    expect((await switchLock(tablet.id, true, mum.token)).status).toBe(200);
    expect(await wish()).toEqual({ wanted: true, source: "device" });
    // The tables say so too: a household admin's, of a kids viewer of the household, from anywhere.
    const key = "PUT /v1/profiles/:id/kids/lock/:deviceId";
    expect(HOUSEHOLD_LEVELS[key]).toBe("householdAdmin");
    expect(HOUSEHOLD_ROUTES[key]).toBe("kids_profile");
    expect(OUTSIDE_ROUTES[key]).toBe("kids");
    expect(KIDS_ROUTES[key]).toBe("none");
    expect(KIDS_MODE_ROUTES["PUT /v1/me/kids/lock"]).toBe("always");
  });

  it("is told in every mode, Nothing too", async () => {
    await setPlan({ defaultMode: "nothing", lockToLobby: true });
    expect((await call(tablet.token, "GET", "/v1/me/kids")).status).toBe(200);
    expect(
      (await call(tablet.token, "PUT", "/v1/me/kids/lock", { status: "ready", locked: true }))
        .status,
    ).toBe(200);
  });
});

describe("the live channel and Play On", () => {
  /** The events a session is sent, as they come. */
  function listen(deviceId: string, session: string) {
    const events: { event: string; data: Record<string, unknown> }[] = [];
    const reader = hub.open(deviceId, session, false, null).getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    const pump = async (): Promise<void> => {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) return;
        buffer += decoder.decode(value);
        let end = buffer.indexOf("\n\n");
        while (end !== -1) {
          const block = buffer.slice(0, end);
          buffer = buffer.slice(end + 2);
          const event = /event: (.*)/.exec(block)?.[1] ?? "";
          const data = /data: (.*)/.exec(block)?.[1] ?? "{}";
          events.push({ event, data: JSON.parse(data) as Record<string, unknown> });
          end = buffer.indexOf("\n\n");
        }
      }
    };
    void pump();
    return events;
  }
  const settle = () => new Promise((done) => setTimeout(done, 20));

  it("tells the child's device at a switch, so it ends the film", async () => {
    clock.now = Date.parse("2026-11-24T18:25:00Z"); // 19:25
    await setPlan({ blocks: [bedtime] });
    const events = listen(tablet.id, "tablet-1");
    await settle();
    const first = events.filter((one) => one.event === "kidsMode").at(-1);
    expect(first?.data["now"]).toMatchObject({ mode: "everything", video: "all" });
    clock.now += 5 * MINUTE;
    control.tick();
    await settle();
    const after = events.filter((one) => one.event === "kidsMode").at(-1);
    expect(after?.data["now"]).toMatchObject({ mode: "listening", video: "none", listening: true });
  });

  it("tells the child's device when its lock is switched, and a device that was away when it is back", async () => {
    const events = listen(tablet.id, "tablet-1");
    await settle();
    expect(events.filter((one) => one.event === "kidsMode").at(-1)?.data["lock"]).toBe(false);
    // From a parent's phone: the tablet hears it at once.
    await call(admin.token, "PUT", `/v1/profiles/${kid}/kids/lock/${tablet.id}`, { lock: true });
    await settle();
    expect(events.filter((one) => one.event === "kidsMode").at(-1)?.data["lock"]).toBe(true);
    // Switched while the tablet's app was not running: what it opens next says so at once.
    await call(admin.token, "PUT", `/v1/profiles/${kid}/kids/lock/${tablet.id}`, { lock: false });
    const again = listen(tablet.id, "tablet-2");
    await settle();
    expect(again.filter((one) => one.event === "kidsMode").at(-1)?.data["lock"]).toBe(false);
  });

  it("tells the grown-ups of a question at once", async () => {
    await setPlan({ defaultMode: "ask" });
    const events = listen(admin.id, "mac-1");
    await settle();
    await call(tablet.token, "POST", "/v1/me/kids/requests", {});
    await settle();
    expect(events.find((one) => one.event === "kidsRequest")?.data["request"]).toMatchObject({
      viewer: { name: "Robin" },
      kind: "open",
    });
  });

  it("refuses Play On for a child where it may not watch, and lets it stop", async () => {
    let order = 0;
    const announce = (deviceId: string, session: string, player: Player | null = null) =>
      hub.announce(deviceId, session, false, {
        order: (order += 1),
        foreground: true,
        canPlay: true,
        profileId: null,
        capabilities: ["play", "stop", "pause"],
        player,
      });
    const both = () => {
      announce(tv.id, "tv-1");
      announce(tablet.id, "tablet-1");
    };
    clock.now = Date.parse("2026-11-24T20:00:00Z"); // bedtime
    await setPlan({ blocks: [bedtime] });
    devices.setRemote(tv.id, { isTarget: true });
    listen(tv.id, "tv-1");
    listen(tablet.id, "tablet-1");
    await settle();
    both();
    const play = (id: string) =>
      hub.command(tablet.id, false, {
        id,
        session: "tablet-1",
        deviceId: tv.id,
        command: {
          type: "play",
          itemId: item("Balloon").id,
          assetId: null,
          profileId: kid,
          startMs: 0,
          paused: false,
          rate: 1,
          audioTrackId: null,
          subtitleTrackId: "off",
          queue: [],
        },
      });
    expect(() => play("c1")).toThrow(/cannot be played now/);
    clock.now = Date.parse("2026-11-25T15:00:00Z"); // Wednesday 16:00
    both();
    expect(play("c2").id).toBe("c2");
  });
});

describe("the signed plan for offline", () => {
  it("is signed by a key the device can pin, and holds for a week", async () => {
    await setPlan({ blocks: [school, bedtime] });
    const reply = await call<{
      signed: { payload: string; signature: string };
      publicKey: string;
    }>(tablet.token, "GET", "/v1/me/kids");
    const { payload, signature } = reply.body.signed;
    const key = createPublicKey({
      key: { kty: "OKP", crv: "Ed25519", x: reply.body.publicKey },
      format: "jwk",
    });
    const bytes = Buffer.from(payload, "base64url");
    expect(verify(null, bytes, key, Buffer.from(signature, "base64url"))).toBe(true);
    const plan = JSON.parse(bytes.toString("utf8")) as {
      profileId: string;
      issuedAt: number;
      validUntil: number;
      timeZone: string;
      plan: KidsPlan;
    };
    expect(plan).toMatchObject({ profileId: kid, issuedAt: clock.now, timeZone: ZONE });
    expect(plan.validUntil - plan.issuedAt).toBe(7 * 24 * 60 * MINUTE);
    expect(plan.plan.blocks).toHaveLength(2);
    // The same key next time.
    const again = await call<{ publicKey: string }>(tablet.token, "GET", "/v1/me/kids");
    expect(again.body.publicKey).toBe(reply.body.publicKey);
  });
});

describe("A child's question reaches the grown-ups' phones", () => {
  it("registers a token, then pushes the question to it through Apple (direct mode)", async () => {
    const paths: string[] = [];
    const bodies: Record<string, unknown>[] = [];
    const apple = createServer((request, response) => {
      let text = "";
      request.on("data", (part: Buffer) => (text += part.toString()));
      request.on("end", () => {
        paths.push(String(request.headers[":path"]));
        bodies.push(JSON.parse(text) as Record<string, unknown>);
        response.writeHead(200);
        response.end();
      });
    });
    await new Promise<void>((done) => apple.listen(0, "127.0.0.1", done));
    try {
      const host = `http://127.0.0.1:${String((apple.address() as AddressInfo).port)}`;
      const keyFile = join(dir, "AuthKey_ABCDE12345.p8");
      writeFileSync(
        keyFile,
        generateKeyPairSync("ec", { namedCurve: "P-256" }).privateKey.export({
          type: "pkcs8",
          format: "pem",
        }),
      );
      chmodSync(keyFile, 0o600);
      const push = new PushService({
        db,
        config: { keyFile, keyId: "ABCDE12345", teamId: "FGHIJ67890", topic: "mt.sil.lobby" },
        hosts: { development: host, production: host },
      });
      // The question's events read the push service of the dependencies (the first app's, which
      // is the one that listens); the routes take it when an app is made.
      deps.push = push;
      app = createApp(deps);
      expect((await call(admin.token, "GET", "/v1/me/push")).body).toEqual({ mode: "direct" });
      const token = "c".repeat(64);
      expect(
        (await call(admin.token, "PUT", "/v1/me/push", { token, environment: "development" }))
          .status,
      ).toBe(204);
      expect(db.all("select token, environment from push_token")).toEqual([
        { token, environment: "development" },
      ]);

      await setPlan({ defaultMode: "ask" });
      const asked = await call(tablet.token, "POST", "/v1/me/kids/requests", { kind: "open" });
      expect(asked.status).toBe(201);
      // Sent in the background: waited for.
      for (let turn = 0; turn < 100 && paths.length === 0; turn += 1) {
        await new Promise((done) => setTimeout(done, 20));
      }
      expect(paths).toEqual([`/3/device/${token}`]);
      expect(bodies[0]).toMatchObject({
        aps: { category: "LOBBY_KIDS_QUESTION", "thread-id": `kids-${kid}` },
        lobby: { kind: "kidsRequest" },
      });
    } finally {
      await new Promise((done) => apple.close(done));
    }
  }, 30_000);
});
