// SPDX-License-Identifier: MPL-2.0
import { isIP } from "node:net";
import { readDirectConfig, type DirectConfig } from "./direct/config.ts";
import { addressKey, plainAddress } from "./limits.ts";

export interface OutsideTlsConfig {
  /** One private address of this machine: that of the tunnel to the relay. */
  host: string;
  port: number;
  /** The relays' addresses in the tunnel. Nobody else is listened to. */
  relays: string[];
  certFile: string;
  keyFile: string;
}

export interface OutsideConfig {
  /** The name devices outside use. A request for any other name is refused. */
  name: string;
  /** The road over the owner's own relay (docs/outside.md). Null: not used. */
  tls: OutsideTlsConfig | null;
  /** The road straight to a device (docs/outside.md). Null: not used. */
  direct: DirectConfig | null;
}

/** Whether an address can only be reached from a private network or this machine. */
export function isPrivateAddress(address: string): boolean {
  const plain = plainAddress(address);
  if (plain === null) return false;
  if (isIP(plain) === 4) {
    const [a = 0, b = 0] = plain.split(".").map(Number);
    return a === 10 || a === 127 || (a === 172 && b >= 16 && b < 32) || (a === 192 && b === 168);
  }
  return plain === "0:0:0:0:0:0:0:1" || /^f[cd]/.test(addressKey(plain) ?? "");
}

/**
 * Reads `outside` from the config. Null when it is not there or not enabled.
 *
 * @throws Error with a sentence that names what is wrong
 */
export function readOutsideConfig(
  raw: unknown,
  home: { host: string; port: number },
  absolute: (path: string) => string,
): OutsideConfig | null {
  if (raw === undefined || raw === null) return null;
  if (typeof raw !== "object" || Array.isArray(raw))
    throw new Error(`"outside" must be an object.`);
  const { enabled, name, tls, direct } = raw as Record<string, unknown>;
  if (enabled !== undefined && typeof enabled !== "boolean") {
    throw new Error(`outside.enabled must be true or false.`);
  }
  if (enabled !== true) return null;
  if (
    typeof name !== "string" ||
    name.length > 253 ||
    !/^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])$/.test(name)
  ) {
    throw new Error(`outside.name must be a host name in lower case, such as lobby.example.com.`);
  }
  return {
    name,
    tls: tls === undefined || tls === null ? null : readTls(tls, home, absolute),
    direct: readDirectConfig(direct, absolute),
  };
}

function readTls(
  raw: unknown,
  home: { host: string; port: number },
  absolute: (path: string) => string,
): OutsideTlsConfig {
  if (typeof raw !== "object" || Array.isArray(raw)) {
    throw new Error(`outside.tls must be an object.`);
  }
  const { host, port, relays, certFile, keyFile } = raw as Record<string, unknown>;
  const wrongHost = `outside.tls.host must be one private address of this machine, not a name and not every address.`;
  if (typeof host !== "string" || !isPrivateAddress(host)) throw new Error(wrongHost);
  if (typeof port !== "number" || !Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error(`outside.tls.port must be a port number.`);
  }
  if (port === home.port) {
    throw new Error(`outside.tls.port must not be the port the server has at home.`);
  }
  if (
    !Array.isArray(relays) ||
    relays.length === 0 ||
    relays.length > 8 ||
    !relays.every((one) => typeof one === "string" && isPrivateAddress(one))
  ) {
    throw new Error(`outside.tls.relays must list the private addresses of the relays.`);
  }
  const file = (value: unknown, key: string): string => {
    if (typeof value !== "string" || value === "") {
      throw new Error(`outside.tls.${key} must be the path of a file.`);
    }
    return absolute(value);
  };
  return {
    host,
    port,
    relays: (relays as string[]).map((one) => plainAddress(one) ?? one),
    certFile: file(certFile, "certFile"),
    keyFile: file(keyFile, "keyFile"),
  };
}
