// SPDX-License-Identifier: MPL-2.0
import { randomBytes } from "node:crypto";
import type { Hono } from "hono";
import type { Device, Devices } from "../auth/devices.ts";
import type { AppEnv } from "./app.ts";

/**
 * AirPlay passes (docs/api.md, "AirPlay"). An AirPlay receiver fetches the film itself and gets
 * neither the device's header nor its cookie, so a device at home may ask for a path under which
 * one file of the library can be read without a credential, for a while. The pass is a random
 * name, not the credential: it opens `GET` and `HEAD` under `/v1/assets/{that id}/` and nothing
 * else, as the device that asked for it, with that device's kids limits, and ends when the device
 * is removed.
 */
export const AIRPLAY = {
  /** Long enough for a long film with a pause, short enough that a pass is not a key. */
  lifetimeMs: 8 * 3_600_000,
  /** Passes per device; asking for another drops the oldest. */
  perDevice: 8,
} as const;

interface Pass {
  deviceId: string;
  assetId: string;
  expiresAt: number;
}

export class AirPlayPasses {
  private readonly passes = new Map<string, Pass>();
  /** The requests made under a pass, so that the credential check knows them. */
  private readonly requests = new WeakMap<Request, Pass>();

  private readonly devices: Devices;
  private readonly now: () => number;

  constructor(devices: Devices, now: () => number) {
    this.devices = devices;
    this.now = now;
  }

  issue(deviceId: string, assetId: string): { name: string; expiresAt: number } {
    this.sweep();
    const own = [...this.passes].filter(([, one]) => one.deviceId === deviceId);
    for (const [name] of own.slice(0, Math.max(0, own.length - AIRPLAY.perDevice + 1))) {
      this.passes.delete(name);
    }
    const name = randomBytes(24).toString("base64url");
    const expiresAt = this.now() + AIRPLAY.lifetimeMs;
    this.passes.set(name, { deviceId, assetId, expiresAt });
    return { name, expiresAt };
  }

  /** The pass of that name, while it holds and its device is still there. */
  find(name: string): Pass | null {
    const pass = this.passes.get(name);
    if (!pass) return null;
    if (pass.expiresAt <= this.now()) {
      this.passes.delete(name);
      return null;
    }
    const device = this.devices.find(pass.deviceId);
    if (!device || device.revokedAt !== null) {
      this.passes.delete(name);
      return null;
    }
    return pass;
  }

  /** The device a request made under a pass acts as. null for every other request. */
  deviceOf(request: Request): Device | null {
    const pass = this.requests.get(request);
    if (!pass) return null;
    const device = this.devices.find(pass.deviceId);
    return device && device.revokedAt === null ? device : null;
  }

  remember(request: Request, pass: Pass): void {
    this.requests.set(request, pass);
  }

  private sweep(): void {
    const now = this.now();
    for (const [name, pass] of this.passes) if (pass.expiresAt <= now) this.passes.delete(name);
  }
}

const ASSET_PATH = /^assets\/([A-Za-z0-9_-]{1,128})\/[^?#]*$/;

/**
 * `GET|HEAD /v1/airplay/{pass}/assets/{id}/…`: the same as `/v1/assets/{id}/…`, as the device that
 * asked for the pass. Before the credential check: the receiver has none. Relative paths in a
 * playlist stay under the pass, so the segments are covered too.
 */
export function registerAirPlayRoutes(app: Hono<AppEnv>, deps: { passes: AirPlayPasses }): void {
  const { passes } = deps;
  app.on(["GET", "HEAD"], "/v1/airplay/:pass/*", async (c) => {
    const pass = passes.find(c.req.param("pass"));
    const url = new URL(c.req.url);
    const prefix = `/v1/airplay/${c.req.param("pass")}/`;
    const rest = url.pathname.startsWith(prefix) ? url.pathname.slice(prefix.length) : "";
    const match = ASSET_PATH.exec(rest);
    // The same empty answer for a pass that is not there and a path that is not its file.
    if (!pass || !match || match[1] !== pass.assetId || rest.includes("..")) {
      return c.json(
        { error: { code: "not_found", message: "There is nothing at this address." } },
        404,
      );
    }
    url.pathname = `/v1/${rest}`;
    const headers = new Headers();
    // What a player sends about the bytes it wants, and nothing that could be a credential.
    for (const name of [
      "range",
      "if-range",
      "if-none-match",
      "if-modified-since",
      "accept",
      "host",
      "user-agent",
    ]) {
      const value = c.req.header(name);
      if (value !== undefined) headers.set(name, value);
    }
    const inner = new Request(url, { method: c.req.method, headers });
    passes.remember(inner, pass);
    return app.fetch(inner, c.env);
  });
}
