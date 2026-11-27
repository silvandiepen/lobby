// SPDX-License-Identifier: MPL-2.0
import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { join } from "node:path";
import { serve, type ServerType } from "@hono/node-server";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { Device, Platform } from "../src/auth/devices.ts";
import { Database } from "../src/db/database.ts";
import { migrations } from "../src/db/migrations.ts";
import {
  COMMANDS,
  readAnnouncement,
  readCommandRequest,
  readResult,
} from "../src/remote/messages.ts";
import { REMOTE_LIMITS, REMOTE_RATES, RemoteHub } from "../src/remote/hub.ts";
import { makeVideo } from "./support/media.ts";
import { CAPABILITIES, LiveClient, playing } from "./support/live.ts";
import { OutsideFixture, until } from "./support/outside.ts";

const FIXTURES = new URL("../../../docs/fixtures/remote/", import.meta.url);
const fixture = <T>(name: string): T =>
  JSON.parse(readFileSync(new URL(name, FIXTURES), "utf8")) as T;

let f: OutsideFixture;
let server: ServerType;
let port: number;
let balloon: string;
let scary: string;
let kid: string;
let parent: string;
let clients: LiveClient[] = [];
let tv: LiveClient;
let phone: LiveClient;

function device(name: string, platform: Platform, outside = false): { id: string; token: string } {
  // Not through pairing, which only lets so many devices ask in an hour.
  const done = f.devices.createOutsideViewer(name, platform);
  if (!outside) f.devices.setAllowOutside(done.device.id, false);
  return { id: done.device.id, token: done.token };
}

async function client(
  name: string,
  platform: Platform,
  said: Record<string, unknown> = {},
  outside = false,
): Promise<LiveClient> {
  const made = new LiveClient(device(name, platform, outside), outside ? () => f.connect() : port);
  clients.push(made);
  await made.open();
  expect(made.status).toBe(200);
  expect((await made.announce(said)).status).toBe(200);
  return made;
}

const patch = (id: string, body: unknown): Promise<{ status: number }> =>
  f.atHome(f.manager.token, "PATCH", `/v1/devices/${id}`, body);

const play = (itemId: string, more: Record<string, unknown> = {}): Record<string, unknown> => ({
  type: "play",
  itemId,
  profileId: parent,
  startMs: null,
  ...more,
});

const error = (reply: { json: <T>() => T }): unknown => {
  const body = reply.json<{ error: { code: string }; reason?: string }>();
  return [body.error.code, body.reason ?? null];
};

const player = (who: LiveClient, id: string): Record<string, unknown> | null =>
  (who.sees(id)?.["player"] ?? null) as Record<string, unknown> | null;

/** Every key in it, however deep, without the values. */
function shape(value: unknown): unknown {
  if (Array.isArray(value)) return value.length === 0 ? [] : [shape(value[0])];
  if (typeof value !== "object" || value === null) return "value";
  return Object.fromEntries(
    Object.entries(value)
      .sort(([a], [b]) => (a < b ? -1 : 1))
      .map(([key, one]) => [key, shape(one)]),
  );
}

beforeAll(async () => {
  f = new OutsideFixture();
  await f.start();
  makeVideo(join(f.dir, "Films", "Balloon (2001).mp4"), { seed: 1 });
  makeVideo(join(f.dir, "Films", "Scary (2002).mp4"), { seed: 2 });
  await f.scan();
  balloon = f.items.find((one) => one.title === "Balloon")?.id ?? "";
  scary = f.items.find((one) => one.title === "Scary")?.id ?? "";
  const profile = async (body: unknown): Promise<string> =>
    (await f.atHome(f.manager.token, "POST", "/v1/profiles", body)).json<{ id: string }>().id;
  parent = await profile({ name: "Tall one" });
  kid = await profile({
    name: "Small one",
    kids: {
      allowedGroupIds: [],
      allowedCategoryIds: [],
      allowedItemIds: [balloon],
      blockedItemIds: [],
    },
  });
  await new Promise<void>((done) => {
    server = serve({ fetch: f.home.fetch, hostname: "127.0.0.1", port: 0 }, (info) => {
      port = info.port;
      done();
    });
  });
});

afterAll(async () => {
  for (const one of clients) one.cut();
  await new Promise((done) => {
    server.close(done);
    if ("closeAllConnections" in server) server.closeAllConnections();
  });
  await f.stop();
});

beforeEach(async () => {
  tv = await client("Living room", "tvos");
  phone = await client("Phone", "ios", { profileId: parent });
  await until(() => phone.sees(tv.id)?.["canPlay"] === true);
});

afterEach(() => {
  for (const one of clients) {
    one.cut();
    f.devices.revoke(one.id);
  }
  clients = [];
  f.remote.recheck();
});

