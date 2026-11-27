// SPDX-License-Identifier: MPL-2.0
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { Hono } from "hono";
import { Devices } from "../../src/auth/devices.ts";
import { Database } from "../../src/db/database.ts";
import { createApp, type AppEnv } from "../../src/http/app.ts";
import { ItemReader } from "../../src/library/items.ts";
import { MusicLibrary } from "../../src/music/index.ts";
import type { MusicRootConfig } from "../../src/music/types.ts";
import { ProgressStore } from "../../src/progress.ts";
import { makeTempDir, removeDir } from "./media.ts";

export interface AudioOptions {
  tags?: Record<string, string>;
  seconds?: number;
  /** Another tone is another file. */
  tone?: number;
  cover?: string;
  chapters?: { title: string; startMs: number; endMs: number }[];
  codec?: string[];
}

/** A real, tiny audio file: a tone with real tags. */
export function makeAudio(path: string, options: AudioOptions = {}): void {
  mkdirSync(dirname(path), { recursive: true });
  const args = ["-v", "error", "-y", "-f", "lavfi"];
  args.push("-i", `sine=frequency=${options.tone ?? 440}:duration=${options.seconds ?? 1}`);
  let chapters: string | null = null;
  if (options.cover) args.push("-i", options.cover);
  if (options.chapters) {
    chapters = `${path}.ffmeta`;
    writeFileSync(
      chapters,
      ";FFMETADATA1\n" +
        options.chapters
          .map(
            (one) =>
              `[CHAPTER]\nTIMEBASE=1/1000\nSTART=${one.startMs}\nEND=${one.endMs}\ntitle=${one.title}\n`,
          )
          .join(""),
    );
    args.push("-f", "ffmetadata", "-i", chapters, "-map_chapters", options.cover ? "2" : "1");
  }
  args.push("-map", "0:a");
  if (options.cover) args.push("-map", "1:v", "-c:v", "copy", "-disposition:v:0", "attached_pic");
  for (const [key, value] of Object.entries(options.tags ?? {})) {
    args.push("-metadata", `${key}=${value}`);
  }
  args.push(...(options.codec ?? []));
  if (path.endsWith(".m4b")) args.push("-f", "ipod");
  if (path.endsWith(".flac")) args.push("-compression_level", "0");
  execFileSync("ffmpeg", [...args, path], { stdio: ["ignore", "ignore", "inherit"] });
  if (chapters) removeDir(chapters);
}

export function makePicture(path: string, color = "red", size = "300x300"): void {
  mkdirSync(dirname(path), { recursive: true });
  execFileSync("ffmpeg", [
    ...["-v", "error", "-y", "-f", "lavfi", "-i", `color=${color}:size=${size}`],
    ...["-frames:v", "1", "-update", "1", path],
  ]);
}

export interface MusicFixture {
  dir: string;
  music: string;
  books: string;
  db: Database;
  library: MusicLibrary;
  app: Hono<AppEnv>;
  clock: { now: number };
  unplugged: Set<string>;
  manager: string;
  viewer: string;
  profile: string;
  other: string;
  scan: () => Promise<void>;
  call: <T = Record<string, unknown>>(
    method: string,
    path: string,
    body?: unknown,
    options?: { token?: string | null; headers?: Record<string, string> },
  ) => Promise<{ status: number; body: T; headers: Headers; bytes: Buffer }>;
  close: () => Promise<void>;
}

export async function setUpMusic(
  options: { stabilityMs?: number; maxCacheGb?: number; forgetAfterMs?: number } = {},
): Promise<MusicFixture> {
  const dir = makeTempDir("lobby-music-");
  const music = join(dir, "Music");
  const books = join(dir, "Books");
  mkdirSync(music);
  mkdirSync(books);
  const clock = { now: 1_800_000_000_000 };
  const now = (): number => clock.now;
  const unplugged = new Set<string>();
  const db = new Database(join(dir, "lobby.db"));
  const roots: MusicRootConfig[] = [
    { path: music, name: "Our Music", hint: "music" },
    { path: books, name: "Our Books", hint: "audiobooks" },
  ];
  const library = new MusicLibrary(
    db,
    {
      dataDir: join(dir, "data"),
      music: {
        roots,
        cacheDir: join(dir, "cache"),
        maxCacheGb: options.maxCacheGb ?? 1,
        minFreeGb: 0,
      },
      stabilityMs: options.stabilityMs ?? 0,
      rescanMinutes: 60,
      ffmpegPath: "ffmpeg",
      ffprobePath: "ffprobe",
    },
    {
      now,
      volumeOf: (path) => Promise.resolve(unplugged.has(path) ? 2 : 1),
      ...(options.forgetAfterMs === undefined ? {} : { forgetAfterMs: options.forgetAfterMs }),
    },
  );
  await library.copies.start();
  const devices = new Devices(db, "secret", now);
  const app = createApp({
    db,
    devices,
    items: new ItemReader(db),
    progress: new ProgressStore(db, now),
    music: library,
    serverName: "Test",
    version: "0",
    isScanning: () => false,
    now,
  });
  const fixture: MusicFixture = {
    dir,
    music,
    books,
    db,
    library,
    app,
    clock,
    unplugged,
    manager: "",
    viewer: "",
    profile: "",
    other: "",
    scan: async () => {
      await library.scanner.scanAll();
      await library.scanner.processQueue();
    },
    call: async <T>(
      method: string,
      path: string,
      body?: unknown,
      {
        token = fixture.viewer,
        headers = {},
      }: { token?: string | null; headers?: Record<string, string> } = {},
    ) => {
      const response = await app.request(path, {
        method,
        headers: {
          ...headers,
          ...(token === null ? {} : { Authorization: `Bearer ${token}` }),
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      });
      const bytes = Buffer.from(await response.arrayBuffer());
      const json = (response.headers.get("Content-Type") ?? "").includes("json");
      return {
        status: response.status,
        body: (json ? JSON.parse(bytes.toString("utf8")) : bytes.toString("utf8")) as T,
        headers: response.headers,
        bytes,
      };
    },
    close: async () => {
      await library.stop();
      db.close();
      removeDir(dir);
    },
  };
  const claimed = devices.claim("secret", "Mac", "macos");
  fixture.manager = claimed.token;
  const request = devices.startPairing("iPad", "ipados");
  devices.approve(request.code, "viewer", claimed.device.id);
  const collected = devices.collect(request.id, request.pollSecret);
  if (collected.status !== "approved") throw new Error("not paired");
  fixture.viewer = collected.token;
  for (const key of ["profile", "other"] as const) {
    const made = await fixture.call<{ id: string }>(
      "POST",
      "/v1/profiles",
      { name: key },
      { token: fixture.manager },
    );
    fixture[key] = made.body.id;
  }
  return fixture;
}
