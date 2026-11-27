// SPDX-License-Identifier: MPL-2.0
import type { Hono } from "hono";
import type { Database } from "../db/database.ts";
import { PictureRefused, type ChosenArtwork } from "../artwork/chosen.ts";
import { LOGO_PATH, pngSize, type LogoStore } from "../artwork/logos.ts";
import type { Device } from "../auth/devices.ts";
import { ProviderUnavailable, type Enricher } from "../enrich/index.ts";
import type { KidsLimits } from "../kids/limits.ts";
import {
  Categories,
  CategoryRefused,
  COLORS,
  type Arrangement,
  type Look,
  type LogoInfo,
  type Owner,
  type Place,
} from "../library/categories.ts";
import {
  MAX_RULE_STUDIOS,
  STUDIO_ID,
  Studios,
  type CategoryRule,
  type Suggestion,
} from "../library/studios.ts";
import { errorMessage, log } from "../log.ts";
import { ApiError, readBody, type AppEnv, type Ctx } from "./app.ts";
import { line, readPicture } from "./edit.ts";

interface CategoryDeps {
  db: Database;
  categories: Categories;
  limits: KidsLimits;
  logos: LogoStore | undefined;
  /** Without these, logos cannot be searched for or uploaded. */
  enricher: Enricher | undefined;
  chosen: ChosenArtwork | undefined;
  requireManager: (c: Ctx, action: string) => Device;
}

/** What a request says about kids viewers. */
interface Ask {
  /** Only tell what would happen. */
  dryRun: boolean;
  /** From a dry run or a refusal: the manager agreed to exactly this. */
  kidsToken: string | null;
}

class DryRun extends Error {
  readonly answer: Record<string, unknown>;
  constructor(answer: Record<string, unknown>) {
    super("A dry run");
    this.answer = answer;
  }
}

class KidsRefused extends Error {
  readonly kids: Record<string, unknown>;
  constructor(message: string, kids: Record<string, unknown>) {
    super(message);
    this.kids = kids;
  }
}

/** SF Symbol names are words of letters and digits with dots between them. */
const ICON = /^[a-z0-9]+(?:\.[a-z0-9]+)*$/;

const invalid = (message: string): ApiError => new ApiError("invalid_request", message);

