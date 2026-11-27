// SPDX-License-Identifier: MPL-2.0
import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { mkdir, readFile, readdir, rename, rm, stat, writeFile } from "node:fs/promises";
import { setPriority } from "node:os";
import { join } from "node:path";
import type { Database } from "../db/database.ts";

export const UPLOAD_PROVIDER = "upload";
export const CHOSEN_FRAME_PROVIDER = "chosen-frame";
export const MAX_UPLOAD_BYTES = 20 * 1024 * 1024;

const MAX_SIDE = 12_000;
const MAX_PIXELS = 80_000_000;
const MIN_SIDE = 100;
const MAX_WIDTH = 1600;
/** A category's logo is shown small; this is twice the widest place. A title's stands on a banner. */
const LOGO_SIDE = 600;
const TITLE_LOGO_SIDE = 800;
/** Words are wide and low. */
const TITLE_LOGO_LEAST = 40;
const MAX_KEPT = 10;
const TIMEOUT_MS = 60_000;
const ORPHAN_MS = 3_600_000;

export type ArtworkShape = "poster" | "backdrop" | "still" | "logo";

export interface MadePicture {
  id: string;
  provider: string;
  /** Says where it came from; the same source gives the same key. */
  key: string;
  path: string;
  width: number;
  height: number;
}

/** The bytes are not a picture Lobby takes. The message can be shown. */
export class PictureRefused extends Error {}

/** A picture without transparency, or a logo that keeps it. */
type Kept = "opaque" | { logoSide: number; least: number };

function logoScale(side: number): string {
  return `scale=w='min(${side},iw)':h='min(${side},ih)':force_original_aspect_ratio=decrease`;
}

type Format = "jpeg" | "png" | "heic";

/** What the bytes are, whatever the sender called them. */
export function pictureFormat(data: Uint8Array): Format | null {
  const bytes = Buffer.from(data.buffer, data.byteOffset, Math.min(data.byteLength, 32));
  if (bytes.length < 16) return null;
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "jpeg";
  if (bytes.subarray(0, 8).equals(Buffer.from("89504e470d0a1a0a", "hex"))) return "png";
  if (
    bytes.toString("latin1", 4, 8) === "ftyp" &&
    /^(?:heic|heix|heim|heis|mif1|msf1)$/.test(bytes.toString("latin1", 8, 12))
  ) {
    return "heic";
  }
  return null;
}

/** EXIF orientation of a JPEG, 1 (upright) when it says nothing. */
export function jpegOrientation(data: Uint8Array): number {
  const bytes = Buffer.from(data.buffer, data.byteOffset, data.byteLength);
  let offset = 2;
  while (offset + 4 <= bytes.length && bytes[offset] === 0xff) {
    const marker = bytes[offset + 1] ?? 0;
    if (marker === 0xda) return 1;
    const length = bytes.readUInt16BE(offset + 2);
    const segment = bytes.subarray(offset + 4, offset + 2 + length);
    if (marker === 0xe1 && segment.toString("latin1", 0, 4) === "Exif") {
      return exifOrientation(segment.subarray(6));
    }
    offset += 2 + length;
  }
  return 1;
}

function exifOrientation(tiff: Buffer): number {
  if (tiff.length < 14) return 1;
  const little = tiff.toString("latin1", 0, 2) === "II";
  const u16 = (at: number): number => (little ? tiff.readUInt16LE(at) : tiff.readUInt16BE(at));
  const start = little ? tiff.readUInt32LE(4) : tiff.readUInt32BE(4);
  if (start + 2 > tiff.length) return 1;
  const count = u16(start);
  for (let index = 0; index < count; index += 1) {
    const entry = start + 2 + index * 12;
    if (entry + 12 > tiff.length) return 1;
    if (u16(entry) === 0x0112) {
      const value = u16(entry + 8);
      return value >= 1 && value <= 8 ? value : 1;
    }
  }
  return 1;
}

/** ffmpeg filters that turn each EXIF orientation upright. */
const UPRIGHT: Record<number, string[]> = {
  2: ["hflip"],
  3: ["hflip", "vflip"],
  4: ["vflip"],
  5: ["transpose=0"],
  6: ["transpose=1"],
  7: ["transpose=3"],
  8: ["transpose=2"],
};
/** The same for a HEIC's own turn, counted in quarter turns anticlockwise. */
const UNTURN: Record<number, string[]> = {
  1: ["transpose=2"],
  2: ["hflip", "vflip"],
  3: ["transpose=1"],
};

