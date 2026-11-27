// SPDX-License-Identifier: MPL-2.0
import type { SQLInputValue } from "node:sqlite";
import type { Database } from "../db/database.ts";
import type { KidsView } from "../kids/limits.ts";
import { DELIVERIES, ROADS, type Delivery, type Road } from "./recorder.ts";
import { addDays, Clock, daysBetween, monthsBetween } from "./time.ts";

export const RANGES = ["week", "month", "year", "all"] as const;
export type RangeName = (typeof RANGES)[number];

const RANGE_DAYS: Readonly<Record<Exclude<RangeName, "all">, number>> = {
  week: 7,
  month: 30,
  year: 365,
};
const HOUR_MS = 3_600_000;
const TOP = 10;
const HISTORY = 50;

export interface Range {
  name: RangeName;
  timeZone: string;
  /** The first and the last local day it covers, both included. */
  firstDay: string;
  lastDay: string;
  from: number;
  to: number;
}

/** A trailing range that ends now, in whole local days. `all` reaches back as far as is kept. */
export function rangeOf(name: RangeName, clock: Clock, now: number, oldest: number): Range {
  const lastDay = clock.at(now).day;
  const firstDay =
    name === "all" ? clock.at(oldest).day : addDays(lastDay, -(RANGE_DAYS[name] - 1));
  return {
    name,
    timeZone: clock.timeZone,
    firstDay,
    lastDay,
    from: Math.max(clock.startOf(firstDay), name === "all" ? oldest : 0),
    to: now,
  };
}

interface SessionRow {
  id: string;
  profile_id: string;
  household_id: string;
  device_id: string | null;
  item_id: string;
  title_id: string;
  started_at: number;
  ended_at: number;
  timed: number;
  watched_ms: number;
  completed: number;
  road: Road;
  delivery: Delivery;
  play_on_from: string | null;
}

const SESSION_COLUMNS = `id, profile_id, household_id, device_id, item_id, title_id, started_at,
  ended_at, timed, watched_ms, completed, road, delivery, play_on_from`;

interface ItemRow {
  id: string;
  kind: string;
  title: string;
  parent_id: string | null;
  season_number: number | null;
  episode_number: number | null;
  year: number | null;
}

/** Sums in a map, created on first use. */
function add<K>(map: Map<K, number>, key: K, amount: number): void {
  map.set(key, (map.get(key) ?? 0) + amount);
}

function emptyHeatmap(): number[][] {
  return Array.from({ length: 7 }, () => Array.from({ length: 24 }, () => 0));
}

function record<K extends string>(keys: readonly K[]): Record<K, number> {
  return Object.fromEntries(keys.map((key) => [key, 0])) as Record<K, number>;
}

/**
 * Hands out the watching of a sitting hour by hour, as it happened. A sitting whose hour is not
 * known (from before) goes to its day only.
 */
function spread(
  clock: Clock,
  row: { started_at: number; watched_ms: number; timed: number },
  each: (local: ReturnType<Clock["at"]>, amount: number, timed: boolean) => void,
): void {
  if (row.timed !== 1) {
    each(clock.at(row.started_at), row.watched_ms, false);
    return;
  }
  let at = row.started_at;
  let left = row.watched_ms;
  for (let i = 0; left > 0 && i < 72; i += 1) {
    const hourEnd = (Math.floor(at / HOUR_MS) + 1) * HOUR_MS;
    const part = Math.min(left, hourEnd - at);
    each(clock.at(at), part, true);
    left -= part;
    at = hourEnd;
  }
  if (left > 0) each(clock.at(at), left, true);
}

/** Part of the day, for "when": mornings, afternoons, evenings and nights. */
function partOfDay(hour: number): "mornings" | "afternoons" | "evenings" | "nights" {
  if (hour >= 6 && hour < 12) return "mornings";
  if (hour >= 12 && hour < 18) return "afternoons";
  if (hour >= 18 && hour < 23) return "evenings";
  return "nights";
}

function inList(ids: Iterable<string>): string {
  return JSON.stringify([...ids]);
}

interface Named {
  id: string;
  name: string;
}

/** Statistics are read from these, with the names that go with them. */
export class StatsReader {
  private readonly db: Database;

