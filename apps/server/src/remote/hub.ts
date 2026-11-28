// SPDX-License-Identifier: MPL-2.0
import { randomUUID } from "node:crypto";
import { AuthError, type Device, type Devices } from "../auth/devices.ts";
import type { Database } from "../db/database.ts";
import { ApiError } from "../http/app.ts";
import { HOUSEHOLD_ACTIVE, OWNER_HOUSEHOLD } from "../households/owner.ts";
import { kidsLimits, type KidsView } from "../kids/limits.ts";
import type { ModeNow } from "../kids/plan.ts";
import { errorMessage, log } from "../log.ts";
import { RateLimiter } from "../outside/limits.ts";
import type {
  Announcement,
  Command,
  CommandRequest,
  CommandResult,
  CommandType,
  PlayCommand,
  Player,
} from "./messages.ts";

export interface RemoteLimits {
  heartbeatMs: number;
  /** A device that says nothing for this long is gone. */
  silentMs: number;
  /** A connection that broke is taken up again within this long, or the device is gone. */
  graceMs: number;
  /** What happened meanwhile is kept this long for a device that comes back. */
  keepMs: number;
  expiryMs: number;
  sessionsPerDevice: number;
  sessions: number;
  bufferedEvents: number;
  bufferedBytes: number;
  /** Waiting to be sent to one device: past this it is too slow and is let go. */
  unsentBytes: number;
  pendingPerTarget: number;
  remembered: number;
}

export const REMOTE_LIMITS: RemoteLimits = {
  heartbeatMs: 5_000,
  silentMs: 12_000,
  graceMs: 5_000,
  keepMs: 60_000,
  expiryMs: 10_000,
  sessionsPerDevice: 4,
  sessions: 64,
  bufferedEvents: 128,
  bufferedBytes: 128 * 1024,
  unsentBytes: 512 * 1024,
  pendingPerTarget: 32,
  remembered: 200,
};

export const REMOTE_RATES = {
  opens: { burst: 20, perMinute: 30 },
  announcements: { burst: 60, perMinute: 240 },
  results: { burst: 80, perMinute: 480 },
  commands: { burst: 30, perMinute: 240 },
  commandsPerTarget: { burst: 60, perMinute: 480 },
} as const;

const TICK_MS = 500;
/** A place that is this far from where others think it is, is told at once. */
const DRIFT_MS = 1_000;

/** What others are told of a device's player. Everything that tells a title apart may be gone. */
export type ShownPlayer =
  ({ redacted: false } & Player) | { redacted: true; status: Player["status"] };

export interface ShownDevice {
  id: string;
  name: string;
  platform: Device["platform"];
  isSelf: boolean;
  isKids: boolean;
  online: boolean;
  foreground: boolean;
  /** Whether a title can be started on it now. */
  canPlay: boolean;
  /** Whether it can be told to pause, jump and so on now. */
  controllable: boolean;
  capabilities: CommandType[];
  player: ShownPlayer | null;
  /**
   * Lobby Server can turn it on and open Lobby on it (`POST /v1/remote/wake`): it is an Apple TV
   * a manager connected, waking is on, and this session is at home and may control others.
   */
  wakeable: boolean;
}

type SentCommand = Command | { type: "yield" };

interface Kept {
  seq: number;
  event: string;
  data: Record<string, unknown>;
  bytes: number;
  /** A later event about the same thing makes this one needless. */
  about: string | null;
  /** Worth nothing after this. */
  expiresAt: number | null;
}

interface Session {
  key: string;
  id: string;
  /** Another one after every start of the server and every session that was forgotten. */
  epoch: string;
  device: Device;
  outside: boolean;
  stream: ReadableStreamDefaultController<Uint8Array> | null;
  droppedAt: number;
  beatAt: number;
  heartbeatAt: number;
  order: number;
  announced: boolean;
  foreground: boolean;
  canPlay: boolean;
  profileId: string | null;
  capabilities: CommandType[];
  player: Player | null;
  /** When it last became the one to send things to. */
  activeAt: number;
  seq: number;
  /** Events up to this one are no longer kept. */
  floor: number;
  kept: Kept[];
  keptBytes: number;
  told: Map<string, ShownDevice>;
  /** The kids mode it was told last, for the child it is used by. */
  kidsTold: string | null;
}

/** When and what of the kids viewers (kids/control.ts); set by the server. */
export interface KidsHooks {
  /** What a child may do now, on this device, coming in this way. */
  state: (profileId: string, deviceId: string, outside: boolean) => ModeNow;
  /** Whether video of this title may play for the child, by what `state` said. */
  allowsVideo: (state: ModeNow, itemId: string) => boolean;
  /** Whether this device is to lock itself to Lobby while the child is in front. */
  lock?: (profileId: string, deviceId: string) => boolean;
}

type Outcome = "done" | "failed" | "expired" | "superseded";
type Settled = (outcome: Outcome, code: string | null, player: Player | null | undefined) => void;

interface Pending {
  id: string;
  type: SentCommand["type"];
  target: Session;
  expiresAt: number;
  handover: boolean;
  settled: Settled;
}

export interface CommandReply {
  id: string;
  expiresAt: number;
  serverTime: number;
}

/** Who asks for something, as far as what they may see goes: a session, or one that was. */
interface Asker {
  device: Device;
  /** The viewer the app said was in front. */
  profileId: string | null;
  /** Whether it came from outside the home; unknown for one that is gone: as at home. */
  outside?: boolean;
}

/**
 * A play for a TV that was woken for it, kept until Lobby is open there (docs/decisions.md, "Wake and Play"). Only the latest
 * per TV counts. Who asked is checked again when it is sent: the phone may have gone by then.
 */
interface HeldPlay {
  /** The sender's id of the command, as for `POST /v1/remote/commands`. */
  id: string;
  tvId: string;
  senderId: string;
  /** The sender's session, to tell how it went while it is there. */
  senderKey: string;
  /** The sender's viewer when it asked. */
  profileId: string | null;
  command: PlayCommand;
  expiresAt: number;
}

/** How waking a TV for a play goes, for the sender's screen. */
export type WakeStep = "profile" | "not_open";

const encoder = new TextEncoder();

const GROUP: Partial<Record<SentCommand["type"], string>> = {
  play: "all",
  stop: "all",
  pause: "transport",
  resume: "transport",
  seek: "place",
  setAudio: "audio",
  setSubtitle: "subtitle",
  setVolume: "volume",
};

