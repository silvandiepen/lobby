// SPDX-License-Identifier: MPL-2.0
import { writeFileSync } from "node:fs";

/**
 * Writes real PGS (Blu-ray) subtitles, a `.sup` file, so tests can make films with image
 * subtitles: ffmpeg cannot turn text into pictures. The format is what Blu-ray players read:
 * segments of a composition, a window, a palette and an RLE picture per cue, and an empty
 * composition to clear it.
 */
export interface PgsPicture {
  width: number;
  height: number;
  /** One byte per pixel: 0 is transparent, anything else is drawn, brighter is whiter. */
  pixels: Uint8Array;
}

export interface PgsCue {
  startMs: number;
  endMs: number;
  picture: PgsPicture;
  /** Where on the screen; the bottom middle when left out. */
  x?: number;
  y?: number;
}

const PCS = 0x16;
const WDS = 0x17;
const PDS = 0x14;
const ODS = 0x15;
const END = 0x80;

function segment(type: number, ms: number, payload: number[]): number[] {
  const pts = Math.round(ms * 90);
  return [
    0x50,
    0x47,
    (pts >>> 24) & 0xff,
    (pts >>> 16) & 0xff,
    (pts >>> 8) & 0xff,
    pts & 0xff,
    0,
    0,
    0,
    0,
    type,
    (payload.length >> 8) & 0xff,
    payload.length & 0xff,
    ...payload,
  ];
}

const u16 = (value: number): number[] => [(value >> 8) & 0xff, value & 0xff];

/** Four grey levels, drawn as white text of growing opacity. */
function level(pixel: number): number {
  return pixel < 32 ? 0 : pixel < 96 ? 1 : pixel < 176 ? 2 : 3;
}

function rle(picture: PgsPicture): number[] {
  const out: number[] = [];
  for (let y = 0; y < picture.height; y += 1) {
    let x = 0;
    while (x < picture.width) {
      const colour = level(picture.pixels[y * picture.width + x] ?? 0);
      let run = 1;
      while (
        x + run < picture.width &&
        run < 16383 &&
        level(picture.pixels[y * picture.width + x + run] ?? 0) === colour
      )
        run += 1;
      if (colour !== 0 && run === 1) {
        out.push(colour);
      } else if (colour === 0) {
        out.push(0, ...(run < 64 ? [run] : [0x40 | (run >> 8), run & 0xff]));
      } else {
        out.push(0, ...(run < 64 ? [0x80 | run] : [0xc0 | (run >> 8), run & 0xff]), colour);
      }
      x += run;
    }
    out.push(0, 0);
  }
  return out;
}

export function pgsFile(cues: PgsCue[], screen = { width: 1920, height: 1080 }): Uint8Array {
  const bytes: number[] = [];
  let composition = 0;
  for (const cue of cues) {
    const { width, height } = cue.picture;
    const x = cue.x ?? Math.max(0, Math.round((screen.width - width) / 2));
    const y = cue.y ?? Math.max(0, screen.height - height - 60);
    const window = [1, 0, ...u16(x), ...u16(y), ...u16(width), ...u16(height)];
    bytes.push(
      ...segment(PCS, cue.startMs, [
        ...u16(screen.width),
        ...u16(screen.height),
        0x10,
        ...u16(composition++),
        0x80,
        0,
        0,
        1,
        ...u16(0),
        0,
        0,
        ...u16(x),
        ...u16(y),
      ]),
      ...segment(WDS, cue.startMs, window),
      // Y, Cr, Cb, alpha: white at four opacities.
      ...segment(PDS, cue.startMs, [
        0,
        0,
        ...[0, 16, 128, 128, 0],
        ...[1, 235, 128, 128, 96],
        ...[2, 235, 128, 128, 176],
        ...[3, 235, 128, 128, 255],
      ]),
    );
    const data = rle(cue.picture);
    const length = data.length + 4;
    bytes.push(
      ...segment(ODS, cue.startMs, [
        ...u16(0),
        0,
        0xc0,
        (length >> 16) & 0xff,
        (length >> 8) & 0xff,
        length & 0xff,
        ...u16(width),
        ...u16(height),
        ...data,
      ]),
      ...segment(END, cue.startMs, []),
      // The clearing composition: no objects.
      ...segment(PCS, cue.endMs, [
        ...u16(screen.width),
        ...u16(screen.height),
        0x10,
        ...u16(composition++),
        0,
        0,
        0,
        0,
      ]),
      ...segment(WDS, cue.endMs, window),
      ...segment(END, cue.endMs, []),
    );
  }
  return Uint8Array.from(bytes);
}

export function writePgs(
  path: string,
  cues: PgsCue[],
  screen?: { width: number; height: number },
): void {
  writeFileSync(path, pgsFile(cues, screen));
}

/** A filled block, for cues whose look does not matter. */
export function block(width: number, height: number): PgsPicture {
  return { width, height, pixels: new Uint8Array(width * height).fill(255) };
}