describe("the channel", () => {
  it("is refused without a credential and to a device that was removed", async () => {
    const stranger = new LiveClient({ id: "x", token: "x" }, port);
    await stranger.open();
    expect(stranger.status).toBe(401);
    f.devices.revoke(phone.id);
    const again = new LiveClient(phone, port);
    await again.open();
    expect(again.status).toBe(401);
  });

  it("says who is there, and is itself only until the device says what it does", async () => {
    const mac = new LiveClient(device("Mac", "macos"), port);
    clients.push(mac);
    await mac.open();
    const hello = mac.events[0];
    expect(hello?.data).toMatchObject({
      deviceId: mac.id,
      resumed: false,
      heartbeatMs: REMOTE_LIMITS.heartbeatMs,
      silentMs: REMOTE_LIMITS.silentMs,
    });
    await until(() => mac.of("snapshot").length === 1);
    const all = mac.of("snapshot")[0]?.data["devices"] as { id: string; online: boolean }[];
    expect(all.map((one) => one.id)).toEqual([mac.id]);
    expect(all[0]?.online).toBe(false);
    await mac.announce();
    await until(() => mac.sees(tv.id) !== null);
    expect(mac.sees(tv.id)).toMatchObject({
      name: "Living room",
      platform: "tvos",
      online: true,
      foreground: true,
      canPlay: true,
      controllable: false,
      player: null,
    });
    // A phone is nobody's target unless it wants to be, and that is its own business.
    expect(mac.sees(phone.id)).toBeNull();
    await phone.post("/v1/me", { isTarget: true }, "PATCH");
    await until(() => mac.sees(phone.id) !== null);
    await phone.post("/v1/me", { isTarget: null }, "PATCH");
    await until(() => mac.sees(phone.id) === null);
  });

  it("shows a television that is off as one that is not there", async () => {
    const off = device("Bedroom", "tvos");
    f.remote.recheck();
    await until(() => phone.sees(off.id) !== null);
    expect(phone.sees(off.id)).toMatchObject({ online: false, canPlay: false, player: null });
    f.devices.revoke(off.id);
    f.remote.recheck();
    await until(() => phone.sees(off.id) === null);
  });

  it("shows a device that fell silent as gone, and ends its channel", async () => {
    await until(() => phone.of("heartbeat").length > 0);
    f.clock.ahead += 6_000;
    await phone.announce();
    f.clock.ahead += 7_000;
    await until(() => phone.sees(tv.id)?.["online"] === false);
    await until(() => tv.closed);
    expect(phone.closed).toBe(false);
    expect(REMOTE_LIMITS.silentMs + 1_000).toBeLessThan(15_000);
    expect((await tv.announce()).status).toBe(410);
    await tv.open(tv.last);
    await tv.announce();
    await until(() => phone.sees(tv.id)?.["online"] === true);
  });

  it("is not shown as gone by a short break, and a longer one is", async () => {
    tv.cut();
    await until(() => phone.sees(tv.id)?.["canPlay"] === false);
    expect(phone.sees(tv.id)?.["online"]).toBe(true);
    f.clock.ahead += REMOTE_LIMITS.graceMs + 1;
    await until(() => phone.sees(tv.id)?.["online"] === false);
  });

  it("goes on where it broke, each event once", async () => {
    await tv.announce({ player: playing(balloon) });
    await until(() => player(phone, tv.id) !== null);
    const last = phone.last;
    const before = phone.events.length;
    phone.cut();
    await tv.announce({ player: playing(scary) });
    await tv.announce({ player: playing(scary, { status: "paused" }) });
    await phone.open(last);
    await until(() => player(phone, tv.id)?.["status"] === "paused");
    const after = phone.events.slice(before);
    expect(after[0]?.data["resumed"]).toBe(true);
    expect(after.filter((one) => one.event === "snapshot")).toEqual([]);
    // Only the newest state of a device is worth keeping.
    const states = after.filter((one) => one.event === "device" && one.id !== null);
    expect(new Set(states.map((one) => one.id)).size).toBe(states.length);
    expect(
      states.filter((one) => (one.data["device"] as { id: string }).id === tv.id),
    ).toHaveLength(1);
    const numbers = phone.events.flatMap((one) =>
      one.id === null ? [] : [Number(one.id.split(".")[1])],
    );
    expect(numbers).toEqual([...numbers].sort((a, b) => a - b));
  });

  it("starts again with a snapshot for an id it does not know", async () => {
    for (const last of ["zzzzzzzz.3", "nonsense", `${phone.last?.split(".")[0] ?? ""}.99999`]) {
      phone.cut();
      const before = phone.events.length;
      await phone.open(last);
      await until(() => phone.events.slice(before).some((one) => one.event === "snapshot"));
      expect(phone.events[before]?.data["resumed"]).toBe(false);
    }
  });

  it("forgets a device that stays away, with what was kept for it", async () => {
    const last = phone.last;
    phone.cut();
    tv.cut();
    // A step at a time: it counts from when the server noticed.
    await until(() => {
      f.clock.ahead += 1_000;
      return f.remote.held.sessions === 0;
    });
    expect(f.remote.held).toMatchObject({ events: 0, bytes: 0, pending: 0 });
    await phone.open(last);
    await until(() => phone.of("snapshot").length === 2);
  });

  it("takes the newest connection of a session", async () => {
    const again = new LiveClient(phone, port);
    Object.assign(again, { session: phone.session });
    clients.push(again);
    await again.open(phone.last);
    expect(again.events[0]?.data["resumed"]).toBe(true);
    await until(() => phone.closed);
  });

  it("starts anew after the server does: devices say again what they do", async () => {
    await tv.announce({ player: playing(balloon) });
    const other = new RemoteHub({ db: f.db, devices: f.devices });
    const stream = other.open(phone.id, phone.session, false, phone.last);
    const { value } = await stream.getReader().read();
    expect(new TextDecoder().decode(value)).toContain('"resumed":false');
    expect(() =>
      other.announce(tv.id, tv.session, false, readAnnouncement(fixture("announce-beat.json"), 0)),
    ).toThrow("Open the live channel again");
    other.stop();
  });

  it("is cut when the device is removed, within a second or so", async () => {
    const at = Date.now();
    expect((await f.atHome(f.manager.token, "DELETE", `/v1/devices/${tv.id}`)).status).toBe(204);
    await until(() => tv.closed);
    expect(Date.now() - at).toBeLessThan(2_000);
    await until(() => phone.sees(tv.id) === null);
    const gone = await phone.command(tv.id, { type: "pause" });
    expect([gone.status, error(gone)]).toEqual([404, ["not_found", null]]);
    // Also when it is done elsewhere, as on the command line.
    f.devices.revoke(phone.id);
    await until(() => phone.closed);
  });

  it("ends when the server stops", async () => {
    const other = new RemoteHub({ db: f.db, devices: f.devices });
    const reader = other.open(phone.id, "s", false, null).getReader();
    other.stop();
    let done = false;
    while (!done) done = (await reader.read()).done;
    expect(() => other.open(phone.id, "s", false, null)).toThrow("stopping");
  });
});

