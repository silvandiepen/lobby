// SPDX-License-Identifier: MPL-2.0
// Not a test: an experiment tool (see docs/playback.md). It serves real files through Lobby's
// playback module, without the rest of the server, so the AVFoundation harness in
// tools/playback-experiments can be pointed at it. No authentication: bind it to a private
// address, for the length of an experiment only.
//
//   node apps/server/test/playback-experiment-server.ts --cache <dir> [--host 127.0.0.1] [--port 8765]
//        [--max-gb 10] [--concurrent 2] <video file>...
//
// Each file becomes the asset "a1", "a2", ... in the order given; the mapping is printed with
// codecs only. A subtitle file with the same name beside a video (.srt) becomes its sidecar "s1".

import { existsSync, statSync } from "node:fs";
import { resolve } from "node:path";
import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { mediaTypeFor } from "../src/http/range.ts";
import { probeFile } from "../src/library/probe.ts";
import { fileResponse } from "../src/playback/files.ts";
import {
  PlaybackService,
  registerPlaybackRoutes,
  type PlaybackAsset,
  type PlaybackSubtitle,
} from "../src/playback/index.ts";

const args = process.argv.slice(2);
const options = { cache: "", host: "127.0.0.1", port: 8765, maxGb: 10, concurrent: 2 };
const files: string[] = [];
for (let index = 0; index < args.length; index += 1) {
  const arg = args[index] ?? "";
  const value = args[index + 1] ?? "";
  if (arg === "--cache") options.cache = resolve(value);
  else if (arg === "--host") options.host = value;
  else if (arg === "--port") options.port = Number(value);
  else if (arg === "--max-gb") options.maxGb = Number(value);
  else if (arg === "--concurrent") options.concurrent = Number(value);
  else {
    files.push(resolve(arg));
    continue;
  }
  index += 1;
}
if (options.cache === "" || files.length === 0) {
  console.error(
    "usage: playback-experiment-server.ts --cache <dir> [--host h] [--port p] [--max-gb n] [--concurrent n] <video>...",
  );
  process.exit(2);
}

const assets = new Map<string, PlaybackAsset>();
for (const [position, path] of files.entries()) {
  const probe = await probeFile(path);
  const info = statSync(path);
  const subtitles: PlaybackSubtitle[] = probe.tracks
    .filter((track) => track.kind === "subtitle")
    .map((track) => ({
      id: `e${track.index}`,
      source: { kind: "embedded", streamIndex: track.index },
      codec: track.codec,
      language: track.language,
      title: track.title,
      isForced: track.isForced,
    }));
  const sidecar = path.replace(/\.[^.]+$/, ".srt");
  if (existsSync(sidecar)) {
    subtitles.push({
      id: "s1",
      source: { kind: "sidecar", path: sidecar },
      codec: "subrip",
      language: null,
      title: null,
      isForced: false,
    });
  }
  const id = `a${position + 1}`;
  assets.set(id, {
    id,
    revision: `${info.size}-${Math.round(info.mtimeMs)}`,
    path,
    sizeBytes: info.size,
    durationMs: probe.durationMs,
    available: true,
    playability: probe.playability,
    playabilityReason: probe.playabilityReason,
    tracks: probe.tracks,
    subtitles,
  });
  const summary = probe.tracks.map((track) => `${track.kind}:${track.codec}`).join(" ");
  console.log(`${id} ${probe.playability} ${(info.size / 1e9).toFixed(2)} GB ${summary}`);
}

const playback = new PlaybackService({
  cacheDir: options.cache,
  maxCacheBytes: options.maxGb * 1024 ** 3,
  maxConcurrent: options.concurrent,
});
await playback.start();

const app = new Hono();
registerPlaybackRoutes(app, { playback, lookupAsset: (id) => assets.get(id) ?? null });
// The original, as the real server's /content route serves it.
app.on(["GET", "HEAD"], "/v1/assets/:id/content", (c) => {
  const asset = assets.get(c.req.param("id"));
  if (!asset) return c.notFound();
  return fileResponse(
    { method: c.req.method, range: c.req.header("Range"), ifRange: c.req.header("If-Range") },
    asset.path,
    { contentType: mediaTypeFor(null, asset.path), etag: asset.revision, immutable: true },
  );
});

const server = serve({ fetch: app.fetch, hostname: options.host, port: options.port });
console.log(`listening on http://${options.host}:${String(options.port)}`);
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    server.close();
    void playback.close().then(() => process.exit(0));
  });
}
