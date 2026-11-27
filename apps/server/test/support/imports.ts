// SPDX-License-Identifier: MPL-2.0
import { join } from "node:path";
import type { Database } from "../../src/db/database.ts";
import type { AppDeps } from "../../src/http/app.ts";
import { ImportService } from "../../src/imports/service.ts";
import { UploadService } from "../../src/imports/uploads.ts";

/** The import and upload routes for a test app, with no folders and Lobby's folder in `dir`. */
export function importsFor(db: Database, dir: string): NonNullable<AppDeps["imports"]> {
  const imports = new ImportService({
    db,
    folders: [],
    roots: () => [],
    lobbyDir: join(dir, "lobby-folder"),
    driveConnected: () => Promise.resolve(false),
    waitMs: 600_000,
    copyAcrossDrives: false,
    matcher: null,
  });
  const uploads = new UploadService({
    db,
    imports,
    roots: () => [],
    maxFileBytes: () => 1024 ** 3,
    quotaBytes: () => 1024 ** 3,
    minFreeBytes: () => 0,
  });
  return {
    imports,
    uploads,
    roots: () => [],
    settings: () => ({ waitMinutes: 10, copyAcrossDrives: false, maxFileGb: 1, quotaGb: 1 }),
  };
}