/** Where a player is at `now`, as everyone works it out. */
function placeAt(player: Player, now: number): number {
  if (player.status !== "playing") return player.positionMs;
  const moved = player.positionMs + Math.max(0, now - player.at) * player.rate;
  return player.durationMs === null ? moved : Math.min(moved, player.durationMs);
}

function sameShown(a: ShownDevice, b: ShownDevice): boolean {
  const plain = (one: ShownDevice): string =>
    JSON.stringify(one, (key, value: unknown) =>
      key === "positionMs" || key === "at" ? undefined : value,
    );
  if (plain(a) !== plain(b)) return false;
  const { player: before } = a;
  const { player: after } = b;
  if (!before || !after || before.redacted || after.redacted) return true;
  return Math.abs(placeAt(before, after.at) - after.positionMs) <= DRIFT_MS;
}

/**
 * What devices say to each other while Lobby is open on them: who is there, what plays, and do
 * this. All of it is in memory. Nothing is kept of what was played; each device writes its own
 * progress as always.
 */
/** How often what children may do is looked at again on the channel without a change. */
const KIDS_RECHECK_MS = 5_000;

export class RemoteHub {
  private readonly db: Database;
  private readonly devices: Devices;
  private readonly now: () => number;
  private readonly limits: RemoteLimits;
  private readonly onPlayOn: ((from: Device, target: Device, itemId: string) => void) | undefined;
  private readonly sessions = new Map<string, Session>();
  private readonly pending = new Map<string, Pending>();
  /** Commands that were taken on, by sender, so that a repeated one is not done twice. */
  private readonly taken = new Map<string, Map<string, { asked: string; reply: CommandReply }>>();
  /**
   * Per device, the viewer its app last said was in front, kept when its channel closes: who the
   * device is being now, for what is only that viewer's (docs/decisions.md, "Who sees which statistics").
   */
  private readonly fronts = new Map<string, string | null>();
  /** Devices that are part of a handover. */
  private readonly busy = new Set<string>();
  /** Plays that wait for a woken TV, by the TV's device id. */
  private readonly heldPlays = new Map<string, HeldPlay>();
  private readonly rates: Record<keyof typeof REMOTE_RATES, RateLimiter>;
  private timer: NodeJS.Timeout | null = null;
  /** Whether a device can be woken by the server; set once the wake service is there. */
  wakeable: (deviceId: string) => boolean = () => false;
  /** Whether the household lets kids turn a TV on ("Kids can turn on the TV"); set by the server. */
  kidsWake: () => boolean = () => false;
  /** The plans of the kids viewers; without them, nothing of a plan holds (as before plans). */
  kids: KidsHooks | null = null;
  private checkedAt = 0;
  private kidsCheckedAt = 0;
  private stopped = false;

  constructor(options: {
    db: Database;
    devices: Devices;
    now?: () => number;
    limits?: Partial<RemoteLimits>;
    /** For the statistics: a title was sent to another device to play. */
    onPlayOn?: (from: Device, target: Device, itemId: string) => void;
  }) {
    this.onPlayOn = options.onPlayOn;
    this.db = options.db;
    this.devices = options.devices;
    this.now = options.now ?? Date.now;
    this.limits = { ...REMOTE_LIMITS, ...options.limits };
    const limiter = (key: keyof typeof REMOTE_RATES): RateLimiter =>
      new RateLimiter(REMOTE_RATES[key], this.now, 256);
    this.rates = {
      opens: limiter("opens"),
      announcements: limiter("announcements"),
      results: limiter("results"),
      commands: limiter("commands"),
      commandsPerTarget: limiter("commandsPerTarget"),
    };
  }

  /** How much is held, for the tests that keep it bounded. */
  get held(): {
    sessions: number;
    events: number;
    bytes: number;
    pending: number;
    taken: number;
    plays: number;
  } {
    let events = 0;
    let bytes = 0;
    let taken = 0;
    for (const one of this.sessions.values()) {
      events += one.kept.length;
      bytes += one.keptBytes;
    }
    for (const one of this.taken.values()) taken += one.size;
    return {
      sessions: this.sessions.size,
      events,
      bytes,
      pending: this.pending.size,
      taken,
      plays: this.heldPlays.size,
    };
  }

  /** What devices are told the time is. */
  time(): number {
    return this.now();
  }

  stop(): void {
    this.stopped = true;
    this.heldPlays.clear();
    this.fronts.clear();
    for (const one of [...this.sessions.values()]) this.forget(one, false);
  }

  // ---- The channel ----

  /** @param last the id of the last event the device got, or null for a new start */
  open(
    deviceId: string,
    id: string,
    outside: boolean,
    last: string | null,
  ): ReadableStream<Uint8Array> {
    if (this.stopped) throw new ApiError("unavailable", "The server is stopping.");
    this.limit("opens", deviceId);
    const device = this.row(deviceId, outside);
    if (!device) throw new AuthError("unauthorized", "This device is not paired with the server.");
    const now = this.now();
    const key = `${deviceId}/${id}`;
    let session = this.sessions.get(key);
    // What was kept for a device that came in another way, or had other limits, is not for this.
    if (
      session &&
      (session.outside !== outside || session.device.kidsProfileId !== device.kidsProfileId)
    ) {
      this.forget(session);
      session = undefined;
    }
    if (!session) {
      this.makeRoom(deviceId);
      session = {
        key,
        id,
        epoch: randomUUID().slice(0, 8),
        device,
        outside,
        stream: null,
        droppedAt: 0,
        beatAt: now,
        heartbeatAt: now,
        order: -1,
        announced: false,
        foreground: false,
        canPlay: false,
        profileId: null,
        capabilities: [],
        player: null,
        activeAt: 0,
        seq: 0,
        floor: 0,
        kept: [],
        keptBytes: 0,
        told: new Map(),
        kidsTold: null,
      };
      this.sessions.set(key, session);
    }
    const one = session;
    one.device = device;
    const [epoch, after] = (last ?? "").split(".");
    const seen = /^\d{1,15}$/.test(after ?? "") ? Number(after) : -1;
    const resumed = epoch === one.epoch && seen >= one.floor && seen <= one.seq;
    // The same session again: the connection before this one is dead, whoever noticed.
    this.drop(one);
    one.beatAt = now;
    one.heartbeatAt = now;
    let mine: ReadableStreamDefaultController<Uint8Array> | null = null;
    const stream = new ReadableStream<Uint8Array>(
      {
        start: (controller) => {
          mine = controller;
        },
        cancel: () => {
          if (one.stream !== mine) return;
          this.drop(one);
          this.sync();
        },
      },
      new ByteLengthQueuingStrategy({ highWaterMark: this.limits.unsentBytes }),
    );
    one.stream = mine;
    this.write(one, null, "hello", {
      session: id,
      deviceId,
      resumed,
      heartbeatMs: this.limits.heartbeatMs,
      silentMs: this.limits.silentMs,
      // A TV that was woken for a play goes straight to it, not to who is watching.
      pendingPlay: this.heldPlays.has(deviceId),
    });
    if (resumed) {
      for (const kept of one.kept) {
        if (kept.seq > seen && (kept.expiresAt === null || kept.expiresAt > now)) {
          this.write(one, kept.seq, kept.event, kept.data);
        }
      }
    } else {
      one.kept = [];
      one.keptBytes = 0;
      // A device that starts again has also lost what it was asked.
      this.abandon(one, "device_offline");
      one.told = this.shownTo(one);
      one.seq += 1;
      one.floor = one.seq;
      this.write(one, one.seq, "snapshot", {
        devices: [...one.told.values()],
      });
      one.kidsTold = null;
    }
    this.run();
    this.sync();
    return stream;
  }

