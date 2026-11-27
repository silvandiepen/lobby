// SPDX-License-Identifier: MPL-2.0
import { randomUUID } from "node:crypto";
import { basename } from "node:path";
import type { RootConfig } from "../config.ts";
import type { Database } from "../db/database.ts";
import { log } from "../log.ts";
import { MAX_RULE_STUDIOS, readRule, type CategoryRule } from "./studios.ts";

export const COLORS = [
  "red",
  "orange",
  "yellow",
  "green",
  "teal",
  "blue",
  "purple",
  "pink",
] as const;

export interface LogoInfo {
  /** Never changes its picture. */
  id: string;
  width: number;
  height: number;
  /** False for an opaque picture, whose shape alone would be a rectangle. */
  transparent: boolean;
}

export interface CategoryEntry {
  id: string;
  /** The category of the same group it is in. One level: that one is in none. */
  parentId: string | null;
  name: string;
  icon: string | null;
  color: string | null;
  logo: LogoInfo | null;
  /** Titles of these studios are in it too, besides those of its folders and those chosen. */
  rule: CategoryRule | null;
}

export interface CategoryGroupEntry {
  id: string;
  /** Null is the main part of the library. */
  name: string | null;
  icon: string | null;
  color: string | null;
  logo: LogoInfo | null;
  /** Names, for apps from before categories had ids. */
  categories: string[];
  /** Each followed by the ones inside it. */
  entries: CategoryEntry[];
}

export interface CategoryView {
  /** Counts changes to the setup. Send it with every change. */
  revision: number;
  groups: CategoryGroupEntry[];
  /** Logos by category name, for apps from before categories had ids. */
  logos: Record<string, { id: string; width: number; height: number }>;
}

export interface FolderEntry {
  id: string;
  name: string;
  hint: string;
  available: boolean;
  categoryId: string | null;
}

/** A change that cannot be made. The message can be shown. */
export class CategoryRefused extends Error {
  readonly code: "invalid_request" | "not_found" | "conflict";
  constructor(code: "invalid_request" | "not_found" | "conflict", message: string) {
    super(message);
    this.code = code;
  }
}

export interface Look {
  name?: string;
  icon?: string | null;
  color?: string | null;
  rule?: CategoryRule | null;
}

/** Where a category goes. A parent wins over a group: what is inside is in its group. */
export interface Place {
  groupId?: string;
  parentId?: string | null;
}

/** Several changes that count as one. `parentId` and ids may name a new one by `new:<key>`. */
export interface Arrangement {
  /** `logoFrom`: the logo another category has before the changes, which keeps it too. */
  create: ({ key: string; name: string; logoFrom?: string } & Place & Look)[];
  categories: ({ id: string; logoFrom?: string } & Place & Look)[];
  /** Every category of that place, each once. A null parent is the group itself. */
  order: { groupId: string; parentId: string | null; ids: string[] }[];
}

export type Owner = "category" | "category_group";

interface GroupRow {
  id: string;
  name: string | null;
  position: number;
  icon: string | null;
  color: string | null;
  logo_id: string | null;
}
interface CategoryRow {
  id: string;
  group_id: string;
  parent_id: string | null;
  name: string;
  position: number;
  icon: string | null;
  color: string | null;
  logo_id: string | null;
  rule_json: string | null;
}
/** How the categories were; enough to put an arrangement back. */
interface UndoState {
  rows: CategoryRow[];
  created: string[];
}
interface LogoRow {
  id: string;
  width: number | null;
  height: number | null;
  transparent: number;
}

const REVISION = "categories_revision";

const noCategory = (): CategoryRefused =>
  new CategoryRefused("not_found", "There is no such category.");
const oneLevel = (): CategoryRefused =>
  new CategoryRefused(
    "invalid_request",
    "A category can be in another one, but not more than one level deep.",
  );
const otherGroup = (): CategoryRefused =>
  new CategoryRefused(
    "invalid_request",
    "A category is in the same part of the library as the one it is in.",
  );

/** Two names a person would call the same are the same. */
export function nameKey(name: string): string {
  return name.normalize("NFKC").trim().replace(/\s+/g, " ").toLocaleLowerCase("en");
}

/**
 * The household's categories: which there are, in what order, how they look and which
 * library folders feed them. Everything else refers to a category by its id, so a name is
 * only a name. No change here removes a title.
 */
