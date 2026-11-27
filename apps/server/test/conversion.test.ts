// SPDX-License-Identifier: MPL-2.0
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  linkSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import type { Hono } from "hono";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { Devices } from "../src/auth/devices.ts";
import { loadConfig } from "../src/config.ts";
import { conversionArguments, type ConversionTarget } from "../src/conversion/convert.ts";
import {
  ConversionService,
  type ConversionJob,
  type ConversionOptions,
  type ConversionStatus,
  type Replacement,
} from "../src/conversion/index.ts";
import { Journal, type FaultPoint, type Operation } from "../src/conversion/moves.ts";
import { Database } from "../src/db/database.ts";
import { createApp, type AppEnv } from "../src/http/app.ts";
import { Catalogue } from "../src/library/catalogue.ts";
import { ItemReader, type ApiItem } from "../src/library/items.ts";
import { Scanner } from "../src/library/scanner.ts";
import { ProgressStore } from "../src/progress.ts";
import { hasEncoder, makeAvi, sha256, srt } from "./playback-support.ts";
import { makeTempDir, makeVideo, removeDir } from "./support/media.ts";

const SETUP_SECRET = "test-setup-secret";
const MINUTE = 60_000;

function tree(root: string): string[] {
  if (!existsSync(root)) return [];
  const found: string[] = [];
  const walk = (dir: string, prefix: string): void => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.isDirectory()) walk(join(dir, entry.name), rel);
      else found.push(rel);
    }
  };
  walk(root, "");
  return found.sort();
}

describe("moves that happen completely or not at all", () => {
  let dir: string;
  let commits: string[];
  let abandoned: string[];

  beforeEach(() => {
    dir = makeTempDir("lobby-moves-");
    commits = [];
    abandoned = [];
  });

  afterEach(() => {
    removeDir(dir);
  });

  function journal(crashAt?: FaultPoint): Journal<{ note: string }> {
    return new Journal<{ note: string }>(join(dir, "journal"), {
      commit: (operation) => {
        commits.push(operation.id);
      },
      abandon: (operation) => {
        abandoned.push(operation.id);
      },
      ...(crashAt
        ? {
            fault: (point) => {
              if (point === crashAt) throw new Error(`killed at ${point}`);
            },
          }
        : {}),
    });
  }

  /** An original in the library, a converted file in staging, and the replacement of one by the other. */
  function replacement(sameName = false): Operation<{ note: string }> {
    mkdirSync(join(dir, "library"), { recursive: true });
    mkdirSync(join(dir, "staging"), { recursive: true });
    writeFileSync(join(dir, "library", sameName ? "film.mp4" : "film.avi"), "the original");
    writeFileSync(join(dir, "staging", "job.mp4"), "the converted file");
    return {
      id: "op-1",
      kind: "replace",
      moves: [
        {
          from: join(dir, "library", sameName ? "film.mp4" : "film.avi"),
          to: join(dir, "kept", "film.original"),
          size: "the original".length,
        },
        {
          from: join(dir, "staging", "job.mp4"),
          to: join(dir, "library", "film.mp4"),
          size: "the converted file".length,
        },
      ],
      data: { note: "x" },
    };
  }

  /** The original's bytes exist exactly once, whatever happened. */
  function originalIsSomewhere(): void {
    const places = ["library/film.avi", "kept/film.original"].filter(
      (path) =>
        existsSync(join(dir, path)) && readFileSync(join(dir, path), "utf8") === "the original",
    );
    expect(places).toHaveLength(1);
  }

  it("moves both files and writes the outcome once", async () => {
    await journal().run(replacement());
    expect(tree(dir)).toEqual(["kept/film.original", "library/film.mp4"]);
    expect(readFileSync(join(dir, "library/film.mp4"), "utf8")).toBe("the converted file");
    expect(commits).toEqual(["op-1"]);
    expect(await journal().recover()).toEqual([]);
    expect(commits).toEqual(["op-1"]);
  });

  for (const point of ["journal", "move:0", "move:1", "commit"] as const) {
    it(`finishes a replacement that was killed at "${point}"`, async () => {
      await expect(journal(point).run(replacement())).rejects.toThrow(`killed at ${point}`);
      originalIsSomewhere();
      // The library is never left without the film for good: recovery completes it.
      expect(await journal().recover()).toEqual([]);
      expect(tree(dir)).toEqual(["kept/film.original", "library/film.mp4"]);
      expect(readFileSync(join(dir, "kept/film.original"), "utf8")).toBe("the original");
      expect(commits.at(-1)).toBe("op-1");
      expect(abandoned).toEqual([]);
      // A second start finds nothing left to do.
      const before = commits.length;
      expect(await journal().recover()).toEqual([]);
      expect(commits).toHaveLength(before);
    });
  }

  it("takes the first move back when the converted file is gone", async () => {
    await expect(journal("move:0").run(replacement())).rejects.toThrow();
    rmSync(join(dir, "staging", "job.mp4"));
    expect(await journal().recover()).toEqual([]);
    expect(tree(dir)).toEqual(["library/film.avi"]);
    expect(readFileSync(join(dir, "library/film.avi"), "utf8")).toBe("the original");
    expect(commits).toEqual([]);
    expect(abandoned).toEqual(["op-1"]);
  });

  it("gives up without touching anything when the original vanished before the first move", async () => {
    await expect(journal("journal").run(replacement())).rejects.toThrow();
    rmSync(join(dir, "library", "film.avi"));
    expect(await journal().recover()).toEqual([]);
    expect(tree(dir)).toEqual(["staging/job.mp4"]);
    expect(abandoned).toEqual(["op-1"]);
  });

  it("leaves files alone, and says so, when they are in two places at once", async () => {
    await expect(journal("move:0").run(replacement())).rejects.toThrow();
    // Someone put a file back under the original's name meanwhile.
    writeFileSync(join(dir, "library", "film.avi"), "the original");
    const before = tree(dir);
    const unclear = await journal().recover();
    expect(unclear).toEqual([{ id: "op-1", reason: expect.any(String) as string }]);
    expect(tree(dir)).toEqual(before);
    expect(commits).toEqual([]);
    expect(abandoned).toEqual([]);
  });

  it("never replaces a file that is already at the destination", async () => {
    const operation = replacement();
    writeFileSync(join(dir, "library", "film.mp4"), "someone else's file");
    await expect(journal().run(operation)).rejects.toThrow(/already a file/);
    // The first move was made; the second cannot be. Nothing is overwritten.
    expect(readFileSync(join(dir, "library/film.mp4"), "utf8")).toBe("someone else's file");
    // Recovery takes the first move back: the library is as it was, plus the stranger's file.
    expect(await journal().recover()).toEqual([]);
    expect(tree(dir)).toEqual(["library/film.avi", "library/film.mp4", "staging/job.mp4"]);
    expect(readFileSync(join(dir, "library/film.mp4"), "utf8")).toBe("someone else's file");
    expect(readFileSync(join(dir, "library/film.avi"), "utf8")).toBe("the original");
    expect(commits).toEqual([]);
    expect(abandoned).toEqual(["op-1"]);
  });

  for (const point of ["journal", "move:0", "move:1", "commit"] as const) {
    it(`handles a new file that takes the old file's exact name, killed at "${point}"`, async () => {
      await expect(journal(point).run(replacement(true))).rejects.toThrow();
      expect(await journal().recover()).toEqual([]);
      expect(tree(dir)).toEqual(["kept/film.original", "library/film.mp4"]);
      expect(readFileSync(join(dir, "library/film.mp4"), "utf8")).toBe("the converted file");
      expect(readFileSync(join(dir, "kept/film.original"), "utf8")).toBe("the original");
    });
  }
});

