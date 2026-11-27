// SPDX-License-Identifier: MPL-2.0
import { createHash, randomUUID, type Hash } from "node:crypto";
import { createReadStream } from "node:fs";
import { mkdir, open, readdir, rename, rm, stat, statfs, truncate } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { RootConfig } from "../config.ts";
import { syncDir } from "../conversion/moves.ts";
import type { Database } from "../db/database.ts";
import { isSubtitleFile, isVideoFile, type SourceHint } from "../library/parse.ts";
import { errorMessage, log } from "../log.ts";
import { ImportError, type ImportService } from "./service.ts";

export type UploadState = "receiving" | "verifying" | "done" | "failed" | "cancelled";

/** Where an upload goes: the films' folder, the series' folder, or one library folder (a category). */
export type Destination =
  { kind: "movies" } | { kind: "series" } | { kind: "folder"; path: string };

export interface ApiUpload {
  id: string;
  batch: string | null;
  relPath: string;
  name: string;
  sizeBytes: number;
  receivedBytes: number;
  state: UploadState;
  reason: string | null;
  destination: Destination;
  /** The import it became, once it arrived whole. */
  itemId: string | null;
  createdAt: number;
  updatedAt: number;
}

interface UploadRow {
  id: string;
  device_id: string;
  batch: string | null;
  rel_path: string;
  size: number;
  sha256: string | null;
  destination_json: string;
  state: UploadState;
  reason: string | null;
  item_id: string | null;
  created_at: number;
  updated_at: number;
}

export interface UploadOptions {
  db: Database;
  imports: ImportService;
  roots: () => RootConfig[];
  /** The largest file that is taken. */
  maxFileBytes: () => number;
  /** What all unfinished uploads together may take on the drive. */
  quotaBytes: () => number;
  /** What must stay free on the drive with Lobby's folder. */
  minFreeBytes: () => number;
  /** Unfinished uploads a device may have at once. Default 8. */
  maxActivePerDevice?: number;
  /** An upload that received nothing this long is given up and removed. Default 7 days. */
  expireMs?: number;
  now?: () => number;
  /** Free bytes on the drive at `path`; replaced in tests. */
  freeBytes?: (path: string) => Promise<number>;
  /** Called while bytes arrive (at most once a second per upload) and when an upload changes. */
  onChange?: (upload: ApiUpload) => void;
}

const REL_SEGMENT = /^[^/\\\0]{1,255}$/;
const PARTIAL = ".lobby-upload";

/** A name sent by an app, checked: below the upload's own folder, without a way out of it. */
export function checkRelPath(value: unknown): string {
  if (typeof value !== "string" || value.length === 0 || value.length > 1024) {
    throw new ImportError(
      "invalid_request",
      `"relPath" must be the file's name, or its path in the folder that was chosen.`,
    );
  }
  const segments = value.split("/");
  if (
    segments.length > 8 ||
    segments.some(
      (one) =>
        !REL_SEGMENT.test(one) ||
        one === "." ||
        one === ".." ||
        one.startsWith(".") ||
        one.trim() !== one,
    ) ||
    Array.from(value).some((char) => char.charCodeAt(0) < 32)
  ) {
    throw new ImportError("invalid_request", `"relPath" has a name Lobby cannot use.`);
  }
  const name = segments.at(-1) ?? "";
  if (!isVideoFile(name) && !isSubtitleFile(name)) {
    throw new ImportError("invalid_request", "Only videos and their subtitles can be uploaded.");
  }
  return value.normalize("NFC");
}

/**
 * Uploads from a manager's device (docs/api.md, Uploads), in pieces that can be resumed: create,
 * then PATCH each piece at the offset where the last one ended, HEAD to ask where it is, and
 * complete with the whole file's SHA-256. The file is written into Lobby's folder on the media
 * drive and then takes the same way into the library as a file in an import folder.
 */
export class UploadService {
  private readonly db: Database;
  private readonly options: UploadOptions;
  private readonly now: () => number;
  /** The whole file's hash so far, for uploads whose bytes all came through this process. */
  private readonly hashes = new Map<string, { hash: Hash; offset: number }>();
  private readonly writing = new Set<string>();
  private readonly toldAt = new Map<string, number>();
  private timer: NodeJS.Timeout | null = null;

