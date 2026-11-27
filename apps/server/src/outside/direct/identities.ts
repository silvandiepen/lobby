// SPDX-License-Identifier: MPL-2.0
import type { Database } from "../../db/database.ts";
import {
  agree,
  b64,
  enrolledSecret,
  newAgreementKey,
  openBytes,
  rawPublic,
  sealBytes,
  unb64,
} from "./envelope.ts";
import type { BoxKeys } from "./keys.ts";

/** What a device keeps, apart from its own keys and the secret it works out itself. */
export interface DirectIdentity {
  introducer: string;
  boxId: string;
  boxKey: string;
  /** SHA-256 of the certificates it may meet. */
  fingerprints: string[];
  /** The `Host` of its requests. */
  name: string;
}

export interface KnownDevice {
  deviceId: string;
  ringKey: string;
  secret: Buffer;
}

interface Row {
  device_id: string;
  ring_key: string;
  wrapped: string;
}

const ALLOWED = "device.revoked_at is null and device.allow_outside = 1";

/** Which devices can ring. Removing a device removes its identity (a trigger in the database). */
export class DirectIdentities {
  private readonly db: Database;
  private readonly keys: BoxKeys;
  private readonly introducer: string;
  private readonly name: string;
  private readonly now: () => number;

  constructor(
    db: Database,
    keys: BoxKeys,
    introducer: string,
    name: string,
    now: () => number = Date.now,
  ) {
    this.db = db;
    this.keys = keys;
    this.introducer = introducer;
    this.name = name;
    this.now = now;
  }

  identity(): DirectIdentity {
    return {
      introducer: this.introducer,
      boxId: this.keys.boxId,
      boxKey: b64(this.keys.boxPublic),
      fingerprints: this.keys.fingerprints,
      name: this.name,
    };
  }

  /** The ring key a device enrolled with. Null when it did not. */
  ringKeyOf(deviceId: string): string | null {
    return (
      this.db.get<Row>("select * from direct_device where device_id = ?", [deviceId])?.ring_key ??
      null
    );
  }

  /**
   * A device enrols at home. The secret itself is never sent: both work it out.
   *
   * @returns the box's half of it; null for keys that are none, or that another device has
   */
  enrol(deviceId: string, ringKey: unknown, agreementKey: unknown): string | null {
    const ring = unb64(ringKey, 32);
    const theirs = unb64(agreementKey, 32);
    if (!ring || !theirs) return null;
    const own = newAgreementKey();
    const ours = rawPublic(own);
    let shared: Buffer;
    try {
      shared = agree(own, theirs);
    } catch {
      return null;
    }
    const secret = enrolledSecret(shared, theirs, ours, this.keys.boxId, b64(ring));
    return this.keep(deviceId, b64(ring), secret) ? b64(ours) : null;
  }

  /** Keeps what a device and the box agreed on. False when another device has that ring key. */
  keep(deviceId: string, ringKey: string, secret: Buffer): boolean {
    return this.db.transaction(() => {
      const other = this.db.get<Row>("select * from direct_device where ring_key = ?", [ringKey]);
      if (other && other.device_id !== deviceId) return false;
      this.db.run(
        `insert or replace into direct_device (device_id, ring_key, wrapped, created_at)
         select id, ?, ?, ? from device where id = ? and revoked_at is null`,
        [
          ringKey,
          sealBytes(this.keys.wrapKey, this.wrapAad(deviceId, ringKey), secret),
          this.now(),
          deviceId,
        ],
      );
      return this.ringKeyOf(deviceId) === ringKey;
    });
  }

  /** The device that rings with this key, if it may. */
  find(ringKey: string): KnownDevice | null {
    const row = this.db.get<Row>(
      `select direct_device.* from direct_device join device on device.id = device_id
       where ring_key = ? and ${ALLOWED}`,
      [ringKey],
    );
    if (!row) return null;
    try {
      const secret = openBytes(
        this.keys.wrapKey,
        this.wrapAad(row.device_id, row.ring_key),
        row.wrapped,
      );
      return { deviceId: row.device_id, ringKey: row.ring_key, secret };
    } catch {
      // From another box's keys: it has to enrol again.
      return null;
    }
  }

  /** The keys of everyone who may ring now. */
  ringKeys(): string[] {
    return this.db
      .all<{ ring_key: string }>(
        `select ring_key from direct_device join device on device.id = device_id
         where ${ALLOWED} order by ring_key limit 128`,
      )
      .map((row) => row.ring_key);
  }

  private wrapAad(deviceId: string, ringKey: string): string {
    return `lobby-direct/1|wrap|${deviceId}|${ringKey}`;
  }
}
