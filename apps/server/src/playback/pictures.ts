// SPDX-License-Identifier: MPL-2.0
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { rename, rm, writeFile } from "node:fs/promises";
import { setPriority } from "node:os";
import { createInterface } from "node:readline";
import { crc32, deflateSync } from "node:zlib";

/**
 * Subtitles stored as pictures (PGS from Blu-ray, DVD, DVB), made into what an app can draw over
 * the picture itself: each cue's picture as a PNG, cut to what it shows, with its place on the
 * screen and its times (docs/decisions.md, "Subtitles per viewer"). AVPlayer shows no picture subtitles in a
 * stream, and they cannot become text without OCR.
 *
 * ffmpeg decodes the track, whatever kind of picture subtitle it is, and draws it onto a canvas
 * of the video's size ("sub2video"): a frame each time the subtitle changes. Those frames come
 * through a pipe as raw RGBA, so nothing large is written to disk.
 */
export const PICTURE_SUBTITLE_CODECS: ReadonlySet<string> = new Set([
  "hdmv_pgs_subtitle",
  "pgssub",
  "dvd_subtitle",
  "dvdsub",
  "dvb_subtitle",
  "dvbsub",
]);

export interface PictureCue {
  startMs: number;
  endMs: number;
  /** Where the picture goes on a screen of `PictureSubtitles.width` × `height`. */
  x: number;
  y: number;
  width: number;
  height: number;
  /** The picture: a PNG with transparency, in base64. */
  png: string;
}

export interface PictureSubtitles {
  /** The screen the cues are placed on: the size of the video. */
  width: number;
  height: number;
  cues: PictureCue[];
}

export type PictureInput =
  { kind: "embedded"; path: string; streamIndex: number } | { kind: "sidecar"; path: string };

/** Far more than any film has: a stream that goes on beyond it is broken. */
const MAX_CUES = 20_000;
/** ffmpeg's last frame of a track can carry a time far beyond the end of the film. */
const LATEST_MS = 48 * 3_600_000;
/** How long a cue that is never cleared stays, when the film's length is unknown. */
const LONGEST_UNCLEARED_MS = 5_000;

interface Frame {
  ms: number;
  width: number;
  height: number;
}

interface OpenCue {
  startMs: number;
  key: string;
  box: { x: number; y: number; width: number; height: number };
  png: string;
}

/**
 * The smallest box around what is not fully transparent, or null for an empty frame. Only the
 * alpha counts: a transparent pixel may still carry a colour from the palette.
 */
export function visibleBox(
  rgba: Uint8Array,
  width: number,
  height: number,
): { x: number; y: number; width: number; height: number } | null {
  const pixels = new Uint32Array(rgba.buffer, rgba.byteOffset, width * height);
  let top = -1;
  let bottom = -1;
  let left = width;
  let right = -1;
  for (let y = 0; y < height; y += 1) {
    const row = y * width;
    let first = -1;
    for (let x = 0; x < width; x += 1) {
      if ((pixels[row + x] ?? 0) > 0xffffff) {
        first = x;
        break;
      }
    }
    if (first === -1) continue;
    let last = first;
    for (let x = width - 1; x > first; x -= 1) {
      if ((pixels[row + x] ?? 0) > 0xffffff) {
        last = x;
        break;
      }
    }
    if (top === -1) top = y;
    bottom = y;
    if (first < left) left = first;
    if (last > right) right = last;
  }
  if (top === -1) return null;
  return { x: left, y: top, width: right - left + 1, height: bottom - top + 1 };
}

function chunk(type: string, data: Buffer): Buffer {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([length, body, crc]);
}