describe("what plays", () => {
  it("is told with the place and the server's time", async () => {
    await tv.announce({ player: playing(balloon, { ageMs: 2_000 }) });
    await until(() => player(phone, tv.id) !== null);
    const seen = player(phone, tv.id);
    expect(seen).toMatchObject({
      redacted: false,
      itemId: balloon,
      positionMs: 60_000,
      durationMs: 5_400_000,
      audioTrackId: "0",
    });
    const event = phone.of("device").at(-1)?.data;
    // The device's own clock plays no part in it.
    const behind = Number(event?.["serverTime"]) - Number(seen?.["at"]);
    expect(behind).toBeGreaterThanOrEqual(2_000);
    expect(behind).toBeLessThan(4_000);
    expect(phone.sees(tv.id)?.["controllable"]).toBe(true);
  });

  it("is not repeated while it goes on as expected, and a jump is told at once", async () => {
    await tv.announce({ player: playing(balloon) });
    await until(() => player(phone, tv.id) !== null);
    const count = (): number =>
      phone.of("device").filter((one) => (one.data["device"] as Device).id === tv.id).length;
    const before = count();
    f.clock.ahead += 3_000;
    await tv.announce({ player: playing(balloon, { positionMs: 63_000 }) });
    await tv.announce();
    await new Promise((done) => setTimeout(done, 300));
    expect(count()).toBe(before);
    await tv.announce({ player: playing(balloon, { positionMs: 600_000 }) });
    await until(() => count() === before + 1);
    await tv.announce({ player: null });
    await until(() => player(phone, tv.id) === null);
  });

  it("does not go back to what an overtaken message said", async () => {
    await tv.announce({ player: playing(balloon, { status: "paused" }) });
    await tv.post(`/v1/live/${tv.session}`, {
      order: 1,
      foreground: false,
      canPlay: false,
      profileId: null,
      capabilities: [],
      player: null,
    });
    await until(() => player(phone, tv.id)?.["status"] === "paused");
    expect(phone.sees(tv.id)?.["foreground"]).toBe(true);
  });

  it("is of the window that plays, when Lobby is open more than once on a device", async () => {
    const second = new LiveClient(tv, port);
    clients.push(second);
    await second.open();
    await second.announce({ player: playing(scary) });
    await until(() => player(phone, tv.id)?.["itemId"] === scary);
    await tv.announce();
    const reply = await phone.command(tv.id, { type: "pause" });
    expect(reply.status).toBe(202);
    await second.asked("pause");
    expect(tv.commands()).toEqual([]);
    second.cut();
    clients.pop();
  });

  it("refuses what is malformed or too much", async () => {
    const bad: unknown[] = [
      { foreground: "yes" },
      { capabilities: "play" },
      { player: [] },
      { player: playing("../x") },
      { player: playing(balloon, { status: "dancing" }) },
      { player: playing(balloon, { positionMs: -1 }) },
      { player: playing(balloon, { volume: 2 }) },
      { player: playing(balloon, { queue: Array<string>(51).fill("x") }) },
      { player: playing(balloon, { audioTracks: [{ id: "a b", label: "x" }] }) },
    ];
    for (const one of bad) {
      const reply = await tv.announce(one as Record<string, unknown>);
      expect([one, reply.status]).toEqual([one, 400]);
      Object.assign(tv, { said: {} });
    }
    const long = await tv.announce({ player: playing("x".repeat(40_000)) });
    expect(long.status).toBe(400);
    expect((await tv.post("/v1/live/unknown", {})).status).toBe(400);
  });
});

