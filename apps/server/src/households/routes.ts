// SPDX-License-Identifier: MPL-2.0
import type { Hono } from "hono";
import type { Device, Devices } from "../auth/devices.ts";
import { ApiError, kidsSettings, readBody, type AppEnv, type Ctx } from "../http/app.ts";
import { log } from "../log.ts";
import type { OutsideEntrance } from "../outside/entrance.ts";
import type { RemoteHub } from "../remote/index.ts";
import { DEFAULT_INVITE_HOURS, MAX_INVITE_HOURS, type Invite } from "./invites.ts";
import { OWNER_HOUSEHOLD } from "./owner.ts";
import type { Household, HouseholdChange, Households } from "./store.ts";

interface HouseholdRouteDeps {
  households: Households;
  devices: Devices;
  outside: OutsideEntrance | undefined;
  remote: RemoteHub | undefined;
  /** A server admin. */
  requireManager: (c: Ctx, action: string) => Device;
  /** An admin of the device's own household, or a server admin. */
  requireHouseholdAdmin: (c: Ctx, action: string) => Device;
  serverName: () => string;
}

/** Megabits a second, as the apps say it, in bytes a second, as the server keeps it. */
const BYTES_PER_MEGABIT = 125_000;
const MAX_MBPS = 10_000;
const MAX_DEVICES = 100;

/** A household as the apps see it. */
function shown(household: Household): Record<string, unknown> {
  return {
    id: household.id,
    name: household.name,
    owner: household.owner,
    scope: household.scope,
    maxMbps: household.bandwidth === null ? null : household.bandwidth / BYTES_PER_MEGABIT,
    allowOutside: household.allowOutside,
    maxDevices: household.maxDevices,
    requiresAdminApproval: household.requiresAdminApproval,
    paused: household.pausedAt !== null,
    pausedAt: household.pausedAt,
    createdAt: household.createdAt,
    devices: household.devices,
    managers: household.managers,
    viewers: household.viewers,
  };
}

function name(body: Record<string, unknown>): string {
  const value = body["name"];
  if (typeof value !== "string" || value.trim() === "" || value.trim().length > 60) {
    throw new ApiError("invalid_request", `"name" must be a name of at most 60 characters.`);
  }
  // As in a pairing request's name: nothing that could fool whoever reads it.
  return value
    .replace(/[\p{C}\p{Zl}\p{Zp}]/gu, "")
    .replace(/\s+/g, " ")
    .trim();
}

/** What the request says to change. What it leaves out stays. */
function change(body: Record<string, unknown>, before: Household | null): HouseholdChange {
  const result: HouseholdChange = {};
  if (body["name"] !== undefined) result.name = name(body);
  if (body["scope"] !== undefined)
    result.scope = kidsSettings(body["scope"], before?.scope ?? null);
  const mbps = body["maxMbps"];
  if (mbps !== undefined) {
    if (mbps !== null && (typeof mbps !== "number" || !(mbps > 0) || mbps > MAX_MBPS)) {
      throw new ApiError(
        "invalid_request",
        `"maxMbps" must be megabits a second, more than 0 and at most ${String(MAX_MBPS)}, or null.`,
      );
    }
    result.bandwidth = mbps === null ? null : Math.max(1, Math.round(mbps * BYTES_PER_MEGABIT));
  }
  for (const key of ["allowOutside", "paused", "requiresAdminApproval"] as const) {
    const value = body[key];
    if (value === undefined) continue;
    if (typeof value !== "boolean") {
      throw new ApiError("invalid_request", `"${key}" must be true or false.`);
    }
    result[key] = value;
  }
  const most = body["maxDevices"];
  if (most !== undefined) {
    if (
      most !== null &&
      (typeof most !== "number" || !Number.isInteger(most) || most < 1 || most > MAX_DEVICES)
    ) {
      throw new ApiError(
        "invalid_request",
        `"maxDevices" must be a whole number from 1 to ${String(MAX_DEVICES)}, or null.`,
      );
    }
    result.maxDevices = most;
  }
  return result;
}

/** What an invitation's device becomes: a household admin unless it says viewer. */
function inviteAccess(body: Record<string, unknown>): "householdAdmin" | "viewer" {
  const value = body["access"] ?? "householdAdmin";
  if (value !== "householdAdmin" && value !== "viewer") {
    throw new ApiError("invalid_request", `"access" must be "householdAdmin" or "viewer".`);
  }
  return value;
}

function hours(body: Record<string, unknown>): number {
  const value = body["inviteHours"] ?? DEFAULT_INVITE_HOURS;
  if (
    typeof value !== "number" ||
    !Number.isInteger(value) ||
    value < 1 ||
    value > MAX_INVITE_HOURS
  ) {
    throw new ApiError(
      "invalid_request",
      `"inviteHours" must be a whole number from 1 to ${String(MAX_INVITE_HOURS)}.`,
    );
  }
  return value;
}

/**
 * Sharing the server with other households (docs/api.md, Households). The owner's managers do
 * all of it, from home; every device can read its own household.
 */
