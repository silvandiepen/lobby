// SPDX-License-Identifier: MPL-2.0
import { randomUUID } from "node:crypto";
import type { Database } from "../db/database.ts";
import { baseOf, nameKey, sortKey } from "./names.ts";
import { withOverrides } from "./tags.ts";
import {
  readMusicOverrides,
  type AudioTags,
  type MusicHint,
  type MusicKind,
  type MusicOverrides,
} from "./types.ts";
import { ViewerRevision } from "./viewer-revision.ts";

export const VARIOUS_ARTISTS = "Various Artists";

/** A name in an identity key cannot run into the next part. */
const key = (...parts: string[]): string => JSON.stringify(parts);

interface TrackRow {
  id: string;
  source_id: string;
  rel_path: string;
  dir: string;
  album_dir: string;
  duration_ms: number | null;
  chapters_json: string;
  cover_id: string | null;
  tags_json: string | null;
  override_json: string | null;
  album_id: string | null;
  book_id: string | null;
  hint: MusicHint;
}

interface OwnerRow {
  id: string;
  override_json: string | null;
}

interface Pending {
  revision: number | null;
  albums: Set<string>;
  books: Set<string>;
  artists: Set<string>;
  /** Where the tracks of an album or book went, so what viewers kept about it can follow. */
  successors: Map<string, string>;
}

/** What most of the values are; the first of equals. */
function mostCommon<T>(values: T[]): T | undefined {
  const counts = new Map<T, number>();
  for (const value of values) counts.set(value, (counts.get(value) ?? 0) + 1);
  let best: T | undefined;
  for (const [value, count] of counts) {
    if (best === undefined || count > (counts.get(best) ?? 0)) best = value;
  }
  return best;
}

function commonGenres(all: string[][]): string[] {
  const counts = new Map<string, number>();
  for (const genre of all.flat()) counts.set(genre, (counts.get(genre) ?? 0) + 1);
  return [...counts]
    .sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1))
    .slice(0, 5)
    .map(([name]) => name);
}

export function parseTags(json: string | null): AudioTags {
  if (json === null) throw new Error("A track without tags was read.");
  return JSON.parse(json) as AudioTags;
}

/**
 * Which album a track is on.
 *
 * A release id from MusicBrainz says it exactly. A compilation is known by its name, since
 * its tracks may be spread over their artists' folders. Anything else is an album in its
 * folder: two albums of the same name ("Greatest Hits", or a FLAC and an MP3 rip) stay apart.
 */
export function albumKey(tags: AudioTags, sourceId: string, albumDir: string): string | null {
  if (tags.album === null) return null;
  const title = nameKey(tags.album);
  if (tags.albumMbid !== null) return key("mb", tags.albumMbid);
  const artists = tags.albumArtists.map(nameKey).join("|");
  if (tags.compilation) return key("va", artists, title);
  // At the top of a library folder there is no album folder to tell albums apart by.
  const who = artists || (albumDir === "" ? nameKey(tags.artists[0] ?? "") : "");
  return key("dir", sourceId, albumDir, who, title);
}

interface BookGuess {
  key: string;
  title: string;
  author: string | null;
}

export function bookOf(
  tags: AudioTags,
  source: string,
  relPath: string,
  albumDir: string,
  whole: boolean,
): BookGuess {
  const folder = baseOf(albumDir);
  const parent = baseOf(albumDir.slice(0, Math.max(0, albumDir.length - folder.length - 1)));
  const named = key("book", source, albumDir, nameKey(tags.album ?? ""));
  if (tags.album !== null) {
    // Author/Book/01.mp3 or Author/Book.m4b: the author's folder is the one that is not the book's.
    const own = whole && nameKey(folder) !== nameKey(tags.album);
    return { key: named, title: tags.album, author: (own ? folder : parent) || null };
  }
  // One file that is a book of its own, or loose stories in a folder.
  if (whole || albumDir === "" || tags.track === null) {
    return {
      key: key("book-file", source, relPath),
      title: tags.title,
      author: whole || parent === "" ? folder || null : parent,
    };
  }
  return { key: named, title: folder, author: parent || null };
}

const ORDER = "order by coalesce(disc, 1), track is null, track, rel_path";

/**
 * Turns files with tags into artists, albums, tracks and books, and notes what changed for
 * the apps' sync. Files are only described here; nothing is ever written to them.
 */
export class MusicCatalogue {
  private readonly db: Database;
  private readonly now: () => number;
  private readonly viewers: ViewerRevision;
  private pending: Pending | null = null;

