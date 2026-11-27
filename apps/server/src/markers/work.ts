// SPDX-License-Identifier: MPL-2.0
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import {
  decodeAudio,
  decodePrint,
  encodePrint,
  fingerprintSamples,
  frameAt,
  slicePrint,
  type Print,
} from "./fingerprint.ts";
import { longestCommon, vote, type Candidate, type Verdict } from "./match.ts";

/**
 * The heavy part of finding intros and credits, as one request and its answer. The background
 * job runs it in a process of its own at the lowest priority (`worker.ts`), so the server's own
 * process never stalls on it while somebody watches; tests call it directly.
 */

export type WorkKind = "intro" | "credits";

/** Fingerprints stretches of a file's sound into files. */
export interface PrintRequest {
  op: "print";
  ffmpegPath: string;
  path: string;
  streamIndex: number | null;
  niceness?: number;
  stretches: { kind: WorkKind; startMs: number; durationMs: number; out: string }[];
}

export interface PrintAnswer {
  frames: Partial<Record<WorkKind, number>>;
}

/** A season's theme: a stretch of one episode's fingerprint. */
export interface ThemeRef {
  file: string;
  startMs: number;
  endMs: number;
}

/** Finds an episode's intro or credits from its fingerprint and those of others. */
export interface MatchRequest {
  op: "match";
  kinds: {
    kind: WorkKind;
    target: string;
    theme: ThemeRef | null;
    partners: string[];
  }[];
}

export interface Found extends Verdict {
  via: "theme" | "episodes";
}

export interface MatchAnswer {
  found: Partial<Record<WorkKind, Found | null>>;
}

export type WorkRequest = PrintRequest | MatchRequest;

/** How long an intro may be, and the credits at the least. */
export const LIMITS: Record<WorkKind, { minMs: number; maxMs?: number }> = {
  intro: { minMs: 15_000, maxMs: 180_000 },
  credits: { minMs: 20_000 },
};

/** A match against the theme this sure needs no other comparison. */
const SURE = 0.7;

/** A theme is found again when this share of it matches. */
const THEME_SHARE = 0.7;

export async function runWork(request: PrintRequest): Promise<PrintAnswer>;
export async function runWork(request: MatchRequest): Promise<MatchAnswer>;
export async function runWork(request: WorkRequest): Promise<PrintAnswer | MatchAnswer>;
export async function runWork(request: WorkRequest): Promise<PrintAnswer | MatchAnswer> {
  if (request.op === "print") return print(request);
  return match(request);
}

async function print(request: PrintRequest): Promise<PrintAnswer> {
  const frames: PrintAnswer["frames"] = {};
  for (const stretch of request.stretches) {
    const samples = await decodeAudio(request.path, {
      ffmpegPath: request.ffmpegPath,
      streamIndex: request.streamIndex,
      startMs: stretch.startMs,
      durationMs: stretch.durationMs,
      ...(request.niceness === undefined ? {} : { niceness: request.niceness }),
    });
    const fingerprint = fingerprintSamples(samples, stretch.startMs);
    await mkdir(dirname(stretch.out), { recursive: true });
    const partial = `${stretch.out}.partial`;
    await writeFile(partial, encodePrint(fingerprint));
    await rename(partial, stretch.out);
    frames[stretch.kind] = fingerprint.hashes.length;
  }
  return { frames };
}

async function load(file: string, cache: Map<string, Print>): Promise<Print> {
  let print = cache.get(file);
  if (!print) {
    print = decodePrint(await readFile(file));
    cache.set(file, print);
  }
  return print;
}

async function match(request: MatchRequest): Promise<MatchAnswer> {
  const cache = new Map<string, Print>();
  const found: MatchAnswer["found"] = {};
  for (const job of request.kinds) {
    const target = await load(job.target, cache);
    const limits = LIMITS[job.kind];
    let result: Found | null = null;
    if (job.theme) {
      const reference = await load(job.theme.file, cache);
      const theme = slicePrint(
        reference,
        frameAt(reference, job.theme.startMs),
        frameAt(reference, job.theme.endMs),
      );
      const length = job.theme.endMs - job.theme.startMs;
      const common = longestCommon(target, theme, {
        minMs: Math.max(limits.minMs, length * THEME_SHARE),
        ...(limits.maxMs === undefined ? {} : { maxMs: limits.maxMs }),
      });
      if (common) {
        const share = Math.min(1, (common.aEndMs - common.aStartMs) / length);
        result = {
          startMs: Math.round(common.aStartMs),
          endMs: Math.round(common.aEndMs),
          confidence: Math.round(Math.min(1, common.quality / 0.7) * share * 100) / 100,
          agreeing: 1,
          via: "theme",
        };
      }
    }
    // Not sure against the theme: the neighbours are asked too, and the surer answer counts.
    if ((result === null || result.confidence < SURE) && job.partners.length > 0) {
      const candidates: (Candidate | null)[] = [];
      for (const partner of job.partners) {
        const common = longestCommon(target, await load(partner, cache), limits);
        candidates.push(
          common
            ? { startMs: common.aStartMs, endMs: common.aEndMs, quality: common.quality }
            : null,
        );
      }
      const verdict = vote(candidates);
      if (verdict && (result === null || verdict.confidence > result.confidence)) {
        result = { ...verdict, via: "episodes" };
      }
    }
    found[job.kind] = result;
  }
  return { found };
}
