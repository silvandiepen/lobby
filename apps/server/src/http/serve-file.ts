// SPDX-License-Identifier: MPL-2.0
import { createReadStream } from "node:fs";
import { realpath, stat } from "node:fs/promises";
import { join, sep } from "node:path";
import { Readable } from "node:stream";
import { errorMessage, log } from "../log.ts";
import { ApiError, type Ctx } from "./app.ts";
import { parseRange } from "./range.ts";

export interface LibraryFile {
  /** For the log: file names are never logged. */
  id: string;
  root: string;
  relPath: string;
  revision: string;
  mtimeMs: number;
  contentType: string;
}

/** Only an indexed file below its library folder is ever opened, whatever its path contains. */
export async function openablePath(file: {
  id: string;
  root: string;
  relPath: string;
}): Promise<{ path: string; size: number }> {
  try {
    const root = await realpath(file.root);
    const path = await realpath(join(file.root, file.relPath));
    if (!path.startsWith(root + sep)) throw new Error("outside the library folder");
    const info = await stat(path);
    if (!info.isFile()) throw new Error("not a file");
    return { path, size: info.size };
  } catch (error) {
    log.warn("An indexed file could not be opened", {
      asset: file.id,
      error: errorMessage(error),
    });
    throw new ApiError("unavailable", "This file cannot be read right now.");
  }
}

/** Answers a request for an original file, whole or as one range. */
export async function serveLibraryFile(c: Ctx, file: LibraryFile): Promise<Response> {
  const { path, size } = await openablePath(file);
  const etag = `"${file.revision}"`;
  const headers = new Headers({
    "Content-Type": file.contentType,
    "Accept-Ranges": "bytes",
    ETag: etag,
    "Last-Modified": new Date(file.mtimeMs).toUTCString(),
    "Cache-Control": "private, no-cache",
  });

  // A resumed download of a file that changed must start over, not splice two versions.
  const ifRange = c.req.header("If-Range");
  const rangeHeader = ifRange !== undefined && ifRange !== etag ? undefined : c.req.header("Range");
  const range = parseRange(rangeHeader, size);
  if (range === "unsatisfiable") {
    headers.set("Content-Range", `bytes */${size}`);
    headers.set("Content-Type", "application/json");
    return new Response(
      JSON.stringify({
        error: {
          code: "range_not_satisfiable",
          message: "That part of the file does not exist.",
        },
      }),
      { status: 416, headers },
    );
  }

  const start = range?.start ?? 0;
  const end = range?.end ?? size - 1;
  headers.set("Content-Length", String(size === 0 ? 0 : end - start + 1));
  if (range) headers.set("Content-Range", `bytes ${start}-${end}/${size}`);
  const status = range ? 206 : 200;
  if (c.req.method === "HEAD" || size === 0) return new Response(null, { status, headers });

  // A stream, so a film is never held in memory and a slow device slows the read.
  const stream = createReadStream(path, { start, end, highWaterMark: 256 * 1024 });
  return new Response(Readable.toWeb(stream) as ReadableStream<Uint8Array>, { status, headers });
}
