// SPDX-License-Identifier: MPL-2.0
import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Hono } from "hono";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { Devices } from "../src/auth/devices.ts";
import { parseConfig } from "../src/config.ts";
import { Database } from "../src/db/database.ts";
import { createApp, type AppEnv } from "../src/http/app.ts";
import { Catalogue } from "../src/library/catalogue.ts";
import { ItemReader, type ApiItem } from "../src/library/items.ts";
import { Scanner } from "../src/library/scanner.ts";
import { chapterKind, markersFromChapters, readChapters } from "../src/markers/chapters.ts";
import { differingBits, fingerprintSamples } from "../src/markers/fingerprint.ts";
import { longestCommon, MIN_CONFIDENCE, vote } from "../src/markers/match.ts";
import { mergeSkipPreferences, readSkipPreferences } from "../src/markers/preferences.ts";
import { MarkerService } from "../src/markers/service.ts";
import type { ApiMarkers } from "../src/markers/store.ts";
import { runWork, type Found } from "../src/markers/work.ts";
import { ProgressStore } from "../src/progress.ts";
import { CREDITS_SECONDS, makeEpisode, SEASON, THEME_SECONDS } from "./support/episodes.ts";
import { makeTempDir, makeVideo, removeDir } from "./support/media.ts";

const SECONDS = 360;
/** How far a found edge may be from where the theme really is. */
const TOLERANCE_MS = 1000;

const introOf = (episode: (typeof SEASON)[number]): { startMs: number; endMs: number } => ({
  startMs: episode.introAt * 1000,
  endMs: (episode.introAt + THEME_SECONDS) * 1000,
});
const creditsOf = (episode: (typeof SEASON)[number]): number =>
  (SECONDS - episode.previewSeconds - CREDITS_SECONDS) * 1000;

function near(actual: number | undefined, expected: number): void {
  expect(actual).toBeDefined();
  expect(Math.abs((actual ?? 0) - expected)).toBeLessThanOrEqual(TOLERANCE_MS);
}

/** Adds chapters to a copy of a file, as an MKV from a disc would have them. */
function withChapters(from: string, to: string, chapters: [string, number, number][]): void {
  const meta = `${to}.meta.txt`;
  writeFileSync(
    meta,
    [
      ";FFMETADATA1",
      ...chapters.flatMap(([title, start, end]) => [
        "[CHAPTER]",
        "TIMEBASE=1/1000",
        `START=${String(start)}`,
        `END=${String(end)}`,
        `title=${title}`,
      ]),
    ].join("\n"),
  );
  execFileSync("ffmpeg", [
    "-v",
    "error",
    "-y",
    "-i",
    from,
    "-i",
    meta,
    "-map",
    "0",
    "-map_metadata",
    "1",
    "-map_chapters",
    "1",
    "-c",
    "copy",
    to,
  ]);
}

describe("fingerprints", () => {
  it("are the same for the same sound however loud, and unrelated for other sound", () => {
    const rate = 5000;
    const tone = new Float32Array(rate * 10);
    const noise = new Float32Array(rate * 10);
    let seed = 7;
    for (let i = 0; i < tone.length; i++) {
      const t = i / rate;
      const pitch = 300 * Math.pow(2, (Math.floor(t * 3) % 7) / 12);
      tone[i] =
        0.3 * Math.sin(2 * Math.PI * pitch * t) + 0.2 * Math.sin(2 * Math.PI * 2.1 * pitch * t);
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      noise[i] = (seed / 0x7fffffff - 0.5) * 0.4;
    }
    const quiet = tone.map((sample) => sample * 0.25);
    const a = fingerprintSamples(tone);
    const b = fingerprintSamples(quiet);
    const c = fingerprintSamples(noise);
    let same = 0;
    let other = 0;
    for (let i = 5; i < a.hashes.length; i++) {
      same += differingBits(a.hashes[i] ?? 0, b.hashes[i] ?? 0);
      other += differingBits(a.hashes[i] ?? 0, c.hashes[i] ?? 0);
    }
    const frames = a.hashes.length - 5;
    expect(same / frames).toBeLessThan(2);
    expect(other / frames).toBeGreaterThan(12);
    // Silence is never compared.
    expect([...fingerprintSamples(new Float32Array(rate * 2)).silent].every((s) => s === 1)).toBe(
      true,
    );
  });

  it("agree on the stretch most comparisons found, and say how sure", () => {
    const one = { startMs: 10_000, endMs: 50_000, quality: 0.9 };
    expect(vote([one, { ...one, startMs: 10_400 }, null])).toMatchObject({
      startMs: 10_200,
      endMs: 50_000,
      agreeing: 2,
    });
    expect(
      vote([one, { startMs: 200_000, endMs: 230_000, quality: 0.9 }, null, null]),
    ).toMatchObject({ agreeing: 1 });
    expect(vote([null, null])).toBeNull();
    // Alone and unsure is not shown.
    expect(vote([{ ...one, quality: 0.3 }, null, null])?.confidence).toBeLessThan(MIN_CONFIDENCE);
  });
});

