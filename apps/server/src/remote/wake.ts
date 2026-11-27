// SPDX-License-Identifier: MPL-2.0
import { randomBytes } from "node:crypto";
import { AuthError, type Device, type Devices } from "../auth/devices.ts";
import type { WakeConfig } from "../config.ts";
import type { Database } from "../db/database.ts";
import { ApiError } from "../http/app.ts";
import { errorMessage, log } from "../log.ts";
import { RateLimiter } from "../outside/limits.ts";
import { WakeHelper, WakeHelperError } from "./wake-helper.ts";

/** How often a TV can be woken. A person tries again once or twice; more is something wrong. */
export const WAKE_RATES = {
  perSender: { burst: 4, perMinute: 6 },
  perTelevision: { burst: 3, perMinute: 4 },
  /** Scans and pairings, by the manager's device. */
  manage: { burst: 10, perMinute: 10 },
} as const;

const PAIRING_MS = 60_000;
const WAKE_TIMEOUT_MS = 40_000;
const SCAN_TIMEOUT_MS = 20_000;

/** How long to wait for Lobby on a woken TV, before pressing select and after. */
export interface WakeTimings {
  /** Lobby did not come up in this long: tvOS probably asks who is watching. */
  pickAfterMs: number;
  /** After that (or without picking), how long Lobby may still take. */
  openMs: number;
  /** How often to look. */
  lookMs: number;
  /** How long a play waits for the TV; null: `remote.wake.holdPlaySeconds`. */
  holdPlayMs: number | null;
}

export const WAKE_TIMINGS: WakeTimings = {
  pickAfterMs: 6_000,
  openMs: 20_000,
  lookMs: 250,
  holdPlayMs: null,
};

/** What the helper said of a wake. */
export interface Woke {
  /** Lobby is in front, as pyatv tells it; null when pyatv cannot tell (Companion alone). */
  front: boolean | null;
  /** Select was pressed once already, by the helper. */
  selected: boolean;
}

/** How a wake goes after the TV is on: "profile" when select is pressed, "not_open" when Lobby never came. */
export type WakeProgress = (step: "profile" | "not_open", reason: string | null) => void;

/** An Apple TV as a manager sees it. */
export interface Television {
  /** pyatv's identifier for it. */
  id: string;
  name: string;
  model: string;
  /** Lobby Server holds credentials for it. */
  paired: boolean;
  /** It answered the last look on the network. */
  found: boolean;
  /** The Lobby device it is, as a manager confirmed. */
  deviceId: string | null;
  /** The Lobby device it probably is, by its name, until a manager confirms one. */
  suggestedDeviceId: string | null;
}

export interface WakeStatus {
  /** `remote.wake` is in lobby.config.json. */
  configured: boolean;
  enabled: boolean;
  /** The setting `remote.wake.kids`: kids mode may wake a TV too. */
  kids: boolean;
  /** The helper runs. */
  running: boolean;
  problem: string | null;
  pyatv: string | null;
  /** When the network was last looked at, in ms; null before the first look. */
  scannedAt: number | null;
  televisions: Television[];
  /** A pairing that waits for the code the TV shows. */
  pairing: { id: string; televisionId: string; expiresAt: number } | null;
}

interface Row {
  id: string;
  name: string;
  model: string;
  device_id: string | null;
  paired_at: number;
}

interface Seen {
  id: string;
  name: string;
  model: string;
  paired: boolean;
}

interface Pairing {
  id: string;
  helperToken: string;
  televisionId: string;
  by: string;
  expiresAt: number;
}

export interface WakeOptions {
  db: Database;
  devices: Devices;
  /** The config as it is now: `enabled` changes while the server runs. */
  config: () => WakeConfig | null;
  /** Something that devices are shown changed: whether a TV can be woken. */
  changed?: () => void;
  now?: () => number;
  /** Makes the helper; a test passes one of its own. */
  helper?: (config: WakeConfig) => WakeHelper;
  timings?: Partial<WakeTimings>;
}

/**
 * Waking an Apple TV and opening Lobby on it, through pyatv's Companion protocol (docs/decisions.md, "Waking the Apple TV"): which
 * TVs Lobby Server is connected to, the Lobby device each one is, the pairing with the code the
 * TV shows, and the waking itself, a few times a minute at most.
 */
