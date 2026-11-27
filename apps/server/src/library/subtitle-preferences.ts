// SPDX-License-Identifier: MPL-2.0
/**
 * How a viewer wants subtitles (docs/api.md, Profiles). The apps choose the tracks from it when
 * a film starts; the player's menu still lets the viewer pick another for that time.
 */
export interface SubtitlePreferences {
  /** Languages in order of preference, as ISO 639 codes ("nl", "eng"). Empty: off. */
  languages: string[];
  /** Forced subtitles (only the lines for speech in another language) when there are some. */
  forced: boolean;
  size: SubtitleSize;
  /** A dark box behind the lines. */
  background: boolean;
}

export type SubtitleSize = "small" | "medium" | "large";

export const SUBTITLE_SIZES: readonly SubtitleSize[] = ["small", "medium", "large"];

/** Off, forced subtitles on: for every viewer, kids viewers too, until they choose. */
export const DEFAULT_SUBTITLES: Readonly<SubtitlePreferences> = Object.freeze({
  languages: [],
  forced: true,
  size: "medium",
  background: true,
});

const MAX_LANGUAGES = 8;
const LANGUAGE = /^[a-z]{2,3}$/;

/** How far subtitles may be moved against the picture, either way. */
export const MAX_SUBTITLE_OFFSET_MS = 10 * 60_000;

export class SubtitlePreferencesError extends Error {}

/** What is stored, with the defaults for what is not. */
export function readSubtitlePreferences(json: string | null): SubtitlePreferences {
  if (json === null) return { ...DEFAULT_SUBTITLES, languages: [] };
  try {
    return mergeSubtitlePreferences(DEFAULT_SUBTITLES, JSON.parse(json) as unknown);
  } catch {
    return { ...DEFAULT_SUBTITLES, languages: [] };
  }
}

/**
 * The preferences after a change. What is left out stays as it was, so an app that does not
 * know a field never wipes it. Throws on a value that is not allowed.
 */
export function mergeSubtitlePreferences(
  before: Readonly<SubtitlePreferences>,
  change: unknown,
): SubtitlePreferences {
  if (typeof change !== "object" || change === null || Array.isArray(change)) {
    throw new SubtitlePreferencesError(`"subtitles" must be an object.`);
  }
  const body = change as Record<string, unknown>;
  const next: SubtitlePreferences = { ...before, languages: [...before.languages] };
  if (body["languages"] !== undefined) {
    const languages = body["languages"];
    if (
      !Array.isArray(languages) ||
      languages.length > MAX_LANGUAGES ||
      !languages.every((code) => typeof code === "string" && LANGUAGE.test(code.toLowerCase()))
    ) {
      throw new SubtitlePreferencesError(
        `"subtitles.languages" must be a list of at most ${String(MAX_LANGUAGES)} language codes ("nl", "eng").`,
      );
    }
    next.languages = [...new Set((languages as string[]).map((code) => code.toLowerCase()))];
  }
  for (const key of ["forced", "background"] as const) {
    const value = body[key];
    if (value === undefined) continue;
    if (typeof value !== "boolean") {
      throw new SubtitlePreferencesError(`"subtitles.${key}" must be true or false.`);
    }
    next[key] = value;
  }
  if (body["size"] !== undefined) {
    const size = body["size"];
    if (typeof size !== "string" || !SUBTITLE_SIZES.includes(size as SubtitleSize)) {
      throw new SubtitlePreferencesError(
        `"subtitles.size" must be one of ${SUBTITLE_SIZES.join(", ")}.`,
      );
    }
    next.size = size as SubtitleSize;
  }
  return next;
}
