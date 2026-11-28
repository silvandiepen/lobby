// SPDX-License-Identifier: MPL-2.0
import { createHash, randomUUID } from "node:crypto";
import type { IncomingMessage } from "node:http";
import { Hono, type Context } from "hono";
import { compress } from "hono/compress";
import { matchedRoutes } from "hono/route";
import {
  ACCESS,
  accessFrom,
  AuthError,
  legacyRole,
  managesHousehold,
  PLATFORMS,
  rank,
  ROLES,
  type Access,
  type Device,
  type Devices,
} from "../auth/devices.ts";
import type { ServerAddresses } from "../addresses.ts";
import type { LogoStore } from "../artwork/logos.ts";
import type { ArtworkStore } from "../artwork/serve.ts";
import type { Database } from "../db/database.ts";
import { registerConversionRoutes, type ConversionService } from "../conversion/index.ts";
import { registerDeviceDownloadRoutes, type DeviceDownloads } from "../devices-downloads/index.ts";
import { Bandwidth } from "../households/bandwidth.ts";
import { householdGuard } from "../households/guard.ts";
import { invitesOf } from "../households/invites.ts";
import { OWNER_HOUSEHOLD } from "../households/owner.ts";
import { registerHouseholdRoutes } from "../households/routes.ts";
import { Households, kidsCodeKey } from "../households/store.ts";
import { KIDS_CODE, KidsCode } from "../kids/code.ts";
import { kidsControl } from "../kids/control.ts";
import { kidsGuard } from "../kids/guard.ts";
import { describeRequest, registerKidsControlRoutes } from "../kids/routes.ts";
import {
  KIDS_LISTS,
  kidsLimits,
  readKids,
  type KidsSettings,
  type KidsView,
} from "../kids/limits.ts";
import { Categories, COLORS as PROFILE_COLORS } from "../library/categories.ts";
import type { ItemReader } from "../library/items.ts";
import {
  MAX_SUBTITLE_OFFSET_MS,
  mergeSubtitlePreferences,
  readSubtitlePreferences,
  SubtitlePreferencesError,
  type SubtitlePreferences,
} from "../library/subtitle-preferences.ts";
import {
  PlaybackPreferencesError,
  readPlaybackPreferences,
  storePlayback,
  type PlaybackPreferences,
} from "../library/playback-preferences.ts";
import { errorMessage, log } from "../log.ts";
import {
  mergeSkipPreferences,
  readSkipPreferences,
  SkipPreferencesError,
  type SkipPreferences,
} from "../markers/preferences.ts";
import { registerMarkerRoutes, type MarkerService } from "../markers/routes.ts";
import { registerMusicRoutes, type MusicLibrary } from "../music/index.ts";
import { registerPlaybackRoutes, type PlaybackService } from "../playback/index.ts";
import { outsideGuard, type OutsideRequest } from "../outside/guard.ts";
import { addressKey } from "../outside/limits.ts";
import { registerOutsideRoutes } from "../outside/routes.ts";
import type { OutsideEntrance } from "../outside/entrance.ts";
import { PlayLog } from "../plays.ts";
import { ENVIRONMENTS, PushError, type PushService } from "../push/service.ts";
import type { ProgressStore } from "../progress.ts";
import { Statistics } from "../stats/recorder.ts";
import { registerStatsRoutes, roadOf } from "../stats/routes.ts";
import { AirPlayPasses, registerAirPlayRoutes } from "./airplay.ts";
import { registerQueryRoutes } from "./query.ts";
import type { OmdbRatings } from "../search/omdb.ts";
import { OutsideSearch } from "../search/outside.ts";
import { registerSearchRoutes } from "../search/routes.ts";
import { SearchService } from "../search/service.ts";
import { registerCategoryRoutes } from "./categories.ts";
import { registerEditRoutes, type EditServices } from "./edit.ts";
import {
  registerRemoteRoutes,
  registerSpeakerRoutes,
  registerWakeRoutes,
  type RemoteHub,
  type SpeakerService,
  type WakeService,
} from "../remote/index.ts";
import type { FolderBrowser } from "../settings/browse.ts";
import { registerSettingsRoutes } from "../settings/routes.ts";
import { registerImportRoutes, type ImportRouteDeps } from "../imports/routes.ts";
import type { SettingsService } from "../settings/service.ts";
import { homeGuard, isNearby, isTailnet, peerAddress } from "./home.ts";
import { BusyError } from "../gate.ts";
import { createAssetLookup } from "./playback-assets.ts";
import type { VideoTags } from "../library/video-tags.ts";
import { mediaTypeFor } from "./range.ts";
import { serveLibraryFile } from "./serve-file.ts";

export const API_VERSION = 1;
/**
 * The oldest app version this server works with. An older app tells its manager to update it
 * (docs/api.md, `GET /v1/server`). Raise it only when the server stops answering an older app.
 */
export const MIN_APP_VERSION = "0.1.0";
export const DEVICE_COOKIE = "lobby_device";

export interface AppDeps {
  db: Database;
  devices: Devices;
  items: ItemReader;
  progress: ProgressStore;
  /** Repackages files AVPlayer cannot open as they are. Without it only original files are served. */
  playback?: PlaybackService;
  /** Reads the picture label of older HEVC files before they are played as they are. */
  videoTags?: VideoTags;
  artwork?: ArtworkStore;
  /** Where paired devices can reach this server, given its id. Told to paired devices only. */
  addresses?: (serverId: string) => ServerAddresses;
  /** Relays of the outside entrance, which may not come in at home. */
  relays?: readonly string[];
  /** What a manager wants on each device. Without it those routes do not exist. */
  downloads?: DeviceDownloads;
  /** Converts old files and replaces them. Without it those routes do not exist. */
  conversion?: ConversionService;
  /** Finds intros and credits. Without it a manager can still set them, but not have them found. */
  markers?: MarkerService;
  logos?: LogoStore;
  /** Lets managers change items. Without it nothing can be edited. */
  edit?: EditServices;
  /** The audio library. Without it there is nothing under /v1/music. */
  music?: MusicLibrary;
  /** The way in for devices outside the home. Managers steer it from here, so from home only. */
  outside?: OutsideEntrance;
  /** Playing on another device. Shared by both entrances; without it those routes do not exist. */
  remote?: RemoteHub;
  /** Waking Apple TVs. At home only; without it those routes do not exist. */
  wake?: WakeService;
  /** HomePods and AirPlay speakers the server plays to. */
  speakers?: SpeakerService;
  /** A manager's settings of the server and its first setup. Without it those routes do not exist. */
  settings?: { service: SettingsService; browser: FolderBrowser };
  /** Import folders, the Inbox and uploads. At home only; without it those routes do not exist. */
  imports?: Omit<ImportRouteDeps, "db" | "requireManager" | "conversion" | "now">;
  /** Ratings from OMDb, with the owner's key. Without it search has TMDB's ratings only. */
  omdb?: OmdbRatings;
  /** Search; made from the catalogue when left out, beyond the library with the edit's TMDB. */
  search?: { service: SearchService; outside: OutsideSearch };
  /** Apple's push service. Without it nothing is pushed, and its routes say so. */
  push?: PushService;
  /** The households that share the server. Made from the catalogue when left out. */
  households?: Households;
  /** Keeps guest households to their caps; shared by both entrances. */
  bandwidth?: Bandwidth;
  /** What is watched, when and by whom. Made from the catalogue when left out; shared by both. */
  stats?: Statistics;
  /** How full the caches and the drive are, for the server's statistics. */
  storage?: () => Record<string, number | null>;
  /** Changed in place when a manager renames the server. */
  serverName: string;
  version: string;
  isScanning: () => boolean;
  now?: () => number;
}

