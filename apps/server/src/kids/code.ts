// SPDX-License-Identifier: MPL-2.0
import { randomBytes, scrypt, timingSafeEqual } from "node:crypto";
import { GuessLimiter } from "../auth/devices.ts";
import type { Database } from "../db/database.ts";

// 32 MB for a moment, about a tenth of a second on the Pi.
const COST = { N: 2 ** 15, r: 8, p: 1, maxmem: 64 * 1024 * 1024 };
const BYTES = 32;

export const KIDS_CODE = /^[0-9]{4}$/;

function slowHash(code: string, salt: Buffer): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    scrypt(code, salt, BYTES, COST, (error, key) => {
      if (error) reject(error);
      else resolve(key);
    });
  });
}

/**
 * A household's code that leads out of kids mode on a device without a lock of its own.
 * Only a salted slow hash is kept. Four digits are few, so what protects them is the count of
 * wrong guesses per device.
 */
export class KidsCode {
  private readonly db: Database;
  private readonly limiter: GuessLimiter;
  /** Where it is kept: each household has its own (households/store.ts, `kidsCodeKey`). */
  private readonly key: string;

  constructor(db: Database, now: () => number = Date.now, key = "kids_code") {
    this.db = db;
    this.limiter = new GuessLimiter(now);
    this.key = key;
  }

  get isSet(): boolean {
    return (this.db.getMeta(this.key) ?? "") !== "";
  }

  async set(code: string | null): Promise<void> {
    if (code === null) {
      this.db.setMeta(this.key, "");
      return;
    }
    const salt = randomBytes(16);
    const hash = await slowHash(code, salt);
    this.db.setMeta(this.key, `${salt.toString("base64url")}.${hash.toString("base64url")}`);
  }

  /** @throws AuthError when the device guessed wrong too often */
  async check(deviceId: string, code: string): Promise<boolean> {
    this.limiter.check(deviceId);
    const [salt = "", hash = ""] = (this.db.getMeta(this.key) ?? "").split(".");
    // Counted before the slow part: many guesses at once are many guesses.
    this.limiter.fail(deviceId);
    const expected = Buffer.from(hash, "base64url");
    const given = await slowHash(code, Buffer.from(salt, "base64url"));
    const correct = expected.length === BYTES && timingSafeEqual(expected, given);
    if (correct) this.limiter.clear(deviceId);
    return correct;
  }
}
