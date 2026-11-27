// SPDX-License-Identifier: MPL-2.0
// Playing on HomePods and AirPlay speakers (docs/decisions.md, "Play on a speaker"): the server
// streams to them through the helper. The helper here is the stand-in of the Apple TV tests
// (support/fake-wake.ts), which runs the real ffmpeg on the real files and reaches no network.
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { serve, type ServerType } from "@hono/node-server";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { loadConfig, parseConfig } from "../src/config.ts";
import { WakeHelper } from "../src/remote/wake-helper.ts";
import { startServer, type RunningServer } from "../src/server.ts";
import { makeAudio } from "./support/audio.ts";
import { LiveClient } from "./support/live.ts";
import { makeTempDir, removeDir } from "./support/media.ts";
import { until } from "./support/outside.ts";

const FAKE = fileURLToPath(new URL("./support/fake-wake.ts", import.meta.url));
const FAKE_PYATV = fileURLToPath(new URL("./support/fake-pyatv/run.py", import.meta.url));
const EVENTS = new URL("../../../docs/fixtures/remote/events.json", import.meta.url);

/** The keys of a message, all the way down, without the values. */
function shape(value: unknown): unknown {
  if (Array.isArray(value)) return value.length === 0 ? [] : [shape(value[0])];
  if (typeof value !== "object" || value === null) return "value";
  return Object.fromEntries(
    Object.entries(value)
      .sort(([a], [b]) => (a < b ? -1 : 1))
      .map(([key, one]) => [key, shape(one)]),
  );
}

interface Reply {
  status: number;
  body: Record<string, unknown>;
}

interface Speaker {
  id: string;
  name: string;
  kind: string;
  canPlay: boolean;
  access: string;
  volume: number | null;
  controllable: boolean;
  play: Record<string, unknown> | null;
}

let dir: string;
let state: string;
let running: RunningServer | null = null;
let server: ServerType | null = null;
let port = 0;
let manager: string;
let clients: LiveClient[] = [];
let tracks: { id: string; title: string; albumId: string | null; bookId: string | null }[] = [];
let books: { id: string; durationMs: number; parts: { trackId: string; startMs: number }[] }[] = [];

const SPEAKERS = [
  { id: "11:22", name: "Kitchen", model: "HomePod", kind: "homepod", access: "open" },
  { id: "33:44", name: "Bedroom", model: "HomePod mini", kind: "homepod", access: "home_only" },
];

const setState = (more: Record<string, unknown> = {}): void => {
  writeFileSync(
    join(state, "tvs.json"),
    JSON.stringify({ televisions: [], speakers: SPEAKERS, ...more }),
  );
};

const changeState = (change: (all: Record<string, unknown>) => void): void => {
  const all = JSON.parse(readFileSync(join(state, "tvs.json"), "utf8")) as Record<string, unknown>;
  change(all);
  writeFileSync(join(state, "tvs.json"), JSON.stringify(all));
};

const logged = (): Record<string, unknown>[] =>
  existsSync(join(state, "log.jsonl"))
    ? readFileSync(join(state, "log.jsonl"), "utf8")
        .trim()
        .split("\n")
        .filter((line) => line !== "")
        .map((line) => JSON.parse(line) as Record<string, unknown>)
    : [];

const streams = (): Record<string, unknown>[] => logged().filter((one) => one["op"] === "stream");

