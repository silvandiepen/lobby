// SPDX-License-Identifier: MPL-2.0
import { randomBytes, randomUUID } from "node:crypto";
import { AuthError, type Device } from "../auth/devices.ts";
import type { WakeConfig } from "../config.ts";
import type { Database } from "../db/database.ts";
import { ApiError } from "../http/app.ts";
import { openablePath } from "../http/serve-file.ts";
import { OWNER_HOUSEHOLD } from "../households/owner.ts";
import { errorMessage, log } from "../log.ts";
import type { MusicLibrary } from "../music/library.ts";
import { RateLimiter } from "../outside/limits.ts";
import { WakeHelperError, type WakeHelper } from "./wake-helper.ts";

/** How often the network is looked at for speakers while the helper runs. */
export const SPEAKER_TIMINGS = {
  scanEveryMs: 60_000,
  /** A speaker that missed this many looks in a row is gone. Multicast misses one now and then. */
  missesGone: 2,
  /** How often what plays for a child is looked at again, and a story's place written. */
  tickMs: 1_000,
  kidsEveryMs: 5_000,
  saveEveryMs: 15_000,
};

export const SPEAKER_RATES = {
  plays: { burst: 10, perMinute: 30 },
  controls: { burst: 30, perMinute: 240 },
  manage: { burst: 10, perMinute: 10 },
} as const;

const STREAM_TIMEOUT_MS = 30_000;
const SCAN_TIMEOUT_MS = 20_000;
const MAX_QUEUE = 500;
/** "Previous" goes to the start of the track after this much of it. */
const RESTART_AFTER_MS = 3_000;

export type SpeakerAccess = "open" | "password" | "home_only";
export type SpeakerKind = "homepod" | "speaker";
export type SpeakerStatus = "loading" | "playing" | "paused" | "ended" | "error";
/** Why a speaker stopped by itself, in a fixed list (free text could hold a title). */
export type SpeakerProblem =
  "refused" | "not_found" | "timeout" | "unavailable" | "drive_away" | "kids_mode" | "failed";

/** What plays on a speaker, as one device is shown it. */
export type ShownSpeakerPlay =
  | { redacted: true; status: SpeakerStatus }
  | {
      redacted: false;
      /** The viewer it plays for: their place in a story is kept, their listens counted. */
      profileId: string;
      /** A story (`bookId`) or music. */
      kind: "story" | "music";
      bookId: string | null;
      albumId: string | null;
      trackIds: string[];
      index: number;
      trackId: string;
      status: SpeakerStatus;
      /** Where it was in the track at `at`, by the server's clock; moves on while `playing`. */
      positionMs: number;
      at: number;
      durationMs: number | null;
      problem: SpeakerProblem | null;
      /** The device that started it. */
      startedBy: string;
    };

/** A speaker in Play On. */
export interface ShownSpeaker {
  id: string;
  name: string;
  kind: SpeakerKind;
  /** Something can be started on it now: it is on the network and the helper runs. */
  canPlay: boolean;
  /** "home_only" and "password": it will probably refuse; say why before trying. */
  access: SpeakerAccess;
  /** 0 to 1, as the speaker last said; null before it played. */
  volume: number | null;
  /** What plays on it can be paused, stopped and so on by who looks. */
  controllable: boolean;
  play: ShownSpeakerPlay | null;
}

/** A speaker as a manager sees it. */
export interface ManagedSpeaker {
  id: string;
  name: string;
  /** What the speaker calls itself. */
  foundName: string;
  /** What a manager named it; null: its own name. */
  customName: string | null;
  model: string;
  kind: SpeakerKind;
  hidden: boolean;
  /** It answered one of the last looks on the network. */
  found: boolean;
  access: SpeakerAccess;
  /** A password for it is kept in pyatv's file. */
  hasPassword: boolean;
  playing: boolean;
}

export interface SpeakersStatus {
  /** `remote.wake` is in lobby.config.json: the helper is set up. */
  configured: boolean;
  /** The setting `remote.wake.speakers`. */
  enabled: boolean;
  running: boolean;
  problem: string | null;
  scannedAt: number | null;
  speakers: ManagedSpeaker[];
}

/** Who asks, as far as speakers go. */
export interface SpeakerAsker {
  device: Device;
  /** The viewer the app has in front; null: nobody chosen. */
  profileId: string | null;
  /** The kids viewer who uses it: its own child, or the one its kids screens show. */
  kid: string | null;
  /** From the home network (or the tailnet): starting needs it. */
  nearby: boolean;
}

/** What may be listened to by a child now (kids/control.ts); null: music is off for it. */
export type ListenCheck = (
  profileId: string,
  deviceId: string,
) => { allowed: boolean; sources: string[] | null } | null;

export interface SpeakerPlayRequest {
  profileId: string;
  /** Music: these tracks, from `index`. */
  trackIds: string[] | null;
  index: number;
  /** A story: its tracks in order, from `startMs` on its own line of time, or where the viewer was. */
  bookId: string | null;
  /** In the track for music, on the book's line of time for a story; null: from the start, or where the viewer was in a story. */
  startMs: number | null;
  /** What the app shows it as. */
  albumId: string | null;
}

