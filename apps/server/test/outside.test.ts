// SPDX-License-Identifier: MPL-2.0
import { truncateSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { Devices, type Device } from "../src/auth/devices.ts";
import { Database } from "../src/db/database.ts";
import { migrations } from "../src/db/migrations.ts";
import { CODE_LENGTH, matches, hashSecret, newCode, readCode } from "../src/outside/code.ts";
import type { AccessEntry } from "../src/outside/access.ts";
import type { OutsideStatus } from "../src/outside/entrance.ts";
import { OUTSIDE_ROUTES, OUTSIDE_SLOTS } from "../src/outside/guard.ts";
import {
  addressKey,
  FailureLimiter,
  plainAddress,
  RateLimiter,
  Slots,
} from "../src/outside/limits.ts";
import type { OutsidePairingRequest } from "../src/outside/pairing.ts";
import { makeMkv } from "./playback-support.ts";
import { makeTempDir, makeVideo, removeDir } from "./support/media.ts";
import { NAME, OutsideFixture, raw, until, type OutsideReply } from "./support/outside.ts";

let f: OutsideFixture;
let tv: { id: string; token: string };
let homeOnly: { id: string; token: string };

beforeEach(async () => {
  f = new OutsideFixture();
  await f.start();
  tv = f.pair("Far TV", true);
  homeOnly = f.pair("Home iPad", false);
});
afterEach(async () => {
  await f.stop();
});

/** The whole answer but its body, to compare one refusal with another. */
const shape = (reply: OutsideReply): unknown => [
  reply.status,
  reply.rawHeaders,
  reply.body.toString(),
];

function registered(): string[] {
  return [
    ...new Set(
      f.app.routes
        .filter((route) => route.method !== "ALL")
        .map((route) => `${route.method === "HEAD" ? "GET" : route.method} ${route.path}`),
    ),
  ];
}

function pathOf(pattern: string): string {
  return pattern.replace(/:[a-zA-Z]+(\{[^}]*\})?/g, "x1");
}

describe("a decision for every route", () => {
  it("is there, and none is left over", () => {
    const routes = registered();
    expect(routes.filter((key) => OUTSIDE_ROUTES[key] === undefined)).toEqual([]);
    expect(Object.keys(OUTSIDE_ROUTES).filter((key) => !routes.includes(key))).toEqual([]);
  });

  it("refuses a route that has none", async () => {
    f.app.get("/v1/something-new", (c) => c.json({ secret: true }));
    expect((await f.ask("GET", "/v1/something-new", { token: tv.token })).status).toBe(404);
  });

  it("keeps every closed route closed, for a manager too, and changes nothing", async () => {
    f.devices.setAllowOutside(f.manager.id, true);
    const closed = Object.entries(OUTSIDE_ROUTES).filter(([, one]) => one === "closed");
    expect(closed.length).toBeGreaterThan(80);
    for (const [key] of closed) {
      const [method = "", pattern = ""] = key.split(" ");
      const path = pathOf(pattern)
        .replace("/v1/devices/x1", `/v1/devices/${tv.id}`)
        .replace("outside/pairing/x1", "outside/pairing/y");
      const reply = await f.ask(method, path, {
        token: f.manager.token,
        ...(["GET", "DELETE"].includes(method)
          ? {}
          : { body: { enabled: false, allowOutside: true, kidsProfileId: null, minutes: 5 } }),
      });
      expect([key, reply.status]).toEqual([key, 403]);
      expect(reply.json<{ error: { message: string } }>().error.message).toBe(
        "This can only be done at home.",
      );
    }
    expect(f.devices.find(tv.id)?.revokedAt).toBeNull();
    expect(f.outside.isOn).toBe(true);
    expect(f.outside.pairing.current()).toBeNull();
  });
});

