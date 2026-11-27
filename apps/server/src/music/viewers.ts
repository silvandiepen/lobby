// SPDX-License-Identifier: MPL-2.0
import type { Database } from "../db/database.ts";
import type { MusicKind } from "./types.ts";
import { ViewerRevision } from "./viewer-revision.ts";

export interface Favourite {
  itemId: string;
  kind: MusicKind;
  favourite: boolean;
  updatedAt: number;
}

export interface Playlist {
  id: string;
  name: string;
  trackIds: string[];
  revision: number;
  createdAt: number;
  updatedAt: number;
}

export interface Play {
  opId: string;
  trackId: string;
  playedAt: number;
  playedMs: number;
  completed: boolean;
}

export const MAX_PLAYLIST_TRACKS = 10_000;
export const MAX_PLAYLISTS = 500;

interface FavouriteRow {
  item_id: string;
  kind: MusicKind;
  favourite: number;
  updated_at: number;
}

interface PlaylistRow {
  id: string;
  profile_id: string;
  name: string;
  tracks_json: string;
  edit_revision: number;
  revision: number;
  created_at: number;
  updated_at: number;
  deleted_at: number | null;
}

interface PlayRow {
  op_id: string;
  track_id: string;
  played_at: number;
  played_ms: number;
  completed: number;
}

export type PlaylistOutcome =
  | { outcome: "ok"; playlist: Playlist }
  | { outcome: "conflict"; playlist: Playlist }
  | { outcome: "not_found" }
  | { outcome: "unknown_track" }
  | { outcome: "too_many" };

const toFavourite = (row: FavouriteRow): Favourite => ({
  itemId: row.item_id,
  kind: row.kind,
  favourite: row.favourite === 1,
  updatedAt: row.updated_at,
});

const toPlaylist = (row: PlaylistRow): Playlist => ({
  id: row.id,
  name: row.name,
  trackIds: JSON.parse(row.tracks_json) as string[],
  revision: row.edit_revision,
  createdAt: row.created_at,
  updatedAt: row.updated_at,
});

/**
 * What each viewer keeps about music. Devices are offline for days, so a change can be sent
 * again safely, and one made against an old state never silently undoes a newer one.
 */
export class MusicViewers {
  private readonly db: Database;
  private readonly now: () => number;
  private readonly counter: ViewerRevision;

  constructor(db: Database, now: () => number = Date.now) {
    this.db = db;
    this.now = now;
    this.counter = new ViewerRevision(db);
  }

  get revision(): number {
    return this.counter.current;
  }

  // ---- Favourites ----

  favourites(profileId: string, since: number): Favourite[] {
    return this.db
      .all<FavouriteRow>(
        "select item_id, kind, favourite, updated_at from music_favourite where profile_id = ? and revision > ? order by revision",
        [profileId, since],
      )
      .map(toFavourite);
  }

  /** The later change wins; a device's clock cannot run ahead of the server's. */
  setFavourite(
    profileId: string,
    itemId: string,
    kind: MusicKind,
    favourite: boolean,
    at: number,
  ): { accepted: boolean; favourite: Favourite } {
    return this.db.transaction(() => {
      const updatedAt = Math.min(at, this.now());
      const current = this.db.get<FavouriteRow>(
        "select item_id, kind, favourite, updated_at from music_favourite where profile_id = ? and item_id = ?",
        [profileId, itemId],
      );
      if (current && (current.favourite === 1) === favourite) {
        return { accepted: true, favourite: toFavourite(current) };
      }
      if (current && updatedAt < current.updated_at) {
        return { accepted: false, favourite: toFavourite(current) };
      }
      this.db.run(
        `insert into music_favourite (profile_id, item_id, kind, favourite, updated_at, revision)
         values (?, ?, ?, ?, ?, ?)
         on conflict (profile_id, item_id) do update set favourite = excluded.favourite,
           updated_at = excluded.updated_at, revision = excluded.revision`,
        [profileId, itemId, kind, favourite ? 1 : 0, updatedAt, this.counter.next()],
      );
      return { accepted: true, favourite: { itemId, kind, favourite, updatedAt } };
    });
  }

  // ---- Playlists ----

  playlists(profileId: string, since: number): { playlists: Playlist[]; removed: string[] } {
    const rows = this.db.all<PlaylistRow>(
      "select * from music_playlist where profile_id = ? and revision > ? order by revision",
      [profileId, since],
    );
    return {
      playlists: rows.filter((row) => row.deleted_at === null).map(toPlaylist),
      removed:
        since === 0 ? [] : rows.filter((row) => row.deleted_at !== null).map((row) => row.id),
    };
  }

