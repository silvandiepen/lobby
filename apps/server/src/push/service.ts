// SPDX-License-Identifier: MPL-2.0
import { createPrivateKey, sign, type KeyObject } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
import { connect, type ClientHttp2Session } from "node:http2";
import type { Database } from "../db/database.ts";
import { log } from "../log.ts";
import { b64, unb64 } from "../outside/direct/envelope.ts";
import { PUSH_PROTOCOL, sealPush, type PushContent } from "./sealed.ts";

/**
 * Push notifications through Apple's service (APNs), in one of three ways (`push.mode`,
 * docs/decisions.md, "Push through a relay"):
 *
 * - `relay`: through the push relay, which holds the team's key for the App Store apps. The app
 *   registers its token there itself and gives this server a handle; what is said is sealed with
 *   a key the app made for this server, so the relay passes on what it cannot read.
 * - `direct`: with a token-based key (.p8) of one's own, for apps built under one's own bundle id.
 *   The config file names where the key is (docs/operations.md, "Push notifications"); it is read
 *   from there, owner-only, and never copied, logged or sent back.
 * - `off`: nothing is pushed.
 */

export const MODES = ["relay", "direct", "off"] as const;
export type PushMode = (typeof MODES)[number];

/**
 * The public relay a server uses when its config names none. Null until it is deployed: then a
 * server needs `push.relay` in its config to use the relay (docs/operations.md).
 */
export const DEFAULT_RELAY: string | null = null;

/** How long a ticket for registering with the relay holds. */
const TICKET_MS = 10 * 60_000;
/** Devices in one send to the relay, as it takes them. */
const PER_SEND = 32;
const HANDLE = /^[A-Za-z0-9_-]{22}$/;

/** How this server pushes, from `push.mode` and `push.relay`. */
export interface PushRoute {
  mode: PushMode;
  /** The relay's address, in relay mode. */
  relay: string | null;
}

/** What signs for the box with the relay: the same key it uses with the introducer. */
export interface BoxSigner {
  readonly boxPublic: Buffer;
  readonly boxId: string;
  sign: (message: string) => Buffer;
}

export const ENVIRONMENTS = ["development", "production"] as const;
export type PushEnvironment = (typeof ENVIRONMENTS)[number];

const HOSTS: Record<PushEnvironment, string> = {
  production: "https://api.push.apple.com",
  development: "https://api.sandbox.push.apple.com",
};

/** Apple wants a new provider token at most once every 20 minutes, and one under an hour old. */
const TOKEN_MS = 45 * 60_000;
const SEND_TIMEOUT_MS = 10_000;
const ID = /^[A-Z0-9]{10}$/;
const TOPIC = /^[A-Za-z0-9.-]{1,155}$/;
const DEVICE_TOKEN = /^[0-9a-f]{64,200}$/;

/** From the config file (`push.apns`): the key stays where the owner put it. */
export interface PushConfig {
  /** The .p8 file: owner-only (mode 600), outside the code. */
  keyFile: string;
  keyId: string;
  teamId: string;
  /** The apps' bundle id. */
  topic: string;
}

export interface PushStatus {
  configured: boolean;
  mode: PushMode;
}

/** What a device is told about registering (`GET /v1/me/push`). */
export type PushRegistration =
  { mode: "relay"; relay: { url: string; ticket: string } } | { mode: "direct" | "off" };

export class PushError extends Error {}

export interface PushMessage {
  title: string;
  body: string;
  /** A notification category of the apps, for its actions. */
  category?: string;
  threadId?: string;
  /** What the app reads: `lobby` in the payload. */
  data: Record<string, unknown>;
  /** Not worth showing after this, in milliseconds. */
  expiresAt?: number;
}

