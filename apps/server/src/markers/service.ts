// SPDX-License-Identifier: MPL-2.0
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { readdir, rm } from "node:fs/promises";
import { setPriority } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Database } from "../db/database.ts";
import type { Catalogue } from "../library/catalogue.ts";
import { errorMessage, log, withoutPaths } from "../log.ts";
import { markersFromChapters, readChapters } from "./chapters.ts";
import { MIN_CONFIDENCE } from "./match.ts";
import { DETECTOR, putMarker, type MarkerKind } from "./store.ts";
import type {
  MatchAnswer,
  MatchRequest,
  PrintAnswer,
  PrintRequest,
  ThemeRef,
  WorkRequest,
} from "./work.ts";

export interface MarkerOptions {
  db: Database;
  catalogue?: Catalogue;
  /** Where the fingerprints are kept. */
  dir: string;
  ffmpegPath?: string;
  ffprobePath?: string;
  /**
   * Why the job should wait now (outside the hours for converting, someone watching); null: go
   * on. What a manager asked for goes on regardless.
   */
  waitBecause?: () => string | null;
  /** How much of the start of an episode is searched for its intro, at most. Default 10 minutes. */
  introMs?: number;
  /** How much of the end is searched for the credits, at most. Default 8 minutes. */
  creditsMs?: number;
  intervalMs?: number;
  now?: () => number;
}

/** Of an episode: a quarter of it at most, at either end. */
const SHARE = 0.25;
const MAX_FAILURES = 3;
/** Neighbours an episode is compared with when its season's theme is not known. */
const PARTNERS = 4;
/** A detected stretch becomes the season's theme when it is this sure, and two agreed. */
const THEME_CONFIDENCE = 0.7;
const WORK_TIMEOUT_MS = 20 * 60_000;
const WORKER = fileURLToPath(new URL("./worker.ts", import.meta.url));

interface ScanRow {
  asset_id: string;
  kind: string;
  season_id: string | null;
  show_id: string | null;
  season_number: number | null;
  episode_number: number | null;
  shared: number;
  revision: string;
  duration_ms: number | null;
  source_path: string;
  rel_path: string;
  path: string;
  chapters_at: number | null;
  printed_at: number | null;
  matched_at: number | null;
  requested_at: number | null;
  failures: number;
}

export interface MarkerStatus {
  /** Why it waits now; null while it may work. */
  waitingBecause: string | null;
  /** The file it is working on now. */
  working: string | null;
  /** Files whose chapters are still to be read, and episodes still to be compared. */
  pending: { chapters: number; episodes: number; requested: number };
  /** Episodes with a detected intro or credits sure enough to show. */
  found: { intro: number; credits: number };
}

export class MarkerError extends Error {
  readonly code: "not_found" | "invalid_request";
  constructor(code: "not_found" | "invalid_request", message: string) {
    super(message);
    this.code = code;
  }
}

/**
 * Finds where episodes' intros and credits are, in the background (docs/decisions.md, "Skip Intro").
 *
 * One file at a time, in this order: the chapters of every film and episode (headers only);
 * then per season, the fingerprint of each episode's first and last minutes; then each episode
 * against its season's theme, or against its neighbours while the theme is not known yet. It
 * works only when converting may (the hours set for it, nobody watching), in a process of its own
 * at the lowest priority, stopped while somebody starts watching. Every step is kept as it is
 * done, so after a restart it goes on where it stopped. Playing never waits for it.
 */
export class MarkerService {
  private readonly options: MarkerOptions;
  private readonly db: Database;
  private readonly now: () => number;
  private timer: NodeJS.Timeout | null = null;
  private lane: Promise<void> | null = null;
  private running: { assetId: string; pid: number | null; paused: boolean } | null = null;
  private stopped = false;

  constructor(options: MarkerOptions) {
    this.options = options;
    this.db = options.db;
    this.now = options.now ?? Date.now;
  }

