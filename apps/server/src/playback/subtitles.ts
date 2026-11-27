// SPDX-License-Identifier: MPL-2.0
import { execFile } from "node:child_process";
import { readFile, rename, rm } from "node:fs/promises";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export type SubtitleInput =
  { kind: "embedded"; path: string; streamIndex: number } | { kind: "sidecar"; path: string };

function isUtf8(bytes: Uint8Array): boolean {
  try {
    new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    return true;
  } catch {
    return false;
  }
}

/**
 * Converts a text subtitle (SubRip, ASS/SSA, mov_text, WebVTT) to a WebVTT file with ffmpeg.
 *
 * The output appears under its final name only when it is complete. An embedded
 * track costs a read of the whole video file, because subtitle lines are spread
 * through it; a sidecar file is converted in milliseconds.
 */
export async function convertSubtitle(
  input: SubtitleInput,
  outputPath: string,
  ffmpegPath = "ffmpeg",
): Promise<void> {
  const args = ["-nostdin", "-hide_banner", "-v", "error", "-y"];
  if (input.kind === "sidecar") {
    // Old subtitle files are often Windows-1252. ffmpeg assumes UTF-8 unless told otherwise.
    if (!isUtf8(await readFile(input.path))) args.push("-sub_charenc", "WINDOWS-1252");
    args.push("-i", input.path, "-map", "0:s:0");
  } else {
    args.push("-i", input.path, "-map", `0:${input.streamIndex}`);
  }
  const partial = `${outputPath}.partial`;
  args.push("-c:s", "webvtt", "-f", "webvtt", partial);
  try {
    await execFileAsync(ffmpegPath, args, { maxBuffer: 1024 * 1024 });
    await rename(partial, outputPath);
  } catch (error) {
    await rm(partial, { force: true });
    throw error;
  }
}
