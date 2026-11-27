// SPDX-License-Identifier: MPL-2.0
import { TMDB_BASE_URL } from "../enrich/tmdb.ts";

/** What TMDB said of a key. */
export type KeyCheck = "accepted" | "refused" | "unreachable";

/** A v3 API key (32 hex characters) or a v4 read token. Anything else is not worth asking about. */
export function looksLikeTmdbKey(key: string): boolean {
  return (
    /^[0-9a-f]{32}$/i.test(key) ||
    /^[A-Za-z0-9_-]{20,1000}\.[A-Za-z0-9_-]{10,2000}\.[A-Za-z0-9_-]{10,1000}$/.test(key)
  );
}

/**
 * Asks TMDB whether it accepts a key, with the smallest request there is. The key goes in the
 * way the enricher sends it, never into a log or an error.
 */
export async function checkTmdbKey(
  key: string,
  baseUrl: string = TMDB_BASE_URL,
  timeoutMs = 10_000,
): Promise<KeyCheck> {
  const url = new URL(`${baseUrl.replace(/\/+$/, "")}/configuration`);
  const headers: Record<string, string> = { accept: "application/json" };
  if (/^[0-9a-f]{32}$/i.test(key)) url.searchParams.set("api_key", key);
  else headers["authorization"] = `Bearer ${key}`;
  try {
    const reply = await fetch(url, { headers, signal: AbortSignal.timeout(timeoutMs) });
    await reply.body?.cancel();
    if (reply.ok) return "accepted";
    return reply.status === 401 || reply.status === 403 ? "refused" : "unreachable";
  } catch {
    return "unreachable";
  }
}
