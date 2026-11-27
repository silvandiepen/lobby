// SPDX-License-Identifier: MPL-2.0
import { describe, expect, it } from "vitest";
import {
  isIgnoredName,
  normalizeTitle,
  parseMediaPath,
  seasonFromFolder,
  sortTitle,
} from "../src/library/parse.ts";

describe("films", () => {
  it("reads title and year from a 'Title (Year)' folder", () => {
    const parsed = parseMediaPath("Toy Story 3 (2010)/Toy Story 3 (2010).mkv", "movies");
    expect(parsed).toMatchObject({ kind: "movie", title: "Toy Story 3", year: 2010 });
  });

  it("trusts the folder over a release name inside it", () => {
    const parsed = parseMediaPath(
      "GOAT (2026)/Goat.2026.1080p.BluRay.x264.AAC5.1-[YTS.BZ].mp4",
      "movies",
    );
    expect(parsed).toMatchObject({ kind: "movie", title: "GOAT", year: 2026 });
  });

  it("drops the running number and genre label of a film in a collection folder", () => {
    expect(
      parseMediaPath(
        "Police Academy/03 Police Academy 3 Back In Training - Comedy 1986 Eng Subs 720p [H264-mp4].mp4",
        "movies",
      ),
    ).toMatchObject({ kind: "movie", title: "Police Academy 3 Back In Training", year: 1986 });
    expect(
      parseMediaPath("Police Academy/01 Police Academy - Comedy 1984 720p.mp4", "movies"),
    ).toMatchObject({ kind: "movie", title: "Police Academy", year: 1984 });
  });

  it("keeps a number that belongs to the title", () => {
    expect(parseMediaPath("Classics/12 Angry Men 1957 1080p.mkv", "movies")).toMatchObject({
      title: "12 Angry Men",
      year: 1957,
    });
    expect(parseMediaPath("Classics/Love - Comedy 1999 720p.mkv", "movies")).toMatchObject({
      title: "Love - Comedy",
    });
  });

  it("reads a 'Year - Title' file", () => {
    expect(parseMediaPath("1988 - Oliver and Company.mkv", "movies")).toMatchObject({
      kind: "movie",
      title: "Oliver and Company",
      year: 1988,
    });
    expect(parseMediaPath("2022 - Puss in Boots The Last Wish.mkv", "movies")).toMatchObject({
      title: "Puss in Boots The Last Wish",
      year: 2022,
    });
  });

  it("reads a dotted release name", () => {
    expect(
      parseMediaPath("Goat.2026.1080p.BluRay.x264.AAC5.1-[YTS.BZ].mp4", "movies"),
    ).toMatchObject({ kind: "movie", title: "Goat", year: 2026 });
  });

  it("reads a spaced release name", () => {
    expect(
      parseMediaPath("Charlie the Wonderdog 2026 1080p AMZN WEB-DL DDP5 1 H 264-iVy.mkv", "movies"),
    ).toMatchObject({ title: "Charlie the Wonderdog", year: 2026 });
  });

  it("keeps a year that is part of the title", () => {
    expect(
      parseMediaPath("Blade Runner 2049 (2017)/Blade Runner 2049.mkv", "movies"),
    ).toMatchObject({ title: "Blade Runner 2049", year: 2017 });
    expect(parseMediaPath("2001 A Space Odyssey 1968 1080p BluRay.mkv", "movies")).toMatchObject({
      title: "2001 A Space Odyssey",
      year: 1968,
    });
  });

  it("keeps subtitles and punctuation in a title", () => {
    expect(
      parseMediaPath(
        "Maleficent - Mistress of Evil (2019)/Maleficent - Mistress of Evil (2019).mp4",
        "movies",
      ),
    ).toMatchObject({ title: "Maleficent - Mistress of Evil", year: 2019 });
    expect(
      parseMediaPath("Beethoven's 2nd (1993)/Beethoven's 2nd (1993).avi", "movies"),
    ).toMatchObject({ title: "Beethoven's 2nd", year: 1993 });
    expect(
      parseMediaPath(
        "20,000 Leagues Under the Sea (1954)/20,000 Leagues Under the Sea (1954).avi",
        "movies",
      ),
    ).toMatchObject({ title: "20,000 Leagues Under the Sea", year: 1954 });
  });

  it("finds editions and parts", () => {
    expect(
      parseMediaPath("Aliens (1986)/Aliens (1986) Director's Cut 1080p.mkv", "movies"),
    ).toMatchObject({ title: "Aliens", year: 1986, edition: "Director's Cut" });
    expect(parseMediaPath("Ben-Hur (1959)/Ben-Hur CD2.avi", "movies")).toMatchObject({
      title: "Ben-Hur",
      part: 2,
    });
  });

  it("finds provider ids in a name", () => {
    expect(parseMediaPath("Coco (2017) {imdb-tt2380307}/Coco.mkv", "movies")).toMatchObject({
      title: "Coco",
      year: 2017,
      imdbId: "tt2380307",
    });
    expect(parseMediaPath("Coco (2017) [tmdbid-354912].mkv", "movies")).toMatchObject({
      tmdbId: 354912,
    });
  });

  it("reports a missing year instead of guessing", () => {
    const parsed = parseMediaPath("Holiday in Gozo.mp4", "movies");
    expect(parsed).toMatchObject({ kind: "movie", title: "Holiday in Gozo", year: null });
    expect(parsed.evidence).toContain("No release year found.");
  });
});

