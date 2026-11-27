// SPDX-License-Identifier: MPL-2.0
import { mkdirSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { serve, type ServerType } from "@hono/node-server";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { Access, Device } from "../src/auth/devices.ts";
import { loadConfig } from "../src/config.ts";
import { createApp } from "../src/http/app.ts";
import { HOUSEHOLD_LEVELS, HOUSEHOLD_ROUTES } from "../src/households/guard.ts";
import { OWNER_HOUSEHOLD } from "../src/households/owner.ts";
import type { KidsSettings } from "../src/kids/limits.ts";
import { WakeHelper } from "../src/remote/wake-helper.ts";
import { startServer } from "../src/server.ts";
import { LiveClient } from "./support/live.ts";
import { makeTempDir, makeVideo, removeDir } from "./support/media.ts";
import { OutsideFixture, until } from "./support/outside.ts";

interface Paired {
  id: string;
  token: string;
}
interface Guest {
  id: string;
  manager: Paired;
}
interface HouseholdReply {
  id: string;
  name: string;
  owner: boolean;
  scope: KidsSettings | null;
  maxMbps: number | null;
  allowOutside: boolean;
  maxDevices: number | null;
  paused: boolean;
  devices: number;
  managers: number;
  viewers: number;
}
interface InviteReply {
  household: HouseholdReply;
  invite: { id: string; code: string; link: string | null; expiresAt: number };
}

const nothing: KidsSettings = {
  allowedGroupIds: [],
  allowedCategoryIds: [],
  allowedItemIds: [],
  blockedItemIds: [],
  blockedCategoryIds: [],
};

let f: OutsideFixture;
let port = 0;
let server: ServerType;
let ownerViewer: Paired;
let ownerProfile: string;
const ids: Record<string, string> = {};
const assets: Record<string, string> = {};
const live: LiveClient[] = [];

const home = (
  who: Paired,
  method: string,
  path: string,
  body?: unknown,
): Promise<{ status: number; json: <T>() => T }> => f.atHome(who.token, method, path, body);

const out = (
  who: Paired,
  method: string,
  path: string,
  body?: unknown,
): ReturnType<OutsideFixture["ask"]> =>
  f.ask(method, path, { token: who.token, ...(body === undefined ? {} : { body }) });

const owner = (): Paired => f.manager;

let addresses = 0;
/** Pairing asks from an address of its own each time: wrong codes are counted per address. */
const pairing = (path: string, body: unknown): ReturnType<OutsideFixture["ask"]> => {
  addresses += 1;
  f.transport.address = `198.51.100.${String(addresses % 250)}`;
  return f.ask("POST", path, { body });
};

async function invite(name: string, more: Record<string, unknown> = {}): Promise<InviteReply> {
  const reply = await home(owner(), "POST", "/v1/households", { name, ...more });
  expect(reply.status).toBe(201);
  return reply.json<InviteReply>();
}

/** A device outside presents a code, a manager compares the digits, and it collects. */
async function come(
  code: string,
  deviceName: string,
  approve: (id: string, comparison: string) => Promise<number>,
  platform = "ios",
): Promise<Paired> {
  const asked = await pairing("/v1/outside-pairing", { code, deviceName, platform });
  expect(asked.status).toBe(201);
  const { id, pollSecret, comparison } = asked.json<{
    id: string;
    pollSecret: string;
    comparison: string;
  }>();
  const pending = await pairing("/v1/outside-pairing/collect", { id, pollSecret });
  expect(pending.status).toBe(202);
  expect(await approve(id, comparison)).toBe(200);
  const done = await pairing("/v1/outside-pairing/collect", { id, pollSecret });
  expect(done.status).toBe(200);
  const { device, token } = done.json<{ device: Device; token: string }>();
  return { id: device.id, token };
}

const byOwner = async (id: string, comparison: string): Promise<number> =>
  (await home(owner(), "POST", `/v1/outside/pairing/${id}/approve`, { comparison })).status;

/** A guest household with its first device, which manages it. */
async function guest(name: string, more: Record<string, unknown> = {}): Promise<Guest> {
  // Its own admin lets its devices in alone, unless a test says otherwise.
  const made = await invite(name, { requiresAdminApproval: false, ...more });
  const manager = await come(made.invite.code, `${name} phone`, byOwner);
  return { id: made.household.id, manager };
}

/** Another device of a guest household, let in by its manager from outside. */
async function another(of: Guest, name: string, platform = "tvos"): Promise<Paired> {
  const window = await out(of.manager, "POST", "/v1/outside/window", { minutes: 5 });
  expect(window.status).toBe(201);
  const { code } = window.json<{ code: string }>();
  return come(
    code,
    name,
    async (id, comparison) =>
      (await out(of.manager, "POST", `/v1/outside/pairing/${id}/approve`, { comparison })).status,
    platform,
  );
}

async function profile(who: Paired, body: unknown, outside = true): Promise<string> {
  const reply = outside
    ? await out(who, "POST", "/v1/profiles", body)
    : await home(who, "POST", "/v1/profiles", body);
  expect(reply.status).toBe(201);
  return reply.json<{ id: string }>().id;
}

async function titles(who: Paired): Promise<string[]> {
  const reply = await out(who, "GET", "/v1/library?limit=1000");
  expect(reply.status).toBe(200);
  return reply
    .json<{ items: { title: string; parentId: string | null }[] }>()
    .items.filter((one) => one.parentId === null)
    .map((one) => one.title)
    .sort();
}

async function groupId(name: string | null): Promise<string> {
  const reply = await home(owner(), "GET", "/v1/categories/edit");
  const found = reply
    .json<{ groups: { id: string; name: string | null }[] }>()
    .groups.find((one) => one.name === name);
  if (!found) throw new Error(`no group ${name ?? "main"}`);
  return found.id;
}

beforeAll(async () => {
  f = new OutsideFixture();
  await f.start();
  for (const folder of ["Small", "Late"]) mkdirSync(join(f.dir, folder));
  f.scanner.syncSources([
    { path: join(f.dir, "Films"), name: "Films", hint: "movies" },
    { path: join(f.dir, "Small"), name: "Small", hint: "movies", group: "Small" },
    { path: join(f.dir, "Late"), name: "Late", hint: "movies", group: "Grown-ups" },
  ]);
  makeVideo(join(f.dir, "Films", "Garden (2001).mp4"), { seed: 1, seconds: 3 });
  makeVideo(join(f.dir, "Small", "Balloon (2002).mp4"), { seed: 2 });
  makeVideo(join(f.dir, "Late", "Scary (2003).mp4"), { seed: 3 });
  await f.scan();
  for (const item of f.items) {
    ids[item.title] = item.id;
    assets[item.title] = item.files[0]?.assetId ?? "";
  }
  ownerProfile = await profile(owner(), { name: "Owner's one" }, false);
  ownerViewer = f.pair("Owner's TV", true);
  await new Promise<void>((done) => {
    server = serve({ fetch: f.home.fetch, hostname: "127.0.0.1", port: 0 }, (info) => {
      port = info.port;
      done();
    });
  });
}, 120_000);

afterAll(async () => {
  for (const one of live) one.cut();
  await new Promise((done) => {
    server.close(done);
    if ("closeAllConnections" in server) server.closeAllConnections();
  });
  await f.stop();
});

describe("a decision for every route", () => {
  it("is there for every route of the whole server, and none is left over", async () => {
    const dir = makeTempDir("lobby-households-routes-");
    const state = join(dir, "wake");
    mkdirSync(state);
    writeFileSync(join(state, "tvs.json"), JSON.stringify({ televisions: [] }));
    const config = join(dir, "lobby.config.json");
    writeFileSync(
      config,
      JSON.stringify({
        host: "127.0.0.1",
        port: 0,
        stabilityMs: 0,
        advertise: false,
        remote: { wake: { pyatv: "/nowhere/bin" } },
      }),
    );
    const fake = fileURLToPath(new URL("./support/fake-wake.ts", import.meta.url));
    const running = await startServer(loadConfig(config), {
      wakeHelper: () =>
        new WakeHelper({
          python: process.execPath,
          flags: [],
          script: fake,
          args: ["--state", state],
        }),
    });
    try {
      const registered = new Set(
        running.app.routes
          .filter((route) => route.method !== "ALL")
          .map((route) => `${route.method === "HEAD" ? "GET" : route.method} ${route.path}`),
      );
      expect([...registered].filter((key) => HOUSEHOLD_ROUTES[key] === undefined)).toEqual([]);
      // And who in a household may ask there, for every one of them.
      expect(Object.keys(HOUSEHOLD_LEVELS).sort()).toEqual(Object.keys(HOUSEHOLD_ROUTES).sort());
      expect(Object.keys(HOUSEHOLD_ROUTES).filter((key) => !registered.has(key))).toEqual([]);
    } finally {
      await running.close();
      removeDir(dir);
    }
  }, 60_000);

  it("refuses a guest household a route that has none", async () => {
    const one = await guest("Undecided");
    const app = createApp(f.deps);
    app.get("/v1/something-new", (c) => c.json({ secret: true }));
    const ask = async (who: Paired): Promise<number> =>
      (
        await app.request("/v1/something-new", {
          headers: { Authorization: `Bearer ${who.token}` },
        })
      ).status;
    expect(await ask(one.manager)).toBe(404);
    expect(await ask(owner())).toBe(200);
  });
});

describe("an invitation", () => {
  it("brings a household's first device in as its manager, once", async () => {
    const made = await invite("The neighbours");
    expect(made.household).toMatchObject({ owner: false, devices: 0, allowOutside: true });
    expect(made.invite.code).toMatch(/^[0-9A-Z]{4}(-[0-9A-Z]{4}){3}$/);
    const manager = await come(made.invite.code, "Neighbour's phone", byOwner);

    const me = await out(manager, "GET", "/v1/me");
    expect(me.status).toBe(200);
    const body = me.json<{ device: Device; household: { name: string; owner: boolean } }>();
    // An older app reads it as a viewer: it cannot manage the server, which is what "manager" was.
    expect(body.device).toMatchObject({
      role: "viewer",
      access: "householdAdmin",
      householdId: made.household.id,
    });
    expect(body.household).toEqual({ id: made.household.id, name: "The neighbours", owner: false });

    // Used up: the same code leads nowhere now.
    const again = await pairing("/v1/outside-pairing", {
      code: made.invite.code,
      deviceName: "Someone else",
      platform: "ios",
    });
    expect(again.status).toBe(404);

    const listed = await home(owner(), "GET", `/v1/households/${made.household.id}`);
    expect(listed.json<{ household: HouseholdReply }>().household).toMatchObject({
      devices: 1,
      managers: 1,
    });
    // The owner's home pairing is the owner's: a guest's manager cannot approve there.
    expect(
      (await home(manager, "POST", "/v1/pairing/approve", { code: "123456", role: "viewer" }))
        .status,
    ).toBe(403);
  });

  it("cannot be used once it expired or was taken back", async () => {
    const late = await invite("Late ones", { inviteHours: 1 });
    f.clock.ahead = 2 * 3_600_000;
    try {
      const reply = await pairing("/v1/outside-pairing", {
        code: late.invite.code,
        deviceName: "Phone",
        platform: "ios",
      });
      expect(reply.status).toBe(404);
    } finally {
      f.clock.ahead = 0;
    }
    const taken = await invite("Taken back");
    expect(
      (
        await home(
          owner(),
          "DELETE",
          `/v1/households/${taken.household.id}/invites/${taken.invite.id}`,
        )
      ).status,
    ).toBe(204);
    const reply = await pairing("/v1/outside-pairing", {
      code: taken.invite.code,
      deviceName: "Phone",
      platform: "ios",
    });
    expect(reply.status).toBe(404);
  });

  it("is the owner's to give, never a guest's", async () => {
    const one = await guest("Not the owner");
    expect((await home(one.manager, "POST", "/v1/households", { name: "More" })).status).toBe(404);
    expect((await out(one.manager, "POST", "/v1/households", { name: "More" })).status).toBe(403);
  });
});

describe("a guest household's manager", () => {
  it("lets their own devices in from outside, which the owner neither sees nor approves", async () => {
    const one = await guest("Pairing ones");
    const window = await out(one.manager, "POST", "/v1/outside/window", { minutes: 5 });
    const { code } = window.json<{ code: string }>();
    const asked = await pairing("/v1/outside-pairing", {
      code,
      deviceName: "Their TV",
      platform: "tvos",
    });
    const { id, comparison } = asked.json<{ id: string; comparison: string }>();
    // Not the owner's to see or to say yes to.
    const ownerSees = await home(owner(), "GET", "/v1/pairing/requests");
    expect(
      ownerSees.json<{ outsideRequests: { id: string }[] }>().outsideRequests.map((r) => r.id),
    ).not.toContain(id);
    expect((await byOwner(id, comparison)) === 404).toBe(true);
    const theySee = await out(one.manager, "GET", "/v1/pairing/requests");
    expect(
      theySee.json<{ outsideRequests: { id: string }[] }>().outsideRequests.map((r) => r.id),
    ).toEqual([id]);
    expect(
      (await out(one.manager, "POST", `/v1/outside/pairing/${id}/approve`, { comparison })).status,
    ).toBe(200);

    const tv = await another(one, "Their bedroom TV");
    const me = (await out(tv, "GET", "/v1/me")).json<{ device: Device }>().device;
    expect(me).toMatchObject({ role: "viewer", householdId: one.id });
    // And the owner's window is not theirs either.
    const ownWindow = await home(owner(), "POST", "/v1/outside/window", { minutes: 5 });
    const ownCode = ownWindow.json<{ code: string }>().code;
    const visitor = await pairing("/v1/outside-pairing", {
      code: ownCode,
      deviceName: "Owner's laptop",
      platform: "macos",
    });
    const request = visitor.json<{ id: string; comparison: string }>();
    expect(
      (
        await out(one.manager, "POST", `/v1/outside/pairing/${request.id}/approve`, {
          comparison: request.comparison,
        })
      ).status,
    ).toBe(404);
    await home(owner(), "DELETE", `/v1/outside/pairing/${request.id}`);
  });

  it("is a manager of nothing else: every route of the server's own is not there", async () => {
    const one = await guest("Nosy ones");
    const owners = Object.entries(HOUSEHOLD_ROUTES).filter(([, decision]) => decision === "owner");
    expect(owners.length).toBeGreaterThan(60);
    for (const [key] of owners) {
      const [method = "", pattern = ""] = key.split(" ");
      const path = pattern.replace(/:[a-zA-Z]+(\{[^}]*\})?/g, "x1");
      const body = ["GET", "DELETE"].includes(method) ? undefined : {};
      const reply = await home(one.manager, method, path, body);
      expect([key, reply.status]).toEqual([key, 404]);
    }
  }, 60_000);
});

