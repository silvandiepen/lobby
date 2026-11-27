// SPDX-License-Identifier: MPL-2.0
/**
 * What a viewer wants done at an intro and at the credits (docs/api.md, Profiles). The apps act on
 * it; the server keeps it with the viewer, so it is the same on every device.
 */
export interface SkipPreferences {
  /** "show": a Skip Intro button during the intro; "skip": jump over it; "off": nothing. */
  intro: "show" | "skip" | "off";
  /** "show": Next Episode from where the credits start; "off": nothing until the end. */
  credits: "show" | "off";
}

export const INTRO_CHOICES: readonly SkipPreferences["intro"][] = ["show", "skip", "off"];
export const CREDITS_CHOICES: readonly SkipPreferences["credits"][] = ["show", "off"];

/** For every viewer, kids too, until a grown-up chooses otherwise. */
export const DEFAULT_SKIPPING: Readonly<SkipPreferences> = Object.freeze({
  intro: "show",
  credits: "show",
});

export class SkipPreferencesError extends Error {}

export function readSkipPreferences(json: string | null): SkipPreferences {
  if (json === null) return { ...DEFAULT_SKIPPING };
  try {
    return mergeSkipPreferences(DEFAULT_SKIPPING, JSON.parse(json) as unknown);
  } catch {
    return { ...DEFAULT_SKIPPING };
  }
}

/** The preferences after a change; what is left out stays. Throws on a value that is not allowed. */
export function mergeSkipPreferences(
  before: Readonly<SkipPreferences>,
  change: unknown,
): SkipPreferences {
  if (typeof change !== "object" || change === null || Array.isArray(change)) {
    throw new SkipPreferencesError(`"skipping" must be an object.`);
  }
  const body = change as Record<string, unknown>;
  const next: SkipPreferences = { ...before };
  const intro = body["intro"];
  if (intro !== undefined) {
    if (typeof intro !== "string" || !INTRO_CHOICES.includes(intro as SkipPreferences["intro"])) {
      throw new SkipPreferencesError(
        `"skipping.intro" must be one of ${INTRO_CHOICES.join(", ")}.`,
      );
    }
    next.intro = intro as SkipPreferences["intro"];
  }
  const credits = body["credits"];
  if (credits !== undefined) {
    if (
      typeof credits !== "string" ||
      !CREDITS_CHOICES.includes(credits as SkipPreferences["credits"])
    ) {
      throw new SkipPreferencesError(
        `"skipping.credits" must be one of ${CREDITS_CHOICES.join(", ")}.`,
      );
    }
    next.credits = credits as SkipPreferences["credits"];
  }
  return next;
}
