// SPDX-License-Identifier: MPL-2.0
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { probeFile } from "../src/library/probe.ts";
import type { PlaybackAsset, PlaybackSubtitle } from "../src/playback/types.ts";

/**
 * Real media for the playback tests, made with the local ffmpeg at test time:
 * Matroska files with the mixes of tracks real libraries have.
 */
export interface MkvOptions {
  seconds?: number;
  video?: "libx264" | "libx265" | "mpeg4" | "mpeg2video";
  /** Sound tracks in file order. `default` marks the one flagged as default. */
  audio?: {
    codec: "aac" | "libopus" | "ac3" | "dca";
    language?: string;
    default?: boolean;
    channels?: number;
  }[];
  /** Embedded SubRip tracks, by language. */
  subtitles?: string[];
}

function run(command: string, args: string[]): string {
  return execFileSync(command, args, { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] });
}

export function hasEncoder(name: string): boolean {
  return new RegExp(`^ \\S+ ${name} `, "m").test(run("ffmpeg", ["-hide_banner", "-encoders"]));
}

export function srt(seconds: number, label = "Line"): string {
  let text = "";
  for (let second = 1, cue = 1; second + 1 < seconds; second += 2, cue += 1) {
    const at = (value: number): string =>
      `00:${String(Math.floor(value / 60)).padStart(2, "0")}:${String(value % 60).padStart(2, "0")},000`;
    text += `${cue}\n${at(second)} --> ${at(second + 1)}\n${label} ${cue}\n\n`;
  }
  return text;
}

export function makeMkv(path: string, options: MkvOptions = {}): void {
  mkdirSync(dirname(path), { recursive: true });
  const seconds = options.seconds ?? 14;
  const audio = options.audio ?? [{ codec: "aac" as const, default: true }];
  const subtitles = options.subtitles ?? [];
  const args = ["-v", "error", "-y"];
  // A keyframe every second, so a few seconds of video already make several segments.
  args.push("-f", "lavfi", "-i", `testsrc2=size=160x90:rate=10:duration=${seconds}`);
  audio.forEach((_, index) => {
    args.push("-f", "lavfi", "-i", `sine=frequency=${440 + index * 220}:duration=${seconds}`);
  });
  subtitles.forEach((language, index) => {
    const file = `${path}.${index}.srt`;
    writeFileSync(file, srt(seconds, `Embedded ${language}`));
    args.push("-i", file);
  });
  args.push("-map", "0:v");
  audio.forEach((_, index) => args.push("-map", `${index + 1}:a`));
  subtitles.forEach((_, index) => args.push("-map", `${audio.length + 1 + index}:s`));
  args.push("-c:v", options.video ?? "libx264", "-pix_fmt", "yuv420p", "-g", "10");
  if (options.video === "libx265") args.push("-x265-params", "log-level=error");
  audio.forEach((track, index) => {
    args.push(`-c:a:${index}`, track.codec);
    // The DTS encoder is marked experimental in ffmpeg and wants 48 kHz.
    if (track.codec === "dca") {
      args.push(`-ar:a:${index}`, "48000", `-ac:a:${index}`, String(track.channels ?? 2));
    }
    if (track.codec === "libopus") args.push(`-ar:a:${index}`, "48000");
    args.push(`-metadata:s:a:${index}`, `language=${track.language ?? "eng"}`);
    args.push(`-disposition:a:${index}`, track.default ? "default" : "0");
  });
  subtitles.forEach((language, index) => {
    args.push(`-c:s:${index}`, "srt", `-metadata:s:s:${index}`, `language=${language}`);
  });
  args.push("-strict", "experimental", "-f", "matroska", path);
  run("ffmpeg", args);
}

/**
 * An AVI like the household's old films: MPEG-4 Part 2 video with B-frames and MP3 sound.
 */
export function makeAvi(path: string, options: { seconds?: number } = {}): void {
  mkdirSync(dirname(path), { recursive: true });
  const seconds = options.seconds ?? 14;
  run("ffmpeg", [
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
    `sine=frequency=440:duration=${seconds}`,
    "-c:v",
    "mpeg4",
    "-vtag",
    "XVID",
    "-bf",
    "2",
    // Keyframes that do not fall on segment boundaries.
    "-g",
    "25",
    "-c:a",
    "libmp3lame",
    "-f",
    "avi",
    path,
  ]);
}

