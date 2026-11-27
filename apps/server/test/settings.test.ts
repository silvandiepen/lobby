// SPDX-License-Identifier: MPL-2.0
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { loadConfig, parseConfig, readConfigFile } from "../src/config.ts";
import { createBackup, restoreBackup } from "../src/backup.ts";
import { FolderBrowser } from "../src/settings/browse.ts";
import { DEFINITIONS, SETTINGS } from "../src/settings/schema.ts";
import { readSettings, SETTING_KEYS, settingsHistory } from "../src/settings/store.ts";
import { checkTmdbKey } from "../src/settings/tmdb.ts";
import { startServer, type RunningServer } from "../src/server.ts";
import { makeTempDir, makeVideo, removeDir } from "./support/media.ts";
import { LocalTmdb } from "./support/tmdb.ts";

// Not anyone's: made up for these tests.
const GOOD_KEY = "0123456789abcdef0123456789abcdef";
const WRONG_KEY = "fedcba9876543210fedcba9876543210";

interface Reply {
  status: number;
  body: Record<string, unknown>;
  text: string;
  headers: Headers;
}

let dir: string;
let configPath: string;
let running: RunningServer | null;
let manager: string;
let restarts: number;

function writeConfig(extra: Record<string, unknown> = {}): void {
  writeFileSync(
    configPath,
    JSON.stringify({ host: "127.0.0.1", port: 0, stabilityMs: 0, advertise: false, ...extra }),
  );
}

async function start(
  extra: Record<string, unknown> = {},
  tmdbBaseUrl?: string,
  claimed = true,
  omdbBaseUrl?: string,
): Promise<void> {
  if (!existsSync(configPath)) writeConfig(extra);
  running = await startServer(loadConfig(configPath), {
    restart: () => {
      restarts += 1;
    },
    browseBases: () => [join(dir, "drive"), join(dir, "home")],
    ...(tmdbBaseUrl === undefined ? {} : { tmdbBaseUrl }),
    ...(omdbBaseUrl === undefined ? {} : { omdbBaseUrl }),
  });
  if (claimed) manager = running.services.devices.createLocalManager("Desk").token;
}

async function ask(
  method: string,
  path: string,
  body?: unknown,
  options: { token?: string | null; peer?: string; raw?: string } = {},
): Promise<Reply> {
  const token = options.token === undefined ? manager : options.token;
  const init: RequestInit = {
    method,
    headers: {
      Host: "127.0.0.1",
      ...(token === null ? {} : { Authorization: `Bearer ${token}` }),
      ...(body === undefined && options.raw === undefined
        ? {}
        : { "Content-Type": "application/json" }),
    },
    ...(options.raw !== undefined
      ? { body: options.raw }
      : body === undefined
        ? {}
        : { body: JSON.stringify(body) }),
  };
  const env =
    options.peer === undefined
      ? undefined
      : { incoming: { socket: { remoteAddress: options.peer } } };
  if (!running) throw new Error("not running");
  const response = await running.app.request(`http://127.0.0.1${path}`, init, env);
  const text = await response.text();
  let parsed: Record<string, unknown> = {};
  try {
    parsed = JSON.parse(text) as Record<string, unknown>;
  } catch {
    // Not JSON.
  }
  return { status: response.status, body: parsed, text, headers: response.headers };
}

const patch = (
  changes: Record<string, unknown>,
  more: Record<string, unknown> = {},
): Promise<Reply> => ask("PATCH", "/v1/settings", { changes, ...more });