  announce(
    deviceId: string,
    id: string,
    outside: boolean,
    said: Announcement,
  ): { serverTime: number; epoch: string; seq: number } {
    const one = this.session(deviceId, id, outside);
    this.limit("announcements", deviceId);
    const now = this.now();
    if (!one.stream && now - one.droppedAt >= this.limits.graceMs) {
      throw new ApiError("gone", "Open the live channel again.", { reason: "session" });
    }
    one.beatAt = now;
    // Requests may overtake each other: what is older than what is known says nothing new.
    if (said.order > one.order) {
      const before = `${one.foreground} ${one.canPlay} ${one.player !== null}`;
      one.order = said.order;
      one.announced = true;
      one.foreground = said.foreground;
      one.canPlay = said.canPlay;
      one.profileId =
        said.profileId !== null && this.profile(said.profileId) ? said.profileId : null;
      this.fronts.set(
        deviceId,
        one.profileId !== null && this.profile(one.profileId, one.device.householdId)
          ? one.profileId
          : null,
      );
      one.capabilities = said.capabilities;
      if (said.player !== undefined) one.player = said.player;
      if (before !== `${one.foreground} ${one.canPlay} ${one.player !== null}`) one.activeAt = now;
      this.sync();
    }
    return { serverTime: now, epoch: one.epoch, seq: one.seq };
  }

  /**
   * The viewer this device's app last said was in front, if it is still one of the device's
   * household; null when it said nobody, or has not said since the server started.
   */
  inFront(deviceId: string): string | null {
    const id = this.fronts.get(deviceId) ?? null;
    if (id === null) return null;
    const device = this.devices.find(deviceId);
    return device && this.profile(id, device.householdId) ? id : null;
  }

  /** Looks again who may be here and see what. */
  recheck(): void {
    for (const one of [...this.sessions.values()]) {
      const device = this.row(one.device.id, one.outside);
      if (!device || device.kidsProfileId !== one.device.kidsProfileId) this.forget(one);
      else one.device = device;
    }
    for (const id of this.taken.keys()) {
      if (![...this.sessions.values()].some((one) => one.device.id === id)) this.taken.delete(id);
    }
    for (const id of this.fronts.keys()) {
      if (!this.row(id, false)) this.fronts.delete(id);
    }
    this.sync();
  }

  private run(): void {
    if (this.timer) return;
    this.timer = setInterval(() => {
      this.tick();
    }, TICK_MS);
    this.timer.unref();
  }

  private tick(): void {
    try {
      const now = this.now();
      for (const one of [...this.sessions.values()]) {
        if (one.stream && now - one.beatAt >= this.limits.silentMs) {
          this.drop(one);
          // It had its time already.
          one.droppedAt = now - this.limits.graceMs;
        }
        if (one.stream && now - one.heartbeatAt >= this.limits.heartbeatMs) {
          one.heartbeatAt = now;
          this.write(one, null, "heartbeat", {});
        }
        if (!one.stream && now - one.droppedAt >= this.limits.keepMs) this.forget(one);
        else if (!this.isOnline(one) && one.announced) {
          // It has to say anew what it is doing when it comes back.
          one.announced = false;
          one.player = null;
          one.order = -1;
          this.abandon(one, "device_offline");
        }
      }
      for (const one of [...this.pending.values()]) {
        if (one.expiresAt <= now) this.settle(one, "expired", "expired");
      }
      for (const play of [...this.heldPlays.values()]) {
        if (play.expiresAt > now) continue;
        this.heldPlays.delete(play.tvId);
        log.info("A play for a woken Apple TV was not taken in time", { device: play.tvId });
        this.tellKey(play.senderKey, play.tvId, play.id)("expired", "expired", undefined);
      }
      if (now - this.checkedAt >= 1_000) {
        this.checkedAt = now;
        this.recheck();
      }
      if (this.sessions.size === 0 && this.heldPlays.size === 0 && this.timer) {
        clearInterval(this.timer);
        this.timer = null;
      }
    } catch (error) {
      // Not knowing who may be here is a reason to let nobody stay.
      log.error("The live channel could not check its devices", { error: errorMessage(error) });
      for (const one of [...this.sessions.values()]) this.forget(one, false);
    }
  }

  private makeRoom(deviceId: string): void {
    const own = [...this.sessions.values()].filter((one) => one.device.id === deviceId);
    const gone = (all: Session[]): Session | undefined =>
      all.filter((one) => !one.stream).sort((a, b) => a.droppedAt - b.droppedAt)[0];
    if (own.length >= this.limits.sessionsPerDevice) {
      const oldest = gone(own);
      if (!oldest) {
        throw new AuthError("rate_limited", "Lobby is open too often on this device.", 15);
      }
      this.forget(oldest);
    }
    if (this.sessions.size >= this.limits.sessions) {
      const oldest = gone([...this.sessions.values()]);
      if (!oldest) throw new AuthError("rate_limited", "Too many devices are connected.", 30);
      this.forget(oldest);
    }
  }