/** Reads `push.apns` from the config file; null when it is not there. */
export function readPushConfig(
  raw: unknown,
  resolvePath: (path: string) => string,
): PushConfig | null {
  if (raw === undefined || raw === null) return null;
  if (typeof raw !== "object" || Array.isArray(raw))
    throw new PushError(`"push" must be an object.`);
  const apns = (raw as Record<string, unknown>)["apns"];
  if (apns === undefined || apns === null) return null;
  if (typeof apns !== "object" || Array.isArray(apns)) {
    throw new PushError(`push.apns must be an object with keyFile, keyId, teamId and topic.`);
  }
  const {
    keyFile,
    keyId,
    teamId,
    topic = "mt.sil.lobby",
    ...rest
  } = apns as Record<string, unknown>;
  if (Object.keys(rest).length > 0) {
    throw new PushError(`push.apns has something unknown: ${Object.keys(rest).join(", ")}.`);
  }
  if (typeof keyFile !== "string" || keyFile === "") {
    throw new PushError(`push.apns.keyFile must be the path of the APNs key (.p8).`);
  }
  if (typeof keyId !== "string" || !ID.test(keyId)) {
    throw new PushError(`push.apns.keyId must be the key's ten-character id.`);
  }
  if (typeof teamId !== "string" || !ID.test(teamId)) {
    throw new PushError(`push.apns.teamId must be the team's ten-character id.`);
  }
  if (typeof topic !== "string" || !TOPIC.test(topic)) {
    throw new PushError(`push.apns.topic must be the apps' bundle id.`);
  }
  return { keyFile: resolvePath(keyFile), keyId, teamId, topic };
}

/** The address of a relay: https, or http on this machine for a relay of one's own to try. */
function relayAddress(value: unknown): string {
  if (typeof value !== "string") throw new PushError(`push.relay must be the relay's address.`);
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new PushError(`push.relay must be the relay's address, as https://….`);
  }
  const local =
    url.protocol === "http:" && ["127.0.0.1", "localhost", "[::1]"].includes(url.hostname);
  if ((url.protocol !== "https:" && !local) || url.search !== "" || url.hash !== "") {
    throw new PushError(`push.relay must be the relay's address, as https://….`);
  }
  return url.href.replace(/\/$/, "");
}

/**
 * Reads `push.mode` and `push.relay`. Without a mode: `direct` when there is a key of one's own
 * (as before there were modes), else the relay when one is known, else off.
 */
export function readPushRoute(raw: unknown, apns: PushConfig | null): PushRoute {
  const push =
    typeof raw === "object" && raw !== null && !Array.isArray(raw)
      ? (raw as Record<string, unknown>)
      : {};
  const unknown = Object.keys(push).filter((key) => !["mode", "relay", "apns"].includes(key));
  if (unknown.length > 0) throw new PushError(`push has something unknown: ${unknown.join(", ")}.`);
  const said = push["mode"];
  if (said !== undefined && !MODES.includes(said as PushMode)) {
    throw new PushError(`push.mode must be "relay", "direct" or "off".`);
  }
  const relay = push["relay"] === undefined ? DEFAULT_RELAY : relayAddress(push["relay"]);
  const mode = (said as PushMode | undefined) ?? (apns ? "direct" : relay ? "relay" : "off");
  if (mode === "direct" && !apns) {
    throw new PushError(`push.mode "direct" needs push.apns: the key of one's own.`);
  }
  if (mode === "relay" && !relay) {
    throw new PushError(`push.mode "relay" needs push.relay: the relay's address.`);
  }
  return { mode, relay: mode === "relay" ? relay : null };
}

export class PushService {
  private readonly db: Database;
  private readonly now: () => number;
  /** Where to send, instead of Apple: for the tests. */
  private readonly hosts: Record<PushEnvironment, string>;
  private readonly config: PushConfig | null;
  private readonly key: KeyObject | null = null;
  private provider: { token: string; at: number } | null = null;
  readonly mode: PushMode;
  private readonly relay: string | null;
  private readonly box: BoxSigner | null;
  /** The last `t` said to the relay: it takes each only once, and only growing. */
  private said = 0;
  private relayQueue: Promise<unknown> = Promise.resolve();