export interface AppEnv {
  /** What the outside entrance knows about the request. Only there on the app it serves. */
  Bindings: { outside?: OutsideRequest; incoming?: IncomingMessage };
  Variables: {
    device: Device;
    /** What the device may see; null for a device without limits. */
    kids: KidsView | null;
  };
}

export type Ctx = Context<AppEnv>;

type ErrorCode =
  | "invalid_request"
  | "unauthorized"
  | "device_revoked"
  | "forbidden"
  | "not_found"
  | "conflict"
  | "kids_confirmation"
  | "kids_mode"
  | "gone"
  | "range_not_satisfiable"
  | "rate_limited"
  | "unavailable"
  | "internal";

const STATUS = {
  invalid_request: 400,
  unauthorized: 401,
  device_revoked: 401,
  forbidden: 403,
  not_found: 404,
  conflict: 409,
  kids_confirmation: 409,
  kids_mode: 403,
  gone: 410,
  range_not_satisfiable: 416,
  rate_limited: 429,
  unavailable: 503,
  internal: 500,
} as const satisfies Record<ErrorCode, number>;

/** A failure with a status and a message that can be shown to the family as it is. */
export class ApiError extends Error {
  readonly code: ErrorCode;
  readonly extra: Record<string, unknown>;

  constructor(code: ErrorCode, message: string, extra: Record<string, unknown> = {}) {
    super(message);
    this.code = code;
    this.extra = extra;
  }
}

interface ProfileRow {
  id: string;
  name: string;
  color: string;
  avatar: string | null;
  kids_json: string | null;
  subtitles_json: string | null;
  playback_json: string | null;
  skipping_json: string | null;
}

interface Profile {
  id: string;
  name: string;
  color: string;
  avatar: string | null;
  kids: KidsSettings | null;
  subtitles: SubtitlePreferences;
  playback: PlaybackPreferences;
  skipping: SkipPreferences;
}

const toProfile = (row: ProfileRow): Profile => ({
  id: row.id,
  name: row.name,
  color: row.color,
  avatar: row.avatar,
  kids: readKids(row.kids_json),
  subtitles: readSubtitlePreferences(row.subtitles_json),
  playback: readPlaybackPreferences(row.playback_json, row.kids_json !== null),
  skipping: readSkipPreferences(row.skipping_json),
});

/** Reads `playback` from a request onto what a viewer had chosen. */
function playbackPreferences(value: unknown, before: string | null): string {
  try {
    return storePlayback(before, value);
  } catch (error) {
    if (error instanceof PlaybackPreferencesError) {
      throw new ApiError("invalid_request", error.message);
    }
    throw error;
  }
}

/** Reads `skipping` from a request onto what a viewer had. */
function skipPreferences(value: unknown, before: string | null): string {
  try {
    return JSON.stringify(mergeSkipPreferences(readSkipPreferences(before), value));
  } catch (error) {
    if (error instanceof SkipPreferencesError) {
      throw new ApiError("invalid_request", error.message);
    }
    throw error;
  }
}

/** Reads `subtitles` from a request onto what a viewer had. */
function subtitlePreferences(value: unknown, before: string | null): string {
  try {
    return JSON.stringify(mergeSubtitlePreferences(readSubtitlePreferences(before), value));
  } catch (error) {
    if (error instanceof SubtitlePreferencesError) {
      throw new ApiError("invalid_request", error.message);
    }
    throw error;
  }
}

const PROFILE_COLUMNS =
  "id, name, color, avatar, kids_json, subtitles_json, playback_json, skipping_json";

// Any id of this form, not a list of those there are: the pictures are in the apps, and a newer
// app may have more of them than this server knows. An app shows the letter for one it lacks.
const AVATAR = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const MAX_AVATAR = 40;

/** Reads `avatar` from a request: an avatar id, or null for the letter. */
function avatarId(value: unknown): string | null {
  if (value === null) return null;
  if (typeof value !== "string" || value.length > MAX_AVATAR || !AVATAR.test(value)) {
    throw new ApiError(
      "invalid_request",
      `"avatar" must be an avatar's id (words of a-z and 0-9 joined by dashes, at most ${String(MAX_AVATAR)} characters) or null.`,
    );
  }
  return value;
}

const MAX_KIDS_IDS = 5000;

/**
 * Reads `kids` from a request: null, or all lists. An id nothing has means nothing. An app from
 * before categories could be blocked does not send those: what is blocked stays blocked.
 */
export function kidsSettings(value: unknown, before: KidsSettings | null): KidsSettings | null {
  if (value === null) return null;
  if (typeof value !== "object" || Array.isArray(value)) {
    throw new ApiError("invalid_request", `"kids" must be an object or null.`);
  }
  const settings = {} as KidsSettings;
  for (const list of KIDS_LISTS) {
    let ids = (value as Record<string, unknown>)[list];
    if (list === "blockedCategoryIds" && ids === undefined) ids = before?.blockedCategoryIds ?? [];
    if (
      !Array.isArray(ids) ||
      ids.length > MAX_KIDS_IDS ||
      !ids.every((id) => typeof id === "string" && id !== "" && id.length <= 64)
    ) {
      throw new ApiError("invalid_request", `"kids.${list}" must be a list of ids.`);
    }
    settings[list] = [...new Set(ids as string[])];
  }
  return settings;
}

interface AssetRow {
  id: string;
  rel_path: string;
  size: number;
  mtime_ms: number;
  revision: string;
  container: string | null;
  available: number;
  source_path: string;
  source_available: number;
}

/** The largest thing a device sends: a kids viewer's four lists, or a long playlist. */
const MAX_BODY = 2 * 1024 * 1024;
/** Before a device has a credential, and where a request is only a word or two. */
const MAX_SMALL_BODY = 16 * 1024;

/** The body as text, refused as soon as it is too long. */
async function bodyText(c: Ctx, most: number): Promise<string> {
  const tooLong = (): ApiError => new ApiError("invalid_request", "The request body is too large.");
  if (Number(c.req.header("Content-Length") ?? "0") > most) throw tooLong();
  const body = c.req.raw.body as ReadableStream<Uint8Array> | null;
  const parts: Uint8Array[] = [];
  let size = 0;
  if (body) {
    for await (const part of body) {
      size += part.byteLength;
      if (size > most) throw tooLong();
      parts.push(part);
    }
  }
  return Buffer.concat(parts).toString("utf8");
}

export async function readBody(c: Ctx, most = MAX_BODY): Promise<Record<string, unknown>> {
  const sent = await bodyText(c, most);
  let body: unknown;
  try {
    body = JSON.parse(sent);
  } catch {
    throw new ApiError("invalid_request", "The request body is not valid JSON.");
  }
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    throw new ApiError("invalid_request", "The request body must be a JSON object.");
  }
  return body as Record<string, unknown>;
}

function text(body: Record<string, unknown>, key: string, maxLength = 200): string {
  const value = body[key];
  if (typeof value !== "string" || value.trim() === "" || value.length > maxLength) {
    throw new ApiError("invalid_request", `"${key}" must be a non-empty string.`);
  }
  return value;
}

function oneOf<T extends string>(
  body: Record<string, unknown>,
  key: string,
  allowed: readonly T[],
): T {
  const value = body[key];
  if (typeof value !== "string" || !allowed.includes(value as T)) {
    throw new ApiError("invalid_request", `"${key}" must be one of: ${allowed.join(", ")}.`);
  }
  return value as T;
}

function wholeNumber(body: Record<string, unknown>, key: string): number {
  const value = body[key];
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
    throw new ApiError("invalid_request", `"${key}" must be a number that is not negative.`);
  }
  return Math.round(value);
}

