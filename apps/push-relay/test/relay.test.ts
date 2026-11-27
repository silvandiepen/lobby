// SPDX-License-Identifier: MPL-2.0

import { verify } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { GENERIC, PROTOCOL, Relay, payload, type Post, type Store } from "../src/core.ts";
import {
  box,
  signed,
  startWorker,
  throwawayAppleKey,
  ticket,
  type Box,
  type ToApple,
} from "./support.ts";

const TOKEN = "a".repeat(64);
const OTHER = "b".repeat(64);
const SEALED = "c".repeat(120);
const KEY_ID = "KEYID00001";
const TEAM_ID = "TEAMID0001";
const TOPIC = "com.example.lobby";

/** A store as the platform's: values go in and out as copies. */
function memory(): Store & { keys: () => string[] } {
  const values = new Map<string, string>();
  return {
    get: (key) => {
      const value = values.get(key);
      return Promise.resolve(value === undefined ? undefined : (JSON.parse(value) as unknown));
    },
    put: (key, value) => {
      values.set(key, JSON.stringify(value));
      return Promise.resolve();
    },
    delete: (key) => {
      values.delete(key);
      return Promise.resolve();
    },
    keys: () => [...values.keys()],
  };
}

describe("the push relay", () => {
  let now: number;
  let apple: ToApple[];
  let answers: Map<string, { status: number; body?: unknown }>;
  let store: ReturnType<typeof memory>;
  let appleKey: ReturnType<typeof throwawayAppleKey>;
  let home: Box;
  let relay: Relay;
  let t: number;

  const post: Post = (url, init) => {
    apple.push({
      url,
      headers: init.headers,
      body: JSON.parse(init.body) as Record<string, unknown>,
    });
    const token = url.split("/").at(-1) ?? "";
    const answer = answers.get(token) ?? { status: 200 };
    return Promise.resolve({ status: answer.status, json: () => Promise.resolve(answer.body) });
  };

  const make = (limits = {}): Relay =>
    new Relay({
      store,
      key: { pem: appleKey.pem, keyId: KEY_ID, teamId: TEAM_ID, topic: TOPIC },
      post,
      now: () => now,
      limits,
    });

  beforeEach(() => {
    now = Date.UTC(2026, 10, 27, 12);
    t = now;
    apple = [];
    answers = new Map();
    store = memory();
    appleKey = throwawayAppleKey();
    home = box();
    relay = make();
  });

  const register = async (
    of = home,
    token = TOKEN,
    environment = "production",
    address = "192.0.2.1",
  ) => {
    const said = await relay.register(
      JSON.stringify({ ticket: ticket(of, now + 600_000), token, environment }),
      address,
    );
    return said;
  };

  const handleOf = async (of = home, token = TOKEN): Promise<string> => {
    const said = await register(of, token);
    expect(said.status).toBe(200);
    return String(said.body?.["handle"]);
  };

  const send = (of: Box, to: { h: string; s: string }[], more: Record<string, unknown> = {}) => {
    t += 1;
    const { text, signature } = signed(of, { t, to, ...more });
    return relay.send(text, of.public, signature);
  };

  describe("an app registering", () => {
    it("gets a handle for its token, the same one again, and never the token back", async () => {
      const first = await register();
      expect(first.status).toBe(200);
      expect(first.body?.["handle"]).toMatch(/^[A-Za-z0-9_-]{22}$/);
      expect(JSON.stringify(first.body)).not.toContain(TOKEN);
      const again = await register();
      expect(again.body?.["handle"]).toBe(first.body?.["handle"]);
      // Another token is another device.
      expect((await register(home, OTHER)).body?.["handle"]).not.toBe(first.body?.["handle"]);
    });

    it("needs a ticket its box signed, that still holds", async () => {
      const stranger = box();
      const forged = ticket(stranger, now + 600_000).replace(stranger.public, home.public);
      for (const bad of [
        forged,
        ticket(home, now - 10 * 60_000),
        ticket(home, now + 2 * 3_600_000),
        "nonsense",
        `${ticket(home, now + 600_000)}.more`,
      ]) {
        const said = await relay.register(
          JSON.stringify({ ticket: bad, token: TOKEN, environment: "production" }),
          "192.0.2.1",
        );
        expect(said.status).toBe(403);
      }
      expect(store.keys().filter((key) => key.startsWith("handle:"))).toEqual([]);
    });

    it("takes only a device token and an environment", async () => {
      expect((await register(home, "not a token")).status).toBe(400);
      expect((await register(home, TOKEN, "staging")).status).toBe(400);
      expect((await relay.register("[]", "192.0.2.1")).status).toBe(400);
    });

    it("is limited per address, and a full box lets go of its oldest device", async () => {
      relay = make({ registersPerMinute: 2, handlesPerBox: 2 });
      const tokens = ["1", "2", "3"].map((digit) => digit.repeat(64));
      const handles: string[] = [];
      for (const [index, token] of tokens.entries()) {
        const said = await register(home, token, "production", `192.0.2.${index}`);
        handles.push(String(said.body?.["handle"]));
      }
      expect((await register(home, TOKEN, "production", "192.0.2.0")).status).toBe(200);
      expect((await register(home, OTHER, "production", "192.0.2.0")).status).toBe(429);
      // The first was let go of for the third, and the third for TOKEN.
      const said = await send(
        home,
        handles.map((h) => ({ h, s: SEALED })),
      );
      expect(said.body?.["results"]).toEqual(["unknown", "unknown", "sent"]);
    });

    it("forgets a handle for its own box only, and says the same either way", async () => {
      const handle = await handleOf();
      const stranger = box();
      expect((await relay.forget(JSON.stringify({ box: stranger.id, handle }))).status).toBe(204);
      expect((await send(home, [{ h: handle, s: SEALED }])).body?.["results"]).toEqual(["sent"]);
      expect((await relay.forget(JSON.stringify({ box: home.id, handle }))).status).toBe(204);
      expect((await send(home, [{ h: handle, s: SEALED }])).body?.["results"]).toEqual(["unknown"]);
      expect(store.keys().filter((key) => !key.startsWith("count:") && key !== "jwt")).toEqual([
        `last:${home.id}`,
      ]);
    });
  });

  describe("a server sending", () => {
    it("reaches its own devices with a generic alert around the sealed text, signed for Apple", async () => {
      const handle = await handleOf();
      const said = await send(home, [{ h: handle, s: SEALED }], { expires: now + 600_000 });
      expect(said).toEqual({ status: 200, body: { results: ["sent"] } });
      const [one] = apple;
      expect(one?.url).toBe(`https://api.push.apple.com/3/device/${TOKEN}`);
      expect(one?.headers).toMatchObject({
        "apns-topic": TOPIC,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": String(Math.floor((now + 600_000) / 1000)),
      });
      expect(one?.body).toEqual({
        aps: { alert: GENERIC, sound: "default", "mutable-content": 1 },
        lobby: { v: 1, s: SEALED },
      });
      expect(JSON.stringify(one?.body)).toBe(payload(SEALED));
      // An ES256 JWT of the key and team, made with the key the relay holds.
      const jwt = String(one?.headers["authorization"]).replace("bearer ", "");
      const [header = "", claims = "", signature = ""] = jwt.split(".");
      expect(JSON.parse(Buffer.from(header, "base64url").toString())).toEqual({
        alg: "ES256",
        kid: KEY_ID,
      });
      expect(JSON.parse(Buffer.from(claims, "base64url").toString())).toEqual({
        iss: TEAM_ID,
        iat: Math.floor(now / 1000),
      });
      expect(
        verify(
          "sha256",
          Buffer.from(`${header}.${claims}`),
          { key: appleKey.public, dsaEncoding: "ieee-p1363" },
          Buffer.from(signature, "base64url"),
        ),
      ).toBe(true);
    });

    it("keeps the provider token for 50 minutes, over a restart too, and then makes another", async () => {
      const handle = await handleOf();
      await send(home, [{ h: handle, s: SEALED }]);
      now += 49 * 60_000;
      t = now;
      relay = make();
      await send(home, [{ h: handle, s: SEALED }]);
      now += 2 * 60_000;
      t = now;
      await send(home, [{ h: handle, s: SEALED }]);
      const tokens = apple.map((one) => one.headers["authorization"]);
      expect(tokens[0]).toBe(tokens[1]);
      expect(tokens[2]).not.toBe(tokens[1]);
    });

    it("uses Apple's sandbox for a development build", async () => {
      const said = await register(home, TOKEN, "development");
      await send(home, [{ h: String(said.body?.["handle"]), s: SEALED }]);
      expect(apple[0]?.url).toBe(`https://api.sandbox.push.apple.com/3/device/${TOKEN}`);
    });

    it("never reaches a device another box registered", async () => {
      const handle = await handleOf();
      const stranger = box();
      const said = await send(stranger, [{ h: handle, s: SEALED }]);
      expect(said.body?.["results"]).toEqual(["unknown"]);
      expect(apple).toEqual([]);
    });

    it("needs the box's own signature, over this very body", async () => {
      const handle = await handleOf();
      const stranger = box();
      t += 1;
      const { text, signature } = signed(stranger, { t, to: [{ h: handle, s: SEALED }] });
      // Another's signature with this box's key, and a body changed after signing.
      expect((await relay.send(text, home.public, signature)).status).toBe(403);
      const own = signed(home, { t, to: [{ h: handle, s: SEALED }] });
      expect(
        (await relay.send(own.text.replace(SEALED, "d".repeat(120)), home.public, own.signature))
          .status,
      ).toBe(403);
      expect((await relay.send(own.text, "short", own.signature)).status).toBe(403);
      expect(apple).toEqual([]);
    });

    it("sends nothing twice when the same send is said again, nor an old one", async () => {
      const handle = await handleOf();
      t += 1;
      const { text, signature } = signed(home, { t, to: [{ h: handle, s: SEALED }] });
      expect((await relay.send(text, home.public, signature)).status).toBe(200);
      expect((await relay.send(text, home.public, signature)).status).toBe(409);
      const old = signed(home, { t: now - 10 * 60_000, to: [{ h: handle, s: SEALED }] });
      expect((await relay.send(old.text, home.public, old.signature)).status).toBe(400);
      expect(apple).toHaveLength(1);
    });

    it("caps the sealed text, the devices in one send, per device and per box", async () => {
      relay = make({ perHandleHour: 2, perBoxDay: 5, perSend: 3 });
      const handle = await handleOf();
      expect((await send(home, [{ h: handle, s: "c".repeat(2_801) }])).status).toBe(400);
      expect((await send(home, [{ h: handle, s: "not base64url!" }])).status).toBe(400);
      expect(
        (
          await send(
            home,
            Array.from({ length: 4 }, () => ({ h: handle, s: SEALED })),
          )
        ).status,
      ).toBe(400);
      expect((await send(home, [])).status).toBe(400);
      const three = await send(
        home,
        Array.from({ length: 3 }, () => ({ h: handle, s: SEALED })),
      );
      expect(three.body?.["results"]).toEqual(["sent", "sent", "limited"]);
      expect(
        (
          await send(
            home,
            Array.from({ length: 3 }, () => ({ h: handle, s: SEALED })),
          )
        ).status,
      ).toBe(429);
      expect(apple).toHaveLength(2);
    });

    it("stops for the day at the daily cap", async () => {
      relay = make({ perDay: 1 });
      const handle = await handleOf();
      expect((await send(home, [{ h: handle, s: SEALED }])).status).toBe(200);
      expect((await send(home, [{ h: handle, s: SEALED }])).status).toBe(503);
      now += 86_400_000;
      t = now;
      expect((await send(home, [{ h: handle, s: SEALED }])).status).toBe(200);
    });

    it("forgets a device Apple says is gone, or a handle not registered again in time", async () => {
      const gone = await handleOf();
      const stale = await handleOf(home, OTHER);
      answers.set(TOKEN, { status: 410 });
      expect((await send(home, [{ h: gone, s: SEALED }])).body?.["results"]).toEqual(["gone"]);
      expect((await send(home, [{ h: gone, s: SEALED }])).body?.["results"]).toEqual(["unknown"]);
      now += 61 * 86_400_000;
      t = now;
      expect((await send(home, [{ h: stale, s: SEALED }])).body?.["results"]).toEqual(["unknown"]);
      expect(store.keys().some((key) => key.startsWith("handle:"))).toBe(false);
      expect(apple).toHaveLength(1);
    });

    it("says a bad token is gone, and makes a new provider token after Apple refused one", async () => {
      const handle = await handleOf();
      answers.set(TOKEN, { status: 403, body: { reason: "ExpiredProviderToken" } });
      expect((await send(home, [{ h: handle, s: SEALED }])).body?.["results"]).toEqual(["failed"]);
      now += 1_000;
      t = now;
      answers.set(TOKEN, { status: 400, body: { reason: "BadDeviceToken" } });
      expect((await send(home, [{ h: handle, s: SEALED }])).body?.["results"]).toEqual(["gone"]);
      expect(apple[1]?.headers["authorization"]).not.toBe(apple[0]?.headers["authorization"]);
    });

    it("sends nothing without the team's key", async () => {
      const handle = await handleOf();
      relay = new Relay({ store, key: null, post, now: () => now });
      expect((await send(home, [{ h: handle, s: SEALED }])).status).toBe(503);
      expect(apple).toEqual([]);
    });

    it("signs as the protocol says", () => {
      expect(PROTOCOL).toBe("lobby-push/1");
    });
  });
});