describe("a command", () => {
  it("arrives, is answered, and the answer gets back, in less than a tenth of a second", async () => {
    await tv.announce({ player: playing(balloon) });
    await until(() => player(phone, tv.id) !== null);
    const times: number[] = [];
    for (let round = 0; round < 11; round += 1) {
      const id = randomUUID();
      const at = performance.now();
      const sent = phone.command(tv.id, { type: "skip", deltaMs: 10_000 }, id);
      while (!tv.commands().some((one) => one.requestId === id)) {
        await new Promise((done) => setImmediate(done));
      }
      times.push(performance.now() - at);
      const reply = await sent;
      expect(reply.status).toBe(202);
      const found = tv.of("command").find((one) => one.data["requestId"] === id);
      expect(found?.data).toMatchObject({
        from: { deviceId: phone.id, name: "Phone" },
        handoverId: null,
        command: { type: "skip", deltaMs: 10_000 },
      });
      expect(Number(found?.data["expiresInMs"])).toBeGreaterThan(9_000);
      await tv.result(String(found?.data["commandId"]));
      await until(() => phone.outcome(id) !== undefined);
      expect(phone.outcome(id)).toMatchObject({ deviceId: tv.id, status: "done", code: null });
    }
    const middle = times.sort((a, b) => a - b)[5] ?? Infinity;
    console.info(`command to television: ${middle.toFixed(1)} ms`);
    expect(middle).toBeLessThan(100);
  });

  it("plays a title, and a failure is told with its reason", async () => {
    const id = randomUUID();
    expect((await phone.command(tv.id, play(balloon, { startMs: 5_000 }), id)).status).toBe(202);
    const asked = await tv.asked("play");
    expect(tv.commands()[0]?.command).toEqual({
      type: "play",
      itemId: balloon,
      assetId: null,
      profileId: parent,
      startMs: 5_000,
      paused: false,
      rate: 1,
      audioTrackId: null,
      subtitleTrackId: null,
      queue: [],
    });
    await tv.result(asked, { status: "failed", code: "cannot_play" });
    await until(() => phone.outcome(id) !== undefined);
    expect(phone.outcome(id)).toMatchObject({ status: "failed", code: "cannot_play" });
    // Said again, or otherwise: it was settled.
    expect((await tv.result(asked)).status).toBe(204);
    expect(phone.of("result")).toHaveLength(1);
  });

  it("keeps the order it was sent in", async () => {
    await tv.announce({ player: playing(balloon) });
    for (let n = 1; n <= 20; n += 1) {
      const type = n % 3 === 0 ? "pause" : "seek";
      await phone.command(tv.id, { type, positionMs: n * 1_000 }, `r${String(n)}`);
    }
    await until(() => tv.commands().length === 20);
    expect(tv.commands().map((one) => one.requestId)).toEqual(
      Array.from({ length: 20 }, (_, index) => `r${String(index + 1)}`),
    );
    // Of those of a kind the last one counts.
    await until(() => phone.of("result").length === 18);
    expect(phone.of("result").every((one) => one.data["status"] === "superseded")).toBe(true);
  });

  it("is done once, however often it is sent", async () => {
    await tv.announce({ player: playing(balloon) });
    const first = await phone.command(tv.id, { type: "pause" }, "again");
    const second = await phone.command(tv.id, { type: "pause" }, "again");
    expect(second.status).toBe(202);
    expect(second.json()).toEqual(first.json());
    const other = await phone.command(tv.id, { type: "stop" }, "again");
    expect([other.status, error(other)]).toEqual([409, ["conflict", "used_id"]]);
    await tv.asked("pause");
    expect(tv.commands()).toHaveLength(1);
    // Another device may use the same id.
    const mac = await client("Mac", "macos");
    expect((await mac.command(tv.id, { type: "stop" }, "again")).status).toBe(202);
  });

  it("expires after ten seconds, and is then not done", async () => {
    await tv.announce({ player: playing(balloon) });
    await phone.command(tv.id, { type: "pause" }, "late");
    const asked = await tv.asked("pause");
    await Promise.all([tv.announce(), phone.announce()]);
    f.clock.ahead += REMOTE_LIMITS.expiryMs;
    await until(() => phone.outcome("late") !== undefined);
    expect(phone.outcome("late")).toMatchObject({ status: "expired", code: "expired" });
    await tv.result(asked);
    expect(phone.of("result")).toHaveLength(1);
  });

  it("that was under way when the connection broke arrives, if there is time left", async () => {
    await tv.announce({ player: playing(balloon) });
    const last = tv.last;
    await phone.command(tv.id, { type: "pause" }, "soon");
    await tv.asked("pause");
    tv.events.length = 0;
    tv.cut();
    await tv.open(last);
    const asked = await tv.asked("pause");
    await tv.result(asked);
    await until(() => phone.outcome("soon")?.["status"] === "done");

    await phone.command(tv.id, { type: "resume" }, "not");
    const before = tv.last;
    await tv.asked("resume");
    tv.events.length = 0;
    tv.cut();
    f.clock.ahead += REMOTE_LIMITS.expiryMs + 1;
    await phone.announce();
    await until(() => phone.outcome("not") !== undefined);
    await tv.open(before);
    await new Promise((done) => setTimeout(done, 200));
    expect(tv.commands()).toEqual([]);
  });

  it("is never kept for a device that is not there", async () => {
    await tv.announce({ player: playing(balloon) });
    tv.cut();
    await until(() => phone.sees(tv.id)?.["controllable"] === false);
    const reply = await phone.command(tv.id, { type: "pause" });
    expect([reply.status, error(reply)]).toEqual([503, ["unavailable", "device_offline"]]);
    const start = await phone.command(tv.id, play(balloon));
    expect(error(start)).toEqual(["unavailable", "device_offline"]);
    tv.events.length = 0;
    await tv.open();
    await tv.announce();
    expect(tv.commands()).toEqual([]);
    expect(f.remote.held.pending).toBe(0);
  });

  it("is refused where it makes no sense", async () => {
    const refused = async (command: Record<string, unknown>): Promise<unknown> => {
      const reply = await phone.command(tv.id, command);
      return [reply.status, error(reply)];
    };
    expect(await refused({ type: "pause" })).toEqual([409, ["conflict", "nothing_playing"]]);
    expect(await refused(play("unknown"))).toEqual([404, ["not_found", null]]);
    expect(await refused(play(balloon, { profileId: "x" }))).toEqual([404, ["not_found", null]]);
    expect(await refused(play(balloon, { assetId: "x" }))).toEqual([404, ["not_found", null]]);
    expect(await refused({ type: "dance" })).toEqual([400, ["invalid_request", null]]);
    expect(await refused({ type: "seek", positionMs: -1 })).toEqual([
      400,
      ["invalid_request", null],
    ]);
    await tv.announce({ player: playing(balloon), capabilities: ["play", "pause", "unknown"] });
    expect(await refused({ type: "setVolume", volume: 1 })).toEqual([
      409,
      ["conflict", "unsupported"],
    ]);
    await tv.announce({ foreground: false });
    expect(await refused(play(balloon))).toEqual([503, ["unavailable", "cannot_play"]]);
  });

  it("is not for a device that a manager kept out, in either way", async () => {
    await patch(tv.id, { allowRemote: false });
    await until(() => phone.sees(tv.id) === null);
    expect((await phone.command(tv.id, play(balloon))).status).toBe(404);
    await patch(tv.id, { allowRemote: true });
    await until(() => phone.sees(tv.id) !== null);
    await patch(phone.id, { allowRemote: false });
    await until(() => phone.sees(tv.id) === null);
    const reply = await phone.command(tv.id, play(balloon));
    expect([reply.status, error(reply)]).toEqual([403, ["forbidden", "control_off"]]);
    expect((await patch(phone.id, { allowRemote: 1 })).status).toBe(400);
    expect((await patch(phone.id, {})).status).toBe(400);
    expect(
      (await phone.post(`/v1/devices/${phone.id}`, { allowRemote: true }, "PATCH")).status,
    ).toBe(403);
  });

  it("is limited in how often, per sender", async () => {
    await tv.announce({ player: playing(balloon) });
    const replies = [];
    for (let n = 0; n < REMOTE_RATES.commands.burst + 10; n += 1) {
      replies.push(await phone.command(tv.id, { type: "setVolume", volume: n / 100 }));
    }
    const limited = replies.filter((one) => one.status === 429);
    expect(limited.length).toBeGreaterThan(0);
    expect(Number(limited[0]?.headers["retry-after"])).toBeGreaterThan(0);
    // Superseded ones are not waited for.
    expect(f.remote.held.pending).toBeLessThanOrEqual(1);
  });
});

