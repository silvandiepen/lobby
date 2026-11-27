// SPDX-License-Identifier: MPL-2.0
import { randomUUID } from "node:crypto";
import { mkdir, open, readdir, readFile, rename, rm, stat } from "node:fs/promises";
import { join } from "node:path";
import { pictureFormat } from "../artwork/chosen.ts";
import { roundWidth } from "../artwork/serve.ts";
import type { Database } from "../db/database.ts";
import { openablePath } from "../http/serve-file.ts";
import { runQuietly, SAFE_INPUT } from "./probe.ts";

const MAX_PIXELS = "80000000";
const MAX_RUNNING = 2;
const MAX_WAITING = 200;
const FILE = /^([0-9a-f]{32})-\d+\.jpg(?:\..+\.part)?$/;

interface Origin {
  id: string;
  root: string;
  rel_path: string;
  /** Set for a picture inside an audio file. */
  stream: number | null;
}

/**
 * Covers at the size a device asks for. The originals stay where they are, beside or inside
 * the audio files; only the scaled versions are kept.
 */
export class CoverStore {
  private readonly db: Database;
  private readonly dir: string;
  private readonly ffmpegPath: string;
  private readonly pending = new Map<string, Promise<string | null>>();
  /** Pictures that could not be decoded, so they are not tried for every row of a list. */
  private readonly broken = new Set<string>();
  private running = 0;
  private readonly waiting: (() => void)[] = [];

  constructor(db: Database, dir: string, ffmpegPath: string) {
    this.db = db;
    this.dir = dir;
    this.ffmpegPath = ffmpegPath;
  }

  /** Removes scaled covers of pictures that are gone. */
  async tidy(): Promise<void> {
    await mkdir(this.dir, { recursive: true });
    for (const name of await readdir(this.dir)) {
      const id = FILE.exec(name)?.[1];
      if (id === undefined || (!name.endsWith(".part") && this.origin(id))) continue;
      await rm(join(this.dir, name), { force: true });
    }
  }

  private origin(id: string): Origin | undefined {
    return (
      this.db.get<Origin>(
        `select music_image.id, music_source.path as root, rel_path, null as stream from music_image
         join music_source on music_source.id = music_image.source_id where music_image.id = ?`,
        [id],
      ) ??
      this.db.get<Origin>(
        `select music_track.id, music_source.path as root, rel_path, cover_stream as stream from music_track
         join music_source on music_source.id = music_track.source_id
         where cover_id = ? order by music_track.available desc limit 1`,
        [id],
      )
    );
  }

  /** The JPEG, or null when there is no such cover. */
  async read(id: string, width: number): Promise<Buffer<ArrayBuffer> | null> {
    if (!/^[0-9a-f]{32}$/.test(id) || this.broken.has(id)) return null;
    const origin = this.origin(id);
    if (!origin) return null;
    const wanted = roundWidth(width);
    const target = join(this.dir, `${id}-${wanted}.jpg`);
    try {
      return await readFile(target);
    } catch {
      // Not scaled to this size yet.
    }
    let work = this.pending.get(target);
    if (!work) {
      work = this.scale(id, origin, target, wanted).finally(() => this.pending.delete(target));
      this.pending.set(target, work);
    }
    const made = await work;
    return made === null ? null : readFile(made);
  }

  private async scale(
    id: string,
    origin: Origin,
    target: string,
    width: number,
  ): Promise<string | null> {
    if (this.running >= MAX_RUNNING) {
      if (this.waiting.length >= MAX_WAITING) return null;
      await new Promise<void>((go) => this.waiting.push(go));
    }
    this.running += 1;
    const part = `${target}.${randomUUID()}.part`;
    try {
      const { path } = await openablePath({
        id: origin.id,
        root: origin.root,
        relPath: origin.rel_path,
      });
      const input = await this.input(path, origin.stream);
      if (!input) {
        this.broken.add(id);
        return null;
      }
      await mkdir(this.dir, { recursive: true });
      await runQuietly(this.ffmpegPath, [
        ...["-v", "error", "-nostdin", "-max_pixels", MAX_PIXELS, ...input],
        ...["-vf", `scale='min(${width},iw)':-2,format=yuvj420p`, "-frames:v", "1"],
        ...["-map_metadata", "-1", "-q:v", "4", "-f", "image2", "-update", "1", "-y", part],
      ]);
      await stat(part);
      await rename(part, target);
      return target;
    } catch (error) {
      if (await this.reachable(origin)) {
        this.broken.add(id);
        return null;
      }
      throw error;
    } finally {
      await rm(part, { force: true });
      this.running -= 1;
      this.waiting.shift()?.();
    }
  }

  private async reachable(origin: Origin): Promise<boolean> {
    try {
      await stat(join(origin.root, origin.rel_path));
      return true;
    } catch {
      return false;
    }
  }

  private async input(path: string, stream: number | null): Promise<string[] | null> {
    if (stream !== null) return [...SAFE_INPUT, "-i", path, "-map", `0:${stream}`];
    const head = Buffer.alloc(32);
    const handle = await open(path, "r");
    try {
      await handle.read(head, 0, head.length, 0);
    } finally {
      await handle.close();
    }
    const format = pictureFormat(head);
    if (format !== "jpeg" && format !== "png") return null;
    return ["-protocol_whitelist", "file", "-f", `${format}_pipe`, "-i", path];
  }
}
