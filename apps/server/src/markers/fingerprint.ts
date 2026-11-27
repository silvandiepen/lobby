// SPDX-License-Identifier: MPL-2.0
import { spawn } from "node:child_process";
import { setPriority } from "node:os";

/**
 * Audio fingerprints for finding what episodes of a season share: the intro's theme and the
 * credits' music (docs/decisions.md, "Skip Intro").
 *
 * The sound is decoded by ffmpeg to mono at 5 kHz. Every 100 ms a window of 2048 samples (0.41 s)
 * is cut into 33 bands between 300 and 2000 Hz, spaced as hearing is. Each of the 32 bits says
 * whether the energy difference between two neighbouring bands grew or shrank since three frames
 * before (after the Philips fingerprint, Haitsma and Kalker 2002, which compares with the frame
 * just before at a far shorter step: over 300 ms the bits stay the same when two copies of the
 * music start up to half a step apart). The same music gives nearly the same
 * bits however loud it is and whatever it was encoded with; unrelated sound differs in about half
 * of them. Frames that are all but silent carry no bits worth comparing and are marked as such.
 *
 * Chapter names are read elsewhere; this is only for what files do not say.
 */

export const SAMPLE_RATE = 5000;
export const FRAME_SAMPLES = 2048;
export const HOP_SAMPLES = 500;
/** How far apart frames are. */
export const FRAME_MS = (HOP_SAMPLES * 1000) / SAMPLE_RATE;
/** Where in its window a frame's time is: the middle. */
export const FRAME_CENTRE_MS = (FRAME_SAMPLES * 1000) / SAMPLE_RATE / 2;

const BANDS = 33;
/** How many frames back the change in energy is measured against. */
const LAG = 3;
const LOW_HZ = 300;
const HIGH_HZ = 2000;
/** Below this mean square (about -60 dBFS) a frame counts as silent. */
const SILENCE = 1e-6;

/** What a stretch of a file sounds like, one 32-bit value every `FRAME_MS`. */
export interface Print {
  /** Where the stretch starts in the file. */
  startMs: number;
  hashes: Uint32Array;
  /** 1 for a frame too quiet to compare. */
  silent: Uint8Array;
}

/** The time in the file of frame `index` of `print`. */
export function frameTime(print: Print, index: number): number {
  return print.startMs + index * FRAME_MS + FRAME_CENTRE_MS;
}

/** The frame of `print` nearest to `ms` in the file, inside the print. */
export function frameAt(print: Print, ms: number): number {
  const index = Math.round((ms - print.startMs - FRAME_CENTRE_MS) / FRAME_MS);
  return Math.max(0, Math.min(print.hashes.length, index));
}

/** A part of `print`, from frame `from` up to `to`, as a print of its own. */
export function slicePrint(print: Print, from: number, to: number): Print {
  return {
    startMs: print.startMs + from * FRAME_MS,
    hashes: print.hashes.slice(from, to),
    silent: print.silent.slice(from, to),
  };
}

let window: Float64Array | null = null;
let bandEdges: Int32Array | null = null;
let bitReverse: Uint32Array | null = null;
let cosines: Float64Array | null = null;
let sines: Float64Array | null = null;

function prepare(): void {
  if (window) return;
  window = new Float64Array(FRAME_SAMPLES);
  for (let i = 0; i < FRAME_SAMPLES; i++) {
    window[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / (FRAME_SAMPLES - 1));
  }
  // Logarithmically spaced, as the ear hears pitch.
  bandEdges = new Int32Array(BANDS + 1);
  for (let b = 0; b <= BANDS; b++) {
    const hz = LOW_HZ * Math.pow(HIGH_HZ / LOW_HZ, b / BANDS);
    bandEdges[b] = Math.round((hz * FRAME_SAMPLES) / SAMPLE_RATE);
  }
  const bits = Math.log2(FRAME_SAMPLES);
  bitReverse = new Uint32Array(FRAME_SAMPLES);
  for (let i = 0; i < FRAME_SAMPLES; i++) {
    let reversed = 0;
    for (let bit = 0; bit < bits; bit++) reversed |= ((i >> bit) & 1) << (bits - 1 - bit);
    bitReverse[i] = reversed;
  }
  cosines = new Float64Array(FRAME_SAMPLES / 2);
  sines = new Float64Array(FRAME_SAMPLES / 2);
  for (let i = 0; i < FRAME_SAMPLES / 2; i++) {
    cosines[i] = Math.cos((2 * Math.PI * i) / FRAME_SAMPLES);
    sines[i] = -Math.sin((2 * Math.PI * i) / FRAME_SAMPLES);
  }
}

