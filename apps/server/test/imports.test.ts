// SPDX-License-Identifier: MPL-2.0
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
  appendFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { Devices } from "../src/auth/devices.ts";
import type { RootConfig } from "../src/config.ts";
import { Database } from "../src/db/database.ts";
import { createApp } from "../src/http/app.ts";
import { episodeTarget, filmTarget, safeName, subtitleTarget } from "../src/imports/naming.ts";
import { judgeFiles, nonFeatureWord, type SeenFile } from "../src/imports/rules.ts";
import {
  ImportService,
  looksLikeDownloads,
  type ApiImportItem,
  type ImportOptions,
  type Identified,
  type Wanted,
} from "../src/imports/service.ts";
import { UploadService } from "../src/imports/uploads.ts";
import { ItemReader } from "../src/library/items.ts";
import { parseMediaPath } from "../src/library/parse.ts";
import { ProgressStore } from "../src/progress.ts";
import { SETTINGS } from "../src/settings/schema.ts";
import { makeTempDir, makeVideo, removeDir } from "./support/media.ts";

const MINUTE = 60_000;
const MB = 1024 * 1024;

const episodeLike = (rel: string): boolean => {
  const parsed = parseMediaPath(rel, "mixed");
  return parsed.kind === "episode" && parsed.episode !== null;
};

function judge(
  files: [string, number][],
  limits = { minFilmBytes: 100 * MB, minEpisodeBytes: 20 * MB },
) {
  const seen: SeenFile[] = files.map(([rel, size]) => ({ rel, size, mtimeMs: 0 }));
  return judgeFiles(seen, episodeLike, limits);
}

describe("which files are finished films and episodes", () => {
  it("waits for a file with anything after its video extension", () => {
    const verdicts = judge([
      ["Film.2020.mkv.part", 900 * MB],
      ["Other.2021.mp4.!qB", 900 * MB],
      ["Third.2022.avi.crdownload", 900 * MB],
      ["Fourth.2023.m4v.xyz", 900 * MB],
      ["Done (2019).mkv", 900 * MB],
    ]);
    for (const name of [
      "Film.2020.mkv.part",
      "Other.2021.mp4.!qB",
      "Third.2022.avi.crdownload",
      "Fourth.2023.m4v.xyz",
    ]) {
      expect(verdicts.get(name)?.status, name).toBe("unfinished");
    }
    expect(verdicts.get("Done (2019).mkv")?.status).toBe("candidate");
  });

  it("waits for a video with a control file beside it", () => {
    for (const companion of [
      "Film (2020).mkv.aria2",
      "Film (2020).mkv.part",
      "Film (2020).!qB",
      "Film (2020).crdownload",
    ]) {
      const verdicts = judge([
        ["Film (2020)/Film (2020).mkv", 900 * MB],
        [`Film (2020)/${companion}`, 1000],
      ]);
      expect(verdicts.get("Film (2020)/Film (2020).mkv")?.status, companion).toBe("unfinished");
    }
  });

  it("leaves out samples, trailers and other extras, by name or folder", () => {
    const names = [
      "Film (2020)/sample.mkv",
      "Film (2020)/film-sample.mkv",
      "Film (2020)/Film.2020.SAMPLE.mkv",
      "Film (2020)/Film Trailer.mp4",
      "Film (2020)/Featurettes/Making of.mkv",
      "Film (2020)/Extras/Bloopers.mkv",
      "Film (2020)/Behind The Scenes.mkv",
      "Film (2020)/Behind.the.Scenes/Part 1.mkv",
      "Film (2020)/Deleted Scenes.mkv",
      "Film (2020)/Interview with the cast.mkv",
      "Film (2020)/Teaser.mkv",
    ];
    const verdicts = judge([
      ["Film (2020)/Film (2020).mkv", 4000 * MB],
      ...names.map((name): [string, number] => [name, 900 * MB]),
    ]);
    for (const name of names) {
      const verdict = verdicts.get(name);
      expect(verdict?.status, name).toBe("excluded");
    }
    expect(verdicts.get("Film (2020)/Film (2020).mkv")?.status).toBe("candidate");
    expect(nonFeatureWord("Samples/x.mkv")).toBeNull();
    expect(nonFeatureWord("Film/x-sample.mkv")).toBe("sample");
    // A word inside another word is not one: "Extraordinary" is a film.
    expect(nonFeatureWord("Extraordinary (2019)/Extraordinary (2019).mkv")).toBeNull();
  });

  it("leaves out a film far too small, and one far smaller than the main file", () => {
    const verdicts = judge([
      ["Tiny (2020).mkv", 50 * MB],
      ["Film (2021)/Film (2021).mkv", 4000 * MB],
      ["Film (2021)/Something else.mkv", 300 * MB],
      ["Show/Season 1/Show S01E01.mkv", 25 * MB],
      ["Show/Season 1/Show S01E02.mkv", 10 * MB],
      ["Show/Season 1/Show S01E03.mkv", 300 * MB],
    ]);
    expect(verdicts.get("Tiny (2020).mkv")).toMatchObject({ status: "excluded", leftover: true });
    expect(verdicts.get("Film (2021)/Something else.mkv")?.status).toBe("excluded");
    // Episodes of one season differ; they are not measured against each other.
    expect(verdicts.get("Show/Season 1/Show S01E01.mkv")?.status).toBe("candidate");
    expect(verdicts.get("Show/Season 1/Show S01E02.mkv")?.status).toBe("excluded");
    expect(verdicts.get("Show/Season 1/Show S01E03.mkv")?.status).toBe("candidate");
  });

  it("leaves out everything that is not a video, as leftovers", () => {
    const extras = [
      "info.nfo",
      "readme.txt",
      "cover.jpg",
      "poster.png",
      "site.url",
      "setup.exe",
      "film.srr",
      "film.sfv",
    ];
    const verdicts = judge([
      ["Film (2020)/Film (2020).mkv", 900 * MB],
      ...extras.map((name): [string, number] => [`Film (2020)/${name}`, 1000]),
    ]);
    for (const name of extras) {
      expect(verdicts.get(`Film (2020)/${name}`), name).toMatchObject({
        status: "excluded",
        leftover: true,
      });
    }
  });

  it("takes subtitles along with their video", () => {
    const verdicts = judge([
      ["Film (2020)/Film (2020).mkv", 900 * MB],
      ["Film (2020)/Film (2020).en.srt", 1000],
      ["Film (2020)/Subs/English.srt", 1000],
      ["Two/A (2001).mkv", 900 * MB],
      ["Two/B (2002).mkv", 900 * MB],
      ["Two/A (2001).nl.srt", 1000],
      ["Two/Other.srt", 1000],
    ]);
    expect(verdicts.get("Film (2020)/Film (2020).mkv")).toEqual({
      status: "candidate",
      subtitles: ["Film (2020)/Film (2020).en.srt", "Film (2020)/Subs/English.srt"],
    });
    expect(verdicts.get("Two/A (2001).mkv")).toEqual({
      status: "candidate",
      subtitles: ["Two/A (2001).nl.srt"],
    });
    expect(verdicts.get("Two/Other.srt")?.status).toBe("excluded");
  });

  it("knows folders a download program uses by their names", () => {
    expect(looksLikeDownloads("/media/drive/Downloads")).toBe(true);
    expect(looksLikeDownloads("/media/drive/Incoming")).toBe(true);
    expect(looksLikeDownloads("/media/drive/New films")).toBe(false);
    const folders = SETTINGS.find((one) => one.key === "import.folders");
    expect(
      folders?.check([{ path: "/media/drive/Downloads" }, { path: "/media/drive/New" }]),
    ).toEqual([
      { path: "/media/drive/Downloads", mode: "index" },
      { path: "/media/drive/New", mode: "move" },
    ]);
    // The manager's choice wins.
    expect(folders?.check([{ path: "/media/drive/Downloads", mode: "move" }])).toEqual([
      { path: "/media/drive/Downloads", mode: "move" },
    ]);
  });
});

