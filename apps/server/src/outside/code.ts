// SPDX-License-Identifier: MPL-2.0
import { createHash, randomBytes, randomInt, timingSafeEqual } from "node:crypto";

// Crockford's base32: no I, L, O or U, so nothing on a TV screen can be read two ways.
const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/** 16 characters of 5 bits: 80 bits. */
export const CODE_LENGTH = 16;
const GROUP = 4;

const digest = (value: string): Buffer => createHash("sha256").update(value).digest();

/** A new pairing code, as it is shown: `XXXX-XXXX-XXXX-XXXX`. */
export function newCode(): string {
  // 256 is a multiple of 32, so every character is equally likely.
  const characters = [...randomBytes(CODE_LENGTH)].map((byte) => ALPHABET[byte % 32]);
  const groups: string[] = [];
  for (let at = 0; at < CODE_LENGTH; at += GROUP) {
    groups.push(characters.slice(at, at + GROUP).join(""));
  }
  return groups.join("-");
}

/** What a person typed, as the code it stands for. Null when it cannot be one. */
export function readCode(typed: string): string | null {
  if (typed.length > 64) return null;
  const code = typed.toUpperCase().replace(/[\s-]/g, "").replace(/O/g, "0").replace(/[IL]/g, "1");
  return /^[0-9A-HJKMNP-TV-Z]{16}$/.test(code) ? code : null;
}

/** What is kept of a secret. */
export function hashSecret(secret: string): Buffer {
  return digest(`outside:${secret}`);
}

/** Compares in the same time whatever the answer, also when there is nothing to compare with. */
export function matches(secret: string, hash: Buffer | null): boolean {
  const same = timingSafeEqual(hashSecret(secret), hash ?? Buffer.alloc(32));
  return same && hash !== null;
}

/** Six digits that both screens show, so the manager sees which device is being approved. */
export function newComparison(): string {
  return String(randomInt(0, 1_000_000)).padStart(6, "0");
}
