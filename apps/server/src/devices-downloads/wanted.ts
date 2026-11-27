// SPDX-License-Identifier: MPL-2.0
import { randomUUID } from "node:crypto";
import type { Database } from "../db/database.ts";
import { kidsLimits, type KidsView } from "../kids/limits.ts";

/** A refusal the HTTP layer turns into a status, with a sentence that can be shown as it is. */
export class DownloadsError extends Error {
  readonly code: "invalid_request" | "not_found" | "conflict";

  constructor(code: DownloadsError["code"], message: string) {
    super(message);
    this.code = code;
  }
}

export type WantedKind = "item" | "next_unwatched";

/** One thing a manager put on a device. */
export interface WantedEntry {
  id: string;
  kind: WantedKind;
  /** The film, episode, season or show; for a rule, the show. */
  itemId: string;
  itemKind: string;
  /** For a rule: whose watching decides what "next" is. */
  profileId: string | null;
  /** For a rule: how many episodes ahead. */
  count: number | null;
  addedBy: string | null;
  addedAt: number;
}

export type WantedInput =
  | { kind: "item"; itemId: string }
  | { kind: "next_unwatched"; showId: string; profileId: string; count: number };

/** A file a device should have, before anything is known about copies or downloads. */
export interface WantedFile {
  assetId: string;
  itemId: string;
  revision: string;
  sizeBytes: number;
  playability: "direct" | "remux" | "transcode" | "unsupported";
  playabilityReason: string | null;
  /** False when the drive is not connected. */
  available: boolean;
  /** Which entries ask for it. */
  why: { wantedId: string; kind: WantedKind }[];
}

export const REPORT_STATES = ["waiting", "downloading", "paused", "downloaded", "failed"] as const;
export type ReportState = (typeof REPORT_STATES)[number];

export const REPORT_ERRORS = [
  "no_space",
  "network",
  "not_found",
  "unsupported",
  "verification_failed",
  "cancelled",
  "other",
] as const;
export type ReportError = (typeof REPORT_ERRORS)[number];

/** What a device says about one file it has or is fetching. */
export interface ReportedDownload {
  assetId: string;
  revision: string;
  state: ReportState;
  bytesDone: number;
  bytesTotal: number | null;
  error: ReportError | null;
  /** True when the person on the device downloaded it themselves. */
  own: boolean;
}

export interface StoredDownload extends ReportedDownload {
  reportedAt: number;
}

export interface DeviceStorage {
  freeBytes: number | null;
  totalBytes: number | null;
  reportedAt: number;
}

/** A manager cannot put more entries than this on one device. */
export const MAX_WANTED_ENTRIES = 500;
/** A device is never told to hold more files than this; the rest is reported as left out. */
export const MAX_WANTED_FILES = 2000;
export const MAX_RULE_COUNT = 50;

interface WantedRow {
  id: string;
  kind: WantedKind;
  item_id: string;
  item_kind: string;
  profile_id: string | null;
  count: number | null;
  added_by: string | null;
  added_at: number;
}

interface FileRow {
  item_id: string;
  asset_id: string;
  revision: string;
  size: number;
  playability: WantedFile["playability"] | null;
  playability_reason: string | null;
  edition: string | null;
  available: number;
}

const WANTED_COLUMNS = `device_wanted.id, device_wanted.kind, device_wanted.item_id, item.kind as item_kind,
  device_wanted.profile_id, device_wanted.count, device_wanted.added_by, device_wanted.added_at`;

function toEntry(row: WantedRow): WantedEntry {
  return {
    id: row.id,
    kind: row.kind,
    itemId: row.item_id,
    itemKind: row.item_kind,
    profileId: row.profile_id,
    count: row.count,
    addedBy: row.added_by,
    addedAt: row.added_at,
  };
}

/**
 * The wanted list of every device, what devices report back, and how a list turns
 * into files. Database only: it knows nothing about copies or ffmpeg.
 */