  private row(profileId: string, id: string): PlaylistRow | undefined {
    return this.db.get<PlaylistRow>(
      "select * from music_playlist where id = ? and profile_id = ?",
      [id, profileId],
    );
  }

  playlist(profileId: string, id: string): Playlist | null {
    const row = this.row(profileId, id);
    return row?.deleted_at === null ? toPlaylist(row) : null;
  }

  private allKnown(trackIds: string[]): boolean {
    const wanted = [...new Set(trackIds)];
    const known =
      this.db.get<{ n: number }>(
        `select count(*) as n from json_each(?) as wanted
         cross join music_change on music_change.id = wanted.value
         where music_change.kind = 'track' and music_change.removed = 0`,
        [JSON.stringify(wanted)],
      )?.n ?? 0;
    return known === wanted.length;
  }

  /** The device chooses the id, so creating again after a lost answer is the same playlist. */
  create(profileId: string, id: string, name: string, trackIds: string[]): PlaylistOutcome {
    return this.db.transaction((): PlaylistOutcome => {
      const existing = this.db.get<PlaylistRow>("select * from music_playlist where id = ?", [id]);
      if (existing) {
        return existing.profile_id === profileId && existing.deleted_at === null
          ? { outcome: "ok", playlist: toPlaylist(existing) }
          : { outcome: "not_found" };
      }
      const count =
        this.db.get<{ n: number }>(
          "select count(*) as n from music_playlist where profile_id = ? and deleted_at is null",
          [profileId],
        )?.n ?? 0;
      if (count >= MAX_PLAYLISTS) return { outcome: "too_many" };
      if (!this.allKnown(trackIds)) return { outcome: "unknown_track" };
      const at = this.now();
      this.db.run(
        `insert into music_playlist (id, profile_id, name, tracks_json, revision, created_at, updated_at)
         values (?, ?, ?, ?, ?, ?, ?)`,
        [id, profileId, name, JSON.stringify(trackIds), this.counter.next(), at, at],
      );
      return this.done(profileId, id);
    });
  }

  private done(profileId: string, id: string): PlaylistOutcome {
    const playlist = this.playlist(profileId, id);
    return playlist ? { outcome: "ok", playlist } : { outcome: "not_found" };
  }

  /** A new name, or a new order and contents, based on the revision the device saw. */
  update(
    profileId: string,
    id: string,
    revision: number,
    change: { name?: string; trackIds?: string[] },
  ): PlaylistOutcome {
    return this.db.transaction((): PlaylistOutcome => {
      const row = this.row(profileId, id);
      if (row?.deleted_at !== null) return { outcome: "not_found" };
      const current = toPlaylist(row);
      const next = {
        name: change.name ?? current.name,
        trackIds: change.trackIds ?? current.trackIds,
      };
      // A retry of a change that arrived, or two devices wanting the same.
      if (
        next.name === current.name &&
        JSON.stringify(next.trackIds) === JSON.stringify(current.trackIds)
      ) {
        return { outcome: "ok", playlist: current };
      }
      if (current.revision !== revision) return { outcome: "conflict", playlist: current };
      if (change.trackIds && !this.allKnown(change.trackIds)) return { outcome: "unknown_track" };
      this.save(id, next.name, next.trackIds);
      return this.done(profileId, id);
    });
  }

  /** Adds to the end. Never a conflict: two devices that add both get their tracks in. */
  append(profileId: string, id: string, opId: string, trackIds: string[]): PlaylistOutcome {
    return this.db.transaction((): PlaylistOutcome => {
      const row = this.row(profileId, id);
      if (row?.deleted_at !== null) return { outcome: "not_found" };
      const current = toPlaylist(row);
      if (
        this.db.get("select 1 as x from music_playlist_op where playlist_id = ? and op_id = ?", [
          id,
          opId,
        ])
      ) {
        return { outcome: "ok", playlist: current };
      }
      if (current.trackIds.length + trackIds.length > MAX_PLAYLIST_TRACKS) {
        return { outcome: "too_many" };
      }
      if (!this.allKnown(trackIds)) return { outcome: "unknown_track" };
      this.db.run(
        "insert into music_playlist_op (op_id, playlist_id, created_at) values (?, ?, ?)",
        [opId, id, this.now()],
      );
      this.save(id, current.name, [...current.trackIds, ...trackIds]);
      return this.done(profileId, id);
    });
  }

