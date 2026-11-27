// SPDX-License-Identifier: MPL-2.0
import {
  mkdirSync,
  renameSync,
  rmSync,
  symlinkSync,
  utimesSync,
  writeFileSync,
  readFileSync,
  statSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ApiAlbum, ApiArtist, ApiBook, ApiTrack } from "../src/music/reader.ts";
import { loadConfig } from "../src/config.ts";
import { Catalogue } from "../src/library/catalogue.ts";
import { Scanner } from "../src/library/scanner.ts";
import { makeAudio, makePicture, setUpMusic, type MusicFixture } from "./support/audio.ts";
import { makeVideo } from "./support/media.ts";

let f: MusicFixture;
beforeEach(async () => {
  f = await setUpMusic();
});
afterEach(async () => {
  await f.close();
});

interface All {
  artists: ApiArtist[];
  albums: ApiAlbum[];
  tracks: ApiTrack[];
  books: ApiBook[];
  removed: string[];
  cursor: string;
  more: boolean;
  reset: boolean;
}
async function all(cursor = ""): Promise<All> {
  const reply = await f.call<All>("GET", `/v1/music/library?limit=1000&cursor=${cursor}`);
  expect(reply.status).toBe(200);
  return reply.body;
}
const queen = (title: string, track: number, more: Record<string, string> = {}) => ({
  tags: {
    title,
    artist: "Queen",
    album: "Opera",
    album_artist: "Queen",
    track: String(track),
    ...more,
  },
  tone: 300 + track * 10,
});
const album = (name: string): string => join(f.music, "Queen", name);

