// SPDX-License-Identifier: MPL-2.0
import { execFileSync } from "node:child_process";
import { connect } from "node:net";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  truncateSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { serve } from "@hono/node-server";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ArtworkStore } from "../src/artwork/serve.ts";
import {
  AuthError,
  Devices,
  MAX_WAITING,
  MAX_WAITING_PER_ADDRESS,
  type Device,
} from "../src/auth/devices.ts";
import { createBackup, restoreBackup } from "../src/backup.ts";
import { Database } from "../src/db/database.ts";
import { BusyError, Gate } from "../src/gate.ts";
import { createApp } from "../src/http/app.ts";
import { isHomeHost, isNearby } from "../src/http/home.ts";
import { createAssetLookup } from "../src/http/playback-assets.ts";
import { log, wholeLines, withoutPaths } from "../src/log.ts";
import { PlaybackService } from "../src/playback/index.ts";
import { readRevocations, REVOKED_FILE, writeRevocations } from "../src/revocations.ts";
import { makeMkv } from "./playback-support.ts";
import { makeTempDir, makeVideo, removeDir } from "./support/media.ts";
import { OutsideFixture, raw, until } from "./support/outside.ts";

let f: OutsideFixture;
beforeEach(async () => {
  f = new OutsideFixture();
  await f.start(false);
});
afterEach(async () => {
  vi.restoreAllMocks();
  await f.stop();
});

/** A request as it arrives from `address`. */
async function from(
  address: string,
  method: string,
  path: string,
  options: { body?: unknown; headers?: Record<string, string>; token?: string } = {},
): Promise<{
  status: number;
  headers: Headers;
  code: string | null;
  body: Record<string, unknown>;
}> {
  const env: object = { incoming: { socket: { remoteAddress: address } } };
  const response = await f.home.request(
    path,
    {
      method,
      headers: {
        ...options.headers,
        ...(options.token === undefined ? {} : { Authorization: `Bearer ${options.token}` }),
      },
      ...(options.body === undefined ? {} : { body: JSON.stringify(options.body) }),
    },
    env,
  );
  const body = (await response.json()) as Record<string, unknown>;
  const error = body["error"] as { code: string } | undefined;
  return { status: response.status, headers: response.headers, code: error?.code ?? null, body };
}
const ask = { deviceName: "TV", platform: "tvos" };

