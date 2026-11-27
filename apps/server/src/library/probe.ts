// SPDX-License-Identifier: MPL-2.0
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { open } from "node:fs/promises";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export type TrackKind = "video" | "audio" | "subtitle";

export interface Track {
  index: number;
  kind: TrackKind;
  codec: string;
  profile: string | null;
  language: string | null;
  title: string | null;
  channels: number | null;
  width: number | null;
  height: number | null;
  pixFmt: string | null;
  /**
   * The sample entry the container gives the codec (ffprobe's codec_tag_string), such as
   * `hvc1` or `hev1`. An empty string when the container has none (Matroska); null when it
   * has not been read yet (files probed before Lobby kept it).
   */
  codecTag: string | null;
  isDefault: boolean;
  isForced: boolean;
}

/**
 * How an Apple device can play a file.
 *
 * - `direct`: the file plays as it is.
 * - `remux`: the picture is fine, but the container or the sound has to be
 *   repackaged first. No re-encoding of video, so a Pi does it far faster than real time.
 * - `transcode`: the picture itself has to be re-encoded.
 * - `unsupported`: there is no picture Lobby can do anything with.
 */
export type Playability = "direct" | "remux" | "transcode" | "unsupported";

export interface ProbeResult {
  container: string;
  durationMs: number | null;
  bitRate: number | null;
  tracks: Track[];
  playability: Playability;
  playabilityReason: string | null;
}

interface FfprobeStream {
  index: number;
  codec_type?: string;
  codec_name?: string;
  profile?: string;
  width?: number;
  height?: number;
  pix_fmt?: string;
  codec_tag_string?: string;
  channels?: number;
  disposition?: Record<string, number>;
  tags?: Record<string, string>;
}

interface FfprobeOutput {
  format?: { format_name?: string; duration?: string; bit_rate?: string };
  streams?: FfprobeStream[];
}

// What AVFoundation plays from an MP4 or MOV file on current Apple hardware.
const DIRECT_CONTAINERS = new Set(["mp4", "mov", "m4v"]);
const DIRECT_VIDEO = new Set(["h264", "hevc"]);
const DIRECT_PIXEL_FORMATS = new Set(["yuv420p", "yuvj420p", "yuv420p10le"]);
const DIRECT_AUDIO = new Set(["aac", "ac3", "eac3", "mp3", "alac"]);
/**
 * The HEVC sample entries AVFoundation shows. Under `hev1` (and Dolby Vision's `dvhe`)
 * it plays the sound and leaves the picture black, so those files are repackaged with
 * the video copied and labelled `hvc1` (or `dvh1`).
 */
export const APPLE_HEVC_TAGS: ReadonlySet<string> = new Set(["hvc1", "dvh1"]);

/** The tag an MP4 for Apple devices gives copied HEVC that carried `tag` in its original. */
export function appleHevcTag(tag: string | null): "hvc1" | "dvh1" {
  return tag === "dvhe" || tag === "dvh1" ? "dvh1" : "hvc1";
}

/**
 * ffprobe's codec_tag_string as Lobby keeps it. Matroska has no sample entries, which
 * ffprobe prints as "[0][0][0][0]": that is kept as "" (known to have none), not as unknown.
 */
export function normaliseCodecTag(tag: string | undefined): string {
  if (tag === undefined || /^(\[0\])+$/.test(tag) || /^0x0+$/.test(tag)) return "";
  return tag;
}
// Subtitles that are text and can be handed to the player as WebVTT.
export const TEXT_SUBTITLES = new Set([
  "subrip",
  "srt",
  "ass",
  "ssa",
  "webvtt",
  "mov_text",
  "text",
]);

/**
 * The codec of a subtitle file beside a film, by its extension: the names ffmpeg gives the
 * same subtitles inside a file. Blu-ray `.sup` and VobSub `.idx` are pictures.
 */
export function sidecarCodec(format: string): string {
  switch (format) {
    case "vtt":
      return "webvtt";
    case "sup":
      return "hdmv_pgs_subtitle";
    case "idx":
      return "dvd_subtitle";
    default:
      return format;
  }
}

function containerName(formatName: string | undefined, path: string): string {
  const names = (formatName ?? "").split(",");
  const extension = path.slice(path.lastIndexOf(".") + 1).toLowerCase();
  if (names.includes("matroska")) return extension === "webm" ? "webm" : "mkv";
  if (names.includes("mp4") || names.includes("mov")) return extension === "mov" ? "mov" : "mp4";
  if (names.includes("avi")) return "avi";
  if (names.includes("mpegts")) return "ts";
  return names[0] ?? extension;
}