describe("where the fingerprints are kept", () => {
  const roots = [{ path: "/media/Series", hint: "series" }];

  it("is the data folder's cache unless markers.cacheDir says otherwise", () => {
    expect(
      parseConfig({ dataDir: "/srv/lobby/data", roots }, "/srv/lobby/lobby.config.json").markers,
    ).toEqual({ cacheDir: "/srv/lobby/data/cache/markers" });
    // On the Pi the data folder is on a small stick: the fingerprints go to the media disk.
    expect(
      parseConfig(
        { dataDir: "/srv/lobby/data", roots, markers: { cacheDir: "/mnt/disk/.lobby/markers" } },
        "/srv/lobby/lobby.config.json",
      ).markers,
    ).toEqual({ cacheDir: "/mnt/disk/.lobby/markers" });
    // Relative to the config file, as the other caches are.
    expect(
      parseConfig({ roots, markers: { cacheDir: "cache/markers" } }, "/srv/lobby/lobby.config.json")
        .markers.cacheDir,
    ).toBe("/srv/lobby/cache/markers");
  });

  it("never inside a library folder", () => {
    for (const cacheDir of ["/media/Series", "/media/Series/.markers"]) {
      expect(() =>
        parseConfig({ roots, markers: { cacheDir } }, "/srv/lobby/lobby.config.json"),
      ).toThrow(/markers.cacheDir .* must not be inside a library root/);
    }
    expect(() =>
      parseConfig({ roots, markers: { cacheDir: 5 } }, "/srv/lobby/lobby.config.json"),
    ).toThrow(/markers.cacheDir must be a path/);
  });
});

