// SPDX-License-Identifier: MPL-2.0
import { PushService, type BoxSigner } from "./push/service.ts";
import { watch, type FSWatcher } from "node:fs";
import { readFileSync, statfsSync, statSync } from "node:fs";
import { join } from "node:path";
import { serve, type ServerType } from "@hono/node-server";
import { Devices } from "./auth/devices.ts";
import { ChosenArtwork } from "./artwork/chosen.ts";
import { FrameMaker } from "./artwork/frames.ts";
import { LogoStore } from "./artwork/logos.ts";
import { ArtworkStore } from "./artwork/serve.ts";
import { createBackup, listBackups, pruneBackups } from "./backup.ts";
import { loadSecrets, type Config, type WakeConfig } from "./config.ts";
import { Database } from "./db/database.ts";
import { announce } from "./discovery.ts";
import { Enricher } from "./enrich/index.ts";
import { API_VERSION, createApp, type AppDeps } from "./http/app.ts";
import { Catalogue } from "./library/catalogue.ts";
import { ItemReader } from "./library/items.ts";
import { isIgnoredName } from "./library/parse.ts";
import { Scanner } from "./library/scanner.ts";
import { VideoTags } from "./library/video-tags.ts";
import { MarkerService } from "./markers/service.ts";
import { errorMessage, log } from "./log.ts";
import { MusicLibrary } from "./music/index.ts";
import { DirectTransport, OutsideEntrance, RelayTransport } from "./outside/index.ts";
import { BoxKeys } from "./outside/direct/keys.ts";
import {
  RemoteHub,
  SPEAKER_TIMINGS,
  SpeakerService,
  WakeService,
  type WakeHelper,
  type WakeTimings,
} from "./remote/index.ts";
import { PlaybackService } from "./playback/index.ts";
import { serverAddresses } from "./addresses.ts";
import { ConversionService } from "./conversion/index.ts";
import { DeviceDownloads } from "./devices-downloads/index.ts";
import { createAssetLookup } from "./http/playback-assets.ts";
import { readRevocations, writeRevocations } from "./revocations.ts";
import { ProgressStore } from "./progress.ts";
import { Statistics } from "./stats/recorder.ts";
import { ImportService } from "./imports/service.ts";
import { UploadService } from "./imports/uploads.ts";
import { FolderBrowser } from "./settings/browse.ts";
import { SettingsService, type SettingsHooks } from "./settings/service.ts";
import { checkOmdbKey, OmdbRatings } from "./search/omdb.ts";
import { OutsideSearch } from "./search/outside.ts";
import { SearchService } from "./search/service.ts";

export const VERSION = (
  JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")) as {
    version: string;
  }
).version;

/**
 * What `lobby serve` exits with to be started again, to take settings that cannot change while it
 * runs. EX_TEMPFAIL; the systemd units restart on it (`RestartForceExitStatus=75`).
 */
export const RESTART_EXIT_CODE = 75;

/** Raised when the apps must fetch every item again because items carry something new. */
const ITEM_SHAPE = "4";

// A copy over the network fires many events per file. Wait for a quiet moment before looking.
const WATCH_DEBOUNCE_MS = 5_000;

export interface Services {
  db: Database;
  devices: Devices;
  catalogue: Catalogue;
  scanner: Scanner;
  videoTags: VideoTags;
  items: ItemReader;
  progress: ProgressStore;
  music: MusicLibrary;
  setupSecret: string;
  tmdbApiKey: string | null;
  omdbApiKey: string | null;
}