  async start(): Promise<void> {
    this.stopped = false;
    await this.removeStalePrints().catch((error: unknown) => {
      log.warn("Could not tidy the intro fingerprints", { error: errorMessage(error) });
    });
    if (this.timer) return;
    this.timer = setInterval(() => void this.tick(), this.options.intervalMs ?? 30_000);
    this.timer.unref();
  }

  async stop(): Promise<void> {
    this.stopped = true;
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    this.signal("SIGKILL");
    await Promise.race([this.lane, new Promise((resolve) => setTimeout(resolve, 5000).unref())]);
  }

  /** Works until there is nothing more it may do now. Work going on is joined, not doubled. */
  tick(): Promise<void> {
    if (this.stopped) return Promise.resolve();
    this.lane ??= this.work()
      .catch((error: unknown) => {
        log.error("Finding intros failed unexpectedly", { error: errorMessage(error) });
      })
      .finally(() => {
        this.lane = null;
        this.running = null;
      });
    return this.lane;
  }

  /** Until nothing is left that may be done now: for tests and the `lobby` command. */
  async drain(): Promise<void> {
    while (!this.stopped) {
      await this.tick();
      if (!this.next(this.waitBecause() === null)) return;
    }
  }

  status(): MarkerStatus {
    this.sync();
    const counts = this.db.get<{ chapters: number; episodes: number; requested: number }>(
      `select
         coalesce(sum(chapters_at is null and failures < ${String(MAX_FAILURES)}), 0) as chapters,
         coalesce(sum(matched_at is null and failures < ${String(MAX_FAILURES)} and ${EPISODE}), 0) as episodes,
         coalesce(sum(requested_at is not null), 0) as requested
       from marker_scan join asset on asset.id = marker_scan.asset_id`,
    ) ?? { chapters: 0, episodes: 0, requested: 0 };
    const found = this.db.get<{ intro: number; credits: number }>(
      `select coalesce(sum(kind = 'intro'), 0) as intro, coalesce(sum(kind = 'credits'), 0) as credits
       from marker where source = 'detected' and confidence >= ?`,
      [MIN_CONFIDENCE],
    ) ?? { intro: 0, credits: 0 };
    return {
      waitingBecause: this.waitBecause(),
      working: this.running?.assetId ?? null,
      pending: counts,
      found,
    };
  }

  /**
   * A manager asks for a season (or a show, or an episode's season, or a film) to be looked at
   * again now: chapters read again, episodes compared again, the theme found again.
   * @returns how many files will be looked at
   */
  request(itemId: string): number {
    const item = this.db.get<{ id: string; kind: string; parent_id: string | null }>(
      "select id, kind, parent_id from item where id = ?",
      [itemId],
    );
    if (!item) throw new MarkerError("not_found", "There is no such title.");
    let seasons: string[] = [];
    let assets: string[];
    if (item.kind === "movie" || item.kind === "personal") {
      assets = this.mainAssets([item.id]);
    } else if (item.kind === "show") {
      seasons = this.db
        .all<{ id: string }>("select id from item where parent_id = ? and kind = 'season'", [
          item.id,
        ])
        .map((row) => row.id);
      assets = this.episodeAssets(seasons);
    } else if (item.kind === "season") {
      seasons = [item.id];
      assets = this.episodeAssets(seasons);
    } else if (item.kind === "episode" && item.parent_id !== null) {
      seasons = [item.parent_id];
      assets = this.episodeAssets(seasons);
    } else {
      throw new MarkerError("invalid_request", "Intros are found for films, shows and seasons.");
    }
    this.sync();
    const now = this.now();
    this.db.transaction(() => {
      for (const season of seasons) {
        this.db.run("delete from season_theme where season_id = ?", [season]);
      }
      for (const asset of assets) {
        this.db.run(
          `update marker_scan set requested_at = ?, chapters_at = null, matched_at = null,
             failures = 0, reason = null, updated_at = ? where asset_id = ?`,
          [now, now, asset],
        );
      }
    });
    void this.tick();
    return assets.length;
  }