/** Reads one cookie from a `Cookie` header. */
function cookieValue(header: string | undefined, name: string): string | undefined {
  for (const part of (header ?? "").split(";")) {
    const separator = part.indexOf("=");
    if (separator !== -1 && part.slice(0, separator).trim() === name) {
      return part.slice(separator + 1).trim();
    }
  }
  return undefined;
}

/** @param scope the kids viewer the cursor is for; left out for a device without limits */
function encodeCursor(
  serverId: string,
  position: { revision: number; id: string },
  scope: string,
): string {
  return Buffer.from(
    JSON.stringify([serverId, position.revision, position.id, ...(scope === "" ? [] : [scope])]),
  ).toString("base64url");
}

function decodeCursor(
  serverId: string,
  cursor: string | undefined,
): { revision: number; id: string; scope: string } | null | "reset" {
  if (cursor === undefined || cursor === "") return null;
  try {
    const parsed: unknown = JSON.parse(Buffer.from(cursor, "base64url").toString("utf8"));
    if (!Array.isArray(parsed)) return "reset";
    const [server, revision, id, scope = ""] = parsed as unknown[];
    if (server !== serverId || typeof revision !== "number" || typeof id !== "string")
      return "reset";
    return typeof scope === "string" ? { revision, id, scope } : "reset";
  } catch {
    return "reset";
  }
}

/**
 * @param entrance "outside" makes the app for the outside entrance: only for requests that
 *   entrance let through, and only the routes in `OUTSIDE_ROUTES`
 */
