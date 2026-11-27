// SPDX-License-Identifier: MPL-2.0
import type { Database } from "../db/database.ts";
import { MIN_CONFIDENCE } from "./match.ts";

/** Raised when what is found or compared changes; files found by an older one are done again. */
export const DETECTOR = 1;

export type MarkerKind = "intro" | "credits";
export type MarkerSource = "manual" | "chapters" | "detected";

/** Where a file's intro and credits are, as the apps get them (docs/api.md, Library). */
export interface ApiMarkers {
  intro: { startMs: number; endMs: number; source: MarkerSource } | null;
  credits: { startMs: number; source: MarkerSource } | null;
}

interface MarkerRow {
  asset_id: string;
  kind: MarkerKind;
  source: MarkerSource;
  start_ms: number | null;
  end_ms: number | null;
  confidence: number;
  detector: number | null;
  asset_revision: string | null;
  updated_at: number;
  revision: string;
}

const ORDER: Record<MarkerSource, number> = { manual: 0, chapters: 1, detected: 2 };

/** What each of the sources says of one file, for a manager. */
export interface MarkerDetail {
  kind: MarkerKind;
  source: MarkerSource;
  /** Null for a manual "there is none". */
  startMs: number | null;
  endMs: number | null;
  confidence: number;
  /** False when it was read from an older version of the file, or is not sure enough to show. */
  used: boolean;
  updatedAt: number;
}

function usable(row: MarkerRow): boolean {
  if (row.source === "manual") return true;
  if (row.asset_revision !== row.revision) return false;
  return row.source === "chapters" || row.confidence >= MIN_CONFIDENCE;
}

/**
 * The markers of these files: manual before chapters before detected; a detected one only when
 * it is sure enough, and none from an older version of the file.
 */
export function markersFor(db: Database, assetIds: readonly string[]): Map<string, ApiMarkers> {
  const result = new Map<string, ApiMarkers>();
  if (assetIds.length === 0) return result;
  const rows = db.all<MarkerRow>(
    `select marker.*, asset.revision from marker join asset on asset.id = marker.asset_id
     where marker.asset_id in (select value from json_each(?))`,
    [JSON.stringify(assetIds)],
  );
  rows.sort((a, b) => ORDER[a.source] - ORDER[b.source]);
  const decided = new Set<string>();
  for (const row of rows) {
    const key = `${row.asset_id} ${row.kind}`;
    if (decided.has(key) || !usable(row)) continue;
    decided.add(key);
    const markers = result.get(row.asset_id) ?? { intro: null, credits: null };
    // A manual row without times: a manager said there is none.
    if (row.start_ms !== null) {
      if (row.kind === "intro" && row.end_ms !== null) {
        markers.intro = { startMs: row.start_ms, endMs: row.end_ms, source: row.source };
      } else if (row.kind === "credits") {
        markers.credits = { startMs: row.start_ms, source: row.source };
      }
    }
    result.set(row.asset_id, markers);
  }
  return result;
}

export function markerDetails(db: Database, assetId: string): MarkerDetail[] {
  const rows = db.all<MarkerRow>(
    `select marker.*, asset.revision from marker join asset on asset.id = marker.asset_id
     where marker.asset_id = ? order by marker.kind`,
    [assetId],
  );
  rows.sort((a, b) => (a.kind === b.kind ? ORDER[a.source] - ORDER[b.source] : 0));
  const effective = markersFor(db, [assetId]).get(assetId);
  return rows.map((row) => {
    const chosen = row.kind === "intro" ? effective?.intro : effective?.credits;
    return {
      kind: row.kind,
      source: row.source,
      startMs: row.start_ms,
      endMs: row.end_ms,
      confidence: row.confidence,
      used:
        usable(row) &&
        (chosen?.source === row.source || (row.source === "manual" && row.start_ms === null)),
      updatedAt: row.updated_at,
    };
  });
}

export interface FoundMarker {
  startMs: number;
  endMs: number | null;
  confidence: number;
}

/**
 * Keeps what a source says of a file's intro or credits, for the revision it was read from;
 * null forgets it. @returns whether anything changed
 */
export function putMarker(
  db: Database,
  assetId: string,
  kind: MarkerKind,
  source: Exclude<MarkerSource, "manual">,
  found: FoundMarker | null,
  revision: string,
  now: number,
): boolean {
  const before = db.get<MarkerRow>(
    "select *, '' as revision from marker where asset_id = ? and kind = ? and source = ?",
    [assetId, kind, source],
  );
  if (found === null) {
    if (!before) return false;
    db.run("delete from marker where asset_id = ? and kind = ? and source = ?", [
      assetId,
      kind,
      source,
    ]);
    return true;
  }
  db.run(
    `insert into marker (asset_id, kind, source, start_ms, end_ms, confidence, detector, asset_revision, updated_at)
     values (?, ?, ?, ?, ?, ?, ?, ?, ?)
     on conflict (asset_id, kind, source) do update set start_ms = excluded.start_ms,
       end_ms = excluded.end_ms, confidence = excluded.confidence, detector = excluded.detector,
       asset_revision = excluded.asset_revision, updated_at = excluded.updated_at`,
    [
      assetId,
      kind,
      source,
      Math.round(found.startMs),
      found.endMs === null ? null : Math.round(found.endMs),
      found.confidence,
      source === "detected" ? DETECTOR : null,
      revision,
      now,
    ],
  );
  return (
    !before ||
    before.start_ms !== Math.round(found.startMs) ||
    before.end_ms !== (found.endMs === null ? null : Math.round(found.endMs)) ||
    before.asset_revision !== revision ||
    before.confidence >= MIN_CONFIDENCE !== found.confidence >= MIN_CONFIDENCE
  );
}

/** What a manager sets: times, null for "there is none", or undefined to go back to automatic. */
export type ManualMarker = { startMs: number; endMs: number | null } | null | undefined;

export function setManual(
  db: Database,
  assetId: string,
  kind: MarkerKind,
  marker: ManualMarker,
  now: number,
): void {
  if (marker === undefined) {
    db.run("delete from marker where asset_id = ? and kind = ? and source = 'manual'", [
      assetId,
      kind,
    ]);
    return;
  }
  db.run(
    `insert into marker (asset_id, kind, source, start_ms, end_ms, confidence, updated_at)
     values (?, ?, 'manual', ?, ?, 1, ?)
     on conflict (asset_id, kind, source) do update set start_ms = excluded.start_ms,
       end_ms = excluded.end_ms, updated_at = excluded.updated_at`,
    [assetId, kind, marker?.startMs ?? null, marker?.endMs ?? null, now],
  );
}