export class WantedStore {
  private readonly db: Database;
  private readonly now: () => number;

  constructor(db: Database, now: () => number = Date.now) {
    this.db = db;
    this.now = now;
  }

  /** @throws DownloadsError `not_found` when there is no such device, or it was removed */
  requireDevice(deviceId: string): void {
    const row = this.db.get("select 1 as x from device where id = ? and revoked_at is null", [
      deviceId,
    ]);
    if (!row) throw new DownloadsError("not_found", "There is no such device.");
  }

  list(deviceId: string): WantedEntry[] {
    return this.db
      .all<WantedRow>(
        `select ${WANTED_COLUMNS} from device_wanted join item on item.id = device_wanted.item_id
         where device_wanted.device_id = ? order by device_wanted.position, device_wanted.added_at`,
        [deviceId],
      )
      .map(toEntry);
  }

  /** Adds an entry, or returns the one that says the same already. */
  add(
    deviceId: string,
    input: WantedInput,
    addedBy: string,
  ): { entry: WantedEntry; created: boolean } {
    return this.db.transaction(() => {
      this.requireDevice(deviceId);
      const itemId = input.kind === "item" ? input.itemId : input.showId;
      const item = this.db.get<{ kind: string }>("select kind from item where id = ?", [itemId]);
      if (!item) throw new DownloadsError("not_found", "That title is not in the library.");
      if (input.kind === "next_unwatched") {
        if (item.kind !== "show") {
          throw new DownloadsError("invalid_request", "A rule needs a series, not a single title.");
        }
        // A viewer of the device's own household only.
        const profile = this.db.get(
          `select 1 as x from profile where id = ? and deleted_at is null
             and household_id = (select household_id from device where id = ?)`,
          [input.profileId, deviceId],
        );
        if (!profile) throw new DownloadsError("not_found", "There is no such viewer.");
      }

      const profileId = input.kind === "item" ? null : input.profileId;
      const existing = this.db.get<{ id: string }>(
        `select id from device_wanted
         where device_id = ? and kind = ? and item_id = ? and profile_id is ?`,
        [deviceId, input.kind, itemId, profileId],
      );
      if (existing) {
        // Asking for a rule again changes how far ahead it looks.
        if (input.kind === "next_unwatched") {
          this.db.run("update device_wanted set count = ? where id = ?", [
            input.count,
            existing.id,
          ]);
        }
        return { entry: this.entry(existing.id), created: false };
      }

      const total =
        this.db.get<{ n: number }>("select count(*) as n from device_wanted where device_id = ?", [
          deviceId,
        ])?.n ?? 0;
      if (total >= MAX_WANTED_ENTRIES) {
        throw new DownloadsError(
          "conflict",
          `A device can hold ${String(MAX_WANTED_ENTRIES)} entries. Remove one first.`,
        );
      }
      const position =
        (this.db.get<{ last: number | null }>(
          "select max(position) as last from device_wanted where device_id = ?",
          [deviceId],
        )?.last ?? 0) + 1;
      const id = randomUUID();
      this.db.run(
        `insert into device_wanted (id, device_id, kind, item_id, profile_id, count, position, added_by, added_at)
         values (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [
          id,
          deviceId,
          input.kind,
          itemId,
          profileId,
          input.kind === "item" ? null : input.count,
          position,
          addedBy,
          this.now(),
        ],
      );
      return { entry: this.entry(id), created: true };
    });
  }

  private entry(id: string): WantedEntry {
    const row = this.db.get<WantedRow>(
      `select ${WANTED_COLUMNS} from device_wanted join item on item.id = device_wanted.item_id
       where device_wanted.id = ?`,
      [id],
    );
    if (!row) throw new Error("The wanted entry vanished.");
    return toEntry(row);
  }

  /** Removes an entry of this device. False when the device has no such entry. */
  remove(deviceId: string, wantedId: string): boolean {
    return (
      this.db.run("delete from device_wanted where device_id = ? and id = ?", [
        deviceId,
        wantedId,
      ]) > 0
    );
  }

  /** The ids of the films and episodes an entry stands for, in watching order. */
  private itemsOf(entry: WantedEntry, view: KidsView | null): string[] {
    if (entry.kind === "next_unwatched") {
      // Specials (season 0) are not part of "the next episode".
      const next = this.db
        .all<{ id: string }>(
          `with recursive below (id, kind, season_number, episode_number, sort_title) as (
             select id, kind, season_number, episode_number, sort_title from item where id = ?
             union all
             select item.id, item.kind, item.season_number, item.episode_number, item.sort_title
             from item join below on item.parent_id = below.id
           )
           select below.id from below
           left join progress on progress.item_id = below.id and progress.profile_id = ?
           where below.kind = 'episode' and coalesce(below.season_number, 1) != 0
             and coalesce(progress.completed, 0) = 0
             -- A removed viewer watches nothing next.
             and exists (select 1 from profile where id = ? and deleted_at is null)
           order by below.season_number, below.episode_number, below.sort_title
           limit ?`,
          // With limits the count is of what is allowed, so it is taken afterwards.
          [entry.itemId, entry.profileId, entry.profileId, view ? -1 : (entry.count ?? 1)],
        )
        .map((row) => row.id);
      return next.filter((id) => view?.items.has(id) ?? true).slice(0, entry.count ?? 1);
    }
    if (entry.itemKind !== "show" && entry.itemKind !== "season") return [entry.itemId];
    return this.db
      .all<{ id: string }>(
        `with recursive below (id, kind, season_number, episode_number, sort_title) as (
           select id, kind, season_number, episode_number, sort_title from item where id = ?
           union all
           select item.id, item.kind, item.season_number, item.episode_number, item.sort_title
           from item join below on item.parent_id = below.id
         )
         select id from below where kind = 'episode'
         order by coalesce(season_number, 1) = 0, season_number, episode_number, sort_title`,
        [entry.itemId],
      )
      .map((row) => row.id);
  }

  /**
   * The files a device should have, in the order to fetch them: entry by entry, and
   * inside a series in watching order. A file two entries ask for appears once.
   * A device of a kids viewer gets only what that viewer may see.
   * `leftOut` counts the files beyond `MAX_WANTED_FILES`.
   */
  files(deviceId: string): { files: WantedFile[]; leftOut: number } {
    const view = kidsLimits(this.db).viewOf(deviceId);
    const order: string[] = [];
    const reasons = new Map<string, WantedFile["why"]>();
    for (const entry of this.list(deviceId)) {
      for (const itemId of this.itemsOf(entry, view)) {
        if (view && !view.items.has(itemId)) continue;
        const why = reasons.get(itemId);
        if (why) {
          why.push({ wantedId: entry.id, kind: entry.kind });
        } else {
          reasons.set(itemId, [{ wantedId: entry.id, kind: entry.kind }]);
          order.push(itemId);
        }
      }
    }
    if (order.length === 0) return { files: [], leftOut: 0 };

    const rows = this.db.all<FileRow>(
      `select item_asset.item_id, asset.id as asset_id, asset.revision, asset.size, asset.playability,
         asset.playability_reason, item_asset.edition,
         (asset.available = 1 and source.available = 1) as available
       from json_each(?) as wanted
       cross join item_asset on item_asset.item_id = wanted.value
       cross join asset on asset.id = item_asset.asset_id
       cross join source on source.id = asset.source_id
       where item_asset.role = 'main' and asset.state = 'probed'
       order by item_asset.edition, item_asset.part, asset.rel_path`,
      [JSON.stringify(order)],
    );
    const byItem = new Map<string, FileRow[]>();
    for (const row of rows) byItem.set(row.item_id, [...(byItem.get(row.item_id) ?? []), row]);

    const files: WantedFile[] = [];
    const seen = new Set<string>();
    let leftOut = 0;
    for (const itemId of order) {
      const all = byItem.get(itemId) ?? [];
      // A film kept in two editions: the first one, with all its parts.
      const edition = all[0]?.edition ?? null;
      for (const row of all.filter((candidate) => candidate.edition === edition)) {
        // One file can hold two episodes.
        if (seen.has(row.asset_id) || view?.assets.has(row.asset_id) === false) continue;
        seen.add(row.asset_id);
        if (files.length >= MAX_WANTED_FILES) {
          leftOut += 1;
          continue;
        }
        files.push({
          assetId: row.asset_id,
          itemId,
          revision: row.revision,
          sizeBytes: row.size,
          playability: row.playability ?? "unsupported",
          playabilityReason: row.playability_reason,
          available: row.available === 1,
          why: reasons.get(itemId) ?? [],
        });
      }
    }
    return { files, leftOut };
  }

  /** The devices that have anything on their list. */
  devicesWithWanted(): string[] {
    return this.db
      .all<{ device_id: string }>(
        `select distinct device_wanted.device_id from device_wanted
         join device on device.id = device_wanted.device_id where device.revoked_at is null`,
      )
      .map((row) => row.device_id);
  }

  /** Replaces everything the device said before with what it says now. */
  saveReport(
    deviceId: string,
    report: {
      freeBytes: number | null;
      totalBytes: number | null;
      downloads: ReportedDownload[];
    },
  ): void {
    const at = this.now();
    this.db.transaction(() => {
      this.db.run("delete from device_download where device_id = ?", [deviceId]);
      for (const download of report.downloads) {
        this.db.run(
          `insert into device_download (device_id, asset_id, revision, state, bytes_done, bytes_total, error, own, reported_at)
           values (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          [
            deviceId,
            download.assetId,
            download.revision,
            download.state,
            download.bytesDone,
            download.bytesTotal,
            download.error,
            download.own ? 1 : 0,
            at,
          ],
        );
      }
      this.db.run(
        `insert into device_storage (device_id, free_bytes, total_bytes, reported_at) values (?, ?, ?, ?)
         on conflict (device_id) do update set free_bytes = excluded.free_bytes,
           total_bytes = excluded.total_bytes, reported_at = excluded.reported_at`,
        [deviceId, report.freeBytes, report.totalBytes, at],
      );
    });
  }

