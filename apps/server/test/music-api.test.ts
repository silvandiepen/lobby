// SPDX-License-Identifier: MPL-2.0
import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { ApiAlbum, ApiArtist, ApiBook, ApiTrack } from "../src/music/reader.ts";
import type { Playlist } from "../src/music/viewers.ts";
import { makeAudio, setUpMusic, type MusicFixture } from "./support/audio.ts";

let f: MusicFixture;
let tracks: ApiTrack[];
let albums: ApiAlbum[];
let artists: ApiArtist[];
let books: ApiBook[];

async function load(): Promise<void> {
  const reply = await f.call<{
    tracks: ApiTrack[];
    albums: ApiAlbum[];
    artists: ApiArtist[];
    books: ApiBook[];
  }>("GET", "/v1/music/library");
  ({ tracks, albums, artists, books } = reply.body);
  tracks.sort((a, b) => (a.title < b.title ? -1 : 1));
}
const track = (title: string): ApiTrack => {
  const found = tracks.find((one) => one.title === title);
  if (!found) throw new Error(`no track ${title}`);
  return found;
};

beforeEach(async () => {
  f = await setUpMusic();
  const tags = { artist: "Queen", album: "Opera", album_artist: "Queen" };
  makeAudio(join(f.music, "Queen/Opera/1.flac"), {
    tags: { ...tags, title: "A", track: "1" },
    seconds: 2,
  });
  makeAudio(join(f.music, "Queen/Opera/2.opus"), {
    tags: { ...tags, title: "B", track: "2" },
    seconds: 2,
    tone: 500,
  });
  makeAudio(join(f.music, "Queen/Opera/3.mp3"), {
    tags: { ...tags, title: "C", track: "3" },
    tone: 600,
    codec: ["-b:a", "64k"],
  });
  makeAudio(join(f.books, "Dahl/Matilda/01 - Start.mp3"), { tone: 700 });
  await f.scan();
  await load();
});
afterEach(async () => {
  await f.close();
});

interface PlaybackReply {
  state: string;
  mode: string;
  url: string | null;
  bytes: number;
  kbps: number | null;
}
async function prepared(id: string, body: Record<string, unknown>): Promise<PlaybackReply> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const reply = await f.call<PlaybackReply>("POST", `/v1/music/tracks/${id}/playback`, body);
    if (reply.status !== 202) return reply.body;
    await new Promise((done) => setTimeout(done, 100));
  }
  throw new Error("never ready");
}

describe("authorisation", () => {
  it("asks for a paired device everywhere, and a manager for edits and status", async () => {
    const t = track("A").id;
    const p = `/v1/music/profiles/${f.profile}`;
    const open: [string, string][] = [
      ["GET", "/v1/music/library"],
      ["GET", `/v1/music/artists/${artists[0]?.id ?? ""}`],
      ["GET", `/v1/music/albums/${albums[0]?.id ?? ""}`],
      ["GET", `/v1/music/tracks/${t}`],
      ["GET", `/v1/music/books/${books[0]?.id ?? ""}`],
      ["GET", `/v1/music/tracks/${t}/content`],
      ["GET", `${p}/favourites`],
      ["GET", `${p}/playlists`],
      ["GET", `${p}/plays`],
      ["GET", `${p}/play-counts`],
      ["GET", `${p}/progress`],
      ["DELETE", `${p}/plays`],
    ];
    const bodies: [string, string][] = [
      ["POST", `/v1/music/tracks/${t}/playback`],
      ["GET", `/v1/music/covers/${"0".repeat(32)}`],
      ["GET", `/v1/music/tracks/${t}/copies/x/128.m4a`],
      ["PUT", `${p}/favourites/${t}`],
      ["POST", `${p}/playlists`],
      ["GET", `${p}/playlists/x`],
      ["PATCH", `${p}/playlists/x`],
      ["DELETE", `${p}/playlists/x`],
      ["POST", `${p}/playlists/x/tracks`],
      ["GET", `${p}/playlists/x/export.m3u8`],
      ["POST", `${p}/plays`],
      ["PUT", `${p}/progress/${t}`],
    ];
    const managers: [string, string][] = [["GET", "/v1/music/status"]];
    for (const kind of ["artists", "albums", "tracks", "books"]) {
      managers.push(["GET", `/v1/music/${kind}/${t}/edit`], ["PATCH", `/v1/music/${kind}/${t}`]);
    }
    for (const [method, path] of [...open, ...bodies, ...managers]) {
      const none = await f.call(method, path, undefined, { token: null });
      expect([path, none.status]).toEqual([path, 401]);
      const wrong = await f.call(method, path, undefined, { token: "nonsense" });
      expect([path, wrong.status]).toEqual([path, 401]);
    }
    for (const [method, path] of open) {
      expect([path, (await f.call(method, path)).status]).toEqual([
        path,
        method === "DELETE" ? 204 : 200,
      ]);
    }
    for (const [method, path] of managers) {
      const body = method === "PATCH" ? { revision: 0, set: { title: "X" } } : undefined;
      expect([path, (await f.call(method, path, body)).status]).toEqual([path, 403]);
    }
    expect(
      (await f.call("GET", "/v1/music/status", undefined, { token: f.manager })).body,
    ).toMatchObject({
      items: { artists: 1, albums: 1, tracks: 4, books: 1 },
      files: { total: 4, waiting: 0, failed: 0 },
    });
    for (const path of ["favourites", "playlists", "plays", "progress"]) {
      expect((await f.call("GET", `/v1/music/profiles/nobody/${path}`)).status).toBe(404);
    }
  });
});