describe("handing over", () => {
  it("moves what plays, and the first ends only when the second plays", async () => {
    await tv.announce({
      player: playing(balloon, { profileId: parent, audioTrackId: "0", rate: 1.5 }),
    });
    await until(() => player(phone, tv.id) !== null);
    const id = randomUUID();
    const sent = await phone.command(tv.id, { type: "handover", toDeviceId: phone.id }, id);
    expect(sent.status).toBe(202);
    const held = await tv.asked("yield");
    expect(phone.commands()).toEqual([]);
    const busy = await phone.command(tv.id, { type: "pause" });
    expect(error(busy)).toEqual(["conflict", "busy"]);
    await tv.result(held, {
      player: playing(balloon, {
        profileId: parent,
        status: "paused",
        positionMs: 61_234,
        rate: 1.5,
      }),
    });
    const started = await phone.asked("play");
    expect(phone.commands()[0]?.command).toMatchObject({
      itemId: balloon,
      profileId: parent,
      startMs: 61_234,
      paused: false,
      rate: 1.5,
      subtitleTrackId: "off",
    });
    expect(tv.commands().map((one) => one.command["type"])).toEqual(["yield"]);
    await phone.result(started);
    await tv.asked("stop");
    await until(() => phone.outcome(id)?.["status"] === "done");
    expect(tv.commands().every((one) => one.requestId === id)).toBe(true);
  });

  it("goes back when the second cannot", async () => {
    await phone.announce({ player: playing(balloon, { profileId: parent }) });
    const id = randomUUID();
    expect(
      (await phone.command(phone.id, { type: "handover", toDeviceId: tv.id }, id)).status,
    ).toBe(202);
    await phone.result(await phone.asked("yield"));
    await tv.result(await tv.asked("play"), { status: "failed", code: "cannot_play" });
    await phone.asked("resume");
    await until(() => phone.outcome(id)?.["status"] === "failed");
    expect(phone.outcome(id)?.["code"]).toBe("cannot_play");
    // Over: the next one may begin.
    const next = await phone.command(phone.id, { type: "handover", toDeviceId: tv.id });
    expect(next.status).toBe(202);
  });

  it("goes back, and stops the second, when the second does not answer", async () => {
    await phone.announce({ player: playing(balloon, { profileId: parent }) });
    await phone.command(phone.id, { type: "handover", toDeviceId: tv.id }, "slow");
    await phone.result(await phone.asked("yield"));
    await tv.asked("play");
    await Promise.all([tv.announce(), phone.announce()]);
    f.clock.ahead += REMOTE_LIMITS.expiryMs;
    await tv.asked("stop");
    await phone.asked("resume");
    await until(() => phone.outcome("slow")?.["status"] === "expired");
  });

  it("stays paused when it was, and goes back when the second goes away", async () => {
    await phone.announce({ player: playing(balloon, { profileId: parent, status: "paused" }) });
    await phone.command(phone.id, { type: "handover", toDeviceId: tv.id }, "away");
    await phone.result(await phone.asked("yield"));
    await tv.asked("play");
    expect(tv.commands()[0]?.command["paused"]).toBe(true);
    f.devices.revoke(tv.id);
    await until(() => phone.outcome("away")?.["code"] === "device_offline");
    expect(phone.commands().map((one) => one.command["type"])).toEqual(["yield"]);
  });

  it("is refused to itself, with nothing playing, and to a device that is not there", async () => {
    const to = async (toDeviceId: string): Promise<unknown> => {
      const reply = await phone.command(tv.id, { type: "handover", toDeviceId });
      return [reply.status, error(reply)];
    };
    expect(await to(phone.id)).toEqual([409, ["conflict", "nothing_playing"]]);
    await tv.announce({ player: playing(balloon, { profileId: parent }) });
    expect(await to(tv.id)).toEqual([400, ["invalid_request", null]]);
    expect(await to(device("Bedroom", "tvos").id)).toEqual([
      503,
      ["unavailable", "device_offline"],
    ]);
    expect(await to("unknown")).toEqual([404, ["not_found", null]]);
  });
});