describe("finding a season's intro and credits", () => {
  let dir: string;
  const files: string[] = [];

  beforeAll(() => {
    dir = makeTempDir("lobby-markers-");
    SEASON.forEach((episode, index) => {
      const file = join(dir, `e${String(index + 1)}.m4a`);
      makeEpisode(file, episode, { seconds: SECONDS });
      files.push(file);
    });
    // Another show: its own sounds, nothing of this theme.
    makeEpisode(
      join(dir, "other.m4a"),
      { introAt: 20, previewSeconds: 10, seed: 40, otherShow: true },
      {
        seconds: SECONDS,
      },
    );
  }, 120_000);
  afterAll(() => {
    removeDir(dir);
  });

  const print = async (file: string): Promise<void> => {
    const answer = await runWork({
      op: "print",
      ffmpegPath: "ffmpeg",
      path: file,
      streamIndex: null,
      stretches: [
        { kind: "intro", startMs: 0, durationMs: SECONDS * 250, out: `${file}.intro.fp` },
        {
          kind: "credits",
          startMs: SECONDS * 750,
          durationMs: SECONDS * 250,
          out: `${file}.credits.fp`,
        },
      ],
    });
    expect(answer.frames.intro).toBeGreaterThan(800);
  };

  it("finds the theme in every episode, wherever it is, within a second", async () => {
    for (const file of [...files, join(dir, "other.m4a")]) await print(file);
    for (const [index, episode] of SEASON.entries()) {
      const target = files[index] as string;
      const partners = files.filter((file) => file !== target);
      const { found } = await runWork({
        op: "match",
        kinds: [
          {
            kind: "intro",
            target: `${target}.intro.fp`,
            theme: null,
            partners: partners.map((file) => `${file}.intro.fp`),
          },
          {
            kind: "credits",
            target: `${target}.credits.fp`,
            theme: null,
            partners: partners.map((file) => `${file}.credits.fp`),
          },
        ],
      });
      near(found.intro?.startMs, introOf(episode).startMs);
      near(found.intro?.endMs, introOf(episode).endMs);
      near(found.credits?.startMs, creditsOf(episode));
      expect(found.intro?.agreeing).toBe(3);
      expect(found.intro?.confidence).toBeGreaterThanOrEqual(0.7);
      expect(found.credits?.confidence).toBeGreaterThanOrEqual(MIN_CONFIDENCE);
    }
  }, 120_000);

  it("finds it against the season's theme alone, and nothing in another show", async () => {
    const reference = SEASON[0] as (typeof SEASON)[number];
    const theme = { file: `${files[0] as string}.intro.fp`, ...introOf(reference) };
    const against = async (file: string): Promise<Found | null> =>
      (
        await runWork({
          op: "match",
          kinds: [{ kind: "intro", target: `${file}.intro.fp`, theme, partners: [] }],
        })
      ).found.intro ?? null;
    const fourth = await against(files[3] as string);
    expect(fourth?.via).toBe("theme");
    near(fourth?.startMs, introOf(SEASON[3] as (typeof SEASON)[number]).startMs);
    near(fourth?.endMs, introOf(SEASON[3] as (typeof SEASON)[number]).endMs);
    expect(await against(join(dir, "other.m4a"))).toBeNull();

    // Compared with episodes of this show, the other one has nothing in common with them.
    const { found } = await runWork({
      op: "match",
      kinds: [
        {
          kind: "intro",
          target: join(dir, "other.m4a.intro.fp"),
          theme: null,
          partners: files.map((file) => `${file}.intro.fp`),
        },
      ],
    });
    expect(found.intro ?? null).toBeNull();
  }, 60_000);

  it("never takes a stretch longer than an intro can be for one", () => {
    const hashes = new Uint32Array(3000).map((_, i) => (i * 2654435761) >>> 0);
    const same = { startMs: 0, hashes, silent: new Uint8Array(3000) };
    // Five minutes alike from the start: the same file twice, not an intro.
    expect(longestCommon(same, same, { minMs: 15_000, maxMs: 180_000 })).toBeNull();
    expect(longestCommon(same, same, { minMs: 15_000 })?.quality).toBe(1);
  });
});

describe("chapters", () => {
  it("knows intros and credits by their names", () => {
    const cases: [string, "intro" | "credits" | null][] = [
      ["Intro", "intro"],
      ["Opening", "intro"],
      ["Opening Credits", "intro"],
      ["OP", "intro"],
      ["Title Sequence", "intro"],
      ["Credits", "credits"],
      ["End Credits", "credits"],
      ["Ending", "credits"],
      ["ED", "credits"],
      ["Closing credits", "credits"],
      ["Chapter 3", null],
      ["Weekend", null],
      ["The Escape", null],
    ];
    expect(cases.map(([title]) => [title, chapterKind(title)])).toEqual(cases);
  });

  it("takes an intro of sensible length near the start and credits in the second half", () => {
    const chapters = [
      { title: "Prologue", startMs: 0, endMs: 60_000 },
      { title: "Intro", startMs: 60_000, endMs: 150_000 },
      { title: "Chapter 2", startMs: 150_000, endMs: 1_200_000 },
      { title: "Credits", startMs: 1_200_000, endMs: 1_300_000 },
    ];
    expect(markersFromChapters(chapters, 1_300_000)).toEqual({
      intro: { startMs: 60_000, endMs: 150_000 },
      credits: { startMs: 1_200_000 },
    });
    // An "intro" of ten minutes, or credits early on, are something else.
    expect(
      markersFromChapters(
        [
          { title: "Intro", startMs: 0, endMs: 600_000 },
          { title: "Credits", startMs: 700_000, endMs: 800_000 },
        ],
        3_000_000,
      ),
    ).toEqual({ intro: null, credits: null });
  });

  it("are read from a real file", async () => {
    const dir = makeTempDir("lobby-chapters-");
    try {
      makeVideo(join(dir, "plain.mp4"), { seconds: 4 });
      withChapters(join(dir, "plain.mp4"), join(dir, "film.mkv"), [
        ["Opening", 0, 1500],
        ["End Credits", 1500, 4000],
      ]);
      expect(await readChapters(join(dir, "film.mkv"))).toEqual([
        { title: "Opening", startMs: 0, endMs: 1500 },
        { title: "End Credits", startMs: 1500, endMs: 4000 },
      ]);
      expect(await readChapters(join(dir, "plain.mp4"))).toEqual([]);
    } finally {
      removeDir(dir);
    }
  });
});

