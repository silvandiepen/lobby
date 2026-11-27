// SPDX-License-Identifier: MPL-2.0

/*
 * The push relay: lets any household's Lobby Server reach the App Store apps through Apple's push
 * service, which takes pushes for the apps only when they are signed with the team's key. The key
 * stays here; servers never get it (docs/outside.md, "The push relay"; docs/decisions.md, "Push
 * through a relay").
 *
 * Who may use it, and for whom:
 * - A server proves it is a box (the Ed25519 key it also uses with the introducer) by signing what
 *   it sends. Its box id is the hash of that key, so nobody else can send as it.
 * - An app registers its device token here, itself, with a ticket its server signed. It gets a
 *   handle back and gives the server that, never the token. A server can push only to handles
 *   registered for its own box; it never learns a token, so it has none of anyone else's.
 * - What it sends is sealed with a key that only the app and its server have. The relay sees a
 *   box id, handles, tokens, sizes and times, and puts a generic alert around the sealed text.
 *
 * One implementation; worker.ts puts it on Cloudflare. Nothing here writes a log.
 */

export const PROTOCOL = "lobby-push/1";

export interface Limits {
  /** One sealed notification, in base64url characters. Apple takes 4 KB in all. */
  sealed: number;
  /** Devices in one send. */
  perSend: number;
  /** Devices a box has registered; the oldest goes for a new one. */
  handlesPerBox: number;
  /** Sends (requests) of one box. */
  sendsPerMinute: number;
  /** Notifications of one box, per day (UTC). */
  perBoxDay: number;
  /** Notifications to one device, per hour. */
  perHandleHour: number;
  /** Registrations from one address. */
  registersPerMinute: number;
  /** Registrations under one box, per day. */
  registersPerBoxDay: number;
  /** Notifications in all, per day. Then nothing until the next. */
  perDay: number;
  /** How far a server's clock may be off. */
  skewMs: number;
  /** How long a ticket may say it holds. */
  ticketMs: number;
  /** A handle the app did not register again for this long is forgotten. */
  handleMs: number;
  /** The longest a notification is worth delivering. */
  expiresMs: number;
}

export const LIMITS: Limits = {
  sealed: 2_800,
  perSend: 32,
  handlesPerBox: 64,
  sendsPerMinute: 30,
  perBoxDay: 1_000,
  perHandleHour: 30,
  registersPerMinute: 20,
  registersPerBoxDay: 200,
  perDay: 20_000,
  skewMs: 5 * 60_000,
  ticketMs: 15 * 60_000,
  handleMs: 60 * 86_400_000,
  expiresMs: 86_400_000,
};

/** What the relay keeps: a key-value store that survives a restart. */
export interface Store {
  get: (key: string) => Promise<unknown>;
  put: (key: string, value: unknown) => Promise<void>;
  delete: (key: string) => Promise<void>;
}

/** The team's key, from the platform's secrets. */
export interface AppleKey {
  /** The .p8 file's text (PKCS #8, P-256). */
  pem: string;
  keyId: string;
  teamId: string;
  /** The apps' bundle id. */
  topic: string;
}

export type Environment = "development" | "production";

export const HOSTS: Record<Environment, string> = {
  production: "https://api.push.apple.com",
  development: "https://api.sandbox.push.apple.com",
};

/** One HTTP/2 request to Apple: `fetch` on Cloudflare. */
export type Post = (
  url: string,
  init: { method: "POST"; headers: Record<string, string>; body: string },
) => Promise<{ status: number; json: () => Promise<unknown> }>;

export interface Answer {
  status: number;
  body?: Record<string, unknown>;
}

/** What one device's notification came to. */
export type Outcome = "sent" | "gone" | "unknown" | "limited" | "failed";

/** What Apple shows when the app cannot open the sealed text: nothing of it. */
export const GENERIC = { title: "Lobby", body: "A request is waiting." } as const;

