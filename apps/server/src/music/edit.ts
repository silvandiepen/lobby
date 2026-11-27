// SPDX-License-Identifier: MPL-2.0
import type { Hono } from "hono";
import type { Database } from "../db/database.ts";
import { ApiError, readBody, type AppEnv, type Ctx } from "../http/app.ts";
import { parseTags, VARIOUS_ARTISTS } from "./catalogue.ts";
import type { MusicLibrary } from "./library.ts";
import { sortKey } from "./names.ts";
import { splitArtists, withOverrides } from "./tags.ts";
import { EDIT_FIELDS, readMusicOverrides, type MusicKind, type MusicOverrides } from "./types.ts";

const KINDS: Record<string, MusicKind> = {
  artists: "artist",
  albums: "album",
  tracks: "track",
  books: "book",
};

interface Row extends Record<string, string | number | null> {
  id: string;
  override_json: string | null;
  edit_revision: number;
}

const invalid = (message: string): ApiError => new ApiError("invalid_request", message);

function line(value: unknown, field: string): string {
  const text = typeof value === "string" ? value.trim() : "";
  if (text === "" || text.length > 300 || /\p{Cc}/u.test(text)) {
    throw invalid(`"${field}" must be one line of 1 to 300 characters.`);
  }
  return text;
}

function lines(value: unknown, field: string, max: number): string[] {
  if (!Array.isArray(value) || value.length > max) {
    throw invalid(`"${field}" must be a list of at most ${max} names.`);
  }
  return [...new Set(value.map((one) => line(one, field)))];
}

function whole(value: unknown, field: string, min: number, max: number): number | null {
  if (value === null) return null;
  if (typeof value !== "number" || !Number.isInteger(value) || value < min || value > max) {
    throw invalid(`"${field}" must be a whole number from ${min} to ${max}, or null.`);
  }
  return value;
}

/** Checks one changed field. Every kind uses the same rules for a field of the same name. */
function checked(field: string, value: unknown): MusicOverrides {
  switch (field) {
    case "title":
    case "sortTitle":
    case "name":
    case "sortName":
      return { [field]: line(value, field) };
    case "artists":
    case "albumArtists":
    case "composers":
    case "authors":
    case "narrators":
    case "genres":
      return { [field]: lines(value, field, 20) };
    case "album":
    case "series":
      return { [field]: value === null ? null : line(value, field) };
    case "disc":
      return { disc: whole(value, field, 1, 999) };
    case "track":
      return { track: whole(value, field, 1, 9999) };
    case "year":
      return { year: whole(value, field, 1000, 2200) };
    case "compilation":
      if (typeof value !== "boolean") throw invalid(`"compilation" must be true or false.`);
      return { compilation: value };
    case "seriesPosition":
      if (value === null) return { seriesPosition: null };
      if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > 9999) {
        throw invalid(`"seriesPosition" must be a number from 0 to 9999, or null.`);
      }
      return { seriesPosition: value };
    case "description":
      if (value === null) return { description: null };
      if (typeof value !== "string" || value.length > 10_000) {
        throw invalid(`"description" must be text of at most 10000 characters, or null.`);
      }
      return { description: value.trim() === "" ? null : value.trim() };
    default:
      throw invalid(`"${field}" cannot be changed here.`);
  }
}