export class WakeService {
  private readonly options: WakeOptions;
  private readonly now: () => number;
  private helper: WakeHelper | null = null;
  private seen = new Map<string, Seen>();
  private scannedAt: number | null = null;
  private pairing: Pairing | null = null;
  /**
   * Wakes under way, by TV: from the request until Lobby came up or was waited for long enough,
   * so that a TV is pressed select on at most once a wake.
   */
  private readonly waking = new Map<string, { woke: Promise<Woke>; told: Set<WakeProgress> }>();
  private readonly rates: Record<keyof typeof WAKE_RATES, RateLimiter>;
  private readonly timings: WakeTimings;
  private stopped = false;
  /** Whether Lobby is open in front on that device; set by the server, from the live channel. */
  isOpen: (deviceId: string) => boolean = () => false;

  constructor(options: WakeOptions) {
    this.options = options;
    this.timings = { ...WAKE_TIMINGS, ...options.timings };
    this.now = options.now ?? Date.now;
    this.rates = {
      perSender: new RateLimiter(WAKE_RATES.perSender, this.now, 256),
      perTelevision: new RateLimiter(WAKE_RATES.perTelevision, this.now, 64),
      manage: new RateLimiter(WAKE_RATES.manage, this.now, 64),
    };
  }

  start(): void {
    const config = this.options.config();
    if (!config || this.helper) return;
    const make =
      this.options.helper ??
      ((one: WakeConfig) =>
        new WakeHelper({
          python: `${one.pyatv.replace(/\/+$/, "")}/python3`,
          args: one.storage === null ? [] : ["--storage", one.storage],
        }));
    this.helper = make(config);
    // Whether TVs are wakeable changes when it comes up or goes down.
    this.helper.onChange = () => this.options.changed?.();
    this.helper.start();
  }

  async stop(): Promise<void> {
    this.stopped = true;
    const helper = this.helper;
    this.helper = null;
    await helper?.stop();
  }

  /** The setting changed: devices are told whether TVs can be woken. */
  settingsChanged(): void {
    this.options.changed?.();
  }

  private get config(): WakeConfig | null {
    return this.options.config();
  }

  // ---- What devices are shown ----

  /** Whether `deviceId` is a TV that can be woken now. */
  wakeable(deviceId: string): boolean {
    const config = this.config;
    if (!config?.enabled || !this.helper?.isUp) return false;
    return this.rowFor(deviceId) !== null;
  }

  /** How long a play waits for a woken TV. */
  holdPlayMs(): number {
    return this.timings.holdPlayMs ?? (this.config?.holdPlaySeconds ?? 180) * 1000;
  }

  /** Whether the household lets kids turn a TV on, and waking is on at all. */
  kidsMayWake(): boolean {
    const config = this.config;
    return config?.enabled === true && config.kids;
  }

  private rowFor(deviceId: string): Row | null {
    return (
      this.options.db.get<Row>("select * from wake_tv where device_id = ?", [deviceId]) ?? null
    );
  }

  private rows(): Row[] {
    return this.options.db.all<Row>("select * from wake_tv order by name, id");
  }

  // ---- A manager's page ----

  status(): WakeStatus {
    const config = this.config;
    const pairing = this.livePairing();
    return {
      configured: config !== null,
      enabled: config?.enabled ?? false,
      kids: config?.kids ?? false,
      running: this.helper?.isUp ?? false,
      problem: config === null ? null : (this.helper?.problem ?? null),
      pyatv: this.helper?.version ?? null,
      scannedAt: this.scannedAt,
      televisions: this.televisions(),
      pairing: pairing
        ? { id: pairing.id, televisionId: pairing.televisionId, expiresAt: pairing.expiresAt }
        : null,
    };
  }

  private televisions(): Television[] {
    const rows = new Map(this.rows().map((row) => [row.id, row]));
    const ids = new Set([...rows.keys(), ...this.seen.keys()]);
    const devices = this.options.devices
      .list()
      .filter((one) => one.revokedAt === null && one.platform === "tvos");
    const linked = new Set([...rows.values()].map((row) => row.device_id).filter((id) => id));
    return [...ids]
      .map((id): Television => {
        const row = rows.get(id);
        const seen = this.seen.get(id);
        const name = seen?.name ?? row?.name ?? "Apple TV";
        const deviceId =
          row?.device_id && devices.some((one) => one.id === row.device_id) ? row.device_id : null;
        const same = devices.filter((one) => !linked.has(one.id) && sameName(one.name, name));
        return {
          id,
          name,
          model: seen?.model ?? row?.model ?? "",
          paired: seen ? seen.paired : row !== undefined,
          found: seen !== undefined,
          deviceId,
          suggestedDeviceId: deviceId === null && same.length === 1 ? (same[0]?.id ?? null) : null,
        };
      })
      .sort((a, b) => a.name.localeCompare(b.name) || a.id.localeCompare(b.id));
  }