function heicTurns(data: Uint8Array): number {
  const bytes = Buffer.from(data.buffer, data.byteOffset, Math.min(data.byteLength, 65_536));
  // A box of nine bytes: its size, its name, and the angle.
  const at = bytes.indexOf(Buffer.from([0, 0, 0, 9, 0x69, 0x72, 0x6f, 0x74]));
  return at === -1 ? 0 : (bytes[at + 8] ?? 0) & 3;
}

interface ProbedStream {
  index: number;
  codec_type?: string;
  width?: number;
  height?: number;
}
interface ProbedGrid {
  coded_width: number;
  coded_height: number;
  horizontal_offset: number;
  vertical_offset: number;
  width: number;
  height: number;
  subcomponents: {
    stream_index: number;
    tile_horizontal_offset: number;
    tile_vertical_offset: number;
  }[];
}
interface Probed {
  streams?: ProbedStream[];
  stream_groups?: { type?: string; components?: ProbedGrid[] }[];
}

/**
 * Makes the pictures a manager picks: a frame at a moment of their choosing, or one from
 * their device. An uploaded picture is never kept as it came: it is decoded and written
 * again, which leaves out everything in it that is not the picture.
 */
export class ChosenArtwork {
  private readonly db: Database;
  private readonly dir: string;
  private readonly ffmpegPath: string;
  private readonly ffprobePath: string;
  private readonly kept: number;
  private running: Promise<unknown> = Promise.resolve();

  /** `kept`: how many uploads and chosen frames an item keeps per kind, the chosen one included. */
  constructor(
    db: Database,
    options: { dir: string; ffmpegPath: string; ffprobePath: string; kept?: number },
  ) {
    this.db = db;
    this.dir = options.dir;
    this.ffmpegPath = options.ffmpegPath;
    this.ffprobePath = options.ffprobePath;
    this.kept = options.kept ?? MAX_KEPT;
  }

  /** One at a time: this shares a small machine with playback. */
  private queued<T>(work: () => Promise<T>): Promise<T> {
    const result = this.running.then(work);
    this.running = result.catch(() => undefined);
    return result;
  }

  async frame(
    source: string,
    asset: { id: string; revision: string },
    positionMs: number,
    shape: ArtworkShape,
  ): Promise<MadePicture> {
    const [width, height] = shape === "poster" ? [720, 1080] : [1280, 720];
    const fill = `scale=iw*sar:ih,scale=${width}:${height}:force_original_aspect_ratio=increase,crop=${width}:${height},format=yuvj420p`;
    return this.queued(() =>
      this.write(CHOSEN_FRAME_PROVIDER, `${asset.id}:${asset.revision}:${positionMs}`, [
        ...["-threads", "2", "-ss", (positionMs / 1000).toFixed(3)],
        ...["-i", source, "-an", "-sn", "-vf", fill],
      ]),
    );
  }

  async upload(data: Uint8Array): Promise<MadePicture> {
    return this.decoded(data, "opaque", (args) =>
      this.write(UPLOAD_PROVIDER, createHash("sha256").update(data).digest("hex"), args),
    );
  }

  /** A logo: checked like any upload, written as a small PNG that keeps its transparency. */
  async logo(
    data: Uint8Array,
    side = LOGO_SIDE,
    least = MIN_SIDE,
  ): Promise<{ id: string; width: number; height: number; transparent: boolean; data: Buffer }> {
    return this.decoded(data, { logoSide: side, least }, async (args) => {
      const path = join(this.dir, `${randomUUID()}.upload`);
      const plane = `${path}.upload`;
      try {
        await run(this.ffmpegPath, [
          ...["-v", "error", "-nostdin", ...args, "-frames:v", "1", "-map_metadata", "-1"],
          // The encoder's own name is no part of the picture.
          ...["-fflags", "+bitexact", "-flags:v", "+bitexact"],
          ...["-c:v", "png", "-f", "image2", "-update", "1", "-y", path],
        ]);
        await run(this.ffmpegPath, [
          ...["-v", "error", "-nostdin", "-f", "png_pipe", "-i", path],
          ...["-vf", "alphaextract,format=gray", "-f", "rawvideo", "-y", plane],
        ]);
        const made = await readFile(path);
        const alpha = await readFile(plane);
        if (!alpha.some((value) => value > 0)) {
          throw new PictureRefused("That picture is completely transparent.");
        }
        return {
          id: createHash("sha256").update(made).digest("hex").slice(0, 32),
          width: made.readUInt32BE(16),
          height: made.readUInt32BE(20),
          transparent: alpha.some((value) => value < 128),
          data: made,
        };
      } finally {
        await rm(path, { force: true });
        await rm(plane, { force: true });
      }
    });
  }

