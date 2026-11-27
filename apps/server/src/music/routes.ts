// SPDX-License-Identifier: MPL-2.0
import type { Hono } from "hono";
import { compress } from "hono/compress";
import type { Device } from "../auth/devices.ts";
import type { Database } from "../db/database.ts";
import { ApiError, readBody, type AppEnv, type Ctx } from "../http/app.ts";
import { openablePath, serveLibraryFile } from "../http/serve-file.ts";
import { log } from "../log.ts";
import { fileResponse } from "../playback/files.ts";
import { COMPACT_KBPS, isCompactAlready, type CompactKbps } from "./copies.ts";
import { registerMusicEditRoutes } from "./edit.ts";
import type { MusicLibrary } from "./library.ts";
import { extensionOf } from "../library/parse.ts";
import { registerMusicViewerRoutes } from "./viewer-routes.ts";

export interface MusicRouteDeps {
  db: Database;
  music: MusicLibrary;
  /** A cursor from another catalogue starts over. */
  catalogueId: string;
  requireManager: (c: Ctx, action: string) => Device;
}

interface FileRow {
  id: string;
  rel_path: string;
  size: number;
  mtime_ms: number;
  revision: string;
  container: string | null;
  duration_ms: number | null;
  bit_rate: number | null;
  lossless: number;
  playability: "direct" | "convert" | null;
  available: number;
  source_path: string;
  source_available: number;
}

const TYPES: Record<string, string> = {
  mp3: "audio/mpeg",
  m4a: "audio/mp4",
  m4b: "audio/mp4",
  mp4: "audio/mp4",
  alac: "audio/mp4",
  aac: "audio/aac",
  flac: "audio/flac",
  wav: "audio/wav",
  wave: "audio/wav",
  aif: "audio/aiff",
  aiff: "audio/aiff",
  aifc: "audio/aiff",
  caf: "audio/x-caf",
  ac3: "audio/ac3",
  eac3: "audio/eac3",
  ogg: "audio/ogg",
  oga: "audio/ogg",
  opus: "audio/ogg",
  wma: "audio/x-ms-wma",
  asf: "audio/x-ms-wma",
  mka: "audio/x-matroska",
};

/** By what is in the file, not by what it is called. */
function audioType(container: string | null, relPath: string): string {
  return TYPES[container ?? ""] ?? TYPES[extensionOf(relPath)] ?? "application/octet-stream";
}

function decodeCursor(
  catalogueId: string,
  cursor: string | undefined,
  current: number,
): { revision: number; id: string } | null | "reset" {
  if (cursor === undefined || cursor === "") return null;
  try {
    const parsed: unknown = JSON.parse(Buffer.from(cursor, "base64url").toString("utf8"));
    if (!Array.isArray(parsed)) return "reset";
    const [catalogue, kind, revision, id] = parsed as unknown[];
    if (catalogue !== catalogueId || kind !== "music" || typeof id !== "string") return "reset";
    // Later than now: the catalogue was put back from a backup.
    if (typeof revision !== "number" || !Number.isSafeInteger(revision) || revision > current) {
      return "reset";
    }
    return { revision, id };
  } catch {
    return "reset";
  }
}

