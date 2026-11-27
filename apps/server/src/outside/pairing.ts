// SPDX-License-Identifier: MPL-2.0
import { randomBytes, randomUUID } from "node:crypto";
import {
  AuthError,
  managesHousehold,
  type Access,
  type Device,
  type Devices,
  type Platform,
} from "../auth/devices.ts";
import type { InviteOpening, Invites } from "../households/invites.ts";
import { OWNER_HOUSEHOLD } from "../households/owner.ts";
import { hashSecret, matches, newCode, newComparison, readCode } from "./code.ts";

export const DEFAULT_WINDOW_MINUTES = 10;
export const MAX_WINDOW_MINUTES = 30;
/** How long a device that showed the right code waits for a manager. */
const REQUEST_MS = 10 * 60_000;
/** Devices that may wait at once, of all households together. */
const MAX_REQUESTS = 32;

export interface OutsideWindow {
  openedBy: string;
  openedAt: number;
  expiresAt: number;
}

/** A device that presented the code and waits for a manager. */
export interface OutsidePairingRequest {
  id: string;
  outside: true;
  deviceName: string;
  platform: Platform;
  /** As the transport gave it; it may be wrong or somebody else's. */
  address: string | null;
  /** The digits on the new device's screen. */
  comparison: string;
  createdAt: number;
  expiresAt: number;
  /** The household it will be in. */
  householdId: string;
  /** It came with an invitation. */
  invited: boolean;
  /** What it will be in its household. */
  access: Access;
  /**
   * `waiting`: for its household admin's yes, with the digits. `awaitingAdmin`: its household
   * admin said yes, and its household needs a server admin's too. `refused`: a server admin
   * said no; its household admin is told until it would have expired.
   */
  state: "waiting" | "awaitingAdmin" | "refused";
}

/** Who says yes or no: their household, and what they are in it. */
export interface Approver {
  householdId: string;
  access: Access;
}

/** A server admin of the owner's household, as the server's own tools approve. */
export const SERVER_ADMIN: Approver = { householdId: OWNER_HOUSEHOLD, access: "admin" };

/** Where a code leads: a window a manager opened for their household, or an invitation. */
export interface Opening {
  /** The window's or the invitation's id. */
  id: string;
  householdId: string;
  access: Access;
  inviteId: string | null;
  until: number;
  /** The code, when it is known here (for the direct road to stretch); else what it made. */
  code: string | null;
  room: string | null;
  roomKey: Buffer | null;
}

interface Window extends OutsideWindow {
  id: string;
  householdId: string;
  hash: Buffer;
  code: string;
  /** A device came with its code: it leads in no more, and closing it turns that device away. */
  used: boolean;
}

interface Request extends Omit<OutsidePairingRequest, "state"> {
  pollHash: Buffer;
  stage: "waiting" | "admin" | "approved" | "refused";
  inviteId: string | null;
  opening: string;
}

/** A name that cannot fool the manager who reads it: no control or direction characters. */
function plainName(name: string): string {
  return (
    name
      .replace(/[\p{C}\p{Zl}\p{Zp}]/gu, "")
      .replace(/\s+/g, " ")
      .trim()
      .slice(0, 80) || "Unnamed device"
  );
}

interface PairingOptions {
  /** Invitations to a household, whose codes also lead in here. */
  invites?: Invites | null;
  /** Whether a household takes one more device: it is there, not paused, not full. */
  fits?: (householdId: string) => boolean;
  /** Whether a household's new devices also need a server admin's yes. */
  requiresAdmin?: (householdId: string) => boolean;
}

/**
 * Pairing from outside. Closed, until a manager opens a window for one device of their
 * household, or the owner invites a household. Windows and requests are in memory, and of the
 * secrets only hashes: a restart closes them. Invitations are in the catalogue, as hashes.
 */