export function createApp(deps: AppDeps, entrance: "home" | "outside" = "home"): Hono<AppEnv> {
  const { db, devices, items, progress } = deps;
  const now = deps.now ?? Date.now;
  const app = new Hono<AppEnv>();

  let serverId = db.getMeta("server_id");
  if (serverId === undefined) {
    serverId = randomUUID();
    db.setMeta("server_id", serverId);
  }
  const catalogueId = serverId;

  const serverInfo = (): Record<string, unknown> => ({
    id: catalogueId,
    name: deps.serverName,
    version: deps.version,
    apiVersion: API_VERSION,
    minAppVersion: MIN_APP_VERSION,
    claimed: devices.isClaimed,
    claim: devices.claimMode,
  });

  app.onError((error, c) => {
    // A device that was removed while it asked: from outside that looks like any refusal.
    if (
      entrance === "outside" &&
      error instanceof AuthError &&
      (error.code === "unauthorized" || error.code === "device_revoked")
    ) {
      return c.body(null, 404);
    }
    if (error instanceof AuthError) {
      if (error.retryAfterSeconds !== null)
        c.header("Retry-After", String(error.retryAfterSeconds));
      return c.json({ error: { code: error.code, message: error.message } }, STATUS[error.code]);
    }
    if (error instanceof BusyError) {
      c.header("Retry-After", "10");
      return c.json(
        { error: { code: "rate_limited", message: "The server is busy. Try again in a moment." } },
        429,
      );
    }
    if (error instanceof ApiError) {
      return c.json(
        { error: { code: error.code, message: error.message }, ...error.extra },
        STATUS[error.code],
      );
    }
    // The pattern: a path can hold whatever was sent.
    const route = matchedRoutes(c).find((one) => one.method !== "ALL")?.path ?? null;
    log.error("Request failed", { route, error: errorMessage(error) });
    return c.json(
      { error: { code: "internal", message: "Something went wrong on the server." } },
      500,
    );
  });

  app.notFound((c) =>
    c.json({ error: { code: "not_found", message: "There is nothing at this address." } }, 404),
  );

  if (entrance === "home") {
    // Again for every request: a manager can change the addresses while the server runs.
    const names = (): ReadonlySet<string> => {
      const addresses = deps.addresses?.(catalogueId) ?? { home: [], remote: [] };
      return new Set([...addresses.home, ...addresses.remote].map((one) => new URL(one).hostname));
    };
    app.use(
      "*",
      homeGuard({
        names,
        relays: new Set(deps.relays ?? []),
        refusal: (message) => new ApiError("forbidden", message),
      }),
    );
  } else {
    app.use(
      "*",
      outsideGuard({
        db,
        playback: deps.playback,
        refusal: (code, message) => new ApiError(code, message),
      }),
    );
  }

  // ---- Open routes: what a device needs before it has a credential. ----

  app.get("/v1/server", (c) => c.json(serverInfo()));

  app.post("/v1/pairing/claim", async (c) => {
    const peer = peerAddress(c);
    // Whoever is first gets it, so nobody from far away is.
    if (devices.claimMode === "open" && peer !== null && !isNearby(peer)) {
      throw new ApiError("forbidden", "Set this server up from the home network.");
    }
    const body = await readBody(c, MAX_SMALL_BODY);
    const result = devices.claim(
      devices.claimMode === "open" && body["setupSecret"] === undefined
        ? null
        : text(body, "setupSecret"),
      text(body, "deviceName"),
      oneOf(body, "platform", PLATFORMS),
    );
    log.info("The server was claimed by its first manager", { device: result.device.id });
    // A fresh server: the app goes on with the first setup.
    const setup = deps.settings?.service.setup();
    return c.json(setup ? { ...result, setup } : result, 201);
  });

  app.post("/v1/pairing/requests", async (c) => {
    const body = await readBody(c, MAX_SMALL_BODY);
    const started = devices.startPairing(
      text(body, "deviceName"),
      oneOf(body, "platform", PLATFORMS),
      addressKey(peerAddress(c)),
    );
    // The household's admins are told, so the code can be typed in while it is on screen.
    if (deps.push) {
      void deps.push.toDevices(
        devices
          .list(OWNER_HOUSEHOLD)
          .filter(
            (one) =>
              one.revokedAt === null && one.kidsProfileId === null && managesHousehold(one.access),
          )
          .map((one) => one.id),
        {
          title: "A device wants to join Lobby",
          body: "Open Lobby to let it in.",
          data: { kind: "pairing", serverId: catalogueId },
        },
      );
    }
    return c.json(started, 201);
  });

  app.post("/v1/pairing/requests/:id/collect", async (c) => {
    const body = await readBody(c, MAX_SMALL_BODY);
    const result = devices.collect(c.req.param("id"), text(body, "pollSecret"));
    if (result.status === "approved") log.info("A device was paired", { device: result.device.id });
    return c.json(result, result.status === "approved" ? 200 : 202);
  });

  // An AirPlay receiver has no credential: what it fetches under a pass is checked as the
  // device that asked for the pass, below.
  const passes = new AirPlayPasses(devices, now);
  registerAirPlayRoutes(app, { passes });

  // ---- Everything below needs a paired device. ----

  app.use("/v1/*", async (c, next) => {
    const passed = passes.deviceOf(c.req.raw);
    if (passed) {
      c.set("device", passed);
      await next();
      return;
    }
    const header = c.req.header("Authorization");
    const bearer = header?.startsWith("Bearer ") ? header.slice(7).trim() : undefined;
    const token = bearer ?? cookieValue(c.req.header("Cookie"), DEVICE_COOKIE);
    if (!token) throw new AuthError("unauthorized", "This device is not paired with the server.");
    c.set("device", devices.authenticate(token));
    await next();
  });

  const households = deps.households ?? new Households(db, devices, invitesOf(db, now), now);
  deps.households = households;
  deps.bandwidth ??= new Bandwidth();
  // Right behind the credential: what is another household's is not there, not even to count.
  app.use(
    "/v1/*",
    householdGuard({
      db,
      bandwidth: deps.bandwidth,
      notFound: () => new ApiError("not_found", "There is nothing here for this device."),
      forbidden: () => new ApiError("forbidden", "This device's role does not allow this."),
    }),
  );

  const categories = new Categories(db);
  const limits = kidsLimits(db);
  // When and what (docs/kids-control.md): one for the catalogue, shared by both entrances.
  const control = kidsControl(db, devices, now);
  // Away: the outside entrance, or the tailnet, which can be anywhere.
  const isAway = (c: Ctx): boolean => entrance === "outside" || isTailnet(peerAddress(c));
  const hub = deps.remote;
  if (hub && !hub.kids) {
    hub.kids = {
      state: (profileId, deviceId, outside) =>
        control.state(profileId, deviceId, control.isAway(deviceId, outside)),
      allowsVideo: (state, itemId) =>
        state.video === "all" ||
        (state.video === "titles" &&
          db.get(
            `with recursive up (id, parent_id) as (
               select id, parent_id from item where id = ?
               union select item.id, item.parent_id from item join up on item.id = up.parent_id)
             select 1 as x from up where id in (select value from json_each(?)) limit 1`,
            [itemId, JSON.stringify(state.titles)],
          ) !== undefined),
      lock: (profileId, deviceId) => control.lockWish(profileId, deviceId).wanted,
      // As the kids guard decides for a song this device asks for (kids/guard.ts).
      listening: (profileId, deviceId) => {
        const plan = control.plan(profileId);
        if (!plan.music) return null;
        const state = control.state(profileId, deviceId, control.isAway(deviceId, false));
        return { allowed: state.listening, sources: plan.musicSourceIds };
      },
    };
    const listening = hub.kids.listening;
    if (deps.speakers && listening) deps.speakers.listen = listening;
    control.on((event) => {
      if (event.type === "changed") {
        hub.kidsChanged();
        return;
      }
      const { request } = event;
      const described = describeRequest(db, control, request);
      const about = `kidsRequest ${request.id}`;
      hub.tellDevices(
        control.deciders(request.profileId).map((one) => one.id),
        event.type === "request" ? "kidsRequest" : "kidsRequestClosed",
        { request: described },
        about,
      );
      // The child's own device hears what came of it.
      if (event.type === "requestClosed") {
        hub.tellDevices([request.deviceId], "kidsRequest", { request }, about);
      }
      // And the grown-ups' phones in their pockets, when Apple's push service is set up.
      if (event.type === "request" && deps.push) {
        const viewer = described["viewer"] as { name?: string } | null;
        const title = described["title"] as { title?: string } | null;
        const name = viewer?.name ?? "A child";
        void deps.push.toDevices(
          control.deciders(request.profileId).map((one) => one.id),
          {
            title: name,
            body: title?.title
              ? `${name} wants to watch ${title.title}.`
              : `${name} wants to open Lobby.`,
            category: "LOBBY_KIDS_QUESTION",
            threadId: `kids-${request.profileId}`,
            data: { kind: "kidsRequest", requestId: request.id, serverId: catalogueId },
            expiresAt: request.expiresAt,
          },
        );
      }
    });
    control.start();
  }
  // Right behind the credential, so nothing below ever sees a kids device ask for too much.
  app.use(
    "/v1/*",
    kidsGuard({
      db,
      showsLogo: (view, logoId) =>
        limits
          .categories(view, categories.view())
          .groups.some((group) =>
            [group, ...group.entries].some((entry) => entry.logo?.id === logoId),
          ),
      notFound: () => new ApiError("not_found", "There is nothing here for this device."),
      control,
      isAway,
      modeRefusal: (state) =>
        new ApiError("kids_mode", "This is not for now.", {
          reason: "kids_mode",
          now: state,
        }),
    }),
  );

  const stats = deps.stats ?? new Statistics(db, { now });
  deps.stats = stats;
  // What is sent of films and songs, by household and road. Counted as it goes out, so a film
  // that is stopped halfway counts for half.
  app.use("/v1/*", async (c, next) => {
    await next();
    const path = c.req.path;
    const media =
      (path.startsWith("/v1/assets/") &&
        (path.endsWith("/content") || path.includes("/prepared/"))) ||
      (path.startsWith("/v1/music/tracks/") &&
        (path.endsWith("/content") || path.includes("/copies/")));
    if (!media || c.req.method !== "GET" || !c.res.body || c.res.status >= 300) return;
    const { householdId } = c.get("device");
    const road = roadOf(c);
    const response = c.res;
    let bytes = 0;
    let counted = false;
    const count = (): void => {
      if (counted) return;
      counted = true;
      try {
        stats.noteSent(householdId, road, bytes);
      } catch (error) {
        log.warn("Could not count what was sent", { error: errorMessage(error) });
      }
    };
    const reader = (response.body as ReadableStream<Uint8Array>).getReader();
    const body = new ReadableStream<Uint8Array>(
      {
        async pull(controller) {
          let read: Awaited<ReturnType<typeof reader.read>>;
          try {
            read = await reader.read();
          } catch (error) {
            count();
            throw error;
          }
          const { done, value } = read;
          if (done) {
            count();
            controller.close();
            return;
          }
          bytes += value.byteLength;
          controller.enqueue(value);
        },
        // Stopped by the player: what went is counted all the same.
        async cancel(reason) {
          count();
          await reader.cancel(reason);
        },
      },
      { highWaterMark: 0 },
    );
    c.res = new Response(body, { status: response.status, headers: response.headers });
  });
  // Whether a sitting that follows was sent as it is or prepared.
  app.use("/v1/assets/:id/playback", async (c, next) => {
    await next();
    if (c.req.method !== "POST" || c.res.status >= 300) return;
    try {
      const reply = (await c.res.clone().json()) as { mode?: unknown };
      if (reply.mode === "direct" || reply.mode === "prepared") {
        stats.notePlayback(c.get("device").id, c.req.param("id"), reply.mode);
      }
    } catch (error) {
      // The answer goes out all the same; the sitting is then "unknown".
      log.warn("Could not note how a file is played", { error: errorMessage(error) });
    }
  });
  registerKidsControlRoutes(app, { db, control, isAway });

  // ---- Push notifications ----

  const push = deps.push;
  const pushRefusal = (error: unknown): never => {
    if (error instanceof PushError) throw new ApiError("invalid_request", error.message);
    throw error;
  };
  const noPush = (): ApiError =>
    new ApiError("unavailable", "Push notifications are not set up on this server.");

  // How this device registers: through the relay (with a ticket the box signed), directly, or not.
  app.get("/v1/me/push", (c) => c.json(push?.registration() ?? { mode: "off" }));

  app.put("/v1/me/push", async (c) => {
    const body = await readBody(c, MAX_SMALL_BODY);
    if (!push || push.status().mode === "off") {
      log.warn("A device wanted to register for push, but push is off on this server");
      throw noPush();
    }
    const environment = oneOf(body, "environment", ENVIRONMENTS);
    const deviceId = c.get("device").id;
    try {
      if (push.mode === "relay") {
        // The relay's handle, never the token: this server never learns where Apple reaches it.
        const { handle, key } = body;
        if (typeof handle !== "string" || typeof key !== "string") {
          throw new PushError(
            `This server pushes through the relay: send "handle" and "key" (GET /v1/me/push).`,
          );
        }
        push.setRelayHandle(deviceId, handle, key, environment);
      } else {
        const token = body["token"];
        push.setToken(deviceId, typeof token === "string" ? token.toLowerCase() : "", environment);
      }
    } catch (error) {
      pushRefusal(error);
    }
    return c.body(null, 204);
  });

  app.delete("/v1/me/push", (c) => {
    push?.removeToken(c.get("device").id);
    return c.body(null, 204);
  });

  // Whether pushes go out; the key itself is set in the config file and never told.
  app.get("/v1/settings/push", (c) => {
    requireManager(c, "see whether push notifications are set up");
    return c.json(push?.status() ?? { configured: false });
  });

  // Each household has its own code for grown-ups.
  const kidsCodes = new Map<string, KidsCode>();
  const kidsCodeOf = (c: Ctx): KidsCode => {
    const { householdId } = c.get("device");
    let code = kidsCodes.get(householdId);
    if (!code) {
      code = new KidsCode(db, now, kidsCodeKey(householdId));
      kidsCodes.set(householdId, code);
    }
    return code;
  };

  // A server admin: the server, its library and its households. Passed on to every part of
  // the server that is the server's own.
  const requireManager = (c: Ctx, action: string): Device => {
    const device = c.get("device");
    if (device.access !== "admin") {
      throw new ApiError("forbidden", `Only a server admin can ${action}.`);
    }
    return device;
  };
  // A household admin, or a server admin: their own household's viewers, kids and devices.
  const requireHouseholdAdmin = (c: Ctx, action: string): Device => {
    const device = c.get("device");
    if (!managesHousehold(device.access)) {
      throw new ApiError("forbidden", `Only an admin of this household can ${action}.`);
    }
    return device;
  };
  /** Throws unless `manager` ranks at least as high as the device it changes. */
  const outranks = (manager: Device, deviceId: string): void => {
    const target = devices.find(deviceId);
    if (target && rank(target.access) > rank(manager.access)) {
      throw new ApiError("forbidden", "Only a server admin can change a server admin's device.");
    }
  };

  // Before the media routes: it also notes media requests, so nothing is prepared ahead meanwhile.
  if (deps.downloads) registerDeviceDownloadRoutes(app, { downloads: deps.downloads, devices });
  // Also before the media routes, for the same reason.
  if (deps.conversion) registerConversionRoutes(app, { conversion: deps.conversion });
  if (deps.markers) registerMarkerRoutes(app, { db, markers: deps.markers, now });

  app.get("/v1/me", (c) => {
    const device = c.get("device");
    const isOwner = device.householdId === OWNER_HOUSEHOLD;
    const setup = device.access === "admin" && isOwner ? deps.settings?.service.setup() : undefined;
    const household = households.find(device.householdId);
    return c.json({
      device,
      // Whose server this is, and whose household the device is in: the apps say both.
      household: household
        ? { id: household.id, name: household.name, owner: household.owner }
        : null,
      // The addresses are for paired devices: the open /v1/server does not carry them.
      server: {
        ...serverInfo(),
        addresses: deps.addresses?.(catalogueId) ?? { home: [], remote: [] },
        // For a manager only, and only from home: outside it is no business of anyone's.
        ...(setup && entrance === "home" ? { setup } : {}),
      },
    });
  });

  if (deps.remote) {
    registerRemoteRoutes(app, {
      hub: deps.remote,
      devices,
      outside: entrance === "outside",
    });
  }

  app.get("/v1/status", (c) => {
    requireManager(c, "see the server's status");
    const sources = db.all<Record<string, string | number | null>>(
      `select source.id, source.name, source.hint, source.available, source.last_scan_started_at,
         source.last_scan_finished_at, (select count(*) from asset where source_id = source.id) as files
       from source order by source.name`,
    );
    const files = db.get<Record<string, number>>(
      `select count(*) as total,
         coalesce(sum(state = 'discovered'), 0) as waiting,
         coalesce(sum(state = 'failed'), 0) as failed,
         coalesce(sum(available = 0), 0) as missing
       from asset`,
    );
    const playability: Record<string, number> = {
      direct: 0,
      remux: 0,
      transcode: 0,
      unsupported: 0,
    };
    for (const row of db.all<{ playability: string; n: number }>(
      "select playability, count(*) as n from asset where state = 'probed' group by playability",
    )) {
      playability[row.playability] = row.n;
    }
    const counts = db.get<Record<string, number>>(
      `select coalesce(sum(kind = 'movie'), 0) as movies, coalesce(sum(kind = 'show'), 0) as shows,
         coalesce(sum(kind = 'episode'), 0) as episodes, coalesce(sum(kind = 'extra'), 0) as extras,
         coalesce(sum(kind = 'personal'), 0) as personal,
         coalesce(sum(match_status = 'needs_review'), 0) as needsReview,
         coalesce(sum(match_status = 'unmatched' and kind in ('movie', 'show')), 0) as unmatched
       from item`,
    );
    return c.json({
      scanning: deps.isScanning(),
      sources: sources.map((source) => ({
        id: source["id"],
        name: source["name"],
        hint: source["hint"],
        available: source["available"] === 1,
        lastScanStartedAt: source["last_scan_started_at"],
        lastScanFinishedAt: source["last_scan_finished_at"],
        files: source["files"],
      })),
      files,
      playability,
      items: counts,
    });
  });

  // ---- Pairing and devices ----

  app.get("/v1/pairing/requests", (c) => {
    const manager = requireHouseholdAdmin(c, "see devices waiting to be paired");
    const isOwner = manager.householdId === OWNER_HOUSEHOLD;
    const isAdmin = manager.access === "admin";
    return c.json({
      // At home is the owner's home: a guest household's devices pair from outside.
      requests: isOwner ? devices.waiting() : [],
      // Let in at home by a household admin, waiting for a server admin; and those turned away.
      awaitingAdmin: isOwner ? devices.awaitingAdmin() : [],
      refused: isOwner && !isAdmin ? devices.refusedByAdmin() : [],
      // Apart from the others: nothing that approves those can approve these.
      outsideRequests:
        deps.outside?.pairing
          .waiting({ householdId: manager.householdId, access: manager.access })
          .map((one) => ({
            ...one,
            householdName: households.find(one.householdId)?.name ?? null,
          })) ?? [],
    });
  });

  app.post("/v1/pairing/approve", async (c) => {
    const manager = requireHouseholdAdmin(c, "approve devices");
    if (manager.householdId !== OWNER_HOUSEHOLD) {
      throw new ApiError(
        "forbidden",
        "Devices of this household pair from outside: open a window for one.",
      );
    }
    const body = await readBody(c);
    const requestId = body["requestId"] === undefined ? null : text(body, "requestId", 64);
    // One a household admin let in: a server admin's yes, without anything else.
    if (requestId !== null && devices.awaitingAdmin().some((one) => one.id === requestId)) {
      if (manager.access !== "admin") {
        throw new ApiError("forbidden", "Only a server admin can let this device in now.");
      }
      const decided = devices.decideAwaiting(requestId, true);
      log.info("A server admin let a device in", { by: manager.id });
      return c.json({ ...decided, awaitsAdmin: false });
    }
    // "access" now, "role" from an older app; "manager" was a server admin.
    const access: Access =
      body["access"] === undefined
        ? accessFrom(oneOf(body, "role", ROLES))
        : oneOf(body, "access", ACCESS);
    if (rank(access) > rank(manager.access)) {
      throw new ApiError("forbidden", "Only a server admin can make a server admin.");
    }
    const needsAdmin = manager.access !== "admin" && households.requiresAdmin(OWNER_HOUSEHOLD);
    const approved =
      requestId === null
        ? devices.approve(text(body, "code", 20), access, manager.id, needsAdmin)
        : devices.approveRequest(requestId, access, manager.id, needsAdmin);
    log.info("A manager approved a device", { by: manager.id, access });
    return c.json({ ...approved, role: legacyRole(approved.access) });
  });

  // A server admin says no to one a household admin let in; its household admin is told.
  app.delete("/v1/pairing/requests/:id", (c) => {
    const manager = requireManager(c, "turn a device away");
    devices.decideAwaiting(c.req.param("id"), false);
    log.info("A server admin turned a device away", { by: manager.id });
    return c.body(null, 204);
  });

  app.get("/v1/devices", (c) => {
    const manager = requireHouseholdAdmin(c, "see the paired devices");
    return c.json({ devices: devices.list(manager.householdId), currentDeviceId: manager.id });
  });

  app.delete("/v1/devices/:id", (c) => {
    const manager = requireHouseholdAdmin(c, "remove devices");
    outranks(manager, c.req.param("id"));
    devices.revoke(c.req.param("id"));
    deps.outside?.recheck();
    deps.remote?.recheck();
    log.info("A manager removed a device", { by: manager.id, device: c.req.param("id") });
    return c.body(null, 204);
  });

  app.patch("/v1/devices/:id", async (c) => {
    const manager = requireHouseholdAdmin(c, "change devices");
    const body = await readBody(c);
    outranks(manager, c.req.param("id"));
    const profileId = body["kidsProfileId"];
    const allowOutside = body["allowOutside"];
    const access = body["access"] === undefined ? undefined : oneOf(body, "access", ACCESS);
    // Up to their own level: only a server admin makes a server admin.
    if (access !== undefined && rank(access) > rank(manager.access)) {
      throw new ApiError("forbidden", "Only a server admin can make a server admin.");
    }
    const remote: { isTarget?: boolean | null; allowRemote?: boolean; remoteOutside?: boolean } =
      {};
    if (body["isTarget"] !== undefined) {
      if (body["isTarget"] !== null && typeof body["isTarget"] !== "boolean") {
        throw new ApiError("invalid_request", `"isTarget" must be true, false or null.`);
      }
      remote.isTarget = body["isTarget"];
    }
    for (const key of ["allowRemote", "remoteOutside"] as const) {
      const value = body[key];
      if (value === undefined) continue;
      if (typeof value !== "boolean") {
        throw new ApiError("invalid_request", `"${key}" must be true or false.`);
      }
      remote[key] = value;
    }
    const others =
      allowOutside !== undefined || access !== undefined || Object.keys(remote).length > 0;
    if (
      profileId !== null &&
      (typeof profileId !== "string" || profileId === "") &&
      // Left out is only fine when another is there.
      !(profileId === undefined && others)
    ) {
      throw new ApiError("invalid_request", `"kidsProfileId" must be a viewer's id or null.`);
    }
    if (allowOutside !== undefined && typeof allowOutside !== "boolean") {
      throw new ApiError("invalid_request", `"allowOutside" must be true or false.`);
    }
    const id = c.req.param("id");
    const before = devices.find(id)?.kidsProfileId ?? null;
    const device = db.transaction(() => {
      let changed = devices.find(id);
      if (profileId !== undefined) changed = devices.bindToKids(id, profileId);
      if (allowOutside !== undefined) changed = devices.setAllowOutside(id, allowOutside);
      if (Object.keys(remote).length > 0) changed = devices.setRemote(id, remote);
      if (access !== undefined) changed = devices.setAccess(id, access);
      return changed;
    });
    // While it was limited, it was not told of everything this viewer watched.
    if (profileId !== undefined && before !== null && before !== profileId) progress.touch(before);
    deps.outside?.recheck();
    deps.remote?.recheck();
    log.info("A manager changed a device", { by: manager.id, device: id });
    return c.json(device);
  });

  // ---- Profiles ----

  const profileById = (id: string): ProfileRow => {
    const row = db.get<ProfileRow>(
      `select ${PROFILE_COLUMNS} from profile where id = ? and deleted_at is null`,
      [id],
    );
    if (!row) throw new ApiError("not_found", "There is no such viewer.");
    return row;
  };

  const refuseWhileBound = (profileId: string): void => {
    const bound = devices.boundTo(profileId);
    if (bound.length === 0) return;
    throw new ApiError("conflict", `First say whose device this is instead: ${bound.join(", ")}.`);
  };

  app.get("/v1/profiles", (c) => {
    const { kidsProfileId: own, householdId } = c.get("device");
    return c.json({
      profiles: db
        .all<ProfileRow>(
          `select ${PROFILE_COLUMNS} from profile where deleted_at is null and household_id = ?
           order by created_at`,
          [householdId],
        )
        .filter((row) => own === null || row.id === own)
        .map(toProfile),
    });
  });

  app.post("/v1/profiles", async (c) => {
    const manager = requireHouseholdAdmin(c, "add viewers");
    const body = await readBody(c);
    const count =
      db.get<{ n: number }>(
        "select count(*) as n from profile where deleted_at is null and household_id = ?",
        [manager.householdId],
      )?.n ?? 0;
    const profile: ProfileRow = {
      id: randomUUID(),
      name: text(body, "name", 40).trim(),
      color:
        body["color"] === undefined
          ? (PROFILE_COLORS[count % PROFILE_COLORS.length] ?? "blue")
          : oneOf(body, "color", PROFILE_COLORS),
      avatar: body["avatar"] === undefined ? null : avatarId(body["avatar"]),
      kids_json: null,
      subtitles_json:
        body["subtitles"] === undefined ? null : subtitlePreferences(body["subtitles"], null),
      playback_json:
        body["playback"] === undefined ? null : playbackPreferences(body["playback"], null),
      skipping_json:
        body["skipping"] === undefined ? null : skipPreferences(body["skipping"], null),
    };
    const kids = body["kids"] === undefined ? null : kidsSettings(body["kids"], null);
    if (kids) profile.kids_json = JSON.stringify(kids);
    db.run(
      `insert into profile (id, name, color, avatar, kids_json, subtitles_json, playback_json, skipping_json, created_at, household_id)
       values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        profile.id,
        profile.name,
        profile.color,
        profile.avatar,
        profile.kids_json,
        profile.subtitles_json,
        profile.playback_json,
        profile.skipping_json,
        now(),
        manager.householdId,
      ],
    );
    return c.json(toProfile(profile), 201);
  });

  app.patch("/v1/profiles/:id", async (c) => {
    requireHouseholdAdmin(c, "change viewers");
    const body = await readBody(c);
    // After the wait for the body: what is written back must be what is there now.
    const profile = profileById(c.req.param("id"));
    if (body["name"] !== undefined) profile.name = text(body, "name", 40).trim();
    if (body["color"] !== undefined) profile.color = oneOf(body, "color", PROFILE_COLORS);
    if (body["avatar"] !== undefined) profile.avatar = avatarId(body["avatar"]);
    if (body["subtitles"] !== undefined) {
      profile.subtitles_json = subtitlePreferences(body["subtitles"], profile.subtitles_json);
    }
    if (body["playback"] !== undefined) {
      profile.playback_json = playbackPreferences(body["playback"], profile.playback_json);
    }
    if (body["skipping"] !== undefined) {
      profile.skipping_json = skipPreferences(body["skipping"], profile.skipping_json);
    }
    if (body["kids"] !== undefined) {
      const kids = kidsSettings(body["kids"], readKids(profile.kids_json));
      // Never by itself: a child's device would suddenly have everything.
      if (kids === null && profile.kids_json !== null) refuseWhileBound(profile.id);
      profile.kids_json = kids === null ? null : JSON.stringify(kids);
    }
    db.transaction(() => {
      db.run(
        "update profile set name = ?, color = ?, avatar = ?, kids_json = ?, subtitles_json = ?, playback_json = ?, skipping_json = ? where id = ?",
        [
          profile.name,
          profile.color,
          profile.avatar,
          profile.kids_json,
          profile.subtitles_json,
          profile.playback_json,
          profile.skipping_json,
          profile.id,
        ],
      );
      // What is no longer blocked need not stay blocked when its files come back.
      db.run(
        `delete from kids_blocked_trace where profile_id = ? and owner_id not in (
           select value from json_each(coalesce(?, '{}'), '$.blockedItemIds'))`,
        [profile.id, profile.kids_json],
      );
      db.run(
        `delete from kids_blocked_gone where profile_id = ? and item_id not in (
           select value from json_each(coalesce(?, '{}'), '$.blockedItemIds'))`,
        [profile.id, profile.kids_json],
      );
    });
    return c.json(toProfile(profile));
  });

  // Not only for managers: whoever may watch as a viewer may give them another picture, children
  // too (the kids guard keeps their device to its own viewer). It reads the picture and nothing
  // else.
  app.put("/v1/profiles/:id/avatar", async (c) => {
    const body = await readBody(c, MAX_SMALL_BODY);
    const avatar = avatarId(body["avatar"]);
    const profile = profileById(c.req.param("id"));
    db.run("update profile set avatar = ? where id = ?", [avatar, profile.id]);
    return c.json(toProfile({ ...profile, avatar }));
  });

  // Like the picture: whoever watches as a viewer chooses how their subtitles look, children
  // too. Only these preferences change.
  app.put("/v1/profiles/:id/subtitles", async (c) => {
    const body = await readBody(c, MAX_SMALL_BODY);
    const profile = profileById(c.req.param("id"));
    const subtitles = subtitlePreferences(body, profile.subtitles_json);
    db.run("update profile set subtitles_json = ? where id = ?", [subtitles, profile.id]);
    return c.json(toProfile({ ...profile, subtitles_json: subtitles }));
  });

  // What happens when something ends. Whoever watches as an ordinary viewer chooses it; a kids
  // viewer's is chosen by the grown-ups (a manager), and the child's own device gets 404 from
  // the kids guard. Only these preferences change.
  app.put("/v1/profiles/:id/playback", async (c) => {
    const body = await readBody(c, MAX_SMALL_BODY);
    const profile = profileById(c.req.param("id"));
    if (profile.kids_json !== null) {
      requireHouseholdAdmin(c, "change what happens at the end for a kids viewer");
    }
    const playback = playbackPreferences(body, profile.playback_json);
    db.run("update profile set playback_json = ? where id = ?", [playback, profile.id]);
    return c.json(toProfile({ ...profile, playback_json: playback }));
  });

  // Whoever watches as a viewer chooses what happens at intros and credits, but not a child: a
  // kids viewer's choice is set by a grown-up, from a device that is not the child's.
  app.put("/v1/profiles/:id/skipping", async (c) => {
    if (c.get("device").kidsProfileId !== null) {
      throw new ApiError("forbidden", "A grown-up chooses this for a kids viewer.");
    }
    const body = await readBody(c, MAX_SMALL_BODY);
    const profile = profileById(c.req.param("id"));
    const skipping = skipPreferences(body, profile.skipping_json);
    db.run("update profile set skipping_json = ? where id = ?", [skipping, profile.id]);
    return c.json(toProfile({ ...profile, skipping_json: skipping }));
  });

  app.delete("/v1/profiles/:id", (c) => {
    requireHouseholdAdmin(c, "remove viewers");
    const profile = profileById(c.req.param("id"));
    refuseWhileBound(profile.id);
    db.transaction(() => {
      db.run("delete from progress where profile_id = ?", [profile.id]);
      control.forget(profile.id);
      db.run("update profile set deleted_at = ? where id = ?", [now(), profile.id]);
    });
    return c.body(null, 204);
  });

  // ---- The way out of kids mode ----

  app.get("/v1/kids/code", (c) => c.json({ set: kidsCodeOf(c).isSet }));

  app.put("/v1/kids/code", async (c) => {
    requireHouseholdAdmin(c, "choose the code for grown-ups");
    const body = await readBody(c, MAX_SMALL_BODY);
    const code = body["code"];
    if (code !== null && (typeof code !== "string" || !KIDS_CODE.test(code))) {
      throw new ApiError("invalid_request", `"code" must be four digits or null.`);
    }
    const kidsCode = kidsCodeOf(c);
    await kidsCode.set(code);
    return c.json({ set: kidsCode.isSet });
  });

  app.post("/v1/kids/code/check", async (c) => {
    const body = await readBody(c, MAX_SMALL_BODY);
    const code = body["code"];
    if (typeof code !== "string" || !KIDS_CODE.test(code)) {
      throw new ApiError("invalid_request", `"code" must be four digits.`);
    }
    const kidsCode = kidsCodeOf(c);
    if (!kidsCode.isSet) throw new ApiError("conflict", "No code was chosen yet.");
    return c.json({ correct: await kidsCode.check(c.get("device").id, code) });
  });

  // ---- Library ----

  // The first sync is a few megabytes of JSON, a tenth of that compressed.
  app.use("/v1/library", compress());
  app.get("/v1/library", (c) => {
    const limitParam = Number(c.req.query("limit") ?? "500");
    if (!Number.isInteger(limitParam) || limitParam < 1 || limitParam > 1000) {
      throw new ApiError("invalid_request", `"limit" must be a whole number from 1 to 1000.`);
    }
    const decoded = decodeCursor(catalogueId, c.req.query("cursor"));
    const view = c.get("kids");
    const scope = view?.profileId ?? "";
    let after = decoded === "reset" ? null : decoded;
    // A device that had limits until now: it gets everything, and loses what is gone.
    if (!view && after && after.scope !== "") after = { revision: 0, id: "", scope: "" };
    const page = view
      ? items.kidsPage(view, after, after?.scope ?? "", limitParam)
      : items.page(after, limitParam);
    return c.json({
      items: page.items,
      // A client starting over has nothing to remove.
      removed: decoded === null || decoded === "reset" ? [] : page.removed,
      cursor: encodeCursor(catalogueId, page.next, scope),
      more: page.more,
      reset: decoded === "reset",
    });
  });

  registerCategoryRoutes(app, {
    db,
    categories,
    limits,
    logos: deps.logos,
    enricher: deps.edit?.enricher,
    chosen: deps.edit?.chosen,
    requireManager,
  });

  app.get("/v1/items/:id", (c) => {
    const view = c.get("kids");
    const [item] = items.read([c.req.param("id")], view);
    if (!item) throw new ApiError("not_found", "That title is no longer in the library.");
    return c.json({ item, children: items.children(item.id, view) });
  });

  if (deps.edit) {
    registerEditRoutes(app, {
      ...deps.edit,
      db,
      items,
      categories,
      now,
      requireManager,
    });
  }

  // ---- Progress ----

  app.get("/v1/profiles/:id/progress", (c) => {
    const profile = profileById(c.req.param("id"));
    const since = Number(c.req.query("since") ?? "0");
    if (!Number.isInteger(since) || since < 0) {
      throw new ApiError("invalid_request", `"since" must be a revision number.`);
    }
    // Read the revision first: a change made in between is then sent again next time, never lost.
    const revision = progress.revision;
    const view = c.get("kids");
    if (view) {
      // All of it every time: a title that is allowed again may have progress from long ago.
      const own = progress.list(profile.id, 0).filter((one) => view.items.has(one.itemId));
      return c.json({ progress: own, revision });
    }
    return c.json({ progress: progress.list(profile.id, since), revision });
  });

  const plays = new PlayLog(db, now);
  registerQueryRoutes(app, { db, items, plays, profile: profileById, now });
  const search = deps.search ?? {
    service: new SearchService(db, items, deps.omdb ?? null),
    outside: new OutsideSearch(() => deps.edit?.enricher.outside ?? null, deps.omdb ?? null, now),
  };
  registerSearchRoutes(app, {
    db,
    search: search.service,
    outside: search.outside,
    profile: profileById,
    now,
  });
  app.get("/v1/popular", (c) => {
    const viewers = c.req.query("viewers") ?? "all";
    if (viewers !== "all" && viewers !== "kids") {
      throw new ApiError("invalid_request", `"viewers" must be "all" or "kids".`);
    }
    const body = JSON.stringify(
      plays.popular(c.get("kids"), viewers === "kids", c.get("device").householdId),
    );
    const etag = `"${createHash("sha256").update(body).digest("hex").slice(0, 32)}"`;
    const headers = { ETag: etag, "Cache-Control": "private, no-cache" };
    if (c.req.header("If-None-Match") === etag) return c.body(null, 304, headers);
    return c.body(body, 200, { ...headers, "Content-Type": "application/json" });
  });

  app.put("/v1/profiles/:id/progress/:item", async (c) => {
    const body = await readBody(c);
    const base = body["baseRevision"];
    if (base !== null && (typeof base !== "number" || !Number.isInteger(base))) {
      throw new ApiError("invalid_request", `"baseRevision" must be a revision number or null.`);
    }
    if (typeof body["completed"] !== "boolean") {
      throw new ApiError("invalid_request", `"completed" must be true or false.`);
    }
    const device = c.get("device");
    const context = { deviceId: device.id, householdId: device.householdId, road: roadOf(c) };
    const result = progress.put(
      c.req.param("id"),
      c.req.param("item"),
      {
        opId: text(body, "opId", 100),
        baseRevision: base,
        positionMs: wholeNumber(body, "positionMs"),
        durationMs: body["durationMs"] === null ? null : wholeNumber(body, "durationMs"),
        completed: body["completed"],
        updatedAt: wholeNumber(body, "updatedAt"),
      },
      (profileId, itemId, before, after) => {
        stats.noteWatch(profileId, itemId, before, after, context);
      },
    );
    if (result.outcome === "not_found")
      throw new ApiError("not_found", "There is no such viewer or title.");
    if (result.outcome === "conflict") {
      throw new ApiError("conflict", "This was changed more recently on another device.", {
        progress: result.progress,
      });
    }
    // What a kids viewer watched counts towards the day's screen time.
    if (!body["completed"]) {
      control.countProgress(
        c.req.param("id"),
        c.req.param("item"),
        wholeNumber(body, "positionMs"),
      );
    }
    return c.json({ progress: result.progress });
  });

  // ---- How far a viewer moved the subtitles of a title ----

  const titleOf = (itemId: string): string => {
    const item = db.get<{ id: string }>("select id from item where id = ?", [itemId]);
    if (!item) throw new ApiError("not_found", "There is no such title.");
    return item.id;
  };

  app.get("/v1/profiles/:id/subtitle-offsets/:item", (c) => {
    const profile = profileById(c.req.param("id"));
    const row = db.get<{ offset_ms: number }>(
      "select offset_ms from subtitle_offset where profile_id = ? and item_id = ?",
      [profile.id, titleOf(c.req.param("item"))],
    );
    return c.json({ offsetMs: row?.offset_ms ?? 0 });
  });

  app.put("/v1/profiles/:id/subtitle-offsets/:item", async (c) => {
    const body = await readBody(c, MAX_SMALL_BODY);
    const offset = body["offsetMs"];
    if (
      typeof offset !== "number" ||
      !Number.isInteger(offset) ||
      Math.abs(offset) > MAX_SUBTITLE_OFFSET_MS
    ) {
      throw new ApiError(
        "invalid_request",
        `"offsetMs" must be a whole number of milliseconds of at most ${String(MAX_SUBTITLE_OFFSET_MS)} either way.`,
      );
    }
    const profile = profileById(c.req.param("id"));
    const item = titleOf(c.req.param("item"));
    if (offset === 0) {
      db.run("delete from subtitle_offset where profile_id = ? and item_id = ?", [
        profile.id,
        item,
      ]);
    } else {
      db.run(
        `insert into subtitle_offset (profile_id, item_id, offset_ms, updated_at) values (?, ?, ?, ?)
         on conflict (profile_id, item_id) do update set offset_ms = excluded.offset_ms,
           updated_at = excluded.updated_at`,
        [profile.id, item, offset, now()],
      );
    }
    return c.json({ offsetMs: offset });
  });

  // ---- Media ----

  const { outside } = deps;
  if (outside)
    registerOutsideRoutes(app, { outside, requireManager, requireHouseholdAdmin, households });
  registerHouseholdRoutes(app, {
    households,
    devices,
    outside,
    remote: deps.remote,
    requireManager,
    requireHouseholdAdmin,
    serverName: () => deps.serverName,
  });
  if (deps.wake && entrance === "home") {
    registerWakeRoutes(app, {
      wake: deps.wake,
      devices,
      settings: deps.settings?.service ?? null,
      remote: deps.remote ?? null,
      requireManager,
    });
  }
  if (deps.speakers && entrance === "home") {
    registerSpeakerRoutes(app, {
      speakers: deps.speakers,
      devices,
      settings: deps.settings?.service ?? null,
      remote: deps.remote ?? null,
      requireManager,
    });
  }
  if (deps.imports && entrance === "home") {
    registerImportRoutes(app, {
      ...deps.imports,
      db,
      ...(deps.conversion ? { conversion: deps.conversion } : {}),
      requireManager,
      now,
    });
  }
  if (deps.settings) {
    registerSettingsRoutes(app, {
      settings: deps.settings.service,
      browser: deps.settings.browser,
      requireManager,
      now,
    });
  }

  const serveAsset = async (c: Ctx): Promise<Response> => {
    const asset = db.get<AssetRow>(
      `select asset.id, asset.rel_path, asset.size, asset.mtime_ms, asset.revision, asset.container,
         asset.available, source.path as source_path, source.available as source_available
       from asset join source on source.id = asset.source_id where asset.id = ?`,
      [c.req.param("id") ?? ""],
    );
    if (!asset) throw new ApiError("not_found", "That file is no longer in the library.");
    if (asset.available !== 1 || asset.source_available !== 1) {
      throw new ApiError("unavailable", "The drive this file is on is not connected right now.");
    }

    return serveLibraryFile(c, {
      id: asset.id,
      root: asset.source_path,
      relPath: asset.rel_path,
      revision: asset.revision,
      mtimeMs: asset.mtime_ms,
      contentType: mediaTypeFor(asset.container, asset.rel_path),
    });
  };

  app.on(["GET", "HEAD"], "/v1/assets/:id/content", serveAsset);

  app.post("/v1/assets/:id/airplay", (c) => {
    // The receiver fetches the film from the home network itself: from outside it could not.
    if (entrance === "outside") throw new ApiError("forbidden", "AirPlay works at home only.");
    const id = c.req.param("id");
    const asset = db.get<{ id: string }>("select id from asset where id = ?", [id]);
    if (!asset) throw new ApiError("not_found", "That file is no longer in the library.");
    const pass = passes.issue(c.get("device").id, asset.id);
    return c.json({
      prefix: `/v1/airplay/${pass.name}`,
      expiresAt: pass.expiresAt,
      assetId: asset.id,
    });
  });

  const artwork = deps.artwork;
  if (artwork) {
    app.get("/v1/artwork/:id", async (c) => {
      const width = Number(c.req.query("w") ?? "800");
      if (!Number.isInteger(width) || width < 1) {
        throw new ApiError("invalid_request", `"w" must be a whole number of pixels.`);
      }
      const picture = await artwork.read(c.req.param("id"), width);
      if (!picture) throw new ApiError("not_found", "That picture is no longer in the library.");
      return c.body(picture.data, 200, {
        "Content-Type": picture.type,
        "X-Content-Type-Options": "nosniff",
        "Cache-Control": "private, max-age=31536000, immutable",
      });
    });
  }

  if (deps.playback) {
    registerPlaybackRoutes(app, {
      playback: deps.playback,
      lookupAsset: createAssetLookup(db, deps.videoTags),
    });
  }

  if (deps.music) registerMusicRoutes(app, { db, music: deps.music, catalogueId, requireManager });

  registerStatsRoutes(app, {
    db,
    stats,
    ...(deps.storage ? { storage: deps.storage } : {}),
    requireManager,
    requireHouseholdAdmin,
    inFront: (deviceId) => hub?.inFront(deviceId) ?? null,
    now,
  });

  return app;
}
