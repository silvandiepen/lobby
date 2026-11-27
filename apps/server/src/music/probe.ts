// SPDX-License-Identifier: MPL-2.0
import { spawn } from "node:child_process";
import { setPriority } from "node:os";
import { canonicalTags, readTags } from "./tags.ts";
import type { AudioTags, Chapter, TrackPlayability } from "./types.ts";

/**
 * The only formats an audio file may turn out to be. Without this list a text file named
 * "song.mp3" could be read as a playlist that points at other files.
 */
export const AUDIO_DEMUXERS = [
  ..."mp3 aac flac wav w64 aiff caf ogg asf ape wv tta tak mpc mpc8 dsf iff ac3 eac3 dts".split(
    " ",
  ),
  ...["mov,mp4,m4a,3gp,3g2,mj2", "matroska,webm", "amr"],
].join(",");
export const SAFE_INPUT = ["-protocol_whitelist", "file", "-format_whitelist", AUDIO_DEMUXERS];

const LOSSLESS = /^(?:flac|alac|ape|wavpack|tta|tak|mlp|truehd|pcm_.*|dsd_.*)$/;
const DIRECT_CODECS: Record<string, RegExp> = {
  mp3: /^mp3$/,
  flac: /^flac$/,
  mp4: /^(?:aac|alac|mp3|ac3|eac3)$/,
  aac: /^aac$/,
  wav: /^pcm_(?:u8|s16le|s24le|s32le|f32le)$/,
  aiff: /^pcm_(?:s8|s16be|s24be|s32be|f32be|s16le)$/,
  caf: /^(?:aac|alac|pcm_(?:s16|s24|s32|f32)[lb]e)$/,
  ac3: /^ac3$/,
  eac3: /^eac3$/,
};

export interface AudioProbe {
  container: string;
  codec: string;
  lossless: boolean;
  durationMs: number | null;
  bitRate: number | null;
  sampleRate: number | null;
  bitDepth: number | null;
  channels: number | null;
  playability: TrackPlayability;
  chapters: Chapter[];
  /** The stream that holds the embedded cover. */
  coverStream: number | null;
  tags: AudioTags;
}

interface Stream {
  index: number;
  codec_type?: string;
  codec_name?: string;
  sample_rate?: string;
  channels?: number;
  bits_per_raw_sample?: string;
  bits_per_sample?: number;
  bit_rate?: string;
  disposition?: Record<string, number>;
  tags?: Record<string, string>;
}

interface Output {
  format?: {
    format_name?: string;
    duration?: string;
    bit_rate?: string;
    tags?: Record<string, string>;
  };
  streams?: Stream[];
  chapters?: { start_time?: string; end_time?: string; tags?: Record<string, string> }[];
}

const positive = (value: string | number | undefined): number | null => {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? Math.round(number) : null;
};

const milliseconds = (seconds: string | undefined): number =>
  Math.max(0, Math.round(Number(seconds ?? "0") * 1000) || 0);

/** A front cover when the file says which one that is, else the first picture. */
function coverStream(streams: Stream[]): number | null {
  const pictures = streams.filter((stream) => stream.disposition?.["attached_pic"] === 1);
  const front = pictures.find((stream) => /front/i.test(stream.tags?.["comment"] ?? ""));
  return (front ?? pictures[0])?.index ?? null;
}

export function interpretAudio(output: Output, relPath: string): AudioProbe {
  const streams = output.streams ?? [];
  const sound = streams.find((stream) => stream.codec_type === "audio" && stream.codec_name);
  if (!sound?.codec_name) throw new Error("There is no sound in this file.");
  const names = (output.format?.format_name ?? "").split(",");
  const container = names.includes("mp4")
    ? "mp4"
    : names.includes("matroska")
      ? "mka"
      : (names[0] ?? "unknown");
  const durationMs = positive(Number(output.format?.duration ?? "0") * 1000);
  return {
    container,
    codec: sound.codec_name,
    lossless: LOSSLESS.test(sound.codec_name),
    durationMs,
    bitRate: positive(sound.bit_rate) ?? positive(output.format?.bit_rate),
    sampleRate: positive(sound.sample_rate),
    bitDepth: positive(sound.bits_per_raw_sample) ?? positive(sound.bits_per_sample),
    channels: positive(sound.channels),
    playability: DIRECT_CODECS[container]?.test(sound.codec_name) ? "direct" : "convert",
    chapters: (output.chapters ?? [])
      .map((chapter) => ({
        title: chapter.tags?.["title"]?.trim().slice(0, 300) || null,
        startMs: milliseconds(chapter.start_time),
        endMs: milliseconds(chapter.end_time),
      }))
      .filter((chapter) => chapter.endMs > chapter.startMs)
      .slice(0, 5000),
    coverStream: coverStream(streams),
    // Ogg keeps its tags on the stream, everything else on the file.
    tags: readTags(canonicalTags(output.format?.tags, sound.tags), relPath),
  };
}

/** Reads a file's headers and tags with ffprobe, at the lowest priority. */
export async function probeAudio(
  path: string,
  relPath: string,
  ffprobePath: string,
): Promise<AudioProbe> {
  const json = await runQuietly(ffprobePath, [
    ...["-v", "error", ...SAFE_INPUT, "-of", "json"],
    ...["-show_format", "-show_streams", "-show_chapters", "--", path],
  ]);
  return interpretAudio(JSON.parse(json.toString("utf8")) as Output, relPath);
}

const MAX_OUTPUT = 32 * 1024 * 1024;

/** Runs ffmpeg or ffprobe behind everything else on the machine, and hands over its output. */
export function runQuietly(
  command: string,
  args: string[],
  timeoutMs = 60_000,
  signal?: AbortSignal,
): Promise<Buffer<ArrayBuffer>> {
  return new Promise((resolve, reject) => {
    const limit = AbortSignal.timeout(timeoutMs);
    const child = spawn(command, args, {
      stdio: ["ignore", "pipe", "pipe"],
      signal: signal ? AbortSignal.any([limit, signal]) : limit,
      killSignal: "SIGKILL",
    });
    if (child.pid !== undefined) {
      try {
        setPriority(child.pid, 15);
      } catch {
        // It already finished.
      }
    }
    const output: Buffer[] = [];
    let size = 0;
    child.stdout.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > MAX_OUTPUT) child.kill("SIGKILL");
      else output.push(chunk);
    });
    let errors = "";
    child.stderr.on("data", (chunk: Buffer) => {
      errors = (errors + chunk.toString()).slice(-300);
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) resolve(Buffer.concat(output));
      else reject(new Error(errors.trim().split("\n").at(-1) ?? `ended with ${String(code)}`));
    });
  });
}
