// SPDX-License-Identifier: MPL-2.0
import type { Database } from "../db/database.ts";

/** Counts changes to what viewers keep (favourites, playlists), apart from the catalogue's. */
export class ViewerRevision {
  private readonly db: Database;

  constructor(db: Database) {
    this.db = db;
  }

  get current(): number {
    return Number(this.db.getMeta("music_viewer_revision") ?? "0");
  }

  /** Call inside a transaction. */
  next(): number {
    const next = this.current + 1;
    this.db.setMeta("music_viewer_revision", String(next));
    return next;
  }
}