export class OutsidePairing {
  private readonly devices: Devices;
  private readonly now: () => number;
  private readonly invites: Invites | null;
  private readonly fits: (householdId: string) => boolean;
  private readonly requiresAdmin: (householdId: string) => boolean;
  /** Told of every code there is, so that it can be known by other roads, and when it is over. */
  onOpened: ((opening: Opening) => void) | null = null;
  onClosed: ((openingId: string) => void) | null = null;
  /** One per household: a new window replaces the one before, and whoever waited at it. */
  private readonly windows = new Map<string, Window>();
  private readonly requests = new Map<string, Request>();

  constructor(devices: Devices, now: () => number, options: PairingOptions = {}) {
    this.devices = devices;
    this.now = now;
    this.invites = options.invites ?? null;
    this.fits = options.fits ?? (() => true);
    this.requiresAdmin = options.requiresAdmin ?? (() => false);
    if (this.invites) {
      this.invites.onCreated = (invite) => {
        this.onOpened?.(this.inviteOpening(invite));
      };
      this.invites.onEnded = (id) => {
        this.onClosed?.(id);
      };
    }
  }

  private inviteOpening(invite: InviteOpening): Opening {
    return {
      id: invite.id,
      householdId: invite.householdId,
      access: invite.access,
      inviteId: invite.id,
      until: invite.expiresAt,
      code: null,
      room: invite.room,
      roomKey: invite.roomKey,
    };
  }

  /** Every code that leads in now, the newest last. */
  openings(): Opening[] {
    const windows = [...this.windows.values()]
      .filter((one) => !one.used && one.expiresAt > this.now())
      .map((one): [number, Opening] => [
        one.openedAt,
        {
          id: one.id,
          householdId: one.householdId,
          access: "viewer",
          inviteId: null,
          until: one.expiresAt,
          code: one.code,
          room: null,
          roomKey: null,
        },
      ]);
    const invites = (this.invites?.open() ?? []).map((one): [number, Opening] => [
      one.createdAt,
      this.inviteOpening(one),
    ]);
    return [...windows, ...invites].sort((a, b) => a[0] - b[0]).map(([, opening]) => opening);
  }

  /** Whether the code with this id still leads in. */
  isOpen(openingId: string): boolean {
    return this.openings().some((one) => one.id === openingId);
  }

  /**
   * @param householdId the household the device will be in, as a viewer
   */
  open(
    by: string,
    minutes: number,
    householdId = OWNER_HOUSEHOLD,
  ): { code: string; expiresAt: number } {
    const code = newCode();
    const openedAt = this.now();
    const expiresAt = openedAt + minutes * 60_000;
    this.close(householdId);
    const window: Window = {
      id: randomUUID(),
      householdId,
      openedBy: by,
      openedAt,
      expiresAt,
      code,
      hash: hashSecret(readCode(code) ?? code),
      used: false,
    };
    this.windows.set(householdId, window);
    this.onOpened?.({
      id: window.id,
      householdId,
      access: "viewer",
      inviteId: null,
      until: expiresAt,
      code,
      room: null,
      roomKey: null,
    });
    return { code, expiresAt };
  }

  /** Closes a household's window, and forgets who was waiting at it. */
  close(householdId = OWNER_HOUSEHOLD): void {
    const window = this.windows.get(householdId);
    this.windows.delete(householdId);
    for (const [id, request] of this.requests) {
      if (request.householdId === householdId && request.inviteId === null) {
        this.requests.delete(id);
      }
    }
    if (window) this.onClosed?.(window.id);
  }

  /** Closes everything: the entrance is off. Invitations stay; they work when it is on. */
  closeAll(): void {
    for (const householdId of [...this.windows.keys()]) this.close(householdId);
    this.requests.clear();
  }

  /** Forgets a household that was paused or removed: nobody of it is waiting any more. */
  forget(householdId: string): void {
    this.close(householdId);
    for (const [id, request] of this.requests) {
      if (request.householdId === householdId) this.requests.delete(id);
    }
  }

  current(householdId = OWNER_HOUSEHOLD): OutsideWindow | null {
    const window = this.windows.get(householdId);
    if (window && !window.used && window.expiresAt <= this.now()) this.close(householdId);
    const live = this.windows.get(householdId);
    if (!live || live.used) return null;
    const { openedBy, openedAt, expiresAt } = live;
    return { openedBy, openedAt, expiresAt };
  }

