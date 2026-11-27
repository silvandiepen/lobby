// SPDX-License-Identifier: MPL-2.0
import { isIP } from "node:net";
import { plainAddress } from "../limits.ts";

const MAX_CANDIDATES = 12;

/**
 * Whether an address is one of the internet at large. A device outside has no business with the
 * home's own network, and the Pi must not be sent knocking there.
 */
export function isPublicAddress(address: string): boolean {
  const plain = plainAddress(address);
  if (plain === null) return false;
  if (isIP(plain) === 4) {
    const [a = 0, b = 0, c = 0] = plain.split(".").map(Number);
    return !(
      a === 0 ||
      a === 10 ||
      a === 127 ||
      a >= 224 ||
      (a === 100 && b >= 64 && b < 128) ||
      (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b < 32) ||
      (a === 192 && b === 168) ||
      (a === 192 && b === 0 && (c === 0 || c === 2)) ||
      (a === 192 && b === 88 && c === 99) ||
      (a === 198 && (b === 18 || b === 19)) ||
      (a === 198 && b === 51 && c === 100) ||
      (a === 203 && b === 0 && c === 113)
    );
  }
  const [first = 0, second = 0] = plain.split(":").map((group) => parseInt(group, 16));
  if (first < 0x2000 || first > 0x3fff) return false;
  // Teredo, documentation, 6to4: none of them is an address of its own.
  return !(
    (first === 0x2001 && (second === 0 || second === 0xdb8)) ||
    first === 0x2002 ||
    first === 0x3fff
  );
}

const CANDIDATE =
  /^a=candidate:([A-Za-z0-9+/]{1,32}) 1 UDP (\d{1,10}) ([0-9a-fA-F:.]{2,45}) (\d{1,5}) typ (host|srflx|prflx|relay)( |$)/i;

/**
 * An ICE description made again from its parts, with only the addresses `keep` wants. Nothing
 * else that was in it comes through: no names to look up, no lines nobody knows. Null when it is
 * not one.
 */
export function cleanSdp(sdp: unknown, keep: (address: string) => boolean): string | null {
  if (typeof sdp !== "string" || sdp.length > 8_192) return null;
  const lines = sdp.split(/\r?\n/);
  const one = (pattern: RegExp): string | null => {
    const found = lines.map((line) => pattern.exec(line)?.[1]).filter((text) => text !== undefined);
    return found.length === 1 ? (found[0] ?? null) : null;
  };
  const ufrag = one(/^a=ice-ufrag:([A-Za-z0-9+/]{4,32})$/);
  const pwd = one(/^a=ice-pwd:([A-Za-z0-9+/]{22,64})$/);
  if (ufrag === null || pwd === null) return null;
  const kept: string[] = [];
  for (const line of lines) {
    const found = CANDIDATE.exec(line);
    if (!found) continue;
    const [, foundation = "", priority = "", address = "", port = "", type = ""] = found;
    const isPort = Number(port) >= 1 && Number(port) <= 65_535;
    if (!isPort || Number(priority) > 0x7fffffff || isIP(address) === 0 || !keep(address)) continue;
    const related = type === "host" ? "" : " raddr 0.0.0.0 rport 0";
    kept.push(
      `a=candidate:${foundation} 1 UDP ${priority} ${address} ${port} typ ${type}${related}`,
    );
    if (kept.length === MAX_CANDIDATES) break;
  }
  return (
    [`a=ice-ufrag:${ufrag}`, `a=ice-pwd:${pwd}`, ...kept, "a=end-of-candidates"].join("\r\n") +
    "\r\n"
  );
}
