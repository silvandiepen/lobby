// SPDX-License-Identifier: MPL-2.0
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { Duplex } from "node:stream";
import { getRequestListener } from "@hono/node-server";
import type { Hono } from "hono";
import { PLATFORMS, type Device, type Devices, type Platform } from "../auth/devices.ts";
import type { Database } from "../db/database.ts";
import type { AppEnv } from "../http/app.ts";
import { invitesOf } from "../households/invites.ts";
import { Households } from "../households/store.ts";
import { errorMessage, log } from "../log.ts";
import { AccessLog, type AccessOutcome } from "./access.ts";
import type { OutsideRequest } from "./guard.ts";
import { addressKey, FailureLimiter, plainAddress, RateLimiter } from "./limits.ts";
import type { DirectStatus, DirectTransport } from "./direct/index.ts";
import { OutsidePairing, type OutsidePairingRequest, type OutsideWindow } from "./pairing.ts";

/** One connection from outside: it carries HTTP/1.1 requests, whatever road it came by. */
export interface OutsideConnection {
  /** Both ends of the bytes, already decrypted on this machine. */
  stream: Duplex;
  /** The other end's address, when the road knows one. */
  address: string | null;
  /**
   * Whether that address is proven to be the other end's own. Behind a relay it can be shared
   * or made up: then it is written down, and nobody is kept out because of it.
   */
  addressIsReliable: boolean;
  /** The device the road has proven to be at the other end. Nobody else's credential counts. */
  deviceId?: string;
}

/** A road in. It is open only between `open` and `close`. */
export interface OutsideTransport {
  readonly name: string;
  open: (accept: (connection: OutsideConnection) => void) => Promise<void>;
  /** Also ends every connection it handed over. */
  close: () => Promise<void>;
  /** Whether it can be reached, and in a sentence why not. */
  status: () => { open: boolean; problem: string | null };
  /** Ends what belongs to devices that may not be here any more. */
  recheck?: (mayBeOutside: (deviceId: string) => boolean) => void;
}

export interface OutsideOptions {
  db: Database;
  devices: Devices;
  /** The name requests must be for. Null: not set up, and it cannot be turned on. */
  name: string | null;
  transports?: OutsideTransport[];
  /** The direct road, when there is one. Made with the pairing, which it has a share in. */
  direct?: (pairing: OutsidePairing) => DirectTransport | null;
  now?: () => number;
  limits?: Partial<OutsideLimits>;
}

export interface OutsideLimits {
  /** Connections that have not shown a credential yet. The oldest makes room for a new one. */
  newConnections: number;
  /** Connections of one address, when the address can be trusted. */
  connectionsPerAddress: number;
  connectionsPerDevice: number;
  connections: number;
  /** For a whole request head, counted from the connection or the answer before. */
  headMs: number;
  /** The same for a connection that has shown a credential. */
  idleMs: number;
  bodyMs: number;
  /** For the other end to take in more of an answer. */
  stallMs: number;
}

export const OUTSIDE_LIMITS: OutsideLimits = {
  newConnections: 32,
  connectionsPerAddress: 48,
  connectionsPerDevice: 24,
  connections: 96,
  headMs: 10_000,
  idleMs: 75_000,
  bodyMs: 30_000,
  stallMs: 180_000,
};

export const OUTSIDE_SWITCH = "outside_enabled";
const TICK_MS = 1_000;
const MAX_URL = 4_096;
const MAX_BODY = 64 * 1024;
const MAX_REPORT = 1024 * 1024;
const MAX_PAIRING_BODY = 2_048;
/** A credential is 32 bytes. Anything else is not looked up. */
const TOKEN = /^[A-Za-z0-9_-]{43}$/;
const COOKIE = "lobby_device";
const PAIR = "/v1/outside-pairing";
const COLLECT = "/v1/outside-pairing/collect";

export interface OutsideStatus {
  configured: boolean;
  enabled: boolean;
  transports: { name: string; open: boolean; problem: string | null }[];
  connections: number;
  window: OutsideWindow | null;
  requests: OutsidePairingRequest[];
  /** Null when the direct road is not set up. */
  direct: DirectStatus | null;
}

interface Live {
  stream: Duplex;
  transport: string;
  address: string | null;
  /** What tries are counted by; null when the address says nothing. */
  key: string | null;
  /** Set once the connection showed a credential. */
  deviceId: string | null;
  /** The device the road says this is. */
  proven: string | null;
  deadline: number;
  request: IncomingMessage | null;
  response: ServerResponse | null;
  movedAt: number;
}

