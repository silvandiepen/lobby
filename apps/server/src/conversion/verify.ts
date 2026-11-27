// SPDX-License-Identifier: MPL-2.0
import { execFile } from "node:child_process";
import { stat } from "node:fs/promises";
import { promisify } from "node:util";
import { fingerprintFile, probeFile, TEXT_SUBTITLES, type ProbeResult } from "../library/probe.ts";
import type { ConversionTarget } from "./convert.ts";

const execFileAsync = promisify(execFile);

/**
 * The thresholds of the proof. Why these numbers is in docs/conversion.md.
 */
export const PROOF = {
  /** The two files may differ this much in length: one second, or 0.2% for a long film. */
  durationToleranceMs: 1000,
  durationToleranceShare: 0.002,
  /** Samples compared picture by picture, spread evenly over the film. */
  samples: 8,
  sampleSeconds: 4,
  /** SSIM, 1 being identical: the mean over all samples, and the worst single sample. */
  ssimMean: 0.95,
  ssimWorst: 0.85,
  /** How much the gap between the end of sound and picture may differ from the original's. */
  driftMs: 250,
  /** The new file's size as a share of the original's. */
  sizeMin: 0.05,
  sizeMax: 3,
} as const;

export interface ProofCheck {
  name:
    | "original_unchanged"
    | "probe"
    | "duration"
    | "video"
    | "audio"
    | "subtitles"
    | "chapters"
    | "size"
    | "decode"
    | "picture"
    | "drift";
  ok: boolean;
  /** What was measured, for the manager and the log. No file names. */
  detail: string;
}

export interface Proof {
  ok: boolean;
  checks: ProofCheck[];
  /** The first check that failed, as a sentence. Null when all passed. */
  reason: string | null;
  ssim: { mean: number; worst: number } | null;
  newSize: number;
}

export interface VerifyInput {
  originalPath: string;
  /** What the original was when the job began. */
  original: { size: number; mtimeMs: number; fingerprint: string | null };
  /** The original as the catalogue probed it. */
  originalProbe: ProbeResult;
  newPath: string;
  target: ConversionTarget;
  ffmpegPath: string;
  ffprobePath: string;
  /** Called between checks, so the caller can wait while someone is watching. */
  pause?: () => Promise<void>;
}

const SENTENCES: Record<ProofCheck["name"], string> = {
  original_unchanged: "The original changed while it was being converted.",
  probe: "The converted file cannot be read as a video Apple devices play.",
  duration: "The converted file is not as long as the original.",
  video: "The converted file's picture is not what was asked for.",
  audio: "The converted file does not have the original's sound tracks.",
  subtitles: "The converted file lost subtitles the original has.",
  chapters: "The converted file lost the original's chapters.",
  size: "The converted file's size makes no sense for this film.",
  decode: "The converted file does not play through without errors.",
  picture: "The converted file's picture differs too much from the original.",
  drift: "Sound and picture drift apart in the converted file.",
};

async function chapterCount(path: string, ffprobePath: string): Promise<number> {
  const { stdout } = await execFileAsync(
    ffprobePath,
    ["-v", "error", "-print_format", "json", "-show_chapters", "--", path],
    { maxBuffer: 16 * 1024 * 1024, timeout: 120_000 },
  );
  return ((JSON.parse(stdout) as { chapters?: unknown[] }).chapters ?? []).length;
}

/**
 * When the first picture stream and the first sound stream end, in seconds, read
 * from the last packets of the file.
 */