describe("a stranger", () => {
  it("gets the same empty 404 for every route and path, whatever the method", async () => {
    const first = await f.ask("GET", "/v1/server");
    expect(first.status).toBe(404);
    expect(first.body).toHaveLength(0);
    const all = JSON.stringify([first.rawHeaders, first.body.toString()]);
    expect(all).not.toMatch(/Secret Household|9\.9\.9|lobby|Date|Server|X-Powered/i);
    const others: [string, string][] = [
      ...registered().map((key): [string, string] => {
        const [method = "", pattern = ""] = key.split(" ");
        return [method, pathOf(pattern)];
      }),
      ["GET", "/"],
      ["GET", "/index.html"],
      ["GET", "/favicon.ico"],
      ["GET", "/.well-known/acme-challenge/x"],
      ["GET", "/v1/../v1/server"],
      ["GET", "/v1/%2e%2e/server"],
      ["HEAD", "/v1/server"],
      ["OPTIONS", "/v1/library"],
      ["POST", "/v1/outside-pairing"],
      ["POST", "/v1/outside-pairing/collect"],
      ["GET", "/v1/outside-pairing"],
    ];
    for (const [method, path] of others) {
      const reply = await f.ask(method, path);
      expect([method, path, shape(reply)]).toEqual([method, path, shape(first)]);
    }
  });

  it("cannot tell an unknown credential, a removed device and one that is only for home apart", async () => {
    const removed = f.pair("Old TV", true);
    f.devices.revoke(removed.id);
    const none = shape(await f.ask("GET", "/v1/me"));
    for (const token of [removed.token, homeOnly.token, "A".repeat(43), "short", ""]) {
      expect(shape(await f.ask("GET", "/v1/me", { token }))).toEqual(none);
      expect(shape(await f.ask("GET", "/v1/me", { cookie: `lobby_device=${token}` }))).toEqual(
        none,
      );
    }
  });

  it("is refused alike with a good credential in a strange request", async () => {
    const none = shape(await f.ask("GET", "/v1/me"));
    const good = { token: tv.token };
    expect((await f.ask("GET", "/v1/me", good)).status).toBe(200);
    expect(
      (await f.ask("GET", "/v1/me", { ...good, host: `${NAME.toUpperCase()}:443` })).status,
    ).toBe(200);
    for (const strange of [
      { host: "evil.example" },
      { host: `${NAME}.evil.example` },
      { host: `${NAME}@evil.example` },
      { host: "127.0.0.1" },
      { headers: { Origin: "https://evil.example" } },
      { headers: { Origin: `https://${NAME}` } },
      { headers: { "Sec-Fetch-Site": "cross-site" } },
    ]) {
      expect(shape(await f.ask("GET", "/v1/me", { ...good, ...strange }))).toEqual(none);
    }
    const auth = `Authorization: Bearer ${tv.token}\r\n`;
    for (const head of [
      `GET /v1/me HTTP/1.1\r\n${auth}\r\n`,
      `GET /v1/me HTTP/1.1\r\nHost: ${NAME}\r\nHost: evil.example\r\n${auth}\r\n`,
      `GET /v1/me HTTP/1.0\r\nHost: ${NAME}\r\n${auth}\r\n`,
      `GET http://evil.example/v1/me HTTP/1.1\r\nHost: ${NAME}\r\n${auth}\r\n`,
      `GET //evil.example/v1/me HTTP/1.1\r\nHost: ${NAME}\r\n${auth}\r\n`,
      `POST /v1/me/downloads HTTP/1.1\r\nHost: ${NAME}\r\n${auth}Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n`,
      `PUT /v1/me HTTP/1.1\r\nHost: ${NAME}\r\n${auth}Expect: 100-continue\r\nContent-Length: 4\r\n\r\n`,
    ]) {
      expect([head, await raw(f.connect(), head)]).toEqual([
        head,
        expect.stringMatching(/^HTTP\/1\.1 404 Not Found\r\n[\s\S]*Content-Length: 0\r\n/),
      ]);
    }
    for (const nonsense of [
      "\x16\x03\x01 hello",
      `CONNECT x:1 HTTP/1.1\r\nHost: ${NAME}\r\n\r\n`,
      `GET /v1/me HTTP/1.1\r\nHost: ${NAME}\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\n`,
      `GET /v1/me HTTP/1.1\r\nHost: ${NAME}\r\nX: ${"a".repeat(20_000)}\r\n\r\n`,
      `POST /v1/me HTTP/1.1\r\nHost: ${NAME}\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n`,
    ]) {
      expect(await raw(f.connect(), nonsense)).toMatch(/^($|HTTP\/1\.1 404 Not Found)/);
    }
  });

  it("does not get into the app when the entrance did not let it in", async () => {
    const response = await f.app.request("/v1/server");
    expect(response.status).toBe(404);
    expect(await response.text()).toBe("");
  });
});