/** The household's categories, and everything a manager can change about them. */
export function registerCategoryRoutes(app: Hono<AppEnv>, deps: CategoryDeps): void {
  const { categories } = deps;

  const manage = (c: Ctx): void => {
    deps.requireManager(c, "change the categories");
  };
  const editView = (): Record<string, unknown> => ({
    ...categories.view(),
    folders: categories.folders(),
    colors: COLORS,
    undo: categories.undoToken(),
  });
  const refused = (error: CategoryRefused): ApiError =>
    new ApiError(error.code, error.message, error.code === "conflict" ? editView() : {});
  /**
   * Runs one change and answers with the setup as it is then, and what it means for kids
   * viewers. One about nested or blocked categories that lets a kids viewer see more is
   * refused until the manager was asked.
   */
  const change = (c: Ctx, revision: number, ask: Ask, work: () => unknown): Response => {
    const { limits } = deps;
    let answer: Record<string, unknown> = {};
    try {
      const before = limits.everyone();
      const epoch = limits.epoch;
      categories.change(
        revision,
        () => {
          const extra = work();
          if (typeof extra === "object" && extra !== null) answer = { ...extra };
        },
        () => {
          // Nothing that counts for limits was touched: nothing can be different.
          const kids = limits.changes(limits.epoch === epoch ? [] : before);
          const appears = kids.changes.some((one) => one.appearing.count > 0);
          const needsConfirmation = appears && categories.mustAsk;
          answer = { ...answer, kidsChanges: kids.changes, kidsToken: kids.token };
          if (ask.dryRun) {
            const would = { ...editView(), revision, undo: null };
            throw new DryRun({ ...would, ...answer, dryRun: true, needsConfirmation });
          }
          const asked = ask.kidsToken === null ? !needsConfirmation : ask.kidsToken === kids.token;
          if (!asked) {
            const names = kids.changes
              .filter((one) => one.appearing.count > 0)
              .map((one) => one.name)
              .join(", ");
            throw new KidsRefused(
              appears
                ? `This lets ${names} see more than now.`
                : "What this changes for kids viewers is different now.",
              { kidsChanges: kids.changes, kidsToken: kids.token },
            );
          }
        },
      );
    } catch (error) {
      if (error instanceof DryRun) return c.json(error.answer);
      if (error instanceof KidsRefused) {
        throw new ApiError("kids_confirmation", error.message, { ...editView(), ...error.kids });
      }
      if (error instanceof CategoryRefused) throw refused(error);
      throw error;
    }
    log.info("A manager changed the categories", { by: c.get("device").id });
    return c.json({ ...editView(), ...answer });
  };
  /** Before slow work, so nothing is fetched for a change that cannot be made. */
  const check = (revision: number, owner: Owner, id: string): void => {
    try {
      if (revision !== categories.revision) {
        throw new CategoryRefused("conflict", "Someone else changed the categories meanwhile.");
      }
      categories.require(owner, id);
    } catch (error) {
      if (error instanceof CategoryRefused) throw refused(error);
      throw error;
    }
  };

  app.get("/v1/categories", (c) => {
    const view = c.get("kids");
    return c.json(view ? deps.limits.categories(view, categories.view()) : categories.view());
  });

  app.get("/v1/logos/:id", (c) => {
    const logo = deps.logos?.read(c.req.param("id"));
    if (!logo) throw new ApiError("not_found", "There is no such logo.");
    return c.body(logo, 200, {
      "Content-Type": "image/png",
      "X-Content-Type-Options": "nosniff",
      "Cache-Control": "private, max-age=31536000, immutable",
    });
  });

  app.get("/v1/categories/edit", (c) => {
    manage(c);
    return c.json(editView());
  });

  // ---- Groups ----

  app.post("/v1/categories/groups", async (c) => {
    manage(c);
    const body = await readBody(c);
    const look = { ...readLook(body), name: readName(body) };
    return change(c, bodyRevision(body), bodyAsk(body), () => {
      categories.createGroup(look);
    });
  });

  app.put("/v1/categories/groups/order", async (c) => {
    manage(c);
    const body = await readBody(c);
    const ids = readIds(body);
    return change(c, bodyRevision(body), bodyAsk(body), () => {
      categories.orderGroups(ids);
    });
  });

  app.patch("/v1/categories/groups/:id", async (c) => {
    manage(c);
    const body = await readBody(c);
    const look = readLook(body);
    return change(c, bodyRevision(body), bodyAsk(body), () => {
      categories.updateGroup(c.req.param("id"), look);
    });
  });

  app.delete("/v1/categories/groups/:id", (c) => {
    manage(c);
    return change(c, queryRevision(c), queryAsk(c), () => {
      categories.deleteGroup(c.req.param("id"), c.req.query("moveTo") ?? null);
    });
  });

  // ---- Folders ----

  app.put("/v1/categories/folders/:id", async (c) => {
    manage(c);
    const body = await readBody(c);
    const categoryId = body["categoryId"];
    if (categoryId !== null && typeof categoryId !== "string") {
      throw invalid(`"categoryId" must be a category's id or null.`);
    }
    return change(c, bodyRevision(body), bodyAsk(body), () => {
      categories.assignFolder(c.req.param("id"), categoryId);
    });
  });

  // ---- Logos ----

  app.get("/v1/categories/logo-search", async (c) => {
    manage(c);
    const query = (c.req.query("query") ?? "").trim();
    if (query === "" || query.length > 100) throw invalid(`"query" must be a studio's name.`);
    const found = await fromTmdb(async () => {
      if (!deps.enricher) throw new ProviderUnavailable("There is no TMDB here.");
      return deps.enricher.searchLogos(query);
    });
    return c.json({
      results: found
        .filter((one) => LOGO_PATH.test(one.path))
        .slice(0, 20)
        .map((one) => ({
          ...one,
          previewUrl: `/v1/categories/logo-search/preview?path=${encodeURIComponent(one.path)}`,
        })),
    });
  });

  app.get("/v1/categories/logo-search/preview", async (c) => {
    manage(c);
    const path = readLogoPath(c.req.query("path"));
    return c.body(await remoteLogo(path), 200, {
      "Content-Type": "image/png",
      "X-Content-Type-Options": "nosniff",
      "Cache-Control": "private, max-age=86400",
    });
  });

  const remoteLogo = async (path: string): Promise<Uint8Array<ArrayBuffer>> => {
    if (!deps.logos) throw new ApiError("unavailable", "This server keeps no logos.");
    try {
      return await deps.logos.fetch(path);
    } catch (error) {
      log.warn("Could not fetch a logo", { error: errorMessage(error) });
      throw new ApiError("unavailable", "That logo cannot be fetched from TMDB right now.");
    }
  };

  for (const [owner, base] of [
    ["category_group", "/v1/categories/groups/:id/logo"],
    ["category", "/v1/categories/:id/logo"],
  ] as [Owner, string][]) {
    const idOf = (c: Ctx): string => c.req.param("id") ?? "";

    app.put(base, async (c) => {
      manage(c);
      const body = await readBody(c);
      const revision = bodyRevision(body);
      const path = readLogoPath(body["path"]);
      check(revision, owner, idOf(c));
      const data = await remoteLogo(path);
      const logo = { id: path.slice(1, -".png".length), ...pngSize(data), transparent: true };
      return change(c, revision, bodyAsk(body), () => {
        categories.setLogo(owner, idOf(c), { ...logo, remotePath: path, data });
      });
    });

    app.post(`${base}/upload`, async (c) => {
      manage(c);
      const revision = queryRevision(c);
      check(revision, owner, idOf(c));
      const { chosen } = deps;
      if (!chosen) throw new ApiError("unavailable", "This server takes no pictures.");
      const picture = await readPicture(c);
      let made: LogoInfo & { data: Uint8Array };
      try {
        made = await chosen.logo(picture);
      } catch (error) {
        if (error instanceof PictureRefused) throw invalid(error.message);
        throw error;
      }
      return change(c, revision, queryAsk(c), () => {
        categories.setLogo(owner, idOf(c), { ...made, remotePath: null });
      });
    });

    app.delete(base, (c) => {
      manage(c);
      return change(c, queryRevision(c), queryAsk(c), () => {
        categories.setLogo(owner, idOf(c), null);
      });
    });
  }

  // ---- Categories ----

  app.post("/v1/categories", async (c) => {
    manage(c);
    const body = await readBody(c);
    const { groupId, parentId } = readPlace(body);
    if (groupId === undefined && (parentId ?? null) === null) {
      throw invalid(`"groupId" must be a group's id.`);
    }
    const look = { ...readLook(body), name: readName(body) };
    return change(c, bodyRevision(body), bodyAsk(body), () => {
      categories.createCategory(groupId, look, parentId ?? null);
    });
  });

  app.put("/v1/categories/order", async (c) => {
    manage(c);
    const body = await readBody(c);
    const { groupId, parentId } = readPlace(body);
    if (groupId === undefined) throw invalid(`"groupId" must be a group's id.`);
    const ids = readIds(body);
    return change(c, bodyRevision(body), bodyAsk(body), () => {
      categories.orderCategories(groupId, ids, parentId);
    });
  });

  // ---- Studios ----

  const studios = new Studios(deps.db);
  const suggestion = (c: Ctx): Suggestion => {
    const found = studios.suggestions(1).find((one) => one.id === c.req.param("id"));
    if (!found) throw new ApiError("not_found", "There is no such suggestion.");
    return found;
  };
  const readMin = (c: Ctx): number => {
    const text = c.req.query("min") ?? String(SUGGEST_MIN);
    if (!/^\d{1,4}$/.test(text) || Number(text) < 1) {
      throw invalid(`"min" must be a whole number from 1.`);
    }
    return Number(text);
  };

  app.get("/v1/categories/suggestions", (c) => {
    manage(c);
    const min = readMin(c);
    return c.json({ min, suggestions: studios.suggestions(min) });
  });

  /** Joins studios to the rule a category has, or gives it one. */
  const joinRule = (categoryId: string, studioIds: string[]): void => {
    const had = categories.ruleOf(categoryId)?.studioIds ?? [];
    const joined = [...new Set([...had, ...studioIds])].sort();
    if (joined.length > MAX_RULE_STUDIOS) {
      throw new CategoryRefused(
        "invalid_request",
        `A category can follow at most ${String(MAX_RULE_STUDIOS)} studios.`,
      );
    }
    categories.updateCategory(categoryId, { rule: { studioIds: joined } });
  };
  /** A suggestion's logo from TMDB, or none when it cannot be fetched. */
  const studioLogo = async (
    path: string | null,
  ): Promise<(LogoInfo & { remotePath: string; data: Uint8Array }) | null> => {
    if (path === null || !deps.logos) return null;
    try {
      const data = await deps.logos.fetch(path);
      return {
        id: path.slice(1, -".png".length),
        ...pngSize(data),
        transparent: true,
        remotePath: path,
        data,
      };
    } catch (error) {
      // Without a logo it is a category all the same; one can be chosen later.
      log.warn("Could not fetch a studio's logo", { error: errorMessage(error) });
      return null;
    }
  };
  /** Before slow work, so nothing is fetched for a change that cannot be made. */
  const current = (revision: number): void => {
    if (revision !== categories.revision) {
      throw refused(
        new CategoryRefused("conflict", "Someone else changed the categories meanwhile."),
      );
    }
  };

  /**
   * A new category that follows the studios, or their studios joined to the rule of one that is
   * there already.
   */
  app.post("/v1/categories/suggestions/:id/accept", async (c) => {
    manage(c);
    const body = await readBody(c);
    const revision = bodyRevision(body);
    const found = suggestion(c);
    const studioIds = found.studios.map((one) => one.id);
    const existing = body["categoryId"];
    if (existing !== undefined) {
      if (typeof existing !== "string") throw invalid(`"categoryId" must be a category's id.`);
      return change(c, revision, bodyAsk(body), () => {
        joinRule(existing, studioIds);
        return { categoryId: existing };
      });
    }
    const { groupId, parentId } = readPlace(body);
    if (groupId === undefined && (parentId ?? null) === null) {
      throw invalid(`"groupId" must be a group's id.`);
    }
    const look = {
      ...readLook(body),
      name: body["name"] === undefined ? found.name : readName(body),
    };
    current(revision);
    const logo = await studioLogo(body["logo"] === false ? null : found.logoPath);
    return change(c, revision, bodyAsk(body), () => {
      const id = categories.createCategory(
        groupId,
        { ...look, rule: { studioIds: [...studioIds].sort() } },
        parentId ?? null,
      );
      if (logo) categories.setLogo("category", id, logo);
      return { categoryId: id };
    });
  });

  /**
   * Several suggestions in one place, as one change: joined to a category there is, as one new
   * category, or as a new category each.
   */
  app.post("/v1/categories/suggestions/accept", async (c) => {
    manage(c);
    const body = await readBody(c);
    const revision = bodyRevision(body);
    const wanted = readIds(body);
    if (wanted.length === 0 || new Set(wanted).size !== wanted.length) {
      throw invalid(`"ids" must name suggestions, each once.`);
    }
    const all = studios.suggestions(1);
    const found = wanted.map((id) => {
      const one = all.find((suggested) => suggested.id === id);
      if (!one) throw new ApiError("not_found", "There is no such suggestion.");
      return one;
    });
    const studioIds = found.flatMap((one) => one.studios.map((studio) => studio.id));
    const existing = body["categoryId"];
    if (existing !== undefined) {
      if (typeof existing !== "string") throw invalid(`"categoryId" must be a category's id.`);
      return change(c, revision, bodyAsk(body), () => {
        joinRule(existing, studioIds);
        return { categoryId: existing, categoryIds: [existing] };
      });
    }
    const { groupId, parentId } = readPlace(body);
    if (groupId === undefined && (parentId ?? null) === null) {
      throw invalid(`"groupId" must be a group's id.`);
    }
    const together = body["together"] ?? false;
    if (typeof together !== "boolean") throw invalid(`"together" must be true or false.`);
    if (body["name"] !== undefined && !together && found.length > 1) {
      throw invalid(`"name" is for one category: send "together": true.`);
    }
    const look = readLook(body);
    current(revision);
    const made = together
      ? [
          {
            name: body["name"] === undefined ? (found[0]?.name ?? "") : readName(body),
            studioIds,
            logoPath: found[0]?.logoPath ?? null,
          },
        ]
      : found.map((one) => ({
          name: body["name"] === undefined ? one.name : readName(body),
          studioIds: one.studios.map((studio) => studio.id),
          logoPath: one.logoPath,
        }));
    const logos = await Promise.all(
      made.map((one) => studioLogo(body["logo"] === false ? null : one.logoPath)),
    );
    return change(c, revision, bodyAsk(body), () => {
      const ids = made.map((one, index) => {
        const id = categories.createCategory(
          groupId,
          { ...look, name: one.name, rule: { studioIds: [...new Set(one.studioIds)].sort() } },
          parentId ?? null,
        );
        const logo = logos[index];
        if (logo) categories.setLogo("category", id, logo);
        return id;
      });
      return { categoryId: ids[0], categoryIds: ids };
    });
  });

  app.post("/v1/categories/suggestions/:id/dismiss", (c) => {
    manage(c);
    const min = readMin(c);
    studios.dismiss(suggestion(c).studios.map((one) => one.id));
    return c.json({ min, suggestions: studios.suggestions(min) });
  });

  app.post("/v1/categories/arrange", async (c) => {
    manage(c);
    const body = await readBody(c);
    const arrangement = readArrangement(body);
    return change(c, bodyRevision(body), bodyAsk(body), () => ({
      created: categories.arrange(arrangement),
    }));
  });

  /** Several categories become one: `ids` go into `into`. */
  app.post("/v1/categories/merge", async (c) => {
    manage(c);
    const body = await readBody(c);
    const into = body["into"];
    if (typeof into !== "string") throw invalid(`"into" must be a category's id.`);
    const ids = readIds(body);
    return change(c, bodyRevision(body), bodyAsk(body), () => {
      categories.merge(into, ids);
      return { categoryId: into };
    });
  });

  app.post("/v1/categories/arrange/undo", async (c) => {
    manage(c);
    const body = await readBody(c);
    const token = body["token"];
    if (typeof token !== "string") throw invalid(`"token" must be the token to undo with.`);
    return change(c, bodyRevision(body), bodyAsk(body), () => {
      categories.undo(token);
    });
  });

  app.patch("/v1/categories/:id", async (c) => {
    manage(c);
    const body = await readBody(c);
    const look = { ...readLook(body), ...readPlace(body) };
    return change(c, bodyRevision(body), bodyAsk(body), () => {
      categories.updateCategory(c.req.param("id"), look);
    });
  });

  app.delete("/v1/categories/:id", (c) => {
    manage(c);
    const target = c.req.query("foldersTo");
    return change(c, queryRevision(c), queryAsk(c), () => {
      categories.deleteCategory(c.req.param("id"), target === "none" ? null : target);
    });
  });
}

