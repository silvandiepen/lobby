// SPDX-License-Identifier: MPL-2.0
import type { Hono } from "hono";
import type { Devices } from "../auth/devices.ts";
import { ApiError, readBody, type AppEnv, type Ctx } from "../http/app.ts";
import type { RemoteHub } from "./hub.ts";
import {
  MAX_MESSAGE,
  readAnnouncement,
  readCommandRequest,
  readId,
  readResult,
} from "./messages.ts";

interface RemoteRouteDeps {
  hub: RemoteHub;
  devices: Devices;
  outside: boolean;
}

/** Playing on another device: one long answer with what happens, and posts to say something. */
export function registerRemoteRoutes(app: Hono<AppEnv>, deps: RemoteRouteDeps): void {
  const { hub, devices, outside } = deps;

  /** The device as it is after the wait for a body: it may be removed or limited by then. */
  const current = (c: Ctx): { deviceId: string; kidsProfileId: string | null } => {
    const before = c.get("device");
    const device = devices.find(before.id);
    if (!device || device.revokedAt !== null || (outside && !device.allowOutside)) {
      throw new ApiError("gone", "Open the live channel again.", { reason: "session" });
    }
    return { deviceId: device.id, kidsProfileId: device.kidsProfileId };
  };

  app.get("/v1/live", (c) => {
    // HEAD comes here too, and has no body to keep open.
    if (c.req.method !== "GET") return c.body(null, 405, { Allow: "GET" });
    const last = c.req.query("last") ?? c.req.header("Last-Event-ID") ?? null;
    const stream = hub.open(
      c.get("device").id,
      readId(c.req.query("session"), "session"),
      outside,
      last,
    );
    return c.body(stream, 200, {
      "Content-Type": "text/event-stream; charset=UTF-8",
      "Cache-Control": "no-store",
      "X-Accel-Buffering": "no",
    });
  });

  app.post("/v1/live/:session", async (c) => {
    const body = await readBody(c, MAX_MESSAGE);
    const { deviceId } = current(c);
    return c.json(
      hub.announce(
        deviceId,
        readId(c.req.param("session"), "session"),
        outside,
        readAnnouncement(body, hub.time()),
      ),
    );
  });

  app.post("/v1/live/:session/results", async (c) => {
    const body = await readBody(c, MAX_MESSAGE);
    const { deviceId } = current(c);
    hub.result(
      deviceId,
      readId(c.req.param("session"), "session"),
      outside,
      readResult(body, hub.time()),
    );
    return c.body(null, 204);
  });

  app.post("/v1/remote/commands", async (c) => {
    const body = await readBody(c, MAX_MESSAGE);
    // A child's device too: the hub lets it start only what it may see, as itself, and control
    // only what plays as itself.
    const { deviceId } = current(c);
    return c.json(hub.command(deviceId, outside, readCommandRequest(body)), 202);
  });

  app.patch("/v1/me", async (c) => {
    const body = await readBody(c, MAX_MESSAGE);
    const { deviceId, kidsProfileId } = current(c);
    if (kidsProfileId !== null) {
      throw new ApiError("not_found", "There is nothing here for this device.");
    }
    const isTarget = body["isTarget"];
    if (isTarget !== null && typeof isTarget !== "boolean") {
      throw new ApiError("invalid_request", `"isTarget" must be true, false or null.`);
    }
    const device = devices.setRemote(deviceId, { isTarget });
    hub.recheck();
    return c.json(device);
  });
}