describe("neat names", () => {
  it("names films and episodes so the library reads them back the same", () => {
    const film = filmTarget({ title: "Blade Runner 2049", year: 2017 }, "MKV");
    expect(film).toBe("Blade Runner 2049 (2017)/Blade Runner 2049 (2017).mkv");
    expect(parseMediaPath(film, "movies")).toMatchObject({
      kind: "movie",
      title: "Blade Runner 2049",
      year: 2017,
    });
    const episode = episodeTarget(
      { show: "Bluey", season: 2, episode: 4, episodeTitle: "Dance Mode" },
      "mp4",
    );
    expect(episode).toBe("Bluey/Season 02/Bluey - S02E04 - Dance Mode.mp4");
    expect(parseMediaPath(episode, "series")).toMatchObject({
      kind: "episode",
      title: "Bluey",
      season: 2,
      episode: 4,
      episodeTitle: "Dance Mode",
    });
    expect(episodeTarget({ show: "Show", season: 1, episode: 1, episodeEnd: 2 }, "mkv")).toBe(
      "Show/Season 01/Show - S01E01-E02.mkv",
    );
  });

  it("keeps out what a drive cannot hold", () => {
    expect(safeName('Mission: Impossible / "Fallout"?')).toBe("Mission Impossible Fallout");
    expect(safeName("...hidden. ")).toBe("hidden");
    expect(filmTarget({ title: "../../etc", year: null }, "mkv")).toBe("etc/etc.mkv");
  });

  it("names subtitles after their video", () => {
    expect(
      subtitleTarget(
        "Film (2020)/Film (2020).mkv",
        "Film.2020.1080p.mkv",
        "Film.2020.1080p.en.srt",
      ),
    ).toBe("Film (2020)/Film (2020).en.srt");
    expect(
      subtitleTarget("Film (2020)/Film (2020).mkv", "Film.2020.1080p.mkv", "English.srt"),
    ).toBe("Film (2020)/Film (2020).English.srt");
    // What says it is forced, and which language, goes along.
    expect(
      subtitleTarget("Film (2020)/Film (2020).mkv", "Film.2020.mkv", "Film.2020.eng.forced.ass"),
    ).toBe("Film (2020)/Film (2020).eng.forced.ass");
  });
});