export type SpeakerAction =
  | { type: "pause" | "resume" | "stop" | "next" | "previous" }
  | { type: "skip"; deltaMs: number }
  | { type: "seek"; positionMs: number }
  | { type: "volume"; volume: number };

interface Row {
  id: string;
  pyatv_id: string;
  found_name: string;
  name: string | null;
  model: string;
  kind: SpeakerKind;
  hidden: number;
}

interface Seen {
  access: SpeakerAccess;
  hasPassword: boolean;
  misses: number;
}

interface TrackInfo {
  id: string;
  title: string;
  artistCredit: string;
  albumId: string | null;
  durationMs: number | null;
}

interface Play {
  speakerId: string;
  profileId: string;
  startedBy: string;
  bookId: string | null;
  albumId: string | null;
  tracks: TrackInfo[];
  index: number;
  status: SpeakerStatus;
  positionMs: number;
  at: number;
  problem: SpeakerProblem | null;
  /** The helper's stream for what sounds now; null while nothing does. */
  stream: string | null;
  /** How much of the current track was heard, for the listens. */
  heardMs: number;
  listenStartedAt: number;
  savedAt: number;
}

export interface SpeakerOptions {
  db: Database;
  music: MusicLibrary;
  config: () => WakeConfig | null;
  helper: () => WakeHelper | null;
  ffmpegPath: string;
  /** What devices are shown changed. */
  changed: () => void;
  now?: () => number;
  timings?: Partial<typeof SPEAKER_TIMINGS>;
}

/**
 * HomePods and other AirPlay speakers (docs/decisions.md, "Play on a speaker"). Lobby Server
 * finds them on its network through the helper of the Apple TVs (`tools/wake.py`, pyatv's RAOP),
 * and plays music and stories to them itself: the phone only says what, and can go. The place in
 * a story and the listens are written for the viewer it plays for, as the apps do when they play.
 */
export class SpeakerService {
  private readonly options: SpeakerOptions;
  private readonly now: () => number;
  private readonly timings: typeof SPEAKER_TIMINGS;
  private readonly seen = new Map<string, Seen>();
  private readonly plays = new Map<string, Play>();
  private readonly volumes = new Map<string, number>();
  /** One thing at a time per speaker: a pause must not overtake the start it follows. */
  private readonly serial = new Map<string, Promise<unknown>>();
  private readonly rates: Record<keyof typeof SPEAKER_RATES, RateLimiter>;
  private rows: Row[] = [];
  private scannedAt: number | null = null;
  private scanTimer: NodeJS.Timeout | null = null;
  private tickTimer: NodeJS.Timeout | null = null;
  private kidsAt = 0;
  private scanning: Promise<void> | null = null;
  private stopped = false;
  /** A child's plan: whether it may listen now. Set by the server. */
  listen: ListenCheck = () => ({ allowed: true, sources: null });

  constructor(options: SpeakerOptions) {
    this.options = options;
    this.now = options.now ?? Date.now;
    this.timings = { ...SPEAKER_TIMINGS, ...options.timings };
    this.rates = {
      plays: new RateLimiter(SPEAKER_RATES.plays, this.now, 256),
      controls: new RateLimiter(SPEAKER_RATES.controls, this.now, 256),
      manage: new RateLimiter(SPEAKER_RATES.manage, this.now, 64),
    };
    this.load();
  }

  start(): void {
    this.stopped = false;
    this.watch();
    this.helperChanged();
  }

  async stop(): Promise<void> {
    this.stopped = true;
    if (this.scanTimer) clearInterval(this.scanTimer);
    if (this.tickTimer) clearInterval(this.tickTimer);
    this.scanTimer = null;
    this.tickTimer = null;
    for (const play of this.plays.values()) this.save(play);
    await Promise.all(
      [...this.plays.values()].map((play) => this.stopStream(play).catch(() => undefined)),
    );
    this.plays.clear();
  }

  private get config(): WakeConfig | null {
    return this.options.config();
  }

  private get enabled(): boolean {
    return this.config?.speakers === true;
  }

  private running(): WakeHelper | null {
    const helper = this.options.helper();
    return helper?.isUp ? helper : null;
  }

  private load(): void {
    this.rows = this.options.db.all<Row>(
      "select id, pyatv_id, found_name, name, model, kind, hidden from speaker order by coalesce(name, found_name), id",
    );
  }

  private nameOf(row: Row): string {
    return row.name ?? row.found_name;
  }

  // ---- The helper ----

  /** The helper came up or went down. Looks at the network while it runs. */
  helperChanged(): void {
    if (this.stopped) return;
    const up = this.running() !== null && this.enabled;
    if (up && !this.scanTimer) {
      void this.scan().catch(() => undefined);
      this.scanTimer = setInterval(() => {
        void this.scan().catch(() => undefined);
      }, this.timings.scanEveryMs);
      this.scanTimer.unref();
    }
    if (!up && this.scanTimer) {
      clearInterval(this.scanTimer);
      this.scanTimer = null;
    }
    if (!up) {
      // What streamed is gone with the helper; a story waits where it was.
      for (const play of this.plays.values()) {
        if (play.status === "playing" || play.status === "loading") {
          this.halt(play, "unavailable");
        }
      }
    }
    this.options.changed();
  }

