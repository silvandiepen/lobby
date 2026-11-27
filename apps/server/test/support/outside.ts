// SPDX-License-Identifier: MPL-2.0
import { Agent, request as httpRequest, type IncomingHttpHeaders } from "node:http";
import { connect, createServer, type Server, type Socket } from "node:net";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import type { Duplex } from "node:stream";
import type { Hono } from "hono";
import { ArtworkStore } from "../../src/artwork/serve.ts";
import { LogoStore } from "../../src/artwork/logos.ts";
import { ChosenArtwork } from "../../src/artwork/chosen.ts";
import { Devices } from "../../src/auth/devices.ts";
import { ConversionService } from "../../src/conversion/index.ts";
import { MarkerService } from "../../src/markers/service.ts";
import { Database } from "../../src/db/database.ts";
import { DeviceDownloads } from "../../src/devices-downloads/index.ts";
import { Enricher } from "../../src/enrich/index.ts";
import { createApp, type AppDeps, type AppEnv } from "../../src/http/app.ts";
import { createAssetLookup } from "../../src/http/playback-assets.ts";
import { Catalogue } from "../../src/library/catalogue.ts";
import { ItemReader, type ApiItem } from "../../src/library/items.ts";
import { Scanner } from "../../src/library/scanner.ts";
import { MusicLibrary } from "../../src/music/index.ts";
import {
  type DirectTransport,
  OutsideEntrance,
  type OutsideConnection,
  type OutsideTransport,
} from "../../src/outside/index.ts";
import type { OutsidePairing } from "../../src/outside/pairing.ts";
import type { OutsideLimits } from "../../src/outside/entrance.ts";
import { PlaybackService } from "../../src/playback/index.ts";
import { RemoteHub, type RemoteLimits } from "../../src/remote/index.ts";
import { ProgressStore } from "../../src/progress.ts";
import { makeTempDir, removeDir } from "./media.ts";
import { settingsFor } from "./settings.ts";

export const NAME = "lobby.example.test";

/** A road over plain sockets on this machine: what a tunnel hands over, without the tunnel. */
export class SocketTransport implements OutsideTransport {
  readonly name = "sockets";
  address: string | null = "203.0.113.7";
  reliable = true;
  port = 0;
  private server: Server | null = null;
  private readonly sockets = new Set<Socket>();

  async open(accept: (connection: OutsideConnection) => void): Promise<void> {
    const server = createServer((socket) => {
      this.sockets.add(socket);
      socket.on("close", () => this.sockets.delete(socket));
      accept({ stream: socket, address: this.address, addressIsReliable: this.reliable });
    });
    this.server = server;
    await new Promise<void>((done) => server.listen(0, "127.0.0.1", done));
    const bound = server.address();
    this.port = bound !== null && typeof bound === "object" ? bound.port : 0;
  }

  async close(): Promise<void> {
    for (const socket of this.sockets) socket.destroy();
    await new Promise((done) => this.server?.close(done));
    this.server = null;
  }

  status(): { open: boolean; problem: string | null } {
    return { open: this.server !== null, problem: null };
  }
}

export interface OutsideReply {
  status: number;
  headers: IncomingHttpHeaders;
  rawHeaders: string[];
  body: Buffer;
  json: <T>() => T;
}

export interface Ask {
  token?: string;
  cookie?: string;
  body?: unknown;
  headers?: Record<string, string>;
  host?: string;
}

/** One request on a connection of its own. */
export function ask(
  open: () => Duplex,
  method: string,
  path: string,
  options: Ask = {},
): Promise<OutsideReply> {
  return new Promise((resolve, reject) => {
    const body = options.body === undefined ? null : Buffer.from(JSON.stringify(options.body));
    const agent = new Agent({ keepAlive: false });
    agent.createConnection = () => open();
    const request = httpRequest(
      {
        method,
        path,
        agent,
        setHost: false,
        headers: {
          Host: options.host ?? NAME,
          ...(options.token === undefined ? {} : { Authorization: `Bearer ${options.token}` }),
          ...(options.cookie === undefined ? {} : { Cookie: options.cookie }),
          ...(body ? { "Content-Type": "application/json", "Content-Length": body.length } : {}),
          ...options.headers,
        },
      },
      (response) => {
        const parts: Buffer[] = [];
        response.on("data", (part: Buffer) => parts.push(part));
        response.on("error", reject);
        response.on("end", () => {
          const whole = Buffer.concat(parts);
          resolve({
            status: response.statusCode ?? 0,
            headers: response.headers,
            rawHeaders: response.rawHeaders,
            body: whole,
            json: <T>() => JSON.parse(whole.toString("utf8")) as T,
          });
        });
      },
    );
    request.on("error", reject);
    request.end(body ?? undefined);
  });
}

/** Everything the server sends on a connection on which `data` is written, until it ends. */
export function raw(socket: Duplex, data: string | Buffer): Promise<string> {
  return new Promise((resolve) => {
    let text = "";
    socket.on("data", (part: Buffer) => (text += part.toString("latin1")));
    socket.on("error", () => undefined);
    socket.on("close", () => {
      resolve(text);
    });
    socket.write(data);
  });
}

