// SPDX-License-Identifier: MPL-2.0
import { randomUUID } from "node:crypto";
import type { Database } from "../db/database.ts";
import { keepBlocked, traceBlocked } from "../kids/blocks.ts";
import { normalizeTitle, sortTitle, type ParsedMedia } from "./parse.ts";

export type ItemKind = "movie" | "show" | "season" | "episode" | "extra" | "personal";

interface ItemRow {
  id: string;
  kind: ItemKind;
  parent_id: string | null;
  match_status: string;
}

interface NewItem {
  kind: ItemKind;
  parentId: string | null;
  identKey: string;
  title: string;
  year?: number | null;
  seasonNumber?: number | null;
  episodeNumber?: number | null;
  airDate?: string | null;
  matchStatus?: "unmatched" | "needs_review" | "personal";
  imdbId?: string | null;
  tmdbType?: "movie" | "tv" | null;
  tmdbId?: number | null;
  metadata?: Record<string, unknown>;
}

function seasonTitle(season: number | null): string {
  if (season === null) return "Other episodes";
  return season === 0 ? "Specials" : `Season ${season}`;
}

/** The title an episode has until something better is known. */
function episodeTitle(parsed: ParsedMedia, number: number | null): string {
  if (number === null) return parsed.episodeTitle ?? parsed.title;
  const alone = (parsed.episodeEnd ?? parsed.episode) === parsed.episode;
  return alone && parsed.episodeTitle !== null ? parsed.episodeTitle : `Episode ${number}`;
}

/**
 * Turns parsed files into the items the family sees, and keeps that mapping
 * stable: the same film or episode always resolves to the same item id, so
 * watch history and downloads survive rescans, renames and restarts.
 */
export class Catalogue {
  private readonly db: Database;
  private readonly now: () => number;
  /** The items made for the file that is being linked. */
  private readonly fresh = new Set<string>();

  constructor(db: Database, now: () => number = Date.now) {
    this.db = db;
    this.now = now;
  }