export class Categories {
  private readonly db: Database;
  private asks = false;

  constructor(db: Database) {
    this.db = db;
  }

  /** Whether the change under way concerns nested or blocked categories. */
  get mustAsk(): boolean {
    return this.asks;
  }

  get revision(): number {
    return Number(this.db.getMeta(REVISION) ?? "0");
  }

  // Reading

  private groupRows(): GroupRow[] {
    return this.db.all<GroupRow>(
      "select * from category_group order by name is not null, position, rowid",
    );
  }

  private categoryRows(): CategoryRow[] {
    return this.db.all<CategoryRow>("select * from category order by position, rowid");
  }

  /** Each followed by the ones inside it. */
  private nested(rows: CategoryRow[]): CategoryRow[] {
    return rows
      .filter((row) => row.parent_id === null)
      .flatMap((row) => [row, ...rows.filter((one) => one.parent_id === row.id)]);
  }

  private logos(): Map<string, LogoInfo> {
    return new Map(
      this.db
        .all<LogoRow>("select id, width, height, transparent from logo where data is not null")
        .map((row) => [
          row.id,
          {
            id: row.id,
            width: row.width ?? 0,
            height: row.height ?? 0,
            transparent: row.transparent === 1,
          },
        ]),
    );
  }

  view(): CategoryView {
    const logos = this.logos();
    const logoOf = (id: string | null): LogoInfo | null =>
      id === null ? null : (logos.get(id) ?? null);
    const categories = this.categoryRows();
    const byName: CategoryView["logos"] = {};
    for (const row of categories) {
      const logo = logoOf(row.logo_id);
      if (logo) byName[row.name] = { id: logo.id, width: logo.width, height: logo.height };
    }
    const groups = this.groupRows().map((group) => {
      const own = this.nested(categories.filter((row) => row.group_id === group.id));
      return {
        id: group.id,
        name: group.name,
        icon: group.icon,
        color: group.color,
        logo: logoOf(group.logo_id),
        categories: own.map((row) => row.name),
        entries: own.map((row) => ({
          id: row.id,
          parentId: row.parent_id,
          name: row.name,
          icon: row.icon,
          color: row.color,
          logo: logoOf(row.logo_id),
          rule: readRule(row.rule_json),
        })),
      };
    });
    return { revision: this.revision, groups, logos: byName };
  }

  folders(): FolderEntry[] {
    return this.db
      .all<{
        id: string;
        path: string;
        hint: string;
        available: number;
        category_id: string | null;
      }>("select id, path, hint, available, category_id from source order by path")
      .map((row) => ({
        id: row.id,
        name: basename(row.path),
        hint: row.hint,
        available: row.available === 1,
        categoryId: row.category_id,
      }));
  }

  /** Every category in the household's order. */
  all(): { id: string; name: string; parentId: string | null }[] {
    return this.view().groups.flatMap((group) =>
      group.entries.map(({ id, name, parentId }) => ({ id, name, parentId })),
    );
  }

  // Changing

  /**
   * Makes one change to the setup. Titles it shows differently are marked as changed, so
   * every app hears of it; the library revision moves in any case.
   *
   * @param check looks at the result; when it throws, nothing happened
   */
  change(revision: number, work: () => void, check: () => void = () => undefined): void {
    this.db.transaction(() => {
      this.asks = false;
      if (revision !== this.revision) {
        throw new CategoryRefused("conflict", "Someone else changed the categories meanwhile.");
      }
      work();
      this.dropUnusedLogos();
      this.db.setMeta(REVISION, String(this.revision + 1));
      this.db.nextRevision();
      check();
    });
  }

  createGroup(look: Look & { name: string }): string {
    this.refuseGroupName(look.name, null);
    const id = randomUUID();
    this.db.run(
      "insert into category_group (id, name, position, icon, color) values (?, ?, ?, ?, ?)",
      [id, look.name, this.nextPosition("category_group"), look.icon ?? null, look.color ?? null],
    );
    return id;
  }

  updateGroup(id: string, look: Look): void {
    const group = this.group(id);
    if (look.name !== undefined) {
      if (group.name === null) {
        throw new CategoryRefused("invalid_request", "The main part has no name.");
      }
      this.refuseGroupName(look.name, id);
      this.db.run("update category_group set name = ? where id = ?", [look.name, id]);
    }
    this.decorate("category_group", id, look);
  }

