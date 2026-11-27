// SPDX-License-Identifier: MPL-2.0
import type { Hono } from "hono";
import type { Database } from "../db/database.ts";
import { ApiError, readBody, type AppEnv, type Ctx } from "../http/app.ts";
import type { MusicLibrary } from "./library.ts";
import {
  MAX_PLAYLIST_TRACKS,
  MAX_PLAYLISTS,
  type Play,
  type Playlist,
  type PlaylistOutcome,
} from "./viewers.ts";

const ID = /^[A-Za-z0-9_-]{1,100}$/;
const MAX_PLAYS = 500;

const invalid = (message: string): ApiError => new ApiError("invalid_request", message);

function identifier(value: unknown, name: string): string {
  if (typeof value !== "string" || !ID.test(value)) throw invalid(`"${name}" is not a valid id.`);
  return value;
}

function count(value: unknown, name: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw invalid(`"${name}" must be a whole number that is not negative.`);
  }
  return value;
}

function flag(value: unknown, name: string): boolean {
  if (typeof value !== "boolean") throw invalid(`"${name}" must be true or false.`);
  return value;
}

function trackList(value: unknown): string[] {
  if (!Array.isArray(value) || value.length > MAX_PLAYLIST_TRACKS) {
    throw invalid(`"trackIds" must be a list of at most ${MAX_PLAYLIST_TRACKS} tracks.`);
  }
  return value.map((one) => identifier(one, "trackIds"));
}

function listName(value: unknown): string {
  const name = typeof value === "string" ? value.trim() : "";
  if (name === "" || name.length > 200 || /[\p{Cc}]/u.test(name)) {
    throw invalid(`"name" must be one line of 1 to 200 characters.`);
  }
  return name;
}

function queryCount(c: Ctx, name: string): number {
  const value = c.req.query(name) ?? "0";
  if (!/^\d{1,15}$/.test(value)) throw invalid(`"${name}" must be a revision number.`);
  return Number(value);
}

