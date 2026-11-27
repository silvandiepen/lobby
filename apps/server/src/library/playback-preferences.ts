// SPDX-License-Identifier: MPL-2.0
/**
 * What happens when something ends, for one viewer (docs/api.md, Profiles; docs/playback.md,
 * "When something ends"). Kept per viewer, not per device: a TV that plays as a viewer goes by
 * that viewer's choice. The apps decide from it; the server only keeps it.
 */
export interface PlaybackPreferences {
  /** At the end of a film (and of a series' last episode): what goes with it, to pick from. */
  filmSuggestions: boolean;
  /** The first suggestion starts by itself, after the countdown. Off unless the viewer turns it on. */
  filmAutoplay: boolean;
  /** At the end of an episode the next one starts by itself, after the countdown. */
  episodeAutoplay: boolean;
  /** How long Up Next counts down. 0: no countdown, only the Play Now button. */
  countdownSeconds: CountdownSeconds;
  /** Up Next comes at the credits, when the server knows where they start; else at the end. */
  startAtCredits: boolean;
  /** Ask "Still watching?" after this many episodes in a row without a touch. 0: never. */
  stillWatchingEpisodes: StillWatchingEpisodes;
  /** Ask "Still watching?" after this many hours without a touch. 0: never. */
  stillWatchingHours: StillWatchingHours;
}

export type CountdownSeconds = 0 | 5 | 10 | 15;
export type StillWatchingEpisodes = 0 | 2 | 3 | 4 | 5;
export type StillWatchingHours = 0 | 1 | 2 | 3 | 4;

export const COUNTDOWN_SECONDS: readonly CountdownSeconds[] = [0, 5, 10, 15];
export const STILL_WATCHING_EPISODES: readonly StillWatchingEpisodes[] = [0, 2, 3, 4, 5];
export const STILL_WATCHING_HOURS: readonly StillWatchingHours[] = [0, 1, 2, 3, 4];

/** Every viewer's until they choose. */
export const DEFAULT_PLAYBACK: Readonly<PlaybackPreferences> = Object.freeze({
  filmSuggestions: true,
  filmAutoplay: false,
  episodeAutoplay: true,
  countdownSeconds: 10,
  startAtCredits: true,
  stillWatchingEpisodes: 3,
  stillWatchingHours: 0,
});

/** A kids viewer's: the same, but asked sooner whether anyone still watches. */
export const DEFAULT_KIDS_PLAYBACK: Readonly<PlaybackPreferences> = Object.freeze({
  ...DEFAULT_PLAYBACK,
  stillWatchingEpisodes: 2,
});

export class PlaybackPreferencesError extends Error {}

const FLAGS = ["filmSuggestions", "filmAutoplay", "episodeAutoplay", "startAtCredits"] as const;
const CHOICES = {
  countdownSeconds: COUNTDOWN_SECONDS,
  stillWatchingEpisodes: STILL_WATCHING_EPISODES,
  stillWatchingHours: STILL_WATCHING_HOURS,
} as const;

/** What the viewer chose themselves: only those keys are stored, the rest follows the defaults. */
export type ChosenPlayback = Partial<PlaybackPreferences>;

function readChosen(json: string | null): ChosenPlayback {
  if (json === null) return {};
  try {
    return changePlayback({}, JSON.parse(json) as unknown);
  } catch {
    return {};
  }
}

/**
 * The preferences a viewer plays by: what they chose, and for the rest the defaults of their
 * kind. A viewer who never chose follows the defaults also when they become a kids viewer.
 */
export function readPlaybackPreferences(json: string | null, isKids: boolean): PlaybackPreferences {
  return { ...(isKids ? DEFAULT_KIDS_PLAYBACK : DEFAULT_PLAYBACK), ...readChosen(json) };
}

/**
 * What is stored after a change: what was chosen before with the change on top. What is left out
 * stays as it was, so an app that does not know a field never wipes it. Throws on a value that is
 * not allowed.
 */
export function changePlayback(before: ChosenPlayback, change: unknown): ChosenPlayback {
  if (typeof change !== "object" || change === null || Array.isArray(change)) {
    throw new PlaybackPreferencesError(`"playback" must be an object.`);
  }
  const body = change as Record<string, unknown>;
  const next: ChosenPlayback = { ...before };
  for (const key of FLAGS) {
    const value = body[key];
    if (value === undefined) continue;
    if (typeof value !== "boolean") {
      throw new PlaybackPreferencesError(`"playback.${key}" must be true or false.`);
    }
    next[key] = value;
  }
  for (const [key, allowed] of Object.entries(CHOICES) as [
    keyof typeof CHOICES,
    readonly number[],
  ][]) {
    const value = body[key];
    if (value === undefined) continue;
    if (typeof value !== "number" || !allowed.includes(value)) {
      throw new PlaybackPreferencesError(`"playback.${key}" must be one of ${allowed.join(", ")}.`);
    }
    (next as Record<string, number>)[key] = value;
  }
  return next;
}

/** Reads a change from a request onto what was stored, as JSON to store. */
export function storePlayback(before: string | null, change: unknown): string {
  return JSON.stringify(changePlayback(readChosen(before), change));
}
