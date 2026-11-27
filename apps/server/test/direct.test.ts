// SPDX-License-Identifier: MPL-2.0
import { randomBytes } from "node:crypto";
import { existsSync, statSync, writeFileSync } from "node:fs";
import { connect } from "node:net";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { AccessEntry } from "../src/outside/access.ts";
import type { OutsideStatus } from "../src/outside/entrance.ts";
import { DirectFixture, programs, Shim, type Programs } from "./support/direct.ts";
import { makeVideo } from "./support/media.ts";
import { raw, until } from "./support/outside.ts";

const found = programs();
const real = found ?? ({} as Programs);

// Both ends are the real programs: ICE and QUIC over loopback, through the real introducer.
describe.skipIf(found === null)("the direct road, end to end", () => {
  let d: DirectFixture;
  let film: Buffer;

  beforeAll(() => {
    film = randomBytes(24 * 1024 * 1024);
  });
  beforeEach(async () => {
    d = new DirectFixture();
    await d.start(real.sidecar);
  });
  afterEach(async () => {
    await d.stop();
  });

  /** A film of which every byte is known, in the place of a real one. */
  const filmUrl = async (): Promise<string> => {
    const path = join(d.f.dir, "Films", "Known (2020).mp4");
    makeVideo(path);
    await d.f.scan();
    const asset = d.f.db.get<{ id: string }>("select id from asset")?.id ?? "";
    writeFileSync(path, film);
    const info = statSync(path);
    d.f.db.run("update asset set size = ?, mtime_ms = ? where id = ?", [
      info.size,
      Math.floor(info.mtimeMs),
      asset,
    ]);
    return `/v1/assets/${asset}/content`;
  };

  /** Where the program brings its streams. */
  const socketFolder = (): string =>
    (d.direct as unknown as { sidecar: { dir: string } }).sidecar.dir;

  it("brings a device to the entrance, and nobody else's credential", async () => {
    const tv = await d.device("Far TV");
    const other = await d.device("Other");
    await tv.connect(real.device);
    const me = await tv.ask("GET", "/v1/me");
    expect(me.status).toBe(200);
    expect(me.json<{ device: { id: string } }>().device.id).toBe(tv.id);
    // Good credentials, on a connection that is another device's.
    for (const token of [other.token, d.f.manager.token, undefined]) {
      const reply = await tv.ask("GET", "/v1/me", token === undefined ? { token: "" } : { token });
      expect([reply.status, reply.body.length]).toEqual([404, 0]);
    }
    for (const path of ["/v1/outside-pairing", "/v1/outside-pairing/collect"]) {
      expect((await tv.ask("POST", path, { body: {} })).status).toBe(404);
    }
    expect((await tv.ask("PUT", "/v1/me/direct", { body: {} })).status).toBe(403);
    const status = (
      await d.f.atHome(d.f.manager.token, "GET", "/v1/outside")
    ).json<OutsideStatus>();
    expect(status.direct).toEqual({
      running: true,
      introducer: true,
      connections: 1,
      relayed: 0,
      devices: 2,
    });
    expect(status.transports.find((one) => one.name === "direct")).toEqual({
      name: "direct",
      open: true,
      problem: null,
    });
    const { entries } = (await d.f.atHome(d.f.manager.token, "GET", "/v1/outside/access")).json<{
      entries: AccessEntry[];
    }>();
    expect(entries.find((one) => one.deviceId === tv.id && one.outcome === "ok")).toMatchObject({
      transport: "direct",
      address: "127.0.0.1",
      outcome: "ok",
    });
  });

  it("carries films byte for byte, many at once, with jumps in between", async () => {
    const url = await filmUrl();
    const tv = await d.device("Far TV");
    await tv.connect(real.device);
    const range = async (from: number, length: number): Promise<void> => {
      const reply = await tv.ask("GET", url, {
        headers: { Range: `bytes=${from}-${from + length - 1}` },
      });
      expect(reply.status).toBe(206);
      expect(reply.body.equals(film.subarray(from, from + length))).toBe(true);
    };
    const jump = (): void => {
      const socket = tv.stream();
      socket.on("error", () => undefined);
      socket.write(
        `GET ${url} HTTP/1.1\r\nHost: lobby.example.test\r\nAuthorization: Bearer ${tv.token}\r\nRange: bytes=0-\r\n\r\n`,
      );
      setTimeout(() => socket.destroy(), 30);
    };
    for (let round = 0; round < 8; round += 1) {
      jump();
      await Promise.all([1, 2, 3, 4].map((one) => range((round * 7 + one * 3) * 400_000, 300_000)));
    }
    await range(0, film.length);
    expect(tv.down).toBeNull();
  });

  it("is closed to a device that cannot prove itself", async () => {
    const tv = await d.device("Far TV");
    const other = await d.device("Other");
    // It knows the certificate and the secret, and not the key.
    await expect(tv.connect(real.device, { seed: other.seed })).rejects.toThrow(/no up/);
    await expect(tv.connect(real.device, { proof: "replayed" })).rejects.toThrow(/no up/);
    await tv.connect(real.device, { proof: "none" });
    const answer = await raw(
      tv.stream(),
      `GET /v1/me HTTP/1.1\r\nHost: lobby.example.test\r\nAuthorization: Bearer ${tv.token}\r\nConnection: close\r\n\r\n`,
    );
    expect(answer).toBe("");
    await until(() => tv.down !== null);
    expect(d.f.outside.status().connections).toBe(0);
    expect(d.f.outside.access.read(100, null)).toEqual([]);
    // And a box with another certificate is not the box.
    await expect(
      tv.connect(real.device, { fingerprint: randomBytes(32).toString("base64url") }),
    ).rejects.toThrow(/no up/);
    await tv.connect(real.device);
    expect((await tv.ask("GET", "/v1/me")).status).toBe(200);
  });

  it("ends at once for a device that is removed or not let in any more", async () => {
    const tv = await d.device("Far TV");
    const pad = await d.device("Far iPad");
    await tv.connect(real.device);
    await pad.connect(real.device);
    await d.f.atHome(d.f.manager.token, "DELETE", `/v1/devices/${tv.id}`);
    await until(() => tv.down !== null);
    expect(pad.down).toBeNull();
    // Its key is not at the introducer any more, so it cannot ring.
    await d.told();
    expect(await tv.ringUp()).toBe(4001);
    await d.f.atHome(d.f.manager.token, "PATCH", `/v1/devices/${pad.id}`, { allowOutside: false });
    await until(() => pad.down !== null);
    await d.told();
    expect(await pad.ringUp()).toBe(4001);
    await d.f.atHome(d.f.manager.token, "PATCH", `/v1/devices/${pad.id}`, { allowOutside: true });
    await d.told();
    await pad.connect(real.device);
    expect((await pad.ask("GET", "/v1/me")).status).toBe(200);
  });

  it("ends for everyone with the switch, and comes back with it", async () => {
    const url = await filmUrl();
    const tv = await d.device("Far TV");
    await tv.connect(real.device);
    const playing = tv.ask("GET", url);
    playing.catch(() => undefined);
    const folder = socketFolder();
    expect(existsSync(folder)).toBe(true);
    const at = Date.now();
    await d.f.outside.setEnabled(false);
    await until(() => tv.down !== null);
    expect(Date.now() - at).toBeLessThan(2_000);
    await until(async () => (await tv.ringUp()) === 4404);
    expect(d.direct.status().open).toBe(false);
    expect(existsSync(folder)).toBe(false);
    await d.f.outside.setEnabled(true);
    await until(() => d.direct.directStatus().introducer);
    await d.told();
    await tv.connect(real.device);
    expect((await tv.ask("GET", "/v1/me")).status).toBe(200);
  });

  it("lets nothing else on this machine in", async () => {
    const tv = await d.device("Far TV");
    await tv.connect(real.device);
    const dir = socketFolder();
    const path = join(dir, "s");
    expect([statSync(dir).mode & 0o777, statSync(path).mode & 0o777]).toEqual([0o700, 0o600]);
    const request = `GET /v1/me HTTP/1.1\r\nHost: lobby.example.test\r\nAuthorization: Bearer ${tv.token}\r\n\r\n`;
    for (const first of [
      "",
      `LOBBY/1 ${"0".repeat(64)} ${"0".repeat(32)}\n`,
      "LOBBY/1\n",
      `${"x".repeat(5_000)}\n`,
    ]) {
      expect(await raw(connect(path), first + request)).toBe("");
    }
    // Nor does the program say its secret to who looks at the processes.
    const listed = spawnSync("ps", ["-axww", "-o", "command="], { encoding: "utf8" }).stdout;
    const line = listed.split("\n").find((one) => one.startsWith(real.sidecar)) ?? "";
    expect(line.trim()).toBe(real.sidecar);
  });

  it("starts the program again when it dies", async () => {
    const tv = await d.device("Far TV");
    await tv.connect(real.device);
    const pid = (d.direct as unknown as { sidecar: { child: { pid: number } } }).sidecar.child.pid;
    process.kill(pid, "SIGKILL");
    await until(() => !d.direct.status().open);
    expect(d.direct.status().problem).toContain("stopped");
    expect(d.direct.directStatus().connections).toBe(0);
    await until(() => d.direct.status().open);
    await tv.connect(real.device);
    expect((await tv.ask("GET", "/v1/me")).status).toBe(200);
  });

  it("gives a device that moves a second connection, and keeps no more than three", async () => {
    const tv = await d.device("Far TV");
    await tv.connect(real.device);
    for (let move = 0; move < 4; move += 1) {
      await tv.connect(real.device);
      expect((await tv.ask("GET", "/v1/me")).status).toBe(200);
    }
    expect(d.direct.directStatus().connections).toBe(3);
  });

  it("takes a new certificate without a device noticing", async () => {
    const tv = await d.device("Far TV");
    const [, next = ""] = tv.identity.fingerprints;
    d.f.clock.ahead += 366 * 86_400_000;
    await until(() => d.direct.identities.identity().fingerprints[0] === next);
    await tv.connect(real.device, { fingerprint: next });
    expect((await tv.ask("GET", "/v1/me")).status).toBe(200);
  });

  it("shows the introducer nothing", async () => {
    const tv = await d.device("Far TV");
    await tv.connect(real.device);
    const seen = tv.lines.flatMap((line) => line.seen).join("\n");
    for (const secret of [
      "candidate",
      "ufrag",
      "127.0.0.1",
      "Far TV",
      tv.token,
      tv.id,
      'nonce":""',
      b64(tv.secret),
    ]) {
      expect(seen).not.toContain(secret);
    }
    for (const text of tv.lines.flatMap((line) => line.seen)) {
      const message = JSON.parse(text) as Record<string, unknown>;
      expect(["challenge", "auth", "ready", "msg"]).toContain(message["t"]);
      if (message["t"] === "msg") expect(Object.keys(message).sort()).toEqual(["p", "t"]);
    }
  });

  it("wastes less than 2 MB on a film that is left, at 40 Mbit/s and 60 ms", async () => {
    const url = await filmUrl();
    const tv = await d.device("Far TV");
    const road = await Shim.start({ oneWayMs: 30, loss: 0, mbit: 40, queueMs: 100 });
    try {
      await tv.connect(real.device, { road });
      await tv.ask("GET", "/v1/me");
      const before = road.counts.toDevice;
      const socket = tv.stream();
      let read = 0;
      await new Promise<void>((done) => {
        socket.on("data", (data: Buffer) => {
          read += data.length;
          // As a player that jumps: it has read two megabytes, and goes away.
          if (read >= 2_000_000) {
            socket.destroy();
            done();
          }
        });
        socket.write(
          `GET ${url} HTTP/1.1\r\nHost: lobby.example.test\r\nAuthorization: Bearer ${tv.token}\r\nRange: bytes=0-\r\n\r\n`,
        );
      });
      await new Promise((done) => setTimeout(done, 1_500));
      const wasted = road.counts.toDevice - before - read;
      expect(wasted).toBeLessThan(2_000_000);
      // And it is over: nothing goes on behind it.
      const then = road.counts.toDevice;
      await new Promise((done) => setTimeout(done, 1_000));
      expect(road.counts.toDevice - then).toBeLessThan(20_000);
      const at = performance.now();
      const reply = await tv.ask("GET", url, { headers: { Range: "bytes=9000000-9200000" } });
      expect(reply.body.equals(film.subarray(9_000_000, 9_200_001))).toBe(true);
      expect(performance.now() - at).toBeLessThan(3_000);
    } finally {
      road.stop();
    }
  });
});

