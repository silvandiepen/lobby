// SPDX-License-Identifier: MPL-2.0

import { openBytes, sealBytes } from "../outside/direct/envelope.ts";

/*
 * What a server says to an app through the push relay, sealed so that the relay passes on what it
 * cannot read: ChaCha20-Poly1305 with the 32-byte key the app made for this server, the 12-byte
 * nonce first and the tag last, base64url. The app's notification service opens it and shows
 * it; the exact bytes are in docs/push-vectors.json, which the apps test against too.
 */

export const PUSH_PROTOCOL = "lobby-push/1";
/** What every sealed notification is bound to. */
export const PUSH_AAD = `${PUSH_PROTOCOL}|alert`;

/** What the lock screen shows, and what the app reads when it is tapped or answered. */
export interface PushContent {
  title: string;
  body: string;
  /** A notification category of the apps, for its actions. */
  category?: string;
  thread?: string;
  data: Record<string, unknown>;
}

export function sealPush(key: Uint8Array, content: PushContent, nonce?: Uint8Array): string {
  return sealBytes(key, PUSH_AAD, Buffer.from(JSON.stringify(content)), nonce);
}

/** @throws Error when it was not sealed with this key */
export function openPush(key: Uint8Array, sealed: string): PushContent {
  return JSON.parse(openBytes(key, PUSH_AAD, sealed).toString("utf8")) as PushContent;
}
