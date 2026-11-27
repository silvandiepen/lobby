// SPDX-License-Identifier: MPL-2.0
import { randomBytes, sign } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  CLOSED,
  Introducer,
  PerMinute,
  readBoxes,
  wishOf,
  type Ground,
  type Line,
  type LineState,
} from "../src/core.ts";
import {
  End,
  idOf,
  person,
  signIn,
  startNode,
  startWorker,
  type Person,
  type Started,
} from "./support.ts";

const ROOM = "A".repeat(22);
const newRoom = (): string => randomBytes(16).toString("base64url");
const BOX_READY = { t: "ready", rooms: 64 };

for (const [name, start] of [
  ["in Node", (boxes: string[]) => startNode(boxes)],
  ["in workerd", (boxes: string[]) => startWorker(boxes)],
] as const) {
  describe(`the introducer ${name}`, () => {
    let box: Person;
    let device: Person;
    let id: string;
    let at: Started;
    const ends: End[] = [];

    beforeEach(async () => {
      box = person();
      device = person();
      id = idOf(box);
      at = await start([id]);
    });
    afterEach(async () => {
      for (const end of ends.splice(0)) end.close();
      await at.close();
    });

    const boxLine = async (keys: string[] = [device.public]): Promise<End> => {
      const { end, said } = await signIn(at.url, { role: "box", box: id, who: box });
      ends.push(end);
      expect(said).toEqual(BOX_READY);
      end.say({ t: "devices", keys });
      // Told in order, so once this is answered the list is there.
      end.say("ping");
      expect(await end.next()).toEqual({ t: "pong" });
      return end;
    };
    const deviceLine = async (who = device): Promise<{ end: End; said: unknown }> => {
      const made = await signIn(at.url, { role: "device", box: id, who });
      ends.push(made.end);
      return made;
    };

    it("passes messages between a box and its device, with who it is from", async () => {
      const boxEnd = await boxLine();
      const one = await deviceLine();
      const { session } = one.said as { session: string };
      expect(one.said).toEqual({ t: "ready", session: expect.stringMatching(/^.{22}$/) as string });
      one.end.say({ t: "msg", p: "c2VhbGVk", key: "somebody-else", session: "another" });
      expect(await boxEnd.next()).toEqual({
        t: "msg",
        session,
        key: device.public,
        p: "c2VhbGVk",
      });
      boxEnd.say({ t: "msg", session, p: "YmFjaw" });
      expect(await one.end.next()).toEqual({ t: "msg", p: "YmFjaw" });
    });

    it("keeps two devices apart", async () => {
      const other = person();
      const boxEnd = await boxLine([device.public, other.public]);
      const one = await deviceLine();
      const two = await deviceLine(other);
      boxEnd.say({ t: "msg", session: (two.said as { session: string }).session, p: "dHdv" });
      expect(await two.end.next()).toEqual({ t: "msg", p: "dHdv" });
      expect(await one.end.silent()).toBe(true);
    });

    it("refuses everything that is not a signed-in box or a device on its list", async () => {
      await boxLine();
      const stranger = person();
      const tries: [string, Promise<{ end: End; said: unknown }>][] = [
        ["a device that is not on the list", deviceLine(stranger)],
        ["a box with another key", signIn(at.url, { role: "box", box: id, who: stranger })],
        [
          "a device that signs as a device and says it is a box",
          signIn(at.url, {
            role: "device",
            box: id,
            who: device,
            change: (message) => ({ ...message, role: "box" }),
          }),
        ],
        [
          "somebody else's signature",
          signIn(at.url, {
            role: "device",
            box: id,
            who: stranger,
            change: (message) => ({ ...message, key: device.public }),
          }),
        ],
        [
          "a signature over another challenge",
          signIn(at.url, {
            role: "device",
            box: id,
            who: device,
            change: (message) => ({
              ...message,
              signature: sign(
                null,
                Buffer.from(`lobby-introducer/1|device|${id}|${"A".repeat(43)}`),
                device.key,
              ).toString("base64url"),
            }),
          }),
        ],
        [
          "a message before signing in",
          signIn(at.url, {
            role: "device",
            box: id,
            who: device,
            change: () => ({ t: "msg", p: "c2VhbGVk" }),
          }),
        ],
      ];
      for (const [what, trying] of tries) {
        const { end, said } = await trying;
        ends.push(end);
        expect([what, said]).toEqual([what, CLOSED.refused]);
      }
    });

    it("has nothing at any other address, nor for a web page", async () => {
      const stranger = idOf(person());
      for (const [path, headers] of [
        ["/", {}],
        [`/v1/box/${stranger}`, {}],
        [`/v1/box/${id}/more`, {}],
        [`/v1/pair/${ROOM}`, {}],
        [`/v1/box/${id}`, { Origin: "https://example.com" }],
      ] as const) {
        const end = new End(`${at.url}${path}`, headers);
        ends.push(end);
        expect([path, await end.next()]).toEqual([path, 404]);
      }
      const plain = await fetch(`${at.url.replace(/^ws/, "http")}/v1/box/${id}`);
      expect(plain.status).toBe(404);
      expect(await plain.text()).toBe("");
    });

    it("tells a device that the box is not there, and knows nobody then", async () => {
      expect((await deviceLine()).said).toBe(CLOSED.offline);
      const boxEnd = await boxLine();
      const one = await deviceLine();
      boxEnd.close();
      expect(await one.end.next()).toBe(CLOSED.offline);
      expect((await deviceLine()).said).toBe(CLOSED.offline);
      // Back, but without its list yet.
      const { end } = await signIn(at.url, { role: "box", box: id, who: box });
      ends.push(end);
      expect((await deviceLine()).said).toBe(CLOSED.refused);
    });

    it("ends the line of a device that is taken off the list", async () => {
      const boxEnd = await boxLine();
      const one = await deviceLine();
      boxEnd.say({ t: "devices", keys: [] });
      expect(await one.end.next()).toBe(CLOSED.refused);
      expect((await deviceLine()).said).toBe(CLOSED.refused);
    });

    it("has one line for a box: the newest", async () => {
      const before = await boxLine();
      const now = await boxLine();
      expect(await before.next()).toBe(CLOSED.replaced);
      const one = await deviceLine();
      one.end.say({ t: "msg", p: "c2VhbGVk" });
      expect(await now.next()).toMatchObject({ t: "msg", p: "c2VhbGVk" });
    });

    it("closes lines that say too much, too often or what is no message", async () => {
      await boxLine();
      for (const wrong of [
        "not json",
        "[]",
        JSON.stringify({ t: "devices", keys: [] }),
        JSON.stringify({ t: "msg", p: 5 }),
        JSON.stringify({ t: "msg", p: "not base64url!" }),
        JSON.stringify({ t: "msg", p: "A".repeat(16_385) }),
        "A".repeat(17_000),
      ]) {
        const { end } = await deviceLine();
        end.say(wrong);
        expect([wrong.slice(0, 30), await end.next()]).toEqual([
          wrong.slice(0, 30),
          CLOSED.unreadable,
        ]);
      }
      const { end } = await deviceLine();
      for (let count = 0; count < 130; count += 1) end.say({ t: "msg", p: "c2VhbGVk" });
      expect(await end.next()).toBe(CLOSED.tooMuch);
    });

    it("has a pairing room while the box says so", async () => {
      const boxEnd = await boxLine();
      const enter = (): End => {
        const end = new End(`${at.url}/v1/pair/${ROOM}`);
        ends.push(end);
        return end;
      };
      expect(await enter().next()).toBe(404);
      boxEnd.say({ t: "pairing", room: ROOM, until: Date.now() + 60_000 });
      boxEnd.say("ping");
      await boxEnd.next();
      const end = enter();
      const ready = (await end.next()) as { session: string };
      expect(ready).toEqual({ t: "ready", session: expect.any(String) as string });
      end.say({ t: "msg", p: "Y29kZQ" });
      // Without a key: it is nobody yet.
      expect(await boxEnd.next()).toEqual({
        t: "msg",
        session: ready.session,
        room: ROOM,
        p: "Y29kZQ",
      });
      boxEnd.say({ t: "msg", session: ready.session, p: "YmFjaw" });
      expect(await end.next()).toEqual({ t: "msg", p: "YmFjaw" });
      boxEnd.say({ t: "pairing", room: null, until: 0 });
      expect(await end.next()).toBe(CLOSED.done);
      expect(await enter().next()).toBe(404);
    });

    const enter = (room: string): End => {
      const end = new End(`${at.url}/v1/pair/${room}`);
      ends.push(end);
      return end;
    };
    /** Says something, and waits until the introducer has taken it in. */
    const tell = async (boxEnd: End, message: object): Promise<void> => {
      boxEnd.say(message);
      boxEnd.say("ping");
      expect(await boxEnd.next()).toEqual({ t: "pong" });
    };

    /** In a room, having said its first thing, as a device does at once. */
    const speaking = async (boxEnd: End, room: string): Promise<End> => {
      const end = enter(room);
      expect(await end.next()).toMatchObject({ t: "ready" });
      end.say({ t: "msg", p: "c3RhcnQ" });
      expect(await boxEnd.next()).toMatchObject({ t: "msg", room, p: "c3RhcnQ" });
      return end;
    };

    it("has a room for every code the box has open, and says which one a device came in", async () => {
      const boxEnd = await boxLine();
      const rooms = [newRoom(), newRoom(), newRoom(), newRoom()];
      const until = Date.now() + 60_000;
      await tell(boxEnd, { t: "rooms", rooms: rooms.map((room) => ({ room, until })) });
      // The oldest as well as the newest, in any order, at the same time.
      const lines = [rooms[2], rooms[0], rooms[3], rooms[1]].map((room) => enter(room ?? ""));
      const sessions: string[] = [];
      for (const end of lines) {
        const ready = (await end.next()) as { session: string };
        expect(ready.session).toMatch(/^.{22}$/);
        sessions.push(ready.session);
      }
      for (const [index, end] of lines.entries())
        end.say({ t: "msg", p: `cm9vbQ${String(index)}` });
      const heard: unknown[] = [];
      for (let count = 0; count < lines.length; count += 1) heard.push(await boxEnd.next());
      expect(heard).toEqual(
        expect.arrayContaining(
          [rooms[2], rooms[0], rooms[3], rooms[1]].map((room, index) => ({
            t: "msg",
            session: sessions[index],
            room,
            p: `cm9vbQ${String(index)}`,
          })),
        ),
      );
      boxEnd.say({ t: "msg", session: sessions[3], p: "YmFjaw" });
      expect(await lines[3]?.next()).toEqual({ t: "msg", p: "YmFjaw" });
      expect(await lines[0]?.silent()).toBe(true);
    });

    it("closes the rooms a box leaves out, and keeps the others with whoever is in them", async () => {
      const boxEnd = await boxLine();
      const [one, two, three] = [newRoom(), newRoom(), newRoom()];
      const until = Date.now() + 60_000;
      await tell(boxEnd, {
        t: "rooms",
        rooms: [one, two, three].map((room) => ({ room, until })),
      });
      const inOne = await speaking(boxEnd, one);
      const inTwo = await speaking(boxEnd, two);
      boxEnd.say({
        t: "rooms",
        rooms: [
          { room: two, until },
          { room: three, until },
        ],
      });
      expect(await inOne.next()).toBe(CLOSED.done);
      expect(await inTwo.silent()).toBe(true);
      expect(await enter(one).next()).toBe(404);
      expect(await enter(three).next()).toMatchObject({ t: "ready" });
      boxEnd.say({ t: "rooms", rooms: [] });
      expect(await inTwo.next()).toBe(CLOSED.done);
      expect(await enter(three).next()).toBe(404);
    });

    it("still has one room for a box from before, which takes the place of all", async () => {
      const boxEnd = await boxLine();
      const [one, two] = [newRoom(), newRoom()];
      const until = Date.now() + 60_000;
      await tell(boxEnd, { t: "rooms", rooms: [{ room: one, until }] });
      await tell(boxEnd, { t: "pairing", room: two, until });
      expect(await enter(one).next()).toBe(404);
      const inTwo = await speaking(boxEnd, two);
      boxEnd.say({ t: "pairing", room: one, until });
      expect(await inTwo.next()).toBe(CLOSED.done);
      expect(await enter(one).next()).toMatchObject({ t: "ready" });
    });

    it("has no more rooms for a box than it says, and none of another box's", async () => {
      const boxEnd = await boxLine();
      const until = Date.now() + 60_000;
      const many = Array.from({ length: 65 }, () => ({ room: newRoom(), until }));
      boxEnd.say({ t: "rooms", rooms: many });
      expect(await boxEnd.next()).toBe(CLOSED.unreadable);
      for (const wrong of [
        { t: "rooms", rooms: "all" },
        { t: "rooms", rooms: [{ room: "short", until }] },
        { t: "rooms", rooms: [{ room: newRoom() }] },
      ]) {
        const again = await boxLine();
        again.say(wrong);
        expect([wrong, await again.next()]).toEqual([wrong, CLOSED.unreadable]);
      }
      const last = await boxLine();
      await tell(last, { t: "rooms", rooms: many.slice(0, 64) });
      expect(await enter(many[63]?.room ?? "").next()).toMatchObject({ t: "ready" });
    });

    it("lets three devices into a room at a time, and others into the other rooms", async () => {
      const boxEnd = await boxLine();
      const [one, two] = [newRoom(), newRoom()];
      const until = Date.now() + 60_000;
      await tell(boxEnd, {
        t: "rooms",
        rooms: [
          { room: one, until },
          { room: two, until },
        ],
      });
      for (let count = 0; count < 3; count += 1) {
        expect(await enter(one).next()).toMatchObject({ t: "ready" });
      }
      expect(await enter(one).next()).toBe(429);
      expect(await enter(two).next()).toMatchObject({ t: "ready" });
    });

    it("sends away who does not sign in, each ten seconds after it came", async () => {
      const first = new End(`${at.url}/v1/box/${id}`);
      ends.push(first);
      expect(await first.next()).toMatchObject({ t: "challenge" });
      await new Promise((resolve) => setTimeout(resolve, 4_000));
      const end = new End(`${at.url}/v1/box/${id}`);
      ends.push(end);
      expect(await end.next()).toMatchObject({ t: "challenge" });
      expect(await first.next(25_000)).toBe(CLOSED.late);
      const firstGone = Date.now();
      expect(await end.next(25_000)).toBe(CLOSED.late);
      // Four seconds after the first, as it came four seconds later; not when the introducer
      // would look again, a whole ten seconds after it sent the first away.
      expect(Date.now() - firstGone).toBeLessThan(8_000);
    }, 60_000);
  });
}