  constructor(options: UploadOptions) {
    this.db = options.db;
    this.options = options;
    this.now = options.now ?? Date.now;
  }

  async start(): Promise<void> {
    await this.expire();
    for (const row of this.db.all<UploadRow>("select * from upload where state = 'verifying'")) {
      void this.verify(row.id);
    }
    this.timer = setInterval(() => void this.expire(), 3_600_000);
    this.timer.unref();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  private dir(): string {
    const lobby = this.options.imports.lobbyDir;
    if (!lobby)
      throw new ImportError("unavailable", "Uploads need Lobby's folder, set under Converting.");
    return join(lobby, "uploads");
  }

  private async ready(): Promise<void> {
    this.dir();
    if (!(await this.options.imports.driveConnected())) {
      throw new ImportError("unavailable", "The drive with Lobby's folder is not connected.");
    }
  }

  private finalPath(row: UploadRow): string {
    return join(this.dir(), row.batch ?? row.id, row.rel_path);
  }

  private partialPath(row: UploadRow): string {
    return `${this.finalPath(row)}${PARTIAL}`;
  }

  private destinationOf(value: unknown): Destination {
    if (typeof value !== "object" || value === null) {
      throw new ImportError(
        "invalid_request",
        `"destination" must say where it goes: movies, series or a folder.`,
      );
    }
    const kind = (value as Record<string, unknown>)["kind"];
    if (kind === "movies" || kind === "series") return { kind };
    if (kind === "folder") {
      const path = (value as Record<string, unknown>)["path"];
      const root = this.options.roots().find((one) => one.path === path);
      if (!root || root.hint === "personal") {
        throw new ImportError(
          "invalid_request",
          "That is not a films or series folder of the library.",
        );
      }
      return { kind, path: root.path };
    }
    throw new ImportError(
      "invalid_request",
      `"destination" must say where it goes: movies, series or a folder.`,
    );
  }

  async create(
    deviceId: string,
    input: {
      relPath: unknown;
      sizeBytes: unknown;
      sha256?: unknown;
      destination: unknown;
      batch?: unknown;
    },
  ): Promise<{ upload: ApiUpload; created: boolean }> {
    await this.ready();
    const relPath = checkRelPath(input.relPath);
    const size = input.sizeBytes;
    if (typeof size !== "number" || !Number.isSafeInteger(size) || size <= 0) {
      throw new ImportError("invalid_request", `"sizeBytes" must be the file's size.`);
    }
    if (size > this.options.maxFileBytes()) {
      throw new ImportError(
        "invalid_request",
        "The file is larger than the server takes. A manager can change that in Server Settings.",
      );
    }
    const sha256 = input.sha256 ?? null;
    if (sha256 !== null && (typeof sha256 !== "string" || !/^[0-9a-fA-F]{64}$/.test(sha256))) {
      throw new ImportError("invalid_request", `"sha256" must be the file's SHA-256 in hex.`);
    }
    const batch = input.batch ?? null;
    if (batch !== null && (typeof batch !== "string" || !/^[A-Za-z0-9_-]{1,64}$/.test(batch))) {
      throw new ImportError("invalid_request", `"batch" must be an id.`);
    }
    const destination = this.destinationOf(input.destination);

    // Sent again after a lost answer: the same upload.
    const same = this.db.get<UploadRow>(
      `select * from upload where device_id = ? and batch is ? and rel_path = ? and size = ?
         and state in ('receiving', 'verifying')`,
      [deviceId, batch, relPath, size],
    );
    if (same) return { upload: await this.toApi(same), created: false };
    if (batch !== null) {
      const taken = this.db.get<UploadRow>(
        "select * from upload where batch = ? and rel_path = ? and state <> 'cancelled' and state <> 'failed'",
        [batch, relPath],
      );
      if (taken)
        throw new ImportError("conflict", "A file with this name is already in this upload.");
    }

    const active = this.db.all<UploadRow>("select * from upload where state = 'receiving'");
    if (
      active.filter((one) => one.device_id === deviceId).length >=
      (this.options.maxActivePerDevice ?? 8)
    ) {
      throw new ImportError(
        "conflict",
        "This device has many unfinished uploads. Finish or cancel some first.",
      );
    }
    const outstanding = active.reduce((sum, one) => sum + one.size, 0);
    if (outstanding + size > this.options.quotaBytes()) {
      throw new ImportError(
        "conflict",
        "Unfinished uploads take all the room they may. Finish or cancel some first.",
      );
    }
    const free = await (this.options.freeBytes ?? freeBytesOf)(
      this.options.imports.lobbyDir ?? "/",
    );
    if (free - outstanding - size < this.options.minFreeBytes()) {
      throw new ImportError(
        "conflict",
        "There is not enough free space on the drive for this file.",
      );
    }

    const id = randomUUID();
    const now = this.now();
    this.db.run(
      `insert into upload (id, device_id, batch, rel_path, size, sha256, destination_json, state,
         created_at, updated_at) values (?, ?, ?, ?, ?, ?, ?, 'receiving', ?, ?)`,
      [
        id,
        deviceId,
        batch,
        relPath,
        size,
        sha256?.toLowerCase() ?? null,
        JSON.stringify(destination),
        now,
        now,
      ],
    );
    const row = this.row(id);
    await mkdir(dirname(this.partialPath(row)), { recursive: true });
    await (await open(this.partialPath(row), "a")).close();
    this.hashes.set(id, { hash: createHash("sha256"), offset: 0 });
    log.info("An upload started", { bytes: size });
    return { upload: await this.toApi(row), created: true };
  }

  private row(id: string): UploadRow {
    const row = this.db.get<UploadRow>("select * from upload where id = ?", [id]);
    if (!row) throw new ImportError("not_found", "There is no such upload.");
    return row;
  }

  /** The upload, for the device that sends it. Another device gets 404, as if there were none. */
  private own(id: string, deviceId: string): UploadRow {
    const row = this.row(id);
    if (row.device_id !== deviceId) throw new ImportError("not_found", "There is no such upload.");
    return row;
  }

  private async received(row: UploadRow): Promise<number> {
    if (row.state !== "receiving") return row.state === "cancelled" ? 0 : row.size;
    try {
      return (await stat(this.partialPath(row))).size;
    } catch {
      return 0;
    }
  }

  async offset(id: string, deviceId: string): Promise<{ upload: ApiUpload; offset: number }> {
    const row = this.own(id, deviceId);
    const offset = await this.received(row);
    return { upload: await this.toApi(row), offset };
  }

  /**
   * Appends one piece. It must start where the last one ended; with a checksum it must match, or
   * it is taken back. @returns the new offset
   */
  async chunk(
    id: string,
    deviceId: string,
    offset: number,
    length: number,
    checksum: string | null,
    body: AsyncIterable<Uint8Array>,
  ): Promise<number> {
    await this.ready();
    const row = this.own(id, deviceId);
    if (row.state !== "receiving") {
      throw new ImportError(
        "conflict",
        row.state === "cancelled" ? "This upload was cancelled." : "This upload has all its bytes.",
      );
    }
    if (this.writing.has(id))
      throw new ImportError("conflict", "Another piece of this upload is arriving.");
    this.writing.add(id);
    try {
      const current = await this.received(row);
      if (offset !== current) {
        throw new UploadConflict("The upload is at another position.", current);
      }
      if (offset + length > row.size) {
        throw new ImportError("invalid_request", "The piece goes past the end of the file.");
      }
      const whole = this.hashes.get(id);
      const continuing = whole?.offset === offset ? whole.hash.copy() : null;
      const piece = checksum === null ? null : createHash("sha256");
      const handle = await open(this.partialPath(row), "a");
      let written = 0;
      try {
        for await (const chunk of body) {
          if (written + chunk.length > length) {
            throw new ImportError("invalid_request", "The piece is longer than it said.");
          }
          await handle.write(chunk);
          piece?.update(chunk);
          continuing?.update(chunk);
          written += chunk.length;
        }
        await handle.sync();
      } catch (error) {
        await handle.close();
        await truncate(this.partialPath(row), offset).catch(() => undefined);
        if (error instanceof ImportError) throw error;
        const code = (error as NodeJS.ErrnoException).code;
        throw new ImportError(
          "unavailable",
          code === "ENOSPC"
            ? "The drive is full."
            : "The piece was interrupted. Ask where the upload is and go on from there.",
        );
      }
      await handle.close();
      if (written !== length) {
        await truncate(this.partialPath(row), offset);
        throw new UploadConflict("The piece was shorter than it said.", offset);
      }
      if (piece && checksum !== null && piece.digest("base64") !== checksum) {
        await truncate(this.partialPath(row), offset);
        throw new UploadConflict("The piece arrived damaged. Send it again.", offset);
      }
      if (continuing) this.hashes.set(id, { hash: continuing, offset: offset + written });
      else this.hashes.delete(id);
      this.db.run("update upload set updated_at = ? where id = ?", [this.now(), id]);
      const told = this.toldAt.get(id) ?? 0;
      if (this.now() - told >= 1000 || offset + written === row.size) {
        this.toldAt.set(id, this.now());
        this.tell(id);
      }
      return offset + written;
    } finally {
      this.writing.delete(id);
    }
  }

  /** The device says everything was sent. The server checks the whole file, then imports it. */
  async complete(id: string, deviceId: string, sha256: unknown): Promise<ApiUpload> {
    await this.ready();
    const row = this.own(id, deviceId);
    if (row.state === "done" || row.state === "verifying") return this.toApi(row);
    if (row.state !== "receiving") throw new ImportError("conflict", "This upload was cancelled.");
    if (sha256 !== undefined && sha256 !== null) {
      if (typeof sha256 !== "string" || !/^[0-9a-fA-F]{64}$/.test(sha256)) {
        throw new ImportError("invalid_request", `"sha256" must be the file's SHA-256 in hex.`);
      }
      if (row.sha256 !== null && row.sha256 !== sha256.toLowerCase()) {
        throw new ImportError(
          "invalid_request",
          "That is not the SHA-256 the upload started with.",
        );
      }
      this.db.run("update upload set sha256 = ? where id = ?", [sha256.toLowerCase(), id]);
    } else if (row.sha256 === null) {
      throw new ImportError("invalid_request", `Send the whole file's "sha256" to finish.`);
    }
    const received = await this.received(row);
    if (received !== row.size) {
      throw new UploadConflict("Not all of the file has arrived.", received);
    }
    this.set(id, { state: "verifying", reason: null });
    const known = this.hashes.get(id);
    if (known?.offset === row.size) {
      await this.verify(id);
    } else {
      // The bytes came through an earlier run of the server: the file is read once more.
      void this.verify(id);
    }
    return this.toApi(this.row(id));
  }

  private async verify(id: string): Promise<void> {
    const row = this.row(id);
    try {
      const known = this.hashes.get(id);
      let digest: string;
      if (known?.offset === row.size) {
        digest = known.hash.digest("hex");
      } else {
        const hash = createHash("sha256");
        for await (const chunk of createReadStream(this.partialPath(row)))
          hash.update(chunk as Buffer);
        digest = hash.digest("hex");
      }
      this.hashes.delete(id);
      if (digest !== row.sha256) {
        // Damaged somewhere on the way: it starts over, rather than importing a broken film.
        await truncate(this.partialPath(row), 0);
        this.hashes.set(id, { hash: createHash("sha256"), offset: 0 });
        this.set(id, {
          state: "receiving",
          reason: "The file arrived damaged. It is sent again from the start.",
        });
        return;
      }
      await this.arrive(this.row(id));
    } catch (error) {
      log.error("An upload could not be checked", { error: errorMessage(error) });
      this.set(id, { state: "failed", reason: "The upload could not be checked. Send it again." });
    }
  }

  /** The whole file is there and proven: it takes its own name and goes to the import. */
  private async arrive(row: UploadRow): Promise<void> {
    const final = this.finalPath(row);
    try {
      await stat(final);
      this.set(row.id, {
        state: "failed",
        reason: "A file with this name is already in this upload.",
      });
      return;
    } catch {
      // Free.
    }
    await rename(this.partialPath(row), final);
    await syncDir(dirname(final));
    const destination = JSON.parse(row.destination_json) as Destination;
    const name = row.rel_path.slice(row.rel_path.lastIndexOf("/") + 1);
    if (isSubtitleFile(name)) {
      // Beside its video: the one in the same folder of this upload, when it is there already.
      const video = this.db
        .all<UploadRow>(
          "select * from upload where batch is ? and state = 'done' and item_id is not null and id <> ?",
          [row.batch, row.id],
        )
        .find((one) => dirname(one.rel_path) === dirname(row.rel_path));
      if (video?.item_id) await this.options.imports.placeLateSubtitle(video.item_id, final);
      this.set(row.id, { state: "done", reason: null, item_id: video?.item_id ?? null });
      return;
    }
    const info = await stat(final);
    const subtitles = (await readdir(dirname(final)))
      .filter((one) => isSubtitleFile(one) && !one.endsWith(PARTIAL))
      .map((one) => join(dirname(final), one));
    const hint: SourceHint =
      destination.kind === "movies"
        ? "movies"
        : destination.kind === "series"
          ? "series"
          : (this.options.roots().find((one) => one.path === destination.path)?.hint ?? "mixed");
    const item = await this.options.imports.addUpload({
      uploadId: row.id,
      path: final,
      relPath: row.rel_path,
      size: info.size,
      mtimeMs: Math.round(info.mtimeMs),
      hint,
      destination: destination.kind === "folder" ? destination.path : null,
      subtitles,
      by: row.device_id,
    });
    this.set(row.id, { state: "done", reason: null, item_id: item.id });
    log.info("An upload arrived", { bytes: row.size });
  }

  async cancel(id: string, deviceId: string): Promise<ApiUpload> {
    const row = this.own(id, deviceId);
    if (row.state === "done") throw new ImportError("conflict", "This upload arrived already.");
    if (row.state === "verifying")
      throw new ImportError("conflict", "This upload is being checked.");
    if (row.state === "receiving" || row.state === "failed") {
      await rm(this.partialPath(row), { force: true }).catch(() => undefined);
      this.hashes.delete(id);
      this.set(id, { state: "cancelled", reason: null });
    }
    return this.toApi(this.row(id));
  }

  /** Uploads that received nothing for a week are given up, and their bytes removed. */
  async expire(): Promise<void> {
    const before = this.now() - (this.options.expireMs ?? 7 * 24 * 3_600_000);
    for (const row of this.db.all<UploadRow>(
      "select * from upload where state = 'receiving' and updated_at < ?",
      [before],
    )) {
      try {
        await rm(this.partialPath(row), { force: true });
      } catch {
        continue;
      }
      this.set(row.id, { state: "cancelled", reason: "Nothing arrived for a week." });
    }
    // Finished ones are kept a month, as the record of what was sent.
    this.db.run(
      "delete from upload where state in ('done', 'cancelled', 'failed') and updated_at < ?",
      [this.now() - 30 * 24 * 3_600_000],
    );
  }

  async list(limit = 200): Promise<ApiUpload[]> {
    const rows = this.db.all<UploadRow>("select * from upload order by created_at desc limit ?", [
      limit,
    ]);
    return Promise.all(rows.map((row) => this.toApi(row)));
  }

  async get(id: string): Promise<ApiUpload> {
    return this.toApi(this.row(id));
  }

  private set(id: string, fields: Partial<UploadRow>): void {
    const entries = Object.entries({ ...fields, updated_at: this.now() });
    this.db.run(
      `update upload set ${entries.map(([key]) => `${key} = ?`).join(", ")} where id = ?`,
      [...entries.map(([, value]) => value), id],
    );
    this.tell(id);
  }

  private tell(id: string): void {
    if (!this.options.onChange) return;
    void this.toApi(this.row(id)).then(this.options.onChange, () => undefined);
  }

  private async toApi(row: UploadRow): Promise<ApiUpload> {
    return {
      id: row.id,
      batch: row.batch,
      relPath: row.rel_path,
      name: row.rel_path.slice(row.rel_path.lastIndexOf("/") + 1),
      sizeBytes: row.size,
      receivedBytes: await this.received(row),
      state: row.state,
      reason: row.reason,
      destination: JSON.parse(row.destination_json) as Destination,
      itemId: row.item_id,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    };
  }
}

/** A piece that does not fit where the upload is: the answer says where to go on. */
export class UploadConflict extends ImportError {
  readonly offset: number;

  constructor(message: string, offset: number) {
    super("conflict", message);
    this.offset = offset;
  }
}

async function freeBytesOf(path: string): Promise<number> {
  const volume = await statfs(path);
  return volume.bavail * volume.bsize;
}