/**
 * The door for devices outside the home. It knows nothing about the road they come by, gives an
 * unknown visitor the same empty 404 whatever is asked, and hands the rest to an app of its own
 * (`createApp(deps, "outside")`), never to the one for home.
 */
export class OutsideEntrance {
  readonly pairing: OutsidePairing;
  readonly access: AccessLog;
  readonly isConfigured: boolean;
  readonly direct: DirectTransport | null;
  private readonly db: Database;
  private readonly devices: Devices;
  private readonly name: string | null;
  private readonly transports: OutsideTransport[];
  private readonly now: () => number;
  private readonly limits: OutsideLimits;
  private readonly server: Server;
  private readonly live = new Map<Duplex, Live>();
  private readonly badCredentials: FailureLimiter;
  private readonly badCodes: FailureLimiter;
  private readonly strangers: FailureLimiter;
  private readonly perDevice: RateLimiter;
  private app: Hono<AppEnv> | null = null;
  private opened = false;
  private stopped = true;
  private timer: NodeJS.Timeout | null = null;
  private changing: Promise<void> = Promise.resolve();
  private readonly problems = new Map<string, string>();

  constructor(options: OutsideOptions) {
    this.db = options.db;
    this.devices = options.devices;
    this.name = options.name?.toLowerCase() ?? null;
    this.isConfigured = this.name !== null;
    this.now = options.now ?? Date.now;
    this.limits = { ...OUTSIDE_LIMITS, ...options.limits };
    const households = new Households(this.db, this.devices, invitesOf(this.db, this.now));
    this.pairing = new OutsidePairing(this.devices, this.now, {
      invites: invitesOf(this.db, this.now),
      fits: (id) => households.hasRoom(id),
      requiresAdmin: (id) => households.requiresAdmin(id),
    });
    this.direct = options.direct?.(this.pairing) ?? null;
    this.transports = [...(options.transports ?? []), ...(this.direct ? [this.direct] : [])];
    this.access = new AccessLog(this.db, this.devices, this.now);
    this.badCredentials = new FailureLimiter(
      { free: 10, forgetMs: 30 * 60_000, all: { burst: 200, perMinute: 60 } },
      this.now,
    );
    // Nobody types a long code wrong thirty times; a wrong try costs an attacker's whole budget.
    this.badCodes = new FailureLimiter(
      { free: 5, forgetMs: 30 * 60_000, all: { burst: 30, perMinute: 3 } },
      this.now,
    );
    this.strangers = new FailureLimiter(
      { free: 600, forgetMs: 10 * 60_000, all: { burst: 2_000, perMinute: 600 } },
      this.now,
    );
    // A first sync is a thousand pictures: that fits in the burst.
    this.perDevice = new RateLimiter({ burst: 1_200, perMinute: 600 }, this.now);
    this.server = createServer({
      maxHeaderSize: 16 * 1024,
      insecureHTTPParser: false,
      requireHostHeader: false,
      keepAliveTimeout: 0,
    });
    this.server.headersTimeout = 0;
    this.server.requestTimeout = 0;
    this.server.maxRequestsPerSocket = 10_000;
    this.server.maxHeadersCount = 64;
    this.server.on("request", (request: IncomingMessage, response: ServerResponse) => {
      this.receive(request, response);
    });
    // Node would answer these itself, in a way that says what is behind the door.
    this.server.on("clientError", (_error, socket) => {
      socket.destroy();
    });
    for (const event of ["checkContinue", "checkExpectation"]) {
      this.server.on(event, (request: IncomingMessage, response: ServerResponse) => {
        this.receive(request, response, true);
      });
    }
    for (const event of ["connect", "upgrade"]) {
      this.server.on(event, (_request: IncomingMessage, socket: Duplex) => {
        socket.destroy();
      });
    }
  }

  /** Whether a manager turned it on. Anything but a clear yes is no. */
  get isOn(): boolean {
    if (!this.isConfigured) return false;
    try {
      return this.db.getMeta(OUTSIDE_SWITCH) === "on";
    } catch (error) {
      log.error("Could not read the outside switch; keeping it closed", {
        error: errorMessage(error),
      });
      return false;
    }
  }

  /** @param app made with `createApp(deps, "outside")` */
  async start(app: Hono<AppEnv>): Promise<void> {
    this.app = app;
    this.stopped = false;
    this.timer = setInterval(() => {
      this.tick();
    }, TICK_MS);
    this.timer.unref();
    await this.reconcile();
  }

  async stop(): Promise<void> {
    this.stopped = true;
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    await this.reconcile();
    this.access.flush();
  }