describe("what belongs to a household", () => {
  it("is not there for another, on every route that names it", async () => {
    const a = await guest("A family");
    const b = await guest("B family");
    const aViewer = await profile(a.manager, { name: "A one" });
    const bViewer = await profile(b.manager, { name: "B one" });
    const aTv = await another(a, "A TV");
    const named = Object.entries(HOUSEHOLD_ROUTES).filter(([, decision]) =>
      ["profile", "device", "music_profile"].includes(decision),
    );
    expect(named.length).toBeGreaterThanOrEqual(25);
    const path = (pattern: string, profileId: string, deviceId: string): string =>
      pattern
        .replace(":profile", profileId)
        .replace("profiles/:id", `profiles/${profileId}`)
        .replace("devices/:id", `devices/${deviceId}`)
        .replace(/:[a-zA-Z]+/g, ids["Garden"] ?? "");
    const body = (method: string): unknown =>
      ["GET", "DELETE"].includes(method) ? undefined : { name: "Taken", avatar: "fox" };
    for (const [key] of named) {
      const [method = "", pattern = ""] = key.split(" ");
      // B's manager, at A's viewer and device; the owner's manager too; and A's at the owner's.
      for (const [who, profileId, deviceId] of [
        [b.manager, aViewer, aTv.id],
        [owner(), aViewer, aTv.id],
        [a.manager, ownerProfile, ownerViewer.id],
        [a.manager, bViewer, b.manager.id],
      ] as const) {
        const reply = await home(who, method, path(pattern, profileId, deviceId), body(method));
        expect([key, reply.status]).toEqual([key, 404]);
      }
    }
    // Nothing was changed.
    const still = await out(a.manager, "GET", "/v1/profiles");
    expect(still.json<{ profiles: { name: string }[] }>().profiles.map((one) => one.name)).toEqual([
      "A one",
    ]);
    expect((await out(aTv, "GET", "/v1/me")).status).toBe(200);
  }, 120_000);

  it("is listed for its own household only", async () => {
    const a = await guest("Listed A");
    const b = await guest("Listed B");
    await profile(a.manager, { name: "Only in A" });
    const lists = async (who: Paired, outside: boolean): Promise<Record<string, unknown>> => {
      const get = async (path: string): Promise<unknown> =>
        outside
          ? (await out(who, "GET", path)).json<unknown>()
          : (await home(who, "GET", path)).json<unknown>();
      return {
        profiles: ((await get("/v1/profiles")) as { profiles: { name: string }[] }).profiles.map(
          (one) => one.name,
        ),
        devices: ((await get("/v1/devices")) as { devices: Device[] }).devices.map(
          (one) => one.householdId,
        ),
        wanted: ((await get("/v1/devices/wanted")) as { devices: { id: string }[] }).devices.map(
          (one) => one.id,
        ),
      };
    };
    expect(await lists(a.manager, true)).toEqual({
      profiles: ["Only in A"],
      devices: [a.id],
      wanted: [a.manager.id],
    });
    expect(await lists(b.manager, true)).toEqual({
      profiles: [],
      devices: [b.id],
      wanted: [b.manager.id],
    });
    const mine = await lists(owner(), false);
    expect(mine["profiles"]).not.toContain("Only in A");
    expect(new Set(mine["devices"] as string[])).toEqual(new Set([OWNER_HOUSEHOLD]));
    // The owner sees the households, without what is in them.
    const all = await home(owner(), "GET", "/v1/households");
    const names = all.json<{ households: HouseholdReply[] }>().households.map((one) => one.name);
    expect(names).toEqual(expect.arrayContaining(["Home", "Listed A", "Listed B"]));
  });

  it("has its own code for grown-ups", async () => {
    const a = await guest("Code A");
    expect((await out(a.manager, "PUT", "/v1/kids/code", { code: "1111" })).status).toBe(200);
    expect((await home(owner(), "GET", "/v1/kids/code")).json<{ set: boolean }>().set).toBe(false);
    const check = async (who: Paired, code: string): Promise<boolean> =>
      (await out(who, "POST", "/v1/kids/code/check", { code })).json<{ correct: boolean }>()
        .correct;
    expect(await check(a.manager, "1111")).toBe(true);
    await home(owner(), "PUT", "/v1/kids/code", { code: "2222" });
    expect(await check(a.manager, "2222")).toBe(false);
    expect(await check(a.manager, "1111")).toBe(true);
    await home(owner(), "PUT", "/v1/kids/code", { code: null });
  });

  it("counts what is popular in each household by itself", async () => {
    const a = await guest("Watchers");
    const viewer = await profile(a.manager, { name: "Watcher" });
    const watch = async (who: Paired, profileId: string, item: string): Promise<void> => {
      const reply = await out(who, "PUT", `/v1/profiles/${profileId}/progress/${item}`, {
        opId: `op-${profileId}-${item}`,
        baseRevision: null,
        positionMs: 900,
        durationMs: 1000,
        completed: false,
        updatedAt: Date.now(),
      });
      expect(reply.status).toBe(200);
    };
    await watch(a.manager, viewer, ids["Scary"] ?? "");
    const popular = async (who: Paired): Promise<string[]> =>
      (await out(who, "GET", "/v1/popular"))
        .json<{ titles: { itemId: string }[] }>()
        .titles.map((one) => one.itemId);
    expect(await popular(a.manager)).toEqual([ids["Scary"]]);
    expect(await popular(ownerViewer)).not.toContain(ids["Scary"]);
    // Nor can the owner's devices read the guest's progress.
    expect((await home(owner(), "GET", `/v1/profiles/${viewer}/progress`)).status).toBe(404);
  });

  it("keeps the access log of its own devices", async () => {
    const a = await guest("Logged");
    await out(a.manager, "GET", "/v1/library?limit=1");
    await out(ownerViewer, "GET", "/v1/library?limit=1");
    await until(async () => {
      const reply = await out(a.manager, "GET", "/v1/outside/access");
      return reply.status === 200 && reply.json<{ entries: unknown[] }>().entries.length > 0;
    });
    const theirs = (await out(a.manager, "GET", "/v1/outside/access"))
      .json<{ entries: { deviceId: string | null }[] }>()
      .entries.map((one) => one.deviceId);
    expect(new Set(theirs)).toEqual(new Set([a.manager.id]));
  });
});

