// SPDX-License-Identifier: MPL-2.0
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export interface Chapter {
  title: string | null;
  startMs: number;
  endMs: number;
}

/** What a file's chapters say of its intro and credits. */
export interface ChapterMarkers {
  intro: { startMs: number; endMs: number } | null;
  credits: { startMs: number } | null;
}

/** Reads a file's chapters with ffprobe: headers only. */
export async function readChapters(path: string, ffprobePath = "ffprobe"): Promise<Chapter[]> {
  const { stdout } = await execFileAsync(
    ffprobePath,
    ["-v", "error", "-print_format", "json", "-show_chapters", "--", path],
    { maxBuffer: 4 * 1024 * 1024, timeout: 60_000 },
  );
  const output = JSON.parse(stdout) as {
    chapters?: { start_time?: string; end_time?: string; tags?: Record<string, string> }[];
  };
  return (output.chapters ?? [])
    .map((chapter) => ({
      title: chapter.tags?.["title"]?.trim().slice(0, 200) || null,
      startMs: Math.round(Number(chapter.start_time) * 1000),
      endMs: Math.round(Number(chapter.end_time) * 1000),
    }))
    .filter(
      (chapter) =>
        Number.isFinite(chapter.startMs) &&
        Number.isFinite(chapter.endMs) &&
        chapter.endMs > chapter.startMs,
    );
}

// "Opening Credits" are the intro; "End Credits" and a plain "Credits" are the credits.
const CREDITS = /\b(end(ing)?|closing|outro)\b|^(ed|credits?|end credits?)$/i;
const INTRO = /\b(intro|opening|title sequence|main titles?|theme)\b|^op$/i;
const CREDITS_WORD = /\bcredits?\b/i;

export function chapterKind(title: string): "intro" | "credits" | null {
  const name = title.trim();
  if (CREDITS.test(name)) return "credits";
  if (INTRO.test(name)) return "intro";
  if (CREDITS_WORD.test(name)) return "credits";
  return null;
}

const MIN_INTRO_MS = 5_000;
const MAX_INTRO_MS = 5 * 60_000;

/**
 * The intro and credits a file's chapters name, when they make sense: an intro of 5 seconds to
 * 5 minutes in the first half, credits in the second half. Chapters called "Chapter 3" say nothing.
 */
export function markersFromChapters(
  chapters: Chapter[],
  durationMs: number | null,
): ChapterMarkers {
  const sorted = [...chapters].sort((a, b) => a.startMs - b.startMs);
  const half = durationMs === null ? Infinity : durationMs / 2;
  let intro: ChapterMarkers["intro"] = null;
  let credits: ChapterMarkers["credits"] = null;
  for (const chapter of sorted) {
    if (chapter.title === null) continue;
    const kind = chapterKind(chapter.title);
    if (kind === "intro" && intro === null) {
      const length = chapter.endMs - chapter.startMs;
      if (length >= MIN_INTRO_MS && length <= MAX_INTRO_MS && chapter.startMs < half) {
        intro = { startMs: chapter.startMs, endMs: chapter.endMs };
      }
    } else if (kind === "credits" && credits === null) {
      if (durationMs === null || chapter.startMs >= half) credits = { startMs: chapter.startMs };
    }
  }
  return { intro, credits };
}