async function streamEnds(
  path: string,
  durationMs: number,
  ffprobePath: string,
): Promise<{ video: number | null; audio: number | null }> {
  const from = Math.max(0, durationMs / 1000 - 30);
  const { stdout } = await execFileAsync(
    ffprobePath,
    [
      "-v",
      "error",
      "-read_intervals",
      `${from.toFixed(3)}%`,
      "-show_entries",
      "packet=codec_type,stream_index,pts_time,dts_time,duration_time",
      "-of",
      "json",
      "--",
      path,
    ],
    { maxBuffer: 256 * 1024 * 1024, timeout: 300_000 },
  );
  const packets =
    (
      JSON.parse(stdout) as {
        packets?: {
          codec_type?: string;
          stream_index?: number;
          pts_time?: string;
          dts_time?: string;
          duration_time?: string;
        }[];
      }
    ).packets ?? [];
  const first: Record<string, number | undefined> = {};
  const end: Record<string, number | null> = { video: null, audio: null };
  for (const packet of packets) {
    const type = packet.codec_type;
    if ((type !== "video" && type !== "audio") || packet.stream_index === undefined) continue;
    first[type] ??= packet.stream_index;
    if (first[type] !== packet.stream_index) continue;
    const at = Number(packet.pts_time ?? packet.dts_time);
    if (!Number.isFinite(at)) continue;
    const until = at + (Number(packet.duration_time) || 0);
    end[type] = Math.max(end[type] ?? 0, until);
  }
  return { video: end["video"] ?? null, audio: end["audio"] ?? null };
}

/** SSIM between the same stretch of two files; null when ffmpeg did not report one. */
async function ssimAt(
  input: VerifyInput,
  startSeconds: number,
  seconds: number,
  size: { width: number; height: number } | null,
): Promise<number | null> {
  const at = ["-ss", startSeconds.toFixed(3), "-t", seconds.toFixed(3)];
  // The original is cut to the new picture's size (an odd size loses one row or column on
  // the way to H.264) and both are set to start at zero, so the same frames meet.
  const cut = size ? `,crop=${String(size.width)}:${String(size.height)}:0:0` : "";
  const filter = `[0:v:0]setpts=PTS-STARTPTS${cut}[a];[1:v:0]setpts=PTS-STARTPTS[b];[a][b]ssim`;
  const result = await execFileAsync(
    input.ffmpegPath,
    [
      "-nostdin",
      "-hide_banner",
      ...at,
      "-i",
      input.originalPath,
      ...at,
      "-i",
      input.newPath,
      "-an",
      "-sn",
      "-lavfi",
      filter,
      "-f",
      "null",
      "-",
    ],
    { maxBuffer: 16 * 1024 * 1024, timeout: 600_000 },
  ).catch((error: unknown) => ({ stderr: (error as { stderr?: string }).stderr ?? "" }));
  const match = /SSIM .*All:([0-9.]+)/.exec(result.stderr);
  return match ? Number(match[1]) : null;
}

function sameLanguages(a: (string | null)[], b: (string | null)[]): boolean {
  return (
    a.length === b.length &&
    a.every((language, index) => (language ?? "und") === (b[index] ?? "und"))
  );
}

/**
 * Everything that has to hold before a converted file may take its original's
 * place. Every check is required; the cheap ones run first, and the first
 * failure stops the rest.
 */