describe("pairing requests", () => {
  it("are as before for a device that asks, is approved and collects", async () => {
    const asked = await from("192.168.1.20", "POST", "/v1/pairing/requests", { body: ask });
    expect(asked.status).toBe(201);
    f.devices.approve(String(asked.body["code"]), "viewer", "cli");
    const collected = await from(
      "192.168.1.20",
      "POST",
      `/v1/pairing/requests/${String(asked.body["id"])}/collect`,
      { body: { pollSecret: asked.body["pollSecret"] } },
    );
    expect([collected.status, collected.body["status"]]).toEqual([200, "approved"]);
  });

  it("from one address take each other's place, and leave those of others alone", () => {
    const other = f.devices.startPairing("Other", "ios", "192.168.1.9");
    for (let n = 0; n < MAX_WAITING_PER_ADDRESS + 3; n += 1) {
      f.devices.startPairing(`Same ${n}`, "ios", "192.168.1.8");
    }
    const waiting = f.devices.waiting();
    expect(waiting).toHaveLength(MAX_WAITING_PER_ADDRESS + 1);
    expect(waiting.some((one) => one.id === other.id)).toBe(true);
    expect(waiting.at(-1)?.deviceName).toBe(`Same ${MAX_WAITING_PER_ADDRESS + 2}`);
    expect(waiting.some((one) => one.deviceName === "Same 0")).toBe(false);
  });

  it("are limited in rate per address and in number in all", async () => {
    const statuses: number[] = [];
    for (let n = 0; n < 22; n += 1) {
      statuses.push(
        (await from("192.168.1.8", "POST", "/v1/pairing/requests", { body: ask })).status,
      );
    }
    expect(statuses.slice(0, 20)).toEqual(Array<number>(20).fill(201));
    expect(statuses.slice(20)).toEqual([429, 429]);
    const neighbour = await from("192.168.1.9", "POST", "/v1/pairing/requests", { body: ask });
    expect(neighbour.status).toBe(201);

    let refused: AuthError | null = null;
    for (let n = 0; n < 100 && !refused; n += 1) {
      f.clock.ahead += 3_000;
      try {
        f.devices.startPairing("Flood", "ios", `192.168.2.${n}`);
      } catch (error) {
        refused = error as AuthError;
      }
    }
    expect([refused?.code, (refused?.retryAfterSeconds ?? 0) > 0]).toEqual(["rate_limited", true]);
    expect(f.devices.waiting()).toHaveLength(MAX_WAITING);
    f.clock.ahead += 11 * 60_000;
    expect(f.devices.startPairing("Later", "ios", "192.168.2.1").code).toMatch(/^\d{6}$/);
    // What nobody approved does not pile up.
    f.clock.ahead += 3 * 3_600_000;
    f.devices.startPairing("Much later", "ios");
    expect(f.db.get("select count(*) as n from pairing_request")).toEqual({ n: 1 });
  });

  it("never show one code twice, however close the numbers are", () => {
    const codes = new Set<string>();
    for (let n = 0; n < MAX_WAITING; n += 1) {
      codes.add(f.devices.startPairing("D", "ios", `10.0.0.${n}`).code);
    }
    expect(codes.size).toBe(MAX_WAITING);
  });

  it("remember a bounded number of wrong guesses, and none at what is not there", () => {
    const limiter = (f.devices as unknown as { limiter: { failures: Map<string, number[]> } })
      .limiter;
    for (let n = 0; n < 500; n += 1) {
      expect(() => f.devices.collect(`none-${n}`, "x")).toThrow("no such pairing request");
    }
    expect(limiter.failures.size).toBe(0);
    for (let n = 0; n < 6_000; n += 1) {
      expect(() => f.devices.approve("000000", "viewer", `m${n}`)).toThrow();
    }
    expect(limiter.failures.size).toBeLessThanOrEqual(4_096);
    const real = f.devices.startPairing("D", "ios");
    for (let n = 0; n < 5; n += 1) expect(() => f.devices.collect(real.id, "x")).toThrow("no such");
    expect(() => f.devices.collect(real.id, real.pollSecret)).toThrow("Too many wrong attempts");
  });
});