  /** The setting `remote.wake.speakers` changed. Off stops what plays. */
  async settingsChanged(): Promise<void> {
    if (!this.enabled) {
      for (const play of [...this.plays.values()]) {
        await this.run(play.speakerId, () => this.end(play, null));
      }
    }
    this.helperChanged();
  }

  /** What the helper says by itself. */
  helperEvent(event: Record<string, unknown>): void {
    if (event["event"] !== "stream_ended") return;
    const stream = event["stream"];
    const play = [...this.plays.values()].find((one) => one.stream === stream);
    if (!play || typeof stream !== "string") return;
    const reason = event["reason"];
    // Stopped by Lobby Server itself: that was handled where it was asked.
    if (reason === "stopped") return;
    play.stream = null;
    void this.run(play.speakerId, async () => {
      if (this.plays.get(play.speakerId) !== play) return;
      if (reason === "ended") {
        await this.advance(play);
      } else {
        const code = event["code"];
        this.halt(play, code === "refused" ? "refused" : code === "timeout" ? "timeout" : "failed");
        log.warn("A speaker stopped playing", { speaker: play.speakerId, code: String(code) });
      }
      this.options.changed();
    }).catch(() => undefined);
  }

  private async ask(
    op: string,
    fields: Record<string, unknown>,
    timeoutMs?: number,
  ): Promise<Record<string, unknown>> {
    const helper = this.running();
    if (!helper) {
      throw new ApiError("unavailable", "Speakers cannot be reached now.", {
        reason: "speaker_unavailable",
      });
    }
    try {
      return await helper.ask(op, fields, timeoutMs);
    } catch (error) {
      if (!(error instanceof WakeHelperError)) throw error;
      throw this.refusal(error.code);
    }
  }

  private refusal(code: string, name = "The speaker"): ApiError {
    switch (code) {
      case "refused":
        return new ApiError(
          "forbidden",
          `${name} did not let Lobby Server play. In the Home app, set Allow Speaker & TV Access to “Everyone on the Same Network”, or enter its password under Speakers.`,
          { reason: "speaker_refused" },
        );
      case "not_found":
        return new ApiError(
          "not_found",
          `${name} was not found on the network. Is it plugged in?`,
          { reason: "speaker_not_found" },
        );
      case "timeout":
        return new ApiError("unavailable", `${name} did not answer in time.`, {
          reason: "speaker_timeout",
        });
      case "bad_request":
        return new ApiError("invalid_request", "The speaker could not be asked that.", {
          reason: "speaker_failed",
        });
      default:
        return new ApiError("unavailable", `${name} could not be reached.`, {
          reason: "speaker_unavailable",
        });
    }
  }

  // ---- Finding them ----

  /** Looks on the network for speakers; new ones are remembered, gone ones marked so. */
  async scan(): Promise<void> {
    if (this.scanning) return this.scanning;
    const looking = (async () => {
      const config = this.config;
      const answer = await this.ask(
        "speakers",
        { timeout: 5, ...(config && config.hosts.length > 0 ? { hosts: config.hosts } : {}) },
        SCAN_TIMEOUT_MS,
      );
      const found = Array.isArray(answer["speakers"]) ? answer["speakers"].slice(0, 64) : [];
      const now = this.now();
      const here = new Set<string>();
      for (const value of found) {
        const one = readSpeaker(value);
        if (!one) continue;
        here.add(one.id);
        this.options.db.run(
          `insert into speaker (id, pyatv_id, found_name, name, model, kind, hidden, first_seen_at, last_seen_at)
           values (?, ?, ?, null, ?, ?, 0, ?, ?)
           on conflict (pyatv_id) do update set found_name = excluded.found_name,
             model = excluded.model, kind = excluded.kind, last_seen_at = excluded.last_seen_at`,
          [randomBytes(9).toString("base64url"), one.id, one.name, one.model, one.kind, now, now],
        );
        this.seen.set(one.id, { access: one.access, hasPassword: one.hasPassword, misses: 0 });
      }
      for (const [id, one] of this.seen) {
        if (here.has(id)) continue;
        one.misses += 1;
        if (one.misses >= this.timings.missesGone) this.seen.delete(id);
      }
      this.scannedAt = now;
      this.load();
      this.options.changed();
    })();
    this.scanning = looking;
    try {
      await looking;
    } finally {
      this.scanning = null;
    }
  }

  private isFound(row: Row): boolean {
    return this.seen.has(row.pyatv_id) || this.plays.get(row.id)?.stream != null;
  }

  // ---- A manager's page ----

