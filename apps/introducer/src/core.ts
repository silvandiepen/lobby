// SPDX-License-Identifier: MPL-2.0
/*
 * The introducer: where a household's box and its devices find each other. It passes sealed
 * messages on. It sees public keys, sizes, times and the addresses people connect from, and never
 * what is said, an address to connect to, or a byte of a film.
 *
 * One implementation for Cloudflare (worker.ts) and for a machine of one's own (node.ts). Nothing
 * here writes a log.
 */

const PROTOCOL = "lobby-introducer/1";

export interface Limits {
  /** A sealed message. */
  payload: number;
  /** Everything else may be longer by this much. */
  around: number;
  /** For signing in. */
  helloMs: number;
  /** How long a device may stay: an introduction takes seconds. */
  deviceMs: number;
  /** A person has to come and approve. */
  pairingMs: number;
  devicesPerBox: number;
  pairingPerRoom: number;
  /** Pairing lines of one box, in all its rooms together. */
  pairingPerBox: number;
  /** Pairing rooms one box may have open at once: one per code that leads in. 1 is as before. */
  roomsPerBox: number;
  lines: number;
  linesPerAddress: number;
  /** New lines from one address. */
  openPerMinute: number;
  messagesPerMinute: number;
  boxMessagesPerMinute: number;
  /** Lines and messages together, per day (UTC). Then nothing until the next. */
  perDay: number;
  /** Counted ahead in steps of this many, so that a nap loses no count. */
  countAhead: number;
  ringKeys: number;
  roomMs: number;
}

export const LIMITS: Limits = {
  payload: 16_384,
  around: 512,
  helloMs: 10_000,
  deviceMs: 120_000,
  pairingMs: 25 * 60_000,
  devicesPerBox: 24,
  pairingPerRoom: 3,
  pairingPerBox: 24,
  roomsPerBox: 64,
  lines: 128,
  linesPerAddress: 16,
  openPerMinute: 20,
  messagesPerMinute: 60,
  boxMessagesPerMinute: 1_200,
  perDay: 20_000,
  countAhead: 50,
  ringKeys: 128,
  roomMs: 45 * 60_000,
};

/** Why a line is closed. */
export const CLOSED = {
  done: 1000,
  refused: 4001,
  unreadable: 4003,
  late: 4008,
  tooMuch: 4029,
  fullDay: 4030,
  offline: 4404,
  replaced: 4409,
} as const;

/** What is known of a line. It survives a nap, and is gone with the line. */
export interface LineState {
  kind: "box" | "device" | "pairing";
  /** Whose: a box by its id. */
  box: string;
  room: string | null;
  nonce: string;
  session: string;
  signedIn: boolean;
  key: string | null;
  address: string;
  at: number;
  minute: number;
  said: number;
}

export interface Line {
  send: (text: string) => void;
  close: (code: number, reason: string) => void;
  /** Null once it is gone. */
  state: () => LineState | null;
  remember: (state: LineState) => void;
}

/** What the introducer stands on. */
export interface Ground {
  lines: () => Line[];
  read: (key: string) => Promise<unknown>;
  write: (key: string, value: unknown) => Promise<void>;
  remove: (key: string) => Promise<void>;
  /** Asks to be woken (`Introducer.woke`). */
  wakeAt: (at: number) => Promise<void>;
  now: () => number;
}

export type Wish = { kind: "box"; box: string } | { kind: "pairing"; room: string };

const BOX_PATH = /^\/v1\/box\/([A-Za-z0-9_-]{43})$/;
const ROOM_PATH = /^\/v1\/pair\/([A-Za-z0-9_-]{22})$/;

/** What a request is for. Null for everything there is nothing for. */
export function wishOf(path: string, boxes: readonly string[]): Wish | null {
  const box = BOX_PATH.exec(path)?.[1];
  // Only for boxes that are known, so strangers cannot use this for boxes of their own.
  if (box !== undefined) return boxes.includes(box) ? { kind: "box", box } : null;
  const room = ROOM_PATH.exec(path)?.[1];
  return room === undefined ? null : { kind: "pairing", room };
}