describe("sound", () => {
  it("serves originals with ranges", async () => {
    const one = track("A");
    const url = `/v1/music/tracks/${one.id}/content`;
    const file = readFileSync(join(f.music, "Queen/Opera/1.flac"));
    const whole = await f.call("GET", url);
    expect(whole.bytes.equals(file)).toBe(true);
    expect(whole.headers.get("Content-Type")).toBe("audio/flac");
    expect(whole.headers.get("ETag")).toBe(`"${one.file.revision}"`);
    const part = await f.call("GET", url, undefined, {
      headers: { Range: "bytes=10-19", "If-Range": `"${one.file.revision}"` },
    });
    expect(part.status).toBe(206);
    expect(part.bytes.equals(file.subarray(10, 20))).toBe(true);
    expect(part.headers.get("Content-Range")).toBe(`bytes 10-19/${file.length}`);
    const stale = await f.call("GET", url, undefined, {
      headers: { Range: "bytes=10-19", "If-Range": '"old"' },
    });
    expect(stale.status).toBe(200);
    const beyond = await f.call("GET", url, undefined, { headers: { Range: "bytes=99999999-" } });
    expect(beyond.status).toBe(416);
    expect(beyond.headers.get("Content-Range")).toBe(`bytes */${file.length}`);
    expect((await f.call("HEAD", url)).bytes).toHaveLength(0);
    expect((await f.call("GET", "/v1/music/tracks/nothing/content")).status).toBe(404);
    f.db.run("update music_source set available = 0");
    expect((await f.call("GET", url)).status).toBe(503);
  });

  it("sends what plays as it is, and makes compact copies of the rest", async () => {
    expect(await prepared(track("A").id, { quality: "original" })).toMatchObject({
      mode: "direct",
      state: "ready",
    });
    // 64 kbit/s already: nothing to gain.
    expect(await prepared(track("C").id, { quality: 128 })).toMatchObject({ mode: "direct" });
    expect(track("C").file.compact).toEqual([]);

    const opus = await prepared(track("B").id, {});
    expect(opus).toMatchObject({ mode: "copy", kbps: 256, state: "ready" });
    const compact = await prepared(track("A").id, { quality: 128, purpose: "download" });
    const file = await f.call("GET", compact.url ?? "");
    expect(file.status).toBe(200);
    expect(file.bytes).toHaveLength(compact.bytes);
    expect(file.headers.get("Content-Type")).toBe("audio/mp4");
    const part = await f.call("GET", compact.url ?? "", undefined, {
      headers: { Range: "bytes=0-7" },
    });
    expect(part.status).toBe(206);
    expect(part.bytes.toString("latin1", 4, 8)).toBe("ftyp");
    expect(
      (await f.call("GET", compact.url ?? "", undefined, { headers: { Range: "bytes=99999999-" } }))
        .status,
    ).toBe(416);
    // The index is in front of the sound, so a player needs no second look.
    expect(file.bytes.indexOf("moov")).toBeLessThan(file.bytes.indexOf("mdat"));
    const path = join(f.dir, "copy.m4a");
    writeFileSync(path, file.bytes);
    const probe = execFileSync("ffprobe", [
      "-v",
      "error",
      "-show_entries",
      "stream=codec_name:format=duration",
      "-of",
      "csv=p=0",
      path,
    ]).toString();
    expect(probe).toContain("aac");
    expect(Number(probe.trim().split("\n").at(-1))).toBeCloseTo(2, 1);

    for (const bad of ["64.m4a", "..%2F..%2Flobby.db", "128.m4a.part"]) {
      expect(
        (
          await f.call(
            "GET",
            `/v1/music/tracks/${track("A").id}/copies/${track("A").file.revision}/${bad}`,
          )
        ).status,
      ).toBe(404);
    }
    expect(
      (await f.call("POST", `/v1/music/tracks/${track("A").id}/playback`, { quality: 64 })).status,
    ).toBe(400);
    expect((await f.call("POST", "/v1/music/tracks/none/playback", {})).status).toBe(404);
    expect(readdirSync(join(f.dir, "cache")).filter((name) => name.endsWith(".part"))).toEqual([]);

    // A copy that exists plays on without the drive; one that does not cannot be made.
    f.db.run("update music_source set available = 0");
    expect(
      (await f.call<PlaybackReply>("POST", `/v1/music/tracks/${track("B").id}/playback`, {})).body
        .state,
    ).toBe("ready");
    expect(
      (await f.call("POST", `/v1/music/tracks/${track("B").id}/playback`, { quality: 128 })).status,
    ).toBe(503);
  });

  it("keeps its cache within its limit, oldest first, and picks it up after a restart", async () => {
    await f.close();
    // Room for one copy of two seconds (about 100 KB with its index), not two.
    f = await setUpMusic({ maxCacheGb: 150_000 / 1024 ** 3 });
    for (const title of ["A", "B"]) {
      makeAudio(join(f.music, `${title}.flac`), {
        tags: { title },
        seconds: 2,
        tone: title === "A" ? 400 : 450,
      });
    }
    makeAudio(join(f.music, "L.flac"), { tags: { title: "L" }, seconds: 60 });
    await f.scan();
    await load();
    const first = await prepared(track("A").id, { quality: 128 });
    // Just used, so it stays and the next one has to wait.
    expect((await prepared(track("B").id, { quality: 128 })).state).toBe("does_not_fit");
    f.clock.now += 10 * 60_000;
    expect((await prepared(track("B").id, { quality: 128 })).state).toBe("ready");
    expect((await f.call("GET", first.url ?? "")).status).toBe(404);
    expect((await prepared(track("L").id, { quality: 256 })).state).toBe("does_not_fit");
    writeFileSync(join(f.dir, "cache", "half.m4a.part"), "x");
    writeFileSync(join(f.dir, "cache", "unknown.txt"), "not ours");
    await f.library.copies.start();
    expect(f.library.copies.totalBytes()).toBeGreaterThan(0);
    expect(readdirSync(join(f.dir, "cache"))).toHaveLength(2);
  });
});