  private live(): Map<string, Request> {
    for (const [id, request] of this.requests) {
      if (request.expiresAt <= this.now()) this.requests.delete(id);
    }
    return this.requests;
  }

  private shown(request: Request): OutsidePairingRequest {
    const { id, outside, deviceName, platform, address, comparison } = request;
    const { createdAt, expiresAt, householdId, invited, access, stage } = request;
    return {
      id,
      outside,
      deviceName,
      platform,
      address,
      comparison,
      createdAt,
      expiresAt,
      householdId,
      invited,
      access,
      state: stage === "admin" ? "awaitingAdmin" : stage === "refused" ? "refused" : "waiting",
    };
  }

  /**
   * Whether this approver may say yes or no to it now. A household's admins decide about their
   * own household's devices; a server admin about those of the owner's household, those that
   * came with an invitation, and every one that waits for a server admin.
   */
  private mayDecide(request: Request, approver: Approver): boolean {
    if (request.stage === "admin") return approver.access === "admin";
    if (request.stage !== "waiting") return false;
    if (approver.access === "admin") {
      return request.householdId === OWNER_HOUSEHOLD || request.inviteId !== null;
    }
    return managesHousehold(approver.access) && approver.householdId === request.householdId;
  }

  /** Those this approver is to see: what they may decide, and what of theirs was turned away. */
  waiting(approver: Approver = SERVER_ADMIN): OutsidePairingRequest[] {
    return [...this.live().values()]
      .filter(
        (one) =>
          this.mayDecide(one, approver) ||
          ((one.stage === "admin" || one.stage === "refused") &&
            managesHousehold(approver.access) &&
            one.householdId === approver.householdId),
      )
      .map((one) => this.shown(one));
  }

  /**
   * A device shows the code it was given. Null when it is not a code that leads in.
   *
   * @param comparison the digits, when both ends worked them out themselves
   */
  present(
    typed: string,
    deviceName: string,
    platform: Platform,
    address: string | null,
    comparison: string = newComparison(),
  ): { id: string; pollSecret: string; comparison: string; expiresAt: number } | null {
    const code = readCode(typed) ?? "";
    // Every code is compared, so the answer takes as long whichever one it is, or none.
    const hashes = [
      ...[...this.windows.values()]
        .filter((one) => !one.used && one.expiresAt > this.now())
        .map((one) => ({ id: one.id, hash: one.hash })),
      ...(this.invites?.open() ?? []).map((one) => ({ id: one.id, hash: one.hash })),
    ];
    let matched: string | null = null;
    for (const one of hashes.length > 0 ? hashes : [{ id: "", hash: null }]) {
      if (matches(code, one.hash) && code !== "") matched = one.id;
    }
    const found = matched === null ? null : this.openings().find((one) => one.id === matched);
    return found ? this.begin(found, deviceName, platform, address, comparison) : null;
  }

  /** The same, for a device on the direct road, which proved the code to that road. */
  presentOpening(
    openingId: string,
    deviceName: string,
    platform: Platform,
    comparison: string,
  ): { id: string; pollSecret: string; comparison: string; expiresAt: number } | null {
    const found = this.openings().find((one) => one.id === openingId);
    return found ? this.begin(found, deviceName, platform, null, comparison) : null;
  }