describe.skipIf(found === null)("a limit on what is sent", () => {
  it("leaves room on the home's upload", async () => {
    const d = new DirectFixture();
    await d.start(real.sidecar, { maxUploadMbit: 8 });
    try {
      const path = join(d.f.dir, "Films", "Known (2020).mp4");
      makeVideo(path);
      await d.f.scan();
      const asset = d.f.db.get<{ id: string }>("select id from asset")?.id ?? "";
      const bytes = randomBytes(3_000_000);
      writeFileSync(path, bytes);
      d.f.db.run("update asset set size = ?, mtime_ms = ? where id = ?", [
        bytes.length,
        Math.floor(statSync(path).mtimeMs),
        asset,
      ]);
      const tv = await d.device("Far TV");
      await tv.connect(real.device);
      const at = performance.now();
      const reply = await tv.ask("GET", `/v1/assets/${asset}/content`);
      const mbit = (reply.body.length * 8) / ((performance.now() - at) * 1000);
      expect(reply.body.equals(bytes)).toBe(true);
      expect(mbit).toBeLessThan(8.5);
      expect(mbit).toBeGreaterThan(5);
    } finally {
      await d.stop();
    }
  });
});

function b64(data: Uint8Array): string {
  return Buffer.from(data).toString("base64url");
}
