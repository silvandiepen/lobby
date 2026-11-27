// SPDX-License-Identifier: MPL-2.0
import { randomUUID } from "node:crypto";
import { AuthError, type Devices } from "../auth/devices.ts";
import type { Database } from "../db/database.ts";
import { readKids, householdScopeKey, type KidsSettings } from "../kids/limits.ts";
import { OWNER_HOUSEHOLD } from "./owner.ts";
import type { Invites } from "./invites.ts";

/** A household as the owner's managers see it (docs/api.md, Households). */
export interface Household {
  id: string;
  name: string;
  /** The server owner's own household. There is one, and it has no limits. */
  owner: boolean;
  /** The part of the library it sees, as kids limits say it; null: all of it. */
  scope: KidsSettings | null;
  /** What all its devices may be sent together, in bytes a second; null: no cap. */
  bandwidth: number | null;
  allowOutside: boolean;
  maxDevices: number | null;
  /** A new device needs a server admin's yes too, after its household admin's. */
  requiresAdminApproval: boolean;
  pausedAt: number | null;
  createdAt: number;
  /** Devices that are not removed, and how many of those are household admins (or server admins). */
  devices: number;
  managers: number;
  viewers: number;
}

interface HouseholdRow {
  id: string;
  name: string;
  owner: number;
  scope_json: string | null;
  bandwidth: number | null;
  allow_outside: number;
  max_devices: number | null;
  requires_admin_approval: number;
  paused_at: number | null;
  removed_at: number | null;
  created_at: number;
  devices: number;
  managers: number;
  viewers: number;
}

/** What the owner can change of a guest household. What is left out stays. */
export interface HouseholdChange {
  name?: string;
  scope?: KidsSettings | null;
  bandwidth?: number | null;
  allowOutside?: boolean;
  maxDevices?: number | null;
  paused?: boolean;
  requiresAdminApproval?: boolean;
}

const SELECT = `select household.*,
    (select count(*) from device where device.household_id = household.id
       and device.revoked_at is null) as devices,
    (select count(*) from device where device.household_id = household.id
       and device.revoked_at is null and device.access != 'viewer') as managers,
    (select count(*) from profile where profile.household_id = household.id
       and profile.deleted_at is null) as viewers
  from household`;

const toHousehold = (row: HouseholdRow): Household => ({
  id: row.id,
  name: row.name,
  owner: row.owner === 1,
  scope: readKids(row.scope_json),
  bandwidth: row.bandwidth,
  allowOutside: row.allow_outside === 1,
  maxDevices: row.max_devices,
  requiresAdminApproval: row.requires_admin_approval === 1,
  pausedAt: row.paused_at,
  createdAt: row.created_at,
  devices: row.devices,
  managers: row.managers,
  viewers: row.viewers,
});

/** The meta key of a household's code for grown-ups. The owner's is the one from before. */
export const kidsCodeKey = (householdId: string): string =>
  householdId === OWNER_HOUSEHOLD ? "kids_code" : `kids_code:${householdId}`;

/**
 * The households that share this server. The owner's is always there; guests are added by an
 * invitation and removed with everything of theirs, never with anything of the library.
 */
export class Households {
  private readonly db: Database;
  private readonly devices: Devices;
  private readonly now: () => number;
  readonly invites: Invites;

  constructor(db: Database, devices: Devices, invites: Invites, now: () => number = Date.now) {
    this.db = db;
    this.devices = devices;
    this.invites = invites;
    this.now = now;
  }

  list(): Household[] {
    return this.db
      .all<HouseholdRow>(`${SELECT} where removed_at is null order by owner desc, created_at, id`)
      .map(toHousehold);
  }

  /** Also a paused one; never one that was removed. */
  find(id: string): Household | null {
    const row = this.db.get<HouseholdRow>(`${SELECT} where id = ? and removed_at is null`, [id]);
    return row ? toHousehold(row) : null;
  }

  private guest(id: string): Household {
    const found = this.find(id);
    if (!found) throw new AuthError("not_found", "There is no such household.");
    if (found.owner) {
      throw new AuthError("conflict", "The server's own household has no limits to change.");
    }
    return found;
  }

  create(name: string, change: Omit<HouseholdChange, "name" | "paused"> = {}): Household {
    const id = randomUUID();
    this.db.run(
      `insert into household (id, name, owner, scope_json, bandwidth, allow_outside, max_devices,
         requires_admin_approval, created_at) values (?, ?, 0, ?, ?, ?, ?, ?, ?)`,
      [
        id,
        name,
        change.scope ? JSON.stringify(change.scope) : null,
        change.bandwidth ?? null,
        change.allowOutside === false ? 0 : 1,
        change.maxDevices ?? null,
        // Fail closed: a new household's devices need a server admin too, unless said otherwise.
        change.requiresAdminApproval === false ? 0 : 1,
        this.now(),
      ],
    );
    return this.guest(id);
  }

