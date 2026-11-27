// SPDX-License-Identifier: MPL-2.0
import { join } from "node:path";
import { appleHevcTag } from "../library/probe.ts";
import type { PlaybackAsset, PlaybackTrack, PreparedAudio } from "./types.ts";

/** Video that goes into MP4 untouched and that Apple's decoders play. */
const COPY_VIDEO = new Set(["h264", "hevc"]);
/**
 * Video that is converted to H.264: MPEG-4 Part 2 (XviD, DivX) and MS-MPEG-4 v3
 * (DivX 3), the codecs of the household's old AVI films. They are about 480 lines
 * high, which the Pi converts several times faster than it plays (docs/playback.md).
 * Anything else that needs converting (AV1, 10-bit H.264) is refused: at 1080p
 * the Pi cannot keep up.
 */
/** Pictures the server converts to H.264. */
export const CONVERT_VIDEO: ReadonlySet<string> = new Set(["mpeg4", "msmpeg4v3"]);
/**
 * libx264 settings for converted video, chosen from measurements on the Pi
 * (docs/playback.md).
 */
export const CONVERT_PRESET = "veryfast";
export const CONVERT_CRF = 21;
/** Seconds per segment. Converted video gets a keyframe exactly this often. */
const SEGMENT_SECONDS = 6;
/**
 * Sound that is copied. Everything else (DTS, Opus, TrueHD, FLAC, Vorbis, MP3) is
 * converted: surround to AC-3, stereo and mono to AAC. On the Pi, ffmpeg encodes
 * 5.1 AC-3 at 85 times real time and 5.1 AAC at 9 times (docs/playback.md), and
 * every Apple device plays AC-3.
 */
const COPY_AUDIO = new Set(["aac", "ac3", "eac3"]);
/** Subtitles ffmpeg can turn into WebVTT. Image subtitles (PGS, DVD) cannot be converted. */
export const TEXT_SUBTITLE_CODECS = new Set([
  "subrip",
  "srt",
  "ass",
  "ssa",
  "webvtt",
  "vtt",
  "mov_text",
  "text",
]);

export interface PlannedAudio extends PreparedAudio {
  /** kbit/s for a converted track. */
  bitrateKbps: number | null;
}

export interface PreparationPlan {
  video: PlaybackTrack;
  /** True when the picture is converted to H.264 instead of copied. */
  videoConverted: boolean;
  audio: PlannedAudio[];
}

export type PlanResult = { ok: true; plan: PreparationPlan } | { ok: false; reason: string };

/**
 * Decides how a file is prepared: which video track is copied or converted, and
 * which sound tracks are copied or converted. The default sound track comes first, because
 * the stream that plays while the copy is still being written carries only the first.
 */
export function planPreparation(asset: PlaybackAsset): PlanResult {
  const video = asset.tracks.find((track) => track.kind === "video");
  if (!video) return { ok: false, reason: "The file has no video track." };
  // A codec Apple devices play can still need converting (its pixel format); the
  // catalogue knows, and says so with the class "transcode".
  const copied = COPY_VIDEO.has(video.codec) && asset.playability !== "transcode";
  if (!copied && !CONVERT_VIDEO.has(video.codec)) {
    return {
      ok: false,
      reason:
        (asset.playability === "transcode" ? asset.playabilityReason : null) ??
        `The video is ${video.codec.toUpperCase()}, which Apple devices do not play.`,
    };
  }

  const tracks = asset.tracks.filter((track) => track.kind === "audio");
  const first = tracks.find((track) => track.isDefault) ?? tracks[0];
  const ordered = first ? [first, ...tracks.filter((track) => track !== first)] : [];
  const audio = ordered.map((track, position): PlannedAudio => {
    const converted = !COPY_AUDIO.has(track.codec);
    // AC-3 carries at most 5.1: 6.1 and 7.1 tracks are mixed down.
    const channels =
      converted && track.channels !== null ? Math.min(track.channels, 6) : track.channels;
    const surround = (channels ?? 2) > 2;
    return {
      index: track.index,
      codec: converted ? (surround ? "ac3" : "aac") : track.codec,
      converted,
      language: track.language,
      title: track.title,
      channels,
      isDefault: position === 0,
      bitrateKbps: converted ? (surround ? 640 : 160) : null,
    };
  });
  return { ok: true, plan: { video, videoConverted: !copied, audio } };
}

