// SPDX-License-Identifier: MPL-2.0
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { ffmpegArguments, planPreparation } from "../src/playback/plan.ts";
import { readStreamPlaylist } from "../src/playback/playlist.ts";
import { PlaybackError, PlaybackService, staysAhead } from "../src/playback/service.ts";
import type { PlaybackAsset, PlaybackTrack } from "../src/playback/types.ts";
import {
  assetFor,
  hasEncoder,
  makeAvi,
  makeMkv,
  sha256,
  slowFfmpeg,
  streamsOf,
  waitFor,
} from "./playback-support.ts";
import { makeTempDir, removeDir } from "./support/media.ts";

function track(
  index: number,
  kind: PlaybackTrack["kind"],
  codec: string,
  extra = {},
): PlaybackTrack {
  return {
    index,
    kind,
    codec,
    language: null,
    title: null,
    channels: kind === "audio" ? 2 : null,
    isDefault: false,
    isForced: false,
    ...extra,
  };
}

function assetWith(tracks: PlaybackTrack[]): PlaybackAsset {
  return {
    id: "a",
    revision: "r1",
    path: "/library/film.mkv",
    sizeBytes: 1000,
    durationMs: 60_000,
    available: true,
    playability: "remux",
    playabilityReason: null,
    tracks,
    subtitles: [],
  };
}

describe("the plan for a file", () => {
  it("copies H.264 with AAC and puts the default sound track first", () => {
    const planned = planPreparation(
      assetWith([
        track(0, "video", "h264"),
        track(1, "audio", "aac", { language: "jpn" }),
        track(2, "audio", "ac3", { language: "eng", isDefault: true, channels: 6 }),
      ]),
    );
    if (!planned.ok) throw new Error(planned.reason);
    expect(planned.plan.audio.map((audio) => [audio.index, audio.codec, audio.converted])).toEqual([
      [2, "ac3", false],
      [1, "aac", false],
    ]);
    expect(planned.plan.audio.map((audio) => audio.isDefault)).toEqual([true, false]);
  });

  it("converts surround DTS to AC-3 (7.1 mixed down to 5.1) and stereo Opus to AAC", () => {
    const planned = planPreparation(
      assetWith([
        track(0, "video", "h264"),
        track(1, "audio", "dts", { channels: 8 }),
        track(2, "audio", "opus", { channels: 2 }),
      ]),
    );
    if (!planned.ok) throw new Error(planned.reason);
    expect(planned.plan.audio).toMatchObject([
      { index: 1, codec: "ac3", converted: true, channels: 6, bitrateKbps: 640 },
      { index: 2, codec: "aac", converted: true, channels: 2, bitrateKbps: 160 },
    ]);
    const args = ffmpegArguments("/library/film.mkv", planned.plan, "/cache");
    expect(args.join(" ")).toContain("-c:v copy");
    expect(args.join(" ")).toContain("-c:a:0 ac3 -b:a:0 640k -ac:a:0 6");
    expect(args.join(" ")).toContain("-hls_segment_filename /cache/media.mp4 /cache/index.m3u8");
    // The second sound track also gets a playlist of its own, so a stream can switch to it.
    expect(args.join(" ")).toContain("-map 0:2 -c:a:0 aac -b:a:0 160k -ac:a:0 2 -map_chapters");
    expect(args.join(" ")).toContain(
      "-hls_segment_filename /cache/audio-1.mp4 /cache/audio-1.m3u8",
    );
    expect(args.join(" ")).not.toContain("hvc1");
  });

  it("tags HEVC as hvc1, which is the only tag AVFoundation plays", () => {
    const planned = planPreparation(
      assetWith([track(0, "video", "hevc"), track(1, "audio", "eac3")]),
    );
    if (!planned.ok) throw new Error(planned.reason);
    const args = ffmpegArguments("/library/film.mkv", planned.plan, "/cache");
    expect(args.join(" ")).toContain("-c:v copy -tag:v hvc1");
    expect(args.join(" ")).toContain("-c:a:0 copy");
  });

  it("converts MPEG-4 video to H.264 with a keyframe at every segment boundary", () => {
    for (const codec of ["mpeg4", "msmpeg4v3"]) {
      const planned = planPreparation({
        ...assetWith([
          track(0, "video", codec),
          track(1, "audio", "mp3"),
          track(2, "audio", "ac3", { channels: 6 }),
        ]),
        playability: "transcode",
        playabilityReason: "The video is MPEG4, which Apple devices do not play.",
      });
      if (!planned.ok) throw new Error(planned.reason);
      expect(planned.plan.videoConverted).toBe(true);
      expect(planned.plan.audio).toMatchObject([
        { index: 1, codec: "aac", converted: true },
        { index: 2, codec: "ac3", converted: false },
      ]);
      const args = ffmpegArguments("/library/film.avi", planned.plan, "/cache").join(" ");
      expect(args).toContain("-c:v libx264 -preset veryfast -crf 21 -profile:v high");
      expect(args).toContain("-pix_fmt yuv420p");
      expect(args).toContain("-force_key_frames expr:gte(t,n_forced*6)");
      expect(args).toContain("-hls_time 6");
      expect(args).not.toContain("-c:v copy");
    }
  });

  it("refuses other video that needs converting, and files without video", () => {
    const av1 = {
      ...assetWith([track(0, "video", "av1"), track(1, "audio", "aac")]),
      playability: "transcode" as const,
    };
    expect(planPreparation(av1)).toEqual({
      ok: false,
      reason: "The video is AV1, which Apple devices do not play.",
    });
    // H.264 the catalogue marked as needing conversion (10-bit) is not copied as if it were fine.
    const reason = "The video uses the pixel format yuv420p10le, which Apple devices do not play.";
    expect(
      planPreparation({
        ...assetWith([track(0, "video", "h264")]),
        playability: "transcode",
        playabilityReason: reason,
      }),
    ).toEqual({ ok: false, reason });
    expect(planPreparation(assetWith([track(0, "audio", "aac")]))).toMatchObject({ ok: false });
  });
});