  /** A manager changed a file's markers: the apps fetch its items again. */
  changed(assetId: string): void {
    this.options.catalogue?.touchAsset(assetId);
  }

  /** Read again after each wait: `stop()` may have come meanwhile. */
  private isStopped(): boolean {
    return this.stopped;
  }

  private waitBecause(): string | null {
    return this.options.waitBecause?.() ?? null;
  }

  private mainAssets(itemIds: string[]): string[] {
    return this.db
      .all<{ asset_id: string }>(
        `select asset_id from item_asset where role = 'main' and item_id in (select value from json_each(?))`,
        [JSON.stringify(itemIds)],
      )
      .map((row) => row.asset_id);
  }

  private episodeAssets(seasonIds: string[]): string[] {
    return this.mainAssets(
      this.db
        .all<{ id: string }>(
          `select id from item where kind = 'episode' and parent_id in (select value from json_each(?))`,
          [JSON.stringify(seasonIds)],
        )
        .map((row) => row.id),
    );
  }

  // ---- The work ----

  /**
   * Brings the job's list in step with the catalogue: every probed main file of a film or an
   * episode, started again from the beginning when the file changed or the detector did.
   */
  private sync(): void {
    const now = this.now();
    this.db.transaction(() => {
      this.db.run(
        `insert into marker_scan (asset_id, revision, detector, updated_at)
         select distinct asset.id, asset.revision, ?, ? from asset
         join item_asset on item_asset.asset_id = asset.id and item_asset.role = 'main'
         join item on item.id = item_asset.item_id and item.kind in ('movie', 'episode')
         where asset.state = 'probed'
         on conflict (asset_id) do update set revision = excluded.revision,
           detector = excluded.detector, chapters_at = null, printed_at = null, matched_at = null,
           failures = 0, reason = null, updated_at = excluded.updated_at
         where marker_scan.revision != excluded.revision or marker_scan.detector != excluded.detector`,
        [DETECTOR, now],
      );
    });
  }

  private rows(): ScanRow[] {
    const rows = this.db.all<ScanRow>(
      `select marker_scan.asset_id, item.kind, season.id as season_id, season.parent_id as show_id,
         item.season_number, item.episode_number, asset.revision, asset.duration_ms,
         (select count(*) from item_asset as other join item as shared on shared.id = other.item_id
            where other.asset_id = asset.id and shared.kind = 'episode') > 1 as shared,
         source.path as source_path, asset.rel_path,
         marker_scan.chapters_at, marker_scan.printed_at, marker_scan.matched_at,
         marker_scan.requested_at, marker_scan.failures
       from marker_scan
       join asset on asset.id = marker_scan.asset_id
       join source on source.id = asset.source_id
       join item_asset on item_asset.asset_id = asset.id and item_asset.role = 'main'
       join item on item.id = item_asset.item_id
       left join item as season on season.id = item.parent_id and item.kind = 'episode'
       where asset.available = 1 and source.available = 1 and marker_scan.failures < ?
       group by marker_scan.asset_id
       order by marker_scan.requested_at is null, season.parent_id, item.season_number,
         item.episode_number, marker_scan.asset_id`,
      [MAX_FAILURES],
    );
    for (const row of rows) row.path = join(row.source_path, row.rel_path);
    return rows;
  }

