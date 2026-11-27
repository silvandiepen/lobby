// SPDX-License-Identifier: MPL-2.0
import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { expect, it } from "vitest";
import { Database } from "../src/db/database.ts";
import { Catalogue } from "../src/library/catalogue.ts";
import { ItemReader } from "../src/library/items.ts";
import { Scanner } from "../src/library/scanner.ts";
import { makeTempDir, removeDir } from "./support/media.ts";

it("marks an old AVI film as one the server converts", async () => {
  const dir = makeTempDir();
  const db = new Database(join(dir, "lobby.db"));
  try {
    const movies = join(dir, "Movies");
    mkdirSync(movies);
    const input = ["-f", "lavfi", "-i", "testsrc2=size=160x90:rate=10:duration=1"];
    execFileSync(
      "ffmpeg",
      ["-v", "error", ...input, "-c:v", "mpeg4"].concat(join(movies, "Up (2009).avi")),
    );
    const scanner = new Scanner(db, new Catalogue(db), {
      stabilityMs: 0,
      probeConcurrency: 1,
      ffprobePath: "ffprobe",
    });
    scanner.syncSources([{ path: movies, name: "Movies", hint: "movies" }]);
    await scanner.scanAll();
    await scanner.scanAll();
    await scanner.processQueue();
    const file = new ItemReader(db).page(null, 10).items[0]?.files[0];
    expect(file).toMatchObject({ playability: "transcode", convertible: true });
  } finally {
    db.close();
    removeDir(dir);
  }
});
