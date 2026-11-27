// SPDX-License-Identifier: MPL-2.0
/**
 * Turns a path under a library root into what Lobby thinks the file is.
 *
 * This is deliberately conservative. It reads only the path: no network, no
 * file contents. Anything it cannot place is returned as `unknown` with the
 * reason in `evidence`, so a manager can sort it out on the review screen
 * instead of finding a wrong title on the shelf.
 */

export type SourceHint = "movies" | "series" | "personal" | "mixed";

export type ParsedKind = "movie" | "episode" | "extra" | "personal" | "unknown";

export interface ParsedMedia {
  kind: ParsedKind;
  /** The film's title, or the show's title for an episode. */
  title: string;
  year: number | null;
  season: number | null;
  episode: number | null;
  /** Last episode in a combined file such as S01E01E02. */
  episodeEnd: number | null;
  episodeTitle: string | null;
  airDate: string | null;
  edition: string | null;
  /** Disc or part number for a film split over several files. */
  part: number | null;
  /** For an extra: what it is. */
  extraKind: "trailer" | "featurette" | "sample" | null;
  imdbId: string | null;
  tmdbId: number | null;
  /** Why the parser decided what it did, for the review screen. */
  evidence: string[];
}

const VIDEO_EXTENSIONS = new Set([
  "mkv",
  "mp4",
  "m4v",
  "mov",
  "avi",
  "webm",
  "mpg",
  "mpeg",
  "ts",
  "m2ts",
  "wmv",
  "flv",
  "ogv",
  "divx",
  "3gp",
]);

const SUBTITLE_EXTENSIONS = new Set(["srt", "vtt", "ass", "ssa", "sub", "idx", "sup"]);

export function extensionOf(name: string): string {
  const dot = name.lastIndexOf(".");
  return dot <= 0 ? "" : name.slice(dot + 1).toLowerCase();
}

/**
 * Bump when the parser reads names differently, so existing files are read again
 * with the new rules at the next start.
 */
export const PARSER_VERSION = 5;

export function isVideoFile(name: string): boolean {
  return VIDEO_EXTENSIONS.has(extensionOf(name));
}

export function isSubtitleFile(name: string): boolean {
  return SUBTITLE_EXTENSIONS.has(extensionOf(name));
}

/**
 * Files Lobby never indexes: dotfiles, macOS resource forks (`._name`), and
 * transfers that are still being written.
 */
export function isIgnoredName(name: string): boolean {
  if (name.startsWith(".")) return true;
  const lower = name.toLowerCase();
  return (
    lower.endsWith(".part") ||
    lower.endsWith(".partial") ||
    lower.endsWith(".crdownload") ||
    lower.endsWith(".download") ||
    lower.endsWith(".tmp") ||
    lower.endsWith(".!qb") ||
    lower.endsWith(".lobby-upload") ||
    lower.endsWith(".ytdl") ||
    // "name.temp.mp4": a download tool's file that is still being assembled.
    /\.temp\.[a-z0-9]+$/.test(lower)
  );
}

// Words that mark where a release name stops being a title.
const RELEASE_TOKEN =
  /^(?:\d{3,4}[pi]|4k|uhd|hd|sd|hdr|hdr10|dv|10bit|8bit|bluray|blu-ray|bdrip|brrip|bdremux|remux|dvdrip|dvdscr|dvd|web|web-dl|webdl|webrip|hdtv|hdrip|pdtv|cam|ts|x264|x265|h264|h265|h\.264|h\.265|hevc|avc|xvid|divx|av1|aac|aac2|ac3|eac3|dts|ddp?\d?|dd\+?|atmos|truehd|flac|mp3|opus|proper|repack|internal|limited|multi|dubbed|subbed|nl|eng|upscaled|amzn|nf|dsnp|dnsp|hmax|max|atvp|hulu|pcok|itunes|yts|yify|rarbg|eztv)$/i;