  constructor(db: Database) {
    this.db = db;
  }

  private sessions(where: string, params: SQLInputValue[]): SessionRow[] {
    return this.db.all<SessionRow>(
      `select ${SESSION_COLUMNS} from watch_session where ${where} order by started_at`,
      params,
    );
  }

  private items(ids: Iterable<string>): Map<string, ItemRow> {
    const rows = this.db.all<ItemRow>(
      `select item.id, item.kind, item.title, item.parent_id, item.season_number,
         item.episode_number, item.year
       from json_each(?) as wanted join item on item.id = wanted.value`,
      [inList(new Set(ids))],
    );
    return new Map(rows.map((row) => [row.id, row]));
  }

  private shows(episodeIds: Iterable<string>): Map<string, string> {
    // An episode's series: above its season, or right above it.
    const rows = this.db.all<{ id: string; show: string }>(
      `select item.id, coalesce(above.parent_id, item.parent_id) as show
       from json_each(?) as wanted join item on item.id = wanted.value
       left join item as above on above.id = item.parent_id and above.kind = 'season'
       where item.kind = 'episode'`,
      [inList(new Set(episodeIds))],
    );
    return new Map(rows.map((row) => [row.id, row.show]));
  }

  private weigh(
    sql: string,
    ids: Map<string, number>,
  ): { id: string; name: string; watchedMs: number }[] {
    const totals = new Map<string, { name: string; watchedMs: number }>();
    for (const row of this.db.all<{ owner: string; id: string; name: string }>(sql, [
      inList(ids.keys()),
    ])) {
      const known = totals.get(row.id) ?? { name: row.name, watchedMs: 0 };
      known.watchedMs += ids.get(row.owner) ?? 0;
      totals.set(row.id, known);
    }
    return [...totals]
      .map(([id, one]) => ({ id, ...one }))
      .sort((a, b) => b.watchedMs - a.watchedMs || (a.name < b.name ? -1 : 1))
      .slice(0, TOP);
  }

  private genres(titles: Map<string, number>): { id: string; name: string; watchedMs: number }[] {
    return this.weigh(
      `select item_genre.item_id as owner, cast(genre.id as text) as id, genre.name
       from json_each(?) as wanted
       join item_genre on item_genre.item_id = wanted.value
       join genre on genre.id = item_genre.genre_id`,
      titles,
    );
  }

  private studios(titles: Map<string, number>): { id: string; name: string; watchedMs: number }[] {
    return this.weigh(
      `select item_studio.item_id as owner, studio.id, studio.name
       from json_each(?) as wanted
       join item_studio on item_studio.item_id = wanted.value
       join studio on studio.id = item_studio.studio_id`,
      titles,
    );
  }

  /** The categories of the folders the files are in. */
  private categories(
    items: Map<string, number>,
  ): { id: string; name: string; watchedMs: number }[] {
    return this.weigh(
      `select distinct item_asset.item_id as owner, category.id, category.name
       from json_each(?) as wanted
       join item_asset on item_asset.item_id = wanted.value and item_asset.role = 'main'
       join asset on asset.id = item_asset.asset_id
       join source on source.id = asset.source_id
       join category on category.id = source.category_id`,
      items,
    );
  }

  private names(
    table: "profile" | "device",
    ids: Iterable<string>,
  ): Map<string, Named & Record<string, unknown>> {
    const columns =
      table === "profile"
        ? `profile.id, profile.name, profile.color, profile.avatar, profile.household_id,
           profile.kids_json is not null as kids`
        : "device.id, device.name, device.platform, device.household_id";
    const rows = this.db.all<Named & Record<string, unknown>>(
      `select ${columns} from json_each(?) as wanted join ${table} on ${table}.id = wanted.value`,
      [inList(new Set(ids))],
    );
    return new Map(rows.map((row) => [row.id, row]));
  }

  /** "S2 E5" and the series' name for an episode; the title and year for anything else. */
  private describe(
    item: ItemRow | undefined,
    title: ItemRow | undefined,
  ): { title: string; subtitle: string | null } {
    if (!item) return { title: title?.title ?? "Removed title", subtitle: null };
    if (item.kind === "episode") {
      const label =
        item.season_number !== null && item.episode_number !== null
          ? `S${String(item.season_number)} E${String(item.episode_number)}`
          : null;
      return {
        title: title?.title ?? item.title,
        subtitle:
          [label, item.title].filter((one) => one !== null && one !== "").join(" · ") || null,
      };
    }
    return { title: item.title, subtitle: item.year === null ? null : String(item.year) };
  }