/** A whole server, with a library of `files` and the outside entrance over plain sockets. */
export class OutsideFixture {
  readonly dir = makeTempDir("lobby-outside-");
  readonly clock = { ahead: 0 };
  readonly now = (): number => Date.now() + this.clock.ahead;
  readonly transport = new SocketTransport();
  readonly db = new Database(join(this.dir, "lobby.db"));
  readonly devices = new Devices(this.db, "setup", this.now);
  readonly playback = new PlaybackService({
    cacheDir: join(this.dir, "cache"),
    minFreeBytes: 0,
    // A slower one for a test that watches a copy while it is written.
    ffmpegPath: process.env["LOBBY_TEST_FFMPEG"] ?? "ffmpeg",
  });
  readonly scanner: Scanner;
  readonly music: MusicLibrary;
  readonly downloads: DeviceDownloads;
  readonly conversion: ConversionService;
  readonly outside: OutsideEntrance;
  readonly remote: RemoteHub;
  readonly deps: AppDeps;
  home!: Hono<AppEnv>;
  app!: Hono<AppEnv>;
  manager!: { id: string; token: string };
  items: ApiItem[] = [];

  constructor(
    limits: Partial<OutsideLimits> = {},
    extra: OutsideTransport[] = [],
    direct?: (parts: {
      db: Database;
      devices: Devices;
      pairing: OutsidePairing;
      now: () => number;
    }) => DirectTransport,
    remote: Partial<RemoteLimits> = {},
  ) {
    const { db, devices, playback, dir } = this;
    const catalogue = new Catalogue(db);
    this.scanner = new Scanner(db, catalogue, {
      stabilityMs: 0,
      probeConcurrency: 2,
      ffprobePath: "ffprobe",
      volumeOf: () => Promise.resolve(1),
    });
    mkdirSync(join(dir, "Films"));
    mkdirSync(join(dir, "Music"));
    this.scanner.syncSources([{ path: join(dir, "Films"), name: "Films", hint: "movies" }]);
    this.downloads = new DeviceDownloads({ db, playback, lookupAsset: createAssetLookup(db) });
    this.conversion = new ConversionService({ db, catalogue, dir: null });
    this.music = new MusicLibrary(db, {
      dataDir: join(dir, "data"),
      music: {
        roots: [{ path: join(dir, "Music"), name: "Music", hint: "music" }],
        cacheDir: join(dir, "music-cache"),
        maxCacheGb: 1,
        minFreeGb: 0,
      },
      stabilityMs: 0,
      rescanMinutes: 60,
      ffmpegPath: "ffmpeg",
      ffprobePath: "ffprobe",
    });
    this.outside = new OutsideEntrance({
      db,
      devices,
      name: NAME,
      transports: [this.transport, ...extra],
      ...(direct ? { direct: (pairing) => direct({ db, devices, pairing, now: this.now }) } : {}),
      now: this.now,
      limits,
    });
    this.remote = new RemoteHub({ db, devices, now: this.now, limits: remote });
    this.deps = {
      db,
      devices,
      items: new ItemReader(db),
      progress: new ProgressStore(db),
      playback,
      downloads: this.downloads,
      conversion: this.conversion,
      markers: new MarkerService({ db, catalogue, dir: join(dir, "markers") }),
      music: this.music,
      artwork: new ArtworkStore(db, join(dir, "art-cache"), "ffmpeg"),
      logos: new LogoStore(db, join(dir, "logos")),
      edit: {
        catalogue,
        enricher: new Enricher({
          db,
          catalogue,
          key: null,
          language: "en-US",
          artworkDir: join(dir, "artwork"),
        }),
        chosen: new ChosenArtwork(db, {
          dir: join(dir, "chosen"),
          ffmpegPath: "ffmpeg",
          ffprobePath: "ffprobe",
        }),
      },
      outside: this.outside,
      remote: this.remote,
      settings: settingsFor(db, devices, dir),
      serverName: "Secret Household",
      version: "9.9.9",
      isScanning: () => false,
    };
  }

  async start(on = true): Promise<void> {
    await this.playback.start();
    await this.conversion.start();
    await this.music.copies.start();
    this.home = createApp(this.deps);
    this.app = createApp(this.deps, "outside");
    const made = this.devices.createLocalManager("Mac");
    this.manager = { id: made.device.id, token: made.token };
    await this.outside.start(this.app);
    if (on) await this.outside.setEnabled(true);
  }

  async scan(): Promise<void> {
    await this.scanner.scanAll();
    await this.scanner.processQueue();
    this.items = this.deps.items.page(null, 1000).items;
  }

  async stop(): Promise<void> {
    this.remote.stop();
    await this.outside.stop();
    await this.downloads.stop();
    await this.conversion.stop();
    await this.music.stop();
    await this.playback.close();
    this.db.close();
    removeDir(this.dir);
  }

  connect(): Socket {
    return connect(this.transport.port, "127.0.0.1");
  }

  ask(method: string, path: string, options: Ask = {}): Promise<OutsideReply> {
    return ask(() => this.connect(), method, path, options);
  }

  async atHome(
    token: string,
    method: string,
    path: string,
    body?: unknown,
  ): Promise<{ status: number; json: <T>() => T }> {
    const response = await this.home.request(path, {
      method,
      headers: { Authorization: `Bearer ${token}` },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    const text = await response.text();
    return { status: response.status, json: <T>() => JSON.parse(text) as T };
  }

  /** A device paired at home, let in from outside or not. */
  pair(name: string, outside: boolean): { id: string; token: string } {
    const waiting = this.devices.startPairing(name, "tvos");
    this.devices.approve(waiting.code, "viewer", "cli");
    const done = this.devices.collect(waiting.id, waiting.pollSecret);
    if (done.status !== "approved") throw new Error("not paired");
    if (outside) this.devices.setAllowOutside(done.device.id, true);
    return { id: done.device.id, token: done.token };
  }
}

export async function until(check: () => boolean | Promise<boolean>): Promise<void> {
  for (let attempt = 0; attempt < 400; attempt += 1) {
    if (await check()) return;
    await new Promise((done) => setTimeout(done, 25));
  }
  throw new Error("it did not happen");
}