  /** A title's logo from a manager's device, kept as a file like its other pictures. */
  async titleLogo(data: Uint8Array): Promise<MadePicture> {
    const { width, height, data: png } = await this.logo(data, TITLE_LOGO_SIDE, TITLE_LOGO_LEAST);
    const id = randomUUID();
    const path = join(this.dir, `chosen-${id}.png`);
    const part = `${path}.part`;
    try {
      await writeFile(part, png);
      await rename(part, path);
    } finally {
      await rm(part, { force: true });
    }
    const key = createHash("sha256").update(data).digest("hex");
    return { id, provider: UPLOAD_PROVIDER, key, path, width, height };
  }

  /** Checks an upload and hands over how to read it: ffmpeg's arguments up to its output. */
  private decoded<T>(data: Uint8Array, as: Kept, work: (args: string[]) => Promise<T>): Promise<T> {
    const format = pictureFormat(data);
    if (!format) throw new PictureRefused("That file is not a JPEG, PNG or HEIC picture.");
    return this.queued(async () => {
      await mkdir(this.dir, { recursive: true });
      const source = join(this.dir, `${randomUUID()}.upload`);
      try {
        await writeFile(source, data);
        const demuxer = { jpeg: "jpeg_pipe", png: "png_pipe", heic: "mov" }[format];
        // Only this one file, read as exactly this format.
        const input = ["-protocol_whitelist", "file", "-f", demuxer];
        const graph = await this.graph(source, input, format, data, as);
        return await work([
          ...["-max_pixels", String(MAX_PIXELS), "-noautorotate"],
          ...input,
          ...["-i", source, "-filter_complex", graph, "-map", "[out]"],
        ]);
      } catch (error) {
        if (error instanceof PictureRefused) throw error;
        throw new PictureRefused("That picture could not be read.");
      } finally {
        await rm(source, { force: true });
      }
    });
  }

  /** How to turn the file into one upright picture of a bounded size. */
  private async graph(
    source: string,
    input: string[],
    format: Format,
    data: Uint8Array,
    as: Kept,
  ): Promise<string> {
    const json = await run(this.ffprobePath, [
      ...["-v", "error", "-max_pixels", String(MAX_PIXELS)],
      ...input,
      ...["-show_streams", ...(format === "heic" ? ["-show_stream_groups"] : [])],
      ...["-of", "json", source],
    ]);
    const probed = JSON.parse(json) as Probed;
    const videos = (probed.streams ?? []).filter((one) => one.codec_type === "video");
    const grid = (probed.stream_groups ?? []).find((one) => one.type === "Tile Grid")
      ?.components?.[0];
    const turn =
      format === "jpeg"
        ? (UPRIGHT[jpegOrientation(data)] ?? [])
        : format === "heic"
          ? (UNTURN[heicTurns(data)] ?? [])
          : [];
    const finish =
      as !== "opaque"
        ? [...turn, logoScale(as.logoSide), "format=rgba[out]"].join(",")
        : [...turn, `scale=w='min(${MAX_WIDTH},iw)':h=-2`, "format=yuvj420p[out]"].join(",");

    if (grid) {
      checkSize(grid.width, grid.height, as);
      const tiles = grid.subcomponents;
      if (tiles.length < 2 || tiles.length > 400) {
        throw new PictureRefused("That picture could not be read.");
      }
      const inputs = tiles.map((tile) => `[0:${tile.stream_index}]`).join("");
      const layout = tiles
        .map((tile) => `${tile.tile_horizontal_offset}_${tile.tile_vertical_offset}`)
        .join("|");
      const crop = `crop=${grid.width}:${grid.height}:${grid.horizontal_offset}:${grid.vertical_offset}`;
      return `${inputs}xstack=inputs=${tiles.length}:layout=${layout},${crop},${finish}`;
    }
    const [only] = videos;
    // Tiles without the layout that says where they go would give a piece of the picture.
    if (!only || (format === "heic" && videos.length > 1)) {
      throw new PictureRefused("That picture could not be read. Try it as a JPEG.");
    }
    checkSize(only.width ?? 0, only.height ?? 0, as);
    const flatten =
      format === "png" && as === "opaque"
        ? // Transparent parts become black rather than noise.
          `[0:${only.index}]format=rgba,split[a][b];[a]drawbox=c=black:t=fill:replace=1[bg];[bg][b]overlay,`
        : `[0:${only.index}]`;
    return `${flatten}${finish}`;
  }