  status(): SpeakersStatus {
    const config = this.config;
    const helper = this.options.helper();
    return {
      configured: config !== null,
      enabled: config?.speakers ?? false,
      running: helper?.isUp ?? false,
      problem: config === null ? null : (helper?.problem ?? null),
      scannedAt: this.scannedAt,
      speakers: this.rows.map((row) => {
        const seen = this.seen.get(row.pyatv_id);
        return {
          id: row.id,
          name: this.nameOf(row),
          foundName: row.found_name,
          customName: row.name,
          model: row.model,
          kind: row.kind,
          hidden: row.hidden === 1,
          found: this.isFound(row),
          access: seen?.access ?? "open",
          hasPassword: seen?.hasPassword ?? false,
          playing: this.plays.has(row.id),
        };
      }),
    };
  }

  private managed(id: string): ManagedSpeaker {
    const one = this.status().speakers.find((speaker) => speaker.id === id);
    if (!one) throw new ApiError("not_found", "There is no such speaker.");
    return one;
  }

  private row(id: string): Row {
    const row = this.rows.find((one) => one.id === id);
    if (!row) throw new ApiError("not_found", "There is no such speaker.");
    return row;
  }

  async scanNow(by: Device): Promise<SpeakersStatus> {
    this.configured();
    this.limit("manage", by.id);
    await this.scan();
    return this.status();
  }

  /** A manager names a speaker (null: its own name again) or hides it from Play On. */
  async change(
    id: string,
    change: { name?: string | null; hidden?: boolean },
  ): Promise<ManagedSpeaker> {
    const row = this.row(id);
    if (change.name !== undefined) {
      this.options.db.run("update speaker set name = ? where id = ?", [change.name, row.id]);
    }
    if (change.hidden !== undefined) {
      this.options.db.run("update speaker set hidden = ? where id = ?", [
        change.hidden ? 1 : 0,
        row.id,
      ]);
      const play = this.plays.get(row.id);
      if (change.hidden && play) await this.run(row.id, () => this.end(play, null));
    }
    this.load();
    this.options.changed();
    return this.managed(row.id);
  }

  /** Keeps a speaker's password in pyatv's file, as the Apple TVs' credentials are; null removes it. */
  async setPassword(by: Device, id: string, password: string | null): Promise<ManagedSpeaker> {
    this.configured();
    this.limit("manage", by.id);
    const row = this.row(id);
    await this.ask("speaker_password", { speaker: row.pyatv_id, password });
    const seen = this.seen.get(row.pyatv_id);
    if (seen) {
      seen.hasPassword = password !== null;
      if (seen.access === "password" && password !== null) seen.access = "open";
    }
    log.info("Changed a speaker's password", { speaker: row.id, device: by.id });
    this.options.changed();
    return this.managed(row.id);
  }

  private configured(): void {
    if (!this.config) {
      throw new ApiError("not_found", "Speakers are not set up on this server.", {
        reason: "speakers_not_configured",
      });
    }
  }

  private limit(rate: keyof typeof SPEAKER_RATES, key: string): void {
    const wait = this.rates[rate].take(key);
    if (wait > 0) {
      throw new AuthError("rate_limited", "That was a lot at once. Try again in a moment.", wait);
    }
  }

  // ---- What devices are shown ----

  /** Whether a device may have speakers at all: the owner's household's, at home, with Play On. */
  private mayUse(device: Device): boolean {
    return (
      this.config !== null &&
      this.enabled &&
      device.revokedAt === null &&
      device.allowRemote &&
      device.householdId === OWNER_HOUSEHOLD
    );
  }

  /**
   * The speakers for one session of the live channel; null when there are none to speak of (not
   * set up), so that nothing is said. A child sees them only while it may listen.
   */
  shownTo(asker: Omit<SpeakerAsker, "nearby"> & { outside: boolean }): ShownSpeaker[] | null {
    if (this.config === null) return null;
    if (asker.outside || !this.mayUse(asker.device)) return [];
    if (asker.kid !== null && this.listen(asker.kid, asker.device.id)?.allowed !== true) return [];
    const up = this.running() !== null;
    return this.rows
      .filter((row) => row.hidden === 0 && (this.isFound(row) || this.plays.has(row.id)))
      .map((row) => this.shown(row, asker.kid, up));
  }

  private shown(row: Row, kid: string | null, up = this.running() !== null): ShownSpeaker {
    const play = this.plays.get(row.id) ?? null;
    const seen = this.seen.get(row.pyatv_id);
    const mine = play !== null && (kid === null || play.profileId === kid);
    return {
      id: row.id,
      name: this.nameOf(row),
      kind: row.kind,
      canPlay: up && seen !== undefined,
      access: seen?.access ?? "open",
      volume: this.volumes.get(row.id) ?? null,
      controllable: mine,
      play:
        play === null
          ? null
          : mine
            ? this.shownPlay(play)
            : { redacted: true, status: play.status },
    };
  }

  private shownPlay(play: Play): ShownSpeakerPlay {
    const track = play.tracks[play.index];
    return {
      redacted: false,
      profileId: play.profileId,
      kind: play.bookId === null ? "music" : "story",
      bookId: play.bookId,
      albumId: play.albumId ?? track?.albumId ?? null,
      trackIds: play.tracks.map((one) => one.id),
      index: play.index,
      trackId: track?.id ?? "",
      status: play.status,
      positionMs: play.positionMs,
      at: play.at,
      durationMs: track?.durationMs ?? null,
      problem: play.problem,
      startedBy: play.startedBy,
    };
  }