describe("who may ask at home", () => {
  const names = new Set(["lobby.example.org"]);

  it("knows the names the server goes by", () => {
    for (const host of [
      "localhost:8674",
      "127.0.0.1",
      "192.168.1.5:8674",
      "100.64.0.10:8674",
      "203.0.113.5",
      "[::1]:8674",
      "[fd7a:115c:a1e0::1]:8674",
      "[fe80::1%en0]:8674",
      "lobby-7c3f9a12.local:8674",
      "Lobby-BFF534E1.LOCAL.",
      "media.example.ts.net:8674",
      "raspberrypi:8674",
      "media.lan",
      "media.home.arpa",
      "lobby.example.org",
      "lobby.example.org:8674",
    ]) {
      expect([host, isHomeHost(host, names)]).toEqual([host, true]);
    }
    for (const host of [
      "",
      "evil.example",
      "evil.example:8674",
      "192.168.1.5.evil.example",
      "local.evil.example",
      "evil.lobby.example.org",
      "evilts.net",
      "ts.net.evil.example",
      "a@192.168.1.5",
      "[::1].evil.example",
      "evil.example/x",
      "evil example",
      ":8674",
    ]) {
      expect([host, isHomeHost(host, names)]).toEqual([host, false]);
    }
  });

  it("refuses another name and another site over real connections, and lets the rest through", async () => {
    f.deps.addresses = () => ({ home: [], remote: ["https://lobby.example.org:8443"] });
    f.home = createApp(f.deps);
    const server = serve({ fetch: f.home.fetch, hostname: "127.0.0.1", port: 0 });
    await new Promise((done) => server.once("listening", done));
    const bound = server.address();
    const port = bound !== null && typeof bound === "object" ? bound.port : 0;
    const status = async (headers: string, path = "/v1/me"): Promise<number> => {
      const text = await raw(
        connect(port, "127.0.0.1"),
        `GET ${path} HTTP/1.1\r\n${headers}Authorization: Bearer ${f.manager.token}\r\nConnection: close\r\n\r\n`,
      );
      return Number(text.slice(9, 12));
    };
    expect(await status(`Host: 127.0.0.1:${port}\r\n`)).toBe(200);
    expect(await status(`Host: lobby-12345678.local:${port}\r\n`)).toBe(200);
    expect(await status(`Host: media.example.ts.net\r\n`)).toBe(200);
    expect(await status(`Host: lobby.example.org:8443\r\n`)).toBe(200);
    expect(await status(`Host: evil.example\r\n`)).toBe(403);
    expect(await status(`Host: evil.example\r\n`, "/v1/server")).toBe(403);
    expect(await status(`Host: evil.example\r\n`, "/nothing")).toBe(403);
    // The server's own page may ask; another site's may not.
    expect(await status(`Host: 10.0.0.5:8674\r\nOrigin: http://10.0.0.5:8674\r\n`)).toBe(200);
    for (const origin of ["http://evil.example", "null", "http://10.0.0.5:1", "nonsense"]) {
      expect(await status(`Host: 10.0.0.5:8674\r\nOrigin: ${origin}\r\n`)).toBe(403);
    }
    await new Promise((done) => server.close(done));
  });

  it("lets a fresh server be claimed with one tap at home or in the tailnet, and from nowhere else", async () => {
    const db = new Database(join(f.dir, "fresh.db"));
    const fresh = new Devices(db, "secret", Date.now, "open");
    f.home = createApp({ ...f.deps, db, devices: fresh });
    const body = { deviceName: "Mac", platform: "macos" };
    for (const far of ["8.8.8.8", "203.0.113.4", "2001:db8::4", "::ffff:8.8.8.8", "100.128.0.1"]) {
      const reply = await from(far, "POST", "/v1/pairing/claim", { body });
      expect([far, reply.status]).toEqual([far, 403]);
    }
    const page = { Origin: "http://evil.example", "Content-Type": "text/plain" };
    expect(
      (await from("192.168.1.4", "POST", "/v1/pairing/claim", { body, headers: page })).status,
    ).toBe(403);
    expect(fresh.isClaimed).toBe(false);
    expect((await from("192.168.1.4", "POST", "/v1/pairing/claim", { body })).status).toBe(201);
    db.close();
    for (const near of [
      "10.0.0.4",
      "172.20.1.1",
      "127.0.0.1",
      "::1",
      "100.64.0.10",
      "fd7a::1",
      "fe80::1%eth0",
    ]) {
      expect([near, isNearby(near)]).toEqual([near, true]);
    }
  });

  it("counts an address in one of the machine's own networks as near", () => {
    const lan = {
      eth0: [
        { address: "2001:db8:1:2::5", cidr: "2001:db8:1:2::5/64", family: "IPv6", internal: false },
        { address: "198.51.100.7", cidr: "198.51.100.7/32", family: "IPv4", internal: false },
      ],
    } as unknown as Parameters<typeof isNearby>[1];
    expect(isNearby("2001:db8:1:2::99", lan)).toBe(true);
    expect(isNearby("2001:db8:1:3::99", lan)).toBe(false);
    expect(isNearby("198.51.100.8", lan)).toBe(false);
    expect(isNearby("nonsense", lan)).toBe(false);
    expect(isNearby(null, lan)).toBe(false);
  });

  it("does not let the outside entrance's relay in at home", async () => {
    f.home = createApp({ ...f.deps, relays: ["10.9.0.1", "127.0.0.1"] });
    expect((await from("10.9.0.1", "GET", "/v1/server")).status).toBe(403);
    expect((await from("::ffff:10.9.0.1", "GET", "/v1/server")).status).toBe(403);
    expect((await from("10.9.0.2", "GET", "/v1/server")).status).toBe(200);
    expect((await from("127.0.0.1", "GET", "/v1/server")).status).toBe(200);
  });
});