  /** The connection is over. The session is kept for a while. */
  private drop(one: Session): void {
    const { stream } = one;
    if (!stream) return;
    one.stream = null;
    one.droppedAt = this.now();
    try {
      stream.close();
    } catch {
      // It was closed by the other end.
    }
  }

  private forget(one: Session, tell = true): void {
    this.drop(one);
    if (this.sessions.get(one.key) !== one) return;
    this.sessions.delete(one.key);
    this.abandon(one, "device_offline");
    if (tell) this.sync();
  }

  private write(
    one: Session,
    seq: number | null,
    event: string,
    data: Record<string, unknown>,
  ): void {
    const { stream } = one;
    if (!stream) return;
    const id = seq === null ? "" : `id: ${one.epoch}.${String(seq)}\n`;
    const now = this.now();
    // Of a command that waited for the connection there is less time left.
    const expiresAt = data["expiresAt"];
    const left = typeof expiresAt === "number" ? { expiresInMs: Math.max(0, expiresAt - now) } : {};
    try {
      stream.enqueue(
        encoder.encode(
          `${id}event: ${event}\ndata: ${JSON.stringify({ ...data, ...left, serverTime: now })}\n\n`,
        ),
      );
      if ((stream.desiredSize ?? 0) >= 0) return;
      stream.error(new Error("This device does not take in what it is sent."));
      one.stream = null;
      one.droppedAt = now;
    } catch {
      one.stream = null;
      one.droppedAt = now;
    }
  }

  /**
   * Tells every manager's channel at home about something of theirs, such as an upload's progress
   * or a file in the Inbox. A later event about the same thing replaces one not yet collected.
   */
  tellManagers(event: string, data: Record<string, unknown>, about: string): void {
    for (const one of this.sessions.values()) {
      if (one.outside || one.device.role !== "manager") continue;
      this.push(one, event, data, about);
    }
  }

  /** Sends an event that a device gets later when its connection is broken just now. */
  private push(
    one: Session,
    event: string,
    data: Record<string, unknown>,
    about: string | null = null,
    expiresAt: number | null = null,
  ): void {
    one.seq += 1;
    const bytes = JSON.stringify(data).length;
    if (about !== null) {
      one.kept = one.kept.filter((kept) => {
        if (kept.about === about) one.keptBytes -= kept.bytes;
        return kept.about !== about;
      });
    }
    one.kept.push({ seq: one.seq, event, data, bytes, about, expiresAt });
    one.keptBytes += bytes;
    while (
      one.kept.length > this.limits.bufferedEvents ||
      one.keptBytes > this.limits.bufferedBytes
    ) {
      const oldest = one.kept.shift();
      if (!oldest) break;
      one.keptBytes -= oldest.bytes;
      one.floor = oldest.seq;
    }
    this.write(one, one.seq, event, data);
  }

  // ---- Who sees what ----

  /** The device, when it may be here: not removed, and its household not paused. */
  private row(deviceId: string, outside: boolean): Device | null {
    const device = this.devices.find(deviceId);
    if (!device || device.revokedAt !== null) return null;
    if (
      !this.db.get(`select 1 as x from device where id = ? and ${HOUSEHOLD_ACTIVE}`, [deviceId])
    ) {
      return null;
    }
    return outside && !device.allowOutside ? null : device;
  }

  /** @param householdId a viewer of another household is none */
  private profile(id: string, householdId?: string): { kids: boolean } | null {
    const row = this.db.get<{ kids: number }>(
      `select kids_json is not null as kids from profile where id = ? and deleted_at is null
         and (? is null or household_id = ?)`,
      [id, householdId ?? null, householdId ?? null],
    );
    return row ? { kids: row.kids === 1 } : null;
  }

  /** What is meant for who uses this session; null without limits. */
  private view(one: Asker): KidsView | null {
    const limits = kidsLimits(this.db);
    if (one.device.kidsProfileId !== null) return limits.view(one.device.kidsProfileId);
    if (one.profileId !== null && this.profile(one.profileId)?.kids !== false) {
      return limits.view(one.profileId);
    }
    // A guest household that sees a part of the library sees only that of what others play.
    return limits.deviceView(one.device);
  }

  /**
   * The kids viewer who uses this session, or null for a grown-up: the device's own child, or the
   * kids viewer the app says is in front. Cheaper than `view`, which works out the titles.
   */
  private kidOf(one: Asker): string | null {
    if (one.device.kidsProfileId !== null) return one.device.kidsProfileId;
    if (one.profileId === null) return null;
    return this.profile(one.profileId)?.kids === true ? one.profileId : null;
  }

  /**
   * The kids viewer of a session of this device, for the routes beside the channel (waking).
   * Throws `410 session` for a session that is not there: what it is for is not known then.
   */
  kidUsing(deviceId: string, id: string, outside: boolean): string | null {
    return this.kidOf(this.session(deviceId, id, outside));
  }

  private isOnline(one: Session): boolean {
    return (
      one.announced &&
      this.now() - one.beatAt < this.limits.silentMs &&
      (one.stream !== null || this.now() - one.droppedAt < this.limits.graceMs)
    );
  }

  /** The session of a device that plays, or else the one it would play on. */
  private main(deviceId: string): Session | null {
    const score = (one: Session): number =>
      (one.player ? 4 : 0) + (one.foreground && one.canPlay ? 2 : 0) + (one.stream ? 1 : 0);
    const all = [...this.sessions.values()]
      .filter((one) => one.device.id === deviceId && this.isOnline(one))
      .sort((a, b) => score(b) - score(a) || b.activeAt - a.activeAt);
    return all[0] ?? null;
  }

  /**
   * Whether this session sees and controls others at all. A child's too, the bound device's as
   * well as the kids screens': it plays on a TV, and controls only what it plays there.
   */
  private mayLook(one: Session): boolean {
    return one.announced && one.device.allowRemote && (!one.outside || one.device.remoteOutside);
  }

  /** Whether a TV can be woken from this session, as far as who uses it goes. */
  private mayWake(one: Session, kid: string | null): boolean {
    return !one.outside && this.mayLook(one) && (kid === null || this.kidsWake());
  }

  /**
   * Whether another device is there for this session. A child sees only where it can play: a
   * target that is open (or that it may wake), and not one that belongs to another child.
   */
  private showsTo(one: Session, device: Device, kid: string | null): boolean {
    if (!this.isShown(device)) return false;
    if (kid === null) return true;
    if (device.kidsProfileId !== null && device.kidsProfileId !== kid) return false;
    return this.main(device.id) !== null || (this.mayWake(one, kid) && this.wakeable(device.id));
  }

