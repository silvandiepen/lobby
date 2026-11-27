// SPDX-License-Identifier: MPL-2.0
import { randomBytes, type KeyObject } from "node:crypto";
import { PLATFORMS, type Device, type Platform } from "../../auth/devices.ts";
import { log } from "../../log.ts";
import { readCode } from "../code.ts";
import type { Opening, OutsidePairing } from "../pairing.ts";
import type { DirectIdentities, DirectIdentity } from "./identities.ts";
import type { Heard, PairingRoom } from "./introducer.ts";
import type { BoxKeys } from "./keys.ts";
import {
  agree,
  b64,
  newAgreementKey,
  open,
  pairingAad,
  pairingCode,
  pairingCommitment,
  pairingKeys,
  pairingSecrets,
  rawPublic,
  seal,
  transcriptHash,
  unb64,
  type PairingSecrets,
} from "./envelope.ts";

/** Devices that may begin with one code: one that lost its line may try again. */
const MAX_STARTS = 5;
/** Things said in the room that were not said by who has the code. */
const MAX_WRONG = 50;
/** A window may close while a device is in it. */
const LINGER_MS = 10 * 60_000;
/** The introducer keeps a room for 45 minutes at most: one that lasts longer is said again. */
const REFRESH_MS = 30 * 60_000;
/** Rooms said to the introducer at most, as many as it keeps for one box. */
const MAX_ROOMS = 64;

interface Begun {
  commitment: Buffer;
  agreement: KeyObject;
  nonce: Buffer;
}

interface Paired {
  secrets: PairingSecrets;
  id: string;
  pollSecret: string;
  ringKey: string;
  /** Once approved, so that it can be said again when the line broke. */
  answer: object | null;
}

interface Room {
  /** The window or invitation the code leads to. */
  opening: string;
  openedAt: number;
  room: string;
  key: Buffer;
  until: number;
  begun: Map<string, Begun>;
  starts: number;
  wrong: number;
  paired: Paired | null;
}

interface PairingDeps {
  pairing: OutsidePairing;
  identities: DirectIdentities;
  keys: BoxKeys;
  /** The rooms at the introducer, the one that matters most first: the others are closed. */
  setRooms: (rooms: PairingRoom[]) => void;
  now: () => number;
}

/**
 * Pairing a device that only has the code, through the introducer, which learns none of it. The
 * code's 80 bits are stretched into a key; under it both sides make a fresh agreement, the device
 * bound to its half before it sees the box's, so that the six digits cannot be steered.
 *
 * Every code that leads in (windows, invitations) has its own room at the introducer, made from
 * the code, and the introducer says by which room a device came. An introducer from before keeps
 * one room of a box: that one is the room a device is pairing in, else the newest code's.
 */
export class DirectPairing {
  private readonly deps: PairingDeps;
  private readonly rooms = new Map<string, Room>();
  /** Codes being stretched, so that one closed meanwhile is not opened after all. */
  private readonly stretching = new Map<string, number>();
  private turn = 0;
  /** What the introducer was told, and when. */
  private told: { rooms: string; at: number } | null = null;
  private tooMany = false;

  constructor(deps: PairingDeps) {
    this.deps = deps;
  }

  /** A manager opened a window, or the owner invited a household. */
  async opened(opening: Opening): Promise<void> {
    this.turn += 1;
    const mine = this.turn;
    this.stretching.set(opening.id, mine);
    let made: { room: string; key: Buffer } | null = null;
    if (opening.room !== null && opening.roomKey !== null) {
      made = { room: opening.room, key: opening.roomKey };
    } else if (opening.code !== null) {
      const code = readCode(opening.code);
      if (code !== null) made = await pairingCode(code);
    }
    if (this.stretching.get(opening.id) !== mine) return;
    this.stretching.delete(opening.id);
    if (!made) return;
    this.rooms.set(opening.id, {
      opening: opening.id,
      openedAt: this.deps.now(),
      room: made.room,
      key: made.key,
      until: opening.until,
      begun: new Map(),
      starts: 0,
      wrong: 0,
      paired: null,
    });
    this.announce();
  }

