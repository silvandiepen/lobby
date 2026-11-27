// SPDX-License-Identifier: MPL-2.0
import type { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import type { Device, Devices } from "../auth/devices.ts";
import { ApiError, readBody, type AppEnv, type Ctx } from "../http/app.ts";
import type { DeviceDownloads } from "./downloads.ts";
import {
  DownloadsError,
  MAX_RULE_COUNT,
  REPORT_ERRORS,
  REPORT_STATES,
  type ReportedDownload,
  type ReportError,
  type ReportState,
  type WantedInput,
} from "./wanted.ts";

export interface DeviceDownloadRouteDeps {
  downloads: DeviceDownloads;
  devices: Devices;
}

/** A report is a few hundred bytes per file. */
const MAX_REPORT_BYTES = 1024 * 1024;
const MAX_REPORTED_DOWNLOADS = 5000;
/** No phone or disk is larger than this (1 PiB), and it is far inside what JSON numbers hold exactly. */
const MAX_BYTES = 2 ** 50;
const ID = /^[A-Za-z0-9_-]{1,64}$/;

function invalid(message: string): never {
  throw new ApiError("invalid_request", message);
}

function id(value: unknown, name: string): string {
  if (typeof value !== "string" || !ID.test(value)) invalid(`"${name}" must be an id.`);
  return value;
}

function bytes(value: unknown, name: string): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0 || value > MAX_BYTES) {
    invalid(`"${name}" must be a whole number of bytes.`);
  }
  return value;
}

function optionalBytes(value: unknown, name: string): number | null {
  return value === undefined || value === null ? null : bytes(value, name);
}

function wantedInput(body: Record<string, unknown>): WantedInput {
  if (body["kind"] === "item") return { kind: "item", itemId: id(body["itemId"], "itemId") };
  if (body["kind"] === "next_unwatched") {
    const count = body["count"];
    if (
      typeof count !== "number" ||
      !Number.isInteger(count) ||
      count < 1 ||
      count > MAX_RULE_COUNT
    ) {
      invalid(`"count" must be a whole number from 1 to ${String(MAX_RULE_COUNT)}.`);
    }
    return {
      kind: "next_unwatched",
      showId: id(body["showId"], "showId"),
      profileId: id(body["profileId"], "profileId"),
      count,
    };
  }
  return invalid(`"kind" must be one of: item, next_unwatched.`);
}

function reportedDownload(value: unknown, seen: Set<string>): ReportedDownload {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    invalid(`Every entry of "downloads" must be an object.`);
  }
  const entry = value as Record<string, unknown>;
  const assetId = id(entry["assetId"], "assetId");
  if (seen.has(assetId)) invalid(`"downloads" names the file ${assetId} twice.`);
  seen.add(assetId);
  const revision = entry["revision"];
  if (typeof revision !== "string" || revision === "" || revision.length > 100) {
    invalid(`"revision" must be the revision the file was downloaded at.`);
  }
  const state = entry["state"];
  if (typeof state !== "string" || !REPORT_STATES.includes(state as ReportState)) {
    invalid(`"state" must be one of: ${REPORT_STATES.join(", ")}.`);
  }
  const error = entry["error"] ?? null;
  if (
    error !== null &&
    (typeof error !== "string" || !REPORT_ERRORS.includes(error as ReportError))
  ) {
    invalid(`"error" must be null or one of: ${REPORT_ERRORS.join(", ")}.`);
  }
  if (entry["own"] !== undefined && typeof entry["own"] !== "boolean") {
    invalid(`"own" must be true or false.`);
  }
  const bytesDone = bytes(entry["bytesDone"], "bytesDone");
  const bytesTotal = optionalBytes(entry["bytesTotal"], "bytesTotal");
  if (bytesTotal !== null && bytesDone > bytesTotal) {
    invalid(`"bytesDone" cannot be more than "bytesTotal".`);
  }
  return {
    assetId,
    revision,
    state: state as ReportState,
    bytesDone,
    bytesTotal,
    // An error only means something on a download that failed.
    error: state === "failed" ? ((error as ReportError | null) ?? "other") : null,
    own: entry["own"] === true,
  };
}

/**
 * Mounts the routes of "Downloads a manager puts on a device" in docs/api.md.
 * Call it after the middleware that sets the device and before the media routes:
 * it also notes every media request, so nothing is prepared ahead while someone watches.
 *
 * - Manager: `GET /v1/devices/wanted`, `GET|POST /v1/devices/:id/wanted`,
 *   `DELETE /v1/devices/:id/wanted/:wantedId`
 * - Any device, about itself only: `GET /v1/me/wanted`, `POST /v1/me/downloads`
 */
