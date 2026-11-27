// SPDX-License-Identifier: MPL-2.0
import {
  copyFileSync,
  chmodSync,
  mkdtempSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { connect, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { connect as tlsConnect, type TLSSocket } from "node:tls";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.ts";
import type { OutsideTlsConfig } from "../src/outside/config.ts";
import { RelayTransport } from "../src/outside/index.ts";
import { readProxyHeader } from "../src/outside/proxy.ts";
import { ask, NAME, OutsideFixture, raw, until } from "./support/outside.ts";
import { makeCertificate } from "./support/tls.ts";

const SIGNATURE = Buffer.from("0d0a0d0a000d0a515549540a", "hex");

function header(options: { command?: number; family?: number; body?: Buffer } = {}): Buffer {
  const body = options.body ?? Buffer.from([203, 0, 113, 9, 10, 0, 0, 1, 1, 2, 1, 187]);
  const fixed = Buffer.alloc(4);
  fixed[0] = options.command ?? 0x21;
  fixed[1] = options.family ?? 0x11;
  fixed.writeUInt16BE(body.length, 2);
  return Buffer.concat([SIGNATURE, fixed, body]);
}
const address6 = Buffer.concat([
  Buffer.from("20010db8000100020000000000000009", "hex"),
  Buffer.alloc(16, 1),
  Buffer.alloc(4, 1),
]);

describe("the relay's header", () => {
  it("is read whole, in pieces and with extras", () => {
    const whole = Buffer.concat([header(), Buffer.from("TLS")]);
    expect(readProxyHeader(whole)).toEqual({ state: "ok", address: "203.0.113.9", length: 28 });
    for (let at = 0; at < 28; at += 1) {
      expect(readProxyHeader(whole.subarray(0, at)).state).toBe("more");
    }
    expect(readProxyHeader(header({ family: 0x21, body: address6 }))).toMatchObject({
      state: "ok",
      address: "2001:db8:1:2:0:0:0:9",
    });
    const extra = Buffer.concat([
      Buffer.from([203, 0, 113, 9, 10, 0, 0, 1, 1, 2, 1, 187]),
      Buffer.from([0x04, 0, 2, 9, 9]),
    ]);
    expect(readProxyHeader(header({ body: extra }))).toMatchObject({ state: "ok", length: 33 });
  });

  it("is refused in every other shape", () => {
    const four = Buffer.from([203, 0, 113, 9, 10, 0, 0, 1, 1, 2, 1, 187]);
    for (const bad of [
      Buffer.from("PROXY TCP4 203.0.113.9 10.0.0.1 1 2\r\n"),
      Buffer.from("GET / HTTP/1.1\r\n"),
      Buffer.from([0x16, 3, 1]),
      header({ command: 0x20 }),
      header({ command: 0x11 }),
      header({ command: 0x2f }),
      header({ family: 0x00 }),
      header({ family: 0x12 }),
      header({ family: 0x31 }),
      header({ family: 0x21 }),
      header({ body: four.subarray(0, 11) }),
      header({ body: Buffer.alloc(513, 1) }),
      header({ body: Buffer.concat([four, Buffer.from([4, 0])]) }),
      header({ body: Buffer.concat([four, Buffer.from([4, 0, 9, 1])]) }),
      header({ body: Buffer.alloc(12) }),
      header({ body: Buffer.concat([Buffer.from([224, 0, 0, 1]), four.subarray(4)]) }),
      header({ family: 0x21, body: Buffer.alloc(36) }),
    ]) {
      expect([bad.toString("hex"), readProxyHeader(bad).state]).toEqual([
        bad.toString("hex"),
        "wrong",
      ]);
    }
  });
});

describe("the road over a relay", () => {
  let dir: string;
  let f: OutsideFixture;
  let transport: RelayTransport;
  let config: OutsideTlsConfig;
  let ca: Buffer;
  let token: string;
  const clock = { ahead: 0 };

  beforeEach(async () => {
    clock.ahead = 0;
    dir = mkdtempSync(join(tmpdir(), "lobby-relay-"));
    const files = makeCertificate(dir, NAME);
    ca = readFileSync(files.certFile);
    config = { host: "127.0.0.1", port: await freePort(), relays: ["127.0.0.1"], ...files };
    transport = new RelayTransport(config, NAME, () => Date.now() + clock.ahead);
    f = new OutsideFixture({}, [transport]);
    await f.start();
    token = f.pair("Far TV", true).token;
  });
  afterEach(async () => {
    await f.stop();
    rmSync(dir, { recursive: true, force: true });
  });

  const tcp = (): Socket => connect(config.port, config.host);
  const secure = (options: object = {}, first: Buffer[] = [header()]): TLSSocket => {
    const socket = tcp();
    for (const part of first) socket.write(part);
    return tlsConnect({ socket, servername: NAME, ca, ALPNProtocols: ["http/1.1"], ...options });
  };
  const failed = (socket: TLSSocket): Promise<string> =>
    new Promise((resolve) => {
      socket.on("secureConnect", () => {
        resolve("connected");
        socket.destroy();
      });
      socket.on("error", () => {
        resolve("refused");
      });
      socket.on("close", () => {
        resolve("refused");
      });
    });

  it("carries requests over TLS, with the visitor's own address", async () => {
    const reply = await ask(() => secure(), "GET", "/v1/me", { token });
    expect(reply.status).toBe(200);
    expect(reply.headers["strict-transport-security"]).toBe("max-age=31536000");
    expect((await ask(() => secure(), "GET", "/v1/server")).status).toBe(404);
    const [stranger, device] = f.outside.access.read(10, null);
    expect([stranger?.address, device?.address, device?.transport]).toEqual([
      "203.0.113.9",
      "203.0.113.9",
      "relay",
    ]);
    const bytes = header({ family: 0x21, body: address6 });
    const socket = tcp();
    socket.setNoDelay(true);
    for (const part of [bytes.subarray(0, 7), bytes.subarray(7, 30), bytes.subarray(30)]) {
      socket.write(part);
      await new Promise((done) => setTimeout(done, 30));
    }
    const tls = tlsConnect({ socket, servername: NAME, ca });
    expect((await ask(() => tls, "GET", "/v1/me", { token })).status).toBe(200);
    expect(f.outside.access.read(1, null)[0]?.address).toBe("2001:db8:1:2:0:0:0:9");
  });

  it("speaks TLS 1.2 and up, HTTP/1.1, and shows its certificate to who knows the name", async () => {
    expect(await failed(secure())).toBe("connected");
    expect(await failed(secure({ maxVersion: "TLSv1.2" }))).toBe("connected");
    expect(
      await failed(
        secure({ minVersion: "TLSv1", maxVersion: "TLSv1.1", ciphers: "DEFAULT@SECLEVEL=0" }),
      ),
    ).toBe("refused");
    expect(await failed(secure({ maxVersion: "TLSv1.2", ciphers: "AES128-SHA" }))).toBe("refused");
    expect(
      await failed(secure({ maxVersion: "TLSv1.2", ciphers: "ECDHE-RSA-AES128-SHA256" })),
    ).toBe("refused");
    expect(
      await failed(secure({ servername: "other.example.test", rejectUnauthorized: false })),
    ).toBe("refused");
    expect(await failed(secure({ servername: "", rejectUnauthorized: false }))).toBe("refused");
    expect(await failed(secure({ ALPNProtocols: ["h2"] }))).toBe("refused");
  });

  it("drops whoever is not the relay, or does not send its header", async () => {
    expect(await failed(secure({}, []))).toBe("refused");
    expect(await failed(secure({}, [header({ command: 0x20 })]))).toBe("refused");
    expect(await raw(tcp(), "GET / HTTP/1.1\r\nHost: x\r\n\r\n")).toBe("");
    const port = await freePort();
    const other = new RelayTransport({ ...config, port, relays: ["10.1.2.3"] }, NAME);
    let accepted = 0;
    await other.open(() => (accepted += 1));
    expect(other.status().open).toBe(true);
    const socket = connect(port, "127.0.0.1");
    expect(await raw(socket, header())).toBe("");
    expect(accepted).toBe(0);
    await other.close();
  });

  it("ends a connection that does not finish its handshake", async () => {
    const started = Date.now();
    const socket = tcp();
    expect(await raw(socket, SIGNATURE.subarray(0, 4))).toBe("");
    expect(Date.now() - started).toBeGreaterThan(9_000);
  }, 20_000);

  it("takes a renewed certificate, and keeps the old one while the new one is no good", async () => {
    const renewed = makeCertificate(dir, NAME, "renewed");
    writeFileSync(config.certFile, "half a certificate");
    await transport.check();
    expect(transport.status()).toEqual({ open: true, problem: null });
    expect(await failed(secure())).toBe("connected");
    renameSync(renewed.keyFile, config.keyFile);
    renameSync(renewed.certFile, config.certFile);
    await transport.check();
    expect(await failed(secure())).toBe("refused");
    ca = readFileSync(config.certFile);
    expect(await failed(secure())).toBe("connected");
  });

  it("closes when the certificate expires, and opens again with a new one", async () => {
    const live = secure();
    live.on("error", () => undefined);
    let closed = false;
    live.on("close", () => (closed = true));
    live.resume();
    await new Promise((done) => live.once("secureConnect", done));
    clock.ahead = 31 * 86_400_000;
    await transport.check();
    expect(transport.status()).toEqual({
      open: false,
      problem: "the certificate is not valid at this time",
    });
    await until(() => closed);
    await expect(ask(() => secure(), "GET", "/v1/me", { token })).rejects.toThrow();
    clock.ahead = 0;
    await transport.check();
    expect((await ask(() => secure(), "GET", "/v1/me", { token })).status).toBe(200);
  });

  it("does not open without a certificate that fits", async () => {
    const good = { ...config, port: await freePort() };
    const another = makeCertificate(dir, "other.example.test", "another");
    const open = join(dir, "open.key");
    copyFileSync(config.keyFile, open);
    chmodSync(open, 0o644);
    for (const [files, problem] of [
      [{ certFile: join(dir, "none") }, "the certificate or its key is not there"],
      [another, "the certificate is for another name"],
      [{ keyFile: another.keyFile }, "the key does not belong to the certificate"],
      [{ keyFile: open }, "the key can be read by everybody on this machine"],
      [{ host: "10.254.254.254" }, /EADDRNOTAVAIL/],
    ] as const) {
      const one = new RelayTransport({ ...good, ...files }, NAME);
      await one.open(() => undefined);
      expect(one.status().open).toBe(false);
      expect(one.status().problem).toMatch(problem);
      await one.close();
    }
  });

  it("is cut by the switch", async () => {
    const socket = secure();
    let closed = false;
    socket.on("close", () => (closed = true));
    socket.on("error", () => undefined);
    socket.resume();
    await new Promise((done) => socket.once("secureConnect", done));
    await f.outside.setEnabled(false);
    await until(() => closed);
    await expect(ask(() => secure(), "GET", "/v1/me", { token })).rejects.toThrow();
  });
});

describe("the config", () => {
  it("is off by default, and refuses addresses anyone can reach", () => {
    const dir = mkdtempSync(join(tmpdir(), "lobby-config-"));
    const path = join(dir, "lobby.config.json");
    const read = (outside: unknown) => {
      writeFileSync(
        path,
        JSON.stringify({ roots: [{ path: "/films", name: "F", hint: "movies" }], outside }),
      );
      return loadConfig(path).outside;
    };
    const tls = {
      host: "10.9.0.2",
      port: 8675,
      relays: ["10.9.0.1"],
      certFile: "cert.pem",
      keyFile: "/k.pem",
    };
    expect(read(undefined)).toBeNull();
    expect(read({ name: NAME, tls })).toBeNull();
    expect(read({ enabled: false, name: 5 })).toBeNull();
    expect(read({ enabled: true, name: NAME })).toEqual({ name: NAME, direct: null, tls: null });
    expect(read({ enabled: true, name: NAME, tls })).toEqual({
      name: NAME,
      direct: null,
      tls: { ...tls, certFile: join(dir, "cert.pem") },
    });
    for (const host of [
      "0.0.0.0",
      "::",
      "::0",
      "0:0:0:0:0:0:0:0",
      "::ffff:0.0.0.0",
      "0",
      "",
      "localhost",
      "203.0.113.4",
      "2001:db8::1",
      "224.0.0.1",
      "169.254.1.1",
      "fe80::1",
    ]) {
      expect(() => read({ enabled: true, name: NAME, tls: { ...tls, host } })).toThrow(
        "outside.tls.host",
      );
    }
    for (const wrong of [
      { relays: [] },
      { relays: ["203.0.113.4"] },
      { relays: ["0.0.0.0"] },
      { relays: "10.9.0.1" },
      { port: 8674 },
      { port: 0 },
      { certFile: "" },
    ]) {
      expect(() => read({ enabled: true, name: NAME, tls: { ...tls, ...wrong } })).toThrow(
        "outside.tls",
      );
    }
    for (const name of [
      "",
      "lobby",
      "10.0.0.1",
      "Lobby.Example.test",
      "a b.example.test",
      "x.test:443",
    ]) {
      expect(() => read({ enabled: true, name, tls })).toThrow("outside.name");
    }
    expect(() => read({ enabled: "yes", name: NAME })).toThrow("outside.enabled");
    rmSync(dir, { recursive: true });
  });
});

async function freePort(): Promise<number> {
  const { createServer } = await import("node:net");
  const server = createServer();
  await new Promise<void>((done) => server.listen(0, "127.0.0.1", done));
  const address = server.address();
  await new Promise((done) => server.close(done));
  return address !== null && typeof address === "object" ? address.port : 0;
}
