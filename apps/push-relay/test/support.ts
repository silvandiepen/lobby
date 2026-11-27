// SPDX-License-Identifier: MPL-2.0

import { createHash, generateKeyPairSync, sign, type KeyObject } from "node:crypto";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { Miniflare, Response as WorkerResponse, type Request as WorkerRequest } from "miniflare";
import { PROTOCOL } from "../src/core.ts";

/** A box: the Ed25519 key a Lobby Server also uses with the introducer. */
export interface Box {
  key: KeyObject;
  /** Raw public key, base64url. */
  public: string;
  id: string;
}

export function box(): Box {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const raw = publicKey.export({ format: "der", type: "spki" }).subarray(-32);
  return {
    key: privateKey,
    public: raw.toString("base64url"),
    id: createHash("sha256").update(raw).digest("base64url"),
  };
}

/** What a server gives its app to register with: `<box key>.<until>.<signature>`. */
export function ticket(of: Box, until: number): string {
  const signature = sign(null, Buffer.from(`${PROTOCOL}|ticket|${of.id}|${until}`), of.key);
  return `${of.public}.${until}.${signature.toString("base64url")}`;
}

/** A send, signed as the server signs it. */
export function signed(of: Box, body: unknown): { text: string; signature: string } {
  const text = JSON.stringify(body);
  const signature = sign(null, Buffer.from(`${PROTOCOL}|send|${of.id}|${text}`), of.key);
  return { text, signature: signature.toString("base64url") };
}

/** A key made for the test, never the team's. */
export function throwawayAppleKey(): { pem: string; public: KeyObject } {
  const pair = generateKeyPairSync("ec", { namedCurve: "P-256" });
  return {
    pem: pair.privateKey.export({ type: "pkcs8", format: "pem" }).toString(),
    public: pair.publicKey,
  };
}

export interface ToApple {
  url: string;
  headers: Record<string, string>;
  body: Record<string, unknown>;
}

/** The real thing: the same files, with their types taken off, in workerd, and Apple played. */
export async function startWorker(
  env: Record<string, string>,
  apple: (request: ToApple) => { status: number; body?: unknown },
): Promise<{ url: string; close: () => Promise<void> }> {
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
    bindings: env,
    durableObjects: { RELAY: { className: "PushRelay", useSQLite: true } },
    // Every request the Worker makes goes here instead of out.
    outboundService: async (request: WorkerRequest) => {
      const headers: Record<string, string> = {};
      request.headers.forEach((value: string, name: string) => {
        headers[name] = value;
      });
      const said = apple({
        url: request.url,
        headers,
        body: JSON.parse(await request.text()) as Record<string, unknown>,
      });
      return new WorkerResponse(said.body === undefined ? null : JSON.stringify(said.body), {
        status: said.status,
      });
    },
  });
  const url = await worker.ready;
  return { url: url.href.replace(/\/$/, ""), close: () => worker.dispose() };
}
