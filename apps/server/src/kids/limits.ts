// SPDX-License-Identifier: MPL-2.0
import { createHash } from "node:crypto";
import type { Database } from "../db/database.ts";
import { Studios } from "../library/studios.ts";
import type { CategoryView } from "../library/categories.ts";
import { OWNER_HOUSEHOLD } from "../households/owner.ts";

/** What a kids viewer may see. Ids only; blocked wins, and nothing allowed is nothing shown. */
export interface KidsSettings {
  allowedGroupIds: string[];
  allowedCategoryIds: string[];
  allowedItemIds: string[];
  blockedItemIds: string[];
  /** Like the allowed ones, a category here covers the categories inside it. */
  blockedCategoryIds: string[];
}

export const KIDS_LISTS = [
  "allowedGroupIds",
  "allowedCategoryIds",
  "allowedItemIds",
  "blockedItemIds",
  "blockedCategoryIds",
] as const satisfies (keyof KidsSettings)[];

/**
 * The part of the library one kids viewer may see, or a guest household (`kind: "household"`,
 * `profileId` then `household:<id>`). A kids viewer of a guest household sees what both allow.
 */
export interface KidsView {
  profileId: string;
  kind: "kids" | "household";
  items: ReadonlySet<string>;
  /** A file only counts when every title it holds may be seen. */
  assets: ReadonlySet<string>;
  /** For titles that may be seen; a show has those of its episodes that may be seen. */
  categories: ReadonlyMap<string, ReadonlySet<string>>;
  /** For films and shows: the categories they are in by a rule, as far as those are allowed. */
  ruled: ReadonlyMap<string, ReadonlySet<string>>;
  available: ReadonlySet<string>;
}

interface ItemRow {
  id: string;
  kind: string;
  parent_id: string | null;
  chosen: string | null;
}

interface LinkRow {
  item_id: string;
  asset_id: string;
  category_id: string | null;
  reachable: number;
}

/** The key a guest household's view is known by, where a kids viewer's id would be. */
export const householdScopeKey = (householdId: string): string => `household:${householdId}`;

/** Only what both allow. */
function both(kids: KidsView, scope: KidsView): KidsView {
  const items = new Set([...kids.items].filter((id) => scope.items.has(id)));
  const keep = <T>(map: ReadonlyMap<string, T>): Map<string, T> =>
    new Map([...map].filter(([id]) => items.has(id)));
  const ruled = new Map<string, Set<string>>();
  for (const [id, ids] of kids.ruled) {
    const also = scope.ruled.get(id);
    const shared = new Set([...ids].filter((one) => also?.has(one) === true));
    if (shared.size > 0) ruled.set(id, shared);
  }
  return {
    profileId: kids.profileId,
    kind: "kids",
    items,
    assets: new Set([...kids.assets].filter((id) => scope.assets.has(id))),
    categories: keep(kids.categories),
    ruled,
    available: new Set([...kids.available].filter((id) => scope.available.has(id))),
  };
}

export function readKids(json: string | null): KidsSettings | null {
  if (json === null) return null;
  // Limits from before categories could be blocked block none.
  return {
    blockedCategoryIds: [],
    ...(JSON.parse(json) as Omit<KidsSettings, "blockedCategoryIds">),
  };
}

/** What a change of the categories means for one kids viewer. */
export interface KidsChange {
  profileId: string;
  name: string;
  /** Films, shows and videos with something in them that this viewer did not see before. */
  appearing: KidsTitles;
  /** And with something that this viewer no longer sees. */
  disappearing: KidsTitles;
}

export interface KidsTitles {
  count: number;
  /** The first of them by name. */
  titles: { id: string; title: string }[];
}

const MAX_TOLD_TITLES = 50;

/**
 * Works out what each kids viewer may see and answers from memory until something that
 * matters changes: the limits, the titles, their files or the categories. The database
 * counts those changes itself (the "kids_epoch" triggers).
 */
export class KidsLimits {
  private readonly db: Database;
  private readonly views = new Map<string, { key: string; view: KidsView }>();
  private readonly told = new Map<string, KidsView>();

  constructor(db: Database) {
    this.db = db;
  }

  /**
   * What this viewer may see: within their household's part of the library, when it has one. A
   * viewer that is gone or no longer a kids viewer sees nothing.
   */
  view(profileId: string): KidsView {
    const row = this.db.get<{ kids_json: string | null; scope_json: string | null }>(
      `select profile.kids_json, household.scope_json from profile
       left join household on household.id = profile.household_id
       where profile.id = ? and profile.deleted_at is null`,
      [profileId],
    );
    const json = row?.kids_json ?? null;
    const scope = row?.scope_json ?? null;
    const key = `${this.stamp()} ${json ?? ""} ${scope ?? ""}`;
    const known = this.views.get(profileId);
    if (known?.key === key) return known.view;
    const own = this.compute(profileId, readKids(json));
    const view = scope === null ? own : both(own, this.compute("", readKids(scope)));
    this.views.set(profileId, { key, view });
    return view;
  }