describe("children", () => {
  async function bound(): Promise<LiveClient> {
    const child = await client("Tablet", "tvos");
    await patch(child.id, { kidsProfileId: kid });
    await until(() => child.closed);
    await child.open(child.last);
    expect(child.events.findLast((one) => one.event === "hello")?.data["resumed"]).toBe(false);
    await child.announce({ profileId: kid });
    await until(() => phone.sees(child.id)?.["isKids"] === true);
    return child;
  }

  it("a child's device sees the TVs that are open for it, and nothing of what others watch", async () => {
    await tv.announce({ player: playing(scary, { profileId: parent }) });
    // Off, and so not there for a child; and another child's TV plays nothing for this one.
    device("Bedroom", "tvos");
    const other = await client("Other room", "tvos");
    const sibling = (
      await f.atHome(f.manager.token, "POST", "/v1/profiles", {
        name: "Other small one",
        kids: {
          allowedGroupIds: [],
          allowedCategoryIds: [],
          allowedItemIds: [],
          blockedItemIds: [],
        },
      })
    ).json<{ id: string }>().id;
    await patch(other.id, { kidsProfileId: sibling });
    const child = await bound();
    await child.announce({ player: playing(balloon, { profileId: kid }) });
    await until(() => child.sees(tv.id) !== null);
    expect(child.sees(tv.id)).toMatchObject({
      online: true,
      canPlay: true,
      controllable: false,
      wakeable: false,
      player: { redacted: true, status: "playing" },
    });
    const after = child.events.findLastIndex((one) => one.event === "hello");
    const said = JSON.stringify(child.events.slice(after));
    expect(said).not.toContain(scary);
    expect(said).not.toContain(other.id);
    expect(said).not.toContain("Bedroom");
    await until(() => player(child, child.id)?.["itemId"] === balloon);
    // Somebody else's film is not a child's to stop, nor to play over.
    for (const command of [{ type: "pause" }, play(balloon, { profileId: kid })]) {
      expect(error(await child.command(tv.id, command))).toEqual([
        "forbidden",
        "title_not_allowed",
      ]);
    }
    expect(error(await child.command(other.id, play(balloon, { profileId: kid })))).toEqual([
      "not_found",
      null,
    ]);
    expect((await child.post("/v1/me", { isTarget: false }, "PATCH")).status).toBe(404);
    // A manager's switch: then it sees itself only, as before.
    await patch(child.id, { allowRemote: false });
    await until(() => child.sees(tv.id) === null);
    expect(error(await child.command(tv.id, { type: "pause" }))).toEqual([
      "forbidden",
      "control_off",
    ]);
  });

  it("a child plays on a TV as itself, only what it may see, also on a grown-up's TV", async () => {
    const child = await bound();
    await until(() => child.sees(tv.id)?.["canPlay"] === true);
    const no = ["forbidden", "title_not_allowed"];
    expect(error(await child.command(tv.id, play(scary, { profileId: kid })))).toEqual(no);
    // Not in somebody else's name, not even for a title the child may see.
    expect(error(await child.command(tv.id, play(balloon, { profileId: parent })))).toEqual(no);
    expect(tv.commands()).toEqual([]);
    const fine = await child.command(
      tv.id,
      play(balloon, { profileId: kid, queue: [scary, balloon] }),
    );
    expect(fine.status).toBe(202);
    await tv.asked("play");
    expect(tv.commands()[0]?.command).toMatchObject({
      itemId: balloon,
      profileId: kid,
      queue: [balloon],
    });
  });

  it("a child controls only what plays as itself", async () => {
    const child = await bound();
    await tv.announce({ player: playing(balloon, { profileId: kid, nextItemId: scary }) });
    await until(() => child.sees(tv.id)?.["controllable"] === true);
    expect(player(child, tv.id)).toMatchObject({ itemId: balloon, nextItemId: null });
    for (const command of [
      { type: "pause" },
      { type: "seek", positionMs: 1_000 },
      { type: "skip", deltaMs: -10_000 },
      { type: "stop" },
    ]) {
      expect((await child.command(tv.id, command)).status).toBe(202);
    }
    expect(error(await child.command(tv.id, { type: "next" }))).toEqual([
      "forbidden",
      "title_not_allowed",
    ]);
    // A grown-up takes over the TV, with the same title: no longer the child's to control.
    await tv.announce({ player: playing(balloon, { profileId: parent }) });
    await until(() => child.sees(tv.id)?.["controllable"] === false);
    expect(player(child, tv.id)).toEqual({ redacted: true, status: "playing" });
    for (const command of [{ type: "pause" }, { type: "stop" }]) {
      expect(error(await child.command(tv.id, command))).toEqual([
        "forbidden",
        "title_not_allowed",
      ]);
    }
    // Nor brought over to the child's device.
    expect(error(await child.command(tv.id, { type: "handover", toDeviceId: child.id }))).toEqual([
      "forbidden",
      "title_not_allowed",
    ]);
  });

  it("shows Up Next to the controller, as much as the viewer may see, and takes its answer", async () => {
    const child = await bound();
    const upNext = {
      kind: "suggestions",
      itemId: scary,
      countdownMs: 8_000,
      suggestions: [scary, balloon],
    };
    await tv.announce({ player: playing(balloon, { profileId: kid, upNext }) });
    await until(() => child.sees(tv.id)?.["controllable"] === true);
    // The child sees only what it may: the countdown's title is not one of those.
    expect(player(child, tv.id)?.["upNext"]).toEqual({
      ...upNext,
      itemId: null,
      suggestions: [balloon],
    });
    expect(error(await child.command(tv.id, { type: "upNext", action: "playNow" }))).toEqual([
      "forbidden",
      "title_not_allowed",
    ]);
    for (const action of ["cancel", "continue"]) {
      expect((await child.command(tv.id, { type: "upNext", action })).status).toBe(202);
    }
    await tv.announce({
      player: playing(balloon, { profileId: kid, upNext: { ...upNext, itemId: balloon } }),
    });
    await until(() => player(child, tv.id)?.["upNext"] !== undefined);
    await until(
      () => (player(child, tv.id)?.["upNext"] as { itemId: string | null }).itemId === balloon,
    );
    expect((await child.command(tv.id, { type: "upNext", action: "playNow" })).status).toBe(202);
    await tv.asked("upNext");
    // A grown-up's phone sees all of it.
    await until(() => player(phone, tv.id)?.["upNext"] !== undefined);
    expect(player(phone, tv.id)?.["upNext"]).toMatchObject({ suggestions: [scary, balloon] });
    // What is not an answer, or not a kind, is refused.
    expect((await child.command(tv.id, { type: "upNext", action: "later" })).status).toBe(400);
    const wrong = await tv.announce({
      player: playing(balloon, { upNext: { ...upNext, kind: "maybe" } }),
    });
    expect(wrong.status).toBe(400);
    const many = Array.from({ length: 21 }, () => balloon);
    const tooMany = await tv.announce({
      player: playing(balloon, { upNext: { ...upNext, suggestions: many } }),
    });
    expect(tooMany.status).toBe(400);
  });

  it("a child moves what it plays to a TV, and back", async () => {
    const child = await bound();
    await child.announce({ player: playing(balloon, { profileId: kid }) });
    await until(() => child.sees(tv.id)?.["canPlay"] === true);
    const sent = await child.command(child.id, { type: "handover", toDeviceId: tv.id });
    expect(sent.status).toBe(202);
    await child.result(await child.asked("yield"), {
      player: playing(balloon, { profileId: kid, status: "paused" }),
    });
    await tv.asked("play");
    expect(tv.commands().at(-1)?.command).toMatchObject({ itemId: balloon, profileId: kid });
  });

  it("only what the child may see is started on it, as that child", async () => {
    const child = await bound();
    const refused = async (command: Record<string, unknown>): Promise<unknown> => {
      const reply = await phone.command(child.id, command);
      return [reply.status, error(reply)];
    };
    const no = [403, ["forbidden", "title_not_allowed"]];
    expect(await refused(play(scary, { profileId: kid }))).toEqual(no);
    expect(await refused(play(balloon, { profileId: parent }))).toEqual(no);
    const fine = await phone.command(
      child.id,
      play(balloon, { profileId: kid, queue: [scary, balloon] }),
    );
    expect(fine.status).toBe(202);
    await child.asked("play");
    // Nothing else comes along in what follows.
    expect(child.commands()[0]?.command["queue"]).toEqual([balloon]);
    await child.announce({ player: playing(balloon, { profileId: kid, nextItemId: scary }) });
    await until(() => player(phone, child.id) !== null);
    expect((await phone.command(child.id, { type: "pause" })).status).toBe(202);
    expect((await phone.command(child.id, { type: "stop" })).status).toBe(202);
    expect(await refused({ type: "next" })).toEqual(no);
    // Nor by handing over.
    await tv.announce({ player: playing(scary, { profileId: kid }) });
    const moved = await phone.command(tv.id, { type: "handover", toDeviceId: child.id });
    expect(error(moved)).toEqual(["forbidden", "title_not_allowed"]);
  });

  it("the limits of a child's viewer count on any device", async () => {
    const reply = await phone.command(tv.id, play(scary, { profileId: kid }));
    expect(error(reply)).toEqual(["forbidden", "title_not_allowed"]);
    expect((await phone.command(tv.id, play(balloon, { profileId: kid }))).status).toBe(202);
  });

  it("a title the viewer may not see is only 'playing' to them, with nothing to tell it by", async () => {
    await phone.announce({ profileId: kid });
    await tv.announce({ player: playing(scary, { queue: [scary], nextItemId: scary }) });
    await until(() => player(phone, tv.id) !== null);
    expect(player(phone, tv.id)).toEqual({ redacted: true, status: "playing" });
    expect(phone.sees(tv.id)?.["controllable"]).toBe(false);
    expect(JSON.stringify(phone.events)).not.toContain(scary);
    for (const command of [{ type: "pause" }, play(balloon, { profileId: kid })]) {
      expect(error(await phone.command(tv.id, command))).toEqual([
        "forbidden",
        "title_not_allowed",
      ]);
    }
    await tv.announce({ player: playing(balloon, { queue: [scary, balloon], nextItemId: scary }) });
    // A child does not start things in somebody else's name.
    expect(error(await phone.command(tv.id, play(balloon)))).toEqual([
      "forbidden",
      "title_not_allowed",
    ]);
    // Not even a title the child may see, while it plays as somebody else.
    expect(player(phone, tv.id)).toEqual({ redacted: true, status: "playing" });
    expect(error(await phone.command(tv.id, { type: "pause" }))).toEqual([
      "forbidden",
      "title_not_allowed",
    ]);
    await tv.announce({
      player: playing(balloon, { profileId: kid, queue: [scary, balloon], nextItemId: scary }),
    });
    await until(() => player(phone, tv.id)?.["itemId"] === balloon);
    expect(player(phone, tv.id)).toMatchObject({ queue: [balloon], nextItemId: null });
    expect((await phone.command(tv.id, { type: "pause" })).status).toBe(202);
    await phone.announce({ profileId: parent });
    await until(() => (player(phone, tv.id)?.["queue"] as string[]).length === 2);
  });

  it("a title that becomes forbidden disappears from what is seen and kept", async () => {
    await phone.announce({ profileId: kid });
    await tv.announce({ player: playing(balloon, { profileId: kid }) });
    await until(() => player(phone, tv.id)?.["itemId"] === balloon);
    const last = phone.last;
    phone.cut();
    const limits = (allowedItemIds: string[]): Promise<unknown> =>
      f.atHome(f.manager.token, "PATCH", `/v1/profiles/${kid}`, {
        kids: { allowedGroupIds: [], allowedCategoryIds: [], allowedItemIds, blockedItemIds: [] },
      });
    await limits([]);
    f.remote.recheck();
    phone.events.length = 0;
    await phone.open(last);
    await until(() => player(phone, tv.id)?.["redacted"] === true);
    expect(JSON.stringify(phone.events)).not.toContain(balloon);
    await limits([balloon]);
  });

  it("what is no film of the library is 'playing' to everyone", async () => {
    await tv.announce({ player: playing("not-in-the-library") });
    await until(() => player(phone, tv.id) !== null);
    expect(player(phone, tv.id)).toEqual({ redacted: true, status: "playing" });
    // A grown-up can still stop it.
    expect((await phone.command(tv.id, { type: "stop" })).status).toBe(202);
  });
});