export function registerMusicRoutes(app: Hono<AppEnv>, deps: MusicRouteDeps): void {
  const { db, music, catalogueId } = deps;
  const { reader, copies, covers } = music;

  // ---- The library ----

  app.use("/v1/music/library", compress());
  app.get("/v1/music/library", (c) => {
    const limit = Number(c.req.query("limit") ?? "500");
    if (!Number.isInteger(limit) || limit < 1 || limit > 1000) {
      throw new ApiError("invalid_request", `"limit" must be a whole number from 1 to 1000.`);
    }
    const decoded = decodeCursor(catalogueId, c.req.query("cursor"), music.catalogue.revision);
    const { next, ...page } = reader.page(decoded === "reset" ? null : decoded, limit);
    return c.json({
      ...page,
      cursor: Buffer.from(JSON.stringify([catalogueId, "music", next.revision, next.id])).toString(
        "base64url",
      ),
      reset: decoded === "reset",
    });
  });

  const gone = (what: string): ApiError =>
    new ApiError("not_found", `That ${what} is no longer in the library.`);

  app.get("/v1/music/artists/:id", (c) => {
    const [artist] = reader.artists([c.req.param("id")]);
    if (!artist) throw gone("artist");
    return c.json({ artist, albums: reader.albumsOfArtist(artist.id) });
  });

  app.get("/v1/music/albums/:id", (c) => {
    const [album] = reader.albums([c.req.param("id")]);
    if (!album) throw gone("album");
    return c.json({ album, tracks: reader.tracksOfAlbum(album.id) });
  });

  app.get("/v1/music/tracks/:id", (c) => {
    const [track] = reader.tracks([c.req.param("id")]);
    if (!track) throw gone("track");
    return c.json({ track });
  });

  app.get("/v1/music/books/:id", (c) => {
    const [book] = reader.books([c.req.param("id")]);
    if (!book) throw gone("book");
    return c.json({ book, tracks: reader.tracksOfBook(book.id) });
  });

  app.get("/v1/music/status", (c) => {
    deps.requireManager(c, "see the server's status");
    const sources = db.all<Record<string, string | number | null>>(
      `select id, name, hint, available, last_scan_started_at, last_scan_finished_at,
         (select count(*) from music_track where source_id = music_source.id) as files
       from music_source order by name`,
    );
    const counts = db.all<{ kind: string; n: number }>(
      "select kind, count(*) as n from music_change where removed = 0 group by kind",
    );
    const count = (kind: string): number => counts.find((row) => row.kind === kind)?.n ?? 0;
    return c.json({
      scanning: music.scanner.isScanning,
      sources: sources.map((source) => ({
        id: source["id"],
        name: source["name"],
        hint: source["hint"],
        available: source["available"] === 1,
        lastScanStartedAt: source["last_scan_started_at"],
        lastScanFinishedAt: source["last_scan_finished_at"],
        files: source["files"],
      })),
      files: db.get(
        `select count(*) as total, coalesce(sum(state = 'discovered'), 0) as waiting,
           coalesce(sum(state = 'failed'), 0) as failed, coalesce(sum(available = 0), 0) as missing
         from music_track`,
      ),
      items: {
        artists: count("artist"),
        albums: count("album"),
        tracks: count("track"),
        books: count("book"),
      },
      copies: { bytes: copies.totalBytes() },
    });
  });

  // ---- Covers ----

  app.get("/v1/music/covers/:id", async (c) => {
    const width = Number(c.req.query("w") ?? "800");
    if (!Number.isInteger(width) || width < 1) {
      throw new ApiError("invalid_request", `"w" must be a whole number of pixels.`);
    }
    const picture = await covers.read(c.req.param("id"), width);
    if (!picture) throw new ApiError("not_found", "That cover is no longer in the library.");
    return c.body(picture, 200, {
      "Content-Type": "image/jpeg",
      "Cache-Control": "private, max-age=31536000, immutable",
    });
  });

  // ---- Sound ----

  const fileOf = (id: string): FileRow => {
    const row = db.get<FileRow>(
      `select music_track.id, rel_path, size, mtime_ms, revision, container, duration_ms, bit_rate,
         lossless, playability, music_track.available, music_source.path as source_path,
         music_source.available as source_available
       from music_track join music_source on music_source.id = music_track.source_id
       where music_track.id = ? and tags_json is not null`,
      [id],
    );
    if (!row) throw gone("track");
    return row;
  };
  const requireReachable = (row: FileRow): void => {
    if (row.available !== 1 || row.source_available !== 1) {
      throw new ApiError("unavailable", "The drive this file is on is not connected right now.");
    }
  };

  app.on(["GET", "HEAD"], "/v1/music/tracks/:id/content", async (c) => {
    const row = fileOf(c.req.param("id"));
    requireReachable(row);
    return serveLibraryFile(c, {
      id: row.id,
      root: row.source_path,
      relPath: row.rel_path,
      revision: row.revision,
      mtimeMs: row.mtime_ms,
      contentType: audioType(row.container, row.rel_path),
    });
  });

  app.post("/v1/music/tracks/:id/playback", async (c) => {
    const body = await readBody(c);
    const quality = body["quality"] ?? "original";
    const kbps = COMPACT_KBPS.find((one) => one === quality);
    if (quality !== "original" && kbps === undefined) {
      throw new ApiError("invalid_request", `"quality" must be "original", 256 or 128.`);
    }
    const purpose = body["purpose"] ?? "play";
    if (purpose !== "play" && purpose !== "download") {
      throw new ApiError("invalid_request", `"purpose" must be "play" or "download".`);
    }
    const row = fileOf(c.req.param("id"));
    const sound = {
      playability: row.playability ?? ("convert" as const),
      lossless: row.lossless === 1,
      bitRate: row.bit_rate,
    };
    const direct =
      kbps === undefined ? sound.playability === "direct" : isCompactAlready(sound, kbps);
    if (direct) {
      requireReachable(row);
      return c.json({
        state: "ready",
        mode: "direct",
        revision: row.revision,
        kbps: null,
        url: `/v1/music/tracks/${row.id}/content`,
        bytes: row.size,
        progress: 1,
        message: null,
      });
    }
    const wanted: CompactKbps = kbps ?? 256;
    // A copy that exists plays on with the drive away.
    const ready = copies.file(row.id, row.revision, wanted) !== null;
    if (!ready) requireReachable(row);
    const status = copies.request(
      {
        id: row.id,
        revision: row.revision,
        durationMs: row.duration_ms,
        sizeBytes: row.size,
        open: () => openablePath({ id: row.id, root: row.source_path, relPath: row.rel_path }),
      },
      wanted,
      purpose === "play",
    );
    if (status.state === "busy") {
      c.header("Retry-After", "30");
      throw new ApiError("rate_limited", "The server is converting a lot right now. Try later.");
    }
    const message =
      status.state === "failed"
        ? "This file could not be converted."
        : status.state === "does_not_fit"
          ? "The server has no room for a converted copy right now."
          : null;
    return c.json(
      {
        state: status.state,
        mode: "copy",
        revision: row.revision,
        kbps: wanted,
        url:
          status.state === "ready"
            ? `/v1/music/tracks/${row.id}/copies/${row.revision}/${wanted}.m4a`
            : null,
        bytes: status.bytes,
        progress: status.progress,
        message,
      },
      status.state === "queued" || status.state === "preparing" ? 202 : 200,
    );
  });

  app.on(["GET", "HEAD"], "/v1/music/tracks/:id/copies/:revision/:file", async (c) => {
    const kbps = COMPACT_KBPS.find((one) => `${one}.m4a` === c.req.param("file"));
    const row = fileOf(c.req.param("id"));
    const copy =
      kbps === undefined || row.revision !== c.req.param("revision")
        ? null
        : copies.file(row.id, row.revision, kbps);
    if (!copy) throw new ApiError("not_found", "This copy no longer exists. Ask for it again.");
    return fileResponse(
      {
        method: c.req.method,
        range: c.req.header("Range"),
        ifRange: c.req.header("If-Range"),
      },
      copy.path,
      { contentType: "audio/mp4", etag: copy.etag, immutable: true },
    );
  });

  registerMusicViewerRoutes(app, { db, music });
  registerMusicEditRoutes(app, {
    db,
    music,
    requireManager: (c) => {
      const device = deps.requireManager(c, "change music");
      return device.id;
    },
    changed: (by, kind, id) => {
      log.info("A manager changed music", { by, kind, id });
    },
  });
}