export function openServices(config: Config): Services {
  const secrets = loadSecrets(config.dataDir);
  const db = new Database(join(config.dataDir, "lobby.db"));
  const catalogue = new Catalogue(db);
  const scanner = new Scanner(db, catalogue, {
    stabilityMs: config.stabilityMs,
    probeConcurrency: config.probeConcurrency,
    ffprobePath: config.ffprobePath,
  });
  scanner.syncSources(config.roots);
  // Apps only fetch what changed. When items gain a field, everything counts as changed once.
  if (db.getMeta("item_shape") !== ITEM_SHAPE) {
    for (const source of db.all<{ id: string }>("select id from source")) {
      catalogue.touchSource(source.id);
    }
    db.setMeta("item_shape", ITEM_SHAPE);
  }
  const devices = new Devices(db, secrets.setupSecret, Date.now, config.claim);
  // Beside the backups too: those are copied elsewhere together.
  devices.onRevoked = (id, at) => {
    for (const dir of new Set([config.dataDir, config.backup.dir])) {
      try {
        writeRevocations(dir, readRevocations(dir).set(id, at));
      } catch (error) {
        // The device is removed all the same. A restore refuses to go on with a broken list.
        log.error("Could not note a removed device beside the backups", {
          error: errorMessage(error),
        });
      }
    }
  };
  return {
    db,
    devices,
    catalogue,
    scanner,
    videoTags: new VideoTags(db, { ffprobePath: config.ffprobePath, catalogue }),
    items: new ItemReader(db),
    progress: new ProgressStore(db),
    music: new MusicLibrary(db, config),
    setupSecret: secrets.setupSecret,
    tmdbApiKey: secrets.tmdbApiKey,
    omdbApiKey: secrets.omdbApiKey,
  };
}

/**
 * Keeps the catalogue in step with the folders: a scan at start, another
 * whenever something changes in a root, and a full one on a timer for
 * whatever the watcher missed.
 */
export class LibraryLoop {
  private readonly scanner: Scanner;
  private readonly config: Config;
  private readonly watchers: FSWatcher[] = [];
  private timer: NodeJS.Timeout | null = null;
  private interval: NodeJS.Timeout | null = null;
  private stopped = false;

  private readonly frames: FrameMaker | null;
  private readonly enricher: Enricher | null;
  private readonly search: { omdb: OmdbRatings; service: SearchService } | null;

  constructor(
    scanner: Scanner,
    config: Config,
    frames: FrameMaker | null = null,
    enricher: Enricher | null = null,
    search: { omdb: OmdbRatings; service: SearchService } | null = null,
  ) {
    this.enricher = enricher;
    this.search = search;
    this.frames = frames;
    this.scanner = scanner;
    this.config = config;
  }

  /** While held (a fresh server before its setup is finished) nothing is looked through. */
  private held = false;

  /** @param held start without looking through anything, until `release` */
  start(held = false): void {
    this.held = held;
    this.watch();
  }

  /** The first setup is finished: look through the folders now. */
  release(): void {
    if (!this.held) return;
    this.held = false;
    this.schedule(0);
  }

  /** The folders or the minutes between scans changed: watch the new ones and look at once. */
  refresh(): void {
    if (this.stopped) return;
    if (this.interval) clearInterval(this.interval);
    this.interval = null;
    for (const watcher of this.watchers.splice(0)) watcher.close();
    this.watch();
  }

  private watch(): void {
    this.schedule(0);
    this.interval = setInterval(() => {
      this.schedule(0);
    }, this.config.rescanMinutes * 60_000);
    for (const root of this.config.roots) {
      try {
        const watcher = watch(root.path, { recursive: true }, (_event, name) => {
          if (name === null || name.split("/").some(isIgnoredName)) return;
          this.schedule(WATCH_DEBOUNCE_MS);
        });
        watcher.on("error", (error) => {
          log.warn("Stopped watching a library folder; the timed scan still covers it", {
            source: root.name,
            error: errorMessage(error),
          });
        });
        this.watchers.push(watcher);
      } catch (error) {
        log.warn("Could not watch a library folder; the timed scan still covers it", {
          source: root.name,
          error: errorMessage(error),
        });
      }
    }
  }

