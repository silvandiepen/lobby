// SPDX-License-Identifier: MPL-2.0
import type { Hono } from "hono";
import type { Device } from "../auth/devices.ts";
import { ApiError, readBody, type AppEnv, type Ctx } from "../http/app.ts";
import type { ConversionKind } from "./convert.ts";
import { ConversionError, type ConversionService } from "./service.ts";
import type { Scope } from "./store.ts";

export interface ConversionRouteDeps {
  conversion: ConversionService;
}

const ID = /^[A-Za-z0-9_-]{1,64}$/;
const KINDS: readonly ConversionKind[] = ["h264", "hevc", "repackage"];
/** One piece of an upload. A Mac sends a film in pieces of a few megabytes. */
const MAX_CHUNK_BYTES = 64 * 1024 * 1024;

function invalid(message: string): never {
  throw new ApiError("invalid_request", message);
}

function id(value: unknown, name: string): string {
  if (typeof value !== "string" || !ID.test(value)) invalid(`"${name}" must be an id.`);
  return value;
}

function scopeOf(body: Record<string, unknown>): Scope {
  const scope = body["scope"];
  if (scope === "item") return { kind: "item", itemId: id(body["itemId"], "itemId") };
  if (scope === "category") {
    return { kind: "category", categoryId: id(body["categoryId"], "categoryId") };
  }
  if (scope === "old") return { kind: "old" };
  return invalid(`"scope" must be one of: item, category, old.`);
}

/**
 * Mounts the routes of "Converting files" in docs/api.md. All of them are for
 * managers: a viewer device gets 403 on every one. Call it after the middleware
 * that sets the device and before the media routes, because it also notes media
 * requests: the server does not convert while someone watches, and does not
 * replace a title that was just played.
 */