  // ---- Playing ----

  /** Runs one thing at a time for a speaker. */
  private run<T>(speakerId: string, work: () => Promise<T>): Promise<T> {
    const before = this.serial.get(speakerId) ?? Promise.resolve();
    const next = before.then(work, work);
    const kept = next.catch(() => undefined);
    this.serial.set(speakerId, kept);
    void kept.then(() => {
      if (this.serial.get(speakerId) === kept) this.serial.delete(speakerId);
    });
    return next;
  }

  /** The speaker for this asker, or 404 as if there were none. */
  private target(asker: SpeakerAsker, speakerId: string): Row {
    if (!this.mayUse(asker.device)) {
      throw new ApiError("not_found", "There is no such speaker.");
    }
    const row = this.rows.find((one) => one.id === speakerId && one.hidden === 0);
    if (!row) throw new ApiError("not_found", "There is no such speaker.");
    return row;
  }

  private notAllowed(): ApiError {
    return new ApiError("forbidden", "This cannot be played there.", {
      reason: "title_not_allowed",
    });
  }

  /** Whether the viewer is a kids viewer of the owner's household; null: no such viewer. */
  private viewer(profileId: string): { kids: boolean } | null {
    const row = this.options.db.get<{ kids: number }>(
      `select kids_json is not null as kids from profile
       where id = ? and deleted_at is null and household_id = ?`,
      [profileId, OWNER_HOUSEHOLD],
    );
    return row ? { kids: row.kids === 1 } : null;
  }

  /** Throws unless a child may listen to these tracks now, on the device that asks. */
  private checkChild(profileId: string, deviceId: string, tracks: string[]): void {
    const may = this.listen(profileId, deviceId);
    if (may === null) throw new ApiError("not_found", "There is nothing here for this viewer.");
    if (!may.allowed) {
      throw new ApiError("forbidden", "This is not for now.", { reason: "kids_mode" });
    }
    const sources = may.sources;
    if (sources === null) return;
    const outside = this.options.db.get(
      `select 1 as x from music_track where id in (select value from json_each(?))
         and source_id not in (select value from json_each(?)) limit 1`,
      [JSON.stringify(tracks), JSON.stringify(sources)],
    );
    if (outside) throw new ApiError("not_found", "There is nothing here for this viewer.");
  }

  /** Starts music or a story on a speaker, for a viewer. Answers once the speaker plays. */
  async play(
    asker: SpeakerAsker,
    speakerId: string,
    request: SpeakerPlayRequest,
  ): Promise<ShownSpeaker> {
    const row = this.target(asker, speakerId);
    if (!asker.nearby) {
      throw new ApiError("forbidden", "Speakers can only be played on from home.", {
        reason: "home_only",
      });
    }
    this.limit("plays", asker.device.id);
    const viewer = this.viewer(request.profileId);
    if (!viewer) throw new ApiError("not_found", "There is no such viewer.");
    // A child plays only as itself; a bound kids device only as its own child.
    if (asker.kid !== null && request.profileId !== asker.kid) throw this.notAllowed();
    if (asker.device.kidsProfileId !== null && request.profileId !== asker.device.kidsProfileId) {
      throw this.notAllowed();
    }
    const { tracks, index, startMs, bookId } = this.queueOf(request);
    if (viewer.kids) {
      this.checkChild(
        request.profileId,
        asker.device.id,
        tracks.map((one) => one.id),
      );
    }
    return this.run(row.id, async () => {
      const before = this.plays.get(row.id);
      // What plays as someone else is not a child's to play over.
      if (before && asker.kid !== null && before.profileId !== asker.kid) {
        throw new ApiError("conflict", "Something else plays there.", { reason: "speaker_busy" });
      }
      if (before) await this.end(before, null);
      const now = this.now();
      const play: Play = {
        speakerId: row.id,
        profileId: request.profileId,
        startedBy: asker.device.id,
        bookId,
        albumId: request.albumId,
        tracks,
        index,
        status: "loading",
        positionMs: startMs,
        at: now,
        problem: null,
        stream: null,
        heardMs: 0,
        listenStartedAt: now,
        savedAt: now,
      };
      this.plays.set(row.id, play);
      this.options.changed();
      try {
        await this.sound(play);
      } catch (error) {
        if (this.plays.get(row.id) === play) this.plays.delete(row.id);
        this.options.changed();
        if (error instanceof ApiError && error.extra["reason"] === "speaker_refused") {
          throw this.refusal("refused", this.nameOf(row));
        }
        throw error;
      }
      log.info("Playing on a speaker", { speaker: row.id, device: asker.device.id });
      this.options.changed();
      return this.shown(row, asker.kid);
    });
  }