/** Boxes from a setting: their ids, with commas or spaces between. */
export function readBoxes(setting: string | undefined): string[] {
  return (setting ?? "").split(/[\s,]+/).filter((one) => /^[A-Za-z0-9_-]{43}$/.test(one));
}

/** Counts per key and minute, and forgets the rest. */
export class PerMinute {
  private readonly counts = new Map<string, number>();
  private minute = 0;
  private readonly max: number;

  constructor(max = 2_048) {
    this.max = max;
  }

  take(key: string, most: number, now: number): boolean {
    const minute = Math.floor(now / 60_000);
    if (minute !== this.minute) this.counts.clear();
    this.minute = minute;
    const had = this.counts.get(key) ?? 0;
    // Full of strangers: those that are not known yet wait a minute.
    if (had >= most || (had === 0 && this.counts.size >= this.max)) return false;
    this.counts.set(key, had + 1);
    return true;
  }
}

const b64 = (data: Uint8Array): string =>
  btoa(String.fromCharCode(...data))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");

function unb64(text: unknown, length: number): Uint8Array<ArrayBuffer> | null {
  if (typeof text !== "string" || !/^[A-Za-z0-9_-]+$/.test(text) || text.length > 128) return null;
  const padded = text.replaceAll("-", "+").replaceAll("_", "/");
  let found: string;
  try {
    found = atob(padded + "=".repeat((4 - (padded.length % 4)) % 4));
  } catch {
    return null;
  }
  const data = Uint8Array.from(found, (character) => character.charCodeAt(0));
  return data.length === length && b64(data) === text ? data : null;
}

const isRoom = (room: unknown): room is string =>
  typeof room === "string" && /^[A-Za-z0-9_-]{22}$/.test(room);

const fresh = (bytes: number): string => b64(crypto.getRandomValues(new Uint8Array(bytes)));

interface Day {
  day: number;
  /** What may be used without writing it down again. */
  reserved: number;
}

interface Room {
  box: string;
  until: number;
}

export class Introducer {
  private readonly ground: Ground;
  private readonly limits: Limits;
  private readonly opening = new PerMinute();
  private used: { day: number; count: number; reserved: number } | null = null;
  private queue: Promise<unknown> = Promise.resolve();

  constructor(ground: Ground, limits: Partial<Limits> = {}) {
    this.ground = ground;
    this.limits = { ...LIMITS, ...limits };
  }

  /** One thing at a time, in the order it came. */
  private inTurn<T>(act: () => Promise<T>): Promise<T> {
    const result = this.queue.then(act);
    this.queue = result.catch(() => undefined);
    return result;
  }

  /**
   * Whether somebody may open a line.
   *
   * @returns what is known of it, or the status of the refusal
   */
  admit(wish: Wish, address: string): Promise<LineState | number> {
    return this.inTurn(async () => {
      const { ground, limits } = this;
      const now = ground.now();
      if (!this.opening.take(address, limits.openPerMinute, now)) return 429;
      const lines = this.states();
      if (
        lines.length >= limits.lines ||
        lines.filter((one) => one.address === address).length >= limits.linesPerAddress
      ) {
        return 429;
      }
      let box: string;
      if (wish.kind === "box") {
        box = wish.box;
        const others = lines.filter((one) => one.box === box && one.kind !== "box");
        if (others.length >= limits.devicesPerBox + 4) return 429;
      } else {
        const room = await this.room(wish.room);
        if (!room) return 404;
        box = room.box;
        const pairing = lines.filter((one) => one.kind === "pairing" && one.box === box);
        if (
          pairing.filter((one) => one.room === wish.room).length >= limits.pairingPerRoom ||
          pairing.length >= limits.pairingPerBox
        ) {
          return 429;
        }
      }
      if (!(await this.count())) return 503;
      return {
        // What it is at a box's address shows when it signs in.
        kind: wish.kind === "box" ? "device" : "pairing",
        box,
        room: wish.kind === "pairing" ? wish.room : null,
        nonce: fresh(32),
        session: fresh(16),
        signedIn: false,
        key: null,
        address,
        at: now,
        minute: 0,
        said: 0,
      };
    });
  }

