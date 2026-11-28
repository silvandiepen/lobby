// SPDX-License-Identifier: MPL-2.0
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { serve, type ServerType } from "@hono/node-server";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { loadConfig, parseConfig } from "../src/config.ts";
import { WakeHelper, WakeHelperError } from "../src/remote/wake-helper.ts";
import { startServer, type RunningServer } from "../src/server.ts";
import { LiveClient } from "./support/live.ts";
import { makeTempDir, makeVideo, removeDir } from "./support/media.ts";
import { until } from "./support/outside.ts";

const FAKE = fileURLToPath(new URL("./support/fake-wake.ts", import.meta.url));
const FAKE_PYATV = fileURLToPath(new URL("./support/fake-pyatv/run.py", import.meta.url));
/** Short waits for Lobby on a woken TV, so that the tests do not wait as long as a TV would. */
const TIMINGS: { pickAfterMs: number; openMs: number; lookMs: number; holdPlayMs: number | null } =
  { pickAfterMs: 400, openMs: 1_500, lookMs: 50, holdPlayMs: null };

interface Reply {
  status: number;
  body: Record<string, unknown>;
}

let dir: string;
let state: string;
let running: RunningServer | null = null;
let server: ServerType | null = null;
let port = 0;
let manager: string;
let clients: LiveClient[] = [];

const tvs = (more: Record<string, unknown> = {}): void => {
  writeFileSync(
    join(state, "tvs.json"),
    JSON.stringify({
      televisions: [
        { id: "AA:BB", name: "Living Room", model: "Apple TV 4K (gen 3)", paired: false },
        { id: "CC:DD", name: "Bedroom", model: "Apple TV HD", paired: true },
      ],
      ...more,
    }),
  );
};

const changeState = (change: (all: Record<string, unknown>) => void): void => {
  const all = JSON.parse(readFileSync(join(state, "tvs.json"), "utf8")) as Record<string, unknown>;
  change(all);
  writeFileSync(join(state, "tvs.json"), JSON.stringify(all));
};

const asked = (): Record<string, unknown>[] =>
  existsSync(join(state, "log.jsonl"))
    ? readFileSync(join(state, "log.jsonl"), "utf8")
        .trim()
        .split("\n")
        .filter((line) => line !== "")
        .map((line) => JSON.parse(line) as Record<string, unknown>)
    : [];

let helper: WakeHelper | null = null;
const fakeHelper = (): WakeHelper => {
  helper = new WakeHelper({
    python: process.execPath,
    flags: [],
    script: FAKE,
    args: ["--state", state],
  });
  return helper;
};

async function start(
  wake: Record<string, unknown> | null = { pyatv: "/nowhere/bin" },
  more: { films?: string; timings?: Partial<typeof TIMINGS> } = {},
): Promise<void> {
  const configPath = join(dir, "lobby.config.json");
  writeFileSync(
    configPath,
    JSON.stringify({
      host: "127.0.0.1",
      port: 0,
      stabilityMs: 0,
      advertise: false,
      ...(more.films ? { roots: [{ path: more.films, name: "Films", hint: "movies" }] } : {}),
      ...(wake ? { remote: { wake } } : {}),
    }),
  );
  running = await startServer(loadConfig(configPath), {
    wakeHelper: fakeHelper,
    wakeTimings: { ...TIMINGS, ...more.timings },
  });
  manager = running.services.devices.createLocalManager("Desk").token;
  server = await new Promise((done) => {
    const made = serve(
      { fetch: running?.app.fetch ?? (() => new Response()), hostname: "127.0.0.1", port: 0 },
      () => {
        done(made);
      },
    );
  });
  const address = server?.address();
  port = typeof address === "object" && address !== null ? address.port : 0;
}

function device(name: string, platform: "tvos" | "ios" | "macos"): { id: string; token: string } {
  if (!running) throw new Error("not running");
  const made = running.services.devices.createOutsideViewer(name, platform);
  running.services.devices.setAllowOutside(made.device.id, false);
  return { id: made.device.id, token: made.token };
}