  /** The tracks to play and where to begin: a story's from the viewer's place, or what was asked. */
  private queueOf(request: SpeakerPlayRequest): {
    tracks: TrackInfo[];
    index: number;
    startMs: number;
    bookId: string | null;
  } {
    const reader = this.options.music.reader;
    if (request.bookId !== null) {
      const book = reader.books([request.bookId])[0];
      const tracks = reader.tracksOfBook(request.bookId);
      if (!book || tracks.length === 0) throw new ApiError("not_found", "There is no such story.");
      let at = request.startMs;
      if (at === null) {
        const kept = this.options.music.progress
          .list(request.profileId, 0)
          .find((one) => one.itemId === book.id);
        at = kept && !kept.completed ? kept.positionMs : 0;
      }
      const clamped = Math.max(0, Math.min(at, book.durationMs));
      const part = book.parts.findLastIndex((one) => one.startMs <= clamped);
      const index = Math.max(0, part);
      return {
        tracks: tracks.map(trackInfo),
        index,
        startMs: clamped - (book.parts[index]?.startMs ?? 0),
        bookId: book.id,
      };
    }
    const ids = request.trackIds ?? [];
    if (ids.length === 0 || ids.length > MAX_QUEUE) {
      throw new ApiError("invalid_request", `"trackIds" must be 1 to ${String(MAX_QUEUE)} tracks.`);
    }
    const found = new Map(reader.tracks(ids).map((one) => [one.id, one]));
    const tracks = ids.map((id) => found.get(id));
    if (tracks.some((one) => one === undefined)) {
      throw new ApiError("not_found", "There is no such track.");
    }
    const known = tracks as NonNullable<(typeof tracks)[number]>[];
    if (request.index < 0 || request.index >= known.length) {
      throw new ApiError("invalid_request", `"index" must be one of the tracks.`);
    }
    return {
      tracks: known.map(trackInfo),
      index: request.index,
      startMs: Math.max(0, request.startMs ?? 0),
      bookId: null,
    };
  }

  /** What a device does with what plays on a speaker. */
  async control(
    asker: SpeakerAsker,
    speakerId: string,
    action: SpeakerAction,
  ): Promise<ShownSpeaker> {
    const row = this.target(asker, speakerId);
    this.limit("controls", asker.device.id);
    return this.run(row.id, async () => {
      const play = this.plays.get(row.id);
      if (!play) {
        throw new ApiError("conflict", "Nothing plays there.", { reason: "nothing_playing" });
      }
      // A child controls only what plays as itself.
      if (asker.kid !== null && play.profileId !== asker.kid) throw this.notAllowed();
      const child = this.viewer(play.profileId)?.kids === true;
      const starts = !["pause", "stop", "volume"].includes(action.type);
      // Going on is listening again: a child only while it may. Pausing and stopping always.
      if (child && starts) {
        this.checkChild(
          play.profileId,
          asker.device.id,
          play.tracks.map((one) => one.id),
        );
      }
      switch (action.type) {
        case "pause":
          if (play.status === "playing" || play.status === "loading") {
            await this.stopStream(play);
            this.halt(play, null, "paused");
          }
          break;
        case "resume":
          if (play.status !== "playing") {
            if (play.status === "ended") this.moveTo(play, 0, 0);
            await this.sound(play);
          }
          break;
        case "stop":
          await this.end(play, null);
          break;
        case "next":
          if (play.index + 1 < play.tracks.length) {
            await this.jump(play, play.index + 1, 0);
          } else {
            await this.stopStream(play);
            this.finishListen(play, false);
            this.halt(play, null, "ended");
          }
          break;
        case "previous":
          if (this.place(play) > RESTART_AFTER_MS || play.index === 0) {
            await this.jump(play, play.index, 0);
          } else {
            await this.jump(play, play.index - 1, 0);
          }
          break;
        case "skip": {
          const [index, ms] = this.after(play, this.place(play) + action.deltaMs);
          await this.jump(play, index, ms);
          break;
        }
        case "seek":
          await this.jump(
            play,
            play.index,
            Math.max(
              0,
              Math.min(action.positionMs, play.tracks[play.index]?.durationMs ?? action.positionMs),
            ),
          );
          break;
        case "volume": {
          const volume = Math.max(0, Math.min(1, action.volume));
          this.volumes.set(row.id, volume);
          if (play.stream) {
            const answer = await this.ask("volume", { stream: play.stream, volume });
            if (typeof answer["volume"] === "number") this.volumes.set(row.id, answer["volume"]);
          }
          break;
        }
      }
      this.options.changed();
      return this.shown(row, asker.kid);
    });
  }

  /** Where it is in the current track now. */
  private place(play: Play): number {
    if (play.status !== "playing") return play.positionMs;
    const moved = play.positionMs + Math.max(0, this.now() - play.at);
    const duration = play.tracks[play.index]?.durationMs ?? null;
    return duration === null ? moved : Math.min(moved, duration);
  }

  /** The track and place `ms` from the start of the current track, across the tracks of the queue. */
  private after(play: Play, ms: number): [number, number] {
    let index = play.index;
    let at = ms;
    while (at < 0 && index > 0) {
      index -= 1;
      at += play.tracks[index]?.durationMs ?? 0;
    }
    if (at < 0) return [index, 0];
    for (;;) {
      const duration = play.tracks[index]?.durationMs ?? null;
      if (duration === null || at < duration || index + 1 >= play.tracks.length) {
        return [index, duration === null ? at : Math.min(at, Math.max(0, duration - 1_000))];
      }
      at -= duration;
      index += 1;
    }
  }