describe("the day's end", () => {
  for (const [name, start] of [
    ["in Node", (box: string) => startNode([box], { perDay: 8 })],
    ["in workerd", (box: string) => startWorker([box], 8)],
  ] as const) {
    it(`refuses everything after it, ${name}`, async () => {
      const box = person();
      const id = idOf(box);
      const at = await start(id);
      try {
        // A line and its signature are two.
        const lines: End[] = [];
        for (let count = 0; count < 4; count += 1) {
          const { end, said } = await signIn(at.url, { role: "box", box: id, who: box });
          lines.push(end);
          expect(said).toEqual(BOX_READY);
        }
        expect((await signIn(at.url, { role: "box", box: id, who: box })).said).toBe(503);
        lines.at(-1)?.say({ t: "devices", keys: [] });
        expect(await lines.at(-1)?.next()).toBe(CLOSED.fullDay);
        for (const end of lines) end.close();
      } finally {
        await at.close();
      }
    });
  }
});

describe("an introducer of one room per box, as before", () => {
  it("says nothing of rooms, nor which room a device came by, and takes no list", async () => {
    const box = person();
    const id = idOf(box);
    const at = await startNode([id], { roomsPerBox: 1 });
    const ends: End[] = [];
    try {
      const { end, said } = await signIn(at.url, { role: "box", box: id, who: box });
      ends.push(end);
      expect(said).toEqual({ t: "ready" });
      end.say({ t: "pairing", room: ROOM, until: Date.now() + 60_000 });
      end.say("ping");
      await end.next();
      const device = new End(`${at.url}/v1/pair/${ROOM}`);
      ends.push(device);
      const ready = (await device.next()) as { session: string };
      device.say({ t: "msg", p: "Y29kZQ" });
      expect(await end.next()).toEqual({ t: "msg", session: ready.session, p: "Y29kZQ" });
      end.say({ t: "rooms", rooms: [] });
      expect(await end.next()).toBe(CLOSED.unreadable);
    } finally {
      for (const end of ends) end.close();
      await at.close();
    }
  });
});