describe("the conversion config", () => {
  let dir: string;

  beforeEach(() => {
    dir = makeTempDir("lobby-conversion-config-");
  });

  afterEach(() => {
    removeDir(dir);
  });

  function config(conversion: unknown): string {
    const path = join(dir, "lobby.config.json");
    writeFileSync(
      path,
      JSON.stringify({
        roots: [{ path: "/drive/Films", hint: "movies" }],
        ...(conversion === undefined ? {} : { conversion }),
      }),
    );
    return path;
  }

  it("is off unless a folder is configured", () => {
    expect(loadConfig(config(undefined)).conversion).toEqual({
      dir: null,
      hours: null,
      repackage: false,
      server: true,
      minFreeGb: 5,
    });
    expect(loadConfig(config({ hours: "01:00-07:00", repackage: true })).conversion.dir).toBeNull();
  });

  it("reads the folder, the hours and the switches", () => {
    expect(
      loadConfig(
        config({ dir: "/drive/.lobby/", hours: "23:30-06:15", repackage: true, server: false }),
      ).conversion,
    ).toEqual({
      dir: "/drive/.lobby",
      hours: { from: 23 * 60 + 30, to: 6 * 60 + 15 },
      repackage: true,
      server: false,
      minFreeGb: 5,
    });
  });

  it("refuses a folder inside the library, around it, or not on the drive", () => {
    for (const [conversion, message] of [
      [{ dir: "relative/path" }, /absolute path/],
      [{ dir: "/drive/Films/.lobby" }, /must not be inside a library root/],
      [{ dir: "/drive/Films" }, /must not be inside a library root/],
      [{ dir: "/drive" }, /must not contain a library root/],
      [{ dir: join(dir, "data", "conversion") }, /not in the data folder/],
      [{ dir: "/drive/.lobby", hours: "1-7" }, /must look like/],
      [{ dir: "/drive/.lobby", hours: "25:00-07:00" }, /must look like/],
      [{ dir: "/drive/.lobby", hours: "07:00-07:00" }, /same time/],
    ] as const) {
      expect(() => loadConfig(config(conversion)), JSON.stringify(conversion)).toThrow(message);
    }
  });
});

interface Fixture {
  root: string;
  /** Stands in for the media drive: the library folders and Lobby's folder are on it. */
  drive: string;
  movies: string;
  series: string;
  lobby: string;
  db: Database;
  scanner: Scanner;
  catalogue: Catalogue;
  clock: { now: number };
}