async function fromTmdb<T>(work: () => Promise<T>): Promise<T> {
  try {
    return await work();
  } catch (error) {
    if (!(error instanceof ProviderUnavailable)) throw error;
    throw new ApiError("unavailable", "TMDB cannot be reached right now.");
  }
}

function bodyRevision(body: Record<string, unknown>): number {
  const value = body["revision"];
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0) {
    throw invalid(`"revision" must be the revision that was read.`);
  }
  return value;
}

function queryRevision(c: Ctx): number {
  const text = c.req.query("revision") ?? "";
  if (!/^\d{1,15}$/.test(text)) throw invalid(`"revision" must be the revision that was read.`);
  return Number(text);
}

function bodyAsk(body: Record<string, unknown>): Ask {
  const dryRun = body["dryRun"] ?? false;
  if (typeof dryRun !== "boolean") throw invalid(`"dryRun" must be true or false.`);
  const kidsToken = body["kidsToken"] ?? null;
  if (kidsToken !== null && typeof kidsToken !== "string") {
    throw invalid(`"kidsToken" must be the token of what was asked.`);
  }
  return { dryRun, kidsToken };
}

function queryAsk(c: Ctx): Ask {
  const dryRun = c.req.query("dryRun") ?? "false";
  if (dryRun !== "true" && dryRun !== "false") throw invalid(`"dryRun" must be true or false.`);
  return { dryRun: dryRun === "true", kidsToken: c.req.query("kidsToken") ?? null };
}

