// SPDX-License-Identifier: MPL-2.0
import { CONVERT_VIDEO } from "../playback/plan.ts";
import type { Database } from "../db/database.ts";
import { Studios } from "./studios.ts";
import { kidsLimits, type KidsView } from "../kids/limits.ts";
import { effectiveSortTitle, readOverrides } from "./overrides.ts";
import { sidecarCodec, TEXT_SUBTITLES } from "./probe.ts";
import { markersFor, type ApiMarkers } from "../markers/store.ts";

/** The catalogue as the apps see it. The shapes are the contract in docs/api.md. */
export interface ApiItem {
  id: string;
  kind: string;
  parentId: string | null;
  title: string;
  sortTitle: string;
  year: number | null;
  seasonNumber: number | null;
  episodeNumber: number | null;
  overview: string | null;
  airDate: string | null;
  runtimeMs: number | null;
  genres: string[];
  categories: string[];
  categoryIds: string[];
  /** Of a film, show or video: the categories that take it in because of its studios. */
  ruleCategoryIds: string[];
  /** Of a film or show: who made or showed it, as TMDB says, the most important first. */
  studios: { id: string; name: string }[];
  matchStatus: string;
  imdbId: string | null;
  tmdb: { type: string; id: number } | null;
  extraKind: string | null;
  trailer: { provider: string; key: string } | null;
  artwork: {
    poster: ApiArtwork | null;
    backdrop: ApiArtwork | null;
    still: ApiArtwork | null;
    logo: ApiArtwork | null;
  };
  tagline: string | null;
  renown: number | null;
  /** TMDB's average rating, 0 to 10, one decimal. Null with fewer than `RATED_VOTES` votes. */
  rating: number | null;
  addedAt: number;
  newEpisodesAt: number | null;
  latestAirDate: string | null;
  available: boolean;
  files: ApiFile[];
}

export interface ApiArtwork {
  id: string;
  width: number | null;
  height: number | null;
}

export interface ApiFile {
  assetId: string;
  role: string;
  edition: string | null;
  part: number | null;
  startMs: number | null;
  endMs: number | null;
  sharedBy: number;
  available: boolean;
  sizeBytes: number;
  durationMs: number | null;
  container: string;
  revision: string;
  playability: string;
  playabilityReason: string | null;
  /** True when the server converts the picture itself (playability "transcode" only). */
  convertible: boolean;
  video: { codec: string; width: number | null; height: number | null; bitDepth: number } | null;
  audio: {
    index: number;
    codec: string;
    language: string | null;
    title: string | null;
    channels: number | null;
    isDefault: boolean;
  }[];
  subtitles: {
    id: string;
    source: "embedded" | "sidecar";
    codec: string;
    language: string | null;
    title: string | null;
    isForced: boolean;
    isText: boolean;
  }[];
  /** Where its intro and credits are, when known (docs/decisions.md, "Skip Intro"). */
  markers: ApiMarkers;
}

interface ItemRow {
  id: string;
  kind: string;
  parent_id: string | null;
  title: string;
  sort_title: string;
  year: number | null;
  season_number: number | null;
  episode_number: number | null;
  overview: string | null;
  air_date: string | null;
  runtime_ms: number | null;
  match_status: string;
  tmdb_type: string | null;
  tmdb_id: number | null;
  imdb_id: string | null;
  metadata_json: string | null;
  override_json: string | null;
  tagline: string | null;
  popularity: number | null;
  vote_average: number | null;
  vote_count: number | null;
  added_at: number;
  revision: number;
}

interface FileRow {
  item_id: string;
  asset_id: string;
  role: string;
  edition: string | null;
  part: number | null;
  start_ms: number | null;
  end_ms: number | null;
  shared_by: number;
  available: number;
  size: number;
  duration_ms: number | null;
  container: string | null;
  revision: string;
  playability: string | null;
  playability_reason: string | null;
}