  private isShown(device: Device): boolean {
    if (device.revokedAt !== null || !device.allowRemote || !device.isTarget) return false;
    const main = this.main(device.id);
    return !main?.outside || device.remoteOutside;
  }

  private shownPlayer(
    player: Player | null,
    view: KidsView | null,
    own = false,
  ): ShownPlayer | null {
    if (!player) return null;
    const see = (id: string): boolean =>
      view
        ? view.items.has(id)
        : this.db.get("select 1 as x from item where id = ?", [id]) !== undefined;
    // A child sees, and so controls, only what plays as that child: not what a grown-up watches,
    // even a title the child may see.
    const others = !own && view !== null && player.profileId !== view.profileId;
    if (player.itemId === null || others || !see(player.itemId)) {
      return { redacted: true, status: player.status };
    }
    return {
      redacted: false,
      ...player,
      assetId:
        player.assetId !== null && view && !view.assets.has(player.assetId) ? null : player.assetId,
      nextItemId: player.nextItemId !== null && see(player.nextItemId) ? player.nextItemId : null,
      queue: player.queue.filter(see),
      upNext: player.upNext && {
        ...player.upNext,
        itemId:
          player.upNext.itemId !== null && see(player.upNext.itemId) ? player.upNext.itemId : null,
        suggestions: player.upNext.suggestions.filter(see),
      },
    };
  }

  private shownDevice(
    to: Session,
    device: Device,
    view: KidsView | null,
    kid: string | null,
  ): ShownDevice {
    const main = this.main(device.id);
    const isSelf = device.id === to.device.id;
    const player = this.shownPlayer(main?.player ?? null, view, isSelf);
    const reachable = main !== null && main.stream !== null;
    return {
      id: device.id,
      name: device.name,
      platform: device.platform,
      isSelf,
      isKids: device.kidsProfileId !== null,
      online: main !== null,
      foreground: main?.foreground ?? false,
      canPlay: reachable && main.foreground && main.canPlay && main.capabilities.includes("play"),
      controllable: reachable && player !== null && (isSelf || view === null || !player.redacted),
      capabilities: main?.capabilities ?? [],
      player,
      // The Apple TVs that can be woken are the owner's, on the owner's network.
      wakeable:
        !isSelf &&
        to.device.householdId === OWNER_HOUSEHOLD &&
        this.mayWake(to, kid) &&
        this.wakeable(device.id),
    };
  }

  private shownTo(one: Session, rows: Device[] = this.devices.list()): Map<string, ShownDevice> {
    const view = this.view(one);
    const kid = this.kidOf(one);
    const look = this.mayLook(one);
    const shown = new Map<string, ShownDevice>();
    for (const device of rows) {
      // Only the devices of the same household: another household's are not there.
      if (device.householdId !== one.device.householdId) continue;
      if (device.id !== one.device.id && !(look && this.showsTo(one, device, kid))) continue;
      shown.set(device.id, this.shownDevice(one, device, view, kid));
    }
    return shown;
  }

  /**
   * The child a session plays for: its own child, the one its kids screens show, or the one
   * whose film it plays (a TV playing as the child).
   */
  private childOf(one: Session): string | null {
    const kid = this.kidOf(one);
    if (kid !== null) return kid;
    const playing = one.player?.profileId ?? null;
    return playing !== null && this.profile(playing)?.kids === true ? playing : null;
  }

  /**
   * Tells each session used by a child what that child may do now, when it is different: at a
   * switch the app ends a film itself, and a TV playing as the child does too.
   */
  private syncKids(force = false): void {
    const { kids } = this;
    if (!kids) return;
    // Worked out again when something changed, and otherwise every few seconds: the clock
    // moves on. A session that was told nothing yet is told at once.
    const now = this.now();
    const all = force || now - this.kidsCheckedAt >= KIDS_RECHECK_MS;
    if (all) this.kidsCheckedAt = now;
    for (const one of this.sessions.values()) {
      const child = this.childOf(one);
      if (child === null) {
        one.kidsTold = null;
        continue;
      }
      if (!all && one.kidsTold !== null) continue;
      const now = kids.state(child, one.device.id, one.outside);
      const lock = kids.lock?.(child, one.device.id) ?? false;
      const key = JSON.stringify([
        lock,
        child,
        now.mode,
        now.browse,
        now.video,
        now.titles,
        now.listening,
        now.waiting,
        now.until,
      ]);
      if (one.kidsTold === key) continue;
      one.kidsTold = key;
      this.push(one, "kidsMode", { profileId: child, now, lock }, "kidsMode");
    }
  }

  /** Something of a child's plan changed: whoever plays for it is told. */
  kidsChanged(): void {
    this.syncKids(true);
  }

  /** Tells these devices' sessions something, such as a child's question to its grown-ups. */
  tellDevices(
    deviceIds: readonly string[],
    event: string,
    data: Record<string, unknown>,
    about: string,
  ): void {
    const ids = new Set(deviceIds);
    for (const one of this.sessions.values()) {
      if (ids.has(one.device.id)) this.push(one, event, data, about);
    }
  }

  /**
   * Whether a child may start video of this title, on this target: by the plan on the target,
   * and when the child itself sends it, on its own device too.
   */
  private kidsAllow(
    sender: Asker,
    target: { device: Device; outside?: boolean },
    profileId: string,
    itemId: string,
  ): boolean {
    const { kids } = this;
    if (!kids) return true;
    const states = [kids.state(profileId, target.device.id, target.outside ?? false)];
    if (this.kidOf(sender) === profileId) {
      states.push(kids.state(profileId, sender.device.id, sender.outside ?? false));
    }
    return states.every((state) => kids.allowsVideo(state, itemId));
  }

  /** Whether a child may turn on a TV now: only where it may watch. */
  kidMayWatch(profileId: string, deviceId: string, outside: boolean): boolean {
    const state = this.kids?.state(profileId, deviceId, outside);
    return state === undefined || state.video === "all";
  }

  /** Tells every session what is different for it. */
  private sync(): void {
    this.deliverHeld();
    if (this.sessions.size === 0) return;
    this.syncKids();
    const rows = this.devices.list().filter((one) => one.revokedAt === null);
    for (const one of this.sessions.values()) {
      const shown = this.shownTo(one, rows);
      for (const id of [...one.told.keys()]) {
        if (shown.has(id)) continue;
        one.told.delete(id);
        this.push(one, "gone", { deviceId: id }, `device ${id}`);
      }
      for (const device of shown.values()) {
        const before = one.told.get(device.id);
        if (before && sameShown(before, device)) continue;
        one.told.set(device.id, device);
        this.push(one, "device", { device }, `device ${device.id}`);
      }
    }
  }