const EDITION_PATTERNS: [RegExp, string][] = [
  [/\bdirector'?s[ .]cut\b/i, "Director's Cut"],
  [/\bextended(?:[ .](?:cut|edition))?\b/i, "Extended"],
  [/\bunrated\b/i, "Unrated"],
  [/\btheatrical(?:[ .](?:cut|edition))?\b/i, "Theatrical"],
  [/\bremastered\b/i, "Remastered"],
  [/\bspecial[ .]edition\b/i, "Special Edition"],
  [/\bfinal[ .]cut\b/i, "Final Cut"],
  [/\bimax\b/i, "IMAX"],
];

const EXTRA_FOLDERS = new Map<string, "trailer" | "featurette">([
  ["trailers", "trailer"],
  ["trailer", "trailer"],
  ["extras", "featurette"],
  ["extra", "featurette"],
  ["featurettes", "featurette"],
  ["behind the scenes", "featurette"],
  ["deleted scenes", "featurette"],
  ["interviews", "featurette"],
  ["bonus", "featurette"],
  ["shorts", "featurette"],
  ["scenes", "featurette"],
  ["other", "featurette"],
]);

function isYear(value: number): boolean {
  return value >= 1888 && value <= new Date().getUTCFullYear() + 2;
}

function tidy(text: string): string {
  return text
    .replace(/[._]+/g, " ")
    .replace(/\s+/g, " ")
    .replace(/^[\s\-–—:,]+|[\s\-–—:,]+$/g, "")
    .trim();
}

/** Removes `[group]`, `{tags}` and parentheses that hold release details, not a year. */
function stripBrackets(text: string): string {
  return text
    .replace(/\[[^\]]*\]/g, " ")
    .replace(/\{[^}]*\}/g, " ")
    .replace(/\(([^)]*)\)/g, (whole: string, inner: string) => {
      if (/^\s*(?:19|20)\d{2}(?:\s*[-–]\s*(?:(?:19|20)?\d{2})?)?\s*$/.test(inner)) return whole;
      const words = inner.split(/[\s.\-_]+/).filter(Boolean);
      return words.some((word) => RELEASE_TOKEN.test(word)) ? " " : whole;
    });
}

/** Cuts a release name at the first word that describes the file rather than the title. */
function cutAtReleaseTokens(text: string): string {
  const words = text.split(" ");
  const cut = words.findIndex((word, index) => index > 0 && RELEASE_TOKEN.test(word));
  return (cut === -1 ? words : words.slice(0, cut)).join(" ");
}

function findEdition(text: string): string | null {
  const plex = /\{edition-([^}]+)\}/i.exec(text);
  if (plex?.[1]) return plex[1].trim();
  for (const [pattern, name] of EDITION_PATTERNS) if (pattern.test(text)) return name;
  return null;
}

function findProviderIds(text: string): { imdbId: string | null; tmdbId: number | null } {
  const imdb = /\b(tt\d{7,9})\b/i.exec(text);
  const tmdb = /[[{]tmdb(?:id)?[-=](\d+)[\]}]/i.exec(text);
  return {
    imdbId: imdb?.[1]?.toLowerCase() ?? null,
    tmdbId: tmdb?.[1] ? Number(tmdb[1]) : null,
  };
}

interface TitleYear {
  title: string;
  year: number | null;
}