export function classify(
  container: string,
  tracks: Track[],
): Pick<ProbeResult, "playability" | "playabilityReason"> {
  const video = tracks.find((track) => track.kind === "video");
  const audio = tracks.filter((track) => track.kind === "audio");
  if (!video)
    return { playability: "unsupported", playabilityReason: "The file has no video track." };

  if (!DIRECT_VIDEO.has(video.codec)) {
    return {
      playability: "transcode",
      playabilityReason: `The video is ${video.codec.toUpperCase()}, which Apple devices do not play.`,
    };
  }
  if (video.pixFmt !== null && !DIRECT_PIXEL_FORMATS.has(video.pixFmt)) {
    return {
      playability: "transcode",
      playabilityReason: `The video uses the pixel format ${video.pixFmt}, which Apple devices do not play.`,
    };
  }
  if (!DIRECT_CONTAINERS.has(container)) {
    return {
      playability: "remux",
      playabilityReason: `The file is ${container.toUpperCase()}, which has to be repackaged as MP4.`,
    };
  }
  // A null tag was not read yet; the catalogue reads it before it relies on this (video-tags.ts).
  if (video.codec === "hevc" && video.codecTag !== null && !APPLE_HEVC_TAGS.has(video.codecTag)) {
    return {
      playability: "remux",
      playabilityReason: `The picture is labelled ${video.codecTag || "without a tag"}, which Apple devices do not show; it has to be relabelled ${appleHevcTag(video.codecTag)}.`,
    };
  }
  if (audio.length > 0 && !audio.some((track) => DIRECT_AUDIO.has(track.codec))) {
    return {
      playability: "remux",
      playabilityReason: `The sound is ${(audio[0]?.codec ?? "unknown").toUpperCase()}, which has to be converted to AAC.`,
    };
  }
  return { playability: "direct", playabilityReason: null };
}

export function interpretProbe(output: FfprobeOutput, path: string): ProbeResult {
  const tracks: Track[] = [];
  for (const stream of output.streams ?? []) {
    const type = stream.codec_type;
    if (type !== "video" && type !== "audio" && type !== "subtitle") continue;
    // Cover art is stored as a video stream with one picture in it.
    if (type === "video" && stream.disposition?.["attached_pic"] === 1) continue;
    if (!stream.codec_name) continue;
    const language = stream.tags?.["language"];
    tracks.push({
      index: stream.index,
      kind: type,
      codec: stream.codec_name,
      profile: stream.profile ?? null,
      language: language && language !== "und" ? language : null,
      title: stream.tags?.["title"] ?? null,
      channels: stream.channels ?? null,
      width: stream.width ?? null,
      height: stream.height ?? null,
      pixFmt: stream.pix_fmt ?? null,
      codecTag: normaliseCodecTag(stream.codec_tag_string),
      isDefault: stream.disposition?.["default"] === 1,
      isForced: stream.disposition?.["forced"] === 1,
    });
  }
  const container = containerName(output.format?.format_name, path);
  const duration = Number(output.format?.duration);
  const bitRate = Number(output.format?.bit_rate);
  return {
    container,
    durationMs: Number.isFinite(duration) && duration > 0 ? Math.round(duration * 1000) : null,
    bitRate: Number.isFinite(bitRate) && bitRate > 0 ? bitRate : null,
    tracks,
    ...classify(container, tracks),
  };
}

/** Reads a file's container and tracks with ffprobe. Reads headers only, not the whole file. */
export async function probeFile(path: string, ffprobePath = "ffprobe"): Promise<ProbeResult> {
  const { stdout } = await execFileAsync(
    ffprobePath,
    ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", "--", path],
    { maxBuffer: 16 * 1024 * 1024, timeout: 120_000 },
  );
  return interpretProbe(JSON.parse(stdout) as FfprobeOutput, path);
}

const FINGERPRINT_CHUNK = 64 * 1024;

/**
 * A cheap identity for a file: its size and a hash of its first and last 64 KB.
 * It lets Lobby recognise a file that was renamed or moved without reading
 * gigabytes, which matters on drives (exFAT) that have no stable file ids.
 */
export async function fingerprintFile(path: string, size: number): Promise<string> {
  const hash = createHash("sha256");
  hash.update(String(size));
  const handle = await open(path, "r");
  try {
    const head = Buffer.alloc(Math.min(FINGERPRINT_CHUNK, size));
    await handle.read(head, 0, head.length, 0);
    hash.update(head);
    if (size > FINGERPRINT_CHUNK) {
      const tail = Buffer.alloc(Math.min(FINGERPRINT_CHUNK, size - FINGERPRINT_CHUNK));
      await handle.read(tail, 0, tail.length, size - tail.length);
      hash.update(tail);
    }
  } finally {
    await handle.close();
  }
  return hash.digest("hex").slice(0, 32);
}