  /** What there is to do next, if anything may be done: a manager's request at any time. */
  private next(mayWait: boolean): { row: ScanRow; step: "chapters" | "print" | "match" } | null {
    this.sync();
    const rows = this.rows().filter((row) => mayWait || row.requested_at !== null);
    for (const row of rows) {
      if (row.chapters_at === null) return { row, step: "chapters" };
    }
    for (const row of rows) {
      if (row.kind !== "episode" || row.season_id === null || row.shared) continue;
      // Also one whose chapters say both: its neighbours are compared with it.
      if (row.printed_at === null) return { row, step: "print" };
    }
    for (const row of rows) {
      if (row.kind !== "episode" || row.season_id === null || row.shared) continue;
      if (row.matched_at !== null || row.printed_at === null) continue;
      // Compared once its season's episodes all have their fingerprints, so it has partners.
      const waiting = this.db.get<{ n: number }>(
        `select 1 as n from marker_scan
         join item_asset on item_asset.asset_id = marker_scan.asset_id and item_asset.role = 'main'
         join item on item.id = item_asset.item_id
         join asset on asset.id = marker_scan.asset_id and asset.available = 1
         where item.parent_id = ? and item.kind = 'episode' and marker_scan.printed_at is null
           and marker_scan.failures < ?`,
        [row.season_id, MAX_FAILURES],
      );
      if (waiting && row.requested_at === null) continue;
      return { row, step: "match" };
    }
    return null;
  }

  /** The kinds still to be found for an episode: those that a manager or its chapters do not give. */
  private wanted(row: ScanRow): MarkerKind[] {
    const known = new Set(
      this.db
        .all<{ kind: MarkerKind }>(
          `select kind from marker where asset_id = ?
             and (source = 'manual' or (source = 'chapters' and asset_revision = ?))`,
          [row.asset_id, row.revision],
        )
        .map((one) => one.kind),
    );
    return (["intro", "credits"] as const).filter((kind) => !known.has(kind));
  }

  private async work(): Promise<void> {
    for (;;) {
      if (this.stopped) return;
      const next = this.next(this.waitBecause() === null);
      if (!next) return;
      const { row, step } = next;
      this.running = { assetId: row.asset_id, pid: null, paused: false };
      try {
        if (step === "chapters") await this.readChapters(row);
        else if (step === "print") await this.print(row);
        else await this.match(row);
      } catch (error) {
        // Stopping kills the worker: that is no failure of the file.
        if (this.isStopped()) return;
        const reason = withoutPaths(errorMessage(error)).slice(0, 300);
        log.warn("Could not look for a file's intro", { asset: row.asset_id, step, reason });
        this.db.run(
          "update marker_scan set failures = failures + 1, reason = ?, updated_at = ? where asset_id = ?",
          [reason, this.now(), row.asset_id],
        );
      } finally {
        this.running = null;
      }
    }
  }

  private async readChapters(row: ScanRow): Promise<void> {
    const chapters = await readChapters(row.path, this.options.ffprobePath ?? "ffprobe");
    const found = markersFromChapters(chapters, row.duration_ms);
    const now = this.now();
    const changed = this.db.transaction(() => {
      const intro = putMarker(
        this.db,
        row.asset_id,
        "intro",
        "chapters",
        found.intro && { ...found.intro, confidence: 1 },
        row.revision,
        now,
      );
      const credits = putMarker(
        this.db,
        row.asset_id,
        "credits",
        "chapters",
        found.credits && { startMs: found.credits.startMs, endMs: null, confidence: 1 },
        row.revision,
        now,
      );
      this.db.run("update marker_scan set chapters_at = ?, updated_at = ? where asset_id = ?", [
        now,
        now,
        row.asset_id,
      ]);
      // A film is done with its chapters: pictures of credits are not looked for (docs/decisions.md, "Skip Intro").
      if (row.kind !== "episode") this.finish(row.asset_id, now);
      return intro || credits;
    });
    if (changed) this.options.catalogue?.touchAsset(row.asset_id);
  }

  private printFile(assetId: string, revision: string, kind: MarkerKind): string {
    const safe = revision.replace(/[^A-Za-z0-9_-]/g, "_");
    return join(this.options.dir, `${assetId}.${safe}.${kind}.fp`);
  }

  /** The stretch of an episode searched for each kind. */
  private stretches(row: ScanRow): { kind: MarkerKind; startMs: number; durationMs: number }[] {
    const duration = row.duration_ms ?? 0;
    const intro = Math.min(this.options.introMs ?? 10 * 60_000, duration * SHARE);
    const credits = Math.min(this.options.creditsMs ?? 8 * 60_000, duration * SHARE);
    return (["intro", "credits"] as const).map((kind) =>
      kind === "intro"
        ? { kind, startMs: 0, durationMs: Math.round(intro) }
        : { kind, startMs: Math.round(duration - credits), durationMs: Math.round(credits) },
    );
  }