describe("a device that is let in", () => {
  it("plays, with ranges, and takes pictures, progress and its wanted list", async () => {
    makeVideo(join(f.dir, "Films/Garden (2001)/Garden (2001).mp4"), { seconds: 2 });
    await f.scan();
    const film = f.items.find((one) => one.title === "Garden");
    const asset = film?.files[0]?.assetId ?? "";
    expect(
      (await f.ask("GET", "/v1/me", { token: tv.token })).json<{ device: Device }>().device,
    ).toMatchObject({
      id: tv.id,
      allowOutside: true,
      role: "viewer",
    });
    const library = await f.ask("GET", "/v1/library", { token: tv.token });
    expect(library.json<{ items: unknown[] }>().items).toHaveLength(1);
    expect(library.headers["strict-transport-security"]).toBe("max-age=31536000");
    expect(library.headers["access-control-allow-origin"]).toBeUndefined();
    expect(library.headers["set-cookie"]).toBeUndefined();
    const start = await f.ask("POST", `/v1/assets/${asset}/playback`, { token: tv.token });
    const url = start.json<{ streamUrl: string }>().streamUrl;
    expect(url).not.toContain(tv.token);
    const whole = await f.ask("GET", url, { cookie: `lobby_device=${tv.token}` });
    expect(whole.status).toBe(200);
    const part = await f.ask("GET", url, {
      cookie: `lobby_device=${tv.token}`,
      headers: { Range: "bytes=10-19" },
    });
    expect([part.status, part.headers["content-range"]]).toEqual([
      206,
      `bytes 10-19/${whole.body.length}`,
    ]);
    expect(part.body.equals(whole.body.subarray(10, 20))).toBe(true);
    expect((await f.ask("HEAD", url, { token: tv.token })).headers["content-length"]).toBe(
      String(whole.body.length),
    );
    const profile = (await f.atHome(f.manager.token, "POST", "/v1/profiles", { name: "A" })).json<{
      id: string;
    }>().id;
    const put = await f.ask("PUT", `/v1/profiles/${profile}/progress/${film?.id ?? ""}`, {
      token: tv.token,
      body: {
        opId: "1",
        baseRevision: null,
        positionMs: 5,
        durationMs: 10,
        completed: false,
        updatedAt: 1,
      },
    });
    expect(put.status).toBe(200);
    const wanted = await f.ask("GET", "/v1/me/wanted", { token: tv.token });
    expect(wanted.status).toBe(200);
    expect(
      (
        await f.ask("GET", "/v1/me/wanted", {
          token: tv.token,
          headers: { "If-None-Match": wanted.headers.etag ?? "" },
        })
      ).status,
    ).toBe(304);
    expect(
      (
        await f.ask("POST", "/v1/me/downloads", {
          token: tv.token,
          body: { freeBytes: 1, totalBytes: 2, downloads: [] },
        })
      ).status,
    ).toBe(200);
  });

  it("is still held to its kids limits, and is not told what is closed", async () => {
    makeVideo(join(f.dir, "Films/Garden (2001)/Garden (2001).mp4"));
    await f.scan();
    const asset = f.items[0]?.files[0]?.assetId ?? "";
    const other = (
      await f.atHome(f.manager.token, "POST", "/v1/profiles", { name: "Tall one" })
    ).json<{ id: string }>().id;
    const avatar = (id: string): Promise<{ status: number }> =>
      f.ask("PUT", `/v1/profiles/${id}/avatar`, { token: tv.token, body: { avatar: "owl" } });
    expect((await avatar(other)).status).toBe(200);
    const kid = (
      await f.atHome(f.manager.token, "POST", "/v1/profiles", {
        name: "Kid",
        kids: {
          allowedGroupIds: [],
          allowedCategoryIds: [],
          allowedItemIds: [],
          blockedItemIds: [],
        },
      })
    ).json<{ id: string }>().id;
    f.devices.bindToKids(tv.id, kid);
    expect((await avatar(kid)).status).toBe(200);
    expect((await avatar(other)).status).toBe(404);
    expect(
      (await f.ask("GET", "/v1/library", { token: tv.token })).json<{ items: unknown[] }>().items,
    ).toEqual([]);
    for (const path of [`/v1/assets/${asset}/content`, "/v1/devices"]) {
      expect((await f.ask("GET", path, { token: tv.token })).status).toBe(404);
    }
    // Music is on for a child unless a grown-up turns it off (docs/decisions.md, "Kids control").
    expect((await f.ask("GET", "/v1/music/library", { token: tv.token })).status).toBe(200);
  });

  it("may not write with the cookie, send a large body or pass its credential on a used connection", async () => {
    const none = shape(await f.ask("GET", "/"));
    const body = { freeBytes: 1, totalBytes: 2, downloads: [] };
    const cookie = `lobby_device=${tv.token}`;
    expect(shape(await f.ask("POST", "/v1/me/downloads", { cookie, body }))).toEqual(none);
    expect(
      shape(await f.ask("GET", "/v1/me", { cookie: `${cookie}; lobby_device=other` })),
    ).toEqual(none);
    const big = { freeBytes: 1, totalBytes: 2, downloads: [], x: "y".repeat(70_000) };
    expect(
      (await f.ask("PUT", "/v1/profiles/a/progress/b", { token: tv.token, body: big })).status,
    ).toBe(413);
    const other = f.pair("Other", true);
    const get = (token: string): string =>
      `GET /v1/me HTTP/1.1\r\nHost: ${NAME}\r\nAuthorization: Bearer ${token}\r\n\r\n`;
    const socket = f.connect();
    let text = "";
    socket.on("data", (part: Buffer) => (text += part.toString()));
    socket.write(get(tv.token));
    await until(() => text.includes("Far TV"));
    socket.write(get(other.token));
    await until(() => text.includes("404 Not Found"));
    expect(text).not.toContain('"Other"');
  });

  it("is cut off at once when it is removed or no longer let in, in the middle of a film", async () => {
    const path = join(f.dir, "Films/Long (2001)/Long (2001).mp4");
    makeVideo(path);
    // Large enough that it cannot all be on the way already.
    truncateSync(path, 200_000_000);
    await f.scan();
    const asset = f.items[0]?.files[0]?.assetId ?? "";
    for (const stop of [
      () => f.atHome(f.manager.token, "PATCH", `/v1/devices/${tv.id}`, { allowOutside: false }),
      () => {
        f.devices.setAllowOutside(tv.id, true);
        return f.atHome(f.manager.token, "DELETE", `/v1/devices/${tv.id}`);
      },
    ]) {
      f.devices.setAllowOutside(tv.id, true);
      const socket = f.connect();
      let got = 0;
      let closed = false;
      socket.on("close", () => (closed = true));
      socket.on("error", () => undefined);
      socket.write(
        `GET /v1/assets/${asset}/content HTTP/1.1\r\nHost: ${NAME}\r\nAuthorization: Bearer ${tv.token}\r\n\r\n`,
      );
      await new Promise<void>((done) =>
        socket.once("data", (part: Buffer) => {
          got += part.length;
          socket.pause();
          done();
        }),
      );
      await stop();
      socket.on("data", (part: Buffer) => (got += part.length));
      socket.resume();
      await until(() => closed);
      expect(got).toBeLessThan(100_000_000);
      expect((await f.ask("GET", "/v1/me", { token: tv.token })).status).toBe(404);
    }
  });

  it("has a limit on streams at once, and gets the place back", async () => {
    const path = join(f.dir, "Films/Long (2001)/Long (2001).mp4");
    makeVideo(path);
    truncateSync(path, 60_000_000);
    await f.scan();
    const asset = f.items[0]?.files[0]?.assetId ?? "";
    const sockets = Array.from({ length: OUTSIDE_SLOTS.stream.perDevice }, () => {
      const socket = f.connect();
      socket.on("error", () => undefined);
      socket.write(
        `GET /v1/assets/${asset}/content HTTP/1.1\r\nHost: ${NAME}\r\nAuthorization: Bearer ${tv.token}\r\n\r\n`,
      );
      return socket;
    });
    await Promise.all(
      sockets.map(
        (socket) =>
          new Promise<void>((done) =>
            socket.once("data", () => {
              socket.pause();
              done();
            }),
          ),
      ),
    );
    const range = { token: tv.token, headers: { Range: "bytes=0-1" } };
    const over = await f.ask("GET", `/v1/assets/${asset}/content`, range);
    expect([over.status, over.headers["retry-after"]]).toEqual([429, "5"]);
    const other = f.pair("Other", true);
    expect(
      (await f.ask("GET", `/v1/assets/${asset}/content`, { ...range, token: other.token })).status,
    ).toBe(206);
    for (const socket of sockets) socket.destroy();
    await until(
      async () => (await f.ask("GET", `/v1/assets/${asset}/content`, range)).status === 206,
    );
  });

  it("may start only a few copies, and ask about them as often as it likes", async () => {
    for (const name of ["A", "B", "C", "D", "E", "F", "G", "H"]) {
      makeMkv(join(f.dir, `Films/${name} (2010)/${name} (2010).mkv`));
    }
    await f.scan();
    let refused = 0;
    let ready = 0;
    for (const item of f.items) {
      const path = `/v1/assets/${item.files[0]?.assetId ?? ""}/playback`;
      let state = "";
      await until(async () => {
        const reply = await f.ask("POST", path, { token: tv.token });
        if (reply.status === 429) {
          refused += 1;
          return true;
        }
        state = reply.json<{ state: string }>().state;
        return state === "ready";
      });
      if (state === "ready") ready += 1;
    }
    expect([ready, refused]).toEqual([6, 2]);
    // At home nothing changed.
    const last = f.items.at(-1)?.files[0]?.assetId ?? "";
    expect((await f.atHome(tv.token, "POST", `/v1/assets/${last}/playback`)).status).toBe(202);
  }, 60_000);
});