  // ---- Commands ----

  private limit(rate: keyof typeof REMOTE_RATES, key: string): void {
    const wait = this.rates[rate].take(key);
    if (wait > 0) {
      throw new AuthError("rate_limited", "That is too much at once. Try again in a moment.", wait);
    }
  }

  private session(deviceId: string, id: string, outside: boolean): Session {
    const one = this.sessions.get(`${deviceId}/${id}`);
    if (!one || one.outside !== outside) {
      throw new ApiError("gone", "Open the live channel again.", { reason: "session" });
    }
    return one;
  }

  /** The session a command for this device goes to. A device that is not shown is not there. */
  private target(sender: Session, deviceId: string): Session {
    const device = this.devices.find(deviceId);
    const own = deviceId === sender.device.id;
    if (
      !device ||
      device.householdId !== sender.device.householdId ||
      (!own && !this.showsTo(sender, device, this.kidOf(sender)))
    ) {
      throw new ApiError("not_found", "There is no such device.");
    }
    const main = this.main(deviceId);
    if (!main?.stream) {
      throw new ApiError("unavailable", `Open Lobby on ${device.name} first.`, {
        reason: "device_offline",
      });
    }
    return main;
  }

  /** Throws when this may not be played there, by this viewer. */
  private checkPlay(target: { device: Device }, command: PlayCommand, sender: Asker): void {
    const refuse = (): ApiError =>
      new ApiError("forbidden", "This title cannot be played there.", {
        reason: "title_not_allowed",
      });
    const profile = this.profile(command.profileId, sender.device.householdId);
    const item = this.db.get(
      "select 1 as x from item where id = ? and kind not in ('show', 'season')",
      [command.itemId],
    );
    const bound = target.device.kidsProfileId;
    if (bound !== null && bound !== command.profileId) throw refuse();
    if (!profile || !item) throw new ApiError("not_found", "There is no such viewer or title.");
    const senderView = this.view(sender);
    // A child's viewer on a shared device does not start things in somebody else's name.
    if (senderView?.kind === "kids" && senderView.profileId !== command.profileId) throw refuse();
    const views = [senderView];
    if (bound !== null || profile.kids) views.push(kidsLimits(this.db).view(command.profileId));
    // When and what: a child plays on a TV only where its plan lets it watch this.
    if (
      (bound !== null || profile.kids) &&
      !this.kidsAllow(sender, target, command.profileId, command.itemId)
    ) {
      throw new ApiError("forbidden", "This cannot be played now.", { reason: "kids_mode" });
    }
    for (const view of views) {
      if (!view) continue;
      if (!view.items.has(command.itemId)) throw refuse();
      if (command.assetId !== null && !view.assets.has(command.assetId)) throw refuse();
      command.queue = command.queue.filter((id) => view.items.has(id));
    }
    if (
      command.assetId !== null &&
      !this.db.get("select 1 as x from item_asset where item_id = ? and asset_id = ?", [
        command.itemId,
        command.assetId,
      ])
    ) {
      throw new ApiError("not_found", "That file is not of this title.");
    }
  }

  private checkCanPlay(target: Session): void {
    if (!target.stream) {
      throw new ApiError("unavailable", `Open Lobby on ${target.device.name} first.`, {
        reason: "device_offline",
      });
    }
    if (target.foreground && target.canPlay && target.capabilities.includes("play")) return;
    throw new ApiError("unavailable", `${target.device.name} cannot play anything now.`, {
      reason: "cannot_play",
    });
  }

  private checkNext(target: Session, next = target.player?.nextItemId ?? null): void {
    const viewer = target.device.kidsProfileId ?? target.player?.profileId ?? null;
    if (next === null || viewer === null) return;
    const limited = target.device.kidsProfileId !== null || this.profile(viewer)?.kids !== false;
    if (limited && !kidsLimits(this.db).view(viewer).items.has(next)) {
      throw new ApiError("forbidden", "The next title cannot be played there.", {
        reason: "title_not_allowed",
      });
    }
  }

  command(deviceId: string, outside: boolean, request: CommandRequest): CommandReply {
    const sender = this.session(deviceId, request.session, outside);
    const asked = JSON.stringify([request.deviceId, request.command]);
    const mine =
      this.taken.get(deviceId) ?? new Map<string, { asked: string; reply: CommandReply }>();
    const before = mine.get(request.id);
    if (before) {
      if (before.asked === asked) return before.reply;
      throw new ApiError("conflict", "This command id was used before.", { reason: "used_id" });
    }
    this.limit("commands", deviceId);
    if (!this.mayLook(sender)) {
      throw sender.announced
        ? new ApiError("forbidden", "This device may not control other devices.", {
            reason: "control_off",
          })
        : new ApiError("gone", "Say first what this device is doing.", { reason: "session" });
    }
    const target = this.target(sender, request.deviceId);
    const { command } = request;
    const others =
      command.type === "handover" ? [request.deviceId, command.toDeviceId] : [request.deviceId];
    if (others.some((id) => this.busy.has(id))) {
      throw new ApiError("conflict", "Playback is moving between devices.", { reason: "busy" });
    }
    const reply = this.remember(
      mine,
      deviceId,
      request.id,
      asked,
      command.type === "handover"
        ? this.handover(sender, target, command.toDeviceId, request.id)
        : this.start(sender, target, command, request.id),
    );
    return reply;
  }

  private remember(
    mine: Map<string, { asked: string; reply: CommandReply }>,
    deviceId: string,
    id: string,
    asked: string,
    reply: CommandReply,
  ): CommandReply {
    mine.set(id, { asked, reply });
    if (mine.size > this.limits.remembered) {
      const oldest = mine.keys().next().value;
      if (oldest !== undefined) mine.delete(oldest);
    }
    this.taken.set(deviceId, mine);
    return reply;
  }