export function registerDeviceDownloadRoutes(
  app: Hono<AppEnv>,
  deps: DeviceDownloadRouteDeps,
): void {
  const { downloads, devices } = deps;

  const manager = (c: Ctx, action: string): Device => {
    const device = c.get("device");
    if (device.access === "viewer") {
      throw new ApiError("forbidden", `Only an admin of this household can ${action}.`);
    }
    return device;
  };

  const handle = async <T>(run: () => T | Promise<T>): Promise<T> => {
    try {
      return await run();
    } catch (error) {
      if (error instanceof DownloadsError) throw new ApiError(error.code, error.message);
      throw error;
    }
  };

  const describeDevice = (device: Device): Record<string, unknown> => ({
    id: device.id,
    name: device.name,
    platform: device.platform,
    role: device.role,
    lastSeenAt: device.lastUsedAt,
  });

  const paired = (deviceId: string): Device => {
    const device = devices
      .list()
      .find((candidate) => candidate.id === deviceId && candidate.revokedAt === null);
    if (!device) throw new ApiError("not_found", "There is no such device.");
    return device;
  };

  // Playing, downloading and asking for playback all count as someone using the server.
  app.use("/v1/assets/*", async (_c, next) => {
    downloads.ahead?.noteActivity();
    await next();
  });

  app.get("/v1/devices/wanted", (c) => {
    const by = manager(c, "see what is on other devices");
    return c.json({
      devices: devices
        .list(by.householdId)
        .filter((device) => device.revokedAt === null)
        .map((device) => ({ ...describeDevice(device), ...downloads.summary(device.id) })),
    });
  });

  app.get("/v1/devices/:id/wanted", (c) =>
    handle(() => {
      manager(c, "see what is on other devices");
      const device = paired(c.req.param("id"));
      return c.json({ device: describeDevice(device), ...downloads.overview(device.id) });
    }),
  );

  app.post("/v1/devices/:id/wanted", (c) =>
    handle(async () => {
      const by = manager(c, "decide what is on a device");
      const device = paired(c.req.param("id"));
      const result = downloads.add(device.id, wantedInput(await readBody(c)), by.id);
      return c.json({ entry: result.entry }, result.created ? 201 : 200);
    }),
  );

  app.delete("/v1/devices/:id/wanted/:wantedId", (c) =>
    handle(() => {
      manager(c, "decide what is on a device");
      const device = paired(c.req.param("id"));
      if (!downloads.remove(device.id, c.req.param("wantedId"))) {
        throw new ApiError("not_found", "That is not on this device's list.");
      }
      return c.body(null, 204);
    }),
  );

  // ---- A device about itself. The device comes from the credential, never from the request. ----

  app.get("/v1/me/wanted", (c) => {
    const list = downloads.list(c.get("device").id);
    const etag = `"${list.revision}"`;
    c.header("ETag", etag);
    c.header("Cache-Control", "private, no-cache");
    if (c.req.header("If-None-Match") === etag) return c.body(null, 304);
    return c.json(list);
  });

  app.post(
    "/v1/me/downloads",
    bodyLimit({
      maxSize: MAX_REPORT_BYTES,
      onError: () => invalid("The report is too large."),
    }),
    async (c) => {
      const device = c.get("device");
      const body = await readBody(c);
      const list = body["downloads"];
      if (!Array.isArray(list) || list.length > MAX_REPORTED_DOWNLOADS) {
        invalid(`"downloads" must be a list of at most ${String(MAX_REPORTED_DOWNLOADS)} files.`);
      }
      const seen = new Set<string>();
      const reported = list.map((entry) => reportedDownload(entry, seen));
      const freeBytes = optionalBytes(body["freeBytes"], "freeBytes");
      const totalBytes = optionalBytes(body["totalBytes"], "totalBytes");
      if (freeBytes !== null && totalBytes !== null && freeBytes > totalBytes) {
        invalid(`"freeBytes" cannot be more than "totalBytes".`);
      }
      downloads.report(device.id, { freeBytes, totalBytes, downloads: reported });
      return c.json({
        accepted: reported.length,
        wantedRevision: downloads.list(device.id).revision,
      });
    },
  );
}
