// SPDX-License-Identifier: MPL-2.0
import type { Database } from "./db/database.ts";
import type { KidsView } from "./kids/limits.ts";

const DAY_MS = 86_400_000;
/** How far back counts, and how long it is kept. */
export const PLAYS_DAYS = 180;
const ENOUGH_MS = 10 * 60_000;
const ENOUGH_PART = 0.25;
/** Films play at up to twice the speed, and positions arrive some seconds apart. */
const FASTEST = 2;
const SLACK_MS = 15_000;

export interface Place {
  positionMs: number;
  durationMs: number | null;
  completed: boolean;
  updatedAt: number;
}

export interface Popular {
  days: number;
  /** Whose watching counts. */
  viewers: "all" | "kids";
  titles: { itemId: string; plays: number }[];
}

function dayOf(at: number): string {
  const date = new Date(at);
  const two = (value: number): string => String(value).padStart(2, "0");
  return `${String(date.getFullYear())}-${two(date.getMonth() + 1)}-${two(date.getDate())}`;
}

/** How much was watched between two places, as far as they tell. */
export function watched(before: Place | null, now: Place): number {
  // The first that is heard of it, perhaps after a flight: all of it at once.
  if (!before) return now.positionMs;
  const most = Math.max(0, now.updatedAt - before.updatedAt) * FASTEST + SLACK_MS;
  const moved = now.positionMs - before.positionMs;
  // From the start again after the end. Any other step back is looking for a scene.
  const forward = moved < 0 && before.completed && !now.completed ? now.positionMs : moved;
  return Math.min(Math.max(0, forward), most);
}

/**
 * What the household watches: per viewer, title and day how much of it, worked out from the
 * places in films and episodes. It leaves the server only as counts of all viewers together.
 */
export class PlayLog {
  private readonly db: Database;
  private readonly now: () => number;
  private prunedOn = "";

  constructor(db: Database, now: () => number = Date.now) {
    this.db = db;
    this.now = now;
  }

  private get oldest(): string {
    return dayOf(this.now() - PLAYS_DAYS * DAY_MS);
  }

  /** Call inside the transaction that saves the new place. */
  note(profileId: string, itemId: string, before: Place | null, now: Place): void {
    const amount = watched(before, now);
    const day = dayOf(now.updatedAt);
    this.prune();
    if (amount <= 0 || day < this.oldest) return;
    const item = this.db.get(
      "select 1 as x from item where id = ? and kind in ('movie', 'episode', 'personal')",
      [itemId],
    );
    if (!item) return;
    const enough =
      now.durationMs !== null && now.durationMs > 0
        ? Math.min(ENOUGH_MS, Math.max(1, now.durationMs * ENOUGH_PART))
        : ENOUGH_MS;
    this.db.run(
      `insert into play (profile_id, item_id, day, watched_ms, counted)
       values (?1, ?2, ?3, ?4, ?4 >= ?5)
       on conflict (profile_id, item_id, day) do update set
         watched_ms = watched_ms + ?4,
         counted = max(counted, watched_ms + ?4 >= ?5)`,
      [profileId, itemId, day, Math.round(amount), enough],
    );
  }

  /** Once a day: nobody's watching is kept for longer than it counts. */
  private prune(): void {
    const { oldest } = this;
    if (this.prunedOn === oldest) return;
    this.db.run("delete from play where day < ?", [oldest]);
    this.prunedOn = oldest;
  }

  /**
   * The titles that were watched, most first. A viewer counts once a day for a film or a whole
   * series. With a kids viewer's view only what kids viewers watched, of what that viewer may see.
   *
   * @param householdId only what this household watched: nobody sees what another one does
   */
  popular(view: KidsView | null, kidsOnly = false, householdId: string | null = null): Popular {
    const kids = view?.kind === "kids" || kidsOnly;
    const rows = this.db.all<{ title: string; item: string; profile: string; day: string }>(
      `select coalesce(above.parent_id, item.parent_id, item.id) as title, item.id as item,
         play.profile_id as profile, play.day
       from play
       join item on item.id = play.item_id
       join profile on profile.id = play.profile_id and profile.deleted_at is null
       left join item as above on above.id = item.parent_id
       where play.counted = 1 and play.day >= ?
         and (? = 0 or profile.kids_json is not null)
         and (? is null or profile.household_id = ?)`,
      [this.oldest, kids ? 1 : 0, householdId, householdId],
    );
    const titles = new Map<string, { plays: Set<string>; last: string }>();
    for (const row of rows) {
      if (view && !(view.items.has(row.item) && view.items.has(row.title))) continue;
      const known = titles.get(row.title) ?? { plays: new Set<string>(), last: "" };
      known.plays.add(`${row.profile} ${row.day}`);
      if (row.day > known.last) known.last = row.day;
      titles.set(row.title, known);
    }
    return {
      days: PLAYS_DAYS,
      viewers: kids ? "kids" : "all",
      titles: [...titles]
        .sort(
          ([idA, a], [idB, b]) =>
            b.plays.size - a.plays.size ||
            (a.last < b.last ? 1 : a.last > b.last ? -1 : idA < idB ? -1 : 1),
        )
        .map(([itemId, { plays }]) => ({ itemId, plays: plays.size })),
    };
  }
}