  constructor(options: {
    db: Database;
    /** The key of one's own, for `direct`. */
    config: PushConfig | null;
    /** Without one: `direct` when there is a key, else off. */
    route?: PushRoute;
    /** The box's key, for `relay`. */
    box?: BoxSigner | null;
    now?: () => number;
    hosts?: Partial<Record<PushEnvironment, string>>;
  }) {
    this.db = options.db;
    this.now = options.now ?? Date.now;
    this.hosts = { ...HOSTS, ...options.hosts };
    const route = options.route ?? { mode: options.config ? "direct" : "off", relay: null };
    this.mode = route.mode;
    this.relay = route.mode === "relay" ? route.relay : null;
    this.box = route.mode === "relay" ? (options.box ?? null) : null;
    const config = route.mode === "direct" ? options.config : null;
    this.config = null;
    if (!config) return;
    try {
      // Owner-only, as any key: one others can read is refused rather than used.
      if ((statSync(config.keyFile).mode & 0o077) !== 0) {
        throw new PushError("The APNs key file must be readable by its owner only (chmod 600).");
      }
      const key = createPrivateKey(readFileSync(config.keyFile, "utf8"));
      if (key.asymmetricKeyType !== "ec")
        throw new PushError("The APNs key file is not an APNs key (.p8).");
      this.key = key;
      this.config = config;
    } catch (error) {
      // The message names the problem, never the key.
      log.error("Push notifications are off: the APNs key cannot be used", {
        problem: error instanceof PushError ? error.message : "unreadable",
      });
    }
  }

  /** Whether pushes go out. Nothing more of the key is told. */
  status(): PushStatus {
    const configured =
      this.mode === "relay" ? this.relay !== null && this.box !== null : this.config !== null;
    return { configured, mode: configured ? this.mode : "off" };
  }

  /**
   * What a device needs to register: in relay mode the relay's address and a ticket the box
   * signed, `<box key>.<until>.<signature>`, which the relay takes for ten minutes.
   */
  registration(): PushRegistration {
    const { relay, box } = this;
    const mode = this.status().mode;
    if (mode !== "relay" || !relay || !box) return { mode: mode === "direct" ? "direct" : "off" };
    const until = this.now() + TICKET_MS;
    const signature = box.sign(`${PUSH_PROTOCOL}|ticket|${box.boxId}|${until}`);
    return {
      mode,
      relay: { url: relay, ticket: `${b64(box.boxPublic)}.${until}.${b64(signature)}` },
    };
  }

  // ---- Devices ----

  setToken(deviceId: string, token: string, environment: PushEnvironment): void {
    if (!DEVICE_TOKEN.test(token)) throw new PushError(`"token" must be the device token in hex.`);
    log.info("A device registered for push", { device: deviceId, environment });
    this.db.run(
      `insert into push_token (device_id, token, environment, updated_at) values (?, ?, ?, ?)
       on conflict (device_id) do update set token = excluded.token,
         environment = excluded.environment, updated_at = excluded.updated_at`,
      [deviceId, token, environment, this.now()],
    );
  }

  /**
   * Relay mode: the handle the relay gave the app, and the key the app made for what this server
   * seals for it. 32 random bytes, base64url.
   */
  setRelayHandle(deviceId: string, handle: string, key: string, environment: PushEnvironment) {
    if (!HANDLE.test(handle)) throw new PushError(`"handle" must be the relay's handle.`);
    log.info("A device registered for push through the relay", { device: deviceId, environment });
    if (!unb64(key, 32)) throw new PushError(`"key" must be 32 bytes, base64url.`);
    this.db.run(
      `insert into push_relay (device_id, handle, key, environment, updated_at)
       values (?, ?, ?, ?, ?)
       on conflict (device_id) do update set handle = excluded.handle, key = excluded.key,
         environment = excluded.environment, updated_at = excluded.updated_at`,
      [deviceId, handle, key, environment, this.now()],
    );
  }

  removeToken(deviceId: string): void {
    this.db.run("delete from push_token where device_id = ?", [deviceId]);
    this.db.run("delete from push_relay where device_id = ?", [deviceId]);
  }

  // ---- Sending ----