/** Reads a title and release year out of a film's file or folder name. */
export function parseTitleYear(raw: string): TitleYear {
  let text = raw.replace(/\{edition-[^}]+\}/gi, " ");
  text = stripBrackets(text);

  // "1988 - Oliver and Company"
  const leading = /^\s*((?:19|20)\d{2})\s+-\s+(.+)$/.exec(text);
  if (leading?.[1] && leading[2] && isYear(Number(leading[1]))) {
    return { title: tidy(cutAtReleaseTokens(tidy(leading[2]))), year: Number(leading[1]) };
  }

  // "Aladdin (1992)"
  const bracketed = /^(.*?)\(\s*((?:19|20)\d{2})\s*\)/.exec(text);
  if (bracketed?.[1] && bracketed[2] && tidy(bracketed[1]) && isYear(Number(bracketed[2]))) {
    return { title: tidy(bracketed[1]), year: Number(bracketed[2]) };
  }

  // "Goat.2026.1080p.BluRay" or "Charlie the Wonderdog 2026 1080p AMZN"
  const words = tidy(text.replace(/[()]/g, " ")).split(" ");
  for (let index = words.length - 1; index > 0; index -= 1) {
    const word = words[index] ?? "";
    if (!/^(?:19|20)\d{2}$/.test(word) || !isYear(Number(word))) continue;
    const next = words[index + 1];
    if (next === undefined || RELEASE_TOKEN.test(next)) {
      return { title: words.slice(0, index).join(" "), year: Number(word) };
    }
  }

  let title = tidy(cutAtReleaseTokens(words.join(" ")));
  for (const [pattern] of EDITION_PATTERNS) title = tidy(title.replace(pattern, " "));
  return { title, year: null };
}

interface EpisodeMarker {
  season: number | null;
  episode: number;
  episodeEnd: number | null;
  /** Index range of the marker in the text it was found in. */
  start: number;
  end: number;
  how: string;
}

function findEpisodeMarker(stem: string): EpisodeMarker | null {
  // S01E02, S01 E36, S01E01E02, S01E02-E03, S01E02-03
  const sxe =
    /(?<![a-z0-9])s(\d{1,2})[ ._-]{0,3}e(\d{1,3})(?:[ ._-]?(?:e|-)(\d{1,3})(?!\d))?/i.exec(stem);
  if (sxe?.[1] && sxe[2]) {
    const episode = Number(sxe[2]);
    let end = sxe[3] ? Number(sxe[3]) : null;
    let length = sxe[0].length;
    // "S01E02-720p" is not episodes 2 to 720.
    if (end !== null && (end <= episode || end > episode + 3)) {
      end = null;
      length = sxe[0].lastIndexOf(sxe[3] ?? "") - 1;
      while (length > 0 && /[ ._\-eE]/.test(sxe[0][length - 1] ?? "")) length -= 1;
    }
    return {
      season: Number(sxe[1]),
      episode,
      episodeEnd: end,
      start: sxe.index,
      end: sxe.index + length,
      how: "season and episode marker",
    };
  }

  // 1x02
  const cross = /(?<![a-z0-9])(\d{1,2})x(\d{2,3})(?![0-9a-z])/i.exec(stem);
  if (cross?.[1] && cross[2]) {
    return {
      season: Number(cross[1]),
      episode: Number(cross[2]),
      episodeEnd: null,
      start: cross.index,
      end: cross.index + cross[0].length,
      how: "1x02 marker",
    };
  }

  // "Ep. 09", "Episode 9", "E09"
  const ep = /(?<![a-z0-9])(?:ep(?:isode)?\.?\s*|e)(\d{1,3})(?![0-9a-z])/i.exec(stem);
  if (ep?.[1]) {
    return {
      season: null,
      episode: Number(ep[1]),
      episodeEnd: null,
      start: ep.index,
      end: ep.index + ep[0].length,
      how: "episode number without a season",
    };
  }
  return null;
}

/** Reads a season number out of a folder name such as "Season 02" or "Show S02 (360p)". */
export function seasonFromFolder(folder: string): number | null {
  if (/^specials?$/i.test(folder.trim())) return 0;
  const named = /(?<![a-z])(?:season|series|seizoen|staffel|saison)[ ._-]*(\d{1,2})(?!\d)/i.exec(
    folder,
  );
  if (named?.[1]) return Number(named[1]);
  const short = /(?<![a-z0-9])s(\d{1,2})(?![0-9a-z])/i.exec(folder);
  if (short?.[1]) return Number(short[1]);
  return null;
}