export async function proveConversion(input: VerifyInput): Promise<Proof> {
  const checks: ProofCheck[] = [];
  let ssim: Proof["ssim"] = null;
  let newSize = 0;
  const finish = (): Proof => {
    const failed = checks.find((check) => !check.ok);
    return {
      ok: !failed,
      checks,
      reason: failed ? SENTENCES[failed.name] : null,
      ssim,
      newSize,
    };
  };
  const check = (name: ProofCheck["name"], ok: boolean, detail: string): boolean => {
    checks.push({ name, ok, detail });
    return ok;
  };

  // The original is still the file the job began with.
  let unchanged = false;
  let detail: string;
  try {
    const info = await stat(input.originalPath);
    const fingerprint =
      input.original.fingerprint === null
        ? null
        : await fingerprintFile(input.originalPath, info.size);
    unchanged =
      info.size === input.original.size &&
      Math.round(info.mtimeMs) === input.original.mtimeMs &&
      fingerprint === input.original.fingerprint;
    detail = unchanged ? "same size, date and fingerprint" : "size, date or fingerprint differ";
  } catch {
    detail = "the original cannot be read";
  }
  if (!check("original_unchanged", unchanged, detail)) return finish();

  let probe: ProbeResult;
  try {
    newSize = (await stat(input.newPath)).size;
    probe = await probeFile(input.newPath, input.ffprobePath);
  } catch {
    check("probe", false, "ffprobe cannot read it");
    return finish();
  }
  if (
    !check(
      "probe",
      probe.container === "mp4" && probe.playability === "direct",
      `${probe.container}, ${probe.playability}`,
    )
  ) {
    return finish();
  }

  const before = input.originalProbe;
  const durationBefore = before.durationMs ?? 0;
  const durationAfter = probe.durationMs ?? 0;
  const tolerance = Math.max(
    PROOF.durationToleranceMs,
    durationBefore * PROOF.durationToleranceShare,
  );
  if (
    !check(
      "duration",
      durationBefore > 0 && Math.abs(durationAfter - durationBefore) <= tolerance,
      `${String(durationBefore)} ms before, ${String(durationAfter)} ms after`,
    )
  ) {
    return finish();
  }

  const video = probe.tracks.filter((track) => track.kind === "video");
  const wantedCodec =
    input.target.video.action === "copy" ? input.target.video.codec : input.target.video.action;
  const videoBefore = before.tracks.find((track) => track.kind === "video");
  // A picture with an odd width or height loses one row or column on the way to H.264.
  const sameSize =
    Math.abs((video[0]?.width ?? 0) - (videoBefore?.width ?? 0)) <= 1 &&
    Math.abs((video[0]?.height ?? 0) - (videoBefore?.height ?? 0)) <= 1;
  if (
    !check(
      "video",
      video.length === 1 && video[0]?.codec === wantedCodec && sameSize,
      `${String(video.length)} picture track(s), ${video[0]?.codec ?? "none"}, ${String(video[0]?.width)}x${String(video[0]?.height)}`,
    )
  ) {
    return finish();
  }

  const audioBefore = before.tracks.filter((track) => track.kind === "audio");
  const audioAfter = probe.tracks.filter((track) => track.kind === "audio");
  const channelsKept = audioAfter.every((track, index) => {
    const wanted = input.target.audio[index];
    return wanted !== undefined && (wanted.channels === null || track.channels === wanted.channels);
  });
  if (
    !check(
      "audio",
      audioBefore.length === audioAfter.length &&
        sameLanguages(
          audioBefore.map((track) => track.language),
          audioAfter.map((track) => track.language),
        ) &&
        channelsKept,
      `${String(audioBefore.length)} before, ${String(audioAfter.length)} after`,
    )
  ) {
    return finish();
  }

  const subtitlesBefore = before.tracks.filter((track) => track.kind === "subtitle");
  const subtitlesAfter = probe.tracks.filter((track) => track.kind === "subtitle");
  const textBefore = subtitlesBefore.filter((track) => TEXT_SUBTITLES.has(track.codec));
  if (
    !check(
      "subtitles",
      // A file with picture subtitles is never replaced: they cannot go into MP4.
      textBefore.length === subtitlesBefore.length &&
        sameLanguages(
          textBefore.map((track) => track.language),
          subtitlesAfter.map((track) => track.language),
        ),
      `${String(subtitlesBefore.length)} before (${String(textBefore.length)} text), ${String(subtitlesAfter.length)} after`,
    )
  ) {
    return finish();
  }

  let chaptersBefore = -1;
  let chaptersAfter = -2;
  try {
    chaptersBefore = await chapterCount(input.originalPath, input.ffprobePath);
    chaptersAfter = await chapterCount(input.newPath, input.ffprobePath);
  } catch {
    // Reported as a failed check below.
  }
  if (
    !check(
      "chapters",
      chaptersBefore === chaptersAfter,
      `${String(chaptersBefore)} before, ${String(chaptersAfter)} after`,
    )
  ) {
    return finish();
  }

  const share = newSize / input.original.size;
  if (
    !check(
      "size",
      share >= PROOF.sizeMin && share <= PROOF.sizeMax,
      `${share.toFixed(2)} of the original`,
    )
  ) {
    return finish();
  }

  // The whole file decodes: every picture and every sound track, to the end.
  await input.pause?.();
  const decode = await execFileAsync(
    input.ffmpegPath,
    [
      "-nostdin",
      "-hide_banner",
      "-v",
      "error",
      "-xerror",
      "-i",
      input.newPath,
      "-map",
      "0:v",
      "-map",
      "0:a?",
      "-f",
      "null",
      "-",
    ],
    { maxBuffer: 16 * 1024 * 1024, timeout: 6 * 3_600_000 },
  ).then(
    (result) => ({ ok: result.stderr.trim() === "", stderr: result.stderr }),
    (error: unknown) => ({
      ok: false,
      stderr: (error as { stderr?: string }).stderr ?? "",
    }),
  );
  if (
    !check(
      "decode",
      decode.ok,
      decode.ok
        ? "no errors"
        : `${String(decode.stderr.trim().split("\n").length)} line(s) of errors`,
    )
  ) {
    return finish();
  }

  // The same pictures: samples spread over the whole film.
  const newPicture =
    video[0]?.width && video[0].height ? { width: video[0].width, height: video[0].height } : null;
  const seconds = durationBefore / 1000;
  // Evenly spread, and never at the very start or end: the first frames of an old AVI do
  // not line up with those of its conversion (measured: SSIM 0.49 at 0 s, 0.98 from 0.5 s on).
  const sampleSeconds = Math.min(PROOF.sampleSeconds, seconds / (PROOF.samples + 1));
  const values: number[] = [];
  for (let index = 0; index < PROOF.samples; index += 1) {
    await input.pause?.();
    const start = ((index + 1) / (PROOF.samples + 1)) * seconds - sampleSeconds / 2;
    const value = await ssimAt(input, Math.max(0, start), sampleSeconds, newPicture);
    if (value === null) {
      check("picture", false, `sample ${String(index + 1)} could not be compared`);
      return finish();
    }
    values.push(value);
  }
  ssim = {
    mean: values.reduce((sum, value) => sum + value, 0) / values.length,
    worst: Math.min(...values),
  };
  if (
    !check(
      "picture",
      ssim.mean >= PROOF.ssimMean && ssim.worst >= PROOF.ssimWorst,
      `SSIM mean ${ssim.mean.toFixed(4)}, worst ${ssim.worst.toFixed(4)} over ${String(values.length)} samples`,
    )
  ) {
    return finish();
  }

  // Sound still ends where it ended against the picture.
  await input.pause?.();
  let drift: number | null = null;
  let driftDetail = "no sound to compare";
  try {
    const [endsBefore, endsAfter] = await Promise.all([
      streamEnds(input.originalPath, durationBefore, input.ffprobePath),
      streamEnds(input.newPath, durationAfter, input.ffprobePath),
    ]);
    if (audioBefore.length > 0) {
      if (
        endsBefore.video === null ||
        endsBefore.audio === null ||
        endsAfter.video === null ||
        endsAfter.audio === null
      ) {
        drift = Number.POSITIVE_INFINITY;
        driftDetail = "the ends of sound and picture cannot be read";
      } else {
        drift = (endsAfter.audio - endsAfter.video - (endsBefore.audio - endsBefore.video)) * 1000;
        driftDetail = `${drift.toFixed(0)} ms`;
      }
    }
  } catch {
    drift = Number.POSITIVE_INFINITY;
    driftDetail = "the ends of sound and picture cannot be read";
  }
  check("drift", drift === null || Math.abs(drift) <= PROOF.driftMs, driftDetail);
  return finish();
}