/** Managers change how music is described. The files are not touched, ever. */
export function registerMusicEditRoutes(
  app: Hono<AppEnv>,
  deps: {
    db: Database;
    music: MusicLibrary;
    /** Refuses viewers; gives the manager's device. */
    requireManager: (c: Ctx) => string;
    changed: (by: string, kind: MusicKind, id: string) => void;
  },
): void {
  const { db, music } = deps;
  const { reader, catalogue } = music;

  const find = (kind: MusicKind, id: string): Row => {
    const row = db.get<Row>(`select * from music_${kind} where id = ?`, [id]);
    if (!row || reader.kindOf(id) !== kind) {
      throw new ApiError("not_found", "That is no longer in the library.");
    }
    return row;
  };

  const automatic = (kind: MusicKind, row: Row): Record<string, unknown> => {
    const text = (column: string): unknown => row[column];
    const list = (column: string): unknown => JSON.parse(String(row[column])) as unknown;
    switch (kind) {
      case "artist":
        return { name: text("name"), sortName: text("sort_name") };
      case "album": {
        const credit = String(row["artist_credit"]);
        return {
          title: text("title"),
          sortTitle: text("sort_title"),
          artists: credit === VARIOUS_ARTISTS || credit === "" ? [] : splitArtists(credit),
          year: text("year"),
          genres: list("genres_json"),
          compilation: row["compilation"] === 1,
        };
      }
      case "book":
        return {
          title: text("title"),
          sortTitle: text("sort_title"),
          authors: list("authors_json"),
          narrators: list("narrators_json"),
          series: text("series"),
          seriesPosition: text("series_position"),
          year: text("year"),
          genres: list("genres_json"),
          description: text("description"),
        };
      case "track":
        return trackFields(parseTags(row["tags_json"] as string | null));
    }
  };

  const trackFields = (tags: ReturnType<typeof parseTags>): Record<string, unknown> => ({
    title: tags.title,
    sortTitle: tags.titleSort ?? sortKey(tags.title),
    artists: tags.artists,
    album: tags.album,
    albumArtists: tags.albumArtists,
    compilation: tags.compilation,
    disc: tags.disc,
    track: tags.track,
    year: tags.year,
    genres: tags.genres,
    composers: tags.composers,
  });

  const item = (kind: MusicKind, id: string): Record<string, unknown> => {
    const [one] =
      kind === "artist"
        ? reader.artists([id])
        : kind === "album"
          ? reader.albums([id])
          : kind === "book"
            ? reader.books([id])
            : reader.tracks([id]);
    return { ...one };
  };

  const view = (kind: MusicKind, id: string): Record<string, unknown> => {
    const row = find(kind, id);
    const changes = readMusicOverrides(row.override_json) as Record<string, unknown>;
    const values = automatic(kind, row);
    const current =
      kind === "track"
        ? trackFields(
            withOverrides(
              parseTags(row["tags_json"] as string | null),
              readMusicOverrides(row.override_json),
            ),
          )
        : values;
    return {
      kind,
      item: item(kind, id),
      revision: row.edit_revision,
      fields: Object.fromEntries(
        EDIT_FIELDS[kind].map((field) => [
          field,
          {
            automatic: values[field],
            overridden: changes[field] !== undefined,
            override: changes[field] ?? null,
            effective: changes[field] !== undefined ? changes[field] : current[field],
          },
        ]),
      ),
    };
  };

  for (const [plural, kind] of Object.entries(KINDS)) {
    app.get(`/v1/music/${plural}/:id/edit`, (c) => {
      deps.requireManager(c);
      return c.json(view(kind, c.req.param("id")));
    });

    app.patch(`/v1/music/${plural}/:id`, async (c) => {
      const by = deps.requireManager(c);
      const id = c.req.param("id");
      find(kind, id);
      const body = await readBody(c);
      const revision = body["revision"];
      if (typeof revision !== "number" || !Number.isInteger(revision) || revision < 0) {
        throw invalid(`"revision" must be the revision that was read.`);
      }
      const set = body["set"] ?? {};
      const reset = body["reset"] ?? [];
      if (typeof set !== "object" || Array.isArray(set)) throw invalid(`"set" must be an object.`);
      if (!Array.isArray(reset)) throw invalid(`"reset" must be a list of fields.`);
      let changes: MusicOverrides = {};
      for (const [field, value] of Object.entries(set)) {
        if (!EDIT_FIELDS[kind].includes(field)) throw invalid(`"${field}" cannot be changed here.`);
        changes = { ...changes, ...checked(field, value) };
      }
      const back = new Set<string>();
      for (const field of reset as unknown[]) {
        if (typeof field !== "string" || !EDIT_FIELDS[kind].includes(field)) {
          throw invalid(`"reset" must be a list of fields.`);
        }
        if (field in changes) throw invalid(`"${field}" cannot be set and put back at once.`);
        back.add(field);
      }
      if (Object.keys(changes).length + back.size === 0)
        throw invalid("There is nothing to change.");

      catalogue.change(() => {
        const row = find(kind, id);
        if (row.edit_revision !== revision) {
          throw new ApiError("conflict", "Someone else changed this meanwhile.", view(kind, id));
        }
        const kept = Object.entries({
          ...readMusicOverrides(row.override_json),
          ...changes,
        }).filter(([field]) => !back.has(field));
        catalogue.applyOverrides(kind, id, Object.fromEntries(kept));
      });
      deps.changed(by, kind, id);
      return c.json(view(kind, id));
    });
  }
}