function cleanShowTitle(folder: string): TitleYear {
  const parsed = parseTitleYear(
    folder.replace(/(?<![a-z0-9])s\d{1,2}(?:-s\d{1,2})?(?![0-9a-z])/gi, " "),
  );
  const title = tidy(parsed.title.replace(/\b(?:complete|collection|season \d+)\b.*$/i, " "));
  return { title: title || tidy(folder), year: parsed.year };
}

function cleanEpisodeTitle(raw: string): string | null {
  // Video sites append the channel's name and tags after an emoji; the title comes before it.
  const beforeEmoji = raw.replace(/\s*\p{Extended_Pictographic}.*$/u, "");
  const text = tidy(beforeEmoji).length > 0 ? beforeEmoji : raw;
  // "S01E05 1080p x265-GROUP" has no title at all. Only words that are never a title's first.
  if (
    /^[\s._-]*(?:\d{3,4}[pi]|[xh][. ]?26[45]|hevc|web-?dl|web-?rip|blu-?ray)(?![a-z0-9])/i.test(
      text,
    )
  )
    return null;
  const stripped = tidy(cutAtReleaseTokens(tidy(stripBrackets(text).replace(/[()]/g, " "))));
  return stripped.length > 0 && !RELEASE_TOKEN.test(stripped) ? stripped : null;
}

function empty(kind: ParsedKind, title: string): ParsedMedia {
  return {
    kind,
    title,
    year: null,
    season: null,
    episode: null,
    episodeEnd: null,
    episodeTitle: null,
    airDate: null,
    edition: null,
    part: null,
    extraKind: null,
    imdbId: null,
    tmdbId: null,
    evidence: [],
  };
}

/**
 * @param relPath path below the library root, with `/` separators
 * @param hint what the household said this root holds
 */
export function parseMediaPath(relPath: string, hint: SourceHint): ParsedMedia {
  const segments = relPath.split("/").filter(Boolean);
  const file = segments.at(-1) ?? relPath;
  const folders = segments.slice(0, -1);
  const stem = file.replace(/\.[^.]+$/, "");
  const ids = findProviderIds(relPath);

  if (hint === "personal") {
    const result = empty("personal", tidy(stem));
    result.evidence.push("This folder holds personal videos.");
    return result;
  }

  // Extras: a recognised folder, or a recognised suffix on the file name.
  const extraFolder = folders.map((f) => EXTRA_FOLDERS.get(f.toLowerCase().trim())).find(Boolean);
  const suffix =
    /[-. _](trailer|featurette|behindthescenes|deleted|interview|scene|short|sample)$/i.exec(stem);
  const isSample = /^sample$/i.test(stem) || suffix?.[1]?.toLowerCase() === "sample";
  if (extraFolder || suffix || /^trailer$/i.test(stem) || isSample) {
    const owner = folders[0] ?? stem;
    const ownerParsed = hint === "series" ? cleanShowTitle(owner) : parseTitleYear(owner);
    const result = empty("extra", ownerParsed.title);
    result.year = ownerParsed.year;
    result.episodeTitle = tidy(stripBrackets(stem)) || stem;
    result.extraKind = isSample
      ? "sample"
      : /trailer/i.test(suffix?.[1] ?? stem) && (suffix || /^trailer$/i.test(stem))
        ? "trailer"
        : (extraFolder ?? "featurette");
    result.imdbId = ids.imdbId;
    result.tmdbId = ids.tmdbId;
    result.evidence.push(
      extraFolder
        ? `In an extras folder ("${folders.join("/")}").`
        : "The file name ends in an extra's suffix.",
    );
    return result;
  }

  const marker = findEpisodeMarker(stem);
  const folderSeason = folders
    .slice()
    .reverse()
    .map(seasonFromFolder)
    .find((value) => value !== null);

  // A full season-and-episode marker means an episode wherever the file sits:
  // loose episodes do end up in a films folder.
  if (hint === "series" || (marker && marker.season !== null)) {
    return parseEpisode({
      stem,
      folders,
      marker,
      folderSeason: folderSeason ?? null,
      ids,
      showFromName: hint !== "series",
    });
  }

  return parseMovie({ stem, folders, ids });
}