describe("the library a guest household sees", () => {
  it("is all of it without limits, and only what the owner allows with them", async () => {
    const all = await guest("Everything");
    expect(await titles(all.manager)).toEqual(["Balloon", "Garden", "Scary"]);
    const some = await guest("Small things", {
      scope: { ...nothing, allowedGroupIds: [await groupId("Small")] },
    });
    expect(await titles(some.manager)).toEqual(["Balloon"]);
    expect((await out(some.manager, "GET", `/v1/items/${ids["Scary"] ?? ""}`)).status).toBe(404);
    expect(
      (await out(some.manager, "GET", `/v1/assets/${assets["Scary"] ?? ""}/content`)).status,
    ).toBe(404);
    expect(
      (await out(some.manager, "GET", `/v1/assets/${assets["Balloon"] ?? ""}/content`)).status,
    ).toBe(200);
    // No part of the library says what music is in it: none.
    expect((await out(some.manager, "GET", "/v1/music/library")).status).toBe(404);
    expect((await out(all.manager, "GET", "/v1/music/library")).status).toBe(200);
    // Nothing allowed is nothing.
    await home(owner(), "PATCH", `/v1/households/${some.id}`, { scope: nothing });
    expect(await titles(some.manager)).toEqual([]);
    await home(owner(), "PATCH", `/v1/households/${some.id}`, { scope: null });
    expect(await titles(some.manager)).toEqual(["Balloon", "Garden", "Scary"]);
  });

  it("is for a child of that household what both allow", async () => {
    const some = await guest("Small ones", {
      scope: { ...nothing, allowedGroupIds: [await groupId("Small"), await groupId(null)] },
    });
    const kid = await profile(some.manager, {
      name: "Little",
      kids: { ...nothing, allowedItemIds: [ids["Balloon"], ids["Scary"]] },
    });
    const tablet = await another(some, "Little's tablet", "ipados");
    const bound = await out(some.manager, "PATCH", `/v1/devices/${tablet.id}`, {
      kidsProfileId: kid,
    });
    expect(bound.status).toBe(200);
    expect(await titles(tablet)).toEqual(["Balloon"]);
    // Their own child's limits, as at home: managers' routes are not there for the tablet.
    expect((await out(tablet, "GET", "/v1/devices")).status).toBe(404);
    // A child of another household is none of theirs to bind.
    const ownersKid = await profile(
      owner(),
      { name: "Owner's small", kids: { ...nothing, allowedItemIds: [ids["Balloon"]] } },
      false,
    );
    expect(
      (await out(some.manager, "PATCH", `/v1/devices/${tablet.id}`, { kidsProfileId: ownersKid }))
        .status,
    ).toBe(404);
  });
});