function readLogoFrom(body: Record<string, unknown>): { logoFrom?: string } {
  const from = body["logoFrom"];
  if (from === undefined) return {};
  if (typeof from !== "string") throw invalid(`"logoFrom" must be a category's id.`);
  return { logoFrom: from };
}

function readRuleOf(body: Record<string, unknown>): { rule?: CategoryRule | null } {
  const rule = body["rule"];
  if (rule === undefined) return {};
  if (rule === null) return { rule: null };
  const ids = typeof rule === "object" ? (rule as Record<string, unknown>)["studioIds"] : null;
  if (
    !Array.isArray(ids) ||
    ids.length === 0 ||
    ids.length > MAX_RULE_STUDIOS ||
    !ids.every((id) => typeof id === "string" && STUDIO_ID.test(id))
  ) {
    throw invalid(`"rule" must be null or { "studioIds": ["company:1", "network:2", …] }.`);
  }
  return { rule: { studioIds: [...new Set(ids as string[])].sort() } };
}

function readPlace(body: Record<string, unknown>): Place {
  const { groupId, parentId } = body;
  if (groupId !== undefined && typeof groupId !== "string") {
    throw invalid(`"groupId" must be a group's id.`);
  }
  if (parentId !== undefined && parentId !== null && typeof parentId !== "string") {
    throw invalid(`"parentId" must be a category's id or null.`);
  }
  return {
    ...(groupId === undefined ? {} : { groupId }),
    ...(parentId === undefined ? {} : { parentId }),
  };
}