describe("viewers", () => {
  const p = (profile = f.profile): string => `/v1/music/profiles/${profile}`;

  it("keeps favourites per viewer; the later change wins", async () => {
    const id = albums[0]?.id ?? "";
    const put = (favourite: boolean, updatedAt: number) =>
      f.call("PUT", `${p()}/favourites/${id}`, { favourite, updatedAt });
    expect((await put(true, 1000)).body).toEqual({
      favourite: { itemId: id, kind: "album", favourite: true, updatedAt: 1000 },
    });
    expect((await put(true, 1000)).status).toBe(200);
    const late = await put(false, 500);
    expect(late.status).toBe(409);
    expect(late.body["favourite"]).toMatchObject({ favourite: true });
    const list = await f.call<{ favourites: unknown[]; revision: number }>(
      "GET",
      `${p()}/favourites`,
    );
    expect(list.body.favourites).toHaveLength(1);
    expect(
      (await f.call<{ favourites: unknown[] }>("GET", `${p(f.other)}/favourites`)).body.favourites,
    ).toEqual([]);
    // A clock that runs ahead cannot win forever.
    await put(false, f.clock.now + 1e9);
    f.clock.now += 1000;
    expect((await put(true, f.clock.now)).status).toBe(200);
    const since = await f.call<{ favourites: unknown[] }>(
      "GET",
      `${p()}/favourites?since=${list.body.revision}`,
    );
    expect(since.body.favourites).toMatchObject([{ favourite: true }]);
    expect(
      (await f.call("PUT", `${p()}/favourites/none`, { favourite: true, updatedAt: 1 })).status,
    ).toBe(404);
    expect(
      (await f.call("PUT", `${p()}/favourites/${id}`, { favourite: 1, updatedAt: 1 })).status,
    ).toBe(400);
  });

  it("keeps ordered playlists without losing anyone's change", async () => {
    const [a, b, c] = ["A", "B", "C"].map((title) => track(title).id) as [string, string, string];
    const id = randomUUID();
    interface One {
      playlist: Playlist;
    }
    const made = await f.call<One>("POST", `${p()}/playlists`, {
      id,
      name: "Car",
      trackIds: [c, a, c],
    });
    expect(made.status).toBe(201);
    expect(made.body.playlist).toMatchObject({ name: "Car", trackIds: [c, a, c], revision: 1 });
    // The answer got lost and the device asks again.
    expect(
      (await f.call<One>("POST", `${p()}/playlists`, { id, name: "Car", trackIds: [] })).body
        .playlist.trackIds,
    ).toEqual([c, a, c]);

    const moved = await f.call<One>("PATCH", `${p()}/playlists/${id}`, {
      revision: 1,
      trackIds: [a, c, c],
    });
    expect(moved.body.playlist).toMatchObject({ trackIds: [a, c, c], revision: 2 });
    expect(
      (await f.call("PATCH", `${p()}/playlists/${id}`, { revision: 1, trackIds: [a, c, c] }))
        .status,
    ).toBe(200);
    const stale = await f.call<One>("PATCH", `${p()}/playlists/${id}`, {
      revision: 1,
      trackIds: [b],
    });
    expect(stale.status).toBe(409);
    expect(stale.body.playlist.trackIds).toEqual([a, c, c]);

    for (let times = 0; times < 2; times += 1) {
      const added = await f.call<One>("POST", `${p()}/playlists/${id}/tracks`, {
        opId: "op1",
        trackIds: [b],
      });
      expect(added.body.playlist.trackIds).toEqual([a, c, c, b]);
    }
    expect(
      (await f.call("POST", `${p()}/playlists/${id}/tracks`, { opId: "op2", trackIds: ["none"] }))
        .status,
    ).toBe(400);
    expect((await f.call("POST", `${p()}/playlists`, { id: randomUUID(), name: "" })).status).toBe(
      400,
    );

    const m3u = await f.call("GET", `${p()}/playlists/${id}/export.m3u8`);
    expect(m3u.bytes.toString("utf8").split("\n").slice(0, 4)).toEqual([
      "#EXTM3U",
      "#PLAYLIST:Car",
      "#EXTINF:2,Queen - A",
      "Queen/Opera/1.flac",
    ]);
    expect(m3u.headers.get("Content-Disposition")).toContain("Car.m3u8");
    for (const method of ["GET", "PATCH"]) {
      expect(
        (
          await f.call(
            method,
            `${p(f.other)}/playlists/${id}`,
            method === "PATCH" ? { revision: 3, name: "x" } : undefined,
          )
        ).status,
      ).toBe(404);
    }

    const sync = await f.call<{ playlists: Playlist[]; revision: number }>(
      "GET",
      `${p()}/playlists`,
    );
    expect((await f.call("DELETE", `${p()}/playlists/${id}?revision=1`)).status).toBe(409);
    expect((await f.call("DELETE", `${p()}/playlists/${id}?revision=3`)).status).toBe(204);
    expect((await f.call("DELETE", `${p()}/playlists/${id}?revision=3`)).status).toBe(204);
    expect(
      (await f.call("GET", `${p()}/playlists?since=${sync.body.revision}`)).body,
    ).toMatchObject({ playlists: [], removed: [id] });
  });

  it("drops a forgotten track from playlists and drops a removed viewer's listening", async () => {
    const id = randomUUID();
    const [a, b] = [track("A").id, track("B").id];
    await f.call("POST", `${p()}/playlists`, { id, name: "Mix", trackIds: [a, b, a] });
    f.library.catalogue.removeTrack(a);
    const list = await f.call<{ playlist: Playlist }>("GET", `${p()}/playlists/${id}`);
    expect(list.body.playlist).toMatchObject({ trackIds: [b], revision: 2 });
    await f.call("DELETE", `/v1/profiles/${f.profile}`, undefined, { token: f.manager });
    expect(f.db.all("select id from music_playlist")).toEqual([]);
  });

  it("keeps a history that can be sent twice", async () => {
    const play = (opId: string, title: string, playedAt: number) => ({
      opId,
      trackId: track(title).id,
      playedAt,
      playedMs: 1500,
      completed: true,
    });
    const plays = [
      play("1", "A", 1000),
      play("2", "B", 2000),
      play("3", "A", 3000),
      { ...play("4", "A", 1), trackId: "gone" },
    ];
    for (let times = 0; times < 2; times += 1) {
      expect((await f.call("POST", `${p()}/plays`, { plays })).body).toEqual({
        accepted: 3,
        unknown: 1,
      });
    }
    const first = await f.call<{ plays: { opId: string }[]; next: string }>(
      "GET",
      `${p()}/plays?limit=2`,
    );
    expect(first.body.plays.map((one) => one.opId)).toEqual(["3", "2"]);
    const rest = await f.call<{ plays: { opId: string }[]; next: null }>(
      "GET",
      `${p()}/plays?limit=2&before=${first.body.next}`,
    );
    expect(rest.body).toMatchObject({ plays: [{ opId: "1" }], next: null });
    expect(
      (await f.call<{ counts: unknown[] }>("GET", `${p()}/play-counts`)).body.counts,
    ).toContainEqual({ trackId: track("A").id, plays: 2, lastPlayedAt: 3000 });
    expect((await f.call("POST", `${p()}/plays`, { plays: [{}] })).status).toBe(400);
    expect((await f.call("DELETE", `${p()}/plays`)).status).toBe(204);
    expect((await f.call<{ plays: unknown[] }>("GET", `${p()}/plays`)).body.plays).toEqual([]);
  });

  it("resumes books by the films' rules", async () => {
    const id = books[0]?.id ?? "";
    const put = (
      opId: string,
      baseRevision: number | null,
      positionMs: number,
      updatedAt: number,
    ) =>
      f.call<{ progress: { positionMs: number; revision: number } }>(
        "PUT",
        `${p()}/progress/${id}`,
        { opId, baseRevision, positionMs, durationMs: 1000, completed: false, updatedAt },
      );
    expect((await put("1", null, 400, 2000)).body.progress).toMatchObject({
      positionMs: 400,
      revision: 1,
    });
    expect((await put("1", null, 999, 2000)).body.progress.positionMs).toBe(400);
    expect((await put("2", null, 100, 1000)).status).toBe(409);
    expect((await put("3", 1, 500, 500)).status).toBe(200);
    expect((await f.call("GET", `${p()}/progress?since=1`)).body).toMatchObject({
      progress: [{ positionMs: 500 }],
      revision: 2,
    });
    expect(
      (
        await f.call("PUT", `${p()}/progress/${albums[0]?.id ?? ""}`, {
          opId: "x",
          baseRevision: null,
          positionMs: 0,
          durationMs: null,
          completed: false,
          updatedAt: 1,
        })
      ).status,
    ).toBe(404);
    // Apart from the films' progress.
    expect((await f.call("GET", `/v1/profiles/${f.profile}/progress`)).body).toEqual({
      progress: [],
      revision: 0,
    });
  });
});