async function start(
  wake: Record<string, unknown> = { pyatv: "/nowhere/bin" },
  found = 2,
): Promise<void> {
  const music = join(dir, "Music");
  const stories = join(dir, "Stories");
  const tags = { artist: "The Band", album: "Songs", album_artist: "The Band" };
  makeAudio(join(music, "Band/Songs/1.flac"), {
    tags: { ...tags, title: "One", track: "1" },
    seconds: 3,
  });
  makeAudio(join(music, "Band/Songs/2.mp3"), {
    tags: { ...tags, title: "Two", track: "2" },
    seconds: 3,
    tone: 500,
  });
  makeAudio(join(music, "Band/Songs/3.opus"), {
    tags: { ...tags, title: "Three", track: "3" },
    seconds: 3,
    tone: 600,
  });
  const book = { album: "The Long Story", artist: "Reader", album_artist: "Reader" };
  makeAudio(join(stories, "Reader/The Long Story/01.mp3"), {
    tags: { ...book, title: "Part One", track: "1" },
    seconds: 8,
    tone: 700,
  });
  makeAudio(join(stories, "Reader/The Long Story/02.mp3"), {
    tags: { ...book, title: "Part Two", track: "2" },
    seconds: 8,
    tone: 800,
  });
  const configPath = join(dir, "lobby.config.json");
  writeFileSync(
    configPath,
    JSON.stringify({
      host: "127.0.0.1",
      port: 0,
      stabilityMs: 0,
      advertise: false,
      dataDir: join(dir, "data"),
      roots: [
        { path: music, name: "Music", hint: "music" },
        { path: stories, name: "Stories", hint: "audiobooks" },
      ],
      remote: { wake },
    }),
  );
  running = await startServer(loadConfig(configPath), {
    wakeHelper: () =>
      new WakeHelper({
        python: process.execPath,
        flags: [],
        script: FAKE,
        args: ["--state", state],
      }),
    speakerTimings: { scanEveryMs: 60_000, kidsEveryMs: 200, tickMs: 100, saveEveryMs: 500 },
  });
  manager = running.services.devices.createLocalManager("Desk").token;
  server = await new Promise((done) => {
    const made = serve(
      { fetch: running?.app.fetch ?? (() => new Response()), hostname: "127.0.0.1", port: 0 },
      () => {
        done(made);
      },
    );
  });
  const address = server?.address();
  port = typeof address === "object" && address !== null ? address.port : 0;
  await running.services.music.scanner.scanAll();
  await running.services.music.scanner.processQueue();
  await until(async () => {
    const library = await ask("GET", "/v1/music/library");
    tracks = (library.body["tracks"] ?? []) as typeof tracks;
    books = (library.body["books"] ?? []) as typeof books;
    return tracks.length === 5 && books.length === 1;
  });
  await until(
    async () =>
      ((await ask("GET", "/v1/speakers")).body["speakers"] as unknown[] | undefined)?.length ===
      found,
  );
}

function device(
  name: string,
  platform: "tvos" | "ios" | "ipados" | "macos",
): { id: string; token: string } {
  if (!running) throw new Error("not running");
  const made = running.services.devices.createOutsideViewer(name, platform);
  running.services.devices.setAllowOutside(made.device.id, false);
  return { id: made.device.id, token: made.token };
}

