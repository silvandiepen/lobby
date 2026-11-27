// SPDX-License-Identifier: MPL-2.0
import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { conversionArguments, targetFor } from "../src/conversion/convert.ts";
import { Database } from "../src/db/database.ts";
import { DeviceDownloads } from "../src/devices-downloads/index.ts";
import { createAssetLookup } from "../src/http/playback-assets.ts";
import { Catalogue } from "../src/library/catalogue.ts";
import { interpretProbe, probeFile } from "../src/library/probe.ts";
import { Scanner } from "../src/library/scanner.ts";
import { VideoTags } from "../src/library/video-tags.ts";
import { ffmpegArguments, MEDIA_FILE, planPreparation } from "../src/playback/plan.ts";
import type { PlaybackAsset } from "../src/playback/types.ts";
import { hasEncoder, streamsOf } from "./playback-support.ts";
import { makeTempDir, removeDir } from "./support/media.ts";

const x265 = hasEncoder("libx265");

/** A second of HEVC with AAC, labelled as asked. Matroska has no labels at all. */
function makeHevc(path: string, tag: "hev1" | "hvc1" | null): void {
  mkdirSync(dirname(path), { recursive: true });
  execFileSync("ffmpeg", [
    "-v",
    "error",
    "-y",
    "-f",
    "lavfi",
    "-i",
    "testsrc2=size=160x90:rate=10:duration=1",
    "-f",
    "lavfi",
    "-i",
    "sine=frequency=440:duration=1",
    "-c:v",
    "libx265",
    "-x265-params",
    "log-level=error",
    "-pix_fmt",
    "yuv420p",
    ...(tag ? ["-tag:v", tag] : []),
    "-c:a",
    "aac",
    path,
  ]);
}

function asset(container: string, codecTag: string | null, path: string): PlaybackAsset {
  return {
    id: "a",
    revision: "r1",
    path,
    sizeBytes: 1000,
    durationMs: 1000,
    available: true,
    playability: "remux",
    playabilityReason: null,
    tracks: [
      {
        index: 0,
        kind: "video",
        codec: "hevc",
        codecTag,
        language: null,
        title: null,
        channels: null,
        isDefault: true,
        isForced: false,
      },
      {
        index: 1,
        kind: "audio",
        codec: "aac",
        language: null,
        title: null,
        channels: 2,
        isDefault: true,
        isForced: false,
      },
    ],
    subtitles: [],
  };
}

function stream(tag: string): {
  index: number;
  codec_type: string;
  codec_name: string;
  codec_tag_string: string;
} {
  return { index: 0, codec_type: "video", codec_name: "hevc", codec_tag_string: tag };
}

