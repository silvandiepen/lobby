// SPDX-License-Identifier: MPL-2.0
import { OWNER_HOUSEHOLD } from "../households/owner.ts";
import type { Hono } from "hono";
import type { Device, Devices } from "../auth/devices.ts";
import { ApiError, readBody, type AppEnv, type Ctx } from "../http/app.ts";
import { isNearby, peerAddress } from "../http/home.ts";
import { SettingsError, type SettingsService } from "../settings/service.ts";
import type { RemoteHub } from "./hub.ts";
import { MAX_MESSAGE, readHeldPlay, readId } from "./messages.ts";
import type { WakeService } from "./wake.ts";

interface WakeRouteDeps {
  wake: WakeService;
  devices: Devices;
  settings: SettingsService | null;
  /** Who uses a session: a child in the kids screens of a grown-up's device is a child here too. */
  remote: RemoteHub | null;
  requireManager: (c: Ctx, action: string) => Device;
}

const MAX_BODY = 4 * 1024;

const text = (body: Record<string, unknown>, key: string): string => {
  const value = body[key];
  if (typeof value !== "string" || value === "" || value.length > 200) {
    throw new ApiError("invalid_request", `"${key}" is missing.`);
  }
  return value;
};

/**
 * Waking Apple TVs (docs/api.md, "Waking an Apple TV"). Only on the app for home: a TV that is
 * turned on from away is someone else's evening. The manager's routes also only nearby.
 */