  deleteGroup(id: string, moveTo: string | null): void {
    const group = this.group(id);
    if (group.name === null) {
      throw new CategoryRefused("invalid_request", "The main part cannot be removed.");
    }
    const inside = this.categoryRows().filter((row) => row.group_id === id);
    if (inside.length > 0) {
      // Never by itself: what was set apart would turn up among everything else.
      if (moveTo === null || moveTo === id) {
        throw new CategoryRefused("invalid_request", "Say which part its categories move to.");
      }
      this.group(moveTo);
      for (const row of inside) {
        this.careful(row);
        this.db.run("update category set group_id = ?, position = ? where id = ?", [
          moveTo,
          this.nextPosition("category"),
          row.id,
        ]);
      }
    }
    this.db.run("delete from category_group where id = ?", [id]);
  }

  /** @param ids every named group, in the new order; the main part is always first */
  orderGroups(ids: string[]): void {
    const named = this.groupRows().filter((row) => row.name !== null);
    this.reorder("category_group", named, ids);
  }

  createCategory(
    groupId: string | undefined,
    look: Look & { name: string },
    parentId: string | null = null,
  ): string {
    const parent = parentId === null ? null : this.category(parentId);
    if (parent && parent.parent_id !== null) throw oneLevel();
    const group = groupId ?? parent?.group_id;
    if (group === undefined) {
      throw new CategoryRefused("invalid_request", "Say which part of the library it is in.");
    }
    this.group(group);
    if (parent && parent.group_id !== group) throw otherGroup();
    this.refuseCategoryName(look.name, null);
    const id = randomUUID();
    this.db.run(
      "insert into category (id, group_id, parent_id, name, position, icon, color) values (?, ?, ?, ?, ?, ?, ?)",
      [
        id,
        group,
        parentId,
        look.name,
        this.nextPosition("category"),
        look.icon ?? null,
        look.color ?? null,
      ],
    );
    if (look.rule) this.decorate("category", id, { rule: look.rule });
    return id;
  }

  /** The studios a category follows; null for none. */
  ruleOf(id: string): CategoryRule | null {
    return readRule(this.category(id).rule_json);
  }

  updateCategory(id: string, change: Look & Place): void {
    this.updateAll([{ ...change, id }]);
  }

  /** Changes several as if at once: only the result has to fit. */
  private updateAll(changes: ({ id: string } & Look & Place)[]): void {
    for (const change of changes) this.category(change.id);
    this.rename(
      new Map(changes.flatMap(({ id, name }) => (name === undefined ? [] : [[id, name] as const]))),
    );
    this.place(changes);
    for (const change of changes) this.decorate("category", change.id, change);
  }

  private rename(names: Map<string, string>): void {
    const rows = this.categoryRows();
    const renamed = rows.filter((row) => (names.get(row.id) ?? row.name) !== row.name);
    if (renamed.length === 0) return;
    const keys = rows.map((row) => nameKey(names.get(row.id) ?? row.name));
    if (new Set(keys).size !== keys.length) {
      throw new CategoryRefused("invalid_request", "There is a category of that name.");
    }
    // Two may change names with each other, and a name is never there twice.
    for (const { id } of renamed) {
      this.db.run("update category set name = ? where id = ?", [`\u0000${id}`, id]);
    }
    for (const { id } of renamed) {
      this.db.run("update category set name = ? where id = ?", [names.get(id) ?? "", id]);
      this.touchTitles(id);
    }
  }

