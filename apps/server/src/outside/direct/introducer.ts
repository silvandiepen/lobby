// SPDX-License-Identifier: MPL-2.0
import { log } from "../../log.ts";
import { b64, INTRODUCER, MAX_ENVELOPE } from "./envelope.ts";
import type { BoxKeys } from "./keys.ts";

const FIRST_WAIT_MS = 1_000;
const LAST_WAIT_MS = 5 * 60_000;
/** Up for this long is up: the next wait starts small again. */
const SETTLED_MS = 60_000;
const PING_MS = 25_000;
/** For the answer to a ping, and for the whole sign-in. */
const ANSWER_MS = 10_000;
/** More than the introducer passes on. */
const MAX_MESSAGE = MAX_ENVELOPE + 1_024;

/** What a device said, as the introducer passed it on. None of it is to be believed. */
export interface Heard {
  session: string;
  /** The ring key it signed in with, and null in a pairing room. */
  key: string | null;
  /** The pairing room it came in by. Null for a ring, and from an introducer of one room. */
  room: string | null;
  payload: string;
}

export interface PairingRoom {
  room: string;
  until: number;
}

export interface IntroducerOptions {
  url: string;
  keys: BoxKeys;
  ringKeys: () => string[];
  heard: (message: Heard, reply: (payload: string) => void) => void;
  now?: () => number;
  /** Between 0 and 1, so that a house of boxes does not come back all at once. */
  random?: () => number;
}

/** The box's line to the introducer: kept up, and signed in on. */
export class IntroducerClient {
  private readonly options: IntroducerOptions;
  private socket: WebSocket | null = null;
  private timer: NodeJS.Timeout | null = null;
  private watchdog: NodeJS.Timeout | null = null;
  private signedIn = false;
  private upSince = 0;
  private attempt = 0;
  private stopped = true;
  private told = "";
  private rooms: PairingRoom[] = [];
  /** How many rooms the introducer keeps for this box: one when it says nothing of it. */
  private roomsThere = 1;
  /** No more than this, whatever it says. */
  static readonly MAX_ROOMS = 64;
  problem: string | null = null;

  constructor(options: IntroducerOptions) {
    this.options = options;
  }

  get isUp(): boolean {
    return this.signedIn;
  }

  start(): void {
    if (!this.stopped) return;
    this.stopped = false;
    this.attempt = 0;
    this.connect();
  }

  stop(): void {
    this.stopped = true;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.drop();
  }

  /** Says who may ring, when that changed. */
  refresh(): void {
    if (!this.signedIn) return;
    const keys = this.options.ringKeys();
    const telling = keys.join(" ");
    if (telling === this.told) return;
    this.told = telling;
    this.send({ t: "devices", keys });
  }

  /**
   * The rooms where a device with a code can find this box, the one that matters most first: what
   * is not among them is closed. An introducer from before keeps only the first.
   */
  setRooms(rooms: PairingRoom[]): void {
    this.rooms = rooms;
    if (this.signedIn) this.sendRooms();
  }

  private sendRooms(): void {
    if (this.roomsThere > 1) {
      this.send({ t: "rooms", rooms: this.rooms.slice(0, this.roomsThere) });
      return;
    }
    const [first] = this.rooms;
    this.send({ t: "pairing", room: first?.room ?? null, until: first?.until ?? 0 });
  }

  private send(message: object): void {
    if (this.socket?.readyState === WebSocket.OPEN) this.socket.send(JSON.stringify(message));
  }

  private drop(): void {
    const socket = this.socket;
    this.socket = null;
    this.signedIn = false;
    if (this.watchdog) clearTimeout(this.watchdog);
    this.watchdog = null;
    socket?.close();
  }

