// SPDX-License-Identifier: MPL-2.0
import { hostname, networkInterfaces, type NetworkInterfaceInfo } from "node:os";
import { BlockList, isIP, isIPv6 } from "node:net";
import type { MiddlewareHandler } from "hono";
import { plainAddress } from "../outside/limits.ts";
import type { AppEnv } from "./app.ts";

/** Endings that no one can have on the internet, or that lead into the household's own tailnet. */
const HOME_ENDINGS = [
  ".local",
  ".lan",
  ".home",
  ".internal",
  ".localdomain",
  ".home.arpa",
  ".ts.net",
];

/**
 * Whether a `Host` is one this server is called by at home. A web page that points its own name
 * at this machine (DNS rebinding) comes with that name, and never with an address.
 *
 * @param names further names: those of the configured addresses
 */
export function isHomeHost(host: string, names: ReadonlySet<string>): boolean {
  const bracketed = /^\[([0-9a-f:.]+(?:%[\w.-]+)?)\](?::\d{1,5})?$/i.exec(host);
  if (bracketed) return isIPv6(bracketed[1] ?? "");
  const name = host
    .replace(/:\d{1,5}$/, "")
    .replace(/\.$/, "")
    .toLowerCase();
  if (isIP(name) === 4) return true;
  if (!/^[a-z0-9]([a-z0-9._-]{0,251}[a-z0-9])?$/.test(name)) return false;
  // One word is a name from the household's own router or hosts file.
  if (!name.includes(".")) return true;
  return (
    names.has(name) ||
    name === hostname().toLowerCase() ||
    HOME_ENDINGS.some((ending) => name.endsWith(ending))
  );
}

const PRIVATE = new BlockList();
for (const [network, prefix] of [
  ["10.0.0.0", 8],
  ["127.0.0.0", 8],
  ["169.254.0.0", 16],
  ["172.16.0.0", 12],
  ["192.168.0.0", 16],
  // The tailnet's.
  ["100.64.0.0", 10],
] as const) {
  PRIVATE.addSubnet(network, prefix, "ipv4");
}
PRIVATE.addSubnet("fc00::", 7, "ipv6");
PRIVATE.addSubnet("fe80::", 10, "ipv6");
PRIVATE.addAddress("::1", "ipv6");

const TAILNET = new BlockList();
TAILNET.addSubnet("100.64.0.0", 10, "ipv4");
TAILNET.addSubnet("fd7a:115c:a1e0::", 48, "ipv6");

/** Whether an address is the tailnet's: near for the server, but anywhere in the world. */
export function isTailnet(address: string | null | undefined): boolean {
  const plain = plainAddress(address?.split("%")[0]);
  if (plain === null) return false;
  return TAILNET.check(plain, isIPv6(plain) ? "ipv6" : "ipv4");
}

/** Whether an address is at home or in the tailnet: private, or in a network this machine is in. */
export function isNearby(
  address: string | null | undefined,
  interfaces: NodeJS.Dict<NetworkInterfaceInfo[]> = networkInterfaces(),
): boolean {
  const plain = plainAddress(address?.split("%")[0]);
  if (plain === null) return false;
  const family = isIPv6(plain) ? "ipv6" : "ipv4";
  if (PRIVATE.check(plain, family)) return true;
  const near = new BlockList();
  for (const one of Object.values(interfaces).flat()) {
    const [network, prefix] = one?.cidr?.split("/") ?? [];
    // A whole range of addresses is a network; a single one, or half the internet, is none.
    if (one?.internal || !network || !prefix || Number(prefix) < 16) continue;
    near.addSubnet(network, Number(prefix), one?.family === "IPv6" ? "ipv6" : "ipv4");
  }
  return near.check(plain, family);
}

/** The address the request came from; null for one that did not come over a network. */
export function peerAddress(c: { env: AppEnv["Bindings"] | undefined }): string | null {
  return plainAddress(c.env?.incoming?.socket.remoteAddress) ?? null;
}

export interface HomeGuardDeps {
  /** Names of the configured addresses, or how to get them now. */
  names: ReadonlySet<string> | (() => ReadonlySet<string>);
  /** The relays of the outside entrance. They have no business here. */
  relays: ReadonlySet<string>;
  refusal: (message: string) => Error;
}

/** Stands before everything on the app for home: what comes from elsewhere is refused. */
export function homeGuard(deps: HomeGuardDeps): MiddlewareHandler<AppEnv> {
  return async (c, next) => {
    const peer = peerAddress(c);
    const loopback = peer !== null && (peer.startsWith("127.") || peer === "0:0:0:0:0:0:0:1");
    if (peer !== null && !loopback && deps.relays.has(peer)) {
      throw deps.refusal("This can only be done at home.");
    }
    const host = c.req.header("Host") ?? new URL(c.req.url).host;
    const names = typeof deps.names === "function" ? deps.names() : deps.names;
    if (!isHomeHost(host, names)) {
      throw deps.refusal(
        "This server does not go by that name. Add it to addresses.remote in its config.",
      );
    }
    // A page of another site can send a request here without reading the answer.
    const origin = c.req.header("Origin");
    if (origin !== undefined) {
      let from: string | null = null;
      try {
        from = new URL(origin).host;
      } catch {
        // "null", for a page that has no site.
      }
      if (from === null || from !== host.toLowerCase()) {
        throw deps.refusal("This cannot be asked from another site.");
      }
    }
    await next();
  };
}