  /** Runs a scan after `delayMs`, replacing one that is already waiting. */
  private schedule(delayMs: number): void {
    if (this.stopped || this.held) return;
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      this.timer = null;
      void this.run();
    }, delayMs);
  }

  private async run(): Promise<void> {
    try {
      const started = Date.now();
      const summary = await this.scanner.scanAll();
      const read = await this.scanner.processQueue();
      if (summary.added + summary.changed + summary.missing + summary.restored + read > 0) {
        log.info("Library scan finished", {
          added: summary.added,
          changed: summary.changed,
          missing: summary.missing,
          restored: summary.restored,
          read,
          seconds: Math.round((Date.now() - started) / 1000),
        });
      }
      const search = this.search;
      void (this.enricher?.run() ?? Promise.resolve())
        .catch((error: unknown) => {
          log.error("Looking titles up failed", { error: errorMessage(error) });
        })
        // Ready before somebody searches: the first index of a whole library takes a moment.
        .then(async () => {
          await search?.service.index.syncAll();
          return search?.omdb.refresh();
        })
        .catch((error: unknown) => {
          log.error("Keeping search up to date failed", { error: errorMessage(error) });
        });
      // Not waited for: a whole library takes a while, and scanning goes on meanwhile.
      this.frames?.run().catch((error: unknown) => {
        log.error("Making pictures failed", { error: errorMessage(error) });
      });
      // New files are only indexed once they have stopped changing, so look again after the wait.
      if (summary.settling > 0 && this.timer === null)
        this.schedule(this.config.stabilityMs + 1_000);
    } catch (error) {
      log.error("Library scan failed", { error: errorMessage(error) });
    }
  }

  stop(): void {
    this.stopped = true;
    this.frames?.stop();
    if (this.timer) clearTimeout(this.timer);
    if (this.interval) clearInterval(this.interval);
    for (const watcher of this.watchers) watcher.close();
  }
}

/** Backs the catalogue up when the newest backup is older than the config allows. */
export async function backupIfDue(
  db: Database,
  config: Config,
  now: number = Date.now(),
): Promise<boolean> {
  const { dir, keep, everyHours } = config.backup;
  if (everyHours <= 0) return false;
  const newest = listBackups(dir)[0];
  if (newest && now - newest.at < everyHours * 3_600_000) return false;
  const backup = await createBackup(db, dir, config.configPath, now, config.dataDir);
  pruneBackups(dir, keep);
  log.info("Backed up the catalogue", { backup: backup.name });
  return true;
}

export interface RunningServer {
  services: Services;
  /** The app for home, as it answers requests; for tests. */
  app: ReturnType<typeof createApp>;
  settings: SettingsService;
  /** Playing on another device; for tests. */
  remote: RemoteHub;
  close: () => Promise<void>;
}

export interface StartOptions {
  /**
   * Restarts the whole server, to take settings that cannot be changed while it runs. The
   * `lobby serve` command exits with `RESTART_EXIT_CODE` under systemd, which starts it again.
   */
  restart?: () => void;
  /** Where the folder browser may look. Default: the mounted drives and the home folder. */
  browseBases?: () => string[];
  /** Where TMDB is asked whether it accepts a key. */
  tmdbBaseUrl?: string;
  /** OMDb somewhere else, for tests. */
  omdbBaseUrl?: string;
  /** Makes the helper that wakes Apple TVs; tests pass one that runs a stand-in. */
  wakeHelper?: (config: WakeConfig) => WakeHelper;
  /** How long a woken TV is waited for; tests wait less. */
  wakeTimings?: Partial<WakeTimings>;
  /** How often speakers are looked for and looked after; tests look more often. */
  speakerTimings?: Partial<typeof SPEAKER_TIMINGS>;
}

