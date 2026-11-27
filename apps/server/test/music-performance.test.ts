// SPDX-License-Identifier: MPL-2.0
import { expect, it } from "vitest";
import { setUpMusic } from "./support/audio.ts";

it("syncs 20,000 tracks without slowing down", async () => {
  const f = await setUpMusic();
  try {
    const { db } = f;
    const tags = JSON.stringify({ title: "T", artists: [], replayGain: null, recordingMbid: null });
    db.transaction(() => {
      const source =
        db.get<{ id: string }>("select id from music_source where hint = 'music'")?.id ?? "";
      const id = (kind: string, n: number): string => `${kind}-${String(n).padStart(6, "0")}`;
      for (let n = 0; n < 1000; n += 1) {
        db.run(
          "insert into music_artist (id, ident_key, name, sort_name, added_at) values (?, ?, ?, ?, 0)",
          [id("artist", n), String(n), `Artist ${n}`, `artist ${n}`],
        );
        db.run("insert into music_change values (?, 'artist', 1, 0)", [id("artist", n)]);
      }
      for (let n = 0; n < 2000; n += 1) {
        db.run("insert into music_album (id, ident_key, title, added_at) values (?, ?, ?, 0)", [
          id("album", n),
          String(n),
          `Album ${n}`,
        ]);
        db.run("insert into music_credit values (?, 0, ?)", [
          id("album", n),
          id("artist", n % 1000),
        ]);
        db.run("insert into music_change values (?, 'album', 1, 0)", [id("album", n)]);
      }
      for (let n = 0; n < 20_000; n += 1) {
        db.run(
          `insert into music_track (id, source_id, rel_path, dir, album_dir, size, mtime_ms, revision, state, first_seen_at, updated_at,
             tags_json, title, album_id, playability) values (?, ?, ?, 'd', 'd', 1, 1, 'r', 'probed', 0, 0, ?, 'T', ?, 'direct')`,
          [id("track", n), source, String(n), tags, id("album", n % 2000)],
        );
        db.run("insert into music_credit values (?, 0, ?)", [
          id("track", n),
          id("artist", n % 1000),
        ]);
        db.run("insert into music_change values (?, 'track', ?, 0)", [
          id("track", n),
          1 + Math.floor(n / 5000),
        ]);
      }
      db.setMeta("music_revision", "4");
    });

    let cursor = "";
    const times: number[] = [];
    const seen = new Set<string>();
    for (let more = true; more;) {
      const started = performance.now();
      const { body } = await f.call<{
        tracks: { id: string }[];
        albums: { id: string }[];
        artists: { id: string }[];
        cursor: string;
        more: boolean;
      }>("GET", `/v1/music/library?cursor=${cursor}`);
      times.push(performance.now() - started);
      for (const one of [...body.tracks, ...body.albums, ...body.artists]) seen.add(one.id);
      ({ cursor, more } = body);
    }
    expect(seen.size).toBe(23_000);
    // A page of 500 takes a few milliseconds; a plan that reads everything takes far longer.
    const middle = [...times].sort((a, b) => a - b)[Math.floor(times.length / 2)] ?? 0;
    expect(middle).toBeLessThan(150);

    // Whatever the machine: no step of a page walks a whole table.
    const plan = (sql: string, params: (string | number)[]): string =>
      db
        .all<{ detail: string }>(`explain query plan ${sql}`, params)
        .map((row) => row.detail)
        .join("\n");
    expect(
      plan(
        "select id from music_change where (revision, id) > (?, ?) and removed <= ? order by revision, id limit 501",
        [0, "", 0],
      ),
    ).toMatch(/^SEARCH music_change USING INDEX music_change_revision/);
    const track = plan(
      `select music_track.* from json_each(?) as wanted cross join music_track on music_track.id = wanted.value
       cross join music_source on music_source.id = music_track.source_id`,
      ["[]"],
    );
    expect(track).toMatch(/SCAN wanted/);
    expect(track).not.toMatch(/SCAN music_/);
    const credit = plan(
      `select 1 from json_each(?) as wanted cross join music_credit on music_credit.owner_id = wanted.value
       cross join music_artist on music_artist.id = music_credit.artist_id`,
      ["[]"],
    );
    expect(credit).not.toMatch(/SCAN music_/);

    // Nothing changed: the answer does not depend on the size of the library.
    const started = performance.now();
    expect(
      (await f.call<{ tracks: unknown[] }>("GET", `/v1/music/library?cursor=${cursor}`)).body
        .tracks,
    ).toEqual([]);
    expect(performance.now() - started).toBeLessThan(150);
    console.info(
      `20,000 tracks: page ${middle.toFixed(1)} ms, slowest ${Math.max(...times).toFixed(1)} ms`,
    );
  } finally {
    await f.close();
  }
});