  private running(): WakeHelper {
    if (!this.config) {
      throw new ApiError("not_found", "Waking Apple TVs is not set up on this server.", {
        reason: "wake_not_configured",
      });
    }
    if (!this.helper?.isUp) {
      throw new ApiError(
        "unavailable",
        `Apple TVs cannot be reached now: ${this.helper?.problem ?? "the helper is starting"}.`,
        { reason: "wake_unavailable" },
      );
    }
    return this.helper;
  }

  private limit(rate: keyof typeof WAKE_RATES, key: string): void {
    const wait = this.rates[rate].take(key);
    if (wait > 0) {
      throw new AuthError("rate_limited", "That was a lot at once. Try again in a moment.", wait);
    }
  }

  /** Looks on the network for Apple TVs. */
  async scan(by: Device): Promise<WakeStatus> {
    const helper = this.running();
    this.limit("manage", by.id);
    const config = this.config;
    const answer = await this.ask(
      helper,
      "scan",
      { timeout: 5, ...(config && config.hosts.length > 0 ? { hosts: config.hosts } : {}) },
      SCAN_TIMEOUT_MS,
    );
    const found = Array.isArray(answer["televisions"]) ? answer["televisions"] : [];
    const seen = new Map<string, Seen>();
    for (const one of found.slice(0, 64)) {
      const tv = readTelevision(one);
      if (tv) seen.set(tv.id, tv);
    }
    this.seen = seen;
    this.scannedAt = this.now();
    // Those Lobby holds credentials for are remembered, also when they were paired without it.
    for (const tv of seen.values()) {
      if (tv.paired) this.remember(tv);
      else this.options.db.run("delete from wake_tv where id = ?", [tv.id]);
    }
    this.options.changed?.();
    return this.status();
  }

  private remember(tv: Seen): void {
    this.options.db.run(
      `insert into wake_tv (id, name, model, device_id, paired_at) values (?, ?, ?, null, ?)
       on conflict (id) do update set name = excluded.name, model = excluded.model`,
      [tv.id, tv.name, tv.model, this.now()],
    );
  }

  private livePairing(): Pairing | null {
    if (this.pairing && this.pairing.expiresAt <= this.now()) this.pairing = null;
    return this.pairing;
  }

  /** Starts pairing: the TV shows a code now, which is typed in the app within a minute. */
  async beginPairing(by: Device, televisionId: string): Promise<WakeStatus["pairing"] & object> {
    const helper = this.running();
    this.limit("manage", by.id);
    const before = this.livePairing();
    if (before) {
      this.pairing = null;
      await helper.ask("pair_cancel", { pairing: before.helperToken }).catch(() => undefined);
    }
    const answer = await this.ask(helper, "pair_begin", { device: televisionId });
    const token = answer["pairing"];
    if (typeof token !== "string") {
      throw new ApiError("unavailable", "The Apple TV did not start pairing. Try again.");
    }
    const pairing: Pairing = {
      id: randomBytes(12).toString("base64url"),
      helperToken: token,
      televisionId,
      by: by.id,
      expiresAt: this.now() + PAIRING_MS,
    };
    this.pairing = pairing;
    log.info("Pairing an Apple TV", { device: by.id });
    return { id: pairing.id, televisionId, expiresAt: pairing.expiresAt };
  }