  /** Only a guest household's: the owner's has no limits. */
  change(id: string, change: HouseholdChange): Household {
    const before = this.guest(id);
    this.db.transaction(() => {
      const set = (column: string, value: string | number | null): void => {
        this.db.run(`update household set ${column} = ? where id = ?`, [value, id]);
      };
      if (change.name !== undefined) set("name", change.name);
      if (change.scope !== undefined) {
        set("scope_json", change.scope === null ? null : JSON.stringify(change.scope));
      }
      if (change.bandwidth !== undefined) set("bandwidth", change.bandwidth);
      if (change.allowOutside !== undefined) set("allow_outside", change.allowOutside ? 1 : 0);
      if (change.maxDevices !== undefined) set("max_devices", change.maxDevices);
      if (change.requiresAdminApproval !== undefined) {
        set("requires_admin_approval", change.requiresAdminApproval ? 1 : 0);
      }
      if (change.paused !== undefined && change.paused !== (before.pausedAt !== null)) {
        set("paused_at", change.paused ? this.now() : null);
      }
    });
    if (change.paused === true) this.invites.revokeAll(id);
    return this.guest(id);
  }

  /** Whether a household's new devices also need a server admin's yes. */
  requiresAdmin(id: string): boolean {
    return (
      this.db.get<{ x: number }>(
        "select requires_admin_approval as x from household where id = ? and removed_at is null",
        [id],
      )?.x !== 0
    );
  }

  /** The owner's own household: its name, and whether its household admins' devices need a server admin. */
  changeOwn(
    id: string,
    change: Pick<HouseholdChange, "name" | "requiresAdminApproval">,
  ): Household {
    if (change.requiresAdminApproval !== undefined) {
      this.db.run("update household set requires_admin_approval = ? where id = ?", [
        change.requiresAdminApproval ? 1 : 0,
        id,
      ]);
    }
    return change.name === undefined
      ? (this.find(id) ?? this.guest(id))
      : this.rename(id, change.name);
  }

  /** Renames the owner's own household, which has nothing else to change. */
  rename(id: string, name: string): Household {
    if (
      this.db.run("update household set name = ? where id = ? and removed_at is null", [
        name,
        id,
      ]) === 0
    ) {
      throw new AuthError("not_found", "There is no such household.");
    }
    return this.find(id) ?? this.guest(id);
  }

  /**
   * Removes a guest household: its devices are removed at once, its viewers with what they
   * watched, its invitations and its code. Nothing of the library is touched.
   */
  remove(id: string): void {
    this.guest(id);
    this.db.transaction(() => {
      const devices = this.devices.list(id).filter((one) => one.revokedAt === null);
      for (const device of devices) this.devices.revoke(device.id, true);
      const ids = this.db
        .all<{ id: string }>("select id from device where household_id = ?", [id])
        .map((row) => row.id);
      const list = JSON.stringify(ids);
      this.db.run("update device set kids_profile_id = null where household_id = ?", [id]);
      this.db.run("delete from device_wanted where device_id in (select value from json_each(?))", [
        list,
      ]);
      this.db.run(
        "update wake_tv set device_id = null where device_id in (select value from json_each(?))",
        [list],
      );
      const people = this.db
        .all<{ id: string }>("select id from profile where household_id = ?", [id])
        .map((row) => row.id);
      const viewers = JSON.stringify(people);
      for (const table of [
        "progress",
        "progress_op",
        "play",
        "kids_item",
        "kids_plan",
        "kids_override",
        "kids_grant",
        "kids_request",
        "kids_screen_time",
      ]) {
        this.db.run(`delete from ${table} where profile_id in (select value from json_each(?))`, [
          viewers,
        ]);
      }
      this.db.run("delete from kids_item where profile_id = ?", [householdScopeKey(id)]);
      // Their music is forgotten by the trigger that goes with a removed viewer.
      this.db.run(
        "update profile set deleted_at = ?, kids_json = null where household_id = ? and deleted_at is null",
        [this.now(), id],
      );
      this.db.run("delete from meta where key = ?", [kidsCodeKey(id)]);
      this.db.run(
        "update household set removed_at = ?, scope_json = null, paused_at = null where id = ?",
        [this.now(), id],
      );
    });
    this.invites.revokeAll(id);
    // Those of a removed household cannot be found any more; they are not left usable either.
    for (const invite of this.invites.list(id)) {
      if (invite.revokedAt === null && invite.usedAt === null) this.invites.revoke(invite.id);
    }
  }

  /** Whether one more device fits. */
  hasRoom(id: string): boolean {
    const found = this.find(id);
    if (!found || found.pausedAt !== null) return false;
    return found.maxDevices === null || this.devices.countIn(id) < found.maxDevices;
  }
}