describe("bodies", () => {
  it("have a length, also when they do not say it", async () => {
    const server = serve({ fetch: f.home.fetch, hostname: "127.0.0.1", port: 0 });
    await new Promise((done) => server.once("listening", done));
    const bound = server.address();
    const base = `http://127.0.0.1:${bound !== null && typeof bound === "object" ? bound.port : 0}`;
    const send = async (path: string, size: number, chunked: boolean): Promise<number> => {
      const text = JSON.stringify({
        name: "A",
        deviceName: "A",
        platform: "ios",
        x: "y".repeat(size),
      });
      const response = await fetch(`${base}${path}`, {
        method: "POST",
        headers: { Authorization: `Bearer ${f.manager.token}` },
        ...(chunked
          ? { body: new Blob([text]).stream(), duplex: "half" as const }
          : { body: text }),
      });
      await response.arrayBuffer();
      return response.status;
    };
    for (const chunked of [false, true]) {
      expect(await send("/v1/pairing/requests", 10_000, chunked)).toBe(201);
      expect(await send("/v1/pairing/requests", 20_000, chunked)).toBe(400);
      expect(await send("/v1/profiles", 1_900_000, chunked)).toBe(201);
      expect(await send("/v1/profiles", 2_200_000, chunked)).toBe(400);
    }
    await new Promise((done) => {
      server.close(done);
      if ("closeAllConnections" in server) server.closeAllConnections();
    });
  });
});

describe("a removed device", () => {
  it.each(["viewer", "manager"])("loses a film it is in the middle of (%s)", async (role) => {
    const path = join(f.dir, "Films/Long (2001)/Long (2001).mp4");
    makeVideo(path);
    truncateSync(path, 64 * 1024 * 1024);
    await f.scan();
    const asset = f.items[0]?.files[0]?.assetId ?? "";
    const device =
      role === "viewer"
        ? f.pair("TV", false)
        : ((made) => ({ id: made.device.id, token: made.token }))(
            f.devices.createLocalManager("Second"),
          );
    const response = await f.home.request(`/v1/assets/${asset}/content`, {
      headers: { Authorization: `Bearer ${device.token}` },
    });
    const reader = response.body?.getReader();
    expect((await reader?.read())?.done).toBe(false);
    f.devices.revoke(device.id);
    await new Promise((done) => setTimeout(done, 1_100));
    await expect(
      (async () => {
        while (!(await reader?.read())?.done);
      })(),
    ).rejects.toThrow();
  });

  it("keeps sending to a device that stays", async () => {
    const path = join(f.dir, "Films/Long (2001)/Long (2001).mp4");
    makeVideo(path);
    truncateSync(path, 8 * 1024 * 1024);
    await f.scan();
    const asset = f.items[0]?.files[0]?.assetId ?? "";
    const reply = await f.home.request(`/v1/assets/${asset}/content`, {
      headers: { Authorization: `Bearer ${f.manager.token}` },
    });
    expect((await reply.arrayBuffer()).byteLength).toBe(8 * 1024 * 1024);
  });
});

