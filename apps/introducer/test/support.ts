// SPDX-License-Identifier: MPL-2.0
import { createHash, generateKeyPairSync, sign, type KeyObject } from "node:crypto";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { Miniflare } from "miniflare";
import { WebSocket } from "ws";
import { startIntroducer } from "../src/node.ts";
import type { Limits } from "../src/core.ts";

export interface Person {
  key: KeyObject;
  public: string;
}

export function person(): Person {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const raw = publicKey.export({ format: "der", type: "spki" }).subarray(-32);
  return { key: privateKey, public: raw.toString("base64url") };
}

export const idOf = (box: Person): string =>
  createHash("sha256").update(Buffer.from(box.public, "base64url")).digest("base64url");

export interface Started {
  url: string;
  close: () => Promise<void>;
}

export async function startNode(boxes: string[], limits: Partial<Limits> = {}): Promise<Started> {
  // Every test comes from one address.
  const running = await startIntroducer({
    boxes,
    port: 0,
    limits: { openPerMinute: 1_000, ...limits },
  });
  return { url: `ws://127.0.0.1:${running.port}`, close: running.close };
}

/** The real thing: the same files, with their types taken off, in workerd. */
export async function startWorker(boxes: string[], perDay = 20_000): Promise<Started> {
  const load = (name: string): { type: "ESModule"; path: string; contents: string } => ({
    type: "ESModule",
    path: name,
    contents: stripTypeScriptTypes(
      readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8"),
    ),
  });
  const worker = new Miniflare({
    compatibilityDate: "2026-07-01",
    modules: [load("worker.ts"), load("core.ts")],
    bindings: { BOXES: boxes.join(","), DAILY_CAP: String(perDay) },
    durableObjects: { INTRODUCER: { className: "IntroducerRoom", useSQLite: true } },
  });
  const url = await worker.ready;
  return {
    url: url.href.replace(/^http/, "ws").replace(/\/$/, ""),
    close: () => worker.dispose(),
  };
}

type Message = Record<string, unknown>;

/** One end of a line. */
export class End {
  readonly socket: WebSocket;
  private readonly waiting: ((message: Message | number) => void)[] = [];
  private readonly held: (Message | number)[] = [];

  constructor(url: string, headers: Record<string, string> = {}) {
    this.socket = new WebSocket(url, { headers });
    this.socket.on("error", () => undefined);
    this.socket.on("message", (data: Buffer) => {
      const text = data.toString("utf8");
      this.give(text === "pong" ? { t: "pong" } : (JSON.parse(text) as Message));
    });
    this.socket.on("close", (code) => {
      this.give(code);
    });
    this.socket.on("unexpected-response", (_request, response) => {
      response.resume();
      this.give(response.statusCode ?? 0);
    });
  }

  private give(message: Message | number): void {
    const next = this.waiting.shift();
    if (next) next(message);
    else this.held.push(message);
  }

  /** The next message, or the number the line was closed or refused with. */
  next(ms = 5_000): Promise<Message | number> {
    const held = this.held.shift();
    if (held !== undefined) return Promise.resolve(held);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error("nothing was said"));
      }, ms);
      this.waiting.push((message) => {
        clearTimeout(timer);
        resolve(message);
      });
    });
  }

  /** Nothing for a while. */
  async silent(ms = 300): Promise<boolean> {
    await new Promise((done) => setTimeout(done, ms));
    return this.held.length === 0;
  }

  say(message: object | string): void {
    this.socket.send(typeof message === "string" ? message : JSON.stringify(message));
  }

  close(): void {
    this.socket.terminate();
  }
}

export interface Auth {
  role: "box" | "device";
  box: string;
  who: Person;
  change?: (message: Message, nonce: string) => Message;
}

/** Signs in. Returns what was said to that. */
export async function signIn(
  url: string,
  { role, box, who, change }: Auth,
): Promise<{ end: End; said: Message | number }> {
  const end = new End(`${url}/v1/box/${box}`);
  const challenge = await end.next();
  if (typeof challenge === "number") return { end, said: challenge };
  const nonce = String(challenge["nonce"]);
  const signature = sign(
    null,
    Buffer.from(`lobby-introducer/1|${role}|${box}|${nonce}`),
    who.key,
  ).toString("base64url");
  const message = { t: "auth", role, key: who.public, signature };
  end.say(change ? change(message, nonce) : message);
  return { end, said: await end.next() };
}
