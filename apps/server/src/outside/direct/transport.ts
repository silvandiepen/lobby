// SPDX-License-Identifier: MPL-2.0
import { createHmac, randomBytes } from "node:crypto";
import type { Socket } from "node:net";
import type { Database } from "../../db/database.ts";
import type { Devices } from "../../auth/devices.ts";
import { errorMessage, log } from "../../log.ts";
import type { OutsideConnection, OutsideTransport } from "../entrance.ts";
import { plainAddress, RateLimiter } from "../limits.ts";
import type { OutsidePairing } from "../pairing.ts";
import type { DirectConfig, IceServer } from "./config.ts";
import {
  b64,
  introductionAad,
  introductionKeys,
  open,
  seal,
  unb64,
  type Introduction,
} from "./envelope.ts";
import { DirectIdentities, type KnownDevice } from "./identities.ts";
import { IntroducerClient, type Heard } from "./introducer.ts";
import { BoxKeys } from "./keys.ts";
import { DirectPairing } from "./pairing.ts";
import { cleanSdp, isPublicAddress } from "./sdp.ts";
import { Sidecar } from "./sidecar.ts";

const TICK_MS = 1_000;
/** A device that moves to another network has an old connection that does not know it yet. */
const PER_DEVICE = 3;
/** As the sidecar has it. */
const SESSIONS = 16;
/** Conversations that have not come to an offer. */
const MAX_INTRODUCTIONS = 64;
const INTRODUCTION_MS = 60_000;
/** Long enough for an evening; a relay asks again while it is in use. */
const TURN_HOURS = 12;

export interface DirectStatus {
  /** Whether the program that makes the connections runs. */
  running: boolean;
  /** Whether the box is signed in at the introducer. */
  introducer: boolean;
  /** Live connections to devices. */
  connections: number;
  /** How many of them go over the owner's relay. */
  relayed: number;
  /** Devices that may ring now. */
  devices: number;
}

interface Underway {
  device: KnownDevice;
  boxNonce: Buffer;
  deviceNonce: Buffer;
  /** Set once an offer came: there is one a conversation. */
  offered: boolean;
  at: number;
}

interface Session {
  deviceId: string;
  at: number;
  up: boolean;
  relayed: boolean;
  address: string | null;
  /** Says the answer to the device, once. */
  answer: ((message: object) => void) | null;
}

export interface DirectOptions {
  config: DirectConfig;
  db: Database;
  devices: Devices;
  pairing: OutsidePairing;
  dataDir: string;
  /** The name requests must be for. */
  name: string;
  now?: () => number;
  /** Which addresses may be in a description. For tests on one machine. */
  keepAddress?: (address: string) => boolean;
}

/**
 * The direct road: device and box are introduced through a service that learns nothing, find a
 * path (ICE) and speak QUIC over it. Every stream is a connection for the entrance, and carries
 * which device is at the other end.
 */
export class DirectTransport implements OutsideTransport {
  readonly name = "direct";
  readonly identities: DirectIdentities;
  private readonly options: DirectOptions;
  private readonly now: () => number;
  private readonly keys: BoxKeys;
  private readonly sidecar: Sidecar;
  private readonly introducer: IntroducerClient;
  private readonly pairing: DirectPairing;
  private readonly outsidePairing: OutsidePairing;
  private readonly introductions = new Map<string, Underway>();
  private readonly sessions = new Map<string, Session>();
  private readonly rings: RateLimiter;
  private readonly allRings: RateLimiter;
  private accept: ((connection: OutsideConnection) => void) | null = null;
  private timer: NodeJS.Timeout | null = null;
  private stunTurn = 0;

  constructor(options: DirectOptions) {
    this.options = options;
    this.now = options.now ?? Date.now;
    const { config, db, dataDir, name } = options;
    this.keys = new BoxKeys(dataDir, this.now);
    this.identities = new DirectIdentities(db, this.keys, config.introducer, name, this.now);
    this.rings = new RateLimiter({ burst: 40, perMinute: 30 }, this.now);
    this.allRings = new RateLimiter({ burst: 200, perMinute: 240 }, this.now);
    this.sidecar = new Sidecar({
      binary: config.binary,
      boxId: this.keys.boxId,
      certificate: () => this.keys.certificate,
      maxUploadMbit: config.maxUploadMbit,
      said: (message) => {
        this.said(message);
      },
      stream: (session, socket) => {
        this.stream(session, socket);
      },
      gone: () => {
        this.sessions.clear();
      },
    });
    this.introducer = new IntroducerClient({
      url: config.introducer,
      keys: this.keys,
      ringKeys: () => this.identities.ringKeys(),
      heard: (message, reply) => {
        this.heard(message, reply);
      },
      now: this.now,
    });
    this.pairing = new DirectPairing({
      pairing: options.pairing,
      identities: this.identities,
      keys: this.keys,
      setRooms: (rooms) => {
        this.introducer.setRooms(rooms);
      },
      now: this.now,
    });
    this.outsidePairing = options.pairing;
    options.pairing.onOpened = (opening) => {
      this.pairing.opened(opening).catch((error: unknown) => {
        log.error("Could not open the pairing room", { error: errorMessage(error) });
      });
    };
    options.pairing.onClosed = (openingId) => {
      this.pairing.closed(openingId);
    };
  }