/** Apple wants a new provider token at most every 20 minutes, and none older than an hour. */
const JWT_MS = 50 * 60_000;
const BOX_KEY = /^[A-Za-z0-9_-]{43}$/;
const SIGNATURE = /^[A-Za-z0-9_-]{86}$/;
const HANDLE = /^[A-Za-z0-9_-]{22}$/;
const TOKEN = /^[0-9a-f]{64,200}$/;
const SEALED = /^[A-Za-z0-9_-]+$/;

interface Registered {
  box: string;
  token: string;
  environment: Environment;
  at: number;
}

interface Planned {
  jobs: (Outcome | Registered)[];
  jwt: string | null;
  until: number;
  wanted: { h: string; s: string }[];
}

interface Count {
  at: number;
  count: number;
}

const b64 = (data: Uint8Array): string =>
  btoa(String.fromCharCode(...data))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");

function unb64(text: string): Uint8Array<ArrayBuffer> {
  const padded = text.replaceAll("-", "+").replaceAll("_", "/");
  const found = atob(padded + "=".repeat((4 - (padded.length % 4)) % 4));
  return Uint8Array.from(found, (character) => character.charCodeAt(0));
}

const fresh = (bytes: number): string => b64(crypto.getRandomValues(new Uint8Array(bytes)));

const utf8 = (text: string): Uint8Array<ArrayBuffer> => new TextEncoder().encode(text);

/** A box's name: the hash of its key, as the introducer and the server make it. */
export async function boxIdOf(key: Uint8Array<ArrayBuffer>): Promise<string> {
  return b64(new Uint8Array(await crypto.subtle.digest("SHA-256", key)));
}

/** The box id of a key that signed this, or null. */
async function signedBy(key: unknown, signature: unknown, text: (box: string) => string) {
  if (typeof key !== "string" || !BOX_KEY.test(key)) return null;
  if (typeof signature !== "string" || !SIGNATURE.test(signature)) return null;
  const raw = unb64(key);
  const box = await boxIdOf(raw);
  try {
    const known = await crypto.subtle.importKey("raw", raw, "Ed25519", false, ["verify"]);
    const good = await crypto.subtle.verify("Ed25519", known, unb64(signature), utf8(text(box)));
    return good ? box : null;
  } catch {
    return null;
  }
}