describe("what a viewer wants at intros and credits", () => {
  it("defaults to the buttons, keeps what is left out, and refuses the unknown", () => {
    expect(readSkipPreferences(null)).toEqual({ intro: "show", credits: "show" });
    expect(readSkipPreferences("not json")).toEqual({ intro: "show", credits: "show" });
    const skip = mergeSkipPreferences(readSkipPreferences(null), { intro: "skip" });
    expect(skip).toEqual({ intro: "skip", credits: "show" });
    expect(mergeSkipPreferences(skip, { credits: "off" })).toEqual({
      intro: "skip",
      credits: "off",
    });
    expect(() => mergeSkipPreferences(skip, { intro: "always" })).toThrow(/intro/);
    expect(() => mergeSkipPreferences(skip, { credits: "skip" })).toThrow(/credits/);
    expect(() => mergeSkipPreferences(skip, [])).toThrow();
  });
});

// ---- The background job and the API, over a real catalogue ----

const SETUP_SECRET = "markers-secret";

interface Fixture {
  dir: string;
  series: string;
  films: string;
  db: Database;
  catalogue: Catalogue;
  scanner: Scanner;
  markers: MarkerService;
  wait: { reason: string | null };
  app: Hono<AppEnv>;
  devices: Devices;
}

let video: string;
beforeAll(() => {
  video = makeTempDir("lobby-marker-episodes-");
  SEASON.forEach((episode, index) => {
    makeEpisode(join(video, `e${String(index + 1)}.mkv`), episode, {
      seconds: SECONDS,
      video: true,
    });
  });
  makeVideo(join(video, "plain.mp4"), { seconds: 90 });
  withChapters(join(video, "plain.mp4"), join(video, "film.mkv"), [
    ["Studio logos", 0, 4000],
    ["Intro", 4000, 20_000],
    ["Story", 20_000, 70_000],
    ["End Credits", 70_000, 90_000],
  ]);
}, 180_000);
afterAll(() => {
  removeDir(video);
});

function setUp(): Fixture {
  const dir = makeTempDir("lobby-marker-job-");
  const series = join(dir, "Series");
  const films = join(dir, "Films");
  execFileSync("mkdir", ["-p", join(series, "Theme Show", "Season 01"), films]);
  const db = new Database(join(dir, "lobby.db"));
  const catalogue = new Catalogue(db);
  const scanner = new Scanner(db, catalogue, {
    stabilityMs: 0,
    probeConcurrency: 2,
    ffprobePath: "ffprobe",
    volumeOf: () => Promise.resolve(1),
  });
  scanner.syncSources([
    { path: series, name: "Series", hint: "series" },
    { path: films, name: "Films", hint: "movies" },
  ]);
  const wait = { reason: null as string | null };
  const markers = new MarkerService({
    db,
    catalogue,
    dir: join(dir, "markers"),
    waitBecause: () => wait.reason,
  });
  const devices = new Devices(db, SETUP_SECRET);
  const app = createApp({
    db,
    devices,
    items: new ItemReader(db),
    progress: new ProgressStore(db),
    markers,
    serverName: "Test",
    version: "0",
    isScanning: () => false,
  });
  return { dir, series, films, db, catalogue, scanner, markers, wait, app, devices };
}

function addEpisode(f: Fixture, number: number): void {
  execFileSync("cp", [
    join(video, `e${String(number)}.mkv`),
    join(f.series, "Theme Show", "Season 01", `Theme Show S01E0${String(number)}.mkv`),
  ]);
}

async function scan(f: Fixture): Promise<void> {
  await f.scanner.scanAll();
  await f.scanner.processQueue();
}

function episodes(f: Fixture): ApiItem[] {
  const reader = new ItemReader(f.db);
  const ids = f.db
    .all<{ id: string }>("select id from item where kind = 'episode' order by episode_number")
    .map((row) => row.id);
  return reader.read(ids);
}