  // ---- The road ----

  async open(accept: (connection: OutsideConnection) => void): Promise<void> {
    this.accept = accept;
    this.keys.rotateIfDue();
    await this.sidecar.start();
    this.introducer.start();
    // Invitations outlive a restart and the entrance being off: their rooms open again.
    for (const opening of this.outsidePairing.openings()) {
      this.pairing.opened(opening).catch((error: unknown) => {
        log.error("Could not open the pairing room", { error: errorMessage(error) });
      });
    }
    this.timer = setInterval(() => {
      this.tick();
    }, TICK_MS);
    this.timer.unref();
  }

  async close(): Promise<void> {
    this.accept = null;
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    this.pairing.closed();
    this.introducer.stop();
    this.introductions.clear();
    this.sessions.clear();
    await this.sidecar.stop();
  }

  status(): { open: boolean; problem: string | null } {
    return {
      open: this.accept !== null && this.sidecar.isUp && this.introducer.isUp,
      problem:
        this.sidecar.problem ??
        (this.introducer.problem === null
          ? null
          : `the introducer cannot be reached: ${this.introducer.problem}`),
    };
  }

  directStatus(): DirectStatus {
    const up = [...this.sessions.values()].filter((one) => one.up);
    return {
      running: this.sidecar.isUp,
      introducer: this.introducer.isUp,
      connections: up.length,
      relayed: up.filter((one) => one.relayed).length,
      devices: this.identities.ringKeys().length,
    };
  }

  /** What a manager gives along with a code. */
  get invitation(): { introducer: string } {
    return { introducer: this.options.config.introducer };
  }

  /** Ends the connections of devices that may not be here any more, and tells who may ring. */
  recheck(mayBeOutside: (deviceId: string) => boolean): void {
    for (const [id, session] of this.sessions) {
      if (!mayBeOutside(session.deviceId)) this.end(id);
    }
    for (const [id, one] of this.introductions) {
      if (!mayBeOutside(one.device.deviceId)) this.introductions.delete(id);
    }
    this.introducer.refresh();
  }

  /** A device enrolled anew: what it had before is not its any more. */
  forget(deviceId: string): void {
    for (const [id, session] of this.sessions) if (session.deviceId === deviceId) this.end(id);
    for (const [id, one] of this.introductions) {
      if (one.device.deviceId === deviceId) this.introductions.delete(id);
    }
    this.introducer.refresh();
  }

  private tick(): void {
    const now = this.now();
    for (const [id, one] of this.introductions) {
      if (now - one.at > INTRODUCTION_MS) this.introductions.delete(id);
    }
    this.pairing.tick();
    if (this.keys.rotateIfDue()) {
      log.info("The direct road has a new certificate");
      this.sidecar.tell({ op: "certificate", ...this.keys.certificate });
    }
  }

  private end(id: string): void {
    this.sessions.delete(id);
    this.sidecar.tell({ op: "close", id });
  }

  // ---- Introductions ----

  private heard(message: Heard, reply: (payload: string) => void): void {
    if (this.accept === null || this.allRings.take("all") > 0) return;
    if (message.key === null) {
      this.pairing.heard(message, reply);
      return;
    }
    // Whoever is not let in now gets no answer at all, whatever the introducer let through.
    const device = this.identities.find(message.key);
    if (!device) return;
    const { session, payload } = message;
    const underway = this.introductions.get(session);
    if (underway && underway.device.ringKey === device.ringKey) {
      this.offer(underway, session, payload, reply);
    } else if (!underway) {
      this.hello(device, session, payload, reply);
    }
  }

  private place(device: KnownDevice, session: string): Introduction {
    return { boxId: this.keys.boxId, ringKey: device.ringKey, session };
  }

  private hello(
    device: KnownDevice,
    session: string,
    payload: string,
    reply: (payload: string) => void,
  ): void {
    const place = this.place(device, session);
    const said = open(
      introductionKeys.hello(device.secret),
      introductionAad(place, "d2b", 0),
      payload,
    );
    const deviceNonce = unb64(said?.["nonce"], 32);
    if (!said || said["t"] !== "hello" || !deviceNonce) return;
    if (this.rings.take(device.deviceId) > 0) return;
    if (this.introductions.size >= MAX_INTRODUCTIONS) {
      const oldest = this.introductions.keys().next().value;
      if (oldest !== undefined) this.introductions.delete(oldest);
    }
    const boxNonce = randomBytes(32);
    this.introductions.set(session, {
      device,
      deviceNonce,
      boxNonce,
      offered: false,
      at: this.now(),
    });
    const { config } = this.options;
    reply(
      seal(introductionKeys.welcome(device.secret, deviceNonce), introductionAad(place, "b2d", 0), {
        t: "welcome",
        nonce: b64(boxNonce),
        // Also for a device that slept through a whole change of certificates.
        fingerprints: this.keys.fingerprints,
        ice: { stun: config.stun, turn: this.turnFor("device") },
      }),
    );
  }

