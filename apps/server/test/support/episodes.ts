// SPDX-License-Identifier: MPL-2.0
import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

/**
 * Fake episodes with a shared theme, made by ffmpeg from its own sources: each has its own
 * background (noise of another colour and seed, a humming voice at another pitch), the season's
 * theme at its own place near the start, and the season's credits music at its own place near the
 * end, with a preview after it. Over everything lies a little noise of the episode's own, so no
 * two copies of the theme are the same bits. Nothing is played.
 */
export interface FakeEpisode {
  /** Where the theme starts, in seconds. */
  introAt: number;
  /** How long the preview after the credits is, in seconds. */
  previewSeconds: number;
  seed: number;
  /** Another show's theme and credits: none of this season's music. */
  otherShow?: boolean;
}

export const THEME_SECONDS = 40;
export const CREDITS_SECONDS = 30;

/** A melody with a beat: the same samples every time it is made. */
const THEME =
  "0.22*sin(2*PI*t*(220*pow(2,mod(floor(t*4)*5,12)/12)))" +
  "+0.18*sin(2*PI*t*(330*pow(2,mod(floor(t*2)*7,12)/12)))" +
  "+0.12*sin(2*PI*t*(880*pow(2,mod(floor(t*8)*3,7)/12)))*lt(mod(t,0.25),0.12)";
/**
 * The credits' music, with a beat of its own. Two held notes alone change too little from one
 * frame to the next: their fingerprints matched in about half the frames, so where the credits
 * were found to start moved by up to two seconds with the AAC encoder of the ffmpeg at hand.
 */
const CREDITS =
  "0.25*sin(2*PI*t*(262*pow(2,mod(floor(t*3)*4,9)/12)))" +
  "+0.2*sin(2*PI*t*(392*pow(2,mod(floor(t*1.5)*5,8)/12)))" +
  "+0.12*sin(2*PI*t*(660*pow(2,mod(floor(t*6)*5,8)/12)))*lt(mod(t,0.2),0.1)";

const OTHER_THEME =
  "0.22*sin(2*PI*t*(196*pow(2,mod(floor(t*5)*3,10)/12)))" +
  "+0.18*sin(2*PI*t*(294*pow(2,mod(floor(t*2.5)*4,11)/12)))";

function background(seed: number, seconds: number, label: string): string {
  const colour = ["pink", "brown", "white", "blue", "violet"][seed % 5] ?? "pink";
  const voice = 120 + seed * 23;
  return (
    `anoisesrc=color=${colour}:seed=${String(seed * 7919 + label.length)}:amplitude=0.12:` +
    `sample_rate=22050:duration=${String(seconds)}[n${label}];` +
    `aevalsrc=exprs='0.3*sin(2*PI*${String(voice)}*t+3*sin(2*PI*0.7*t))*(0.5+0.5*sin(2*PI*${String(2.3 + seed * 0.37)}*t))':` +
    `s=22050:d=${String(seconds)}[v${label}];` +
    `[n${label}][v${label}]amix=inputs=2:normalize=0[${label}]`
  );
}

/** Writes one fake episode. `video` adds a tiny picture, so the scanner takes it as an episode. */
export function makeEpisode(
  path: string,
  episode: FakeEpisode,
  options: { seconds?: number; video?: boolean } = {},
): void {
  mkdirSync(dirname(path), { recursive: true });
  const seconds = options.seconds ?? 360;
  const creditsAt = seconds - episode.previewSeconds - CREDITS_SECONDS;
  const middle = creditsAt - episode.introAt - THEME_SECONDS;
  const graph = [
    background(episode.seed, episode.introAt, "a"),
    `aevalsrc=exprs='${episode.otherShow ? OTHER_THEME : THEME}':s=22050:d=${String(THEME_SECONDS)}[theme]`,
    background(episode.seed + 11, middle, "b"),
    `aevalsrc=exprs='${episode.otherShow ? OTHER_THEME : CREDITS}':s=22050:d=${String(CREDITS_SECONDS)}[credits]`,
    background(episode.seed + 23, episode.previewSeconds, "c"),
    "[a][theme][b][credits][c]concat=n=5:v=0:a=1[story]",
    `anoisesrc=color=white:seed=${String(episode.seed + 101)}:amplitude=0.02:sample_rate=22050:duration=${String(seconds)}[hiss]`,
    "[story][hiss]amix=inputs=2:normalize=0,aformat=channel_layouts=stereo[out]",
  ].join(";");
  execFileSync(
    "ffmpeg",
    [
      "-v",
      "error",
      "-y",
      ...(options.video
        ? // At a frame rate real episodes have. At one picture a second, ffmpeg 6.1 (Ubuntu
          // 24.04's) cannot read the picture's format when it seeks into the MKV, and then
          // shifts the sound's times by half a minute.
          ["-f", "lavfi", "-i", `color=c=black:size=64x36:rate=24:duration=${String(seconds)}`]
        : []),
      "-filter_complex",
      graph,
      ...(options.video ? ["-map", "0:v", "-c:v", "libx264", "-pix_fmt", "yuv420p"] : []),
      "-map",
      "[out]",
      "-c:a",
      "aac",
      // At 64 kbit/s, and with noise substitution, the encoder rounds the sound differently
      // with and without the processor's vector instructions: where the credits were found
      // moved by up to 2.6 s between two builds of the same ffmpeg. Like this it does not.
      "-b:a",
      "128k",
      "-aac_pns",
      "0",
      "-t",
      String(seconds),
      path,
    ],
    { stdio: ["ignore", "ignore", "inherit"] },
  );
}

/** The season used by the tests: the theme and the credits at a different place in each. */
export const SEASON: FakeEpisode[] = [
  { introAt: 3, previewSeconds: 5, seed: 1 },
  { introAt: 12.5, previewSeconds: 15, seed: 2 },
  { introAt: 21, previewSeconds: 25.5, seed: 3 },
  { introAt: 34, previewSeconds: 10, seed: 4 },
];