describe("episodes", () => {
  it("reads a fully named episode", () => {
    expect(
      parseMediaPath(
        "Friends/Season 9/Friends (1994) - S09E17 - The One With The Memorial Service (1080p BluRay x265 Silence).mkv",
        "series",
      ),
    ).toMatchObject({
      kind: "episode",
      title: "Friends",
      year: 1994,
      season: 9,
      episode: 17,
      episodeTitle: "The One With The Memorial Service",
    });
  });

  it("takes the show from the folder when the file has only a marker", () => {
    expect(
      parseMediaPath("The Sopranos/Season 5/ S05E03 - Where's Johnny .mkv", "series"),
    ).toMatchObject({
      title: "The Sopranos",
      season: 5,
      episode: 3,
      episodeTitle: "Where's Johnny",
    });
  });

  it("reads a dotted release name", () => {
    expect(
      parseMediaPath(
        "Animal Control/Season 2/Animal.Control.S02E09.Beagles.and.Lemurs.1080p.DSNP.WEB-DL.DDP5.1.H.264-MADSKY.mkv",
        "series",
      ),
    ).toMatchObject({
      title: "Animal Control",
      season: 2,
      episode: 9,
      episodeTitle: "Beagles and Lemurs",
    });
    expect(
      parseMediaPath("The Bear/Season 4/The.Bear.S04E04.1080p.WEBRip.x265-PGW.mkv", "series"),
    ).toMatchObject({ title: "The Bear", season: 4, episode: 4, episodeTitle: null });
  });

  it("reads a marker with a space in it", () => {
    expect(
      parseMediaPath(
        "Darkwing Duck/Season 1 (1991-92)/Darkwing Duck - S01 E36 - Slaves to Fashion (480p - DNSP Web-DL).mp4",
        "series",
      ),
    ).toMatchObject({
      title: "Darkwing Duck",
      season: 1,
      episode: 36,
      episodeTitle: "Slaves to Fashion",
    });
  });

  it("reads a combined file as a range of episodes", () => {
    expect(
      parseMediaPath(
        "Adventurs of the Gummi Bears/Season 1/Adventures.of.the.Gummi.Bears.S01E02-E03.The.Sinister.Sculptor.&.Zummi.Makes.It.Hot.1080p.UPSCALED.AAC.2.0.H.265.-EDGE2020.mkv",
        "series",
      ),
    ).toMatchObject({
      season: 1,
      episode: 2,
      episodeEnd: 3,
      episodeTitle: "The Sinister Sculptor & Zummi Makes It Hot",
    });
    expect(parseMediaPath("Example/S01E01E02.mkv", "series")).toMatchObject({
      season: 1,
      episode: 1,
      episodeEnd: 2,
    });
  });

  it("does not read a resolution as a second episode", () => {
    expect(parseMediaPath("Example/Example.S01E02-720p.mkv", "series")).toMatchObject({
      season: 1,
      episode: 2,
      episodeEnd: null,
    });
    expect(parseMediaPath("Example/Example 1920x1080 S02E05.mkv", "series")).toMatchObject({
      season: 2,
      episode: 5,
    });
  });

  it("takes the season from the folder when the name has none", () => {
    expect(
      parseMediaPath(
        "Chip 'n Dale Rescue Rangers/Chip 'n Dale Rescue Rangers S02 (360p re-webrip)/Chip 'n' Dale Rescue Rangers S02E14 The Case of the Cola Cult.mp4",
        "series",
      ),
    ).toMatchObject({
      title: "Chip 'n Dale Rescue Rangers",
      season: 2,
      episode: 14,
      episodeTitle: "The Case of the Cola Cult",
    });
    expect(
      parseMediaPath(
        "Talespin/TaleSpin - Ep. 09 - I Only Have Ice for You (480p - DVDRip).mp4",
        "series",
      ),
    ).toMatchObject({
      title: "Talespin",
      season: 1,
      episode: 9,
      episodeTitle: "I Only Have Ice for You",
    });
  });

  it("reads season and episode packed into one number", () => {
    expect(
      parseMediaPath(
        "Looney Tunes/Looney.Tunes.S01-S24.Golden.Collection.DVDRip.x264-JCH[rartv]/Looney Tunes Season 10/1013 The Honey-Mousers.mkv",
        "series",
      ),
    ).toMatchObject({
      title: "Looney Tunes",
      season: 10,
      episode: 13,
      episodeTitle: "The Honey-Mousers",
    });
  });

  it("reads an episode counted across the whole show", () => {
    expect(parseMediaPath("Tom and Jerry/079 - Life with Tom.mp4", "series")).toMatchObject({
      title: "Tom and Jerry",
      season: 1,
      episode: 79,
      episodeTitle: "Life with Tom",
    });
  });

  it("keeps a dated video without inventing an episode number", () => {
    const parsed = parseMediaPath(
      "Curious George/2026-03-20 - Let's Feed The Birds! Curious George [gsY23C591kY].mp4",
      "series",
    );
    expect(parsed).toMatchObject({
      kind: "episode",
      title: "Curious George",
      episode: null,
      airDate: "2026-03-20",
    });
  });

  it("reads a release date written as month, day, year inside a year folder", () => {
    expect(
      parseMediaPath("Looney Tunes/1938/112638DVD The Daffy Doc LT.avi", "series"),
    ).toMatchObject({
      kind: "episode",
      title: "Looney Tunes",
      episode: null,
      airDate: "1938-11-26",
      episodeTitle: "The Daffy Doc",
    });
    expect(parseMediaPath("Looney Tunes/1953/022853DVD Duck Amuck MM.avi", "series")).toMatchObject(
      {
        airDate: "1953-02-28",
        episodeTitle: "Duck Amuck",
      },
    );
    // Six digits that are not a date in that year are left alone.
    expect(parseMediaPath("Looney Tunes/1953/991299 Something.avi", "series").airDate).toBeNull();
  });

  it("drops the channel tags a video site adds after an emoji", () => {
    expect(
      parseMediaPath(
        "Curious George/2025-06-05 - George and the Magic Shadow!  🐵 Curious George 🐵 Kids Cartoon 🐵 Kids Movies [2adw9tUZkFg].mp4",
        "series",
      ),
    ).toMatchObject({ airDate: "2025-06-05", episodeTitle: "George and the Magic Shadow!" });
  });

  it("recognises a loose episode in a films folder", () => {
    expect(parseMediaPath("Mr Bean 1990 S01E06 Mr Bean Rides Again.mp4", "movies")).toMatchObject({
      kind: "episode",
      title: "Mr Bean",
      year: 1990,
      season: 1,
      episode: 6,
      episodeTitle: "Mr Bean Rides Again",
    });
    expect(
      parseMediaPath("New Arrivals/The.Bear.S04E04.1080p.WEBRip.x265-PGW.mkv", "movies"),
    ).toMatchObject({ kind: "episode", title: "The Bear", season: 4, episode: 4 });
  });

  it("leaves an unnumbered, undated file for review", () => {
    const parsed = parseMediaPath("Looney Tunes/Extras Disc/Bugs Bunny Superstar.avi", "series");
    expect(parsed).toMatchObject({
      kind: "episode",
      title: "Looney Tunes",
      episode: null,
      airDate: null,
    });
    expect(parsed.evidence).toContain("No episode number found in the file name.");
  });

  it("recognises an episode in a mixed folder", () => {
    expect(parseMediaPath("Bluey/Season 02/S02E04.mkv", "mixed")).toMatchObject({
      kind: "episode",
      title: "Bluey",
      season: 2,
      episode: 4,
    });
    expect(parseMediaPath("The Jungle Book (1967)/movie.mkv", "mixed")).toMatchObject({
      kind: "movie",
      title: "The Jungle Book",
      year: 1967,
    });
  });
});