  private checkPlaying(sender: Asker, target: Session): Player {
    const shown = this.shownPlayer(
      target.player,
      this.view(sender),
      sender.device.id === target.device.id,
    );
    if (!shown || !target.player) {
      throw new ApiError("conflict", `Nothing plays on ${target.device.name}.`, {
        reason: "nothing_playing",
      });
    }
    // Somebody else's film is not a child's to stop.
    if (shown.redacted && this.view(sender) && sender.device.id !== target.device.id) {
      throw new ApiError("forbidden", "This cannot be controlled from here.", {
        reason: "title_not_allowed",
      });
    }
    return target.player;
  }

  private start(sender: Session, target: Session, command: Command, id: string): CommandReply {
    if (command.type === "play") {
      this.checkPlay(target, command, sender);
      this.checkCanPlay(target);
      if (target.player) this.checkPlaying(sender, target);
    } else {
      this.checkPlaying(sender, target);
      if (!target.capabilities.includes(command.type)) {
        throw new ApiError("conflict", "That device cannot do this.", { reason: "unsupported" });
      }
      if (command.type === "next") this.checkNext(target);
      // Play Now starts what Up Next shows: a title the viewer must be allowed, as for next.
      if (command.type === "upNext" && command.action === "playNow") {
        this.checkNext(target, target.player?.upNext?.itemId ?? null);
      }
    }
    this.checkRoom(target);
    const tell = this.tellSender(sender, target.device.id, id);
    const expiresAt = this.send(target, command, id, sender.device, null, tell);
    if (command.type === "play" && target.device.id !== sender.device.id) {
      this.onPlayOn?.(sender.device, target.device, command.itemId);
    }
    return { id, expiresAt, serverTime: this.now() };
  }

  private checkRoom(target: Session): void {
    this.limit("commandsPerTarget", target.device.id);
    let waiting = 0;
    for (const one of this.pending.values()) if (one.target === target) waiting += 1;
    if (waiting >= this.limits.pendingPerTarget) {
      throw new AuthError("rate_limited", "That device has not done what it was asked yet.", 5);
    }
  }

  /** Tells the session with this key, while there is one: it may have gone and come back. */
  private tellKey(key: string, deviceId: string, commandId: string): Settled {
    return (status, code) => {
      const sender = this.sessions.get(key);
      if (sender) this.push(sender, "result", { commandId, deviceId, status, code });
    };
  }

  private tellSender(sender: Session, deviceId: string, commandId: string): Settled {
    return (status, code) => {
      if (this.sessions.get(sender.key) !== sender) return;
      this.push(sender, "result", { commandId, deviceId, status, code });
    };
  }

  /** @returns when it is too late to do it */
  private send(
    target: Session,
    command: SentCommand,
    id: string,
    from: Device,
    handoverId: string | null,
    settled: Settled,
  ): number {
    const now = this.now();
    const expiresAt = now + this.limits.expiryMs;
    const group = GROUP[command.type];
    for (const one of [...this.pending.values()]) {
      // Who spoke last decides.
      if (one.target !== target || one.handover || group === undefined) continue;
      if (group === "all" || GROUP[one.type] === group) this.settle(one, "superseded", null);
    }
    // The sender's id can be anyone's: what is waited for has a name of the server's own.
    const commandId = randomUUID();
    this.pending.set(commandId, {
      id: commandId,
      type: command.type,
      target,
      expiresAt,
      handover: handoverId !== null,
      settled,
    });
    this.push(
      target,
      "command",
      {
        commandId,
        requestId: id,
        handoverId,
        from: { deviceId: from.id, name: from.name },
        command,
        expiresAt,
      },
      null,
      expiresAt,
    );
    return expiresAt;
  }

  private settle(
    one: Pending,
    outcome: Outcome,
    code: string | null,
    player?: Player | null,
  ): void {
    if (!this.pending.delete(one.id)) return;
    // Nobody waits for it any more, so a device that comes back must not do it.
    if (outcome !== "done") {
      one.target.kept = one.target.kept.filter((kept) => {
        const mine = kept.data["commandId"] === one.id && kept.event === "command";
        if (mine) one.target.keptBytes -= kept.bytes;
        return !mine;
      });
    }
    one.settled(outcome, code, player);
  }

  /** What was asked of a session that is no longer there. */
  private abandon(target: Session, code: string): void {
    for (const one of [...this.pending.values()]) {
      if (one.target === target) this.settle(one, "failed", code);
    }
  }

  result(deviceId: string, id: string, outside: boolean, said: CommandResult): void {
    const one = this.session(deviceId, id, outside);
    this.limit("results", deviceId);
    const pending = this.pending.get(said.commandId);
    // Said before, or too late: then it was settled already.
    if (!pending || pending.target !== one) return;
    one.beatAt = this.now();
    if (said.player !== undefined) one.player = said.player;
    const late = pending.expiresAt <= this.now();
    this.settle(pending, late ? "expired" : said.status, late ? "expired" : said.code, said.player);
    this.sync();
  }

  // ---- Plays that wait for a woken TV (docs/decisions.md, "Wake and Play") ----

  /** Whether Lobby is open in front on this device and can be told to play. */
  isOpen(deviceId: string): boolean {
    const main = this.main(deviceId);
    return (
      main !== null &&
      main.stream !== null &&
      main.foreground &&
      main.canPlay &&
      main.capabilities.includes("play")
    );
  }

  /**
   * Throws when this sender may not have this played on the TV, as for a play sent at once:
   * before the TV is woken, so that it is not woken for nothing.
   */
  checkHeldPlay(senderId: string, sessionId: string, tvId: string, command: PlayCommand): void {
    const sender = this.session(senderId, sessionId, false);
    const tv = this.devices.find(tvId);
    if (!tv || tv.revokedAt !== null || tv.householdId !== sender.device.householdId) {
      throw new ApiError("not_found", "There is no such device.");
    }
    this.checkPlay({ device: tv }, { ...command, queue: [...command.queue] }, sender);
  }

  /**
   * Keeps the play for the TV until its Lobby is open there, at most `ms`; a later one for the
   * same TV replaces it. Sent at once when it is open already.
   */
  holdPlay(
    senderId: string,
    sessionId: string,
    tvId: string,
    request: { id: string; command: PlayCommand },
    ms: number,
  ): { id: string; expiresAt: number } {
    this.checkHeldPlay(senderId, sessionId, tvId, request.command);
    const sender = this.session(senderId, sessionId, false);
    const before = this.heldPlays.get(tvId);
    if (before && !(before.senderKey === sender.key && before.id === request.id)) {
      this.heldPlays.delete(tvId);
      this.tellKey(before.senderKey, tvId, before.id)("superseded", null, undefined);
    }
    const expiresAt = this.now() + ms;
    this.heldPlays.set(tvId, {
      id: request.id,
      tvId,
      senderId,
      senderKey: sender.key,
      profileId: sender.profileId,
      command: request.command,
      expiresAt,
    });
    this.run();
    this.sync();
    return { id: request.id, expiresAt };
  }

