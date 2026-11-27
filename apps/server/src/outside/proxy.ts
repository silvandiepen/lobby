// SPDX-License-Identifier: MPL-2.0
import { plainAddress } from "./limits.ts";

// The start of every PROXY protocol v2 header.
const SIGNATURE = Buffer.from("0d0a0d0a000d0a515549540a", "hex");
const FIXED = 16;
/** Addresses take 36 bytes at most; the rest is for extras a relay may add. */
const MAX_REST = 512;

export type ProxyHeader =
  /** Not all of it is there yet. */
  | { state: "more"; bytes: number }
  | { state: "ok"; address: string; length: number }
  | { state: "wrong" };

const WRONG: ProxyHeader = { state: "wrong" };

/**
 * Reads the PROXY protocol v2 header at the start of `data`. Only a forwarded TCP connection
 * counts: version 1, LOCAL, UDP and Unix sockets are wrong, and so is anything malformed.
 */
export function readProxyHeader(data: Buffer): ProxyHeader {
  const start = Math.min(data.length, SIGNATURE.length);
  if (!data.subarray(0, start).equals(SIGNATURE.subarray(0, start))) return WRONG;
  if (data.length < FIXED) return { state: "more", bytes: FIXED };
  if (data[12] !== 0x21) return WRONG;
  const family = data[13];
  if (family !== 0x11 && family !== 0x21) return WRONG;
  const addresses = family === 0x11 ? 12 : 36;
  const rest = data.readUInt16BE(14);
  if (rest < addresses || rest > MAX_REST) return WRONG;
  const length = FIXED + rest;
  if (data.length < length) return { state: "more", bytes: length };
  for (let at = FIXED + addresses; at < length;) {
    if (at + 3 > length) return WRONG;
    at += 3 + data.readUInt16BE(at + 1);
    if (at > length) return WRONG;
  }
  const source = data.subarray(FIXED, FIXED + (family === 0x11 ? 4 : 16));
  const groups: string[] = [];
  for (let at = 0; at < source.length; at += 2) groups.push(source.readUInt16BE(at).toString(16));
  const address = plainAddress(family === 0x11 ? source.join(".") : groups.join(":"));
  // "Any" and multicast are never where a connection comes from.
  if (address === null || /^0\.|^(22[4-9]|2[3-5]\d)\.|^(0:){7}0$|^ff/.test(address)) return WRONG;
  return { state: "ok", address, length };
}
