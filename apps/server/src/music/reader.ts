// SPDX-License-Identifier: MPL-2.0
import type { Database } from "../db/database.ts";
import { VARIOUS_ARTISTS } from "./catalogue.ts";
import { nameKey, sortKey } from "./names.ts";
import { COMPACT_KBPS, isCompactAlready } from "./copies.ts";
import {
  readMusicOverrides,
  type AudioTags,
  type Chapter,
  type MusicKind,
  type MusicOverrides,
  type ReplayGain,
} from "./types.ts";

/** The audio library as the apps see it. The shapes are the contract in docs/api.md. */
export interface ApiArtist {
  id: string;
  name: string;
  sortName: string;
  mbid: string | null;
  addedAt: number;
}

export interface ApiAlbum {
  id: string;
  title: string;
  sortTitle: string;
  artistCredit: string;
  artistIds: string[];
  compilation: boolean;
  year: number | null;
  genres: string[];
  trackCount: number;
  discCount: number;
  durationMs: number;
  coverId: string | null;
  mbid: string | null;
  addedAt: number;
}

export interface ApiTrack {
  id: string;
  title: string;
  sortTitle: string;
  artistCredit: string;
  artistIds: string[];
  albumId: string | null;
  bookId: string | null;
  disc: number | null;
  track: number | null;
  year: number | null;
  genres: string[];
  composers: string[];
  durationMs: number | null;
  chapters: Chapter[];
  replayGain: ReplayGain | null;
  coverId: string | null;
  mbid: string | null;
  addedAt: number;
  available: boolean;
  file: {
    revision: string;
    sizeBytes: number;
    container: string;
    codec: string;
    lossless: boolean;
    bitRate: number | null;
    sampleRate: number | null;
    bitDepth: number | null;
    channels: number | null;
    playability: "direct" | "convert";
    /** The compact qualities that are smaller than the file itself. */
    compact: number[];
  };
}

export interface ApiBook {
  id: string;
  title: string;
  sortTitle: string;
  authors: string[];
  narrators: string[];
  series: string | null;
  seriesPosition: number | null;
  year: number | null;
  genres: string[];
  description: string | null;
  language: string | null;
  durationMs: number;
  coverId: string | null;
  addedAt: number;
  parts: { trackId: string; startMs: number; durationMs: number | null }[];
  chapters: {
    title: string | null;
    startMs: number;
    endMs: number;
    trackId: string;
    trackStartMs: number;
  }[];
}

export interface MusicPage {
  artists: ApiArtist[];
  albums: ApiAlbum[];
  tracks: ApiTrack[];
  books: ApiBook[];
  removed: string[];
  next: { revision: number; id: string };
  more: boolean;
}

interface ArtistRow {
  id: string;
  name: string;
  sort_name: string;
  mbid: string | null;
  override_json: string | null;
  added_at: number;
}

interface AlbumRow {
  id: string;
  title: string;
  sort_title: string;
  artist_credit: string;
  year: number | null;
  genres_json: string;
  compilation: number;
  mbid: string | null;
  track_count: number;
  disc_count: number;
  duration_ms: number;
  cover_id: string | null;
  override_json: string | null;
  added_at: number;
}

interface TrackRow {
  id: string;
  title: string;
  sort_title: string;
  artist_credit: string;
  album_id: string | null;
  book_id: string | null;
  disc: number | null;
  track: number | null;
  year: number | null;
  genres_json: string;
  composers_json: string;
  duration_ms: number | null;
  chapters_json: string;
  cover_id: string | null;
  tags_json: string | null;
  first_seen_at: number;
  reachable: number;
  revision: string;
  size: number;
  container: string | null;
  codec: string | null;
  lossless: number;
  bit_rate: number | null;
  sample_rate: number | null;
  bit_depth: number | null;
  channels: number | null;
  playability: "direct" | "convert" | null;
}

interface BookRow {
  id: string;
  title: string;
  sort_title: string;
  authors_json: string;
  narrators_json: string;
  series: string | null;
  series_position: number | null;
  year: number | null;
  genres_json: string;
  description: string | null;
  language: string | null;
  duration_ms: number;
  cover_id: string | null;
  override_json: string | null;
  added_at: number;
}

interface PartRow {
  id: string;
  book_id: string;
  title: string;
  duration_ms: number | null;
  chapters_json: string;
}

const list = (json: string): string[] => JSON.parse(json) as string[];
const kept = <T>(change: T | undefined, automatic: T): T =>
  change === undefined ? automatic : change;

function sorted(changes: MusicOverrides, automatic: string): string {
  if (changes.sortTitle !== undefined) return nameKey(changes.sortTitle);
  return changes.title === undefined ? automatic : sortKey(changes.title);
}

interface Credit {
  ids: string[];
  names: string[];
  renamed: boolean;
}

export class MusicReader {
  private readonly db: Database;

  constructor(db: Database) {
    this.db = db;
  }