interface TrackRow {
  asset_id: string;
  idx: number;
  kind: string;
  codec: string;
  language: string | null;
  title: string | null;
  channels: number | null;
  width: number | null;
  height: number | null;
  pix_fmt: string | null;
  is_default: number;
  is_forced: number;
}

interface Metadata {
  extraKind?: string | null;
  trailer?: { provider: string; key: string } | null;
}

interface Derived {
  available: Set<string>;
  /** Category ids from the files' folders, before a manager's changes. */
  automatic: Map<string, Set<string>>;
  categories: Map<string, Set<string>>;
  ruled: Map<string, Set<string>>;
  names: Map<string, string>;
}

/** A show gets everything that is there when it arrives; what comes later is new. */
const NEW_AFTER_MS = 24 * 3_600_000;
const RENOWNED_VOTES = 20_000;
const RENOWNED_POPULARITY = 200;
/** Fewer votes than this say little about how good a title is. */
export const RATED_VOTES = 10;

/** TMDB's average rating, as the apps get it. */
export function ratingOf(votes: number | null, average: number | null): number | null {
  if (votes === null || votes < RATED_VOTES || average === null) return null;
  return Math.round(average * 10) / 10;
}

/**
 * How well known a title is, 0 to 1, from TMDB's numbers alone: mostly how many people rated
 * it, a little how they did and how much it is looked at now. Null when nobody rated it.
 */
export function renown(
  votes: number | null,
  rating: number | null,
  popularity: number | null,
): number | null {
  if (votes === null || votes <= 0) return null;
  const part = (value: number, full: number): number =>
    Math.min(1, Math.log1p(value) / Math.log1p(full));
  const known = part(votes, RENOWNED_VOTES);
  // A handful of ratings says little, so it is pulled to the middle.
  const liked = (votes * (rating ?? 6.5) + 200 * 6.5) / (votes + 200) / 10;
  const now = part(popularity ?? 0, RENOWNED_POPULARITY);
  return Math.round(100 * (0.6 * known + 0.2 * known * liked + 0.2 * now)) / 100;
}

function noArtwork(): ApiItem["artwork"] {
  return { poster: null, backdrop: null, still: null, logo: null };
}

interface Episodes {
  first: number;
  newest: number;
  aired: string | null;
}

/** In order of name, so names and ids go side by side. */
function named(
  ids: ReadonlySet<string> | undefined,
  names: Map<string, string>,
): { id: string; name: string }[] {
  return [...(ids ?? [])]
    .map((id) => ({ id, name: names.get(id) ?? "" }))
    .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
}

/**
 * Reads items out of the catalogue in the shape the apps use.
 *
 * Availability and categories of a show depend on every file below it, so they
 * are worked out once per library revision for the whole catalogue (a few
 * thousand rows) and reused until something changes.
 */
export class ItemReader {
  private readonly db: Database;
  private derived: { revision: number; value: Derived } | null = null;

  constructor(db: Database) {
    this.db = db;
  }

  /** The categories the files alone put an item in. */
  automaticCategories(itemId: string): { id: string; name: string }[] {
    const { automatic, names } = this.derive();
    return named(automatic.get(itemId), names);
  }

