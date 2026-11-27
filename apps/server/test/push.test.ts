// SPDX-License-Identifier: MPL-2.0
import { generateKeyPairSync, verify, type KeyObject } from "node:crypto";
import { chmodSync, writeFileSync } from "node:fs";
import { createServer, type Http2Server, type IncomingHttpHeaders } from "node:http2";
import type { AddressInfo } from "node:net";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { Devices } from "../src/auth/devices.ts";
import { Database } from "../src/db/database.ts";
import { PushError, PushService, readPushConfig, type PushConfig } from "../src/push/service.ts";
import { makeTempDir, removeDir } from "./support/media.ts";

interface Received {
  headers: IncomingHttpHeaders;
  body: Record<string, unknown>;
}

let dir: string;
let db: Database;
let devices: Devices;
let apple: Http2Server;
let received: Received[];
/** What the fake Apple answers, by device token. */
let answers: Map<string, number>;
let publicKey: KeyObject;
let config: PushConfig;
let host: string;

const TOKEN = "a".repeat(64);
const OTHER = "b".repeat(64);

beforeEach(async () => {
  dir = makeTempDir("lobby-push-");
  db = new Database(join(dir, "lobby.db"));
  devices = new Devices(db, "secret");
  const pair = generateKeyPairSync("ec", { namedCurve: "P-256" });
  publicKey = pair.publicKey;
  const keyFile = join(dir, "AuthKey_ABCDE12345.p8");
  writeFileSync(keyFile, pair.privateKey.export({ type: "pkcs8", format: "pem" }));
  chmodSync(keyFile, 0o600);
  config = { keyFile, keyId: "ABCDE12345", teamId: "FGHIJ67890", topic: "mt.sil.lobby" };
  received = [];
  answers = new Map();
  // Apple's service, as far as Lobby uses it: HTTP/2, one POST per device.
  apple = createServer((request, response) => {
    let text = "";
    request.on("data", (part: Buffer) => (text += part.toString()));
    request.on("end", () => {
      received.push({
        headers: request.headers,
        body: JSON.parse(text) as Record<string, unknown>,
      });
      const token = String(request.headers[":path"]).split("/").at(-1) ?? "";
      response.writeHead(answers.get(token) ?? 200);
      response.end();
    });
  });
  await new Promise<void>((done) => apple.listen(0, "127.0.0.1", done));
  host = `http://127.0.0.1:${String((apple.address() as AddressInfo).port)}`;
});

afterEach(async () => {
  await new Promise((done) => apple.close(done));
  db.close();
  removeDir(dir);
});

const service = (more: Partial<PushConfig> = {}): PushService =>
  new PushService({
    db,
    config: { ...config, ...more },
    hosts: { development: host, production: host },
  });

describe("push notifications", () => {
  it("sends Apple what it wants, signed with the team's key", async () => {
    const push = service();
    expect(push.status()).toEqual({ configured: true, mode: "direct" });
    const phone = devices.createLocalManager("Phone").device;
    push.setToken(phone.id, TOKEN, "development");
    const sent = await push.toDevices([phone.id], {
      title: "Robin",
      body: "Robin wants to open Lobby.",
      category: "LOBBY_KIDS_QUESTION",
      threadId: "kids-yeva",
      data: { kind: "kidsRequest", requestId: "q1", serverId: "s1" },
    });
    expect(sent).toBe(1);
    const [one] = received;
    expect(one?.headers[":path"]).toBe(`/3/device/${TOKEN}`);
    expect(one?.headers["apns-topic"]).toBe("mt.sil.lobby");
    expect(one?.headers["apns-push-type"]).toBe("alert");
    expect(one?.body).toEqual({
      aps: {
        alert: { title: "Robin", body: "Robin wants to open Lobby." },
        sound: "default",
        category: "LOBBY_KIDS_QUESTION",
        "thread-id": "kids-yeva",
      },
      lobby: { kind: "kidsRequest", requestId: "q1", serverId: "s1" },
    });
    // The provider token is an ES256 JWT of the key and team.
    const jwt = String(one?.headers["authorization"]).replace("bearer ", "");
    const [header = "", claims = "", signature = ""] = jwt.split(".");
    expect(JSON.parse(Buffer.from(header, "base64url").toString())).toEqual({
      alg: "ES256",
      kid: "ABCDE12345",
    });
    expect(JSON.parse(Buffer.from(claims, "base64url").toString())).toMatchObject({
      iss: "FGHIJ67890",
    });
    expect(
      verify(
        "sha256",
        Buffer.from(`${header}.${claims}`),
        { key: publicKey, dsaEncoding: "ieee-p1363" },
        Buffer.from(signature, "base64url"),
      ),
    ).toBe(true);
  });

  it("forgets a token Apple says is gone, and never sends to a removed device", async () => {
    const push = service();
    const phone = devices.createLocalManager("Phone").device;
    const old = devices.createLocalManager("Old").device;
    push.setToken(phone.id, TOKEN, "production");
    push.setToken(old.id, OTHER, "production");
    answers.set(TOKEN, 410);
    devices.revoke(old.id);
    expect(await push.toDevices([phone.id, old.id], { title: "t", body: "b", data: {} })).toBe(0);
    expect(received).toHaveLength(1);
    expect(db.all("select * from push_token where device_id = ?", [phone.id])).toEqual([]);
  });

  it("refuses a key file others can read, and never tells the key", () => {
    chmodSync(config.keyFile, 0o644);
    const push = service();
    expect(push.status()).toEqual({ configured: false, mode: "off" });
    expect(JSON.stringify(push.status())).not.toContain("PRIVATE");
  });

  it("reads where the key is from the config file", () => {
    expect(readPushConfig(undefined, (path) => path)).toBeNull();
    expect(
      readPushConfig(
        { apns: { keyFile: "keys/a.p8", keyId: "ABCDE12345", teamId: "FGHIJ67890" } },
        (path) => `/base/${path}`,
      ),
    ).toEqual({
      keyFile: "/base/keys/a.p8",
      keyId: "ABCDE12345",
      teamId: "FGHIJ67890",
      topic: "mt.sil.lobby",
    });
    expect(() =>
      readPushConfig({ apns: { keyFile: "a.p8", keyId: "short", teamId: "FGHIJ67890" } }, (p) => p),
    ).toThrow(PushError);
    expect(() =>
      readPushConfig(
        { apns: { keyFile: "a.p8", keyId: "ABCDE12345", teamId: "FGHIJ67890", key: "x" } },
        (p) => p,
      ),
    ).toThrow(PushError);
  });

  it("takes only a device token", () => {
    const push = service();
    const phone = devices.createLocalManager("Phone").device;
    expect(() => {
      push.setToken(phone.id, "not a token", "production");
    }).toThrow(PushError);
  });
});
