// SPDX-License-Identifier: MPL-2.0
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { Readable } from "node:stream";
import { parseRange } from "../http/range.ts";

export interface FileRequest {
  method: string;
  range: string | undefined;
  ifRange: string | undefined;
}

export interface FileResponseOptions {
  contentType: string;
  /** Sent as the ETag, and compared with If-Range so a resumed download never splices two versions. */
  etag: string;
  /**
   * True for a file that will never change again. A file ffmpeg is still appending
   * to is served up to its current length and must not be cached.
   */
  immutable: boolean;
}

export function errorResponse(
  status: number,
  code: string,
  message: string,
  headers: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify({ error: { code, message } }), {
    status,
    headers: { "Content-Type": "application/json; charset=UTF-8", ...headers },
  });
}

/**
 * Serves a file from the cache with single byte ranges, as a stream: a film is
 * never held in memory, and a slow device slows the read.
 */
export async function fileResponse(
  request: FileRequest,
  path: string,
  options: FileResponseOptions,
): Promise<Response> {
  let size: number;
  try {
    size = (await stat(path)).size;
  } catch {
    return errorResponse(404, "not_found", "This prepared file no longer exists.");
  }
  const etag = `"${options.etag}"`;
  const headers = new Headers({
    "Content-Type": options.contentType,
    "Accept-Ranges": "bytes",
    "Cache-Control": options.immutable ? "private, max-age=3600" : "no-store",
  });
  // A growing file has no stable identity yet, so it gets no ETag.
  if (options.immutable) headers.set("ETag", etag);

  const rangeHeader =
    request.ifRange !== undefined && request.ifRange !== etag ? undefined : request.range;
  const range = parseRange(rangeHeader, size);
  if (range === "unsatisfiable") {
    return errorResponse(416, "range_not_satisfiable", "That part of the file does not exist.", {
      "Content-Range": `bytes */${size}`,
    });
  }
  const start = range?.start ?? 0;
  const end = range?.end ?? size - 1;
  headers.set("Content-Length", String(size === 0 ? 0 : end - start + 1));
  if (range) headers.set("Content-Range", `bytes ${start}-${end}/${size}`);
  const status = range ? 206 : 200;
  if (request.method === "HEAD" || size === 0) return new Response(null, { status, headers });

  const stream = createReadStream(path, { start, end, highWaterMark: 256 * 1024 });
  return new Response(Readable.toWeb(stream) as ReadableStream<Uint8Array>, { status, headers });
}
