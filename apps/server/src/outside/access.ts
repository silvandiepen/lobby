// SPDX-License-Identifier: MPL-2.0
import type { Devices } from "../auth/devices.ts";
import type { Database } from "../db/database.ts";

export type AccessOutcome =
  /** Answered. */
  | "ok"
  /** No credential, or one that is not let in from outside. */
  | "refused"
  /** A known device at a route that is closed from outside, or is not there. */
  | "closed"
  /** Too much at once or too often. */
  | "limited"
  /** It failed on the server. */
  | "error";

export interface AccessEntry {
  id: number;
  at: number;
  until: number;
  count: number;
  deviceId: string | null;
  transport: string;
  address: string | null;
  routeClass: string;
  outcome: AccessOutcome;
}

export const ACCESS_DAYS = 30;
/** Strangers have their own share, so a flood of them does not push out who really came in. */
const MAX_ROWS = { known: 15_000, strangers: 5_000 };
const MAX_BUFFERED = 500;
const TOGETHER_MS = 60_000;
/** In the place of an address, when there are too many to write each down. */
export const MANY = "many";

type Buffered = Omit<AccessEntry, "id">;

/**
 * Who came in from outside. Requests that are alike within a minute are one row, because a film
 * is hundreds of requests and the Pi's disk is slow.
 */
export class AccessLog {
  private readonly db: Database;
  private readonly devices: Devices;
  private readonly now: () => number;
  private readonly buffer = new Map<string, Buffered>();
  private flushedAt = 0;

  constructor(db: Database, devices: Devices, now: () => number) {
    this.db = db;
    this.devices = devices;
    this.now = now;
  }

  note(entry: Omit<Buffered, "at" | "until" | "count">): void {
    const at = this.now();
    let wanted = entry;
    let key = this.key(wanted);
    if (!this.buffer.has(key) && this.buffer.size >= MAX_BUFFERED) {
      wanted = { ...entry, address: MANY };
      key = this.key(wanted);
      // Even so there is a fixed number of kinds, per device that is let in.
      if (!this.buffer.has(key) && this.buffer.size >= MAX_BUFFERED * 2) this.flush();
    }
    const known = this.buffer.get(key);
    if (known) {
      known.count += 1;
      known.until = at;
    } else {
      this.buffer.set(key, { ...wanted, at, until: at, count: 1 });
    }
    if (entry.deviceId !== null && entry.outcome === "ok") {
      this.devices.noteOutside(entry.deviceId, at);
    }
  }

  private key(entry: Omit<Buffered, "at" | "until" | "count">): string {
    return JSON.stringify([
      entry.deviceId,
      entry.transport,
      entry.address,
      entry.routeClass,
      entry.outcome,
    ]);
  }

  /** Writes down what is a minute old. */
  tick(): void {
    if (this.buffer.size > 0 && this.now() - this.flushedAt >= TOGETHER_MS) this.flush();
  }

  flush(): void {
    this.flushedAt = this.now();
    if (this.buffer.size === 0) return;
    const entries = [...this.buffer.values()];
    this.buffer.clear();
    this.db.transaction(() => {
      for (const one of entries) {
        this.db.run(
          `insert into outside_access (at, until, count, device_id, transport, address, route_class, outcome)
           values (?, ?, ?, ?, ?, ?, ?, ?)`,
          [
            one.at,
            one.until,
            one.count,
            one.deviceId,
            one.transport,
            one.address,
            one.routeClass,
            one.outcome,
          ],
        );
      }
      this.db.run("delete from outside_access where until < ?", [
        this.now() - ACCESS_DAYS * 86_400_000,
      ]);
      this.db.run(
        `delete from outside_access where device_id is null and id <= (
           select id from outside_access where device_id is null order by id desc limit 1 offset ?)`,
        [MAX_ROWS.strangers],
      );
      this.db.run(
        `delete from outside_access where device_id is not null and id <= (
           select id from outside_access where device_id is not null order by id desc limit 1 offset ?)`,
        [MAX_ROWS.known],
      );
    });
  }

  /**
   * The newest entries first. `before` is the id of the last one of the page before.
   *
   * @param householdId only those of this household's devices; all of them when left out, also
   *   those of nobody's, which only the owner sees
   */
  read(limit: number, before: number | null, householdId?: string): AccessEntry[] {
    this.flush();
    const mine = householdId ?? null;
    return this.db.all<AccessEntry>(
      `select id, at, until, count, device_id as deviceId, transport, address,
         route_class as routeClass, outcome
       from outside_access where id < ?
         and (? is null or device_id in (select id from device where household_id = ?))
       order by id desc limit ?`,
      [before ?? Number.MAX_SAFE_INTEGER, mine, mine, limit],
    );
  }
}
