// SPDX-License-Identifier: MPL-2.0
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createSocket, type Socket as UdpSocket } from "node:dgram";
import {
  createPublicKey,
  generateKeyPairSync,
  randomBytes,
  sign,
  type KeyObject,
} from "node:crypto";
import { existsSync } from "node:fs";
import { connect, type Socket } from "node:net";
import { join } from "node:path";
import { createInterface } from "node:readline";
import type { Readable } from "node:stream";
import type { DirectConfig } from "../../src/outside/direct/config.ts";
import {
  agree,
  b64,
  enrolledSecret,
  introductionAad,
  introductionKeys,
  newAgreementKey,
  open,
  rawPublic,
  seal,
  unb64,
} from "../../src/outside/direct/envelope.ts";
import { BoxKeys } from "../../src/outside/direct/keys.ts";
import { DirectTransport } from "../../src/outside/direct/index.ts";
import { makeTempDir, removeDir } from "./media.ts";
import { ask, NAME, OutsideFixture, until, type Ask, type OutsideReply } from "./outside.ts";

const CRATE = join(import.meta.dirname, "../../../direct");
const INTRODUCER = join(import.meta.dirname, "../../../introducer/src/node.ts");

export interface Programs {
  sidecar: string;
  device: string;
}

/** The real programs: built when there is a cargo to build them with. Null when there is not. */
export function programs(): Programs | null {
  const given = process.env["LOBBY_DIRECT_TARGET"];
  const target = given ?? join(CRATE, "target", "release");
  const found = {
    sidecar: join(target, "lobby-direct"),
    device: join(target, "examples", "device"),
  };
  if (given === undefined) {
    const built = spawnSync(
      "cargo",
      [
        "build",
        "--release",
        "--locked",
        "--bins",
        "--examples",
        "--manifest-path",
        join(CRATE, "Cargo.toml"),
      ],
      { encoding: "utf8" },
    );
    if (built.error) {
      console.warn(
        "SKIPPED: the direct connection end to end. There is no cargo here to build lobby-direct.",
      );
      return null;
    }
    if (built.status !== 0) throw new Error(`lobby-direct does not build:\n${built.stderr}`);
  }
  if (!existsSync(found.sidecar) || !existsSync(found.device)) {
    throw new Error(`There is no lobby-direct in ${target}.`);
  }
  return found;
}

export interface RunningIntroducer {
  url: string;
  port: number;
  stop: () => Promise<void>;
}

/** The introducer itself, as its owner runs it. */
export async function runIntroducer(
  boxes: string[],
  port = 0,
  env: Record<string, string> = {},
): Promise<RunningIntroducer> {
  const child = spawn(process.execPath, [INTRODUCER], {
    env: { PATH: process.env["PATH"], BOXES: boxes.join(","), PORT: String(port), ...env },
    stdio: ["ignore", "pipe", "inherit"],
  });
  const at = await new Promise<number>((resolve, reject) => {
    child.once("exit", () => {
      reject(new Error("the introducer stopped"));
    });
    createInterface({ input: child.stdout }).on("line", (line) => {
      const found = /port (\d+)/.exec(line)?.[1];
      if (found !== undefined) resolve(Number(found));
    });
  });
  return {
    port: at,
    url: `ws://127.0.0.1:${at}`,
    stop: async () => {
      const gone = new Promise((done) => child.once("exit", done));
      child.kill("SIGKILL");
      await gone;
    },
  };
}

/** A server with the direct road, on one machine. */
export class DirectFixture {
  readonly dataDir = makeTempDir("lobby-direct-data-");
  f!: OutsideFixture;
  direct!: DirectTransport;
  introducer!: RunningIntroducer;
  /** Made at once, so that an introducer for several servers can know them all. */
  readonly keys = new BoxKeys(this.dataDir);
  readonly people: TestDevice[] = [];
  private ownIntroducer = true;

