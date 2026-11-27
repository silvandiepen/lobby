// SPDX-License-Identifier: MPL-2.0

import { generateKeyPairSync, randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
// The relay itself, as it runs on Cloudflare, with Apple played: what the server sends must pass it.
import { Relay, type Answer, type Store } from "../../push-relay/src/core.ts";
import { Devices } from "../src/auth/devices.ts";
import { Database } from "../src/db/database.ts";
import { BoxKeys } from "../src/outside/direct/keys.ts";
import { openPush, sealPush, type PushContent } from "../src/push/sealed.ts";
import { PushError, PushService, readPushRoute, type PushConfig } from "../src/push/service.ts";
import { makeTempDir, removeDir } from "./support/media.ts";

interface ToApple {
  url: string;
  body: { aps: Record<string, unknown>; lobby: { v: number; s: string } };
}

let dir: string;
let db: Database;
let devices: Devices;
let keys: BoxKeys;
let relayServer: Server;
let relayUrl: string;
let apple: ToApple[];
let appleSays: number;

function memory(): Store {
  const values = new Map<string, string>();
  return {
    get: (key) =>
      Promise.resolve(values.has(key) ? (JSON.parse(values.get(key) ?? "") as unknown) : undefined),
    put: (key, value) => {
      values.set(key, JSON.stringify(value));
      return Promise.resolve();
    },
    delete: (key) => {
      values.delete(key);
      return Promise.resolve();
    },
  };
}

beforeEach(async () => {
  dir = makeTempDir("lobby-push-relay-");
  db = new Database(join(dir, "lobby.db"));
  devices = new Devices(db, "secret");
  keys = new BoxKeys(join(dir, "data"));
  apple = [];
  appleSays = 200;
  const pem = generateKeyPairSync("ec", { namedCurve: "P-256" })
    .privateKey.export({ type: "pkcs8", format: "pem" })
    .toString();
  const relay = new Relay({
    store: memory(),
    key: { pem, keyId: "KEYID00001", teamId: "TEAMID0001", topic: "com.example.lobby" },
    post: (url, init) => {
      apple.push({ url, body: JSON.parse(init.body) as ToApple["body"] });
      return Promise.resolve({ status: appleSays, json: () => Promise.resolve({}) });
    },
  });
  relayServer = createServer((request, response) => {
    let text = "";
    request.on("data", (part: Buffer) => (text += part.toString()));
    request.on("end", () => {
      const said: Promise<Answer> =
        request.url === "/v1/tokens"
          ? relay.register(text, "192.0.2.1")
          : request.url === "/v1/send"
            ? relay.send(text, request.headers["x-lobby-box"], request.headers["x-lobby-signature"])
            : Promise.resolve({ status: 404 });
      void said.then(({ status, body }) => {
        response.writeHead(status, { "content-type": "application/json" });
        response.end(body === undefined ? undefined : JSON.stringify(body));
      });
    });
  });
  await new Promise<void>((done) => relayServer.listen(0, "127.0.0.1", done));
  relayUrl = `http://127.0.0.1:${String((relayServer.address() as AddressInfo).port)}`;
});

afterEach(async () => {
  await new Promise((done) => relayServer.close(done));
  db.close();
  removeDir(dir);
});

const relayed = (): PushService =>
  new PushService({ db, config: null, route: { mode: "relay", relay: relayUrl }, box: keys });

/** What the app does: registers its token with the relay, with the server's ticket. */
async function registerAsTheApp(push: PushService, token: string): Promise<string> {
  const registration = push.registration();
  if (registration.mode !== "relay") throw new Error("not relay mode");
  const answer = await fetch(`${registration.relay.url}/v1/tokens`, {
    method: "POST",
    body: JSON.stringify({ ticket: registration.relay.ticket, token, environment: "production" }),
  });
  expect(answer.status).toBe(200);
  return ((await answer.json()) as { handle: string }).handle;
}

const QUESTION = {
  title: "Robin",
  body: "Robin wants to watch The Film.",
  category: "LOBBY_KIDS_QUESTION",
  threadId: "kids-p1",
  data: { kind: "kidsRequest", requestId: "q1", serverId: "s1" },
};

describe("push through the relay", () => {
  it("sends each device its own sealed text, signed by the box, and never learns a token", async () => {
    const push = relayed();
    expect(push.status()).toEqual({ configured: true, mode: "relay" });
    const phone = devices.createLocalManager("Phone").device;
    const pad = devices.createLocalManager("Pad").device;
    const token = "a".repeat(64);
    const phoneKey = randomBytes(32);
    const padKey = randomBytes(32);
    push.setRelayHandle(
      phone.id,
      await registerAsTheApp(push, token),
      phoneKey.toString("base64url"),
      "production",
    );
    push.setRelayHandle(
      pad.id,
      await registerAsTheApp(push, "b".repeat(64)),
      padKey.toString("base64url"),
      "production",
    );
    expect(await push.toDevices([phone.id, pad.id], QUESTION)).toBe(2);
    // In no particular order: the devices are looked up by their ids, which are random.
    const toPhone = `https://api.push.apple.com/3/device/${token}`;
    const toPad = `https://api.push.apple.com/3/device/${"b".repeat(64)}`;
    expect(apple.map((one) => one.url).sort()).toEqual([toPhone, toPad]);
    // Apple, and the relay, see only the generic alert; the app opens the rest.
    const first = apple.find((one) => one.url === toPhone);
    const second = apple.find((one) => one.url === toPad);
    expect(first?.body.aps["alert"]).toEqual({ title: "Lobby", body: "A request is waiting." });
    expect(JSON.stringify(first?.body)).not.toContain("Robin");
    const expected: PushContent = {
      title: "Robin",
      body: "Robin wants to watch The Film.",
      category: "LOBBY_KIDS_QUESTION",
      thread: "kids-p1",
      data: QUESTION.data,
    };
    expect(openPush(phoneKey, first?.body.lobby.s ?? "")).toEqual(expected);
    expect(openPush(padKey, second?.body.lobby.s ?? "")).toEqual(expected);
    expect(() => openPush(padKey, first?.body.lobby.s ?? "")).toThrow();
    expect(JSON.stringify(db.all("select * from push_relay"))).not.toContain(token);
  });

  it("gives the app a ticket the relay takes, and nothing of the key in it", () => {
    const registration = relayed().registration();
    expect(registration.mode).toBe("relay");
    if (registration.mode !== "relay") return;
    expect(registration.relay.url).toBe(relayUrl);
    const [key, until, signature] = registration.relay.ticket.split(".");
    expect(key).toBe(keys.boxPublic.toString("base64url"));
    expect(Number(until)).toBeGreaterThan(Date.now());
    expect(signature).toMatch(/^[A-Za-z0-9_-]{86}$/);
  });

  it("forgets a handle the relay says is gone, and never sends to a removed device", async () => {
    const push = relayed();
    const phone = devices.createLocalManager("Phone").device;
    const old = devices.createLocalManager("Old").device;
    const key = randomBytes(32).toString("base64url");
    push.setRelayHandle(phone.id, await registerAsTheApp(push, "a".repeat(64)), key, "production");
    push.setRelayHandle(old.id, await registerAsTheApp(push, "b".repeat(64)), key, "production");
    devices.revoke(old.id);
    appleSays = 410;
    expect(await push.toDevices([phone.id, old.id], QUESTION)).toBe(0);
    expect(apple).toHaveLength(1);
    expect(db.all("select * from push_relay where device_id = ?", [phone.id])).toEqual([]);
  });

  it("sends nothing to a handle another box registered", async () => {
    const push = relayed();
    const other = new PushService({
      db,
      config: null,
      route: { mode: "relay", relay: relayUrl },
      box: new BoxKeys(join(dir, "other")),
    });
    const phone = devices.createLocalManager("Phone").device;
    const handle = await registerAsTheApp(other, "a".repeat(64));
    push.setRelayHandle(phone.id, handle, randomBytes(32).toString("base64url"), "production");
    expect(await push.toDevices([phone.id], QUESTION)).toBe(0);
    expect(apple).toEqual([]);
  });

  it("takes only a relay handle and a 32-byte key", () => {
    const push = relayed();
    const phone = devices.createLocalManager("Phone").device;
    expect(() => {
      push.setRelayHandle(phone.id, "short", randomBytes(32).toString("base64url"), "production");
    }).toThrow(PushError);
    expect(() => {
      push.setRelayHandle(
        phone.id,
        "A".repeat(22),
        randomBytes(16).toString("base64url"),
        "production",
      );
    }).toThrow(PushError);
  });

  it("is quiet, and sends nothing, when the relay cannot be reached", async () => {
    const push = new PushService({
      db,
      config: null,
      route: { mode: "relay", relay: "http://127.0.0.1:9" },
      box: keys,
    });
    const phone = devices.createLocalManager("Phone").device;
    push.setRelayHandle(
      phone.id,
      "A".repeat(22),
      randomBytes(32).toString("base64url"),
      "production",
    );
    expect(await push.toDevices([phone.id], QUESTION)).toBe(0);
  });
});

describe("push turned off", () => {
  it("says so, and sends nothing", async () => {
    const push = new PushService({ db, config: null, route: { mode: "off", relay: null } });
    expect(push.status()).toEqual({ configured: false, mode: "off" });
    expect(push.registration()).toEqual({ mode: "off" });
    const phone = devices.createLocalManager("Phone").device;
    push.setToken(phone.id, "a".repeat(64), "production");
    expect(await push.toDevices([phone.id], QUESTION)).toBe(0);
  });
});

describe("the push mode from the config file", () => {
  const apns: PushConfig = {
    keyFile: "/keys/key.p8",
    keyId: "KEYID00001",
    teamId: "TEAMID0001",
    topic: "com.example.lobby",
  };

  it("keeps a key of one's own direct, as before there were modes", () => {
    expect(readPushRoute({ apns: {} }, apns)).toEqual({ mode: "direct", relay: null });
  });

  it("uses the relay that is named, and is off without one", () => {
    expect(readPushRoute({ relay: "https://push.example.com/" }, null)).toEqual({
      mode: "relay",
      relay: "https://push.example.com",
    });
    expect(readPushRoute(undefined, null)).toEqual({ mode: "off", relay: null });
    expect(readPushRoute({ mode: "off", relay: "https://push.example.com" }, apns)).toEqual({
      mode: "off",
      relay: null,
    });
    expect(
      readPushRoute({ mode: "relay", relay: "https://push.example.com", apns: {} }, apns),
    ).toEqual({ mode: "relay", relay: "https://push.example.com" });
  });

  it("refuses what cannot work", () => {
    for (const [raw, key] of [
      [{ mode: "direct" }, null],
      [{ mode: "relay" }, null],
      [{ mode: "sometimes" }, null],
      [{ relay: "http://push.example.com" }, null],
      [{ relay: "https://push.example.com/?a=1" }, null],
      [{ relays: "https://push.example.com" }, null],
    ] as const) {
      expect(() => readPushRoute(raw, key)).toThrow(PushError);
    }
  });
});

describe("the sealed text", () => {
  it("is exactly what the apps test against (docs/push-vectors.json)", () => {
    const vectors = JSON.parse(
      readFileSync(join(import.meta.dirname, "../../../docs/push-vectors.json"), "utf8"),
    ) as {
      aad: string;
      key: string;
      nonce: string;
      cases: { content: PushContent; sealed: string }[];
    };
    expect(vectors.aad).toBe("lobby-push/1|alert");
    const key = Buffer.from(vectors.key, "base64url");
    for (const one of vectors.cases) {
      expect(sealPush(key, one.content, Buffer.from(vectors.nonce, "base64url"))).toBe(one.sealed);
      expect(openPush(key, one.sealed)).toEqual(one.content);
    }
  });
});