describe("import folders", () => {
  let dir: string;
  let db: Database;
  let incoming: string;
  let lobby: string;
  let roots: RootConfig[];
  let clock: number;
  let open: Set<string>;
  let running: ImportService[];
  let matched: Wanted[];
  let answers: Map<string, Identified>;
  let changes: number;

  beforeEach(() => {
    dir = makeTempDir("lobby-imports-");
    db = new Database(join(dir, "lobby.db"));
    incoming = join(dir, "drive", "New");
    lobby = join(dir, "drive", "Lobby");
    roots = [
      { path: join(dir, "drive", "Movies"), name: "Movies", hint: "movies" },
      { path: join(dir, "drive", "Series"), name: "Series", hint: "series" },
      { path: join(dir, "drive", "Pixar"), name: "Pixar", hint: "movies" },
    ];
    for (const path of [incoming, lobby, ...roots.map((root) => root.path)])
      mkdirSync(path, { recursive: true });
    clock = 1_000_000_000;
    open = new Set();
    running = [];
    matched = [];
    answers = new Map();
    changes = 0;
  });

  afterEach(async () => {
    for (const one of running) await one.stop();
    db.close();
    removeDir(dir);
  });

  function service(more: Partial<ImportOptions> = {}): ImportService {
    const one = new ImportService({
      db,
      folders: [{ path: incoming, mode: "move" }],
      roots: () => roots,
      lobbyDir: lobby,
      driveConnected: () => Promise.resolve(true),
      waitMs: 10 * MINUTE,
      copyAcrossDrives: false,
      // TMDB's part: what the household's TMDB lookup answers, by title.
      matcher: (wanted) => {
        matched.push(wanted);
        return Promise.resolve(
          answers.get(wanted.title) ?? {
            accepted: { title: wanted.title, year: wanted.year ?? 2000, tmdbId: 7 },
            reason: "",
            candidates: [],
          },
        );
      },
      limits: { minFilmBytes: 1000, minEpisodeBytes: 1000 },
      now: () => clock,
      isOpenElsewhere: (path) => Promise.resolve(open.has(path)),
      intervalMs: 3_600_000,
      onLibraryChanged: () => {
        changes += 1;
      },
      ...more,
    });
    running.push(one);
    return one;
  }

  /** Looks, lets the waiting time pass, and looks again. */
  async function settle(imports: ImportService): Promise<void> {
    await imports.scanNow();
    clock += 11 * MINUTE;
    await imports.scanNow();
  }

  function tree(root: string): string[] {
    if (!existsSync(root)) return [];
    const found: string[] = [];
    const walk = (at: string, prefix: string): void => {
      for (const entry of readdirSync(at, { withFileTypes: true })) {
        const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
        if (entry.isDirectory()) walk(join(at, entry.name), rel);
        else found.push(rel);
      }
    };
    walk(root, "");
    return found.sort();
  }

  const only = (
    imports: ImportService,
    view: Parameters<ImportService["items"]>[0],
  ): ApiImportItem[] => imports.items(view, 100);

  it("moves a finished film into the films folder under a neat name, with its subtitle", async () => {
    const release = join(incoming, "Arrival.2016.1080p.BluRay.x264-GRP");
    makeVideo(join(release, "Arrival.2016.1080p.BluRay.x264-GRP.mkv"), { seconds: 2 });
    writeFileSync(
      join(release, "Arrival.2016.1080p.BluRay.x264-GRP.en.srt"),
      "1\n00:00:01,000 --> 00:00:02,000\nHello\n",
    );
    writeFileSync(join(release, "release.nfo"), "info");
    makeVideo(join(release, "Sample", "arrival-sample.mkv"));
    const original = readFileSync(join(release, "Arrival.2016.1080p.BluRay.x264-GRP.mkv"));

    const imports = service();
    await imports.scanNow();
    // Not touched until it held still.
    expect(tree(roots[0]?.path ?? "")).toEqual([]);
    expect(only(imports, ["waiting"]).map((one) => one.name)).toEqual([
      "Arrival.2016.1080p.BluRay.x264-GRP.mkv",
    ]);
    clock += 11 * MINUTE;
    await imports.scanNow();

    expect(tree(roots[0]?.path ?? "")).toEqual([
      "Arrival (2016)/Arrival (2016).en.srt",
      "Arrival (2016)/Arrival (2016).mkv",
    ]);
    expect(
      readFileSync(join(roots[0]?.path ?? "", "Arrival (2016)/Arrival (2016).mkv")).equals(
        original,
      ),
    ).toBe(true);
    expect(matched[0]).toMatchObject({ type: "movie", title: "Arrival", year: 2016 });
    expect(matched[0]?.runtimeMinutes).toBe(0);
    expect(changes).toBe(1);
    const [done] = only(imports, ["imported"]);
    expect(done).toMatchObject({
      state: "imported",
      title: "Arrival",
      year: 2016,
      actions: ["cleanUp"],
    });
    expect(done?.leftovers).toEqual({
      dir: "Arrival.2016.1080p.BluRay.x264-GRP",
      files: [
        "Arrival.2016.1080p.BluRay.x264-GRP/Sample/arrival-sample.mkv",
        "Arrival.2016.1080p.BluRay.x264-GRP/release.nfo",
      ],
    });
    // The sample was never moved or listed: it is only shown, with its reason.
    expect(
      only(imports, ["ignored"])
        .map((one) => [one.name, one.reason])
        .sort(),
    ).toEqual([
      ["arrival-sample.mkv", "Its name says “sample”, so it is not the film or episode itself."],
      ["release.nfo", "It is not a video."],
    ]);

    // What was left goes only when a manager says so.
    expect(existsSync(release)).toBe(true);
    await imports.cleanUp(done?.id ?? "", "manager");
    expect(existsSync(release)).toBe(false);
    expect(existsSync(incoming)).toBe(true);
    expect(imports.activityLog(10).map((one) => one.action)).toContain("cleaned");
  });

  it("puts an episode in its show's season folder", async () => {
    makeVideo(join(incoming, "The.Office.US.S02E03.Office.Olympics.720p.WEB.mkv"));
    const imports = service();
    await settle(imports);
    expect(tree(roots[1]?.path ?? "")).toEqual([
      "The Office US/Season 02/The Office US - S02E03 - Office Olympics.mkv",
    ]);
    expect(matched[0]).toMatchObject({ type: "tv", title: "The Office US", season: 2, episode: 3 });
  });

  it("does not touch a file that keeps changing", async () => {
    const path = join(incoming, "Growing (2020).mkv");
    makeVideo(path);
    const imports = service();
    await imports.scanNow();
    for (let round = 0; round < 3; round += 1) {
      clock += 6 * MINUTE;
      appendFileSync(path, Buffer.alloc(100));
      await imports.scanNow();
      expect(existsSync(path)).toBe(true);
    }
    clock += 11 * MINUTE;
    await imports.scanNow();
    expect(existsSync(path)).toBe(false);
    expect(tree(roots[0]?.path ?? "")).toEqual(["Growing (2020)/Growing (2020).mkv"]);
  });

  it("waits while a program keeps a file beside it, or has it open", async () => {
    const path = join(incoming, "Busy (2020)", "Busy (2020).mkv");
    makeVideo(path);
    writeFileSync(`${path}.aria2`, "control");
    const imports = service();
    await settle(imports);
    clock += 60 * MINUTE;
    await imports.scanNow();
    expect(existsSync(path)).toBe(true);
    expect(only(imports, ["waiting"])[0]?.reason).toBe(
      "A program still keeps a file beside it, so it is not finished yet.",
    );

    rmSync(`${path}.aria2`);
    open.add(path);
    await settle(imports);
    expect(existsSync(path)).toBe(true);
    expect(only(imports, ["waiting"])[0]?.reason).toBe("Another program has it open.");

    open.clear();
    await imports.scanNow();
    expect(existsSync(path)).toBe(false);
  });

  it("waits for a name with something after the video extension until it changes", async () => {
    const part = join(incoming, "Later (2021).mkv.part");
    makeVideo(join(incoming, "tmp.mkv"));
    renameSync(join(incoming, "tmp.mkv"), part);
    const imports = service();
    await settle(imports);
    expect(only(imports, ["waiting"]).map((one) => [one.name, one.reason])).toEqual([
      [
        "Later (2021).mkv.part",
        "It has “.part” after the video extension, so it is not finished yet.",
      ],
    ]);
    renameSync(part, join(incoming, "Later (2021).mkv"));
    await settle(imports);
    expect(tree(roots[0]?.path ?? "")).toEqual(["Later (2021)/Later (2021).mkv"]);
    expect(only(imports, ["waiting"])).toEqual([]);
  });

  it("keeps what TMDB cannot place in the Inbox, and moves it when a manager confirms", async () => {
    answers.set("Hero", {
      accepted: null,
      reason: "Several films on TMDB fit this title.",
      candidates: [
        { title: "Hero", year: 2002, tmdbId: 1 },
        { title: "Hero", year: 1992, tmdbId: 2 },
      ],
    });
    makeVideo(join(incoming, "Hero.mkv"));
    const imports = service();
    await settle(imports);
    const [waiting] = only(imports, ["inbox"]);
    expect(waiting).toMatchObject({
      reason: "Several films on TMDB fit this title.",
      candidates: [{ year: 2002 }, { year: 1992 }],
      actions: ["move", "dismiss"],
    });
    expect(existsSync(join(incoming, "Hero.mkv"))).toBe(true);

    const item = await imports.confirm(waiting?.id ?? "", "manager", {
      action: "move",
      kind: "movie",
      title: "Hero",
      year: 2002,
      destination: roots[2]?.path ?? null,
    });
    expect(item.state).toBe("imported");
    expect(tree(roots[2]?.path ?? "")).toEqual(["Hero (2002)/Hero (2002).mkv"]);
    expect(
      imports
        .activityLog(5)
        .map((one) => one.action)
        .slice(0, 2),
    ).toEqual(["imported", "confirmed"]);
  });

  it("asks a manager when there is no TMDB key, and when the name says nothing", async () => {
    makeVideo(join(incoming, "Some Film (1999).mkv"));
    makeVideo(join(incoming, "Some Show S01E01.mkv"), { seed: 1 });
    const imports = service({ matcher: () => Promise.resolve(null) });
    await settle(imports);
    expect(only(imports, ["inbox"]).map((one) => one.reason)).toEqual([
      "Without a TMDB key Lobby cannot check what this is. Confirm the title.",
      "Without a TMDB key Lobby cannot check what this is. Confirm the title.",
    ]);
    expect(tree(roots[0]?.path ?? "")).toEqual([]);
  });

  it("never replaces a file that is already in the library", async () => {
    const there = join(roots[0]?.path ?? "", "Taken (2008)", "Taken (2008).mkv");
    mkdirSync(dirname(there), { recursive: true });
    writeFileSync(there, "the family's copy");
    makeVideo(join(incoming, "Taken.2008.mkv"));
    const imports = service();
    await settle(imports);
    expect(readFileSync(there, "utf8")).toBe("the family's copy");
    expect(existsSync(join(incoming, "Taken.2008.mkv"))).toBe(true);
    expect(only(imports, ["inbox"])[0]?.reason).toBe(
      "There is already a file named “Taken (2008).mkv” in Movies.",
    );
  });

  it("refuses to move between drives unless copying is on, and then proves the copy", async () => {
    const volumeOf = (path: string): Promise<number> =>
      Promise.resolve(path.startsWith(incoming) ? 2 : 1);
    makeVideo(join(incoming, "Far (2010).mkv"));
    const bytes = readFileSync(join(incoming, "Far (2010).mkv"));
    const imports = service({ volumeOf });
    await settle(imports);
    expect(only(imports, ["inbox"])[0]?.reason).toMatch(/^It is on another drive than Movies\./);
    expect(existsSync(join(incoming, "Far (2010).mkv"))).toBe(true);

    imports.configure({ copyAcrossDrives: true });
    const [waiting] = only(imports, ["inbox"]);
    await imports.confirm(waiting?.id ?? "", "manager", {
      action: "move",
      kind: "movie",
      title: "Far",
      year: 2010,
    });
    const copied = join(roots[0]?.path ?? "", "Far (2010)", "Far (2010).mkv");
    expect(readFileSync(copied).equals(bytes)).toBe(true);
    expect(existsSync(join(incoming, "Far (2010).mkv"))).toBe(false);
    expect(tree(roots[0]?.path ?? "")).toEqual(["Far (2010)/Far (2010).mkv"]);
  });

  it("does not move without Lobby's folder", async () => {
    makeVideo(join(incoming, "Stay (2005).mkv"));
    const imports = service({ lobbyDir: null });
    await settle(imports);
    expect(only(imports, ["inbox"])[0]?.reason).toBe(
      "Moving needs Lobby's folder, set under Converting.",
    );
  });

  for (const point of ["journal", "move:0", "move:1", "commit"] as const) {
    it(`finishes a move the server was stopped in (${point})`, async () => {
      makeVideo(join(incoming, "Crash (2004).mkv"));
      writeFileSync(join(incoming, "Crash (2004).srt"), "1\n00:00:01,000 --> 00:00:02,000\nHi\n");
      const bytes = readFileSync(join(incoming, "Crash (2004).mkv"));
      const first = service({
        fault: (at) => {
          if (at === point) throw new Error(`stopped at ${at}`);
        },
      });
      await settle(first);
      await first.stop();

      const second = service();
      await second.start();
      await second.stop();
      const copies = [
        join(incoming, "Crash (2004).mkv"),
        join(roots[0]?.path ?? "", "Crash (2004)", "Crash (2004).mkv"),
      ].filter((path) => existsSync(path) && readFileSync(path).equals(bytes));
      expect(copies).toHaveLength(1);
      expect(tree(roots[0]?.path ?? "")).toEqual([
        "Crash (2004)/Crash (2004).mkv",
        "Crash (2004)/Crash (2004).srt",
      ]);
      expect(only(second, ["imported"]).map((one) => one.state)).toEqual(["imported"]);
      expect(readdirSync(join(lobby, "imports", "journal"))).toEqual([]);
    });
  }

  it("takes a move back when another file took its place while the server was stopped", async () => {
    makeVideo(join(incoming, "Swap (2001).mkv"));
    const first = service({
      fault: (at) => {
        if (at === "journal") throw new Error("stopped");
      },
    });
    await settle(first);
    await first.stop();
    const target = join(roots[0]?.path ?? "", "Swap (2001)", "Swap (2001).mkv");
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, "someone else's");
    const second = service();
    await second.start();
    await second.stop();
    expect(readFileSync(target, "utf8")).toBe("someone else's");
    expect(existsSync(join(incoming, "Swap (2001).mkv"))).toBe(true);
    expect(only(second, ["inbox"])[0]?.reason).toBe("Another file was in the way.");
  });

  it("lists files of a folder that is indexed, and moves one only when a manager says so", async () => {
    const downloads = join(dir, "drive", "Downloads");
    makeVideo(join(downloads, "Kept.2011.1080p", "Kept.2011.1080p.mkv"));
    makeVideo(join(downloads, "Kept.2011.1080p", "sample.mkv"), { seed: 2 });
    const imports = service({ folders: [{ path: downloads, mode: "index" }] });
    expect(imports.indexSources()).toEqual([{ path: downloads, name: "Downloads", hint: "mixed" }]);
    await settle(imports);
    const [listed] = only(imports, ["listed"]);
    expect(listed).toMatchObject({ name: "Kept.2011.1080p.mkv", actions: ["move", "dismiss"] });
    expect(imports.isListed(downloads, "Kept.2011.1080p/Kept.2011.1080p.mkv")).toBe(true);
    expect(imports.isListed(downloads, "Kept.2011.1080p/sample.mkv")).toBe(false);
    expect(matched).toEqual([]);
    expect(tree(roots[0]?.path ?? "")).toEqual([]);

    await imports.confirm(listed?.id ?? "", "manager", {
      action: "move",
      kind: "movie",
      title: "Kept",
      year: 2011,
    });
    expect(tree(roots[0]?.path ?? "")).toEqual(["Kept (2011)/Kept (2011).mkv"]);
    expect(imports.isListed(downloads, "Kept.2011.1080p/Kept.2011.1080p.mkv")).toBe(false);
  });

  it("lets a manager leave a file alone, or import one that was left out", async () => {
    makeVideo(join(incoming, "Alone (2000).mkv"));
    makeVideo(join(incoming, "The Interview (2014)", "The Interview (2014).mkv"), { seed: 3 });
    const imports = service({ matcher: () => Promise.resolve(null) });
    await settle(imports);
    const [inbox] = only(imports, ["inbox"]);
    await imports.dismiss(inbox?.id ?? "", "manager");
    await settle(imports);
    expect(only(imports, ["dismissed"]).map((one) => one.name)).toEqual(["Alone (2000).mkv"]);
    expect(existsSync(join(incoming, "Alone (2000).mkv"))).toBe(true);

    const [ignored] = only(imports, ["ignored"]);
    expect(ignored?.reason).toBe(
      "Its name says “interview”, so it is not the film or episode itself.",
    );
    await imports.confirm(ignored?.id ?? "", "manager", {
      action: "move",
      kind: "movie",
      title: "The Interview",
      year: 2014,
    });
    expect(tree(roots[0]?.path ?? "")).toEqual(["The Interview (2014)/The Interview (2014).mkv"]);
  });

  it("forgets a file that went away before it was imported", async () => {
    makeVideo(join(incoming, "Gone (2000).mkv"));
    const imports = service({ matcher: () => Promise.resolve(null) });
    await settle(imports);
    expect(only(imports, ["inbox"])).toHaveLength(1);
    rmSync(join(incoming, "Gone (2000).mkv"));
    await imports.scanNow();
    expect(only(imports, ["inbox"])).toEqual([]);
    expect(imports.activityLog(1)[0]?.action).toBe("gone");
  });
});

