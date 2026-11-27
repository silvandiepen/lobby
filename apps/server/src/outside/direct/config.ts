// SPDX-License-Identifier: MPL-2.0
import { isIP } from "node:net";
import { readFileSync, statSync } from "node:fs";

export interface IceServer {
  host: string;
  port: number;
}

export interface TurnServer extends IceServer {
  /** The secret coturn shares with this server (`static-auth-secret`). */
  secret: string;
}

export interface DirectConfig {
  /** Where device and box find each other: `wss://introducer.example.com`. */
  introducer: string;
  /** Servers that tell an end its own public address. Without one, only public addresses work. */
  stun: IceServer[];
  /** The owner's own relay, for networks that let nothing through directly. */
  turn: TurnServer | null;
  /** The one address of this machine to use, such as that of its home network. */
  bind: string | null;
  /** Everything sent together stays under this, so that the home's upload is usable. */
  maxUploadMbit: number | null;
  /** The lobby-direct program. */
  binary: string;
}

const HOST =
  /^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])$/;

function isLoopback(host: string): boolean {
  return host === "localhost" || host === "[::1]" || /^127\.\d+\.\d+\.\d+$/.test(host);
}

/**
 * Reads `outside.direct`. Null when it is not there.
 *
 * @throws Error with a sentence that names what is wrong
 */
export function readDirectConfig(
  raw: unknown,
  absolute: (path: string) => string,
): DirectConfig | null {
  if (raw === undefined || raw === null) return null;
  if (typeof raw !== "object" || Array.isArray(raw)) {
    throw new Error(`outside.direct must be an object.`);
  }
  const { introducer, stun, turn, bind, maxUploadMbit, binary } = raw as Record<string, unknown>;
  let upload: number | null = null;
  if (maxUploadMbit !== undefined && maxUploadMbit !== null) {
    if (typeof maxUploadMbit !== "number" || !(maxUploadMbit >= 1 && maxUploadMbit <= 10_000)) {
      throw new Error(`outside.direct.maxUploadMbit must be a number from 1 to 10000.`);
    }
    upload = maxUploadMbit;
  }
  if (bind !== undefined && bind !== null && (typeof bind !== "string" || isIP(bind) === 0)) {
    throw new Error(`outside.direct.bind must be an address of this machine.`);
  }
  if (binary !== undefined && (typeof binary !== "string" || binary === "")) {
    throw new Error(`outside.direct.binary must be the path of the lobby-direct program.`);
  }
  return {
    introducer: readUrl(introducer),
    stun: readStun(stun),
    turn: readTurn(turn, absolute),
    bind: bind ?? null,
    maxUploadMbit: upload,
    binary: absolute(binary ?? "bin/lobby-direct"),
  };
}

function readUrl(raw: unknown): string {
  const wrong = `outside.direct.introducer must be the address of the introducer, such as wss://introducer.example.com.`;
  if (typeof raw !== "string" || raw.length > 300) throw new Error(wrong);
  const url = URL.parse(raw);
  if (
    !url ||
    !(url.protocol === "wss:" || (url.protocol === "ws:" && isLoopback(url.hostname))) ||
    url.username !== "" ||
    url.password !== "" ||
    url.search !== "" ||
    url.hash !== ""
  ) {
    throw new Error(wrong);
  }
  return url.href.replace(/\/+$/, "");
}

function readServer(raw: unknown, key: string, port: number): IceServer {
  const { host, port: given } = (typeof raw === "object" && raw !== null ? raw : {}) as Record<
    string,
    unknown
  >;
  if (typeof host !== "string" || (isIP(host) === 0 && !HOST.test(host))) {
    throw new Error(`${key}.host must be a host name or an address.`);
  }
  const at = given ?? port;
  if (typeof at !== "number" || !Number.isInteger(at) || at < 1 || at > 65_535) {
    throw new Error(`${key}.port must be a port number.`);
  }
  return { host, port: at };
}

function readStun(raw: unknown): IceServer[] {
  if (raw === undefined || raw === null) return [];
  if (!Array.isArray(raw) || raw.length > 4) {
    throw new Error(`outside.direct.stun must be a list of at most four servers.`);
  }
  return raw.map((one: unknown, index) => readServer(one, `outside.direct.stun[${index}]`, 3478));
}

function readTurn(raw: unknown, absolute: (path: string) => string): TurnServer | null {
  if (raw === undefined || raw === null) return null;
  const server = readServer(raw, "outside.direct.turn", 3478);
  if (/(^|\.)cloudflare\.(com|net)$/i.test(server.host)) {
    // The owner's rule: nothing of a film passes through there.
    throw new Error(`outside.direct.turn must be a relay of your own, never Cloudflare's.`);
  }
  const { secret, secretFile } = raw as Record<string, unknown>;
  let found = secret;
  if (secret === undefined && typeof secretFile === "string" && secretFile !== "") {
    const path = absolute(secretFile);
    let mode: number;
    try {
      mode = statSync(path).mode;
      found = readFileSync(path, "utf8").trim();
    } catch (error) {
      throw new Error(`outside.direct.turn.secretFile cannot be read.`, { cause: error });
    }
    if ((mode & 0o077) !== 0) {
      throw new Error(`outside.direct.turn.secretFile can be read by others. Set its mode to 600.`);
    }
  }
  if (typeof found !== "string" || found.length < 16 || found.length > 256) {
    throw new Error(
      `outside.direct.turn needs "secretFile", or "secret" with at least 16 characters.`,
    );
  }
  return { ...server, secret: found };
}