/** Fewer titles than this make a shelf, not a category. */
const SUGGEST_MIN = 8;

const MAX_ARRANGED = 500;
/** A key the app makes up for a category that is not there yet. */
const KEY = /^[A-Za-z0-9_-]{1,64}$/;

function readArrangement(body: Record<string, unknown>): Arrangement {
  const list = (name: string): Record<string, unknown>[] => {
    const value = body[name] ?? [];
    if (
      !Array.isArray(value) ||
      value.length > MAX_ARRANGED ||
      !value.every((one) => typeof one === "object" && one !== null && !Array.isArray(one))
    ) {
      throw invalid(`"${name}" must be a list.`);
    }
    return value as Record<string, unknown>[];
  };
  const create = list("create").map((one) => {
    const key = one["key"];
    if (typeof key !== "string" || !KEY.test(key)) {
      throw invalid(`"key" must be 1 to 64 letters, digits, "-" or "_".`);
    }
    return {
      ...readLook(one),
      ...readPlace(one),
      ...readLogoFrom(one),
      name: readName(one),
      key,
    };
  });
  const categories = list("categories").map((one) => {
    const id = one["id"];
    if (typeof id !== "string") throw invalid(`"id" must be a category's id.`);
    return { ...readLook(one), ...readPlace(one), ...readLogoFrom(one), id };
  });
  if (new Set(categories.map((one) => one.id)).size !== categories.length) {
    throw invalid(`"categories" can name each category once.`);
  }
  const order = list("order").map((one) => {
    const { groupId, parentId = null } = readPlace(one);
    if (groupId === undefined) throw invalid(`"groupId" must be a group's id.`);
    return { groupId, parentId, ids: readIds(one) };
  });
  if (create.length + categories.length + order.length === 0) {
    throw invalid("There is nothing to arrange.");
  }
  return { create, categories, order };
}