describe("the switch", () => {
  it("is off until a manager turns it on, stays as it was left, and only moves from home", async () => {
    const other = new OutsideFixture();
    await other.start(false);
    expect(other.outside.status()).toMatchObject({ configured: true, enabled: false });
    expect(other.transport.status().open).toBe(false);
    expect((await other.atHome(other.manager.token, "POST", "/v1/outside/window", {})).status).toBe(
      409,
    );
    const viewer = other.pair("V", true);
    expect(
      (await other.atHome(viewer.token, "PATCH", "/v1/outside", { enabled: true })).status,
    ).toBe(403);
    const on = await other.atHome(other.manager.token, "PATCH", "/v1/outside", { enabled: true });
    expect(on.json<OutsideStatus>()).toMatchObject({
      enabled: true,
      transports: [{ name: "sockets", open: true, problem: null }],
    });
    expect((await other.ask("GET", "/v1/me", { token: viewer.token })).status).toBe(200);
    await other.outside.stop();
    expect(other.transport.status().open).toBe(false);
    await other.outside.start(other.app);
    expect(other.transport.status().open).toBe(true);
    // Anything but a clear yes is no.
    other.db.setMeta("outside_enabled", "true");
    await until(() => !other.transport.status().open);
    await other.stop();
  });

  it("closes everything at once, also from the command line's process", async () => {
    for (const off of [
      () => f.atHome(f.manager.token, "PATCH", "/v1/outside", { enabled: false }),
      (): Promise<unknown> => {
        const second = new DatabaseSync(join(f.dir, "lobby.db"));
        second.exec("update meta set value = 'off' where key = 'outside_enabled'");
        second.close();
        return Promise.resolve();
      },
    ]) {
      await f.outside.setEnabled(true);
      f.outside.pairing.open(f.manager.id, 10);
      const socket = f.connect();
      let closed = false;
      socket.on("error", () => undefined);
      socket.on("close", () => (closed = true));
      socket.resume();
      socket.write(
        `GET /v1/me HTTP/1.1\r\nHost: ${NAME}\r\nAuthorization: Bearer ${tv.token}\r\n\r\n`,
      );
      await until(() => f.outside.status().connections === 1);
      await off();
      await until(() => closed && !f.transport.status().open);
      expect(f.outside.pairing.current()).toBeNull();
      await expect(f.ask("GET", "/v1/me", { token: tv.token })).rejects.toThrow();
    }
  });

  it("cannot be turned on when it is not set up", async () => {
    const { OutsideEntrance } = await import("../src/outside/index.ts");
    const bare = new OutsideEntrance({ db: f.db, devices: f.devices, name: null });
    expect(bare.isOn).toBe(false);
    f.deps.outside = bare;
    const { createApp } = await import("../src/http/app.ts");
    f.home = createApp(f.deps);
    expect(
      (await f.atHome(f.manager.token, "PATCH", "/v1/outside", { enabled: true })).status,
    ).toBe(409);
  });
});