  /** Moves categories between groups and into and out of each other, with what is inside them. */
  private place(changes: ({ id: string } & Place)[]): void {
    const before = new Map(this.categoryRows().map((row) => [row.id, row]));
    const after = new Map([...before].map(([id, row]) => [id, { ...row }]));
    const asked = new Map<string, string>();
    for (const { id, groupId, parentId } of changes) {
      const row = after.get(id);
      if (!row) throw noCategory();
      if (groupId !== undefined) {
        this.group(groupId);
        asked.set(id, groupId);
        // Out of its group is out of what it was in.
        if (groupId !== row.group_id) row.parent_id = null;
        row.group_id = groupId;
      }
      if (parentId !== undefined) row.parent_id = parentId;
    }
    for (const row of after.values()) {
      if (row.parent_id === null) continue;
      const parent = after.get(row.parent_id);
      if (!parent) throw noCategory();
      if (parent.id === row.id || parent.parent_id !== null) throw oneLevel();
      if ((asked.get(row.id) ?? parent.group_id) !== parent.group_id) throw otherGroup();
      row.group_id = parent.group_id;
    }
    for (const { id } of changes) {
      const was = before.get(id);
      const row = after.get(id);
      if (!was || !row) continue;
      if (was.parent_id === row.parent_id && was.group_id === row.group_id) continue;
      // Its new neighbours have an order; it comes last.
      row.position = this.nextPosition("category");
      this.db.run("update category set position = ? where id = ?", [row.position, id]);
    }
    for (const row of after.values()) {
      const was = before.get(row.id);
      if (was?.parent_id === row.parent_id && was.group_id === row.group_id) continue;
      if (was) this.careful(was);
      if (row.parent_id !== null) this.asks = true;
      this.db.run("update category set group_id = ?, parent_id = ? where id = ?", [
        row.group_id,
        row.parent_id,
        row.id,
      ]);
    }
  }

  /**
   * @param parentId whose order it is: that of the ones inside it, or with null that of the
   * group's own; left out, the order is of all of the group, as apps from before have it
   * @param ids each of them, in the new order
   */
  orderCategories(groupId: string, ids: string[], parentId?: string | null): void {
    this.group(groupId);
    if (typeof parentId === "string" && this.category(parentId).group_id !== groupId) {
      throw otherGroup();
    }
    // Only neighbours are compared, so one order for all of them says how each ones' is.
    this.reorder(
      "category",
      this.categoryRows().filter(
        (row) => row.group_id === groupId && (parentId === undefined || row.parent_id === parentId),
      ),
      ids,
    );
  }

  /**
   * Makes several changes as one, which can be taken back until something else changes.
   *
   * @returns the ids of the new ones, by key
   */
  arrange(arrangement: Arrangement): Record<string, string> {
    const rows = this.categoryRows();
    const created = new Map<string, string>();
    const real = (id: string): string => {
      if (!id.startsWith("new:")) return id;
      const found = created.get(id.slice("new:".length));
      if (found === undefined) throw noCategory();
      return found;
    };
    const realOrNull = (id: string | null): string | null => (id === null ? null : real(id));
    const main = this.groupRows().find((row) => row.name === null);
    for (const { key, groupId, parentId } of arrangement.create) {
      if (created.has(key)) {
        throw new CategoryRefused("invalid_request", "Two new categories have the same key.");
      }
      // Its name and place may be free only after the changes; until then it has neither. One
      // with a parent goes to that one's group.
      const group = groupId ?? ((parentId ?? null) === null ? undefined : main?.id);
      created.set(key, this.createCategory(group, { name: `\u0000${randomUUID()}` }));
    }
    for (const one of [
      ...arrangement.create.map((entry) => ({ ...entry, id: `new:${entry.key}` })),
      ...arrangement.categories,
    ]) {
      if (one.logoFrom === undefined) continue;
      const logo = this.category(real(one.logoFrom)).logo_id;
      this.db.run("update category set logo_id = ? where id = ?", [logo, real(one.id)]);
    }
    this.updateAll([
      ...arrangement.create.map(({ key, parentId, groupId, ...look }) => ({
        ...look,
        id: real(`new:${key}`),
        ...(groupId === undefined ? {} : { groupId }),
        parentId: realOrNull(parentId ?? null),
      })),
      ...arrangement.categories.map(({ parentId, ...change }) => ({
        ...change,
        id: real(change.id),
        ...(parentId === undefined ? {} : { parentId: realOrNull(parentId) }),
      })),
    ]);
    for (const { groupId, parentId, ids } of arrangement.order) {
      this.orderCategories(groupId, ids.map(real), realOrNull(parentId));
    }
    const state: UndoState = { rows, created: [...created.values()] };
    this.db.run("delete from category_undo");
    this.db.run("insert into category_undo (token, revision, state_json) values (?, ?, ?)", [
      randomUUID(),
      // Of the setup this is becoming.
      this.revision + 1,
      JSON.stringify(state),
    ]);
    return Object.fromEntries(created);
  }

