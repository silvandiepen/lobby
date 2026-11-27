// SPDX-License-Identifier: MPL-2.0
/**
 * How search compares words: without case, accents or punctuation, so "Amélie" is "amelie" and
 * "WALL·E" is "wall e". The index (SQLite's unicode61 tokenizer with remove_diacritics 2) folds
 * the same way.
 */
export function fold(text: string): string {
  return text
    .normalize("NFKD")
    .replace(/\p{M}+/gu, "")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();
}

/** The words of a text, folded. */
export function words(text: string): string[] {
  const folded = fold(text);
  return folded === "" ? [] : folded.split(" ");
}

/**
 * How many letters must change to make one word the other: swaps of two letters next to each
 * other count once (Damerau). Stops counting above `most`, and then answers `most + 1`.
 */
export function editDistance(a: string, b: string, most: number): number {
  if (Math.abs(a.length - b.length) > most) return most + 1;
  const before = new Array<number>(b.length + 1);
  let previous = Array.from({ length: b.length + 1 }, (_, index) => index);
  for (let i = 1; i <= a.length; i += 1) {
    const current = [i];
    let lowest = i;
    for (let j = 1; j <= b.length; j += 1) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      let value = Math.min(
        (previous[j] ?? 0) + 1,
        (current[j - 1] ?? 0) + 1,
        (previous[j - 1] ?? 0) + cost,
      );
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) {
        value = Math.min(value, (before[j - 2] ?? 0) + 1);
      }
      current[j] = value;
      lowest = Math.min(lowest, value);
    }
    if (lowest > most) return most + 1;
    for (let j = 0; j <= b.length; j += 1) before[j] = previous[j] ?? 0;
    previous = current;
  }
  return Math.min(previous[b.length] ?? most + 1, most + 1);
}

/** How many letters may be wrong in a word this long: none in a short word. */
export function typosAllowed(word: string): number {
  return word.length < 4 ? 0 : word.length < 8 ? 1 : 2;
}

/** A word as an FTS5 string, so nothing in it is read as syntax. */
export function quoted(word: string): string {
  return `"${word.replace(/"/g, '""')}"`;
}