  /** @param introducer one that is shared with other servers, and stopped by whoever made it */
  async start(
    sidecar: string,
    config: Partial<DirectConfig> = {},
    introducer?: RunningIntroducer,
  ): Promise<void> {
    this.ownIntroducer = introducer === undefined;
    this.introducer = introducer ?? (await runIntroducer([this.keys.boxId]));
    this.f = new OutsideFixture({}, [], ({ db, devices, pairing, now }) => {
      this.direct = new DirectTransport({
        config: {
          introducer: this.introducer.url,
          stun: [],
          turn: null,
          bind: "127.0.0.1",
          maxUploadMbit: null,
          binary: sidecar,
          ...config,
        },
        db,
        devices,
        pairing,
        now,
        dataDir: this.dataDir,
        name: NAME,
        // There is no address of the internet on one machine.
        keepAddress: () => true,
      });
      return this.direct;
    });
    await this.f.start();
    await until(() => this.direct.directStatus().introducer);
  }

  async stop(): Promise<void> {
    for (const one of this.people) one.stop();
    await this.f.stop();
    if (this.ownIntroducer) await this.introducer.stop();
    removeDir(this.dataDir);
  }

  /** A device that enrolled at home. */
  async device(name: string, outside = true): Promise<TestDevice> {
    const paired = this.f.pair(name, outside);
    const device = new TestDevice(this.introducer.url, paired.id, paired.token);
    this.people.push(device);
    await device.enrol(this.f);
    await this.told();
    return device;
  }

  /** The list of who may ring is sent every second or so; now is better. */
  async told(): Promise<void> {
    this.f.outside.recheck();
    await new Promise((done) => setTimeout(done, 100));
  }
}

export interface Identity {
  introducer: string;
  boxId: string;
  boxKey: string;
  fingerprints: string[];
  name: string;
}

/** Where a conversation goes wrong, on purpose. */
export interface Faults {
  hello?: (payload: string) => string;
  offer?: (payload: string) => string;
  /** Session to bind to, instead of the one it is. */
  session?: string;
  fingerprint?: string;
  proof?: "none" | "replayed";
  seed?: Buffer;
  /** Changes where the device thinks the box is, and the other way round. */
  road?: Shim;
}

export interface Up {
  port: number;
  local: string;
  remote: string;
}

type Message = Record<string, unknown>;

/** A line at the introducer, as a device has one. */
export class Line {
  readonly socket: WebSocket;
  /** Everything that went over it, as the introducer saw it. */
  readonly seen: string[] = [];
  private readonly waiting: ((message: Message | number) => void)[] = [];
  private readonly held: (Message | number)[] = [];

  constructor(url: string) {
    this.socket = new WebSocket(url);
    this.socket.addEventListener("message", (event: MessageEvent) => {
      const text = String(event.data);
      this.seen.push(text);
      this.give(JSON.parse(text) as Message);
    });
    this.socket.addEventListener("error", () => undefined);
    this.socket.addEventListener("close", (event) => {
      this.give(event.code);
    });
  }

  private give(message: Message | number): void {
    const next = this.waiting.shift();
    if (next) next(message);
    else this.held.push(message);
  }

  say(message: object): void {
    const text = JSON.stringify(message);
    this.seen.push(text);
    this.socket.send(text);
  }

  next(ms = 5_000): Promise<Message | number> {
    const held = this.held.shift();
    if (held !== undefined) return Promise.resolve(held);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error("nothing was said"));
      }, ms);
      this.waiting.push((message) => {
        clearTimeout(timer);
        resolve(message);
      });
    });
  }

  async silent(ms = 400): Promise<boolean> {
    await new Promise((done) => setTimeout(done, ms));
    return this.held.length === 0;
  }

  close(): void {
    this.socket.close();
  }
}