  /** The line is there. */
  opened(line: Line, state: LineState): Promise<void> {
    return this.inTurn(async () => {
      if (state.kind === "pairing") {
        // Knowing the room is all there is to show: what is said in it is sealed with the code.
        state.signedIn = true;
        line.remember(state);
        if (!this.box(state.box)) {
          line.close(CLOSED.offline, "offline");
          return;
        }
        line.send(JSON.stringify({ t: "ready", session: state.session }));
      } else {
        line.remember(state);
        line.send(JSON.stringify({ t: "challenge", nonce: state.nonce }));
      }
      await this.ground.wakeAt(this.ground.now() + this.limits.helloMs);
    });
  }

  heard(line: Line, text: unknown): Promise<void> {
    return this.inTurn(async () => {
      const state = line.state();
      if (!state) return;
      const { limits } = this;
      if (typeof text !== "string" || text.length > limits.payload + limits.around) {
        line.close(CLOSED.unreadable, "size");
        return;
      }
      const now = this.ground.now();
      if (this.isLate(state, now)) {
        line.close(CLOSED.late, "late");
        return;
      }
      const minute = Math.floor(now / 60_000);
      state.said = state.minute === minute ? state.said + 1 : 1;
      state.minute = minute;
      line.remember(state);
      const most = state.kind === "box" ? limits.boxMessagesPerMinute : limits.messagesPerMinute;
      if (state.said > most) {
        line.close(CLOSED.tooMuch, "rate");
        return;
      }
      if (!(await this.count())) {
        line.close(CLOSED.fullDay, "day");
        return;
      }
      let message: Record<string, unknown>;
      try {
        const value: unknown = JSON.parse(text);
        if (typeof value !== "object" || value === null || Array.isArray(value)) {
          throw new Error("no object");
        }
        message = value as Record<string, unknown>;
      } catch {
        line.close(CLOSED.unreadable, "json");
        return;
      }
      if (!state.signedIn) await this.signIn(line, state, message);
      else if (message["t"] === "msg") await this.pass(line, state, message);
      else if (state.kind === "box") await this.told(line, state, message);
      else line.close(CLOSED.unreadable, "message");
    });
  }

  closed(line: Line): Promise<void> {
    return this.inTurn(async () => {
      const state = line.state();
      if (state?.kind !== "box" || !state.signedIn) return;
      const still = this.ground.lines().some((one) => {
        const other = one === line ? null : one.state();
        return other?.kind === "box" && other.signedIn && other.box === state.box;
      });
      if (!still) await this.forget(state.box);
    });
  }

  /** Closes what has been here for too long. */
  woke(): Promise<void> {
    return this.inTurn(async () => {
      const now = this.ground.now();
      let waiting = false;
      for (const line of this.ground.lines()) {
        const state = line.state();
        if (!state || (state.kind === "box" && state.signedIn)) continue;
        if (this.isLate(state, now)) line.close(CLOSED.late, "late");
        else waiting = true;
      }
      if (waiting) await this.ground.wakeAt(now + this.limits.helloMs);
    });
  }

  private isLate(state: LineState, now: number): boolean {
    if (state.kind === "box" && state.signedIn) return false;
    const { helloMs, deviceMs, pairingMs } = this.limits;
    const most = !state.signedIn ? helloMs : state.kind === "pairing" ? pairingMs : deviceMs;
    return now - state.at > most;
  }

  private states(): LineState[] {
    return this.ground
      .lines()
      .map((line) => line.state())
      .filter((state) => state !== null);
  }

  private box(id: string): Line | undefined {
    return this.ground.lines().find((line) => {
      const state = line.state();
      return state?.kind === "box" && state.signedIn && state.box === id;
    });
  }

