// SPDX-License-Identifier: MPL-2.0
import type { Hono } from "hono";
import type { Device, Devices } from "../auth/devices.ts";
import { ApiError, readBody, type AppEnv, type Ctx } from "../http/app.ts";
import { isNearby, peerAddress } from "../http/home.ts";
import { SettingsError, type SettingsService } from "../settings/service.ts";
import type { RemoteHub } from "./hub.ts";
import { MAX_MESSAGE, readId } from "./messages.ts";
import type {
  SpeakerAction,
  SpeakerAsker,
  SpeakerPlayRequest,
  SpeakerService,
} from "./speakers.ts";

interface SpeakerRouteDeps {
  speakers: SpeakerService;
  devices: Devices;
  settings: SettingsService | null;
  /** Who uses a session: a child in the kids screens of a grown-up's device is a child here too. */
  remote: RemoteHub | null;
  requireManager: (c: Ctx, action: string) => Device;
}

const MAX_BODY = 4 * 1024;
const MAX_TRACKS = 500;

const ACTIONS = ["pause", "resume", "stop", "next", "previous", "skip", "seek", "volume"] as const;

function optionalId(body: Record<string, unknown>, key: string): string | null {
  const value = body[key];
  return value === undefined || value === null ? null : readId(value, key);
}

function number(value: unknown, key: string, min: number, max: number): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < min || value > max) {
    throw new ApiError(
      "invalid_request",
      `"${key}" must be a number from ${String(min)} to ${String(max)}.`,
    );
  }
  return value;
}

function readPlay(body: Record<string, unknown>): SpeakerPlayRequest {
  const profileId = readId(body["profileId"], "profileId");
  const bookId = optionalId(body, "bookId");
  const albumId = optionalId(body, "albumId");
  const raw = body["trackIds"];
  let trackIds: string[] | null = null;
  if (raw !== undefined && raw !== null) {
    if (!Array.isArray(raw) || raw.length > MAX_TRACKS) {
      throw new ApiError(
        "invalid_request",
        `"trackIds" must be a list of at most ${String(MAX_TRACKS)} tracks.`,
      );
    }
    trackIds = raw.map((one, at) => readId(one, `trackIds[${String(at)}]`));
  }
  if ((bookId === null) === (trackIds === null)) {
    throw new ApiError("invalid_request", `Either "bookId" or "trackIds".`);
  }
  const index =
    body["index"] === undefined || body["index"] === null
      ? 0
      : number(body["index"], "index", 0, MAX_TRACKS - 1);
  const startMs =
    body["startMs"] === undefined || body["startMs"] === null
      ? null
      : number(body["startMs"], "startMs", 0, 7 * 24 * 3_600_000);
  return {
    profileId,
    trackIds,
    index: Math.floor(index),
    bookId,
    startMs: startMs === null ? null : Math.round(startMs),
    albumId,
  };
}

function readAction(body: Record<string, unknown>): SpeakerAction {
  const type = body["type"];
  const known = ACTIONS.find((one) => one === type);
  if (!known) {
    throw new ApiError("invalid_request", `"type" must be one of ${ACTIONS.join(", ")}.`);
  }
  switch (known) {
    case "skip":
      return {
        type: known,
        deltaMs: Math.round(number(body["deltaMs"], "deltaMs", -3_600_000, 3_600_000)),
      };
    case "seek":
      return {
        type: known,
        positionMs: Math.round(number(body["positionMs"], "positionMs", 0, 7 * 24 * 3_600_000)),
      };
    case "volume":
      return { type: known, volume: number(body["volume"], "volume", 0, 1) };
    default:
      return { type: known };
  }
}

/**
 * HomePods and other AirPlay speakers (docs/api.md, "Playing on a speaker"). On the app for
 * home only: the speakers are on the owner's network. Starting needs an address at home or in
 * the tailnet; the manager's routes too.
 */