  constructor(db: Database, now: () => number = Date.now) {
    this.db = db;
    this.now = now;
    this.viewers = new ViewerRevision(db);
  }

  get revision(): number {
    return Number(this.db.getMeta("music_revision") ?? "0");
  }

  /** Runs `work` as one change: albums and artists are worked out once at its end. */
  change<T>(work: () => T): T {
    if (this.pending) return work();
    return this.db.transaction(() => {
      this.pending = {
        revision: null,
        albums: new Set(),
        books: new Set(),
        artists: new Set(),
        successors: new Map(),
      };
      try {
        const result = work();
        this.settle(this.pending);
        return result;
      } finally {
        this.pending = null;
      }
    });
  }

  private open(): Pending {
    if (!this.pending) throw new Error("A change to the audio catalogue outside change().");
    return this.pending;
  }

  private nextRevision(): number {
    const pending = this.open();
    if (pending.revision === null) {
      pending.revision = this.revision + 1;
      this.db.setMeta("music_revision", String(pending.revision));
    }
    return pending.revision;
  }

  touch(kind: MusicKind, id: string): void {
    this.db.run(
      `insert into music_change (id, kind, revision) values (?, ?, ?)
       on conflict (id) do update set revision = excluded.revision, removed = 0`,
      [id, kind, this.nextRevision()],
    );
  }

  private bury(id: string): void {
    this.db.run("update music_change set revision = ?, removed = 1 where id = ?", [
      this.nextRevision(),
      id,
    ]);
  }

  /** Every track of a folder changed, for example because its drive came or went. */
  touchSource(sourceId: string): void {
    this.change(() => {
      this.db.run(
        `update music_change set revision = ? where id in (
           select id from music_track where source_id = ? and state = 'probed')`,
        [this.nextRevision(), sourceId],
      );
    });
  }

  touchTrack(id: string): void {
    this.change(() => {
      // Only what an app was told about; a file that was never read is not a track yet.
      this.db.run("update music_change set revision = ? where id = ? and removed = 0", [
        this.nextRevision(),
        id,
      ]);
    });
  }

  /** Pictures came or went in a folder: the albums and books there choose a cover again. */
  refreshDir(sourceId: string, dir: string): void {
    this.change(() => {
      const pending = this.open();
      for (const row of this.db.all<{ album_id: string | null; book_id: string | null }>(
        `select distinct album_id, book_id from music_track
         where source_id = ?1 and (album_dir = ?2 or dir = ?2)`,
        [sourceId, dir],
      )) {
        if (row.album_id !== null) pending.albums.add(row.album_id);
        if (row.book_id !== null) pending.books.add(row.book_id);
      }
    });
  }

  /** Works a track out again from its tags and what a manager changed. */
  link(trackId: string): void {
    this.change(() => {
      const pending = this.open();
      const row = this.db.get<TrackRow>(
        `select music_track.*, music_source.hint from music_track
         join music_source on music_source.id = music_track.source_id where music_track.id = ?`,
        [trackId],
      );
      if (!row) return;
      const tags = withOverrides(parseTags(row.tags_json), readMusicOverrides(row.override_json));

      let albumId: string | null = null;
      let bookId: string | null = null;
      if (row.hint === "audiobooks") {
        const whole = row.rel_path.toLowerCase().endsWith(".m4b") || row.chapters_json !== "[]";
        const book = bookOf(tags, row.source_id, row.rel_path, row.album_dir, whole);
        bookId = this.owner("music_book", "book_id", book.key, row.book_id, row.id);
      } else {
        const album = albumKey(tags, row.source_id, row.album_dir);
        if (album !== null) {
          albumId = this.owner("music_album", "album_id", album, row.album_id, row.id);
        }
      }
      this.db.run(
        `update music_track set album_id = ?, book_id = ?, title = ?, sort_title = ?, artist_credit = ?,
           disc = ?, track = ?, year = ?, genres_json = ?, composers_json = ? where id = ?`,
        [
          albumId,
          bookId,
          tags.title,
          tags.titleSort === null ? sortKey(tags.title) : nameKey(tags.titleSort),
          tags.artistCredit,
          tags.disc,
          tags.track,
          tags.year,
          JSON.stringify(tags.genres),
          JSON.stringify(tags.composers),
          row.id,
        ],
      );
      // Who reads a book is not a musician in the artists' list.
      this.credit(
        row.id,
        row.hint === "audiobooks"
          ? []
          : this.artists(tags.artists, tags.artistMbids, tags.artistSort),
      );
      for (const [before, after, set] of [
        [row.album_id, albumId, pending.albums],
        [row.book_id, bookId, pending.books],
      ] as const) {
        if (after !== null) set.add(after);
        if (before !== null && before !== after) {
          set.add(before);
          if (after !== null) pending.successors.set(before, after);
        }
      }
      this.touch("track", row.id);
    });
  }