  private derive(): Derived {
    const revision = this.db.currentRevision();
    if (this.derived?.revision === revision) return this.derived.value;

    const parents = new Map(
      this.db
        .all<{ id: string; parent_id: string | null }>("select id, parent_id from item")
        .map((row) => [row.id, row.parent_id]),
    );
    const available = new Set<string>();
    const automatic = new Map<string, Set<string>>();
    const leaves = this.db.all<{ item_id: string; category: string | null; reachable: number }>(
      `select distinct item_asset.item_id, source.category_id as category,
         (asset.available = 1 and source.available = 1 and item_asset.role = 'main') as reachable
       from item_asset
       join asset on asset.id = item_asset.asset_id
       join source on source.id = asset.source_id
       where asset.state = 'probed'`,
    );
    for (const leaf of leaves) {
      let current: string | null = leaf.item_id;
      while (current !== null) {
        if (leaf.reachable === 1) available.add(current);
        if (leaf.category !== null) {
          const ids = automatic.get(current) ?? new Set<string>();
          ids.add(leaf.category);
          automatic.set(current, ids);
        }
        current = parents.get(current) ?? null;
      }
    }
    const names = new Map(
      this.db
        .all<{ id: string; name: string }>("select id, name from category")
        .map((row) => [row.id, row.name]),
    );
    const chosen = new Map<string, Set<string>>();
    for (const row of this.db.all<{ id: string; ids: string }>(
      "select id, json_extract(override_json, '$.categoryIds') as ids from item where json_extract(override_json, '$.categoryIds') is not null",
    )) {
      const ids = (JSON.parse(row.ids) as string[]).filter((id) => names.has(id));
      // Without a category left the title would be hidden; the folders decide again.
      if (ids.length > 0) chosen.set(row.id, new Set(ids));
    }
    const categories = new Map(automatic);
    if (chosen.size > 0) {
      for (const id of parents.keys()) {
        let current: string | null = id;
        while (current !== null && !chosen.has(current)) current = parents.get(current) ?? null;
        const ids = current === null ? undefined : chosen.get(current);
        if (ids) categories.set(id, ids);
      }
    }
    const value = { available, automatic, categories, ruled: new Studios(this.db).ruled(), names };
    this.derived = { revision, value };
    return value;
  }

  /**
   * The categories each film, show or video is in: its own and those that take it in by a
   * rule, as far as a kids viewer may see them. Never the categories they are inside of.
   */
  titleCategories(view: KidsView | null = null): Map<string, Set<string>> {
    const derived = this.derive();
    const own = (view ?? derived).categories;
    const ruled = (view ?? derived).ruled;
    const found = new Map<string, Set<string>>();
    for (const map of [own, ruled]) {
      for (const [id, ids] of map) {
        const known = found.get(id) ?? new Set<string>();
        for (const one of ids) known.add(one);
        found.set(id, known);
      }
    }
    return found;
  }