export interface SubtitleOutput {
  streamIndex: number;
  /** Where the WebVTT is written. */
  path: string;
}

/** File names inside a prepared copy's folder. */
export const STREAM_PLAYLIST = "index.m3u8";
export const MEDIA_FILE = "media.mp4";

/** The files of the separate rendition of the sound track at `position` (1 or higher) in the plan. */
export function audioRenditionFiles(position: number): { playlist: string; media: string } {
  return { playlist: `audio-${position}.m3u8`, media: `audio-${position}.mp4` };
}

function hlsOutput(media: string, playlist: string): string[] {
  return [
    // Chapters would become an extra text track in the MP4; data streams are not media.
    "-map_chapters",
    "-1",
    "-dn",
    "-f",
    "hls",
    "-hls_time",
    String(SEGMENT_SECONDS),
    "-hls_list_size",
    "0",
    "-hls_playlist_type",
    "event",
    "-hls_segment_type",
    "fmp4",
    // single_file: every segment goes into one MP4.
    // (Not temp_file: with single_file, ffmpeg then lists "media.mp4.tmp" in the playlist.)
    "-hls_flags",
    "single_file+independent_segments",
    "-hls_segment_filename",
    media,
    playlist,
  ];
}

function audioCodecArguments(track: PlannedAudio, position: number): string[] {
  if (!track.converted) return [`-c:a:${position}`, "copy"];
  return [
    `-c:a:${position}`,
    track.codec,
    `-b:a:${position}`,
    `${track.bitrateKbps ?? 160}k`,
    ...(track.channels !== null ? [`-ac:a:${position}`, String(track.channels)] : []),
  ];
}

/**
 * The ffmpeg command line for a plan. One pass over the original writes, into `dir`:
 *
 * - `media.mp4` with its playlist `index.m3u8`: the video (copied, or converted to
 *   H.264) and every sound track in one fragmented MP4. It is the stream (which plays the first sound track) and the download.
 * - `audio-N.mp4` with `audio-N.m3u8` for every further sound track, because a stream
 *   can only switch to a sound track that has a playlist of its own.
 * - the embedded text subtitles as WebVTT, since the file is being read anyway.
 */
export function ffmpegArguments(
  sourcePath: string,
  plan: PreparationPlan,
  dir: string,
  subtitles: SubtitleOutput[] = [],
): string[] {
  const args = ["-nostdin", "-hide_banner", "-v", "error", "-progress", "pipe:1", "-y"];
  args.push("-i", sourcePath);

  args.push("-map", `0:${plan.video.index}`);
  for (const track of plan.audio) args.push("-map", `0:${track.index}`);
  if (plan.videoConverted) {
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
      // H.264 with this pixel format needs an even width and height.
      "-vf",
      "crop=trunc(iw/2)*2:trunc(ih/2)*2",
      // A keyframe at every segment boundary, so every segment is as long as the playlist says.
      "-force_key_frames",
      `expr:gte(t,n_forced*${SEGMENT_SECONDS})`,
    );
  } else {
    args.push("-c:v", "copy");
    // AVFoundation shows HEVC in MP4 only under the hvc1 tag (dvh1 for Dolby Vision). Under
    // hev1, ffmpeg's default and what some files carry, it plays the sound over a black picture.
    if (plan.video.codec === "hevc") args.push("-tag:v", appleHevcTag(plan.video.codecTag ?? null));
  }
  plan.audio.forEach((track, position) => {
    args.push(...audioCodecArguments(track, position));
    args.push(`-disposition:a:${position}`, position === 0 ? "default" : "0");
  });
  args.push(...hlsOutput(join(dir, MEDIA_FILE), join(dir, STREAM_PLAYLIST)));

  plan.audio.forEach((track, position) => {
    if (position === 0) return;
    const files = audioRenditionFiles(position);
    args.push("-map", `0:${track.index}`, ...audioCodecArguments(track, 0));
    args.push(...hlsOutput(join(dir, files.media), join(dir, files.playlist)));
  });

  for (const subtitle of subtitles) {
    args.push("-map", `0:${subtitle.streamIndex}`, "-c:s", "webvtt", "-f", "webvtt", subtitle.path);
  }
  return args;
}