describe("pairing from outside", () => {
  const present = (code: string, deviceName = "Apple TV"): Promise<OutsideReply> =>
    f.ask("POST", "/v1/outside-pairing", { body: { code, deviceName, platform: "tvos" } });
  const openWindow = async (minutes?: number): Promise<string> => {
    const reply = await f.atHome(
      f.manager.token,
      "POST",
      "/v1/outside/window",
      minutes === undefined ? {} : { minutes },
    );
    expect(reply.status).toBe(201);
    return reply.json<{ code: string }>().code;
  };

  it("goes through a window, a comparison and an approval, and gives a viewer", async () => {
    const code = await openWindow();
    expect(code).toMatch(/^([0-9A-HJKMNP-TV-Z]{4}-){3}[0-9A-HJKMNP-TV-Z]{4}$/);
    const shown = await present(code.toLowerCase().replace(/-/g, " "), "Apple‮TV\u0000\n  x");
    expect(shown.status).toBe(201);
    const request = shown.json<{ id: string; pollSecret: string; comparison: string }>();
    const collect = (): Promise<OutsideReply> =>
      f.ask("POST", "/v1/outside-pairing/collect", {
        body: { id: request.id, pollSecret: request.pollSecret },
      });
    expect((await collect()).status).toBe(202);
    // One device only.
    expect((await present(code)).status).toBe(404);
    const list = (await f.atHome(f.manager.token, "GET", "/v1/pairing/requests")).json<{
      requests: unknown[];
      outsideRequests: OutsidePairingRequest[];
    }>();
    expect(list.requests).toEqual([]);
    expect(list.outsideRequests).toEqual([
      expect.objectContaining({
        id: request.id,
        outside: true,
        deviceName: "AppleTV x",
        address: "203.0.113.7",
        comparison: request.comparison,
      }),
    ]);
    expect(JSON.stringify(list)).not.toContain(request.pollSecret);
    // The ways the home flow has do not approve it.
    for (const body of [
      { requestId: request.id, role: "viewer" },
      { requestId: request.id, role: "manager" },
      { code: request.comparison, role: "viewer" },
    ]) {
      expect((await f.atHome(f.manager.token, "POST", "/v1/pairing/approve", body)).status).toBe(
        404,
      );
    }
    const approve = `/v1/outside/pairing/${request.id}/approve`;
    const body = { comparison: request.comparison, role: "manager" };
    expect((await f.atHome(f.manager.token, "POST", approve, {})).status).toBe(400);
    expect((await f.atHome(tv.token, "POST", approve, body)).status).toBe(403);
    expect((await collect()).status).toBe(202);
    expect((await f.atHome(f.manager.token, "POST", approve, body)).status).toBe(200);
    const done = await collect();
    expect(done.status).toBe(200);
    const paired = done.json<{ device: Device; token: string }>();
    expect(paired.device).toMatchObject({ role: "viewer", allowOutside: true });
    expect((await f.ask("GET", "/v1/me", { token: paired.token })).status).toBe(200);
    expect((await collect()).status).toBe(404);
  });

  it("turns the device away when the digits are not its own, or the manager says no", async () => {
    const first = (await present(await openWindow())).json<{ id: string; comparison: string }>();
    const wrong = first.comparison === "000000" ? "000001" : "000000";
    expect(
      (
        await f.atHome(f.manager.token, "POST", `/v1/outside/pairing/${first.id}/approve`, {
          comparison: wrong,
        })
      ).status,
    ).toBe(409);
    expect(f.outside.pairing.waiting()).toEqual([]);
    const second = (await present(await openWindow())).json<{ id: string }>();
    expect(
      (await f.atHome(f.manager.token, "DELETE", `/v1/outside/pairing/${second.id}`)).status,
    ).toBe(204);
    expect(f.outside.pairing.waiting()).toEqual([]);
  });

  it("is closed without a window, after it, and after a restart", async () => {
    const none = shape(await f.ask("GET", "/"));
    expect(shape(await present(newCode()))).toEqual(none);
    expect(
      (await f.atHome(f.manager.token, "POST", "/v1/outside/window", { minutes: 31 })).status,
    ).toBe(400);
    const code = await openWindow(30);
    f.clock.ahead += 30 * 60_000;
    expect(shape(await present(code))).toEqual(none);
    const next = await openWindow();
    expect((await f.atHome(f.manager.token, "DELETE", "/v1/outside/window")).status).toBe(204);
    expect(shape(await present(next))).toEqual(none);
    // A code with a mistake in the rest does not use it up.
    const last = await openWindow();
    expect(
      shape(
        await f.ask("POST", "/v1/outside-pairing", {
          body: { code: last, deviceName: "x", platform: "cli" },
        }),
      ),
    ).toEqual(none);
    expect((await present(last)).status).toBe(201);
    // Nothing of it is in the database.
    f.db.run("pragma wal_checkpoint(truncate)");
    const { readFileSync } = await import("node:fs");
    expect(readFileSync(join(f.dir, "lobby.db")).includes(last)).toBe(false);
  });

  it("slows wrong codes down per address, and for everyone when the address says nothing", async () => {
    await openWindow();
    const tries: number[] = [];
    for (let attempt = 0; attempt < 7; attempt += 1) tries.push((await present(newCode())).status);
    expect(tries).toEqual([404, 404, 404, 404, 404, 429, 429]);
    f.transport.address = "2001:db8::1";
    expect((await present(newCode())).status).toBe(404);
    f.transport.reliable = false;
    const anonymous: number[] = [];
    for (let attempt = 0; attempt < 26; attempt += 1) {
      anonymous.push((await present(newCode())).status);
    }
    expect(anonymous.filter((status) => status === 404).length).toBeLessThanOrEqual(25);
    expect(anonymous.at(-1)).toBe(429);
    // Even the right code has to wait then.
    f.transport.reliable = true;
    f.transport.address = "198.51.100.9";
    const code = await openWindow();
    const reply = await present(code);
    expect([reply.status, reply.body.length]).toEqual([429, 0]);
    expect(Number(reply.headers["retry-after"])).toBeGreaterThan(0);
    f.clock.ahead += 5 * 60_000;
    expect((await present(code)).status).toBe(201);
  });
});