describe("uploads", () => {
  let dir: string;
  let db: Database;
  let lobby: string;
  let roots: RootConfig[];
  let imports: ImportService;
  let uploads: UploadService;
  let app: ReturnType<typeof createApp>;
  let manager: string;
  let viewer: string;
  let free: number;

  function build(): void {
    uploads = new UploadService({
      db,
      imports,
      roots: () => roots,
      maxFileBytes: () => 50 * MB,
      quotaBytes: () => 60 * MB,
      minFreeBytes: () => 1 * MB,
      freeBytes: () => Promise.resolve(free),
    });
    const devices = new Devices(db, "secret");
    app = createApp({
      db,
      devices,
      items: new ItemReader(db),
      progress: new ProgressStore(db),
      imports: {
        imports,
        uploads,
        roots: () => roots,
        settings: () => ({
          waitMinutes: 10,
          copyAcrossDrives: false,
          maxFileGb: 0.05,
          quotaGb: 0.06,
        }),
      },
      serverName: "Test",
      version: "0.0.0",
      isScanning: () => false,
    });
  }

  beforeEach(() => {
    dir = makeTempDir("lobby-uploads-");
    db = new Database(join(dir, "lobby.db"));
    lobby = join(dir, "drive", "Lobby");
    roots = [
      { path: join(dir, "drive", "Movies"), name: "Movies", hint: "movies" },
      { path: join(dir, "drive", "Series"), name: "Series", hint: "series" },
    ];
    for (const path of [lobby, ...roots.map((root) => root.path)])
      mkdirSync(path, { recursive: true });
    free = 10_000 * MB;
    imports = new ImportService({
      db,
      folders: [],
      roots: () => roots,
      lobbyDir: lobby,
      driveConnected: () => Promise.resolve(true),
      waitMs: 10 * MINUTE,
      copyAcrossDrives: false,
      matcher: null,
      limits: { minFilmBytes: 1000, minEpisodeBytes: 1000 },
      isOpenElsewhere: () => Promise.resolve(false),
    });
    build();
    const devices = new Devices(db, "secret");
    manager = devices.createLocalManager("Mac").token;
    const made = devices.createLocalManager("Phone");
    db.run("update device set role = 'viewer', access = 'viewer' where id = ?", [made.device.id]);
    viewer = made.token;
  });

  afterEach(async () => {
    await imports.stop();
    uploads.stop();
    db.close();
    removeDir(dir);
  });

  interface Reply {
    status: number;
    body: Record<string, unknown>;
    headers: Headers;
  }

  async function call(
    method: string,
    path: string,
    options: {
      body?: unknown;
      bytes?: Uint8Array;
      headers?: Record<string, string>;
      token?: string;
      peer?: string;
    } = {},
  ): Promise<Reply> {
    const headers: Record<string, string> = {
      Authorization: `Bearer ${options.token ?? manager}`,
      ...options.headers,
    };
    let body: string | Uint8Array | undefined;
    if (options.bytes) {
      body = options.bytes;
      headers["Content-Length"] ??= String(options.bytes.length);
    } else if (options.body !== undefined) {
      body = JSON.stringify(options.body);
      headers["Content-Type"] = "application/json";
    }
    const env =
      options.peer === undefined
        ? undefined
        : { incoming: { socket: { remoteAddress: options.peer } } };
    const response = await app.request(
      `http://127.0.0.1${path}`,
      { method, headers, ...(body === undefined ? {} : { body }) },
      env,
    );
    const text = await response.text();
    return {
      status: response.status,
      body: text === "" ? {} : (JSON.parse(text) as Record<string, unknown>),
      headers: response.headers,
    };
  }

  const sha = (bytes: Uint8Array, encoding: "hex" | "base64" = "hex"): string =>
    createHash("sha256").update(bytes).digest(encoding);

  function film(name = "Upload (2019).mkv"): Buffer {
    const path = join(dir, "phone", name);
    makeVideo(path, { seconds: 3 });
    return readFileSync(path);
  }

  async function create(bytes: Uint8Array, more: Record<string, unknown> = {}): Promise<string> {
    const reply = await call("POST", "/v1/uploads", {
      body: {
        relPath: "Upload (2019).mkv",
        sizeBytes: bytes.length,
        destination: { kind: "movies" },
        ...more,
      },
    });
    expect(reply.status).toBe(201);
    return (reply.body["upload"] as { id: string }).id;
  }

  const piece = (
    id: string,
    bytes: Uint8Array,
    from: number,
    to: number,
    checksum = true,
  ): Promise<Reply> =>
    call("PATCH", `/v1/uploads/${id}`, {
      bytes: bytes.subarray(from, to),
      headers: {
        "Upload-Offset": String(from),
        ...(checksum
          ? { "Upload-Checksum": `sha256 ${sha(bytes.subarray(from, to), "base64")}` }
          : {}),
      },
    });

  it("receives a file in pieces, proves it, and puts it in the Inbox for a title", async () => {
    const bytes = film();
    const id = await create(bytes);
    const half = Math.floor(bytes.length / 2);
    expect((await piece(id, bytes, 0, half)).headers.get("Upload-Offset")).toBe(String(half));
    expect((await call("HEAD", `/v1/uploads/${id}`)).headers.get("Upload-Offset")).toBe(
      String(half),
    );
    expect((await piece(id, bytes, half, bytes.length)).status).toBe(204);
    const done = await call("POST", `/v1/uploads/${id}/complete`, { body: { sha256: sha(bytes) } });
    expect(done.status).toBe(200);
    const upload = done.body["upload"] as { state: string; itemId: string };
    expect(upload.state).toBe("done");

    // No TMDB key here: it waits for a manager, then goes where it was sent.
    const item = (await call("GET", `/v1/imports/items/${upload.itemId}`)).body[
      "item"
    ] as ApiImportItem;
    expect(item).toMatchObject({ origin: "upload", state: "inbox", title: "Upload", year: 2019 });
    const confirmed = await call("POST", `/v1/imports/items/${item.id}/confirm`, {
      body: { action: "move", kind: "movie", title: "Upload", year: 2019 },
    });
    expect((confirmed.body["item"] as ApiImportItem).state).toBe("imported");
    const placed = join(roots[0]?.path ?? "", "Upload (2019)", "Upload (2019).mkv");
    expect(readFileSync(placed).equals(bytes)).toBe(true);
    // Lobby's staging is empty again.
    expect(readdirSync(join(lobby, "uploads"))).toEqual([]);
  });

  it("refuses a piece at the wrong place, or one that arrived damaged, and says where to go on", async () => {
    const bytes = film();
    const id = await create(bytes);
    const skip = await piece(id, bytes, 100, 200);
    expect(skip.status).toBe(409);
    expect(skip.body["offset"]).toBe(0);

    const damaged = await call("PATCH", `/v1/uploads/${id}`, {
      bytes: bytes.subarray(0, 1000),
      headers: {
        "Upload-Offset": "0",
        "Upload-Checksum": `sha256 ${sha(Buffer.from("other"), "base64")}`,
      },
    });
    expect(damaged.status).toBe(409);
    expect(damaged.body["offset"]).toBe(0);
    expect((await call("GET", `/v1/uploads/${id}`)).body["offset"]).toBe(0);
  });

  it("goes on where it stopped after a piece was cut off, and after the server started again", async () => {
    const bytes = film();
    const id = await create(bytes);
    // A piece that says it is longer than what arrives: the connection broke.
    expect((await piece(id, bytes, 0, 5000)).status).toBe(204);
    const cut = await call("PATCH", `/v1/uploads/${id}`, {
      bytes: bytes.subarray(5000, 8000),
      headers: { "Upload-Offset": "5000", "Content-Length": "9000" },
    });
    // What arrived of a piece that was cut off is not kept: it goes on from where the last whole one ended.
    expect(cut.status).toBe(409);
    expect(cut.body["offset"]).toBe(5000);
    const third = Math.floor(bytes.length / 3);
    expect((await piece(id, bytes, 5000, third)).status).toBe(204);

    // The server starts again: what arrived is on the drive, the running hash is not.
    uploads.stop();
    build();
    const where = await call("HEAD", `/v1/uploads/${id}`);
    expect(where.headers.get("Upload-Offset")).toBe(String(third));
    expect((await piece(id, bytes, third, bytes.length, false)).status).toBe(204);
    const done = await call("POST", `/v1/uploads/${id}/complete`, { body: { sha256: sha(bytes) } });
    expect(done.status).toBe(202);
    for (let tries = 0; tries < 100; tries += 1) {
      const now = (await call("GET", `/v1/uploads/${id}`)).body["upload"] as { state: string };
      if (now.state === "done") break;
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    expect(
      ((await call("GET", `/v1/uploads/${id}`)).body["upload"] as { state: string }).state,
    ).toBe("done");
  });

  it("starts over when the whole file does not match its hash", async () => {
    const bytes = film();
    const id = await create(bytes);
    const changed = Buffer.from(bytes);
    changed[changed.length - 1] = (changed[changed.length - 1] ?? 0) ^ 0xff;
    expect((await piece(id, changed, 0, changed.length)).status).toBe(204);
    const done = await call("POST", `/v1/uploads/${id}/complete`, { body: { sha256: sha(bytes) } });
    expect((done.body["upload"] as { state: string; reason: string }).state).toBe("receiving");
    expect((await call("GET", `/v1/uploads/${id}`)).body["offset"]).toBe(0);
  });

  it("refuses what is too large, beyond the room, without space, for viewers and from far away", async () => {
    const big = await call("POST", "/v1/uploads", {
      body: { relPath: "Big (2000).mkv", sizeBytes: 51 * MB, destination: { kind: "movies" } },
    });
    expect(big.status).toBe(400);
    await call("POST", "/v1/uploads", {
      body: { relPath: "A (2000).mkv", sizeBytes: 40 * MB, destination: { kind: "movies" } },
    });
    const full = await call("POST", "/v1/uploads", {
      body: { relPath: "B (2000).mkv", sizeBytes: 30 * MB, destination: { kind: "movies" } },
    });
    expect(full.status).toBe(409);
    free = 45 * MB;
    const space = await call("POST", "/v1/uploads", {
      body: { relPath: "C (2000).mkv", sizeBytes: 10 * MB, destination: { kind: "movies" } },
    });
    expect((space.body["error"] as { message: string }).message).toBe(
      "There is not enough free space on the drive for this file.",
    );
    const odd = await call("POST", "/v1/uploads", {
      body: { relPath: "../x.mkv", sizeBytes: 10, destination: { kind: "movies" } },
    });
    expect(odd.status).toBe(400);
    const text = await call("POST", "/v1/uploads", {
      body: { relPath: "notes.txt", sizeBytes: 10, destination: { kind: "movies" } },
    });
    expect(text.status).toBe(400);
    const nowhere = await call("POST", "/v1/uploads", {
      body: { relPath: "D.mkv", sizeBytes: 10, destination: { kind: "folder", path: "/etc" } },
    });
    expect(nowhere.status).toBe(400);
    expect((await call("POST", "/v1/uploads", { token: viewer, body: {} })).status).toBe(403);
    expect((await call("GET", "/v1/imports", { peer: "203.0.113.9" })).status).toBe(403);
    expect((await call("GET", "/v1/imports", { peer: "100.101.102.103" })).status).toBe(200);
  });

  it("sends an episode to the series folder, with a subtitle that came first", async () => {
    const bytes = film("Show S01E02.mkv");
    const subtitle = Buffer.from("1\n00:00:01,000 --> 00:00:02,000\nHi\n");
    const sub = await call("POST", "/v1/uploads", {
      body: {
        relPath: "Show/Show S01E02.en.srt",
        sizeBytes: subtitle.length,
        destination: { kind: "series" },
        batch: "b1",
      },
    });
    const subId = (sub.body["upload"] as { id: string }).id;
    await piece(subId, subtitle, 0, subtitle.length);
    await call("POST", `/v1/uploads/${subId}/complete`, { body: { sha256: sha(subtitle) } });
    const video = await call("POST", "/v1/uploads", {
      body: {
        relPath: "Show/Show S01E02.mkv",
        sizeBytes: bytes.length,
        destination: { kind: "series" },
        batch: "b1",
        sha256: sha(bytes),
      },
    });
    const id = (video.body["upload"] as { id: string }).id;
    await piece(id, bytes, 0, bytes.length);
    const done = await call("POST", `/v1/uploads/${id}/complete`, { body: {} });
    const itemId = (done.body["upload"] as { itemId: string }).itemId;
    const item = (await call("GET", `/v1/imports/items/${itemId}`)).body["item"] as ApiImportItem;
    expect(item).toMatchObject({ kind: "episode", title: "Show", season: 1, episode: 2 });
    await call("POST", `/v1/imports/items/${itemId}/confirm`, {
      body: { kind: "episode", title: "Show", season: 1, episode: 2 },
    });
    const season = join(roots[1]?.path ?? "", "Show", "Season 01");
    expect(readdirSync(season).sort()).toEqual(["Show - S01E02.en.srt", "Show - S01E02.mkv"]);
    expect(statSync(join(season, "Show - S01E02.mkv")).size).toBe(bytes.length);
  });

  it("cancels an upload and removes what arrived", async () => {
    const bytes = film();
    const id = await create(bytes);
    await piece(id, bytes, 0, 1000);
    expect(
      ((await call("DELETE", `/v1/uploads/${id}`)).body["upload"] as { state: string }).state,
    ).toBe("cancelled");
    expect(readdirSync(join(lobby, "uploads", id))).toEqual([]);
    expect((await piece(id, bytes, 1000, 2000)).status).toBe(409);
  });
});
