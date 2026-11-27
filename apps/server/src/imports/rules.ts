// SPDX-License-Identifier: MPL-2.0
import { extensionOf, isIgnoredName, isSubtitleFile, isVideoFile } from "../library/parse.ts";

/**
 * What an import folder holds, file by file, judged by name and size alone.
 *
 * A file a program is still writing is unfinished: it has another extension after the video one
 * ("Film.mkv.part", "Film.mp4.abc"), or a control file beside it ("Film.mkv.aria2"). It waits,
 * and is looked at again when it changes. Samples, trailers, extras and files far smaller than a
 * film are excluded, and so is everything that is not a video or a subtitle: those are never
 * moved and never listed, only shown with their reason.
 */

export interface SeenFile {
  /** Below the import folder, with `/` separators. */
  rel: string;
  size: number;
  mtimeMs: number;
}

export type Verdict =
  | { status: "candidate"; subtitles: string[] }
  | { status: "unfinished"; reason: string }
  | { status: "excluded"; reason: string; leftover: boolean }
  /** Not worth a line: dotfiles, the system's own files. */
  | { status: "skip" };

export interface RuleLimits {
  /** A film smaller than this is not one. */
  minFilmBytes: number;
  /** An episode smaller than this is not one. */
  minEpisodeBytes: number;
}

const MB = 1024 * 1024;

export const DEFAULT_LIMITS: RuleLimits = {
  minFilmBytes: 100 * MB,
  minEpisodeBytes: 20 * MB,
};

/** Video extensions a finished file ends in. Anything after one of these means it is not done. */
const VIDEO_THEN_MORE =
  /\.(?:mkv|mp4|m4v|avi|mov|wmv|mpg|mpeg|ts|m2ts|webm|divx|flv|ogv|3gp)\.([^./]+)$/i;

/** Extensions of the control and temporary files programs keep beside what they write. */
const CONTROL =
  /^(?:part|partial|!qb|aria2|crdownload|download|tmp|temp|ytdl|filepart|unfinished|incomplete|dlpart|opdownload)$/i;

/** Words that mark something that is not the film or episode itself. */
const NOT_THE_FEATURE =
  /(?:^|[^a-z0-9])(sample|trailers?|featurettes?|extras?|behind[ ._-]*the[ ._-]*scenes|deleted[ ._-]*scenes?|interviews?|teasers?)(?:[^a-z0-9]|$)/i;

/** What is left behind in a folder once its film is moved, and may go when a manager says so. */
const LEFTOVER_EXTENSIONS = new Set([
  "nfo",
  "txt",
  "jpg",
  "jpeg",
  "png",
  "gif",
  "webp",
  "url",
  "exe",
  "srr",
  "sfv",
  "md5",
  "sha1",
  "html",
  "htm",
  "lnk",
  "website",
]);

/** The system's own files, which say nothing. */
const SYSTEM_FILES = new Set(["thumbs.db", "desktop.ini", ".ds_store"]);

export function dirOf(rel: string): string {
  const at = rel.lastIndexOf("/");
  return at === -1 ? "" : rel.slice(0, at);
}

export function nameOf(rel: string): string {
  return rel.slice(rel.lastIndexOf("/") + 1);
}

function stemOf(name: string): string {
  const dot = name.lastIndexOf(".");
  return dot <= 0 ? name : name.slice(0, dot);
}

/** The word that makes this path something other than the feature, if one does. */
export function nonFeatureWord(rel: string): string | null {
  const segments = rel.split("/");
  const last = segments.length - 1;
  for (const [index, segment] of segments.entries()) {
    const text = index === last ? stemOf(segment) : segment;
    const found = NOT_THE_FEATURE.exec(text);
    if (found?.[1]) return found[1].toLowerCase();
  }
  return null;
}

/** Whether a file of this name is one a manager may let Lobby delete as a leftover. */
export function isLeftoverName(name: string): boolean {
  const lower = name.toLowerCase();
  return SYSTEM_FILES.has(lower) || LEFTOVER_EXTENSIONS.has(extensionOf(lower));
}

/** Whether a name is one that is still being written, by itself. */
export function unfinishedByName(name: string): string | null {
  const more = VIDEO_THEN_MORE.exec(name);
  if (more?.[1] && !isSubtitleFile(name)) {
    return `It has “.${more[1]}” after the video extension, so it is not finished yet.`;
  }
  if (isIgnoredName(name) && !name.startsWith(".")) {
    return "Its name says it is still being written.";
  }
  return null;
}

/** Whether a control file sits beside `name` in a folder that holds `siblings`. */
function hasCompanion(name: string, siblings: readonly string[]): boolean {
  const lower = name.toLowerCase();
  const stem = stemOf(lower);
  return siblings.some((other) => {
    const candidate = other.toLowerCase();
    if (candidate === lower) return false;
    for (const base of [lower, stem]) {
      if (!candidate.startsWith(`${base}.`)) continue;
      const rest = candidate.slice(base.length + 1);
      if (CONTROL.test(rest)) return true;
    }
    return false;
  });
}

