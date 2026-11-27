// SPDX-License-Identifier: MPL-2.0
import type { Context, Env, Hono } from "hono";
import { errorResponse, fileResponse } from "./files.ts";
import { audioRenditionFiles, MEDIA_FILE, STREAM_PLAYLIST, TEXT_SUBTITLE_CODECS } from "./plan.ts";
import { languageTag, masterPlaylist, subtitlePlaylist, trackName } from "./playlist.ts";
import { PlaybackError, type PlaybackService } from "./service.ts";
import type { PlaybackAsset, PreparedAudio, Preparation } from "./types.ts";

export interface PlaybackRouteDeps {
  playback: PlaybackService;
  /**
   * Finds an asset by id, with its path already resolved and checked to lie inside
   * its library folder. Null when there is no such asset. Access checks (device,
   * role) happen in middleware before these routes.
   */
  lookupAsset: (assetId: string) => PlaybackAsset | null | Promise<PlaybackAsset | null>;
}

/** The body of `POST /v1/assets/{id}/playback`. Documented in docs/api.md. */
export interface PlaybackResponse {
  state: "ready" | "preparing" | "queued" | "failed" | "unsupported";
  mode: "direct" | "prepared" | null;
  revision: string;
  progress: number;
  preparedMs: number;
  durationMs: number | null;
  streamUrl: string | null;
  downloadUrl: string | null;
  downloadBytes: number | null;
  audio: PreparedAudio[];
  videoConverted: boolean;
  speed: number | null;
  message: string | null;
}

const STATUS: Record<PlaybackError["code"], number> = {
  // Not reached for playback itself, which answers 200 with state "unsupported".
  unsupported: 422,
  unsupported_subtitle: 422,
  not_found: 404,
  unavailable: 503,
  busy: 429,
};

function playlistResponse(method: string, text: string): Response {
  return new Response(method === "HEAD" ? null : text, {
    headers: {
      "Content-Type": "application/vnd.apple.mpegurl",
      "Content-Length": String(Buffer.byteLength(text)),
      "Cache-Control": "no-store",
    },
  });
}

function preparedBase(asset: PlaybackAsset): string {
  return `/v1/assets/${encodeURIComponent(asset.id)}/prepared/${encodeURIComponent(asset.revision)}`;
}

function directAudio(asset: PlaybackAsset): PreparedAudio[] {
  return asset.tracks
    .filter((track) => track.kind === "audio")
    .map((track) => ({
      index: track.index,
      codec: track.codec,
      converted: false,
      language: track.language,
      title: track.title,
      channels: track.channels,
      isDefault: track.isDefault,
    }));
}

function describe(asset: PlaybackAsset, preparation: Preparation): PlaybackResponse {
  const base = preparedBase(asset);
  const ready = preparation.state === "ready";
  return {
    state: preparation.state,
    mode: "prepared",
    revision: asset.revision,
    progress: preparation.progress,
    preparedMs: preparation.preparedMs,
    durationMs: preparation.durationMs,
    streamUrl: preparation.streamable ? `${base}/master.m3u8` : null,
    downloadUrl: ready ? `${base}/${MEDIA_FILE}` : null,
    downloadBytes: ready ? preparation.sizeBytes : null,
    audio: preparation.audio,
    videoConverted: preparation.videoConverted,
    speed: preparation.speed,
    message: preparation.error,
  };
}

function unsupported(asset: PlaybackAsset, message: string): PlaybackResponse {
  return {
    state: "unsupported",
    mode: null,
    revision: asset.revision,
    progress: 0,
    preparedMs: 0,
    durationMs: asset.durationMs,
    streamUrl: null,
    downloadUrl: null,
    downloadBytes: null,
    audio: [],
    videoConverted: false,
    speed: null,
    message,
  };
}

