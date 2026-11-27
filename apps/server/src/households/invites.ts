// SPDX-License-Identifier: MPL-2.0
import { randomUUID } from "node:crypto";
import type { Access } from "../auth/devices.ts";
import type { Database } from "../db/database.ts";
import { hashSecret, newCode, readCode } from "../outside/code.ts";
import { pairingCode } from "../outside/direct/envelope.ts";

/** How long an invitation lasts when nothing is said, and at most. */
export const DEFAULT_INVITE_HOURS = 72;
export const MAX_INVITE_HOURS = 14 * 24;

/** An invitation as a manager sees it. The code is not in it: it is shown once. */
export interface Invite {
  id: string;
  householdId: string;
  /** What its device becomes in the household: a household admin or a viewer. */
  access: "householdAdmin" | "viewer";
  createdBy: string;
  createdAt: number;
  expiresAt: number;
  /** When a device came with it. Then it works no more. */
  usedAt: number | null;
  revokedAt: number | null;
}

/** What the pairing needs of an invitation that can still be used. */
export interface InviteOpening {
  id: string;
  householdId: string;
  access: Access;
  hash: Buffer;
  /** For the direct road: where the device meets the server, and the key stretched from the code. */
  room: string | null;
  roomKey: Buffer | null;
  createdAt: number;
  expiresAt: number;
}

interface InviteRow {
  id: string;
  household_id: string;
  access: "household_admin" | "viewer";
  code_hash: Uint8Array;
  room: string | null;
  room_key: Uint8Array | null;
  created_by: string;
  created_at: number;
  expires_at: number;
  used_at: number | null;
  revoked_at: number | null;
}

const toInvite = (row: InviteRow): Invite => ({
  id: row.id,
  householdId: row.household_id,
  access: row.access === "viewer" ? "viewer" : "householdAdmin",
  createdBy: row.created_by,
  createdAt: row.created_at,
  expiresAt: row.expires_at,
  usedAt: row.used_at,
  revokedAt: row.revoked_at,
});

/**
 * Invitations to a household: one device each, for a while. Of the code only its hash is kept,
 * and what the direct road needs, which tells nothing of the code either.
 */
export class Invites {
  private readonly db: Database;
  private readonly now: () => number;
  /** Told of every new invitation, with its code, so the direct road can open a room for it. */
  onCreated: ((opening: InviteOpening) => void) | null = null;
  /** Told when one can no longer be used. */
  onEnded: ((id: string) => void) | null = null;

  constructor(db: Database, now: () => number = Date.now) {
    this.db = db;
    this.now = now;
  }

  async create(
    householdId: string,
    by: string,
    hours: number,
    access: "householdAdmin" | "viewer" = "householdAdmin",
  ): Promise<{ invite: Invite; code: string }> {
    const code = newCode();
    const plain = readCode(code) ?? code;
    const { room, key } = await pairingCode(plain);
    const row: InviteRow = {
      id: randomUUID(),
      household_id: householdId,
      access: access === "viewer" ? "viewer" : "household_admin",
      code_hash: hashSecret(plain),
      room,
      room_key: key,
      created_by: by,
      created_at: this.now(),
      expires_at: this.now() + hours * 3_600_000,
      used_at: null,
      revoked_at: null,
    };
    this.db.run(
      `insert into household_invite (id, household_id, code_hash, room, room_key, created_by,
         created_at, expires_at, access) values (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        row.id,
        row.household_id,
        row.code_hash,
        row.room,
        row.room_key,
        row.created_by,
        row.created_at,
        row.expires_at,
        row.access,
      ],
    );
    const opening = this.opening(row);
    if (opening) this.onCreated?.(opening);
    return { invite: toInvite(row), code };
  }

  private opening(row: InviteRow): InviteOpening | null {
    if (row.used_at !== null || row.revoked_at !== null || row.expires_at <= this.now()) {
      return null;
    }
    return {
      id: row.id,
      householdId: row.household_id,
      access: row.access === "viewer" ? "viewer" : "householdAdmin",
      hash: Buffer.from(row.code_hash),
      room: row.room,
      roomKey: row.room_key === null ? null : Buffer.from(row.room_key),
      createdAt: row.created_at,
      expiresAt: row.expires_at,
    };
  }

  /** Those that can still be used, of households that are there and not paused. */
  open(): InviteOpening[] {
    return this.db
      .all<InviteRow>(
        `select household_invite.* from household_invite
         join household on household.id = household_invite.household_id
         where used_at is null and revoked_at is null and expires_at > ?
           and household.removed_at is null and household.paused_at is null
         order by household_invite.created_at`,
        [this.now()],
      )
      .flatMap((row) => this.opening(row) ?? []);
  }

  /** @param householdId only of this household */
  list(householdId?: string): Invite[] {
    return this.db
      .all<InviteRow>(
        householdId === undefined
          ? "select * from household_invite order by created_at desc"
          : "select * from household_invite where household_id = ? order by created_at desc",
        householdId === undefined ? [] : [householdId],
      )
      .map(toInvite);
  }

  find(id: string): Invite | null {
    const row = this.db.get<InviteRow>("select * from household_invite where id = ?", [id]);
    return row ? toInvite(row) : null;
  }

  /** A device came with it: nobody else can. False when it could not be used any more. */
  use(id: string): boolean {
    const used = this.db.run(
      `update household_invite set used_at = ?
       where id = ? and used_at is null and revoked_at is null and expires_at > ?`,
      [this.now(), id, this.now()],
    );
    // Not ended for the road the device came by: it is pairing there now.
    return used > 0;
  }

  revoke(id: string): void {
    this.db.run("update household_invite set revoked_at = ? where id = ? and revoked_at is null", [
      this.now(),
      id,
    ]);
    this.onEnded?.(id);
  }

  /** Every invitation of a household, for when it is paused or removed. */
  revokeAll(householdId: string): void {
    for (const one of this.open().filter((invite) => invite.householdId === householdId)) {
      this.revoke(one.id);
    }
  }
}

const shared = new WeakMap<Database, Invites>();

/**
 * The invitations of this catalogue, shared by the households and the pairing.
 *
 * @param now the clock, taken from whoever asks first
 */
export function invitesOf(db: Database, now: () => number = Date.now): Invites {
  let found = shared.get(db);
  if (!found) {
    found = new Invites(db, now);
    shared.set(db, found);
  }
  return found;
}
