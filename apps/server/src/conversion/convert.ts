// SPDX-License-Identifier: MPL-2.0
import { spawn, type ChildProcess } from "node:child_process";
import { setPriority } from "node:os";
import { createInterface } from "node:readline";
import type { Track } from "../library/probe.ts";
import { appleHevcTag, TEXT_SUBTITLES } from "../library/probe.ts";
import { CONVERT_CRF, CONVERT_PRESET } from "../playback/plan.ts";

/** h264: old MPEG-4 video to H.264. hevc: AV1 to HEVC. repackage: into MP4, nothing re-encoded. */
export type ConversionKind = "h264" | "hevc" | "repackage";

/** Sound that goes into MP4 as it is. The same rule as for playback (docs/playback.md). */
const COPY_AUDIO = new Set(["aac", "ac3", "eac3"]);

export interface AudioTarget {
  /** The stream's index in the original. */
  index: number;
  action: "copy" | "aac" | "ac3";
  channels: number | null;
  language: string | null;
}

/** What the converted file must contain. A worker on a Mac is told this; the server builds its own command from it. */
export interface ConversionTarget {
  container: "mp4";
  /** The index is at the front, so the file starts playing before it is fully fetched. */
  faststart: true;
  video: {
    index: number;
    action: "h264" | "hevc" | "copy";
    codec: string;
    /** The original's sample entry (`hev1`, `hvc1`, `dvhe`…); "" or null when none is known. */
    codecTag?: string | null;
  };
  audio: AudioTarget[];
  /** Text subtitles inside the file, kept as text. */
  subtitles: { index: number; language: string | null }[];
  keepChapters: true;
  /** What the server itself uses for H.264, as a reference for quality. */
  reference: { encoder: "libx264"; preset: string; crf: number };
}

/** Whether every sound track can go into MP4 untouched. */
export function audioIsCopyable(tracks: Track[]): boolean {
  return tracks
    .filter((track) => track.kind === "audio")
    .every((track) => COPY_AUDIO.has(track.codec));
}

/** What a conversion of this kind has to produce from these tracks. Every sound track, in the file's order. */
export function targetFor(kind: ConversionKind, tracks: Track[]): ConversionTarget | null {
  const video = tracks.find((track) => track.kind === "video");
  if (!video) return null;
  return {
    container: "mp4",
    faststart: true,
    video: {
      index: video.index,
      action: kind === "repackage" ? "copy" : kind,
      codec: video.codec,
      codecTag: video.codecTag,
    },
    audio: tracks
      .filter((track) => track.kind === "audio")
      .map((track): AudioTarget => {
        if (COPY_AUDIO.has(track.codec)) {
          return {
            index: track.index,
            action: "copy",
            channels: track.channels,
            language: track.language,
          };
        }
        const channels = track.channels === null ? null : Math.min(track.channels, 6);
        return {
          index: track.index,
          action: (channels ?? 2) > 2 ? "ac3" : "aac",
          channels,
          language: track.language,
        };
      }),
    subtitles: tracks
      .filter((track) => track.kind === "subtitle" && TEXT_SUBTITLES.has(track.codec))
      .map((track) => ({ index: track.index, language: track.language })),
    keepChapters: true,
    reference: { encoder: "libx264", preset: CONVERT_PRESET, crf: CONVERT_CRF },
  };
}

/**
 * The server's own ffmpeg command for a target. Unlike a copy made for streaming
 * (fragmented, in the cache) this is a library file: an ordinary MP4 with its
 * index at the front, all sound tracks, text subtitles, chapters and tags.
 */
export function conversionArguments(
  sourcePath: string,
  target: ConversionTarget,
  outputPath: string,
): string[] {
  const args = ["-nostdin", "-hide_banner", "-v", "error", "-progress", "pipe:1", "-y"];
  args.push("-i", sourcePath, "-map", `0:${target.video.index}`);
  for (const audio of target.audio) args.push("-map", `0:${audio.index}`);
  for (const subtitle of target.subtitles) args.push("-map", `0:${subtitle.index}`);

  if (target.video.action === "copy") {
    args.push("-c:v", "copy");
    // AVFoundation shows HEVC in MP4 only under the hvc1 tag (dvh1 for Dolby Vision).
    if (target.video.codec === "hevc") {
      args.push("-tag:v", appleHevcTag(target.video.codecTag ?? null));
    }
  } else if (target.video.action === "h264") {
    args.push(
      "-c:v",
      "libx264",
      "-preset",
      CONVERT_PRESET,
      "-crf",
      String(CONVERT_CRF),
      "-profile:v",
      "high",
      "-pix_fmt",
      "yuv420p",
      "-vf",
      "crop=trunc(iw/2)*2:trunc(ih/2)*2",
    );
  } else {
    throw new Error("The server does not convert to HEVC; that is a job for a Mac.");
  }

  target.audio.forEach((audio, position) => {
    if (audio.action === "copy") {
      args.push(`-c:a:${position}`, "copy");
    } else {
      args.push(
        `-c:a:${position}`,
        audio.action,
        `-b:a:${position}`,
        audio.action === "ac3" ? "640k" : "160k",
      );
      if (audio.channels !== null) args.push(`-ac:a:${position}`, String(audio.channels));
    }
  });
  if (target.subtitles.length > 0) args.push("-c:s", "mov_text");
  args.push("-map_metadata", "0", "-map_chapters", "0", "-movflags", "+faststart", "-f", "mp4");
  args.push(outputPath);
  return args;
}

/** A running ffmpeg that can be made to stand still, continued and stopped. */
export interface RunningConversion {
  done: Promise<{ code: number | null; stderr: string }>;
  setPaused: (paused: boolean) => void;
  cancel: () => void;
}

export function runConversion(
  ffmpegPath: string,
  args: string[],
  options: { niceness: number; onProgress: (outTimeMs: number) => void },
): RunningConversion {
  const child: ChildProcess = spawn(ffmpegPath, args, { stdio: ["ignore", "pipe", "pipe"] });
  let stderr = "";
  let paused = false;
  let ended = false;
  child.once("spawn", () => {
    if (child.pid === undefined) return;
    try {
      setPriority(child.pid, options.niceness);
    } catch {
      // The process can be gone already.
    }
    if (paused) child.kill("SIGSTOP");
  });
  if (child.stdout) {
    createInterface({ input: child.stdout }).on("line", (line) => {
      const match = /^out_time_us=(\d+)/.exec(line);
      if (match) options.onProgress(Math.round(Number(match[1]) / 1000));
    });
  }
  child.stderr?.setEncoding("utf8");
  child.stderr?.on("data", (chunk: string) => {
    stderr = (stderr + chunk).slice(-4000);
  });
  const done = new Promise<{ code: number | null; stderr: string }>((resolve) => {
    child.once("error", (error) => {
      ended = true;
      resolve({ code: null, stderr: stderr + error.message });
    });
    child.once("close", (code) => {
      ended = true;
      resolve({ code, stderr });
    });
  });
  return {
    done,
    setPaused: (next) => {
      if (ended || next === paused) return;
      paused = next;
      child.kill(next ? "SIGSTOP" : "SIGCONT");
    },
    cancel: () => {
      if (ended) return;
      // A stopped process does not see SIGTERM until it is continued.
      if (paused) child.kill("SIGCONT");
      paused = false;
      child.kill("SIGTERM");
      setTimeout(() => {
        if (!ended) child.kill("SIGKILL");
      }, 5000).unref();
    },
  };
}