export function registerWakeRoutes(app: Hono<AppEnv>, deps: WakeRouteDeps): void {
  const { wake, devices, requireManager } = deps;

  const manager = (c: Ctx, action: string): Device => {
    const device = requireManager(c, action);
    const peer = peerAddress(c);
    if (peer !== null && !isNearby(peer)) {
      throw new ApiError("forbidden", "Apple TVs can only be connected at home or over Tailscale.");
    }
    c.header("Cache-Control", "no-store");
    return device;
  };

  app.get("/v1/wake", (c) => {
    manager(c, "see the Apple TVs");
    return c.json(wake.status());
  });

  app.patch("/v1/wake", async (c) => {
    const body = await readBody(c, MAX_BODY);
    const device = manager(c, "turn waking Apple TVs on or off");
    const changes: Record<string, boolean> = {};
    for (const [field, key] of [
      ["enabled", "remote.wake.enabled"],
      ["kids", "remote.wake.kids"],
    ] as const) {
      const value = body[field];
      if (value === undefined) continue;
      if (typeof value !== "boolean") {
        throw new ApiError("invalid_request", `"${field}" must be true or false.`);
      }
      changes[key] = value;
    }
    if (Object.keys(changes).length === 0) {
      throw new ApiError("invalid_request", `"enabled" or "kids" must be true or false.`);
    }
    if (!deps.settings) throw new ApiError("unavailable", "The settings cannot be changed here.");
    if (!wake.status().configured) {
      throw new ApiError("not_found", "Waking Apple TVs is not set up on this server.", {
        reason: "wake_not_configured",
      });
    }
    try {
      await deps.settings.change(device.id, changes, { dryRun: false, baseVersion: null });
    } catch (error) {
      if (error instanceof SettingsError) throw new ApiError(error.code, error.message);
      throw error;
    }
    return c.json(wake.status());
  });

  app.post("/v1/wake/scan", async (c) => {
    const device = manager(c, "look for Apple TVs");
    return c.json(await wake.scan(device));
  });

  app.post("/v1/wake/pairings", async (c) => {
    const body = await readBody(c, MAX_BODY);
    const device = manager(c, "connect an Apple TV");
    return c.json(await wake.beginPairing(device, text(body, "televisionId")), 201);
  });

  app.post("/v1/wake/pairings/:id", async (c) => {
    const body = await readBody(c, MAX_BODY);
    const device = manager(c, "connect an Apple TV");
    return c.json(await wake.finishPairing(device, c.req.param("id"), text(body, "pin")));
  });

  app.delete("/v1/wake/pairings/:id", async (c) => {
    manager(c, "connect an Apple TV");
    await wake.cancelPairing(c.req.param("id"));
    return c.body(null, 204);
  });

  app.put("/v1/wake/televisions/:id", async (c) => {
    const body = await readBody(c, MAX_BODY);
    manager(c, "connect an Apple TV");
    const deviceId = body["deviceId"];
    if (deviceId !== null && (typeof deviceId !== "string" || deviceId === "")) {
      throw new ApiError("invalid_request", `"deviceId" must be a device's id or null.`);
    }
    // A TV on the owner's network is a device of the owner's household.
    if (deviceId !== null && devices.find(deviceId)?.householdId !== OWNER_HOUSEHOLD) {
      throw new ApiError("not_found", "There is no such device.");
    }
    return c.json(wake.link(c.req.param("id"), deviceId));
  });

  app.delete("/v1/wake/televisions/:id", async (c) => {
    const device = manager(c, "disconnect an Apple TV");
    await wake.unpair(device, c.req.param("id"));
    return c.body(null, 204);
  });

  // A device at home that may play on others: the TV then opens Lobby. With `play`, the server
  // keeps the play and sends it the moment Lobby is open there (docs/decisions.md, "Wake and Play"); without, the device sends
  // what to play over the live channel as always. A child (a bound device, or the kids screens of
  // the session it names) only when the household lets kids turn on the TV.
  app.post("/v1/remote/wake", async (c) => {
    const body = await readBody(c, MAX_MESSAGE);
    const before = c.get("device");
    const device = devices.find(before.id);
    if (!device || device.revokedAt !== null) {
      throw new ApiError("gone", "Open the live channel again.", { reason: "session" });
    }
    const session = body["session"];
    if (session !== undefined && (typeof session !== "string" || session === "")) {
      throw new ApiError("invalid_request", `"session" must be the id of this device's channel.`);
    }
    const kid =
      device.kidsProfileId ??
      (session === undefined || !deps.remote
        ? null
        : deps.remote.kidUsing(device.id, session, false));
    const notWakeable = (): ApiError =>
      new ApiError("not_found", "That device cannot be woken.", { reason: "not_wakeable" });
    if (kid !== null && !wake.kidsMayWake()) throw notWakeable();
    // And only where the child's plan lets it watch now (docs/kids-control.md).
    if (kid !== null && deps.remote && !deps.remote.kidMayWatch(kid, device.id, false)) {
      throw notWakeable();
    }
    if (!device.allowRemote) {
      throw new ApiError("forbidden", "Playing on other devices is turned off for this device.", {
        reason: "control_off",
      });
    }
    const peer = peerAddress(c);
    if (peer !== null && !isNearby(peer)) {
      throw new ApiError("forbidden", "An Apple TV can only be woken from home.", {
        reason: "home_only",
      });
    }
    const target = text(body, "deviceId");
    if (target === device.id) throw new ApiError("invalid_request", "This device is awake.");
    const shown = devices.find(target);
    if (
      !shown ||
      shown.revokedAt !== null ||
      !shown.isTarget ||
      !shown.allowRemote ||
      shown.householdId !== device.householdId
    ) {
      throw new ApiError("not_found", "There is no such device.");
    }
    // Another child's TV plays nothing for this one.
    if (kid !== null && shown.kidsProfileId !== null && shown.kidsProfileId !== kid) {
      throw notWakeable();
    }
    const play =
      body["play"] === undefined || body["play"] === null ? null : readHeldPlay(body["play"]);
    const hub = deps.remote;
    if (play && (session === undefined || !hub)) {
      throw new ApiError("invalid_request", `"session" is needed with "play".`);
    }
    // Not woken for a title that would be refused there.
    if (play && hub && session !== undefined)
      hub.checkHeldPlay(device.id, session, target, play.command);
    const commandId = play?.id ?? null;
    const progress =
      hub && session !== undefined
        ? (step: "profile" | "not_open", reason: string | null): void => {
            hub.tellWake(device.id, session, target, commandId, step, reason);
          }
        : undefined;
    const woke = await wake.wake(device, target, progress);
    const held =
      play && hub && session !== undefined
        ? hub.holdPlay(device.id, session, target, play, wake.holdPlayMs())
        : null;
    return c.json(
      {
        deviceId: target,
        wokenAt: Date.now(),
        lobbyInFront: woke.front,
        play: held,
      },
      202,
    );
  });

  // The sender takes back a play that waits for a woken TV. 404 when it is not waiting any more:
  // sent, replaced or over.
  app.delete("/v1/remote/wake/:deviceId/plays/:id", (c) => {
    const device = c.get("device");
    const cancelled = deps.remote?.cancelHeldPlay(
      device.id,
      readId(c.req.param("deviceId"), "deviceId"),
      readId(c.req.param("id"), "id"),
    );
    if (!cancelled) throw new ApiError("not_found", "No such play waits for that device.");
    return c.body(null, 204);
  });
}