  private begin(
    opening: Opening,
    deviceName: string,
    platform: Platform,
    address: string | null,
    comparison: string,
  ): { id: string; pollSecret: string; comparison: string; expiresAt: number } | null {
    if (!this.fits(opening.householdId) || this.live().size >= MAX_REQUESTS) return null;
    // Used up by the one who came with it, whatever comes of the request.
    if (opening.inviteId !== null) {
      if (!this.invites?.use(opening.inviteId)) return null;
    } else {
      const window = this.windows.get(opening.householdId);
      if (!window || window.id !== opening.id || window.used) return null;
      // The window is used up; the road the device came by stays open for it meanwhile.
      window.used = true;
      for (const [id, one] of this.requests) {
        if (one.householdId === opening.householdId && one.inviteId === null) {
          this.requests.delete(id);
        }
      }
    }
    const pollSecret = randomBytes(32).toString("base64url");
    const request: Request = {
      id: randomUUID(),
      outside: true,
      deviceName: plainName(deviceName),
      platform,
      address,
      comparison,
      createdAt: this.now(),
      expiresAt: this.now() + REQUEST_MS,
      householdId: opening.householdId,
      invited: opening.inviteId !== null,
      pollHash: hashSecret(pollSecret),
      stage: "waiting",
      access: opening.access,
      inviteId: opening.inviteId,
      opening: opening.id,
    };
    this.requests.set(request.id, request);
    return { id: request.id, pollSecret, comparison, expiresAt: request.expiresAt };
  }

  /**
   * An approver says yes. While it waits for its household admin, with the digits on the new
   * device's screen; when it waits for a server admin, a server admin without them (they are
   * not where the device is: its household admin compared them).
   *
   * @returns the request as it is now: `awaitingAdmin` when a server admin is still to say yes
   */
  approve(
    id: string,
    comparison: string | null,
    approver: Approver = SERVER_ADMIN,
  ): OutsidePairingRequest {
    const request = this.live().get(id);
    if (!request || !this.mayDecide(request, approver)) {
      throw new AuthError(
        "not_found",
        "That device is no longer waiting. Open a new window and start again.",
      );
    }
    if (request.stage === "waiting") {
      if (comparison === null || !matches(comparison, hashSecret(request.comparison))) {
        // One chance: whoever guesses here is not looking at the device.
        this.requests.delete(id);
        throw new AuthError(
          "conflict",
          "Those are not the digits on the new device. It was turned away; start again.",
        );
      }
      const needsAdmin = approver.access !== "admin" && this.requiresAdmin(request.householdId);
      request.stage = needsAdmin ? "admin" : "approved";
    } else {
      request.stage = "approved";
    }
    request.expiresAt = this.now() + REQUEST_MS;
    return this.shown(request);
  }

  /** Whether it waits for a server admin's yes, which needs no digits. */
  awaitsAdmin(id: string): boolean {
    return this.live().get(id)?.stage === "admin";
  }

  /** An approver says no. A server admin's no to one that waited for them is told its household. */
  deny(id: string, approver: Approver = SERVER_ADMIN): void {
    const request = this.live().get(id);
    const own =
      request !== undefined &&
      request.stage === "admin" &&
      managesHousehold(approver.access) &&
      approver.householdId === request.householdId;
    if (!request || !(this.mayDecide(request, approver) || own)) {
      throw new AuthError("not_found", "That device is not waiting.");
    }
    if (request.stage === "admin" && approver.access === "admin") request.stage = "refused";
    else this.requests.delete(id);
  }

  /** Forgets one that was turned away, once its household admin has seen it. */
  dismiss(id: string, approver: Approver): void {
    const request = this.live().get(id);
    if (request?.stage === "refused" && request.householdId === approver.householdId) {
      this.requests.delete(id);
    }
  }

  /** The new device asks whether it was approved. Null for anything but the right secret. */
  collect(
    id: string,
    pollSecret: string,
  ):
    | { status: "pending"; expiresAt: number; waitingFor?: "admin" }
    | { status: "approved"; device: Device; token: string }
    | null {
    const request = this.live().get(id) ?? null;
    const same = matches(pollSecret, request ? request.pollHash : null);
    if (!request || !same || request.stage === "refused") return null;
    if (request.stage === "waiting") return { status: "pending", expiresAt: request.expiresAt };
    if (request.stage === "admin") {
      return { status: "pending", expiresAt: request.expiresAt, waitingFor: "admin" };
    }
    this.requests.delete(id);
    // The household may have been paused, removed or filled up meanwhile.
    if (!this.fits(request.householdId)) return null;
    return {
      status: "approved",
      ...this.devices.createOutsideDevice(
        request.deviceName,
        request.platform,
        request.access,
        request.householdId,
      ),
    };
  }
}