/**
 * Judges every file of one import folder.
 *
 * @param files every file below the folder
 * @param episodeLike whether a path reads as an episode (a season and episode in its name)
 */
export function judgeFiles(
  files: readonly SeenFile[],
  episodeLike: (rel: string) => boolean,
  limits: RuleLimits = DEFAULT_LIMITS,
): Map<string, Verdict> {
  const verdicts = new Map<string, Verdict>();
  const byDir = new Map<string, SeenFile[]>();
  for (const file of files) {
    const dir = dirOf(file.rel);
    byDir.set(dir, [...(byDir.get(dir) ?? []), file]);
  }

  for (const [, inDir] of byDir) {
    const names = inDir.map((file) => nameOf(file.rel));
    const videos: SeenFile[] = [];
    for (const file of inDir) {
      const name = nameOf(file.rel);
      if (name.startsWith(".") || SYSTEM_FILES.has(name.toLowerCase())) {
        verdicts.set(file.rel, { status: "skip" });
        continue;
      }
      // A program's control file beside its video ("Film.mkv.aria2") is said on the video.
      const base = name.replace(/\.[^.]+$/, "");
      if (base !== name && isVideoFile(base) && names.includes(base)) {
        verdicts.set(file.rel, { status: "skip" });
        continue;
      }
      const unfinished = unfinishedByName(name);
      if (unfinished) {
        verdicts.set(file.rel, { status: "unfinished", reason: unfinished });
        continue;
      }
      if (isSubtitleFile(name)) continue;
      if (!isVideoFile(name)) {
        // A control file beside a video is said on the video; on its own it is a leftover.
        verdicts.set(file.rel, {
          status: "excluded",
          reason: "It is not a video.",
          leftover: isLeftoverName(name),
        });
        continue;
      }
      if (hasCompanion(name, names)) {
        verdicts.set(file.rel, {
          status: "unfinished",
          reason: "A program still keeps a file beside it, so it is not finished yet.",
        });
        continue;
      }
      videos.push(file);
    }

    // Episodes of a season vary in size; a film's sample is a sliver of the film.
    const largestFilm = Math.max(
      0,
      ...videos.filter((file) => !episodeLike(file.rel)).map((file) => file.size),
    );
    const features: SeenFile[] = [];
    for (const file of videos) {
      const word = nonFeatureWord(file.rel);
      if (word) {
        verdicts.set(file.rel, {
          status: "excluded",
          reason: `Its name says “${word}”, so it is not the film or episode itself.`,
          leftover: true,
        });
        continue;
      }
      const episode = episodeLike(file.rel);
      const minimum = episode ? limits.minEpisodeBytes : limits.minFilmBytes;
      if (file.size < minimum) {
        verdicts.set(file.rel, {
          status: "excluded",
          reason: `At ${megabytes(file.size)} it is too small for ${episode ? "an episode" : "a film"}.`,
          leftover: true,
        });
        continue;
      }
      if (!episode && largestFilm > 0 && file.size * 4 < largestFilm) {
        verdicts.set(file.rel, {
          status: "excluded",
          reason: "It is far smaller than the main file beside it.",
          leftover: true,
        });
        continue;
      }
      features.push(file);
    }

    // Subtitles go along with the video they belong to: the one whose name they start with,
    // or the only one in the folder.
    const subtitles = inDir.filter(
      (file) => isSubtitleFile(nameOf(file.rel)) && !verdicts.has(file.rel),
    );
    const claimed = new Set<string>();
    for (const video of features) {
      const stem = stemOf(nameOf(video.rel)).toLowerCase();
      const own = subtitles
        .filter((sub) => {
          const name = nameOf(sub.rel).toLowerCase();
          return name.startsWith(`${stem}.`) || (features.length === 1 && !claimed.has(sub.rel));
        })
        .map((sub) => sub.rel);
      for (const rel of own) claimed.add(rel);
      verdicts.set(video.rel, { status: "candidate", subtitles: own });
    }
    for (const sub of subtitles) {
      if (claimed.has(sub.rel)) continue;
      verdicts.set(sub.rel, {
        status: "excluded",
        reason: "A subtitle without a video it belongs to.",
        leftover: false,
      });
    }
  }

  // Subtitles in a "Subs" folder belong to the only video one folder up.
  for (const [dir, inDir] of byDir) {
    if (!/^(?:subs?|subtitles?)$/i.test(nameOf(dir))) continue;
    const parent = dirOf(dir);
    const owners = [...verdicts.entries()].filter(
      ([rel, verdict]) => verdict.status === "candidate" && dirOf(rel) === parent,
    );
    if (owners.length !== 1) continue;
    const [ownerRel, owner] = owners[0] ?? [];
    if (!ownerRel || owner?.status !== "candidate") continue;
    for (const file of inDir) {
      const verdict = verdicts.get(file.rel);
      if (isSubtitleFile(nameOf(file.rel)) && verdict?.status === "excluded") {
        owner.subtitles.push(file.rel);
        verdicts.delete(file.rel);
      }
    }
  }
  return verdicts;
}

function megabytes(bytes: number): string {
  return bytes < MB ? "less than 1 MB" : `${String(Math.round(bytes / MB))} MB`;
}