/** A ground that stays when the introducer on it goes. */
class Field implements Ground {
  readonly kept = new Map<string, unknown>();
  readonly all = new Set<Fake>();
  time = Date.UTC(2026, 0, 1, 23, 0);
  wake: number | null = null;
  readonly lines = (): Line[] => [...this.all];
  readonly read = (key: string): Promise<unknown> => Promise.resolve(this.kept.get(key));
  readonly write = (key: string, value: unknown): Promise<void> => {
    this.kept.set(key, value);
    return Promise.resolve();
  };
  readonly remove = (key: string): Promise<void> => {
    this.kept.delete(key);
    return Promise.resolve();
  };
  readonly wakeAt = (at: number): Promise<void> => {
    this.wake = at;
    return Promise.resolve();
  };
  readonly now = (): number => this.time;
}

class Fake implements Line {
  readonly sent: Record<string, unknown>[] = [];
  closed: number | null = null;
  private current: LineState | null = null;
  private readonly field: Field;
  constructor(field: Field) {
    this.field = field;
    field.all.add(this);
  }
  send(text: string): void {
    this.sent.push(JSON.parse(text) as Record<string, unknown>);
  }
  close(code: number): void {
    this.closed = code;
    this.field.all.delete(this);
  }
  state(): LineState | null {
    return this.current;
  }
  remember(state: LineState): void {
    this.current = JSON.parse(JSON.stringify(state)) as LineState;
  }
}