  private async print(row: ScanRow): Promise<void> {
    if (row.duration_ms === null || row.duration_ms < 60_000) {
      this.db.run(
        `update marker_scan set printed_at = ?, matched_at = ?, requested_at = null,
           reason = 'Too short to have an intro.', updated_at = ? where asset_id = ?`,
        [this.now(), this.now(), this.now(), row.asset_id],
      );
      return;
    }
    const audio = this.db.get<{ idx: number }>(
      `select idx from track where asset_id = ? and kind = 'audio' order by is_default desc, idx limit 1`,
      [row.asset_id],
    );
    if (!audio) {
      this.db.run(
        `update marker_scan set printed_at = ?, matched_at = ?, requested_at = null,
           reason = 'The file has no sound.', updated_at = ? where asset_id = ?`,
        [this.now(), this.now(), this.now(), row.asset_id],
      );
      return;
    }
    const request: PrintRequest = {
      op: "print",
      ffmpegPath: this.options.ffmpegPath ?? "ffmpeg",
      path: row.path,
      streamIndex: audio.idx,
      stretches: this.stretches(row).map((stretch) => ({
        ...stretch,
        out: this.printFile(row.asset_id, row.revision, stretch.kind),
      })),
    };
    await this.run<PrintAnswer>(request, row);
    // Older fingerprints of the same file are of no use any more.
    await this.removeStalePrints(row.asset_id);
    const now = this.now();
    this.db.run(
      "update marker_scan set printed_at = ?, reason = null, updated_at = ? where asset_id = ?",
      [now, now, row.asset_id],
    );
    // Episodes that had nobody to compare with have somebody now.
    this.db.run(
      `update marker_scan set matched_at = null, updated_at = ? where reason = ? and asset_id in (
         select item_asset.asset_id from item_asset join item on item.id = item_asset.item_id
         join item as season on season.id = item.parent_id
         where season.parent_id = ? and item.kind = 'episode')`,
      [now, ALONE, row.show_id],
    );
  }

  /** The other episodes to compare with: of the same season first, the nearest first. */
  private partners(row: ScanRow, kind: MarkerKind): string[] {
    const others = this.db.all<{
      asset_id: string;
      revision: string;
      season_id: string;
      season_number: number | null;
      episode_number: number | null;
    }>(
      `select marker_scan.asset_id, asset.revision, item.parent_id as season_id,
         season.season_number, item.episode_number
       from marker_scan
       join asset on asset.id = marker_scan.asset_id
       join item_asset on item_asset.asset_id = asset.id and item_asset.role = 'main'
       join item on item.id = item_asset.item_id and item.kind = 'episode'
       join item as season on season.id = item.parent_id
       where season.parent_id = ? and marker_scan.printed_at is not null
         and marker_scan.asset_id != ? and asset.available = 1`,
      [row.show_id, row.asset_id],
    );
    const distance = (other: (typeof others)[number]): number =>
      other.season_id === row.season_id
        ? Math.abs((other.episode_number ?? 0) - (row.episode_number ?? 0))
        : 1000 * (1 + Math.abs((other.season_number ?? 0) - (row.season_number ?? 0))) +
          (other.episode_number ?? 0);
    const files = others
      .sort((a, b) => distance(a) - distance(b))
      .map((other) => this.printFile(other.asset_id, other.revision, kind))
      .filter((file) => existsSync(file));
    const sameSeason = others.filter((other) => other.season_id === row.season_id).length;
    // Other seasons only to make up for a season that has too few of its own.
    return files.slice(0, sameSeason >= 2 ? Math.min(PARTNERS, sameSeason) : PARTNERS);
  }

