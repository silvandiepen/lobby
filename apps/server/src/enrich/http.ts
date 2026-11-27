// SPDX-License-Identifier: MPL-2.0
import { setTimeout as sleep } from "node:timers/promises";
import { ProviderError, ProviderUnavailable } from "./provider.ts";

export interface FetchLimits {
  /** Requests in flight at once, artwork included. */
  maxConcurrent: number;
  /** Shortest time between the starts of two requests. */
  minIntervalMs: number;
  timeoutMs: number;
  /** How often one request is tried again after 429, 5xx or a connection failure. */
  retries: number;
  /** The first wait before trying again; it doubles each time. */
  backoffMs: number;
  /** Longest wait before trying again. A longer Retry-After is treated as an outage. */
  maxBackoffMs: number;
  maxBytes: number;
}

export const DEFAULT_LIMITS: FetchLimits = {
  maxConcurrent: 4,
  minIntervalMs: 50,
  timeoutMs: 20_000,
  retries: 4,
  backoffMs: 1_000,
  maxBackoffMs: 60_000,
  maxBytes: 16 * 1024 * 1024,
};

export interface Fetched {
  status: number;
  body: Uint8Array<ArrayBuffer>;
}

/** A bounded, polite HTTP client. Its errors never hold a URL, a header or a query. */
export class LimitedFetch {
  private readonly limits: FetchLimits;
  private readonly signal: AbortSignal;
  private running = 0;
  private nextStart = 0;
  private readonly queue: (() => void)[] = [];

  constructor(limits: FetchLimits, signal: AbortSignal) {
    this.limits = limits;
    this.signal = signal;
  }

  /**
   * @param what names the request in errors, without anything from the household
   */
  async get(url: URL, headers: Record<string, string>, what: string): Promise<Fetched> {
    for (let attempt = 0; ; attempt += 1) {
      const result = await this.once(url, headers);
      this.signal.throwIfAborted();
      if ("fetched" in result) {
        const { status } = result.fetched;
        if (status === 401) {
          throw new ProviderUnavailable(`${what} was refused (401)`, true);
        }
        if (status !== 429 && status < 500) return result.fetched;
      }
      const reason = "fetched" in result ? `status ${result.fetched.status}` : result.failure;
      const wait = Math.max(this.limits.backoffMs * 2 ** attempt, result.retryAfterMs ?? 0);
      if (attempt >= this.limits.retries || wait > this.limits.maxBackoffMs) {
        throw new ProviderUnavailable(`${what} failed: ${reason}`);
      }
      await sleep(wait, undefined, { signal: this.signal });
    }
  }

  private async once(
    url: URL,
    headers: Record<string, string>,
  ): Promise<
    | { fetched: Fetched; retryAfterMs: number | null }
    | { failure: string; retryAfterMs: number | null }
  > {
    await this.acquire();
    try {
      const delay = this.nextStart - performance.now();
      this.nextStart = Math.max(this.nextStart, performance.now()) + this.limits.minIntervalMs;
      if (delay > 0) await sleep(delay, undefined, { signal: this.signal });
      const response = await fetch(url, {
        headers,
        // A redirect could carry the key to another host.
        redirect: "error",
        signal: AbortSignal.any([this.signal, AbortSignal.timeout(this.limits.timeoutMs)]),
      });
      const body = await this.readBody(response);
      return {
        fetched: { status: response.status, body },
        retryAfterMs: retryAfter(response.headers.get("retry-after")),
      };
    } catch (error) {
      this.signal.throwIfAborted();
      if (error instanceof ProviderError) throw error;
      return { failure: failureName(error), retryAfterMs: null };
    } finally {
      this.release();
    }
  }

  private async readBody(response: Response): Promise<Uint8Array<ArrayBuffer>> {
    const chunks: Uint8Array[] = [];
    let size = 0;
    if (response.body) {
      for await (const chunk of response.body as ReadableStream<Uint8Array>) {
        size += chunk.byteLength;
        if (size > this.limits.maxBytes) throw new ProviderError("The answer is too large");
        chunks.push(chunk);
      }
    }
    const body = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      body.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return body;
  }

  private async acquire(): Promise<void> {
    // A freed place is handed straight to the next in line, so the count never overshoots.
    if (this.running < this.limits.maxConcurrent) this.running += 1;
    else await new Promise<void>((go) => this.queue.push(go));
  }

  private release(): void {
    const next = this.queue.shift();
    if (next) next();
    else this.running -= 1;
  }
}

function retryAfter(value: string | null): number | null {
  if (value === null) return null;
  const seconds = Number(value);
  if (Number.isFinite(seconds)) return Math.max(0, seconds * 1000);
  const at = Date.parse(value);
  return Number.isNaN(at) ? null : Math.max(0, at - Date.now());
}

/** Only an error code or name: messages can quote the request. */
function failureName(error: unknown): string {
  if (!(error instanceof Error)) return "unknown failure";
  const { cause } = error;
  if (cause instanceof Error && "code" in cause && typeof cause.code === "string") {
    return cause.code;
  }
  return error.name === "TimeoutError" ? "timeout" : "connection failure";
}