describe("a nap", () => {
  const enter = async (field: Field, introducer: Introducer, box: Person, role: string) => {
    const who = box;
    const state = await introducer.admit({ kind: "box", box: idOf(box) }, "203.0.113.1");
    if (typeof state === "number") throw new Error(String(state));
    const line = new Fake(field);
    await introducer.opened(line, state);
    const nonce = String(line.sent[0]?.["nonce"]);
    const signature = sign(
      null,
      Buffer.from(`lobby-introducer/1|${role}|${idOf(box)}|${nonce}`),
      who.key,
    ).toString("base64url");
    await introducer.heard(line, JSON.stringify({ t: "auth", role, key: who.public, signature }));
    return line;
  };

  it("forgets no line, no list and no count", async () => {
    const field = new Field();
    const box = person();
    const limits = { perDay: 60, countAhead: 50 };
    const before = new Introducer(field, limits);
    const line = await enter(field, before, box, "box");
    const keys = [person().public];
    await before.heard(line, JSON.stringify({ t: "devices", keys }));
    expect(line.sent.at(-1)).toEqual({ t: "ready", rooms: 64 });

    const after = new Introducer(field, limits);
    expect(field.kept.get(`devices:${idOf(box)}`)).toEqual(keys);
    // What was counted ahead is gone, and not given twice.
    for (let count = 0; count < 10; count += 1) {
      await after.heard(line, JSON.stringify({ t: "devices", keys }));
    }
    expect(line.closed).toBeNull();
    await after.heard(line, JSON.stringify({ t: "devices", keys }));
    expect(line.closed).toBe(CLOSED.fullDay);
    field.time += 2 * 3_600_000;
    expect(await after.admit({ kind: "box", box: idOf(box) }, "203.0.113.1")).toBeTypeOf("object");
  });

  it("is woken for lines that are late, and no longer than there are any", async () => {
    const field = new Field();
    const introducer = new Introducer(field);
    const box = person();
    const line = await enter(field, introducer, box, "box");
    field.time += 60_000;
    field.wake = null;
    await introducer.woke();
    expect([line.closed, field.wake]).toEqual([null, null]);
  });

  const pairingLine = async (introducer: Introducer, field: Field, room: string) => {
    const state = await introducer.admit({ kind: "pairing", room }, "198.51.100.7");
    if (typeof state === "number") return state;
    const line = new Fake(field);
    await introducer.opened(line, state);
    return line;
  };

  it("lets every room end by itself, and keeps none longer than 45 minutes", async () => {
    const field = new Field();
    const introducer = new Introducer(field);
    const box = person();
    const line = await enter(field, introducer, box, "box");
    const [short, long] = ["S".repeat(22), "L".repeat(22)];
    await introducer.heard(
      line,
      JSON.stringify({
        t: "rooms",
        rooms: [
          { room: short, until: field.time + 60_000 },
          { room: long, until: field.time + 24 * 3_600_000 },
        ],
      }),
    );
    expect(await pairingLine(introducer, field, short)).toBeInstanceOf(Fake);
    field.time += 2 * 60_000;
    expect(await pairingLine(introducer, field, short)).toBe(404);
    expect(await pairingLine(introducer, field, long)).toBeInstanceOf(Fake);
    field.time += 44 * 60_000;
    expect(await pairingLine(introducer, field, long)).toBe(404);
    // Said again, it is there again; what is over is not kept.
    await introducer.heard(
      line,
      JSON.stringify({ t: "rooms", rooms: [{ room: long, until: field.time + 60_000 }] }),
    );
    expect(await pairingLine(introducer, field, long)).toBeInstanceOf(Fake);
    expect(field.kept.get(`rooms-of:${idOf(box)}`)).toEqual([long]);
    expect(field.kept.has(`room:${short}`)).toBe(false);
  });

  it("ends a quiet line whose room is over once it speaks", async () => {
    const field = new Field();
    const introducer = new Introducer(field);
    const box = await enter(field, introducer, person(), "box");
    const [one, two] = ["o".repeat(22), "t".repeat(22)];
    const until = field.time + 60_000;
    await introducer.heard(box, JSON.stringify({ t: "rooms", rooms: [{ room: one, until }] }));
    const quiet = await pairingLine(introducer, field, one);
    if (typeof quiet === "number") throw new Error(String(quiet));
    // As workerd may: the room is closed, but the line is not told.
    field.all.delete(quiet);
    await introducer.heard(box, JSON.stringify({ t: "rooms", rooms: [{ room: two, until }] }));
    expect(quiet.closed).toBeNull();
    field.all.add(quiet);
    const told = box.sent.length;
    await introducer.heard(quiet, JSON.stringify({ t: "msg", p: "c3RhcnQ" }));
    expect(quiet.closed).toBe(CLOSED.done);
    expect(box.sent.length).toBe(told);
  });

  it("limits the pairing lines of a box in all its rooms together", async () => {
    const field = new Field();
    const introducer = new Introducer(field, { pairingPerBox: 4, openPerMinute: 100 });
    const line = await enter(field, introducer, person(), "box");
    const rooms = ["a", "b", "c"].map((letter) => letter.repeat(22));
    await introducer.heard(
      line,
      JSON.stringify({
        t: "rooms",
        rooms: rooms.map((room) => ({ room, until: field.time + 60_000 })),
      }),
    );
    const got = [];
    for (const room of [...rooms, ...rooms]) got.push(await pairingLine(introducer, field, room));
    expect(got.map((one) => (typeof one === "number" ? one : "in"))).toEqual([
      "in",
      "in",
      "in",
      "in",
      429,
      429,
    ]);
  });

  it("takes over the one room an introducer from before kept", async () => {
    const field = new Field();
    const box = person();
    const before = "B".repeat(22);
    field.kept.set(`room:${before}`, { box: idOf(box), until: field.time + 60_000 });
    field.kept.set(`room-of:${idOf(box)}`, before);
    const introducer = new Introducer(field);
    const line = await enter(field, introducer, box, "box");
    const inside = await pairingLine(introducer, field, before);
    expect(inside).toBeInstanceOf(Fake);
    const now = "N".repeat(22);
    await introducer.heard(
      line,
      JSON.stringify({ t: "rooms", rooms: [{ room: now, until: field.time + 60_000 }] }),
    );
    expect((inside as Fake).closed).toBe(CLOSED.done);
    expect(field.kept.has(`room:${before}`)).toBe(false);
    expect(field.kept.has(`room-of:${idOf(box)}`)).toBe(false);
    expect(field.kept.get(`rooms-of:${idOf(box)}`)).toEqual([now]);
  });

  it("limits addresses, and keeps its memory small", () => {
    const limiter = new PerMinute(2);
    expect([1, 2, 3].map(() => limiter.take("a", 2, 0))).toEqual([true, true, false]);
    expect(limiter.take("b", 2, 0)).toBe(true);
    expect(limiter.take("c", 2, 0)).toBe(false);
    expect(limiter.take("c", 2, 60_000)).toBe(true);
  });
});

describe("addresses", () => {
  it("are for boxes that are known", () => {
    const id = idOf(person());
    expect(readBoxes(` ${id}, <box id>,short `)).toEqual([id]);
    expect(wishOf(`/v1/box/${id}`, [id])).toEqual({ kind: "box", box: id });
    expect(wishOf(`/v1/box/${id}`, [])).toBeNull();
    expect(wishOf(`/v1/pair/${ROOM}`, [])).toEqual({ kind: "pairing", room: ROOM });
    expect(wishOf("/v1/pair/short", [])).toBeNull();
  });
});