  /** @param openingId the code that leads in no more; every one when left out */
  closed(openingId?: string): void {
    if (openingId === undefined) {
      this.stretching.clear();
      this.rooms.clear();
    } else {
      this.stretching.delete(openingId);
      this.rooms.delete(openingId);
    }
    this.announce();
  }

  /** The rooms a device is pairing in, then the newest, then the older ones. */
  private get ordered(): Room[] {
    // Newest made first where they were opened in the same moment.
    return [...this.rooms.values()]
      .reverse()
      .sort(
        (one, other) =>
          Number(other.paired !== null) - Number(one.paired !== null) ||
          other.openedAt - one.openedAt,
      );
  }

  private announce(): void {
    const ordered = this.ordered;
    const now = this.deps.now();
    if (ordered.length > MAX_ROOMS && !this.tooMany) {
      log.warn("More codes are open than the introducer keeps rooms for: the oldest wait", {
        open: ordered.length,
        rooms: MAX_ROOMS,
      });
    }
    this.tooMany = ordered.length > MAX_ROOMS;
    const rooms = ordered
      .slice(0, MAX_ROOMS)
      .map((one) => ({ room: one.room, until: one.until + LINGER_MS }));
    const telling = rooms.map((one) => `${one.room} ${String(one.until)}`).join(" ");
    if (rooms.length === 0 && this.told === null) return;
    if (this.told?.rooms === telling && now - this.told.at < REFRESH_MS) return;
    this.told = rooms.length === 0 ? null : { rooms: telling, at: now };
    this.deps.setRooms(rooms);
  }

  /** The room a device speaks in. */
  private roomOf(message: Heard): Room | undefined {
    // An introducer from before has only the first, and does not say.
    if (message.room === null) return this.ordered[0];
    for (const one of this.rooms.values()) if (one.room === message.room) return one;
    return undefined;
  }

  private close(one: Room): void {
    this.rooms.delete(one.opening);
    this.announce();
  }

  tick(): void {
    const now = this.deps.now();
    for (const one of [...this.rooms.values()]) {
      const waiting = one.paired !== null;
      const over = waiting
        ? now > one.until + LINGER_MS
        : !this.deps.pairing.isOpen(one.opening) || now > one.until;
      if (over) this.rooms.delete(one.opening);
    }
    this.announce();
  }

  heard(message: Heard, reply: (payload: string) => void): void {
    const one = this.roomOf(message);
    if (!one || one.wrong >= MAX_WRONG) return;
    const { session, payload } = message;
    const { room } = one;
    if (one.paired) {
      const asked = open(one.paired.secrets.d2b, pairingAad(room, session, "collect"), payload);
      if (asked) this.collect(one, one.paired, session, asked, reply);
      else one.wrong += 1;
      return;
    }
    const begun = one.begun.get(session);
    const step = begun ? "reveal" : "start";
    const key = pairingKeys.code(one.key, "d2b");
    const said = open(key, pairingAad(room, session, step), payload);
    if (!said) {
      one.wrong += 1;
      return;
    }
    if (begun) this.reveal(one, begun, session, said, reply);
    else this.start(one, session, said, reply);
  }

  private start(
    one: Room,
    session: string,
    said: Record<string, unknown>,
    reply: (payload: string) => void,
  ): void {
    const commitment = unb64(said["commitment"], 32);
    if (!commitment || one.starts >= MAX_STARTS) return;
    one.starts += 1;
    const begun: Begun = { commitment, agreement: newAgreementKey(), nonce: randomBytes(32) };
    one.begun.set(session, begun);
    reply(
      seal(pairingKeys.code(one.key, "b2d"), pairingAad(one.room, session, "key"), {
        agreementKey: b64(rawPublic(begun.agreement)),
        nonce: b64(begun.nonce),
        boxKey: b64(this.deps.keys.boxPublic),
      }),
    );
  }

