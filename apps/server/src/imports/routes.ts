// SPDX-License-Identifier: MPL-2.0
import type { Hono } from "hono";
import type { Device } from "../auth/devices.ts";
import type { ConversionService } from "../conversion/index.ts";
import { ConversionError } from "../conversion/index.ts";
import type { Database } from "../db/database.ts";
import { ApiError, readBody, type AppEnv, type Ctx } from "../http/app.ts";
import { isNearby, peerAddress } from "../http/home.ts";
import { RateLimiter } from "../outside/limits.ts";
import type { RootConfig } from "../config.ts";
import { ImportError, type Decision, type ImportService, type ItemState } from "./service.ts";
import { UploadConflict, type UploadService } from "./uploads.ts";

export interface ImportRouteDeps {
  db: Database;
  imports: ImportService;
  uploads: UploadService;
  conversion?: ConversionService;
  roots: () => RootConfig[];
  settings: () => {
    waitMinutes: number;
    copyAcrossDrives: boolean;
    maxFileGb: number;
    quotaGb: number;
  };
  requireManager: (c: Ctx, action: string) => Device;
  now?: () => number;
}

/** A piece of an upload. Apps send 64 MB; a background task on iOS sends one piece per task. */
export const MAX_PIECE_BYTES = 256 * 1024 * 1024;

export const UPLOAD_RATES = {
  create: { burst: 200, perMinute: 120 },
  change: { burst: 60, perMinute: 60 },
} as const;

const VIEWS: Record<string, ItemState[]> = {
  inbox: ["inbox", "failed"],
  waiting: ["waiting", "moving"],
  ignored: ["ignored", "dismissed"],
  done: ["imported", "listed"],
  all: ["waiting", "inbox", "moving", "imported", "listed", "ignored", "failed", "dismissed"],
};

function translate(error: unknown): never {
  if (error instanceof UploadConflict) {
    throw new ApiError("conflict", error.message, { offset: error.offset });
  }
  if (error instanceof ImportError) throw new ApiError(error.code, error.message);
  if (error instanceof ConversionError) throw new ApiError(error.code, error.message, error.extra);
  throw error;
}

async function handle<T>(run: () => T | Promise<T>): Promise<T> {
  try {
    return await run();
  } catch (error) {
    translate(error);
  }
}

function invalid(message: string): never {
  throw new ApiError("invalid_request", message);
}

function optionalNumber(body: Record<string, unknown>, key: string): number | null {
  const value = body[key] ?? null;
  if (value === null) return null;
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0 || value > 9999) {
    invalid(`"${key}" must be a whole number.`);
  }
  return value;
}

/**
 * Import folders, the Inbox and uploads (docs/api.md, Imports and uploads). For managers at home
 * or in the tailnet: the outside entrance has none of these routes (docs/decisions.md, "Import folders and uploads").
 */