  /**
   * The album or book with this key. When a whole album gets another key (its folder was
   * renamed, or it was tagged again), it keeps its id: the first of its tracks to arrive
   * takes it along, unless another track is settled in it.
   */
  private owner(
    table: "music_album" | "music_book",
    column: "album_id" | "book_id",
    ident: string,
    current: string | null,
    trackId: string,
  ): string {
    const existing = this.db.get<{ id: string }>(`select id from ${table} where ident_key = ?`, [
      ident,
    ]);
    if (existing) return existing.id;
    if (current !== null) {
      const settled = this.db.get(
        `select 1 as x from music_track where ${column} = ? and id != ? and state = 'probed' and available = 1 limit 1`,
        [current, trackId],
      );
      if (!settled) {
        this.db.run(`update ${table} set ident_key = ? where id = ?`, [ident, current]);
        return current;
      }
    }
    const id = randomUUID();
    this.db.run(`insert into ${table} (id, ident_key, added_at) values (?, ?, ?)`, [
      id,
      ident,
      this.now(),
    ]);
    return id;
  }

  private artists(names: string[], mbids: string[], sort: string | null): string[] {
    const aligned = names.length === mbids.length;
    return [
      ...new Set(
        names.map((name, index) =>
          this.artist(
            name,
            aligned ? (mbids[index] ?? null) : null,
            names.length === 1 ? sort : null,
          ),
        ),
      ),
    ];
  }

  private artist(name: string, mbid: string | null, sort: string | null): string {
    const ident = key(nameKey(name));
    const find = (one: string): { id: string; mbid: string | null } | undefined =>
      this.db.get<{ id: string; mbid: string | null }>(
        "select id, mbid from music_artist where ident_key = ?",
        [one],
      );
    const known = find(ident);
    if (known && (mbid === null || known.mbid === null || known.mbid === mbid)) {
      if (mbid !== null && known.mbid === null) {
        this.db.run("update music_artist set mbid = ? where id = ?", [mbid, known.id]);
        this.touch("artist", known.id);
      }
      return known.id;
    }
    // Two artists with one name, told apart by MusicBrainz.
    const own = known && mbid !== null ? key(nameKey(name), mbid) : ident;
    const namesake = known ? find(own) : undefined;
    if (namesake) return namesake.id;
    const id = randomUUID();
    this.db.run(
      "insert into music_artist (id, ident_key, name, sort_name, mbid, added_at) values (?, ?, ?, ?, ?, ?)",
      [id, own, name, sort === null ? sortKey(name) : nameKey(sort), mbid, this.now()],
    );
    this.touch("artist", id);
    return id;
  }

  private credit(ownerId: string, artistIds: string[]): void {
    const before = this.db
      .all<{ artist_id: string }>(
        "select artist_id from music_credit where owner_id = ? order by position",
        [ownerId],
      )
      .map((row) => row.artist_id);
    if (before.join() === artistIds.join()) return;
    this.db.run("delete from music_credit where owner_id = ?", [ownerId]);
    artistIds.forEach((artistId, position) => {
      this.db.run("insert into music_credit (owner_id, position, artist_id) values (?, ?, ?)", [
        ownerId,
        position,
        artistId,
      ]);
    });
    for (const id of before) this.open().artists.add(id);
  }

  private settle(pending: Pending): void {
    for (const id of pending.albums) this.refreshAlbum(id, pending);
    for (const id of pending.books) this.refreshBook(id, pending);
    for (const id of pending.artists) {
      if (this.db.get("select 1 as x from music_credit where artist_id = ? limit 1", [id]))
        continue;
      if (this.db.run("delete from music_artist where id = ?", [id]) === 0) continue;
      this.forgetViewers(id, null);
      this.bury(id);
    }
  }

  private tracksOf(column: "album_id" | "book_id", id: string): (TrackRow & { tags: AudioTags })[] {
    return this.db
      .all<TrackRow>(`select * from music_track where ${column} = ? ${ORDER}`, [id])
      .map((row) => ({
        ...row,
        tags: withOverrides(parseTags(row.tags_json), readMusicOverrides(row.override_json)),
      }));
  }