describe("editing", () => {
  const patch = (kind: string, id: string, body: unknown) =>
    f.call<{
      revision: number;
      fields: Record<string, { automatic: unknown; overridden: boolean; effective: unknown }>;
    }>("PATCH", `/v1/music/${kind}/${id}`, body, { token: f.manager });

  it("lays changes over the tags, survives rescans and goes back", async () => {
    const id = track("A").id;
    const edited = await patch("tracks", id, {
      revision: 0,
      set: { title: "Alpha", artists: ["Queen", "Guest"], album: "Other" },
    });
    expect(edited.status).toBe(200);
    expect(edited.body).toMatchObject({
      revision: 1,
      fields: {
        title: { automatic: "A", overridden: true, effective: "Alpha" },
        year: { overridden: false },
      },
    });
    f.db.run("update music_track set state = 'discovered'");
    await f.scan();
    await load();
    expect(track("Alpha")).toMatchObject({ artistCredit: "Queen, Guest" });
    expect(artists.map((one) => one.name).sort()).toEqual(["Guest", "Queen"]);
    expect(albums.map((one) => one.title).sort()).toEqual(["Opera", "Other"]);
    expect((await patch("tracks", id, { revision: 0, set: { title: "X" } })).status).toBe(409);
    expect(
      (await patch("tracks", id, { revision: 1, reset: ["title", "artists", "album"] })).status,
    ).toBe(200);
    await load();
    expect(track("A").artistCredit).toBe("Queen");
    expect(artists.map((one) => one.name)).toEqual(["Queen"]);
    expect(albums.map((one) => one.title)).toEqual(["Opera"]);
  });

  it("takes favourites along when an album becomes part of another", async () => {
    const id = track("A").id;
    const opera = albums[0]?.id ?? "";
    await patch("tracks", id, { revision: 0, set: { album: "Other" } });
    await load();
    const other = albums.find((one) => one.title === "Other")?.id ?? "";
    await patch("albums", other, { revision: 0, set: { title: "Another" } });
    const base = `/v1/music/profiles/${f.profile}/favourites`;
    await f.call("PUT", `${base}/${other}`, { favourite: true, updatedAt: 1 });
    await patch("tracks", id, { revision: 1, reset: ["album"] });
    await load();
    expect(albums.map((one) => [one.id, one.title, one.trackCount])).toEqual([[opera, "Opera", 3]]);
    const reply = await f.call<{ favourites: { itemId: string }[] }>("GET", base);
    expect(reply.body.favourites.map((one) => one.itemId)).toEqual([opera]);
  });

  it("edits albums, artists and books", async () => {
    const [album, artist, book] = [albums[0]?.id ?? "", artists[0]?.id ?? "", books[0]?.id ?? ""];
    expect(
      (
        await patch("albums", album, {
          revision: 0,
          set: { title: "The Opera", year: 1975, artists: ["Freddie"] },
        })
      ).status,
    ).toBe(200);
    expect(
      (
        await patch("books", book, {
          revision: 0,
          set: { title: "Matilda!", series: "Dahl", seriesPosition: 1.5, narrators: ["Mum"] },
        })
      ).status,
    ).toBe(200);
    expect(
      (await patch("artists", artist, { revision: 0, set: { name: "Queen (UK)" } })).status,
    ).toBe(200);
    await load();
    expect(albums[0]).toMatchObject({
      title: "The Opera",
      sortTitle: "opera",
      year: 1975,
      artistCredit: "Freddie",
    });
    expect(books[0]).toMatchObject({
      title: "Matilda!",
      series: "Dahl",
      seriesPosition: 1.5,
      narrators: ["Mum"],
    });
    expect(track("A").artistCredit).toBe("Queen (UK)");
    expect(
      (await patch("albums", album, { revision: 1, reset: ["title", "year", "artists"] })).status,
    ).toBe(200);
    await load();
    expect(albums[0]).toMatchObject({ title: "Opera", artistIds: [artist] });
  });

  it("refuses what makes no sense", async () => {
    const id = track("A").id;
    for (const body of [
      {},
      { revision: 0 },
      { revision: 0, set: { title: "" } },
      { revision: 0, set: { title: "a\nb" } },
      { revision: 0, set: { path: "/x" } },
      { revision: 0, set: { year: "1975" } },
      { revision: 0, set: { genres: "x" } },
      { revision: 0, set: { title: "x" }, reset: ["title"] },
      { revision: 0, reset: ["nope"] },
      { revision: "0", set: { title: "x" } },
      { revision: 0, set: null, reset: "title" },
    ]) {
      expect([body, (await patch("tracks", id, body)).status]).toEqual([body, 400]);
    }
    expect((await patch("albums", id, { revision: 0, set: { title: "x" } })).status).toBe(404);
  });
});