describe("queues", () => {
  it("run a few, keep some waiting, and refuse the rest", async () => {
    const gate = new Gate(2, 2);
    const ends: (() => void)[] = [];
    let running = 0;
    let most = 0;
    const work = (): Promise<void> =>
      gate.run(async () => {
        running += 1;
        most = Math.max(most, running);
        await new Promise<void>((done) => ends.push(done));
        running -= 1;
      });
    const all = [work(), work(), work(), work()];
    await expect(work()).rejects.toBeInstanceOf(BusyError);
    for (let n = 0; n < 4; n += 1) {
      await until(() => ends.length > n);
      ends[n]?.();
    }
    await Promise.all(all);
    expect(most).toBe(2);
    // One that fails gives its place back.
    await expect(gate.run(() => Promise.reject(new Error("no")))).rejects.toThrow("no");
    const again = [work(), work()];
    await until(() => ends.length === 6);
    ends.slice(4).forEach((end) => {
      end();
    });
    await Promise.all(again);
  });

  it("of files to prepare are bounded, and never refuse one that is there already", async () => {
    for (const name of ["A", "B", "C", "D"]) {
      makeMkv(join(f.dir, `Films/${name} (2010)/${name} (2010).mkv`));
    }
    await f.scan();
    // Waits for as long as it is let.
    const slow = join(f.dir, "slow.sh");
    writeFileSync(slow, "#!/bin/sh\nexec sleep 30\n", { mode: 0o755 });
    const playback = new PlaybackService({
      cacheDir: join(f.dir, "cache2"),
      minFreeBytes: 0,
      maxConcurrent: 1,
      maxQueued: 2,
      ffmpegPath: slow,
    });
    await playback.start();
    const app = createApp({ ...f.deps, playback });
    const start = async (index: number): Promise<Response> =>
      app.request(`/v1/assets/${f.items[index]?.files[0]?.assetId ?? ""}/playback`, {
        method: "POST",
        headers: { Authorization: `Bearer ${f.manager.token}` },
      });
    for (const index of [0, 1, 2]) expect((await start(index)).status).toBe(202);
    const over = await start(3);
    expect([over.status, over.headers.get("Retry-After")]).toEqual([429, "30"]);
    expect(await over.json()).toMatchObject({ error: { code: "rate_limited" } });
    expect((await start(2)).status).toBe(202);
    await playback.close();
  });

  it("of pictures and subtitles answer 429 when they are full", async () => {
    makeVideo(join(f.dir, "Films/One (2010)/One (2010).mp4"));
    for (const language of ["en", "nl"]) {
      writeFileSync(
        join(f.dir, `Films/One (2010)/One (2010).${language}.srt`),
        "1\n00:00:00,000 --> 00:00:00,500\nHello\n",
      );
    }
    await f.scan();
    const asset = await createAssetLookup(f.db)(f.items[0]?.files[0]?.assetId ?? "");
    const full = new Gate(0, 0);
    const playback = new PlaybackService({ cacheDir: join(f.dir, "cache3"), minFreeBytes: 0 });
    await playback.start();
    Object.assign(playback, { sidecarSubtitles: full });
    const artwork = new ArtworkStore(f.db, join(f.dir, "art2"), "ffmpeg");
    Object.assign(artwork, { gate: full });
    const app = createApp({ ...f.deps, playback, artwork });
    const get = (path: string): Promise<Response> =>
      Promise.resolve(
        app.request(path, { headers: { Authorization: `Bearer ${f.manager.token}` } }),
      );
    const subtitle = asset?.subtitles[0]?.id ?? "";
    expect((await get(`/v1/assets/${asset?.id ?? ""}/subtitles/${subtitle}.vtt`)).status).toBe(429);
    execFileSync("ffmpeg", [
      ..."-v error -f lavfi -i color=c=red:size=900x1350 -frames:v 1 -update 1".split(" "),
      join(f.dir, "art.jpg"),
    ]);
    f.db.run(
      `insert into artwork (id, item_id, kind, provider, local_path, width, height, selected)
       values ('art', ?, 'poster', 'frame', ?, 900, 1350, 1)`,
      [f.items[0]?.id ?? "", join(f.dir, "art.jpg")],
    );
    const picture = await get("/v1/artwork/art?w=200");
    expect([picture.status, picture.headers.get("Retry-After")]).toEqual([429, "10"]);
    await playback.close();
  });
});