describe("outside", () => {
  it("a device that is not let in gets nothing", async () => {
    const away = new LiveClient(device("Away", "ios"), () => f.connect());
    await away.open();
    expect(away.status).toBe(404);
  });

  it("a device sees itself only, until a manager says otherwise", async () => {
    await tv.announce({ player: playing(balloon) });
    const away = await client("Away", "ios", {}, true);
    await away.announce({ player: playing(balloon) });
    await until(() => player(away, away.id) !== null);
    expect(away.sees(tv.id)).toBeNull();
    expect(error(await away.command(tv.id, { type: "pause" }))).toEqual([
      "forbidden",
      "control_off",
    ]);
    await patch(away.id, { remoteOutside: true });
    await until(() => player(away, tv.id)?.["itemId"] === balloon);
    const id = randomUUID();
    expect((await away.command(tv.id, { type: "pause" }, id)).status).toBe(202);
    await tv.result(await tv.asked("pause"));
    await until(() => away.outcome(id)?.["status"] === "done");
    await patch(away.id, { remoteOutside: false });
    await until(() => away.sees(tv.id) === null);
  });

  it("a television that is outside is nobody's, until a manager says otherwise", async () => {
    const far = await client("Far", "tvos", {}, true);
    await far.announce({ player: playing(balloon) });
    await until(() => phone.sees(far.id) === null);
    expect((await phone.command(far.id, { type: "pause" })).status).toBe(404);
    await patch(far.id, { remoteOutside: true });
    await until(() => player(phone, far.id) !== null);
  });

  it("is cut when the device is no longer let in, and when the entrance closes", async () => {
    const away = await client("Away", "ios", {}, true);
    const at = Date.now();
    await patch(away.id, { allowOutside: false });
    await until(() => away.closed);
    expect(Date.now() - at).toBeLessThan(2_000);
    const other = await client("Other", "ios", {}, true);
    await f.outside.setEnabled(false);
    await until(() => other.closed);
    await f.outside.setEnabled(true);
  });

  it("goes on where it broke, and not from one entrance to the other", async () => {
    const away = await client("Away", "ios", {}, true);
    const { last } = away;
    away.cut();
    await away.open(last);
    expect(away.of("hello").at(-1)?.data["resumed"]).toBe(true);
    const home = new LiveClient(away, port);
    Object.assign(home, { session: away.session });
    clients.push(home);
    await home.open(away.last);
    expect(home.events[0]?.data["resumed"]).toBe(false);
    await until(() => away.closed);
    clients.pop();
    home.cut();
  });
});

describe("limits", () => {
  it("a device has a few channels at once", async () => {
    const more: LiveClient[] = [];
    for (let n = 1; n < REMOTE_LIMITS.sessionsPerDevice; n += 1) {
      const one = new LiveClient(phone, port);
      more.push(one);
      await one.open();
      expect(one.status).toBe(200);
    }
    const extra = new LiveClient(phone, port);
    await extra.open();
    expect(extra.status).toBe(429);
    more[0]?.cut();
    await until(async () => {
      await extra.open();
      return extra.status === 200;
    });
    for (const one of [...more, extra]) one.cut();
  });

  it("what a device says is limited in how often", async () => {
    let limited = 0;
    for (let n = 0; n < REMOTE_RATES.announcements.burst + 30; n += 1) {
      if ((await tv.announce()).status === 429) limited += 1;
    }
    expect(limited).toBeGreaterThan(0);
  });

  it("keeps a bounded amount for a device that is away", async () => {
    const hub = new RemoteHub({ db: f.db, devices: f.devices, limits: { bufferedEvents: 8 } });
    const reader = hub.open(phone.id, "p", false, null).getReader();
    hub.open(tv.id, "t", false, null);
    const said = readAnnouncement(fixture("announce-idle.json"), Date.now());
    hub.announce(phone.id, "p", false, { ...said, order: 1 });
    hub.announce(tv.id, "t", false, { ...said, order: 1 });
    await reader.cancel();
    for (let n = 0; n < 200; n += 1) {
      const made = f.devices.createLocalManager("Many");
      f.devices.setRemote(made.device.id, { isTarget: true });
      hub.recheck();
      f.devices.setRemote(made.device.id, { isTarget: false });
      hub.recheck();
      f.devices.revoke(made.device.id);
    }
    expect(hub.held.events).toBeLessThanOrEqual(16);
    expect(hub.held.bytes).toBeLessThanOrEqual(2 * REMOTE_LIMITS.bufferedBytes);
    // Too much was lost to go on from there.
    const back = hub.open(phone.id, "p", false, "x.1").getReader();
    expect(new TextDecoder().decode((await back.read()).value)).toContain('"resumed":false');
    hub.stop();
    expect(hub.held).toMatchObject({ sessions: 0, events: 0, pending: 0 });
  });

  it("lets go of a device that does not take in what it is sent", () => {
    const hub = new RemoteHub({ db: f.db, devices: f.devices, limits: { unsentBytes: 4_096 } });
    // Nobody reads it.
    hub.open(phone.id, "p", false, null);
    hub.open(tv.id, "t", false, null);
    const said = readAnnouncement(fixture("announce-idle.json"), Date.now());
    hub.announce(phone.id, "p", false, { ...said, order: 1 });
    for (let n = 0; n < 50; n += 1) {
      hub.announce(tv.id, "t", false, { ...said, order: n, foreground: n % 2 === 0 });
    }
    const pause = readCommandRequest(fixture<unknown[]>("commands.json")[1] as never);
    const again = { ...pause, session: "p", deviceId: tv.id };
    expect(() => hub.command(phone.id, false, again)).toThrow("Open Lobby");
    hub.stop();
  });

  it("remembers a bounded number of commands", () => {
    const hub = new RemoteHub({ db: f.db, devices: f.devices, limits: { remembered: 5 } });
    hub.open(phone.id, "p", false, null);
    hub.open(tv.id, "t", false, null);
    const said = readAnnouncement(fixture("announce-idle.json"), Date.now());
    hub.announce(phone.id, "p", false, { ...said, order: 1 });
    const state = readAnnouncement(fixture("announce-playing.json"), Date.now());
    hub.announce(tv.id, "t", false, { ...state, order: 1 });
    for (let n = 0; n < 20; n += 1) {
      const command = { type: "pause" } as const;
      hub.command(phone.id, false, { id: `c${n}`, session: "p", deviceId: tv.id, command });
    }
    expect(hub.held.taken).toBe(5);
    expect(hub.held.pending).toBe(1);
    hub.stop();
  });
});