/** An in-place radix-2 FFT of `re` and `im`, both FRAME_SAMPLES long. */
function fft(re: Float64Array, im: Float64Array): void {
  const n = FRAME_SAMPLES;
  const reverse = bitReverse as Uint32Array;
  for (let i = 0; i < n; i++) {
    const j = reverse[i] as number;
    if (j > i) {
      const r = re[i] as number;
      re[i] = re[j] as number;
      re[j] = r;
      const m = im[i] as number;
      im[i] = im[j] as number;
      im[j] = m;
    }
  }
  const cos = cosines as Float64Array;
  const sin = sines as Float64Array;
  for (let size = 2; size <= n; size *= 2) {
    const half = size / 2;
    const step = n / size;
    for (let start = 0; start < n; start += size) {
      for (let k = 0; k < half; k++) {
        const wr = cos[k * step] as number;
        const wi = sin[k * step] as number;
        const a = start + k;
        const b = a + half;
        const br = re[b] as number;
        const bi = im[b] as number;
        const tr = br * wr - bi * wi;
        const ti = br * wi + bi * wr;
        const ar = re[a] as number;
        const ai = im[a] as number;
        re[b] = ar - tr;
        im[b] = ai - ti;
        re[a] = ar + tr;
        im[a] = ai + ti;
      }
    }
  }
}

/** The fingerprint of mono samples at `SAMPLE_RATE`, the first sample at `startMs` in the file. */
export function fingerprintSamples(samples: Float32Array, startMs = 0): Print {
  prepare();
  const frames =
    samples.length < FRAME_SAMPLES
      ? 0
      : Math.floor((samples.length - FRAME_SAMPLES) / HOP_SAMPLES) + 1;
  const hashes = new Uint32Array(frames);
  const silent = new Uint8Array(frames);
  const re = new Float64Array(FRAME_SAMPLES);
  const im = new Float64Array(FRAME_SAMPLES);
  const edges = bandEdges as Int32Array;
  const win = window as Float64Array;
  // The energies of the last LAG frames, oldest first.
  const history = Array.from({ length: LAG + 1 }, () => new Float64Array(BANDS));
  for (let f = 0; f < frames; f++) {
    const current = history[f % (LAG + 1)] as Float64Array;
    const previous = history[(f + 1) % (LAG + 1)] as Float64Array;
    const offset = f * HOP_SAMPLES;
    let power = 0;
    for (let i = 0; i < FRAME_SAMPLES; i++) {
      const sample = samples[offset + i] as number;
      power += sample * sample;
      re[i] = sample * (win[i] as number);
      im[i] = 0;
    }
    fft(re, im);
    for (let b = 0; b < BANDS; b++) {
      let energy = 0;
      for (let k = edges[b] as number; k < (edges[b + 1] as number); k++) {
        const r = re[k] as number;
        const m = im[k] as number;
        energy += r * r + m * m;
      }
      current[b] = energy;
    }
    silent[f] = power / FRAME_SAMPLES < SILENCE ? 1 : 0;
    let hash = 0;
    if (f >= LAG) {
      for (let b = 0; b < BANDS - 1; b++) {
        const now = (current[b] as number) - (current[b + 1] as number);
        const before = (previous[b] as number) - (previous[b + 1] as number);
        if (now - before > 0) hash |= 1 << b;
      }
    } else {
      // The first frames have nothing to compare with; they are never matched.
      silent[f] = 1;
    }
    hashes[f] = hash >>> 0;
  }
  return { startMs, hashes, silent };
}