describe("extras and personal videos", () => {
  it("files a featurette under its show", () => {
    expect(parseMediaPath("Friends/Featurettes/Season 7/Gag Reel_new.mkv", "series")).toMatchObject(
      { kind: "extra", title: "Friends", extraKind: "featurette" },
    );
  });

  it("recognises a local trailer in a film folder", () => {
    expect(parseMediaPath("Up (2009)/Extras/trailer.mp4", "movies")).toMatchObject({
      kind: "extra",
      title: "Up",
      year: 2009,
      extraKind: "trailer",
    });
    expect(parseMediaPath("Up (2009)/Up (2009)-trailer.mp4", "movies")).toMatchObject({
      kind: "extra",
      title: "Up",
      extraKind: "trailer",
    });
  });

  it("treats everything in a personal root as personal", () => {
    expect(parseMediaPath("2024/Holiday in Gozo.mp4", "personal")).toMatchObject({
      kind: "personal",
      title: "Holiday in Gozo",
    });
  });
});

describe("helpers", () => {
  it("ignores hidden files, resource forks and unfinished transfers", () => {
    expect(isIgnoredName("._Movie.mp4")).toBe(true);
    expect(isIgnoredName(".DS_Store")).toBe(true);
    expect(isIgnoredName("Movie.mkv.part")).toBe(true);
    expect(isIgnoredName("2025-12-26 - Clip [abc].temp.mp4")).toBe(true);
    expect(isIgnoredName("Movie.mkv")).toBe(false);
  });

  it("reads seasons from folder names", () => {
    expect(seasonFromFolder("Season 02")).toBe(2);
    expect(seasonFromFolder("Season 1 (1991-92)")).toBe(1);
    expect(seasonFromFolder("Looney Tunes Season 10")).toBe(10);
    expect(seasonFromFolder("Specials")).toBe(0);
    expect(seasonFromFolder("1938")).toBeNull();
  });

  it("normalises titles for matching and sorting", () => {
    expect(normalizeTitle("Chip 'n' Dale: Rescue Rangers")).toBe("chip n dale rescue rangers");
    expect(normalizeTitle("Lilo & Stitch")).toBe("lilo and stitch");
    expect(sortTitle("The Bear")).toBe("bear");
    expect(sortTitle("A Bug's Life")).toBe("bugs life");
  });
});