/** A part of an RGBA frame as a PNG. */
export function pngOf(
  rgba: Uint8Array,
  frameWidth: number,
  box: { x: number; y: number; width: number; height: number },
): Buffer {
  const stride = box.width * 4;
  const raw = Buffer.alloc((stride + 1) * box.height);
  for (let y = 0; y < box.height; y += 1) {
    const from = ((box.y + y) * frameWidth + box.x) * 4;
    // Filter type 0 (none) before each row.
    raw.set(rgba.subarray(from, from + stride), y * (stride + 1) + 1);
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(box.width, 0);
  header.writeUInt32BE(box.height, 4);
  header[8] = 8; // bits per channel
  header[9] = 6; // RGBA
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

/**
 * Reads one picture subtitle track into cues. The whole file is read: the cues are spread
 * through it.
 *
 * @param durationMs the film's length, for a last cue that is never cleared
 */
export function readPictureSubtitles(
  input: PictureInput,
  options: { ffmpegPath?: string; durationMs?: number | null; niceness?: number } = {},
): Promise<PictureSubtitles> {
  const stream = input.kind === "embedded" ? `0:${String(input.streamIndex)}` : "0:s:0";
  const args = [
    "-nostdin",
    "-hide_banner",
    "-v",
    "info",
    // The cues' own times, as the text subtitles have them: not moved to start at the first.
    "-copyts",
    "-i",
    input.path,
    "-filter_complex",
    `[${stream}]showinfo[pictures]`,
    "-map",
    "[pictures]",
    "-fps_mode",
    "passthrough",
    "-f",
    "rawvideo",
    "-pix_fmt",
    "rgba",
    "pipe:1",
  ];
  const child = spawn(options.ffmpegPath ?? "ffmpeg", args, { stdio: ["ignore", "pipe", "pipe"] });
  if (child.pid !== undefined) {
    try {
      setPriority(child.pid, options.niceness ?? 10);
    } catch {
      // Not allowed here: it runs at the same priority, which is only slower for the rest.
    }
  }

  return new Promise((resolve, reject) => {
    const frames: Frame[] = [];
    let screen: { width: number; height: number } | null = null;
    let pending: Buffer[] = [];
    let pendingBytes = 0;
    let used = 0;
    const cues: PictureCue[] = [];
    let open: OpenCue | null = null;
    let lastMs = 0;
    let failure: Error | null = null;
    const errors: string[] = [];

    const close = (atMs: number): void => {
      if (!open) return;
      if (atMs > open.startMs) {
        cues.push({ startMs: open.startMs, endMs: atMs, ...open.box, png: open.png });
      }
      open = null;
    };

    const take = (frame: Frame, rgba: Uint8Array): void => {
      if (frame.ms > LATEST_MS) return;
      lastMs = Math.max(lastMs, frame.ms);
      const box = visibleBox(rgba, frame.width, frame.height);
      if (!box) {
        close(frame.ms);
        return;
      }
      const png = pngOf(rgba, frame.width, box);
      const key = createHash("sha256")
        .update(`${String(box.x)},${String(box.y)},`)
        .update(png)
        .digest("hex");
      // ffmpeg repeats the frame on screen just before each change.
      if (open?.key === key) return;
      close(frame.ms);
      if (cues.length >= MAX_CUES) {
        failure = new Error("The subtitle track has more cues than a film has.");
        child.kill("SIGKILL");
        return;
      }
      open = { startMs: frame.ms, key, box, png: png.toString("base64") };
    };

    // A frame's bytes may arrive before ffmpeg's line about it, or after.
    const drain = (): void => {
      while (used < frames.length) {
        const frame = frames[used];
        if (!frame) return;
        const size = frame.width * frame.height * 4;
        if (pendingBytes < size) return;
        const joined = pending.length === 1 ? pending[0] : Buffer.concat(pending);
        if (!joined) return;
        // A copy of its own: the pixels are read four bytes at a time.
        const rgba = new Uint8Array(size);
        rgba.set(joined.subarray(0, size));
        const rest = joined.subarray(size);
        pending = rest.length > 0 ? [rest] : [];
        pendingBytes = rest.length;
        used += 1;
        take(frame, rgba);
      }
    };

    child.stdout.on("data", (data: Buffer) => {
      pending.push(data);
      pendingBytes += data.length;
      drain();
    });
    const lines = createInterface({ input: child.stderr });
    lines.on("line", (line) => {
      const shown =
        /\bn:\s*\d+\s+pts:\s*-?\d+\s+pts_time:(-?[\d.]+(?:e[+-]?\d+)?).*?\ss:(\d+)x(\d+)/.exec(
          line,
        );
      if (shown) {
        const width = Number(shown[2]);
        const height = Number(shown[3]);
        screen ??= { width, height };
        frames.push({ ms: Math.max(0, Math.round(Number(shown[1]) * 1000)), width, height });
        drain();
      } else if (/error|invalid/i.test(line) && errors.length < 5) {
        errors.push(line);
      }
    });
    child.on("error", reject);
    child.on("close", (code) => {
      drain();
      if (failure) {
        reject(failure);
        return;
      }
      if (code !== 0) {
        reject(new Error(`ffmpeg ended with ${String(code)}: ${errors.join(" ")}`));
        return;
      }
      if (open) {
        const end = options.durationMs ?? open.startMs + LONGEST_UNCLEARED_MS;
        close(Math.max(end, lastMs));
      }
      resolve({ width: screen?.width ?? 0, height: screen?.height ?? 0, cues });
    });
  });
}

/** Writes the cues as JSON, under their final name only when complete. */
export async function writePictureSubtitles(
  input: PictureInput,
  outputPath: string,
  options: { ffmpegPath?: string; durationMs?: number | null } = {},
): Promise<void> {
  const pictures = await readPictureSubtitles(input, options);
  const partial = `${outputPath}.partial`;
  try {
    await writeFile(partial, JSON.stringify(pictures));
    await rename(partial, outputPath);
  } catch (error) {
    await rm(partial, { force: true });
    throw error;
  }
}