/** How many bits two values differ in. */
export function differingBits(a: number, b: number): number {
  let x = (a ^ b) >>> 0;
  x = x - ((x >>> 1) & 0x55555555);
  x = (x & 0x33333333) + ((x >>> 2) & 0x33333333);
  return Math.imul((x + (x >>> 4)) & 0x0f0f0f0f, 0x01010101) >>> 24;
}

export interface DecodeOptions {
  ffmpegPath: string;
  /** The stream index of the audio track in the file; null: the first. */
  streamIndex: number | null;
  startMs: number;
  durationMs: number;
  /** For the background job: as low as it goes. */
  niceness?: number;
  /** Stops ffmpeg after this long. Default 10 minutes. */
  timeoutMs?: number;
}

/**
 * Decodes a stretch of a file's sound to mono samples at `SAMPLE_RATE`, without writing any file:
 * ffmpeg sends raw 16-bit samples down a pipe. Nothing is played.
 */
export function decodeAudio(path: string, options: DecodeOptions): Promise<Float32Array> {
  const args = [
    "-nostdin",
    "-v",
    "error",
    "-ss",
    (options.startMs / 1000).toFixed(3),
    "-t",
    (options.durationMs / 1000).toFixed(3),
    "-i",
    path,
    "-map",
    options.streamIndex === null ? "0:a:0" : `0:${String(options.streamIndex)}`,
    "-vn",
    "-sn",
    "-dn",
    "-ac",
    "1",
    "-ar",
    String(SAMPLE_RATE),
    "-f",
    "s16le",
    "-",
  ];
  return new Promise((resolve, reject) => {
    const child = spawn(options.ffmpegPath, args, { stdio: ["ignore", "pipe", "pipe"] });
    if (options.niceness !== undefined) {
      child.once("spawn", () => {
        try {
          if (child.pid !== undefined) setPriority(child.pid, options.niceness ?? 0);
        } catch {
          // It runs at the server's own priority then; the server itself is niced by its unit.
        }
      });
    }
    const chunks: Buffer[] = [];
    let stderr = "";
    child.stdout.on("data", (chunk: Buffer) => chunks.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => {
      if (stderr.length < 4000) stderr += chunk.toString("utf8");
    });
    const timer = setTimeout(() => child.kill("SIGKILL"), options.timeoutMs ?? 600_000);
    child.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.once("close", (code, signal) => {
      clearTimeout(timer);
      if (code !== 0) {
        reject(
          new Error(
            `ffmpeg could not decode the sound (${signal ?? `exit ${String(code)}`}): ${stderr.trim().slice(0, 300)}`,
          ),
        );
        return;
      }
      const bytes = Buffer.concat(chunks);
      const count = Math.floor(bytes.length / 2);
      const samples = new Float32Array(count);
      for (let i = 0; i < count; i++) samples[i] = bytes.readInt16LE(i * 2) / 32768;
      resolve(samples);
    });
  });
}

/** A print as bytes, for the cache: count, start, the hashes, then the silent flags. */
export function encodePrint(print: Print): Buffer {
  const count = print.hashes.length;
  const buffer = Buffer.alloc(8 + count * 5);
  buffer.writeUInt32LE(count, 0);
  buffer.writeUInt32LE(Math.round(print.startMs), 4);
  for (let i = 0; i < count; i++) buffer.writeUInt32LE(print.hashes[i] as number, 8 + i * 4);
  for (let i = 0; i < count; i++) buffer[8 + count * 4 + i] = print.silent[i] as number;
  return buffer;
}

export function decodePrint(buffer: Buffer): Print {
  if (buffer.length < 8) throw new Error("A fingerprint file is too short.");
  const count = buffer.readUInt32LE(0);
  if (buffer.length !== 8 + count * 5) throw new Error("A fingerprint file has the wrong length.");
  const hashes = new Uint32Array(count);
  const silent = new Uint8Array(count);
  for (let i = 0; i < count; i++) hashes[i] = buffer.readUInt32LE(8 + i * 4);
  for (let i = 0; i < count; i++) silent[i] = buffer[8 + count * 4 + i] as number;
  return { startMs: buffer.readUInt32LE(4), hashes, silent };
}