  /**
   * Finds the item with this identity or creates it. Identity keys are built
   * from what the file names say (title, year, season, episode), never from a
   * provider's data, so a later match cannot split or merge items.
   */
  private ensureItem(item: NewItem, revision: number): string {
    const existing = this.db.get<{
      id: string;
      title: string;
      air_date: string | null;
      match_status: string;
      enriched_at: number | null;
    }>("select id, title, air_date, match_status, enriched_at from item where ident_key = ?", [
      item.identKey,
    ]);
    if (existing) {
      // Until a provider or a manager has named the item, it shows what the file names say,
      // so better parsing rules improve what is already in the catalogue.
      const fromNames =
        existing.enriched_at === null &&
        (existing.match_status === "unmatched" || existing.match_status === "needs_review");
      const status = item.matchStatus ?? "unmatched";
      if (
        fromNames &&
        item.kind !== "show" &&
        item.kind !== "season" &&
        (existing.title !== item.title ||
          existing.air_date !== (item.airDate ?? null) ||
          existing.match_status !== status)
      ) {
        this.db.run(
          "update item set title = ?, sort_title = ?, air_date = ?, match_status = ?, metadata_json = ?, revision = ? where id = ?",
          [
            item.title,
            sortTitle(item.title),
            item.airDate ?? null,
            status,
            item.metadata ? JSON.stringify(item.metadata) : null,
            revision,
            existing.id,
          ],
        );
      }
      return existing.id;
    }
    const id = randomUUID();
    this.fresh.add(id);
    this.db.run(
      `insert into item (id, kind, parent_id, ident_key, title, sort_title, year, season_number,
         episode_number, air_date, match_status, imdb_id, tmdb_type, tmdb_id, metadata_json, added_at, revision)
       values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        id,
        item.kind,
        item.parentId,
        item.identKey,
        item.title,
        sortTitle(item.title),
        item.year ?? null,
        item.seasonNumber ?? null,
        item.episodeNumber ?? null,
        item.airDate ?? null,
        item.matchStatus ?? "unmatched",
        item.imdbId ?? null,
        item.tmdbType ?? null,
        item.tmdbId ?? null,
        item.metadata ? JSON.stringify(item.metadata) : null,
        this.now(),
        revision,
      ],
    );
    return id;
  }

  private link(
    itemId: string,
    assetId: string,
    role: "main" | "trailer" | "extra",
    parsed: ParsedMedia,
  ): void {
    this.db.run(
      `insert into item_asset (item_id, asset_id, role, edition, part) values (?, ?, ?, ?, ?)
       on conflict (item_id, asset_id) do update set role = excluded.role, edition = excluded.edition, part = excluded.part`,
      [itemId, assetId, role, parsed.edition, parsed.part],
    );
  }

  /** Marks an item and everything above it as changed, so clients refresh them. */
  touch(itemId: string, revision: number): void {
    let current: string | null = itemId;
    while (current !== null) {
      this.db.run("update item set revision = ? where id = ?", [revision, current]);
      current =
        this.db.get<{ parent_id: string | null }>("select parent_id from item where id = ?", [
          current,
        ])?.parent_id ?? null;
    }
  }

  /**
   * A season and its show were added when their newest episode was. Another file for an episode
   * that was there is not a new episode, and neither is one that got another name.
   */
  private noteAdded(linked: string[], previous: string[]): void {
    const before = this.db.get<{ at: number | null }>(
      "select min(added_at) as at from item where id in (select value from json_each(?))",
      [JSON.stringify(previous)],
    )?.at;
    for (const id of linked) {
      if (!this.fresh.has(id)) continue;
      if (before != null) {
        this.db.run("update item set added_at = min(added_at, ?) where id = ?", [before, id]);
      }
      const item = this.db.get<{ kind: ItemKind; added_at: number; parent_id: string | null }>(
        "select kind, added_at, parent_id from item where id = ?",
        [id],
      );
      if (item?.kind !== "episode") continue;
      for (let above = item.parent_id; above !== null; above = this.parentOf(above)) {
        this.db.run(
          this.fresh.has(above)
            ? "update item set added_at = ? where id = ?"
            : "update item set added_at = max(added_at, ?) where id = ?",
          [item.added_at, above],
        );
      }
    }
  }

  private ensureShow(parsed: ParsedMedia, revision: number): string {
    return this.ensureItem(
      {
        kind: "show",
        parentId: null,
        identKey: `show:${normalizeTitle(parsed.title)}`,
        title: parsed.title,
        year: parsed.year,
      },
      revision,
    );
  }

  private ensureMovie(parsed: ParsedMedia, revision: number, needsReview: boolean): string {
    return this.ensureItem(
      {
        kind: "movie",
        parentId: null,
        identKey: `movie:${normalizeTitle(parsed.title)}:${parsed.year ?? "?"}`,
        title: parsed.title,
        year: parsed.year,
        matchStatus: needsReview ? "needs_review" : "unmatched",
        imdbId: parsed.imdbId,
        tmdbType: parsed.tmdbId === null ? null : "movie",
        tmdbId: parsed.tmdbId,
      },
      revision,
    );
  }

  /**
   * Links a probed file to its item(s), creating them when they are new.
   * Called again when a file changes; a link a manager locked is left alone.
   *
   * @returns the ids of the items the file now belongs to
   */
  linkAsset(assetId: string, parsed: ParsedMedia, hint: string): string[] {
    this.fresh.clear();
    return this.db.transaction(() => {
      const previous = this.db.all<ItemRow>(
        `select item.id, item.kind, item.parent_id, item.match_status
         from item_asset join item on item.id = item_asset.item_id where item_asset.asset_id = ?`,
        [assetId],
      );
      if (previous.some((item) => item.match_status === "locked")) {
        return previous.map((item) => item.id);
      }

      const revision = this.db.nextRevision();
      const linked: string[] = [];

      if (parsed.kind === "episode") {
        const showId = this.ensureShow(parsed, revision);
        const seasonId = this.ensureItem(
          {
            kind: "season",
            parentId: showId,
            identKey: `season:${showId}:${parsed.season ?? "none"}`,
            title: seasonTitle(parsed.season),
            seasonNumber: parsed.season,
          },
          revision,
        );
        if (parsed.episode === null) {
          // No number in the name: keep it playable under the show and ask a manager.
          const id = this.ensureItem(
            {
              kind: "episode",
              parentId: seasonId,
              identKey: `episode:${showId}:asset:${assetId}`,
              title: episodeTitle(parsed, null),
              seasonNumber: parsed.season,
              airDate: parsed.airDate,
              // A date and a title identify an episode well enough to look it up later.
              matchStatus: parsed.airDate === null ? "needs_review" : "unmatched",
              metadata: { evidence: parsed.evidence },
            },
            revision,
          );
          this.link(id, assetId, "main", parsed);
          linked.push(id);
        } else {
          const last = parsed.episodeEnd ?? parsed.episode;
          for (let number = parsed.episode; number <= last; number += 1) {
            const id = this.ensureItem(
              {
                kind: "episode",
                parentId: seasonId,
                identKey: `episode:${showId}:${parsed.season ?? "none"}:${number}`,
                title: episodeTitle(parsed, number),
                seasonNumber: parsed.season,
                episodeNumber: number,
                metadata: {
                  evidence: parsed.evidence,
                  ...(last !== parsed.episode && parsed.episodeTitle !== null
                    ? { combinedTitle: parsed.episodeTitle }
                    : {}),
                },
              },
              revision,
            );
            this.link(id, assetId, "main", parsed);
            linked.push(id);
          }
        }
      } else if (parsed.kind === "extra") {
        const parentId =
          hint === "series"
            ? this.ensureShow(parsed, revision)
            : this.ensureMovie(parsed, revision, false);
        const id = this.ensureItem(
          {
            kind: "extra",
            parentId,
            identKey: `extra:${assetId}`,
            title: parsed.episodeTitle ?? "Extra",
            metadata: { extraKind: parsed.extraKind, evidence: parsed.evidence },
          },
          revision,
        );
        this.link(id, assetId, parsed.extraKind === "trailer" ? "trailer" : "extra", parsed);
        linked.push(id);
      } else if (parsed.kind === "personal") {
        const id = this.ensureItem(
          {
            kind: "personal",
            parentId: null,
            identKey: `personal:${assetId}`,
            title: parsed.title,
            matchStatus: "personal",
          },
          revision,
        );
        this.link(id, assetId, "main", parsed);
        linked.push(id);
      } else {
        const id =
          parsed.kind === "unknown"
            ? this.ensureItem(
                {
                  kind: "movie",
                  parentId: null,
                  identKey: `unknown:${assetId}`,
                  title: parsed.title,
                  matchStatus: "needs_review",
                  metadata: { evidence: parsed.evidence },
                },
                revision,
              )
            : this.ensureMovie(parsed, revision, false);
        this.link(id, assetId, "main", parsed);
        linked.push(id);
      }

      // The file may have belonged to other items before it was renamed or re-read.
      const [onlyPrevious] = previous;
      const [onlyLinked] = linked;
      if (
        previous.length === 1 &&
        linked.length === 1 &&
        onlyPrevious &&
        onlyLinked &&
        onlyPrevious.id !== onlyLinked
      ) {
        // A rename that changed what the file is called: the family's place in it moves along.
        this.db.run("update or ignore progress set item_id = ? where item_id = ?", [
          onlyLinked,
          onlyPrevious.id,
        ]);
        this.db.run("update or ignore play set item_id = ? where item_id = ?", [
          onlyLinked,
          onlyPrevious.id,
        ]);
      }
      this.noteAdded(
        linked,
        previous.map((item) => item.id),
      );
      // What a manager changed moves along as well, for everything the rename leaves empty.
      const successors = new Map<string, string>();
      if (previous.length === linked.length) {
        previous.forEach((item, index) => {
          this.pairUp(item.id, linked[index] ?? item.id, successors);
        });
      } else if (onlyPrevious && onlyLinked) {
        const from = this.parentOf(onlyPrevious.id);
        const to = this.parentOf(onlyLinked);
        if (from !== null && to !== null) this.pairUp(from, to, successors);
      }
      keepBlocked(
        this.db,
        assetId,
        previous.map((item) => item.id),
        successors,
        this.fresh,
      );
      for (const item of previous) {
        if (linked.includes(item.id)) continue;
        this.db.run("delete from item_asset where item_id = ? and asset_id = ?", [
          item.id,
          assetId,
        ]);
        this.removeIfEmpty(item.id, revision, successors);
      }
      for (const id of linked) this.touch(id, revision);
      return linked;
    });
  }

  /** Marks every item with a file in this library folder as changed, e.g. when its drive goes away. */
  touchSource(sourceId: string): void {
    this.db.transaction(() => {
      const revision = this.db.nextRevision();
      const items = this.db.all<{ item_id: string }>(
        `select distinct item_asset.item_id from item_asset
         join asset on asset.id = item_asset.asset_id where asset.source_id = ?`,
        [sourceId],
      );
      const touched = new Set<string>();
      for (const item of items) {
        let current: string | null = item.item_id;
        while (current !== null && !touched.has(current)) {
          touched.add(current);
          this.db.run("update item set revision = ? where id = ?", [revision, current]);
          current =
            this.db.get<{ parent_id: string | null }>("select parent_id from item where id = ?", [
              current,
            ])?.parent_id ?? null;
        }
      }
    });
  }

  /** Marks every item a file belongs to as changed. */
  touchAsset(assetId: string): void {
    this.db.transaction(() => {
      const items = this.db.all<{ item_id: string }>(
        "select item_id from item_asset where asset_id = ?",
        [assetId],
      );
      if (items.length === 0) return;
      const revision = this.db.nextRevision();
      for (const item of items) this.touch(item.item_id, revision);
    });
  }

  /** Removes a file for good, and any item it leaves with nothing to play. */
  removeAsset(assetId: string): void {
    this.db.transaction(() => {
      const items = this.db.all<{ item_id: string }>(
        "select item_id from item_asset where asset_id = ?",
        [assetId],
      );
      const revision = this.db.nextRevision();
      traceBlocked(this.db, assetId);
      this.db.run("delete from asset where id = ?", [assetId]);
      for (const item of items) this.removeIfEmpty(item.item_id, revision);
    });
  }

  /**
   * Deletes an item that has no files and no children left, then looks at its
   * parent. A match a manager locked is kept: it holds their decision.
   */
  private removeIfEmpty(
    itemId: string,
    revision: number,
    successors: Map<string, string> = new Map<string, string>(),
  ): void {
    const item = this.db.get<ItemRow>(
      "select id, kind, parent_id, match_status from item where id = ?",
      [itemId],
    );
    if (!item) return;
    const files = this.db.get<{ n: number }>(
      "select count(*) as n from item_asset where item_id = ?",
      [itemId],
    );
    const children = this.db.get<{ n: number }>(
      "select count(*) as n from item where parent_id = ?",
      [itemId],
    );
    if ((files?.n ?? 0) > 0 || (children?.n ?? 0) > 0) {
      this.touch(itemId, revision);
      return;
    }
    const successor = successors.get(itemId);
    if (successor !== undefined) this.moveKidsLimits(itemId, successor);
    if (successor !== undefined) this.moveEdits(itemId, successor, revision);
    else if (item.match_status === "locked") return;
    this.db.run("delete from item where id = ?", [itemId]);
    this.db.run(
      "insert into tombstone (item_id, revision) values (?, ?) on conflict (item_id) do update set revision = excluded.revision",
      [itemId, revision],
    );
    if (item.parent_id !== null) this.removeIfEmpty(item.parent_id, revision, successors);
  }

  private parentOf(itemId: string): string | null {
    return (
      this.db.get<{ parent_id: string | null }>("select parent_id from item where id = ?", [itemId])
        ?.parent_id ?? null
    );
  }

  /** Notes which item takes over from which, up through the seasons and shows they are in. */
  private pairUp(from: string, to: string, successors: Map<string, string>): void {
    let pair: [string | null, string | null] = [from, to];
    while (pair[0] !== null && pair[1] !== null && pair[0] !== pair[1]) {
      const [a, b] = pair;
      const kinds = this.db.all<{ kind: string }>("select kind from item where id in (?, ?)", [
        a,
        b,
      ]);
      if (kinds[0]?.kind !== kinds[1]?.kind) return;
      successors.set(a, b);
      pair = [this.parentOf(a), this.parentOf(b)];
    }
  }

  /**
   * A renamed title stays blocked for the kids it was blocked for, and stays allowed. Not
   * allowed when it joins a title that was there already: that one was not chosen.
   */
  private moveKidsLimits(from: string, to: string): void {
    const add = (list: string): void => {
      this.db.run(
        `update profile set kids_json = json_insert(kids_json, '$.${list}[#]', ?1)
         where kids_json is not null
           and exists (select 1 from json_each(kids_json, '$.${list}') where value = ?2)
           and not exists (select 1 from json_each(kids_json, '$.${list}') where value = ?1)`,
        [to, from],
      );
    };
    add("blockedItemIds");
    if (this.fresh.has(to)) add("allowedItemIds");
  }

  /** Gives an item's edits, chosen pictures and chosen match to the one that replaces it. */
  private moveEdits(from: string, to: string, revision: number): void {
    const old = this.db.get<{
      override_json: string | null;
      match_status: string;
      tmdb_type: string | null;
      tmdb_id: number | null;
      edit_revision: number;
    }>(
      "select override_json, match_status, tmdb_type, tmdb_id, edit_revision from item where id = ?",
      [from],
    );
    const target = this.db.get<{ edit_revision: number }>(
      "select edit_revision from item where id = ?",
      [to],
    );
    // Edits made on the new item itself count for more.
    if (!old || !target || old.edit_revision === 0 || target.edit_revision > 0) return;
    this.db.run("update item set override_json = ?, edit_revision = ? where id = ?", [
      old.override_json,
      old.edit_revision,
      to,
    ]);
    if (old.match_status === "locked") {
      this.db.run(
        `update item set match_status = 'locked', tmdb_type = ?, tmdb_id = ?, enriched_at = null,
           enrich_next_attempt_at = null, candidates_json = null where id = ?`,
        [old.tmdb_type, old.tmdb_id, to],
      );
    }
    for (const row of this.db.all<{ id: string; kind: string }>(
      "select id, kind from artwork where item_id = ? and locked = 1",
      [from],
    )) {
      this.db.run("update artwork set selected = 0 where item_id = ? and kind = ?", [to, row.kind]);
      this.db.run("update or ignore artwork set item_id = ?, automatic = 0 where id = ?", [
        to,
        row.id,
      ]);
    }
    this.touch(to, revision);
    this.touchBelow(to, revision);
  }

  /** Marks everything below an item as changed. */
  touchBelow(itemId: string, revision: number): void {
    this.db.run(
      `with recursive below (id) as (
         select id from item where parent_id = ?
         union all select item.id from item join below on item.parent_id = below.id)
       update item set revision = ? where id in (select id from below)`,
      [itemId, revision],
    );
  }

  /** Chooses the picture Lobby would by itself: the provider's, or else a frame. */
  selectAutomaticArtwork(itemId: string, kind: string): void {
    this.db.run("update artwork set selected = 0, locked = 0 where item_id = ? and kind = ?", [
      itemId,
      kind,
    ]);
    this.db.run(
      `update artwork set selected = 1 where id = (
         select id from artwork where item_id = ? and kind = ? and (automatic = 1 or provider = 'frame')
         order by automatic desc limit 1)`,
      [itemId, kind],
    );
  }

  /**
   * Takes everything a provider gave an item away again, so it shows what the file names
   * say. The item, its identity, its edits and everyone's place in it stay.
   */
  forgetMatch(
    itemId: string,
    status: "unmatched" | "locked",
    revision: number,
    match: { tmdbType: "movie" | "tv"; tmdbId: number } | null = null,
  ): void {
    const item = this.db.get<{
      kind: ItemKind;
      title: string;
      season_number: number | null;
      episode_number: number | null;
    }>("select kind, title, season_number, episode_number from item where id = ?", [itemId]);
    if (!item) return;
    const json = this.db.get<{ parsed_json: string }>(
      `with recursive tree (id) as (
         select ? union all select item.id from item join tree on item.parent_id = tree.id)
       select parsed_json from item_asset join asset on asset.id = item_asset.asset_id
       where item_asset.item_id in (select id from tree) and parsed_json is not null
       order by item_asset.role = 'main' desc, asset.rel_path limit 1`,
      [itemId],
    );
    const parsed = json ? (JSON.parse(json.parsed_json) as ParsedMedia) : null;
    let title = item.title;
    if (item.kind === "season") title = seasonTitle(item.season_number);
    else if (parsed && item.kind === "episode") title = episodeTitle(parsed, item.episode_number);
    else if (parsed && (item.kind === "movie" || item.kind === "show")) title = parsed.title;
    const named = item.kind === "movie" || item.kind === "show";
    this.db.run(
      `update item set title = ?, sort_title = ?, year = ?, overview = null, air_date = ?, runtime_ms = null,
         tmdb_type = ?, tmdb_id = ?, imdb_id = ?, metadata_json = ?, candidates_json = null, match_status = ?,
         enriched_at = null, enrich_attempts = 0, enrich_next_attempt_at = null, tagline = null, popularity = null,
         vote_average = null, vote_count = null, facts_at = null, revision = ? where id = ?`,
      [
        title,
        sortTitle(title),
        named ? (parsed?.year ?? null) : null,
        item.kind === "episode" ? (parsed?.airDate ?? null) : null,
        match?.tmdbType ?? null,
        match?.tmdbId ?? null,
        item.kind === "movie" && match === null ? (parsed?.imdbId ?? null) : null,
        parsed && !named ? JSON.stringify({ evidence: parsed.evidence }) : null,
        status,
        revision,
        itemId,
      ],
    );
    this.db.run("delete from item_genre where item_id = ?", [itemId]);
    this.db.run("delete from artwork where item_id = ? and provider = 'tmdb' and locked = 0", [
      itemId,
    ]);
    this.db.run("update artwork set automatic = 0 where item_id = ?", [itemId]);
    for (const kind of ["poster", "backdrop", "still", "logo"]) {
      const chosen = this.db.get(
        "select 1 as x from artwork where item_id = ? and kind = ? and selected = 1",
        [itemId, kind],
      );
      if (!chosen) this.selectAutomaticArtwork(itemId, kind);
    }
    this.touch(itemId, revision);
  }

  /** The seasons and episodes of a show that follow its match: not those a manager locked. */
  followers(showId: string): string[] {
    return this.db
      .all<{ id: string }>(
        `with recursive below (id, kind, status) as (
           select id, kind, match_status from item where parent_id = ?
           union all select item.id, item.kind, item.match_status
             from item join below on item.parent_id = below.id)
         select id from below where kind in ('season', 'episode') and status != 'locked'`,
        [showId],
      )
      .map((row) => row.id);
  }
}