export async function startServer(
  config: Config,
  options: StartOptions = {},
): Promise<RunningServer> {
  const services = openServices(config);
  // Also those that were removed before there was a list.
  for (const device of services.devices.list()) {
    if (device.revokedAt === null) continue;
    services.devices.onRevoked?.(device.id, device.revokedAt);
  }
  const GB = 1024 ** 3;
  // Read each time: a manager can change how long it is kept while the server runs.
  const stats = new Statistics(services.db, { keepDays: () => config.statistics.keepDays });
  stats.prune(true);
  const playback = new PlaybackService({
    onPrepared: (event) => {
      stats.notePrepared(event);
    },
    cacheDir: config.playback.cacheDir,
    maxCacheBytes: config.playback.maxCacheGb * GB,
    minFreeBytes: config.playback.minFreeGb * GB,
    maxConcurrent: config.playback.maxConcurrent,
    ffmpegPath: config.ffmpegPath,
  });
  await playback.start();
  const conversion = new ConversionService({
    db: services.db,
    catalogue: services.catalogue,
    dir: config.conversion.dir,
    ffmpegPath: config.ffmpegPath,
    ffprobePath: config.ffprobePath,
    hours: config.conversion.hours,
    repackage: config.conversion.repackage,
    serverConverts: config.conversion.server,
    minFreeBytes: config.conversion.minFreeGb * GB,
    onStarted: (jobId) => {
      stats.noteConversionClaimed(jobId);
    },
    onConverted: (jobId, assetId, savedBytes) => {
      stats.noteConverted(jobId, assetId, savedBytes);
    },
    // The new file is read at once, so the title plays again within seconds.
    onReplaced: async () => {
      await services.scanner.scanAll();
      await services.scanner.processQueue();
    },
  });
  // Intros and credits are found when converting may run: the same hours, nobody watching.
  const markers = new MarkerService({
    db: services.db,
    catalogue: services.catalogue,
    dir: config.markers.cacheDir,
    ffmpegPath: config.ffmpegPath,
    ffprobePath: config.ffprobePath,
    waitBecause: () => conversion.quietBecause(),
  });
  const remote = new RemoteHub({
    db: services.db,
    devices: services.devices,
    onPlayOn: (from, target, itemId) => {
      stats.notePlayOn(from.id, target.id, itemId);
    },
  });
  const imports = new ImportService({
    db: services.db,
    folders: config.imports.folders,
    roots: () => config.roots,
    lobbyDir: config.conversion.dir,
    driveConnected: () => conversion.driveConnected(),
    waitMs: config.imports.waitMinutes * 60_000,
    copyAcrossDrives: config.imports.copyAcrossDrives,
    matcher: null,
    ffprobePath: config.ffprobePath,
    onLibraryChanged: async () => {
      services.scanner.syncSources(librarySources());
      await services.scanner.scanAll();
      await services.scanner.processQueue();
    },
    onChange: (item) => {
      remote.tellManagers("import", { item }, `import ${item.id}`);
    },
  });
  const librarySources = (): typeof config.roots => [...config.roots, ...imports.indexSources()];
  const filterIndexFolders = (): void => {
    for (const source of imports.indexSources()) {
      services.scanner.setFilter(source.path, (rel) => imports.isListed(source.path, rel));
    }
  };
  filterIndexFolders();
  services.scanner.syncSources(librarySources());
  const uploads = new UploadService({
    db: services.db,
    imports,
    roots: () => config.roots,
    maxFileBytes: () => config.imports.maxFileGb * GB,
    quotaBytes: () => config.imports.quotaGb * GB,
    minFreeBytes: () => config.conversion.minFreeGb * GB,
    onChange: (upload) => {
      remote.tellManagers("upload", { upload }, `upload ${upload.id}`);
    },
  });
  const downloads = new DeviceDownloads({
    db: services.db,
    playback,
    lookupAsset: createAssetLookup(services.db, services.videoTags),
    videoTags: services.videoTags,
  });
  const enricher = new Enricher({
    db: services.db,
    catalogue: services.catalogue,
    key: services.tmdbApiKey,
    language: config.language,
    artworkDir: join(config.dataDir, "artwork", "tmdb"),
    ffmpegPath: config.ffmpegPath,
  });
  // Ratings beyond TMDB's only with the owner's OMDb key (docs/decisions.md, "Search"); without one OMDb is never asked.
  const omdb = new OmdbRatings(services.db, {
    key: services.omdbApiKey,
    ...(options.omdbBaseUrl === undefined ? {} : { baseUrl: options.omdbBaseUrl }),
  });
  const search = new SearchService(services.db, services.items, omdb);
  imports.setMatcher(async (wanted) => {
    if (!enricher.isConfigured) return null;
    const decision = await enricher.identify({
      type: wanted.type,
      title: wanted.title,
      year: wanted.year,
      tmdbIds: [],
      imdbIds: [],
      runtimes: wanted.runtimeMinutes === null ? [] : [wanted.runtimeMinutes],
      episodes:
        wanted.type === "tv"
          ? [{ season: wanted.season, episode: wanted.episode, title: wanted.episodeTitle }]
          : [],
    });
    if (decision.accepted) {
      return {
        accepted: {
          title: decision.accepted.title,
          year: decision.accepted.year,
          tmdbId: decision.accepted.id,
        },
        reason: "",
        candidates: [],
      };
    }
    return {
      accepted: null,
      reason: decision.reason,
      candidates: decision.candidates
        .filter((one) => one.type !== "episode")
        .map((one) => ({ title: one.title, year: one.year, tmdbId: one.id })),
    };
  });
  const chosen = new ChosenArtwork(services.db, {
    dir: join(config.dataDir, "artwork", "chosen"),
    ffmpegPath: config.ffmpegPath,
    ffprobePath: config.ffprobePath,
  });
  const logos = new LogoStore(services.db, join(config.dataDir, "artwork", "logos"));
  void logos.start();
  const outsideDirect = config.outside?.direct ?? null;
  const outside = new OutsideEntrance({
    db: services.db,
    devices: services.devices,
    name: config.outside?.name ?? null,
    ...(outsideDirect
      ? {
          direct: (pairing) => {
            try {
              return new DirectTransport({
                config: outsideDirect,
                db: services.db,
                devices: services.devices,
                pairing,
                dataDir: config.dataDir,
                name: config.outside?.name ?? "",
              });
            } catch (error) {
              // Home and the other roads go on without it.
              log.error("The direct road cannot be used", { problem: errorMessage(error) });
              return null;
            }
          },
        }
      : {}),
    transports: config.outside?.tls
      ? [new RelayTransport(config.outside.tls, config.outside.name)]
      : [],
  });
  // Set right below: the speakers use the helper of the Apple TVs.
  let speakers: SpeakerService | null = null;
  const wake = new WakeService({
    db: services.db,
    devices: services.devices,
    config: () => config.wake,
    changed: () => {
      remote.recheck();
    },
    helperChanged: () => speakers?.helperChanged(),
    helperEvent: (event) => speakers?.helperEvent(event),
    ...(options.wakeHelper ? { helper: options.wakeHelper } : {}),
    ...(options.wakeTimings ? { timings: options.wakeTimings } : {}),
  });
  remote.wakeable = (deviceId) => wake.wakeable(deviceId);
  wake.isOpen = (deviceId) => remote.isOpen(deviceId);
  remote.kidsWake = () => wake.kidsMayWake();
  const speakerService = new SpeakerService({
    db: services.db,
    music: services.music,
    config: () => config.wake,
    helper: () => wake.process(),
    ffmpegPath: config.ffmpegPath,
    changed: () => {
      remote.speakersChanged();
    },
    ...(options.speakerTimings ? { timings: options.speakerTimings } : {}),
  });
  speakers = speakerService;
  remote.speakers = (asker) => speakerService.shownTo(asker);
  const browser = new FolderBrowser(options.browseBases);
  // Set below, once the loop and the announcement exist; the settings are only changed after that.
  let applyLive: SettingsHooks["apply"] = () => Promise.resolve();
  let startScanning = (): void => undefined;
  const settings = new SettingsService({
    configPath: config.configPath,
    config,
    db: services.db,
    devices: services.devices,
    browser,
    hasTmdbKey: services.tmdbApiKey !== null && services.tmdbApiKey !== "",
    hasOmdbKey: services.omdbApiKey !== null && services.omdbApiKey !== "",
    ...(options.tmdbBaseUrl === undefined ? {} : { tmdbBaseUrl: options.tmdbBaseUrl }),
    ...(options.omdbBaseUrl === undefined
      ? {}
      : { checkOmdbKey: (key: string) => checkOmdbKey(key, options.omdbBaseUrl) }),
    hooks: {
      apply: (next, previous, changed) => applyLive(next, previous, changed),
      restart: () => {
        if (options.restart) options.restart();
        else log.warn("A restart is needed to take the new settings; start the server again");
      },
      setTmdbKey: (key) => {
        enricher.setKey(key);
        if (key !== null) void enricher.run().catch(() => undefined);
      },
      setOmdbKey: (key) => {
        omdb.setKey(key);
        if (key !== null) {
          void omdb.refresh().catch((error: unknown) => {
            log.warn("Reading ratings from OMDb failed", { error: errorMessage(error) });
          });
        }
      },
      startScanning: () => {
        startScanning();
      },
    },
  });
  settings.ensure();
  const deps: AppDeps = {
    push: new PushService({
      db: services.db,
      config: config.push,
      route: config.pushRoute,
      box: config.pushRoute.mode === "relay" ? pushBox(config.dataDir) : null,
    }),
    db: services.db,
    devices: services.devices,
    items: services.items,
    progress: services.progress,
    playback,
    videoTags: services.videoTags,
    downloads,
    conversion,
    markers,
    addresses: (serverId) =>
      serverAddresses({
        serverId,
        port: config.port,
        advertised: config.advertise,
        remote: config.addresses.remote,
      }),
    artwork: new ArtworkStore(
      services.db,
      join(config.dataDir, "cache", "artwork"),
      config.ffmpegPath,
    ),
    logos,
    music: services.music,
    edit: { catalogue: services.catalogue, enricher, chosen },
    omdb,
    search: {
      service: search,
      outside: new OutsideSearch(() => enricher.outside, omdb),
    },
    relays: config.outside?.tls?.relays ?? [],
    outside,
    remote,
    wake,
    speakers: speakerService,
    settings: { service: settings, browser },
    imports: {
      imports,
      uploads,
      roots: () => config.roots,
      settings: () => ({
        waitMinutes: config.imports.waitMinutes,
        copyAcrossDrives: config.imports.copyAcrossDrives,
        maxFileGb: config.imports.maxFileGb,
        quotaGb: config.imports.quotaGb,
      }),
    },
    stats,
    storage: () => {
      const size = (path: string): number => {
        try {
          return statSync(path).size;
        } catch {
          return 0;
        }
      };
      const database = join(config.dataDir, "lobby.db");
      let free: number | null = null;
      let total: number | null = null;
      try {
        const volume = statfsSync(config.dataDir);
        free = volume.bavail * volume.bsize;
        total = volume.blocks * volume.bsize;
      } catch {
        // Not every system says; the page then leaves it out.
      }
      return {
        playbackCacheBytes: playback.cacheBytes(),
        playbackCacheMaxBytes: config.playback.maxCacheGb * GB,
        musicCacheBytes: services.music.copies.totalBytes(),
        musicCacheMaxBytes: config.music.maxCacheGb * GB,
        databaseBytes: size(database) + size(`${database}-wal`),
        dataFreeBytes: free,
        dataTotalBytes: total,
      };
    },
    serverName: config.serverName,
    version: VERSION,
    isScanning: () => services.scanner.isScanning,
  };
  const app = createApp(deps);

  const frames = new FrameMaker(services.db, services.catalogue, {
    dir: join(config.dataDir, "artwork"),
    ffmpegPath: config.ffmpegPath,
  });
  const loop = new LibraryLoop(services.scanner, config, frames, enricher, {
    omdb,
    service: search,
  });
  const server: ServerType = serve(
    { fetch: app.fetch, hostname: config.host, port: config.port },
    (info) => {
      log.info("Lobby Server is listening", {
        address: info.address,
        port: info.port,
        version: VERSION,
      });
      if (!services.devices.isClaimed) {
        log.info(
          config.claim === "open"
            ? "No manager yet. The first device that connects sets this server up."
            : // Shown here, on the Pi's own console, and nowhere else.
              `No manager yet. Claim this server from the Mac app with the setup secret: ${services.setupSecret}`,
        );
      }
    },
  );
  const announceNow = (): (() => Promise<void>) | null =>
    config.advertise
      ? announce({
          serverName: config.serverName,
          serverId: services.db.getMeta("server_id") ?? "",
          port: config.port,
          apiVersion: API_VERSION,
        })
      : null;
  let withdraw = announceNow();

  applyLive = async (next, _previous, changed) => {
    if (changed.includes("serverName")) {
      deps.serverName = next.serverName;
      // Announced again under the new name; devices looking see it at once.
      const before = withdraw;
      withdraw = null;
      await before?.();
      withdraw = announceNow();
    }
    if (changed.some((key) => key.startsWith("import.") || key.startsWith("uploads."))) {
      for (const source of imports.indexSources()) services.scanner.setFilter(source.path, null);
      imports.configure({
        folders: next.imports.folders,
        waitMs: next.imports.waitMinutes * 60_000,
        copyAcrossDrives: next.imports.copyAcrossDrives,
      });
      filterIndexFolders();
    }
    if (changed.includes("roots") || changed.includes("import.folders")) {
      services.scanner.syncSources(librarySources());
    }
    if (changed.includes("roots") || changed.includes("rescanMinutes")) loop.refresh();
    if (changed.includes("import.folders")) {
      void services.scanner.scanAll().catch(() => undefined);
    }
    if (changed.some((key) => key.startsWith("conversion."))) {
      conversion.configure({
        hours: next.conversion.hours,
        repackage: next.conversion.repackage,
        serverConverts: next.conversion.server,
        minFreeBytes: next.conversion.minFreeGb * GB,
      });
    }
    if (changed.some((key) => key.startsWith("remote.wake."))) {
      wake.settingsChanged();
      await speakerService.settingsChanged();
    }
    // The addresses and the backups are read from the config each time: nothing to do.
  };
  startScanning = () => {
    loop.release();
  };

  // Before the first scan: a replacement that was interrupted is finished or taken back first.
  await conversion.start();
  // Also before the first scan: a move that was interrupted is finished or taken back first.
  await imports.start();
  await uploads.start();
  loop.start(settings.holdsScanning);
  await services.music.start();
  downloads.start();
  await markers.start();
  // Older HEVC files were judged without their picture label. Reading it is cheap (headers
  // only), one file at a time, shortly after start; a file played before is read on demand.
  let closing = false;
  const tagTimer = setTimeout(() => {
    services.videoTags
      .checkPending(() => closing)
      .catch((error: unknown) => {
        log.error("Reading picture labels failed", { error: errorMessage(error) });
      });
  }, 30_000);
  tagTimer.unref();
  wake.start();
  speakerService.start();
  services.progress.prune();
  if (config.outside) await outside.start(createApp(deps, "outside"));
  let backingUp: Promise<void> = Promise.resolve();
  const backUp = (): void => {
    backingUp = backingUp.then(async () => {
      try {
        await backupIfDue(services.db, config);
      } catch (error) {
        log.error("Could not back up the catalogue", { error: errorMessage(error) });
      }
    });
  };
  backUp();
  const backupTimer = setInterval(backUp, 3_600_000);

  return {
    services,
    remote,
    app,
    settings,
    close: () =>
      new Promise((resolve) => {
        closing = true;
        clearTimeout(tagTimer);
        loop.stop();
        omdb.stop();
        uploads.stop();
        logos.stop();
        remote.stop();
        clearInterval(backupTimer);
        const outsideStopped = outside.stop();
        server.close(() => {
          void Promise.all([
            outsideStopped,
            enricher.stop(),
            services.music.stop(),
            // First, so it does not start another copy while the playback service closes.
            downloads.stop().then(() => playback.close()),
            conversion.stop(),
            markers.stop(),
            imports.stop(),
            // First, so that what streams to a speaker is stopped while the helper still runs.
            speakerService.stop().then(() => wake.stop()),
            backingUp,
            withdraw?.(),
          ]).finally(() => {
            services.db.close();
            resolve();
          });
        });
        // A player keeps its connection open between requests. Without this the server
        // would wait for every device to hang up before it stops.
        if ("closeAllConnections" in server) server.closeAllConnections();
      }),
  };
}

/** The box's key, which also signs for it with the push relay. Null, and said, when it is damaged. */
function pushBox(dataDir: string): BoxSigner | null {
  try {
    return new BoxKeys(dataDir);
  } catch (error) {
    log.error("Push notifications are off: the box's keys cannot be used", {
      problem: errorMessage(error),
    });
    return null;
  }
}