  /**
   * True when nothing is left in it: it is removed, and what viewers kept follows its tracks.
   * A manager's changes do not: they were about this one, not about the one it became part of.
   */
  private removedIfEmpty(
    table: "music_album" | "music_book",
    id: string,
    tracks: unknown[],
    pending: Pending,
  ): boolean {
    if (tracks.length > 0) return false;
    const successor = pending.successors.get(id) ?? null;
    this.credit(id, []);
    this.db.run(`delete from ${table} where id = ?`, [id]);
    this.forgetViewers(id, successor);
    this.bury(id);
    return true;
  }

  private refreshAlbum(id: string, pending: Pending): void {
    const tracks = this.tracksOf("album_id", id);
    if (this.removedIfEmpty("music_album", id, tracks, pending)) return;
    const [first] = tracks;
    if (!first) return;
    const row = this.db.get<OwnerRow>("select id, override_json from music_album where id = ?", [
      id,
    ]);
    const changes = readMusicOverrides(row?.override_json ?? null);
    const title = mostCommon(tracks.map((track) => track.tags.album ?? "")) ?? "";
    const albumSort = tracks.find((track) => track.tags.albumSort)?.tags.albumSort ?? null;

    const lead = tracks.find((track) => track.tags.albumArtists.length > 0)?.tags;
    const primary = new Set(tracks.map((track) => nameKey(track.tags.artists[0] ?? "")));
    const compilation =
      tracks.some((track) => track.tags.compilation) || (!lead && primary.size > 1);
    let credit: string;
    let artistIds: string[];
    if (lead) {
      credit = lead.albumArtistCredit ?? lead.albumArtists.join(", ");
      artistIds = this.artists(lead.albumArtists, lead.albumArtistMbids, lead.albumArtistSort);
    } else if (compilation || first.tags.artists.length === 0) {
      credit = compilation ? VARIOUS_ARTISTS : "";
      artistIds = [];
    } else {
      // Only who is on every track: guests on one song did not make the album.
      const names = first.tags.artists.filter((name) =>
        tracks.every((track) =>
          track.tags.artists.some((other) => nameKey(other) === nameKey(name)),
        ),
      );
      credit = names.join(", ");
      artistIds = this.artists(
        names,
        names.length === first.tags.artists.length ? first.tags.artistMbids : [],
        first.tags.artistSort,
      );
    }
    if (changes.artists !== undefined) artistIds = this.artists(changes.artists, [], null);
    this.credit(id, artistIds);

    this.db.run(
      `update music_album set title = ?, sort_title = ?, artist_credit = ?, year = ?, genres_json = ?,
         compilation = ?, mbid = ?, track_count = ?, disc_count = ?, duration_ms = ?, cover_id = ? where id = ?`,
      [
        title,
        albumSort === null ? sortKey(title) : nameKey(albumSort),
        credit,
        mostCommon(tracks.map((track) => track.tags.year).filter((year) => year !== null)) ?? null,
        JSON.stringify(commonGenres(tracks.map((track) => track.tags.genres))),
        compilation ? 1 : 0,
        first.tags.albumMbid,
        tracks.length,
        new Set(tracks.map((track) => track.tags.disc ?? 1)).size,
        tracks.reduce((sum, track) => sum + (track.duration_ms ?? 0), 0),
        this.cover(tracks, "album_id"),
        id,
      ],
    );
    this.touch("album", id);
  }

  private refreshBook(id: string, pending: Pending): void {
    const tracks = this.tracksOf("book_id", id);
    if (this.removedIfEmpty("music_book", id, tracks, pending)) return;
    const [first] = tracks;
    if (!first) return;
    const whole = first.rel_path.toLowerCase().endsWith(".m4b") || first.chapters_json !== "[]";
    const guess = bookOf(first.tags, first.source_id, first.rel_path, first.album_dir, whole);
    const { tags } = first;
    const authors =
      tags.albumArtists.length > 0
        ? tags.albumArtists
        : tags.artists.length > 0
          ? tags.artists
          : guess.author === null
            ? []
            : [guess.author];
    this.db.run(
      `update music_book set title = ?, sort_title = ?, authors_json = ?, narrators_json = ?, series = ?,
         series_position = ?, year = ?, genres_json = ?, description = ?, language = ?, duration_ms = ?,
         cover_id = ? where id = ?`,
      [
        guess.title,
        tags.albumSort !== null && guess.title === tags.album
          ? nameKey(tags.albumSort)
          : sortKey(guess.title),
        JSON.stringify(authors),
        // Audiobook tools put the reader in the composer.
        JSON.stringify(tags.narrators.length > 0 ? tags.narrators : tags.composers),
        tags.series,
        tags.seriesPosition,
        tags.year,
        JSON.stringify(commonGenres(tracks.map((track) => track.tags.genres))),
        tags.description,
        tags.language,
        tracks.reduce((sum, track) => sum + (track.duration_ms ?? 0), 0),
        this.cover(tracks, "book_id"),
        id,
      ],
    );
    this.touch("book", id);
  }

