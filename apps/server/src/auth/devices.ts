// SPDX-License-Identifier: MPL-2.0
import { createHash, randomBytes, randomInt, randomUUID, timingSafeEqual } from "node:crypto";
import { RateLimiter } from "../outside/limits.ts";
import type { Database } from "../db/database.ts";
import { HOUSEHOLD_ACTIVE, HOUSEHOLD_OUTSIDE, OWNER_HOUSEHOLD } from "../households/owner.ts";

/** What an older app reads: "manager" is a server admin, everyone else a viewer. */
export type Role = "manager" | "viewer";
/**
 * What a device may do (docs/api.md, Households). A server admin: everything. A household admin:
 * their own household's viewers, kids, devices and invitations. A viewer: watch.
 */
export type Access = "admin" | "householdAdmin" | "viewer";
export type Platform = "ios" | "ipados" | "macos" | "tvos" | "cli";

export const PLATFORMS: readonly Platform[] = ["ios", "ipados", "macos", "tvos", "cli"];
export const ROLES: readonly Role[] = ["manager", "viewer"];
export const ACCESS: readonly Access[] = ["admin", "householdAdmin", "viewer"];

type AccessColumn = "admin" | "household_admin" | "viewer";
const COLUMN: Readonly<Record<Access, AccessColumn>> = {
  admin: "admin",
  householdAdmin: "household_admin",
  viewer: "viewer",
};
const FROM_COLUMN: Readonly<Record<AccessColumn, Access>> = {
  admin: "admin",
  household_admin: "householdAdmin",
  viewer: "viewer",
};

/** What an older app is told of a device: only a server admin is its manager. */
export const legacyRole = (access: Access): Role => (access === "admin" ? "manager" : "viewer");

/** What a request or the command line says, as an access: an older "manager" is a server admin. */
export function accessFrom(value: Access | Role): Access {
  return value === "manager" ? "admin" : value;
}

/** How far up it goes: who may change whom. */
export const rank = (access: Access): number => ACCESS.length - 1 - ACCESS.indexOf(access);

/** Whether it manages a household (its own; a server admin also the server). */
export const managesHousehold = (access: Access): boolean => access !== "viewer";

export interface Device {
  id: string;
  name: string;
  platform: Platform;
  /** For older apps: "manager" only for a server admin. */
  role: Role;
  access: Access;
  createdAt: number;
  lastUsedAt: number | null;
  revokedAt: number | null;
  /** The kids viewer this device belongs to: it gets only what that viewer may see. */
  kidsProfileId: string | null;
  /** Whether a manager lets this device in from outside (docs/outside.md). */
  allowOutside: boolean;
  lastOutsideAt: number | null;
  /** Whether titles can be sent to it from other devices. */
  isTarget: boolean;
  /** Whether a manager lets it see and control other devices, and be controlled. */
  allowRemote: boolean;
  /** The same while it is outside. */
  remoteOutside: boolean;
  /** The household it belongs to (docs/api.md, Households). */
  householdId: string;
}

interface DeviceRow {
  id: string;
  name: string;
  platform: Platform;
  role: Role;
  created_at: number;
  last_used_at: number | null;
  revoked_at: number | null;
  kids_profile_id: string | null;
  allow_outside: number;
  last_outside_at: number | null;
  /** Null: what is usual for such a device. */
  is_target: number | null;
  allow_remote: number;
  remote_outside: number;
  household_id: string;
  access: AccessColumn;
}

interface PairingRow {
  id: string;
  code_hash: string;
  poll_secret_hash: string;
  device_name: string;
  platform: Platform;
  created_at: number;
  expires_at: number;
  /** The access it is given, as the column says it. */
  approved_role: AccessColumn | null;
  awaits_admin: number;
  refused_at: number | null;
  approved_at: number | null;
  completed_at: number | null;
}

export interface PairingRequest {
  id: string;
  deviceName: string;
  platform: Platform;
  /** For the manager to compare with the device's screen. Null after a server restart. */
  code: string | null;
  createdAt: number;
  expiresAt: number;
}

/** Thrown for a failure the HTTP layer turns into a status and an error code. */
export class AuthError extends Error {
  readonly code:
    | "unauthorized"
    | "device_revoked"
    | "forbidden"
    | "not_found"
    | "gone"
    | "rate_limited"
    | "conflict";
  readonly retryAfterSeconds: number | null;