  private save(id: string, name: string, trackIds: string[]): void {
    this.db.run(
      `update music_playlist set name = ?, tracks_json = ?, edit_revision = edit_revision + 1,
         revision = ?, updated_at = ? where id = ?`,
      [name, JSON.stringify(trackIds), this.counter.next(), this.now(), id],
    );
  }

  remove(profileId: string, id: string, revision: number): PlaylistOutcome {
    return this.db.transaction((): PlaylistOutcome => {
      const row = this.row(profileId, id);
      if (!row) return { outcome: "not_found" };
      const playlist = toPlaylist(row);
      if (row.deleted_at !== null) return { outcome: "ok", playlist };
      if (row.edit_revision !== revision) return { outcome: "conflict", playlist };
      this.db.run(
        "update music_playlist set deleted_at = ?, tracks_json = '[]', revision = ? where id = ?",
        [this.now(), this.counter.next(), id],
      );
      return { outcome: "ok", playlist };
    });
  }

  /** The playlist for other players, with the files' paths inside their library folders. */
  exportM3u(playlist: Playlist): string {
    const line = (text: string): string => text.replace(/[\r\n]+/g, " ");
    const rows = this.db.all<{
      title: string;
      artist_credit: string;
      duration_ms: number | null;
      rel_path: string;
    }>(
      `select title, artist_credit, duration_ms, rel_path from json_each(?) as wanted
       cross join music_track on music_track.id = wanted.value order by wanted.key`,
      [JSON.stringify(playlist.trackIds)],
    );
    return [
      "#EXTM3U",
      `#PLAYLIST:${line(playlist.name)}`,
      ...rows.flatMap((row) => [
        `#EXTINF:${row.duration_ms === null ? -1 : Math.round(row.duration_ms / 1000)},` +
          line(row.artist_credit === "" ? row.title : `${row.artist_credit} - ${row.title}`),
        // "./" so that a file named "#1.mp3" is not a comment.
        line(row.rel_path.startsWith("#") ? `./${row.rel_path}` : row.rel_path),
      ]),
      "",
    ].join("\n");
  }

  // ---- Play history ----

  addPlays(profileId: string, plays: Play[]): { accepted: number; unknown: number } {
    return this.db.transaction(() => {
      let accepted = 0;
      let unknown = 0;
      for (const play of plays) {
        if (!this.allKnown([play.trackId])) {
          unknown += 1;
          continue;
        }
        // Sent again after a lost answer: it is there already.
        this.db.run(
          `insert into music_play (op_id, profile_id, track_id, played_at, played_ms, completed)
           values (?, ?, ?, ?, ?, ?) on conflict (profile_id, op_id) do nothing`,
          [
            play.opId,
            profileId,
            play.trackId,
            Math.min(play.playedAt, this.now()),
            play.playedMs,
            play.completed ? 1 : 0,
          ],
        );
        accepted += 1;
      }
      return { accepted, unknown };
    });
  }

  /** Newest first. */
  plays(
    profileId: string,
    before: { playedAt: number; opId: string } | null,
    limit: number,
  ): { plays: Play[]; more: boolean } {
    const rows = this.db.all<PlayRow>(
      `select op_id, track_id, played_at, played_ms, completed from music_play
       where profile_id = ? and (played_at, op_id) < (?, ?)
       order by played_at desc, op_id desc limit ?`,
      [profileId, before?.playedAt ?? Number.MAX_SAFE_INTEGER, before?.opId ?? "", limit + 1],
    );
    return {
      plays: rows.slice(0, limit).map((row) => ({
        opId: row.op_id,
        trackId: row.track_id,
        playedAt: row.played_at,
        playedMs: row.played_ms,
        completed: row.completed === 1,
      })),
      more: rows.length > limit,
    };
  }

  /** How often and when last, per track: for "most played" and smart shelves. */
  playCounts(profileId: string): { trackId: string; plays: number; lastPlayedAt: number }[] {
    return this.db
      .all<{ track_id: string; plays: number; last: number }>(
        `select track_id, sum(completed) as plays, max(played_at) as last from music_play
         where profile_id = ? group by track_id`,
        [profileId],
      )
      .map((row) => ({ trackId: row.track_id, plays: row.plays, lastPlayedAt: row.last }));
  }

  clearPlays(profileId: string): void {
    this.db.run("delete from music_play where profile_id = ?", [profileId]);
  }
}
