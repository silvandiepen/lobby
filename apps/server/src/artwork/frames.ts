// SPDX-License-Identifier: MPL-2.0
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdir, rename, rm, stat } from "node:fs/promises";
import { setPriority } from "node:os";
import { join } from "node:path";
import type { Database } from "../db/database.ts";
import type { Catalogue } from "../library/catalogue.ts";
import { errorMessage, log } from "../log.ts";

export const FRAME_PROVIDER = "frame";
const WIDTH = 1280;
/** A frame this small as a JPEG is close to one colour: a fade, or the black before a title. */
const DULL_BYTES = 30_000;
const POSITIONS = [0.2, 0.35, 0.5];
const TIMEOUT_MS = 60_000;

export interface FrameMakerOptions {
  dir: string;
  ffmpegPath: string;
  /** How many pictures become visible to the apps at once. */
  batchSize?: number;
}

interface Wanted {
  asset_id: string;
  revision: string;
  duration_ms: number | null;
  rel_path: string;
  source_path: string;
  item_id: string;
  item_kind: string;
}

interface Made {
  itemId: string;
  kind: "backdrop" | "still";
  key: string;
  path: string;
  width: number;
  height: number;
}

/**
 * Gives every episode a still, and every film and show a backdrop, from the files
 * themselves. One ffmpeg at a time at low priority; nothing is written near the media.
 * Pictures from a metadata provider are chosen over these.
 */
export class FrameMaker {
  private readonly db: Database;
  private readonly catalogue: Catalogue;
  private readonly options: FrameMakerOptions;
  /** Files no frame could be read from, by asset and revision, until the next start. */
  private readonly failed = new Set<string>();
  private running = false;
  private readonly stopping = new AbortController();

  constructor(db: Database, catalogue: Catalogue, options: FrameMakerOptions) {
    this.db = db;
    this.catalogue = catalogue;
    this.options = options;
  }

  stop(): void {
    this.stopping.abort();
  }

  private isStopping(): boolean {
    return this.stopping.signal.aborted;
  }

  /** Makes every missing picture. Returns how many it made. */
  async run(): Promise<number> {
    if (this.running || this.isStopping()) return 0;
    this.running = true;
    try {
      await mkdir(this.options.dir, { recursive: true });
      await this.forgetReplaced();
      let count = 0;
      let batch: Made[] = [];
      for (const wanted of this.wanted()) {
        if (this.isStopping()) break;
        const made = await this.make(wanted);
        if (made === null) continue;
        batch.push(made);
        count += 1;
        if (batch.length >= (this.options.batchSize ?? 25)) {
          this.save(batch);
          batch = [];
        }
      }
      if (this.isStopping()) {
        // The database is being closed. These are made again at the next start.
        for (const made of batch) await rm(made.path, { force: true });
        return count - batch.length;
      }
      this.save(batch);
      this.adoptForShows();
      if (count > 0) log.info("Made pictures from films and episodes", { count });
      return count;
    } finally {
      this.running = false;
    }
  }

  private wanted(): Wanted[] {
    return this.db
      .all<Wanted>(
        `select asset.id as asset_id, asset.revision, asset.duration_ms, asset.rel_path,
           source.path as source_path, item.id as item_id, item.kind as item_kind
         from item
         join item_asset on item_asset.item_id = item.id and item_asset.role = 'main'
         join asset on asset.id = item_asset.asset_id
         join source on source.id = asset.source_id
         where item.kind in ('movie', 'episode') and asset.state = 'probed'
           and asset.available = 1 and source.available = 1
           and not exists (select 1 from artwork where artwork.item_id = item.id
             and artwork.provider = '${FRAME_PROVIDER}')
         group by item.id having asset.id = min(asset.id)
         order by item.kind desc, item.added_at desc`,
      )
      .filter((row) => !this.failed.has(`${row.asset_id}:${row.revision}`));
  }

  private async make(wanted: Wanted): Promise<Made | null> {
    const source = join(wanted.source_path, wanted.rel_path);
    const name = `${randomUUID()}.jpg`;
    const path = join(this.options.dir, name);
    let best = 0;
    for (const position of POSITIONS) {
      const attempt = `${path}.part`;
      try {
        await this.grab(source, ((wanted.duration_ms ?? 0) * position) / 1000, attempt);
        const { size } = await stat(attempt);
        if (size > best) {
          await rename(attempt, path);
          best = size;
        }
      } catch (error) {
        if (this.isStopping()) break;
        log.warn("Could not read a picture from a file", {
          asset: wanted.asset_id,
          error: errorMessage(error),
        });
        break;
      } finally {
        await rm(attempt, { force: true });
      }
      if (best >= DULL_BYTES) break;
    }
    if (best === 0) {
      if (!this.isStopping()) this.failed.add(`${wanted.asset_id}:${wanted.revision}`);
      return null;
    }
    return {
      itemId: wanted.item_id,
      kind: wanted.item_kind === "episode" ? "still" : "backdrop",
      key: `${wanted.asset_id}:${wanted.revision}`,
      path,
      width: WIDTH,
      height: Math.round((WIDTH * 9) / 16),
    };
  }