  /** Plays from another place: what sounds stops, and starts again there if it played. */
  private async jump(play: Play, index: number, ms: number): Promise<void> {
    const playing = play.status === "playing" || play.status === "loading";
    await this.stopStream(play);
    if (index !== play.index) this.finishListen(play, false);
    this.moveTo(play, index, ms);
    if (playing) await this.sound(play);
    else this.save(play);
  }

  private moveTo(play: Play, index: number, ms: number): void {
    if (index !== play.index) {
      play.heardMs = 0;
      play.listenStartedAt = this.now();
    }
    play.index = index;
    play.positionMs = ms;
    play.at = this.now();
  }

  /** Makes the speaker sound the current track from `positionMs`. */
  private async sound(play: Play): Promise<void> {
    const track = play.tracks[play.index];
    const row = this.row(play.speakerId);
    if (!track) throw new ApiError("not_found", "There is no such track.");
    const file = this.options.db.get<{
      rel_path: string;
      available: number;
      source_path: string;
      source_available: number;
    }>(
      `select rel_path, music_track.available, music_source.path as source_path,
         music_source.available as source_available
       from music_track join music_source on music_source.id = music_track.source_id
       where music_track.id = ?`,
      [track.id],
    );
    if (!file || file.available !== 1 || file.source_available !== 1) {
      this.halt(play, "drive_away");
      throw new ApiError("unavailable", "The drive this music is on is not connected right now.", {
        reason: "drive_away",
      });
    }
    const { path } = await openablePath({
      id: track.id,
      root: file.source_path,
      relPath: file.rel_path,
    });
    const stream = randomUUID();
    play.status = "loading";
    play.problem = null;
    const album = track.albumId ? this.options.music.reader.albums([track.albumId])[0] : undefined;
    const book = play.bookId ? this.options.music.reader.books([play.bookId])[0] : undefined;
    const volume = this.volumes.get(play.speakerId);
    let answer: Record<string, unknown>;
    try {
      answer = await this.ask(
        "stream",
        {
          speaker: row.pyatv_id,
          stream,
          ffmpeg: this.options.ffmpegPath,
          file: path,
          startMs: Math.round(play.positionMs),
          ...(volume === undefined ? {} : { volume }),
          title: track.title,
          artist: track.artistCredit,
          album: book?.title ?? album?.title ?? null,
        },
        STREAM_TIMEOUT_MS,
      );
    } catch (error) {
      const reason = error instanceof ApiError ? error.extra["reason"] : undefined;
      this.halt(
        play,
        reason === "speaker_refused"
          ? "refused"
          : reason === "speaker_not_found"
            ? "not_found"
            : reason === "speaker_timeout"
              ? "timeout"
              : "unavailable",
      );
      if (reason === "speaker_refused") {
        const seen = this.seen.get(row.pyatv_id);
        if (seen && seen.access === "open") seen.access = "home_only";
      }
      throw error;
    }
    play.stream = stream;
    play.status = "playing";
    play.at = this.now();
    const seen = this.seen.get(row.pyatv_id);
    if (seen && seen.access !== "open") seen.access = "open";
    if (typeof answer["volume"] === "number") this.volumes.set(play.speakerId, answer["volume"]);
  }

  private async stopStream(play: Play): Promise<void> {
    const stream = play.stream;
    if (stream === null) return;
    // Heard up to here, before the place is moved.
    play.positionMs = this.place(play);
    play.heardMs += Math.max(0, this.now() - play.at);
    play.at = this.now();
    play.stream = null;
    try {
      await this.ask("stream_stop", { stream });
    } catch (error) {
      log.warn("Stopping a speaker failed", { problem: errorMessage(error) });
    }
  }

  /** Nothing sounds any more; what was heard is kept. */
  private halt(play: Play, problem: SpeakerProblem | null, status?: SpeakerStatus): void {
    if (play.status === "playing") {
      play.positionMs = this.place(play);
      play.heardMs += Math.max(0, this.now() - play.at);
    }
    play.stream = null;
    play.at = this.now();
    play.status = status ?? (problem === null ? "paused" : "error");
    play.problem = problem;
    this.save(play);
  }

  /** The track came to its end: the next one, or the end of it all. */
  private async advance(play: Play): Promise<void> {
    const track = play.tracks[play.index];
    play.heardMs += Math.max(0, this.now() - play.at);
    play.positionMs = track?.durationMs ?? this.place(play);
    play.status = "paused";
    this.finishListen(play, true);
    if (play.index + 1 < play.tracks.length) {
      this.moveTo(play, play.index + 1, 0);
      try {
        await this.sound(play);
      } catch (error) {
        log.warn("The next track did not start on a speaker", { problem: errorMessage(error) });
      }
      this.save(play);
      return;
    }
    play.status = "ended";
    play.at = this.now();
    this.save(play, true);
  }