  /** The provider token, ES256 as Apple wants it; made again before it gets old. */
  private providerToken(): string | null {
    const { config, key } = this;
    if (!config || !key) return null;
    const now = this.now();
    if (this.provider && now - this.provider.at < TOKEN_MS) return this.provider.token;
    const part = (value: unknown): string =>
      Buffer.from(JSON.stringify(value)).toString("base64url");
    const unsigned = `${part({ alg: "ES256", kid: config.keyId })}.${part({ iss: config.teamId, iat: Math.floor(now / 1000) })}`;
    const signature = sign("sha256", Buffer.from(unsigned), { key, dsaEncoding: "ieee-p1363" });
    this.provider = { token: `${unsigned}.${signature.toString("base64url")}`, at: now };
    return this.provider.token;
  }

  /**
   * Sends to these devices, as far as they gave a token and are not removed. Never throws: a
   * notification that does not arrive is a pity, not an error of what caused it.
   *
   * @returns how many Apple took
   */
  async toDevices(deviceIds: readonly string[], message: PushMessage): Promise<number> {
    if (this.mode === "relay") return this.throughRelay(deviceIds, message);
    const provider = this.providerToken();
    const { config } = this;
    if (!provider || !config || deviceIds.length === 0) return 0;
    const rows = this.db.all<{ device_id: string; token: string; environment: PushEnvironment }>(
      `select push_token.device_id, push_token.token, push_token.environment from push_token
       join device on device.id = push_token.device_id and device.revoked_at is null
       where push_token.device_id in (select value from json_each(?))`,
      [JSON.stringify(deviceIds)],
    );
    if (rows.length === 0) {
      log.info("No device with a push token to notify", { devices: deviceIds.length });
    }
    const payload = JSON.stringify({
      aps: {
        alert: { title: message.title, body: message.body },
        sound: "default",
        ...(message.category ? { category: message.category } : {}),
        ...(message.threadId ? { "thread-id": message.threadId } : {}),
      },
      lobby: message.data,
    });
    const sessions = new Map<PushEnvironment, ClientHttp2Session>();
    const sessionFor = (environment: PushEnvironment): ClientHttp2Session => {
      let session = sessions.get(environment);
      if (!session) {
        session = connect(this.hosts[environment]);
        session.on("error", () => undefined);
        sessions.set(environment, session);
      }
      return session;
    };
    const other = (environment: PushEnvironment): PushEnvironment =>
      environment === "production" ? "development" : "production";
    let sent = 0;
    try {
      await Promise.all(
        rows.map(async (row) => {
          let reply = await this.post(
            sessionFor(row.environment),
            row.token,
            payload,
            provider,
            config,
            message,
          );
          // A token is Apple's sandbox's or Apple's production's, never both. When the app said
          // the wrong one (a development-signed build that thought it was a store build), the
          // other host takes it: the stored environment is corrected.
          if (reply.status === 400 && reply.reason === "BadDeviceToken") {
            const environment = other(row.environment);
            const again = await this.post(
              sessionFor(environment),
              row.token,
              payload,
              provider,
              config,
              message,
            );
            if (again.status === 200) {
              this.db.run("update push_token set environment = ? where device_id = ?", [
                environment,
                row.device_id,
              ]);
              log.info("A device's push token belongs to the other Apple environment: corrected", {
                device: row.device_id,
                was: row.environment,
                now: environment,
              });
            }
            reply = again.status === 200 ? again : reply;
          }
          if (reply.status === 200) {
            sent += 1;
            return;
          }
          log.warn("Apple did not take a notification", {
            device: row.device_id,
            environment: row.environment,
            status: reply.status,
            reason: reply.reason,
          });
          // The app was removed, or the token is no longer valid in either environment.
          if (reply.status === 410 || reply.status === 400) this.removeToken(row.device_id);
          if (reply.status === 403) this.provider = null;
        }),
      );
    } finally {
      for (const session of sessions.values()) session.close();
    }
    return sent;
  }