  private offer(
    underway: Underway,
    session: string,
    payload: string,
    reply: (payload: string) => void,
  ): void {
    const { device, deviceNonce, boxNonce } = underway;
    const place = this.place(device, session);
    const key = (direction: "d2b" | "b2d"): Buffer =>
      introductionKeys.session(device.secret, deviceNonce, boxNonce, direction);
    if (underway.offered) return;
    const said = open(key("d2b"), introductionAad(place, "d2b", 1), payload);
    if (said?.["t"] !== "offer") return;
    underway.offered = true;
    const answer = (message: object): void => {
      reply(seal(key("b2d"), introductionAad(place, "b2d", 1), message));
      this.introductions.delete(session);
    };
    const keep = this.options.keepAddress ?? isPublicAddress;
    const offer = cleanSdp(said["sdp"], keep);
    if (offer === null) {
      answer({ t: "error", error: "invalid" });
      return;
    }
    if (!this.sidecar.isUp) {
      answer({ t: "error", error: "unavailable" });
      return;
    }
    const own = [...this.sessions].filter(([, one]) => one.deviceId === device.deviceId);
    const oldest = own[0];
    if (oldest && own.length >= PER_DEVICE) this.end(oldest[0]);
    if (this.sessions.size >= SESSIONS) {
      answer({ t: "error", error: "busy" });
      return;
    }
    const id = randomBytes(16).toString("hex");
    this.sessions.set(id, {
      deviceId: device.deviceId,
      at: this.now(),
      up: false,
      relayed: false,
      address: null,
      answer,
    });
    const { config } = this.options;
    const turn = this.turnFor("box");
    this.sidecar.tell({
      op: "open",
      id,
      device: device.ringKey,
      offer,
      bind: config.bind,
      stun: this.stun(),
      turn: turn && { host: turn.host, port: turn.port, user: turn.username, pass: turn.password },
    });
  }

  /** One after another, so that one that is down is not always the one that is asked. */
  private stun(): IceServer | null {
    const { stun } = this.options.config;
    this.stunTurn += 1;
    return stun[this.stunTurn % Math.max(1, stun.length)] ?? null;
  }

  /** A password of coturn's kind: for a few hours, and for nobody in particular. */
  private turnFor(
    who: string,
  ): (IceServer & { username: string; password: string; until: number }) | null {
    const { turn } = this.options.config;
    if (!turn) return null;
    const until = this.now() + TURN_HOURS * 3_600_000;
    const username = `${Math.floor(until / 1000)}:${who}-${randomBytes(6).toString("hex")}`;
    const password = createHmac("sha1", turn.secret).update(username).digest("base64");
    return { host: turn.host, port: turn.port, username, password, until };
  }

  // ---- What the sidecar says ----

  private said(message: Record<string, unknown>): void {
    const id = message["id"];
    const session = typeof id === "string" ? this.sessions.get(id) : undefined;
    if (typeof id !== "string" || !session) {
      // It made a connection that is not wanted any more.
      if (typeof id === "string" && message["event"] !== "closed") {
        this.sidecar.tell({ op: "close", id });
      }
      return;
    }
    if (message["event"] === "answer") {
      const sdp = cleanSdp(message["sdp"], this.options.keepAddress ?? isPublicAddress);
      if (sdp === null) {
        this.end(id);
        return;
      }
      session.answer?.({ t: "answer", sdp });
      session.answer = null;
    } else if (message["event"] === "up") {
      session.up = true;
      session.relayed = message["local"] === "relay" || message["remote"] === "relay";
      const address = message["address"];
      session.address = typeof address === "string" ? plainAddress(address) : null;
      log.info("A device has a direct connection", {
        device: session.deviceId,
        path: `${String(message["local"])}/${String(message["remote"])}`,
        ms: this.now() - session.at,
      });
    } else if (message["event"] === "closed") {
      session.answer?.({ t: "error", error: "unavailable" });
      this.sessions.delete(id);
      log.info("A direct connection ended", {
        device: session.deviceId,
        reason: String(message["reason"]),
        megabytes: Math.round(Number(message["sent"]) / 1e5) / 10,
        lost: Number(message["lost"]),
      });
    }
  }

  private stream(id: string, socket: Socket): void {
    const session = this.sessions.get(id);
    if (!session?.up || !this.accept || !this.options.devices.mayBeOutside(session.deviceId)) {
      socket.destroy();
      return;
    }
    this.accept({
      stream: socket,
      // As ICE saw it. It may be shared, so nobody is kept out because of it.
      address: session.address,
      addressIsReliable: false,
      deviceId: session.deviceId,
    });
  }
}