export function sha256(path: string): string {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

/** Builds the playback module's view of a file from a real ffprobe run. */
export async function assetFor(
  path: string,
  overrides: Partial<PlaybackAsset> = {},
  sidecars: { id: string; path: string; language?: string }[] = [],
): Promise<PlaybackAsset> {
  const probe = await probeFile(path);
  const info = statSync(path);
  const subtitles: PlaybackSubtitle[] = [
    ...probe.tracks
      .filter((track) => track.kind === "subtitle")
      .map((track): PlaybackSubtitle => ({
        id: `e${track.index}`,
        source: { kind: "embedded", streamIndex: track.index },
        codec: track.codec,
        language: track.language,
        title: track.title,
        isForced: track.isForced,
      })),
    ...sidecars.map((sidecar): PlaybackSubtitle => ({
      id: sidecar.id,
      source: { kind: "sidecar", path: sidecar.path },
      codec: "subrip",
      language: sidecar.language ?? null,
      title: null,
      isForced: false,
    })),
  ];
  return {
    id: "asset-1",
    revision: `${info.size}-${Math.round(info.mtimeMs)}`,
    path,
    sizeBytes: info.size,
    durationMs: probe.durationMs,
    available: true,
    playability: probe.playability,
    playabilityReason: probe.playabilityReason,
    tracks: probe.tracks.map((track) => ({
      index: track.index,
      kind: track.kind,
      codec: track.codec,
      language: track.language,
      title: track.title,
      channels: track.channels,
      isDefault: track.isDefault,
      isForced: track.isForced,
    })),
    subtitles,
    ...overrides,
  };
}

export interface ProbedStream {
  index: number;
  codec_type: string;
  codec_name: string;
  codec_tag_string: string;
  pix_fmt?: string;
  width?: number;
  height?: number;
  channels?: number;
  tags?: Record<string, string>;
  disposition?: Record<string, number>;
}

/**
 * Where a file's timeline starts, in milliseconds. ffmpeg 6.1 puts the AAC encoder's priming
 * before zero in an MKV it writes (-23 ms at 44.1 kHz); newer versions start at zero. What is
 * made from the file starts at its first packet, so its times are later by as much.
 */
export function startMsOf(path: string): number {
  const output = run("ffprobe", [
    "-v",
    "error",
    "-show_entries",
    "format=start_time",
    "-of",
    "csv=p=0",
    path,
  ]);
  return Math.round(Number(output.trim()) * 1000);
}

export function streamsOf(path: string): ProbedStream[] {
  const output = run("ffprobe", ["-v", "error", "-print_format", "json", "-show_streams", path]);
  return (JSON.parse(output) as { streams: ProbedStream[] }).streams;
}

/**
 * The real ffmpeg, slowed down to a multiple of real time, so a test can look at a
 * preparation while it is running. The same binary does the same work; only its
 * reading of the input is paced (`-readrate`).
 *
 * Only the preparation itself (the pass that reports `-progress`) is paced. A sidecar subtitle
 * is converted by the same program, and ffmpeg 6.1 paces a subtitle file too: a two-minute
 * SubRip took fifteen seconds at eight times real time, while the film was finished meanwhile.
 */
export function slowFfmpeg(dir: string, rate: number): string {
  const path = join(dir, `ffmpeg-readrate-${rate}`);
  writeFileSync(
    path,
    [
      "#!/bin/sh",
      'for arg in "$@"; do',
      `  [ "$arg" = -progress ] && exec ffmpeg -readrate ${String(rate)} "$@"`,
      "done",
      'exec ffmpeg "$@"',
      "",
    ].join("\n"),
  );
  chmodSync(path, 0o755);
  return path;
}

export async function waitFor<T>(
  check: () => Promise<T | null | undefined | false> | T | null | undefined | false,
  timeoutMs = 120_000,
): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > deadline) throw new Error("Timed out waiting for a condition.");
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
}