  async setEnabled(enabled: boolean): Promise<void> {
    if (!enabled) this.cutAll();
    this.db.setMeta(OUTSIDE_SWITCH, enabled && this.isConfigured ? "on" : "off");
    await this.reconcile();
  }

  status(): OutsideStatus {
    const open = this.opened;
    return {
      configured: this.isConfigured,
      enabled: this.isOn,
      transports: this.transports.map((one) => {
        const { open: isOpen, problem } = one.status();
        return {
          name: one.name,
          open: open && isOpen,
          problem: problem ?? this.problems.get(one.name) ?? null,
        };
      }),
      connections: this.live.size,
      window: this.pairing.current(),
      requests: this.pairing.waiting(),
      direct: this.direct?.directStatus() ?? null,
    };
  }

  /** Ends the connections of devices that may not be here any more. */
  recheck(): void {
    const allowed = new Map<string, boolean>();
    for (const one of this.live.values()) {
      if (one.deviceId === null) continue;
      let may = allowed.get(one.deviceId);
      if (may === undefined) {
        may = this.devices.mayBeOutside(one.deviceId);
        allowed.set(one.deviceId, may);
      }
      if (!may) one.stream.destroy();
    }
    for (const transport of this.transports) {
      transport.recheck?.((deviceId) => this.devices.mayBeOutside(deviceId));
    }
  }

  private cutAll(): void {
    this.pairing.closeAll();
    for (const one of this.live.values()) one.stream.destroy();
  }

  /** Opens or closes the roads, as the switch says. One change at a time. */
  private reconcile(): Promise<void> {
    this.changing = this.changing.then(async () => {
      const wanted = !this.stopped && this.isOn;
      if (wanted === this.opened) return;
      this.opened = wanted;
      if (!wanted) this.cutAll();
      for (const transport of this.transports) {
        try {
          if (wanted) {
            await transport.open((connection) => {
              this.accept(transport.name, connection);
            });
            log.info("An outside road is open", { transport: transport.name });
          } else {
            await transport.close();
            log.info("An outside road is closed", { transport: transport.name });
          }
          this.problems.delete(transport.name);
        } catch (error) {
          this.problems.set(transport.name, errorMessage(error));
          log.error("An outside road could not be opened or closed", {
            transport: transport.name,
            error: errorMessage(error),
          });
        }
      }
    });
    return this.changing;
  }

  private tick(): void {
    try {
      // The command line changes the same switch from another process.
      if (this.isOn !== this.opened) void this.reconcile();
      const now = this.now();
      for (const one of this.live.values()) {
        // Between requests it is the next head that is waited for, then that request's body.
        const late = one.deadline <= now && one.request?.complete !== true;
        const stalled =
          one.response?.writableNeedDrain === true && now - one.movedAt > this.limits.stallMs;
        if (late || stalled) one.stream.destroy();
      }
      this.recheck();
      this.access.tick();
    } catch (error) {
      // Not knowing who may be here is a reason to let nobody stay.
      log.error("The outside entrance could not check its connections", {
        error: errorMessage(error),
      });
      this.cutAll();
    }
  }

  private accept(transport: string, connection: OutsideConnection): void {
    const { stream } = connection;
    stream.on("error", () => undefined);
    if (!this.opened || !this.isOn) {
      stream.destroy();
      return;
    }
    const address = plainAddress(connection.address);
    const key = connection.addressIsReliable ? addressKey(address) : null;
    const unknown = [...this.live.values()].filter((one) => one.deviceId === null);
    const sameAddress =
      key === null ? 0 : [...this.live.values()].filter((one) => one.key === key).length;
    if (
      sameAddress >= this.limits.connectionsPerAddress ||
      this.live.size >= this.limits.connections + this.limits.newConnections
    ) {
      stream.destroy();
      return;
    }
    // Whoever only holds connections loses them to whoever comes in.
    const known = this.live.size - unknown.length;
    if (unknown.length >= this.limits.newConnections) unknown[0]?.stream.destroy();
    if (known >= this.limits.connections) {
      stream.destroy();
      return;
    }
    const one: Live = {
      stream,
      transport,
      address,
      key,
      deviceId: null,
      proven: connection.deviceId ?? null,
      deadline: this.now() + this.limits.headMs,
      request: null,
      response: null,
      movedAt: this.now(),
    };
    this.live.set(stream, one);
    stream.once("close", () => {
      this.live.delete(stream);
    });
    this.server.emit("connection", stream);
  }

  // ---- Requests ----