  /** Stops it altogether and forgets it, keeping the viewer's place. */
  private async end(play: Play, problem: SpeakerProblem | null): Promise<void> {
    await this.stopStream(play);
    this.halt(play, problem, play.status === "ended" ? "ended" : undefined);
    this.finishListen(play, false);
    if (this.plays.get(play.speakerId) === play) this.plays.delete(play.speakerId);
  }

  /** A listen of the current track, as the apps judge one (MusicPlay.judge). */
  private finishListen(play: Play, reachedEnd: boolean): void {
    const track = play.tracks[play.index];
    const heard = Math.round(play.heardMs);
    play.heardMs = 0;
    if (!track) return;
    const completed = judge(heard, track.durationMs, reachedEnd);
    const startedAt = play.listenStartedAt;
    play.listenStartedAt = this.now();
    if (completed === null) return;
    try {
      this.options.music.viewers.addPlays(play.profileId, [
        { opId: randomUUID(), trackId: track.id, playedAt: startedAt, playedMs: heard, completed },
      ]);
    } catch (error) {
      log.warn("A listen on a speaker could not be kept", { problem: errorMessage(error) });
    }
  }

  /** Writes the place in a story for its viewer, as the app does while it plays. */
  private save(play: Play, completed = false): void {
    if (play.bookId === null) return;
    const book = this.options.music.reader.books([play.bookId])[0];
    const part = book?.parts[play.index];
    if (!book || !part) return;
    const position = part.startMs + this.place(play);
    const done = completed || book.durationMs - position < 5_000;
    play.savedAt = this.now();
    try {
      this.options.music.progress.put(play.profileId, book.id, {
        opId: randomUUID(),
        baseRevision: null,
        positionMs: done ? book.durationMs : position,
        durationMs: book.durationMs,
        completed: done,
        updatedAt: this.now(),
      });
    } catch (error) {
      log.warn("The place in a story on a speaker could not be kept", {
        problem: errorMessage(error),
      });
    }
  }

  // ---- While it plays ----

  /** Writes a story's place now and then, and stops a child's when its plan says it is over. */
  tick(): void {
    const now = this.now();
    const kids = now - this.kidsAt >= this.timings.kidsEveryMs;
    if (kids) this.kidsAt = now;
    for (const play of [...this.plays.values()]) {
      if (play.status === "playing" && now - play.savedAt >= this.timings.saveEveryMs) {
        this.save(play);
      }
      if (!kids || this.viewer(play.profileId)?.kids !== true) continue;
      const may = this.listen(play.profileId, play.startedBy);
      if (may?.allowed === true) continue;
      void this.run(play.speakerId, async () => {
        if (this.plays.get(play.speakerId) !== play) return;
        log.info("Stopped a child's music on a speaker: its plan does not allow it now", {
          speaker: play.speakerId,
        });
        await this.end(play, "kids_mode");
        this.options.changed();
      }).catch(() => undefined);
    }
  }

  /** Starts the timer that ticks while anything plays. */
  watch(): void {
    if (this.tickTimer) return;
    this.tickTimer = setInterval(() => {
      try {
        this.tick();
      } catch (error) {
        log.error("Speakers could not be looked after", { error: errorMessage(error) });
      }
    }, this.timings.tickMs);
    this.tickTimer.unref();
  }

  /** For the tests that keep it bounded. */
  get held(): { plays: number; speakers: number } {
    return { plays: this.plays.size, speakers: this.seen.size };
  }
}

function trackInfo(track: {
  id: string;
  title: string;
  artistCredit: string;
  albumId: string | null;
  durationMs: number | null;
}): TrackInfo {
  return {
    id: track.id,
    title: track.title,
    artistCredit: track.artistCredit,
    albumId: track.albumId,
    durationMs: track.durationMs,
  };
}

/** Whether a listen counts: as `MusicPlay.judge` in LobbyKit. Null: not heard at all. */
export function judge(
  listenedMs: number,
  durationMs: number | null,
  reachedEnd: boolean,
): boolean | null {
  if (reachedEnd) return true;
  const duration = durationMs ?? 0;
  if (duration > 0 && listenedMs * 2 >= duration) return true;
  if (listenedMs >= 240_000) return true;
  return listenedMs >= Math.min(30_000, Math.max(duration / 2, 1)) ? false : null;
}

function readSpeaker(value: unknown): {
  id: string;
  name: string;
  model: string;
  kind: SpeakerKind;
  access: SpeakerAccess;
  hasPassword: boolean;
} | null {
  if (typeof value !== "object" || value === null) return null;
  const one = value as Record<string, unknown>;
  const { id, name, model, kind, access, hasPassword } = one;
  if (typeof id !== "string" || id === "" || id.length > 200) return null;
  return {
    id,
    name: typeof name === "string" && name.trim() !== "" ? name.trim().slice(0, 100) : "Speaker",
    model: typeof model === "string" ? model.slice(0, 100) : "",
    kind: kind === "homepod" ? "homepod" : "speaker",
    access: access === "password" || access === "home_only" ? access : "open",
    hasPassword: hasPassword === true,
  };
}