  private credits(ids: string[]): Map<string, Credit> {
    const credits = new Map<string, Credit>();
    // "cross join" keeps SQLite from starting at every artist in the library.
    for (const row of this.db.all<{
      owner_id: string;
      artist_id: string;
      name: string;
      override_json: string | null;
    }>(
      `select music_credit.owner_id, music_credit.artist_id, music_artist.name, music_artist.override_json
       from json_each(?) as wanted
       cross join music_credit on music_credit.owner_id = wanted.value
       cross join music_artist on music_artist.id = music_credit.artist_id
       order by music_credit.owner_id, music_credit.position`,
      [JSON.stringify(ids)],
    )) {
      const credit = credits.get(row.owner_id) ?? { ids: [], names: [], renamed: false };
      const name = readMusicOverrides(row.override_json).name;
      credit.ids.push(row.artist_id);
      credit.names.push(name ?? row.name);
      credit.renamed ||= name !== undefined;
      credits.set(row.owner_id, credit);
    }
    return credits;
  }

  artists(ids: string[]): ApiArtist[] {
    if (ids.length === 0) return [];
    return this.db
      .all<ArtistRow>(
        `select music_artist.* from json_each(?) as wanted
         cross join music_artist on music_artist.id = wanted.value order by wanted.key`,
        [JSON.stringify(ids)],
      )
      .map((row) => {
        const changes = readMusicOverrides(row.override_json);
        return {
          id: row.id,
          name: changes.name ?? row.name,
          sortName:
            changes.sortName !== undefined
              ? nameKey(changes.sortName)
              : changes.name !== undefined
                ? sortKey(changes.name)
                : row.sort_name,
          mbid: row.mbid,
          addedAt: row.added_at,
        };
      });
  }

  albums(ids: string[]): ApiAlbum[] {
    if (ids.length === 0) return [];
    const credits = this.credits(ids);
    return this.db
      .all<AlbumRow>(
        `select music_album.* from json_each(?) as wanted
         cross join music_album on music_album.id = wanted.value order by wanted.key`,
        [JSON.stringify(ids)],
      )
      .map((row) => {
        const changes = readMusicOverrides(row.override_json);
        const credit = credits.get(row.id);
        const compilation = changes.compilation ?? row.compilation === 1;
        return {
          id: row.id,
          title: changes.title ?? row.title,
          sortTitle: sorted(changes, row.sort_title),
          artistCredit:
            changes.artists !== undefined || credit?.renamed
              ? (credit?.names.join(", ") ?? (compilation ? VARIOUS_ARTISTS : ""))
              : row.artist_credit,
          artistIds: credit?.ids ?? [],
          compilation,
          year: kept(changes.year, row.year),
          genres: changes.genres ?? list(row.genres_json),
          trackCount: row.track_count,
          discCount: row.disc_count,
          durationMs: row.duration_ms,
          coverId: row.cover_id,
          mbid: row.mbid,
          addedAt: row.added_at,
        };
      });
  }

  tracks(ids: string[]): ApiTrack[] {
    if (ids.length === 0) return [];
    const credits = this.credits(ids);
    return this.db
      .all<TrackRow>(
        `select music_track.*, (music_track.available = 1 and music_source.available = 1) as reachable
         from json_each(?) as wanted
         cross join music_track on music_track.id = wanted.value
         cross join music_source on music_source.id = music_track.source_id
         where music_track.tags_json is not null order by wanted.key`,
        [JSON.stringify(ids)],
      )
      .map((row) => {
        const tags = JSON.parse(row.tags_json ?? "{}") as Partial<AudioTags>;
        const credit = credits.get(row.id);
        return {
          id: row.id,
          title: row.title,
          sortTitle: row.sort_title,
          artistCredit: credit?.renamed ? credit.names.join(", ") : row.artist_credit,
          artistIds: credit?.ids ?? [],
          albumId: row.album_id,
          bookId: row.book_id,
          disc: row.disc,
          track: row.track,
          year: row.year,
          genres: list(row.genres_json),
          composers: list(row.composers_json),
          durationMs: row.duration_ms,
          chapters: JSON.parse(row.chapters_json) as Chapter[],
          replayGain: tags.replayGain ?? null,
          coverId: row.album_id === null && row.book_id === null ? row.cover_id : null,
          mbid: tags.recordingMbid ?? null,
          addedAt: row.first_seen_at,
          available: row.reachable === 1,
          file: {
            revision: row.revision,
            sizeBytes: row.size,
            container: row.container ?? "unknown",
            codec: row.codec ?? "unknown",
            lossless: row.lossless === 1,
            bitRate: row.bit_rate,
            sampleRate: row.sample_rate,
            bitDepth: row.bit_depth,
            channels: row.channels,
            playability: row.playability ?? "convert",
            compact: COMPACT_KBPS.filter(
              (kbps) =>
                !isCompactAlready(
                  {
                    playability: row.playability ?? "convert",
                    lossless: row.lossless === 1,
                    bitRate: row.bit_rate,
                  },
                  kbps,
                ),
            ),
          },
        };
      });
  }

