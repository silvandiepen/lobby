// SPDX-License-Identifier: MPL-2.0
import { extensionOf } from "../library/parse.ts";

/**
 * The names an imported file gets in the library, in the form the parser reads back as the same
 * title: "Title (Year)/Title (Year).ext" for a film, "Show/Season 01/Show - S01E02 - Episode.ext"
 * for an episode.
 */

export interface FilmName {
  title: string;
  year: number | null;
  edition?: string | null;
  part?: number | null;
}

export interface EpisodeName {
  show: string;
  season: number;
  episode: number;
  episodeEnd?: number | null;
  episodeTitle?: string | null;
}

/** What may be in a name on every drive the household has: exFAT refuses the most. */
export function safeName(text: string, most = 120): string {
  const cleaned = Array.from(text.normalize("NFC"))
    .map((char) => (char.charCodeAt(0) < 32 || '/\\:*?"<>|'.includes(char) ? " " : char))
    .join("")
    .replace(/\s+/g, " ")
    .trim()
    // A name may not end in a dot or a space on exFAT and Windows, nor start with a dot here.
    .replace(/^[.\s]+|[.\s]+$/g, "");
  return Array.from(cleaned).slice(0, most).join("").trim();
}

const pad = (value: number): string => String(value).padStart(2, "0");

export function filmTarget(film: FilmName, extension: string): string {
  const title = safeName(film.title) || "Untitled";
  const base = film.year === null ? title : `${title} (${String(film.year)})`;
  const edition = film.edition ? ` - ${safeName(film.edition, 40)}` : "";
  const part = film.part ? ` - Part ${String(film.part)}` : "";
  return `${base}/${base}${edition}${part}.${extension.toLowerCase()}`;
}

export function episodeTarget(name: EpisodeName, extension: string): string {
  const show = safeName(name.show) || "Untitled";
  const numbers =
    `S${pad(name.season)}E${pad(name.episode)}` +
    (name.episodeEnd && name.episodeEnd > name.episode ? `-E${pad(name.episodeEnd)}` : "");
  const title = name.episodeTitle ? safeName(name.episodeTitle, 80) : "";
  const file = `${show} - ${numbers}${title ? ` - ${title}` : ""}`;
  return `${show}/Season ${pad(name.season)}/${file}.${extension.toLowerCase()}`;
}

/**
 * A subtitle's name beside its video: what followed the video's name stays ("Film.en.srt" →
 * "Title (Year).en.srt"); a subtitle named otherwise keeps its own name after the video's.
 */
export function subtitleTarget(
  videoTarget: string,
  videoName: string,
  subtitleName: string,
): string {
  const dot = videoTarget.lastIndexOf(".");
  const base = dot === -1 ? videoTarget : videoTarget.slice(0, dot);
  const videoStem = videoName.replace(/\.[^.]+$/, "").toLowerCase();
  const extension = extensionOf(subtitleName);
  const subtitleStem = subtitleName.slice(0, subtitleName.length - extension.length - 1);
  let middle: string;
  if (subtitleStem.toLowerCase() === videoStem) middle = "";
  else if (subtitleStem.toLowerCase().startsWith(`${videoStem}.`)) {
    middle = subtitleStem.slice(videoStem.length);
  } else middle = `.${safeName(subtitleStem, 40)}`;
  return `${base}${middle.replace(/[/\\]/g, "")}.${extension}`;
}