  /**
   * Reads the given items, in the order of `ids`. Unknown ids are left out, and with a kids
   * viewer's view everything that viewer may not see.
   */
  read(ids: string[], view: KidsView | null = null): ApiItem[] {
    if (view) ids = ids.filter((id) => view.items.has(id));
    if (ids.length === 0) return [];
    const list = JSON.stringify(ids);
    const rows = new Map(
      this.db
        .all<ItemRow>("select * from item where id in (select value from json_each(?))", [list])
        .map((row) => [row.id, row]),
    );
    // "cross join" fixes the order: start from the asked-for items. Left to itself SQLite
    // starts from every probed file, which cost a second per page on the Pi.
    const files = this.db.all<FileRow>(
      `select item_asset.item_id, item_asset.asset_id, item_asset.role, item_asset.edition, item_asset.part,
         item_asset.start_ms, item_asset.end_ms,
         (select count(*) from item_asset as other
            join item on item.id = other.item_id
            where other.asset_id = item_asset.asset_id and item.kind = 'episode') as shared_by,
         (asset.available = 1 and source.available = 1) as available,
         asset.size, asset.duration_ms, asset.container, asset.revision, asset.playability, asset.playability_reason
       from json_each(?) as wanted
       cross join item_asset on item_asset.item_id = wanted.value
       cross join asset on asset.id = item_asset.asset_id
       cross join source on source.id = asset.source_id
       where asset.state = 'probed'
       order by item_asset.role, item_asset.part, asset.rel_path`,
      [list],
    );
    const assetList = JSON.stringify([...new Set(files.map((file) => file.asset_id))]);
    const tracks = new Map<string, TrackRow[]>();
    for (const track of this.db.all<TrackRow>(
      "select * from track where asset_id in (select value from json_each(?)) order by asset_id, idx",
      [assetList],
    )) {
      tracks.set(track.asset_id, [...(tracks.get(track.asset_id) ?? []), track]);
    }
    const sidecars = new Map<
      string,
      { id: string; format: string; language: string | null; is_forced: number }[]
    >();
    for (const sidecar of this.db.all<{
      id: string;
      asset_id: string;
      format: string;
      language: string | null;
      is_forced: number;
    }>(
      "select id, asset_id, format, language, is_forced from sidecar where asset_id in (select value from json_each(?)) order by rel_path",
      [assetList],
    )) {
      sidecars.set(sidecar.asset_id, [...(sidecars.get(sidecar.asset_id) ?? []), sidecar]);
    }
    const genres = new Map<string, string[]>();
    for (const genre of this.db.all<{ item_id: string; name: string }>(
      `select item_genre.item_id, genre.name from item_genre join genre on genre.id = item_genre.genre_id
       where item_genre.item_id in (select value from json_each(?)) order by genre.name`,
      [list],
    )) {
      genres.set(genre.item_id, [...(genres.get(genre.item_id) ?? []), genre.name]);
    }
    const artwork = new Map<string, ApiItem["artwork"]>();
    for (const art of this.db.all<{
      id: string;
      item_id: string;
      kind: "poster" | "backdrop" | "still" | "logo";
      width: number | null;
      height: number | null;
    }>(
      "select id, item_id, kind, width, height from artwork where selected = 1 and provider != 'none' and item_id in (select value from json_each(?))",
      [list],
    )) {
      const entry = artwork.get(art.item_id) ?? noArtwork();
      entry[art.kind] = { id: art.id, width: art.width, height: art.height };
      artwork.set(art.item_id, entry);
    }

    const studios = new Map<string, { id: string; name: string }[]>();
    for (const studio of this.db.all<{ item_id: string; id: string; name: string }>(
      `select item_studio.item_id, studio.id, studio.name from item_studio
       join studio on studio.id = item_studio.studio_id
       where item_studio.item_id in (select value from json_each(?)) order by item_studio.position`,
      [list],
    )) {
      studios.set(studio.item_id, [
        ...(studios.get(studio.item_id) ?? []),
        { id: studio.id, name: studio.name },
      ]);
    }

    const episodes = this.episodes(
      [...rows.values()].filter((row) => row.kind === "show" || row.kind === "season"),
      view,
    );
    const derived = this.derive();
    const markers = markersFor(this.db, [...new Set(files.map((file) => file.asset_id))]);
    const filesByItem = new Map<string, ApiFile[]>();
    for (const file of files) {
      if (view && !view.assets.has(file.asset_id)) continue;
      const assetTracks = tracks.get(file.asset_id) ?? [];
      const video = assetTracks.find((track) => track.kind === "video");
      const api: ApiFile = {
        assetId: file.asset_id,
        role: file.role,
        edition: file.edition,
        part: file.part,
        startMs: file.start_ms,
        endMs: file.end_ms,
        sharedBy: Math.max(1, file.shared_by),
        available: file.available === 1,
        sizeBytes: file.size,
        durationMs: file.duration_ms,
        container: file.container ?? "unknown",
        revision: file.revision,
        playability: file.playability ?? "unsupported",
        playabilityReason: file.playability_reason,
        convertible:
          file.playability === "transcode" && video !== undefined && CONVERT_VIDEO.has(video.codec),
        video: video
          ? {
              codec: video.codec,
              width: video.width,
              height: video.height,
              bitDepth: video.pix_fmt?.includes("10") ? 10 : video.pix_fmt?.includes("12") ? 12 : 8,
            }
          : null,
        audio: assetTracks
          .filter((track) => track.kind === "audio")
          .map((track) => ({
            index: track.idx,
            codec: track.codec,
            language: track.language,
            title: track.title,
            channels: track.channels,
            isDefault: track.is_default === 1,
          })),
        subtitles: [
          ...assetTracks
            .filter((track) => track.kind === "subtitle")
            .map((track) => ({
              id: `t${track.idx}`,
              source: "embedded" as const,
              codec: track.codec,
              language: track.language,
              title: track.title,
              isForced: track.is_forced === 1,
              isText: TEXT_SUBTITLES.has(track.codec),
            })),
          ...(sidecars.get(file.asset_id) ?? []).map((sidecar) => ({
            id: `s${sidecar.id}`,
            source: "sidecar" as const,
            codec: sidecarCodec(sidecar.format),
            language: sidecar.language,
            title: null,
            isForced: sidecar.is_forced === 1,
            isText: TEXT_SUBTITLES.has(sidecarCodec(sidecar.format)),
          })),
        ],
        markers: markers.get(file.asset_id) ?? { intro: null, credits: null },
      };
      filesByItem.set(file.item_id, [...(filesByItem.get(file.item_id) ?? []), api]);
    }

    const result: ApiItem[] = [];
    for (const id of ids) {
      const row = rows.get(id);
      if (!row) continue;
      const overrides = readOverrides(row.override_json);
      const own = named((view ?? derived).categories.get(id), derived.names);
      const below = episodes.get(id);
      const metadata = row.metadata_json ? (JSON.parse(row.metadata_json) as Metadata) : {};
      result.push({
        id: row.id,
        kind: row.kind,
        parentId: row.parent_id,
        title: overrides.title ?? row.title,
        sortTitle: effectiveSortTitle(overrides, row.sort_title),
        year: overrides.year === undefined ? row.year : overrides.year,
        seasonNumber: row.season_number,
        episodeNumber: row.episode_number,
        overview: overrides.overview === undefined ? row.overview : overrides.overview,
        airDate: row.air_date,
        runtimeMs: row.runtime_ms,
        genres: overrides.genres ?? genres.get(id) ?? [],
        categories: own.map((one) => one.name),
        categoryIds: own.map((one) => one.id),
        ruleCategoryIds:
          row.parent_id === null
            ? named((view ?? derived).ruled.get(id), derived.names).map((one) => one.id)
            : [],
        studios: row.parent_id === null ? (studios.get(id) ?? []) : [],
        matchStatus: row.match_status,
        imdbId: row.imdb_id,
        tmdb:
          row.tmdb_type !== null && row.tmdb_id !== null
            ? { type: row.tmdb_type, id: row.tmdb_id }
            : null,
        extraKind: metadata.extraKind ?? null,
        trailer: metadata.trailer ?? null,
        artwork: artwork.get(id) ?? noArtwork(),
        tagline: row.tagline,
        renown: renown(row.vote_count, row.vote_average, row.popularity),
        rating: ratingOf(row.vote_count, row.vote_average),
        addedAt: below?.newest ?? row.added_at,
        newEpisodesAt: below && below.newest - below.first >= NEW_AFTER_MS ? below.newest : null,
        latestAirDate: below?.aired ?? null,
        available: (view ?? derived).available.has(id),
        files: filesByItem.get(id) ?? [],
      });
    }
    return result;
  }