interface EpisodeInput {
  stem: string;
  folders: string[];
  marker: EpisodeMarker | null;
  folderSeason: number | null;
  ids: { imdbId: string | null; tmdbId: number | null };
  /** Outside a series folder the top folder is not a show, so the file name names it. */
  showFromName: boolean;
}

function parseEpisode({
  stem,
  folders,
  marker,
  folderSeason,
  ids,
  showFromName,
}: EpisodeInput): ParsedMedia {
  const beforeMarker = marker ? stem.slice(0, marker.start) : "";
  const named = showFromName && tidy(stripBrackets(beforeMarker)).length > 0;
  const show =
    folders[0] && !named ? cleanShowTitle(folders[0]) : cleanShowTitle(beforeMarker || stem);
  // "Friends (1994) - S09E17" names the show's year even when the folder does not.
  const yearInName = /\(((?:19|20)\d{2})\)/.exec(beforeMarker);

  const result = empty("episode", show.title);
  result.year = show.year ?? (yearInName?.[1] ? Number(yearInName[1]) : null);
  result.imdbId = ids.imdbId;
  result.tmdbId = ids.tmdbId;
  result.evidence.push(
    folders[0] && !named
      ? `Show taken from the folder "${folders[0]}".`
      : "Show taken from the file name.",
  );

  if (marker) {
    result.season = marker.season ?? folderSeason ?? 1;
    result.episode = marker.episode;
    result.episodeEnd = marker.episodeEnd;
    result.episodeTitle = cleanEpisodeTitle(stem.slice(marker.end));
    result.evidence.push(`Found a ${marker.how} in the file name.`);
    if (marker.season === null) {
      result.evidence.push(
        folderSeason === null
          ? "No season in the name or folder, so season 1 is assumed."
          : `Season ${folderSeason} taken from the folder.`,
      );
    }
    return result;
  }

  // "1013 The Honey-Mousers" inside "Season 10": season digits, then two episode digits.
  const packed = /^(\d{3,4})(?!\d)[ ._-]+(.+)$/.exec(stem);
  if (packed?.[1] && packed[2] && folderSeason !== null && folderSeason > 0) {
    const digits = packed[1];
    const seasonDigits = String(folderSeason);
    if (digits.startsWith(seasonDigits) && digits.length === seasonDigits.length + 2) {
      result.season = folderSeason;
      result.episode = Number(digits.slice(seasonDigits.length));
      result.episodeTitle = cleanEpisodeTitle(packed[2]);
      result.evidence.push(
        `The number ${digits} read as season ${folderSeason}, episode ${result.episode}.`,
      );
      return result;
    }
  }

  // "2026-03-20 - Let's Feed The Birds"
  const dated = /^((?:19|20)\d{2})[-.](\d{2})[-.](\d{2})(?!\d)[ ._-]*(.*)$/.exec(stem);
  if (dated?.[1] && dated[2] && dated[3]) {
    result.airDate = `${dated[1]}-${dated[2]}-${dated[3]}`;
    result.season = folderSeason;
    result.episodeTitle = cleanEpisodeTitle(dated[4] ?? "");
    result.evidence.push("The file name starts with a date and has no episode number.");
    return result;
  }

  // "041655DVD The Hole Idea LT" inside "1955": a release date written as month, day, year.
  const yearFolder = folders
    .map((folder) => /^((?:19|20)\d{2})$/.exec(folder.trim())?.[1])
    .find(Boolean);
  const coded = /^(\d{2})(\d{2})(\d{2})(?:DVD)?[ ._-]+(.+?)(?:\s+(?:LT|MM))?$/.exec(stem);
  if (coded?.[1] && coded[2] && coded[3] && coded[4] && yearFolder?.endsWith(coded[3])) {
    const month = Number(coded[1]);
    const day = Number(coded[2]);
    if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
      result.airDate = `${yearFolder}-${coded[1]}-${coded[2]}`;
      result.season = folderSeason;
      result.episodeTitle = cleanEpisodeTitle(coded[4]);
      result.evidence.push(
        `The number ${coded[1]}${coded[2]}${coded[3]} read as the date ${result.airDate}.`,
      );
      return result;
    }
  }

  // "079 - Life with Tom": an episode number counted across the whole show.
  const counted = /^(\d{1,3})(?!\d)\s*[-.]\s+(.+)$/.exec(stem);
  if (counted?.[1] && counted[2]) {
    result.season = folderSeason ?? 1;
    result.episode = Number(counted[1]);
    result.episodeTitle = cleanEpisodeTitle(counted[2]);
    result.evidence.push(
      folderSeason === null
        ? "The file name starts with an episode number and no season, so season 1 is assumed."
        : `Episode number from the file name, season ${folderSeason} from the folder.`,
    );
    return result;
  }

  result.season = folderSeason;
  result.episodeTitle = cleanEpisodeTitle(stem) ?? tidy(stem);
  result.evidence.push("No episode number found in the file name.");
  return result;
}

