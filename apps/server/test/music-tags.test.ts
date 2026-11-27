// SPDX-License-Identifier: MPL-2.0
import { describe, expect, it } from "vitest";
import { albumDirOf, coverRank, isAudioFile, nameKey, sortKey } from "../src/music/names.ts";
import { canonicalTags, guessFromPath, readTags, splitArtists } from "../src/music/tags.ts";

const read = (tags: Record<string, string>, path = "x.mp3"): ReturnType<typeof readTags> =>
  readTags(canonicalTags(tags), path);

describe("audio tags", () => {
  it("splits artists only where that is certain", () => {
    expect(splitArtists("Queen; David Bowie")).toEqual(["Queen", "David Bowie"]);
    expect(splitArtists("Queen feat. David Bowie")).toEqual(["Queen", "David Bowie"]);
    expect(splitArtists("Queen (ft. David Bowie)")).toEqual(["Queen", "David Bowie"]);
    expect(splitArtists("A / B")).toEqual(["A", "B"]);
    for (const whole of [
      "AC/DC",
      "Simon & Garfunkel",
      "Earth, Wind & Fire",
      "Tyler, The Creator",
    ]) {
      expect(splitArtists(whole)).toEqual([whole]);
    }
  });

  it("prefers the list of artists and keeps the sleeve's wording", () => {
    const tags = read({ artist: "A & B", ARTISTS: "A;B" });
    expect(tags.artists).toEqual(["A", "B"]);
    expect(tags.artistCredit).toBe("A & B");
  });

  it("reads every spelling of a tag", () => {
    const tags = read({
      ALBUMARTIST: "Band",
      "MusicBrainz Album Id": "0aafc0f2-5b4b-4a2d-9f9d-2f5e8a4b7c11",
      TRACKNUMBER: "03/12",
      discnumber: "2",
      ORIGINALDATE: "1975-11-21",
      date: "2011",
      genre: "(17)Rock; Pop",
      REPLAYGAIN_TRACK_GAIN: "-6.48 dB",
      replaygain_album_peak: "0.98",
      "artist-sort": "Queen, The",
      TCMP: "1",
      composer: "X; Y",
    });
    expect(tags).toMatchObject({
      albumArtists: ["Band"],
      albumMbid: "0aafc0f2-5b4b-4a2d-9f9d-2f5e8a4b7c11",
      track: 3,
      disc: 2,
      year: 1975,
      genres: ["Rock", "Pop"],
      replayGain: { trackGainDb: -6.48, trackPeak: null, albumGainDb: null, albumPeak: 0.98 },
      artistSort: "Queen, The",
      compilation: true,
      composers: ["X", "Y"],
    });
    expect(read({ R128_TRACK_GAIN: "-256" }).replayGain?.trackGainDb).toBe(4);
    expect(read({ replaygain_track_gain: "nan", track: "0", date: "soon" })).toMatchObject({
      replayGain: null,
      track: null,
      year: null,
    });
  });

  it("falls back to the path", () => {
    expect(guessFromPath("Queen/A Night at the Opera (1975)/11 - Bohemian Rhapsody.mp3")).toEqual({
      artist: "Queen",
      album: "A Night at the Opera",
      title: "Bohemian Rhapsody",
      track: 11,
      disc: null,
    });
    expect(guessFromPath("Queen/Live/CD 2/03. Intro.flac")).toMatchObject({
      artist: "Queen",
      album: "Live",
      disc: 2,
      track: 3,
    });
    expect(guessFromPath("Pink Floyd - Time.mp3")).toMatchObject({
      artist: "Pink Floyd",
      title: "Time",
      album: null,
    });
    // A loose download is not on an album named after its folder.
    expect(read({ title: "T", artist: "A" }, "Downloads/Stuff/song.mp3").album).toBeNull();
    expect(guessFromPath("99 Luftballons.mp3").title).toBe("Luftballons");
    expect(read({ title: "99 Luftballons" }, "99 Luftballons.mp3").title).toBe("99 Luftballons");
  });

  it("compares and sorts names of any script", () => {
    expect(nameKey("Beyoncé")).toBe("beyonce");
    expect(nameKey("Кино")).toBe("кино");
    expect(nameKey("!!!")).toBe("!!!");
    expect(sortKey("The Beatles")).toBe("beatles");
    expect(sortKey("De Dijk")).toBe("dijk");
    expect(sortKey("The The")).toBe("the");
  });

  it("knows audio files, covers and disc folders", () => {
    expect(["a.mp3", "a.FLAC", "a.m4b", "a.wv"].every(isAudioFile)).toBe(true);
    expect(["a.mp4", "a.mkv", "a.jpg", "a.m4p"].some(isAudioFile)).toBe(false);
    expect(coverRank("Cover.JPG")).toBe(0);
    expect(coverRank("back.jpg")).toBeNull();
    expect(albumDirOf("Queen/Live/CD1")).toBe("Queen/Live");
    expect(albumDirOf("Queen/Discovery")).toBe("Queen/Discovery");
  });
});