/** A JSON object, or null. */
function object(text: unknown): Record<string, unknown> | null {
  if (typeof text !== "string") return null;
  try {
    const value: unknown = JSON.parse(text);
    return typeof value === "object" && value !== null && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
}

const refused = (status: number, code: string): Answer => ({ status, body: { error: code } });

/** Counts per key and minute, and forgets the rest. */
export class PerMinute {
  private readonly counts = new Map<string, number>();
  private minute = 0;
  private readonly max: number;

  constructor(max = 2_048) {
    this.max = max;
  }

  take(key: string, most: number, now: number): boolean {
    const minute = Math.floor(now / 60_000);
    if (minute !== this.minute) this.counts.clear();
    this.minute = minute;
    const had = this.counts.get(key) ?? 0;
    if (had >= most || (had === 0 && this.counts.size >= this.max)) return false;
    this.counts.set(key, had + 1);
    return true;
  }
}

export class Relay {
  private readonly store: Store;
  private readonly key: AppleKey | null;
  private readonly post: Post;
  private readonly now: () => number;
  private readonly limits: Limits;
  private readonly hosts: Record<Environment, string>;
  private readonly registering = new PerMinute();
  private readonly sending = new PerMinute();
  private signing: Awaited<ReturnType<typeof crypto.subtle.importKey>> | null = null;
  private queue: Promise<unknown> = Promise.resolve();

  constructor(options: {
    store: Store;
    key: AppleKey | null;
    post: Post;
    now?: () => number;
    limits?: Partial<Limits>;
    hosts?: Partial<Record<Environment, string>>;
  }) {
    this.store = options.store;
    this.key = options.key;
    this.post = options.post;
    this.now = options.now ?? Date.now;
    this.limits = { ...LIMITS, ...options.limits };
    this.hosts = { ...HOSTS, ...options.hosts };
  }

  /** One thing at a time, so that counts and lists are never written over each other. */
  private inTurn<T>(act: () => Promise<T>): Promise<T> {
    const result = this.queue.then(act);
    this.queue = result.catch(() => undefined);
    return result;
  }

  // ---- The app ----

  /**
   * `POST /v1/tokens` `{ ticket, token, environment }`: an app's device token, for the box that
   * signed the ticket. The same token for the same box keeps its handle.
   */
  register(text: unknown, address: string): Promise<Answer> {
    return this.inTurn(async () => {
      const { limits, store } = this;
      const now = this.now();
      if (!this.registering.take(address, limits.registersPerMinute, now)) {
        return refused(429, "rate");
      }
      const body = object(text);
      if (!body) return refused(400, "json");
      const { ticket, token, environment } = body;
      if (typeof token !== "string" || !TOKEN.test(token)) return refused(400, "token");
      if (environment !== "development" && environment !== "production") {
        return refused(400, "environment");
      }
      const box = await this.ticketBox(ticket, now);
      if (!box) return refused(403, "ticket");
      if (!(await this.counted(`registered:${box}`, 86_400_000, limits.registersPerBoxDay, 1))) {
        return refused(429, "day");
      }
      const index = `token:${box}:${token}`;
      let handle = (await store.get(index)) as string | undefined;
      const handles = ((await store.get(`box:${box}`)) as string[] | undefined) ?? [];
      if (handle === undefined || !handles.includes(handle)) {
        if (handle !== undefined) await this.drop(handle);
        handle = fresh(16);
        // A box that is full lets go of the device that registered longest ago.
        while (handles.length >= limits.handlesPerBox) {
          const oldest = handles.shift();
          if (oldest !== undefined) await this.drop(oldest);
        }
      } else {
        handles.splice(handles.indexOf(handle), 1);
      }
      handles.push(handle);
      await store.put(`handle:${handle}`, {
        box,
        token,
        environment,
        at: now,
      } satisfies Registered);
      await store.put(index, handle);
      await store.put(`box:${box}`, handles);
      return { status: 200, body: { handle, until: now + limits.handleMs } };
    });
  }

  /** `POST /v1/tokens/forget` `{ box, handle }`: the app signed out, or was removed. */
  forget(text: unknown): Promise<Answer> {
    return this.inTurn(async () => {
      const body = object(text);
      const { box, handle } = body ?? {};
      if (typeof box !== "string" || !BOX_KEY.test(box) || typeof handle !== "string") {
        return refused(400, "json");
      }
      const known = HANDLE.test(handle)
        ? ((await this.store.get(`handle:${handle}`)) as Registered | undefined)
        : undefined;
      if (known?.box === box) await this.drop(handle);
      // The same answer either way: whether a handle exists is told to nobody.
      return { status: 204 };
    });
  }

  /** The box that signed a ticket that still holds. Ticket: `<box key>.<until>.<signature>`. */
  private async ticketBox(ticket: unknown, now: number): Promise<string | null> {
    if (typeof ticket !== "string" || ticket.length > 200) return null;
    const [key, until, signature, ...rest] = ticket.split(".");
    const ends = Number(until);
    if (rest.length > 0 || !/^\d{1,15}$/.test(until ?? "")) return null;
    if (ends < now - this.limits.skewMs || ends > now + this.limits.ticketMs + this.limits.skewMs) {
      return null;
    }
    return signedBy(key, signature, (box) => `${PROTOCOL}|ticket|${box}|${until ?? ""}`);
  }

  // ---- The server ----

  /**
   * `POST /v1/send`, body `{ t, expires, to: [{ h, s }] }`, signed by the box over
   * `lobby-push/1|send|<box id>|<body>`: the key in `x-lobby-box`, the signature in
   * `x-lobby-signature`. `t` is the server's time and grows with each send, so nothing is sent
   * twice by saying it again.
   */
  async send(text: unknown, boxKey: unknown, signature: unknown): Promise<Answer> {
    const planned = await this.inTurn(async (): Promise<Answer | Planned> => {
      const { limits, store } = this;
      const now = this.now();
      if (typeof text !== "string" || text.length > 4 * limits.perSend * limits.sealed) {
        return refused(413, "size");
      }
      const box = await signedBy(boxKey, signature, (id) => `${PROTOCOL}|send|${id}|${text}`);
      if (!box) return refused(403, "signature");
      if (!this.sending.take(box, limits.sendsPerMinute, now)) return refused(429, "rate");
      const body = object(text);
      const { t, expires, to } = body ?? {};
      if (typeof t !== "number" || !Number.isSafeInteger(t) || Math.abs(t - now) > limits.skewMs) {
        return refused(400, "time");
      }
      const last = (await store.get(`last:${box}`)) as number | undefined;
      if (last !== undefined && t <= last) return refused(409, "again");
      if (
        !Array.isArray(to) ||
        to.length === 0 ||
        to.length > limits.perSend ||
        !to.every(
          (one: unknown) =>
            typeof one === "object" &&
            one !== null &&
            typeof (one as Record<string, unknown>)["h"] === "string" &&
            typeof (one as Record<string, unknown>)["s"] === "string",
        )
      ) {
        return refused(400, "to");
      }
      const wanted = to as { h: string; s: string }[];
      if (
        wanted.some(
          (one) => !HANDLE.test(one.h) || one.s.length > limits.sealed || !SEALED.test(one.s),
        )
      ) {
        return refused(400, "sealed");
      }
      await store.put(`last:${box}`, t);
      const until = Math.min(
        typeof expires === "number" && expires > now ? expires : now + 3_600_000,
        now + limits.expiresMs,
      );
      if (!this.key) return refused(503, "unavailable");
      if (!(await this.counted(`sent:${box}`, 86_400_000, limits.perBoxDay, wanted.length))) {
        return refused(429, "day");
      }
      if (!(await this.counted("sent", 86_400_000, limits.perDay, wanted.length))) {
        return refused(503, "day");
      }
      const jwt = await this.providerToken();
      const jobs: (Outcome | Registered)[] = [];
      for (const one of wanted) jobs.push(await this.whom(box, one.h, now, jwt !== null));
      return { jobs, jwt, until, wanted };
    });
    if ("status" in planned) return planned;
    // Apple is asked outside the turn, so that one slow answer holds up no other household.
    const { jobs, jwt, until, wanted } = planned;
    const asked = await Promise.all(
      jobs.map((job, index) =>
        typeof job === "string" || jwt === null
          ? Promise.resolve({ outcome: job as Outcome, status: 0 })
          : this.ask(job, jwt, wanted[index]?.s ?? "", until),
      ),
    );
    return this.inTurn(async () => {
      for (const [index, { outcome, status }] of asked.entries()) {
        const handle = wanted[index]?.h;
        // The app was removed, or the token is not one for these apps: forget it.
        if (outcome === "gone" && handle !== undefined) await this.drop(handle);
        if (status === 403) {
          this.signing = null;
          await this.store.delete("jwt");
        }
      }
      return { status: 200, body: { results: asked.map(({ outcome }) => outcome) } };
    });
  }

  /** Where one notification goes, or why it goes nowhere. */
  private async whom(
    box: string,
    handle: string,
    now: number,
    signed: boolean,
  ): Promise<Outcome | Registered> {
    const { store, limits } = this;
    const known = (await store.get(`handle:${handle}`)) as Registered | undefined;
    // Only a device that registered for this very box.
    if (known?.box !== box) return "unknown";
    if (now - known.at > limits.handleMs) {
      await this.drop(handle);
      return "unknown";
    }
    if (!signed) return "failed";
    if (!(await this.counted(`to:${handle}`, 3_600_000, limits.perHandleHour, 1))) {
      return "limited";
    }
    return known;
  }

  private async ask(
    known: Registered,
    jwt: string,
    sealed: string,
    until: number,
  ): Promise<{ outcome: Outcome; status: number }> {
    if (!this.key) return { outcome: "failed", status: 0 };
    let status: number;
    let reason: unknown = null;
    try {
      const answer = await this.post(`${this.hosts[known.environment]}/3/device/${known.token}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${jwt}`,
          "apns-topic": this.key.topic,
          "apns-push-type": "alert",
          "apns-priority": "10",
          "apns-expiration": String(Math.floor(until / 1000)),
          "content-type": "application/json",
        },
        body: payload(sealed),
      });
      status = answer.status;
      if (status === 400) {
        reason = ((await answer.json().catch(() => null)) as { reason?: unknown } | null)?.reason;
      }
    } catch {
      return { outcome: "failed", status: 0 };
    }
    if (status === 200) return { outcome: "sent", status };
    if (status === 410 || reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic") {
      return { outcome: "gone", status };
    }
    return { outcome: status === 429 ? "limited" : "failed", status };
  }

  /** The provider token, ES256 as Apple wants it, kept for 50 minutes (also over a restart). */
  private async providerToken(): Promise<string | null> {
    const { key, store } = this;
    if (!key) return null;
    const now = this.now();
    const kept = (await store.get("jwt")) as { token: string; at: number } | undefined;
    if (kept && now - kept.at < JWT_MS && now >= kept.at) return kept.token;
    try {
      this.signing ??= await crypto.subtle.importKey(
        "pkcs8",
        unb64(
          key.pem
            .replace(/-----[^-]+-----/g, "")
            .replace(/\s+/g, "")
            .replaceAll("+", "-")
            .replaceAll("/", "_"),
        ),
        { name: "ECDSA", namedCurve: "P-256" },
        false,
        ["sign"],
      );
    } catch {
      return null;
    }
    const part = (value: unknown): string => b64(utf8(JSON.stringify(value)));
    const unsigned = `${part({ alg: "ES256", kid: key.keyId })}.${part({ iss: key.teamId, iat: Math.floor(now / 1000) })}`;
    // WebCrypto gives r and s side by side, as a JWT wants them.
    const signature = await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      this.signing,
      utf8(unsigned),
    );
    const token = `${unsigned}.${b64(new Uint8Array(signature))}`;
    await store.put("jwt", { token, at: now });
    return token;
  }

  /** Adds `many` to a count over a window; false, and nothing added, when it would pass `most`. */
  private async counted(key: string, windowMs: number, most: number, many: number) {
    const now = this.now();
    const at = Math.floor(now / windowMs);
    const had = (await this.store.get(`count:${key}`)) as Count | undefined;
    const count = had?.at === at ? had.count : 0;
    if (count + many > most) return false;
    await this.store.put(`count:${key}`, { at, count: count + many } satisfies Count);
    return true;
  }

  private async drop(handle: string): Promise<void> {
    const { store } = this;
    const known = (await store.get(`handle:${handle}`)) as Registered | undefined;
    await store.delete(`handle:${handle}`);
    if (!known) return;
    await store.delete(`token:${known.box}:${known.token}`);
    const handles = ((await store.get(`box:${known.box}`)) as string[] | undefined) ?? [];
    const left = handles.filter((one) => one !== handle);
    if (left.length === 0) await store.delete(`box:${known.box}`);
    else await store.put(`box:${known.box}`, left);
  }
}

/**
 * What Apple gets: a generic alert, and the sealed text for the app's notification service to
 * open. Nothing else: no category, thread or id, which the app takes from the sealed text.
 */
export function payload(sealed: string): string {
  return JSON.stringify({
    aps: { alert: GENERIC, sound: "default", "mutable-content": 1 },
    lobby: { v: 1, s: sealed },
  });
}
