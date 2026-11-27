// SPDX-License-Identifier: MPL-2.0
import type { Hono } from "hono";
import type { Database } from "../db/database.ts";
import { ApiError, readBody, type AppEnv, type Ctx } from "../http/app.ts";
import { MarkerError, type MarkerService } from "./service.ts";
import {
  markerDetails,
  markersFor,
  setManual,
  type ManualMarker,
  type MarkerKind,
} from "./store.ts";

export type { MarkerService } from "./service.ts";

export interface MarkerRouteDeps {
  db: Database;
  markers: MarkerService;
  now: () => number;
}

/** The longest a file is taken to be, for a time a manager sends: a day. */
const MAX_MS = 24 * 3_600_000;

function invalid(message: string): never {
  throw new ApiError("invalid_request", message);
}

function milliseconds(value: unknown, name: string): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0 || value > MAX_MS) {
    invalid(`"${name}" must be whole milliseconds from the start of the file.`);
  }
  return value;
}

/** A time a manager sends: an object, null for "there is none", left out to keep it as it is. */
function manual(body: Record<string, unknown>, kind: "intro" | "credits"): ManualMarker | "keep" {
  if (!(kind in body)) return "keep";
  const value = body[kind];
  if (value === null) return null;
  if (typeof value !== "object" || Array.isArray(value)) {
    invalid(`"${kind}" must be an object or null.`);
  }
  const marker = value as Record<string, unknown>;
  const startMs = milliseconds(marker["startMs"], `${kind}.startMs`);
  if (kind === "credits") return { startMs, endMs: null };
  const endMs = milliseconds(marker["endMs"], "intro.endMs");
  if (endMs <= startMs) invalid(`"intro.endMs" must be after "intro.startMs".`);
  return { startMs, endMs };
}

/**
 * Mounts "Intros and credits" in docs/api.md: what the background job is doing, a file's markers
 * as each source says them, setting them by hand, and looking at a season again. For server
 * admins: the markers are of the library that every household shares.
 */
export function registerMarkerRoutes(app: Hono<AppEnv>, deps: MarkerRouteDeps): void {
  const { db, markers, now } = deps;

  const admin = (c: Ctx, action: string): void => {
    if (c.get("device").access !== "admin") {
      throw new ApiError("forbidden", `Only a server admin can ${action}.`);
    }
  };

  const asset = (id: string): { id: string; durationMs: number | null } => {
    const row = db.get<{ id: string; duration_ms: number | null }>(
      "select id, duration_ms from asset where id = ?",
      [id],
    );
    if (!row) throw new ApiError("not_found", "There is no such file.");
    return { id: row.id, durationMs: row.duration_ms };
  };

  const describe = (assetId: string): Record<string, unknown> => {
    const scan = db.get<{
      chapters_at: number | null;
      printed_at: number | null;
      matched_at: number | null;
      requested_at: number | null;
      failures: number;
      reason: string | null;
    }>("select * from marker_scan where asset_id = ?", [assetId]);
    return {
      assetId,
      markers: markersFor(db, [assetId]).get(assetId) ?? { intro: null, credits: null },
      sources: markerDetails(db, assetId),
      scan: scan
        ? {
            chaptersRead: scan.chapters_at !== null,
            compared: scan.matched_at !== null,
            requested: scan.requested_at !== null,
            failures: scan.failures,
            reason: scan.reason,
          }
        : null,
    };
  };

  app.get("/v1/markers", (c) => {
    admin(c, "see how intros are found");
    return c.json(markers.status());
  });

  app.get("/v1/markers/assets/:id", (c) => {
    admin(c, "see where intros are");
    return c.json(describe(asset(c.req.param("id")).id));
  });

  app.put("/v1/markers/assets/:id", async (c) => {
    admin(c, "set where intros are");
    const body = await readBody(c);
    const file = asset(c.req.param("id"));
    const intro = manual(body, "intro");
    const credits = manual(body, "credits");
    for (const [name, marker] of [
      ["intro", intro],
      ["credits", credits],
    ] as const) {
      if (
        marker &&
        marker !== "keep" &&
        file.durationMs !== null &&
        marker.startMs >= file.durationMs
      ) {
        invalid(`"${name}.startMs" is past the end of the file.`);
      }
    }
    db.transaction(() => {
      if (intro !== "keep") setManual(db, file.id, "intro", intro, now());
      if (credits !== "keep") setManual(db, file.id, "credits", credits, now());
    });
    markers.changed(file.id);
    return c.json(describe(file.id));
  });

  // Back to what the chapters say or what was found.
  app.delete("/v1/markers/assets/:id", (c) => {
    admin(c, "set where intros are");
    const file = asset(c.req.param("id"));
    const kind = c.req.query("kind");
    let kinds: MarkerKind[] = ["intro", "credits"];
    if (kind === "intro" || kind === "credits") kinds = [kind];
    else if (kind !== undefined) invalid(`"kind" must be intro or credits.`);
    db.transaction(() => {
      for (const one of kinds) {
        setManual(db, file.id, one, undefined, now());
      }
    });
    markers.changed(file.id);
    return c.json(describe(file.id));
  });

  app.post("/v1/markers/items/:id/detect", (c) => {
    admin(c, "have intros found");
    try {
      const files = markers.request(c.req.param("id"));
      return c.json({ files, status: markers.status() }, 202);
    } catch (error) {
      if (error instanceof MarkerError) throw new ApiError(error.code, error.message);
      throw error;
    }
  });
}