  private grab(source: string, seconds: number, target: string): Promise<void> {
    const args = ["-v", "error", "-nostdin", "-threads", "2", "-ss", seconds.toFixed(2)];
    args.push("-i", source, "-an", "-sn", "-frames:v", "1");
    // Square pixels first, then filled to 16:9, so every tile is the same shape.
    const shape = `scale=iw*sar:ih,scale=${WIDTH}:720:force_original_aspect_ratio=increase,crop=${WIDTH}:720,format=yuvj420p`;
    args.push("-vf", shape, "-q:v", "4", "-f", "image2", "-update", "1", "-y", target);
    return new Promise((resolve, reject) => {
      const child = spawn(this.options.ffmpegPath, args, {
        stdio: ["ignore", "ignore", "pipe"],
        signal: AbortSignal.any([this.stopping.signal, AbortSignal.timeout(TIMEOUT_MS)]),
      });
      if (child.pid !== undefined) {
        try {
          setPriority(child.pid, 15);
        } catch {
          // It already finished.
        }
      }
      let errors = "";
      child.stderr.on("data", (chunk: Buffer) => {
        errors = (errors + chunk.toString()).slice(-500);
      });
      child.on("error", reject);
      child.on("close", (code) => {
        if (code === 0) resolve();
        else reject(new Error(errors.trim().split("\n").at(-1) ?? `ffmpeg ended with ${code}`));
      });
    });
  }

  private save(batch: Made[]): void {
    if (batch.length === 0) return;
    this.db.transaction(() => {
      const revision = this.db.nextRevision();
      for (const made of batch) {
        // The item may have gone while its picture was being made.
        if (!this.db.get("select 1 as x from item where id = ?", [made.itemId])) continue;
        this.insert(made);
        this.catalogue.touch(made.itemId, revision);
      }
    });
  }

  private insert(made: Made): void {
    const chosen = this.db.get(
      "select 1 as x from artwork where item_id = ? and kind = ? and selected = 1",
      [made.itemId, made.kind],
    );
    this.db.run(
      `insert into artwork (id, item_id, kind, provider, remote_path, local_path, width, height, selected)
       values (?, ?, ?, '${FRAME_PROVIDER}', ?, ?, ?, ?, ?)`,
      [
        randomUUID(),
        made.itemId,
        made.kind,
        made.key,
        made.path,
        made.width,
        made.height,
        chosen ? 0 : 1,
      ],
    );
  }

  /** A show borrows the picture of its first episode. */
  private adoptForShows(): void {
    const shows = this.db.all<{ id: string; key: string; local_path: string }>(
      `select show.id, artwork.remote_path as key, artwork.local_path
       from item as show
       join item as season on season.parent_id = show.id
       join item as episode on episode.parent_id = season.id or episode.id = season.id
       join artwork on artwork.item_id = episode.id and artwork.provider = '${FRAME_PROVIDER}'
       where show.kind = 'show' and episode.kind = 'episode'
         and not exists (select 1 from artwork as own where own.item_id = show.id
           and own.provider = '${FRAME_PROVIDER}')
       order by coalesce(season.season_number, 9999) = 0, season.season_number, episode.episode_number`,
    );
    const first = new Map<string, Made>();
    for (const show of shows) {
      if (first.has(show.id)) continue;
      first.set(show.id, {
        itemId: show.id,
        kind: "backdrop",
        key: show.key,
        path: show.local_path,
        width: WIDTH,
        height: Math.round((WIDTH * 9) / 16),
      });
    }
    this.save([...first.values()]);
  }

  /** Drops pictures of files that were replaced or removed, so they are made again. */
  private async forgetReplaced(): Promise<void> {
    const stale = this.db.all<{ id: string; item_id: string; kind: string; local_path: string }>(
      `select artwork.id, artwork.item_id, artwork.kind, artwork.local_path from artwork
       where provider = '${FRAME_PROVIDER}' and locked = 0 and not exists (
         select 1 from asset where asset.id || ':' || asset.revision = artwork.remote_path)`,
    );
    if (stale.length === 0) return;
    this.db.transaction(() => {
      const revision = this.db.nextRevision();
      for (const row of stale) {
        this.db.run("delete from artwork where id = ?", [row.id]);
        this.catalogue.touch(row.item_id, revision);
      }
    });
    for (const row of stale) {
      const used = this.db.get("select 1 as x from artwork where local_path = ?", [row.local_path]);
      if (!used) await rm(row.local_path, { force: true });
    }
  }
}