describe("limits", () => {
  it("slow bad credentials down, and never a good one", async () => {
    const statuses: number[] = [];
    for (let attempt = 0; attempt < 13; attempt += 1) {
      statuses.push((await f.ask("GET", "/v1/me", { token: homeOnly.token })).status);
    }
    expect(statuses.slice(0, 10)).toEqual(Array<number>(10).fill(404));
    expect(statuses.slice(-2)).toEqual([429, 429]);
    // The same address, which a household shares.
    expect((await f.ask("GET", "/v1/me", { token: tv.token })).status).toBe(200);
  });

  it("make room for a newcomer when silent connections fill the door", async () => {
    const small = new OutsideFixture({ newConnections: 4, headMs: 60_000 });
    await small.start();
    const device = small.pair("TV", true);
    let closed = 0;
    const silent = Array.from({ length: 12 }, () => {
      const socket = small.connect();
      socket.on("close", () => (closed += 1));
      socket.on("error", () => undefined);
      return socket;
    });
    await until(() => closed >= 8);
    expect((await small.ask("GET", "/v1/me", { token: device.token })).status).toBe(200);
    for (const socket of silent) socket.destroy();
    await small.stop();
  });

  it("end a connection that sends its head or its body too slowly, and one that asks twice at once", async () => {
    const small = new OutsideFixture({ headMs: 1_000, bodyMs: 1_000 });
    await small.start();
    const device = small.pair("TV", true);
    const slow = small.connect();
    const drip = setInterval(() => slow.write("x"), 200);
    expect(await raw(slow, "GET /")).toBe("");
    clearInterval(drip);
    expect(
      await raw(
        small.connect(),
        `POST /v1/me/downloads HTTP/1.1\r\nHost: ${NAME}\r\nAuthorization: Bearer ${device.token}\r\nContent-Length: 100\r\n\r\n{`,
      ),
    ).not.toContain("200 OK");
    await small.stop();
    const twice = `GET /v1/library HTTP/1.1\r\nHost: ${NAME}\r\nAuthorization: Bearer ${tv.token}\r\n\r\n`;
    expect((await raw(f.connect(), twice + twice)).match(/200 OK/g) ?? []).toHaveLength(0);
  });

  it("lets a slow viewer watch longer than a body may take", async () => {
    const small = new OutsideFixture({ bodyMs: 500, headMs: 500 });
    await small.start();
    const device = small.pair("TV", true);
    const path = join(small.dir, "Films/Long (2001)/Long (2001).mp4");
    makeVideo(path);
    truncateSync(path, 30_000_000);
    await small.scan();
    const asset = small.items[0]?.files[0]?.assetId ?? "";
    const socket = small.connect();
    let got = 0;
    socket.write(
      `GET /v1/assets/${asset}/content HTTP/1.1\r\nHost: ${NAME}\r\nAuthorization: Bearer ${device.token}\r\nConnection: close\r\n\r\n`,
    );
    socket.on("data", (part: Buffer) => {
      if (got === 0) {
        socket.pause();
        setTimeout(() => socket.resume(), 2_500);
      }
      got += part.length;
    });
    await new Promise((done) => socket.once("close", done));
    expect(got).toBeGreaterThan(30_000_000);
    await small.stop();
  });

  it("remember a bounded number of addresses, and count IPv6 by its /64", () => {
    let now = 0;
    const limiter = new FailureLimiter(
      { free: 2, forgetMs: 1_000_000, all: { burst: 1e6, perMinute: 1 }, max: 100 },
      () => now,
    );
    for (let n = 0; n < 1_000; n += 1) limiter.fail(`key${n}`);
    expect(limiter.size).toBe(100);
    limiter.fail("one");
    expect(limiter.wait("one")).toBe(0);
    limiter.fail("one");
    expect(limiter.wait("one")).toBe(15);
    now += 15_000;
    limiter.fail("one");
    expect(limiter.wait("one")).toBe(30);
    expect(limiter.wait("two")).toBe(0);
    for (let n = 0; n < 30; n += 1) limiter.fail("one");
    expect(limiter.wait("one")).toBe(3600);

    const rate = new RateLimiter({ burst: 2, perMinute: 60 }, () => now, 10);
    expect([rate.take("a"), rate.take("a"), rate.take("a")]).toEqual([0, 0, 1]);
    now += 1_000;
    expect(rate.take("a")).toBe(0);
    for (let n = 0; n < 100; n += 1) rate.take(`k${n}`);
    expect(rate.size).toBe(10);

    const slots = new Slots(1, 2);
    const held = slots.take("a");
    expect(slots.take("a")).toBeNull();
    expect(slots.take("b")).not.toBeNull();
    expect(slots.take("c")).toBeNull();
    held?.();
    held?.();
    expect(slots.take("c")).not.toBeNull();
    expect(slots.take("d")).toBeNull();

    expect(addressKey("2001:db8:1:2:3::4")).toBe(addressKey("2001:DB8:1:2::9"));
    expect(addressKey("2001:db8:1:2::1")).not.toBe(addressKey("2001:db8:1:3::1"));
    expect(addressKey("::ffff:198.51.100.7")).toBe("198.51.100.7");
    expect(plainAddress("::ffff:c633:6407")).toBe("198.51.100.7");
    expect(addressKey("nonsense")).toBeNull();
    expect(addressKey(null)).toBeNull();
  });
});

