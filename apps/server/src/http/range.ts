// SPDX-License-Identifier: MPL-2.0
/** A single byte range, both ends inclusive. */
export interface ByteRange {
  start: number;
  end: number;
}

/**
 * Parses a `Range` header for a file of `size` bytes.
 *
 * @returns the range to send, `null` when there is no usable Range header
 *   (send the whole file), or `"unsatisfiable"` when the range lies outside the file.
 */
export function parseRange(
  header: string | undefined,
  size: number,
): ByteRange | null | "unsatisfiable" {
  if (header === undefined) return null;
  const match = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  // Several ranges or another unit: the standard allows ignoring the header.
  if (!match) return null;
  const [, first, last] = match;
  if (first === "" && last === "") return null;

  if (first === "") {
    // "bytes=-500": the last 500 bytes.
    const length = Number(last);
    if (length === 0 || size === 0) return "unsatisfiable";
    return { start: Math.max(0, size - length), end: size - 1 };
  }
  const start = Number(first);
  if (!Number.isSafeInteger(start) || start >= size) return "unsatisfiable";
  if (last === "") return { start, end: size - 1 };
  const end = Number(last);
  if (!Number.isSafeInteger(end) || end < start) return null;
  return { start, end: Math.min(end, size - 1) };
}

const MEDIA_TYPES: Record<string, string> = {
  mp4: "video/mp4",
  m4v: "video/mp4",
  mov: "video/quicktime",
  mkv: "video/x-matroska",
  webm: "video/webm",
  avi: "video/x-msvideo",
  ts: "video/mp2t",
  m2ts: "video/mp2t",
  mpg: "video/mpeg",
  mpeg: "video/mpeg",
  wmv: "video/x-ms-wmv",
};

export function mediaTypeFor(container: string | null, path: string): string {
  const extension = path.slice(path.lastIndexOf(".") + 1).toLowerCase();
  return MEDIA_TYPES[container ?? ""] ?? MEDIA_TYPES[extension] ?? "application/octet-stream";
}
