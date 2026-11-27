// SPDX-License-Identifier: MPL-2.0
import { mkdirSync, renameSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { Database } from "../src/db/database.ts";
import { Catalogue } from "../src/library/catalogue.ts";
import { Scanner } from "../src/library/scanner.ts";
import { makeTempDir, makeVideo, removeDir } from "./support/media.ts";

interface Fixture {
  dir: string;
  movies: string;
  series: string;
  db: Database;
  scanner: Scanner;
  clock: { now: number };
  /** Folders whose drive is "unplugged": they report another volume. */
  unplugged: Set<string>;
}

function setUp(stabilityMs = 0): Fixture {
  const dir = makeTempDir();
  const movies = join(dir, "Movies");
  const series = join(dir, "Series");
  mkdirSync(movies);
  mkdirSync(series);
  const clock = { now: 1_800_000_000_000 };
  const unplugged = new Set<string>();
  const db = new Database(join(dir, "lobby.db"));
  const catalogue = new Catalogue(db, () => clock.now);
  const scanner = new Scanner(db, catalogue, {
    stabilityMs,
    probeConcurrency: 2,
    ffprobePath: "ffprobe",
    now: () => clock.now,
    volumeOf: (path) => Promise.resolve(unplugged.has(path) ? 2 : 1),
  });
  scanner.syncSources([
    { path: movies, name: "Movies", hint: "movies" },
    { path: series, name: "Series", hint: "series" },
  ]);
  return { dir, movies, series, db, scanner, clock, unplugged };
}

async function scan(fixture: Fixture): Promise<void> {
  await fixture.scanner.scanAll();
  await fixture.scanner.processQueue();
}

function items(db: Database, kind: string): { id: string; title: string; year: number | null }[] {
  return db.all(
    "select id, title, year from item where kind = ? order by season_number, episode_number, sort_title",
    [kind],
  );
}

describe("scanner", () => {
  let fixture: Fixture;
  beforeEach(() => {
    fixture = setUp();
  });
  afterEach(() => {
    fixture.db.close();
    removeDir(fixture.dir);
  });

  it("turns files into films, shows, seasons and episodes", async () => {
    makeVideo(join(fixture.movies, "Up (2009)/Up (2009).mp4"));
    makeVideo(join(fixture.series, "Bluey/Season 02/Bluey - S02E04 - Trains.mkv"), { seed: 1 });
    makeVideo(join(fixture.series, "Bluey/Season 02/Bluey - S02E05 - Flat Pack.mkv"), { seed: 2 });
    await scan(fixture);

    expect(items(fixture.db, "movie")).toMatchObject([{ title: "Up", year: 2009 }]);
    expect(items(fixture.db, "show")).toMatchObject([{ title: "Bluey" }]);
    expect(items(fixture.db, "season")).toMatchObject([{ title: "Season 2" }]);
    expect(items(fixture.db, "episode").map((item) => item.title)).toEqual(["Trains", "Flat Pack"]);

    const assets = fixture.db.all<{ container: string; playability: string; state: string }>(
      "select container, playability, state from asset order by rel_path",
    );
    expect(assets).toEqual([
      { container: "mkv", playability: "remux", state: "probed" },
      { container: "mkv", playability: "remux", state: "probed" },
      { container: "mp4", playability: "direct", state: "probed" },
    ]);
    const tracks = fixture.db.all<{ kind: string; codec: string }>(
      "select kind, codec from track join asset on asset.id = track.asset_id where rel_path like 'Up%' order by idx",
    );
    expect(tracks).toEqual([
      { kind: "video", codec: "h264" },
      { kind: "audio", codec: "aac" },
    ]);
  });

  it("adds nothing when the same folder is scanned again", async () => {
    makeVideo(join(fixture.movies, "Up (2009)/Up (2009).mp4"));
    await scan(fixture);
    const revision = fixture.db.currentRevision();
    const summary = await fixture.scanner.scanAll();
    expect(summary).toMatchObject({ added: 0, changed: 0, missing: 0, restored: 0 });
    expect(await fixture.scanner.processQueue()).toBe(0);
    expect(fixture.db.currentRevision()).toBe(revision);
    expect(items(fixture.db, "movie")).toHaveLength(1);
  });

  it("ignores hidden files, resource forks, partial transfers and empty files", async () => {
    makeVideo(join(fixture.movies, "Up (2009)/Up (2009).mp4"));
    writeFileSync(join(fixture.movies, "Up (2009)/._Up (2009).mp4"), "resource fork");
    writeFileSync(join(fixture.movies, "Coco (2017).mkv.part"), "half a film");
    writeFileSync(join(fixture.movies, "Empty (2020).mp4"), "");
    writeFileSync(join(fixture.movies, ".DS_Store"), "x");
    await scan(fixture);
    expect(fixture.db.all("select id from asset")).toHaveLength(1);
  });

  it("does not follow a link out of the library folder", async () => {
    const outside = join(fixture.dir, "Private");
    makeVideo(join(outside, "Secret (2001).mp4"));
    symlinkSync(outside, join(fixture.movies, "Linked"));
    symlinkSync(join(outside, "Secret (2001).mp4"), join(fixture.movies, "Secret (2001).mp4"));
    await scan(fixture);
    expect(fixture.db.all("select id from asset")).toHaveLength(0);
  });

  it("keeps a file that cannot be read and retries it later", async () => {
    writeFileSync(join(fixture.movies, "Broken (2001).mp4"), "this is not a video");
    await scan(fixture);
    const failed = fixture.db.get<{ state: string; attempts: number; next_attempt_at: number }>(
      "select state, attempts, next_attempt_at from asset",
    );
    expect(failed).toMatchObject({ state: "failed", attempts: 1 });
    expect(items(fixture.db, "movie")).toHaveLength(0);

    // Not retried before its time.
    expect(await fixture.scanner.processQueue()).toBe(0);
    // The copy finishes; the file is now a real video.
    makeVideo(join(fixture.movies, "Broken (2001).mp4"));
    fixture.clock.now += 61_000;
    await scan(fixture);
    expect(items(fixture.db, "movie")).toMatchObject([{ title: "Broken", year: 2001 }]);
  });

  it("links one file that holds two episodes to both", async () => {
    makeVideo(join(fixture.series, "Example/Example S01E01E02.mkv"));
    await scan(fixture);
    const episodes = fixture.db.all<{ episode_number: number; assets: number }>(
      `select episode_number, (select count(*) from item_asset where item_id = item.id) as assets
       from item where kind = 'episode' order by episode_number`,
    );
    expect(episodes).toEqual([
      { episode_number: 1, assets: 1 },
      { episode_number: 2, assets: 1 },
    ]);
    expect(fixture.db.all("select id from asset")).toHaveLength(1);
  });

  it("files a trailer and a subtitle with their film", async () => {
    makeVideo(join(fixture.movies, "Up (2009)/Up (2009).mp4"));
    makeVideo(join(fixture.movies, "Up (2009)/Extras/trailer.mp4"), { seed: 3 });
    writeFileSync(
      join(fixture.movies, "Up (2009)/Up (2009).nl.srt"),
      "1\n00:00:00,000 --> 00:00:01,000\nHoi\n",
    );
    await scan(fixture);
    const movie = items(fixture.db, "movie")[0];
    const extra = fixture.db.get<{ parent_id: string; role: string }>(
      "select parent_id, role from item join item_asset on item_asset.item_id = item.id where kind = 'extra'",
    );
    expect(extra).toEqual({ parent_id: movie?.id, role: "trailer" });
    const sidecar = fixture.db.get<{ language: string; format: string; rel_path: string }>(
      "select sidecar.language, format, asset.rel_path from sidecar join asset on asset.id = sidecar.asset_id",
    );
    expect(sidecar).toEqual({ language: "nl", format: "srt", rel_path: "Up (2009)/Up (2009).mp4" });
  });

  it("reads a subtitle file's language and whether it is forced from its name", async () => {
    makeVideo(join(fixture.movies, "Up (2009)/Up (2009).mkv"));
    const line = "1\n00:00:00,000 --> 00:00:01,000\nHoi\n";
    for (const name of [
      "Up (2009).en.srt",
      "Up (2009).eng.forced.srt",
      "Up (2009).Dutch.vtt",
      "Up (2009).fre.ass",
      "Up (2009).forced.srt",
      "Up (2009).srt",
    ]) {
      writeFileSync(join(fixture.movies, "Up (2009)", name), line);
    }
    await scan(fixture);
    const sidecars = fixture.db.all<{
      rel_path: string;
      language: string | null;
      is_forced: number;
      format: string;
    }>("select rel_path, language, is_forced, format from sidecar order by rel_path");
    expect(sidecars).toEqual([
      { rel_path: "Up (2009)/Up (2009).Dutch.vtt", language: "nl", is_forced: 0, format: "vtt" },
      { rel_path: "Up (2009)/Up (2009).en.srt", language: "en", is_forced: 0, format: "srt" },
      {
        rel_path: "Up (2009)/Up (2009).eng.forced.srt",
        language: "en",
        is_forced: 1,
        format: "srt",
      },
      { rel_path: "Up (2009)/Up (2009).forced.srt", language: null, is_forced: 1, format: "srt" },
      { rel_path: "Up (2009)/Up (2009).fre.ass", language: "fr", is_forced: 0, format: "ass" },
      { rel_path: "Up (2009)/Up (2009).srt", language: null, is_forced: 0, format: "srt" },
    ]);

    // A row an older Lobby wrote, before it knew the word, is put right by the next scan.
    fixture.db.run("update sidecar set is_forced = 0, language = null");
    await scan(fixture);
    const forced = fixture.db.all<{ rel_path: string }>(
      "select rel_path from sidecar where is_forced = 1 order by rel_path",
    );
    expect(forced.map((row) => row.rel_path)).toEqual([
      "Up (2009)/Up (2009).eng.forced.srt",
      "Up (2009)/Up (2009).forced.srt",
    ]);
    expect(
      fixture.db.get<{ n: number }>("select count(*) as n from sidecar where language = 'en'")?.n,
    ).toBe(2);
  });
});

describe("scanner over time", () => {
  let fixture: Fixture;
  afterEach(() => {
    fixture.db.close();
    removeDir(fixture.dir);
  });

  it("waits for a new file to stop changing", async () => {
    fixture = setUp(30_000);
    makeVideo(join(fixture.movies, "Up (2009)/Up (2009).mp4"));
    expect(await fixture.scanner.scanAll()).toMatchObject({ added: 0, settling: 1 });

    fixture.clock.now += 10_000;
    expect(await fixture.scanner.scanAll()).toMatchObject({ added: 0, settling: 1 });

    // The copy is still running: the file grows, so the wait starts again.
    makeVideo(join(fixture.movies, "Up (2009)/Up (2009).mp4"), { seconds: 2 });
    fixture.clock.now += 25_000;
    expect(await fixture.scanner.scanAll()).toMatchObject({ added: 0, settling: 1 });

    fixture.clock.now += 31_000;
    expect(await fixture.scanner.scanAll()).toMatchObject({ added: 1, settling: 0 });
  });

  it("keeps a renamed file's identity and the family's place in it", async () => {
    fixture = setUp();
    makeVideo(join(fixture.movies, "Up (2009)/Up (2009).mp4"));
    await scan(fixture);
    const before = fixture.db.get<{ id: string; revision: string }>(
      "select id, revision from asset",
    );
    const item = items(fixture.db, "movie")[0];
    fixture.db.run(
      "insert into profile (id, name, color, created_at) values ('p1', 'Alex', 'blue', 0)",
    );
    fixture.db.run(
      "insert into progress (profile_id, item_id, position_ms, completed, revision, updated_at) values ('p1', ?, 4000, 0, 1, 0)",
      [item?.id ?? ""],
    );

    // Same film, tidier name: the item stays.
    renameSync(join(fixture.movies, "Up (2009)"), join(fixture.movies, "Up! (2009)"));
    await scan(fixture);
    const after = fixture.db.all<{
      id: string;
      revision: string;
      rel_path: string;
      available: number;
    }>("select id, revision, rel_path, available from asset");
    expect(after).toEqual([
      {
        id: before?.id,
        revision: before?.revision,
        rel_path: "Up! (2009)/Up (2009).mp4",
        available: 1,
      },
    ]);
    expect(items(fixture.db, "movie").map((movie) => movie.id)).toEqual([item?.id]);

    // A rename that changes the title makes a new item, and the progress follows the file.
    renameSync(join(fixture.movies, "Up! (2009)"), join(fixture.movies, "Upwards (2009)"));
    await scan(fixture);
    const renamed = items(fixture.db, "movie");
    expect(renamed).toMatchObject([{ title: "Upwards" }]);
    expect(renamed[0]?.id).not.toBe(item?.id);
    expect(fixture.db.all("select item_id from progress")).toEqual([{ item_id: renamed[0]?.id }]);
    expect(fixture.db.all("select item_id from tombstone")).toEqual([{ item_id: item?.id }]);
    expect(fixture.db.get<{ id: string }>("select id from asset")?.id).toBe(before?.id);
  });

  it("re-reads a file whose contents changed", async () => {
    fixture = setUp();
    const path = join(fixture.movies, "Up (2009)/Up (2009).mp4");
    makeVideo(path);
    await scan(fixture);
    const before = fixture.db.get<{ id: string; revision: string; duration_ms: number }>(
      "select id, revision, duration_ms from asset",
    );
    makeVideo(path, { seconds: 3 });
    const summary = await fixture.scanner.scanAll();
    await fixture.scanner.processQueue();
    expect(summary.changed).toBe(1);
    const after = fixture.db.get<{ id: string; revision: string; duration_ms: number }>(
      "select id, revision, duration_ms from asset",
    );
    expect(after?.id).toBe(before?.id);
    expect(after?.revision).not.toBe(before?.revision);
    expect(after?.duration_ms).toBeGreaterThan(before?.duration_ms ?? 0);
    expect(items(fixture.db, "movie")).toHaveLength(1);
  });

  it("marks a deleted file missing, then forgets it after thirty days", async () => {
    fixture = setUp();
    makeVideo(join(fixture.movies, "Up (2009)/Up (2009).mp4"));
    makeVideo(join(fixture.movies, "Coco (2017)/Coco (2017).mp4"), { seed: 4 });
    await scan(fixture);
    rmSync(join(fixture.movies, "Up (2009)"), { recursive: true });

    expect(await fixture.scanner.scanAll()).toMatchObject({ missing: 1 });
    expect(items(fixture.db, "movie")).toHaveLength(2);

    fixture.clock.now += 31 * 24 * 3_600_000;
    await fixture.scanner.scanAll();
    expect(items(fixture.db, "movie")).toMatchObject([{ title: "Coco" }]);
    expect(fixture.db.all("select item_id from tombstone")).toHaveLength(1);
  });

  it("keeps the whole catalogue when a drive disappears, and restores it when it returns", async () => {
    fixture = setUp();
    makeVideo(join(fixture.movies, "Up (2009)/Up (2009).mp4"));
    makeVideo(join(fixture.series, "Bluey/Season 01/Bluey S01E01.mkv"), { seed: 5 });
    await scan(fixture);
    const revision = fixture.db.currentRevision();

    // The mount point stays, empty and on the system disk, when a drive is unplugged.
    renameSync(fixture.movies, join(fixture.dir, "Unplugged"));
    mkdirSync(fixture.movies);
    fixture.unplugged.add(fixture.movies);
    const summary = await fixture.scanner.scanAll();
    expect(summary).toMatchObject({ missing: 0, unavailableSources: ["Movies"] });
    expect(fixture.db.all("select id from asset where available = 1")).toHaveLength(2);
    expect(
      fixture.db.all<{ name: string; available: number }>(
        "select name, available from source order by name",
      ),
    ).toEqual([
      { name: "Movies", available: 0 },
      { name: "Series", available: 1 },
    ]);
    expect(fixture.db.currentRevision()).toBeGreaterThan(revision);

    // A root that cannot be read at all is treated the same way.
    rmSync(fixture.movies, { recursive: true });
    expect((await fixture.scanner.scanAll()).unavailableSources).toEqual(["Movies"]);
    expect(items(fixture.db, "movie")).toHaveLength(1);

    renameSync(join(fixture.dir, "Unplugged"), fixture.movies);
    fixture.unplugged.delete(fixture.movies);
    expect(await fixture.scanner.scanAll()).toMatchObject({
      added: 0,
      missing: 0,
      unavailableSources: [],
    });
    expect(
      fixture.db.get<{ available: number }>("select available from source where name = 'Movies'"),
    ).toEqual({
      available: 1,
    });
  });

  it("treats a library folder someone emptied as emptied, not as a missing drive", async () => {
    fixture = setUp();
    makeVideo(join(fixture.movies, "Up (2009)/Up (2009).mp4"));
    await scan(fixture);
    rmSync(join(fixture.movies, "Up (2009)"), { recursive: true });
    expect(await fixture.scanner.scanAll()).toMatchObject({ missing: 1, unavailableSources: [] });
    expect(
      fixture.db.get<{ available: number }>("select available from source where name = 'Movies'"),
    ).toEqual({
      available: 1,
    });
  });

  it("carries on after a restart in the middle of a scan", async () => {
    fixture = setUp();
    makeVideo(join(fixture.movies, "Up (2009)/Up (2009).mp4"));
    makeVideo(join(fixture.movies, "Coco (2017)/Coco (2017).mp4"), { seed: 6 });
    // Files were found, then the server stopped before reading any of them.
    await fixture.scanner.scanAll();
    expect(items(fixture.db, "movie")).toHaveLength(0);
    const path = join(fixture.dir, "lobby.db");
    fixture.db.close();

    const db = new Database(path);
    const scanner = new Scanner(db, new Catalogue(db), {
      stabilityMs: 0,
      probeConcurrency: 2,
      ffprobePath: "ffprobe",
    });
    fixture.db = db;
    await scanner.scanAll();
    expect(await scanner.processQueue()).toBe(2);
    expect(items(db, "movie").map((movie) => movie.title)).toEqual(["Coco", "Up"]);
    expect(db.all("select id from asset")).toHaveLength(2);
  });
});