  reported(deviceId: string): StoredDownload[] {
    return this.db
      .all<{
        asset_id: string;
        revision: string;
        state: ReportState;
        bytes_done: number;
        bytes_total: number | null;
        error: ReportError | null;
        own: number;
        reported_at: number;
      }>("select * from device_download where device_id = ? order by asset_id", [deviceId])
      .map((row) => ({
        assetId: row.asset_id,
        revision: row.revision,
        state: row.state,
        bytesDone: row.bytes_done,
        bytesTotal: row.bytes_total,
        error: row.error,
        own: row.own === 1,
        reportedAt: row.reported_at,
      }));
  }

  storage(deviceId: string): DeviceStorage | null {
    const row = this.db.get<{
      free_bytes: number | null;
      total_bytes: number | null;
      reported_at: number;
    }>("select free_bytes, total_bytes, reported_at from device_storage where device_id = ?", [
      deviceId,
    ]);
    return row
      ? { freeBytes: row.free_bytes, totalBytes: row.total_bytes, reportedAt: row.reported_at }
      : null;
  }

  /** The item a file belongs to, for files a device holds that are on no list. */
  itemOfAsset(assetId: string): string | null {
    return (
      this.db.get<{ item_id: string }>(
        "select item_id from item_asset where asset_id = ? and role = 'main' order by item_id limit 1",
        [assetId],
      )?.item_id ?? null
    );
  }
}
