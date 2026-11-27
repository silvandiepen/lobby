// SPDX-License-Identifier: MPL-2.0
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { Devices } from "../src/auth/devices.ts";
import { createBackup, listBackups, pruneBackups, restoreBackup } from "../src/backup.ts";
import { loadConfig } from "../src/config.ts";
import { Database } from "../src/db/database.ts";
import { Catalogue } from "../src/library/catalogue.ts";
import { Scanner } from "../src/library/scanner.ts";
import { ProgressStore } from "../src/progress.ts";
import { backupIfDue } from "../src/server.ts";
import { makeTempDir, makeVideo, removeDir } from "./support/media.ts";

const HOUR = 3_600_000;
const START = Date.UTC(2026, 10, 24, 9, 0, 0);

let dir: string;
let db: Database;

beforeEach(() => {
  dir = makeTempDir();
  mkdirSync(join(dir, "data"));
  db = new Database(join(dir, "data", "lobby.db"));
});

afterEach(() => {
  db.close();
  removeDir(dir);
});

describe("catalogue backup", () => {
  it("restores devices, profiles and progress into an empty data folder", async () => {
    const movies = join(dir, "Movies");
    mkdirSync(movies);
    makeVideo(join(movies, "Up (2009).mp4"));
    const scanner = new Scanner(db, new Catalogue(db), {
      stabilityMs: 0,
      probeConcurrency: 1,
      ffprobePath: "ffprobe",
    });
    scanner.syncSources([{ path: movies, name: "Pixar", hint: "movies" }]);
    await scanner.scanAll();
    await scanner.scanAll();
    await scanner.processQueue();
    const item = db.get<{ id: string }>("select id from item where kind = 'movie'");
    expect(item).toBeDefined();
    const itemId = item?.id ?? "";

    const { token } = new Devices(db, "setup-secret").createLocalManager("Mac");
    db.run("insert into profile (id, name, color, created_at) values ('p1', 'Mila', 'blue', ?)", [
      START,
    ]);
    const put = new ProgressStore(db).put("p1", itemId, {
      opId: "op-1",
      baseRevision: null,
      positionMs: 61_000,
      durationMs: 120_000,
      completed: false,
      updatedAt: START,
    });
    expect(put.outcome).toBe("accepted");

    const configPath = join(dir, "lobby.config.json");
    writeFileSync(configPath, JSON.stringify({ roots: [{ path: movies, hint: "movies" }] }));
    const backup = await createBackup(db, join(dir, "backups"), configPath, START);
    expect(backup.name).toBe("20261124-090000");
    expect(existsSync(join(backup.path, "lobby.config.json"))).toBe(true);
    expect(existsSync(join(backup.path, "secrets.json"))).toBe(false);

    // Something that happened after the backup must not come back with it.
    db.run("delete from profile where id = 'p1'");

    const fresh = join(dir, "fresh-data");
    restoreBackup(backup.path, fresh);
    const restored = new Database(join(fresh, "lobby.db"));
    try {
      expect(new Devices(restored, "another-secret").authenticate(token).role).toBe("manager");
      expect(restored.get<{ name: string }>("select name from profile where id = 'p1'")?.name).toBe(
        "Mila",
      );
      expect(new ProgressStore(restored).list("p1", 0)).toMatchObject([
        { itemId, positionMs: 61_000 },
      ]);
      expect(restored.currentRevision()).toBeGreaterThan(0);
    } finally {
      restored.close();
    }
  });

  it("refuses to restore over an existing catalogue", async () => {
    const backup = await createBackup(db, join(dir, "backups"), null, START);
    expect(() => {
      restoreBackup(backup.path, join(dir, "data"));
    }).toThrow(/already exists/);
  });

  it("refuses a file that is not a Lobby catalogue", () => {
    const stray = join(dir, "stray.db");
    writeFileSync(stray, "not a database");
    expect(() => {
      restoreBackup(stray, join(dir, "fresh-data"));
    }).toThrow();
    expect(existsSync(join(dir, "fresh-data", "lobby.db"))).toBe(false);
  });

  it("keeps only the newest backups", async () => {
    const backups = join(dir, "backups");
    for (let day = 0; day < 5; day += 1) {
      await createBackup(db, backups, null, START + day * 24 * HOUR);
    }
    expect(pruneBackups(backups, 3)).toEqual(["20261125-090000", "20261124-090000"]);
    expect(listBackups(backups).map((backup) => backup.name)).toEqual([
      "20261128-090000",
      "20261127-090000",
      "20261126-090000",
    ]);
  });

  it("backs up on a schedule and not more often", async () => {
    const movies = join(dir, "Movies");
    mkdirSync(movies);
    const configPath = join(dir, "lobby.config.json");
    writeFileSync(
      configPath,
      JSON.stringify({
        roots: [{ path: movies, hint: "movies" }],
        backup: { keep: 2, everyHours: 24 },
      }),
    );
    const config = loadConfig(configPath);
    expect(config.backup.dir).toBe(join(dir, "data", "backups"));

    expect(await backupIfDue(db, config, START)).toBe(true);
    expect(await backupIfDue(db, config, START + 23 * HOUR)).toBe(false);
    expect(await backupIfDue(db, config, START + 24 * HOUR)).toBe(true);
    expect(await backupIfDue(db, config, START + 48 * HOUR)).toBe(true);
    expect(listBackups(config.backup.dir)).toHaveLength(2);
  });

  it("rejects a backup folder inside a library root", () => {
    const movies = join(dir, "Movies");
    mkdirSync(movies);
    const configPath = join(dir, "lobby.config.json");
    writeFileSync(
      configPath,
      JSON.stringify({
        roots: [{ path: movies, hint: "movies" }],
        backup: { dir: join(movies, "backups") },
      }),
    );
    expect(() => loadConfig(configPath)).toThrow(/must not be inside a library root/);
  });
});