/** A device, as the apps are one. */
export class TestDevice {
  readonly id: string;
  readonly token: string;
  readonly ring: KeyObject = generateKeyPairSync("ed25519").privateKey;
  readonly ringKey: string;
  readonly lines: Line[] = [];
  identity!: Identity;
  secret!: Buffer;
  private readonly introducer: string;
  private readonly children: ChildProcess[] = [];
  up: Up | null = null;
  /** Why it is not connected any more. */
  down: string | null = null;

  constructor(introducer: string, id: string, token: string) {
    this.introducer = introducer;
    this.id = id;
    this.token = token;
    this.ringKey = b64(rawPublic(createPublicKey(this.ring)));
  }

  get seed(): Buffer {
    return this.ring.export({ format: "der", type: "pkcs8" }).subarray(-32);
  }

  async enrol(f: OutsideFixture): Promise<void> {
    const own = newAgreementKey();
    const ours = rawPublic(own);
    const reply = await f.atHome(this.token, "PUT", "/v1/me/direct", {
      ringKey: this.ringKey,
      agreementKey: b64(ours),
    });
    if (reply.status !== 200) throw new Error(`could not enrol: ${reply.status}`);
    const { agreementKey, ...identity } = reply.json<Identity & { agreementKey: string }>();
    const theirs = unb64(agreementKey, 32);
    if (!theirs) throw new Error("no agreement key");
    this.identity = identity;
    this.secret = enrolledSecret(agree(own, theirs), ours, theirs, identity.boxId, this.ringKey);
  }

  /** Signs in at the introducer. A number is why it could not. */
  async ringUp(key: KeyObject = this.ring): Promise<{ line: Line; session: string } | number> {
    const { boxId } = this.identity;
    const line = new Line(`${this.introducer}/v1/box/${boxId}`);
    this.lines.push(line);
    const challenge = await line.next();
    if (typeof challenge === "number") return challenge;
    const signed = `lobby-introducer/1|device|${boxId}|${String(challenge["nonce"])}`;
    line.say({
      t: "auth",
      role: "device",
      key: b64(rawPublic(createPublicKey(key))),
      signature: b64(sign(null, Buffer.from(signed), key)),
    });
    const ready = await line.next();
    if (typeof ready === "number") return ready;
    return { line, session: String(ready["session"]) };
  }

  /** Says hello, and gets a welcome. Null when nobody answers. */
  async greet(
    line: Line,
    session: string,
    faults: Faults = {},
  ): Promise<{ nonce: Buffer; boxNonce: Buffer; welcome: Message; payload: string } | null> {
    const place = {
      boxId: this.identity.boxId,
      ringKey: this.ringKey,
      session: faults.session ?? session,
    };
    const nonce = randomBytes(32);
    const payload = seal(introductionKeys.hello(this.secret), introductionAad(place, "d2b", 0), {
      t: "hello",
      nonce: b64(nonce),
    });
    line.say({ t: "msg", p: faults.hello?.(payload) ?? payload });
    const answer = await line.next(1_500).catch(() => null);
    if (answer === null || typeof answer === "number") return null;
    const welcome = open(
      introductionKeys.welcome(this.secret, nonce),
      introductionAad(place, "b2d", 0),
      answer["p"],
    );
    const boxNonce = unb64(welcome?.["nonce"], 32);
    if (!welcome || !boxNonce) throw new Error("the welcome is not from the box");
    return { nonce, boxNonce, welcome, payload };
  }

  sealOffer(session: string, nonce: Buffer, boxNonce: Buffer, sdp: string): string {
    const place = { boxId: this.identity.boxId, ringKey: this.ringKey, session };
    return seal(
      introductionKeys.session(this.secret, nonce, boxNonce, "d2b"),
      introductionAad(place, "d2b", 1),
      { t: "offer", sdp },
    );
  }

  openAnswer(session: string, nonce: Buffer, boxNonce: Buffer, payload: unknown): Message | null {
    const place = { boxId: this.identity.boxId, ringKey: this.ringKey, session };
    return open(
      introductionKeys.session(this.secret, nonce, boxNonce, "b2d"),
      introductionAad(place, "b2d", 1),
      payload,
    );
  }

