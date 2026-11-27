// SPDX-License-Identifier: MPL-2.0
import type { Hono } from "hono";
import type { Device } from "../auth/devices.ts";
import type { Households } from "../households/store.ts";
import { ApiError, readBody, type AppEnv, type Ctx } from "../http/app.ts";
import { log } from "../log.ts";
import type { DirectTransport } from "./direct/index.ts";
import type { OutsideEntrance } from "./entrance.ts";
import { DEFAULT_WINDOW_MINUTES, MAX_WINDOW_MINUTES, type Approver } from "./pairing.ts";

interface OutsideRouteDeps {
  outside: OutsideEntrance;
  /** A server admin. */
  requireManager: (c: Ctx, action: string) => Device;
  /** An admin of the device's own household, or a server admin. */
  requireHouseholdAdmin: (c: Ctx, action: string) => Device;
  households: Households;
}

/** How a manager at home steers the outside entrance. All of it is closed from outside. */
export function registerOutsideRoutes(app: Hono<AppEnv>, deps: OutsideRouteDeps): void {
  const { outside, requireManager, requireHouseholdAdmin } = deps;
  const approver = (device: Device): Approver => ({
    householdId: device.householdId,
    access: device.access,
  });

  /** The status, with each waiting device's household by name. */
  const status = (): Record<string, unknown> => {
    const now = outside.status();
    return {
      ...now,
      requests: now.requests.map((one) => ({
        ...one,
        householdName: deps.households.find(one.householdId)?.name ?? null,
      })),
    };
  };

  app.get("/v1/outside", (c) => {
    requireManager(c, "see the outside entrance");
    return c.json(status());
  });

  app.patch("/v1/outside", async (c) => {
    const manager = requireManager(c, "change the outside entrance");
    const body = await readBody(c);
    const enabled = body["enabled"];
    if (typeof enabled !== "boolean") {
      throw new ApiError("invalid_request", `"enabled" must be true or false.`);
    }
    if (enabled && !outside.isConfigured) {
      throw new ApiError("conflict", "The outside entrance is not set up on the server.");
    }
    log.info(
      enabled ? "A manager opened the outside entrance" : "A manager closed the outside entrance",
      { by: manager.id },
    );
    await outside.setEnabled(enabled);
    return c.json(status());
  });

  app.post("/v1/outside/window", async (c) => {
    const manager = requireHouseholdAdmin(c, "let a device pair from outside");
    const body = await readBody(c);
    const minutes = body["minutes"] ?? DEFAULT_WINDOW_MINUTES;
    if (
      typeof minutes !== "number" ||
      !Number.isInteger(minutes) ||
      minutes < 1 ||
      minutes > MAX_WINDOW_MINUTES
    ) {
      throw new ApiError(
        "invalid_request",
        `"minutes" must be a whole number from 1 to ${MAX_WINDOW_MINUTES}.`,
      );
    }
    if (!outside.isOn) throw new ApiError("conflict", "The outside entrance is closed.");
    log.info("A manager let one device pair from outside", { by: manager.id, minutes });
    c.header("Cache-Control", "no-store");
    // For one device of the manager's own household.
    const window = outside.pairing.open(manager.id, minutes, manager.householdId);
    return c.json({ ...window, direct: outside.direct?.invitation ?? null }, 201);
  });

  app.delete("/v1/outside/window", (c) => {
    const manager = requireHouseholdAdmin(c, "let a device pair from outside");
    outside.pairing.close(manager.householdId);
    return c.body(null, 204);
  });

  app.post("/v1/outside/pairing/:id/approve", async (c) => {
    const manager = requireHouseholdAdmin(c, "approve devices");
    const body = await readBody(c);
    const comparison = body["comparison"];
    // Left out only by a server admin who says yes to one its household admin let in.
    const withoutDigits =
      comparison === undefined && outside.pairing.awaitsAdmin(c.req.param("id"));
    if (!withoutDigits && (typeof comparison !== "string" || !/^\d{6}$/.test(comparison))) {
      throw new ApiError(
        "invalid_request",
        `"comparison" must be the six digits on the new device's screen.`,
      );
    }
    if (!outside.isOn) throw new ApiError("conflict", "The outside entrance is closed.");
    const approved = outside.pairing.approve(
      c.req.param("id"),
      typeof comparison === "string" ? comparison : null,
      approver(manager),
    );
    log.info("A manager approved a device from outside", { by: manager.id });
    return c.json({
      deviceName: approved.deviceName,
      platform: approved.platform,
      role: "viewer",
      access: approved.access,
      householdId: approved.householdId,
      // Its household needs a server admin's yes too: it waits for that now.
      awaitsAdmin: approved.state === "awaitingAdmin",
    });
  });

  app.delete("/v1/outside/pairing/:id", (c) => {
    const manager = requireHouseholdAdmin(c, "approve devices");
    outside.pairing.deny(c.req.param("id"), approver(manager));
    return c.body(null, 204);
  });

  // ---- A device that gets itself ready for the direct road, at home ----

  const ready = (): DirectTransport => {
    if (!outside.direct) {
      throw new ApiError("not_found", "The direct connection is not set up on the server.");
    }
    return outside.direct;
  };

  app.get("/v1/me/direct", (c) => {
    const { identities } = ready();
    const device = c.get("device");
    c.header("Cache-Control", "no-store");
    return c.json({
      ...identities.identity(),
      ringKey: identities.ringKeyOf(device.id),
      allowed: device.allowOutside,
    });
  });

  app.put("/v1/me/direct", async (c) => {
    const direct = ready();
    const device = c.get("device");
    const body = await readBody(c);
    const before = direct.identities.ringKeyOf(device.id);
    const agreementKey = direct.identities.enrol(device.id, body["ringKey"], body["agreementKey"]);
    if (agreementKey === null) {
      throw new ApiError(
        "invalid_request",
        `"ringKey" and "agreementKey" must be new public keys of this device.`,
      );
    }
    if (before !== null) direct.forget(device.id);
    log.info("A device got ready for the direct connection", { device: device.id });
    c.header("Cache-Control", "no-store");
    return c.json({
      ...direct.identities.identity(),
      ringKey: body["ringKey"],
      allowed: device.allowOutside,
      agreementKey,
    });
  });

  app.get("/v1/outside/access", (c) => {
    const manager = requireHouseholdAdmin(c, "see who came in from outside");
    const limit = Number(c.req.query("limit") ?? "100");
    const before = c.req.query("before");
    if (!Number.isInteger(limit) || limit < 1 || limit > 500) {
      throw new ApiError("invalid_request", `"limit" must be a whole number from 1 to 500.`);
    }
    if (before !== undefined && !/^\d{1,15}$/.test(before)) {
      throw new ApiError("invalid_request", `"before" must be the id of an entry.`);
    }
    return c.json({
      // The owner is answerable for the whole server and sees all of it; a guest household its own.
      entries: outside.access.read(
        limit,
        before === undefined ? null : Number(before),
        manager.access === "admin" ? undefined : manager.householdId,
      ),
    });
  });
}
