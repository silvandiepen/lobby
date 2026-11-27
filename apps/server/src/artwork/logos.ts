// SPDX-License-Identifier: MPL-2.0
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import type { Database } from "../db/database.ts";
import { errorMessage, log } from "../log.ts";

const IMAGE_BASE = "https://image.tmdb.org/t/p/w500";
const MAX_BYTES = 2 * 1024 * 1024;
const MAX_SIDE = 4000;
const RETRY_MS = 10 * 60_000;
const PNG = Buffer.from("89504e470d0a1a0a", "hex");

/** A studio's logo on TMDB, e.g. "/1TjvGVDMYsj6JBxOAkUHpPEwLf7.png". */
export const LOGO_PATH = /^\/[A-Za-z0-9]{8,64}\.png$/;

/**
 * The pictures of the household's logos: PNGs in the catalogue itself, so a backup holds
 * them. Logos named by the config are fetched from TMDB when they are not there yet.
 */
export class LogoStore {
  private readonly db: Database;
  /** Where logos were kept before they moved into the catalogue. */
  private readonly oldDir: string;
  private readonly baseUrl: string;
  private timer: NodeJS.Timeout | null = null;
  private readonly stopping = new AbortController();

  constructor(db: Database, oldDir: string, baseUrl: string = IMAGE_BASE) {
    this.db = db;
    this.oldDir = oldDir;
    this.baseUrl = baseUrl;
  }

  /** Gets the pictures that are missing, again later if that fails. */
  async start(): Promise<void> {
    let missing = false;
    for (const logo of this.db.all<{ id: string; remote_path: string }>(
      "select id, remote_path from logo where data is null and remote_path is not null",
    )) {
      try {
        const data = await this.load(logo.id, logo.remote_path);
        if (this.stopping.signal.aborted) return;
        const { width, height } = pngSize(data);
        this.db.transaction(() => {
          const filled = this.db.run(
            "update logo set data = ?, width = ?, height = ? where id = ? and data is null",
            [data, width, height, logo.id],
          );
          if (filled > 0) this.db.nextRevision();
        });
      } catch (error) {
        if (this.stopping.signal.aborted) return;
        missing = true;
        log.warn("Could not fetch a category's logo", {
          logo: logo.id,
          error: errorMessage(error),
        });
      }
    }
    if (missing) {
      this.timer = setTimeout(() => void this.start(), RETRY_MS);
      this.timer.unref();
    }
  }

  stop(): void {
    this.stopping.abort();
    if (this.timer) clearTimeout(this.timer);
  }

  read(id: string): Uint8Array<ArrayBuffer> | null {
    return (
      this.db.get<{ data: Uint8Array<ArrayBuffer> | null }>("select data from logo where id = ?", [
        id,
      ])?.data ?? null
    );
  }

  /** A logo's picture from TMDB. */
  async fetch(path: string): Promise<Uint8Array<ArrayBuffer>> {
    if (!LOGO_PATH.test(path)) throw new Error("Not a logo's path.");
    const response = await fetch(`${this.baseUrl}${path}`, {
      redirect: "error",
      signal: AbortSignal.any([this.stopping.signal, AbortSignal.timeout(20_000)]),
    });
    if (!response.ok) throw new Error(`TMDB answered ${String(response.status)}`);
    if (Number(response.headers.get("content-length") ?? "0") > MAX_BYTES) {
      throw new Error("The logo is too large.");
    }
    const data = new Uint8Array(await response.arrayBuffer());
    if (data.byteLength > MAX_BYTES) throw new Error("The logo is too large.");
    pngSize(data);
    return data;
  }

  private async load(id: string, path: string): Promise<Uint8Array<ArrayBuffer>> {
    let kept: Uint8Array<ArrayBuffer>;
    try {
      kept = new Uint8Array(await readFile(join(this.oldDir, `${id}.png`)));
    } catch {
      return this.fetch(path);
    }
    pngSize(kept);
    return kept;
  }
}

export function pngSize(data: Uint8Array): { width: number; height: number } {
  const bytes = Buffer.from(data.buffer, data.byteOffset, data.byteLength);
  if (bytes.length < 24 || !bytes.subarray(0, 8).equals(PNG)) throw new Error("Not a PNG.");
  const width = bytes.readUInt32BE(16);
  const height = bytes.readUInt32BE(20);
  if (width === 0 || height === 0) throw new Error("An empty picture.");
  if (width > MAX_SIDE || height > MAX_SIDE) throw new Error("The logo is too large.");
  return { width, height };
}
