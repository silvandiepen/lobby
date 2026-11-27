// SPDX-License-Identifier: MPL-2.0
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { access, mkdir, readdir, rename, rm, writeFile } from "node:fs/promises";
import { setPriority } from "node:os";
import { join } from "node:path";
import { pngSize } from "../artwork/logos.ts";
import type { Database } from "../db/database.ts";
import {
  ProviderError,
  type ArtworkKind,
  type MetadataProvider,
  type RemoteImage,
} from "./provider.ts";

export const TMDB_PROVIDER = "tmdb";
const PREFIX = "tmdb-";
/** How wide a banner's picture is kept, and a title's logo. */
const LARGE_WIDTH = 1920;
const LOGO_WIDTH = 800;
/** Up to this wide there may be more of it at the provider. */
const NORMAL_WIDTH = 1280;
const MAX_PIXELS = 80_000_000;
const REDUCE_TIMEOUT_MS = 60_000;

interface Picture {
  data: Uint8Array;
  width: number;
  height: number;
}

export interface PreparedImage {
  id: string;
  remote: RemoteImage;
  path: string;
  width: number;
  height: number;
}

/** Reads a JPEG's size from its header, or null when it is not a whole JPEG. */
export function jpegSize(data: Uint8Array): { width: number; height: number } | null {
  if (data[0] !== 0xff || data[1] !== 0xd8) return null;
  if (data.at(-2) !== 0xff || data.at(-1) !== 0xd9) return null;
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  let offset = 2;
  while (offset + 9 < data.length) {
    if (data[offset] !== 0xff) return null;
    const marker = data[offset + 1] ?? 0;
    if (marker === 0xff) {
      offset += 1;
      continue;
    }
    // SOF0 to SOF15, except the three markers in that range that are not frames.
    if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) {
      const height = view.getUint16(offset + 5);
      const width = view.getUint16(offset + 7);
      return width > 0 && height > 0 ? { width, height } : null;
    }
    offset += 2 + view.getUint16(offset + 2);
  }
  return null;
}

const IEND = Buffer.from("49454e44ae426082", "hex");

/** Reads a PNG's size, or null when it is not a whole PNG or not one to draw as a logo. */
export function logoSize(
  data: Uint8Array,
  anyShape = false,
): { width: number; height: number } | null {
  const bytes = Buffer.from(data.buffer, data.byteOffset, data.byteLength);
  if (!bytes.subarray(-8).equals(IEND)) return null;
  // Grey or colour with a channel for transparency, or a palette that says what is see-through.
  const colour = bytes[25];
  const header = bytes.subarray(0, 4096);
  const transparent = colour === 4 || colour === 6 || header.includes("tRNS");
  if (!transparent && !anyShape) return null;
  try {
    return pngSize(data);
  } catch {
    return null;
  }
}

function sizeOf(
  data: Uint8Array,
  kind: ArtworkKind,
  anyShape = false,
): { width: number; height: number } | null {
  return kind === "logo" ? logoSize(data, anyShape) : jpegSize(data);
}

async function exists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

/** What several uses of the same folder have to know about each other. */
export interface ImageFolder {
  dir: string;
  ffmpegPath: string;
  /** Pictures are made smaller one at a time: this shares a small machine with playback. */
  reducing: Promise<unknown>;
  /** Downloaded by someone, but not in the catalogue yet. */
  inFlight: Set<string>;
  tended: boolean;
}

/** Keeps the provider's pictures on disk, one file per artwork id. */
export class ImageFiles {
  private readonly db: Database;
  private readonly provider: MetadataProvider;
  private readonly folder: ImageFolder;
  private readonly signal: AbortSignal;
  /** Downloaded, but not in the catalogue yet. */
  private readonly loose = new Set<string>();

  constructor(db: Database, provider: MetadataProvider, folder: ImageFolder, signal: AbortSignal) {
    this.db = db;
    this.provider = provider;
    this.folder = folder;
    this.signal = signal;
  }

  /** Finds the picture on disk, or downloads it. Null when the provider has no usable one. */
  async prepare(itemId: string, remote: RemoteImage): Promise<PreparedImage | null> {
    const row = this.db.get<{
      id: string;
      local_path: string | null;
      width: number | null;
      height: number | null;
    }>(
      "select id, local_path, width, height from artwork where item_id = ? and kind = ? and provider = ? and remote_path = ?",
      [itemId, remote.kind, TMDB_PROVIDER, remote.path],
    );
    if (row?.local_path && row.width !== null && row.height !== null) {
      const kept = await exists(row.local_path);
      this.signal.throwIfAborted();
      if (kept) {
        const more =
          remote.large === true && row.width <= NORMAL_WIDTH ? await this.wide(remote) : null;
        if (more && more.width > NORMAL_WIDTH) return this.store(row.id, remote, more);
        return { id: row.id, remote, path: row.local_path, width: row.width, height: row.height };
      }
    }
    return this.download(row?.id ?? randomUUID(), remote);
  }