describe.skipIf(!hasEncoder("libmp3lame"))("converting files and replacing originals", () => {
  let fixture: Fixture;
  let services: ConversionService[];
  let app: Hono<AppEnv>;
  let managerToken: string;

  beforeEach(() => {
    const root = makeTempDir("lobby-conversion-");
    const drive = join(root, "drive");
    const movies = join(drive, "Movies");
    const series = join(drive, "Series");
    mkdirSync(movies, { recursive: true });
    mkdirSync(series, { recursive: true });
    const clock = { now: Date.UTC(2026, 10, 24, 12, 0, 0) };
    const now = (): number => clock.now;
    const db = new Database(join(root, "lobby.db"));
    const catalogue = new Catalogue(db, now);
    const scanner = new Scanner(db, catalogue, {
      stabilityMs: 0,
      probeConcurrency: 2,
      ffprobePath: "ffprobe",
      now,
      volumeOf: () => Promise.resolve(1),
    });
    scanner.syncSources([
      { path: movies, name: "Films", hint: "movies" },
      { path: series, name: "Series", hint: "series" },
    ]);
    fixture = {
      root,
      drive,
      movies,
      series,
      lobby: join(drive, ".lobby"),
      db,
      scanner,
      catalogue,
      clock,
    };
    services = [];
  });

  afterEach(async () => {
    await Promise.all(services.map((service) => service.stop()));
    fixture.db.close();
    removeDir(fixture.root);
  });

  async function scan(): Promise<void> {
    await fixture.scanner.scanAll();
    await fixture.scanner.processQueue();
  }

  function service(options: Partial<ConversionOptions> = {}): ConversionService {
    const created = new ConversionService({
      db: fixture.db,
      catalogue: fixture.catalogue,
      dir: fixture.lobby,
      minFreeBytes: 0,
      quietMs: 0,
      now: () => fixture.clock.now,
      volumeOf: () => Promise.resolve(1),
      onReplaced: scan,
      ...options,
    });
    services.push(created);
    return created;
  }

  function items(): ApiItem[] {
    return new ItemReader(fixture.db).page(null, 1000).items;
  }

  function item(kind: string, title?: string): ApiItem {
    const found = items().find(
      (candidate) => candidate.kind === kind && (title === undefined || candidate.title === title),
    );
    if (!found) throw new Error(`no ${kind} ${title ?? ""}`);
    return found;
  }

  /** A film as the household has them: an old AVI with a subtitle file beside it. */
  async function film(
    name = "Brave (2012)",
  ): Promise<{ path: string; hash: string; item: ApiItem }> {
    const path = join(fixture.movies, name, `${name}.avi`);
    makeAvi(path, { seconds: 8 });
    writeFileSync(join(fixture.movies, name, `${name}.nl.srt`), srt(8));
    // An old date, as old files have: the stand-in for a file that has long stopped changing.
    utimesSync(path, new Date("2015-03-01T10:00:00Z"), new Date("2015-03-01T10:00:00Z"));
    await scan();
    return { path, hash: sha256(path), item: item("movie", name.replace(/ \(\d+\)$/, "")) };
  }

  async function untilSettled(
    conversion: ConversionService,
    jobId: string,
  ): Promise<ConversionJob> {
    for (let round = 0; round < 20; round += 1) {
      await conversion.tick();
      const job = (await conversion.status()).jobs.find((candidate) => candidate.id === jobId);
      if (job && !["queued", "converting", "verifying", "uploaded"].includes(job.state)) return job;
    }
    throw new Error("the job did not settle");
  }

  async function convert(conversion: ConversionService, itemId: string): Promise<ConversionJob> {
    const result = await conversion.enqueue({ kind: "item", itemId }, "manager");
    const job = result.jobs[0];
    if (!job) throw new Error("nothing was queued");
    if (job.state !== "queued") return job;
    return untilSettled(conversion, job.id);
  }

  it(
    "converts an AVI, proves it, and puts it in the original's place",
    { timeout: 240_000 },
    async () => {
      const original = await film();
      const before = original.item;
      const file = before.files[0];
      expect(file).toMatchObject({ container: "avi", playability: "transcode" });
      expect(file?.subtitles.map((subtitle) => subtitle.language)).toEqual(["nl"]);
      // A viewer is halfway through it.
      fixture.db.run(
        "insert into profile (id, name, color, created_at) values ('p1', 'Kid', 'red', 0)",
      );
      new ProgressStore(fixture.db, () => fixture.clock.now).put("p1", before.id, {
        opId: "op",
        baseRevision: null,
        positionMs: 4000,
        durationMs: 8000,
        completed: false,
        updatedAt: fixture.clock.now,
      });

      const conversion = service();
      await conversion.start();
      const job = await convert(conversion, before.id);
      expect(job).toMatchObject({ state: "done", kind: "h264", doneBy: "server", reason: null });
      const proof = job.proof as {
        ok: boolean;
        checks: { name: string; ok: boolean }[];
        ssim: { mean: number };
      };
      expect(proof.ok).toBe(true);
      expect(proof.checks.map((check) => check.name)).toEqual([
        "original_unchanged",
        "probe",
        "duration",
        "video",
        "audio",
        "subtitles",
        "chapters",
        "size",
        "decode",
        "picture",
        "drift",
      ]);
      expect(proof.checks.every((check) => check.ok)).toBe(true);
      expect(proof.ssim.mean).toBeGreaterThan(0.95);

      // The library folder: the same base name with a new extension, the subtitle untouched, nothing else.
      expect(tree(fixture.movies)).toEqual([
        "Brave (2012)/Brave (2012).mp4",
        "Brave (2012)/Brave (2012).nl.srt",
      ]);
      // The original was moved, not copied or deleted: the same bytes, the same date, in Lobby's folder.
      const kept = join(fixture.lobby, "originals/2026-11-24/Movies/Brave (2012)/Brave (2012).avi");
      expect(sha256(kept)).toBe(original.hash);
      expect(statSync(kept).mtime.toISOString()).toBe("2015-03-01T10:00:00.000Z");
      const manifest = JSON.parse(readFileSync(`${kept}.lobby.json`, "utf8")) as Record<
        string,
        unknown
      >;
      expect(manifest).toMatchObject({
        originalPath: original.path,
        replacedBy: join(fixture.movies, "Brave (2012)/Brave (2012).mp4"),
        kind: "h264",
        convertedBy: "server",
      });
      expect(tree(join(fixture.lobby, "staging"))).toEqual([]);
      expect(tree(join(fixture.lobby, "journal"))).toEqual([]);

      // The catalogue: the same title and the same file id, now a file that plays as it is.
      const after = item("movie", "Brave");
      expect(after.id).toBe(before.id);
      expect(items().filter((candidate) => candidate.kind === "movie")).toHaveLength(1);
      expect(after.files).toHaveLength(1);
      expect(after.files[0]).toMatchObject({
        assetId: file?.assetId,
        container: "mp4",
        playability: "direct",
        available: true,
      });
      expect(after.files[0]?.revision).not.toBe(file?.revision);
      expect(after.files[0]?.video?.codec).toBe("h264");
      expect(after.files[0]?.subtitles.map((subtitle) => subtitle.language)).toEqual(["nl"]);
      expect(
        new ProgressStore(fixture.db)
          .list("p1", 0)
          .map((progress) => [progress.itemId, progress.positionMs]),
      ).toEqual([[before.id, 4000]]);
      // It is an ordinary MP4 with its index at the front.
      const head = readFileSync(join(fixture.movies, "Brave (2012)/Brave (2012).mp4")).subarray(
        0,
        4096,
      );
      expect(head.includes("moov")).toBe(true);

      // Nothing in Lobby's folder is indexed.
      expect(fixture.db.all("select id from asset")).toHaveLength(1);

      // Asking again: there is nothing left to convert.
      const again = await conversion.enqueue({ kind: "item", itemId: before.id }, "manager");
      expect(again).toMatchObject({ queued: 0, skipped: 1 });
      expect(again.jobs[0]?.reason).toBe("This file plays as it is.");

      // ---- Undo: the original is back where it was, byte for byte. The converted file is set aside. ----
      const [replaced] = conversion.replacements();
      expect(replaced).toMatchObject({
        state: "replaced",
        assetId: file?.assetId,
        itemId: before.id,
      });
      const undone = await conversion.undo(replaced?.id ?? "");
      expect(undone.state).toBe("undone");
      expect(tree(fixture.movies)).toEqual([
        "Brave (2012)/Brave (2012).avi",
        "Brave (2012)/Brave (2012).nl.srt",
      ]);
      expect(sha256(original.path)).toBe(original.hash);
      expect(tree(fixture.lobby)).toEqual([
        "lobby-folder.json",
        "undone/2026-11-24/Movies/Brave (2012)/Brave (2012).mp4",
      ]);
      const restored = item("movie", "Brave");
      expect(restored.id).toBe(before.id);
      expect(restored.files[0]).toMatchObject({
        assetId: file?.assetId,
        container: "avi",
        revision: file?.revision,
      });
      await expect(conversion.undo(replaced?.id ?? "")).rejects.toMatchObject({ code: "conflict" });

      // Only an explicit purge deletes what Lobby kept.
      expect((await conversion.purge(replaced?.id ?? "")).state).toBe("purged");
      expect(tree(fixture.lobby)).toEqual(["lobby-folder.json"]);
      expect(tree(fixture.movies)).toHaveLength(2);
    },
  );

  it(
    "deletes a kept original only on an explicit purge, after which there is no undo",
    { timeout: 240_000 },
    async () => {
      const original = await film();
      const conversion = service();
      await conversion.start();
      expect((await convert(conversion, original.item.id)).state).toBe("done");
      const [replaced] = conversion.replacements();
      const kept = join(fixture.lobby, "originals/2026-11-24/Movies/Brave (2012)/Brave (2012).avi");

      // Time passes, the server restarts: the original is still there. Nothing purges by itself.
      fixture.clock.now += 400 * 24 * 60 * MINUTE;
      const later = service();
      await later.start();
      await later.tick();
      expect(existsSync(kept)).toBe(true);

      // The converted film is gone: what Lobby keeps is the last copy, and stays.
      const converted = join(fixture.movies, "Brave (2012)/Brave (2012).mp4");
      renameSync(converted, `${converted}.away`);
      await expect(later.purge(replaced?.id ?? "")).rejects.toMatchObject({ code: "conflict" });
      expect(existsSync(kept)).toBe(true);
      renameSync(`${converted}.away`, converted);

      expect((await later.purge(replaced?.id ?? "")).state).toBe("purged");
      expect(existsSync(kept)).toBe(false);
      expect(existsSync(`${kept}.lobby.json`)).toBe(false);
      expect(tree(fixture.movies)).toEqual([
        "Brave (2012)/Brave (2012).mp4",
        "Brave (2012)/Brave (2012).nl.srt",
      ]);
      await expect(later.undo(replaced?.id ?? "")).rejects.toMatchObject({ code: "conflict" });
      await expect(later.purge(replaced?.id ?? "")).rejects.toMatchObject({ code: "conflict" });
    },
  );

  for (const point of ["journal", "move:0", "move:1", "commit"] as const) {
    it(`survives being killed at "${point}" of a replacement`, { timeout: 240_000 }, async () => {
      const original = await film();
      let killed = false;
      const conversion = service({
        fault: (at) => {
          // From the kill on nothing works any more in this process, as after a real one.
          if (at === point || killed) {
            killed = true;
            throw new Error("killed");
          }
        },
      });
      await conversion.start();
      const queued = await conversion.enqueue(
        { kind: "item", itemId: original.item.id },
        "manager",
      );
      await conversion.tick();
      expect(killed).toBe(true);

      // What the kill left: the original's bytes exist exactly once, untouched.
      const places = [
        original.path,
        join(fixture.lobby, "originals/2026-11-24/Movies/Brave (2012)/Brave (2012).avi"),
      ].filter((path) => existsSync(path));
      expect(places).toHaveLength(1);
      expect(sha256(places[0] ?? "")).toBe(original.hash);

      // The server starts again.
      await conversion.stop();
      const restarted = service();
      await restarted.start();
      await scan();
      expect(tree(fixture.movies)).toEqual([
        "Brave (2012)/Brave (2012).mp4",
        "Brave (2012)/Brave (2012).nl.srt",
      ]);
      expect(
        sha256(join(fixture.lobby, "originals/2026-11-24/Movies/Brave (2012)/Brave (2012).avi")),
      ).toBe(original.hash);
      expect(tree(join(fixture.lobby, "journal"))).toEqual([]);
      const status = await restarted.status();
      expect(status.needsAttention).toEqual([]);
      expect(status.jobs.find((job) => job.id === queued.jobs[0]?.id)).toMatchObject({
        state: "done",
      });
      expect(restarted.replacements()).toHaveLength(1);
      const after = item("movie", "Brave");
      expect(after.id).toBe(original.item.id);
      expect(after.files).toHaveLength(1);
      expect(after.files[0]).toMatchObject({
        assetId: original.item.files[0]?.assetId,
        container: "mp4",
        playability: "direct",
      });
    });
  }

  it(
    "keeps the title's own file row when the scanner met the new file first",
    { timeout: 240_000 },
    async () => {
      const original = await film();
      let killed = false;
      const conversion = service({
        fault: (at) => {
          if (at === "move:1" || killed) {
            killed = true;
            throw new Error("killed");
          }
        },
      });
      await conversion.start();
      await conversion.enqueue({ kind: "item", itemId: original.item.id }, "manager");
      await conversion.tick();
      // Both files moved, the database knows nothing yet, and a scan runs before recovery.
      await conversion.stop();
      await scan();
      expect(fixture.db.all("select id from asset")).toHaveLength(2);

      const restarted = service();
      await restarted.start();
      await scan();
      expect(fixture.db.all("select id from asset")).toHaveLength(1);
      const after = item("movie", "Brave");
      expect(after.id).toBe(original.item.id);
      expect(after.files.map((file) => [file.assetId, file.container])).toEqual([
        [original.item.files[0]?.assetId, "mp4"],
      ]);
    },
  );

  it(
    "stops when the drive is pulled out mid-replacement, writes nothing where it was, and finishes when it is back",
    { timeout: 240_000 },
    async () => {
      const original = await film();
      const away = join(fixture.root, "drive-unplugged");
      let pulled = false;
      const conversion = service({
        fault: (at) => {
          if (at !== "move:0" || pulled) return;
          // The drive goes. What is left at its path is an empty mount point.
          pulled = true;
          renameSync(fixture.drive, away);
          mkdirSync(fixture.drive);
          throw Object.assign(new Error("EIO: i/o error"), { code: "EIO" });
        },
      });
      await conversion.start();
      const queued = await conversion.enqueue(
        { kind: "item", itemId: original.item.id },
        "manager",
      );
      await conversion.tick();
      expect(pulled).toBe(true);

      for (let round = 0; round < 3; round += 1) await conversion.tick();
      const without = await conversion.status();
      expect(without.driveConnected).toBe(false);
      expect(without.jobs[0]).toMatchObject({ state: "uploaded" });
      expect(without.jobs[0]?.reason).toContain("disconnected");
      // Nothing was created on the empty mount point: no folder of Lobby's, no staging, no journal.
      expect(readdirSync(fixture.drive)).toEqual([]);
      await expect(conversion.claim("mac", ["h264"])).rejects.toMatchObject({
        code: "unavailable",
      });
      await expect(conversion.undo("anything")).rejects.toMatchObject({ code: "unavailable" });

      // The drive is plugged in again.
      rmSync(fixture.drive, { recursive: true });
      renameSync(away, fixture.drive);
      await conversion.tick();
      await scan();
      expect(tree(fixture.movies)).toEqual([
        "Brave (2012)/Brave (2012).mp4",
        "Brave (2012)/Brave (2012).nl.srt",
      ]);
      expect(
        sha256(join(fixture.lobby, "originals/2026-11-24/Movies/Brave (2012)/Brave (2012).avi")),
      ).toBe(original.hash);
      expect(
        (await conversion.status()).jobs.find((job) => job.id === queued.jobs[0]?.id)?.state,
      ).toBe("done");
      expect(item("movie", "Brave").files[0]?.container).toBe("mp4");
    },
  );

  it("does not set its folder up on a volume the library is not known to be on", async () => {
    await film();
    const conversion = service({ volumeOf: () => Promise.resolve(2) });
    await conversion.start();
    expect((await conversion.status()).driveConnected).toBe(false);
    expect(existsSync(fixture.lobby)).toBe(false);
  });

  it("leaves a file alone when the drive is full, and says so", { timeout: 240_000 }, async () => {
    const original = await film();
    // No room: the file waits, nothing is written.
    const full = service({ minFreeBytes: 2 ** 50 });
    await full.start();
    const queued = await full.enqueue({ kind: "item", itemId: original.item.id }, "manager");
    expect(queued.jobs[0]).toMatchObject({ state: "queued" });
    await full.tick();
    const waiting = (await full.status()).jobs[0];
    expect(waiting).toMatchObject({
      state: "queued",
      reason: "There is not enough free space on the drive.",
    });
    expect(tree(join(fixture.lobby, "staging"))).toEqual([]);
    await full.cancel(waiting?.id ?? "");
    await full.stop();

    // The drive fills up while ffmpeg writes: the job fails, the half-written file goes, the original stays.
    const failing = join(fixture.root, "ffmpeg-full");
    writeFileSync(
      failing,
      '#!/bin/sh\nfor last; do :; done\nprintf partial > "$last"\necho "av_interleaved_write_frame(): No space left on device" >&2\nexit 1\n',
    );
    chmodSync(failing, 0o755);
    const conversion = service({ ffmpegPath: failing });
    await conversion.start();
    const job = await convert(conversion, original.item.id);
    expect(job).toMatchObject({
      state: "failed",
      reason: "The drive ran out of space while converting.",
    });
    expect(tree(join(fixture.lobby, "staging"))).toEqual([]);
    expect(sha256(original.path)).toBe(original.hash);
    expect(tree(fixture.movies)).toHaveLength(2);
    expect(conversion.replacements()).toEqual([]);
  });

  it(
    "refuses files that are hard to judge, each with its reason",
    { timeout: 240_000 },
    async () => {
      const conversion = service();
      // Plays as it is.
      makeVideo(join(fixture.movies, "Up (2009)/Up (2009).mp4"), { seconds: 2 });
      // A second name for the same file somewhere else on the drive.
      makeAvi(join(fixture.movies, "Linked (2001)/Linked (2001).avi"), { seconds: 2 });
      linkSync(
        join(fixture.movies, "Linked (2001)/Linked (2001).avi"),
        join(fixture.drive, "elsewhere.avi"),
      );
      // Still in a download program's hands.
      makeAvi(join(fixture.movies, "Downloads/Fresh (2002)/Fresh (2002).avi"), { seconds: 2 });
      makeAvi(join(fixture.movies, "Seeding (2003)/Seeding (2003).avi"), { seconds: 2 });
      writeFileSync(join(fixture.movies, "Seeding (2003)/Seeding (2003).avi.torrent"), "x");
      // An MP4 of the same name is already beside it.
      makeAvi(join(fixture.movies, "Twice (2004)/Twice (2004).avi"), { seconds: 2 });
      makeVideo(join(fixture.movies, "Twice (2004)/Twice (2004).mp4"), { seconds: 2, seed: 3 });
      // Two episodes in one file, and a film in two parts.
      makeAvi(join(fixture.series, "Show/Season 01/Show S01E01E02.avi"), { seconds: 2 });
      makeAvi(join(fixture.movies, "Long (2005)/Long (2005) part1.avi"), { seconds: 2 });
      makeAvi(join(fixture.movies, "Long (2005)/Long (2005) part2.avi"), { seconds: 3 });
      // Subtitles stored as pictures cannot go into MP4.
      makeAvi(join(fixture.movies, "Pictures (2006)/Pictures (2006).avi"), { seconds: 2 });
      // An MKV with a good picture: only repackaged when the household turned that on.
      execFileSync("ffmpeg", [
        "-v",
        "error",
        "-y",
        "-f",
        "lavfi",
        "-i",
        "testsrc2=size=160x90:rate=10:duration=2",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=440:duration=2",
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        join(fixture.movies, "Good (2007).mkv"),
      ]);
      await scan();
      const pictures = fixture.db.get<{ id: string }>(
        "select id from asset where rel_path like 'Pictures%'",
      );
      fixture.db.run(
        "insert into track (asset_id, idx, kind, codec, is_default, is_forced) values (?, 9, 'subtitle', 'dvd_subtitle', 0, 0)",
        [pictures?.id ?? ""],
      );

      const reasons = new Map<string, string | null>();
      for (const row of fixture.db.all<{ id: string; rel_path: string }>(
        "select id, rel_path from asset order by rel_path",
      )) {
        const itemId = fixture.db.get<{ item_id: string }>(
          "select item_id from item_asset where asset_id = ? limit 1",
          [row.id],
        )?.item_id;
        const result = await conversion.enqueue({ kind: "item", itemId: itemId ?? "" }, "manager");
        for (const job of result.jobs) {
          if (job.assetId === row.id)
            reasons.set(row.rel_path, job.state === "queued" ? null : job.reason);
        }
      }
      expect(Object.fromEntries(reasons)).toEqual({
        "Downloads/Fresh (2002)/Fresh (2002).avi":
          "It is in a download folder, where a download program may still use it.",
        "Good (2007).mkv": "Repackaging files that already have a good picture is turned off.",
        "Linked (2001)/Linked (2001).avi":
          "The file has a second name somewhere (a hard link), so something else may use it.",
        "Long (2005)/Long (2005) part1.avi": "It is one part of a film kept in several files.",
        "Long (2005)/Long (2005) part2.avi": "It is one part of a film kept in several files.",
        "Pictures (2006)/Pictures (2006).avi":
          "It has subtitles stored as pictures, which an MP4 file cannot keep.",
        "Seeding (2003)/Seeding (2003).avi": "A download program still has a file beside it.",
        "Show/Season 01/Show S01E01E02.avi": "It holds several episodes in one file.",
        "Twice (2004)/Twice (2004).avi":
          "There is already an MP4 file with the same name beside it.",
        "Twice (2004)/Twice (2004).mp4": "This file plays as it is.",
        "Up (2009)/Up (2009).mp4": "This file plays as it is.",
      });
      // Nothing was queued, so nothing was touched.
      expect((await conversion.status()).counts.queued).toBe(0);
      expect(existsSync(join(fixture.lobby, "staging"))).toBe(false);

      // "Everything old" lists what is old, not what plays as it is.
      const old = await conversion.enqueue({ kind: "old" }, "manager");
      expect(old.jobs.every((job) => job.state === "skipped")).toBe(true);
      expect(old.jobs.map((job) => job.reason)).not.toContain("This file plays as it is.");
      expect(old.jobs).toHaveLength(8);
      await expect(conversion.enqueue({ kind: "item", itemId: "nope" }, "m")).rejects.toMatchObject(
        {
          code: "not_found",
        },
      );
    },
  );

  it(
    "repackages an MKV without touching picture or sound, when that is turned on",
    { timeout: 240_000 },
    async () => {
      const path = join(fixture.movies, "Good (2007)/Good (2007).mkv");
      mkdirSync(dirname(path), { recursive: true });
      const subtitles = join(fixture.root, "embedded.srt");
      writeFileSync(subtitles, srt(8, "Embedded"));
      const chapters = join(fixture.root, "chapters.txt");
      writeFileSync(
        chapters,
        ";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=4000\ntitle=One\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=4000\nEND=8000\ntitle=Two\n",
      );
      execFileSync("ffmpeg", [
        "-v",
        "error",
        "-y",
        "-f",
        "lavfi",
        "-i",
        "testsrc2=size=160x90:rate=10:duration=8",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=440:duration=8",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=660:duration=8",
        "-i",
        subtitles,
        "-i",
        chapters,
        "-map",
        "0:v",
        "-map",
        "1:a",
        "-map",
        "2:a",
        "-map",
        "3:s",
        "-map_chapters",
        "4",
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        "-g",
        "10",
        "-c:a:0",
        "aac",
        "-c:a:1",
        "ac3",
        "-c:s",
        "srt",
        "-metadata:s:a:0",
        "language=eng",
        "-metadata:s:a:1",
        "language=dut",
        "-metadata:s:s:0",
        "language=dut",
        path,
      ]);
      await scan();
      const before = item("movie", "Good");
      const conversion = service({ repackage: true });
      await conversion.start();
      const job = await convert(conversion, before.id);
      expect(job).toMatchObject({ state: "done", kind: "repackage" });
      const proof = job.proof as {
        ssim: { worst: number };
        checks: { name: string; detail: string }[];
      };
      // The picture was copied, not encoded again.
      expect(proof.ssim.worst).toBeGreaterThan(0.999);
      expect(proof.checks.find((check) => check.name === "chapters")?.detail).toBe(
        "2 before, 2 after",
      );

      const after = item("movie", "Good").files[0];
      expect(after).toMatchObject({ container: "mp4", playability: "direct" });
      expect(after?.audio.map((audio) => [audio.codec, audio.language])).toEqual([
        ["aac", "eng"],
        ["ac3", "dut"],
      ]);
      expect(after?.subtitles.map((subtitle) => [subtitle.language, subtitle.isText])).toEqual([
        ["dut", true],
      ]);
    },
  );

  it(
    "converts only inside its hours, only while nobody watches, and not while paused",
    { timeout: 240_000 },
    async () => {
      const original = await film();
      let minute = 12 * 60;
      const conversion = service({
        hours: { from: 23 * 60, to: 6 * 60 },
        quietMs: 5 * MINUTE,
        minuteOfDay: () => minute,
      });
      await conversion.start();
      const queued = await conversion.enqueue(
        { kind: "item", itemId: original.item.id },
        "manager",
      );
      const state = async (): Promise<ConversionStatus> => {
        await conversion.tick();
        return conversion.status();
      };

      expect(await state()).toMatchObject({
        serverIdleBecause: "It is outside the hours set for converting.",
        counts: { queued: 1 },
      });
      minute = 23 * 60 + 30;
      conversion.noteActivity();
      expect((await state()).serverIdleBecause).toBe("Someone is watching or downloading.");
      fixture.clock.now += 5 * MINUTE;
      conversion.setPaused(true);
      expect(await state()).toMatchObject({
        paused: true,
        serverIdleBecause: "Converting is paused.",
      });
      expect(await conversion.claim("mac", ["h264"])).toBeNull();
      expect(tree(fixture.movies)).toContain("Brave (2012)/Brave (2012).avi");

      conversion.setPaused(false);
      minute = 2 * 60;
      expect((await untilSettled(conversion, queued.jobs[0]?.id ?? "")).state).toBe("done");
    },
  );

  it(
    "does not replace a title someone is watching, and does when they are done",
    { timeout: 240_000 },
    async () => {
      const original = await film();
      const assetId = original.item.files[0]?.assetId ?? "";
      // Watching does not stop the checks here (no quiet time), only the replacement.
      const conversion = service();
      await conversion.start();
      const queued = await conversion.enqueue(
        { kind: "item", itemId: original.item.id },
        "manager",
      );
      conversion.noteActivity(assetId);
      await conversion.tick();
      const waiting = (await conversion.status()).jobs[0];
      expect(waiting).toMatchObject({
        state: "uploaded",
        reason: "Waiting until nobody is watching this title.",
      });
      expect(tree(fixture.movies)).toContain("Brave (2012)/Brave (2012).avi");

      fixture.clock.now += 11 * MINUTE;
      expect((await untilSettled(conversion, queued.jobs[0]?.id ?? "")).state).toBe("done");
      expect(tree(fixture.movies)).toContain("Brave (2012)/Brave (2012).mp4");
    },
  );

  it(
    "refuses the result when the original changed while it was converted",
    { timeout: 240_000 },
    async () => {
      const original = await film();
      // A stand-in for ffmpeg that also touches the original while it works.
      const meddling = join(fixture.root, "ffmpeg-meddling");
      writeFileSync(
        meddling,
        `#!/bin/sh\nffmpeg "$@" || exit 1\ncase "$*" in *faststart*) printf x >> "${original.path}";; esac\n`,
      );
      chmodSync(meddling, 0o755);
      const conversion = service({ ffmpegPath: meddling });
      await conversion.start();
      const job = await convert(conversion, original.item.id);
      expect(job.state).not.toBe("done");
      expect(tree(fixture.movies)).toEqual([
        "Brave (2012)/Brave (2012).avi",
        "Brave (2012)/Brave (2012).nl.srt",
      ]);
      expect(conversion.replacements()).toEqual([]);
      expect(existsSync(join(fixture.lobby, "originals"))).toBe(false);
    },
  );

  describe("through the API, with a Mac taking jobs", () => {
    let conversion: ConversionService;

    interface Reply<T> {
      status: number;
      body: T;
      headers: Headers;
    }

    async function call<T = Record<string, unknown>>(
      method: string,
      path: string,
      options: {
        token?: string;
        body?: unknown;
        headers?: Record<string, string>;
        bytes?: Uint8Array;
      } = {},
    ): Promise<Reply<T>> {
      const headers: Record<string, string> = { ...options.headers };
      if (options.token) headers["Authorization"] = `Bearer ${options.token}`;
      let body: string | Uint8Array | undefined;
      if (options.bytes) {
        body = options.bytes;
        headers["Content-Length"] = String(options.bytes.length);
      } else if (options.body !== undefined) {
        body = JSON.stringify(options.body);
        headers["Content-Type"] = "application/json";
      }
      const response = await app.request(path, {
        method,
        headers,
        ...(body === undefined ? {} : { body }),
      });
      const text = await response.text();
      return {
        status: response.status,
        body: (text === "" ? null : JSON.parse(text)) as T,
        headers: response.headers,
      };
    }

    async function pair(role: "viewer" | "manager"): Promise<{ token: string; id: string }> {
      const request = await call<{ id: string; code: string; pollSecret: string }>(
        "POST",
        "/v1/pairing/requests",
        { body: { deviceName: role === "manager" ? "A Mac" : "Kids iPad", platform: "macos" } },
      );
      await call("POST", "/v1/pairing/approve", {
        token: managerToken,
        body: { code: request.body.code, role },
      });
      const collected = await call<{ token: string; device: { id: string } }>(
        "POST",
        `/v1/pairing/requests/${request.body.id}/collect`,
        { body: { pollSecret: request.body.pollSecret } },
      );
      return { token: collected.body.token, id: collected.body.device.id };
    }

    interface Claimed {
      job: ConversionJob;
      original: { assetId: string; url: string; bytes: number };
      target: ConversionTarget;
      uploadUrl: string;
    }

    beforeEach(async () => {
      // The server does not convert by itself here: the Mac does.
      conversion = service({ serverConverts: false, leaseMs: 5 * MINUTE });
      await conversion.start();
      app = createApp({
        db: fixture.db,
        devices: new Devices(fixture.db, SETUP_SECRET, () => fixture.clock.now),
        items: new ItemReader(fixture.db),
        progress: new ProgressStore(fixture.db, () => fixture.clock.now),
        conversion,
        serverName: "Test Lobby",
        version: "0.0.0-test",
        isScanning: () => false,
        now: () => fixture.clock.now,
      });
      const claimed = await call<{ token: string }>("POST", "/v1/pairing/claim", {
        body: { setupSecret: SETUP_SECRET, deviceName: "Manager", platform: "macos" },
      });
      managerToken = claimed.body.token;
    });

    /** Fetches the original like a Mac would and converts it with the server's own reference command. */
    async function convertLikeAMac(
      mac: { token: string },
      claimed: Claimed,
      work: string,
    ): Promise<Buffer> {
      const fetched = await app.request(claimed.original.url, {
        headers: { Authorization: `Bearer ${mac.token}`, "X-Lobby-Purpose": "convert" },
      });
      expect(fetched.status).toBe(200);
      mkdirSync(work, { recursive: true });
      const source = join(work, "original.bin");
      writeFileSync(source, Buffer.from(await fetched.arrayBuffer()));
      expect(statSync(source).size).toBe(claimed.original.bytes);
      const result = join(work, "result.mp4");
      execFileSync("ffmpeg", conversionArguments(source, claimed.target, result), {
        stdio: "ignore",
      });
      return readFileSync(result);
    }

    async function send(
      mac: { token: string },
      claimed: Claimed,
      bytes: Buffer,
    ): Promise<Reply<{ job: ConversionJob }>> {
      const half = Math.floor(bytes.length / 2);
      const first = await call("PATCH", claimed.uploadUrl, {
        token: mac.token,
        headers: { "Upload-Offset": "0" },
        bytes: bytes.subarray(0, half),
      });
      expect(first.status).toBe(204);
      expect(first.headers.get("Upload-Offset")).toBe(String(half));
      const rest = await call("PATCH", claimed.uploadUrl, {
        token: mac.token,
        headers: { "Upload-Offset": String(half) },
        bytes: bytes.subarray(half),
      });
      expect(rest.headers.get("Upload-Offset")).toBe(String(bytes.length));
      return call<{ job: ConversionJob }>(
        "POST",
        `/v1/conversion/jobs/${claimed.job.id}/complete`,
        {
          token: mac.token,
          body: {
            sizeBytes: bytes.length,
            sha256: createHash("sha256").update(bytes).digest("hex"),
          },
        },
      );
    }

    it("is for managers only", async () => {
      const original = await film();
      const viewer = await pair("viewer");
      const queued = await call<{ jobs: ConversionJob[] }>("POST", "/v1/conversion/jobs", {
        token: managerToken,
        body: { scope: "item", itemId: original.item.id },
      });
      expect(queued.status).toBe(201);
      const jobId = queued.body.jobs[0]?.id ?? "";
      const routes: [string, string, unknown?][] = [
        ["GET", "/v1/conversion"],
        ["POST", "/v1/conversion/jobs", { scope: "old" }],
        ["POST", "/v1/conversion/pause", {}],
        ["POST", "/v1/conversion/resume", {}],
        ["DELETE", `/v1/conversion/jobs/${jobId}`],
        ["POST", `/v1/conversion/jobs/${jobId}/move`, { to: "top" }],
        ["POST", "/v1/conversion/claim", {}],
        ["POST", `/v1/conversion/jobs/${jobId}/heartbeat`, { progress: 0.5 }],
        ["HEAD", `/v1/conversion/jobs/${jobId}/upload`],
        ["PATCH", `/v1/conversion/jobs/${jobId}/upload`, {}],
        ["POST", `/v1/conversion/jobs/${jobId}/complete`, { sizeBytes: 1 }],
        ["POST", `/v1/conversion/jobs/${jobId}/release`, {}],
        ["GET", "/v1/conversion/replacements"],
        ["POST", "/v1/conversion/replacements/x/undo", {}],
        ["POST", "/v1/conversion/replacements/x/purge", { confirm: "delete for good" }],
      ];
      for (const [method, path, body] of routes) {
        expect(
          (await call(method, path, { token: viewer.token, body })).status,
          `${method} ${path}`,
        ).toBe(403);
        expect((await call(method, path, { body })).status, `${method} ${path}`).toBe(401);
      }
      const status = await call<ConversionStatus>("GET", "/v1/conversion", { token: managerToken });
      expect(status.body.jobs).toHaveLength(1);
      expect(status.body.jobs[0]).toMatchObject({ state: "queued", claimedBy: null });
      expect(status.body.paused).toBe(false);
    });

    it(
      "lets a Mac take a job, send the result in pieces, and replaces the original once it is proven",
      { timeout: 240_000 },
      async () => {
        const original = await film();
        const mac = await pair("manager");
        const other = await pair("manager");
        await call("POST", "/v1/conversion/jobs", {
          token: managerToken,
          body: { scope: "item", itemId: original.item.id },
        });

        // Nothing for a Mac that only does AV1.
        expect(
          (
            await call("POST", "/v1/conversion/claim", {
              token: mac.token,
              body: { kinds: ["hevc"] },
            })
          ).status,
        ).toBe(204);
        const claim = await call<Claimed>("POST", "/v1/conversion/claim", {
          token: mac.token,
          body: {},
        });
        expect(claim.status).toBe(200);
        const claimed = claim.body;
        expect(claimed.job).toMatchObject({ state: "claimed", claimedBy: mac.id, kind: "h264" });
        expect(claimed.target).toMatchObject({
          container: "mp4",
          faststart: true,
          video: { action: "h264" },
          audio: [{ action: "aac" }],
          reference: { encoder: "libx264", preset: "veryfast", crf: 21 },
        });
        // It is this Mac's now: nobody else gets it or can speak for it.
        expect(
          (await call("POST", "/v1/conversion/claim", { token: other.token, body: {} })).status,
        ).toBe(204);
        for (const [method, path, body] of [
          ["POST", `/v1/conversion/jobs/${claimed.job.id}/heartbeat`, { progress: 0.2 }],
          ["HEAD", claimed.uploadUrl, undefined],
          ["POST", `/v1/conversion/jobs/${claimed.job.id}/complete`, { sizeBytes: 5 }],
          ["POST", `/v1/conversion/jobs/${claimed.job.id}/release`, {}],
        ] as const) {
          expect((await call(method, path, { token: other.token, body })).status, path).toBe(410);
        }
        const beat = await call<{ job: ConversionJob }>(
          "POST",
          `/v1/conversion/jobs/${claimed.job.id}/heartbeat`,
          { token: mac.token, body: { progress: 0.4 } },
        );
        expect(beat.body.job.progress).toBe(0.4);

        const bytes = await convertLikeAMac(mac, claimed, join(fixture.root, "mac"));
        // A piece that does not start where the last one ended is refused, with the right place.
        const wrong = await call<{ offset: number }>("PATCH", claimed.uploadUrl, {
          token: mac.token,
          headers: { "Upload-Offset": "10" },
          bytes: bytes.subarray(10, 20),
        });
        expect(wrong.status).toBe(409);
        expect(wrong.body.offset).toBe(0);
        const early = await call("POST", `/v1/conversion/jobs/${claimed.job.id}/complete`, {
          token: mac.token,
          body: { sizeBytes: bytes.length },
        });
        expect(early.status).toBe(409);

        const done = await send(mac, claimed, bytes);
        expect(done.status).toBe(202);
        expect(done.body.job.state).toBe("uploaded");
        // Fetching the original to convert it did not count as someone watching it.
        const settled = await untilSettled(conversion, claimed.job.id);
        expect(settled).toMatchObject({ state: "done", doneBy: mac.id });
        expect(tree(fixture.movies)).toEqual([
          "Brave (2012)/Brave (2012).mp4",
          "Brave (2012)/Brave (2012).nl.srt",
        ]);
        expect(sha256(join(fixture.movies, "Brave (2012)/Brave (2012).mp4"))).toBe(
          createHash("sha256").update(bytes).digest("hex"),
        );
        expect(
          sha256(join(fixture.lobby, "originals/2026-11-24/Movies/Brave (2012)/Brave (2012).avi")),
        ).toBe(original.hash);

        // Undo and purge through the API; purge only with the words.
        const list = await call<{ replacements: Replacement[] }>(
          "GET",
          "/v1/conversion/replacements",
          {
            token: managerToken,
          },
        );
        const replacementId = list.body.replacements[0]?.id ?? "";
        for (const body of [{}, { confirm: true }, { confirm: "yes" }]) {
          const refused = await call("POST", `/v1/conversion/replacements/${replacementId}/purge`, {
            token: managerToken,
            body,
          });
          expect(refused.status).toBe(400);
        }
        expect(
          existsSync(
            join(fixture.lobby, "originals/2026-11-24/Movies/Brave (2012)/Brave (2012).avi"),
          ),
        ).toBe(true);
        const undone = await call<{ replacement: Replacement }>(
          "POST",
          `/v1/conversion/replacements/${replacementId}/undo`,
          { token: managerToken, body: {} },
        );
        expect(undone.status).toBe(200);
        expect(undone.body.replacement.state).toBe("undone");
        expect(sha256(original.path)).toBe(original.hash);
      },
    );

    it(
      "refuses a wrong result and leaves the original where it is",
      { timeout: 300_000 },
      async () => {
        const original = await film();
        const mac = await pair("manager");
        const work = join(fixture.root, "mac");
        mkdirSync(work, { recursive: true });
        const make = (name: string, args: string[]): Buffer => {
          execFileSync("ffmpeg", [
            "-v",
            "error",
            "-y",
            ...args,
            "-movflags",
            "+faststart",
            join(work, name),
          ]);
          return readFileSync(join(work, name));
        };
        const picture = ["-f", "lavfi", "-i", "testsrc2=size=160x90:rate=10:duration=8"];
        const sound = ["-f", "lavfi", "-i", "sine=frequency=440:duration=8"];
        const h264 = ["-c:v", "libx264", "-pix_fmt", "yuv420p"];

        const wrongs: [string, Buffer, string][] = [
          [
            "not a video at all",
            Buffer.from("this is not an MP4 file ".repeat(400)),
            "The converted file cannot be read as a video Apple devices play.",
          ],
          [
            "another film",
            make("other.mp4", [
              "-f",
              "lavfi",
              "-i",
              "mandelbrot=size=160x90:rate=10",
              ...sound,
              ...h264,
              "-c:a",
              "aac",
              "-t",
              "8",
            ]),
            "The converted file's picture differs too much from the original.",
          ],
          [
            "cut short",
            make("short.mp4", [
              "-f",
              "lavfi",
              "-i",
              "testsrc2=size=160x90:rate=10:duration=5",
              "-f",
              "lavfi",
              "-i",
              "sine=frequency=440:duration=5",
              ...h264,
              "-c:a",
              "aac",
            ]),
            "The converted file is not as long as the original.",
          ],
          [
            "without its sound",
            make("silent.mp4", [...picture, ...h264]),
            "The converted file does not have the original's sound tracks.",
          ],
          [
            "the wrong codec",
            make("mpeg4.mp4", [...picture, ...sound, "-c:v", "mpeg4", "-c:a", "aac"]),
            "The converted file cannot be read as a video Apple devices play.",
          ],
          [
            "sound that ends early",
            make("drift.mp4", ["-i", original.path, ...h264, "-af", "atrim=end=6", "-c:a", "aac"]),
            "Sound and picture drift apart in the converted file.",
          ],
        ];
        for (const [what, bytes, reason] of wrongs) {
          await call("POST", "/v1/conversion/jobs", {
            token: managerToken,
            body: { scope: "item", itemId: original.item.id },
          });
          const claim = await call<Claimed>("POST", "/v1/conversion/claim", {
            token: mac.token,
            body: {},
          });
          expect(claim.status, what).toBe(200);
          expect((await send(mac, claim.body, bytes)).status, what).toBe(202);
          const settled = await untilSettled(conversion, claim.body.job.id);
          expect([what, settled.state, settled.reason]).toEqual([what, "failed", reason]);
          // Nothing moved; what was sent is gone.
          expect(tree(fixture.movies), what).toEqual([
            "Brave (2012)/Brave (2012).avi",
            "Brave (2012)/Brave (2012).nl.srt",
          ]);
          expect(sha256(original.path)).toBe(original.hash);
          expect(tree(join(fixture.lobby, "staging")), what).toEqual([]);
          expect(existsSync(join(fixture.lobby, "originals"))).toBe(false);
        }
        expect(conversion.replacements()).toEqual([]);

        // Damaged on the way: refused before anything is checked, and the upload starts over.
        await call("POST", "/v1/conversion/jobs", {
          token: managerToken,
          body: { scope: "item", itemId: original.item.id },
        });
        const claim = await call<Claimed>("POST", "/v1/conversion/claim", {
          token: mac.token,
          body: {},
        });
        const bytes = Buffer.from("x".repeat(5000));
        await call("PATCH", claim.body.uploadUrl, {
          token: mac.token,
          headers: { "Upload-Offset": "0" },
          bytes,
        });
        const damaged = await call<{ offset: number }>(
          "POST",
          `/v1/conversion/jobs/${claim.body.job.id}/complete`,
          { token: mac.token, body: { sizeBytes: 5000, sha256: "0".repeat(64) } },
        );
        expect(damaged.status).toBe(409);
        expect(damaged.body.offset).toBe(0);
        const head = await call("HEAD", claim.body.uploadUrl, { token: mac.token });
        expect(head.headers.get("Upload-Offset")).toBe("0");

        // Far too large: stopped while it arrives.
        const flood = await call("PATCH", claim.body.uploadUrl, {
          token: mac.token,
          headers: { "Upload-Offset": "0" },
          bytes: Buffer.alloc(claim.body.original.bytes * 3 + 17 * 1024 * 1024),
        });
        expect(flood.status).toBe(400);
      },
    );

    it(
      "takes a job back from a Mac that goes silent, and from one that gives it back",
      { timeout: 120_000 },
      async () => {
        const original = await film();
        const mac = await pair("manager");
        const other = await pair("manager");
        await call("POST", "/v1/conversion/jobs", {
          token: managerToken,
          body: { scope: "item", itemId: original.item.id },
        });
        const claim = await call<Claimed>("POST", "/v1/conversion/claim", {
          token: mac.token,
          body: {},
        });
        await call("PATCH", claim.body.uploadUrl, {
          token: mac.token,
          headers: { "Upload-Offset": "0" },
          bytes: Buffer.from("half a film"),
        });
        // A heartbeat keeps it.
        fixture.clock.now += 4 * MINUTE;
        await call("POST", `/v1/conversion/jobs/${claim.body.job.id}/heartbeat`, {
          token: mac.token,
          body: { progress: 0.5 },
        });
        fixture.clock.now += 4 * MINUTE;
        expect(
          (await call("POST", "/v1/conversion/claim", { token: other.token, body: {} })).status,
        ).toBe(204);

        // Silence does not.
        fixture.clock.now += 2 * MINUTE;
        const taken = await call<Claimed>("POST", "/v1/conversion/claim", {
          token: other.token,
          body: {},
        });
        expect(taken.status).toBe(200);
        expect(taken.body.job).toMatchObject({ id: claim.body.job.id, claimedBy: other.id });
        // The first Mac's half upload is gone, and it is told so.
        expect(
          (await call("HEAD", taken.body.uploadUrl, { token: other.token })).headers.get(
            "Upload-Offset",
          ),
        ).toBe("0");
        const late = await call("PATCH", claim.body.uploadUrl, {
          token: mac.token,
          headers: { "Upload-Offset": "11" },
          bytes: Buffer.from("more"),
        });
        expect(late.status).toBe(410);

        const released = await call<{ job: ConversionJob }>(
          "POST",
          `/v1/conversion/jobs/${taken.body.job.id}/release`,
          { token: other.token, body: {} },
        );
        expect(released.body.job).toMatchObject({ state: "queued", claimedBy: null });

        // A manager can change the order, and cancel.
        const moved = await call<{ job: ConversionJob }>(
          "POST",
          `/v1/conversion/jobs/${taken.body.job.id}/move`,
          { token: managerToken, body: { to: "top" } },
        );
        expect(moved.status).toBe(200);
        const cancelled = await call<{ job: ConversionJob }>(
          "DELETE",
          `/v1/conversion/jobs/${taken.body.job.id}`,
          { token: managerToken },
        );
        expect(cancelled.body.job.state).toBe("cancelled");
        expect(tree(fixture.movies)).toHaveLength(2);
        expect(sha256(original.path)).toBe(original.hash);
      },
    );

    it("answers plainly when converting is not set up", async () => {
      const off = new ConversionService({
        db: fixture.db,
        catalogue: fixture.catalogue,
        dir: null,
      });
      await off.start();
      const offApp = createApp({
        db: fixture.db,
        devices: new Devices(fixture.db, SETUP_SECRET, () => fixture.clock.now),
        items: new ItemReader(fixture.db),
        progress: new ProgressStore(fixture.db),
        conversion: off,
        serverName: "Test Lobby",
        version: "0.0.0-test",
        isScanning: () => false,
      });
      const headers = {
        Authorization: `Bearer ${managerToken}`,
        "Content-Type": "application/json",
      };
      const status = await offApp.request("/v1/conversion", { headers });
      expect(await status.json()).toMatchObject({ enabled: false, jobs: [] });
      const queued = await offApp.request("/v1/conversion/jobs", {
        method: "POST",
        headers,
        body: JSON.stringify({ scope: "old" }),
      });
      expect(queued.status).toBe(503);
      await off.tick();
    });
  });
});
