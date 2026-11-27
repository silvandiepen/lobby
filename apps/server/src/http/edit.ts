// SPDX-License-Identifier: MPL-2.0
import { randomUUID } from "node:crypto";
import { realpath } from "node:fs/promises";
import { join, sep } from "node:path";
import type { Hono } from "hono";
import {
  PictureRefused,
  MAX_UPLOAD_BYTES,
  pictureFormat,
  type ChosenArtwork,
} from "../artwork/chosen.ts";
import type { Device } from "../auth/devices.ts";
import type { Database } from "../db/database.ts";
import {
  imagePath,
  ProviderUnavailable,
  type ArtworkKind,
  type Enricher,
  type ImageOwner,
  type TitleType,
} from "../enrich/index.ts";
import type { Catalogue } from "../library/catalogue.ts";
import type { Categories } from "../library/categories.ts";
import type { ApiItem, ItemReader } from "../library/items.ts";
import {
  editableFields,
  readOverrides,
  storedField,
  type EditableField,
  type Overrides,
} from "../library/overrides.ts";
import { log } from "../log.ts";
import { ApiError, readBody, type AppEnv, type Ctx } from "./app.ts";

export interface EditServices {
  catalogue: Catalogue;
  enricher: Enricher;
  chosen: ChosenArtwork;
}

interface EditDeps extends EditServices {
  db: Database;
  items: ItemReader;
  categories: Categories;
  now: () => number;
  requireManager: (c: Ctx, action: string) => Device;
}

interface Row {
  id: string;
  kind: string;
  parent_id: string | null;
  title: string;
  sort_title: string;
  year: number | null;
  season_number: number | null;
  episode_number: number | null;
  overview: string | null;
  match_status: string;
  tmdb_type: TitleType | null;
  tmdb_id: number | null;
  metadata_json: string | null;
  override_json: string | null;
  candidates_json: string | null;
  edit_revision: number;
}

interface ArtworkRow {
  id: string;
  kind: ArtworkKind;
  provider: string;
  remote_path: string | null;
  width: number | null;
  height: number | null;
  language: string | null;
  selected: number;
  locked: number;
}

const ARTWORK_KINDS: Record<string, ArtworkKind[]> = {
  movie: ["poster", "backdrop", "logo"],
  show: ["poster", "backdrop", "logo"],
  personal: ["poster", "backdrop", "logo"],
  season: ["poster"],
  episode: ["still"],
};
const SOURCES: Record<string, string> = {
  tmdb: "tmdb",
  frame: "frame",
  "chosen-frame": "frame",
  upload: "upload",
};
/** Chosen by a manager in the place of a logo: the title in words. */
const NO_PICTURE = "none";

const invalid = (message: string): ApiError => new ApiError("invalid_request", message);

