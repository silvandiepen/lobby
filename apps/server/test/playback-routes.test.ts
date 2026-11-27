// SPDX-License-Identifier: MPL-2.0
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Hono } from "hono";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { registerPlaybackRoutes, type PlaybackResponse } from "../src/playback/routes.ts";
import { PlaybackService } from "../src/playback/service.ts";
import type { PlaybackAsset } from "../src/playback/types.ts";
import {
  assetFor,
  hasEncoder,
  makeAvi,
  makeMkv,
  slowFfmpeg,
  srt,
  startMsOf,
  waitFor,
} from "./playback-support.ts";
import { makeTempDir, makeVideo, removeDir } from "./support/media.ts";
import { block, writePgs } from "./support/pgs.ts";

/** A pattern for a WebVTT cue time under an hour, as ffmpeg writes it: `00:01.023`. */
function cueTime(ms: number): string {
  const minutes = String(Math.floor(ms / 60_000)).padStart(2, "0");
  const seconds = String(Math.floor((ms % 60_000) / 1000)).padStart(2, "0");
  return `${minutes}:${seconds}\\.${String(ms % 1000).padStart(3, "0")}`;
}

interface ErrorBody {
  error: { code: string; message: string };
}

describe("the playback routes", () => {
  let dir: string;
  let playback: PlaybackService;
  let app: Hono;
  let assets: Map<string, PlaybackAsset>;

  async function setUp(ffmpegPath?: string): Promise<void> {
    playback = new PlaybackService({
      cacheDir: join(dir, "cache"),
      minFreeBytes: 0,
      ...(ffmpegPath ? { ffmpegPath } : {}),
    });
    await playback.start();
    app = new Hono();
    registerPlaybackRoutes(app, { playback, lookupAsset: (id) => assets.get(id) ?? null });
  }

  beforeEach(() => {
    dir = makeTempDir("lobby-playback-routes-");
    assets = new Map();
  });

  afterEach(async () => {
    await playback.close();
    removeDir(dir);
  });

  async function askPlayback(id: string): Promise<{ status: number; body: PlaybackResponse }> {
    const response = await app.request(`/v1/assets/${id}/playback`, { method: "POST" });
    return { status: response.status, body: (await response.json()) as PlaybackResponse };
  }

  async function untilReady(id: string): Promise<PlaybackResponse> {
    return waitFor(async () => {
      const { body } = await askPlayback(id);
      if (body.state === "failed") throw new Error(body.message ?? "failed");
      return body.state === "ready" ? body : null;
    });
  }

  async function mkvAsset(seconds = 14): Promise<PlaybackAsset> {
    const source = join(dir, "library", "film.mkv");
    makeMkv(source, {
      seconds,
      audio: [
        { codec: "libopus", language: "jpn" },
        { codec: "aac", language: "dut", default: true },
      ],
      subtitles: ["eng"],
    });
    // A sidecar in Windows-1252, as old subtitle files are.
    const sidecar = join(dir, "library", "film.nl.srt");
    writeFileSync(sidecar, Buffer.from(srt(seconds, "Café crème"), "latin1"));
    const asset = await assetFor(source, { id: "film" }, [
      { id: "s7", path: sidecar, language: "dut" },
    ]);
    // Blu-ray subtitles in a file of their own.
    const sup = join(dir, "library", "film.en.sup");
    writePgs(sup, [{ startMs: 1_000, endMs: 2_000, picture: block(300, 50) }], {
      width: 1280,
      height: 720,
    });
    asset.subtitles.push({
      id: "s8",
      source: { kind: "sidecar", path: sup },
      codec: "hdmv_pgs_subtitle",
      language: "eng",
      title: null,
      isForced: false,
    });
    asset.subtitles.push({
      id: "e9",
      source: { kind: "embedded", streamIndex: 9 },
      codec: "hdmv_pgs_subtitle",
      language: "eng",
      title: null,
      isForced: false,
    });
    assets.set(asset.id, asset);
    return asset;
  }

  it("answers 404 for an asset that does not exist", async () => {
    await setUp();
    const response = await app.request("/v1/assets/nope/playback", { method: "POST" });
    expect(response.status).toBe(404);
    expect(((await response.json()) as ErrorBody).error.code).toBe("not_found");
  });

  it("points at the original for a file that plays as it is", async () => {
    await setUp();
    const source = join(dir, "direct.mp4");
    makeVideo(source);
    const asset = await assetFor(source, { id: "direct" });
    assets.set(asset.id, asset);
    const { status, body } = await askPlayback("direct");
    expect(status).toBe(200);
    expect(body).toMatchObject({
      state: "ready",
      mode: "direct",
      streamUrl: "/v1/assets/direct/content",
      downloadUrl: "/v1/assets/direct/content",
      downloadBytes: asset.sizeBytes,
      revision: asset.revision,
    });
    expect(body.audio).toMatchObject([{ codec: "aac", converted: false }]);
  });

  it("says why a file whose video it does not convert cannot play", async () => {
    await setUp();
    const source = join(dir, "old.mpg");
    makeVideo(source, { videoCodec: "mpeg2video", audioCodec: "mp2" });
    const asset = await assetFor(source, { id: "old" });
    assets.set(asset.id, asset);
    const { status, body } = await askPlayback("old");
    expect(status).toBe(200);
    expect(body).toMatchObject({
      state: "unsupported",
      mode: null,
      streamUrl: null,
      downloadUrl: null,
    });
    expect(body.message).toContain("MPEG2VIDEO");

    // Also when the catalogue thought repackaging would do.
    assets.set("old", { ...asset, playability: "remux", playabilityReason: null });
    const second = await askPlayback("old");
    expect(second.status).toBe(200);
    expect(second.body).toMatchObject({ state: "unsupported", streamUrl: null });
    expect(second.body.message).toContain("MPEG2VIDEO");
  });

  it.skipIf(!hasEncoder("libmp3lame"))(
    "converts an old AVI and serves it like a repackaged file",
    { timeout: 180_000 },
    async () => {
      await setUp();
      const source = join(dir, "old.avi");
      makeAvi(source);
      const asset = await assetFor(source, { id: "avi" });
      assets.set(asset.id, asset);
      const first = await askPlayback("avi");
      expect(first.status).toBe(202);
      expect(first.body).toMatchObject({ mode: "prepared", videoConverted: true });

      const ready = await untilReady("avi");
      const base = `/v1/assets/avi/prepared/${asset.revision}`;
      expect(ready).toMatchObject({
        videoConverted: true,
        speed: null,
        streamUrl: `${base}/master.m3u8`,
        downloadUrl: `${base}/media.mp4`,
      });
      expect(ready.audio).toMatchObject([{ codec: "aac", converted: true }]);
      const playlist = await (await app.request(`${base}/index.m3u8`)).text();
      expect(playlist).toContain("#EXT-X-ENDLIST");
      const download = await app.request(`${base}/media.mp4`, { method: "HEAD" });
      expect(Number(download.headers.get("Content-Length"))).toBe(ready.downloadBytes);
    },
  );

  it("answers 503 when the drive is gone and nothing was prepared", async () => {
    await setUp();
    const asset = await mkvAsset();
    assets.set(asset.id, { ...asset, available: false });
    const response = await app.request("/v1/assets/film/playback", { method: "POST" });
    expect(response.status).toBe(503);
    expect(((await response.json()) as ErrorBody).error.code).toBe("unavailable");
  });

  it(
    "prepares an MKV and serves the stream, the file and the subtitles",
    { timeout: 180_000 },
    async () => {
      await setUp();
      const asset = await mkvAsset();
      const first = await askPlayback("film");
      expect(first.status).toBe(202);
      expect(["queued", "preparing"]).toContain(first.body.state);
      expect(first.body.downloadUrl).toBeNull();

      const ready = await untilReady("film");
      const base = `/v1/assets/film/prepared/${asset.revision}`;
      expect(ready).toMatchObject({
        mode: "prepared",
        progress: 1,
        streamUrl: `${base}/master.m3u8`,
        downloadUrl: `${base}/media.mp4`,
        durationMs: asset.durationMs,
      });
      expect(ready.audio).toMatchObject([
        { index: 2, codec: "aac", language: "dut", isDefault: true, converted: false },
        { index: 1, codec: "aac", language: "jpn", isDefault: false, converted: true },
      ]);

      // Master playlist: one variant and the two text subtitles, not the picture subtitle.
      const master = await app.request(`${base}/master.m3u8`);
      expect(master.status).toBe(200);
      expect(master.headers.get("Content-Type")).toBe("application/vnd.apple.mpegurl");
      const masterText = await master.text();
      expect(masterText).toContain("#EXT-X-START:TIME-OFFSET=0");
      expect(masterText).toContain(
        '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",DEFAULT=NO,AUTOSELECT=NO,FORCED=NO,URI="subtitles/e3.m3u8"',
      );
      expect(masterText).toContain('NAME="Dutch",LANGUAGE="nl"');
      expect(masterText).toContain('URI="subtitles/s7.m3u8"');
      expect(masterText).not.toContain("e9");
      expect(masterText).toContain(
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Dutch",LANGUAGE="nl",DEFAULT=YES,AUTOSELECT=YES\n',
      );
      expect(masterText).toContain(
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Japanese",LANGUAGE="ja",DEFAULT=NO,AUTOSELECT=YES,URI="audio-1.m3u8"',
      );
      expect(masterText).toMatch(
        /#EXT-X-STREAM-INF:BANDWIDTH=\d+,CLOSED-CAPTIONS=NONE,AUDIO="audio",SUBTITLES="subs"\nindex\.m3u8\n$/,
      );

      const audioPlaylist = await app.request(`${base}/audio-1.m3u8`);
      expect(audioPlaylist.status).toBe(200);
      expect(await audioPlaylist.text()).toContain('#EXT-X-MAP:URI="audio-1.mp4"');
      const audioFile = await app.request(`${base}/audio-1.mp4`, { method: "HEAD" });
      expect(audioFile.status).toBe(200);
      expect(audioFile.headers.get("Content-Type")).toBe("audio/mp4");
      expect((await app.request(`${base}/audio-2.mp4`)).status).toBe(404);

      const subtitlePlaylist = await (await app.request(`${base}/subtitles/e3.m3u8`)).text();
      expect(subtitlePlaylist).toContain("../../../subtitles/e3.vtt");
      expect(
        new URL("../../../subtitles/e3.vtt", `http://lobby${base}/subtitles/e3.m3u8`).pathname,
      ).toBe("/v1/assets/film/subtitles/e3.vtt");
      expect(subtitlePlaylist).toContain("#EXT-X-ENDLIST");
      expect((await app.request(`${base}/subtitles/e9.m3u8`)).status).toBe(404);

      // Stream playlist and the file it points into.
      const playlist = await (await app.request(`${base}/index.m3u8`)).text();
      expect(playlist).toContain("#EXT-X-ENDLIST");
      const map = /#EXT-X-MAP:URI="media\.mp4",BYTERANGE="(\d+)@0"/.exec(playlist);
      const initLength = Number(map?.[1]);
      expect(initLength).toBeGreaterThan(0);

      const head = await app.request(`${base}/media.mp4`, { method: "HEAD" });
      expect(head.status).toBe(200);
      expect(head.headers.get("Accept-Ranges")).toBe("bytes");
      expect(head.headers.get("Content-Type")).toBe("video/mp4");
      expect(Number(head.headers.get("Content-Length"))).toBe(ready.downloadBytes);
      expect(head.headers.get("ETag")).toBe(`"${asset.revision}-prepared"`);

      const init = await app.request(`${base}/media.mp4`, {
        headers: { Range: `bytes=0-${initLength - 1}` },
      });
      expect(init.status).toBe(206);
      expect(init.headers.get("Content-Range")).toBe(
        `bytes 0-${initLength - 1}/${ready.downloadBytes}`,
      );
      const bytes = Buffer.from(await init.arrayBuffer());
      expect(bytes.length).toBe(initLength);
      expect(bytes.subarray(4, 8).toString("latin1")).toBe("ftyp");

      const whole = Buffer.from(await (await app.request(`${base}/media.mp4`)).arrayBuffer());
      const onDisk = readFileSync(
        playback.resolveFile(asset.id, asset.revision, "media.mp4")?.path ?? "",
      );
      expect(whole.equals(onDisk)).toBe(true);

      const beyond = await app.request(`${base}/media.mp4`, {
        headers: { Range: `bytes=${(ready.downloadBytes ?? 0) + 10}-` },
      });
      expect(beyond.status).toBe(416);
      expect(beyond.headers.get("Content-Range")).toBe(`bytes */${ready.downloadBytes}`);

      // A resumed download of another version starts over instead of splicing.
      const resumed = await app.request(`${base}/media.mp4`, {
        headers: { Range: "bytes=100-", "If-Range": '"another-revision-prepared"' },
      });
      expect(resumed.status).toBe(200);

      // Subtitles as WebVTT: embedded, and the Windows-1252 sidecar as UTF-8.
      const embedded = await app.request("/v1/assets/film/subtitles/e3.vtt");
      expect(embedded.status).toBe(200);
      expect(embedded.headers.get("Content-Type")).toBe("text/vtt; charset=UTF-8");
      // On the prepared copy's clock, which starts where the file's first packet is.
      const shift = -startMsOf(asset.path);
      expect(await embedded.text()).toMatch(
        new RegExp(
          `^WEBVTT\n\n${cueTime(1000 + shift)} --> ${cueTime(2000 + shift)}\nEmbedded eng 1\n`,
        ),
      );
      const sidecar = await (await app.request("/v1/assets/film/subtitles/s7.vtt")).text();
      expect(sidecar).toContain("Café crème 1");

      const picture = await app.request("/v1/assets/film/subtitles/e9.vtt");
      expect(picture.status).toBe(422);
      expect(((await picture.json()) as ErrorBody).error.code).toBe("unsupported_subtitle");
      expect((await app.request("/v1/assets/film/subtitles/e77.vtt")).status).toBe(404);

      // Picture subtitles as placed PNGs: only for a track stored as pictures.
      const pictures = await app.request("/v1/assets/film/subtitles/s8.json");
      expect(pictures.status).toBe(200);
      expect(pictures.headers.get("Content-Type")).toBe("application/json");
      const body = (await pictures.json()) as {
        width: number;
        height: number;
        cues: { startMs: number; endMs: number; width: number; height: number }[];
      };
      expect(body.width).toBe(1280);
      expect(body.cues).toEqual([
        expect.objectContaining({ startMs: 1_000, endMs: 2_000, width: 300, height: 50 }),
      ]);
      const textAsPictures = await app.request("/v1/assets/film/subtitles/e3.json");
      expect(textAsPictures.status).toBe(422);
      expect(((await textAsPictures.json()) as ErrorBody).error.code).toBe("unsupported_subtitle");
      expect((await app.request("/v1/assets/film/subtitles/e77.json")).status).toBe(404);
    },
  );

  it(
    "refuses every prepared file name but the known ones, and stale revisions",
    { timeout: 180_000 },
    async () => {
      await setUp();
      const asset = await mkvAsset();
      await askPlayback("film");
      await untilReady("film");
      const base = `/v1/assets/film/prepared/${asset.revision}`;
      for (const name of [
        "meta.json",
        "..%2Fmeta.json",
        "%2e%2e%2fmeta.json",
        "..%2F..%2F..%2Flibrary%2Ffilm.mkv",
        "media.mp4%00.txt",
        "index.m3u8.tmp",
      ]) {
        const response = await app.request(`${base}/${name}`);
        expect(response.status, name).toBe(404);
      }
      expect((await app.request(`${base}/../../../../library/film.mkv`)).status).toBe(404);
      expect((await app.request(`${base}/subtitles/..%2F..%2Fmeta.json`)).status).toBe(404);
      expect((await app.request("/v1/assets/film/subtitles/..%2Fx.vtt")).status).toBe(404);

      // The file changed: URLs of the old revision stop working, a new POST prepares the new one.
      assets.set("film", { ...asset, revision: "changed" });
      expect((await app.request(`${base}/media.mp4`)).status).toBe(404);
      expect((await app.request(`${base}/master.m3u8`)).status).toBe(404);
      const again = await askPlayback("film");
      expect(again.status).toBe(202);
      expect(again.body.revision).toBe("changed");
      const ready = await untilReady("film");
      expect(ready.downloadUrl).toBe("/v1/assets/film/prepared/changed/media.mp4");
    },
  );

  it(
    "offers the stream before the file is finished, and the file only when it is",
    { timeout: 180_000 },
    async () => {
      await setUp(slowFfmpeg(dir, 8));
      const asset = await mkvAsset(120);
      await askPlayback("film");
      const streaming = await waitFor(async () => {
        const { body } = await askPlayback("film");
        return body.streamUrl !== null ? body : null;
      });
      expect(streaming).toMatchObject({
        state: "preparing",
        downloadUrl: null,
        downloadBytes: null,
      });
      expect(streaming.preparedMs).toBeGreaterThanOrEqual(30_000);
      expect(streaming.progress).toBeLessThan(1);
      expect(streaming.speed).toBeGreaterThan(0);
      expect(streaming.videoConverted).toBe(false);

      const base = `/v1/assets/film/prepared/${asset.revision}`;
      const master = await (await app.request(`${base}/master.m3u8`)).text();
      // The sidecar is there at once; the embedded track only when the pass is done.
      expect(master).toContain('URI="subtitles/s7.m3u8"');
      expect(master).not.toContain("e3.m3u8");

      const playlistResponse = await app.request(`${base}/index.m3u8`);
      expect(playlistResponse.headers.get("Cache-Control")).toBe("no-store");
      expect(playlistResponse.headers.get("ETag")).toBeNull();
      const playlist = await playlistResponse.text();
      expect(playlist).not.toContain("#EXT-X-ENDLIST");
      const segment = /#EXT-X-BYTERANGE:(\d+)@(\d+)/.exec(playlist);
      const [length, offset] = [Number(segment?.[1]), Number(segment?.[2])];
      const part = await app.request(`${base}/media.mp4`, {
        headers: { Range: `bytes=${offset}-${offset + length - 1}` },
      });
      expect(part.status).toBe(206);
      const bytes = Buffer.from(await part.arrayBuffer());
      expect(bytes.length).toBe(length);
      // A segment is an index box followed by movie fragments.
      expect(bytes.subarray(4, 8).toString("latin1")).toBe("sidx");
      expect(bytes.includes("moof")).toBe(true);

      const ready = await untilReady("film");
      expect(ready.downloadUrl).toBe(`${base}/media.mp4`);
      expect(await (await app.request(`${base}/master.m3u8`)).text()).toContain("e3.m3u8");
    },
  );
});
