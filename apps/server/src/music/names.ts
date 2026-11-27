// SPDX-License-Identifier: MPL-2.0
import { extensionOf } from "../library/parse.ts";

const AUDIO_EXTENSIONS = new Set([
  ..."mp3 m4a m4b aac flac alac wav wave aif aiff aifc caf".split(" "),
  ..."ogg oga opus wma ape wv tta tak mpc mka dsf dff ac3 eac3 dts amr spx".split(" "),
]);
const IMAGE = /^(cover|folder|front)\.(?:jpe?g|png)$/i;
const DISC_FOLDER = /^(?:cd|dis[ck]|dvd|lp|side|part|deel|teil)[ _.-]*(\d{1,2}|[ab])\b/i;

export function isAudioFile(name: string): boolean {
  return AUDIO_EXTENSIONS.has(extensionOf(name));
}

/** Which of the cover names a picture has, best first (0), or null for any other picture. */
export function coverRank(name: string): number | null {
  const match = IMAGE.exec(name);
  return match?.[1] ? ["cover", "folder", "front"].indexOf(match[1].toLowerCase()) : null;
}

export function dirOf(relPath: string): string {
  const slash = relPath.lastIndexOf("/");
  return slash === -1 ? "" : relPath.slice(0, slash);
}

export function baseOf(relPath: string): string {
  return relPath.slice(relPath.lastIndexOf("/") + 1);
}

/** The disc a folder name stands for ("CD 2", "Disc 1 - Live"), or null. */
export function discOfFolder(name: string): number | null {
  const found = DISC_FOLDER.exec(name)?.[1]?.toLowerCase();
  if (found === undefined) return null;
  return found === "a" ? 1 : found === "b" ? 2 : Number(found);
}

/** The folder of the whole album: the file's own, or the one around a disc folder. */
export function albumDirOf(dir: string): string {
  return dir !== "" && discOfFolder(baseOf(dir)) !== null ? dirOf(dir) : dir;
}

/** A name to compare by. Keeps every script's letters, unlike the film titles' version. */
export function nameKey(name: string): string {
  const key = name
    .normalize("NFKD")
    .replace(/\p{M}+/gu, "")
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/['’`]/g, "")
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();
  // "!!!" and the like are names too.
  return key || name.trim().toLowerCase();
}

/** A name to sort by: "The Beatles" files under B. */
export function sortKey(name: string): string {
  return nameKey(name).replace(/^(?:the|a|an|de|het|een) (?=\S)/, "");
}

const VARIOUS = new Set(["various artists", "various", "va", "diverse artiesten", "diversen"]);
export function isVarious(name: string): boolean {
  return VARIOUS.has(nameKey(name));
}