function markersOf(item: ApiItem | undefined): ApiMarkers | undefined {
  return item?.files[0]?.markers;
}

describe("the background job", () => {
  let f: Fixture;
  beforeEach(() => {
    f = setUp();
  });
  afterEach(async () => {
    await f.markers.stop();
    f.db.close();
    removeDir(f.dir);
  });

  it("waits outside its hours, then finds each episode's intro and credits", async () => {
    for (const number of [1, 2, 3]) addEpisode(f, number);
    await scan(f);
    f.wait.reason = "It is outside the hours set for converting.";
    await f.markers.drain();
    expect(f.markers.status()).toMatchObject({
      waitingBecause: "It is outside the hours set for converting.",
      pending: { episodes: 3 },
    });
    expect(existsSync(join(f.dir, "markers"))).toBe(false);
    expect(episodes(f).map(markersOf)).toEqual([
      { intro: null, credits: null },
      { intro: null, credits: null },
      { intro: null, credits: null },
    ]);

    f.wait.reason = null;
    const started = process.cpuUsage();
    const startedAt = Date.now();
    await f.markers.drain();
    const used = process.cpuUsage(started);
    // The heavy part is in other processes; this one only waits for them.
    expect((used.user + used.system) / 1000).toBeLessThan((Date.now() - startedAt) * 0.5);
    const found = episodes(f);
    for (const [index, item] of found.entries()) {
      const episode = SEASON[index] as (typeof SEASON)[number];
      const markers = markersOf(item);
      expect(markers?.intro?.source).toBe("detected");
      near(markers?.intro?.startMs, introOf(episode).startMs);
      near(markers?.intro?.endMs, introOf(episode).endMs);
      near(markers?.credits?.startMs, creditsOf(episode));
    }
    expect(f.markers.status()).toMatchObject({
      waitingBecause: null,
      pending: { chapters: 0, episodes: 0, requested: 0 },
      found: { intro: 3, credits: 3 },
    });
    expect(f.db.all("select kind from season_theme order by kind")).toEqual([
      { kind: "credits" },
      { kind: "intro" },
    ]);
  }, 120_000);

  it("goes on where it stopped, and matches a new episode against the theme", async () => {
    for (const number of [1, 2, 3]) addEpisode(f, number);
    await scan(f);
    await f.markers.drain();
    const printed = f.db.all<{ asset_id: string; printed_at: number }>(
      "select asset_id, printed_at from marker_scan order by asset_id",
    );
    const prints = readdirSync(join(f.dir, "markers")).sort();
    expect(prints).toHaveLength(6);

    // A restart in the middle of comparing: the fingerprints are kept, only the comparison is
    // done again.
    const first = printed[0]?.asset_id ?? "";
    f.db.run("update marker_scan set matched_at = null where asset_id = ?", [first]);
    f.db.run("delete from marker where asset_id = ?", [first]);
    await f.markers.stop();
    const again = new MarkerService({
      db: f.db,
      catalogue: f.catalogue,
      dir: join(f.dir, "markers"),
    });
    await again.start();
    await again.drain();
    expect(f.db.all("select asset_id, printed_at from marker_scan order by asset_id")).toEqual(
      printed,
    );
    expect(readdirSync(join(f.dir, "markers")).sort()).toEqual(prints);
    expect(
      markersOf(episodes(f).find((one) => one.files[0]?.assetId === first))?.intro,
    ).not.toBeNull();

    // A new episode later: compared with the theme alone.
    addEpisode(f, 4);
    await scan(f);
    const theme = f.db.all("select * from season_theme order by kind");
    await again.drain();
    const fourth = markersOf(episodes(f)[3]);
    near(fourth?.intro?.startMs, introOf(SEASON[3] as (typeof SEASON)[number]).startMs);
    near(fourth?.credits?.startMs, creditsOf(SEASON[3] as (typeof SEASON)[number]));
    expect(f.db.all("select * from season_theme order by kind")).toEqual(theme);
    await again.stop();
  }, 120_000);

  it("reads chapters first, of films too, and does not compare what they give", async () => {
    execFileSync("cp", [join(video, "film.mkv"), join(f.films, "Some Film (2001).mkv")]);
    withChapters(
      join(video, "e1.mkv"),
      join(f.series, "Theme Show", "Season 01", "Theme Show S01E01.mkv"),
      [
        ["Opening", 2000, 44_000],
        ["Episode", 44_000, 320_000],
        ["Ending", 320_000, 360_000],
      ],
    );
    addEpisode(f, 2);
    await scan(f);
    f.wait.reason = null;
    await f.markers.drain();
    const film = new ItemReader(f.db).read(
      f.db.all<{ id: string }>("select id from item where kind = 'movie'").map((row) => row.id),
    )[0];
    expect(markersOf(film)).toEqual({
      intro: { startMs: 4000, endMs: 20_000, source: "chapters" },
      credits: { startMs: 70_000, source: "chapters" },
    });
    const [one, two] = episodes(f);
    expect(markersOf(one)).toEqual({
      intro: { startMs: 2000, endMs: 44_000, source: "chapters" },
      credits: { startMs: 320_000, source: "chapters" },
    });
    // The other one is still compared with it.
    expect(markersOf(two)?.intro?.source).toBe("detected");
    // The episodes are fingerprinted, the one with chapters too, so the other has its intro to
    // compare with; the film never is.
    expect(readdirSync(join(f.dir, "markers"))).toHaveLength(4);
    expect(f.db.all("select kind from season_theme")).toEqual([{ kind: "intro" }]);
  }, 120_000);

  it("does what a manager asks for at once, at any hour", async () => {
    for (const number of [1, 2]) addEpisode(f, number);
    await scan(f);
    f.wait.reason = "Someone is watching or downloading.";
    const season = f.db.get<{ id: string }>("select id from item where kind = 'season'")?.id ?? "";
    expect(f.markers.request(season)).toBe(2);
    await f.markers.drain();
    expect(episodes(f).map((one) => markersOf(one)?.intro?.source)).toEqual([
      "detected",
      "detected",
    ]);
    expect(f.markers.status().pending.requested).toBe(0);
  }, 120_000);

  it("starts a file again when it changes", async () => {
    for (const number of [1, 2]) addEpisode(f, number);
    await scan(f);
    await f.markers.drain();
    const asset = episodes(f)[0]?.files[0]?.assetId ?? "";
    f.db.run("update asset set revision = 'changed' where id = ?", [asset]);
    // The old finding is not for the new file.
    expect(markersOf(episodes(f)[0])).toEqual({ intro: null, credits: null });
    expect(f.markers.status().pending.episodes).toBe(1);
    await f.markers.drain();
    expect(markersOf(episodes(f)[0])?.intro?.source).toBe("detected");
    expect(readdirSync(join(f.dir, "markers")).filter((name) => name.startsWith(asset))).toEqual([
      `${asset}.changed.credits.fp`,
      `${asset}.changed.intro.fp`,
    ]);
  }, 120_000);
});