describe("audio scanner", () => {
  it("makes artists, albums and tracks from tags", async () => {
    makeAudio(join(album("Opera"), "01.mp3"), queen("One", 1, { date: "1975", genre: "Rock" }));
    makeAudio(join(album("Opera"), "02.flac"), {
      ...queen("Two", 2, { REPLAYGAIN_TRACK_GAIN: "-6.5 dB", artist: "Queen feat. David Bowie" }),
    });
    await f.scan();
    const { artists, albums, tracks } = await all();
    expect(artists.map((one) => one.name).sort()).toEqual(["David Bowie", "Queen"]);
    expect(albums).toMatchObject([
      {
        title: "Opera",
        artistCredit: "Queen",
        trackCount: 2,
        discCount: 1,
        year: 1975,
        genres: ["Rock"],
        compilation: false,
      },
    ]);
    expect(albums[0]?.artistIds).toEqual([artists.find((one) => one.name === "Queen")?.id]);
    const two = tracks.find((one) => one.title === "Two");
    expect(two).toMatchObject({
      albumId: albums[0]?.id,
      track: 2,
      artistCredit: "Queen feat. David Bowie",
      available: true,
      replayGain: { trackGainDb: -6.5 },
      file: {
        container: "flac",
        codec: "flac",
        lossless: true,
        playability: "direct",
        compact: [256, 128],
      },
    });
    expect(two?.artistIds).toHaveLength(2);
  });

  it("says what plays directly and what has to be converted", async () => {
    const formats: [string, string[], string][] = [
      ["a.mp3", [], "direct"],
      ["a.m4a", ["-c:a", "alac"], "direct"],
      ["b.m4a", ["-c:a", "aac"], "direct"],
      ["a.wav", [], "direct"],
      ["a.ogg", ["-c:a", "flac"], "convert"],
      ["a.opus", [], "convert"],
      ["a.wma", [], "convert"],
      ["a.wv", [], "convert"],
      ["a.mka", ["-c:a", "mp3"], "convert"],
    ];
    for (const [name, codec] of formats)
      makeAudio(join(f.music, name), { codec, tags: { title: name, artist: "X" } });
    await f.scan();
    const { tracks } = await all();
    expect(Object.fromEntries(tracks.map((one) => [one.title, one.file.playability]))).toEqual(
      Object.fromEntries(formats.map(([name, , expected]) => [name, expected])),
    );
    // Ogg's tags are on its stream.
    expect(tracks.find((one) => one.title === "a.opus")?.artistCredit).toBe("X");
  });

  it("reads files without tags from their path, and compilations as one album", async () => {
    makeAudio(join(f.music, "ABBA/Arrival/01 - My Love.mp3"), {});
    makeAudio(join(f.music, "Hits/01.mp3"), { tags: { title: "A", artist: "X", album: "Now 1" } });
    makeAudio(join(f.music, "Hits/02.mp3"), {
      tags: { title: "B", artist: "Y", album: "Now 1" },
      tone: 500,
    });
    makeAudio(join(f.music, "X/c.mp3"), {
      tags: { title: "C", artist: "X", album: "Mix", compilation: "1" },
      tone: 510,
    });
    makeAudio(join(f.music, "Y/d.mp3"), {
      tags: { title: "D", artist: "Y", album: "Mix", compilation: "1" },
      tone: 520,
    });
    await f.scan();
    const { albums } = await all();
    expect(
      albums.map((one) => [one.title, one.artistCredit, one.compilation, one.trackCount]).sort(),
    ).toEqual([
      ["Arrival", "ABBA", false, 1],
      ["Mix", "Various Artists", true, 2],
      ["Now 1", "Various Artists", true, 2],
    ]);
  });

  it("puts disc folders in one album and keeps albums of the same name apart", async () => {
    makeAudio(join(album("Live"), "CD1/01.mp3"), queen("A", 1, { album: "Live" }));
    makeAudio(join(album("Live"), "CD2/01.mp3"), queen("B", 2, { album: "Live", track: "1" }));
    makeAudio(join(album("Live again"), "01.mp3"), queen("C", 3, { album: "Live" }));
    await f.scan();
    const { albums, tracks } = await all();
    expect(albums.map((one) => [one.title, one.discCount]).sort()).toEqual([
      ["Live", 1],
      ["Live", 2],
    ]);
    expect(tracks.find((one) => one.title === "B")?.disc).toBe(2);
  });

  it("makes books with chapters, from one file or several", async () => {
    makeAudio(join(f.books, "Milne/Pooh.m4b"), {
      seconds: 2,
      tags: { title: "Pooh", album: "Pooh", artist: "A. A. Milne", composer: "A Reader" },
      codec: ["-c:a", "aac"],
      chapters: [
        { title: "Bees", startMs: 0, endMs: 1000 },
        { title: "Rabbit", startMs: 1000, endMs: 2000 },
      ],
    });
    makeAudio(join(f.books, "Dahl/Matilda/01 - Start.mp3"), { tone: 600 });
    makeAudio(join(f.books, "Dahl/Matilda/02 - End.mp3"), { tone: 610 });
    makeAudio(join(f.books, "Stories/Dad tells one.mp3"), { tone: 620 });
    await f.scan();
    const { books, artists, albums, tracks } = await all();
    expect(artists).toEqual([]);
    expect(albums).toEqual([]);
    expect(tracks.every((one) => one.bookId !== null)).toBe(true);
    const pooh = books.find((one) => one.title === "Pooh");
    expect(pooh).toMatchObject({ authors: ["A. A. Milne"], narrators: ["A Reader"] });
    expect(pooh?.chapters.map((one) => [one.title, one.startMs])).toEqual([
      ["Bees", 0],
      ["Rabbit", 1000],
    ]);
    const matilda = books.find((one) => one.title === "Matilda");
    expect(matilda?.authors).toEqual(["Dahl"]);
    expect(matilda?.chapters.map((one) => one.title)).toEqual(["Start", "End"]);
    expect(matilda?.parts[1]?.startMs).toBe(matilda?.parts[0]?.durationMs);
    expect(books.map((one) => one.title)).toContain("Dad tells one");
  });

  it("syncs only what changed, with tombstones", async () => {
    makeAudio(join(album("Opera"), "01.mp3"), queen("One", 1));
    makeAudio(join(f.music, "Gone/01.mp3"), {
      tags: { title: "G", artist: "Gone", album: "Gone" },
    });
    await f.scan();
    const first = await all();
    expect((await all(first.cursor)).tracks).toEqual([]);
    await f.scan();
    expect(await all(first.cursor)).toMatchObject({
      artists: [],
      albums: [],
      tracks: [],
      removed: [],
      cursor: first.cursor,
    });

    rmSync(join(f.music, "Gone"), { recursive: true });
    await f.scan();
    const missing = await all(first.cursor);
    expect(missing.tracks).toMatchObject([{ title: "G", available: false }]);
    f.clock.now += 31 * 24 * 3_600_000;
    await f.scan();
    const removed = await all(missing.cursor);
    const gone = first.tracks.find((one) => one.title === "G");
    expect(removed.removed.sort()).toEqual([gone?.id, gone?.albumId, gone?.artistIds[0]].sort());
    expect((await all()).removed).toEqual([]);

    // In pages of one the whole library arrives, once.
    let cursor = "";
    const seen: string[] = [];
    for (let more = true; more;) {
      const page = (await f.call<All>("GET", `/v1/music/library?limit=1&cursor=${cursor}`)).body;
      seen.push(...[...page.artists, ...page.albums, ...page.tracks].map((one) => one.id));
      ({ cursor, more } = page);
    }
    expect(seen).toHaveLength(3);
    expect(new Set(seen).size).toBe(3);
    expect((await all("nonsense")).reset).toBe(true);
    const ahead = Buffer.from(
      JSON.stringify([f.db.getMeta("server_id"), "music", 9999, "x"]),
    ).toString("base64url");
    expect((await all(ahead)).reset).toBe(true);
  });

  it("keeps ids when files move, are tagged again, or both", async () => {
    makeAudio(join(album("Opera"), "01.mp3"), { ...queen("One", 1), seconds: 6 });
    makeAudio(join(album("Opera"), "02.mp3"), { ...queen("Two", 2), seconds: 6.5 });
    await f.scan();
    const before = await all();
    const ids = (all: All): unknown => ({
      albums: all.albums.map((one) => one.id),
      tracks: Object.fromEntries(all.tracks.map((one) => [one.title, one.id])),
    });
    renameSync(album("Opera"), album("A Night at the Opera"));
    await f.scan();
    const moved = await all();
    expect(ids(moved)).toEqual(ids(before));
    expect(moved.tracks.map((one) => one.file.revision).sort()).toEqual(
      before.tracks.map((one) => one.file.revision).sort(),
    );

    // Tagged again in place: the whole album gets another name and keeps its id.
    for (const [index, title] of ["One", "Two"].entries()) {
      makeAudio(join(album("A Night at the Opera"), `0${index + 1}.mp3`), {
        ...queen(title, index + 1, { album: "A Night at the Opera" }),
        seconds: 6 + index / 2,
      });
      utimesSync(join(album("A Night at the Opera"), `0${index + 1}.mp3`), 1, 1000 + index);
    }
    await f.scan();
    const tagged = await all();
    expect(ids(tagged)).toEqual(ids(before));
    expect(tagged.albums[0]?.title).toBe("A Night at the Opera");

    // Tagged again and renamed at once, as tagging tools do.
    rmSync(join(album("A Night at the Opera"), "01.mp3"));
    makeAudio(join(album("A Night at the Opera"), "01 One.mp3"), {
      ...queen("One", 1, { album: "A Night at the Opera", genre: "Opera rock" }),
      seconds: 6,
    });
    await f.scan();
    const renamed = await all();
    expect(ids(renamed)).toEqual(ids(before));
    expect(renamed.tracks.find((one) => one.title === "One")?.file.revision).not.toBe(
      tagged.tracks.find((one) => one.title === "One")?.file.revision,
    );
  });

  it("tells a missing drive from an emptied folder", async () => {
    makeAudio(join(album("Opera"), "01.mp3"), queen("One", 1));
    await f.scan();
    rmSync(join(f.music, "Queen"), { recursive: true });
    f.unplugged.add(f.music);
    await f.scan();
    expect(f.db.get("select available, missing_since from music_track")).toEqual({
      available: 1,
      missing_since: null,
    });
    expect((await all()).tracks[0]?.available).toBe(false);
    f.unplugged.clear();
    await f.scan();
    expect(f.db.get("select available from music_track")).toEqual({ available: 0 });
  });

  it("waits for files to hold still, and leaves broken and foreign ones out", async () => {
    await f.close();
    f = await setUpMusic({ stabilityMs: 1000 });
    const path = join(album("Opera"), "01.mp3");
    makeAudio(path, queen("One", 1));
    mkdirSync(join(f.dir, "outside"));
    makeAudio(join(f.dir, "outside/secret.mp3"), {});
    symlinkSync(join(f.dir, "outside/secret.mp3"), join(f.music, "link.mp3"));
    symlinkSync(join(f.dir, "outside"), join(f.music, "linked"));
    writeFileSync(join(f.music, "broken.mp3"), "this is not sound");
    // Read as a playlist, this would name another file.
    writeFileSync(
      join(f.music, "trick.mp3"),
      `#EXTM3U\n#EXTINF:1,\n${join(f.dir, "outside/secret.mp3")}\n#EXT-X-ENDLIST\n`,
    );
    writeFileSync(join(f.music, "._01.mp3"), "x");
    makeVideo(join(f.music, "clip.mp4"));
    await f.scan();
    expect((await all()).tracks).toEqual([]);
    f.clock.now += 1500;
    await f.scan();
    expect((await all()).tracks.map((one) => one.title)).toEqual(["One"]);
    expect(
      f.db.all("select rel_path from music_track where state = 'failed' order by rel_path"),
    ).toEqual([{ rel_path: "broken.mp3" }, { rel_path: "trick.mp3" }]);
  });

  it("chooses covers beside and inside files, and scales them", async () => {
    const inside = join(f.dir, "inside.png");
    makePicture(inside, "blue");
    makeAudio(join(album("Opera"), "01.mp3"), { ...queen("One", 1), cover: inside });
    await f.scan();
    const embedded = (await all()).albums[0]?.coverId ?? "";
    const get = (id: string, w = 200) => f.call("GET", `/v1/music/covers/${id}?w=${w}`);
    const picture = await get(embedded);
    expect(picture.status).toBe(200);
    expect(picture.headers.get("Content-Type")).toBe("image/jpeg");
    expect(picture.bytes.subarray(0, 2).toString("hex")).toBe("ffd8");

    makePicture(join(album("Opera"), "folder.jpg"), "green");
    makePicture(join(album("Opera"), "cover.jpg"), "red");
    await f.scan();
    const beside = (await all()).albums[0]?.coverId ?? "";
    expect(beside).not.toBe(embedded);
    expect(f.db.get("select rel_path from music_image where id = ?", [beside])).toEqual({
      rel_path: "Queen/Opera/cover.jpg",
    });
    expect((await get(beside)).status).toBe(200);

    // Scaled before, shown with the drive away; another size is not.
    renameSync(f.music, `${f.music}-away`);
    expect((await get(beside)).status).toBe(200);
    expect((await get(beside, 400)).status).toBe(503);
    renameSync(`${f.music}-away`, f.music);

    rmSync(join(album("Opera"), "cover.jpg"));
    writeFileSync(
      join(album("Opera"), "folder.jpg"),
      "#EXTM3U\nnot a picture at all, at all, at all",
    );
    await f.scan();
    const bad = (await all()).albums[0]?.coverId ?? "";
    expect((await get(bad)).status).toBe(404);
    expect((await get("..%2F..%2Flobby.db")).status).toBe(404);
    expect((await get(beside)).status).toBe(404);
    await f.library.covers.tidy();
  });

  it("never opens an indexed path outside its folder, and never writes there", async () => {
    const path = join(album("Opera"), "01.flac");
    makeAudio(path, queen("One", 1));
    await f.scan();
    const before = createHash("sha256").update(readFileSync(path)).digest("hex");
    const track = (await all()).tracks[0];
    await f.call(
      "PATCH",
      `/v1/music/tracks/${track?.id ?? ""}`,
      { revision: 0, set: { title: "Other" } },
      { token: f.manager },
    );
    await f.scan();
    expect(createHash("sha256").update(readFileSync(path)).digest("hex")).toBe(before);

    writeFileSync(join(f.dir, "secret.mp3"), "secret");
    const url = `/v1/music/tracks/${track?.id ?? ""}/content`;
    f.db.run("update music_track set rel_path = '../secret.mp3'");
    expect((await f.call("GET", url)).status).toBe(503);
    const ask = (): Promise<{ status: number; body: { state: string } }> =>
      f.call("POST", `/v1/music/tracks/${track?.id ?? ""}/playback`, { quality: 128 });
    expect((await ask()).status).toBe(202);
    await vi.waitFor(async () => {
      expect((await ask()).body.state).toBe("failed");
    });
    f.db.run("update music_track set rel_path = 'Queen/Opera/01.flac'");
    rmSync(path);
    symlinkSync(join(f.dir, "secret.mp3"), path);
    expect((await f.call("GET", url)).status).toBe(503);
    expect(statSync(join(f.dir, "secret.mp3")).size).toBe(6);
  });
});