  // ---- One viewer ----

  viewer(
    profileId: string,
    range: Range,
    clock: Clock,
    options: { view: KidsView | null; oldest: number },
  ): Record<string, unknown> {
    const { view } = options;
    const allowed = (row: { item_id: string; title_id: string }): boolean =>
      !view || (view.items.has(row.item_id) && view.items.has(row.title_id));
    const rows = this.sessions("profile_id = ? and started_at >= ? and started_at <= ?", [
      profileId,
      range.from,
      range.to,
    ]).filter(allowed);

    const days = new Map<string, number>();
    const months = new Map<string, number>();
    const heatmap = emptyHeatmap();
    const when = { mornings: 0, afternoons: 0, evenings: 0, nights: 0, weekdays: 0, weekends: 0 };
    const titles = new Map<string, number>();
    const titleSessions = new Map<string, number>();
    const titleLast = new Map<string, number>();
    const itemsWatched = new Map<string, number>();
    const devices = new Map<string, number>();
    const roads = record(ROADS);
    const deliveries = record(DELIVERIES);
    let watchedMs = 0;
    let playOn = 0;
    for (const row of rows) {
      watchedMs += row.watched_ms;
      add(titles, row.title_id, row.watched_ms);
      add(titleSessions, row.title_id, 1);
      titleLast.set(row.title_id, Math.max(titleLast.get(row.title_id) ?? 0, row.ended_at));
      add(itemsWatched, row.item_id, row.watched_ms);
      if (row.device_id !== null) add(devices, row.device_id, row.watched_ms);
      roads[row.road] += row.watched_ms;
      deliveries[row.delivery] += row.watched_ms;
      if (row.play_on_from !== null) playOn += 1;
      spread(clock, row, (local, amount, timed) => {
        add(days, local.day, amount);
        add(months, local.month, amount);
        if (!timed) return;
        const row7 = heatmap[local.weekday];
        if (row7) row7[local.hour] = (row7[local.hour] ?? 0) + amount;
        when[partOfDay(local.hour)] += amount;
        if (local.weekday >= 5) when.weekends += amount;
        else when.weekdays += amount;
      });
    }

    // Listening, from the music library's own history.
    const listening = this.db.all<{ played_at: number; played_ms: number; track_id: string }>(
      `select played_at, played_ms, track_id from music_play
       where profile_id = ? and played_at >= ? and played_at <= ?`,
      [profileId, range.from, range.to],
    );
    const listenedDays = new Map<string, number>();
    const listenedMonths = new Map<string, number>();
    const tracks = new Map<string, { ms: number; plays: number }>();
    let listenedMs = 0;
    for (const play of listening) {
      listenedMs += play.played_ms;
      const local = clock.at(play.played_at);
      add(listenedDays, local.day, play.played_ms);
      add(listenedMonths, local.month, play.played_ms);
      const known = tracks.get(play.track_id) ?? { ms: 0, plays: 0 };
      known.ms += play.played_ms;
      known.plays += 1;
      tracks.set(play.track_id, known);
    }
    const albums = new Map<
      string,
      { title: string; artist: string; coverId: string | null; listenedMs: number; plays: number }
    >();
    const artists = new Map<string, number>();
    for (const row of this.db.all<{
      track: string;
      album: string | null;
      title: string | null;
      artist: string | null;
      cover: string | null;
      track_artist: string;
    }>(
      `select music_track.id as track, music_album.id as album, music_album.title,
         music_album.artist_credit as artist, music_album.cover_id as cover,
         music_track.artist_credit as track_artist
       from json_each(?) as wanted join music_track on music_track.id = wanted.value
       left join music_album on music_album.id = music_track.album_id`,
      [inList(tracks.keys())],
    )) {
      const played = tracks.get(row.track);
      if (!played) continue;
      add(artists, row.artist ?? row.track_artist, played.ms);
      if (row.album === null) continue;
      const known = albums.get(row.album) ?? {
        title: row.title ?? "",
        artist: row.artist ?? "",
        coverId: row.cover,
        listenedMs: 0,
        plays: 0,
      };
      known.listenedMs += played.ms;
      known.plays += played.plays;
      albums.set(row.album, known);
    }

    // What the titles are.
    const items = this.items([...titles.keys(), ...itemsWatched.keys()]);
    const finished = new Set(rows.filter((row) => row.completed === 1).map((row) => row.item_id));
    let filmsFinished = 0;
    let episodesFinished = 0;
    for (const id of finished) {
      const kind = items.get(id)?.kind;
      if (kind === "movie" || kind === "personal") filmsFinished += 1;
      if (kind === "episode") episodesFinished += 1;
    }
    const topTitles = [...titles]
      .sort(([idA, a], [idB, b]) => b - a || (idA < idB ? -1 : 1))
      .slice(0, TOP)
      .map(([id, ms]) => ({
        itemId: id,
        title: items.get(id)?.title ?? "Removed title",
        kind: items.get(id)?.kind ?? null,
        watchedMs: ms,
        sessions: titleSessions.get(id) ?? 0,
        lastAt: titleLast.get(id) ?? null,
      }));

    // How far along each series watched in this range is.
    const showIds = [...titles.keys()].filter((id) => items.get(id)?.kind === "show");
    const series = showIds.length === 0 ? [] : this.seriesProgress(profileId, showIds, rows, view);

    // Streaks, over everything that is kept.
    const streakDays = new Set<string>();
    for (const row of this.db.all<{ started_at: number; item_id: string; title_id: string }>(
      "select started_at, item_id, title_id from watch_session where profile_id = ? and started_at >= ?",
      [profileId, options.oldest],
    )) {
      if (allowed(row)) streakDays.add(clock.at(row.started_at).day);
    }
    const streak = streaks(streakDays, range.lastDay);

    const dayList = daysBetween(range.firstDay, range.lastDay).map((day) => ({
      day,
      watchedMs: days.get(day) ?? 0,
      listenedMs: listenedDays.get(day) ?? 0,
    }));
    const monthList = monthsBetween(range.firstDay.slice(0, 7), range.lastDay.slice(0, 7)).map(
      (month) => ({
        month,
        watchedMs: months.get(month) ?? 0,
        listenedMs: listenedMonths.get(month) ?? 0,
      }),
    );

    const result: Record<string, unknown> = {
      range,
      totals: {
        watchedMs,
        sessions: rows.length,
        titles: titles.size,
        filmsFinished,
        episodesFinished,
        listenedMs,
        tracksPlayed: listening.length,
        activeDays: new Set(dayList.filter((one) => one.watchedMs > 0).map((one) => one.day)).size,
      },
      days: dayList,
      months: monthList,
      heatmap,
      when,
      topTitles,
      series,
      genres: this.genres(titles),
      studios: this.studios(titles),
      categories: this.categories(itemsWatched),
      streak,
      music: {
        listenedMs,
        plays: listening.length,
        topAlbums: [...albums]
          .sort(([, a], [, b]) => b.listenedMs - a.listenedMs)
          .slice(0, TOP)
          .map(([id, one]) => ({ id, ...one })),
        topArtists: [...artists]
          .filter(([name]) => name !== "")
          .sort(([, a], [, b]) => b - a)
          .slice(0, TOP)
          .map(([name, ms]) => ({ name, listenedMs: ms })),
      },
    };
    const deviceNames = this.names("device", devices.keys());
    const showsOf = this.shows([...itemsWatched.keys()]);
    const historyRows = rows.slice(-HISTORY).reverse();
    const fromNames = this.names(
      "device",
      historyRows.flatMap((row) => (row.play_on_from === null ? [] : [row.play_on_from])),
    );
    return {
      ...result,
      playOnSessions: playOn,
      roads,
      deliveries,
      devices: [...devices]
        .sort(([, a], [, b]) => b - a)
        .map(([id, ms]) => ({
          id,
          name: deviceNames.get(id)?.name ?? "Removed device",
          platform: deviceNames.get(id)?.["platform"] ?? null,
          watchedMs: ms,
        })),
      history: historyRows.map((row) => {
        const item = items.get(row.item_id);
        const title = items.get(showsOf.get(row.item_id) ?? row.title_id);
        return {
          id: row.id,
          itemId: row.item_id,
          titleId: row.title_id,
          ...this.describe(item, title),
          startedAt: row.started_at,
          endedAt: row.ended_at,
          timed: row.timed === 1,
          watchedMs: row.watched_ms,
          completed: row.completed === 1,
          device: row.device_id === null ? null : (deviceNames.get(row.device_id)?.name ?? null),
          road: row.road,
          delivery: row.delivery,
          playOnFrom:
            row.play_on_from === null ? null : (fromNames.get(row.play_on_from)?.name ?? null),
        };
      }),
    };
  }