describe("the HEVC label", () => {
  it("is kept, with Matroska's empty tag as none rather than unknown", () => {
    const hev1 = interpretProbe(
      { format: { format_name: "mov,mp4" }, streams: [stream("hev1")] },
      "/f.mp4",
    );
    expect(hev1.tracks[0]?.codecTag).toBe("hev1");
    expect(hev1.playability).toBe("remux");
    expect(hev1.playabilityReason).toContain("hev1");

    const hvc1 = interpretProbe(
      { format: { format_name: "mov,mp4" }, streams: [stream("hvc1")] },
      "/f.mp4",
    );
    expect(hvc1.playability).toBe("direct");

    const dolby = interpretProbe(
      { format: { format_name: "mov,mp4" }, streams: [stream("dvhe")] },
      "/f.mp4",
    );
    expect(dolby.playability).toBe("remux");

    const mkv = interpretProbe(
      { format: { format_name: "matroska,webm" }, streams: [stream("[0][0][0][0]")] },
      "/f.mkv",
    );
    expect(mkv.tracks[0]?.codecTag).toBe("");
    expect(mkv.playability).toBe("remux");
  });

  it("relabels every copied HEVC picture: hvc1, and dvh1 for Dolby Vision", () => {
    for (const [container, tag, expected] of [
      ["mp4", "hev1", "hvc1"],
      ["mkv", "", "hvc1"],
      ["mkv", null, "hvc1"],
      ["mp4", "dvhe", "dvh1"],
    ] as const) {
      const planned = planPreparation(asset(container, tag, `/library/film.${container}`));
      if (!planned.ok) throw new Error(planned.reason);
      expect(ffmpegArguments("/f", planned.plan, "/cache").join(" ")).toContain(
        `-c:v copy -tag:v ${expected}`,
      );
    }
    const target = targetFor("repackage", [{ ...base(), codecTag: "hev1" }]);
    if (!target) throw new Error("No target");
    expect(conversionArguments("/f.mp4", target, "/out.mp4").join(" ")).toContain(
      "-c:v copy -tag:v hvc1",
    );
  });

  describe.skipIf(!x265)("in real files", () => {
    let dir: string;
    beforeEach(() => {
      dir = makeTempDir();
    });
    afterEach(() => {
      removeDir(dir);
    });

    it("is read when probing, and a prepared copy of a hev1 MP4 is hvc1", async () => {
      const hev1 = join(dir, "hev1.mp4");
      const hvc1 = join(dir, "hvc1.mp4");
      makeHevc(hev1, "hev1");
      makeHevc(hvc1, "hvc1");
      expect(streamsOf(hev1)[0]).toMatchObject({ codec_tag_string: "hev1" });

      const probed = await probeFile(hev1);
      expect(probed.tracks.find((track) => track.kind === "video")?.codecTag).toBe("hev1");
      expect(probed.playability).toBe("remux");
      expect((await probeFile(hvc1)).playability).toBe("direct");

      const planned = planPreparation(asset("mp4", "hev1", hev1));
      if (!planned.ok) throw new Error(planned.reason);
      const out = join(dir, "prepared");
      mkdirSync(out);
      execFileSync("ffmpeg", ffmpegArguments(hev1, planned.plan, out), { stdio: "ignore" });
      expect(streamsOf(join(out, MEDIA_FILE))[0]).toMatchObject({
        codec_name: "hevc",
        codec_tag_string: "hvc1",
      });
    });

    describe("of files probed before it was kept", () => {
      let db: Database;
      let tags: VideoTags;
      let reads: number;

      beforeEach(async () => {
        const movies = join(dir, "Movies");
        makeHevc(join(movies, "Aladdin (1992)/Aladdin (1992).mp4"), "hev1");
        makeHevc(join(movies, "Up (2009)/Up (2009).mp4"), "hvc1");
        makeHevc(join(movies, "Cars (2006)/Cars (2006).mkv"), null);
        db = new Database(join(dir, "lobby.db"));
        const catalogue = new Catalogue(db);
        const scanner = new Scanner(db, catalogue, {
          stabilityMs: 0,
          probeConcurrency: 1,
          ffprobePath: "ffprobe",
          volumeOf: () => Promise.resolve(1),
        });
        scanner.syncSources([{ path: movies, name: "Movies", hint: "movies" }]);
        await scanner.scanAll();
        await scanner.processQueue();
        expect(
          db.all("select codec_tag from track where kind = 'video' order by codec_tag"),
        ).toEqual([{ codec_tag: "" }, { codec_tag: "hev1" }, { codec_tag: "hvc1" }]);
        // As a catalogue from before: no labels, and every MP4 judged to play as it is.
        db.run("update track set codec_tag = null");
        db.run(
          "update asset set playability = 'direct', playability_reason = null where container = 'mp4'",
        );
        reads = 0;
        tags = new VideoTags(db, {
          ffprobePath: "ffprobe",
          catalogue,
          probe: (path, ffprobe) => {
            reads += 1;
            return probeFile(path, ffprobe);
          },
        });
      });
      afterEach(() => {
        db.close();
      });

      const idOf = (name: string): string =>
        db.get<{ id: string }>("select id from asset where rel_path like ?", [`${name}%`])?.id ??
        "";

      it("reads the label before deciding to play a file as it is", async () => {
        expect(tags.pending().sort()).toEqual([idOf("Aladdin"), idOf("Up")].sort());
        // Matroska is repackaged and relabelled anyway: never in question, never read again.
        expect(tags.unchecked(idOf("Cars"))).toBe(false);

        const lookup = createAssetLookup(db, tags);
        const [aladdin, again] = await Promise.all([
          lookup(idOf("Aladdin")),
          lookup(idOf("Aladdin")),
        ]);
        expect(reads).toBe(1);
        expect(aladdin?.playability).toBe("remux");
        expect(again?.playability).toBe("remux");
        expect(aladdin?.tracks[0]?.codecTag).toBe("hev1");

        expect((await lookup(idOf("Up")))?.playability).toBe("direct");
        expect(tags.pending()).toEqual([]);
        await lookup(idOf("Up"));
        expect(reads).toBe(2);
      });

      it("does not offer a device the file as it is before its label is read", async () => {
        db.run(
          "insert into device (id, name, platform, role, token_hash, created_at) values ('d', 'iPad', 'ipados', 'viewer', 'h', 0)",
        );
        const downloads = new DeviceDownloads({ db, videoTags: tags });
        const itemId =
          db.get<{ item_id: string }>("select item_id from item_asset where asset_id = ?", [
            idOf("Aladdin"),
          ])?.item_id ?? "";
        downloads.add("d", { kind: "item", itemId }, "test");
        expect(downloads.list("d").assets[0]).toMatchObject({ state: "waiting", mode: null });
        await tags.ensure(idOf("Aladdin"));
        // Read now: it needs a relabelled copy, which only a server that prepares copies can offer.
        expect(downloads.list("d").assets[0]).toMatchObject({ state: "unsupported", mode: null });
        expect(tags.unchecked(idOf("Aladdin"))).toBe(false);
      });

      it("reads the rest in one pass in the background", async () => {
        expect(await tags.checkPending()).toBe(1);
        expect(tags.pending()).toEqual([]);
        expect(await tags.checkPending()).toBe(0);
        expect(reads).toBe(2);
      });
    });
  });
});

function base() {
  return {
    index: 0,
    kind: "video" as const,
    codec: "hevc",
    profile: null,
    language: null,
    title: null,
    channels: null,
    width: null,
    height: null,
    pixFmt: null,
    codecTag: null,
    isDefault: true,
    isForced: false,
  };
}
