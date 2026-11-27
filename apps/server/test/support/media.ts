// SPDX-License-Identifier: MPL-2.0
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

/**
 * Real, tiny video files made with ffmpeg, so tests exercise the real ffprobe
 * and the real file system instead of a stand-in.
 */
export interface MediaOptions {
  seconds?: number;
  /** ffmpeg video encoder: libx264 (default), mpeg4. */
  videoCodec?: string;
  audioCodec?: string;
  /** A second value makes the picture differ, so two files get different fingerprints. */
  seed?: number;
}

export function makeTempDir(prefix = "lobby-test-"): string {
  return mkdtempSync(join(tmpdir(), prefix));
}

export function removeDir(path: string): void {
  rmSync(path, { recursive: true, force: true });
}

export function makeVideo(path: string, options: MediaOptions = {}): void {
  mkdirSync(dirname(path), { recursive: true });
  const seconds = String(options.seconds ?? 1);
  execFileSync(
    "ffmpeg",
    [
      "-v",
      "error",
      "-y",
      "-f",
      "lavfi",
      "-i",
      `testsrc2=size=160x90:rate=10:duration=${seconds}`,
      "-f",
      "lavfi",
      "-i",
      `sine=frequency=${440 + (options.seed ?? 0) * 37}:duration=${seconds}`,
      "-c:v",
      options.videoCodec ?? "libx264",
      "-pix_fmt",
      "yuv420p",
      "-c:a",
      options.audioCodec ?? "aac",
      "-metadata",
      `comment=seed-${options.seed ?? 0}`,
      "-shortest",
      path,
    ],
    { stdio: ["ignore", "ignore", "inherit"] },
  );
}