/** Everything a manager can change about an item. Media files are only ever read. */
export function registerEditRoutes(app: Hono<AppEnv>, deps: EditDeps): void {
  const { db, items, catalogue, enricher, chosen } = deps;

  const manage = (c: Ctx): Row => {
    deps.requireManager(c, "change titles");
    return find(c.req.param("id") ?? "");
  };
  const find = (id: string): Row => {
    const row = db.get<Row>("select * from item where id = ?", [id]);
    if (!row) throw new ApiError("not_found", "That title is no longer in the library.");
    return row;
  };
  const readItem = (id: string): ApiItem => {
    const [item] = items.read([id]);
    if (!item) throw new ApiError("not_found", "That title is no longer in the library.");
    return item;
  };
  const checkRevision = (row: Row, revision: number): void => {
    if (row.edit_revision === revision) return;
    throw new ApiError("conflict", "Someone else changed this meanwhile.", editView(row.id));
  };
  const queryRevision = (c: Ctx): number => {
    const text = c.req.query("revision") ?? "";
    if (!/^\d{1,15}$/.test(text)) throw invalid(`"revision" must be the revision that was read.`);
    return Number(text);
  };
  const bodyRevision = (body: Record<string, unknown>): number => {
    const value = body["revision"];
    if (typeof value !== "number" || !Number.isInteger(value) || value < 0) {
      throw invalid(`"revision" must be the revision that was read.`);
    }
    return value;
  };

  /** Runs `work` as one change: refused when someone was first, seen by every app after. */
  const change = (
    id: string,
    revision: number,
    work: (row: Row, library: number) => void,
  ): void => {
    db.transaction(() => {
      const row = find(id);
      checkRevision(row, revision);
      const library = db.nextRevision();
      work(row, library);
      db.run("update item set edit_revision = edit_revision + 1 where id = ?", [id]);
      catalogue.touch(id, library);
    });
  };

  const fieldsOf = (row: Row, item: ApiItem): Record<string, unknown> => {
    const overrides = readOverrides(row.override_json);
    const automatic: Record<EditableField, unknown> = {
      title: row.title,
      sortTitle: row.sort_title,
      year: row.year,
      overview: row.overview,
      genres: db
        .all<{ name: string }>(
          "select genre.name from item_genre join genre on genre.id = item_genre.genre_id where item_id = ? order by genre.name",
          [row.id],
        )
        .map((one) => one.name),
      categories: items.automaticCategories(row.id).map((one) => one.name),
    };
    return Object.fromEntries(
      editableFields(row.kind).map((field) => [
        field,
        {
          automatic: automatic[field],
          overridden: overrides[storedField(field)] !== undefined,
          override:
            field === "categories"
              ? overrides.categoryIds === undefined
                ? null
                : item.categories
              : (overrides[field] ?? null),
          effective: item[field],
        },
      ]),
    );
  };

  const localArtwork = (itemId: string, kind: ArtworkKind): Record<string, unknown>[] =>
    db
      .all<ArtworkRow>(
        `select id, kind, provider, remote_path, width, height, language, selected, locked from artwork
         where item_id = ? and kind = ? and local_path is not null order by selected desc, rowid desc`,
        [itemId, kind],
      )
      .map((row) => ({
        source: SOURCES[row.provider] ?? row.provider,
        artworkId: row.id,
        path: row.provider === "tmdb" ? row.remote_path : null,
        previewUrl: `/v1/artwork/${row.id}?w=400`,
        width: row.width,
        height: row.height,
        language: row.language,
        selected: row.selected === 1,
        chosen: row.selected === 1 && row.locked === 1,
      }));

  const isWithoutLogo = (itemId: string): boolean =>
    db.get(
      "select 1 as x from artwork where item_id = ? and kind = 'logo' and provider = ? and selected = 1",
      [itemId, NO_PICTURE],
    ) !== undefined;

  const matchOf = (row: Row): Record<string, unknown> => {
    const review = row.candidates_json
      ? (JSON.parse(row.candidates_json) as { reason?: string; candidates?: unknown[] })
      : null;
    const metadata = JSON.parse(row.metadata_json ?? "{}") as { evidence?: string[] };
    return {
      status: row.match_status,
      chosen: row.match_status === "locked",
      tmdb:
        row.tmdb_id !== null && row.tmdb_type !== null
          ? { type: row.tmdb_type, id: row.tmdb_id }
          : null,
      canChange: row.kind === "movie" || row.kind === "show",
      available: enricher.isConfigured,
      reason: review?.reason ?? null,
      candidates: review?.candidates ?? [],
      evidence: metadata.evidence ?? [],
    };
  };

  const editView = (id: string): Record<string, unknown> => {
    const row = find(id);
    const item = readItem(id);
    const all = editableFields(row.kind).includes("categories") ? deps.categories.all() : [];
    return {
      item,
      revision: row.edit_revision,
      fields: fieldsOf(row, item),
      categoryNames: all.map((one) => one.name),
      categories: all,
      categoryIds: {
        automatic: items.automaticCategories(id).map((one) => one.id),
        overridden: readOverrides(row.override_json).categoryIds !== undefined,
        effective: item.categoryIds,
      },
      artwork: Object.fromEntries(
        (ARTWORK_KINDS[row.kind] ?? []).map((kind) => [kind, localArtwork(id, kind)]),
      ),
      withoutLogo: isWithoutLogo(id),
      match: matchOf(row),
    };
  };

  /** A picture, search or lookup that needs TMDB answers 503 when TMDB is away. */
  const fromTmdb = async <T>(work: () => Promise<T>): Promise<T> => {
    try {
      return await work();
    } catch (error) {
      if (!(error instanceof ProviderUnavailable)) throw error;
      throw new ApiError("unavailable", "TMDB cannot be reached right now.");
    }
  };

  // ---- Fields ----

  app.get("/v1/items/:id/edit", (c) => c.json(editView(manage(c).id)));

  app.patch("/v1/items/:id", async (c) => {
    const row = manage(c);
    const body = await readBody(c);
    const revision = bodyRevision(body);
    const allowed = editableFields(row.kind);
    const set = readSet(body["set"], allowed, deps.categories.all());
    const reset = readReset(body["reset"], allowed);
    const both = reset.find((field) => set[storedField(field)] !== undefined);
    if (both) throw invalid(`"${both}" cannot be set and put back at once.`);

    change(row.id, revision, (current, library) => {
      const overrides: Overrides = { ...readOverrides(current.override_json), ...set };
      // "delete" on the copy: a field that is put back is gone, not null.
      const kept = Object.fromEntries(
        Object.entries(overrides).filter(
          ([field]) => !reset.some((one) => storedField(one) === field),
        ),
      );
      db.run("update item set override_json = ? where id = ?", [
        Object.keys(kept).length === 0 ? null : JSON.stringify(kept),
        row.id,
      ]);
      if (set.categoryIds !== undefined || reset.includes("categories")) {
        catalogue.touchBelow(row.id, library);
      }
    });
    log.info("A manager changed a title", { by: c.get("device").id, item: row.id });
    return c.json(editView(row.id));
  });

  // ---- Artwork ----

  const kindFor = (row: Row, value: unknown): ArtworkKind => {
    const kinds = ARTWORK_KINDS[row.kind] ?? [];
    const kind = kinds.find((one) => one === value);
    if (!kind) {
      throw invalid(
        kinds.length === 0
          ? "This has no pictures to choose."
          : `"kind" must be one of: ${kinds.join(", ")}.`,
      );
    }
    return kind;
  };

  /** What TMDB calls this item, or null when it is not matched. */
  const ownerOf = (row: Row): ImageOwner | null => {
    if (row.tmdb_id === null || !["matched", "locked"].includes(row.match_status)) return null;
    if (row.kind === "movie") return { type: "movie", id: row.tmdb_id };
    if (row.kind === "show") return { type: "tv", id: row.tmdb_id };
    let show: Row | undefined = row;
    while (show && show.kind !== "show") {
      show = show.parent_id === null ? undefined : find(show.parent_id);
    }
    if (show?.tmdb_id == null || row.season_number === null) return null;
    const season = { type: "tv" as const, id: show.tmdb_id, season: row.season_number };
    if (row.kind === "season") return season;
    return row.episode_number === null ? null : { ...season, episode: row.episode_number };
  };

  app.get("/v1/items/:id/artwork-options", async (c) => {
    const row = manage(c);
    const kind = kindFor(row, c.req.query("kind"));
    const owner = ownerOf(row);
    let available = enricher.isConfigured;
    let remote: Awaited<ReturnType<Enricher["imageOptions"]>> = [];
    if (owner && available) {
      try {
        remote = await enricher.imageOptions(owner, kind);
      } catch (error) {
        // The pictures that are here can still be chosen.
        if (!(error instanceof ProviderUnavailable)) throw error;
        available = false;
      }
    }
    const local = localArtwork(row.id, kind);
    const here = new Set(local.map((one) => one["path"]));
    return c.json({
      kind,
      revision: find(row.id).edit_revision,
      tmdbAvailable: available,
      options: [
        ...local,
        ...remote
          .filter((one) => !here.has(one.path))
          .map((one) => ({
            source: "tmdb",
            artworkId: null,
            path: one.path,
            previewUrl: `/v1/items/${row.id}/artwork-options/preview?kind=${kind}&path=${encodeURIComponent(one.path)}`,
            width: one.width,
            height: one.height,
            language: one.language,
            selected: false,
            chosen: false,
          })),
      ],
    });
  });

  app.get("/v1/items/:id/artwork-options/preview", async (c) => {
    const row = manage(c);
    const kind = kindFor(row, c.req.query("kind"));
    const path = c.req.query("path") ?? "";
    if (!imagePath(kind, path)) throw invalid(`"path" must be a path from the options.`);
    const picture = await fromTmdb(() => enricher.preview(kind, path));
    const format = picture ? pictureFormat(picture) : null;
    if (!picture || format !== (kind === "logo" ? "png" : "jpeg")) {
      throw new ApiError("not_found", "TMDB does not have that picture.");
    }
    return c.body(picture, 200, {
      "Content-Type": `image/${format}`,
      "X-Content-Type-Options": "nosniff",
      "Cache-Control": "private, max-age=86400",
    });
  });

  const choose = (itemId: string, kind: ArtworkKind, artworkId: string): void => {
    db.run("update artwork set selected = 0, locked = 0 where item_id = ? and kind = ?", [
      itemId,
      kind,
    ]);
    db.run("update artwork set selected = 1, locked = 1 where id = ?", [artworkId]);
  };

  /** The file a frame is taken from: the one asked for, or the item's first. */
  const frameSource = async (
    row: Row,
    assetId: unknown,
    positionMs: unknown,
  ): Promise<{ path: string; asset: { id: string; revision: string }; positionMs: number }> => {
    if (typeof positionMs !== "number" || !Number.isInteger(positionMs) || positionMs < 0) {
      throw invalid(`"positionMs" must be a whole number of milliseconds.`);
    }
    if (assetId !== undefined && typeof assetId !== "string") {
      throw invalid(`"assetId" must be one of the title's files.`);
    }
    const asset = db.get<{
      id: string;
      revision: string;
      rel_path: string;
      source_path: string;
      duration_ms: number | null;
      reachable: number;
    }>(
      `with recursive tree (id) as (
         select ?1 union all select item.id from item join tree on item.parent_id = tree.id)
       select asset.id, asset.revision, asset.rel_path, asset.duration_ms, source.path as source_path,
         (asset.available = 1 and source.available = 1) as reachable
       from item_asset join asset on asset.id = item_asset.asset_id
       join source on source.id = asset.source_id join item on item.id = item_asset.item_id
       where item_asset.item_id in (select id from tree) and item_asset.role = 'main'
         and asset.state = 'probed' and (?2 is null or asset.id = ?2)
       order by coalesce(item.season_number, 9999) = 0, item.season_number, item.episode_number,
         item_asset.part, asset.rel_path limit 1`,
      [row.id, assetId ?? null],
    );
    if (!asset) throw new ApiError("not_found", "That file does not belong to this title.");
    if (asset.reachable !== 1) {
      throw new ApiError("unavailable", "The drive this file is on is not connected right now.");
    }
    if (asset.duration_ms !== null && positionMs >= asset.duration_ms) {
      throw invalid(`"positionMs" is after the end of the file.`);
    }
    let path: string;
    try {
      const root = await realpath(asset.source_path);
      path = await realpath(join(asset.source_path, asset.rel_path));
      if (!path.startsWith(root + sep)) throw new Error("outside the library folder");
    } catch {
      throw new ApiError("unavailable", "This file cannot be read right now.");
    }
    return { path, asset: { id: asset.id, revision: asset.revision }, positionMs };
  };

  app.post("/v1/items/:id/artwork", async (c) => {
    const row = manage(c);
    const body = await readBody(c);
    const revision = bodyRevision(body);
    checkRevision(row, revision);
    const kind = kindFor(row, body["kind"]);
    if (body["source"] === "existing") {
      const artworkId = body["artworkId"];
      if (typeof artworkId !== "string") throw invalid(`"artworkId" must be one from the options.`);
      change(row.id, revision, () => {
        const art = db.get(
          "select 1 as x from artwork where id = ? and item_id = ? and kind = ? and local_path is not null",
          [artworkId, row.id, kind],
        );
        if (!art) throw new ApiError("not_found", "That picture is no longer there.");
        choose(row.id, kind, artworkId);
      });
    } else if (body["source"] === "tmdb") {
      const path = body["path"];
      if (typeof path !== "string" || !imagePath(kind, path)) {
        throw invalid(`"path" must be a path from the options.`);
      }
      const added = await fromTmdb(() =>
        enricher.addImage(
          row.id,
          { kind, path, language: null, large: kind === "backdrop", anyShape: true },
          (artworkId) => {
            change(row.id, revision, () => {
              choose(row.id, kind, artworkId);
            });
          },
        ),
      );
      if (!added) throw new ApiError("not_found", "TMDB does not have that picture.");
    } else if (body["source"] === NO_PICTURE) {
      if (kind !== "logo") throw invalid("Only a logo can be left out.");
      change(row.id, revision, () => {
        db.run(
          `insert into artwork (id, item_id, kind, provider, remote_path) values (?, ?, ?, ?, ?)
           on conflict (item_id, kind, provider, remote_path) do nothing`,
          [randomUUID(), row.id, kind, NO_PICTURE, NO_PICTURE],
        );
        const none = db.get<{ id: string }>(
          "select id from artwork where item_id = ? and kind = ? and provider = ?",
          [row.id, kind, NO_PICTURE],
        );
        choose(row.id, kind, none?.id ?? "");
      });
    } else if (body["source"] === "frame") {
      if (kind === "logo") throw invalid("A logo cannot be made from a film.");
      const { path, asset, positionMs } = await frameSource(
        row,
        body["assetId"],
        body["positionMs"],
      );
      let made;
      try {
        made = await chosen.frame(path, asset, positionMs, kind);
      } catch {
        throw new ApiError("unavailable", "No picture could be read at that moment.");
      }
      change(row.id, revision, () => {
        choose(row.id, kind, chosen.save(row.id, kind, made));
      });
      await chosen.tidy(deps.now());
    } else {
      throw invalid(`"source" must be one of: tmdb, frame, existing, none.`);
    }
    log.info("A manager chose a picture", { by: c.get("device").id, item: row.id, kind });
    return c.json(editView(row.id));
  });

  app.post("/v1/items/:id/artwork/upload", async (c) => {
    const row = manage(c);
    const revision = queryRevision(c);
    checkRevision(row, revision);
    const kind = kindFor(row, c.req.query("kind"));
    const data = await readPicture(c);
    let made;
    try {
      made = await (kind === "logo" ? chosen.titleLogo(data) : chosen.upload(data));
    } catch (error) {
      if (error instanceof PictureRefused) throw invalid(error.message);
      throw error;
    }
    change(row.id, revision, () => {
      choose(row.id, kind, chosen.save(row.id, kind, made));
    });
    await chosen.tidy(deps.now());
    log.info("A manager chose a picture", { by: c.get("device").id, item: row.id, kind });
    return c.json(editView(row.id));
  });

  app.delete("/v1/items/:id/artwork", (c) => {
    const row = manage(c);
    const kind = kindFor(row, c.req.query("kind"));
    change(row.id, queryRevision(c), () => {
      catalogue.selectAutomaticArtwork(row.id, kind);
    });
    return c.json(editView(row.id));
  });

  // ---- Match ----

  const matchable = (row: Row): TitleType => {
    if (row.kind === "movie") return "movie";
    if (row.kind === "show") return "tv";
    throw invalid("Only a film or a series can be matched.");
  };

  app.get("/v1/items/:id/match", async (c) => {
    const row = manage(c);
    const type = matchable(row);
    const query = (c.req.query("query") ?? "").trim();
    if (query === "" || query.length > 200) throw invalid(`"query" must be a title.`);
    const yearText = c.req.query("year") ?? "";
    if (yearText !== "" && !/^\d{4}$/.test(yearText)) throw invalid(`"year" must be a year.`);
    const hits = await fromTmdb(() =>
      enricher.search(type, query, yearText === "" ? null : Number(yearText)),
    );
    return c.json({
      results: hits.slice(0, 20).map((hit) => ({
        tmdb: { type: hit.type, id: hit.id },
        title: hit.title,
        originalTitle: hit.originalTitle,
        year: hit.year,
        overview: hit.overview,
        previewUrl:
          hit.posterPath === null
            ? null
            : `/v1/items/${row.id}/artwork-options/preview?kind=poster&path=${encodeURIComponent(hit.posterPath)}`,
      })),
    });
  });

  /** Sets a title and everything that follows it back to what the files say. */
  const startOver = (
    row: Row,
    revision: number,
    status: "unmatched" | "locked",
    match: { tmdbType: TitleType; tmdbId: number } | null,
  ): void => {
    change(row.id, revision, (_current, library) => {
      for (const id of catalogue.followers(row.id)) {
        catalogue.forgetMatch(id, "unmatched", library);
      }
      catalogue.forgetMatch(row.id, status, library, match);
    });
  };

  app.put("/v1/items/:id/match", async (c) => {
    const row = manage(c);
    const type = matchable(row);
    const body = await readBody(c);
    const revision = bodyRevision(body);
    checkRevision(row, revision);
    const tmdbId = body["tmdbId"];
    if (body["tmdbType"] !== type) throw invalid(`"tmdbType" must be "${type}" for this title.`);
    if (typeof tmdbId !== "number" || !Number.isSafeInteger(tmdbId) || tmdbId < 1) {
      throw invalid(`"tmdbId" must be a TMDB id.`);
    }
    const details = await fromTmdb(() => enricher.details(type, tmdbId));
    if (!details) throw new ApiError("not_found", "TMDB does not have that title.");
    startOver(row, revision, "locked", { tmdbType: type, tmdbId });
    await enricher.enrichNow(row.id);
    log.info("A manager chose a match", { by: c.get("device").id, item: row.id });
    return c.json(editView(row.id));
  });

  app.delete("/v1/items/:id/match", (c) => {
    const row = manage(c);
    matchable(row);
    startOver(row, queryRevision(c), "locked", null);
    log.info("A manager said there is no match", { by: c.get("device").id, item: row.id });
    return c.json(editView(row.id));
  });

  app.post("/v1/items/:id/match/automatic", async (c) => {
    const row = manage(c);
    matchable(row);
    const body = await readBody(c);
    startOver(row, bodyRevision(body), "unmatched", null);
    // Without TMDB it simply waits for the next lookup.
    if (enricher.isConfigured) await enricher.enrichNow(row.id);
    return c.json(editView(row.id));
  });
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function readReset(value: unknown, allowed: EditableField[]): EditableField[] {
  if (value === undefined) return [];
  if (!Array.isArray(value)) throw invalid(`"reset" must be a list of fields.`);
  return (value as unknown[]).map((one) => {
    const field = allowed.find((name) => name === one);
    if (!field) throw invalid(`"reset" can hold: ${allowed.join(", ")}.`);
    return field;
  });
}

function readSet(
  value: unknown,
  allowed: EditableField[],
  categories: { id: string; name: string }[],
): Overrides {
  if (value === undefined) return {};
  if (!isObject(value)) throw invalid(`"set" must be an object.`);
  const takes = allowed.includes("categories") ? [...allowed, "categoryIds"] : allowed;
  const unknown = Object.keys(value).find((key) => !takes.includes(key));
  if (unknown !== undefined) throw invalid(`"set" can hold: ${allowed.join(", ")}.`);

  const result: Overrides = {};
  if (value["title"] !== undefined) result.title = line(value["title"], "title", 300);
  if (value["sortTitle"] !== undefined) {
    result.sortTitle = line(value["sortTitle"], "sortTitle", 300);
  }
  if (value["year"] !== undefined) {
    const year = value["year"];
    if (
      year !== null &&
      (typeof year !== "number" || !Number.isInteger(year) || year < 1850 || year > 2200)
    ) {
      throw invalid(`"year" must be a year or null.`);
    }
    result.year = year;
  }
  if (value["overview"] !== undefined) {
    const overview = value["overview"];
    if (overview !== null && (typeof overview !== "string" || overview.length > 10_000)) {
      throw invalid(`"overview" must be a text of at most 10000 characters or null.`);
    }
    result.overview = overview === null || overview.trim() === "" ? null : overview.trim();
  }
  if (value["genres"] !== undefined) result.genres = names(value["genres"], "genres", 20);
  if (value["categories"] !== undefined && value["categoryIds"] !== undefined) {
    throw invalid(`Send "categoryIds" or "categories", not both.`);
  }
  for (const [field, by] of [
    ["categoryIds", "id"],
    ["categories", "name"],
  ] as ["categoryIds" | "categories", "id" | "name"][]) {
    if (value[field] === undefined) continue;
    const wanted = names(value[field], field, 50);
    if (wanted.length === 0) throw invalid(`"${field}" must hold at least one category.`);
    result.categoryIds = wanted.map((one) => {
      const known = categories.find((category) => category[by] === one);
      if (!known) throw invalid(`"${field}" can only hold existing categories.`);
      return known.id;
    });
  }
  return result;
}

export function line(value: unknown, field: string, maxLength: number): string {
  if (typeof value !== "string" || value.trim() === "" || value.length > maxLength) {
    throw invalid(`"${field}" must be a text of 1 to ${maxLength} characters.`);
  }
  const text = value.trim();
  if (/\p{Cc}/u.test(text)) throw invalid(`"${field}" must be a single line.`);
  return text;
}

function names(value: unknown, field: string, most: number): string[] {
  if (!Array.isArray(value) || value.length > most) {
    throw invalid(`"${field}" must be a list of at most ${most} names.`);
  }
  return [...new Set((value as unknown[]).map((one) => line(one, field, 60)))];
}

/** The request's bytes, refused as soon as they are too many. */
export async function readPicture(c: Ctx): Promise<Uint8Array> {
  const tooLarge = (): ApiError =>
    invalid(`The picture is larger than ${MAX_UPLOAD_BYTES / 1024 / 1024} MB.`);
  if (Number(c.req.header("Content-Length") ?? "0") > MAX_UPLOAD_BYTES) throw tooLarge();
  const chunks: Uint8Array[] = [];
  let size = 0;
  const body = c.req.raw.body as ReadableStream<Uint8Array> | null;
  if (body) {
    for await (const chunk of body) {
      size += chunk.byteLength;
      if (size > MAX_UPLOAD_BYTES) throw tooLarge();
      chunks.push(chunk);
    }
  }
  return Buffer.concat(chunks);
}