/** What each viewer keeps: favourites, playlists, history and their place in long pieces. */
export function registerMusicViewerRoutes(
  app: Hono<AppEnv>,
  deps: { db: Database; music: MusicLibrary },
): void {
  const { db, music } = deps;
  const { viewers, reader, progress } = music;
  const base = "/v1/music/profiles/:profile";

  const profileOf = (c: Ctx): string => {
    const id = c.req.param("profile") ?? "";
    if (!db.get("select 1 as x from profile where id = ? and deleted_at is null", [id])) {
      throw new ApiError("not_found", "There is no such viewer.");
    }
    return id;
  };

  // ---- Favourites ----

  app.get(`${base}/favourites`, (c) => {
    const profile = profileOf(c);
    const since = queryCount(c, "since");
    // Read first: a change made in between is sent again next time, never lost.
    const revision = viewers.revision;
    return c.json({ favourites: viewers.favourites(profile, since), revision });
  });

  app.put(`${base}/favourites/:item`, async (c) => {
    const profile = profileOf(c);
    const body = await readBody(c);
    const favourite = flag(body["favourite"], "favourite");
    const updatedAt = count(body["updatedAt"], "updatedAt");
    const kind = reader.kindOf(c.req.param("item"));
    if (!kind) throw new ApiError("not_found", "That is no longer in the library.");
    const result = viewers.setFavourite(profile, c.req.param("item"), kind, favourite, updatedAt);
    if (!result.accepted) {
      throw new ApiError("conflict", "This was changed more recently on another device.", {
        favourite: result.favourite,
      });
    }
    return c.json({ favourite: result.favourite });
  });

  // ---- Playlists ----

  const answer = (result: PlaylistOutcome): Playlist => {
    switch (result.outcome) {
      case "ok":
        return result.playlist;
      case "conflict":
        throw new ApiError("conflict", "This playlist was changed on another device.", {
          playlist: result.playlist,
        });
      case "unknown_track":
        throw invalid("A track in this list is no longer in the library.");
      case "too_many":
        throw new ApiError(
          "conflict",
          `A viewer can have ${MAX_PLAYLISTS} playlists, of ${MAX_PLAYLIST_TRACKS} tracks each.`,
        );
      case "not_found":
        throw new ApiError("not_found", "There is no such playlist.");
    }
  };

  app.get(`${base}/playlists`, (c) => {
    const profile = profileOf(c);
    const since = queryCount(c, "since");
    const revision = viewers.revision;
    return c.json({ ...viewers.playlists(profile, since), revision });
  });

  app.post(`${base}/playlists`, async (c) => {
    const profile = profileOf(c);
    const body = await readBody(c);
    const playlist = answer(
      viewers.create(
        profile,
        identifier(body["id"], "id"),
        listName(body["name"]),
        trackList(body["trackIds"] ?? []),
      ),
    );
    return c.json({ playlist }, 201);
  });

  app.get(`${base}/playlists/:id`, (c) => {
    const playlist = viewers.playlist(profileOf(c), c.req.param("id"));
    if (!playlist) throw new ApiError("not_found", "There is no such playlist.");
    return c.json({ playlist });
  });

  app.patch(`${base}/playlists/:id`, async (c) => {
    const profile = profileOf(c);
    const body = await readBody(c);
    const change = {
      ...(body["name"] === undefined ? {} : { name: listName(body["name"]) }),
      ...(body["trackIds"] === undefined ? {} : { trackIds: trackList(body["trackIds"]) }),
    };
    if (Object.keys(change).length === 0) throw invalid("There is nothing to change.");
    const revision = count(body["revision"], "revision");
    return c.json({
      playlist: answer(viewers.update(profile, c.req.param("id"), revision, change)),
    });
  });

  app.post(`${base}/playlists/:id/tracks`, async (c) => {
    const profile = profileOf(c);
    const body = await readBody(c);
    const tracks = trackList(body["trackIds"]);
    if (tracks.length === 0) throw invalid(`"trackIds" is empty.`);
    return c.json({
      playlist: answer(
        viewers.append(profile, c.req.param("id"), identifier(body["opId"], "opId"), tracks),
      ),
    });
  });

  app.delete(`${base}/playlists/:id`, (c) => {
    const profile = profileOf(c);
    if (c.req.query("revision") === undefined) throw invalid(`"revision" is missing.`);
    answer(viewers.remove(profile, c.req.param("id"), queryCount(c, "revision")));
    return c.body(null, 204);
  });

  app.get(`${base}/playlists/:id/export.m3u8`, (c) => {
    const playlist = viewers.playlist(profileOf(c), c.req.param("id"));
    if (!playlist) throw new ApiError("not_found", "There is no such playlist.");
    return c.body(viewers.exportM3u(playlist), 200, {
      "Content-Type": "application/vnd.apple.mpegurl; charset=UTF-8",
      "Content-Disposition": `attachment; filename="playlist.m3u8"; filename*=UTF-8''${encodeFileName(`${playlist.name}.m3u8`)}`,
      "Cache-Control": "no-store",
    });
  });

  // ---- History ----

  app.post(`${base}/plays`, async (c) => {
    const profile = profileOf(c);
    const body = await readBody(c);
    const list = body["plays"];
    if (!Array.isArray(list) || list.length > MAX_PLAYS) {
      throw invalid(`"plays" must be a list of at most ${MAX_PLAYS}.`);
    }
    const plays = list.map((one: unknown): Play => {
      if (typeof one !== "object" || one === null) throw invalid("A play must be an object.");
      const play = one as Record<string, unknown>;
      return {
        opId: identifier(play["opId"], "opId"),
        trackId: identifier(play["trackId"], "trackId"),
        playedAt: count(play["playedAt"], "playedAt"),
        playedMs: count(play["playedMs"], "playedMs"),
        completed: flag(play["completed"], "completed"),
      };
    });
    return c.json(viewers.addPlays(profile, plays));
  });

  app.get(`${base}/plays`, (c) => {
    const profile = profileOf(c);
    const limit = Number(c.req.query("limit") ?? "100");
    if (!Number.isInteger(limit) || limit < 1 || limit > 1000) {
      throw invalid(`"limit" must be a whole number from 1 to 1000.`);
    }
    const before = /^(\d{1,15})\.([A-Za-z0-9_-]{1,100})$/.exec(c.req.query("before") ?? "");
    if (c.req.query("before") !== undefined && !before) {
      throw invalid(`"before" must come from the previous answer.`);
    }
    const { plays, more } = viewers.plays(
      profile,
      before ? { playedAt: Number(before[1]), opId: before[2] ?? "" } : null,
      limit,
    );
    const last = plays.at(-1);
    return c.json({ plays, next: more && last ? `${last.playedAt}.${last.opId}` : null });
  });

  app.get(`${base}/play-counts`, (c) => c.json({ counts: viewers.playCounts(profileOf(c)) }));

  app.delete(`${base}/plays`, (c) => {
    viewers.clearPlays(profileOf(c));
    return c.body(null, 204);
  });

  // ---- Progress ----

  app.get(`${base}/progress`, (c) => {
    const profile = profileOf(c);
    const since = queryCount(c, "since");
    const revision = progress.revision;
    return c.json({ progress: progress.list(profile, since), revision });
  });

  app.put(`${base}/progress/:item`, async (c) => {
    const profile = profileOf(c);
    const body = await readBody(c);
    const result = progress.put(profile, c.req.param("item"), {
      opId: identifier(body["opId"], "opId"),
      baseRevision:
        body["baseRevision"] === null ? null : count(body["baseRevision"], "baseRevision"),
      positionMs: count(body["positionMs"], "positionMs"),
      durationMs: body["durationMs"] === null ? null : count(body["durationMs"], "durationMs"),
      completed: flag(body["completed"], "completed"),
      updatedAt: count(body["updatedAt"], "updatedAt"),
    });
    if (result.outcome === "not_found") {
      throw new ApiError("not_found", "There is no such track or book.");
    }
    if (result.outcome === "conflict") {
      throw new ApiError("conflict", "This was changed more recently on another device.", {
        progress: result.progress,
      });
    }
    return c.json({ progress: result.progress });
  });
}

/** For a header: only what RFC 5987 lets through unescaped, and no lone surrogates. */
function encodeFileName(name: string): string {
  return encodeURIComponent(name.toWellFormed().replaceAll("/", "-")).replace(
    /['()*]/g,
    (one) => `%${one.charCodeAt(0).toString(16).toUpperCase()}`,
  );
}