describe("the owner", () => {
  it("pauses a household: its devices get nothing and keep everything", async () => {
    const one = await guest("Paused ones");
    const viewer = await profile(one.manager, { name: "Kept" });
    expect(
      (await home(owner(), "PATCH", `/v1/households/${one.id}`, { paused: true })).status,
    ).toBe(200);
    const outside = await out(one.manager, "GET", "/v1/me");
    expect([outside.status, outside.body.length]).toEqual([404, 0]);
    expect((await home(one.manager, "GET", "/v1/me")).status).toBe(404);
    await home(owner(), "PATCH", `/v1/households/${one.id}`, { paused: false });
    const back = await out(one.manager, "GET", "/v1/profiles");
    expect(back.json<{ profiles: { id: string }[] }>().profiles.map((p) => p.id)).toEqual([viewer]);
  });

  it("removes a household: its devices are cut off at once, never the library", async () => {
    const one = await guest("Gone ones");
    const viewer = await profile(one.manager, { name: "Gone" });
    const tv = await another(one, "Gone TV");
    const before = (await home(owner(), "GET", "/v1/library?limit=1000")).json<{
      items: unknown[];
    }>().items.length;
    expect((await home(owner(), "DELETE", `/v1/households/${one.id}`)).status).toBe(204);
    expect((await out(tv, "GET", "/v1/me")).status).toBe(404);
    expect(
      (await home(one.manager, "GET", "/v1/me")).json<{ error: { code: string } }>().error.code,
    ).toBe("device_revoked");
    expect((await home(owner(), "GET", `/v1/households/${one.id}`)).status).toBe(404);
    expect((await home(owner(), "GET", `/v1/profiles/${viewer}/progress`)).status).toBe(404);
    const after = (await home(owner(), "GET", "/v1/library?limit=1000")).json<{
      items: unknown[];
    }>().items.length;
    expect(after).toBe(before);
    expect((await home(owner(), "DELETE", `/v1/households/${OWNER_HOUSEHOLD}`)).status).toBe(409);
  });

  it("keeps a household to its devices and to home", async () => {
    const small = await guest("Few devices", { maxDevices: 1 });
    const window = await out(small.manager, "POST", "/v1/outside/window", { minutes: 5 });
    const { code } = window.json<{ code: string }>();
    const refused = await pairing("/v1/outside-pairing", {
      code,
      deviceName: "One too many",
      platform: "tvos",
    });
    expect(refused.status).toBe(404);

    const away = await guest("Not from outside");
    await home(owner(), "PATCH", `/v1/households/${away.id}`, { allowOutside: false });
    expect((await out(away.manager, "GET", "/v1/me")).status).toBe(404);
    await home(owner(), "PATCH", `/v1/households/${away.id}`, { allowOutside: true });
    expect((await out(away.manager, "GET", "/v1/me")).status).toBe(200);
  });

  it("caps what a household is sent, all its devices together", async () => {
    const one = await guest("Slow line");
    const asset = assets["Garden"] ?? "";
    const size = statSync(join(f.dir, "Films", "Garden (2001).mp4")).size;
    // About two seconds' worth for the whole file.
    const bytesPerSecond = size / 2;
    await home(owner(), "PATCH", `/v1/households/${one.id}`, {
      maxMbps: bytesPerSecond / 125_000,
    });
    const started = performance.now();
    const reply = await home(one.manager, "GET", `/v1/assets/${asset}/content`);
    expect(reply.status).toBe(200);
    const took = performance.now() - started;
    expect(took).toBeGreaterThan(1_500);
    // The owner's own are sent as fast as they go.
    const quick = performance.now();
    expect((await home(owner(), "GET", `/v1/assets/${asset}/content`)).status).toBe(200);
    expect(performance.now() - quick).toBeLessThan(took);
    await home(owner(), "PATCH", `/v1/households/${one.id}`, { maxMbps: null });
  }, 30_000);

  it("changes no limits of their own household", async () => {
    const reply = await home(owner(), "PATCH", `/v1/households/${OWNER_HOUSEHOLD}`, {
      maxMbps: 1,
    });
    expect(reply.status).toBe(409);
    const renamed = await home(owner(), "PATCH", `/v1/households/${OWNER_HOUSEHOLD}`, {
      name: "The Parkers",
    });
    expect(renamed.json<HouseholdReply>()).toMatchObject({ name: "The Parkers", owner: true });
    await home(owner(), "PATCH", `/v1/households/${OWNER_HOUSEHOLD}`, { name: "Home" });
  });
});

