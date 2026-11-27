// SPDX-License-Identifier: MPL-2.0
import { localHost } from "./discovery.ts";

/** Where a paired device can reach this server. Given to paired devices only (`GET /v1/me`). */
export interface ServerAddresses {
  /** On the home network. Empty when the server does not announce itself there. */
  home: string[];
  /** From anywhere the household set up a road in (a tailnet name, a tunnel). From the config. */
  remote: string[];
}

const MAX_REMOTE_ADDRESSES = 8;

/**
 * Checks the `addresses.remote` list of the config: http or https URLs of this server,
 * without a path, a query or a login in them. Returns each as its origin.
 * The server only hands these out. Listing an address here opens nothing.
 *
 * @throws Error with a sentence that names the entry that is wrong
 */
export function parseRemoteAddresses(raw: unknown): string[] {
  if (raw === undefined || raw === null) return [];
  if (!Array.isArray(raw)) throw new Error(`"addresses.remote" must be a list of URLs.`);
  if (raw.length > MAX_REMOTE_ADDRESSES) {
    throw new Error(
      `"addresses.remote" can hold ${String(MAX_REMOTE_ADDRESSES)} addresses at most.`,
    );
  }
  const result: string[] = [];
  raw.forEach((entry: unknown, index) => {
    const name = `addresses.remote[${String(index)}]`;
    if (typeof entry !== "string" || entry.length > 300) {
      throw new Error(`${name} must be a URL such as https://lobby.example.ts.net.`);
    }
    let url: URL;
    try {
      url = new URL(entry);
    } catch {
      throw new Error(`${name} is not a URL. Write it like https://lobby.example.ts.net.`);
    }
    if (url.protocol !== "http:" && url.protocol !== "https:") {
      throw new Error(`${name} must start with http:// or https://.`);
    }
    if (url.username !== "" || url.password !== "") {
      throw new Error(`${name} must not contain a user name or password.`);
    }
    if (url.pathname !== "/" || url.search !== "" || url.hash !== "") {
      throw new Error(`${name} must be the address only, without a path or query.`);
    }
    if (url.hostname === "") throw new Error(`${name} has no host name.`);
    if (!result.includes(url.origin)) result.push(url.origin);
  });
  return result;
}

/** The addresses a paired device is given. */
export function serverAddresses(options: {
  serverId: string;
  port: number;
  /** Whether the server answers to its `.local` name (it announces itself). */
  advertised: boolean;
  remote: string[];
}): ServerAddresses {
  return {
    home: options.advertised
      ? [`http://${localHost(options.serverId)}:${String(options.port)}`]
      : [],
    remote: options.remote,
  };
}