  private seriesProgress(
    profileId: string,
    showIds: string[],
    rows: SessionRow[],
    view: KidsView | null,
  ): Record<string, unknown>[] {
    const episodes = this.db.all<{
      show: string;
      id: string;
      completed: number | null;
      title: string;
      show_title: string;
      season_number: number | null;
      episode_number: number | null;
    }>(
      `select show.id as show, episode.id, progress.completed, episode.title,
         show.title as show_title, episode.season_number, episode.episode_number
       from json_each(?) as wanted
       join item as show on show.id = wanted.value
       join item as season on season.parent_id = show.id and season.kind = 'season'
       join item as episode on episode.parent_id = season.id and episode.kind = 'episode'
       left join progress on progress.item_id = episode.id and progress.profile_id = ?
       union all
       select show.id as show, episode.id, progress.completed, episode.title,
         show.title as show_title, episode.season_number, episode.episode_number
       from json_each(?) as wanted
       join item as show on show.id = wanted.value
       join item as episode on episode.parent_id = show.id and episode.kind = 'episode'
       left join progress on progress.item_id = episode.id and progress.profile_id = ?`,
      [inList(showIds), profileId, inList(showIds), profileId],
    );
    const shows = new Map<
      string,
      { title: string; total: number; watched: number; episodes: Map<string, string> }
    >();
    for (const one of episodes) {
      if (view && !view.items.has(one.id)) continue;
      const known = shows.get(one.show) ?? {
        title: one.show_title,
        total: 0,
        watched: 0,
        episodes: new Map<string, string>(),
      };
      known.total += 1;
      if (one.completed === 1) known.watched += 1;
      known.episodes.set(
        one.id,
        one.season_number !== null && one.episode_number !== null
          ? `S${String(one.season_number)} E${String(one.episode_number)}`
          : one.title,
      );
      shows.set(one.show, known);
    }
    const last = new Map<string, SessionRow>();
    for (const row of rows) if (shows.has(row.title_id)) last.set(row.title_id, row);
    return [...last.values()]
      .reverse()
      .slice(0, TOP)
      .map((row) => {
        const show = shows.get(row.title_id);
        return {
          itemId: row.title_id,
          title: show?.title ?? "",
          episodesWatched: show?.watched ?? 0,
          episodes: show?.total ?? 0,
          lastEpisodeId: row.item_id,
          lastEpisode: show?.episodes.get(row.item_id) ?? null,
          lastAt: row.ended_at,
        };
      });
  }