describe("playing on another device", () => {
  it("sees and controls the devices of its own household only", async () => {
    const one = await guest("Remote ones");
    const theirTv = await another(one, "Their living room");
    const open = async (who: Paired, outside: boolean): Promise<LiveClient> => {
      const client = new LiveClient(who, outside ? () => f.connect() : port);
      live.push(client);
      await client.open();
      expect(client.status).toBe(200);
      expect((await client.announce()).status).toBe(200);
      return client;
    };
    const ownerTv = await open(ownerViewer, false);
    const tv = await open(theirTv, true);
    // Played on from outside only with remoteOutside, as for anyone.
    await out(one.manager, "PATCH", `/v1/devices/${theirTv.id}`, { remoteOutside: true });
    await out(one.manager, "PATCH", `/v1/devices/${one.manager.id}`, { remoteOutside: true });
    const phone = await open(one.manager, true);
    await until(() => phone.sees(tv.id) !== null);
    expect(phone.sees(ownerTv.id)).toBeNull();
    const command = await phone.command(ownerTv.id, { type: "pause" });
    expect(command.status).toBe(404);
    // Nor waking the owner's TVs: those are on the owner's network.
    expect(
      (await home(one.manager, "POST", "/v1/remote/wake", { deviceId: ownerTv.id })).status,
    ).toBe(404);
  });
});

