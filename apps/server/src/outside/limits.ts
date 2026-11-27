// SPDX-License-Identifier: MPL-2.0
import { isIP, isIPv6 } from "node:net";

/** A bucket that holds `burst` and fills at `perMinute`. */
export interface Rate {
  burst: number;
  perMinute: number;
}

interface Bucket {
  left: number;
  at: number;
}

/** Token buckets by key, of which at most `max` are remembered: the one used longest ago goes. */
export class RateLimiter {
  private readonly buckets = new Map<string, Bucket>();
  private readonly rate: Rate;
  private readonly now: () => number;
  private readonly max: number;

  constructor(rate: Rate, now: () => number, max = 4096) {
    this.rate = rate;
    this.now = now;
    this.max = max;
  }

  get size(): number {
    return this.buckets.size;
  }

  /** Seconds to wait before there is one to take; 0 when there is one now. Takes nothing. */
  wait(key: string): number {
    const left = this.left(key);
    return left >= 1 ? 0 : Math.ceil(((1 - left) / this.rate.perMinute) * 60);
  }

  /** Takes one when there is one. Returns the seconds to wait when there is none. */
  take(key: string): number {
    const left = this.left(key);
    const taken = left >= 1;
    this.buckets.delete(key);
    this.buckets.set(key, { left: taken ? left - 1 : left, at: this.now() });
    if (this.buckets.size > this.max) {
      const oldest = this.buckets.keys().next().value;
      if (oldest !== undefined) this.buckets.delete(oldest);
    }
    return taken ? 0 : Math.ceil(((1 - left) / this.rate.perMinute) * 60);
  }

  private left(key: string): number {
    const bucket = this.buckets.get(key);
    if (!bucket) return this.rate.burst;
    const since = Math.max(0, this.now() - bucket.at);
    return Math.min(this.rate.burst, bucket.left + (since / 60_000) * this.rate.perMinute);
  }
}

const FIRST_BACKOFF_MS = 15_000;
const LAST_BACKOFF_MS = 3_600_000;

/**
 * Failed tries. Each address gets a few, then a wait that doubles every time. A try also counts
 * against everyone together, because an address can be anyone's: many can share one, and one
 * can have many.
 */
export class FailureLimiter {
  private readonly perAddress = new Map<string, { failures: number; at: number; until: number }>();
  private readonly all: RateLimiter;
  private readonly free: number;
  private readonly forgetMs: number;
  private readonly now: () => number;
  private readonly max: number;

  constructor(
    options: { free: number; forgetMs: number; all: Rate; max?: number },
    now: () => number,
  ) {
    this.all = new RateLimiter(options.all, now);
    this.free = options.free;
    this.forgetMs = options.forgetMs;
    this.now = now;
    this.max = options.max ?? 4096;
  }

  get size(): number {
    return this.perAddress.size;
  }

  /** Seconds to wait before the next try; 0: go on. `key` is null when the address says nothing. */
  wait(key: string | null): number {
    const entry = key === null ? undefined : this.perAddress.get(key);
    const address = entry ? Math.ceil(Math.max(0, entry.until - this.now()) / 1000) : 0;
    return Math.max(address, this.all.wait("all"));
  }

  fail(key: string | null): void {
    this.all.take("all");
    if (key === null) return;
    const before = this.perAddress.get(key);
    const fresh = before && this.now() - Math.max(before.at, before.until) < this.forgetMs;
    const failures = (fresh ? before.failures : 0) + 1;
    const over = failures - this.free;
    const backoff =
      over < 0 ? 0 : Math.min(LAST_BACKOFF_MS, FIRST_BACKOFF_MS * 2 ** Math.min(over, 20));
    this.perAddress.delete(key);
    this.perAddress.set(key, { failures, at: this.now(), until: this.now() + backoff });
    if (this.perAddress.size > this.max) {
      const oldest = this.perAddress.keys().next().value;
      if (oldest !== undefined) this.perAddress.delete(oldest);
    }
  }

  clear(key: string | null): void {
    if (key !== null) this.perAddress.delete(key);
  }
}

/** Counts what is going on at once, per key and in all. */
export class Slots {
  private readonly taken = new Map<string, number>();
  private total = 0;
  private readonly perKey: number;
  private readonly inAll: number;

  constructor(perKey: number, inAll: number) {
    this.perKey = perKey;
    this.inAll = inAll;
  }

  /** A function that gives the slot back (once), or null when there is none. */
  take(key: string): (() => void) | null {
    const held = this.taken.get(key) ?? 0;
    if (held >= this.perKey || this.total >= this.inAll) return null;
    this.taken.set(key, held + 1);
    this.total += 1;
    let given = false;
    return () => {
      if (given) return;
      given = true;
      this.total -= 1;
      const left = (this.taken.get(key) ?? 1) - 1;
      if (left === 0) this.taken.delete(key);
      else this.taken.set(key, left);
    };
  }
}

/** The eight groups of an IPv6 address. */
function groups(address: string): number[] {
  let plain = address.split("%")[0] ?? "";
  const dotted = /^(.*:)(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(plain);
  if (dotted) {
    const [, head = "", a, b, c, d] = dotted;
    plain = `${head}${(Number(a) * 256 + Number(b)).toString(16)}:${(Number(c) * 256 + Number(d)).toString(16)}`;
  }
  const [left = "", right] = plain.split("::");
  const read = (part: string): number[] =>
    part === "" ? [] : part.split(":").map((group) => parseInt(group, 16));
  const first = read(left);
  if (right === undefined) return first;
  const last = read(right);
  return [...first, ...Array<number>(8 - first.length - last.length).fill(0), ...last];
}

/** An address in one way of writing it: IPv4 inside IPv6 as IPv4. Null when it is none. */
export function plainAddress(address: string | null | undefined): string | null {
  if (!address || isIP(address) === 0) return null;
  if (!isIPv6(address)) return address;
  const g = groups(address);
  if (g.slice(0, 5).every((group) => group === 0) && g[5] === 0xffff) {
    const [high = 0, low = 0] = g.slice(6);
    return [high >> 8, high & 255, low >> 8, low & 255].join(".");
  }
  return g.map((group) => group.toString(16)).join(":");
}

/** What tries are counted by: the address, or the /64 an IPv6 address is in. */
export function addressKey(address: string | null): string | null {
  const plain = plainAddress(address);
  if (plain === null || !isIPv6(plain)) return plain;
  return `${plain.split(":").slice(0, 4).join(":")}::/64`;
}