  private stamp(): string {
    return `${String(this.db.currentRevision())} ${this.db.getMeta("kids_epoch") ?? ""}`;
  }

  /** What a guest household may see of the library; null when it may see all of it. */
  householdView(householdId: string): KidsView | null {
    const scope =
      this.db.get<{ scope_json: string | null }>(
        "select scope_json from household where id = ? and owner = 0",
        [householdId],
      )?.scope_json ?? null;
    if (scope === null) return null;
    const id = householdScopeKey(householdId);
    const key = `${this.stamp()} ${scope}`;
    const known = this.views.get(id);
    if (known?.key === key) return known.view;
    const view = { ...this.compute(id, readKids(scope)), kind: "household" as const };
    this.views.set(id, { key, view });
    return view;
  }

  /** What a device may see: its kids viewer's, else its household's; null when it has no limits. */
  deviceView(device: { kidsProfileId: string | null; householdId: string }): KidsView | null {
    if (device.kidsProfileId !== null) return this.view(device.kidsProfileId);
    return device.householdId === OWNER_HOUSEHOLD ? null : this.householdView(device.householdId);
  }

  /** The same, by the device's id. */
  viewOf(deviceId: string): KidsView | null {
    const row = this.db.get<{ kidsProfileId: string | null; householdId: string }>(
      "select kids_profile_id as kidsProfileId, household_id as householdId from device where id = ?",
      [deviceId],
    );
    return row ? this.deviceView(row) : null;
  }

  /** Different after every change that can move a title in or out of a limit. */
  get epoch(): string {
    return this.db.getMeta("kids_epoch") ?? "";
  }

  /**
   * Every kids viewer of the owner's household and what they see now. Those of guests are not
   * told to the owner's managers: they are another household's children.
   */
  everyone(): { id: string; name: string; view: KidsView }[] {
    return this.kidsViewers().map(({ id, name }) => ({ id, name, view: this.view(id) }));
  }

  /**
   * What became different since `before`. Meant for inside a transaction that may still be
   * taken back, so nothing of it is kept: the numbers a view is known by can be given again.
   *
   * @returns the changes, and a token that is the same only while exactly the same would appear
   */
  changes(before: { id: string; name: string; view: KidsView }[]): {
    changes: KidsChange[];
    token: string;
  } {
    const changes: KidsChange[] = [];
    const hash = createHash("sha256");
    for (const one of before) {
      const json =
        this.db.get<{ kids_json: string | null }>("select kids_json from profile where id = ?", [
          one.id,
        ])?.kids_json ?? null;
      const after = this.compute(one.id, readKids(json));
      // The owner's viewers only (see everyone()): there is no part of the library to keep to.
      const gained = [...after.items].filter((id) => !one.view.items.has(id)).sort();
      const lost = [...one.view.items].filter((id) => !after.items.has(id));
      if (gained.length > 0) hash.update(`${one.id} ${gained.join(" ")}\n`);
      if (gained.length === 0 && lost.length === 0) continue;
      changes.push({
        profileId: one.id,
        name: one.name,
        appearing: this.titles(gained),
        disappearing: this.titles(lost),
      });
    }
    return { changes, token: hash.digest("hex").slice(0, 32) };
  }

  private kidsViewers(): { id: string; name: string; kids_json: string }[] {
    return this.db.all(
      `select id, name, kids_json from profile
       where deleted_at is null and kids_json is not null and household_id = '${OWNER_HOUSEHOLD}'
       order by created_at, id`,
    );
  }

  /** What the family would call these: the film, show or video each is part of. */
  private titles(ids: string[]): KidsTitles {
    if (ids.length === 0) return { count: 0, titles: [] };
    const titles = this.db.all<{ id: string; title: string }>(
      `with recursive up (id, parent_id) as (
         select id, parent_id from item where id in (select value from json_each(?))
         union select item.id, item.parent_id from item join up on item.id = up.parent_id)
       select item.id, coalesce(json_extract(item.override_json, '$.title'), item.title) as title
       from up join item on item.id = up.id where up.parent_id is null
       order by item.sort_title, item.id`,
      [JSON.stringify(ids)],
    );
    return { count: titles.length, titles: titles.slice(0, MAX_TOLD_TITLES) };
  }

