// SPDX-License-Identifier: MPL-2.0
import { createServer, type IncomingMessage, type Server } from "node:http";
import { isIPv6, type AddressInfo } from "node:net";
import { pathToFileURL } from "node:url";
import { WebSocketServer, type WebSocket } from "ws";
import {
  Introducer,
  readBoxes,
  wishOf,
  type Ground,
  type Limits,
  type Line,
  type LineState,
} from "./core.ts";

/* The introducer on a machine of one's own, behind a web server that does the TLS. */

export interface NodeOptions {
  boxes: string[];
  host?: string;
  port: number;
  /** Believe `X-Forwarded-For`: only with a web server of one's own in front. */
  trustProxy?: boolean;
  limits?: Partial<Limits>;
  now?: () => number;
}

export interface RunningIntroducer {
  port: number;
  close: () => Promise<void>;
}

class SocketLine implements Line {
  private readonly socket: WebSocket;
  private current: LineState | null = null;

  constructor(socket: WebSocket) {
    this.socket = socket;
  }

  send(text: string): void {
    if (this.socket.readyState === this.socket.OPEN) this.socket.send(text);
  }

  close(code: number, reason: string): void {
    if (this.current) this.current.signedIn = false;
    this.socket.close(code, reason);
    // Whoever does not say goodbye back does not stay for that.
    setTimeout(() => {
      this.socket.terminate();
    }, 2_000).unref();
  }

  state(): LineState | null {
    return this.current === null ? null : { ...this.current };
  }

  remember(state: LineState): void {
    this.current = { ...state };
  }
}

function addressOf(request: IncomingMessage, trustProxy: boolean): string {
  const forwarded = request.headers["x-forwarded-for"];
  const last = typeof forwarded === "string" ? forwarded.split(",").at(-1)?.trim() : undefined;
  const address = (trustProxy ? last : undefined) ?? request.socket.remoteAddress ?? "unknown";
  return isIPv6(address) && !address.startsWith("::ffff:")
    ? address.split(":").slice(0, 4).join(":")
    : address;
}

export async function startIntroducer(options: NodeOptions): Promise<RunningIntroducer> {
  const lines = new Set<SocketLine>();
  const kept = new Map<string, unknown>();
  const now = options.now ?? Date.now;
  let timer: NodeJS.Timeout | null = null;
  let timerAt = 0;
  const ground: Ground = {
    lines: () => [...lines],
    read: (key) => Promise.resolve(kept.get(key)),
    write: (key, value) => {
      kept.set(key, value);
      return Promise.resolve();
    },
    remove: (key) => {
      kept.delete(key);
      return Promise.resolve();
    },
    wakeAt: (at) => {
      if (timer && timerAt <= at) return Promise.resolve();
      if (timer) clearTimeout(timer);
      timerAt = at;
      timer = setTimeout(
        () => {
          timer = null;
          void introducer.woke();
        },
        Math.max(10, at - now()),
      );
      return Promise.resolve();
    },
    now,
  };
  const introducer = new Introducer(ground, options.limits);
  const sockets = new WebSocketServer({
    noServer: true,
    clientTracking: true,
    maxPayload: 32 * 1024,
    perMessageDeflate: false,
  });
  const server: Server = createServer((_request, response) => {
    response.writeHead(404, { "Content-Length": "0", Connection: "close" });
    response.end();
  });
  server.headersTimeout = 10_000;
  server.requestTimeout = 10_000;
  server.maxConnections = 256;

  server.on("upgrade", (request: IncomingMessage, socket, head) => {
    const refuse = (status: number): void => {
      socket.end(`HTTP/1.1 ${status} Refused\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`);
    };
    socket.on("error", () => undefined);
    const path = (request.url ?? "").split("?")[0] ?? "";
    const wish = wishOf(path, options.boxes);
    if (!wish || request.headers.origin !== undefined) {
      refuse(404);
      return;
    }
    introducer
      .admit(wish, addressOf(request, options.trustProxy ?? false))
      .then((state) => {
        if (typeof state === "number") {
          refuse(state);
          return;
        }
        sockets.handleUpgrade(request, socket, head, (made) => {
          const line = new SocketLine(made);
          lines.add(line);
          made.on("error", () => undefined);
          made.on("message", (data: Buffer, isBinary: boolean) => {
            const text = isBinary ? null : data.toString("utf8");
            // Never counts, as on Cloudflare.
            if (text === "ping") line.send("pong");
            else void introducer.heard(line, text);
          });
          made.on("close", () => {
            lines.delete(line);
            void introducer.closed(line);
          });
          void introducer.opened(line, state);
        });
      })
      .catch(() => {
        refuse(500);
      });
  });

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(options.port, options.host ?? "127.0.0.1", resolve);
  });
  return {
    port: (server.address() as AddressInfo).port,
    close: async () => {
      if (timer) clearTimeout(timer);
      for (const socket of sockets.clients) socket.terminate();
      await new Promise((done) => server.close(done));
    },
  };
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  const { env } = process;
  const boxes = readBoxes(env["BOXES"]);
  if (boxes.length === 0) {
    console.error("BOXES must hold the ids of the boxes that may use this (lobby direct id).");
    process.exit(1);
  }
  const perDay = Number(env["DAILY_CAP"]);
  const roomsPerBox = Number(env["ROOMS_PER_BOX"]);
  const running = await startIntroducer({
    boxes,
    host: env["HOST"] ?? "127.0.0.1",
    port: Number(env["PORT"] ?? "8676"),
    trustProxy: env["TRUST_PROXY"] === "1",
    limits: {
      ...(Number.isInteger(perDay) && perDay > 0 ? { perDay } : {}),
      // 1: one pairing room per box, as the introducer had before.
      ...(Number.isInteger(roomsPerBox) && roomsPerBox >= 1 && roomsPerBox <= 64
        ? { roomsPerBox }
        : {}),
    },
  });
  console.log(`The introducer is listening on port ${running.port}.`);
}