  private reveal(
    one: Room,
    begun: Begun,
    session: string,
    said: Record<string, unknown>,
    reply: (payload: string) => void,
  ): void {
    // Whatever comes of it, this conversation is used up.
    one.begun.delete(session);
    const deviceAgreement = unb64(said["agreementKey"], 32);
    const deviceNonce = unb64(said["nonce"], 32);
    const ringKey = unb64(said["ringKey"], 32);
    const deviceName = said["deviceName"];
    const platform = PLATFORMS.find((known) => known === said["platform"] && known !== "cli");
    if (
      !deviceAgreement ||
      !deviceNonce ||
      !ringKey ||
      platform === undefined ||
      typeof deviceName !== "string" ||
      deviceName.trim() === "" ||
      deviceName.length > 200 ||
      !pairingCommitment(deviceAgreement, deviceNonce).equals(begun.commitment)
    ) {
      one.wrong += 1;
      return;
    }
    let shared: Buffer;
    try {
      shared = agree(begun.agreement, deviceAgreement);
    } catch {
      one.wrong += 1;
      return;
    }
    const secrets = pairingSecrets(
      shared,
      one.key,
      transcriptHash({
        room: one.room,
        commitment: begun.commitment,
        boxAgreement: rawPublic(begun.agreement),
        boxNonce: begun.nonce,
        boxKey: this.deps.keys.boxPublic,
        deviceAgreement,
        deviceNonce,
        ringKey,
        deviceName,
        platform,
      }),
    );
    const asked = this.present(one, deviceName, platform, secrets.comparison);
    if (!asked) return;
    one.paired = {
      secrets,
      id: asked.id,
      pollSecret: asked.pollSecret,
      ringKey: b64(ringKey),
      answer: null,
    };
    // Nobody else gets in with this code, and an invitation's room does not stay for days.
    one.begun.clear();
    one.until = Math.min(one.until, this.deps.now() + LINGER_MS);
    log.info("A device asks to pair from outside");
    reply(
      seal(secrets.b2d, pairingAad(one.room, session, "waiting"), {
        status: "pending",
        expiresAt: asked.expiresAt,
      }),
    );
    // A device pairing here keeps this room, whatever is opened meanwhile, and it ends sooner.
    this.announce();
  }

  private present(
    one: Room,
    deviceName: string,
    platform: Platform,
    comparison: string,
  ): ReturnType<OutsidePairing["present"]> {
    // The same window as over any other road, used up by the same act.
    return this.deps.pairing.presentOpening(one.opening, deviceName, platform, comparison);
  }

  private collect(
    one: Room,
    paired: Paired,
    session: string,
    asked: Record<string, unknown>,
    reply: (payload: string) => void,
  ): void {
    const nonce = unb64(asked["nonce"], 16);
    if (!nonce) return;
    const answer = (value: object): void => {
      // The question's own number is in the answer's place, so an old answer is none.
      const aad = pairingAad(one.room, session, `answer|${b64(nonce)}`);
      reply(seal(paired.secrets.b2d, aad, value));
    };
    if (asked["done"] === true && paired.answer) {
      answer({ status: "done" });
      this.close(one);
      return;
    }
    if (paired.answer) {
      answer(paired.answer);
      return;
    }
    const collected = this.deps.pairing.collect(paired.id, paired.pollSecret);
    if (!collected) {
      answer({ status: "refused" });
      this.close(one);
      return;
    }
    if (collected.status === "pending") {
      answer(collected);
      return;
    }
    paired.answer = this.complete(collected, paired);
    answer(paired.answer);
  }

  private complete(
    collected: { device: Device; token: string },
    paired: Paired,
  ): { status: "approved"; device: Device; token: string; direct: DirectIdentity | null } {
    const { identities } = this.deps;
    const kept = identities.keep(collected.device.id, paired.ringKey, paired.secrets.secret);
    log.info("A device was paired from outside", { device: collected.device.id });
    return {
      status: "approved",
      device: collected.device,
      token: collected.token,
      direct: kept ? identities.identity() : null,
    };
  }
}