function readName(body: Record<string, unknown>): string {
  return line(body["name"], "name", 60);
}

function readLook(body: Record<string, unknown>): Look {
  const look: Look = { ...readRuleOf(body) };
  if (body["name"] !== undefined) look.name = readName(body);
  const icon = body["icon"];
  if (icon !== undefined) {
    if (icon !== null && (typeof icon !== "string" || icon.length > 64 || !ICON.test(icon))) {
      throw invalid(`"icon" must be the name of an SF Symbol or null.`);
    }
    look.icon = icon;
  }
  const color = body["color"];
  if (color !== undefined) {
    if (color !== null && !COLORS.some((one) => one === color)) {
      throw invalid(`"color" must be null or one of: ${COLORS.join(", ")}.`);
    }
    look.color = color as string | null;
  }
  return look;
}

function readIds(body: Record<string, unknown>): string[] {
  const ids = body["ids"];
  if (!Array.isArray(ids) || ids.length > 500 || !ids.every((id) => typeof id === "string")) {
    throw invalid(`"ids" must be a list of ids.`);
  }
  return ids;
}

function readLogoPath(value: unknown): string {
  if (typeof value !== "string" || !LOGO_PATH.test(value)) {
    throw invalid(`"path" must be a path from the search.`);
  }
  return value;
}