  /** What takes the last arrangement back; null once something else changed. */
  undoToken(): string | null {
    return (
      this.db.get<{ token: string }>("select token from category_undo where revision = ?", [
        this.revision,
      ])?.token ?? null
    );
  }

  undo(token: string): void {
    if (token !== this.undoToken()) {
      throw new CategoryRefused("conflict", "The categories changed, so this cannot be undone.");
    }
    const row = this.db.get<{ state_json: string }>(
      "select state_json from category_undo where token = ?",
      [token],
    );
    const state = JSON.parse(row?.state_json ?? "") as UndoState;
    const now = new Map(this.categoryRows().map((one) => [one.id, one]));
    // The old names may be those of the new ones.
    for (const id of state.created) this.removeCategory(id, null);
    this.rename(new Map(state.rows.map(({ id, name }) => [id, name])));
    for (const old of state.rows) {
      const was = now.get(old.id);
      if (was?.parent_id !== old.parent_id || was.group_id !== old.group_id) this.asks = true;
      this.db.run(
        `update category set group_id = ?, parent_id = ?, position = ?, icon = ?, color = ?,
           rule_json = ?, logo_id = ? where id = ?`,
        [
          old.group_id,
          old.parent_id,
          old.position,
          old.icon,
          old.color,
          old.rule_json,
          old.logo_id,
          old.id,
        ],
      );
    }
    this.db.run("delete from category_undo");
  }

  /**
   * Removes a category. Titles put in it by hand go back to their folder's category, or
   * keep the others they were given. Categories inside it take its place.
   *
   * @param foldersTo where its folders go; `undefined` is only fine when it has none
   */
  deleteCategory(id: string, foldersTo: string | null | undefined): void {
    const row = this.category(id);
    const folders = this.db.all<{ id: string }>("select id from source where category_id = ?", [
      id,
    ]);
    if (folders.length > 0) {
      if (foldersTo === undefined || foldersTo === id) {
        throw new CategoryRefused("invalid_request", "Say which category its folders go to.");
      }
      if (foldersTo !== null) this.careful(this.category(foldersTo));
    }
    this.careful(row);
    const rows = this.categoryRows();
    const inside = rows.filter((one) => one.parent_id === id);
    if (inside.length > 0) {
      const around = rows
        .filter((one) => one.parent_id === null && one.group_id === row.group_id)
        .flatMap((one) => (one.id === id ? inside : [one]));
      around.forEach((one, index) => {
        this.db.run("update category set parent_id = null, position = ? where id = ?", [
          index,
          one.id,
        ]);
      });
    }
    this.removeCategory(id, foldersTo ?? null);
  }

  private removeCategory(id: string, foldersTo: string | null): void {
    this.careful(this.category(id));
    this.touchTitles(id);
    this.db.run("update source set category_id = ? where category_id = ?", [foldersTo, id]);
    for (const item of this.db.all<{ id: string; override_json: string }>(
      `select id, override_json from item where exists (
         select 1 from json_each(item.override_json, '$.categoryIds') where value = ?)`,
      [id],
    )) {
      const overrides = JSON.parse(item.override_json) as Record<string, unknown>;
      const left = (overrides["categoryIds"] as string[]).filter((one) => one !== id);
      if (left.length > 0) overrides["categoryIds"] = left;
      else delete overrides["categoryIds"];
      this.saveOverrides(item.id, overrides);
      this.db.run("update item set edit_revision = edit_revision + 1 where id = ?", [item.id]);
    }
    this.db.run("delete from category where id = ?", [id]);
  }