  /** The whole way, with the real programs. */
  async connect(device: string, faults: Faults = {}): Promise<Up> {
    const rung = await this.ringUp();
    if (typeof rung === "number") throw new Error(`refused: ${rung}`);
    const { line, session } = rung;
    const greeted = await this.greet(line, session, faults);
    if (!greeted) throw new Error("no welcome");
    const { nonce, boxNonce, welcome } = greeted;

    const child = spawn(device, [], { stdio: ["pipe", "pipe", "inherit"] });
    this.children.push(child);
    const heard = new Heard(child.stdout, (reason) => (this.down = reason));
    const say = (message: object): void => {
      child.stdin.write(`${JSON.stringify(message)}\n`);
    };
    say({ op: "gather", bind: "127.0.0.1" });
    const offer = await heard.event("offer");
    let sdp = String(offer["sdp"]);
    if (faults.road) sdp = faults.road.offer(sdp);
    const payload = this.sealOffer(session, nonce, boxNonce, sdp);
    line.say({ t: "msg", p: faults.offer?.(payload) ?? payload });
    const said = await line.next(8_000);
    if (typeof said === "number") throw new Error(`closed: ${said}`);
    const answer = this.openAnswer(session, nonce, boxNonce, said["p"]);
    if (answer?.["t"] !== "answer") throw new Error(`no answer: ${JSON.stringify(answer)}`);
    let theirs = String(answer["sdp"]);
    if (faults.road) theirs = faults.road.answer(theirs);
    line.close();
    say({
      op: "connect",
      sdp: theirs,
      fingerprint: faults.fingerprint ?? (welcome["fingerprints"] as string[])[0],
      seed: b64(faults.seed ?? this.seed),
      boxId: this.identity.boxId,
      proof: faults.proof ?? "",
    });
    const up = await heard.event("up", 25_000);
    this.down = null;
    this.up = {
      port: Number(up["port"]),
      local: String(up["local"]),
      remote: String(up["remote"]),
    };
    return this.up;
  }

  /** A stream of its own. */
  stream(): Socket {
    if (!this.up) throw new Error("not connected");
    return connect(this.up.port, "127.0.0.1");
  }

  ask(method: string, path: string, options: Ask = {}): Promise<OutsideReply> {
    return ask(() => this.stream(), method, path, { token: this.token, ...options });
  }

  stop(): void {
    for (const line of this.lines) line.close();
    for (const child of this.children) child.kill("SIGKILL");
  }
}

class Heard {
  private readonly held: Message[] = [];
  private waiting: ((message: Message) => void) | null = null;

  constructor(from: Readable, down: (reason: string) => void) {
    createInterface({ input: from }).on("line", (line) => {
      const message = JSON.parse(line) as Message;
      if (message["event"] === "down") {
        down(String(message["error"]));
        return;
      }
      if (this.waiting) this.waiting(message);
      else this.held.push(message);
    });
  }

  async event(name: string, ms = 10_000): Promise<Message> {
    const message =
      this.held.shift() ??
      (await new Promise<Message>((resolve, reject) => {
        const timer = setTimeout(() => {
          reject(new Error(`no ${name}`));
        }, ms);
        this.waiting = (one) => {
          clearTimeout(timer);
          this.waiting = null;
          resolve(one);
        };
      }));
    if (message["event"] !== name) throw new Error(`no ${name}: ${JSON.stringify(message)}`);
    return message;
  }
}

