// SPDX-License-Identifier: MPL-2.0
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { inflateSync } from "node:zlib";
import { afterEach, describe, expect, it } from "vitest";
import { pngOf, readPictureSubtitles, visibleBox } from "../src/playback/pictures.ts";
import { block, writePgs } from "./support/pgs.ts";

const folders: string[] = [];
afterEach(() => {
  for (const folder of folders.splice(0)) rmSync(folder, { recursive: true, force: true });
});

function folder(): string {
  const made = mkdtempSync(join(tmpdir(), "lobby-pictures-"));
  folders.push(made);
  return made;
}

describe("picture subtitles", () => {
  it("finds what is drawn by its alpha only", () => {
    const rgba = new Uint8Array(4 * 4 * 4);
    // A transparent pixel with a colour: not drawn.
    rgba.set([255, 255, 255, 0], (0 * 4 + 0) * 4);
    rgba.set([255, 255, 255, 255], (1 * 4 + 2) * 4);
    rgba.set([255, 255, 255, 128], (2 * 4 + 1) * 4);
    expect(visibleBox(rgba, 4, 4)).toEqual({ x: 1, y: 1, width: 2, height: 2 });
    expect(visibleBox(new Uint8Array(16 * 4), 4, 4)).toBeNull();
  });

  it("writes a PNG of the part that is drawn", () => {
    const rgba = new Uint8Array(4 * 4 * 4);
    rgba.set([10, 20, 30, 255], (1 * 4 + 2) * 4);
    const png = pngOf(rgba, 4, { x: 2, y: 1, width: 1, height: 1 });
    expect([...png.subarray(1, 4)]).toEqual([0x50, 0x4e, 0x47]);
    expect(png.readUInt32BE(16)).toBe(1);
    expect(png.readUInt32BE(20)).toBe(1);
    const idatLength = png.readUInt32BE(33);
    const raw = inflateSync(png.subarray(41, 41 + idatLength));
    expect([...raw]).toEqual([0, 10, 20, 30, 255]);
  });

  it("reads each cue of a Blu-ray track with its time and place", async () => {
    const path = join(folder(), "film.sup");
    writePgs(
      path,
      [
        { startMs: 1_000, endMs: 2_500, picture: block(200, 40), x: 100, y: 600 },
        { startMs: 4_000, endMs: 5_000, picture: block(120, 30) },
      ],
      { width: 1280, height: 720 },
    );
    const pictures = await readPictureSubtitles({ kind: "sidecar", path }, { durationMs: 10_000 });
    expect(pictures.width).toBe(1280);
    expect(pictures.height).toBe(720);
    expect(pictures.cues.length).toBe(2);
    const [first, second] = pictures.cues;
    expect(first).toMatchObject({
      startMs: 1_000,
      endMs: 2_500,
      x: 100,
      y: 600,
      width: 200,
      height: 40,
    });
    expect(second).toMatchObject({ startMs: 4_000, endMs: 5_000, width: 120, height: 30 });
    expect(
      Buffer.from(first?.png ?? "", "base64")
        .subarray(1, 4)
        .toString("ascii"),
    ).toBe("PNG");
  });

  it("reads a track inside a film by its stream", async () => {
    const dir = folder();
    const sup = join(dir, "film.sup");
    writePgs(sup, [{ startMs: 1_500, endMs: 3_000, picture: block(160, 32) }], {
      width: 640,
      height: 360,
    });
    const film = join(dir, "film.mkv");
    execFileSync("ffmpeg", [
      "-nostdin",
      "-v",
      "error",
      "-f",
      "lavfi",
      "-i",
      "color=black:s=640x360:d=5",
      // As a film has it: the cue at 1.5 s into the film.
      "-copyts",
      "-i",
      sup,
      "-map",
      "0:v",
      "-map",
      "1:s",
      "-c:v",
      "libx264",
      "-preset",
      "ultrafast",
      "-c:s",
      "copy",
      film,
    ]);
    const pictures = await readPictureSubtitles(
      { kind: "embedded", path: film, streamIndex: 1 },
      { durationMs: 5_000 },
    );
    expect(pictures.cues).toHaveLength(1);
    expect(pictures.cues[0]).toMatchObject({
      startMs: 1_500,
      endMs: 3_000,
      width: 160,
      height: 32,
    });
  });

  it("fails when ffmpeg cannot read the file", async () => {
    const path = join(folder(), "missing.sup");
    await expect(readPictureSubtitles({ kind: "sidecar", path })).rejects.toThrow();
  });
});