  /** Relay mode: each device's text sealed with its own key, signed by the box, in turns. */
  private throughRelay(deviceIds: readonly string[], message: PushMessage): Promise<number> {
    const result = this.relayQueue.then(async () => {
      const { relay, box } = this;
      if (!relay || !box || deviceIds.length === 0) return 0;
      const stored = this.db.all<{ device_id: string; handle: string; key: string }>(
        `select push_relay.device_id, push_relay.handle, push_relay.key from push_relay
         join device on device.id = push_relay.device_id and device.revoked_at is null
         where push_relay.device_id in (select value from json_each(?))`,
        [JSON.stringify(deviceIds)],
      );
      // Keys are checked when they are set; one that is not a key is never sealed with.
      const rows = stored.flatMap((row) => {
        const secret = unb64(row.key, 32);
        return secret ? [{ ...row, secret }] : [];
      });
      const content: PushContent = {
        title: message.title,
        body: message.body,
        ...(message.category ? { category: message.category } : {}),
        ...(message.threadId ? { thread: message.threadId } : {}),
        data: message.data,
      };
      let sent = 0;
      for (let start = 0; start < rows.length; start += PER_SEND) {
        const some = rows.slice(start, start + PER_SEND);
        // Each device's own key: one removed device's key opens nothing of another's.
        const to = some.map((row) => ({ h: row.handle, s: sealPush(row.secret, content) }));
        this.said = Math.max(this.now(), this.said + 1);
        const text = JSON.stringify({
          t: this.said,
          ...(message.expiresAt ? { expires: message.expiresAt } : {}),
          to,
        });
        const results = await this.postToRelay(relay, box, text);
        for (const [index, outcome] of results.entries()) {
          const row = some[index];
          if (outcome === "sent") sent += 1;
          // The relay does not know it, or Apple said the app is gone: the app registers again.
          if (row && (outcome === "gone" || outcome === "unknown")) {
            this.db.run("delete from push_relay where device_id = ? and handle = ?", [
              row.device_id,
              row.handle,
            ]);
          }
        }
      }
      return sent;
    });
    this.relayQueue = result.catch(() => undefined);
    return result.catch(() => 0);
  }

  private async postToRelay(relay: string, box: BoxSigner, text: string): Promise<string[]> {
    try {
      const answer = await fetch(`${relay}/v1/send`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-lobby-box": b64(box.boxPublic),
          "x-lobby-signature": b64(box.sign(`${PUSH_PROTOCOL}|send|${box.boxId}|${text}`)),
        },
        body: text,
        signal: AbortSignal.timeout(SEND_TIMEOUT_MS),
      });
      if (answer.status !== 200) {
        await answer.body?.cancel();
        log.warn("The push relay did not take a notification", { status: answer.status });
        return [];
      }
      const said = (await answer.json()) as { results?: unknown };
      return Array.isArray(said.results) ? said.results.map(String) : [];
    } catch {
      log.warn("The push relay cannot be reached");
      return [];
    }
  }

  private post(
    session: ClientHttp2Session,
    token: string,
    payload: string,
    provider: string,
    config: PushConfig,
    message: PushMessage,
  ): Promise<{ status: number; reason?: string }> {
    return new Promise((done) => {
      const timer = setTimeout(() => {
        request.close();
        done({ status: 0 });
      }, SEND_TIMEOUT_MS);
      const request = session.request({
        ":method": "POST",
        ":path": `/3/device/${token}`,
        authorization: `bearer ${provider}`,
        "apns-topic": config.topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": String(Math.floor((message.expiresAt ?? this.now() + 3_600_000) / 1000)),
        "content-type": "application/json",
      });
      let status = 0;
      let text = "";
      request.on("response", (headers) => {
        status = headers[":status"] ?? 0;
      });
      request.on("data", (part: Buffer) => {
        if (text.length < 1000) text += part.toString();
      });
      request.on("error", () => {
        clearTimeout(timer);
        done({ status: 0 });
      });
      request.on("close", () => {
        clearTimeout(timer);
        let reason: string | undefined;
        try {
          const said = (JSON.parse(text) as { reason?: unknown }).reason;
          if (typeof said === "string") reason = said;
        } catch {
          // No body, or not JSON: the status says enough.
        }
        done(reason ? { status, reason } : { status });
      });
      request.end(payload);
    });
  }
}