export function registerSpeakerRoutes(app: Hono<AppEnv>, deps: SpeakerRouteDeps): void {
  const { speakers, devices, requireManager } = deps;

  const manager = (c: Ctx, action: string): Device => {
    const device = requireManager(c, action);
    const peer = peerAddress(c);
    if (peer !== null && !isNearby(peer)) {
      throw new ApiError("forbidden", "Speakers can only be set up at home or over Tailscale.");
    }
    c.header("Cache-Control", "no-store");
    return device;
  };

  /** The device that asks, as it is now, and who uses the session it names. */
  const asker = (c: Ctx, body: Record<string, unknown>): SpeakerAsker => {
    const before = c.get("device");
    const device = devices.find(before.id);
    if (!device || device.revokedAt !== null) {
      throw new ApiError("gone", "Open the live channel again.", { reason: "session" });
    }
    const session = readId(body["session"], "session");
    const hub = deps.remote;
    const kid = device.kidsProfileId ?? (hub ? hub.kidUsing(device.id, session, false) : null);
    const peer = peerAddress(c);
    return {
      device,
      profileId: hub?.inFront(device.id) ?? null,
      kid,
      nearby: peer === null || isNearby(peer),
    };
  };

  app.get("/v1/speakers", (c) => {
    manager(c, "see the speakers");
    return c.json(speakers.status());
  });

  app.patch("/v1/speakers", async (c) => {
    const body = await readBody(c, MAX_BODY);
    const device = manager(c, "turn speakers on or off");
    const enabled = body["enabled"];
    if (typeof enabled !== "boolean") {
      throw new ApiError("invalid_request", `"enabled" must be true or false.`);
    }
    if (!deps.settings) throw new ApiError("unavailable", "The settings cannot be changed here.");
    if (!speakers.status().configured) {
      throw new ApiError("not_found", "Speakers are not set up on this server.", {
        reason: "speakers_not_configured",
      });
    }
    try {
      await deps.settings.change(
        device.id,
        { "remote.wake.speakers": enabled },
        { dryRun: false, baseVersion: null },
      );
    } catch (error) {
      if (error instanceof SettingsError) throw new ApiError(error.code, error.message);
      throw error;
    }
    return c.json(speakers.status());
  });

  app.post("/v1/speakers/scan", async (c) => {
    const device = manager(c, "look for speakers");
    return c.json(await speakers.scanNow(device));
  });

  app.patch("/v1/speakers/:id", async (c) => {
    const body = await readBody(c, MAX_BODY);
    manager(c, "change a speaker");
    const change: { name?: string | null; hidden?: boolean } = {};
    if (body["name"] !== undefined) {
      const name = body["name"];
      if (name !== null && (typeof name !== "string" || name.trim() === "" || name.length > 60)) {
        throw new ApiError("invalid_request", `"name" must be 1 to 60 characters, or null.`);
      }
      change.name = name === null ? null : name.trim();
    }
    if (body["hidden"] !== undefined) {
      if (typeof body["hidden"] !== "boolean") {
        throw new ApiError("invalid_request", `"hidden" must be true or false.`);
      }
      change.hidden = body["hidden"];
    }
    if (Object.keys(change).length === 0) {
      throw new ApiError("invalid_request", `"name" or "hidden" is needed.`);
    }
    return c.json(await speakers.change(readId(c.req.param("id"), "id"), change));
  });

  app.put("/v1/speakers/:id/password", async (c) => {
    const body = await readBody(c, MAX_BODY);
    const device = manager(c, "change a speaker");
    const password = body["password"];
    if (
      password !== null &&
      (typeof password !== "string" || password === "" || password.length > 128)
    ) {
      throw new ApiError("invalid_request", `"password" must be 1 to 128 characters, or null.`);
    }
    return c.json(await speakers.setPassword(device, readId(c.req.param("id"), "id"), password));
  });

  // Any device of the owner's household that may play on others; a child only as itself, and
  // only while its plan lets it listen. The server plays it: the device can go.
  app.post("/v1/speakers/:id/play", async (c) => {
    const body = await readBody(c, MAX_MESSAGE);
    const who = asker(c, body);
    return c.json(await speakers.play(who, readId(c.req.param("id"), "id"), readPlay(body)));
  });

  app.post("/v1/speakers/:id/control", async (c) => {
    const body = await readBody(c, MAX_MESSAGE);
    const who = asker(c, body);
    return c.json(await speakers.control(who, readId(c.req.param("id"), "id"), readAction(body)));
  });
}
