// SPDX-License-Identifier: MPL-2.0

import { PerMinute, Relay, type AppleKey, type Answer, type Limits } from "./core.ts";

/* The push relay on Cloudflare: a Worker that looks at the request, and one Durable Object. */

// What is used of the platform. Written out, so that a type package does not come with it.
interface Context {
  storage: {
    get: (key: string) => Promise<unknown>;
    put: (key: string, value: unknown) => Promise<void>;
    delete: (key: string) => Promise<boolean>;
  };
}
interface Stub {
  fetch: (request: Request) => Promise<Response>;
}
export interface Env {
  /** The team's APNs key (.p8), as a secret: `wrangler secret put APNS_KEY`. */
  APNS_KEY?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  /** The apps' bundle id. */
  APNS_TOPIC?: string;
  DAILY_CAP?: string;
  RELAY: { idFromName: (name: string) => unknown; get: (id: unknown) => Stub };
}

const ADDRESS = "x-lobby-address";
/** Nothing that is sent here is longer. */
const MOST = 512 * 1024;
const ROUTES = new Set(["/v1/tokens", "/v1/tokens/forget", "/v1/send"]);

const opening = new PerMinute();

const answer = ({ status, body }: Answer): Response =>
  body === undefined
    ? new Response(null, { status })
    : new Response(JSON.stringify(body), {
        status,
        headers: { "content-type": "application/json" },
      });

/** Addresses count by the network they are in: an IPv6 customer has a whole /64. */
export function addressOf(request: Request): string {
  const address = request.headers.get("cf-connecting-ip") ?? "unknown";
  return address.includes(":") ? address.split(":").slice(0, 4).join(":") : address;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (
      !ROUTES.has(pathname) ||
      request.method !== "POST" ||
      // Only a web page sends this, and no web page has business here.
      request.headers.has("origin") ||
      Number(request.headers.get("content-length") ?? "0") > MOST
    ) {
      return new Response(null, { status: 404 });
    }
    // Before the object is woken, which costs.
    if (!opening.take(addressOf(request), 120, Date.now())) {
      return new Response(null, { status: 429 });
    }
    const headers = new Headers(request.headers);
    headers.set(ADDRESS, addressOf(request));
    const stub = env.RELAY.get(env.RELAY.idFromName("relay"));
    return stub.fetch(new Request(request, { headers }));
  },
};

function appleKey(env: Env): AppleKey | null {
  const { APNS_KEY: pem, APNS_KEY_ID: keyId, APNS_TEAM_ID: teamId, APNS_TOPIC: topic } = env;
  if (!pem || !keyId || !teamId || !topic) return null;
  return { pem, keyId, teamId, topic };
}

function settings(env: Env): Partial<Limits> {
  const perDay = Number(env.DAILY_CAP);
  return Number.isInteger(perDay) && perDay > 0 ? { perDay } : {};
}

export class PushRelay {
  private readonly relay: Relay;

  constructor(context: Context, env: Env) {
    const { storage } = context;
    this.relay = new Relay({
      store: {
        get: (key) => storage.get(key),
        put: (key, value) => storage.put(key, value),
        delete: async (key) => {
          await storage.delete(key);
        },
      },
      key: appleKey(env),
      // Apple's service speaks HTTP/2 only; the platform's fetch speaks it to Apple.
      post: (url, init) => fetch(url, init),
      limits: settings(env),
    });
  }

  async fetch(request: Request): Promise<Response> {
    const text = await request.text();
    if (text.length > MOST) return new Response(null, { status: 413 });
    const { pathname } = new URL(request.url);
    const { headers } = request;
    if (pathname === "/v1/tokens") {
      return answer(await this.relay.register(text, headers.get(ADDRESS) ?? "unknown"));
    }
    if (pathname === "/v1/tokens/forget") return answer(await this.relay.forget(text));
    if (pathname === "/v1/send") {
      return answer(
        await this.relay.send(text, headers.get("x-lobby-box"), headers.get("x-lobby-signature")),
      );
    }
    return new Response(null, { status: 404 });
  }
}