/** A device paired at home into the owner's household, as the command line approves it. */
function atHome(name: string, access: Access): Paired {
  const waiting = f.devices.startPairing(name, "ios");
  f.devices.approve(waiting.code, access, "cli");
  const done = f.devices.collect(waiting.id, waiting.pollSecret);
  if (done.status !== "approved") throw new Error("not paired");
  return { id: done.device.id, token: done.token };
}

/** A device outside that shows a code, and what it is told after that. */
async function asks(
  code: string,
  deviceName: string,
): Promise<{
  id: string;
  comparison: string;
  collect: () => ReturnType<OutsideFixture["ask"]>;
}> {
  const asked = await pairing("/v1/outside-pairing", { code, deviceName, platform: "tvos" });
  expect(asked.status).toBe(201);
  const { id, pollSecret, comparison } = asked.json<{
    id: string;
    pollSecret: string;
    comparison: string;
  }>();
  return {
    id,
    comparison,
    collect: () => pairing("/v1/outside-pairing/collect", { id, pollSecret }),
  };
}

describe("a household admin of the owner's household", () => {
  it("sets up its viewers and devices, and nothing of the server", async () => {
    const parent = atHome("Parent's phone", "householdAdmin");
    const tablet = atHome("Tablet", "viewer");
    const me = (await home(parent, "GET", "/v1/me")).json<{ device: Device }>().device;
    expect(me).toMatchObject({
      access: "householdAdmin",
      role: "viewer",
      householdId: OWNER_HOUSEHOLD,
    });

    // Its household: viewers, kids, devices, the code.
    const viewer = await profile(parent, { name: "Little one" }, false);
    expect(
      (await home(parent, "PATCH", `/v1/profiles/${viewer}`, { name: "Small one" })).status,
    ).toBe(200);
    expect((await home(parent, "PUT", "/v1/kids/code", { code: "4321" })).status).toBe(200);
    await home(parent, "PUT", "/v1/kids/code", { code: null });
    expect((await home(parent, "GET", "/v1/devices")).status).toBe(200);
    expect(
      (
        await home(parent, "PATCH", `/v1/devices/${tablet.id}`, { access: "householdAdmin" })
      ).json<Device>().access,
    ).toBe("householdAdmin");
    expect(
      (await home(parent, "PATCH", `/v1/devices/${tablet.id}`, { access: "viewer" })).status,
    ).toBe(200);

    // Never more than itself, and never a server admin's device.
    expect(
      (await home(parent, "PATCH", `/v1/devices/${tablet.id}`, { access: "admin" })).status,
    ).toBe(403);
    expect((await home(parent, "DELETE", `/v1/devices/${owner().id}`)).status).toBe(403);
    expect(
      (await home(parent, "PATCH", `/v1/devices/${owner().id}`, { access: "viewer" })).status,
    ).toBe(403);
    expect(
      (await home(parent, "POST", "/v1/pairing/approve", { code: "000000", role: "manager" }))
        .status,
    ).toBe(403);

    // Every route of the server's own says no.
    // Of those this server has (it has no Apple TVs to wake).
    const here = new Set(
      f.home.routes.map(
        (route) => `${route.method === "HEAD" ? "GET" : route.method} ${route.path}`,
      ),
    );
    const servers = Object.entries(HOUSEHOLD_LEVELS).filter(
      ([key, level]) => level === "admin" && here.has(key),
    );
    expect(servers.length).toBeGreaterThan(60);
    for (const [key] of servers) {
      const [method = "", pattern = ""] = key.split(" ");
      const path = pattern.replace(/:[a-zA-Z]+(\{[^}]*\})?/g, "x1");
      const reply = await home(
        parent,
        method,
        path,
        ["GET", "DELETE"].includes(method) ? undefined : {},
      );
      expect([key, reply.status]).toEqual([key, 403]);
    }
    // A viewer is told the same where a household admin may.
    expect((await home(tablet, "GET", "/v1/devices")).status).toBe(403);
    expect((await home(tablet, "POST", "/v1/household/invites", {})).status).toBe(403);
    f.devices.revoke(parent.id);
    f.devices.revoke(tablet.id);
  }, 60_000);

  it("invites into its own household from outside, never a new household", async () => {
    const parent = atHome("Grandma's helper", "householdAdmin");
    const made = await home(parent, "POST", "/v1/household/invites", { access: "viewer" });
    expect(made.status).toBe(201);
    const { code } = made.json<{ code: string }>();
    expect((await home(parent, "POST", "/v1/households", { name: "Mine" })).status).toBe(403);

    const grandma = await asks(code, "Grandma's TV");
    // The household admin compares the digits; the owner's household needs no server admin.
    const yes = await home(parent, "POST", `/v1/outside/pairing/${grandma.id}/approve`, {
      comparison: grandma.comparison,
    });
    expect(yes.json<{ access: string; awaitsAdmin: boolean }>()).toMatchObject({
      access: "viewer",
      awaitsAdmin: false,
    });
    const done = await grandma.collect();
    expect(done.status).toBe(200);
    expect(done.json<{ device: Device }>().device).toMatchObject({
      access: "viewer",
      householdId: OWNER_HOUSEHOLD,
      allowOutside: true,
    });
    f.devices.revoke(parent.id);
  });

  it("is made only by a server admin into a server admin, and the last one stays", async () => {
    const helper = atHome("Helper", "householdAdmin");
    const promoted = await home(owner(), "PATCH", `/v1/devices/${helper.id}`, { access: "admin" });
    expect(promoted.json<Device>()).toMatchObject({ access: "admin", role: "manager" });
    await home(owner(), "PATCH", `/v1/devices/${helper.id}`, { access: "viewer" });
    // The last server admin cannot stop being one.
    expect(
      (await home(owner(), "PATCH", `/v1/devices/${owner().id}`, { access: "viewer" })).status,
    ).toBe(409);
    // Nor is a server admin made in a guest household.
    const one = await guest("No admins here");
    expect(
      (await home(owner(), "PATCH", `/v1/devices/${one.manager.id}`, { access: "admin" })).status,
    ).toBe(404);
    f.devices.revoke(helper.id);
  });
});