  private theme(row: ScanRow, kind: MarkerKind): ThemeRef | null {
    const theme = this.db.get<{
      asset_id: string;
      asset_revision: string;
      start_ms: number;
      end_ms: number;
    }>(
      `select season_theme.* from season_theme join asset on asset.id = season_theme.asset_id
       where season_id = ? and kind = ? and detector = ? and asset.revision = season_theme.asset_revision
         and season_theme.asset_id != ?`,
      [row.season_id, kind, DETECTOR, row.asset_id],
    );
    if (!theme) return null;
    const file = this.printFile(theme.asset_id, theme.asset_revision, kind);
    if (!existsSync(file)) return null;
    return { file, startMs: theme.start_ms, endMs: theme.end_ms };
  }

  private async match(row: ScanRow): Promise<void> {
    this.themeFromChapters(row);
    const kinds: MatchRequest["kinds"] = [];
    for (const kind of this.wanted(row)) {
      const target = this.printFile(row.asset_id, row.revision, kind);
      if (!existsSync(target)) {
        // Its fingerprint went (a cache that was cleared): made again first.
        this.db.run("update marker_scan set printed_at = null where asset_id = ?", [row.asset_id]);
        return;
      }
      kinds.push({
        kind,
        target,
        theme: this.theme(row, kind),
        partners: this.partners(row, kind),
      });
    }
    const now = this.now();
    if (kinds.length === 0) {
      // Its chapters or a manager say both: nothing to compare.
      this.finish(row.asset_id, now);
      return;
    }
    if (kinds.every((one) => one.theme === null && one.partners.length === 0)) {
      this.db.run(
        `update marker_scan set matched_at = ?, requested_at = null, reason = ?, updated_at = ?
         where asset_id = ?`,
        [now, ALONE, now, row.asset_id],
      );
      return;
    }
    const answer = await this.run<MatchAnswer>({ op: "match", kinds }, row);
    const changed = this.db.transaction(() => {
      let changed = false;
      for (const { kind } of kinds) {
        const found = answer.found[kind] ?? null;
        changed =
          putMarker(this.db, row.asset_id, kind, "detected", found, row.revision, now) || changed;
        if (
          found &&
          found.via === "episodes" &&
          found.agreeing >= 2 &&
          found.confidence >= THEME_CONFIDENCE &&
          row.season_id !== null
        ) {
          this.db.run(
            `insert into season_theme (season_id, kind, asset_id, asset_revision, start_ms, end_ms, detector, updated_at)
             values (?, ?, ?, ?, ?, ?, ?, ?) on conflict (season_id, kind) do nothing`,
            [
              row.season_id,
              kind,
              row.asset_id,
              row.revision,
              found.startMs,
              found.endMs,
              DETECTOR,
              now,
            ],
          );
        }
      }
      this.finish(row.asset_id, now);
      return changed;
    });
    if (changed) this.options.catalogue?.touchAsset(row.asset_id);
  }

  /** An intro its chapters name is the season's theme, while none is known. */
  private themeFromChapters(row: ScanRow): void {
    if (row.season_id === null) return;
    const intro = this.db.get<{ start_ms: number; end_ms: number }>(
      `select start_ms, end_ms from marker where asset_id = ? and kind = 'intro'
         and source = 'chapters' and asset_revision = ?`,
      [row.asset_id, row.revision],
    );
    if (!intro || !existsSync(this.printFile(row.asset_id, row.revision, "intro"))) return;
    this.db.run(
      `insert into season_theme (season_id, kind, asset_id, asset_revision, start_ms, end_ms, detector, updated_at)
       values (?, 'intro', ?, ?, ?, ?, ?, ?) on conflict (season_id, kind) do nothing`,
      [
        row.season_id,
        row.asset_id,
        row.revision,
        intro.start_ms,
        intro.end_ms,
        DETECTOR,
        this.now(),
      ],
    );
  }

  private finish(assetId: string, now: number): void {
    this.db.run(
      `update marker_scan set printed_at = coalesce(printed_at, ?), matched_at = ?,
         requested_at = null, failures = 0, reason = null, updated_at = ? where asset_id = ?`,
      [now, now, now, assetId],
    );
  }