  /** The code the TV shows. Connects the TV, and links it to a Lobby device when one fits. */
  async finishPairing(by: Device, pairingId: string, pin: string): Promise<Television> {
    const helper = this.running();
    const pairing = this.livePairing();
    if (!pairing || pairing.id !== pairingId) {
      throw new ApiError("gone", "The code was not typed in time. Start again.", {
        reason: "pairing_expired",
      });
    }
    if (!/^\d{4}$/.test(pin)) {
      throw new ApiError("invalid_request", "The code is the four digits the Apple TV shows.");
    }
    this.pairing = null;
    try {
      await this.ask(helper, "pair_pin", { pairing: pairing.helperToken, pin });
      const answer = await this.ask(helper, "pair_finish", { pairing: pairing.helperToken });
      const tv = readTelevision(answer["television"]);
      if (!tv) throw new ApiError("unavailable", "The Apple TV did not say who it is.");
      this.seen.set(tv.id, { ...tv, paired: true });
      this.remember({ ...tv, paired: true });
    } finally {
      await helper.ask("pair_cancel", { pairing: pairing.helperToken }).catch(() => undefined);
    }
    log.info("Connected an Apple TV", { device: by.id });
    this.options.changed?.();
    const shown = this.televisions().find((one) => one.id === pairing.televisionId);
    if (!shown) throw new ApiError("not_found", "That Apple TV is no longer known.");
    return shown;
  }

  async cancelPairing(pairingId: string): Promise<void> {
    const pairing = this.livePairing();
    if (!pairing || pairing.id !== pairingId) return;
    this.pairing = null;
    await this.helper?.ask("pair_cancel", { pairing: pairing.helperToken }).catch(() => undefined);
  }

  /** A manager says which Lobby device this TV is; null: none. */
  link(televisionId: string, deviceId: string | null): Television {
    const row = this.options.db.get<Row>("select * from wake_tv where id = ?", [televisionId]);
    if (!row) {
      throw new ApiError("not_found", "Lobby Server is not connected to that Apple TV.", {
        reason: "not_paired",
      });
    }
    if (deviceId !== null) {
      const device = this.options.devices.find(deviceId);
      if (!device || device.revokedAt !== null) {
        throw new ApiError("not_found", "There is no such device.");
      }
      if (device.platform !== "tvos") {
        throw new ApiError("invalid_request", `${device.name} is not an Apple TV.`);
      }
    }
    this.options.db.transaction(() => {
      if (deviceId !== null) {
        this.options.db.run("update wake_tv set device_id = null where device_id = ?", [deviceId]);
      }
      this.options.db.run("update wake_tv set device_id = ? where id = ?", [
        deviceId,
        televisionId,
      ]);
    });
    this.options.changed?.();
    const shown = this.televisions().find((one) => one.id === televisionId);
    if (!shown) throw new ApiError("not_found", "That Apple TV is no longer known.");
    return shown;
  }

  /** Lobby Server forgets the TV's credentials. On the TV it stays in the list until removed there. */
  async unpair(by: Device, televisionId: string): Promise<void> {
    const helper = this.running();
    this.limit("manage", by.id);
    await this.ask(helper, "unpair", { device: televisionId });
    this.options.db.run("delete from wake_tv where id = ?", [televisionId]);
    const seen = this.seen.get(televisionId);
    if (seen) this.seen.set(televisionId, { ...seen, paired: false });
    log.info("Disconnected an Apple TV", { device: by.id });
    this.options.changed?.();
  }

  // ---- Waking ----

  /**
   * Turns the TV that is `deviceId` on and opens Lobby on it. Resolves once the TV took both;
   * Lobby then opens the live channel by itself. When it does not come up within a few seconds
   * (tvOS asks who is watching, and opens no app until someone answers), select is pressed once
   * on the TV and Lobby opened again (`remote.wake.pickProfile`). `progress` hears of that.
   */
  async wake(sender: Device, deviceId: string, progress?: WakeProgress): Promise<Woke> {
    const config = this.config;
    if (!config?.enabled) {
      throw new ApiError("forbidden", "Waking Apple TVs is turned off.", { reason: "wake_off" });
    }
    const row = this.rowFor(deviceId);
    const device = this.options.devices.find(deviceId);
    if (!row || !device || device.revokedAt !== null) {
      throw new ApiError("not_found", "That device cannot be woken.", { reason: "not_wakeable" });
    }
    const helper = this.running();
    this.limit("perSender", sender.id);
    this.limit("perTelevision", row.id);
    const already = this.waking.get(row.id);
    if (already) {
      if (progress) already.told.add(progress);
      return already.woke;
    }
    const told = new Set<WakeProgress>(progress ? [progress] : []);
    const woke = this.ask(
      helper,
      "wake",
      { device: row.id, app: config.app, pickProfile: config.pickProfile },
      WAKE_TIMEOUT_MS,
    ).then((answer) => {
      const said = readWoke(answer);
      log.info("Woke an Apple TV", {
        device: deviceId,
        by: sender.id,
        front: said.front,
        selected: said.selected,
      });
      return said;
    });
    const one = { woke, told };
    this.waking.set(row.id, one);
    woke
      .then((said) => this.follow(row.id, deviceId, said, told))
      .catch(() => undefined)
      .finally(() => {
        if (this.waking.get(row.id) === one) this.waking.delete(row.id);
      });
    return woke;
  }