  private connect(): void {
    if (this.stopped) return;
    const { url, keys } = this.options;
    const socket = new WebSocket(`${url}/v1/box/${keys.boxId}`);
    this.socket = socket;
    this.expect("no answer");
    const mine = (act: () => void): void => {
      if (this.socket === socket) act();
    };
    socket.addEventListener("message", (event: MessageEvent) => {
      mine(() => {
        this.receive(event.data as unknown);
      });
    });
    // Always followed by a close, which says as much.
    socket.addEventListener("error", () => undefined);
    socket.addEventListener("close", (event) => {
      mine(() => {
        this.lost(event.code === 4001 ? "it does not know this box" : "the line was closed");
      });
    });
  }

  /** Something has to come within the time there is for it. */
  private expect(otherwise: string): void {
    if (this.watchdog) clearTimeout(this.watchdog);
    this.watchdog = setTimeout(() => {
      this.lost(otherwise);
    }, ANSWER_MS);
  }

  private lost(problem: string): void {
    const now = (this.options.now ?? Date.now)();
    if (this.signedIn && now - this.upSince >= SETTLED_MS) this.attempt = 0;
    this.drop();
    if (this.stopped) return;
    if (this.problem !== problem) log.warn("The introducer cannot be reached", { problem });
    this.problem = problem;
    const most = Math.min(LAST_WAIT_MS, FIRST_WAIT_MS * 2 ** Math.min(this.attempt, 16));
    this.attempt += 1;
    const wait = most / 2 + ((this.options.random ?? Math.random)() * most) / 2;
    this.timer = setTimeout(() => {
      this.connect();
    }, wait);
  }

  private receive(data: unknown): void {
    if (typeof data !== "string" || data.length > MAX_MESSAGE) {
      this.lost("it said something that is too long");
      return;
    }
    if (data === "pong") {
      this.rest();
      return;
    }
    let message: Record<string, unknown>;
    try {
      const value: unknown = JSON.parse(data);
      if (typeof value !== "object" || value === null) throw new Error("no object");
      message = value as Record<string, unknown>;
    } catch {
      this.lost("it said something that is not a message");
      return;
    }
    const { keys, heard } = this.options;
    if (message["t"] === "challenge" && typeof message["nonce"] === "string") {
      if (this.signedIn || !/^[A-Za-z0-9_-]{32,64}$/.test(message["nonce"])) return;
      const signed = keys.sign(`${INTRODUCER}|box|${keys.boxId}|${message["nonce"]}`);
      this.expect("it did not let this box in");
      this.send({ t: "auth", role: "box", key: b64(keys.boxPublic), signature: b64(signed) });
    } else if (message["t"] === "ready" && !this.signedIn) {
      this.signedIn = true;
      const { rooms } = message;
      this.roomsThere =
        typeof rooms === "number" && Number.isInteger(rooms) && rooms > 1
          ? Math.min(rooms, IntroducerClient.MAX_ROOMS)
          : 1;
      this.upSince = (this.options.now ?? Date.now)();
      this.problem = null;
      this.told = "\n";
      this.refresh();
      // Also none: rooms closed while the line was down may still be there.
      if (this.rooms.length > 0 || this.roomsThere > 1) this.sendRooms();
      log.info("Signed in at the introducer");
      this.rest();
    } else if (message["t"] === "msg" && this.signedIn) {
      const { session, key, room, p } = message;
      if (
        typeof session !== "string" ||
        !/^[A-Za-z0-9_-]{16,64}$/.test(session) ||
        typeof p !== "string" ||
        p.length > MAX_ENVELOPE ||
        (key !== undefined && typeof key !== "string") ||
        (room !== undefined && typeof room !== "string")
      ) {
        return;
      }
      heard({ session, key: key ?? null, room: room ?? null, payload: p }, (payload) => {
        this.send({ t: "msg", session, p: payload });
      });
    }
  }

  /** All is well: look again in a while. */
  private rest(): void {
    if (this.watchdog) clearTimeout(this.watchdog);
    this.watchdog = setTimeout(() => {
      this.expect("it does not answer any more");
      if (this.socket?.readyState === WebSocket.OPEN) this.socket.send("ping");
    }, PING_MS);
  }
}
