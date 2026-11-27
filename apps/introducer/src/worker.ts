// SPDX-License-Identifier: MPL-2.0
import {
  Introducer,
  PerMinute,
  readBoxes,
  wishOf,
  type Ground,
  type Limits,
  type Line,
  type LineState,
} from "./core.ts";

/* The introducer on Cloudflare: a Worker that looks at the request, and one Durable Object. */

// What is used of the platform. Written out, so that a type package does not come with it.
interface Socket {
  send: (text: string) => void;
  close: (code: number, reason: string) => void;
  serializeAttachment: (value: unknown) => void;
  deserializeAttachment: () => unknown;
  readyState: number;
}
interface Context {
  getWebSockets: () => Socket[];
  acceptWebSocket: (socket: Socket) => void;
  setWebSocketAutoResponse: (pair: unknown) => void;
  storage: {
    get: (key: string) => Promise<unknown>;
    put: (key: string, value: unknown) => Promise<void>;
    delete: (key: string) => Promise<boolean>;
    getAlarm: () => Promise<number | null>;
    setAlarm: (at: number) => Promise<void>;
  };
}
interface Stub {
  fetch: (request: Request) => Promise<Response>;
}
export interface Env {
  /** Ids of the boxes that may use this. */
  BOXES?: string;
  DAILY_CAP?: string;
  INTRODUCER: { idFromName: (name: string) => unknown; get: (id: unknown) => Stub };
}
declare const WebSocketPair: new () => { 0: Socket; 1: Socket };
declare const WebSocketRequestResponsePair: new (request: string, response: string) => unknown;

const ADDRESS = "x-lobby-address";
const OPEN = 1;
const nothing = (status = 404): Response => new Response(null, { status });

const opening = new PerMinute();

function settings(env: Env): Partial<Limits> {
  const perDay = Number(env.DAILY_CAP);
  return Number.isInteger(perDay) && perDay > 0 ? { perDay } : {};
}

/** Addresses count by the network they are in: an IPv6 customer has a whole /64. */
export function addressOf(request: Request): string {
  const address = request.headers.get("cf-connecting-ip") ?? "unknown";
  return address.includes(":") ? address.split(":").slice(0, 4).join(":") : address;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const wish = wishOf(new URL(request.url).pathname, readBoxes(env.BOXES));
    if (
      !wish ||
      request.method !== "GET" ||
      request.headers.get("upgrade")?.toLowerCase() !== "websocket" ||
      // Only a web page sends this, and no web page has business here.
      request.headers.has("origin")
    ) {
      return nothing();
    }
    // Before the object is woken, which costs.
    if (!opening.take(addressOf(request), 40, Date.now())) return nothing(429);
    const headers = new Headers(request.headers);
    headers.set(ADDRESS, addressOf(request));
    const stub = env.INTRODUCER.get(env.INTRODUCER.idFromName("introducer"));
    return stub.fetch(new Request(request, { headers }));
  },
};

class SocketLine implements Line {
  readonly socket: Socket;

  constructor(socket: Socket) {
    this.socket = socket;
  }

  send(text: string): void {
    if (this.socket.readyState === OPEN) this.socket.send(text);
  }

  close(code: number, reason: string): void {
    // So that it counts for nothing from here on.
    const state = this.state();
    if (state) this.remember({ ...state, at: -1, signedIn: false });
    this.socket.close(code, reason);
  }

  state(): LineState | null {
    return this.socket.deserializeAttachment() as LineState | null;
  }

  remember(state: LineState): void {
    this.socket.serializeAttachment(state);
  }
}

export class IntroducerRoom {
  private readonly context: Context;
  private readonly env: Env;
  private readonly introducer: Introducer;

  constructor(context: Context, env: Env) {
    this.context = context;
    this.env = env;
    // Answered without waking up.
    context.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
    const { storage } = context;
    const ground: Ground = {
      lines: () =>
        context
          .getWebSockets()
          .filter((socket) => socket.readyState === OPEN)
          .map((socket) => new SocketLine(socket)),
      read: (key) => storage.get(key),
      write: (key, value) => storage.put(key, value),
      remove: async (key) => {
        await storage.delete(key);
      },
      wakeAt: async (at) => {
        if ((await storage.getAlarm()) === null) await storage.setAlarm(at);
      },
      now: () => Date.now(),
    };
    this.introducer = new Introducer(ground, settings(env));
  }

  async fetch(request: Request): Promise<Response> {
    const wish = wishOf(new URL(request.url).pathname, readBoxes(this.env.BOXES));
    if (!wish) return nothing();
    const state = await this.introducer.admit(wish, request.headers.get(ADDRESS) ?? "unknown");
    if (typeof state === "number") return nothing(state);
    const pair = new WebSocketPair();
    this.context.acceptWebSocket(pair[1]);
    await this.introducer.opened(new SocketLine(pair[1]), state);
    return new Response(null, { status: 101, webSocket: pair[0] } as ResponseInit);
  }

  async webSocketMessage(socket: Socket, message: unknown): Promise<void> {
    await this.introducer.heard(new SocketLine(socket), message);
  }

  async webSocketClose(socket: Socket, code: number): Promise<void> {
    await this.introducer.closed(new SocketLine(socket));
    // The other half of the goodbye, which the platform does not say by itself.
    if (socket.readyState !== 3) socket.close(code >= 3000 ? code : 1000, "");
  }

  async webSocketError(socket: Socket): Promise<void> {
    await this.introducer.closed(new SocketLine(socket));
  }

  async alarm(): Promise<void> {
    await this.introducer.woke();
  }
}
