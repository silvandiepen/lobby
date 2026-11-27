// SPDX-License-Identifier: MPL-2.0
import { differingBits, FRAME_MS, frameTime, type Print } from "./fingerprint.ts";

/**
 * Finding the stretch two episodes share, and agreeing on it across a season (docs/decisions.md, "Skip Intro").
 *
 * Two prints are laid over each other at every shift. At a shift, a frame matches when neither
 * side is silent and the two values differ in few bits. A run of matches, with short gaps allowed
 * (a sound effect over the theme, a frame cut differently), is a common stretch. The longest one
 * over all shifts wins. Unrelated sound matches a frame now and then by chance, never for long.
 */

export interface MatchOptions {
  /** A frame matches when its values differ in at most this many of 32 bits. */
  maxBits?: number;
  /** How many frames in a row may not match inside a stretch. */
  maxGapFrames?: number;
  /** The shortest stretch that counts. */
  minMs: number;
  /** The longest stretch that counts; a longer one is cut to the best part of this length. */
  maxMs?: number;
}

/** A stretch both prints have, as times in each file. */
export interface Common {
  aStartMs: number;
  aEndMs: number;
  bStartMs: number;
  bEndMs: number;
  /** The share of frames inside the stretch that matched, 0 to 1. */
  quality: number;
}

const DEFAULT_BITS = 10;
const DEFAULT_GAP = 12;

/** The longest stretch `a` and `b` have in common, or null when there is none long enough. */
export function longestCommon(a: Print, b: Print, options: MatchOptions): Common | null {
  const maxBits = options.maxBits ?? DEFAULT_BITS;
  const maxGap = options.maxGapFrames ?? DEFAULT_GAP;
  const minFrames = Math.ceil(options.minMs / FRAME_MS);
  const na = a.hashes.length;
  const nb = b.hashes.length;
  const ah = a.hashes;
  const bh = b.hashes;
  const as = a.silent;
  const bs = b.silent;
  let best: { shift: number; from: number; to: number; good: number } | null = null;
  // Frame i of a lies over frame i - shift of b.
  for (let shift = -(nb - 1); shift < na; shift++) {
    const from = Math.max(0, shift);
    const to = Math.min(na, nb + shift);
    if (to - from < minFrames) continue;
    if (best && to - from <= best.to - best.from) continue;
    let runStart = -1;
    let lastGood = -1;
    let good = 0;
    for (let i = from; i <= to; i++) {
      let matched = false;
      if (i < to) {
        const j = i - shift;
        matched =
          as[i] === 0 && bs[j] === 0 && differingBits(ah[i] as number, bh[j] as number) <= maxBits;
      }
      if (matched) {
        if (runStart < 0) {
          runStart = i;
          good = 0;
        }
        lastGood = i;
        good += 1;
        continue;
      }
      if (runStart >= 0 && (i === to || i - lastGood > maxGap)) {
        const length = lastGood + 1 - runStart;
        if (length >= minFrames && (!best || length > best.to - best.from)) {
          best = { shift, from: runStart, to: lastGood + 1, good };
        }
        runStart = -1;
      }
    }
  }
  if (!best) return null;
  let { from, to } = best;
  let good = best.good;
  const maxFrames = options.maxMs === undefined ? Infinity : Math.floor(options.maxMs / FRAME_MS);
  if (to - from > maxFrames) {
    // Longer than an intro can be: not what is looked for.
    return null;
  }
  // The edges of a run are single lucky frames as often as the music itself: trim them to
  // where matches are dense.
  ({ from, to, good } = trim(a, b, best.shift, from, to, good, maxBits));
  if (to - from < minFrames) return null;
  return {
    aStartMs: frameTime(a, from),
    aEndMs: frameTime(a, to - 1) + FRAME_MS / 2,
    bStartMs: frameTime(b, from - best.shift),
    bEndMs: frameTime(b, to - 1 - best.shift) + FRAME_MS / 2,
    quality: good / (to - from),
  };
}

/** Moves each end of a stretch inward while the frames there match less than half the time. */
function trim(
  a: Print,
  b: Print,
  shift: number,
  from: number,
  to: number,
  good: number,
  maxBits: number,
): { from: number; to: number; good: number } {
  const matches = (i: number): boolean => {
    const j = i - shift;
    return (
      a.silent[i] === 0 &&
      b.silent[j] === 0 &&
      differingBits(a.hashes[i] as number, b.hashes[j] as number) <= maxBits
    );
  };
  const WINDOW = 10;
  const dense = (start: number): boolean => {
    let count = 0;
    for (let i = start; i < start + WINDOW && i < to; i++) if (matches(i)) count += 1;
    return count >= WINDOW / 2;
  };
  while (to - from > WINDOW && !dense(from)) {
    if (matches(from)) good -= 1;
    from += 1;
  }
  while (to - from > WINDOW && !dense(to - WINDOW)) {
    if (matches(to - 1)) good -= 1;
    to -= 1;
  }
  return { from, to, good };
}

/** What one comparison said about the episode being judged. */
export interface Candidate {
  startMs: number;
  endMs: number;
  quality: number;
}

export interface Verdict {
  startMs: number;
  endMs: number;
  /** 0 to 1. Below `MIN_CONFIDENCE` it is kept but not used. */
  confidence: number;
  /** How many comparisons agreed. */
  agreeing: number;
}

/** Detected markers below this are not shown to viewers. */
export const MIN_CONFIDENCE = 0.5;

function overlapShare(x: Candidate, y: Candidate): number {
  const inside = Math.min(x.endMs, y.endMs) - Math.max(x.startMs, y.startMs);
  if (inside <= 0) return 0;
  const outside = Math.max(x.endMs, y.endMs) - Math.min(x.startMs, y.startMs);
  return inside / outside;
}

function median(values: number[]): number {
  const sorted = [...values].sort((x, y) => x - y);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1
    ? (sorted[middle] as number)
    : ((sorted[middle - 1] as number) + (sorted[middle] as number)) / 2;
}

/**
 * Agrees on one stretch for an episode from what each comparison with another episode found
 * (null where it found nothing). The largest group of stretches that overlap well wins; its
 * edges are the middle ones of the group. Confidence is how many comparisons agree, times how
 * well they matched; a single comparison counts for less than two that agree.
 */
export function vote(found: (Candidate | null)[]): Verdict | null {
  const candidates = found.filter((one): one is Candidate => one !== null);
  if (candidates.length === 0 || found.length === 0) return null;
  let bestGroup: Candidate[] = [];
  let bestScore = -1;
  for (const candidate of candidates) {
    const group = candidates.filter((other) => overlapShare(candidate, other) >= 0.6);
    const score = group.length + group.reduce((sum, one) => sum + one.quality, 0) / 1000;
    if (score > bestScore) {
      bestScore = score;
      bestGroup = group;
    }
  }
  const quality = bestGroup.reduce((sum, one) => sum + one.quality, 0) / bestGroup.length;
  const agreeing = bestGroup.length;
  const confidence =
    Math.min(1, quality / 0.7) * (agreeing / found.length) * (agreeing >= 2 ? 1 : 0.75);
  return {
    startMs: Math.round(median(bestGroup.map((one) => one.startMs))),
    endMs: Math.round(median(bestGroup.map((one) => one.endMs))),
    confidence: Math.round(confidence * 100) / 100,
    agreeing,
  };
}
