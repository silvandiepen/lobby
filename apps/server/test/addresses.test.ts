// SPDX-License-Identifier: MPL-2.0
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { parseRemoteAddresses, serverAddresses } from "../src/addresses.ts";
import { Devices } from "../src/auth/devices.ts";
import { loadConfig } from "../src/config.ts";
import { Database } from "../src/db/database.ts";
import { createApp } from "../src/http/app.ts";
import { ItemReader } from "../src/library/items.ts";
import { ProgressStore } from "../src/progress.ts";
import { makeTempDir, removeDir } from "./support/media.ts";

describe("the server's addresses", () => {
  let dir: string;

  beforeEach(() => {
    dir = makeTempDir("lobby-addresses-");
  });

  afterEach(() => {
    removeDir(dir);
  });

  function config(addresses: unknown): string {
    const path = join(dir, "lobby.config.json");
    mkdirSync(join(dir, "Films"), { recursive: true });
    writeFileSync(
      path,
      JSON.stringify({
        roots: [{ path: join(dir, "Films"), hint: "movies" }],
        ...(addresses === undefined ? {} : { addresses }),
      }),
    );
    return path;
  }

  it("reads remote addresses from the config as plain origins", () => {
    expect(loadConfig(config(undefined)).addresses).toEqual({ remote: [] });
    expect(loadConfig(config({})).addresses).toEqual({ remote: [] });
    expect(
      loadConfig(
        config({
          remote: [
            "http://media.example.ts.net:8674",
            "https://lobby.example.org/",
            "HTTPS://Lobby.Example.org",
          ],
        }),
      ).addresses,
    ).toEqual({ remote: ["http://media.example.ts.net:8674", "https://lobby.example.org"] });
  });

  it("refuses anything that is not an http or https address of the server", () => {
    for (const [remote, message] of [
      ["https://lobby.example.org", /must be a list/],
      [[42], /must be a URL/],
      [["lobby.example.org"], /is not a URL/],
      [["ftp://lobby.example.org"], /http:\/\/ or https:\/\//],
      [["javascript:alert(1)"], /http:\/\/ or https:\/\//],
      [["file:///etc/passwd"], /http:\/\/ or https:\/\//],
      [["https://someone:secret@lobby.example.org"], /user name or password/],
      [["https://lobby.example.org/v1/server"], /without a path/],
      [["https://lobby.example.org?x=1"], /without a path/],
      [["https://lobby.example.org#top"], /without a path/],
      [[`https://${"a".repeat(300)}.example.org`], /must be a URL/],
      [Array.from({ length: 9 }, (_, n) => `https://lobby${n}.example.org`), /8 addresses at most/],
    ] as const) {
      expect(() => parseRemoteAddresses(remote), JSON.stringify(remote).slice(0, 60)).toThrow(
        message,
      );
    }
    // The config names the entry and stops the server from starting.
    expect(() => loadConfig(config({ remote: ["https://ok.example.org", "nope"] }))).toThrow(
      /Lobby config: addresses\.remote\[1\] is not a URL/,
    );
  });

  it("builds the home address from the name the server announces", () => {
    const serverId = "7c3f9a12-5b8e-4d21-9f6a-2e4b8c1d0a57";
    expect(serverAddresses({ serverId, port: 8674, advertised: true, remote: [] })).toEqual({
      home: ["http://lobby-7c3f9a12.local:8674"],
      remote: [],
    });
    // A server that does not announce itself has no name to be found by at home.
    expect(
      serverAddresses({
        serverId,
        port: 8674,
        advertised: false,
        remote: ["https://lobby.example.org"],
      }),
    ).toEqual({ home: [], remote: ["https://lobby.example.org"] });
  });

  it("tells paired devices the addresses, and nobody else", async () => {
    const db = new Database(join(dir, "lobby.db"));
    const remote = ["http://media.example.ts.net:8674"];
    const app = createApp({
      db,
      devices: new Devices(db, "setup-secret"),
      items: new ItemReader(db),
      progress: new ProgressStore(db),
      addresses: (serverId) => serverAddresses({ serverId, port: 8674, advertised: true, remote }),
      serverName: "Test Lobby",
      version: "0.0.0-test",
      isScanning: () => false,
    });
    const json = async (
      path: string,
      init: RequestInit = {},
    ): Promise<{ status: number; text: string }> => {
      const response = await app.request(path, init);
      return { status: response.status, text: await response.text() };
    };

    // Before pairing: the open route says who the server is, not where else it lives.
    const open = await json("/v1/server");
    expect(open.status).toBe(200);
    expect(open.text).not.toContain("addresses");
    expect(open.text).not.toContain("example.ts.net");
    expect((await json("/v1/me")).status).toBe(401);
    expect((await json("/v1/me")).text).not.toContain("example.ts.net");

    const claimed = await json("/v1/pairing/claim", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ setupSecret: "setup-secret", deviceName: "Mac", platform: "macos" }),
    });
    expect(claimed.status).toBe(201);
    expect(claimed.text).not.toContain("example.ts.net");
    const token = (JSON.parse(claimed.text) as { token: string }).token;

    const me = await json("/v1/me", { headers: { Authorization: `Bearer ${token}` } });
    const server = (JSON.parse(me.text) as { server: { id: string; addresses: unknown } }).server;
    expect(server.addresses).toEqual({
      home: [`http://lobby-${server.id.replaceAll("-", "").slice(0, 8)}.local:8674`],
      remote,
    });
    // Also with a credential, the open route stays as it was.
    const stillOpen = await json("/v1/server", { headers: { Authorization: `Bearer ${token}` } });
    expect(stillOpen.text).not.toContain("addresses");
    db.close();
  });

  it("gives empty lists when the server was started without addresses", async () => {
    const db = new Database(join(dir, "lobby.db"));
    const app = createApp({
      db,
      devices: new Devices(db, "setup-secret"),
      items: new ItemReader(db),
      progress: new ProgressStore(db),
      serverName: "Test Lobby",
      version: "0.0.0-test",
      isScanning: () => false,
    });
    const claimed = await app.request("/v1/pairing/claim", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ setupSecret: "setup-secret", deviceName: "Mac", platform: "macos" }),
    });
    const token = ((await claimed.json()) as { token: string }).token;
    const me = await app.request("/v1/me", { headers: { Authorization: `Bearer ${token}` } });
    expect(((await me.json()) as { server: { addresses: unknown } }).server.addresses).toEqual({
      home: [],
      remote: [],
    });
    db.close();
  });
});