/**
 * Mounts the playback and subtitle routes of docs/api.md on the app:
 *
 * - `POST /v1/assets/:id/playback` starts a preparation or reports on the one there is
 * - `GET|HEAD /v1/assets/:id/prepared/:revision/{master.m3u8,index.m3u8,media.mp4,audio-N.m3u8,audio-N.mp4,subtitles/:subtitleId.m3u8}`
 * - `GET|HEAD /v1/assets/:id/subtitles/:subtitleId.vtt`
 * - `GET|HEAD /v1/assets/:id/subtitles/:subtitleId.json` (picture subtitles)
 */
export function registerPlaybackRoutes<E extends Env>(app: Hono<E>, deps: PlaybackRouteDeps): void {
  const { playback } = deps;

  const handle = async (run: () => Promise<Response>): Promise<Response> => {
    try {
      return await run();
    } catch (error) {
      if (error instanceof PlaybackError) {
        if (error.code === "busy") {
          return errorResponse(429, "rate_limited", error.message, { "Retry-After": "30" });
        }
        return errorResponse(STATUS[error.code], error.code, error.message);
      }
      throw error;
    }
  };

  const findAsset = async (c: Context<E>): Promise<PlaybackAsset | Response> => {
    const asset = await deps.lookupAsset(c.req.param("id") ?? "");
    return asset ?? errorResponse(404, "not_found", "That file is no longer in the library.");
  };

  /** An asset whose revision is the one in the URL. Older URLs answer 404: ask for playback again. */
  const findPrepared = async (c: Context<E>): Promise<PlaybackAsset | Response> => {
    const asset = await findAsset(c);
    if (asset instanceof Response) return asset;
    if (c.req.param("revision") !== asset.revision) {
      return errorResponse(404, "not_found", "This file changed. Ask for playback again.");
    }
    return asset;
  };

  app.post("/v1/assets/:id/playback", (c) =>
    handle(async () => {
      const asset = await findAsset(c);
      if (asset instanceof Response) return asset;

      if (asset.playability === "direct") {
        const url = `/v1/assets/${encodeURIComponent(asset.id)}/content`;
        if (!asset.available) {
          throw new PlaybackError(
            "unavailable",
            "The drive this file is on is not connected right now.",
          );
        }
        return c.json({
          state: "ready",
          mode: "direct",
          revision: asset.revision,
          progress: 1,
          preparedMs: asset.durationMs ?? 0,
          durationMs: asset.durationMs,
          streamUrl: url,
          downloadUrl: url,
          downloadBytes: asset.sizeBytes,
          audio: directAudio(asset),
          videoConverted: false,
          speed: null,
          message: null,
        } satisfies PlaybackResponse);
      }
      if (asset.playability === "unsupported") {
        return c.json(
          unsupported(
            asset,
            asset.playabilityReason ?? "This file cannot be played on Apple devices.",
          ),
        );
      }
      let preparation: Preparation;
      try {
        preparation = await playback.prepare(asset);
      } catch (error) {
        // Video this server does not convert (AV1, 10-bit H.264), or no video at all.
        if (error instanceof PlaybackError && error.code === "unsupported") {
          return c.json(unsupported(asset, error.message));
        }
        throw error;
      }
      return c.json(describe(asset, preparation), preparation.state === "ready" ? 200 : 202);
    }),
  );

  app.on(["GET", "HEAD"], "/v1/assets/:id/prepared/:revision/master.m3u8", (c) =>
    handle(async () => {
      const asset = await findPrepared(c);
      if (asset instanceof Response) return asset;
      const preparation = await playback.status(asset);
      if (!preparation?.streamable) {
        return errorResponse(404, "not_found", "This file is not prepared for playback yet.");
      }
      const subtitles = await playback.streamSubtitles(asset);
      const text = masterPlaylist({
        // The playlist wants the peak rate; twice the file's average is a safe ceiling.
        bandwidth:
          asset.durationMs !== null && asset.durationMs > 0
            ? ((asset.sizeBytes * 8) / (asset.durationMs / 1000)) * 2
            : 16_000_000,
        streamUri: STREAM_PLAYLIST,
        // The first sound track is inside the stream itself; the others have their own playlists.
        audio: preparation.audio.map((audio, position) => ({
          name: trackName(audio.title, audio.language, `Audio ${position + 1}`),
          language: languageTag(audio.language),
          uri: position === 0 ? null : audioRenditionFiles(position).playlist,
        })),
        subtitles: subtitles.map((subtitle, position) => ({
          name: trackName(subtitle.title, subtitle.language, `Subtitles ${position + 1}`),
          language: languageTag(subtitle.language),
          isForced: subtitle.isForced,
          uri: `subtitles/${encodeURIComponent(subtitle.id)}.m3u8`,
        })),
      });
      // Not cached: subtitles are added to it when the preparation finishes.
      return playlistResponse(c.req.method, text);
    }),
  );

  app.on(
    ["GET", "HEAD"],
    "/v1/assets/:id/prepared/:revision/subtitles/:playlist{[A-Za-z0-9_-]+\\.m3u8}",
    (c) =>
      handle(async () => {
        const asset = await findPrepared(c);
        if (asset instanceof Response) return asset;
        const subtitleId = c.req.param("playlist").replace(/\.m3u8$/, "");
        const subtitle = asset.subtitles.find((candidate) => candidate.id === subtitleId);
        if (!subtitle || !TEXT_SUBTITLE_CODECS.has(subtitle.codec)) {
          return errorResponse(404, "not_found", "This file has no such subtitle track.");
        }
        // Relative, as every other address in a playlist: an app's own local server has the API
        // under a path of its own.
        const vtt = `../../../subtitles/${encodeURIComponent(subtitle.id)}.vtt`;
        const text = subtitlePlaylist(asset.durationMs ?? 0, vtt);
        return playlistResponse(c.req.method, text);
      }),
  );

  app.on(["GET", "HEAD"], "/v1/assets/:id/prepared/:revision/:file", (c) =>
    handle(async () => {
      const asset = await findPrepared(c);
      if (asset instanceof Response) return asset;
      const file = playback.resolveFile(asset.id, asset.revision, c.req.param("file"));
      if (!file) return errorResponse(404, "not_found", "This prepared file does not exist.");
      return fileResponse(
        { method: c.req.method, range: c.req.header("Range"), ifRange: c.req.header("If-Range") },
        file.path,
        {
          contentType: file.contentType,
          etag: `${asset.revision}-prepared`,
          // The playlist changes until ffmpeg is done; the MP4 only grows.
          immutable: file.complete,
        },
      );
    }),
  );

  app.on(["GET", "HEAD"], "/v1/assets/:id/subtitles/:subtitle{[A-Za-z0-9_-]+\\.vtt}", (c) =>
    handle(async () => {
      const asset = await findAsset(c);
      if (asset instanceof Response) return asset;
      const subtitleId = c.req.param("subtitle").replace(/\.vtt$/, "");
      const path = await playback.subtitle(asset, subtitleId);
      return fileResponse(
        { method: c.req.method, range: c.req.header("Range"), ifRange: c.req.header("If-Range") },
        path,
        {
          contentType: "text/vtt; charset=UTF-8",
          etag: `${asset.revision}-${subtitleId}`,
          immutable: true,
        },
      );
    }),
  );

  // Picture subtitles (docs/decisions.md, "Subtitles per viewer"): each cue a placed PNG, for the app to draw.
  app.on(["GET", "HEAD"], "/v1/assets/:id/subtitles/:subtitle{[A-Za-z0-9_-]+\\.json}", (c) =>
    handle(async () => {
      const asset = await findAsset(c);
      if (asset instanceof Response) return asset;
      const subtitleId = c.req.param("subtitle").replace(/\.json$/, "");
      const path = await playback.pictureSubtitle(asset, subtitleId);
      return fileResponse(
        { method: c.req.method, range: c.req.header("Range"), ifRange: c.req.header("If-Range") },
        path,
        {
          contentType: "application/json",
          etag: `${asset.revision}-${subtitleId}-pictures`,
          immutable: true,
        },
      );
    }),
  );
}