export function registerConversionRoutes(app: Hono<AppEnv>, deps: ConversionRouteDeps): void {
  const { conversion } = deps;

  const manager = (c: Ctx, action: string): Device => {
    const device = c.get("device");
    if (device.access !== "admin") {
      throw new ApiError("forbidden", `Only a server admin can ${action}.`);
    }
    return device;
  };

  const handle = async <T>(run: () => T | Promise<T>): Promise<T> => {
    try {
      return await run();
    } catch (error) {
      if (error instanceof ConversionError) {
        throw new ApiError(error.code, error.message, error.extra);
      }
      throw error;
    }
  };

  app.use("/v1/assets/:id/*", async (c, next) => {
    // A Mac fetching an original to convert it is not someone watching it.
    if (c.req.header("X-Lobby-Purpose") !== "convert" || c.get("device").access !== "admin") {
      conversion.noteActivity(c.req.param("id"));
    }
    await next();
  });

  app.get("/v1/conversion", (c) =>
    handle(async () => {
      manager(c, "see what is being converted");
      return c.json(await conversion.status());
    }),
  );

  app.post("/v1/conversion/jobs", (c) =>
    handle(async () => {
      const by = manager(c, "have files converted");
      return c.json(await conversion.enqueue(scopeOf(await readBody(c)), by.id), 201);
    }),
  );

  app.post("/v1/conversion/pause", (c) =>
    handle(async () => {
      manager(c, "pause converting");
      conversion.setPaused(true);
      return c.json(await conversion.status());
    }),
  );

  app.post("/v1/conversion/resume", (c) =>
    handle(async () => {
      manager(c, "resume converting");
      conversion.setPaused(false);
      return c.json(await conversion.status());
    }),
  );

  app.delete("/v1/conversion/jobs/:id", (c) =>
    handle(async () => {
      manager(c, "cancel a conversion");
      return c.json({ job: await conversion.cancel(c.req.param("id")) });
    }),
  );

  app.post("/v1/conversion/jobs/:id/move", (c) =>
    handle(async () => {
      manager(c, "change the order of conversions");
      const to = (await readBody(c))["to"];
      if (to !== "top" && to !== "bottom") invalid(`"to" must be one of: top, bottom.`);
      return c.json({ job: conversion.move(c.req.param("id"), to) });
    }),
  );

  // ---- A Mac that takes jobs. A paired manager device only. ----

  app.post("/v1/conversion/claim", (c) =>
    handle(async () => {
      const device = manager(c, "convert files for the server");
      const body = await readBody(c);
      const kinds = body["kinds"] ?? KINDS;
      if (
        !Array.isArray(kinds) ||
        kinds.length === 0 ||
        kinds.some((kind) => !KINDS.includes(kind as ConversionKind))
      ) {
        invalid(`"kinds" must list some of: ${KINDS.join(", ")}.`);
      }
      const claimed = await conversion.claim(device.id, kinds as ConversionKind[]);
      if (!claimed) return c.body(null, 204);
      const { job, target, asset } = claimed;
      const assetId = encodeURIComponent(asset.id);
      return c.json({
        job,
        original: {
          assetId: asset.id,
          // Fetch it with Range requests, and with the header "X-Lobby-Purpose: convert".
          url: `/v1/assets/${assetId}/content`,
          bytes: asset.size,
          durationMs: asset.probe.durationMs,
          container: asset.probe.container,
          tracks: asset.probe.tracks,
        },
        target,
        uploadUrl: `/v1/conversion/jobs/${job.id}/upload`,
      });
    }),
  );

  app.post("/v1/conversion/jobs/:id/heartbeat", (c) =>
    handle(async () => {
      const device = manager(c, "convert files for the server");
      const progress = (await readBody(c))["progress"];
      if (typeof progress !== "number" || !Number.isFinite(progress)) {
        invalid(`"progress" must be a number from 0 to 1.`);
      }
      return c.json({ job: conversion.heartbeat(c.req.param("id"), device.id, progress) });
    }),
  );

  // Also answers HEAD, with the offset in the header alone.
  app.get("/v1/conversion/jobs/:id/upload", (c) =>
    handle(async () => {
      const device = manager(c, "convert files for the server");
      const offset = await conversion.uploadOffset(c.req.param("id"), device.id);
      return c.json({ offset }, 200, {
        "Upload-Offset": String(offset),
        "Cache-Control": "no-store",
      });
    }),
  );

  app.patch("/v1/conversion/jobs/:id/upload", (c) =>
    handle(async () => {
      const device = manager(c, "convert files for the server");
      const offset = Number(c.req.header("Upload-Offset"));
      if (!Number.isSafeInteger(offset) || offset < 0) {
        invalid(`The "Upload-Offset" header must say where this piece starts.`);
      }
      const length = Number(c.req.header("Content-Length"));
      if (!Number.isSafeInteger(length) || length <= 0 || length > MAX_CHUNK_BYTES) {
        invalid(`A piece must say its length and be at most ${String(MAX_CHUNK_BYTES)} bytes.`);
      }
      const body = c.req.raw.body;
      if (!body) invalid("The piece is empty.");
      // The declared length is enforced while reading, not trusted.
      let read = 0;
      const bounded = (async function* (): AsyncGenerator<Uint8Array> {
        for await (const chunk of body as unknown as AsyncIterable<Uint8Array>) {
          read += chunk.length;
          if (read > length) invalid("The piece is longer than it said.");
          yield chunk;
        }
      })();
      const next = await conversion.uploadChunk(c.req.param("id"), device.id, offset, bounded);
      return c.body(null, 204, { "Upload-Offset": String(next) });
    }),
  );

  app.post("/v1/conversion/jobs/:id/complete", (c) =>
    handle(async () => {
      const device = manager(c, "convert files for the server");
      const body = await readBody(c);
      const size = body["sizeBytes"];
      if (typeof size !== "number" || !Number.isSafeInteger(size) || size <= 0) {
        invalid(`"sizeBytes" must be the size of the result.`);
      }
      const sha256 = body["sha256"] ?? null;
      if (sha256 !== null && (typeof sha256 !== "string" || !/^[0-9a-fA-F]{64}$/.test(sha256))) {
        invalid(`"sha256" must be the result's SHA-256 in hex.`);
      }
      return c.json(
        {
          job: await conversion.complete(c.req.param("id"), device.id, {
            sizeBytes: size,
            sha256: sha256,
          }),
        },
        202,
      );
    }),
  );

  app.post("/v1/conversion/jobs/:id/release", (c) =>
    handle(async () => {
      const device = manager(c, "convert files for the server");
      return c.json({ job: await conversion.release(c.req.param("id"), device.id) });
    }),
  );

  // ---- What was replaced ----

  app.get("/v1/conversion/replacements", (c) =>
    handle(() => {
      manager(c, "see what was replaced");
      return c.json({ replacements: conversion.replacements() });
    }),
  );

  app.post("/v1/conversion/replacements/:id/undo", (c) =>
    handle(async () => {
      manager(c, "undo a replacement");
      return c.json({ replacement: await conversion.undo(c.req.param("id")) });
    }),
  );

  app.post("/v1/conversion/replacements/:id/purge", (c) =>
    handle(async () => {
      manager(c, "delete an original for good");
      // Deleting is never implied: the request has to say it in so many words.
      if ((await readBody(c))["confirm"] !== "delete for good") {
        invalid(`To delete for good, send { "confirm": "delete for good" }.`);
      }
      return c.json({ replacement: await conversion.purge(c.req.param("id")) });
    }),
  );
}