describe("the push relay in workerd", () => {
  let at: { url: string; close: () => Promise<void> };
  let apple: ToApple[];
  const appleKey = throwawayAppleKey();
  const home = box();

  beforeEach(async () => {
    apple = [];
    at = await startWorker(
      { APNS_KEY: appleKey.pem, APNS_KEY_ID: KEY_ID, APNS_TEAM_ID: TEAM_ID, APNS_TOPIC: TOPIC },
      (request) => {
        apple.push(request);
        return { status: 200 };
      },
    );
  });
  afterEach(async () => {
    await at.close();
  });

  it("registers, sends to Apple and forgets, over HTTP", async () => {
    const registered = await fetch(`${at.url}/v1/tokens`, {
      method: "POST",
      body: JSON.stringify({
        ticket: ticket(home, Date.now() + 600_000),
        token: TOKEN,
        environment: "production",
      }),
    });
    expect(registered.status).toBe(200);
    const { handle } = (await registered.json()) as { handle: string };
    const { text, signature } = signed(home, { t: Date.now(), to: [{ h: handle, s: SEALED }] });
    const sent = await fetch(`${at.url}/v1/send`, {
      method: "POST",
      headers: { "x-lobby-box": home.public, "x-lobby-signature": signature },
      body: text,
    });
    expect(await sent.json()).toEqual({ results: ["sent"] });
    expect(apple[0]?.url).toBe(`https://api.push.apple.com/3/device/${TOKEN}`);
    expect(apple[0]?.headers["apns-topic"]).toBe(TOPIC);
    expect(apple[0]?.body).toEqual(JSON.parse(payload(SEALED)));
    const forgot = await fetch(`${at.url}/v1/tokens/forget`, {
      method: "POST",
      body: JSON.stringify({ box: home.id, handle }),
    });
    expect(forgot.status).toBe(204);
  });

  it("has nothing for anything else, nor for a web page", async () => {
    for (const [path, init] of [
      ["/", { method: "GET" }],
      ["/v1/tokens", { method: "GET" }],
      ["/v1/tokens", { method: "POST", headers: { origin: "https://example.com" }, body: "{}" }],
      ["/v1/other", { method: "POST", body: "{}" }],
    ] as const) {
      const said = await fetch(`${at.url}${path}`, init);
      await said.body?.cancel();
      expect(said.status).toBe(404);
    }
  });
});