  /** When the episodes in these seasons and shows came: of those the viewer may see. */
  private episodes(containers: ItemRow[], view: KidsView | null): Map<string, Episodes> {
    const found = new Map<string, Episodes>();
    if (containers.length === 0) return found;
    const rows = this.db.all<{
      id: string;
      season: string;
      show: string | null;
      added_at: number;
      air_date: string | null;
    }>(
      `with season (id, show) as (
         select id, parent_id from item where kind = 'season'
           and (id in (select value from json_each(?1)) or parent_id in (select value from json_each(?1))))
       select episode.id, season.id as season, season.show, episode.added_at, episode.air_date
       from season cross join item as episode on episode.parent_id = season.id
       where episode.kind = 'episode'`,
      [JSON.stringify(containers.map((row) => row.id))],
    );
    for (const row of rows) {
      if (view && !view.items.has(row.id)) continue;
      for (const id of [row.season, row.show]) {
        if (id === null) continue;
        const known = found.get(id);
        found.set(id, {
          first: Math.min(known?.first ?? row.added_at, row.added_at),
          newest: Math.max(known?.newest ?? row.added_at, row.added_at),
          aired:
            [known?.aired ?? null, row.air_date]
              .filter((one) => one !== null)
              .sort()
              .at(-1) ?? null,
        });
      }
    }
    return found;
  }