  /**
   * Makes several categories one: their folders feed it, the titles put in them by hand are in
   * it, their studios join its rule and the categories inside them go inside it. Then they are
   * gone. It keeps its name, place and look; without a logo it takes the first one's. No title
   * is removed. A kids viewer allowed it sees what they brought, so this is always asked about.
   *
   * @param ids the ones that go, each once, not `into`
   */
  merge(into: string, ids: string[]): void {
    const target = this.category(into);
    if (ids.length === 0 || new Set(ids).size !== ids.length || ids.includes(into)) {
      throw new CategoryRefused(
        "invalid_request",
        `"ids" must name other categories than the one they go into, each once.`,
      );
    }
    const going = ids.map((id) => this.category(id));
    if (target.parent_id !== null && going.some((row) => row.id === target.parent_id)) {
      throw new CategoryRefused(
        "invalid_request",
        "A category cannot go into one that is inside it. Take that one out first.",
      );
    }
    const inside = this.categoryRows().filter(
      (row) => row.parent_id !== null && ids.includes(row.parent_id) && !ids.includes(row.id),
    );
    if (inside.length > 0 && target.parent_id !== null) throw oneLevel();
    const studios = new Set(readRule(target.rule_json)?.studioIds ?? []);
    for (const row of going) {
      for (const studio of readRule(row.rule_json)?.studioIds ?? []) studios.add(studio);
    }
    if (studios.size > MAX_RULE_STUDIOS) {
      throw new CategoryRefused(
        "invalid_request",
        `Together they follow more than ${MAX_RULE_STUDIOS} studios, which is more than one category can.`,
      );
    }
    // Whatever was allowed or blocked, it is about kids viewers.
    this.asks = true;
    this.careful(target);
    for (const row of going) this.careful(row);
    if (inside.length > 0) {
      this.place(inside.map((row) => ({ id: row.id, parentId: into })));
    }
    if (studios.size > 0) {
      this.decorate("category", into, { rule: { studioIds: [...studios].sort() } });
    }
    if (target.logo_id === null) {
      const logo = going.find((row) => row.logo_id !== null)?.logo_id ?? null;
      if (logo !== null) this.db.run("update category set logo_id = ? where id = ?", [logo, into]);
    }
    for (const row of going) {
      // Titles put in it by hand are in the one it goes into instead, once.
      for (const item of this.db.all<{ id: string; override_json: string }>(
        `select id, override_json from item where exists (
           select 1 from json_each(item.override_json, '$.categoryIds') where value = ?)`,
        [row.id],
      )) {
        const overrides = JSON.parse(item.override_json) as Record<string, unknown>;
        const chosen = overrides["categoryIds"] as string[];
        overrides["categoryIds"] = [...new Set(chosen.map((one) => (one === row.id ? into : one)))];
        this.saveOverrides(item.id, overrides);
        this.db.run("update item set edit_revision = edit_revision + 1 where id = ?", [item.id]);
      }
      this.removeCategory(row.id, into);
    }
    this.touchTitles(into);
  }

  assignFolder(sourceId: string, categoryId: string | null): void {
    const source = this.db.get<{ category_id: string | null }>(
      "select category_id from source where id = ?",
      [sourceId],
    );
    if (!source) throw new CategoryRefused("not_found", "There is no such folder.");
    if (categoryId !== null) this.careful(this.category(categoryId));
    if (source.category_id !== null) this.careful(this.category(source.category_id));
    this.db.run("update source set category_id = ?, category_seeded = 1 where id = ?", [
      categoryId,
      sourceId,
    ]);
    this.touchFolder(sourceId);
  }

  // Logos

  /** Gives a category or group a logo whose picture is here already. */
  setLogo(
    owner: Owner,
    id: string,
    logo: (LogoInfo & { remotePath: string | null; data: Uint8Array }) | null,
  ): void {
    this.require(owner, id);
    if (logo) {
      this.db.run(
        `insert into logo (id, remote_path, data, width, height, transparent) values (?, ?, ?, ?, ?, ?)
         on conflict (id) do update set data = coalesce(logo.data, excluded.data),
           width = coalesce(logo.width, excluded.width), height = coalesce(logo.height, excluded.height)`,
        [logo.id, logo.remotePath, logo.data, logo.width, logo.height, logo.transparent ? 1 : 0],
      );
    }
    this.db.run(`update ${owner} set logo_id = ? where id = ?`, [logo?.id ?? null, id]);
  }

  require(owner: Owner, id: string): void {
    if (owner === "category") this.category(id);
    else this.group(id);
  }

  private dropUnusedLogos(): void {
    this.db.run(
      `delete from logo where id not in (
         select logo_id from category where logo_id is not null
         union select logo_id from category_group where logo_id is not null)`,
    );
  }

  // Helpers

  private group(id: string): GroupRow {
    const row = this.db.get<GroupRow>("select * from category_group where id = ?", [id]);
    if (!row) throw new CategoryRefused("not_found", "There is no such part of the library.");
    return row;
  }

  private category(id: string): CategoryRow {
    const row = this.db.get<CategoryRow>("select * from category where id = ?", [id]);
    if (!row) throw noCategory();
    return row;
  }