/** A road between the two with a delay, a speed, a queue and losses. Nothing in between it. */
export class Shim {
  readonly counts = {
    carried: 0,
    carriedBytes: 0,
    toDevice: 0,
    lost: 0,
    full: 0,
    waitedMs: 0,
    waits: 0,
  };
  private sides: [UdpSocket, UdpSocket];
  private readonly peers: ({ port: number; address: string } | null)[] = [null, null];
  private readonly queues: { at: number; data: Buffer }[][] = [[], []];
  private readonly busy = [0, 0];
  private readonly timer: NodeJS.Timeout;
  private readonly road: { oneWayMs: number; loss: number; mbit: number; queueMs: number };
  private ports: [number, number] = [0, 0];
  private seed = 1;

  private constructor(road: Shim["road"]) {
    this.road = road;
    this.sides = [this.side(0), this.side(1)];
    this.timer = setInterval(() => {
      this.pump();
    }, 1);
  }

  static async start(road: Shim["road"]): Promise<Shim> {
    const shim = new Shim(road);
    for (const side of shim.sides) {
      await new Promise<void>((done) => side.bind(0, "127.0.0.1", done));
      side.setRecvBufferSize(4 << 20);
      side.setSendBufferSize(4 << 20);
    }
    shim.ports = shim.sides.map((side) => side.address().port) as [number, number];
    return shim;
  }

  private side(index: number): UdpSocket {
    const side = createSocket("udp4");
    side.on("error", () => undefined);
    side.on("message", (data, from) => {
      this.peers[index] = from;
      // What comes in at one side goes out at the other.
      this.enter(1 - index, data);
    });
    return side;
  }

  /**
   * The device's network gives it another public port, as a mobile network's NAT does now and
   * then: from here on the box hears it from another address, and what the box sends to the old
   * one is lost.
   */
  async rebind(): Promise<void> {
    const old = this.sides[1];
    const fresh = this.side(1);
    await new Promise<void>((done) => fresh.bind(0, "127.0.0.1", done));
    fresh.setRecvBufferSize(4 << 20);
    fresh.setSendBufferSize(4 << 20);
    this.sides = [this.sides[0], fresh];
    old.close();
  }

  stop(): void {
    clearInterval(this.timer);
    for (const side of this.sides) side.close();
  }

  private replace(sdp: string, port: number): string {
    const kept = sdp
      .split(/\r?\n/)
      .filter((line) => line !== "" && !/^a=(candidate|end-of)/.test(line));
    kept.push(`a=candidate:1 1 UDP 2122317823 127.0.0.1 ${port} typ host`, "a=end-of-candidates");
    return `${kept.join("\r\n")}\r\n`;
  }

  // Side 0 is where the device is, side 1 where the box is.
  offer(sdp: string): string {
    return this.replace(sdp, this.ports[1]);
  }

  answer(sdp: string): string {
    return this.replace(sdp, this.ports[0]);
  }

  private random(): number {
    this.seed = (this.seed * 1_103_515_245 + 12_345) & 0x7fffffff;
    return this.seed / 0x7fffffff;
  }

  private enter(side: number, data: Buffer): void {
    const { oneWayMs, loss, mbit, queueMs } = this.road;
    if (this.random() < loss) {
      this.counts.lost += 1;
      return;
    }
    const now = performance.now();
    const took = ((data.length + 28) * 8) / (mbit * 1000);
    const start = Math.max(this.busy[side] ?? 0, now);
    if (start - now > queueMs) {
      this.counts.full += 1;
      return;
    }
    if (side === 0) {
      this.counts.waitedMs += start - now;
      this.counts.waits += 1;
    }
    this.busy[side] = start + took;
    this.queues[side]?.push({ at: start + took + oneWayMs, data });
  }

  private pump(): void {
    const now = performance.now();
    this.queues.forEach((queue, side) => {
      let due = 0;
      const peer = this.peers[side];
      for (const one of queue) {
        if (one.at > now) break;
        due += 1;
        if (!peer) continue;
        this.counts.carried += 1;
        this.counts.carriedBytes += one.data.length;
        if (side === 0) this.counts.toDevice += one.data.length;
        this.sides[side]?.send(one.data, peer.port, peer.address);
      }
      queue.splice(0, due);
    });
  }
}