  /**
   * One page of the catalogue for a client that last saw `after`.
   * Items come in the order they changed, oldest change first.
   */
  page(
    after: { revision: number; id: string } | null,
    limit: number,
  ): {
    items: ApiItem[];
    removed: string[];
    next: { revision: number; id: string };
    more: boolean;
  } {
    const current = this.db.currentRevision();
    const from = after ?? { revision: 0, id: "" };
    const ids = this.db.all<{ id: string; revision: number }>(
      `select id, revision from item where revision > ? or (revision = ? and id > ?)
       order by revision, id limit ?`,
      [from.revision, from.revision, from.id, limit + 1],
    );
    const more = ids.length > limit;
    const pageIds = ids.slice(0, limit);
    const last = pageIds.at(-1);
    // With nothing left, the client has seen everything up to now.
    // "\uffff" sorts after every id, so the cursor means: all of this revision was seen.
    const next =
      more && last ? { revision: last.revision, id: last.id } : { revision: current, id: "\uffff" };
    const removed = this.db
      .all<{ item_id: string }>(
        "select item_id from tombstone where revision > ? and revision <= ? order by revision",
        [from.revision, next.revision],
      )
      .map((row) => row.item_id);
    return { items: this.read(pageIds.map((row) => row.id)), removed, next, more };
  }

  /**
   * The same for a device of a kids viewer. What became allowed or stopped being allowed has
   * a place among the changes, whether a title, the limits or the categories changed.
   *
   * @param scope the kids viewer `after` was made for, or "" for a device without limits
   */
  kidsPage(
    view: KidsView,
    after: { revision: number; id: string } | null,
    scope: string,
    limit: number,
  ): {
    items: ApiItem[];
    removed: string[];
    next: { revision: number; id: string };
    more: boolean;
  } {
    const limits = kidsLimits(this.db);
    limits.note(view);
    const current = this.db.currentRevision();
    // The device holds what another viewer, or nobody's limits, let it have: all of that goes,
    // and it starts over. Also when the catalogue was put back from a backup.
    const other = after !== null && (scope !== view.profileId || after.revision > current);
    const from = after === null || other ? { revision: 0, id: "" } : after;
    const rows = this.db.all<{ id: string; revision: number }>(
      `select id, revision from (
         select item.id, max(item.revision, kids_item.revision) as revision
         from kids_item join item on item.id = kids_item.item_id
         where kids_item.profile_id = ? and kids_item.visible = 1)
       where revision > ? or (revision = ? and id > ?)
       order by revision, id limit ?`,
      [view.profileId, from.revision, from.revision, from.id, limit + 1],
    );
    const more = rows.length > limit;
    const page = rows.slice(0, limit);
    const last = page.at(-1);
    const next =
      more && last ? { revision: last.revision, id: last.id } : { revision: current, id: "\uffff" };
    let gone: { id: string }[] = [];
    if (other) {
      gone = this.db.all<{ id: string }>(
        "select id from item union select item_id from tombstone where revision > ? or ? > ?",
        [after.revision, after.revision, current],
      );
    } else if (after !== null) {
      gone = this.db.all<{ id: string }>(
        `select item_id as id from kids_item
         where profile_id = ? and visible = 0 and revision > ? and revision <= ? order by revision`,
        [view.profileId, from.revision, next.revision],
      );
    }
    return {
      items: this.read(
        page.map((row) => row.id),
        view,
      ),
      removed: gone.map((row) => row.id).filter((id) => !view.items.has(id)),
      next,
      more,
    };
  }

  /** @param view with a kids viewer's view, only what that viewer may see */
  children(itemId: string, view: KidsView | null = null): ApiItem[] {
    const ids = this.db
      .all<{ id: string }>(
        "select id from item where parent_id = ? order by kind, season_number, episode_number, sort_title",
        [itemId],
      )
      .map((row) => row.id);
    return this.read(ids, view);
  }
}