async function ask(
  method: string,
  path: string,
  body?: unknown,
  options: { token?: string; peer?: string } = {},
): Promise<Reply> {
  if (!running) throw new Error("not running");
  const env =
    options.peer === undefined
      ? undefined
      : { incoming: { socket: { remoteAddress: options.peer } } };
  const response = await running.app.request(
    `http://127.0.0.1${path}`,
    {
      method,
      headers: {
        Host: "127.0.0.1",
        Authorization: `Bearer ${options.token ?? manager}`,
        ...(body === undefined ? {} : { "Content-Type": "application/json" }),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    },
    env,
  );
  const text = await response.text();
  let parsed: Record<string, unknown> = {};
  try {
    parsed = JSON.parse(text) as Record<string, unknown>;
  } catch {
    // Not JSON.
  }
  return { status: response.status, body: parsed };
}

const reason = (reply: Reply): unknown => [
  (reply.body["error"] as { code?: string } | undefined)?.code ?? null,
  reply.body["reason"] ?? null,
];

async function live(
  who: { id: string; token: string },
  more: Record<string, unknown> = {},
): Promise<LiveClient> {
  const made = new LiveClient(who, port);
  clients.push(made);
  await made.open();
  expect(made.status).toBe(200);
  expect((await made.announce(more)).status).toBe(200);
  return made;
}

/** The speakers a channel was told last. */
const told = (client: LiveClient): Speaker[] | null =>
  (client.of("speakers").at(-1)?.data["speakers"] as Speaker[] | undefined) ?? null;

const speakerNamed = (client: LiveClient, name: string): Speaker | undefined =>
  told(client)?.find((one) => one.name === name);

async function profile(name: string, kids = false): Promise<string> {
  const made = await ask("POST", "/v1/profiles", {
    name,
    ...(kids
      ? {
          kids: {
            allowedGroupIds: [],
            allowedCategoryIds: [],
            allowedItemIds: [],
            blockedItemIds: [],
            blockedCategoryIds: [],
          },
        }
      : {}),
  });
  expect(made.status).toBe(201);
  return made.body["id"] as string;
}

const trackId = (title: string): string => {
  const found = tracks.find((one) => one.title === title);
  if (!found) throw new Error(`no track ${title}`);
  return found.id;
};

const songs = (): string[] => ["One", "Two", "Three"].map(trackId);

beforeEach(() => {
  dir = makeTempDir("lobby-speakers-");
  state = join(dir, "fake");
  mkdirSync(state);
  setState();
});

afterEach(async () => {
  for (const one of clients) one.cut();
  clients = [];
  if (server) {
    if ("closeAllConnections" in server) server.closeAllConnections();
    await new Promise((done) => server?.close(done));
  }
  server = null;
  await running?.close();
  running = null;
  removeDir(dir);
});

describe("remote.wake.speakers in the config", () => {
  const parse = (wake: unknown): boolean | undefined =>
    parseConfig({ remote: { wake } }, "/srv/lobby/lobby.config.json").wake?.speakers;

  it("is on unless turned off, and only true or false", () => {
    expect(parse({ pyatv: "pyatv/bin" })).toBe(true);
    expect(parse({ pyatv: "pyatv/bin", speakers: false })).toBe(false);
    expect(() => parse({ pyatv: "pyatv/bin", speakers: "yes" })).toThrow(/speakers/);
  });
});

describe("finding speakers", () => {
  it("shows them in Play On, as a manager names them, without the hidden ones", async () => {
    await start();
    const phone = device("Phone", "ios");
    const channel = await live(phone);
    await until(() => (told(channel)?.length ?? 0) === 2);
    expect(speakerNamed(channel, "Kitchen")).toMatchObject({
      kind: "homepod",
      canPlay: true,
      access: "open",
      play: null,
    });
    // It lets only its Home play: said before anyone tries.
    expect(speakerNamed(channel, "Bedroom")?.access).toBe("home_only");

    const listed = (await ask("GET", "/v1/speakers")).body;
    expect(listed).toMatchObject({ configured: true, enabled: true, running: true });
    const kitchen = (listed["speakers"] as Record<string, unknown>[]).find(
      (one) => one["foundName"] === "Kitchen",
    );
    expect(kitchen).toMatchObject({ found: true, hidden: false, customName: null });
    // pyatv's identifier stays on the server.
    expect(JSON.stringify(listed)).not.toContain("11:22");
    const id = kitchen?.["id"] as string;

    expect((await ask("PATCH", `/v1/speakers/${id}`, { name: "Kitchen Speaker" })).status).toBe(
      200,
    );
    await until(() => speakerNamed(channel, "Kitchen Speaker") !== undefined);
    expect((await ask("PATCH", `/v1/speakers/${id}`, { hidden: true })).status).toBe(200);
    await until(() => told(channel)?.length === 1);
    expect(speakerNamed(channel, "Kitchen Speaker")).toBeUndefined();
    // Hidden is not there for playing either.
    const viewer = await profile("Alex");
    expect(
      (
        await ask(
          "POST",
          `/v1/speakers/${id}/play`,
          { session: channel.session, profileId: viewer, trackIds: songs() },
          { token: phone.token },
        )
      ).status,
    ).toBe(404);
  });

  it("is for managers to change, at home", async () => {
    await start();
    const phone = device("Phone", "ios");
    expect((await ask("GET", "/v1/speakers", undefined, { token: phone.token })).status).toBe(403);
    expect((await ask("GET", "/v1/speakers", undefined, { peer: "203.0.113.9" })).status).toBe(403);
  });

  it("forgets a speaker that is no longer on the network, after it missed two looks", async () => {
    await start();
    const channel = await live(device("Phone", "ios"));
    await until(() => (told(channel)?.length ?? 0) === 2);
    changeState((all) => {
      all["speakers"] = [SPEAKERS[0]];
    });
    await ask("POST", "/v1/speakers/scan");
    expect(told(channel)?.length).toBe(2);
    await ask("POST", "/v1/speakers/scan");
    await until(() => told(channel)?.length === 1);
    const listed = (await ask("GET", "/v1/speakers")).body["speakers"] as Record<string, unknown>[];
    expect(listed.find((one) => one["foundName"] === "Bedroom")?.["found"]).toBe(false);
  });

  it("says nothing of speakers without remote.wake, and nothing when they are turned off", async () => {
    await start({ pyatv: "/nowhere/bin", speakers: false }, 0);
    const channel = await live(device("Phone", "ios"));
    await until(() => told(channel) !== null);
    expect(told(channel)).toEqual([]);
    expect((await ask("PATCH", "/v1/speakers", { enabled: true })).status).toBe(200);
    await until(() => (told(channel)?.length ?? 0) === 2);
  });
});

describe("playing on a speaker", () => {
  it("streams the album from the server, and the phone is only the remote", async () => {
    await start();
    const phone = device("Phone", "ios");
    const channel = await live(phone);
    await until(() => speakerNamed(channel, "Kitchen") !== undefined);
    const id = speakerNamed(channel, "Kitchen")?.id ?? "";
    const viewer = await profile("Alex");
    const play = (body: Record<string, unknown>): Promise<Reply> =>
      ask(
        "POST",
        `/v1/speakers/${id}/play`,
        { session: channel.session, profileId: viewer, ...body },
        { token: phone.token },
      );
    const control = (body: Record<string, unknown>): Promise<Reply> =>
      ask(
        "POST",
        `/v1/speakers/${id}/control`,
        { session: channel.session, ...body },
        { token: phone.token },
      );

    const started = await play({ trackIds: songs(), index: 1 });
    expect(started.status).toBe(200);
    expect(started.body).toMatchObject({
      volume: 0.4,
      controllable: true,
      play: { redacted: false, kind: "music", status: "playing", trackId: trackId("Two") },
    });
    const first = streams()[0];
    expect(first).toMatchObject({ speaker: "11:22", startMs: 0, title: "Two", album: "Songs" });
    // The file itself, by its path on the server: nothing goes through anything else.
    expect(String(first?.["file"])).toMatch(/Band\/Songs\/2\.mp3$/);
    await until(() => speakerNamed(channel, "Kitchen")?.play?.["status"] === "playing");

    // The phone goes away; the music does not.
    channel.cut();
    await new Promise((done) => setTimeout(done, 300));
    expect(
      ((await ask("GET", "/v1/speakers")).body["speakers"] as Record<string, unknown>[]).find(
        (one) => one["foundName"] === "Kitchen",
      )?.["playing"],
    ).toBe(true);
    const back = await live(phone);
    await until(() => speakerNamed(back, "Kitchen")?.play?.["status"] === "playing");
    const remote = (body: Record<string, unknown>): Promise<Reply> =>
      ask(
        "POST",
        `/v1/speakers/${id}/control`,
        { session: back.session, ...body },
        { token: phone.token },
      );

    // Pause stops the stream; going on streams again from where it was.
    await new Promise((done) => setTimeout(done, 400));
    const paused = await remote({ type: "pause" });
    expect(paused.body["play"]).toMatchObject({ status: "paused" });
    const at = (paused.body["play"] as { positionMs: number }).positionMs;
    expect(at).toBeGreaterThan(300);
    await until(() => logged().some((one) => one["op"] === "stream_stop"));
    await until(() => logged().some((one) => one["op"] === "sent"));
    // What the speaker got was FLAC, decoded by ffmpeg from the file.
    expect(logged().find((one) => one["op"] === "sent")).toMatchObject({ flac: true });
    expect((logged().find((one) => one["op"] === "sent")?.["bytes"] as number) > 1_000).toBe(true);

    const resumed = await remote({ type: "resume" });
    expect(resumed.body["play"]).toMatchObject({ status: "playing" });
    expect(streams()[1]?.["startMs"]).toBe(at);

    expect((await remote({ type: "volume", volume: 0.25 })).body["volume"]).toBe(0.25);
    expect(logged().find((one) => one["op"] === "volume")).toMatchObject({ volume: 0.25 });

    const next = await remote({ type: "next" });
    expect(next.body["play"]).toMatchObject({ trackId: trackId("Three"), index: 2 });
    expect(streams()[2]).toMatchObject({ title: "Three", startMs: 0, volume: 0.25 });

    const skipped = await remote({ type: "skip", deltaMs: -2_000 });
    // Back across the start of the track into the one before.
    expect(skipped.body["play"]).toMatchObject({ trackId: trackId("Two"), status: "playing" });
    expect((skipped.body["play"] as { positionMs: number }).positionMs).toBeGreaterThan(900);

    const stopped = await remote({ type: "stop" });
    expect(stopped.body["play"]).toBeNull();
    await until(() => speakerNamed(back, "Kitchen")?.play === null);
    expect(reason(await control({ type: "pause" }))).toEqual(["conflict", "nothing_playing"]);
  });

  it("goes on with the next track by itself, and counts what was heard", async () => {
    await start();
    setState({ streamMs: 300 });
    const phone = device("Phone", "ios");
    const channel = await live(phone);
    await until(() => speakerNamed(channel, "Kitchen") !== undefined);
    const id = speakerNamed(channel, "Kitchen")?.id ?? "";
    const viewer = await profile("Alex");
    expect(
      (
        await ask(
          "POST",
          `/v1/speakers/${id}/play`,
          { session: channel.session, profileId: viewer, trackIds: songs() },
          { token: phone.token },
        )
      ).status,
    ).toBe(200);
    await until(() => speakerNamed(channel, "Kitchen")?.play?.["status"] === "ended");
    expect(streams().map((one) => one["title"])).toEqual(["One", "Two", "Three"]);
    const plays = await ask("GET", `/v1/music/profiles/${viewer}/plays`, undefined, {
      token: phone.token,
    });
    const heard = (plays.body["plays"] as { trackId: string; completed: boolean }[]).map(
      (one) => one.trackId,
    );
    expect(heard.sort()).toEqual(songs().sort());
  });

  it("plays a story from where the viewer was, and keeps the place for them", async () => {
    await start();
    const phone = device("Phone", "ios");
    const channel = await live(phone);
    await until(() => speakerNamed(channel, "Kitchen") !== undefined);
    const id = speakerNamed(channel, "Kitchen")?.id ?? "";
    const viewer = await profile("Alex");
    const book = books[0];
    if (!book) throw new Error("no story");
    const second = book.parts[1];
    if (!second) throw new Error("one part");
    // Where they were on another device: half a second into the second part.
    expect(
      (
        await ask(
          "PUT",
          `/v1/music/profiles/${viewer}/progress/${book.id}`,
          {
            opId: "earlier",
            baseRevision: null,
            positionMs: second.startMs + 500,
            durationMs: book.durationMs,
            completed: false,
            updatedAt: Date.now(),
          },
          { token: phone.token },
        )
      ).status,
    ).toBe(200);
    const started = await ask(
      "POST",
      `/v1/speakers/${id}/play`,
      { session: channel.session, profileId: viewer, bookId: book.id },
      { token: phone.token },
    );
    expect(started.body["play"]).toMatchObject({
      kind: "story",
      bookId: book.id,
      index: 1,
      positionMs: 500,
    });
    expect(streams()[0]).toMatchObject({
      title: "Part Two",
      startMs: 500,
      album: "The Long Story",
    });
    await new Promise((done) => setTimeout(done, 700));
    const paused = await ask(
      "POST",
      `/v1/speakers/${id}/control`,
      { session: channel.session, type: "pause" },
      { token: phone.token },
    );
    const place = (paused.body["play"] as { positionMs: number }).positionMs;
    const kept = await ask("GET", `/v1/music/profiles/${viewer}/progress`, undefined, {
      token: phone.token,
    });
    const progress = (kept.body["progress"] as { itemId: string; positionMs: number }[]).find(
      (one) => one.itemId === book.id,
    );
    expect(progress?.positionMs).toBe(second.startMs + place);
    expect(place).toBeGreaterThan(1_000);
    const back = await ask(
      "POST",
      `/v1/speakers/${id}/control`,
      { session: channel.session, type: "skip", deltaMs: -15_000 },
      { token: phone.token },
    );
    // Back over the start of the part, into the first one.
    expect(back.body["play"]).toMatchObject({ index: 0, positionMs: 0, status: "paused" });
  });

  it("says plainly when a speaker refuses", async () => {
    await start();
    setState({ streamFails: "refused" });
    const phone = device("Phone", "ios");
    const channel = await live(phone);
    await until(() => speakerNamed(channel, "Kitchen") !== undefined);
    const id = speakerNamed(channel, "Kitchen")?.id ?? "";
    const viewer = await profile("Alex");
    const refused = await ask(
      "POST",
      `/v1/speakers/${id}/play`,
      { session: channel.session, profileId: viewer, trackIds: songs() },
      { token: phone.token },
    );
    expect(reason(refused)).toEqual(["forbidden", "speaker_refused"]);
    expect((refused.body["error"] as { message: string }).message).toContain(
      "Everyone on the Same Network",
    );
    // From now on it is said before trying.
    await until(() => speakerNamed(channel, "Kitchen")?.access === "home_only");
    expect(speakerNamed(channel, "Kitchen")?.play).toBeNull();
  });

  it("is started from home only, by a device that may play on others", async () => {
    await start();
    const phone = device("Phone", "ios");
    const channel = await live(phone);
    await until(() => speakerNamed(channel, "Kitchen") !== undefined);
    const id = speakerNamed(channel, "Kitchen")?.id ?? "";
    const viewer = await profile("Alex");
    const body = { session: channel.session, profileId: viewer, trackIds: songs() };
    expect(
      reason(
        await ask("POST", `/v1/speakers/${id}/play`, body, {
          token: phone.token,
          peer: "203.0.113.9",
        }),
      ),
    ).toEqual(["forbidden", "home_only"]);
    expect((await ask("PATCH", `/v1/devices/${phone.id}`, { allowRemote: false })).status).toBe(
      200,
    );
    expect(
      (await ask("POST", `/v1/speakers/${id}/play`, body, { token: phone.token })).status,
    ).toBe(404);
    await until(() => told(channel)?.length === 0);
  });
});

describe("children on a speaker", () => {
  async function plan(kid: string, mode: string, music = true): Promise<void> {
    const reply = await ask("PUT", `/v1/profiles/${kid}/kids/plan`, {
      plan: { defaultMode: mode, music },
    });
    expect(reply.status).toBe(200);
  }

  it("plays only as the child, only while it may listen, and stops when that ends", async () => {
    await start();
    const kid = await profile("Robin", true);
    const grownUp = await profile("Alex");
    const tablet = device("Tablet", "ipados");
    expect((await ask("PATCH", `/v1/devices/${tablet.id}`, { kidsProfileId: kid })).status).toBe(
      200,
    );
    await plan(kid, "listening");
    const channel = await live(tablet, { profileId: kid });
    await until(() => speakerNamed(channel, "Kitchen") !== undefined);
    const id = speakerNamed(channel, "Kitchen")?.id ?? "";
    const play = (profileId: string): Promise<Reply> =>
      ask(
        "POST",
        `/v1/speakers/${id}/play`,
        { session: channel.session, profileId, trackIds: songs() },
        { token: tablet.token },
      );
    expect(reason(await play(grownUp))).toEqual(["forbidden", "title_not_allowed"]);
    const started = await play(kid);
    expect(started.status).toBe(200);
    expect(started.body["play"]).toMatchObject({ profileId: kid, status: "playing" });

    // Bedtime: nothing. What plays for the child stops, and the speakers are gone for it.
    await plan(kid, "nothing");
    await until(
      () => streams().length === 1 && logged().some((one) => one["op"] === "stream_stop"),
    );
    await until(() => told(channel)?.length === 0);
    expect(
      ((await ask("GET", "/v1/speakers")).body["speakers"] as Record<string, unknown>[]).some(
        (one) => one["playing"] === true,
      ),
    ).toBe(false);
    expect(reason(await play(kid))).toEqual(["kids_mode", "kids_mode"]);
  });

  it("is not there when music is off for the child", async () => {
    await start();
    const kid = await profile("Robin", true);
    const tablet = device("Tablet", "ipados");
    await ask("PATCH", `/v1/devices/${tablet.id}`, { kidsProfileId: kid });
    await plan(kid, "everything", false);
    const channel = await live(tablet, { profileId: kid });
    const grown = await live(device("Phone", "ios"));
    await until(() => speakerNamed(grown, "Kitchen") !== undefined);
    const id = speakerNamed(grown, "Kitchen")?.id ?? "";
    const reply = await ask(
      "POST",
      `/v1/speakers/${id}/play`,
      { session: channel.session, profileId: kid, trackIds: songs() },
      { token: tablet.token },
    );
    expect(reply.status).toBe(404);
  });

  it("in the kids screens of a grown-up's device: only as that child, and not over another's music", async () => {
    await start();
    const kid = await profile("Robin", true);
    const grownUp = await profile("Alex");
    await plan(kid, "listening");
    const ipad = device("iPad", "ipados");
    const phone = device("Phone", "ios");
    const kidsScreens = await live(ipad, { profileId: kid });
    const parent = await live(phone, { profileId: grownUp });
    await until(() => speakerNamed(parent, "Kitchen") !== undefined);
    const id = speakerNamed(parent, "Kitchen")?.id ?? "";
    // The grown-up's music plays there.
    expect(
      (
        await ask(
          "POST",
          `/v1/speakers/${id}/play`,
          { session: parent.session, profileId: grownUp, trackIds: songs() },
          { token: phone.token },
        )
      ).status,
    ).toBe(200);
    // The child sees that something plays, not what, and cannot touch it.
    await until(() => speakerNamed(kidsScreens, "Kitchen")?.play?.["redacted"] === true);
    expect(speakerNamed(kidsScreens, "Kitchen")?.controllable).toBe(false);
    const asKid = (path: string, body: Record<string, unknown>): Promise<Reply> =>
      ask(
        "POST",
        `/v1/speakers/${id}/${path}`,
        { session: kidsScreens.session, ...body },
        {
          token: ipad.token,
        },
      );
    expect(reason(await asKid("control", { type: "pause" }))).toEqual([
      "forbidden",
      "title_not_allowed",
    ]);
    expect(reason(await asKid("play", { profileId: grownUp, trackIds: songs() }))).toEqual([
      "forbidden",
      "title_not_allowed",
    ]);
    expect(reason(await asKid("play", { profileId: kid, trackIds: songs() }))).toEqual([
      "conflict",
      "speaker_busy",
    ]);
    // Once it is over, the child may play its own, and the grown-up controls that too.
    await ask(
      "POST",
      `/v1/speakers/${id}/control`,
      { session: parent.session, type: "stop" },
      { token: phone.token },
    );
    expect((await asKid("play", { profileId: kid, trackIds: songs() })).status).toBe(200);
    expect((await asKid("control", { type: "pause" })).body["play"]).toMatchObject({
      status: "paused",
    });
    await until(() => speakerNamed(parent, "Kitchen")?.play?.["profileId"] === kid);
  });
});

// The real tools/wake.py with a stand-in for pyatv (support/fake-pyatv): which speakers it lists,
// and what it sends one. The decoder is the real ffmpeg. Needs only a python3.
const python = ((): string | null => {
  const found = spawnSync("python3", ["-c", "import sys; print(sys.executable)"], {
    encoding: "utf8",
  });
  return found.status === 0 ? found.stdout.trim() : null;
})();
if (!python) console.warn("Skipping tools/wake.py's speakers with a stand-in pyatv: no python3.");

describe.skipIf(!python)("tools/wake.py and speakers", () => {
  async function helperFor(speaker: string): Promise<{
    helper: WakeHelper;
    calls: () => Record<string, unknown>[];
    events: Record<string, unknown>[];
  }> {
    const log = join(dir, `${speaker}.log`);
    const fake = join(dir, `${speaker}.json`);
    writeFileSync(fake, JSON.stringify({ scenario: "direct", speaker, log }));
    const helper = new WakeHelper({
      python: python ?? "python3",
      script: FAKE_PYATV,
      args: ["--fake", fake, "--storage", join(dir, "pyatv.conf")],
    });
    const events: Record<string, unknown>[] = [];
    helper.onEvent = (event) => events.push(event);
    helper.start();
    expect(await helper.whenReady(10_000)).toBe(true);
    const calls = (): Record<string, unknown>[] =>
      existsSync(log)
        ? readFileSync(log, "utf8")
            .trim()
            .split("\n")
            .map((line) => JSON.parse(line) as Record<string, unknown>)
        : [];
    return { helper, calls, events };
  }

  const song = (): string => {
    const path = join(dir, "song.flac");
    makeAudio(path, { seconds: 2 });
    return path;
  };

  it("lists speakers, not the Apple TV, and says which will refuse", async () => {
    const { helper } = await helperFor("plays");
    try {
      const answer = await helper.ask("speakers", { timeout: 1 });
      expect(answer["speakers"]).toEqual([
        {
          id: "11:22",
          name: "Kitchen",
          model: "HomePod (fake)",
          kind: "homepod",
          access: "open",
          hasPassword: false,
        },
        {
          id: "33:44",
          name: "Bedroom",
          model: "HomePod mini (fake)",
          kind: "homepod",
          access: "home_only",
          hasPassword: false,
        },
        {
          id: "55:66",
          name: "Garden",
          model: "Speaker (fake)",
          kind: "speaker",
          access: "password",
          hasPassword: false,
        },
      ]);
    } finally {
      await helper.stop();
    }
  });

  it("decodes the file to FLAC with ffmpeg and sends it until it ends", async () => {
    const { helper, calls, events } = await helperFor("plays");
    try {
      const answer = await helper.ask("stream", {
        speaker: "11:22",
        stream: "one",
        ffmpeg: "ffmpeg",
        file: song(),
        startMs: 500,
        volume: 0.3,
        title: "One",
      });
      expect(answer).toEqual({ volume: 0.3 });
      await until(() => events.some((one) => one["event"] === "stream_ended"));
      expect(events).toEqual([
        { event: "stream_ended", stream: "one", reason: "ended", code: null },
      ]);
      const sent = calls().find((one) => one["call"] === "sent");
      expect(sent).toMatchObject({ flac: true, stopped: false });
      expect(sent?.["bytes"] as number).toBeGreaterThan(10_000);
      expect(calls().map((one) => one["call"])).toEqual([
        "scan",
        "connect",
        "set_volume",
        "stream_file",
        "sent",
        "close",
      ]);
      expect(calls().find((one) => one["call"] === "set_volume")).toMatchObject({ volume: 30 });
    } finally {
      await helper.stop();
    }
  });

  it("stops a stream when asked, and says so", async () => {
    const { helper, calls, events } = await helperFor("plays");
    try {
      // Long enough not to end by itself.
      const path = join(dir, "long.flac");
      makeAudio(path, { seconds: 60 });
      await helper.ask("stream", {
        speaker: "11:22",
        stream: "two",
        ffmpeg: "ffmpeg",
        file: path,
        startMs: 0,
      });
      expect(await helper.ask("volume", { stream: "two", volume: 0.5 })).toEqual({ volume: 0.5 });
      expect(await helper.ask("stream_stop", { stream: "two" })).toEqual({ stopped: true });
      await until(() => events.length > 0);
      expect(events).toEqual([
        { event: "stream_ended", stream: "two", reason: "stopped", code: null },
      ]);
      expect(calls().map((one) => one["call"])).toContain("stop");
      await expect(helper.ask("volume", { stream: "two", volume: 0.5 })).rejects.toMatchObject({
        code: "not_streaming",
      });
    } finally {
      await helper.stop();
    }
  });

  it("says refused when the speaker lets only its Home play", async () => {
    const { helper } = await helperFor("refuses");
    try {
      await expect(
        helper.ask("stream", {
          speaker: "33:44",
          stream: "three",
          ffmpeg: "ffmpeg",
          file: song(),
          startMs: 0,
        }),
      ).rejects.toMatchObject({ code: "refused" });
      await expect(
        helper.ask("stream", {
          speaker: "99:99",
          stream: "four",
          ffmpeg: "ffmpeg",
          file: song(),
          startMs: 0,
        }),
      ).rejects.toMatchObject({ code: "not_found" });
      await expect(
        helper.ask("stream", { speaker: "11:22", stream: "five", ffmpeg: "ffmpeg", file: "song" }),
      ).rejects.toMatchObject({ code: "bad_request" });
    } finally {
      await helper.stop();
    }
  });

  it("keeps a speaker's password in pyatv's file", async () => {
    const { helper } = await helperFor("plays");
    try {
      expect(await helper.ask("speaker_password", { speaker: "55:66", password: "1234" })).toEqual(
        {},
      );
      await expect(
        helper.ask("speaker_password", { speaker: "55:66", password: "" }),
      ).rejects.toMatchObject({ code: "bad_request" });
    } finally {
      await helper.stop();
    }
  });
});