describe("codes", () => {
  it("are 16 characters of 5 bits, all of them used, and read however they are typed", () => {
    expect(CODE_LENGTH * 5).toBeGreaterThanOrEqual(80);
    const seen = new Set<string>();
    for (let n = 0; n < 300; n += 1) for (const one of newCode().replace(/-/g, "")) seen.add(one);
    expect([...seen].sort().join("")).toBe("0123456789ABCDEFGHJKMNPQRSTVWXYZ");
    expect(readCode("oil1 0abc-defg-hjkm")).toBe("01110ABCDEFGHJKM");
    for (const bad of [
      "",
      "0123456789ABCDE",
      "0123456789ABCDEFG",
      "U123456789ABCDEF",
      "é".repeat(16),
    ]) {
      expect(readCode(bad)).toBeNull();
    }
    expect(matches("", null)).toBe(false);
    expect(matches("a", hashSecret("a"))).toBe(true);
    expect(matches("b", hashSecret("a"))).toBe(false);
  });
});

describe("what is written down", () => {
  it("says who, where from, what kind and how it went, and nothing else", async () => {
    await f.ask("GET", "/v1/me", { token: tv.token });
    await f.ask("GET", "/v1/me?x=secretquery", { token: tv.token });
    await f.ask("GET", "/v1/devices", { token: tv.token });
    await f.ask("GET", "/wp-login.php", { token: "B".repeat(43) });
    const reply = await f.atHome(f.manager.token, "GET", "/v1/outside/access?limit=10");
    const { entries } = reply.json<{ entries: AccessEntry[] }>();
    expect(entries.map((one) => [one.deviceId, one.routeClass, one.outcome, one.count])).toEqual([
      [null, "none", "refused", 1],
      [tv.id, "closed", "closed", 1],
      [tv.id, "account", "ok", 2],
    ]);
    expect(entries.every((one) => one.address === "203.0.113.7")).toBe(true);
    expect(JSON.stringify(entries)).not.toMatch(/secretquery|wp-login|BBBB|v1/);
    expect(JSON.stringify(entries)).not.toContain(tv.token);
    const list = (await f.atHome(f.manager.token, "GET", "/v1/devices")).json<{
      devices: Device[];
    }>().devices;
    expect(list.find((one) => one.id === tv.id)?.lastOutsideAt).not.toBeNull();
    expect(list.find((one) => one.id === homeOnly.id)).toMatchObject({
      allowOutside: false,
      lastOutsideAt: null,
    });
    expect((await f.atHome(tv.token, "GET", "/v1/outside/access")).status).toBe(403);
    const older = await f.atHome(
      f.manager.token,
      "GET",
      `/v1/outside/access?before=${String(entries[0]?.id)}`,
    );
    expect(older.json<{ entries: unknown[] }>().entries).toHaveLength(2);
  });

  it("is bounded, and a flood of strangers does not push out who came in", async () => {
    await f.ask("GET", "/v1/me", { token: tv.token });
    f.outside.access.flush();
    f.db.transaction(() => {
      for (let n = 0; n < 7_000; n += 1) {
        f.db.run(
          `insert into outside_access (at, until, count, transport, route_class, outcome) values (?, ?, 1, 'x', 'none', 'refused')`,
          [f.now(), f.now()],
        );
      }
    });
    for (let n = 0; n < 3_000; n += 1) {
      f.outside.access.note({
        deviceId: null,
        transport: "x",
        address: `10.0.${n >> 8}.${n & 255}`,
        routeClass: "none",
        outcome: "refused",
      });
    }
    f.outside.access.flush();
    const rows = f.db.get<{ n: number }>("select count(*) as n from outside_access")?.n ?? 0;
    expect(rows).toBeLessThanOrEqual(5_001);
    expect(
      f.db.get<{ n: number }>("select count(*) as n from outside_access where device_id = ?", [
        tv.id,
      ])?.n,
    ).toBe(1);
    f.clock.ahead += 31 * 86_400_000;
    await f.ask("GET", "/x");
    expect(f.outside.access.read(500, null)).toHaveLength(1);
  });
});

