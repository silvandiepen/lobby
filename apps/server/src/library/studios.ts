// SPDX-License-Identifier: MPL-2.0
import { createHash } from "node:crypto";
import type { Database } from "../db/database.ts";
import { nameKey } from "./categories.ts";

/** A company that made a title, or the network that showed it, as TMDB knows it. */
export interface Studio {
  kind: "company" | "network";
  id: number;
  name: string;
  /** A PNG at TMDB, or null. */
  logoPath: string | null;
  country: string | null;
}

/** How a studio is named everywhere else: "company:12" or "network:34". */
export const STUDIO_ID = /^(company|network):[1-9][0-9]{0,9}$/;

export function studioId(studio: Pick<Studio, "kind" | "id">): string {
  return `${studio.kind}:${String(studio.id)}`;
}

/** The most studios one category's rule can name. */
export const MAX_RULE_STUDIOS = 50;

/** A category that takes in the titles of these studios. */
export interface CategoryRule {
  studioIds: string[];
}

export function readRule(json: string | null): CategoryRule | null {
  return json === null ? null : (JSON.parse(json) as CategoryRule);
}

export interface Suggestion {
  /** Stays the same while the same studios are in it. */
  id: string;
  name: string;
  studios: { id: string; name: string; logoPath: string | null; titles: number }[];
  /** Films and shows of any of them in the household. */
  count: number;
  titles: { id: string; title: string }[];
  /** A logo of one of them, for `GET /v1/categories/logo-search/preview?path=`. */
  logoPath: string | null;
  /** A category of that name, which could take the rule instead of a new one. */
  categoryId: string | null;
}

/** Words that say what kind of company it is, not which. Never a name. */
const KIND_WORDS = new Set([
  "animation",
  "animated",
  "co",
  "company",
  "corporation",
  "entertainment",
  "feature",
  "features",
  "film",
  "films",
  "home",
  "inc",
  "llc",
  "ltd",
  "media",
  "motion",
  "picture",
  "pictures",
  "production",
  "productions",
  "studio",
  "studios",
  "television",
  "the",
  "tv",
]);

/** What several companies of one studio have in common: their name without the kind of company. */
export function studioKey(name: string): string {
  const words = nameKey(name)
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim()
    .split(" ")
    .filter((word) => word !== "");
  const kept = words.filter((word) => !KIND_WORDS.has(word));
  return (kept.length > 0 ? kept : words).join(" ");
}

const SHOWN_TITLES = 6;

/** What TMDB says made the household's titles, and the categories that follow studios. */
export class Studios {
  private readonly db: Database;

  constructor(db: Database) {
    this.db = db;
  }

  /**
   * Keeps what made a film or show. Answers whether that is different now; then every title
   * it is in a category through is different too.
   */
  save(itemId: string, studios: Studio[]): boolean {
    const now = Date.now();
    const before = this.of(itemId).join(" ");
    const unique = [...new Map(studios.map((one) => [studioId(one), one])).values()];
    for (const one of unique) {
      this.db.run(
        `insert into studio (id, kind, tmdb_id, name, logo_path, country, seen_at) values (?, ?, ?, ?, ?, ?, ?)
         on conflict (id) do update set name = excluded.name,
           logo_path = coalesce(excluded.logo_path, studio.logo_path),
           country = excluded.country, seen_at = excluded.seen_at`,
        [studioId(one), one.kind, one.id, one.name, one.logoPath, one.country, now],
      );
    }
    const after = unique.map((one) => studioId(one));
    this.db.run("update item set studios_at = ? where id = ?", [now, itemId]);
    if (after.join(" ") === before) return false;
    this.db.run("delete from item_studio where item_id = ?", [itemId]);
    after.forEach((id, position) => {
      this.db.run("insert into item_studio (item_id, studio_id, position) values (?, ?, ?)", [
        itemId,
        id,
        position,
      ]);
    });
    return true;
  }

  of(itemId: string): string[] {
    return this.db
      .all<{ studio_id: string }>(
        "select studio_id from item_studio where item_id = ? order by position",
        [itemId],
      )
      .map((row) => row.studio_id);
  }