  /** The picture at a banner's width, or null when it cannot be had. */
  private async wide({ kind, path }: RemoteImage): Promise<Picture | null> {
    try {
      const data = await this.provider.image(kind, path, "original");
      this.signal.throwIfAborted();
      const size = data ? jpegSize(data) : null;
      return data && size ? await this.reduced(data, size, kind, LARGE_WIDTH) : null;
    } catch (error) {
      this.signal.throwIfAborted();
      // Too large to take, or not to be made smaller: the ordinary size will do.
      if (!(error instanceof ProviderError)) throw error;
      return null;
    }
  }

  private async fetch(remote: RemoteImage): Promise<Picture | null> {
    const { kind, path, large, anyShape } = remote;
    const wide = large === true ? await this.wide(remote) : null;
    if (wide) return wide;
    const data = await this.provider.image(kind, path);
    this.signal.throwIfAborted();
    const size = data ? sizeOf(data, kind, anyShape) : null;
    if (!data || !size) return null;
    if (kind !== "logo") return { data, ...size };
    return this.reduced(data, size, kind, LOGO_WIDTH);
  }

  /** The picture at most this wide, without anything in it that is not the picture. */
  private async reduced(
    data: Uint8Array,
    size: { width: number; height: number },
    kind: ArtworkKind,
    width: number,
  ): Promise<Picture> {
    if (size.width <= width) return { data, ...size };
    const { folder } = this;
    const work = folder.reducing.then(() => {
      this.signal.throwIfAborted();
      return reduce(folder.ffmpegPath, data, kind, width, this.signal);
    });
    folder.reducing = work.catch(() => undefined);
    const smaller = await work;
    this.signal.throwIfAborted();
    const now = sizeOf(smaller, kind, true);
    if (!now) throw new ProviderError("A picture could not be made smaller");
    return { data: smaller, ...now };
  }

  private async download(id: string, remote: RemoteImage): Promise<PreparedImage | null> {
    const got = await this.fetch(remote);
    return got && this.store(id, remote, got);
  }

  private async store(
    id: string,
    remote: RemoteImage,
    { data, width, height }: Picture,
  ): Promise<PreparedImage> {
    await mkdir(this.folder.dir, { recursive: true });
    // A wider one gets a file of its own: the one in use stays until the catalogue says otherwise.
    const wide = remote.large === true && width > NORMAL_WIDTH ? "-wide" : "";
    const path = join(
      this.folder.dir,
      `${PREFIX}${id}${wide}.${remote.kind === "logo" ? "png" : "jpg"}`,
    );
    const part = `${path}.part`;
    this.loose.add(path);
    this.folder.inFlight.add(path);
    try {
      await writeFile(part, data);
      await rename(part, path);
    } finally {
      await rm(part, { force: true });
    }
    this.signal.throwIfAborted();
    return { id, remote, path, width, height };
  }

  /**
   * Makes this the picture Lobby chooses by itself. One a manager chose stays selected.
   * Call inside a transaction. Returns whether what the apps see changed.
   */
  save(itemId: string, image: PreparedImage): boolean {
    const { kind } = image.remote;
    const chosen = this.db.all<{ id: string; locked: number }>(
      "select id, locked from artwork where item_id = ? and kind = ? and selected = 1",
      [itemId, kind],
    );
    const before = this.db.get<{ width: number | null }>(
      "select width from artwork where id = ? and selected = 1",
      [image.id],
    );
    const id = this.insert(itemId, image);
    this.db.run("update artwork set automatic = (id = ?) where item_id = ? and kind = ?", [
      id,
      itemId,
      kind,
    ]);
    const wider = before !== undefined && before.width !== image.width;
    // The same picture may have been chosen; then it only gained width.
    if (chosen.some((row) => row.locked === 1)) return wider;
    this.db.run("update artwork set selected = (id = ?) where item_id = ? and kind = ?", [
      id,
      itemId,
      kind,
    ]);
    return chosen.length !== 1 || chosen[0]?.id !== id || wider;
  }

  /** Files a picture without choosing it, and returns its id. Call inside a transaction. */
  insert(itemId: string, image: PreparedImage): string {
    const { kind, path: remotePath, language } = image.remote;
    this.db.run(
      `insert into artwork (id, item_id, kind, provider, remote_path, local_path, width, height, language, selected)
       values (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
       on conflict (item_id, kind, provider, remote_path) do update set
         local_path = excluded.local_path, width = excluded.width, height = excluded.height`,
      [
        image.id,
        itemId,
        kind,
        TMDB_PROVIDER,
        remotePath,
        image.path,
        image.width,
        image.height,
        language,
      ],
    );
    this.kept(image.path);
    // Another lookup may have filed the same picture first, under its own id.
    return (
      this.db.get<{ id: string }>(
        "select id from artwork where item_id = ? and kind = ? and provider = ? and remote_path = ?",
        [itemId, kind, TMDB_PROVIDER, remotePath],
      )?.id ?? image.id
    );
  }