describe("letting a device in", () => {
  it("is for a manager, one device at a time, and off for those that were paired before", async () => {
    const path = `/v1/devices/${homeOnly.id}`;
    expect((await f.atHome(tv.token, "PATCH", path, { allowOutside: true })).status).toBe(403);
    expect((await f.atHome(f.manager.token, "PATCH", path, { allowOutside: "yes" })).status).toBe(
      400,
    );
    expect((await f.atHome(f.manager.token, "PATCH", path, {})).status).toBe(400);
    expect(
      (await f.atHome(f.manager.token, "PATCH", "/v1/devices/x", { allowOutside: true })).status,
    ).toBe(404);
    const reply = await f.atHome(f.manager.token, "PATCH", path, { allowOutside: true });
    expect(reply.json<Device>()).toMatchObject({ allowOutside: true, kidsProfileId: null });
    expect((await f.ask("GET", "/v1/me", { token: homeOnly.token })).status).toBe(200);
    expect(
      (await f.atHome(f.manager.token, "PATCH", path, { kidsProfileId: null })).json<Device>(),
    ).toMatchObject({ allowOutside: true });

    const dir = makeTempDir();
    const old = new DatabaseSync(join(dir, "lobby.db"));
    old.exec(
      "create table schema_migration (version integer primary key, name text not null, applied_at integer not null) strict",
    );
    for (const migration of migrations.filter((one) => one.version < 8)) {
      old.exec(migration.sql);
      old.exec(`insert into schema_migration values (${String(migration.version)}, 'x', 1)`);
    }
    old.exec(
      "insert into device (id, name, platform, role, token_hash, created_at) values ('d', 'TV', 'tvos', 'viewer', 'h', 1)",
    );
    old.close();
    const upgraded = new Database(join(dir, "lobby.db"));
    expect(new Devices(upgraded, "s").find("d")).toMatchObject({
      allowOutside: false,
      lastOutsideAt: null,
    });
    upgraded.close();
    removeDir(dir);
  });

  it("keeps a credential with enough in it, and only its hash", () => {
    expect(Buffer.from(tv.token, "base64url")).toHaveLength(32);
    const row = f.db.get<{ token_hash: string }>("select token_hash from device where id = ?", [
      tv.id,
    ]);
    expect(row?.token_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(JSON.stringify(f.db.all("select * from device"))).not.toContain(tv.token);
  });
});