  /** After the TV is on: waits for Lobby, and presses select once when it does not come. */
  private async follow(
    televisionId: string,
    deviceId: string,
    woke: Woke,
    told: Set<WakeProgress>,
  ): Promise<void> {
    const tell: WakeProgress = (step, reason) => {
      for (const one of told) {
        try {
          one(step, reason);
        } catch {
          // A screen that went away.
        }
      }
    };
    if (woke.front === true) return;
    const { pickAfterMs, openMs } = this.timings;
    let selected = woke.selected;
    if (!selected && this.config?.pickProfile === true) {
      if (await this.opens(deviceId, pickAfterMs)) return;
      const helper = this.helper;
      const app = this.config.app;
      if (!helper?.isUp || this.stopped) return;
      selected = true;
      tell("profile", null);
      try {
        const answer = readWoke(
          await this.ask(helper, "pick", { device: televisionId, app }, WAKE_TIMEOUT_MS),
        );
        log.info("Pressed select on a woken Apple TV that did not open Lobby", {
          device: deviceId,
          front: answer.front,
        });
        if (answer.front === true) return;
      } catch (error) {
        log.warn("Pressing select on an Apple TV failed", { problem: errorMessage(error) });
      }
    }
    if (await this.opens(deviceId, openMs)) return;
    log.warn("Lobby did not come up on a woken Apple TV", {
      device: deviceId,
      reason: "timeout",
      selected,
    });
    tell("not_open", "timeout");
  }

  /** Whether Lobby opens on the device within `ms`. */
  private async opens(deviceId: string, ms: number): Promise<boolean> {
    const end = this.now() + ms;
    for (;;) {
      if (this.isOpen(deviceId)) return true;
      if (this.stopped || this.now() >= end) return false;
      await new Promise((done) => setTimeout(done, this.timings.lookMs));
    }
  }

  /** Asks the helper; its refusals become answers the app can show. */
  private async ask(
    helper: WakeHelper,
    op: string,
    fields: Record<string, unknown>,
    timeoutMs?: number,
  ): Promise<Record<string, unknown>> {
    try {
      return await helper.ask(op, fields, timeoutMs);
    } catch (error) {
      if (!(error instanceof WakeHelperError)) throw error;
      const reason = `wake_${error.code}`;
      switch (error.code) {
        case "not_found":
          throw new ApiError(
            "not_found",
            "That Apple TV was not found on the network. Is it plugged in?",
            { reason },
          );
        case "not_paired":
          throw new ApiError(
            "forbidden",
            "The Apple TV no longer accepts Lobby Server. Connect it again in Server Settings.",
            { reason },
          );
        case "pairing_failed":
          throw new ApiError("forbidden", "The Apple TV did not take the code. Start again.", {
            reason,
          });
        case "timeout":
          throw new ApiError("unavailable", "The Apple TV did not answer in time.", { reason });
        case "bad_request":
          throw new ApiError("invalid_request", error.message, { reason });
        default:
          log.warn("Asking an Apple TV failed", { op, problem: errorMessage(error) });
          throw new ApiError("unavailable", "The Apple TV could not be reached.", { reason });
      }
    }
  }
}

function sameName(a: string, b: string): boolean {
  const plain = (one: string): string => one.trim().toLocaleLowerCase();
  return plain(a) === plain(b);
}

function readWoke(answer: Record<string, unknown>): Woke {
  const front = answer["front"];
  return {
    front: typeof front === "boolean" ? front : null,
    selected: answer["selected"] === true,
  };
}

function readTelevision(value: unknown): Seen | null {
  if (typeof value !== "object" || value === null) return null;
  const one = value as Record<string, unknown>;
  const { id, name, model, paired } = one;
  if (typeof id !== "string" || id === "" || id.length > 200) return null;
  return {
    id,
    name: typeof name === "string" && name.trim() !== "" ? name.trim().slice(0, 100) : "Apple TV",
    model: typeof model === "string" ? model.slice(0, 100) : "",
    paired: paired === true,
  };
}