  private kept(path: string): void {
    this.loose.delete(path);
    this.folder.inFlight.delete(path);
  }

  /** Removes what was downloaded for nothing. */
  async discardLoose(): Promise<void> {
    for (const path of [...this.loose]) {
      await rm(path, { force: true });
      this.kept(path);
    }
  }

  /**
   * Once per start: removes pictures nothing refers to, and gets back the ones whose
   * file is gone, as after restoring a backup of the catalogue alone.
   */
  async tend(): Promise<void> {
    if (this.folder.tended) return;
    await mkdir(this.folder.dir, { recursive: true });
    this.signal.throwIfAborted();
    const names = new Set(await readdir(this.folder.dir));
    this.signal.throwIfAborted();
    const rows = this.db.all<{
      id: string;
      kind: RemoteImage["kind"];
      remote_path: string;
      local_path: string;
      language: string | null;
      width: number | null;
    }>(
      "select id, kind, remote_path, local_path, language, width from artwork where provider = ? and remote_path is not null and local_path is not null",
      [TMDB_PROVIDER],
    );
    const used = new Set(rows.map((row) => row.local_path));
    // Decided before anything is awaited, so a picture filed meanwhile is never removed.
    const unused = [...names]
      .filter((name) => name.startsWith(PREFIX))
      .map((name) => join(this.folder.dir, name))
      .filter((path) => !used.has(path) && !this.folder.inFlight.has(path.replace(/\.part$/, "")));
    for (const path of unused) await rm(path, { force: true });
    for (const row of rows) {
      if (await exists(row.local_path)) continue;
      this.signal.throwIfAborted();
      let image: PreparedImage | null;
      try {
        const { kind, remote_path: path, language } = row;
        const large = kind === "backdrop" && (row.width ?? 0) > NORMAL_WIDTH;
        image = await this.download(row.id, { kind, path, language, large, anyShape: true });
      } catch (error) {
        // One bad picture does not hold up the rest.
        if (error instanceof ProviderError) continue;
        throw error;
      }
      if (!image) continue;
      this.db.run("update artwork set local_path = ?, width = ?, height = ? where id = ?", [
        image.path,
        image.width,
        image.height,
        row.id,
      ]);
      this.kept(image.path);
    }
    this.folder.tended = true;
  }
}

function reduce(
  ffmpegPath: string,
  data: Uint8Array,
  kind: ArtworkKind,
  width: number,
  signal: AbortSignal,
): Promise<Uint8Array> {
  const logo = kind === "logo";
  // Read from a pipe, as exactly this format, so it can point at nothing else.
  const input = [
    ...["-v", "error", "-nostdin", "-threads", "2", "-max_pixels", String(MAX_PIXELS)],
    ...["-protocol_whitelist", "pipe", "-f", logo ? "png_pipe" : "jpeg_pipe", "-i", "pipe:0"],
  ];
  const output = [
    ...["-frames:v", "1", "-map_metadata", "-1", "-fflags", "+bitexact", "-flags:v", "+bitexact"],
    ...["-vf", `scale=${width}:-2:flags=lanczos,format=${logo ? "rgba" : "yuvj420p"}`],
    ...(logo ? ["-c:v", "png"] : ["-c:v", "mjpeg", "-q:v", "3"]),
    ...["-f", "image2pipe", "pipe:1"],
  ];
  return new Promise((resolve, reject) => {
    const child = spawn(ffmpegPath, [...input, ...output], {
      stdio: ["pipe", "pipe", "ignore"],
      signal: AbortSignal.any([signal, AbortSignal.timeout(REDUCE_TIMEOUT_MS)]),
    });
    if (child.pid !== undefined) {
      try {
        setPriority(child.pid, 15);
      } catch {
        // It already finished.
      }
    }
    const parts: Buffer[] = [];
    child.stdout.on("data", (part: Buffer) => parts.push(part));
    const failed = (): void => {
      reject(new ProviderError("A picture could not be made smaller"));
    };
    child.on("error", failed);
    child.on("close", (code) => {
      if (code === 0) resolve(Buffer.concat(parts));
      else failed();
    });
    // It closes its side early when it cannot read the picture; the exit code says so.
    child.stdin.on("error", () => undefined);
    child.stdin.end(data);
  });
}
