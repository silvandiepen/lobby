// SPDX-License-Identifier: MPL-2.0
import type { AudioTags, MusicOverrides, ReplayGain } from "./types.ts";
import { baseOf, dirOf, discOfFolder, isVarious, sortKey } from "./names.ts";

/** Tags come as "album_artist", "ALBUMARTIST" or "MusicBrainz Album Id": one spelling for all. */
export function canonicalTags(
  ...sets: (Record<string, string> | undefined)[]
): Map<string, string> {
  const tags = new Map<string, string>();
  for (const set of sets) {
    for (const [key, raw] of Object.entries(set ?? {})) {
      const value = raw
        .replaceAll("\0", ";")
        .replace(/[\r\t]/g, " ")
        .trim();
      const name = key.toLowerCase().replace(/[^a-z0-9]/g, "");
      if (value !== "" && !tags.has(name)) tags.set(name, value.slice(0, 20_000));
    }
  }
  return tags;
}

const oneLine = (value: string): string => value.replace(/\s+/g, " ").trim().slice(0, 500);

function unique(values: string[]): string[] {
  const seen = new Set<string>();
  return values.filter((value) => {
    const key = value.toLowerCase();
    if (value === "" || seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function split(value: string | undefined, separator: RegExp): string[] {
  return unique((value ?? "").split(separator).map(oneLine)).slice(0, 50);
}

/**
 * The people in an artist tag. Only separators that are never part of a name: "AC/DC",
 * "Simon & Garfunkel" and "Earth, Wind & Fire" stay whole.
 */
export function splitArtists(credit: string): string[] {
  return split(credit, /\s*;\s*|\s+\/\s+|\s+[([]?(?:feat\.?|ft\.?|featuring)\s+/i).map((name) =>
    // "Queen (feat. David Bowie)" leaves its closing bracket behind.
    !/[([]/.test(name) ? name.replace(/[)\]]+$/, "").trim() : name,
  );
}

/** "3", "3/12", "03". Null for nothing usable. */
function position(value: string | undefined): number | null {
  const number = Number(/^\s*(\d{1,4})\b/.exec(value ?? "")?.[1] ?? "0");
  return number > 0 ? number : null;
}

function yearOf(value: string | undefined): number | null {
  const year = Number(/\b(\d{4})\b/.exec(value ?? "")?.[1] ?? "0");
  return year >= 1000 && year <= 2200 ? year : null;
}

function decibels(value: string | undefined): number | null {
  const number = Number.parseFloat(value ?? "");
  return Number.isFinite(number) && Math.abs(number) <= 60 ? number : null;
}

function peak(value: string | undefined): number | null {
  const number = Number.parseFloat(value ?? "");
  return Number.isFinite(number) && number > 0 && number <= 100 ? number : null;
}

/** Opus keeps its own gain in 1/256 dB against -23 LUFS; ReplayGain is against -18. */
function r128(value: string | undefined): number | null {
  return value !== undefined && /^-?\d{1,6}$/.test(value)
    ? decibels(String(Number(value) / 256 + 5))
    : null;
}

function replayGain(tags: Map<string, string>): ReplayGain | null {
  const gain: ReplayGain = {
    trackGainDb: decibels(tags.get("replaygaintrackgain")) ?? r128(tags.get("r128trackgain")),
    trackPeak: peak(tags.get("replaygaintrackpeak")),
    albumGainDb: decibels(tags.get("replaygainalbumgain")) ?? r128(tags.get("r128albumgain")),
    albumPeak: peak(tags.get("replaygainalbumpeak")),
  };
  return Object.values(gain).some((value) => value !== null) ? gain : null;
}

const MBID = /[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/gi;
function mbids(value: string | undefined): string[] {
  return [...new Set((value ?? "").toLowerCase().match(MBID) ?? [])];
}

interface PathGuess {
  title: string;
  artist: string | null;
  album: string | null;
  disc: number | null;
  track: number | null;
}

/**
 * Reads Artist/Album/NN Title. The album's folder counts as an album only when the file is
 * numbered: a loose download in some folder is not on an album named after that folder.
 */
export function guessFromPath(relPath: string): PathGuess {
  const base = baseOf(relPath);
  const stem = base.slice(0, base.lastIndexOf(".")).replaceAll("_", " ").trim();
  const folders = dirOf(relPath).split("/").filter(Boolean);
  const discFolder = discOfFolder(folders.at(-1) ?? "");
  if (discFolder !== null) folders.pop();

  // "1-03 Title", "103 Title" is left alone (it may be a name), "03 - Title", "03. Title".
  const numbered = /^(?:(\d)-)?(\d{1,2})(?:\s*[-.)]\s*|\s+)(\S.*)$/.exec(stem);
  let title = numbered?.[3] ?? stem;
  let artist = folders.length >= 2 ? (folders.at(-2) ?? null) : null;
  const named = /^(.+?) - (.+)$/.exec(title);
  if (named?.[1] && named[2] && (artist === null || sortKey(named[1]) === sortKey(artist))) {
    artist = named[1];
    title = named[2];
  }
  if (artist === null && folders.length === 1 && !numbered) artist = folders[0] ?? null;
  const album = numbered && folders.length > 0 ? (folders.at(-1) ?? null) : null;
  return {
    title,
    artist,
    // "2009 - Album" and "Album (2009)" are the album, with its year beside it.
    album: album?.replace(/^\d{4} - (?=\S)/, "").replace(/(?<=\S)\s*[([]\d{4}[)\]]$/, "") ?? null,
    disc: numbered?.[1] ? Number(numbered[1]) : discFolder,
    track: numbered?.[2] ? Number(numbered[2]) || null : null,
  };
}

export function readTags(tags: Map<string, string>, relPath: string): AudioTags {
  const guess = guessFromPath(relPath);
  const first = (...names: string[]): string | null => {
    for (const name of names) {
      const value = tags.get(name);
      if (value !== undefined && oneLine(value) !== "") return oneLine(value);
    }
    return null;
  };
  const credit = first("artist", "artists", "albumartist") ?? guess.artist ?? "";
  // Picard writes the list beside the sleeve's wording.
  const listed = split(tags.get("artists"), /\s*;\s*/);
  const artists = listed.length > 0 ? listed : splitArtists(credit);
  const albumCredit = first("albumartist", "band", "ensemble");
  const albumListed = split(tags.get("albumartists"), /\s*;\s*/);
  const albumArtists =
    albumListed.length > 0 ? albumListed : albumCredit === null ? [] : splitArtists(albumCredit);
  // A file without any tag on an album gets the one its path says; a tagged loose file does not.
  const album = first("album") ?? (guess.album && guess.track !== null ? guess.album : null);
  const compilation =
    /^(?:1|true|yes)$/i.test(first("compilation", "itunescompilation", "tcmp") ?? "") ||
    albumArtists.some(isVarious);
  const seriesPosition = Number.parseFloat(
    first("seriespart", "seriesindex", "movement", "mvin") ?? "",
  );
  const artistMbids = mbids(tags.get("musicbrainzartistid"));
  const albumArtistMbids = mbids(tags.get("musicbrainzalbumartistid"));
  return {
    title: first("title") ?? guess.title,
    titleSort: first("titlesort", "sorttitle", "sortname"),
    artists: artists.filter((name) => !isVarious(name)),
    artistCredit: credit.replace(/\s*;\s*/g, ", "),
    artistSort: first("artistsort", "sortartist"),
    artistMbids,
    album,
    albumSort: first("albumsort", "sortalbum"),
    albumArtists: albumArtists.filter((name) => !isVarious(name)),
    albumArtistCredit: albumCredit?.replace(/\s*;\s*/g, ", ") ?? null,
    albumArtistSort: first("albumartistsort", "sortalbumartist"),
    albumArtistMbids,
    compilation,
    disc: position(tags.get("disc") ?? tags.get("discnumber")) ?? guess.disc,
    track: position(tags.get("track") ?? tags.get("tracknumber")) ?? guess.track,
    year: yearOf(
      first("originalyear") ?? first("originaldate", "tdor", "tory") ?? first("date", "year") ?? "",
    ),
    // "(17)Rock": the old numbered genres keep their number in front.
    genres: split(tags.get("genre"), /\s*;\s*|\s+\/\s+/)
      .map((name) => name.replace(/^\(\d{1,3}\)/, "").trim())
      .filter((name) => name !== "" && !/^\d+$/.test(name))
      .slice(0, 20),
    composers: split(tags.get("composer"), /\s*;\s*|\s+\/\s+/),
    narrators: split(first("narrator", "narratedby", "nrt", "reader") ?? "", /\s*[;,]\s*/),
    series: first("series", "movementname", "mvnm"),
    seriesPosition: Number.isFinite(seriesPosition) ? seriesPosition : null,
    description:
      (tags.get("description") ?? tags.get("synopsis") ?? tags.get("comment"))?.slice(0, 10_000) ??
      null,
    language: first("language"),
    recordingMbid: mbids(tags.get("musicbrainztrackid"))[0] ?? null,
    albumMbid: mbids(tags.get("musicbrainzalbumid"))[0] ?? null,
    replayGain: replayGain(tags),
  };
}

/** The tags with a manager's changes laid over them. */
export function withOverrides(tags: AudioTags, changes: MusicOverrides): AudioTags {
  const next: AudioTags = { ...tags };
  if (changes.title !== undefined) {
    next.title = changes.title;
    next.titleSort = null;
  }
  if (changes.sortTitle !== undefined) next.titleSort = changes.sortTitle;
  if (changes.artists !== undefined) {
    next.artists = changes.artists;
    next.artistCredit = changes.artists.join(", ");
    next.artistSort = null;
    next.artistMbids = [];
  }
  if (changes.album !== undefined) {
    next.album = changes.album;
    next.albumSort = null;
    next.albumMbid = null;
  }
  if (changes.albumArtists !== undefined) {
    next.albumArtists = changes.albumArtists;
    next.albumArtistCredit = changes.albumArtists.join(", ") || null;
    next.albumArtistSort = null;
    next.albumArtistMbids = [];
    next.albumMbid = null;
  }
  if (changes.compilation !== undefined) next.compilation = changes.compilation;
  if (changes.disc !== undefined) next.disc = changes.disc;
  if (changes.track !== undefined) next.track = changes.track;
  if (changes.year !== undefined) next.year = changes.year;
  if (changes.genres !== undefined) next.genres = changes.genres;
  if (changes.composers !== undefined) next.composers = changes.composers;
  return next;
}