async function ask(
  method: string,
  path: string,
  body?: unknown,
  options: { token?: string; peer?: string } = {},
): Promise<Reply> {
  if (!running) throw new Error("not running");
  const env =
    options.peer === undefined
      ? undefined
      : { incoming: { socket: { remoteAddress: options.peer } } };
  const response = await running.app.request(
    `http://127.0.0.1${path}`,
    {
      method,
      headers: {
        Host: "127.0.0.1",
        Authorization: `Bearer ${options.token ?? manager}`,
        ...(body === undefined ? {} : { "Content-Type": "application/json" }),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    },
    env,
  );
  const text = await response.text();
  let parsed: Record<string, unknown> = {};
  try {
    parsed = JSON.parse(text) as Record<string, unknown>;
  } catch {
    // Not JSON.
  }
  return { status: response.status, body: parsed };
}

const reason = (reply: Reply): unknown => [
  (reply.body["error"] as { code?: string } | undefined)?.code ?? null,
  reply.body["reason"] ?? null,
];

const televisions = (reply: Reply): Record<string, unknown>[] =>
  reply.body["televisions"] as Record<string, unknown>[];

async function live(who: { id: string; token: string }): Promise<LiveClient> {
  const made = new LiveClient(who, port);
  clients.push(made);
  await made.open();
  expect(made.status).toBe(200);
  expect((await made.announce()).status).toBe(200);
  return made;
}

/** A TV that Lobby Server is connected to and that is linked to the Lobby device `tv`. */
async function connected(tv: string): Promise<void> {
  await until(async () => (await ask("GET", "/v1/wake")).body["running"] === true);
  await ask("POST", "/v1/wake/scan");
  const linked = await ask("PUT", "/v1/wake/televisions/CC:DD", { deviceId: tv });
  expect(linked.status).toBe(200);
}

beforeEach(() => {
  dir = makeTempDir("lobby-wake-");
  state = join(dir, "fake");
  mkdirSync(state);
  tvs();
});

afterEach(async () => {
  for (const one of clients) one.cut();
  clients = [];
  if (server) {
    if ("closeAllConnections" in server) server.closeAllConnections();
    await new Promise((done) => server?.close(done));
  }
  server = null;
  await running?.close();
  running = null;
  removeDir(dir);
});

describe("remote.wake in the config", () => {
  const parse = (remote: unknown): ReturnType<typeof parseConfig>["wake"] =>
    parseConfig({ remote }, "/srv/lobby/lobby.config.json").wake;

  it("is off without it, and takes the venv, the storage and the hosts", () => {
    expect(parse(undefined)).toBeNull();
    expect(parse({})).toBeNull();
    expect(parse({ wake: { pyatv: "pyatv/bin" } })).toEqual({
      pyatv: "/srv/lobby/pyatv/bin",
      storage: null,
      hosts: [],
      app: "mt.sil.lobby",
      enabled: true,
      kids: false,
      pickProfile: true,
      holdPlaySeconds: 180,
      speakers: true,
    });
    expect(
      parse({
        wake: { pyatv: "/v/bin", storage: "tv.conf", hosts: ["192.168.1.20"], enabled: false },
      }),
    ).toMatchObject({ storage: "/srv/lobby/tv.conf", hosts: ["192.168.1.20"], enabled: false });
  });

  it("refuses what it cannot use", () => {
    expect(() => parse({ wake: {} })).toThrow(/remote.wake.pyatv/);
    expect(() => parse({ wake: { pyatv: "/v/bin", hosts: ["tv.local"] } })).toThrow(/IPv4/);
    expect(() => parse({ wake: { pyatv: "/v/bin", app: "not a bundle" } })).toThrow(/bundle id/);
    expect(() => parse({ wake: { pyatv: "/v/bin", python: "/usr/bin/evil" } })).toThrow(/unknown/);
    expect(() => parse({ wake: { pyatv: "/v/bin", kids: "yes" } })).toThrow(/remote.wake.kids/);
    expect(() => parse({ wake: { pyatv: "/v/bin", pickProfile: 1 } })).toThrow(/pickProfile/);
    expect(() => parse({ wake: { pyatv: "/v/bin", holdPlaySeconds: 5 } })).toThrow(/15 to 900/);
    expect(
      parse({ wake: { pyatv: "/v/bin", pickProfile: false, holdPlaySeconds: 60 } }),
    ).toMatchObject({ pickProfile: false, holdPlaySeconds: 60 });
    expect(() => parse("on")).toThrow(/"remote"/);
  });
});

describe("Apple TVs for a manager", () => {
  it("are for a manager at home only", async () => {
    await start();
    const phone = device("Phone", "ios");
    expect(reason(await ask("GET", "/v1/wake", undefined, { token: phone.token }))).toEqual([
      "forbidden",
      null,
    ]);
    expect((await ask("GET", "/v1/wake", undefined, { peer: "203.0.113.9" })).status).toBe(403);
    await until(async () => (await ask("GET", "/v1/wake")).body["running"] === true);
    const status = await ask("GET", "/v1/wake");
    expect(status.body).toMatchObject({
      configured: true,
      enabled: true,
      pyatv: "fake",
      problem: null,
    });
  });

  it("are found, connected with the code the TV shows, linked and disconnected", async () => {
    await start();
    const living = device("Living Room", "tvos");
    device("Kitchen iPad", "ios");
    await until(async () => (await ask("GET", "/v1/wake")).body["running"] === true);

    const scanned = await ask("POST", "/v1/wake/scan");
    expect(scanned.status).toBe(200);
    expect(televisions(scanned)).toEqual([
      expect.objectContaining({
        id: "CC:DD",
        name: "Bedroom",
        paired: true,
        found: true,
        deviceId: null,
      }),
      expect.objectContaining({
        id: "AA:BB",
        paired: false,
        found: true,
        suggestedDeviceId: living.id,
      }),
    ]);

    const begun = await ask("POST", "/v1/wake/pairings", { televisionId: "AA:BB" });
    expect(begun.status).toBe(201);
    const wrong = await ask("POST", `/v1/wake/pairings/${String(begun.body["id"])}`, {
      pin: "9999",
    });
    expect(reason(wrong)).toEqual(["forbidden", "wake_pairing_failed"]);
    // That pairing is over: the code is asked for again.
    const again = await ask("POST", `/v1/wake/pairings/${String(begun.body["id"])}`, {
      pin: "1234",
    });
    expect(reason(again)).toEqual(["gone", "pairing_expired"]);

    const second = await ask("POST", "/v1/wake/pairings", { televisionId: "AA:BB" });
    expect(
      reason(await ask("POST", `/v1/wake/pairings/${String(second.body["id"])}`, { pin: "12" })),
    ).toEqual(["invalid_request", null]);
    const third = await ask("POST", "/v1/wake/pairings", { televisionId: "AA:BB" });
    const done = await ask("POST", `/v1/wake/pairings/${String(third.body["id"])}`, {
      pin: "1234",
    });
    expect(done.status).toBe(200);
    expect(done.body).toMatchObject({
      id: "AA:BB",
      paired: true,
      suggestedDeviceId: living.id,
      deviceId: null,
    });
    // The PIN went to the helper and nowhere else.
    expect(JSON.stringify((await ask("GET", "/v1/wake")).body)).not.toContain("1234");

    expect(
      (await ask("PUT", "/v1/wake/televisions/AA:BB", { deviceId: living.id })).body,
    ).toMatchObject({
      deviceId: living.id,
      suggestedDeviceId: null,
    });
    const ipad = device("iPad", "ios");
    expect(reason(await ask("PUT", "/v1/wake/televisions/AA:BB", { deviceId: ipad.id }))).toEqual([
      "invalid_request",
      null,
    ]);
    // One Lobby device is one TV: linking it elsewhere unlinks it here.
    await ask("PUT", "/v1/wake/televisions/CC:DD", { deviceId: living.id });
    const after = televisions(await ask("GET", "/v1/wake"));
    expect(after.find((one) => one["id"] === "AA:BB")?.["deviceId"]).toBeNull();
    expect(after.find((one) => one["id"] === "CC:DD")?.["deviceId"]).toBe(living.id);

    expect((await ask("DELETE", "/v1/wake/televisions/CC:DD")).status).toBe(204);
    const gone = televisions(await ask("GET", "/v1/wake")).find((one) => one["id"] === "CC:DD");
    expect(gone).toMatchObject({ paired: false, deviceId: null });
    expect(asked().filter((one) => one["op"] === "unpair")).toEqual([
      expect.objectContaining({ device: "CC:DD" }),
    ]);
    expect(reason(await ask("PUT", "/v1/wake/televisions/CC:DD", { deviceId: living.id }))).toEqual(
      ["not_found", "not_paired"],
    );
  });

  it("turns waking on and off as a setting, kept with the others", async () => {
    await start();
    const off = await ask("PATCH", "/v1/wake", { enabled: false });
    expect(off.status).toBe(200);
    expect(off.body["enabled"]).toBe(false);
    const settings = await ask("GET", "/v1/settings");
    const setting = (settings.body["settings"] as Record<string, unknown>[]).find(
      (one) => one["key"] === "remote.wake.enabled",
    );
    expect(setting).toMatchObject({ value: false, available: true });
    expect(
      (await ask("PATCH", "/v1/settings", { changes: { "remote.wake.enabled": true } })).status,
    ).toBe(200);
    expect((await ask("GET", "/v1/wake")).body["enabled"]).toBe(true);
  });

  it("says when it is not set up, and the setting says why", async () => {
    await start(null);
    expect((await ask("GET", "/v1/wake")).body).toMatchObject({
      configured: false,
      enabled: false,
      running: false,
    });
    expect(reason(await ask("POST", "/v1/wake/scan"))).toEqual([
      "not_found",
      "wake_not_configured",
    ]);
    expect(reason(await ask("PATCH", "/v1/wake", { enabled: true }))).toEqual([
      "not_found",
      "wake_not_configured",
    ]);
    const settings = await ask("GET", "/v1/settings");
    const setting = (settings.body["settings"] as Record<string, unknown>[]).find(
      (one) => one["key"] === "remote.wake.enabled",
    );
    expect(setting).toMatchObject({ available: false });
    expect(String(setting?.["unavailableReason"])).toMatch(/pyatv/);
  });
});

describe("waking a TV to play on it", () => {
  it("is shown to the devices that may control it, and wakes it with Lobby", async () => {
    await start();
    const tv = device("Living Room", "tvos");
    const phone = await live(device("Phone", "ios"));
    await connected(tv.id);
    await until(() => phone.sees(tv.id)?.["wakeable"] === true);
    expect(phone.sees(tv.id)).toMatchObject({ online: false, canPlay: false, wakeable: true });

    const woken = await phone.post("/v1/remote/wake", { deviceId: tv.id });
    expect(woken.status).toBe(202);
    expect(woken.json<Record<string, unknown>>()).toMatchObject({ deviceId: tv.id });
    expect(asked().filter((one) => one["op"] === "wake")).toEqual([
      expect.objectContaining({ device: "CC:DD", app: "mt.sil.lobby" }),
    ]);

    // Turned off: no longer shown as wakeable, and refused.
    await ask("PATCH", "/v1/wake", { enabled: false });
    await until(() => phone.sees(tv.id)?.["wakeable"] === false);
    const refused = await phone.post("/v1/remote/wake", { deviceId: tv.id });
    expect(refused.status).toBe(403);
    expect(refused.json<Record<string, unknown>>()["reason"]).toBe("wake_off");
  });

  it("keeps a sleeping TV in Play On while the helper is down, and says why a wake fails", async () => {
    await start();
    const tv = device("Living Room", "tvos");
    const phone = await live(device("Phone", "ios"));
    await connected(tv.id);
    await until(() => phone.sees(tv.id)?.["wakeable"] === true);

    // The helper stops (it starts again by itself in a real server): the TV is still listed, asleep,
    // and still offered as one that wakes. Only the wake itself says the helper is not there.
    await helper?.stop();
    await until(async () => (await ask("GET", "/v1/wake")).body["running"] === false);
    const fresh = await live(device("Tablet", "ios"));
    await until(() => fresh.sees(tv.id) !== null);
    expect(fresh.sees(tv.id)).toMatchObject({ online: false, canPlay: false, wakeable: true });
    expect(phone.sees(tv.id)).toMatchObject({ online: false, wakeable: true });
    const refused = await phone.post("/v1/remote/wake", { deviceId: tv.id });
    expect(refused.status).toBe(503);
    expect(refused.json<Record<string, unknown>>()["reason"]).toBe("wake_unavailable");
    expect(asked().filter((one) => one["op"] === "wake")).toEqual([]);
  });

  it("lists a TV that is linked but not woken by this server only as asleep", async () => {
    await start();
    const tv = device("Living Room", "tvos");
    const phone = await live(device("Phone", "ios"));
    // Never linked: still listed, asleep, but not as one that wakes.
    await until(() => phone.sees(tv.id) !== null);
    expect(phone.sees(tv.id)).toMatchObject({ online: false, canPlay: false, wakeable: false });
  });

  it("is never for devices without control, from away, or for a TV it does not know", async () => {
    await start();
    const tv = device("Living Room", "tvos");
    const other = device("Den", "tvos");
    const phone = device("Phone", "ios");
    await connected(tv.id);

    const profile = await ask("POST", "/v1/profiles", {
      name: "Kid",
      kids: { allowedGroupIds: [], allowedCategoryIds: [], allowedItemIds: [], blockedItemIds: [] },
    });
    const kids = device("Kids iPad", "ios");
    await ask("PATCH", `/v1/devices/${kids.id}`, { kidsProfileId: profile.body["id"] });
    // Kids cannot turn on the TV unless the household says so.
    expect(
      reason(await ask("POST", "/v1/remote/wake", { deviceId: tv.id }, { token: kids.token })),
    ).toEqual(["not_found", "not_wakeable"]);
    const kidsLive = await live(kids);
    await until(() => kidsLive.of("snapshot").length > 0);
    expect(kidsLive.sees(tv.id)).toBeNull();

    expect(
      reason(
        await ask(
          "POST",
          "/v1/remote/wake",
          { deviceId: tv.id },
          { token: phone.token, peer: "203.0.113.9" },
        ),
      ),
    ).toEqual(["forbidden", "home_only"]);
    expect(
      reason(await ask("POST", "/v1/remote/wake", { deviceId: other.id }, { token: phone.token })),
    ).toEqual(["not_found", "not_wakeable"]);
    running?.services.devices.setRemote(phone.id, { allowRemote: false });
    expect(
      reason(await ask("POST", "/v1/remote/wake", { deviceId: tv.id }, { token: phone.token })),
    ).toEqual(["forbidden", "control_off"]);
    expect(asked().filter((one) => one["op"] === "wake")).toEqual([]);
  });

  it("is for kids only when the household lets kids turn on the TV", async () => {
    await start();
    const tv = device("Living Room", "tvos");
    await connected(tv.id);
    const profile = async (name: string): Promise<string> =>
      (
        await ask("POST", "/v1/profiles", {
          name,
          kids: {
            allowedGroupIds: [],
            allowedCategoryIds: [],
            allowedItemIds: [],
            blockedItemIds: [],
          },
        })
      ).body["id"] as string;
    const kid = await profile("Kid");
    const bound = device("Kids iPad", "ios");
    await ask("PATCH", `/v1/devices/${bound.id}`, { kidsProfileId: kid });
    const boundLive = await live(bound);
    // A grown-up's phone in kids mode: the same, by the session it names.
    const phone = device("Phone", "ios");
    const kidsMode = await live(phone);
    expect((await kidsMode.announce({ profileId: kid })).status).toBe(200);
    const wakeFrom = (who: { token: string }, session?: string): Promise<Reply> =>
      ask(
        "POST",
        "/v1/remote/wake",
        { deviceId: tv.id, ...(session === undefined ? {} : { session }) },
        { token: who.token },
      );

    // Off, as it starts: the TV that is off is not there for them, and waking it is refused.
    expect((await ask("GET", "/v1/wake")).body["kids"]).toBe(false);
    await until(() => kidsMode.of("snapshot").length > 0 && boundLive.of("snapshot").length > 0);
    expect(boundLive.sees(tv.id)).toBeNull();
    await until(() => kidsMode.sees(tv.id) === null);
    expect(reason(await wakeFrom(bound))).toEqual(["not_found", "not_wakeable"]);
    expect(reason(await wakeFrom(phone, kidsMode.session))).toEqual(["not_found", "not_wakeable"]);
    expect(reason(await wakeFrom(phone, "no-such-session"))).toEqual(["gone", "session"]);
    expect(asked().filter((one) => one["op"] === "wake")).toEqual([]);

    // On: shown as wakeable, and woken.
    const on = await ask("PATCH", "/v1/wake", { kids: true });
    expect(on.status).toBe(200);
    expect(on.body).toMatchObject({ enabled: true, kids: true });
    await until(() => boundLive.sees(tv.id)?.["wakeable"] === true);
    await until(() => kidsMode.sees(tv.id)?.["wakeable"] === true);
    expect((await wakeFrom(bound)).status).toBe(202);
    expect((await wakeFrom(phone, kidsMode.session)).status).toBe(202);
    expect(asked().filter((one) => one["op"] === "wake").length).toBeGreaterThan(0);

    // Another child's TV is not this child's to wake.
    const sibling = await profile("Sibling");
    await ask("PATCH", `/v1/devices/${tv.id}`, { kidsProfileId: sibling });
    await until(() => boundLive.sees(tv.id) === null);
    expect(reason(await wakeFrom(bound))).toEqual(["not_found", "not_wakeable"]);
    await ask("PATCH", `/v1/devices/${tv.id}`, { kidsProfileId: null });

    // A setting as the others, and off again from there.
    const setting = (
      (await ask("GET", "/v1/settings")).body["settings"] as Record<string, unknown>[]
    ).find((one) => one["key"] === "remote.wake.kids");
    expect(setting).toMatchObject({
      value: true,
      available: true,
      title: "Kids can turn on the TV",
    });
    expect(
      (await ask("PATCH", "/v1/settings", { changes: { "remote.wake.kids": false } })).status,
    ).toBe(200);
    await until(() => boundLive.sees(tv.id) === null);
    expect(reason(await wakeFrom(bound))).toEqual(["not_found", "not_wakeable"]);
    // Waking turned off altogether is off for kids too.
    await ask("PATCH", "/v1/wake", { kids: true, enabled: false });
    expect(reason(await wakeFrom(bound))).toEqual(["not_found", "not_wakeable"]);
  });

  it("is limited, and one wake at a time per TV", async () => {
    await start();
    const tv = device("Living Room", "tvos");
    const phone = device("Phone", "ios");
    await connected(tv.id);
    changeState((all) => {
      all["wakeMs"] = 300;
    });
    const together = await Promise.all(
      [1, 2, 3].map(() =>
        ask("POST", "/v1/remote/wake", { deviceId: tv.id }, { token: phone.token }),
      ),
    );
    expect(together.map((one) => one.status)).toEqual([202, 202, 202]);
    expect(asked().filter((one) => one["op"] === "wake")).toHaveLength(1);
    const statuses: number[] = [];
    for (let i = 0; i < 6; i += 1) {
      statuses.push(
        (await ask("POST", "/v1/remote/wake", { deviceId: tv.id }, { token: phone.token })).status,
      );
    }
    expect(statuses).toContain(429);
    expect(asked().filter((one) => one["op"] === "wake").length).toBeLessThanOrEqual(4);
  });

  it("says why when the TV cannot be woken", async () => {
    await start();
    const tv = device("Living Room", "tvos");
    const phone = device("Phone", "ios");
    await connected(tv.id);
    changeState((all) => {
      all["wakeFails"] = "not_found";
    });
    expect(
      reason(await ask("POST", "/v1/remote/wake", { deviceId: tv.id }, { token: phone.token })),
    ).toEqual(["not_found", "wake_not_found"]);
    changeState((all) => {
      all["wakeFails"] = "not_paired";
    });
    expect(
      reason(await ask("POST", "/v1/remote/wake", { deviceId: tv.id }, { token: phone.token })),
    ).toEqual(["forbidden", "wake_not_paired"]);
  });
});

// What was seen in use: the TV woke, stopped at tvOS's "who is watching", and the
// phone had given up on it by the time Lobby opened. The server now keeps the play (docs/decisions.md, "Wake and Play").
describe("a play kept for a woken TV", () => {
  let balloon: string;
  let scary: string;
  let parent: string;
  let kid: string;

  const profile = async (name: string, kids?: string[]): Promise<string> =>
    (
      await ask("POST", "/v1/profiles", {
        name,
        ...(kids
          ? {
              kids: {
                allowedGroupIds: [],
                allowedCategoryIds: [],
                allowedItemIds: kids,
                blockedItemIds: [],
              },
            }
          : {}),
      })
    ).body["id"] as string;

  async function films(timings: Partial<typeof TIMINGS> = {}, wake: Record<string, unknown> = {}) {
    const folder = join(dir, "Films");
    mkdirSync(folder);
    makeVideo(join(folder, "Balloon (2001).mp4"), { seed: 1 });
    makeVideo(join(folder, "Scary (2002).mp4"), { seed: 2 });
    await start({ pyatv: "/nowhere/bin", ...wake }, { films: folder, timings });
    await running?.services.scanner.scanAll();
    await running?.services.scanner.processQueue();
    const items = running?.services.db.all<{ id: string; title: string }>(
      "select id, title from item",
    );
    balloon = items?.find((one) => one.title === "Balloon")?.id ?? "";
    scary = items?.find((one) => one.title === "Scary")?.id ?? "";
    parent = await profile("Tall one");
    kid = await profile("Small one", [balloon]);
  }

  const playOf = (itemId: string, profileId: string): Record<string, unknown> => ({
    type: "play",
    itemId,
    profileId,
    startMs: 61_000,
    audioTrackId: "0",
    subtitleTrackId: "off",
  });

  const wakeAndPlay = (
    phone: LiveClient,
    tvId: string,
    id: string,
    command: Record<string, unknown>,
  ): ReturnType<LiveClient["post"]> =>
    phone.post("/v1/remote/wake", {
      deviceId: tvId,
      session: phone.session,
      play: { id, command },
    });

  /** The TV's Lobby opening: the live channel, and that it can play. */
  async function opens(tv: { id: string; token: string }): Promise<LiveClient> {
    const made = new LiveClient(tv, port);
    clients.push(made);
    await made.open();
    expect((await made.announce()).status).toBe(200);
    return made;
  }

  const picks = (): number => asked().filter((one) => one["op"] === "pick").length;

  it("sends it the moment Lobby is open there, also when the phone has gone", async () => {
    await films();
    const tv = device("Living Room", "tvos");
    const phone = await live(device("Phone", "ios"));
    await phone.announce({ profileId: parent });
    await connected(tv.id);
    await until(() => phone.sees(tv.id)?.["wakeable"] === true);

    const woken = await wakeAndPlay(phone, tv.id, "play-1", playOf(balloon, parent));
    expect(woken.status).toBe(202);
    const reply = woken.json<{ play: { id: string; expiresAt: number }; lobbyInFront: null }>();
    expect(reply.play.id).toBe("play-1");
    expect(reply.play.expiresAt).toBeGreaterThan(Date.now() + 170_000);
    expect(reply.lobbyInFront).toBeNull();
    expect(running?.remote.held.plays).toBe(1);

    // The phone goes (the app was closed); the TV's Lobby opens later, after a profile was picked.
    phone.cut();
    const screen = await opens(tv);
    expect(screen.of("hello")[0]?.data["pendingPlay"]).toBe(true);
    await screen.asked("play");
    const [sent] = screen.commands();
    expect(sent?.requestId).toBe("play-1");
    expect(sent?.command).toMatchObject({
      type: "play",
      itemId: balloon,
      profileId: parent,
      startMs: 61_000,
      audioTrackId: "0",
      subtitleTrackId: "off",
    });
    expect(running?.remote.held.plays).toBe(0);

    // The phone back: it hears how it went.
    await phone.open(phone.last);
    expect((await screen.result(sent?.commandId ?? "")).status).toBe(204);
    await until(() => phone.outcome("play-1") !== undefined);
    expect(phone.outcome("play-1")).toMatchObject({ status: "done", deviceId: tv.id });
  });

  it("keeps only the latest per TV, and a cancelled one is never sent", async () => {
    await films();
    const tv = device("Living Room", "tvos");
    const phone = await live(device("Phone", "ios"));
    await phone.announce({ profileId: parent });
    await connected(tv.id);

    expect((await wakeAndPlay(phone, tv.id, "first", playOf(balloon, parent))).status).toBe(202);
    expect((await wakeAndPlay(phone, tv.id, "second", playOf(scary, parent))).status).toBe(202);
    await until(() => phone.outcome("first") !== undefined);
    expect(phone.outcome("first")).toMatchObject({ status: "superseded" });
    expect(running?.remote.held.plays).toBe(1);

    // Another device may not take it back.
    const other = await live(device("Tablet", "macos"));
    expect((await other.post(`/v1/remote/wake/${tv.id}/plays/second`, {}, "DELETE")).status).toBe(
      404,
    );
    expect((await phone.post(`/v1/remote/wake/${tv.id}/plays/second`, {}, "DELETE")).status).toBe(
      204,
    );
    expect((await phone.post(`/v1/remote/wake/${tv.id}/plays/second`, {}, "DELETE")).status).toBe(
      404,
    );
    const screen = await opens(tv);
    expect(screen.of("hello")[0]?.data["pendingPlay"]).toBe(false);
    await new Promise((done) => setTimeout(done, 300));
    expect(screen.commands()).toEqual([]);
  });

  it("is over after its time, and the TV gets nothing then", async () => {
    await films({ holdPlayMs: 600 });
    const tv = device("Living Room", "tvos");
    const phone = await live(device("Phone", "ios"));
    await phone.announce({ profileId: parent });
    await connected(tv.id);
    expect((await wakeAndPlay(phone, tv.id, "late", playOf(balloon, parent))).status).toBe(202);
    await until(() => phone.outcome("late") !== undefined);
    expect(phone.outcome("late")).toMatchObject({ status: "expired", code: "expired" });
    expect(running?.remote.held.plays).toBe(0);
    const screen = await opens(tv);
    await new Promise((done) => setTimeout(done, 300));
    expect(screen.commands()).toEqual([]);
  });

  it("checks kids limits before waking, and again when it is sent", async () => {
    await films();
    const tv = device("Living Room", "tvos");
    const phone = await live(device("Phone", "ios"));
    // The phone in kids mode.
    await phone.announce({ profileId: kid });
    await connected(tv.id);
    await ask("PATCH", "/v1/wake", { kids: true });

    // A title the child may not see: refused, and the TV is not woken for it.
    const refused = await wakeAndPlay(phone, tv.id, "scary", playOf(scary, kid));
    expect(refused.status).toBe(403);
    expect(refused.json<Record<string, unknown>>()["reason"]).toBe("title_not_allowed");
    expect(asked().filter((one) => one["op"] === "wake")).toEqual([]);

    // Allowed when asked; no longer by the time the TV opens: not sent.
    expect((await wakeAndPlay(phone, tv.id, "balloon", playOf(balloon, kid))).status).toBe(202);
    const limited = await ask("PATCH", `/v1/profiles/${kid}`, {
      kids: {
        allowedGroupIds: [],
        allowedCategoryIds: [],
        allowedItemIds: [],
        blockedItemIds: [],
      },
    });
    expect(limited.status).toBe(200);
    const screen = await opens(tv);
    await until(() => phone.outcome("balloon") !== undefined);
    expect(phone.outcome("balloon")).toMatchObject({ status: "failed", code: "title_not_allowed" });
    expect(screen.commands()).toEqual([]);
  });

  it("is not sent once kids may not turn on the TV, or the phone was removed", async () => {
    await films();
    const tv = device("Living Room", "tvos");
    const phone = await live(device("Phone", "ios"));
    await phone.announce({ profileId: kid });
    await connected(tv.id);
    await ask("PATCH", "/v1/wake", { kids: true });
    expect((await wakeAndPlay(phone, tv.id, "kids", playOf(balloon, kid))).status).toBe(202);
    await ask("PATCH", "/v1/wake", { kids: false });
    const screen = await opens(tv);
    await until(() => phone.outcome("kids") !== undefined);
    expect(phone.outcome("kids")).toMatchObject({ status: "failed", code: "not_wakeable" });
    screen.cut();

    // A grown-up's phone that is removed before the TV opens.
    const grown = device("Other phone", "ios");
    const other = await live(grown);
    await other.announce({ profileId: parent });
    expect((await wakeAndPlay(other, tv.id, "grown", playOf(balloon, parent))).status).toBe(202);
    running?.services.devices.revoke(grown.id);
    const again = await opens(tv);
    await new Promise((done) => setTimeout(done, 300));
    expect(again.commands()).toEqual([]);
    expect(running?.remote.held.plays).toBe(0);
  });

  it("is not sent to a TV that moved to another household meanwhile", async () => {
    await films();
    const tv = device("Living Room", "tvos");
    const phone = await live(device("Phone", "ios"));
    await phone.announce({ profileId: parent });
    await connected(tv.id);
    expect((await wakeAndPlay(phone, tv.id, "away", playOf(balloon, parent))).status).toBe(202);
    running?.services.db.run(
      "insert into household (id, name, created_at) values ('guests', 'Guests', 0)",
    );
    running?.services.db.run("update device set household_id = 'guests' where id = ?", [tv.id]);
    const screen = await opens(tv);
    await until(() => phone.outcome("away") !== undefined);
    expect(phone.outcome("away")).toMatchObject({ status: "failed", code: "not_found" });
    expect(screen.commands()).toEqual([]);
  });

  it("does not press select when Lobby comes up by itself", async () => {
    await films();
    const tv = device("Living Room", "tvos");
    const phone = await live(device("Phone", "ios"));
    await phone.announce({ profileId: parent });
    await connected(tv.id);
    expect((await wakeAndPlay(phone, tv.id, "direct", playOf(balloon, parent))).status).toBe(202);
    const screen = await opens(tv);
    await screen.asked("play");
    await new Promise((done) => setTimeout(done, TIMINGS.pickAfterMs + 300));
    expect(picks()).toBe(0);
    expect(phone.of("wake")).toEqual([]);
  });

  it("presses select once when Lobby does not come up, and says so", async () => {
    await films();
    const tv = device("Living Room", "tvos");
    const phone = await live(device("Phone", "ios"));
    await phone.announce({ profileId: parent });
    await connected(tv.id);
    expect((await wakeAndPlay(phone, tv.id, "picker", playOf(balloon, parent))).status).toBe(202);
    // The TV shows who is watching; the server presses select, and then Lobby opens.
    await until(() => picks() === 1);
    expect(asked().find((one) => one["op"] === "pick")).toMatchObject({
      device: "CC:DD",
      app: "mt.sil.lobby",
    });
    await until(() => phone.of("wake").length > 0);
    expect(phone.of("wake")[0]?.data).toMatchObject({
      deviceId: tv.id,
      commandId: "picker",
      step: "profile",
    });
    // Asked again meanwhile: the same wake, no second select.
    expect((await wakeAndPlay(phone, tv.id, "picker", playOf(balloon, parent))).status).toBe(202);
    const screen = await opens(tv);
    await screen.asked("play");
    await new Promise((done) => setTimeout(done, 300));
    expect(picks()).toBe(1);
    expect(asked().filter((one) => one["op"] === "wake")).toHaveLength(1);
  });

  it("says when Lobby never came up, and keeps the play for later", async () => {
    await films();
    const tv = device("Living Room", "tvos");
    const phone = await live(device("Phone", "ios"));
    await phone.announce({ profileId: parent });
    await connected(tv.id);
    expect((await wakeAndPlay(phone, tv.id, "never", playOf(balloon, parent))).status).toBe(202);
    await until(() => phone.of("wake").some((one) => one.data["step"] === "not_open"));
    expect(phone.of("wake").map((one) => [one.data["step"], one.data["reason"]])).toEqual([
      ["profile", null],
      ["not_open", "timeout"],
    ]);
    expect(picks()).toBe(1);
    // Someone picks a profile by hand later: the film still starts.
    const screen = await opens(tv);
    await screen.asked("play");
  });

  it("leaves the profile to the people when pickProfile is off", async () => {
    await films({}, { pickProfile: false });
    const tv = device("Living Room", "tvos");
    const phone = await live(device("Phone", "ios"));
    await phone.announce({ profileId: parent });
    await connected(tv.id);
    expect((await wakeAndPlay(phone, tv.id, "hands", playOf(balloon, parent))).status).toBe(202);
    expect(asked().find((one) => one["op"] === "wake")).toMatchObject({ pickProfile: false });
    await until(() => phone.of("wake").some((one) => one.data["step"] === "not_open"));
    expect(picks()).toBe(0);
  });

  it("trusts the helper when pyatv can tell that Lobby is in front", async () => {
    await films();
    changeState((all) => {
      all["front"] = true;
    });
    const tv = device("Living Room", "tvos");
    const phone = await live(device("Phone", "ios"));
    await phone.announce({ profileId: parent });
    await connected(tv.id);
    const woken = await wakeAndPlay(phone, tv.id, "front", playOf(balloon, parent));
    expect(woken.json<Record<string, unknown>>()["lobbyInFront"]).toBe(true);
    await new Promise((done) => setTimeout(done, TIMINGS.pickAfterMs + 300));
    expect(picks()).toBe(0);
  });
});

describe("the helper process", () => {
  it("is started again when it stops, and says what is wrong", async () => {
    tvs({ crash: true });
    const helper = fakeHelper();
    helper.start();
    try {
      const starts = join(state, "starts");
      await until(() => existsSync(starts) && readFileSync(starts, "utf8").length >= 2);
      expect(helper.isUp).toBe(false);
      expect(helper.problem).toMatch(/stopped/);
      await expect(helper.ask("ping")).rejects.toBeInstanceOf(WakeHelperError);
      // Mended: it comes up by itself.
      tvs();
      expect(await helper.whenReady(10_000)).toBe(true);
      expect(await helper.ask("ping")).toEqual({ pyatv: "fake" });
    } finally {
      await helper.stop();
    }
  });

  it("says so when there is no Python", async () => {
    const helper = new WakeHelper({ python: join(dir, "missing", "python3") });
    helper.start();
    try {
      expect(helper.problem).toMatch(/no Python/);
      await expect(helper.ask("ping")).rejects.toMatchObject({ code: "unavailable" });
    } finally {
      await helper.stop();
    }
  });
});

// The real tools/wake.py with a stand-in for pyatv (test/support/fake-pyatv): what it does after
// waking, for each way the TV can answer. Needs only a python3.
const python = ((): string | null => {
  const found = spawnSync("python3", ["-c", "import sys; print(sys.executable)"], {
    encoding: "utf8",
  });
  return found.status === 0 ? found.stdout.trim() : null;
})();
if (!python) console.warn("Skipping tools/wake.py with a stand-in pyatv: no python3.");

describe.skipIf(!python)("tools/wake.py after waking", () => {
  async function helperFor(
    scenario: string,
  ): Promise<{ helper: WakeHelper; calls: () => string[] }> {
    const log = join(dir, `${scenario}.log`);
    const fake = join(dir, `${scenario}.json`);
    writeFileSync(fake, JSON.stringify({ scenario, log }));
    const helper = new WakeHelper({
      python: python ?? "python3",
      script: FAKE_PYATV,
      args: ["--fake", fake, "--storage", join(dir, "pyatv.conf")],
    });
    helper.start();
    expect(await helper.whenReady(10_000)).toBe(true);
    const calls = (): string[] =>
      existsSync(log)
        ? readFileSync(log, "utf8")
            .trim()
            .split("\n")
            .map((line) => (JSON.parse(line) as { call: string }).call)
        : [];
    return { helper, calls };
  }

  const wake = { device: "AA:BB", app: "mt.sil.lobby" };

  it("leaves it when Lobby comes up directly", async () => {
    const { helper, calls } = await helperFor("direct");
    try {
      expect(await helper.ask("wake", wake)).toEqual({
        front: true,
        selected: false,
        reason: null,
      });
      expect(calls()).toEqual(["scan", "connect", "turn_on", "launch_app", "close"]);
    } finally {
      await helper.stop();
    }
  });

  it("presses select once on who is watching, and opens Lobby again", async () => {
    const { helper, calls } = await helperFor("picker");
    try {
      expect(await helper.ask("wake", wake)).toEqual({ front: true, selected: true, reason: null });
      expect(calls()).toEqual([
        "scan",
        "connect",
        "turn_on",
        "launch_app",
        "select",
        "launch_app",
        "close",
      ]);
    } finally {
      await helper.stop();
    }
  });

  it("says timeout when Lobby never comes up, after one select only", async () => {
    const { helper, calls } = await helperFor("never");
    try {
      expect(await helper.ask("wake", wake)).toEqual({
        front: false,
        selected: true,
        reason: "timeout",
      });
      expect(calls().filter((one) => one === "select")).toHaveLength(1);
      // Not allowed to pick: no select at all.
      expect(await helper.ask("wake", { ...wake, pickProfile: false })).toEqual({
        front: false,
        selected: false,
        reason: "timeout",
      });
      expect(calls().filter((one) => one === "select")).toHaveLength(1);
    } finally {
      await helper.stop();
    }
  });

  it("says it cannot tell when pyatv does not know the app in front, and picks when asked", async () => {
    const { helper, calls } = await helperFor("blind");
    try {
      expect(await helper.ask("wake", wake)).toEqual({
        front: null,
        selected: false,
        reason: null,
      });
      expect(calls()).not.toContain("select");
      expect(await helper.ask("pick", wake)).toEqual({ front: null, selected: true, reason: null });
      expect(calls().filter((one) => one === "select")).toHaveLength(1);
    } finally {
      await helper.stop();
    }
  });
});

// The real tools/wake.py with a real pyatv, when there is one: LOBBY_PYATV_BIN, or python3 on PATH
// with pyatv. It never looks on the network: only at this machine's own address.
const pyatvBin = ((): string | null => {
  const given = process.env["LOBBY_PYATV_BIN"];
  if (given && existsSync(join(given, "python3"))) return given;
  const found = spawnSync("python3", ["-c", "import pyatv, sys; print(sys.prefix)"], {
    encoding: "utf8",
  });
  return found.status === 0 ? join(found.stdout.trim(), "bin") : null;
})();
if (!pyatvBin) {
  console.warn(
    "Skipping the real wake helper: no Python with pyatv (set LOBBY_PYATV_BIN to a venv's bin).",
  );
}

describe.skipIf(!pyatvBin)("tools/wake.py with pyatv", () => {
  it("answers, looks nowhere but here, and forgets credentials in a file only its user reads", async () => {
    const storage = join(dir, "pyatv.conf");
    writeFileSync(
      storage,
      JSON.stringify({
        version: 1,
        devices: [
          { info: {}, protocols: { companion: { identifier: "FAKE-ID", credentials: "a:b:c:d" } } },
        ],
      }),
      { mode: 0o644 },
    );
    const helper = new WakeHelper({
      python: join(pyatvBin ?? "", "python3"),
      args: ["--storage", storage],
    });
    helper.start();
    try {
      expect(await helper.whenReady(20_000)).toBe(true);
      expect(helper.version).toMatch(/^\d+\.\d+/);
      expect((await helper.ask("ping"))["pyatv"]).toBe(helper.version);
      // Only this machine is asked: no TV of the household hears it.
      expect(await helper.ask("scan", { timeout: 1, hosts: ["127.0.0.1"] })).toEqual({
        televisions: [],
      });
      await expect(helper.ask("scan", { timeout: 99 })).rejects.toMatchObject({
        code: "bad_request",
      });
      await expect(helper.ask("nothing")).rejects.toMatchObject({ code: "bad_request" });
      await expect(
        helper.ask("pair_pin", { pairing: "unknown", pin: "1234" }),
      ).rejects.toMatchObject({
        code: "timeout",
      });
      expect(await helper.ask("unpair", { device: "OTHER" })).toEqual({ removed: false });
      expect(await helper.ask("unpair", { device: "FAKE-ID" })).toEqual({ removed: true });
      expect(statSync(storage).mode & 0o777).toBe(0o600);
      expect(readFileSync(storage, "utf8")).not.toContain("a:b:c:d");
    } finally {
      await helper.stop();
    }
  }, 60_000);
});
