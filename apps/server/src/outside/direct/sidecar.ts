// SPDX-License-Identifier: MPL-2.0
import { spawn, type ChildProcessByStdio } from "node:child_process";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { chmodSync, mkdtempSync, rmSync, statSync } from "node:fs";
import { createServer, type Server, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import type { Readable, Writable } from "node:stream";
import { log } from "../../log.ts";

const FIRST_WAIT_MS = 1_000;
const LAST_WAIT_MS = 60_000;
const SETTLED_MS = 60_000;
const READY_MS = 10_000;
const HELLO_MS = 5_000;
const MAX_HELLO = 256;
const MAX_LINE = 64 * 1024;
/** What Node may hold of a film for a device that does not read. */
const BUFFER = 16 * 1024;
/** More than all devices' streams together. */
const MAX_SOCKETS = 512;

type Child = ChildProcessByStdio<Writable, Readable, Readable>;

export interface SidecarOptions {
  binary: string;
  boxId: string;
  certificate: () => { chain: string[]; key: string };
  maxUploadMbit: number | null;
  /** A whole line from the sidecar. */
  said: (message: Record<string, unknown>) => void;
  /** A stream of a session, already past its first line. */
  stream: (session: string, socket: Socket) => void;
  /** It went away, and with it every session. */
  gone: () => void;
}

/**
 * The program that speaks ICE and QUIC: kept running, and the only one that can reach the socket
 * it brings the streams to. That socket lies in a folder only this user can enter, and every
 * connection starts with a secret that is made anew for every run and told over stdin.
 */
export class Sidecar {
  private readonly options: SidecarOptions;
  private child: Child | null = null;
  private server: Server | null = null;
  private dir: string | null = null;
  private secret = Buffer.alloc(0);
  private readonly sockets = new Set<Socket>();
  private timer: NodeJS.Timeout | null = null;
  private attempt = 0;
  private startedAt = 0;
  private ready = false;
  private stopped = true;
  problem: string | null = null;

  constructor(options: SidecarOptions) {
    this.options = options;
  }

  get isUp(): boolean {
    return this.ready;
  }

  async start(): Promise<void> {
    if (!this.stopped) return;
    this.stopped = false;
    this.attempt = 0;
    this.dir = mkdtempSync(join(tmpdir(), "lobby-direct-"));
    chmodSync(this.dir, 0o700);
    const path = join(this.dir, "s");
    const server = createServer({ highWaterMark: BUFFER }, (socket) => {
      this.receive(socket);
    });
    server.maxConnections = MAX_SOCKETS;
    this.server = server;
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(path, resolve);
    });
    chmodSync(path, 0o600);
    this.run(path);
  }

  async stop(): Promise<void> {
    if (this.stopped) return;
    this.stopped = true;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    const child = this.child;
    this.child = null;
    this.ready = false;
    for (const socket of this.sockets) socket.destroy();
    if (child && child.exitCode === null && child.signalCode === null) {
      const exited = new Promise((done) => child.once("exit", done));
      // It says goodbye to the devices when its stdin ends.
      child.stdin.end();
      const kill = setTimeout(() => child.kill("SIGKILL"), 2_000);
      await exited;
      clearTimeout(kill);
    }
    const server = this.server;
    this.server = null;
    if (server?.listening) await new Promise((done) => server.close(done));
    if (this.dir !== null) rmSync(this.dir, { recursive: true, force: true });
    this.dir = null;
  }

  /** Also while it starts: it reads what it was told in order. */
  tell(message: object): void {
    this.child?.stdin.write(`${JSON.stringify(message)}\n`);
  }

  private run(path: string): void {
    if (this.stopped) return;
    const { binary, boxId, certificate, maxUploadMbit } = this.options;
    try {
      const info = statSync(binary);
      if (!info.isFile()) throw new Error("not a file");
      if ((info.mode & 0o022) !== 0) {
        this.fail(path, "the lobby-direct program can be changed by others on this machine");
        return;
      }
    } catch {
      this.fail(path, "the lobby-direct program is not there");
      return;
    }
    this.startedAt = Date.now();
    this.secret = Buffer.from(randomBytes(32).toString("hex"));
    const child = spawn(binary, [], { stdio: ["pipe", "pipe", "pipe"], cwd: "/", env: {} });
    this.child = child;
    const late = setTimeout(() => child.kill("SIGKILL"), READY_MS);
    let ended = false;
    const end = (problem: string): void => {
      if (ended) return;
      ended = true;
      clearTimeout(late);
      if (this.child !== child) return;
      this.child = null;
      const wasReady = this.ready;
      this.ready = false;
      for (const socket of this.sockets) socket.destroy();
      if (wasReady) this.options.gone();
      this.fail(path, problem);
    };
    child.on("error", () => {
      end("the lobby-direct program cannot be started");
    });
    child.on("exit", (code) => {
      end(`the lobby-direct program stopped (${String(code ?? "killed")})`);
    });
    // Written to a program that is gone; its exit says so.
    child.stdin.on("error", () => undefined);
    createInterface({ input: child.stderr }).on("line", (line) => {
      if (line.startsWith("lobby-direct: ")) log.warn("From lobby-direct", { problem: line });
    });
    createInterface({ input: child.stdout }).on("line", (line) => {
      if (this.child !== child || line.length > MAX_LINE) return;
      let message: Record<string, unknown>;
      try {
        message = JSON.parse(line) as Record<string, unknown>;
      } catch {
        return;
      }
      if (message["event"] === "ready") {
        clearTimeout(late);
        this.ready = true;
        this.problem = null;
        log.info("lobby-direct is running");
        return;
      }
      this.options.said(message);
    });
    child.stdin.write(
      `${JSON.stringify({
        op: "start",
        socket: path,
        secret: this.secret.toString("ascii"),
        boxId,
        ...certificate(),
        maxUploadBits: Math.round((maxUploadMbit ?? 0) * 1_000_000),
      })}\n`,
    );
  }

  private fail(path: string, problem: string): void {
    if (this.stopped) return;
    if (problem !== this.problem) log.error("The direct road is down", { problem });
    this.problem = problem;
    if (Date.now() - this.startedAt >= SETTLED_MS) this.attempt = 0;
    const wait = Math.min(LAST_WAIT_MS, FIRST_WAIT_MS * 2 ** Math.min(this.attempt, 10));
    this.attempt += 1;
    this.timer = setTimeout(
      () => {
        this.run(path);
      },
      wait * (0.75 + Math.random() / 2),
    );
  }

  /** Reads the first line, and nothing past it. */
  private receive(socket: Socket): void {
    this.sockets.add(socket);
    socket.on("error", () => undefined);
    const timer = setTimeout(() => socket.destroy(), HELLO_MS);
    socket.once("close", () => {
      clearTimeout(timer);
      this.sockets.delete(socket);
    });
    let held = Buffer.alloc(0);
    const read = (): void => {
      const data = socket.read() as Buffer | null;
      if (!data) return;
      held = Buffer.concat([held, data]);
      const end = held.indexOf(10);
      if (end === -1 && held.length <= MAX_HELLO) return;
      socket.off("readable", read);
      clearTimeout(timer);
      const session = end === -1 || end > MAX_HELLO ? null : this.hello(held.subarray(0, end));
      if (session === null) {
        socket.destroy();
        return;
      }
      const rest = held.subarray(end + 1);
      if (rest.length > 0) socket.unshift(rest);
      this.options.stream(session, socket);
    };
    socket.on("readable", read);
  }

  private hello(line: Buffer): string | null {
    const [version, secret = "", session = "", ...more] = line.toString("latin1").split(" ");
    const shown = Buffer.from(secret, "latin1");
    const same = shown.length === this.secret.length && timingSafeEqual(shown, this.secret);
    return this.ready && same && version === "LOBBY/1" && more.length === 0 ? session : null;
  }
}
