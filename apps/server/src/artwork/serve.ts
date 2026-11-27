// SPDX-License-Identifier: MPL-2.0
import { spawn } from "node:child_process";
import { mkdir, readFile, rename, rm, stat } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { join } from "node:path";
import { Gate } from "../gate.ts";
import type { Database } from "../db/database.ts";

/** 1280 and 1920 are a banner's; the stored pictures go no wider. */
const WIDTHS = [200, 400, 800, 1280, 1600, 1920];
const MAX_RUNNING = 2;
/** More than any screen shows, for every device of a household. */
const MAX_WAITING = 1_000;

/** The smallest offered width that covers `requested`. */
export function roundWidth(requested: number): number {
  return WIDTHS.find((width) => width >= requested) ?? 1920;
}

/** Hands out artwork at the size a device asks for, scaling each size once. */
export class ArtworkStore {
  private readonly db: Database;
  private readonly cacheDir: string;
  private readonly ffmpegPath: string;
  private readonly pending = new Map<string, Promise<string>>();
  private readonly gate = new Gate(MAX_RUNNING, MAX_WAITING);

  constructor(db: Database, cacheDir: string, ffmpegPath: string) {
    this.db = db;
    this.cacheDir = cacheDir;
    this.ffmpegPath = ffmpegPath;
  }

  /** The JPEG, or the PNG of a logo; null when there is no such artwork. */
  async read(
    id: string,
    width: number,
  ): Promise<{ data: Buffer<ArrayBuffer>; type: "image/jpeg" | "image/png" } | null> {
    const row = this.db.get<{ local_path: string | null; width: number | null }>(
      "select local_path, width from artwork where id = ?",
      [id],
    );
    if (!row?.local_path) return null;
    const wanted = roundWidth(width);
    const path =
      row.width !== null && row.width <= wanted
        ? row.local_path
        : await this.scaled(id, row.local_path, wanted);
    const type = path.endsWith(".png") ? "image/png" : "image/jpeg";
    return { data: await readFile(path), type };
  }

  private async scaled(id: string, source: string, width: number): Promise<string> {
    const png = source.endsWith(".png");
    const target = join(this.cacheDir, `${id}-${width}.${png ? "png" : "jpg"}`);
    try {
      await stat(target);
      return target;
    } catch {
      // Not scaled to this size yet.
    }
    let work = this.pending.get(target);
    if (!work) {
      work = this.gate
        .run(() => this.scale(source, target, width))
        .finally(() => this.pending.delete(target));
      this.pending.set(target, work);
    }
    return work;
  }

  private async scale(source: string, target: string, width: number): Promise<string> {
    const part = `${target}.${randomUUID()}.part`;
    const png = source.endsWith(".png");
    try {
      await mkdir(this.cacheDir, { recursive: true });
      await new Promise<void>((resolve, reject) => {
        const child = spawn(
          this.ffmpegPath,
          [
            ...["-v", "error", "-nostdin", "-i", source, "-frames:v", "1"],
            ...["-vf", `scale='min(${width},iw)':-2${png ? ",format=rgba" : ""}`],
            ...(png ? ["-c:v", "png"] : ["-c:v", "mjpeg", "-q:v", "4"]),
            ...["-f", "image2", "-update", "1", "-y", part],
          ],
          { stdio: "ignore" },
        );
        child.on("error", reject);
        child.on("close", (code) => {
          if (code === 0) resolve();
          else reject(new Error(`Scaling artwork failed (${code})`));
        });
      });
      await rename(part, target);
      return target;
    } finally {
      await rm(part, { force: true });
    }
  }
}