  /** Notes that the change is about nested or blocked categories: kids are asked about first. */
  private careful(row: CategoryRow): void {
    this.asks ||=
      row.parent_id !== null ||
      this.db.get("select 1 as x from category where parent_id = ?", [row.id]) !== undefined ||
      this.db.get(
        `select 1 as x from profile, json_each(profile.kids_json, '$.blockedCategoryIds')
         where profile.deleted_at is null and value = ?`,
        [row.id],
      ) !== undefined;
  }

  private decorate(owner: Owner, id: string, look: Look): void {
    if (look.icon !== undefined) {
      this.db.run(`update ${owner} set icon = ? where id = ?`, [look.icon, id]);
    }
    if (look.color !== undefined) {
      this.db.run(`update ${owner} set color = ? where id = ?`, [look.color, id]);
    }
    if (look.rule !== undefined && owner === "category") {
      const json = look.rule === null ? null : JSON.stringify(look.rule);
      if (this.category(id).rule_json === json) return;
      // What it took in, and what it takes in now.
      this.touchTitles(id);
      this.db.run("update category set rule_json = ? where id = ?", [json, id]);
      this.touchTitles(id);
      this.asks = true;
    }
  }

  private nextPosition(table: Owner): number {
    return (
      this.db.get<{ n: number }>(`select coalesce(max(position), -1) + 1 as n from ${table}`)?.n ??
      0
    );
  }

  private reorder(table: Owner, rows: { id: string }[], ids: string[]): void {
    const same = ids.length === rows.length && new Set(ids).size === ids.length;
    if (!same || !rows.every((row) => ids.includes(row.id))) {
      throw new CategoryRefused("invalid_request", `"ids" must hold each of them once.`);
    }
    ids.forEach((id, index) => {
      this.db.run(`update ${table} set position = ? where id = ?`, [index, id]);
    });
  }

  private refuseCategoryName(name: string, except: string | null): void {
    const taken = this.categoryRows().some(
      (row) => row.id !== except && nameKey(row.name) === nameKey(name),
    );
    if (taken) throw new CategoryRefused("invalid_request", "There is a category of that name.");
  }

  private refuseGroupName(name: string, except: string | null): void {
    const taken = this.groupRows().some(
      (row) => row.id !== except && row.name !== null && nameKey(row.name) === nameKey(name),
    );
    if (taken) throw new CategoryRefused("invalid_request", "There is a part of that name.");
  }

  private saveOverrides(itemId: string, overrides: Record<string, unknown>): void {
    this.db.run("update item set override_json = ? where id = ?", [
      Object.keys(overrides).length === 0 ? null : JSON.stringify(overrides),
      itemId,
    ]);
  }

  /**
   * Marks what is in a category as changed: by folder or by hand, with everything above and
   * below. A title that only might be in it is marked too; that costs a line in a sync.
   */
  private touchTitles(categoryId: string): void {
    this.touch(
      `select item_asset.item_id from item_asset join asset on asset.id = item_asset.asset_id
         join source on source.id = asset.source_id where source.category_id = ?1
       union select id from item where exists (
         select 1 from json_each(item.override_json, '$.categoryIds') where value = ?1)
       union select item_studio.item_id from category
         cross join json_each(category.rule_json, '$.studioIds') as wanted
         join item_studio on item_studio.studio_id = wanted.value where category.id = ?1`,
      categoryId,
    );
  }

  private touchFolder(sourceId: string): void {
    this.touch(
      `select item_asset.item_id from item_asset join asset on asset.id = item_asset.asset_id
       where asset.source_id = ?1`,
      sourceId,
    );
  }

  private touch(select: string, value: string): void {
    const revision = this.db.nextRevision();
    this.db.run(
      `with recursive start (id) as (${select}),
         up (id) as (
           select id from start
           union select item.parent_id from item join up on item.id = up.id
             where item.parent_id is not null),
         down (id) as (
           select id from start
           union select item.id from item join down on item.parent_id = down.id)
       update item set revision = ?2 where id in (select id from up union select id from down)`,
      [value, revision],
    );
  }

  // Taking over from the config