  /** The sender takes its play back. False when none of its waits for that TV any more. */
  cancelHeldPlay(senderId: string, tvId: string, id: string): boolean {
    const play = this.heldPlays.get(tvId);
    if (!play || play.senderId !== senderId || play.id !== id) return false;
    this.heldPlays.delete(tvId);
    return true;
  }

  /** Tells the sender's session how waking the TV goes. */
  tellWake(
    senderId: string,
    sessionId: string,
    tvId: string,
    commandId: string | null,
    step: WakeStep,
    reason: string | null,
  ): void {
    const sender = this.sessions.get(`${senderId}/${sessionId}`);
    if (!sender) return;
    this.push(sender, "wake", { deviceId: tvId, commandId, step, reason });
  }

  /** Sends the plays whose TV is open now, once who asked is checked again. */
  private deliverHeld(): void {
    for (const play of [...this.heldPlays.values()]) {
      if (!this.isOpen(play.tvId) || this.busy.has(play.tvId)) continue;
      const target = this.main(play.tvId);
      if (!target) continue;
      this.heldPlays.delete(play.tvId);
      const tell = this.tellKey(play.senderKey, play.tvId, play.id);
      try {
        const askers = this.heldAskers(play, target.device);
        const command: PlayCommand = { ...play.command, queue: [...play.command.queue] };
        for (const asker of askers) {
          this.checkPlay(target, command, asker);
          if (target.player) this.checkPlaying(asker, target);
        }
        const [first] = askers;
        if (!first) throw new ApiError("not_found", "There is no such device.");
        this.send(target, command, play.id, first.device, null, tell);
        log.info("Sent a play to a woken Apple TV", { device: play.tvId, by: play.senderId });
      } catch (error) {
        log.info("A play for a woken Apple TV was not allowed any more", {
          device: play.tvId,
          reason: this.reason(error),
        });
        tell("failed", this.reason(error), undefined);
      }
    }
  }

  /**
   * Who asked, as they are now. The viewer the sender had when it asked, and the one its session
   * has now when that is another: both must be allowed. Throws when the sender may no longer.
   */
  private heldAskers(play: HeldPlay, tv: Device): Asker[] {
    const device = this.row(play.senderId, false);
    if (!device?.allowRemote) {
      throw new ApiError("forbidden", "This device may not control other devices.", {
        reason: "control_off",
      });
    }
    if (!tv.isTarget || !tv.allowRemote || tv.householdId !== device.householdId) {
      throw new ApiError("not_found", "There is no such device.");
    }
    const live = this.sessions.get(play.senderKey);
    const askers: Asker[] = [
      { device, profileId: play.profileId, outside: live?.outside ?? false },
    ];
    if (live && live.profileId !== play.profileId) {
      askers.push({ device, profileId: live.profileId, outside: live.outside });
    }
    // A child's wake needs the household's yes, also when it is sent.
    if (askers.some((one) => this.kidOf(one) !== null) && !this.kidsWake()) {
      throw new ApiError("not_found", "That device cannot be woken.", { reason: "not_wakeable" });
    }
    return askers;
  }

  /**
   * Moves what plays from one device to another. The first stops and says where it was; only
   * when the second plays is it over for the first, and when it does not the first goes on.
   */
  private handover(sender: Session, main: Session, toDeviceId: string, id: string): CommandReply {
    const fromId = main.device.id;
    if (fromId === toDeviceId) {
      throw new ApiError("invalid_request", `"toDeviceId" must be another device.`);
    }
    const own = (session: Session): Session =>
      session.device.id === sender.device.id && sender.stream ? sender : session;
    const from = main;
    const to = own(this.target(sender, toDeviceId));
    const player = this.checkPlaying(sender, from);
    const command = (now: Player): PlayCommand => ({
      type: "play",
      itemId: now.itemId ?? "",
      assetId: now.assetId,
      profileId: now.profileId ?? "",
      startMs: Math.round(placeAt(now, this.now())),
      paused: now.status === "paused",
      rate: Math.min(4, Math.max(0.25, now.rate)),
      audioTrackId: now.audioTrackId,
      subtitleTrackId: now.subtitleTrackId ?? "off",
      queue: now.queue,
    });
    this.checkPlay(to, command(player), sender);
    this.checkCanPlay(to);
    this.checkRoom(from);
    this.checkRoom(to);
    const went = player.status !== "paused";
    this.busy.add(fromId).add(toDeviceId);
    const tell = this.tellSender(sender, toDeviceId, id);
    const end = (outcome: Outcome, code: string | null): void => {
      this.busy.delete(fromId);
      this.busy.delete(toDeviceId);
      tell(outcome, code, undefined);
    };
    const also = (target: Session, type: "stop" | "resume"): void => {
      if (this.sessions.get(target.key) !== target) return;
      this.send(target, { type }, id, sender.device, id, () => undefined);
    };
    const giveBack = (): void => {
      if (went) also(from, "resume");
    };
    this.send(from, { type: "yield" }, id, sender.device, id, (outcome, code, said) => {
      if (outcome !== "done") {
        // It may have stopped without being heard.
        if (outcome === "expired") giveBack();
        end(outcome, code);
        return;
      }
      // Where it was, held still: the time until the other plays is not part of the film.
      const last = said ?? from.player ?? player;
      const moved = command({ ...last, status: "paused" });
      moved.paused = !went;
      try {
        this.checkPlay(to, moved, sender);
        this.checkCanPlay(to);
      } catch (error) {
        giveBack();
        end("failed", this.reason(error));
        return;
      }
      this.send(to, moved, id, sender.device, id, (second, why) => {
        if (second === "done") {
          also(from, "stop");
        } else {
          if (second === "expired") also(to, "stop");
          giveBack();
        }
        end(second, why);
      });
    });
    return { id, expiresAt: this.now() + 2 * this.limits.expiryMs, serverTime: this.now() };
  }

  private reason(error: unknown): string {
    const known = error instanceof ApiError ? error.extra["reason"] : null;
    return typeof known === "string" ? known : "not_found";
  }
}