interface MovieInput {
  stem: string;
  folders: string[];
  ids: { imdbId: string | null; tmdbId: number | null };
}

const GENRE_LABEL =
  /\s+-\s+(?:action|adventure|animation|comedy|crime|documentary|drama|family|fantasy|horror|musical|mystery|romance|sci-?fi|thriller|war|western)$/i;

/**
 * Films kept together in a folder named after the series ("Police Academy/03 Police
 * Academy 3 Back In Training - Comedy 1986") often carry a running number in front
 * and a genre label behind. Both are dropped; the number only when what follows it
 * starts with the folder's name, so "12 Angry Men" keeps its twelve.
 */
function collectionFilmTitle(title: string, folderTitle: string): string {
  let cleaned = title;
  const numbered = /^\d{1,2}\s+(?:-\s+)?(.+)$/.exec(cleaned);
  const folderKey = normalizeTitle(folderTitle);
  if (numbered?.[1] && folderKey && normalizeTitle(numbered[1]).startsWith(folderKey)) {
    cleaned = numbered[1];
    cleaned = tidy(cleaned.replace(GENRE_LABEL, ""));
  }
  return cleaned;
}

function parseMovie({ stem, folders, ids }: MovieInput): ParsedMedia {
  const fromFile = parseTitleYear(stem);
  const folder = folders.at(-1);
  const fromFolder = folder ? parseTitleYear(folder) : null;

  // A folder named "Title (Year)" is the household's own label; trust it over a release name.
  const useFolder = fromFolder !== null && fromFolder.year !== null && fromFolder.title.length > 0;
  const chosen = useFolder ? fromFolder : fromFile;

  const title =
    !useFolder && fromFolder ? collectionFilmTitle(chosen.title, fromFolder.title) : chosen.title;

  const result = empty(title ? "movie" : "unknown", title || tidy(stem));
  result.year = chosen.year ?? fromFile.year;
  result.edition = findEdition(stem) ?? (folder ? findEdition(folder) : null);
  result.imdbId = ids.imdbId;
  result.tmdbId = ids.tmdbId;

  const part = /(?<![a-z])(?:cd|disc|disk|part|pt)[ ._-]?(\d)(?!\d)/i.exec(stem);
  if (part?.[1]) result.part = Number(part[1]);

  result.evidence.push(
    useFolder
      ? `Title and year taken from the folder "${folder ?? ""}".`
      : "Title taken from the file name.",
  );
  if (result.year === null) result.evidence.push("No release year found.");
  if (!chosen.title) result.evidence.push("No usable title found.");
  return result;
}

/** A comparison key for titles: lower case, no punctuation, no leading article. */
export function normalizeTitle(title: string): string {
  return title
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/['’`]/g, "")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

/** A title to sort by: "The Bear" files under B. */
export function sortTitle(title: string): string {
  return normalizeTitle(title).replace(/^(?:the|a|an|de|het|een) (?=\S)/, "");
}