  /**
   * Gives every folder the catalogue does not know yet the category the config names. The
   * config counts once per folder; what managers do afterwards is kept here.
   */
  seed(roots: RootConfig[]): void {
    this.db.transaction(() => {
      if (!this.groupRows().some((row) => row.name === null)) {
        this.db.run("insert into category_group (id, name, position) values (?, null, -1)", [
          randomUUID(),
        ]);
      }
      const fresh = new Set<string>();
      let changed = false;
      let ignored = false;
      for (const root of roots) {
        const source = this.db.get<{ id: string; category_seeded: number; name: string | null }>(
          `select source.id, source.category_seeded, category.name from source
           left join category on category.id = source.category_id where source.path = ?`,
          [root.path],
        );
        if (!source) continue;
        if (source.category_seeded === 1) {
          ignored ||= this.differs(source.name, root);
          continue;
        }
        this.db.run("update source set category_id = ?, category_seeded = 1 where id = ?", [
          this.seedCategory(root, fresh),
          source.id,
        ]);
        this.touchFolder(source.id);
        changed = true;
      }
      // A folder that is no longer in the config, with titles that still know their category.
      for (const source of this.db.all<{ id: string; name: string }>(
        "select id, name from source where category_seeded = 0",
      )) {
        const known = this.categoryRows().find((row) => nameKey(row.name) === nameKey(source.name));
        if (!known) continue;
        this.db.run("update source set category_id = ?, category_seeded = 1 where id = ?", [
          known.id,
          source.id,
        ]);
      }
      changed = this.adoptNamedOverrides() || changed;
      if (changed) {
        this.db.setMeta(REVISION, String(this.revision + 1));
        this.db.nextRevision();
      }
      if (ignored) {
        log.info(
          "Categories are set up in the apps; the names, groups and logos of known folders in the config are ignored",
        );
      }
    });
  }

  private seedCategory(root: RootConfig, fresh: Set<string>): string {
    const known = this.categoryRows().find((row) => nameKey(row.name) === nameKey(root.name));
    if (known) {
      // Two new folders of one category: the last logo named counts, as it did in the config.
      if (root.logo && fresh.has(known.id)) this.seedLogo(known.id, root.logo);
      return known.id;
    }
    const wanted = root.group?.trim() ?? "";
    const groups = this.groupRows();
    const group = groups.find((row) =>
      wanted === ""
        ? row.name === null
        : row.name !== null && nameKey(row.name) === nameKey(wanted),
    );
    const id = this.createCategory(group?.id ?? this.createGroup({ name: wanted }), {
      name: root.name,
    });
    fresh.add(id);
    if (root.logo) this.seedLogo(id, root.logo);
    return id;
  }

  private seedLogo(categoryId: string, remotePath: string): void {
    const id = basename(remotePath, ".png");
    // The picture itself is fetched by the logo store; until then there is no logo.
    this.db.run("insert into logo (id, remote_path) values (?, ?) on conflict (id) do nothing", [
      id,
      remotePath,
    ]);
    this.db.run("update category set logo_id = ? where id = ?", [id, categoryId]);
  }

  private differs(categoryName: string | null, root: RootConfig): boolean {
    if (categoryName !== root.name) return true;
    const row = this.db.get<{ group_name: string | null; logo_id: string | null }>(
      `select category_group.name as group_name, category.logo_id from category
       join category_group on category_group.id = category.group_id where category.name = ?`,
      [root.name],
    );
    return (
      (row?.group_name ?? null) !== (root.group ?? null) ||
      (root.logo != null && row?.logo_id !== basename(root.logo, ".png"))
    );
  }

  /** Titles that were put in categories by name, before categories had ids. */
  private adoptNamedOverrides(): boolean {
    const items = this.db.all<{ id: string; override_json: string }>(
      "select id, override_json from item where json_extract(override_json, '$.categories') is not null",
    );
    if (items.length === 0) return false;
    const ids = new Map(this.categoryRows().map((row) => [row.name, row.id]));
    const revision = this.db.nextRevision();
    for (const item of items) {
      const { categories, ...others } = JSON.parse(item.override_json) as Record<string, unknown>;
      const found = (categories as string[])
        .map((name) => ids.get(name))
        .filter((id): id is string => id !== undefined);
      this.saveOverrides(item.id, found.length > 0 ? { ...others, categoryIds: found } : others);
      this.db.run("update item set revision = ? where id = ?", [revision, item.id]);
    }
    return true;
  }
}