  private async write(provider: string, key: string, args: string[]): Promise<MadePicture> {
    await mkdir(this.dir, { recursive: true });
    const id = randomUUID();
    const path = join(this.dir, `chosen-${id}.jpg`);
    const part = `${path}.part`;
    try {
      await run(this.ffmpegPath, [
        ...["-v", "error", "-nostdin", ...args, "-frames:v", "1", "-map_metadata", "-1"],
        ...["-q:v", "3", "-f", "image2", "-update", "1", "-y", part],
      ]);
      const json = await run(this.ffprobePath, [
        ...["-v", "error", "-f", "jpeg_pipe", "-show_streams", "-of", "json", part],
      ]);
      const [made] = (JSON.parse(json) as Probed).streams ?? [];
      if (!made?.width || !made.height) throw new Error("no picture was written");
      await rename(part, path);
      return { id, provider, key, path, width: made.width, height: made.height };
    } finally {
      await rm(part, { force: true });
    }
  }

  /**
   * Files a picture with its item, and forgets the oldest unused ones. Call inside a
   * transaction. Returns the id to use: the same source twice is one picture.
   */
  save(itemId: string, kind: ArtworkShape, made: MadePicture): string {
    this.db.run(
      `insert into artwork (id, item_id, kind, provider, remote_path, local_path, width, height, selected)
       values (?, ?, ?, ?, ?, ?, ?, ?, 0) on conflict (item_id, kind, provider, remote_path) do nothing`,
      [made.id, itemId, kind, made.provider, made.key, made.path, made.width, made.height],
    );
    const id =
      this.db.get<{ id: string }>(
        "select id from artwork where item_id = ? and kind = ? and provider = ? and remote_path = ?",
        [itemId, kind, made.provider, made.key],
      )?.id ?? made.id;
    this.db.run(
      `delete from artwork where id in (
         select id from artwork where item_id = ? and kind = ? and provider in ('${UPLOAD_PROVIDER}', '${CHOSEN_FRAME_PROVIDER}')
           and id != ? order by locked desc, rowid desc limit -1 offset ${this.kept - 1})`,
      [itemId, kind, id],
    );
    return id;
  }

  /** Removes files whose picture is gone from the catalogue. */
  async tidy(now: number = Date.now()): Promise<void> {
    await mkdir(this.dir, { recursive: true });
    for (const name of await readdir(this.dir)) {
      if (!/^chosen-.*\.(?:jpg|png)(?:\.part)?$|\.upload$/.test(name)) continue;
      const path = join(this.dir, name);
      if (this.db.get("select 1 as x from artwork where local_path = ?", [path])) continue;
      // It may be on its way into the catalogue right now.
      if (now - (await stat(path)).mtimeMs > ORPHAN_MS) await rm(path, { force: true });
    }
  }
}

function checkSize(width: number, height: number, as: Kept): void {
  const least = as === "opaque" ? MIN_SIDE : as.least;
  if (width < least || height < least) {
    throw new PictureRefused("That picture is too small.");
  }
  if (width > MAX_SIDE || height > MAX_SIDE || width * height > MAX_PIXELS) {
    throw new PictureRefused("That picture is too large.");
  }
}

function run(command: string, args: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      stdio: ["ignore", "pipe", "pipe"],
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    if (child.pid !== undefined) {
      try {
        setPriority(child.pid, 10);
      } catch {
        // It already finished.
      }
    }
    const output: Buffer[] = [];
    child.stdout.on("data", (chunk: Buffer) => output.push(chunk));
    let errors = "";
    child.stderr.on("data", (chunk: Buffer) => {
      errors = (errors + chunk.toString()).slice(-300);
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) resolve(Buffer.concat(output).toString("utf8"));
      else reject(new Error(errors.trim().split("\n").at(-1) ?? `ended with ${code}`));
    });
  });
}