async function until(check: () => boolean | Promise<boolean>, ms = 20_000): Promise<void> {
  const end = Date.now() + ms;
  while (!(await check())) {
    if (Date.now() > end) throw new Error("timed out");
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
}

function server(): RunningServer {
  if (!running) throw new Error("not running");
  return running;
}

function secrets(): { tmdbApiKey: string | null; omdbApiKey?: string | null; setupSecret: string } {
  return JSON.parse(readFileSync(join(dir, "data", "secrets.json"), "utf8")) as {
    tmdbApiKey: string | null;
    omdbApiKey?: string | null;
    setupSecret: string;
  };
}

function setting(reply: Reply, key: string): Record<string, unknown> | undefined {
  return (reply.body["settings"] as Record<string, unknown>[]).find((one) => one["key"] === key);
}

beforeEach(() => {
  dir = makeTempDir("lobby-settings-");
  for (const one of ["drive/Films", "drive/Series", "home", "elsewhere"]) {
    mkdirSync(join(dir, one), { recursive: true });
  }
  configPath = join(dir, "lobby.config.json");
  running = null;
  restarts = 0;
  manager = "";
});

afterEach(async () => {
  await running?.close();
  delete process.env["LOBBY_TMDB_API_KEY"];
  removeDir(dir);
});

describe("the schema", () => {
  it("describes every key the store holds, and only those", () => {
    expect(SETTINGS.map((one) => one.key).sort()).toEqual([...SETTING_KEYS].sort());
  });

  it("leaves where the server listens and the programs it runs to the file", () => {
    for (const key of [
      "host",
      "port",
      "dataDir",
      "ffmpegPath",
      "ffprobePath",
      "claim",
      "outside",
      "backup.dir",
    ]) {
      expect(DEFINITIONS.has(key), key).toBe(false);
    }
  });
});

describe("the store", () => {
  it("is made from the file on first start, and the server runs as it did", async () => {
    mkdirSync(join(dir, "data"));
    writeConfig({
      serverName: "Den",
      roots: [{ path: join(dir, "drive", "Films"), name: "Films", hint: "movies" }],
      conversion: { hours: "01:00-07:00" },
      backup: { keep: 3 },
    });
    const before = loadConfig(configPath);
    await start();
    const stored = readSettings(join(dir, "data"));
    expect(stored?.version).toBe(1);
    expect(stored?.values["serverName"]).toBe("Den");
    expect(stored?.values["backup.keep"]).toBe(3);
    // Defaults stay defaults: what the file left out is not written in.
    expect(Object.hasOwn(stored?.values ?? {}, "language")).toBe(false);
    expect(loadConfig(configPath)).toEqual(before);
  });

  it("wins over the file for its keys once it exists; the file keeps the rest", async () => {
    await start({ serverName: "Den" });
    const changed = await patch({ serverName: "Attic" });
    expect(changed.status).toBe(200);
    await running?.close();
    running = null;
    writeConfig({ serverName: "Cellar", language: "nl-NL" });
    const config = loadConfig(configPath);
    expect(config.serverName).toBe("Attic");
    // Not in the store, so the default, not the file's: the store holds what was set when it was made.
    expect(config.language).toBe("en-US");
    expect(config.host).toBe("127.0.0.1");
  });

  it("starts a fresh server without folders, and looks through nothing", async () => {
    await start();
    expect(running?.services.scanner.isScanning).toBe(false);
    expect(running?.services.db.all("select * from source")).toEqual([]);
  });
});

describe("reading the settings", () => {
  it("gives the schema and the values, and a secret only as set or not set", async () => {
    process.env["LOBBY_TMDB_API_KEY"] = GOOD_KEY;
    await start({ serverName: "Den" });
    const reply = await ask("GET", "/v1/settings");
    expect(reply.status).toBe(200);
    expect(setting(reply, "serverName")).toMatchObject({
      value: "Den",
      apply: "live",
      section: "general",
    });
    expect(setting(reply, "advertise")).toMatchObject({ apply: "restart" });
    expect(reply.body["secrets"]).toEqual({
      tmdbKey: { set: true, source: "environment" },
      omdbKey: { set: false, source: null },
    });
    expect(reply.text).not.toContain(GOOD_KEY);
    expect(reply.headers.get("Cache-Control")).toBe("no-store");
  });

  it("says the upload limit needs the direct connection set up in the file", async () => {
    await start();
    expect(setting(await ask("GET", "/v1/settings"), "outside.direct.maxUploadMbit")).toMatchObject(
      {
        available: false,
      },
    );
  });
});

describe("changing the settings", () => {
  it("explains a dry run and changes nothing", async () => {
    await start();
    const reply = await patch(
      {
        roots: [
          { path: join(dir, "drive", "Films"), hint: "movies" },
          { path: join(dir, "drive", "Series"), hint: "series" },
        ],
        advertise: true,
      },
      { dryRun: true },
    );
    expect(reply.status).toBe(200);
    expect(reply.body).toMatchObject({ dryRun: true, restart: true, rescanFolders: 2, version: 1 });
    const messages = (reply.body["effects"] as { message: string }[]).map((one) => one.message);
    expect(messages).toContain("Will look through 2 new folders.");
    expect(messages.some((one) => one.includes("restarts"))).toBe(true);
    expect(readSettings(join(dir, "data"))?.version).toBe(1);
    expect(running?.services.db.all("select * from source")).toEqual([]);
    expect(restarts).toBe(0);
  });

  it("takes the name, the folders, converting, the addresses and backups at once", async () => {
    makeVideo(join(dir, "drive", "Films", "Night Train (1999).mp4"));
    await start({
      roots: [{ path: join(dir, "drive", "Series"), hint: "series" }],
      conversion: { dir: join(dir, "drive", "lobby") },
    });
    const reply = await patch({
      serverName: "Attic",
      roots: [
        { path: join(dir, "drive", "Series"), hint: "series" },
        { path: join(dir, "drive", "Films"), hint: "movies", name: "Films" },
      ],
      "conversion.hours": "02:00-06:00",
      "addresses.remote": ["http://media.example.org:8674"],
      "backup.everyHours": 0,
    });
    expect(reply.status).toBe(200);
    expect(reply.body).toMatchObject({ restart: false, restarting: false, version: 2 });
    expect(restarts).toBe(0);
    expect((await ask("GET", "/v1/server", undefined, { token: null })).body["name"]).toBe("Attic");
    await until(
      () =>
        (running?.services.db.get<{ n: number }>(
          "select count(*) as n from item where kind = 'movie'",
        )?.n ?? 0) > 0,
    );
    expect(running?.app).toBeDefined();
    const me = await ask("GET", "/v1/me");
    expect((me.body["server"] as { addresses: { remote: string[] } }).addresses.remote).toEqual([
      "http://media.example.org:8674",
    ]);
    // The new name is let in at once.
    const byName = await server().app.request("http://media.example.org:8674/v1/server", {
      headers: { Host: "media.example.org:8674" },
    });
    expect(byName.status).toBe(200);
    const conversion = await ask("GET", "/v1/conversion");
    expect(conversion.body["hours"]).toEqual({ from: 120, to: 360 });
    expect(running?.settings.current.changed.sort()).toEqual(
      ["serverName", "roots", "conversion.hours", "addresses.remote", "backup.everyHours"].sort(),
    );
  });

  it("restarts for what cannot be taken while it runs", async () => {
    await start();
    const reply = await patch({ language: "nl-NL" });
    expect(reply.body).toMatchObject({ restart: true, restarting: true });
    await until(() => restarts === 1);
    expect(readSettings(join(dir, "data"))?.values["language"]).toBe("nl-NL");
    const busy = await patch({ serverName: "Other" });
    expect(busy.status).toBe(503);
  });

  it("has no way to change where it listens or what it runs", async () => {
    await start();
    for (const [key, value] of [
      ["host", "0.0.0.0"],
      ["port", 80],
      ["dataDir", "/tmp"],
      ["ffmpegPath", "/bin/sh"],
      ["outside.direct.binary", "/bin/sh"],
      ["claim", "open"],
    ] as const) {
      expect((await patch({ [key]: value })).status, key).toBe(400);
    }
  });

  it("refuses a wrong value of every kind, says which, and keeps everything as it was", async () => {
    await start({ serverName: "Den" });
    const before = structuredClone(running?.services && loadConfig(configPath));
    const fileBefore = readFileSync(configPath, "utf8");
    const wrong: [string, unknown][] = [
      ["serverName", ""],
      ["advertise", "yes"],
      ["language", "Dutch"],
      ["roots", "/media"],
      ["roots", [{ path: "relative/path", hint: "movies" }]],
      ["roots", [{ path: join(dir, "drive", "Films"), hint: "cartoons" }]],
      ["roots", [{ path: join(dir, "drive", "Films"), hint: "movies", extra: 1 }]],
      ["rescanMinutes", 0],
      ["conversion.hours", "1-7"],
      ["conversion.hours", "01:00-01:00"],
      ["conversion.server", 1],
      ["conversion.minFreeGb", -1],
      ["addresses.remote", ["ftp://x.example.org"]],
      ["addresses.remote", "http://x.example.org"],
      ["backup.keep", 0],
      ["probeConcurrency", 9],
      ["nope", 1],
    ];
    for (const [key, value] of wrong) {
      const reply = await patch({ [key]: value });
      expect(reply.status, `${key} ${JSON.stringify(value)}`).toBe(400);
      expect((reply.body["problems"] as { key: string | null }[])[0]?.key ?? key).toBe(key);
    }
    expect(readSettings(join(dir, "data"))?.version).toBe(1);
    expect(readFileSync(configPath, "utf8")).toBe(fileBefore);
    expect(loadConfig(configPath)).toEqual(before);
    expect(running?.settings.audit(100).filter((one) => one["action"] === "refused").length).toBe(
      wrong.length,
    );
  });

  it("refuses folders outside the drives and the home folder, also by a way round", async () => {
    await start();
    symlinkSync(join(dir, "elsewhere"), join(dir, "drive", "out"));
    for (const path of [
      join(dir, "elsewhere"),
      join(dir, "drive", "..", "elsewhere"),
      join(dir, "drive", "out"),
      join(dir, "drive", "missing"),
      join(dir, "drive", ".hidden"),
      "/etc",
    ]) {
      const reply = await patch({ roots: [{ path, hint: "movies" }] });
      expect(reply.status, path).toBe(400);
    }
    // Lobby's folder may be one it makes, but on a drive.
    expect((await patch({ "conversion.dir": join(dir, "elsewhere", "lobby") })).status).toBe(400);
    expect((await patch({ "conversion.dir": join(dir, "drive", "Films", "lobby") })).status).toBe(
      200,
    );
    expect(readSettings(join(dir, "data"))?.values["conversion.dir"]).toBe(
      join(dir, "drive", "Films", "lobby"),
    );
  });

  it("refuses Lobby's folder inside a library folder, which the config forbids", async () => {
    await start({ roots: [{ path: join(dir, "drive", "Films"), hint: "movies" }] });
    const reply = await patch({ "conversion.dir": join(dir, "drive", "Films", ".lobby") });
    expect(reply.status).toBe(400);
    const inside = await patch({ "conversion.dir": join(dir, "drive", "Films", "lobby") });
    expect(inside.status).toBe(400);
    expect(
      String(
        inside.body["problems"] && (inside.body["problems"] as { message: string }[])[0]?.message,
      ),
    ).toContain("outside every library folder");
  });

  it("refuses a change on top of one it did not see", async () => {
    await start();
    expect((await patch({ serverName: "A" }, { baseVersion: 1 })).status).toBe(200);
    expect((await patch({ serverName: "B" }, { baseVersion: 1 })).status).toBe(409);
    expect(readSettings(join(dir, "data"))?.values["serverName"]).toBe("A");
  });

  it("leaves the server as it was when the change cannot be kept", async () => {
    await start({ serverName: "Den" });
    const settingsFolder = join(dir, "data", "settings");
    chmodSync(settingsFolder, 0o500);
    try {
      const reply = await patch({ serverName: "Attic", "backup.keep": 2 });
      expect(reply.status).toBe(503);
      expect(
        String(reply.body["error"] && (reply.body["error"] as { message: string }).message),
      ).toContain("Nothing was changed");
    } finally {
      chmodSync(settingsFolder, 0o700);
    }
    expect((await ask("GET", "/v1/server", undefined, { token: null })).body["name"]).toBe("Den");
    const reply = await ask("GET", "/v1/settings");
    expect(reply.body["version"]).toBe(1);
    expect(setting(reply, "backup.keep")?.["value"]).toBe(7);
    expect(readdirSync(settingsFolder).filter((name) => name.endsWith(".writing"))).toEqual([]);
  });

  it("keeps the versions before, and restores one as a new version", async () => {
    await start({ serverName: "Den" });
    await patch({ serverName: "Attic" });
    await patch({ serverName: "Loft" });
    const history = await ask("GET", "/v1/settings/history");
    expect((history.body["versions"] as { version: number }[]).map((one) => one.version)).toEqual([
      3, 2, 1,
    ]);
    const dry = await ask("POST", "/v1/settings/history/1/restore", { dryRun: true });
    expect(dry.body).toMatchObject({ dryRun: true, changed: ["serverName"] });
    const restored = await ask("POST", "/v1/settings/history/1/restore", {});
    expect(restored.body).toMatchObject({ version: 4 });
    expect((await ask("GET", "/v1/server", undefined, { token: null })).body["name"]).toBe("Den");
    expect(settingsHistory(join(dir, "data")).map((one) => one.version)).toEqual([3, 2, 1]);
    expect((await ask("POST", "/v1/settings/history/99/restore", {})).status).toBe(404);
    const audit = await ask("GET", "/v1/settings/audit");
    expect((audit.body["entries"] as { action: string }[]).map((one) => one.action)).toEqual([
      "restore",
      "change",
      "change",
    ]);
  });

  it("goes into backups, without a secret, and comes back with a restore", async () => {
    await start({ serverName: "Den" });
    await patch({ serverName: "Attic" });
    const services = server().services;
    const backup = await createBackup(
      services.db,
      join(dir, "backups"),
      configPath,
      Date.now(),
      join(dir, "data"),
    );
    expect(
      (
        JSON.parse(readFileSync(join(backup.path, "settings.json"), "utf8")) as {
          values: Record<string, unknown>;
        }
      ).values["serverName"],
    ).toBe("Attic");
    expect(readdirSync(backup.path)).not.toContain("secrets.json");
    const target = join(dir, "restored");
    expect(restoreBackup(backup.path, target).join(" ")).toContain("settings");
    expect(readSettings(target)?.values["serverName"]).toBe("Attic");
  });
});

describe("who may change the settings", () => {
  it("managers only, close by only, a sensible amount only", async () => {
    await start();
    const viewer = server().services.devices.createOutsideViewer("TV", "tvos").token;
    for (const [method, path] of [
      ["GET", "/v1/settings"],
      ["PATCH", "/v1/settings"],
      ["GET", "/v1/settings/history"],
      ["POST", "/v1/settings/history/1/restore"],
      ["GET", "/v1/settings/audit"],
      ["GET", "/v1/settings/browse"],
      ["PUT", "/v1/settings/tmdb"],
      ["DELETE", "/v1/settings/tmdb"],
      ["GET", "/v1/setup"],
      ["POST", "/v1/setup/steps/name"],
      ["POST", "/v1/setup/finish"],
    ] as const) {
      const body =
        method === "GET" || method === "DELETE" ? undefined : { changes: { serverName: "X" } };
      expect((await ask(method, path, body, { token: viewer })).status, `${method} ${path}`).toBe(
        403,
      );
      expect((await ask(method, path, body, { token: null })).status, `${method} ${path}`).toBe(
        401,
      );
      // From the internet, even with a manager's credential.
      expect((await ask(method, path, body, { peer: "8.8.8.8" })).status, `${method} ${path}`).toBe(
        403,
      );
    }
    // At home and over Tailscale it is fine.
    expect((await ask("GET", "/v1/settings", undefined, { peer: "192.168.1.20" })).status).toBe(
      200,
    );
    expect((await ask("GET", "/v1/settings", undefined, { peer: "100.101.102.103" })).status).toBe(
      200,
    );
    expect((await ask("GET", "/v1/settings")).body["version"]).toBe(1);
  });

  it("refuses a body that is too large", async () => {
    await start();
    const reply = await ask("PATCH", "/v1/settings", undefined, {
      raw: JSON.stringify({ changes: { serverName: "x".repeat(200_000) } }),
    });
    expect(reply.status).toBe(400);
    expect((reply.body["error"] as { message: string }).message).toContain("too large");
  });

  it("refuses too many changes in a row", async () => {
    await start();
    let refused: Reply | null = null;
    for (let index = 0; index < 30 && refused === null; index += 1) {
      const reply = await patch({ serverName: `Name ${String(index)}` }, { dryRun: true });
      if (reply.status === 429) refused = reply;
    }
    expect(refused?.headers.get("Retry-After")).toMatch(/^\d+$/);
  });
});

describe("looking through the server's folders", () => {
  beforeEach(() => {
    makeVideo(join(dir, "drive", "Films", "A (2001).mp4"));
    makeVideo(join(dir, "drive", "Films", "Inner", "B (2002).mkv"));
    writeFileSync(join(dir, "drive", "Films", "notes.txt"), "");
    mkdirSync(join(dir, "drive", ".Trash"));
    mkdirSync(join(dir, "drive", "lost+found"));
    writeFileSync(join(dir, "elsewhere", "secret.mp4"), "");
    symlinkSync(join(dir, "elsewhere"), join(dir, "drive", "escape"));
    symlinkSync(join(dir, "drive", "Series"), join(dir, "drive", "Shortcut"));
  });

  it("starts at the drives and the home folder", async () => {
    await start();
    const reply = await ask("GET", "/v1/settings/browse");
    expect(reply.status).toBe(200);
    expect((reply.body["folders"] as { name: string }[]).map((one) => one.name)).toEqual([
      "drive",
      "home",
    ]);
    expect(reply.body["path"]).toBeNull();
  });

  it("shows folders with their video files, without hidden ones and without ways out", async () => {
    await start();
    const drive = await ask(
      "GET",
      `/v1/settings/browse?path=${encodeURIComponent(join(dir, "drive"))}`,
    );
    const folders = drive.body["folders"] as { name: string; videoFiles: number; path: string }[];
    expect(folders.map((one) => one.name)).toEqual(["Films", "Series", "Shortcut"]);
    expect(folders[0]?.videoFiles).toBe(2);
    // A link within the allowed places shows where it leads.
    expect(folders[2]?.path).toBe(
      running && (await import("node:fs")).realpathSync(join(dir, "drive", "Series")),
    );
    expect(drive.text).not.toContain("elsewhere");
    expect(drive.body["parent"]).toBeNull();
    const films = await ask(
      "GET",
      `/v1/settings/browse?path=${encodeURIComponent(join(dir, "drive", "Films"))}`,
    );
    expect(films.body).toMatchObject({ videoFiles: 1 });
    expect(films.text).not.toContain("notes.txt");
  });

  it("refuses everything outside, however it is asked", async () => {
    await start();
    const refused: [string, number][] = [
      [join(dir, "elsewhere"), 403],
      [join(dir, "drive", "..", "elsewhere"), 403],
      [join(dir, "drive", "escape"), 403],
      [join(dir, "drive", "..", "..", "..", "etc"), 403],
      ["/etc", 403],
      ["/", 403],
      [join(dir, "drive", ".Trash"), 403],
      [join(dir, "drive", "lost+found"), 403],
      ["drive/Films", 400],
      [join(dir, "drive", "Films", "A (2001).mp4"), 400],
      [join(dir, "drive", "nothing"), 404],
      [`${join(dir, "drive")}\0/x`, 400],
    ];
    for (const [path, status] of refused) {
      const reply = await ask("GET", `/v1/settings/browse?path=${encodeURIComponent(path)}`);
      expect(reply.status, path).toBe(status);
      expect(reply.text).not.toContain("secret.mp4");
    }
  });

  it("reads only: nothing is made or changed in the folders", async () => {
    await start();
    const before = readdirSync(join(dir, "drive"), { recursive: true }).sort();
    await ask("GET", `/v1/settings/browse?path=${encodeURIComponent(join(dir, "drive"))}`);
    await ask("GET", `/v1/settings/browse?path=${encodeURIComponent(join(dir, "drive", "Films"))}`);
    expect(readdirSync(join(dir, "drive"), { recursive: true }).sort()).toEqual(before);
  });

  it("also works on its own, with the mounted drives of this machine", async () => {
    const listing = await new FolderBrowser().list(undefined);
    expect(listing.folders.length).toBeGreaterThan(0);
  });
});

describe("the TMDB key", () => {
  let tmdb: LocalTmdb;

  beforeEach(async () => {
    tmdb = await LocalTmdb.start(Buffer.from([0xff, 0xd8, 0xff, 0xd9]));
    tmdb.intercept = (request) => {
      if (request.path !== "/3/configuration") return null;
      const key = request.query.get("api_key");
      return key === GOOD_KEY
        ? { body: { images: {} } }
        : { status: 401, body: { status_code: 7, status_message: "Invalid API key" } };
    };
  });

  afterEach(async () => {
    await tmdb.stop();
  });

  it("is checked with TMDB, kept in the secrets, and never comes back or into the log", async () => {
    const output = vi.spyOn(process.stdout, "write");
    await start({}, `${tmdb.origin}/3`);
    const wrong = await ask("PUT", "/v1/settings/tmdb", { key: WRONG_KEY });
    expect(wrong.status).toBe(400);
    expect((wrong.body["error"] as { message: string }).message).toContain("does not accept");
    const notAKey = await ask("PUT", "/v1/settings/tmdb", { key: "hello" });
    expect(notAKey.status).toBe(400);
    expect(tmdb.requests("/3/configuration").length).toBe(1);

    const set = await ask("PUT", "/v1/settings/tmdb", { key: ` ${GOOD_KEY} ` });
    expect(set.status).toBe(200);
    expect(set.body).toEqual({ tmdbKey: { set: true, source: "settings" } });
    expect(secrets().tmdbApiKey).toBe(GOOD_KEY);
    for (const path of [
      "/v1/settings",
      "/v1/settings/audit",
      "/v1/settings/history",
      "/v1/setup",
      "/v1/me",
      "/v1/status",
    ]) {
      expect((await ask("GET", path)).text, path).not.toContain(GOOD_KEY);
    }
    expect(readFileSync(join(dir, "data", "settings", "settings.json"), "utf8")).not.toContain(
      GOOD_KEY,
    );
    const logged = output.mock.calls.map((call) => String(call[0])).join("");
    output.mockRestore();
    expect(logged).not.toContain(GOOD_KEY);
    expect(logged).not.toContain(WRONG_KEY);

    const removed = await ask("DELETE", "/v1/settings/tmdb");
    expect(removed.body).toEqual({ tmdbKey: { set: false, source: null } });
    expect(secrets().tmdbApiKey).toBeNull();
    // The setup secret is still there.
    expect(secrets().setupSecret).toEqual(running?.services.setupSecret);
  });

  it("says so when TMDB cannot be reached, and keeps nothing", async () => {
    await start({}, "http://127.0.0.1:9/3");
    const reply = await ask("PUT", "/v1/settings/tmdb", { key: GOOD_KEY });
    expect(reply.status).toBe(503);
    expect(secrets().tmdbApiKey).toBeNull();
  });

  it("cannot be changed in the app when the environment sets it", async () => {
    process.env["LOBBY_TMDB_API_KEY"] = GOOD_KEY;
    await start({}, `${tmdb.origin}/3`);
    expect((await ask("PUT", "/v1/settings/tmdb", { key: GOOD_KEY })).status).toBe(409);
    expect((await ask("DELETE", "/v1/settings/tmdb")).status).toBe(409);
  });

  it("is asked about the way the enricher asks", async () => {
    expect(await checkTmdbKey(GOOD_KEY, `${tmdb.origin}/3`)).toBe("accepted");
    expect(await checkTmdbKey(WRONG_KEY, `${tmdb.origin}/3`)).toBe("refused");
    tmdb.intercept = (request) =>
      request.headers["authorization"] === "Bearer aaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbb.cccccccccccc"
        ? { body: {} }
        : { status: 401 };
    expect(
      await checkTmdbKey("aaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbb.cccccccccccc", `${tmdb.origin}/3`),
    ).toBe("accepted");
  });
});

describe("the OMDb key", () => {
  let omdb: Server;
  let origin: string;
  let asked: number;

  beforeEach(async () => {
    asked = 0;
    omdb = createServer((request, response) => {
      asked += 1;
      const key = new URL(request.url ?? "/", "http://localhost").searchParams.get("apikey");
      response.writeHead(key === "omdbgood1" ? 200 : 401, { "content-type": "application/json" });
      response.end(
        JSON.stringify(
          key === "omdbgood1"
            ? { Response: "True", imdbRating: "9.3", Ratings: [] }
            : { Response: "False", Error: "Invalid API key!" },
        ),
      );
    });
    await new Promise<void>((resolve) => omdb.listen(0, "127.0.0.1", resolve));
    origin = `http://127.0.0.1:${String((omdb.address() as AddressInfo).port)}/`;
  });

  afterEach(async () => {
    await new Promise<void>((resolve) => {
      omdb.close(() => {
        resolve();
      });
    });
  });

  it("is off until the owner sets one, checked with OMDb, and never comes back", async () => {
    await start({}, undefined, true, origin);
    expect((await ask("GET", "/v1/settings")).body["secrets"]).toMatchObject({
      omdbKey: { set: false, source: null },
    });
    // Nothing was asked without a key.
    expect(asked).toBe(0);
    expect((await ask("PUT", "/v1/settings/omdb", { key: "x" })).status).toBe(400);
    const wrong = await ask("PUT", "/v1/settings/omdb", { key: "omdbwrong" });
    expect(wrong.status).toBe(400);
    const set = await ask("PUT", "/v1/settings/omdb", { key: " omdbgood1 " });
    expect(set.body).toEqual({ omdbKey: { set: true, source: "settings" } });
    expect(secrets().omdbApiKey).toBe("omdbgood1");
    expect((await ask("GET", "/v1/settings")).text).not.toContain("omdbgood1");
    expect((await ask("GET", "/v1/settings/audit")).text).not.toContain("omdbgood1");
    const removed = await ask("DELETE", "/v1/settings/omdb");
    expect(removed.body).toEqual({ omdbKey: { set: false, source: null } });
    expect(secrets().omdbApiKey).toBeNull();
    expect(secrets().setupSecret).toEqual(running?.services.setupSecret);
  });
});

describe("the first setup", () => {
  it("follows the claim of a fresh server, and nothing is looked through until it is done", async () => {
    makeVideo(join(dir, "drive", "Films", "Night Train (1999).mp4"));
    await start({}, undefined, false);
    const claim = await ask(
      "POST",
      "/v1/pairing/claim",
      { deviceName: "Phone", platform: "ios" },
      { token: null },
    );
    expect(claim.status).toBe(201);
    expect(claim.body["setup"]).toMatchObject({ needed: true });
    manager = claim.body["token"] as string;
    const me = await ask("GET", "/v1/me");
    expect((me.body["server"] as { setup: { needed: boolean } }).setup.needed).toBe(true);

    expect((await ask("POST", "/v1/setup/finish")).status).toBe(409);
    await patch({ serverName: "Attic" });
    await patch({ roots: [{ path: join(dir, "drive", "Films"), hint: "movies", name: "Films" }] });
    expect((await ask("POST", "/v1/setup/steps/tmdb", { state: "skipped" })).body).toMatchObject({
      needed: true,
      steps: [
        { id: "name", done: true },
        { id: "folders", done: true },
        { id: "tmdb", done: true, skipped: true },
        { id: "scan", done: false },
      ],
    });
    await new Promise((resolve) => setTimeout(resolve, 500));
    expect(running?.services.db.get<{ n: number }>("select count(*) as n from asset")?.n).toBe(0);

    const finished = await ask("POST", "/v1/setup/finish");
    expect(finished.body).toMatchObject({ needed: false });
    await until(
      () =>
        (running?.services.db.get<{ n: number }>(
          "select count(*) as n from item where kind = 'movie'",
        )?.n ?? 0) > 0,
    );
    // Without a key, titles come from the file names.
    expect(
      running?.services.db.get<{ title: string }>("select title from item where kind = 'movie'")
        ?.title,
    ).toBe("Night Train");
  });

  it("is not asked of a server that already has folders", async () => {
    await start({ roots: [{ path: join(dir, "drive", "Films"), hint: "movies" }] });
    expect((await ask("GET", "/v1/setup")).body).toMatchObject({ needed: false });
  });

  it("refuses a step there is not", async () => {
    await start();
    expect((await ask("POST", "/v1/setup/steps/folders", { state: "done" })).status).toBe(404);
    expect((await ask("POST", "/v1/setup/steps/name", { state: "maybe" })).status).toBe(400);
    expect((await ask("POST", "/v1/setup/steps/tmdb", { state: "done" })).status).toBe(409);
  });
});

describe("the config", () => {
  it("still reads a file as it did", () => {
    writeConfig({ roots: [{ path: join(dir, "drive", "Films"), hint: "movies" }] });
    const config = parseConfig(readConfigFile(configPath), configPath);
    expect(config.roots[0]).toMatchObject({ name: "Films", hint: "movies" });
    expect(() =>
      parseConfig({ roots: [{ path: join(dir, "x"), hint: "movies", name: 5 }] }, configPath),
    ).toThrow("name");
  });
});