  /** The categories each film or show is in by a rule. Below it, the same. */
  ruled(): Map<string, Set<string>> {
    const found = new Map<string, Set<string>>();
    for (const row of this.db.all<{ item_id: string; category_id: string }>(
      `select distinct item_studio.item_id, category.id as category_id
       from category cross join json_each(category.rule_json, '$.studioIds') as wanted
       join item_studio on item_studio.studio_id = wanted.value
       where category.rule_json is not null`,
    )) {
      const ids = found.get(row.item_id) ?? new Set<string>();
      found.set(row.item_id, ids.add(row.category_id));
    }
    return found;
  }

  /**
   * Studios with at least `min` films and shows in the household that no category follows
   * and no manager waved away, one suggestion for the companies of one studio.
   */
  suggestions(min: number): Suggestion[] {
    const taken = new Set(
      this.db
        .all<{ value: string }>(
          `select wanted.value from category cross join json_each(category.rule_json, '$.studioIds') as wanted
           where category.rule_json is not null
           union select studio_id from studio_dismissed`,
        )
        .map((row) => row.value),
    );
    const rows = this.db.all<{
      studio_id: string;
      name: string;
      logo_path: string | null;
      item_id: string;
      title: string;
      sort_title: string;
    }>(
      `select studio.id as studio_id, studio.name, studio.logo_path, item.id as item_id,
         coalesce(json_extract(item.override_json, '$.title'), item.title) as title, item.sort_title
       from item_studio join studio on studio.id = item_studio.studio_id
       join item on item.id = item_studio.item_id
       where item.kind in ('movie', 'show') and item.parent_id is null
       order by item.sort_title, item.id`,
    );
    interface Found {
      name: string;
      logoPath: string | null;
      titles: Set<string>;
    }
    const groups = new Map<string, { studios: Map<string, Found>; titles: Map<string, string> }>();
    for (const row of rows) {
      if (taken.has(row.studio_id)) continue;
      const key = studioKey(row.name);
      const group = groups.get(key) ?? {
        studios: new Map<string, Found>(),
        titles: new Map<string, string>(),
      };
      groups.set(key, group);
      const studio = group.studios.get(row.studio_id) ?? {
        name: row.name,
        logoPath: row.logo_path,
        titles: new Set<string>(),
      };
      group.studios.set(row.studio_id, studio);
      studio.titles.add(row.item_id);
      group.titles.set(row.item_id, row.title);
    }
    const categories = new Map(
      this.db
        .all<{ id: string; name: string }>("select id, name from category")
        .map((row) => [nameKey(row.name), row.id]),
    );
    const found: Suggestion[] = [];
    for (const group of groups.values()) {
      if (group.titles.size < min) continue;
      const studios = [...group.studios]
        .map(([id, one]) => ({
          id,
          name: one.name,
          logoPath: one.logoPath,
          titles: one.titles.size,
        }))
        .sort((a, b) => b.titles - a.titles || (a.id < b.id ? -1 : 1));
      // The name of the one with most titles, which is the studio itself more often than not.
      const name = studios.reduce((best, one) =>
        one.titles === best.titles && one.name.length < best.name.length ? one : best,
      ).name;
      const ids = studios.map((one) => one.id).sort();
      found.push({
        id: createHash("sha256").update(ids.join(" ")).digest("hex").slice(0, 16),
        name,
        studios,
        count: group.titles.size,
        titles: [...group.titles].slice(0, SHOWN_TITLES).map(([id, title]) => ({ id, title })),
        logoPath: studios.find((one) => one.logoPath !== null)?.logoPath ?? null,
        categoryId: categories.get(nameKey(name)) ?? null,
      });
    }
    return found.sort((a, b) => b.count - a.count || (a.name < b.name ? -1 : 1));
  }

  /** Remembers that these are not to be suggested again. */
  dismiss(studioIds: string[]): void {
    for (const id of studioIds) {
      this.db.run("insert into studio_dismissed (studio_id) values (?) on conflict do nothing", [
        id,
      ]);
    }
  }

  /** Whether a studio is known here: from a title, or from a category that follows it. */
  known(id: string): boolean {
    return this.db.get("select 1 as x from studio where id = ?", [id]) !== undefined;
  }
}