describe("the settings", () => {
  it("are kept, with what is usual per device", async () => {
    const usual = (platform: Platform): boolean =>
      f.devices.find(device("One", platform).id)?.isTarget ?? false;
    expect(["tvos", "macos", "ios", "ipados"].map((one) => usual(one as Platform))).toEqual([
      true,
      true,
      false,
      false,
    ]);
    const reply = await phone.post("/v1/me", { isTarget: true }, "PATCH");
    expect(reply.json<Device>()).toMatchObject({
      isTarget: true,
      allowRemote: true,
      remoteOutside: false,
    });
    expect(f.devices.find(phone.id)?.isTarget).toBe(true);
    expect((await phone.post("/v1/me", {}, "PATCH")).status).toBe(400);
    await patch(phone.id, { isTarget: null, remoteOutside: true });
    expect(f.devices.find(phone.id)).toMatchObject({ isTarget: false, remoteOutside: true });
  });

  it("are added to a catalogue from before, and change nothing else in it", () => {
    const path = join(f.dir, "before.db");
    const later = migrations.filter((one) => one.version >= 13);
    migrations.splice(migrations.length - later.length, later.length);
    try {
      const old = new Database(path);
      old.run(
        `insert into device (id, name, platform, role, token_hash, created_at)
         values ('d', 'TV', 'tvos', 'viewer', 'x', 1)`,
      );
      old.close();
    } finally {
      migrations.push(...later);
    }
    const upgraded = new Database(path);
    expect(
      upgraded.get("select name, is_target, allow_remote, remote_outside from device"),
    ).toEqual({ name: "TV", is_target: null, allow_remote: 1, remote_outside: 0 });
    upgraded.close();
  });

  it("nothing of what was played is written down", async () => {
    const count = (): unknown =>
      f.db
        .all<{ name: string }>("select name from sqlite_master where type = 'table'")
        .map(({ name }) => [
          name,
          f.db.get<{ n: number }>(`select count(*) as n from "${name}"`)?.n,
        ]);
    const before = count();
    await tv.announce({ player: playing(balloon, { profileId: parent }) });
    await phone.command(tv.id, { type: "pause" });
    await tv.result(await tv.asked("pause"));
    expect(count()).toEqual(before);
  });
});

describe("the fixtures the apps test with", () => {
  it("are what this server takes", () => {
    for (const name of ["announce-playing", "announce-idle", "announce-beat"]) {
      const said = readAnnouncement(fixture(`${name}.json`), 1_000);
      expect(said.capabilities).toEqual(CAPABILITIES);
    }
    expect(readAnnouncement(fixture("announce-playing.json"), 1_000).player?.at).toBe(960);
    const commands = fixture<Record<string, unknown>[]>("commands.json").map(readCommandRequest);
    expect(commands.map((one) => one.command.type)).toEqual([...COMMANDS, "handover"]);
    expect(readResult(fixture("result-done.json"), 0).code).toBeNull();
    expect(readResult(fixture("result-failed.json"), 0).code).toBe("cannot_play");
  });

  it("are what this server sends", async () => {
    const events = fixture<{ event: string; data: Record<string, unknown> }[]>("events.json");
    const example = (event: string, index = 0): unknown =>
      shape(events.filter((one) => one.event === event)[index]?.data);
    const sent = (from: LiveClient, event: string): unknown => shape(from.of(event).at(-1)?.data);

    const reply = await tv.announce({
      player: playing(balloon, { subtitleTracks: [{ id: "s", label: "x", language: null }] }),
    });
    expect(shape(reply.json())).toEqual(shape(fixture("announce-reply.json")));
    await until(() => player(phone, tv.id) !== null);
    expect(sent(phone, "device")).toEqual(example("device"));
    const taken = await phone.command(tv.id, play(balloon));
    expect(shape(taken.json())).toEqual(shape(fixture("command-reply.json")));
    const asked = await tv.asked("play");
    expect(sent(tv, "command")).toEqual(example("command"));
    await tv.result(asked);
    await until(() => phone.of("result").length > 0 && phone.of("heartbeat").length > 0);
    expect(sent(phone, "result")).toEqual(example("result"));
    expect(sent(phone, "hello")).toEqual(example("hello"));
    expect(sent(phone, "heartbeat")).toEqual(example("heartbeat"));
    await phone.command(tv.id, { type: "handover", toDeviceId: phone.id });
    await tv.announce({ player: playing("unknown") });
    await until(() => player(phone, tv.id)?.["redacted"] === true);
    expect(sent(phone, "device")).toEqual(example("device", 1));
    await patch(tv.id, { allowRemote: false });
    await until(() => phone.sees(tv.id) === null);
    expect(sent(phone, "gone")).toEqual(example("gone"));
  });
});