  private compute(profileId: string, kids: KidsSettings | null): KidsView {
    const items = new Set<string>();
    const assets = new Set<string>();
    const categories = new Map<string, Set<string>>();
    const available = new Set<string>();
    const ruled = new Map<string, Set<string>>();
    const view: KidsView = {
      profileId,
      kind: "kids",
      items,
      assets,
      categories,
      ruled,
      available,
    };
    if (!kids) return view;

    const rows = new Map(
      this.db
        .all<ItemRow>(
          "select id, kind, parent_id, json_extract(override_json, '$.categoryIds') as chosen from item",
        )
        .map((row) => [row.id, row]),
    );
    // Of every file, also one that is being read again: its folder still says what it is.
    const links = this.db.all<LinkRow>(
      `select item_asset.item_id, item_asset.asset_id, source.category_id,
         (asset.state = 'probed' and asset.available = 1 and source.available = 1
            and item_asset.role = 'main') as reachable
       from item_asset
       join asset on asset.id = item_asset.asset_id
       join source on source.id = asset.source_id`,
    );
    const groupOf = new Map<string, string>();
    const insideOf = new Map<string, string>();
    for (const row of this.db.all<{ id: string; group_id: string; parent_id: string | null }>(
      "select id, group_id, parent_id from category",
    )) {
      groupOf.set(row.id, row.group_id);
      if (row.parent_id !== null) insideOf.set(row.id, row.parent_id);
    }
    /** A category is named by itself or by the one it is in. */
    const named = (id: string, ids: Set<string>): boolean =>
      ids.has(id) || ids.has(insideOf.get(id) ?? "");
    const main = this.db.get<{ id: string }>("select id from category_group where name is null");
    const allowedGroups = new Set(kids.allowedGroupIds);
    const allowedCategories = new Set(kids.allowedCategoryIds);
    const allowedItems = new Set(kids.allowedItemIds);
    const blockedItems = new Set(kids.blockedItemIds);
    const blockedCategories = new Set(kids.blockedCategoryIds);

    const folders = new Map<string, Set<string>>();
    const linked = new Set<string>();
    for (const link of links) {
      linked.add(link.item_id);
      if (link.category_id === null) continue;
      const ids = folders.get(link.item_id) ?? new Set<string>();
      folders.set(link.item_id, ids.add(link.category_id));
    }

    const parentOf = (row: ItemRow): ItemRow | undefined =>
      row.parent_id === null ? undefined : rows.get(row.parent_id);

    const rules = new Studios(this.db).ruled();
    /** The categories its film or show is in by a rule. */
    const ruleOf = (row: ItemRow): Set<string> => {
      let top = row;
      for (let one = parentOf(row); one; one = parentOf(one)) top = one;
      return rules.get(top.id) ?? new Set();
    };

    /** What a manager chose for it or for something above it, else its own folders. */
    const own = (row: ItemRow): Set<string> => {
      for (let one: ItemRow | undefined = row; one; one = parentOf(one)) {
        if (one.chosen === null) continue;
        const ids = (JSON.parse(one.chosen) as string[]).filter((id) => groupOf.has(id));
        if (ids.length > 0) return new Set(ids);
      }
      return folders.get(row.id) ?? new Set();
    };

    /** Whether one of these ids is the item's own or that of something above it. */
    const within = (row: ItemRow, ids: Set<string>): boolean => {
      for (let one: ItemRow | undefined = row; one; one = parentOf(one)) {
        if (ids.has(one.id)) return true;
      }
      return false;
    };

    /**
     * A rule brings a title only into the category itself, never into its group: a studio makes
     * all kinds of films, and the group was allowed for what was put in it by hand.
     */
    const allowed = (row: ItemRow, ids: Set<string>): boolean => {
      const rule = ruleOf(row);
      if (within(row, blockedItems)) return false;
      if ([...ids, ...rule].some((id) => named(id, blockedCategories))) return false;
      if (within(row, allowedItems)) return true;
      if ([...rule].some((id) => named(id, allowedCategories))) return true;
      // A title in no category belongs to the main part of the library.
      if (ids.size === 0) {
        return linked.has(row.id) && main !== undefined && allowedGroups.has(main.id);
      }
      return [...ids].some(
        (id) => named(id, allowedCategories) || allowedGroups.has(groupOf.get(id) ?? ""),
      );
    };

    // Shows and seasons follow from what is in them, so none is shown with nothing inside.
    for (const row of rows.values()) {
      if (row.kind === "show" || row.kind === "season") continue;
      const ids = own(row);
      if (!allowed(row, ids)) continue;
      const parent = parentOf(row);
      // An extra belongs to its film: without the film there is nowhere to show it.
      if (parent?.kind === "movie" && !allowed(parent, own(parent))) continue;
      items.add(row.id);
      categories.set(row.id, new Set(ids));
      const rule = [...ruleOf(row)].filter((id) => named(id, allowedCategories));
      let top = row;
      for (let one = parent; one; one = parentOf(one)) top = one;
      if (rule.length > 0) ruled.set(top.id, new Set([...(ruled.get(top.id) ?? []), ...rule]));
      for (let above = parent; above && above.kind !== "movie"; above = parentOf(above)) {
        items.add(above.id);
        const known = categories.get(above.id) ?? new Set<string>();
        for (const id of ids) known.add(id);
        categories.set(above.id, known);
      }
    }

    const refused = new Set<string>();
    for (const link of links) {
      if (items.has(link.item_id)) assets.add(link.asset_id);
      else refused.add(link.asset_id);
    }
    for (const id of refused) assets.delete(id);

    for (const link of links) {
      if (link.reachable !== 1 || !assets.has(link.asset_id)) continue;
      for (let one = rows.get(link.item_id); one; one = parentOf(one)) available.add(one.id);
    }
    return view;
  }