describe("the log", () => {
  it("keeps no path out of a message", () => {
    for (const [text, kept] of [
      [
        "ENOENT: no such file or directory, realpath '/media/x/Bob's film (2009)/a.mkv'",
        "ENOENT: no such file or directory, realpath <path>",
      ],
      [
        "Command failed: ffprobe -v error /media/x/A film.mkv\n/media/x/A film.mkv: Invalid data found when processing input",
        "Command failed: ffprobe -v error <path>\n<path>: Invalid data found when processing input",
      ],
      [
        "[in#0 @ 0x1] Error opening input file /a/B: c.mkv.",
        "[in#0 @ 0x1] Error opening input file <path>",
      ],
      ['could not open "/a/b c.mkv"', "could not open <path>"],
      ["file:/a/b", "<path>"],
      [
        "GET https://api.example.org/3/search?query=Title failed",
        "GET https://api.example.org<path>",
      ],
      ["status 503", "status 503"],
      ["50 / 3 and/or nothing", "50 / 3 and/or nothing"],
    ] as const) {
      expect(withoutPaths(text)).toBe(kept);
    }
    expect(wholeLines(`${"x".repeat(4_000)}\nkept`)).toBe("kept");
    expect(wholeLines("short\nkept")).toBe("short\nkept");
  });

  it("does not name a household's file, whatever goes wrong with it", async () => {
    const lines: string[] = [];
    for (const level of ["log", "warn", "error"] as const) {
      vi.spyOn(console, level).mockImplementation((line: string) => {
        lines.push(line);
      });
    }
    const folder = join(f.dir, "Films/Secret Wedding (2001)");
    makeVideo(join(folder, "Secret Wedding (2001).mp4"));
    makeMkv(join(f.dir, "Films/Hidden Holiday (2003)/Hidden Holiday (2003).mkv"));
    mkdirSync(join(f.dir, "Films/Broken Birthday (2002)"));
    writeFileSync(
      join(f.dir, "Films/Broken Birthday (2002)/Broken Birthday (2002).mp4"),
      "no film",
    );
    writeFileSync(join(folder, "Secret Wedding (2001).srt"), "not a subtitle");
    await f.scan();
    const asset = f.items.find((one) => one.title === "Secret Wedding")?.files[0]?.assetId ?? "";
    const mkv = f.items.find((one) => one.title === "Hidden Holiday")?.files[0]?.assetId ?? "";
    const get = (path: string, method = "GET"): Promise<Response> =>
      Promise.resolve(
        f.home.request(path, { method, headers: { Authorization: `Bearer ${f.manager.token}` } }),
      );
    const lookup = await createAssetLookup(f.db)(asset);
    await get(`/v1/assets/${asset}/subtitles/${lookup?.subtitles[0]?.id ?? ""}.vtt`);
    rmSync(join(folder, "Secret Wedding (2001).mp4"));
    expect((await get(`/v1/assets/${asset}/content`)).status).toBe(503);
    symlinkSync("/etc/hosts", join(folder, "Secret Wedding (2001).mp4"));
    expect((await get(`/v1/assets/${asset}/content`)).status).toBe(503);
    truncateSync(join(f.dir, "Films/Hidden Holiday (2003)/Hidden Holiday (2003).mkv"), 500);
    await get(`/v1/assets/${mkv}/playback`, "POST");
    await until(() => lines.some((line) => line.includes("could not be prepared")));
    log.error("x", { error: `stat '${folder}/a.mp4'` });
    expect(lines.length).toBeGreaterThan(3);
    expect(lines.join("\n")).not.toMatch(/Wedding|Birthday|Holiday|\.mp4|\.mkv/);
  });
});