  private async signIn(
    line: Line,
    state: LineState,
    message: Record<string, unknown>,
  ): Promise<void> {
    const refuse = (): void => {
      line.close(CLOSED.refused, "refused");
    };
    const role = message["role"];
    const key = unb64(message["key"], 32);
    const signature = unb64(message["signature"], 64);
    if (message["t"] !== "auth" || (role !== "box" && role !== "device") || !key || !signature) {
      refuse();
      return;
    }
    let good: boolean;
    try {
      const known = await crypto.subtle.importKey("raw", key, "Ed25519", false, ["verify"]);
      const signed = new TextEncoder().encode(`${PROTOCOL}|${role}|${state.box}|${state.nonce}`);
      good = await crypto.subtle.verify("Ed25519", known, signature, signed);
    } catch {
      good = false;
    }
    if (!good) {
      refuse();
      return;
    }
    state.nonce = "";
    if (role === "box") {
      // A box's id is the hash of its key: nobody else can sign in as it.
      const id = b64(new Uint8Array(await crypto.subtle.digest("SHA-256", key)));
      if (id !== state.box) {
        refuse();
        return;
      }
      this.box(id)?.close(CLOSED.replaced, "replaced");
      state.kind = "box";
      state.signedIn = true;
      line.remember(state);
      // How many rooms it may have: a box from before says one with `pairing`, and that still works.
      const { roomsPerBox } = this.limits;
      line.send(
        JSON.stringify(roomsPerBox > 1 ? { t: "ready", rooms: roomsPerBox } : { t: "ready" }),
      );
      return;
    }
    if (!this.box(state.box)) {
      line.close(CLOSED.offline, "offline");
      return;
    }
    const ringKey = b64(key);
    const may = (await this.ground.read(`devices:${state.box}`)) as string[] | undefined;
    const same = this.states().filter((one) => one.kind === "device" && one.signedIn);
    if (!may?.includes(ringKey)) {
      refuse();
      return;
    }
    if (
      same.filter((one) => one.box === state.box).length >= this.limits.devicesPerBox ||
      same.filter((one) => one.key === ringKey).length >= 4
    ) {
      line.close(CLOSED.tooMuch, "busy");
      return;
    }
    state.signedIn = true;
    state.key = ringKey;
    line.remember(state);
    line.send(JSON.stringify({ t: "ready", session: state.session }));
  }

  private async pass(
    line: Line,
    state: LineState,
    message: Record<string, unknown>,
  ): Promise<void> {
    const { p } = message;
    if (typeof p !== "string" || p.length > this.limits.payload || !/^[A-Za-z0-9_-]+$/.test(p)) {
      line.close(CLOSED.unreadable, "payload");
      return;
    }
    if (state.room !== null && (await this.room(state.room))?.box !== state.box) {
      // Its room was closed, or ran out, while the line was quiet.
      line.close(CLOSED.done, "over");
      return;
    }
    if (state.kind !== "box") {
      const box = this.box(state.box);
      if (!box) {
        line.close(CLOSED.offline, "offline");
        return;
      }
      box.send(
        JSON.stringify({
          t: "msg",
          session: state.session,
          ...(state.key === null ? {} : { key: state.key }),
          // Which code it came in with, so that a box with several rooms knows whose it is.
          ...(state.room === null || this.limits.roomsPerBox === 1 ? {} : { room: state.room }),
          p,
        }),
      );
      return;
    }
    for (const other of this.ground.lines()) {
      const device = other.state();
      if (
        device?.kind !== "box" &&
        device?.signedIn === true &&
        device.box === state.box &&
        device.session === message["session"]
      ) {
        other.send(JSON.stringify({ t: "msg", p }));
        return;
      }
    }
  }