  constructor(code: AuthError["code"], message: string, retryAfterSeconds: number | null = null) {
    super(message);
    this.code = code;
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

const PAIRING_LIFETIME_MS = 10 * 60_000;
const GUESS_WINDOW_MS = 10 * 60_000;
const MAX_WRONG_GUESSES = 5;
// Writing last_used_at on every request would turn each video range request into a database write.
const LAST_USED_RESOLUTION_MS = 60_000;

function hash(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function sameSecret(a: string, b: string): boolean {
  const left = Buffer.from(hash(a));
  const right = Buffer.from(hash(b));
  return timingSafeEqual(left, right);
}

function toDevice(row: DeviceRow): Device {
  return {
    id: row.id,
    name: row.name,
    platform: row.platform,
    role: legacyRole(FROM_COLUMN[row.access]),
    access: FROM_COLUMN[row.access],
    createdAt: row.created_at,
    lastUsedAt: row.last_used_at,
    revokedAt: row.revoked_at,
    kidsProfileId: row.kids_profile_id,
    allowOutside: row.allow_outside === 1,
    lastOutsideAt: row.last_outside_at,
    isTarget:
      row.is_target === null
        ? row.platform === "tvos" || row.platform === "macos"
        : row.is_target === 1,
    allowRemote: row.allow_remote === 1,
    remoteOutside: row.remote_outside === 1,
    householdId: row.household_id,
  };
}

/** How many devices may wait to be paired: in all, and from one address. */
export const MAX_WAITING = 40;
export const MAX_WAITING_PER_ADDRESS = 8;
const ASK_PER_ADDRESS = { burst: 20, perMinute: 10 };
const ASK_IN_ALL = { burst: 60, perMinute: 30 };
/** A request nobody approved is kept this long after it expired, so the device is told that it did. */
const KEEP_EXPIRED_MS = 3_600_000;
const MAX_GUESS_KEYS = 4_096;

/** Counts wrong guesses per key and locks the key out once there are too many. */
export class GuessLimiter {
  private readonly failures = new Map<string, number[]>();
  private readonly now: () => number;

  constructor(now: () => number) {
    this.now = now;
  }

  /** Throws when `key` has used up its wrong guesses. */
  check(key: string): void {
    const recent = (this.failures.get(key) ?? []).filter((at) => at > this.now() - GUESS_WINDOW_MS);
    if (recent.length > 0) this.failures.set(key, recent);
    else this.failures.delete(key);
    const oldest = recent[0];
    if (recent.length >= MAX_WRONG_GUESSES && oldest !== undefined) {
      const retryAfter = Math.ceil((oldest + GUESS_WINDOW_MS - this.now()) / 1000);
      throw new AuthError(
        "rate_limited",
        "Too many wrong attempts. Try again in a few minutes.",
        retryAfter,
      );
    }
  }

  fail(key: string): void {
    const all = [...(this.failures.get(key) ?? []), this.now()].slice(-MAX_WRONG_GUESSES);
    this.failures.delete(key);
    this.failures.set(key, all);
    if (this.failures.size <= MAX_GUESS_KEYS) return;
    // The key that failed longest ago makes room.
    const first = this.failures.keys().next().value;
    if (first !== undefined) this.failures.delete(first);
  }

  clear(key: string): void {
    this.failures.delete(key);
  }
}

/**
 * Device credentials and pairing.
 *
 * A credential is 32 random bytes. Only its SHA-256 is stored, which is enough
 * for a secret with that much entropy: there is nothing to brute-force. Pairing
 * codes are short, so they are protected by expiry, single use and a lockout.
 */
/**
 * How the first manager gets in. "open": the first device to ask sets the server up.
 * "secret": it must also know the setup secret from the server's own console.
 */
export type ClaimMode = "open" | "secret";

/** Set when a restore left nobody who manages the server. */
export const CLAIM_NEEDS_SECRET = "claim_needs_secret";

export class Devices {
  private readonly configuredClaim: ClaimMode;
  /** Told of every device that is removed. */
  onRevoked: ((deviceId: string, at: number) => void) | null = null;
  private readonly db: Database;
  private readonly now: () => number;
  private readonly setupSecret: string;
  private readonly limiter: GuessLimiter;
  /** Codes on show right now, by request. Only in memory: the database holds their hashes. */
  private readonly shownCodes = new Map<string, string>();
  /** Where waiting requests came from, as far as that is known. */
  private readonly askedFrom = new Map<string, string>();
  private readonly askPerAddress: RateLimiter;
  private readonly askInAll: RateLimiter;

  constructor(
    db: Database,
    setupSecret: string,
    now: () => number = Date.now,
    claimMode: ClaimMode = "secret",
  ) {
    this.configuredClaim = claimMode;
    this.db = db;
    this.setupSecret = setupSecret;
    this.now = now;
    this.limiter = new GuessLimiter(now);
    this.askPerAddress = new RateLimiter(ASK_PER_ADDRESS, now);
    this.askInAll = new RateLimiter(ASK_IN_ALL, now);
  }

  get claimMode(): ClaimMode {
    return this.db.getMeta(CLAIM_NEEDS_SECRET) === "yes" ? "secret" : this.configuredClaim;
  }

  get isClaimed(): boolean {
    return (
      this.db.get(
        "select 1 as x from device where access = 'admin' and revoked_at is null limit 1",
      ) !== undefined
    );
  }

  private createDevice(
    name: string,
    platform: Platform,
    access: Access,
    allowOutside = false,
    householdId = OWNER_HOUSEHOLD,
  ): { device: Device; token: string } {
    // A server admin is of the owner's household, and of no other.
    if (access === "admin" && householdId !== OWNER_HOUSEHOLD) {
      throw new AuthError("forbidden", "A server admin is of the server owner's household.");
    }
    const role = legacyRole(access);
    const token = randomBytes(32).toString("base64url");
    const row: DeviceRow = {
      id: randomUUID(),
      name: name.trim().slice(0, 80) || "Unnamed device",
      platform,
      role,
      created_at: this.now(),
      last_used_at: null,
      revoked_at: null,
      kids_profile_id: null,
      allow_outside: allowOutside ? 1 : 0,
      last_outside_at: null,
      is_target: null,
      allow_remote: 1,
      remote_outside: 0,
      household_id: householdId,
      access: COLUMN[access],
    };
    this.db.run(
      `insert into device (id, name, platform, role, token_hash, created_at, allow_outside,
         household_id, access) values (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        row.id,
        row.name,
        row.platform,
        row.role,
        hash(token),
        row.created_at,
        row.allow_outside,
        householdId,
        row.access,
      ],
    );
    return { device: toDevice(row), token };
  }

  /**
   * The first manager claims a new server. In "secret" mode only with the setup
   * secret; in "open" mode the first device to ask gets it, because a household
   * setting up its own server should not have to read a log first.
   */
  claim(
    setupSecret: string | null,
    deviceName: string,
    platform: Platform,
  ): { device: Device; token: string } {
    this.limiter.check("claim");
    // Checked and written in one transaction, so two devices asking at once cannot both win.
    return this.db.transaction(() => {
      if (this.isClaimed) {
        throw new AuthError(
          "forbidden",
          "This server already has a manager. Ask them to approve this device.",
        );
      }
      if (
        this.claimMode === "secret" &&
        (setupSecret === null || !sameSecret(setupSecret, this.setupSecret))
      ) {
        this.limiter.fail("claim");
        throw new AuthError("forbidden", "That setup secret is not right.");
      }
      return this.createDevice(deviceName, platform, "admin");
    });
  }

  /** Creates a manager device from the Pi's own command line, where no secret is needed. */
  createLocalManager(deviceName: string): { device: Device; token: string } {
    return this.createDevice(deviceName, "cli", "admin");
  }

  /** @throws AuthError when the token is unknown or its device was revoked */
  authenticate(token: string): Device {
    const row = this.db.get<DeviceRow & { active: number }>(
      `select *, ${HOUSEHOLD_ACTIVE} as active from device where token_hash = ?`,
      [hash(token)],
    );
    if (!row) throw new AuthError("unauthorized", "This device is not paired with the server.");
    if (row.revoked_at !== null) {
      throw new AuthError(
        "device_revoked",
        "A manager removed this device. Pair it again to continue.",
      );
    }
    // A household the owner paused: its devices are told nothing, and keep their credential.
    if (row.active !== 1) {
      throw new AuthError("not_found", "There is nothing here for this device.");
    }
    if (row.last_used_at === null || this.now() - row.last_used_at > LAST_USED_RESOLUTION_MS) {
      this.db.run("update device set last_used_at = ? where id = ?", [this.now(), row.id]);
      row.last_used_at = this.now();
    }
    return toDevice(row);
  }

  /**
   * A device paired from outside: a viewer, or a household admin when an invitation said so.
   * Never a server admin: they act from home.
   */
  createOutsideDevice(
    name: string,
    platform: Platform,
    access: Access = "viewer",
    householdId = OWNER_HOUSEHOLD,
  ): { device: Device; token: string } {
    if (access === "admin") {
      throw new AuthError("forbidden", "A device from outside is never a server admin.");
    }
    return this.createDevice(name, platform, access, true, householdId);
  }

  /** A viewer of the owner's household, paired from outside. */
  createOutsideViewer(name: string, platform: Platform): { device: Device; token: string } {
    return this.createOutsideDevice(name, platform);
  }

  /**
   * The device behind a credential that comes from outside. Null for an unknown one, a removed
   * one and one that is only for home: in one query, so the three cannot be told apart.
   */
  authenticateOutside(token: string): Device | null {
    const row = this.db.get<DeviceRow>(
      `select * from device where token_hash = ? and revoked_at is null and allow_outside = 1
         and ${HOUSEHOLD_OUTSIDE}`,
      [hash(token)],
    );
    return row ? toDevice(row) : null;
  }

  mayBeOutside(deviceId: string): boolean {
    return (
      this.db.get(
        `select 1 as x from device where id = ? and revoked_at is null and allow_outside = 1
           and ${HOUSEHOLD_OUTSIDE}`,
        [deviceId],
      ) !== undefined
    );
  }

  setAllowOutside(deviceId: string, allow: boolean): Device {
    const changed = this.db.run(
      "update device set allow_outside = ? where id = ? and revoked_at is null",
      [allow ? 1 : 0, deviceId],
    );
    const device = changed === 0 ? null : this.find(deviceId);
    if (!device) throw new AuthError("not_found", "There is no such device.");
    return device;
  }

  /** What is left out stays. `isTarget: null` is what is usual for such a device. */
  setRemote(
    deviceId: string,
    settings: { isTarget?: boolean | null; allowRemote?: boolean; remoteOutside?: boolean },
  ): Device {
    const { isTarget, allowRemote, remoteOutside } = settings;
    const number = (value: boolean | null): number | null =>
      value === null ? null : Number(value);
    const before = this.find(deviceId);
    if (!before || before.revokedAt !== null) {
      throw new AuthError("not_found", "There is no such device.");
    }
    return this.db.transaction(() => {
      if (isTarget !== undefined) {
        this.db.run("update device set is_target = ? where id = ?", [number(isTarget), deviceId]);
      }
      if (allowRemote !== undefined) {
        this.db.run("update device set allow_remote = ? where id = ?", [
          number(allowRemote),
          deviceId,
        ]);
      }
      if (remoteOutside !== undefined) {
        this.db.run("update device set remote_outside = ? where id = ?", [
          number(remoteOutside),
          deviceId,
        ]);
      }
      return this.find(deviceId) ?? before;
    });
  }

  noteOutside(deviceId: string, at: number): void {
    this.db.run(
      "update device set last_outside_at = ? where id = ? and coalesce(last_outside_at, 0) < ?",
      [at, deviceId, at - LAST_USED_RESOLUTION_MS],
    );
  }

  /** @param householdId only the devices of this household; all of them when left out */
  list(householdId?: string): Device[] {
    return (
      householdId === undefined
        ? this.db.all<DeviceRow>("select * from device order by created_at")
        : this.db.all<DeviceRow>(
            "select * from device where household_id = ? order by created_at",
            [householdId],
          )
    ).map(toDevice);
  }

  /** How many devices a household has that are not removed. */
  countIn(householdId: string): number {
    return (
      this.db.get<{ n: number }>(
        "select count(*) as n from device where household_id = ? and revoked_at is null",
        [householdId],
      )?.n ?? 0
    );
  }

  find(deviceId: string): Device | null {
    const row = this.db.get<DeviceRow>("select * from device where id = ?", [deviceId]);
    return row ? toDevice(row) : null;
  }

  /** Says which kids viewer a device belongs to, or that it belongs to none. */
  bindToKids(deviceId: string, profileId: string | null): Device {
    return this.db.transaction(() => {
      const device = this.find(deviceId);
      if (!device || device.revokedAt !== null) {
        throw new AuthError("not_found", "There is no such device.");
      }
      if (profileId !== null) {
        if (device.access !== "viewer") {
          throw new AuthError("conflict", "An admin's device cannot be limited to a kids viewer.");
        }
        // A viewer of another household is no viewer at all for this device.
        const profile = this.db.get<{ kids_json: string | null }>(
          "select kids_json from profile where id = ? and deleted_at is null and household_id = ?",
          [profileId, device.householdId],
        );
        if (!profile) throw new AuthError("not_found", "There is no such viewer.");
        if (profile.kids_json === null) {
          throw new AuthError("conflict", "Turn kids limits on for this viewer first.");
        }
      }
      this.db.run("update device set kids_profile_id = ? where id = ?", [profileId, deviceId]);
      return { ...device, kidsProfileId: profileId };
    });
  }

  /** The names of the devices that belong to this kids viewer. */
  boundTo(profileId: string): string[] {
    return this.db
      .all<{ name: string }>(
        "select name from device where kids_profile_id = ? and revoked_at is null order by name",
        [profileId],
      )
      .map((row) => row.name);
  }

  /**
   * @param everyone also the last manager: for a household that is removed as a whole
   */
  revoke(deviceId: string, everyone = false): void {
    const row = this.db.get<DeviceRow>("select * from device where id = ?", [deviceId]);
    if (!row) throw new AuthError("not_found", "There is no such device.");
    if (row.revoked_at !== null) return;
    if (!everyone) this.keepOneAdmin(row);
    const at = this.now();
    this.db.run("update device set revoked_at = ? where id = ?", [at, deviceId]);
    this.onRevoked?.(deviceId, at);
  }

  /**
   * Throws when this device is the last that keeps its household managed: the last server admin,
   * or a guest household's last household admin.
   */
  private keepOneAdmin(row: DeviceRow): void {
    const last =
      row.access === "admin" ||
      (row.access === "household_admin" && row.household_id !== OWNER_HOUSEHOLD);
    if (!last) return;
    const others = this.db.get<{ n: number }>(
      `select count(*) as n from device where access = ? and revoked_at is null
         and household_id = ? and id != ?`,
      [row.access, row.household_id, row.id],
    );
    if ((others?.n ?? 0) === 0) {
      throw new AuthError(
        "conflict",
        row.access === "admin"
          ? "This is the only server admin. Make another one before this one stops being it."
          : "This is the household's only admin. Make another one first.",
      );
    }
  }

  /** Makes a device a server admin, a household admin or a viewer. */
  setAccess(deviceId: string, access: Access): Device {
    return this.db.transaction(() => {
      const row = this.db.get<DeviceRow>("select * from device where id = ?", [deviceId]);
      if (!row || row.revoked_at !== null)
        throw new AuthError("not_found", "There is no such device.");
      if (FROM_COLUMN[row.access] === access) return toDevice(row);
      if (access === "admin" && row.household_id !== OWNER_HOUSEHOLD) {
        throw new AuthError("conflict", "A server admin is of the server owner's household.");
      }
      if (access !== "viewer" && row.kids_profile_id !== null) {
        throw new AuthError("conflict", "First say this device belongs to no kids viewer.");
      }
      if (rank(access) < rank(FROM_COLUMN[row.access])) this.keepOneAdmin(row);
      this.db.run("update device set access = ?, role = ? where id = ?", [
        COLUMN[access],
        legacyRole(access),
        deviceId,
      ]);
      return this.find(deviceId) ?? toDevice(row);
    });
  }

  /** Makes room for one more waiting request, or refuses it. */
  private admit(address: string | null): void {
    const wait = Math.max(
      address === null ? 0 : this.askPerAddress.take(address),
      this.askInAll.take("all"),
    );
    const waiting = this.db.all<{ id: string }>(
      "select id from pairing_request where expires_at > ? and approved_at is null order by created_at",
      [this.now()],
    );
    const refuse = (seconds: number): never => {
      throw new AuthError(
        "rate_limited",
        "Too many devices are asking to be paired. Try again in a few minutes.",
        seconds,
      );
    };
    if (wait > 0) refuse(wait);
    const here = new Set(waiting.map((request) => request.id));
    for (const id of this.askedFrom.keys()) if (!here.has(id)) this.askedFrom.delete(id);
    // A device that asks again and again takes its own place, not everybody's.
    const own =
      address === null ? [] : waiting.filter(({ id }) => this.askedFrom.get(id) === address);
    const oldest = own[0];
    if (oldest && own.length >= MAX_WAITING_PER_ADDRESS) {
      this.db.run("delete from pairing_request where id = ?", [oldest.id]);
      this.askedFrom.delete(oldest.id);
    } else if (waiting.length >= MAX_WAITING) {
      refuse(60);
    }
  }

  /**
   * A new device asks to join and gets a code to show on its screen.
   *
   * @param address where it asks from, when that is known
   */
  startPairing(
    deviceName: string,
    platform: Platform,
    address: string | null = null,
  ): { id: string; code: string; pollSecret: string; expiresAt: number } {
    this.admit(address);
    this.db.run(
      "delete from pairing_request where expires_at < ? or (expires_at < ? and approved_at is null)",
      [this.now() - 24 * 3_600_000, this.now() - KEEP_EXPIRED_MS],
    );
    // Two waiting devices must never show the same code. Few wait, so the next number that is
    // free is never far.
    let number = randomInt(0, 1_000_000);
    let code = String(number).padStart(6, "0");
    while (this.findWaiting(code)) {
      number = (number + 1) % 1_000_000;
      code = String(number).padStart(6, "0");
    }
    const id = randomUUID();
    const pollSecret = randomBytes(24).toString("base64url");
    const expiresAt = this.now() + PAIRING_LIFETIME_MS;
    this.db.run(
      `insert into pairing_request (id, code_hash, poll_secret_hash, device_name, platform, created_at, expires_at)
       values (?, ?, ?, ?, ?, ?, ?)`,
      [
        id,
        hash(`code:${code}`),
        hash(pollSecret),
        deviceName.trim().slice(0, 80) || "Unnamed device",
        platform,
        this.now(),
        expiresAt,
      ],
    );
    for (const request of this.shownCodes.keys()) {
      if (!this.findWaitingById(request)) this.shownCodes.delete(request);
    }
    this.shownCodes.set(id, code);
    if (address !== null) this.askedFrom.set(id, address);
    return { id, code, pollSecret, expiresAt };
  }

  private findWaiting(code: string): PairingRow | undefined {
    return this.db.get<PairingRow>(
      "select * from pairing_request where code_hash = ? and expires_at > ? and approved_at is null",
      [hash(`code:${code}`), this.now()],
    );
  }

  private findWaitingById(id: string): PairingRow | undefined {
    return this.db.get<PairingRow>(
      "select * from pairing_request where id = ? and expires_at > ? and approved_at is null",
      [id, this.now()],
    );
  }

  waiting(): PairingRequest[] {
    return this.db
      .all<PairingRow>(
        "select * from pairing_request where expires_at > ? and approved_at is null order by created_at",
        [this.now()],
      )
      .map((row) => ({
        id: row.id,
        deviceName: row.device_name,
        platform: row.platform,
        code: this.shownCodes.get(row.id) ?? null,
        createdAt: row.created_at,
        expiresAt: row.expires_at,
      }));
  }

  /**
   * A manager approves the device showing `code`.
   *
   * @param approver the manager's device id, or "cli" from the Pi's command line
   */
  approve(
    code: string,
    given: Access | Role,
    approver: string,
    needsAdmin = false,
  ): { deviceName: string; platform: Platform; access: Access; awaitsAdmin: boolean } {
    const key = `approve:${approver}`;
    this.limiter.check(key);
    const request = this.findWaiting(code.replace(/\D/g, ""));
    if (!request) {
      this.limiter.fail(key);
      throw new AuthError(
        "not_found",
        "No device is waiting with that code. Check the code, or start again on the new device.",
      );
    }
    this.limiter.clear(key);
    return this.grant(request, accessFrom(given), approver, needsAdmin);
  }

  /** A manager approves a device picked from the list of those waiting. */
  approveRequest(
    requestId: string,
    given: Access | Role,
    approver: string,
    needsAdmin = false,
  ): { deviceName: string; platform: Platform; access: Access; awaitsAdmin: boolean } {
    const request = this.findWaitingById(requestId);
    if (!request) {
      throw new AuthError(
        "not_found",
        "That device is no longer waiting. Start again on the new device.",
      );
    }
    return this.grant(request, accessFrom(given), approver, needsAdmin);
  }

  private grant(
    request: PairingRow,
    access: Access,
    approver: string,
    needsAdmin: boolean,
  ): { deviceName: string; platform: Platform; access: Access; awaitsAdmin: boolean } {
    this.shownCodes.delete(request.id);
    this.db.run(
      `update pairing_request set approved_role = ?, approved_by = ?, approved_at = ?,
         awaits_admin = ? where id = ?`,
      [
        COLUMN[access],
        approver === "cli" ? null : approver,
        this.now(),
        needsAdmin ? 1 : 0,
        request.id,
      ],
    );
    return {
      deviceName: request.device_name,
      platform: request.platform,
      access,
      awaitsAdmin: needsAdmin,
    };
  }

  /** Those a household admin let in at home, waiting for a server admin's yes. */
  awaitingAdmin(): (PairingRequest & { access: Access })[] {
    return this.db
      .all<PairingRow>(
        `select * from pairing_request where approved_at is not null and awaits_admin = 1
           and completed_at is null and refused_at is null and expires_at > ? order by created_at`,
        [this.now()],
      )
      .map((row) => ({
        id: row.id,
        deviceName: row.device_name,
        platform: row.platform,
        code: null,
        createdAt: row.created_at,
        expiresAt: row.expires_at,
        access: FROM_COLUMN[row.approved_role ?? "viewer"],
      }));
  }

  /** Those a server admin turned away, while they would still have waited: their admin is told. */
  refusedByAdmin(): PairingRequest[] {
    return this.db
      .all<PairingRow>(
        "select * from pairing_request where refused_at is not null and expires_at > ? order by refused_at",
        [this.now()],
      )
      .map((row) => ({
        id: row.id,
        deviceName: row.device_name,
        platform: row.platform,
        code: null,
        createdAt: row.created_at,
        expiresAt: row.expires_at,
      }));
  }

  /** A server admin says yes, or no, to one that waits for them. */
  decideAwaiting(requestId: string, yes: boolean): { deviceName: string; platform: Platform } {
    const request = this.db.get<PairingRow>(
      `select * from pairing_request where id = ? and awaits_admin = 1 and completed_at is null
         and refused_at is null and expires_at > ?`,
      [requestId, this.now()],
    );
    if (!request) throw new AuthError("not_found", "That device is no longer waiting.");
    this.db.run(
      yes
        ? "update pairing_request set awaits_admin = 0 where id = ?"
        : "update pairing_request set refused_at = ? where id = ?",
      yes ? [request.id] : [this.now(), request.id],
    );
    return { deviceName: request.device_name, platform: request.platform };
  }

  /** The new device asks whether it was approved, and collects its credential exactly once. */
  collect(
    requestId: string,
    pollSecret: string,
  ):
    | { status: "pending"; expiresAt: number; waitingFor?: "admin" }
    | { status: "approved"; device: Device; token: string } {
    const key = `collect:${requestId}`;
    this.limiter.check(key);
    const request = this.db.get<PairingRow>("select * from pairing_request where id = ?", [
      requestId,
    ]);
    if (!request || !sameSecret(hash(pollSecret), request.poll_secret_hash)) {
      // There is nothing to guess at a request that is not there.
      if (request) this.limiter.fail(key);
      throw new AuthError("not_found", "There is no such pairing request.");
    }
    if (request.completed_at !== null) {
      throw new AuthError("gone", "This pairing request was already used. Start again.");
    }
    if (request.refused_at !== null) {
      throw new AuthError("gone", "The server's owner did not let this device in.");
    }
    if (
      request.approved_at === null ||
      request.approved_role === null ||
      request.awaits_admin === 1
    ) {
      if (request.expires_at <= this.now()) {
        throw new AuthError("gone", "The pairing code expired. Start again.");
      }
      return request.awaits_admin === 1
        ? { status: "pending", expiresAt: request.expires_at, waitingFor: "admin" }
        : { status: "pending", expiresAt: request.expires_at };
    }
    const access = FROM_COLUMN[request.approved_role];
    return this.db.transaction(() => {
      const created = this.createDevice(request.device_name, request.platform, access);
      this.db.run("update pairing_request set completed_at = ? where id = ?", [
        this.now(),
        request.id,
      ]);
      return { status: "approved" as const, ...created };
    });
  }
}