  /**
   * The picture beside the files, else the one inside them. In a folder that several albums
   * share, or at the top of a library folder, a picture beside them says less.
   */
  private cover(tracks: TrackRow[], column: "album_id" | "book_id"): string | null {
    const embedded = tracks.find((track) => track.cover_id !== null)?.cover_id ?? null;
    const [first] = tracks;
    if (!first) return embedded;
    const dirs = [...new Set([first.album_dir, ...tracks.map((track) => track.dir)])].filter(
      (dir) => dir !== "",
    );
    for (const dir of dirs) {
      const beside = this.db.get<{ id: string }>(
        `select id from music_image where source_id = ? and dir = ?
         order by instr('cover folder front', lower(substr(rel_path, length(dir) + 2, 5))), rel_path limit 1`,
        [first.source_id, dir],
      );
      if (!beside) continue;
      const shared =
        (this.db.get<{ n: number }>(
          `select count(distinct ${column}) as n from music_track where source_id = ? and album_dir = ?`,
          [first.source_id, first.album_dir],
        )?.n ?? 0) > 1;
      return shared && embedded !== null ? embedded : beside.id;
    }
    return embedded;
  }

  /** Removes a track whose file has been gone for long. */
  removeTrack(id: string): void {
    this.change(() => {
      const pending = this.open();
      const row = this.db.get<{ album_id: string | null; book_id: string | null }>(
        "select album_id, book_id from music_track where id = ?",
        [id],
      );
      if (!row) return;
      if (row.album_id !== null) pending.albums.add(row.album_id);
      if (row.book_id !== null) pending.books.add(row.book_id);
      this.credit(id, []);
      this.db.run("delete from music_track where id = ?", [id]);
      this.db.run("delete from music_play where track_id = ?", [id]);
      for (const list of this.db.all<{ id: string; tracks_json: string }>(
        `select id, tracks_json from music_playlist where deleted_at is null and exists (
           select 1 from json_each(tracks_json) where value = ?)`,
        [id],
      )) {
        this.db.run(
          `update music_playlist set tracks_json = ?, edit_revision = edit_revision + 1, revision = ? where id = ?`,
          [
            JSON.stringify((JSON.parse(list.tracks_json) as string[]).filter((one) => one !== id)),
            this.viewers.next(),
            list.id,
          ],
        );
      }
      this.forgetViewers(id, null);
      this.bury(id);
    });
  }

  /** What viewers kept about something that is gone moves to what took its place, or goes too. */
  private forgetViewers(id: string, successor: string | null): void {
    if (successor !== null) {
      const revision = this.viewers.next();
      this.db.run(
        `update or ignore music_favourite set item_id = ?, revision = ? where item_id = ?`,
        [successor, revision, id],
      );
      const progress = Number(this.db.getMeta("music_progress_revision") ?? "0") + 1;
      if (
        this.db.run(
          "update or ignore music_progress set item_id = ?, revision = ? where item_id = ?",
          [successor, progress, id],
        ) > 0
      ) {
        this.db.setMeta("music_progress_revision", String(progress));
      }
    }
    this.db.run("delete from music_favourite where item_id = ?", [id]);
    this.db.run("delete from music_progress where item_id = ?", [id]);
  }

  /** A manager's changes to one thing; the caller checked them. */
  applyOverrides(kind: MusicKind, id: string, overrides: MusicOverrides): void {
    this.change(() => {
      const pending = this.open();
      this.db.run(
        `update music_${kind} set override_json = ?, edit_revision = edit_revision + 1 where id = ?`,
        [Object.keys(overrides).length === 0 ? null : JSON.stringify(overrides), id],
      );
      if (kind === "track") this.link(id);
      else if (kind === "album") pending.albums.add(id);
      else this.touch(kind, id);
      if (kind === "artist") {
        this.db.run(
          "update music_change set revision = ? where id in (select owner_id from music_credit where artist_id = ?)",
          [this.nextRevision(), id],
        );
      }
    });
  }
}