describe("offering a stream while its copy is written", () => {
  const film = 90 * 60_000;

  it("waits for 30 seconds of film", () => {
    expect(staysAhead(29_000, film, 50)).toBe(false);
    expect(staysAhead(30_000, film, 50)).toBe(true);
  });

  it("starts at once when the copy is written faster than it plays", () => {
    expect(staysAhead(30_000, film, 1.2)).toBe(true);
    expect(staysAhead(30_000, null, 8)).toBe(true);
  });

  it("holds back a conversion that is slower than playback until the head start is enough", () => {
    // At half speed the viewer gains a minute on every two minutes written.
    expect(staysAhead(30_000, film, 0.5)).toBe(false);
    expect(staysAhead(40 * 60_000, film, 0.5)).toBe(false);
    expect(staysAhead(55 * 60_000, film, 0.5)).toBe(true);
    expect(staysAhead(60_000, null, 0.5)).toBe(false);
    expect(staysAhead(60_000, film, 0)).toBe(false);
  });
});

describe("preparing a file", () => {
  let dir: string;
  let cacheDir: string;
  let services: PlaybackService[];
  let clock: { now: number };

  beforeEach(() => {
    dir = makeTempDir("lobby-playback-");
    cacheDir = join(dir, "cache");
    services = [];
    clock = { now: 1_800_000_000_000 };
  });

  afterEach(async () => {
    await Promise.all(services.map((service) => service.close()));
    removeDir(dir);
  });

  async function service(
    options: {
      maxCacheBytes?: number;
      maxConcurrent?: number;
      maxConversions?: number;
      ffmpegPath?: string;
    } = {},
  ): Promise<PlaybackService> {
    const created = new PlaybackService({
      cacheDir,
      minFreeBytes: 0,
      now: () => clock.now,
      ...options,
    });
    services.push(created);
    await created.start();
    return created;
  }

  async function prepared(playback: PlaybackService, asset: PlaybackAsset): Promise<void> {
    await playback.prepare(asset);
    await waitFor(async () => {
      const status = await playback.status(asset);
      if (status?.state === "failed") throw new Error(status.error ?? "failed");
      return status?.state === "ready";
    });
  }

  function mediaPath(playback: PlaybackService, asset: PlaybackAsset): string {
    const file = playback.resolveFile(asset.id, asset.revision, "media.mp4");
    if (!file) throw new Error("no prepared file");
    return file.path;
  }

  it("repackages an MKV into one fragmented MP4 with a finished playlist, leaving the original alone", async () => {
    const source = join(dir, "library", "film.mkv");
    makeMkv(source, {
      audio: [
        { codec: "libopus", language: "jpn" },
        { codec: "aac", language: "eng", default: true },
      ],
      subtitles: ["eng"],
    });
    const before = sha256(source);
    const asset = await assetFor(source);
    expect(asset.playability).toBe("remux");

    const playback = await service();
    const first = await playback.prepare(asset);
    expect(["queued", "preparing"]).toContain(first.state);
    await prepared(playback, asset);

    const status = await playback.status(asset);
    expect(status).toMatchObject({ state: "ready", progress: 1, streamable: true, error: null });
    // The default track (AAC, copied) comes first; Opus was converted.
    expect(status?.audio).toMatchObject([
      { index: 2, codec: "aac", converted: false, language: "eng", isDefault: true },
      { index: 1, codec: "aac", converted: true, language: "jpn", isDefault: false },
    ]);

    const media = mediaPath(playback, asset);
    const streams = streamsOf(media);
    expect(streams.map((stream) => [stream.codec_type, stream.codec_name])).toEqual([
      ["video", "h264"],
      ["audio", "aac"],
      ["audio", "aac"],
    ]);
    expect(streams[1]?.tags?.["language"]).toBe("eng");
    expect(streams[2]?.tags?.["language"]).toBe("jpn");
    expect(status?.sizeBytes).toBe(readFileSync(media).length);

    // Fragmented MP4: the file starts with ftyp, then moov, then moof/mdat pairs.
    const head = readFileSync(media).subarray(0, 4096).toString("latin1");
    expect(head.slice(4, 8)).toBe("ftyp");
    expect(head).toContain("mvex");

    const playlist = readFileSync(
      playback.resolveFile(asset.id, asset.revision, "index.m3u8")?.path ?? "",
      "utf8",
    );
    expect(playlist).toContain('#EXT-X-MAP:URI="media.mp4",BYTERANGE=');
    expect(playlist).toContain("#EXT-X-ENDLIST");
    expect(playlist.match(/#EXTINF/g)?.length).toBeGreaterThanOrEqual(2);

    // The second sound track also exists on its own, for switching while streaming.
    const alternate = playback.resolveFile(asset.id, asset.revision, "audio-1.mp4");
    expect(alternate?.contentType).toBe("audio/mp4");
    expect(streamsOf(alternate?.path ?? "").map((stream) => stream.codec_name)).toEqual(["aac"]);
    expect(
      readFileSync(
        playback.resolveFile(asset.id, asset.revision, "audio-1.m3u8")?.path ?? "",
        "utf8",
      ),
    ).toContain("#EXT-X-ENDLIST");

    // The embedded subtitle was written in the same pass.
    const vtt = readFileSync(await playback.subtitle(asset, "e3"), "utf8");
    expect(vtt.startsWith("WEBVTT")).toBe(true);
    expect(vtt).toContain("Embedded eng 1");

    expect(sha256(source)).toBe(before);
    expect(readdirSync(join(dir, "library")).filter((name) => !name.endsWith(".srt"))).toEqual([
      "film.mkv",
    ]);
  });

  it.skipIf(!hasEncoder("libx265"))("keeps HEVC as it is and tags it hvc1", async () => {
    const source = join(dir, "hevc.mkv");
    makeMkv(source, { video: "libx265", audio: [{ codec: "ac3", default: true }] });
    const asset = await assetFor(source);
    const playback = await service();
    await prepared(playback, asset);
    const streams = streamsOf(mediaPath(playback, asset));
    expect(streams[0]).toMatchObject({ codec_name: "hevc", codec_tag_string: "hvc1" });
    expect(streams[1]).toMatchObject({ codec_name: "ac3" });
  });

  it.skipIf(!hasEncoder("dca"))(
    "converts DTS sound: 5.1 to AC-3, stereo to AAC",
    { timeout: 180_000 },
    async () => {
      const source = join(dir, "dts.mkv");
      makeMkv(source, {
        audio: [
          { codec: "dca", channels: 6, default: true },
          { codec: "dca", channels: 2 },
        ],
      });
      const asset = await assetFor(source);
      expect(
        asset.tracks
          .filter((candidate) => candidate.kind === "audio")
          .map((candidate) => [candidate.codec, candidate.channels]),
      ).toEqual([
        ["dts", 6],
        ["dts", 2],
      ]);
      const playback = await service();
      await prepared(playback, asset);
      const streams = streamsOf(mediaPath(playback, asset));
      expect(streams[1]).toMatchObject({ codec_name: "ac3", channels: 6 });
      expect(streams[2]).toMatchObject({ codec_name: "aac", channels: 2 });
      expect((await playback.status(asset))?.audio).toMatchObject([
        { codec: "ac3", converted: true, channels: 6 },
        { codec: "aac", converted: true, channels: 2 },
      ]);
    },
  );

  it(
    "can be streamed while it is still being written, and cleans up when stopped",
    { timeout: 180_000 },
    async () => {
      const source = join(dir, "long.mkv");
      makeMkv(source, { seconds: 120, subtitles: ["eng"] });
      const asset = await assetFor(source);
      const playback = await service({ ffmpegPath: slowFfmpeg(dir, 8) });
      await playback.prepare(asset);

      const streaming = await waitFor(async () => {
        const status = await playback.status(asset);
        return status?.streamable ? status : null;
      });
      expect(streaming.state).toBe("preparing");
      expect(streaming.preparedMs).toBeGreaterThanOrEqual(30_000);
      expect(streaming.preparedMs).toBeLessThan(120_000);
      expect(streaming.progress).toBeGreaterThan(0);
      expect(streaming.progress).toBeLessThan(1);

      const playlist = playback.resolveFile(asset.id, asset.revision, "index.m3u8");
      expect(playlist?.complete).toBe(false);
      const text = readFileSync(playlist?.path ?? "", "utf8");
      expect(text).toContain("#EXT-X-PLAYLIST-TYPE:EVENT");
      expect(text).not.toContain("#EXT-X-ENDLIST");
      // Every byte range the playlist lists is already in the file.
      const ranges = [...text.matchAll(/#EXT-X-BYTERANGE:(\d+)@(\d+)/g)];
      const last = ranges.at(-1);
      const media = readFileSync(mediaPath(playback, asset));
      expect(Number(last?.[1]) + Number(last?.[2])).toBeLessThanOrEqual(media.length);

      // The embedded subtitle is being written by this run: nothing in the stream's menu yet.
      expect(await playback.streamSubtitles(asset)).toEqual([]);

      await playback.close();
      expect(readdirSync(join(cacheDir, "prepared"))).toEqual([]);
      expect(readdirSync(join(cacheDir, "subtitles"))).toEqual([]);
    },
  );

  it(
    "prepares a bounded number of files at once and queues the rest",
    { timeout: 180_000 },
    async () => {
      const assets: PlaybackAsset[] = [];
      for (const name of ["one", "two", "three"]) {
        const source = join(dir, `${name}.mkv`);
        makeMkv(source, { seconds: 30 });
        assets.push(await assetFor(source, { id: name }));
      }
      const [one, two, three] = assets as [PlaybackAsset, PlaybackAsset, PlaybackAsset];
      const playback = await service({ maxConcurrent: 2, ffmpegPath: slowFfmpeg(dir, 8) });
      await playback.prepare(one);
      await playback.prepare(two);
      expect((await playback.prepare(three)).state).toBe("queued");

      await waitFor(async () => (await playback.status(one))?.state === "preparing");
      await waitFor(async () => (await playback.status(two))?.state === "preparing");
      expect((await playback.status(three))?.state).toBe("queued");
      // Asking again does not start it twice or jump the queue.
      expect((await playback.prepare(three)).state).toBe("queued");

      await waitFor(async () => (await playback.status(three))?.state === "ready");
      expect((await playback.status(one))?.state).toBe("ready");
      expect((await playback.status(two))?.state).toBe("ready");
    },
  );

  it(
    "prepares a copy ahead only while nothing else is asked for",
    { timeout: 180_000 },
    async () => {
      const ahead = join(dir, "ahead.mkv");
      makeMkv(ahead, { seconds: 60 });
      const wanted = join(dir, "wanted.mkv");
      makeMkv(wanted, { seconds: 30 });
      const background = await assetFor(ahead, { id: "ahead" });
      const interactive = await assetFor(wanted, { id: "wanted" });
      const playback = await service({ ffmpegPath: slowFfmpeg(dir, 4) });
      const written = async (): Promise<number> =>
        (await playback.status(background))?.preparedMs ?? 0;

      await playback.prepare(background, { background: true });
      expect(playback.peek("ahead", background.revision)).toMatchObject({ background: true });
      await waitFor(async () => (await written()) >= 12_000);

      // Someone wants to watch another file: the copy made ahead stands still meanwhile.
      await playback.prepare(interactive);
      await waitFor(async () => (await playback.status(interactive))?.state === "preparing");
      await new Promise((resolve) => setTimeout(resolve, 1500));
      const stoodAt = await written();
      // Looked at all the while the other file is prepared, not after: once it is ready the copy
      // made ahead goes on at once, and ffmpeg 6.1 then reads what it missed at full speed.
      const seen = new Set<number>();
      await waitFor(async () => {
        const at = await written();
        if ((await playback.status(interactive))?.state === "ready") return true;
        seen.add(at);
        return false;
      });
      expect([...seen]).toEqual([stoodAt]);
      expect(stoodAt).toBeLessThan(60_000);

      // And it goes on by itself afterwards.
      await waitFor(async () => (await playback.status(background))?.state === "ready");
    },
  );

  it(
    "holds a copy made ahead while someone watches, and makes it an ordinary job when it is asked for",
    { timeout: 180_000 },
    async () => {
      const source = join(dir, "ahead.mkv");
      makeMkv(source, { seconds: 20 });
      const asset = await assetFor(source, { id: "ahead" });
      const playback = await service();

      playback.holdBackground(true);
      expect((await playback.prepare(asset, { background: true })).state).toBe("queued");
      await new Promise((resolve) => setTimeout(resolve, 1000));
      expect(playback.peek("ahead", asset.revision)).toMatchObject({
        state: "queued",
        background: true,
      });
      expect(playback.peek("ahead", "another-revision")).toBeNull();

      // The viewer asks for this very file: it no longer waits for quiet.
      await playback.prepare(asset);
      expect(playback.peek("ahead", asset.revision)).toMatchObject({ background: false });
      await prepared(playback, asset);
      expect(playback.peek("ahead", asset.revision)).toMatchObject({ state: "ready" });

      // Stopping a held, stopped job on shutdown does not hang.
      const other = join(dir, "other.mkv");
      makeMkv(other, { seconds: 60 });
      const second = await assetFor(other, { id: "other" });
      playback.holdBackground(false);
      const slow = await service({ ffmpegPath: slowFfmpeg(dir, 1) });
      await slow.prepare(second, { background: true });
      await waitFor(async () => (await slow.status(second))?.state === "preparing");
      slow.holdBackground(true);
      const started = Date.now();
      await slow.close();
      expect(Date.now() - started).toBeLessThan(4000);
    },
  );

  it("replaces the copy when the file's revision changes", async () => {
    const source = join(dir, "film.mkv");
    makeMkv(source);
    const playback = await service();
    const old = await assetFor(source, { revision: "rev-1" });
    await prepared(playback, old);
    const oldMedia = mediaPath(playback, old);

    const changed = await assetFor(source, { revision: "rev-2" });
    expect(await playback.status(changed)).toBeNull();
    expect(playback.resolveFile(changed.id, "rev-2", "media.mp4")).toBeNull();
    await prepared(playback, changed);

    expect(playback.resolveFile(old.id, "rev-1", "media.mp4")).toBeNull();
    expect(await playback.status(old)).toBeNull();
    expect(mediaPath(playback, changed)).toBe(oldMedia);
    expect(readdirSync(join(cacheDir, "prepared"))).toHaveLength(1);
  });

  it(
    "evicts the least recently used copies to stay inside the cache limit",
    { timeout: 180_000 },
    async () => {
      const assets: PlaybackAsset[] = [];
      for (const name of ["one", "two", "three"]) {
        const source = join(dir, `${name}.mkv`);
        makeMkv(source);
        assets.push(await assetFor(source, { id: name }));
      }
      const [one, two, three] = assets as [PlaybackAsset, PlaybackAsset, PlaybackAsset];
      // Room for two copies, not three.
      const playback = await service({ maxCacheBytes: Math.round(one.sizeBytes * 2.5) });

      await prepared(playback, one);
      clock.now += 600_000;
      await prepared(playback, two);
      clock.now += 600_000;
      // Using the first copy makes the second the oldest.
      expect(playback.resolveFile(one.id, one.revision, "media.mp4")).not.toBeNull();
      clock.now += 600_000;
      await prepared(playback, three);

      expect((await playback.status(one))?.state).toBe("ready");
      expect(await playback.status(two)).toBeNull();
      expect((await playback.status(three))?.state).toBe("ready");
      expect(playback.cacheBytes()).toBeLessThanOrEqual(Math.round(one.sizeBytes * 2.5));
      expect(readdirSync(join(cacheDir, "prepared"))).toHaveLength(2);
    },
  );

  it("fails with a reason when a file is larger than the whole cache", async () => {
    const source = join(dir, "film.mkv");
    makeMkv(source);
    const asset = await assetFor(source);
    const playback = await service({ maxCacheBytes: Math.round(asset.sizeBytes / 2) });
    await playback.prepare(asset);
    const failed = await waitFor(async () => {
      const status = await playback.status(asset);
      return status?.state === "failed" ? status : null;
    });
    expect(failed.error).toBe("This file is larger than the space set aside for prepared copies.");
    expect(readdirSync(join(cacheDir, "prepared"))).toEqual([]);
  });

  it("keeps finished copies over a restart and deletes what a crash left half-written", async () => {
    const source = join(dir, "film.mkv");
    makeMkv(source, { subtitles: ["eng"] });
    const asset = await assetFor(source);
    const first = await service();
    await prepared(first, asset);
    const media = mediaPath(first, asset);
    await first.close();

    // What a killed server leaves: a folder whose meta file never said "complete",
    // a folder without a meta file, and a subtitle that was being written.
    const crashed = join(cacheDir, "prepared", "0123456789abcdef0123456789abcdef");
    mkdirSync(crashed);
    writeFileSync(join(crashed, "media.mp4"), "half a film");
    writeFileSync(join(crashed, "index.m3u8"), "#EXTM3U\n");
    writeFileSync(
      join(crashed, "meta.json"),
      JSON.stringify({ assetId: "other", revision: "r", complete: false }),
    );
    const stray = join(cacheDir, "prepared", "stray");
    mkdirSync(stray);
    writeFileSync(join(stray, "media.mp4"), "no meta file");
    writeFileSync(join(cacheDir, "subtitles", "abc.vtt.partial"), "WEBVTT\n");

    const second = await service();
    expect(existsSync(crashed)).toBe(false);
    expect(existsSync(stray)).toBe(false);
    expect(readdirSync(join(cacheDir, "subtitles")).some((name) => name.endsWith(".partial"))).toBe(
      false,
    );
    expect(await second.status(asset)).toMatchObject({ state: "ready", progress: 1 });
    expect(mediaPath(second, asset)).toBe(media);
    expect(existsSync(media)).toBe(true);
    // The subtitle written by the first run is still there too.
    expect(readFileSync(await second.subtitle(asset, "e2"), "utf8")).toContain("Embedded eng 1");

    // With the drive unplugged the copy and its subtitle still play; nothing new can be made.
    const unplugged = { ...asset, available: false };
    expect((await second.prepare(unplugged)).state).toBe("ready");
    expect(readFileSync(await second.subtitle(unplugged, "e2"), "utf8")).toContain("WEBVTT");
    await expect(
      second.prepare({ ...unplugged, id: "another", revision: "r" }),
    ).rejects.toMatchObject({ code: "unavailable" });
  });

  it("only ever resolves the two known file names", async () => {
    const source = join(dir, "film.mkv");
    makeMkv(source);
    const asset = await assetFor(source);
    const playback = await service();
    await prepared(playback, asset);
    writeFileSync(join(dir, "secret.txt"), "not for devices");

    for (const name of [
      "meta.json",
      "../meta.json",
      "..",
      ".",
      "",
      "media.mp4/../meta.json",
      "../../../secret.txt",
      "/etc/passwd",
      "media.mp4\0.txt",
      "index.m3u8.tmp",
      "audio-0.mp4",
      "audio-100.mp4",
      "audio-1.mp4/../meta.json",
      "audio-1.vtt",
      "MEDIA.MP4",
      "constructor",
      "__proto__",
    ]) {
      expect(playback.resolveFile(asset.id, asset.revision, name), name).toBeNull();
    }
    // An asset id is hashed before it becomes a folder name, whatever it holds.
    const sneaky = { ...asset, id: "../../library" };
    await prepared(playback, sneaky);
    const resolved = mediaPath(playback, sneaky);
    expect(resolved.startsWith(join(cacheDir, "prepared") + "/")).toBe(true);
    expect(resolved).toMatch(/prepared\/[0-9a-f]{32}\/media\.mp4$/);
  });

  it("reports a file ffmpeg cannot read as failed, and tries again when asked again", async () => {
    const source = join(dir, "broken.mkv");
    makeMkv(source);
    const asset = await assetFor(source);
    writeFileSync(source, "this is not a video file any more");
    const playback = await service();
    await playback.prepare(asset);
    const failed = await waitFor(async () => {
      const status = await playback.status(asset);
      return status?.state === "failed" ? status : null;
    });
    expect(failed.error).toBe("This file could not be prepared for playback.");
    expect(playback.resolveFile(asset.id, asset.revision, "media.mp4")).toBeNull();
    expect(readdirSync(join(cacheDir, "prepared"))).toEqual([]);

    makeMkv(source);
    await prepared(playback, asset);
    expect((await playback.status(asset))?.state).toBe("ready");
  });

  it.skipIf(!hasEncoder("libmp3lame"))(
    "converts an AVI with MPEG-4 video and MP3 sound to H.264 and AAC",
    { timeout: 180_000 },
    async () => {
      const source = join(dir, "library", "old.avi");
      makeAvi(source);
      const before = sha256(source);
      const asset = await assetFor(source);
      expect(asset.playability).toBe("transcode");
      expect(streamsOf(source)[0]).toMatchObject({ codec_name: "mpeg4", codec_tag_string: "XVID" });

      const playback = await service();
      expect((await playback.prepare(asset)).videoConverted).toBe(true);
      await prepared(playback, asset);
      const status = await playback.status(asset);
      expect(status).toMatchObject({ state: "ready", videoConverted: true, speed: null });
      expect(status?.audio).toMatchObject([{ codec: "aac", converted: true, channels: 1 }]);

      const media = mediaPath(playback, asset);
      const streams = streamsOf(media);
      expect(streams[0]).toMatchObject({
        codec_name: "h264",
        codec_tag_string: "avc1",
        pix_fmt: "yuv420p",
        width: 160,
        height: 90,
      });
      expect(streams[1]).toMatchObject({ codec_name: "aac" });

      // 14 seconds with a keyframe forced every 6: segments of 6, 6 and 2 seconds.
      const playlist = readFileSync(join(media, "..", "index.m3u8"), "utf8");
      const lengths = [...playlist.matchAll(/#EXTINF:([0-9.]+)/g)].map((match) =>
        Math.round(Number(match[1])),
      );
      expect(lengths).toEqual([6, 6, 2]);
      expect(readStreamPlaylist(playlist).ended).toBe(true);
      expect(sha256(source)).toBe(before);

      // The flag survives a restart.
      await playback.close();
      const second = await service();
      expect(await second.status(asset)).toMatchObject({ state: "ready", videoConverted: true });
    },
  );

  it.skipIf(!hasEncoder("libmp3lame"))(
    "converts one file at a time and lets files that are only repackaged pass",
    { timeout: 180_000 },
    async () => {
      const assets: PlaybackAsset[] = [];
      for (const name of ["one", "two"]) {
        const source = join(dir, `${name}.avi`);
        makeAvi(source, { seconds: 40 });
        assets.push(await assetFor(source, { id: name }));
      }
      const mkv = join(dir, "three.mkv");
      makeMkv(mkv, { seconds: 40 });
      assets.push(await assetFor(mkv, { id: "three" }));
      const [one, two, three] = assets as [PlaybackAsset, PlaybackAsset, PlaybackAsset];

      const playback = await service({ maxConcurrent: 3, ffmpegPath: slowFfmpeg(dir, 4) });
      await playback.prepare(one);
      await playback.prepare(two);
      await playback.prepare(three);
      await waitFor(async () => (await playback.status(one))?.state === "preparing");
      await waitFor(async () => (await playback.status(three))?.state === "preparing");
      // There is a free slot, but the second conversion waits for the first.
      expect((await playback.status(two))?.state).toBe("queued");

      await waitFor(async () => (await playback.status(one))?.state === "ready");
      await waitFor(async () => (await playback.status(two))?.state === "ready");
      expect((await playback.status(three))?.state).toBe("ready");
    },
  );

  it.skipIf(!hasEncoder("libmp3lame"))(
    "holds the stream back while a conversion runs slower than the film plays",
    { timeout: 180_000 },
    async () => {
      const source = join(dir, "slow.avi");
      makeAvi(source, { seconds: 50 });
      const asset = await assetFor(source);
      // The real ffmpeg, reading at 0.6 times playback speed.
      const playback = await service({ ffmpegPath: slowFfmpeg(dir, 0.6) });
      await playback.prepare(asset);
      const status = await waitFor(async () => {
        const current = await playback.status(asset);
        return current && current.preparedMs >= 30_000 ? current : null;
      });
      // 30 seconds would do for a fast copy. Here a viewer would catch up before the end.
      expect(status).toMatchObject({ state: "preparing", streamable: false, videoConverted: true });
      expect(status.speed).toBeLessThan(1);
      expect(status.speed).toBeGreaterThan(0);
      expect(status.preparedMs).toBeLessThan(42_000);
    },
  );

  it("refuses files it cannot repackage or convert", async () => {
    const source = join(dir, "old.mkv");
    makeMkv(source, { video: "mpeg2video" });
    const asset = await assetFor(source);
    const playback = await service();
    await expect(playback.prepare(asset)).rejects.toMatchObject({ code: "unsupported" });
    await expect(
      playback.prepare({ ...(await assetFor(source)), available: false }),
    ).rejects.toBeInstanceOf(PlaybackError);
  });
});