describe("a restored backup", () => {
  let backups: string;
  beforeEach(() => {
    backups = join(f.dir, "backups");
  });
  const at = Date.UTC(2026, 10, 24);

  it("does not bring back a device that was removed since, or the outside entrance", async () => {
    const tv = f.pair("TV", true);
    const phone = f.pair("Phone", false);
    f.devices.setRemote(phone.id, { remoteOutside: true, allowRemote: false });
    await f.outside.setEnabled(true);
    const asked = f.devices.startPairing("Asking", "ios");
    f.devices.approve(asked.code, "manager", "cli");
    const backup = await createBackup(f.db, backups, null, at);
    f.devices.revoke(tv.id);
    writeRevocations(backups, readRevocations(backups).set(tv.id, 5));

    const target = join(f.dir, "restored");
    const notes = restoreBackup(backup.path, target);
    expect(notes.join(" ")).toContain("stay removed: 1");
    const db = new Database(join(target, "lobby.db"));
    const restored = new Devices(db, "s");
    expect(() => restored.authenticate(tv.token)).toThrow("removed this device");
    expect(restored.authenticate(phone.token).id).toBe(phone.id);
    expect(restored.authenticate(f.manager.token).role).toBe("manager");
    expect(restored.list().some((one: Device) => one.allowOutside)).toBe(false);
    expect(restored.find(phone.id)).toMatchObject({ remoteOutside: false, allowRemote: false });
    expect(db.getMeta("outside_enabled")).toBe("off");
    expect(() => restored.collect(asked.id, asked.pollSecret)).toThrow("no such pairing request");
    db.close();
    // And stays known in the new place.
    expect(readRevocations(target).has(tv.id)).toBe(true);
    expect(existsSync(`${join(target, "lobby.db")}.restoring`)).toBe(false);
    expect(statSync(join(target, REVOKED_FILE)).mode & 0o077).toBe(0);
  });

  it("learns of removed devices from later backups too", async () => {
    const tv = f.pair("TV", false);
    const backup = await createBackup(f.db, backups, null, at);
    f.devices.revoke(tv.id);
    await createBackup(f.db, backups, null, at + 86_400_000);
    const target = join(f.dir, "restored");
    restoreBackup(join(backup.path, "lobby.db"), target);
    const db = new Database(join(target, "lobby.db"));
    expect(new Devices(db, "s").find(tv.id)?.revokedAt).not.toBeNull();
    db.close();
  });

  it("refuses to go on with a list it cannot read", async () => {
    const backup = await createBackup(f.db, backups, null, at);
    writeFileSync(join(backups, REVOKED_FILE), "{ half");
    const target = join(f.dir, "restored");
    expect(() => restoreBackup(backup.path, target)).toThrow("could come back");
    expect(existsSync(join(target, "lobby.db"))).toBe(false);
  });

  it("does not leave the server to whoever comes first when no manager is left", async () => {
    const backup = await createBackup(f.db, backups, null, at);
    f.devices.createLocalManager("New");
    f.devices.revoke(f.manager.id);
    writeRevocations(backups, new Map([[f.manager.id, 5]]));
    const target = join(f.dir, "restored");
    expect(restoreBackup(backup.path, target).join(" ")).toContain("setup secret");
    const db = new Database(join(target, "lobby.db"));
    const restored = new Devices(db, "the-secret", Date.now, "open");
    expect([restored.isClaimed, restored.claimMode]).toEqual([false, "secret"]);
    expect(() => restored.claim(null, "Stranger", "ios")).toThrow("not right");
    expect(restored.claim("the-secret", "Mac", "macos").device.role).toBe("manager");
    db.close();
  });

  it("has a list that the running server keeps", async () => {
    const { startServer } = await import("../src/server.ts");
    const { loadConfig } = await import("../src/config.ts");
    const dir = makeTempDir("lobby-run-");
    mkdirSync(join(dir, "films"));
    const path = join(dir, "lobby.config.json");
    writeFileSync(
      path,
      JSON.stringify({
        host: "127.0.0.1",
        port: 0,
        roots: [{ path: join(dir, "films"), name: "F", hint: "movies" }],
      }),
    );
    let running = await startServer(loadConfig(path));
    const made = running.services.devices.createLocalManager("A");
    running.services.devices.createLocalManager("B");
    running.services.devices.revoke(made.device.id);
    for (const place of ["data", "data/backups"]) {
      expect(readRevocations(join(dir, place)).has(made.device.id)).toBe(true);
    }
    await running.close();
    rmSync(join(dir, "data", REVOKED_FILE));
    running = await startServer(loadConfig(path));
    expect(readFileSync(join(dir, "data", REVOKED_FILE), "utf8")).toContain(made.device.id);
    await running.close();
    removeDir(dir);
  });
});