describe("the API", () => {
  let f: Fixture;
  let admin: string;
  let viewer: string;
  beforeEach(async () => {
    f = setUp();
    for (const number of [1, 2]) addEpisode(f, number);
    await scan(f);
    admin = f.devices.createLocalManager("Mac").token;
    const waiting = f.devices.startPairing("TV", "tvos");
    f.devices.approve(waiting.code, "viewer", "cli");
    const done = f.devices.collect(waiting.id, waiting.pollSecret);
    if (done.status !== "approved") throw new Error("not paired");
    viewer = done.token;
  }, 60_000);
  afterEach(async () => {
    await f.markers.stop();
    f.db.close();
    removeDir(f.dir);
  });

  const call = async <T = Record<string, unknown>>(
    token: string,
    method: string,
    path: string,
    body?: unknown,
  ): Promise<{ status: number; body: T }> => {
    const response = await f.app.request(path, {
      method,
      headers: {
        Authorization: `Bearer ${token}`,
        ...(body === undefined ? {} : { "Content-Type": "application/json" }),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    const text = await response.text();
    return { status: response.status, body: (text === "" ? null : JSON.parse(text)) as T };
  };

  it("lets a server admin set markers by hand, which win, and go back to what was found", async () => {
    await f.markers.drain();
    const [one] = episodes(f);
    const asset = one?.files[0]?.assetId ?? "";
    const path = `/v1/markers/assets/${asset}`;
    expect((await call(viewer, "GET", path)).status).toBe(403);
    expect((await call(viewer, "PUT", path, { intro: null })).status).toBe(403);

    const seen = await call<{ sources: { source: string; used: boolean }[] }>(admin, "GET", path);
    expect(seen.status).toBe(200);
    expect(seen.body.sources.map((one) => [one.source, one.used])).toEqual([
      ["detected", true],
      ["detected", true],
    ]);

    const set = await call<{ markers: ApiMarkers }>(admin, "PUT", path, {
      intro: { startMs: 1000, endMs: 30_000 },
      credits: null,
    });
    expect(set.status).toBe(200);
    expect(set.body.markers).toEqual({
      intro: { startMs: 1000, endMs: 30_000, source: "manual" },
      credits: null,
    });
    // What the apps get, too.
    const library = await call<{ items: ApiItem[] }>(viewer, "GET", "/v1/library");
    const item = library.body.items.find((one) => one.files[0]?.assetId === asset);
    expect(item?.files[0]?.markers).toEqual(set.body.markers);

    for (const body of [
      { intro: { startMs: 5000, endMs: 4000 } },
      { intro: { startMs: -1, endMs: 4000 } },
      { credits: { startMs: 1.5 } },
      { credits: { startMs: 10_000_000 } },
      { intro: "soon" },
    ]) {
      expect([body, (await call(admin, "PUT", path, body)).status]).toEqual([body, 400]);
    }

    const back = await call<{ markers: ApiMarkers }>(admin, "DELETE", `${path}?kind=credits`);
    expect(back.body.markers.credits?.source).toBe("detected");
    expect(back.body.markers.intro?.source).toBe("manual");
    const all = await call<{ markers: ApiMarkers }>(admin, "DELETE", path);
    expect(all.body.markers.intro?.source).toBe("detected");
    expect((await call(admin, "GET", "/v1/markers/assets/nothing")).status).toBe(404);
  }, 120_000);

  it("finds a season again when asked, for a server admin only", async () => {
    const season = f.db.get<{ id: string }>("select id from item where kind = 'season'")?.id ?? "";
    const path = `/v1/markers/items/${season}/detect`;
    expect((await call(viewer, "POST", path)).status).toBe(403);
    f.wait.reason = "It is outside the hours set for converting.";
    const asked = await call<{ files: number; status: { pending: { requested: number } } }>(
      admin,
      "POST",
      path,
    );
    expect(asked.status).toBe(202);
    expect(asked.body.files).toBe(2);
    await f.markers.drain();
    const status = await call<{ waitingBecause: string; found: { intro: number } }>(
      admin,
      "GET",
      "/v1/markers",
    );
    expect(status.body).toMatchObject({
      waitingBecause: "It is outside the hours set for converting.",
      found: { intro: 2 },
    });
    expect((await call(admin, "POST", "/v1/markers/items/nothing/detect")).status).toBe(404);
  }, 120_000);

  it("keeps what each viewer wants at intros and credits", async () => {
    const created = await call<{ id: string; skipping: unknown }>(admin, "POST", "/v1/profiles", {
      name: "Sam",
      skipping: { intro: "skip" },
    });
    expect(created.body.skipping).toEqual({ intro: "skip", credits: "show" });
    const id = created.body.id;
    const put = await call<{ skipping: unknown }>(viewer, "PUT", `/v1/profiles/${id}/skipping`, {
      credits: "off",
    });
    expect(put.status).toBe(200);
    expect(put.body.skipping).toEqual({ intro: "skip", credits: "off" });
    expect(
      (await call(viewer, "PUT", `/v1/profiles/${id}/skipping`, { intro: "maybe" })).status,
    ).toBe(400);
    const patched = await call<{ skipping: unknown }>(admin, "PATCH", `/v1/profiles/${id}`, {
      skipping: { intro: "off" },
    });
    expect(patched.body.skipping).toEqual({ intro: "off", credits: "off" });
    const listed = await call<{ profiles: { skipping: unknown }[] }>(viewer, "GET", "/v1/profiles");
    expect(listed.body.profiles.map((one) => one.skipping)).toEqual([
      { intro: "off", credits: "off" },
    ]);
  });
});