  private async told(
    line: Line,
    state: LineState,
    message: Record<string, unknown>,
  ): Promise<void> {
    const { ground, limits } = this;
    if (message["t"] === "devices") {
      const { keys } = message;
      if (
        !Array.isArray(keys) ||
        keys.length > limits.ringKeys ||
        !keys.every((key: unknown) => unb64(key, 32) !== null)
      ) {
        line.close(CLOSED.unreadable, "devices");
        return;
      }
      await ground.write(`devices:${state.box}`, keys);
      for (const other of ground.lines()) {
        const device = other.state();
        if (
          device?.kind === "device" &&
          device.signedIn &&
          device.box === state.box &&
          !keys.includes(device.key)
        ) {
          other.close(CLOSED.refused, "refused");
        }
      }
    } else if (message["t"] === "pairing") {
      // A box from before: one room, which takes the place of all it had.
      const { room, until } = message;
      if (room === null) {
        await this.setRooms(state.box, []);
        return;
      }
      if (!isRoom(room) || typeof until !== "number") {
        line.close(CLOSED.unreadable, "pairing");
        return;
      }
      await this.setRooms(state.box, [{ room, until }]);
    } else if (message["t"] === "rooms" && limits.roomsPerBox > 1) {
      // Every room of the box, each for one code: what is not in it is closed.
      const { rooms } = message;
      if (
        !Array.isArray(rooms) ||
        rooms.length > limits.roomsPerBox ||
        !rooms.every(
          (one: unknown) =>
            typeof one === "object" &&
            one !== null &&
            isRoom((one as Record<string, unknown>)["room"]) &&
            typeof (one as Record<string, unknown>)["until"] === "number",
        )
      ) {
        line.close(CLOSED.unreadable, "rooms");
        return;
      }
      await this.setRooms(state.box, rooms as { room: string; until: number }[]);
    } else {
      line.close(CLOSED.unreadable, "message");
    }
  }

  private async room(name: string): Promise<Room | null> {
    const room = (await this.ground.read(`room:${name}`)) as Room | undefined;
    return room && room.until > this.ground.now() ? room : null;
  }

  /** The rooms a box said it has, also as an introducer from before kept them. */
  private async roomsOf(box: string): Promise<string[]> {
    const { ground } = this;
    const many = ((await ground.read(`rooms-of:${box}`)) as string[] | undefined) ?? [];
    const one = (await ground.read(`room-of:${box}`)) as string | undefined;
    return one === undefined || many.includes(one) ? many : [...many, one];
  }

  /** The box's rooms are these from now on. */
  private async setRooms(box: string, wanted: { room: string; until: number }[]): Promise<void> {
    const { ground, limits } = this;
    const now = ground.now();
    const kept = new Map<string, number>();
    for (const { room, until } of wanted) {
      // Somebody else's room stays theirs; one that is over is none.
      const taken = await this.room(room);
      if ((taken && taken.box !== box) || until <= now) continue;
      kept.set(room, Math.min(until, now + limits.roomMs));
    }
    for (const room of await this.roomsOf(box)) {
      if (!kept.has(room)) await this.closeRoom(box, room);
    }
    for (const [room, until] of kept) {
      await ground.write(`room:${room}`, { box, until } satisfies Room);
    }
    await ground.remove(`room-of:${box}`);
    if (kept.size === 0) await ground.remove(`rooms-of:${box}`);
    else await ground.write(`rooms-of:${box}`, [...kept.keys()]);
  }

  private async closeRoom(box: string, room: string): Promise<void> {
    const taken = (await this.ground.read(`room:${room}`)) as Room | undefined;
    if (taken?.box === box) await this.ground.remove(`room:${room}`);
    for (const line of this.ground.lines()) {
      const state = line.state();
      if (state?.room === room && state.box === box) line.close(CLOSED.done, "over");
    }
  }

  /** Nothing is kept of a box that is not here. */
  private async forget(box: string): Promise<void> {
    await this.ground.remove(`devices:${box}`);
    await this.setRooms(box, []);
    for (const line of this.ground.lines()) {
      if (line.state()?.box === box) line.close(CLOSED.offline, "offline");
    }
  }

  /** One more today. False when there is no more today. */
  private async count(): Promise<boolean> {
    const day = Math.floor(this.ground.now() / 86_400_000);
    if (this.used?.day !== day) {
      const stored = (await this.ground.read("day")) as Day | undefined;
      const before = stored?.day === day ? stored.reserved : 0;
      this.used = { day, count: before, reserved: before };
    }
    const { used } = this;
    if (used.count >= this.limits.perDay) return false;
    if (used.count >= used.reserved) {
      used.reserved += this.limits.countAhead;
      await this.ground.write("day", { day, reserved: used.reserved } satisfies Day);
    }
    used.count += 1;
    return true;
  }
}
