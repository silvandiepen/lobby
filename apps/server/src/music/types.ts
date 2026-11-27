// SPDX-License-Identifier: MPL-2.0
export const MUSIC_HINTS = ["music", "audiobooks"] as const;
export type MusicHint = (typeof MUSIC_HINTS)[number];

/** A folder with audio. Nothing in it is ever written. */
export interface MusicRootConfig {
  path: string;
  name: string;
  hint: MusicHint;
}

export interface Chapter {
  title: string | null;
  startMs: number;
  endMs: number;
}

export interface ReplayGain {
  trackGainDb: number | null;
  trackPeak: number | null;
  albumGainDb: number | null;
  albumPeak: number | null;
}

/** What an audio file says about itself, with its path filling the gaps. */
export interface AudioTags {
  title: string;
  titleSort: string | null;
  artists: string[];
  /** As the sleeve says it: "Queen feat. David Bowie". */
  artistCredit: string;
  artistSort: string | null;
  artistMbids: string[];
  album: string | null;
  albumSort: string | null;
  albumArtists: string[];
  albumArtistCredit: string | null;
  albumArtistSort: string | null;
  albumArtistMbids: string[];
  compilation: boolean;
  disc: number | null;
  track: number | null;
  year: number | null;
  genres: string[];
  composers: string[];
  narrators: string[];
  series: string | null;
  seriesPosition: number | null;
  description: string | null;
  language: string | null;
  recordingMbid: string | null;
  albumMbid: string | null;
  replayGain: ReplayGain | null;
}

/** The tags a manager can change on a track. */
export const TRACK_FIELDS = [
  "title",
  "sortTitle",
  "artists",
  "album",
  "albumArtists",
  "compilation",
  "disc",
  "track",
  "year",
  "genres",
  "composers",
] as const;
export const ALBUM_FIELDS = [
  "title",
  "sortTitle",
  "artists",
  "year",
  "genres",
  "compilation",
] as const;
export const ARTIST_FIELDS = ["name", "sortName"] as const;
export const BOOK_FIELDS = [
  "title",
  "sortTitle",
  "authors",
  "narrators",
  "series",
  "seriesPosition",
  "year",
  "genres",
  "description",
] as const;

export type MusicKind = "artist" | "album" | "track" | "book";
export const EDIT_FIELDS: Record<MusicKind, readonly string[]> = {
  artist: ARTIST_FIELDS,
  album: ALBUM_FIELDS,
  track: TRACK_FIELDS,
  book: BOOK_FIELDS,
};

/** A manager's changes, kept apart from what the files say. */
export interface MusicOverrides {
  title?: string;
  sortTitle?: string;
  name?: string;
  sortName?: string;
  artists?: string[];
  album?: string | null;
  albumArtists?: string[];
  compilation?: boolean;
  disc?: number | null;
  track?: number | null;
  year?: number | null;
  genres?: string[];
  composers?: string[];
  authors?: string[];
  narrators?: string[];
  series?: string | null;
  seriesPosition?: number | null;
  description?: string | null;
}

export function readMusicOverrides(json: string | null): MusicOverrides {
  return json === null ? {} : (JSON.parse(json) as MusicOverrides);
}

export type TrackPlayability = "direct" | "convert";