describe("a household whose new devices need a server admin", () => {
  const strict = async (): Promise<Guest> => guest("Strict ones", { requiresAdminApproval: true });

  it("lets a device in only after both said yes", async () => {
    const one = await strict();
    const window = await out(one.manager, "POST", "/v1/outside/window", { minutes: 5 });
    const tv = await asks(window.json<{ code: string }>().code, "Strict TV");
    const first = await out(one.manager, "POST", `/v1/outside/pairing/${tv.id}/approve`, {
      comparison: tv.comparison,
    });
    expect(first.json<{ awaitsAdmin: boolean }>().awaitsAdmin).toBe(true);
    const waits = await tv.collect();
    expect([waits.status, waits.json<{ waitingFor: string }>().waitingFor]).toEqual([202, "admin"]);
    // The household admin sees it wait; the server admin sees it, with the household's name.
    const theirs = (await out(one.manager, "GET", "/v1/pairing/requests")).json<{
      outsideRequests: { id: string; state: string }[];
    }>();
    expect(theirs.outsideRequests).toEqual([
      expect.objectContaining({ id: tv.id, state: "awaitingAdmin" }),
    ]);
    const admins = (await home(owner(), "GET", "/v1/pairing/requests")).json<{
      outsideRequests: { id: string; state: string; householdName: string }[];
    }>();
    expect(admins.outsideRequests).toContainEqual(
      expect.objectContaining({ id: tv.id, state: "awaitingAdmin", householdName: "Strict ones" }),
    );
    // Its household admin cannot say the second yes.
    expect(
      (await out(one.manager, "POST", `/v1/outside/pairing/${tv.id}/approve`, {})).status,
    ).toBe(404);
    const second = await home(owner(), "POST", `/v1/outside/pairing/${tv.id}/approve`, {});
    expect(second.json<{ awaitsAdmin: boolean }>().awaitsAdmin).toBe(false);
    const done = await tv.collect();
    expect(done.status).toBe(200);
    expect(done.json<{ device: Device }>().device.householdId).toBe(one.id);
  });

  it("tells its household admin when a server admin says no, and lets nothing in", async () => {
    const one = await strict();
    const window = await out(one.manager, "POST", "/v1/outside/window", { minutes: 5 });
    const tv = await asks(window.json<{ code: string }>().code, "Refused TV");
    await out(one.manager, "POST", `/v1/outside/pairing/${tv.id}/approve`, {
      comparison: tv.comparison,
    });
    expect((await home(owner(), "DELETE", `/v1/outside/pairing/${tv.id}`)).status).toBe(204);
    expect((await tv.collect()).status).toBe(404);
    const theirs = (await out(one.manager, "GET", "/v1/pairing/requests")).json<{
      outsideRequests: { id: string; state: string }[];
    }>();
    expect(theirs.outsideRequests).toEqual([
      expect.objectContaining({ id: tv.id, state: "refused" }),
    ]);
  });

  it("lets a request that nobody decided about expire as any other", async () => {
    const one = await strict();
    const window = await out(one.manager, "POST", "/v1/outside/window", { minutes: 5 });
    const tv = await asks(window.json<{ code: string }>().code, "Late TV");
    await out(one.manager, "POST", `/v1/outside/pairing/${tv.id}/approve`, {
      comparison: tv.comparison,
    });
    f.clock.ahead = 11 * 60_000;
    try {
      expect((await tv.collect()).status).toBe(404);
      const admins = (await home(owner(), "GET", "/v1/pairing/requests")).json<{
        outsideRequests: { id: string }[];
      }>();
      expect(admins.outsideRequests.map((r) => r.id)).not.toContain(tv.id);
    } finally {
      f.clock.ahead = 0;
    }
  });

  it("is the server admin's to turn on and off, never its household admin's", async () => {
    const one = await strict();
    expect(
      (
        await out(one.manager, "PATCH", `/v1/households/${one.id}`, {
          requiresAdminApproval: false,
        })
      ).status,
    ).toBe(403);
    expect(
      (
        await home(one.manager, "PATCH", `/v1/households/${one.id}`, {
          requiresAdminApproval: false,
        })
      ).status,
    ).toBe(404);
    const parent = atHome("Owner's household admin", "householdAdmin");
    expect(
      (
        await home(parent, "PATCH", `/v1/households/${OWNER_HOUSEHOLD}`, {
          requiresAdminApproval: true,
        })
      ).status,
    ).toBe(403);
    const off = await home(owner(), "PATCH", `/v1/households/${one.id}`, {
      requiresAdminApproval: false,
    });
    expect(off.json<{ requiresAdminApproval: boolean }>().requiresAdminApproval).toBe(false);
    // A new household needs it unless said otherwise.
    const fresh = await invite("Fresh ones");
    expect(fresh.household).toMatchObject({ requiresAdminApproval: true });
    f.devices.revoke(parent.id);
  });

  it("holds the owner's own household to it at home too, when it is on", async () => {
    await home(owner(), "PATCH", `/v1/households/${OWNER_HOUSEHOLD}`, {
      requiresAdminApproval: true,
    });
    const parent = atHome("Careful parent", "householdAdmin");
    try {
      const waiting = f.devices.startPairing("Kitchen iPad", "ipados");
      const yes = await home(parent, "POST", "/v1/pairing/approve", {
        code: waiting.code,
        access: "viewer",
      });
      expect(yes.json<{ awaitsAdmin: boolean }>().awaitsAdmin).toBe(true);
      expect(f.devices.collect(waiting.id, waiting.pollSecret)).toMatchObject({
        status: "pending",
        waitingFor: "admin",
      });
      const listed = (await home(owner(), "GET", "/v1/pairing/requests")).json<{
        awaitingAdmin: { id: string }[];
      }>();
      expect(listed.awaitingAdmin.map((one) => one.id)).toEqual([waiting.id]);
      expect(
        (await home(parent, "POST", "/v1/pairing/approve", { requestId: waiting.id })).status,
      ).toBe(403);
      expect(
        (await home(owner(), "POST", "/v1/pairing/approve", { requestId: waiting.id })).status,
      ).toBe(200);
      expect(f.devices.collect(waiting.id, waiting.pollSecret).status).toBe("approved");

      const other = f.devices.startPairing("Stranger's phone", "ios");
      await home(parent, "POST", "/v1/pairing/approve", { code: other.code, access: "viewer" });
      expect((await home(owner(), "DELETE", `/v1/pairing/requests/${other.id}`)).status).toBe(204);
      expect(() => f.devices.collect(other.id, other.pollSecret)).toThrow(/did not let/);
      const told = (await home(parent, "GET", "/v1/pairing/requests")).json<{
        refused: { id: string }[];
      }>();
      expect(told.refused.map((one) => one.id)).toEqual([other.id]);
    } finally {
      await home(owner(), "PATCH", `/v1/households/${OWNER_HOUSEHOLD}`, {
        requiresAdminApproval: false,
      });
      f.devices.revoke(parent.id);
    }
  });
});