describe("audio beside films", () => {
  it("reads the new hints from the config and keeps them out of the films", async () => {
    const write = (roots: unknown, more = {}): string => {
      const path = join(f.dir, "lobby.config.json");
      writeFileSync(path, JSON.stringify({ dataDir: join(f.dir, "data"), roots, ...more }));
      return path;
    };
    const films = join(f.dir, "Films");
    const config = loadConfig(
      write([
        { path: films, hint: "movies" },
        { path: `${f.music}/`, hint: "music" },
        { path: f.books, name: "Stories", hint: "audiobooks" },
      ]),
    );
    expect(config.roots.map((one) => one.path)).toEqual([films]);
    expect(config.music.roots).toEqual([
      { path: f.music, name: "Music", hint: "music" },
      { path: f.books, name: "Stories", hint: "audiobooks" },
    ]);
    expect(() => loadConfig(write([{ path: f.music, hint: "songs" }]))).toThrow(/audiobooks/);
    expect(() =>
      loadConfig(
        write([
          { path: f.music, hint: "music" },
          { path: `${f.music}/Queen`, hint: "music" },
        ]),
      ),
    ).toThrow(/overlap/);
    expect(() =>
      loadConfig(
        write([{ path: f.music, hint: "music" }], { music: { cacheDir: `${f.music}/cache` } }),
      ),
    ).toThrow(/inside a library root/);

    makeAudio(join(album("Opera"), "01.flac"), queen("One", 1));
    makeVideo(join(films, "Up (2009).mp4"));
    makeAudio(join(films, "soundtrack.mp3"), {});
    const scanner = new Scanner(f.db, new Catalogue(f.db), {
      stabilityMs: 0,
      probeConcurrency: 1,
      ffprobePath: "ffprobe",
    });
    scanner.syncSources(config.roots);
    await scanner.scanAll();
    await scanner.processQueue();
    const films1 = (await f.call("GET", "/v1/library")).body;
    const categories = (await f.call("GET", "/v1/categories")).body;
    await f.scan();
    expect((await f.call("GET", "/v1/library")).body).toEqual(films1);
    expect((await f.call("GET", "/v1/categories")).body).toEqual(categories);
    expect((films1["items"] as { title: string }[]).map((one) => one.title)).toEqual(["Up"]);
    const status = await f.call<{ sources: unknown[] }>("GET", "/v1/status", undefined, {
      token: f.manager,
    });
    expect(status.body.sources).toHaveLength(1);
    expect((await all()).tracks.map((one) => one.title)).toEqual(["One"]);
  });
});