export function registerHouseholdRoutes(app: Hono<AppEnv>, deps: HouseholdRouteDeps): void {
  const { households, devices, requireManager, requireHouseholdAdmin } = deps;

  const owner = (c: Ctx, action: string): Device => {
    const device = requireManager(c, action);
    // The household guard keeps these to the owner's household; this says it once more.
    if (device.householdId !== OWNER_HOUSEHOLD) {
      throw new ApiError("not_found", "There is nothing at this address.");
    }
    c.header("Cache-Control", "no-store");
    return device;
  };

  const found = (id: string): Household => {
    const household = households.find(id);
    if (!household) throw new ApiError("not_found", "There is no such household.");
    return household;
  };

  /** What devices are cut off from at once, wherever they are. */
  const recheck = (householdId: string): void => {
    deps.outside?.pairing.forget(householdId);
    deps.outside?.recheck();
    deps.remote?.recheck();
  };

  /** What a guest needs to come in: the code, and the link and QR code made of it. */
  const invitation = (
    invite: Invite,
    code: string,
    household: Household,
  ): Record<string, unknown> => {
    const introducer = deps.outside?.direct?.invitation.introducer ?? null;
    let link: string | null = null;
    if (introducer !== null) {
      // As URLComponents reads it: %20 for a space, never "+".
      const query = Object.entries({
        i: introducer,
        c: code,
        h: household.name,
        s: deps.serverName(),
      })
        .map(([key, value]) => `${key}=${encodeURIComponent(value)}`)
        .join("&");
      link = `lobby://pair?${query}`;
    }
    return { ...invite, code, introducer, link };
  };

  app.get("/v1/household", (c) => {
    const device = c.get("device");
    const household = found(device.householdId);
    // Its own, limits and all: whoever is in a household may know how it is shared with them.
    return c.json({ household: shown(household), serverName: deps.serverName() });
  });

  app.get("/v1/households", (c) => {
    owner(c, "see the households");
    return c.json({ households: households.list().map(shown) });
  });

  app.post("/v1/households", async (c) => {
    const by = owner(c, "invite a household");
    const body = await readBody(c);
    const wanted = change(body, null);
    const lasting = hours(body);
    const household = households.create(name(body), wanted);
    const made = await households.invites.create(household.id, by.id, lasting);
    log.info("A manager invited a household", { by: by.id, household: household.id });
    return c.json(
      { household: shown(household), invite: invitation(made.invite, made.code, household) },
      201,
    );
  });

  app.get("/v1/households/:id", (c) => {
    owner(c, "see the households");
    const household = found(c.req.param("id"));
    return c.json({
      household: shown(household),
      // What the owner is responsible for: which devices, not what they watch.
      devices: devices
        .list(household.id)
        .filter((one) => one.revokedAt === null)
        .map((one) => ({
          id: one.id,
          name: one.name,
          platform: one.platform,
          role: one.role,
          access: one.access,
          createdAt: one.createdAt,
          lastUsedAt: one.lastUsedAt,
          lastOutsideAt: one.lastOutsideAt,
        })),
      invites: households.invites.list(household.id),
    });
  });

  app.patch("/v1/households/:id", async (c) => {
    const by = owner(c, "change a household");
    const body = await readBody(c);
    const before = found(c.req.param("id"));
    const wanted = change(body, before);
    let after: Household;
    if (before.owner) {
      if (Object.keys(wanted).some((key) => key !== "name" && key !== "requiresAdminApproval")) {
        throw new ApiError("conflict", "The server's own household has no limits to change.");
      }
      after = households.changeOwn(before.id, wanted);
    } else {
      after = households.change(before.id, wanted);
    }
    recheck(after.id);
    log.info("A manager changed a household", { by: by.id, household: after.id });
    return c.json(shown(after));
  });

  app.delete("/v1/households/:id", (c) => {
    const by = owner(c, "remove a household");
    const household = found(c.req.param("id"));
    if (household.owner) {
      throw new ApiError("conflict", "The server's own household cannot be removed.");
    }
    households.remove(household.id);
    recheck(household.id);
    log.info("A manager removed a household", { by: by.id, household: household.id });
    return c.body(null, 204);
  });

  app.post("/v1/households/:id/invites", async (c) => {
    const by = owner(c, "invite a household");
    const body = await readBody(c);
    const household = found(c.req.param("id"));
    if (household.pausedAt !== null) {
      throw new ApiError("conflict", "This household is paused. Let it in again first.");
    }
    const made = await households.invites.create(
      household.id,
      by.id,
      hours(body),
      inviteAccess(body),
    );
    log.info("A manager invited a household", { by: by.id, household: household.id });
    return c.json(invitation(made.invite, made.code, household), 201);
  });

  // ---- A household admin invites into their own household ----

  app.get("/v1/household/invites", (c) => {
    const by = requireHouseholdAdmin(c, "see this household's invitations");
    c.header("Cache-Control", "no-store");
    return c.json({ invites: households.invites.list(by.householdId) });
  });

  app.post("/v1/household/invites", async (c) => {
    const by = requireHouseholdAdmin(c, "invite someone to this household");
    const body = await readBody(c);
    const household = found(by.householdId);
    const made = await households.invites.create(
      household.id,
      by.id,
      hours(body),
      inviteAccess(body),
    );
    log.info("A household admin invited a device", { by: by.id, household: household.id });
    c.header("Cache-Control", "no-store");
    return c.json(invitation(made.invite, made.code, household), 201);
  });

  app.delete("/v1/household/invites/:invite", (c) => {
    const by = requireHouseholdAdmin(c, "take back an invitation");
    const invite = households.invites.find(c.req.param("invite"));
    if (!invite || invite.householdId !== by.householdId) {
      throw new ApiError("not_found", "There is no such invitation.");
    }
    households.invites.revoke(invite.id);
    return c.body(null, 204);
  });

  app.delete("/v1/households/:id/invites/:invite", (c) => {
    owner(c, "take back an invitation");
    const household = found(c.req.param("id"));
    const invite = households.invites.find(c.req.param("invite"));
    if (!invite || invite.householdId !== household.id) {
      throw new ApiError("not_found", "There is no such invitation.");
    }
    households.invites.revoke(invite.id);
    return c.body(null, 204);
  });
}