  books(ids: string[]): ApiBook[] {
    if (ids.length === 0) return [];
    const parts = new Map<string, PartRow[]>();
    for (const part of this.db.all<PartRow>(
      `select music_track.id, music_track.book_id, music_track.title, music_track.duration_ms,
         music_track.chapters_json
       from json_each(?) as wanted
       cross join music_track on music_track.book_id = wanted.value
       where music_track.tags_json is not null
       order by coalesce(disc, 1), track is null, track, rel_path`,
      [JSON.stringify(ids)],
    )) {
      const known = parts.get(part.book_id);
      if (known) known.push(part);
      else parts.set(part.book_id, [part]);
    }
    return this.db
      .all<BookRow>(
        `select music_book.* from json_each(?) as wanted
         cross join music_book on music_book.id = wanted.value order by wanted.key`,
        [JSON.stringify(ids)],
      )
      .map((row) => {
        const changes = readMusicOverrides(row.override_json);
        return {
          id: row.id,
          title: changes.title ?? row.title,
          sortTitle: sorted(changes, row.sort_title),
          authors: changes.authors ?? list(row.authors_json),
          narrators: changes.narrators ?? list(row.narrators_json),
          series: kept(changes.series, row.series),
          seriesPosition: kept(changes.seriesPosition, row.series_position),
          year: kept(changes.year, row.year),
          genres: changes.genres ?? list(row.genres_json),
          description: kept(changes.description, row.description),
          language: row.language,
          durationMs: row.duration_ms,
          coverId: row.cover_id,
          addedAt: row.added_at,
          ...layOut(parts.get(row.id) ?? []),
        };
      });
  }

  /** One page of what changed after `after`, oldest change first; null starts at the beginning. */
  page(after: { revision: number; id: string } | null, limit: number): MusicPage {
    const current = Number(this.db.getMeta("music_revision") ?? "0");
    const from = after ?? { revision: 0, id: "" };
    // A row value, so the index is walked from exactly there whatever the size of the library.
    const rows = this.db.all<{ id: string; kind: MusicKind; revision: number; removed: number }>(
      `select id, kind, revision, removed from music_change
       where (revision, id) > (?, ?) and removed <= ? order by revision, id limit ?`,
      // Who starts over has nothing to remove.
      [from.revision, from.id, after === null ? 0 : 1, limit + 1],
    );
    const more = rows.length > limit;
    const page = rows.slice(0, limit);
    const last = page.at(-1);
    const of = (kind: MusicKind): string[] =>
      page.filter((row) => row.kind === kind && row.removed === 0).map((row) => row.id);
    return {
      artists: this.artists(of("artist")),
      albums: this.albums(of("album")),
      tracks: this.tracks(of("track")),
      books: this.books(of("book")),
      removed: page.filter((row) => row.removed === 1).map((row) => row.id),
      // "￿" sorts after every id: all of this revision was seen.
      next:
        more && last ? { revision: last.revision, id: last.id } : { revision: current, id: "￿" },
      more,
    };
  }

  /** What kind of thing an id is, when it is in the library. */
  kindOf(id: string): MusicKind | null {
    return (
      this.db.get<{ kind: MusicKind }>(
        "select kind from music_change where id = ? and removed = 0",
        [id],
      )?.kind ?? null
    );
  }

  tracksOfAlbum(id: string): ApiTrack[] {
    return this.ordered("album_id = ?", id);
  }

  tracksOfBook(id: string): ApiTrack[] {
    return this.ordered("book_id = ?", id);
  }

  /** Albums under their own name or with them on a track. */
  albumsOfArtist(id: string): ApiAlbum[] {
    return this.albums(
      this.db
        .all<{ id: string }>(
          `select id from music_album where id in (select owner_id from music_credit where artist_id = ?1)
             or id in (select music_track.album_id from music_credit
                       join music_track on music_track.id = music_credit.owner_id
                       where music_credit.artist_id = ?1)
           order by year is null, year, sort_title`,
          [id],
        )
        .map((row) => row.id),
    );
  }

  private ordered(where: "album_id = ?" | "book_id = ?", id: string): ApiTrack[] {
    return this.tracks(
      this.db
        .all<{ id: string }>(
          `select id from music_track where ${where} order by coalesce(disc, 1), track is null, track, rel_path`,
          [id],
        )
        .map((row) => row.id),
    );
  }
}

/** Puts the files of a book one after another, with their chapters on one line of time. */
function layOut(rows: PartRow[]): Pick<ApiBook, "parts" | "chapters"> {
  const parts: ApiBook["parts"] = [];
  const chapters: ApiBook["chapters"] = [];
  let at = 0;
  for (const row of rows) {
    const own = JSON.parse(row.chapters_json) as Chapter[];
    parts.push({ trackId: row.id, startMs: at, durationMs: row.duration_ms });
    if (own.length > 0) {
      for (const chapter of own) {
        chapters.push({
          title: chapter.title,
          startMs: at + chapter.startMs,
          endMs: at + chapter.endMs,
          trackId: row.id,
          trackStartMs: chapter.startMs,
        });
      }
    } else if (rows.length > 1) {
      chapters.push({
        title: row.title,
        startMs: at,
        endMs: at + (row.duration_ms ?? 0),
        trackId: row.id,
        trackStartMs: 0,
      });
    }
    at += row.duration_ms ?? 0;
  }
  return { parts, chapters };
}