  /**
   * Notes what changed for this viewer since the last refresh of any of their devices, so
   * that the changes have a place in the order of library revisions.
   */
  note(view: KidsView): void {
    if (this.told.get(view.profileId) === view) return;
    this.db.transaction(() => {
      const files = new Map<string, string[]>();
      for (const link of this.db.all<{ item_id: string; asset_id: string }>(
        "select item_id, asset_id from item_asset order by asset_id",
      )) {
        if (!view.items.has(link.item_id) || !view.assets.has(link.asset_id)) continue;
        files.set(link.item_id, [...(files.get(link.item_id) ?? []), link.asset_id]);
      }
      const known = new Map(
        this.db
          .all<{ item_id: string; visible: number; shape: string }>(
            "select item_id, visible, shape from kids_item where profile_id = ?",
            [view.profileId],
          )
          .map((row) => [row.item_id, row]),
      );
      let revision: number | null = null;
      const save = (itemId: string, visible: boolean, shape: string): void => {
        revision ??= this.db.nextRevision();
        this.db.run(
          `insert into kids_item (profile_id, item_id, visible, shape, revision) values (?, ?, ?, ?, ?)
           on conflict (profile_id, item_id) do update set visible = excluded.visible,
             shape = excluded.shape, revision = excluded.revision`,
          [view.profileId, itemId, visible ? 1 : 0, shape, revision],
        );
      };
      for (const id of view.items) {
        const rule = [...(view.ruled.get(id) ?? [])].sort();
        const shape = JSON.stringify([
          [...(view.categories.get(id) ?? [])].sort(),
          view.available.has(id),
          files.get(id) ?? [],
          // Only when there is one, so what was told before stays the same.
          ...(rule.length > 0 ? [rule] : []),
        ]);
        const before = known.get(id);
        if (before?.visible !== 1 || before.shape !== shape) save(id, true, shape);
      }
      for (const row of known.values()) {
        if (row.visible === 1 && !view.items.has(row.item_id)) save(row.item_id, false, "");
      }
    });
    this.told.set(view.profileId, view);
  }

  /** The household's categories, as far as this viewer has titles in them. */
  categories(view: KidsView, all: CategoryView): CategoryView {
    const shown = new Set<string>();
    for (const ids of view.categories.values()) for (const id of ids) shown.add(id);
    for (const ids of view.ruled.values()) for (const id of ids) shown.add(id);
    // One with something inside is there, as a group is.
    for (const entry of all.groups.flatMap((group) => group.entries)) {
      if (entry.parentId !== null && shown.has(entry.id)) shown.add(entry.parentId);
    }
    const groups = all.groups
      .map((group) => {
        const entries = group.entries.filter((entry) => shown.has(entry.id));
        return { ...group, entries, categories: entries.map((entry) => entry.name) };
      })
      // The main part is always there, as it is for everyone.
      .filter((group) => group.name === null || group.entries.length > 0);
    const names = new Set(groups.flatMap((group) => group.categories));
    return {
      revision: all.revision,
      groups,
      logos: Object.fromEntries(Object.entries(all.logos).filter(([name]) => names.has(name))),
    };
  }
}

const limits = new WeakMap<Database, KidsLimits>();

/** The limits of this catalogue, shared by everything that answers from it. */
export function kidsLimits(db: Database): KidsLimits {
  let found = limits.get(db);
  if (!found) {
    found = new KidsLimits(db);
    limits.set(db, found);
  }
  return found;
}