  private receive(request: IncomingMessage, response: ServerResponse, expects = false): void {
    const one = this.live.get(request.socket);
    // Two at once on one connection is something no player does.
    if (!one || one.response !== null || !this.opened || !this.isOn) {
      request.socket.destroy();
      return;
    }
    one.request = request;
    one.response = response;
    one.movedAt = this.now();
    one.deadline = this.now() + this.limits.bodyMs;
    response.on("drain", () => {
      one.movedAt = this.now();
    });
    response.once("close", () => {
      if (one.response !== response) return;
      one.request = null;
      one.response = null;
      one.deadline = this.now() + (one.deviceId === null ? this.limits.headMs : this.limits.idleMs);
    });
    response.sendDate = false;
    this.handle(one, request, response, expects).catch((error: unknown) => {
      log.error("A request from outside failed", { error: errorMessage(error) });
      request.socket.destroy();
    });
  }

  private note(one: Live, device: Device | null, routeClass: string, outcome: AccessOutcome): void {
    this.access.note({
      deviceId: device?.id ?? null,
      transport: one.transport,
      address: one.address,
      routeClass,
      outcome,
    });
  }

  /** The one answer for everybody who is not let in, whatever they asked. */
  private refuse(response: ServerResponse, wait = 0): void {
    if (response.headersSent) {
      response.destroy();
      return;
    }
    response.writeHead(wait > 0 ? 429 : 404, {
      ...SECURITY_HEADERS,
      "Cache-Control": "no-store",
      "Content-Length": "0",
      Connection: "close",
      ...(wait > 0 ? { "Retry-After": String(wait) } : {}),
    });
    response.end();
  }