export function registerImportRoutes(app: Hono<AppEnv>, deps: ImportRouteDeps): void {
  const { imports, uploads, requireManager } = deps;
  const now = deps.now ?? Date.now;
  const limits = {
    create: new RateLimiter(UPLOAD_RATES.create, now),
    change: new RateLimiter(UPLOAD_RATES.change, now),
  };

  const manager = (c: Ctx, action: string, rate: keyof typeof limits | null = null): Device => {
    const device = requireManager(c, action);
    const peer = peerAddress(c);
    if (peer !== null && !isNearby(peer)) {
      throw new ApiError("forbidden", "Uploading and importing work at home or over Tailscale.");
    }
    if (rate !== null) {
      const wait = limits[rate].take(device.id);
      if (wait > 0) {
        c.header("Retry-After", String(wait));
        throw new ApiError("rate_limited", "That was a lot at once. Try again in a moment.");
      }
    }
    c.header("Cache-Control", "no-store");
    return device;
  };

  app.get("/v1/imports", (c) =>
    handle(async () => {
      manager(c, "see the imports");
      const status = await imports.status();
      const destinations = deps
        .roots()
        .filter((root) => root.hint !== "personal")
        .map((root) => ({ path: root.path, name: root.name, hint: root.hint }));
      return c.json({ ...status, destinations, settings: deps.settings() });
    }),
  );

  app.get("/v1/imports/items", (c) =>
    handle(() => {
      manager(c, "see the imports");
      const view = c.req.query("view") ?? "inbox";
      const states = VIEWS[view];
      if (!states) invalid(`"view" must be one of: ${Object.keys(VIEWS).join(", ")}.`);
      const limit = Number(c.req.query("limit") ?? "200");
      if (!Number.isInteger(limit) || limit < 1 || limit > 1000) {
        invalid(`"limit" must be a whole number from 1 to 1000.`);
      }
      return c.json({ items: imports.items(states, limit) });
    }),
  );

  app.get("/v1/imports/items/:id", (c) =>
    handle(() => {
      manager(c, "see the imports");
      return c.json({ item: imports.item(c.req.param("id")) });
    }),
  );

  app.post("/v1/imports/items/:id/confirm", (c) =>
    handle(async () => {
      const device = manager(c, "import files", "change");
      const body = await readBody(c);
      const action = body["action"] ?? "move";
      if (action !== "move" && action !== "list") invalid(`"action" must be move or list.`);
      const kind = body["kind"] ?? null;
      if (action === "move" && kind !== "movie" && kind !== "episode") {
        invalid(`"kind" must be movie or episode.`);
      }
      const title = body["title"] ?? null;
      if (
        action === "move" &&
        (typeof title !== "string" || title.trim() === "" || title.length > 200)
      ) {
        invalid(`"title" must be the title, at most 200 characters.`);
      }
      const episodeTitle = body["episodeTitle"] ?? null;
      if (
        episodeTitle !== null &&
        (typeof episodeTitle !== "string" || episodeTitle.length > 200)
      ) {
        invalid(`"episodeTitle" must be text of at most 200 characters.`);
      }
      const destination = body["destination"] ?? null;
      if (destination !== null && typeof destination !== "string") {
        invalid(`"destination" must be a library folder's path, or null.`);
      }
      const decision: Decision = {
        action,
        ...(kind === "movie" || kind === "episode" ? { kind } : {}),
        ...(typeof title === "string" ? { title } : {}),
        year: optionalNumber(body, "year"),
        season: optionalNumber(body, "season"),
        episode: optionalNumber(body, "episode"),
        episodeTitle: episodeTitle,
        destination: destination,
      };
      return c.json({ item: await imports.confirm(c.req.param("id"), device.id, decision) });
    }),
  );

  app.post("/v1/imports/items/:id/dismiss", (c) =>
    handle(async () => {
      const device = manager(c, "import files", "change");
      return c.json({ item: await imports.dismiss(c.req.param("id"), device.id) });
    }),
  );

  app.post("/v1/imports/items/:id/clean-up", (c) =>
    handle(async () => {
      const device = manager(c, "remove what was left", "change");
      // Deleting is never implied: the request says it in so many words.
      if ((await readBody(c))["confirm"] !== "delete leftovers") {
        invalid(`To delete what was left, send { "confirm": "delete leftovers" }.`);
      }
      return c.json({ item: await imports.cleanUp(c.req.param("id"), device.id) });
    }),
  );

  app.post("/v1/imports/items/:id/convert", (c) =>
    handle(async () => {
      const device = manager(c, "have files converted", "change");
      const conversion = deps.conversion;
      if (!conversion?.enabled) throw new ApiError("unavailable", "Converting is not set up.");
      const place = imports.assetPathOf(c.req.param("id"));
      if (!place) throw new ApiError("conflict", "It is not in the library yet.");
      const found = deps.db.get<{ item_id: string }>(
        `select item_asset.item_id from asset
           join source on source.id = asset.source_id
           join item_asset on item_asset.asset_id = asset.id
         where source.path || '/' || asset.rel_path = ? and item_asset.role = 'main' limit 1`,
        [place.path],
      );
      if (!found)
        throw new ApiError("conflict", "The library has not read it yet. Try again in a minute.");
      return c.json(
        await conversion.enqueue({ kind: "item", itemId: found.item_id }, device.id),
        201,
      );
    }),
  );

  app.get("/v1/imports/activity", (c) =>
    handle(() => {
      manager(c, "see the imports");
      const limit = Number(c.req.query("limit") ?? "100");
      if (!Number.isInteger(limit) || limit < 1 || limit > 500) {
        invalid(`"limit" must be a whole number from 1 to 500.`);
      }
      return c.json({ entries: imports.activityLog(limit) });
    }),
  );

  app.post("/v1/imports/scan", (c) =>
    handle(async () => {
      manager(c, "look through the import folders", "change");
      await imports.scanNow();
      return c.json(await imports.status());
    }),
  );

  // ---- Uploads ----

  app.get("/v1/uploads", (c) =>
    handle(async () => {
      manager(c, "see the uploads");
      return c.json({ uploads: await uploads.list() });
    }),
  );

  app.post("/v1/uploads", (c) =>
    handle(async () => {
      const device = manager(c, "upload files", "create");
      const body = await readBody(c);
      const { upload, created } = await uploads.create(device.id, {
        relPath: body["relPath"],
        sizeBytes: body["sizeBytes"],
        sha256: body["sha256"],
        destination: body["destination"],
        batch: body["batch"],
      });
      return c.json({ upload, url: `/v1/uploads/${upload.id}` }, created ? 201 : 200, {
        "Upload-Offset": String(upload.receivedBytes),
        "Upload-Length": String(upload.sizeBytes),
      });
    }),
  );

  // Also answers HEAD, with the offset in the headers alone.
  app.get("/v1/uploads/:id", (c) =>
    handle(async () => {
      const device = manager(c, "upload files");
      const { upload, offset } = await uploads.offset(c.req.param("id"), device.id);
      return c.json({ upload, offset }, 200, {
        "Upload-Offset": String(offset),
        "Upload-Length": String(upload.sizeBytes),
      });
    }),
  );

  app.patch("/v1/uploads/:id", (c) =>
    handle(async () => {
      const device = manager(c, "upload files");
      const offset = Number(c.req.header("Upload-Offset"));
      if (!Number.isSafeInteger(offset) || offset < 0) {
        invalid(`The "Upload-Offset" header must say where this piece starts.`);
      }
      const length = Number(c.req.header("Content-Length"));
      if (!Number.isSafeInteger(length) || length <= 0 || length > MAX_PIECE_BYTES) {
        invalid(`A piece must say its length and be at most ${String(MAX_PIECE_BYTES)} bytes.`);
      }
      // tus's checksum extension: "sha256 <base64 of the piece's hash>".
      const checksumHeader = c.req.header("Upload-Checksum") ?? null;
      let checksum: string | null = null;
      if (checksumHeader !== null) {
        const match = /^sha256 ([A-Za-z0-9+/]{43}=)$/.exec(checksumHeader.trim());
        if (!match?.[1])
          invalid(`"Upload-Checksum" must be "sha256 " and the piece's hash in base64.`);
        checksum = match[1];
      }
      const body = c.req.raw.body;
      if (!body) invalid("The piece is empty.");
      const next = await uploads.chunk(
        c.req.param("id"),
        device.id,
        offset,
        length,
        checksum,
        body,
      );
      return c.body(null, 204, { "Upload-Offset": String(next) });
    }),
  );

  app.post("/v1/uploads/:id/complete", (c) =>
    handle(async () => {
      const device = manager(c, "upload files");
      const body = await readBody(c);
      const upload = await uploads.complete(c.req.param("id"), device.id, body["sha256"]);
      return c.json({ upload }, upload.state === "done" ? 200 : 202);
    }),
  );

  app.delete("/v1/uploads/:id", (c) =>
    handle(async () => {
      const device = manager(c, "upload files");
      return c.json({ upload: await uploads.cancel(c.req.param("id"), device.id) });
    }),
  );
}