  // ---- The server ----

  server(
    range: Range,
    clock: Clock,
    options: {
      /** Opened by the owner: this household's viewers and devices. Null: the owner's own. */
      householdId: string | null;
      ownerHouseholdId: string;
      storage: Record<string, number | null>;
      /** Only this household's watching, listening and bytes: its overview. */
      only?: string;
      /** What the asking device may see of the library, for a household with a part of it. */
      view?: KidsView | null;
    },
  ): Record<string, unknown> {
    const detail = options.householdId ?? options.ownerHouseholdId;
    const { only, view } = options;
    const rows = (
      only === undefined
        ? this.sessions("started_at >= ? and started_at <= ?", [range.from, range.to])
        : this.sessions("household_id = ? and started_at >= ? and started_at <= ?", [
            only,
            range.from,
            range.to,
          ])
    ).filter((row) => !view || (view.items.has(row.item_id) && view.items.has(row.title_id)));

    const days = new Map<string, { watchedMs: number; sessions: number; viewers: Set<string> }>();
    const heatmap = emptyHeatmap();
    const hours = Array.from({ length: 24 }, () => 0);
    const roads = record(ROADS);
    const deliveries = record(DELIVERIES);
    const households = new Map<
      string,
      { watchedMs: number; sessions: number; viewers: Set<string>; devices: Set<string> }
    >();
    const titles = new Map<string, { watchedMs: number; sessions: number; viewers: Set<string> }>();
    const viewers = new Map<string, { watchedMs: number; sessions: number; lastAt: number }>();
    const devices = new Map<string, { watchedMs: number; sessions: number }>();
    const targets = new Map<string, number>();
    const allViewers = new Set<string>();
    const allDevices = new Set<string>();
    let watchedMs = 0;
    let playOnSessions = 0;
    let playOnMs = 0;
    for (const row of rows) {
      watchedMs += row.watched_ms;
      allViewers.add(row.profile_id);
      if (row.device_id !== null) allDevices.add(row.device_id);
      roads[row.road] += row.watched_ms;
      deliveries[row.delivery] += row.watched_ms;
      const household = households.get(row.household_id) ?? {
        watchedMs: 0,
        sessions: 0,
        viewers: new Set<string>(),
        devices: new Set<string>(),
      };
      household.watchedMs += row.watched_ms;
      household.sessions += 1;
      household.viewers.add(row.profile_id);
      if (row.device_id !== null) household.devices.add(row.device_id);
      households.set(row.household_id, household);
      const startDay = clock.at(row.started_at).day;
      const day = days.get(startDay) ?? { watchedMs: 0, sessions: 0, viewers: new Set<string>() };
      day.sessions += 1;
      day.viewers.add(row.profile_id);
      days.set(startDay, day);
      spread(clock, row, (local, amount, timed) => {
        const one = days.get(local.day) ?? {
          watchedMs: 0,
          sessions: 0,
          viewers: new Set<string>(),
        };
        one.watchedMs += amount;
        days.set(local.day, one);
        if (!timed) return;
        const row7 = heatmap[local.weekday];
        if (row7) row7[local.hour] = (row7[local.hour] ?? 0) + amount;
        hours[local.hour] = (hours[local.hour] ?? 0) + amount;
      });
      // What other households watch is theirs: only their totals, unless the owner opens one.
      if (row.household_id !== detail) continue;
      const title = titles.get(row.title_id) ?? {
        watchedMs: 0,
        sessions: 0,
        viewers: new Set<string>(),
      };
      title.watchedMs += row.watched_ms;
      title.sessions += 1;
      title.viewers.add(row.profile_id);
      titles.set(row.title_id, title);
      const viewer = viewers.get(row.profile_id) ?? { watchedMs: 0, sessions: 0, lastAt: 0 };
      viewer.watchedMs += row.watched_ms;
      viewer.sessions += 1;
      viewer.lastAt = Math.max(viewer.lastAt, row.ended_at);
      viewers.set(row.profile_id, viewer);
      if (row.device_id !== null) {
        const device = devices.get(row.device_id) ?? { watchedMs: 0, sessions: 0 };
        device.watchedMs += row.watched_ms;
        device.sessions += 1;
        devices.set(row.device_id, device);
      }
      if (row.play_on_from !== null) {
        playOnSessions += 1;
        playOnMs += row.watched_ms;
        if (row.device_id !== null) add(targets, row.device_id, 1);
      }
    }

    // Bytes sent, per road: home, or away by one of the roads.
    const traffic = this.db.all<{ hour: number; household_id: string; road: Road; bytes: number }>(
      "select hour, household_id, road, bytes from stats_traffic where hour >= ? and hour <= ?",
      [Math.floor(range.from / HOUR_MS), Math.floor(range.to / HOUR_MS)],
    );
    const sent = record(ROADS);
    const sentDays = new Map<string, { homeBytes: number; awayBytes: number }>();
    const householdBytes = new Map<string, number>();
    for (const row of traffic) {
      if (only !== undefined && row.household_id !== only) continue;
      sent[row.road] += row.bytes;
      add(householdBytes, row.household_id, row.bytes);
      const local = clock.at(row.hour * HOUR_MS);
      const day = sentDays.get(local.day) ?? { homeBytes: 0, awayBytes: 0 };
      if (row.road === "home") day.homeBytes += row.bytes;
      else day.awayBytes += row.bytes;
      sentDays.set(local.day, day);
    }

    const prepared = this.db.get<{
      count: number;
      converted: number;
      background: number;
      time: number;
      bytes: number;
    }>(
      `select count(*) as count, coalesce(sum(converted), 0) as converted,
         coalesce(sum(background), 0) as background, coalesce(sum(elapsed_ms), 0) as time,
         coalesce(sum(bytes), 0) as bytes
       from stats_event where kind = 'prepared' and at >= ? and at <= ?`,
      [range.from, range.to],
    );
    const converted = this.db.get<{ count: number; time: number; saved: number }>(
      `select count(*) as count, coalesce(sum(elapsed_ms), 0) as time,
         coalesce(sum(saved_bytes), 0) as saved
       from stats_event where kind = 'converted' and at >= ? and at <= ?`,
      [range.from, range.to],
    );
    const conversionJobs = this.db.get<{ failed: number; waiting: number }>(
      `select coalesce(sum(state = 'failed' and updated_at >= ?), 0) as failed,
         coalesce(sum(state in ('queued', 'claimed', 'converting', 'uploaded', 'verifying')), 0)
           as waiting
       from conversion_job`,
      [range.from],
    );
    // Space the replacements saved over all time, less those that were undone.
    const savedInAll = this.db.get<{ saved: number }>(
      `select coalesce(sum(original_size - new_size), 0) as saved from conversion_replacement
       where state != 'undone'`,
    );

    // The library, by the month titles came in. Films, and episodes for series.
    const growth = this.db.all<{ added_at: number; kind: string }>(
      `select added_at, kind from item where kind in ('movie', 'episode', 'personal')
         and added_at >= ? and added_at <= ?`,
      [range.from, range.to],
    );
    const growthMonths = new Map<string, { films: number; episodes: number }>();
    for (const row of growth) {
      const month = clock.at(row.added_at).month;
      const known = growthMonths.get(month) ?? { films: 0, episodes: 0 };
      if (row.kind === "episode") known.episodes += 1;
      else known.films += 1;
      growthMonths.set(month, known);
    }
    const library = this.db.get<{ films: number; shows: number; episodes: number }>(
      `select coalesce(sum(kind in ('movie', 'personal')), 0) as films,
         coalesce(sum(kind = 'show'), 0) as shows, coalesce(sum(kind = 'episode'), 0) as episodes
       from item`,
    );
    const listening = this.db.get<{ ms: number; plays: number }>(
      `select coalesce(sum(played_ms), 0) as ms, count(*) as plays from music_play
       where played_at >= ? and played_at <= ?
         and (? is null or profile_id in (select id from profile where household_id = ?))`,
      [range.from, range.to, only ?? null, only ?? null],
    );

    const topTitleRows = [...titles]
      .sort(
        ([idA, a], [idB, b]) =>
          b.viewers.size - a.viewers.size || b.watchedMs - a.watchedMs || (idA < idB ? -1 : 1),
      )
      .slice(0, TOP);
    const items = this.items(topTitleRows.map(([id]) => id));
    const profileNames = this.names("profile", viewers.keys());
    const deviceNames = this.names("device", [...devices.keys(), ...targets.keys()]);
    const householdNames = new Map(
      this.db
        .all<{ id: string; name: string; owner: number }>(
          "select id, name, owner from household where removed_at is null or id in (select value from json_each(?))",
          [inList(households.keys())],
        )
        .map((row) => [row.id, row]),
    );

    return {
      range,
      household:
        options.householdId === null
          ? null
          : {
              id: options.householdId,
              name: householdNames.get(options.householdId)?.name ?? "",
            },
      totals: {
        watchedMs,
        sessions: rows.length,
        viewers: allViewers.size,
        devices: allDevices.size,
        listenedMs: listening?.ms ?? 0,
        tracksPlayed: listening?.plays ?? 0,
      },
      days: daysBetween(range.firstDay, range.lastDay).map((day) => ({
        day,
        watchedMs: days.get(day)?.watchedMs ?? 0,
        sessions: days.get(day)?.sessions ?? 0,
        viewers: days.get(day)?.viewers.size ?? 0,
      })),
      heatmap,
      hours,
      topTitles: topTitleRows.map(([id, one]) => ({
        itemId: id,
        title: items.get(id)?.title ?? "Removed title",
        kind: items.get(id)?.kind ?? null,
        viewers: one.viewers.size,
        sessions: one.sessions,
        watchedMs: one.watchedMs,
      })),
      viewers: [...viewers]
        .sort(([, a], [, b]) => b.watchedMs - a.watchedMs)
        .map(([id, one]) => ({
          id,
          name: profileNames.get(id)?.name ?? "Removed viewer",
          color: profileNames.get(id)?.["color"] ?? null,
          avatar: profileNames.get(id)?.["avatar"] ?? null,
          kids: profileNames.get(id)?.["kids"] === 1,
          ...one,
        })),
      devices: [...devices]
        .sort(([, a], [, b]) => b.watchedMs - a.watchedMs)
        .map(([id, one]) => ({
          id,
          name: deviceNames.get(id)?.name ?? "Removed device",
          platform: deviceNames.get(id)?.["platform"] ?? null,
          ...one,
        })),
      households: [...new Set([...households.keys(), ...householdBytes.keys()])]
        .map((id) => {
          const one = households.get(id);
          return {
            id,
            name: householdNames.get(id)?.name ?? "Removed household",
            owner: householdNames.get(id)?.owner === 1,
            watchedMs: one?.watchedMs ?? 0,
            sessions: one?.sessions ?? 0,
            viewers: one?.viewers.size ?? 0,
            devices: one?.devices.size ?? 0,
            bytesSent: householdBytes.get(id) ?? 0,
          };
        })
        .sort((a, b) => Number(b.owner) - Number(a.owner) || b.watchedMs - a.watchedMs),
      roads,
      deliveries,
      traffic: {
        homeBytes: sent.home,
        awayBytes: sent.tailnet + sent.relay + sent.direct + sent.unknown,
        byRoad: sent,
        days: daysBetween(range.firstDay, range.lastDay).map((day) => ({
          day,
          homeBytes: sentDays.get(day)?.homeBytes ?? 0,
          awayBytes: sentDays.get(day)?.awayBytes ?? 0,
        })),
      },
      preparations: {
        count: prepared?.count ?? 0,
        converted: prepared?.converted ?? 0,
        ahead: prepared?.background ?? 0,
        timeMs: prepared?.time ?? 0,
        bytes: prepared?.bytes ?? 0,
      },
      conversions: {
        done: converted?.count ?? 0,
        failed: conversionJobs?.failed ?? 0,
        waiting: conversionJobs?.waiting ?? 0,
        timeMs: converted?.time ?? 0,
        savedBytes: converted?.saved ?? 0,
        savedInAllBytes: savedInAll?.saved ?? 0,
      },
      library: {
        films: library?.films ?? 0,
        shows: library?.shows ?? 0,
        episodes: library?.episodes ?? 0,
        months: monthsBetween(range.firstDay.slice(0, 7), range.lastDay.slice(0, 7)).map(
          (month) => ({
            month,
            films: growthMonths.get(month)?.films ?? 0,
            episodes: growthMonths.get(month)?.episodes ?? 0,
          }),
        ),
      },
      playOn: {
        sessions: playOnSessions,
        watchedMs: playOnMs,
        targets: [...targets]
          .sort(([, a], [, b]) => b - a)
          .map(([id, sessions]) => ({
            id,
            name: deviceNames.get(id)?.name ?? "Removed device",
            sessions,
          })),
      },
      storage: options.storage,
    };
  }
}

/** The run of days with watching that reaches today (or yesterday), and the longest one. */
export function streaks(
  days: ReadonlySet<string>,
  today: string,
): { current: number; longest: number } {
  const sorted = [...days].sort();
  let longest = 0;
  let run = 0;
  let previous: string | null = null;
  for (const day of sorted) {
    run = previous !== null && addDays(previous, 1) === day ? run + 1 : 1;
    longest = Math.max(longest, run);
    previous = day;
  }
  let current = 0;
  let day = days.has(today) ? today : addDays(today, -1);
  while (days.has(day) && current < 4000) {
    current += 1;
    day = addDays(day, -1);
  }
  return { current, longest };
}