  // ---- The process that does the heavy part ----

  private signal(signal: NodeJS.Signals): void {
    const pid = this.running?.pid;
    if (pid === undefined || pid === null) return;
    try {
      // The whole group: the worker and the ffmpeg it started.
      process.kill(-pid, signal);
    } catch {
      // It ended a moment ago.
    }
  }

  private pause(paused: boolean): void {
    if (!this.running || this.running.paused === paused) return;
    this.running.paused = paused;
    this.signal(paused ? "SIGSTOP" : "SIGCONT");
  }

  private run<T>(request: WorkRequest, row: ScanRow): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const child = spawn(process.execPath, [WORKER], {
        stdio: ["pipe", "pipe", "pipe"],
        // Its own group, so that it and its ffmpeg are stopped together.
        detached: true,
      });
      const running = this.running;
      child.once("spawn", () => {
        if (child.pid === undefined) return;
        if (running) running.pid = child.pid;
        try {
          // ffmpeg, started by it, inherits this.
          setPriority(child.pid, 19);
        } catch (error) {
          log.warn("Could not lower the priority of finding intros", {
            error: errorMessage(error),
          });
        }
        if (process.platform === "linux") {
          // The idle class: the drive is read only when nothing else wants it.
          spawn("ionice", ["-c", "3", "-p", String(child.pid)], { stdio: "ignore" }).once(
            "error",
            () => undefined,
          );
        }
      });
      const stdout: Buffer[] = [];
      let stderr = "";
      child.stdout.on("data", (chunk: Buffer) => stdout.push(chunk));
      child.stderr.on("data", (chunk: Buffer) => {
        if (stderr.length < 4000) stderr += chunk.toString("utf8");
      });
      // It stands still while it should not work, unless a manager asked.
      const watch = setInterval(() => {
        if (row.requested_at !== null) return;
        this.pause(this.waitBecause() !== null);
      }, 2000);
      const timeout = setTimeout(() => {
        this.signal("SIGKILL");
      }, WORK_TIMEOUT_MS);
      child.once("error", (error) => {
        clearInterval(watch);
        clearTimeout(timeout);
        reject(error);
      });
      child.once("close", (code, signal) => {
        clearInterval(watch);
        clearTimeout(timeout);
        if (code !== 0) {
          reject(new Error(stderr.trim() || `The worker ended (${signal ?? String(code)}).`));
          return;
        }
        try {
          resolve(JSON.parse(Buffer.concat(stdout).toString("utf8")) as T);
        } catch (error) {
          reject(error instanceof Error ? error : new Error(String(error)));
        }
      });
      child.stdin.end(JSON.stringify(request));
    });
  }

  /** Removes fingerprints of files that changed or went, or of one file all but the current. */
  private async removeStalePrints(assetId?: string): Promise<void> {
    if (!existsSync(this.options.dir)) return;
    const current = new Set(
      this.db
        .all<{ asset_id: string; revision: string }>(
          "select marker_scan.asset_id, asset.revision from marker_scan join asset on asset.id = marker_scan.asset_id",
        )
        .flatMap((row) =>
          (["intro", "credits"] as const).map((kind) =>
            this.printFile(row.asset_id, row.revision, kind),
          ),
        ),
    );
    for (const name of await readdir(this.options.dir)) {
      if (assetId !== undefined && !name.startsWith(`${assetId}.`)) continue;
      const file = join(this.options.dir, name);
      if (!current.has(file)) await rm(file, { force: true });
    }
  }
}

/** Why an episode was not compared: there was no other to compare it with. */
const ALONE = "No other episode to compare with yet.";

/** An episode's file, in SQL over marker_scan and asset. */
const EPISODE = `exists (select 1 from item_asset join item on item.id = item_asset.item_id
  where item_asset.asset_id = marker_scan.asset_id and item.kind = 'episode')`;