  private async handle(
    one: Live,
    request: IncomingMessage,
    response: ServerResponse,
    expects: boolean,
  ): Promise<void> {
    const url = request.url ?? "";
    const method = request.method ?? "";
    const strange =
      expects ||
      // A device that is known has nothing to pair.
      (one.proven !== null && (url === PAIR || url === COLLECT)) ||
      request.httpVersion !== "1.1" ||
      !["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"].includes(method) ||
      url.length > MAX_URL ||
      // Also keeps out "//host" and "http://host", which would name another host than Host does.
      !/^\/(?!\/)[\x21-\x7e]*$/.test(url) ||
      /[\\#]/.test(url) ||
      !this.isForThisName(request) ||
      // Only a web page sends these. No app does, and Lobby has no web page.
      request.headers.origin !== undefined ||
      request.headers["sec-fetch-site"] !== undefined ||
      request.headers["transfer-encoding"] !== undefined ||
      request.headers.upgrade !== undefined;

    if (!strange && method === "POST" && (url === PAIR || url === COLLECT)) {
      await this.pair(one, request, response, url);
      return;
    }

    const presented = strange ? null : this.credential(request, method);
    const device =
      presented !== null && TOKEN.test(presented)
        ? this.devices.authenticateOutside(presented)
        : null;
    // A connection belongs to the first device that uses it.
    const another = [one.deviceId, one.proven].some((id) => id !== null && id !== device?.id);
    if (!device || another) {
      const limiter = presented === null ? this.strangers : this.badCredentials;
      // A right credential never gets here: nobody is locked out by a neighbour's old tablet.
      const wait = limiter.wait(one.key);
      if (wait === 0) limiter.fail(one.key);
      this.note(one, null, "none", wait > 0 ? "limited" : "refused");
      this.refuse(response, wait);
      return;
    }
    if (one.deviceId === null) {
      let others = 0;
      for (const other of this.live.values()) if (other.deviceId === device.id) others += 1;
      if (others >= this.limits.connectionsPerDevice) {
        this.note(one, device, "none", "limited");
        this.refuse(response, 5);
        return;
      }
      one.deviceId = device.id;
    }
    const wait = this.perDevice.take(device.id);
    if (wait > 0) {
      this.note(one, device, "none", "limited");
      this.refuse(response, wait);
      return;
    }
    const length = Number(request.headers["content-length"] ?? "0");
    const most = url === "/v1/me/downloads" ? MAX_REPORT : MAX_BODY;
    if (!Number.isSafeInteger(length) || length > most) {
      this.note(one, device, "none", "limited");
      response.writeHead(413, { ...SECURITY_HEADERS, "Content-Length": "0", Connection: "close" });
      response.end();
      return;
    }
    await this.serve(one, device, request, response);
  }

  private async serve(
    one: Live,
    device: Device,
    request: IncomingMessage,
    response: ServerResponse,
  ): Promise<void> {
    const app = this.app;
    if (!app) {
      this.refuse(response);
      return;
    }
    const outside: OutsideRequest = {
      device,
      routeClass: "none",
      transport: one.transport,
      onClosed: (done) => {
        if (response.destroyed || response.writableFinished) done();
        else response.once("close", done);
      },
    };
    const listener = getRequestListener(
      async (webRequest) => {
        const answer = await app.fetch(webRequest, { outside });
        const headers = new Headers(answer.headers);
        for (const [name, value] of Object.entries(SECURITY_HEADERS)) headers.set(name, value);
        if (!headers.has("Cache-Control")) headers.set("Cache-Control", "private, no-store");
        const closed = answer.status === 403 || answer.status === 404 || answer.status === 401;
        this.note(
          one,
          device,
          outside.routeClass,
          answer.status === 429
            ? "limited"
            : answer.status >= 500
              ? "error"
              : closed
                ? "closed"
                : "ok",
        );
        return new Response(answer.body, { status: answer.status, headers });
      },
      { overrideGlobalObjects: false },
    );
    await listener(request, response);
  }

  private isForThisName(request: IncomingMessage): boolean {
    let hosts = 0;
    for (let index = 0; index < request.rawHeaders.length; index += 2) {
      if (request.rawHeaders[index]?.toLowerCase() === "host") hosts += 1;
    }
    const host = (request.headers.host ?? "").toLowerCase().replace(/:\d{1,5}$/, "");
    return hosts === 1 && this.name !== null && host === this.name;
  }

  private credential(request: IncomingMessage, method: string): string | null {
    const header = request.headers.authorization;
    if (header !== undefined) return header.startsWith("Bearer ") ? header.slice(7).trim() : "";
    // The cookie is there for the player, which only reads.
    if (method !== "GET" && method !== "HEAD") return null;
    const found = (request.headers.cookie ?? "")
      .split(";")
      .map((part) => part.trim())
      .filter((part) => part.startsWith(`${COOKIE}=`));
    return found.length === 1 ? (found[0]?.slice(COOKIE.length + 1) ?? "") : null;
  }

  // ---- Pairing ----

  private async pair(
    one: Live,
    request: IncomingMessage,
    response: ServerResponse,
    url: string,
  ): Promise<void> {
    // There is no chunked body here, so this is all there can be.
    if (Number(request.headers["content-length"] ?? "0") > MAX_PAIRING_BODY) {
      this.note(one, null, "pairing", "refused");
      this.refuse(response);
      return;
    }
    const body = await readJson(request);
    const wait = this.badCodes.wait(one.key);
    if (wait > 0) {
      this.note(one, null, "pairing", "limited");
      this.refuse(response, wait);
      return;
    }
    const text = (key: string): string => {
      const value = body?.[key];
      return typeof value === "string" && value.length <= 200 ? value : "";
    };
    const platform = PLATFORMS.find((known) => known === text("platform") && known !== "cli");
    const answer =
      url === PAIR
        ? this.presentCode(text("code"), text("deviceName"), platform, one.address)
        : this.pairing.collect(text("id"), text("pollSecret"));
    if (answer === null) {
      this.badCodes.fail(one.key);
      this.note(one, null, "pairing", "refused");
      this.refuse(response);
      return;
    }
    this.badCodes.clear(one.key);
    const paired = "device" in answer ? answer.device : null;
    if (url === PAIR) log.info("A device asks to pair from outside");
    if (paired) log.info("A device was paired from outside", { device: paired.id });
    this.note(one, paired, "pairing", "ok");
    const json = Buffer.from(JSON.stringify(answer));
    response.writeHead(url === PAIR ? 201 : paired ? 200 : 202, {
      ...SECURITY_HEADERS,
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=UTF-8",
      "Content-Length": String(json.length),
      Connection: "close",
    });
    response.end(json);
  }

  private presentCode(
    code: string,
    deviceName: string,
    platform: Platform | undefined,
    address: string | null,
  ): ReturnType<OutsidePairing["present"]> {
    // Checked first, so that a request with mistakes does not use the code up.
    if (platform === undefined || deviceName.trim() === "") return null;
    return this.pairing.present(code, deviceName, platform, address);
  }
}

const SECURITY_HEADERS: Readonly<Record<string, string>> = {
  "Strict-Transport-Security": "max-age=31536000",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
};

/** The body as a JSON object, or null. */
async function readJson(request: IncomingMessage): Promise<Record<string, unknown> | null> {
  const parts: Buffer[] = [];
  for await (const part of request as AsyncIterable<Buffer>) parts.push(part);
  try {
    const value: unknown = JSON.parse(Buffer.concat(parts).toString("utf8"));
    if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
    return value as Record<string, unknown>;
  } catch {
    return null;
  }
}
