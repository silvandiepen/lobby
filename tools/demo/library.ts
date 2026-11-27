// SPDX-License-Identifier: MPL-2.0
/**
 * Downloads the demo library: the open movies in films.json, from the Blender Foundation's own
 * download server, their posters from Wikimedia Commons, and a CREDITS.txt beside each film.
 *
 *   node tools/demo/library.ts --media ~/lobby-demo/media --state ~/lobby-demo/state
 *
 * Needs `unzip` and `ffmpeg`. About 1.6 GB. A film that is there already is not fetched again.
 */
import { execFileSync } from "node:child_process";
import {
  createWriteStream,
  existsSync,
  mkdirSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { FILMS, option, stateDir } from "./lib.ts";

const media = option("media", join(process.env["HOME"] ?? ".", "lobby-demo", "media"));
const posters = join(stateDir(), "posters");
mkdirSync(posters, { recursive: true });

async function download(url: string, to: string): Promise<void> {
  const response = await fetch(url, { headers: { "User-Agent": "lobby-demo-library/1" } });
  if (!response.ok || !response.body) throw new Error(`${url}: ${response.status}`);
  mkdirSync(dirname(to), { recursive: true });
  await pipeline(Readable.fromWeb(response.body), createWriteStream(`${to}.part`));
  execFileSync("mv", [`${to}.part`, to]);
}

function hasVideo(folder: string): boolean {
  return (
    existsSync(folder) && readdirSync(folder).some((name) => /\.(mov|mkv|mp4|m4v)$/i.test(name))
  );
}

for (const film of FILMS) {
  const folder = join(media, film.folder);
  mkdirSync(folder, { recursive: true });
  if (!hasVideo(folder)) {
    const name = decodeURIComponent(film.download.url.split("/").pop() ?? "film");
    const target = join(folder, name);
    console.log(`Downloading ${film.title}`);
    await download(film.download.url, target);
    if (film.download.zip) {
      execFileSync("unzip", ["-o", "-q", "-j", target, "-d", folder]);
      rmSync(target);
    }
  }
  if (film.subtitles && !existsSync(join(folder, film.subtitles.file))) {
    await download(film.subtitles.url, join(folder, film.subtitles.file));
  }
  writeFileSync(
    join(folder, "CREDITS.txt"),
    [
      film.title,
      film.attribution,
      `Licence: ${film.licence}, ${film.licenceUrl}`,
      `Checked at: ${film.licenceSource}`,
      `Film from: ${film.download.url} (unchanged)`,
      `Poster: ${film.poster.source}${film.poster.cropToPortrait ? " (a still, cropped to a portrait poster)" : ""}`,
      "",
    ].join("\n"),
  );

  const poster = join(posters, `${film.title}.jpg`);
  if (!existsSync(poster)) {
    const original = join(posters, `${film.title}.original`);
    await download(film.poster.url, original);
    // One JPEG for every poster; the still is cut to 2:3 from its middle.
    const filter = film.poster.cropToPortrait ? ["-vf", "crop=ih*2/3:ih"] : [];
    execFileSync("ffmpeg", ["-v", "error", "-y", "-i", original, ...filter, "-q:v", "3", poster]);
    rmSync(original);
  }
}

writeFileSync(
  join(media, "ATTRIBUTION.md"),
  [
    "# The demo library",
    "",
    "Open movies of the Blender Foundation, unchanged. Categories are invented for the demo.",
    "",
    ...FILMS.map(
      (film) => `- **${film.title}** (${film.year}): ${film.attribution}. ${film.licence}.`,
    ),
    "",
  ].join("\n"),
);
console.log(`The library is in ${media}, posters in ${posters}.`);
