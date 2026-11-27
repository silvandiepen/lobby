// SPDX-License-Identifier: MPL-2.0
import { ApiError } from "../http/app.ts";

/** What one device may ask of another. "yield" is not here: only the server asks that. */
export const COMMANDS = [
  "play",
  "pause",
  "resume",
  "seek",
  "skip",
  "next",
  "stop",
  "setAudio",
  "setSubtitle",
  "setVolume",
  "upNext",
] as const;
export type CommandType = (typeof COMMANDS)[number];

export const STATUSES = ["loading", "playing", "paused", "buffering", "ended", "error"] as const;
export type PlayerStatus = (typeof STATUSES)[number];

/** Why a device did not do what it was asked. No free text: that could hold a title. */
export const FAILURES = [
  "not_allowed",
  "not_found",
  "cannot_play",
  "nothing_playing",
  "unsupported",
  "expired",
  "busy",
  "declined",
  "error",
] as const;
export type Failure = (typeof FAILURES)[number];

export interface Track {
  id: string;
  label: string;
  language: string | null;
}

/** What a player shows at the end (docs/playback.md, "When something ends"). */
export const UP_NEXT_KINDS = ["episode", "suggestions", "stillWatching"] as const;
export type UpNextKind = (typeof UP_NEXT_KINDS)[number];

export interface UpNext {
  kind: UpNextKind;
  /** What starts by itself after the countdown, or with Play Now. Null: nothing does. */
  itemId: string | null;
  /** How long until it starts by itself, when it was measured. Null: it waits for Play Now. */
  countdownMs: number | null;
  /** What the viewer may pick from, the first first. Empty but for suggestions. */
  suggestions: string[];
}

/** What another device may answer to Up Next or "Still watching?". */
export const UP_NEXT_ACTIONS = ["playNow", "cancel", "continue"] as const;
export type UpNextAction = (typeof UP_NEXT_ACTIONS)[number];

export interface Player {
  itemId: string | null;
  assetId: string | null;
  profileId: string | null;
  status: PlayerStatus;
  positionMs: number;
  /** When it was there, by the server's clock. */
  at: number;
  durationMs: number | null;
  rate: number;
  audioTracks: Track[];
  audioTrackId: string | null;
  subtitleTracks: Track[];
  subtitleTrackId: string | null;
  volume: number | null;
  nextItemId: string | null;
  queue: string[];
  /** Null: no Up Next on screen. A device from before leaves it out: null too. */
  upNext: UpNext | null;
}

export interface Announcement {
  order: number;
  foreground: boolean;
  canPlay: boolean;
  profileId: string | null;
  capabilities: CommandType[];
  /** Left out: as it was. Null: nothing plays. */
  player: Player | null | undefined;
}

export interface PlayCommand {
  type: "play";
  itemId: string;
  assetId: string | null;
  profileId: string;
  /** Null: where this viewer was. */
  startMs: number | null;
  paused: boolean;
  rate: number;
  /** Null: the target's own choice. "off" for no subtitles. */
  audioTrackId: string | null;
  subtitleTrackId: string | null;
  queue: string[];
}

export type Command =
  | PlayCommand
  | { type: "pause" | "resume" | "next" | "stop" }
  | { type: "seek"; positionMs: number }
  | { type: "skip"; deltaMs: number }
  | { type: "setAudio"; trackId: string }
  | { type: "setSubtitle"; trackId: string | null }
  | { type: "setVolume"; volume: number }
  | { type: "upNext"; action: UpNextAction };

export type Asked = Command | { type: "handover"; toDeviceId: string };

export interface CommandRequest {
  id: string;
  session: string;
  deviceId: string;
  command: Asked;
}

export interface CommandResult {
  commandId: string;
  status: "done" | "failed";
  code: Failure | null;
  player: Player | null | undefined;
}

/** A device cannot send more than this. A list of tracks and a queue fit easily. */
export const MAX_MESSAGE = 32 * 1024;
const MAX_TRACKS = 32;
const MAX_QUEUE = 50;
const MAX_SUGGESTIONS = 20;
const MAX_LABEL = 80;
const DAY_MS = 86_400_000;
/** Measured longer ago than this is not the place it is at now. */
const MAX_AGE_MS = 10_000;
const ID = /^[A-Za-z0-9_-]{1,128}$/;
const TRACK_ID = /^[A-Za-z0-9_.:-]{1,64}$/;

type Body = Record<string, unknown>;

function wrong(key: string, what: string): ApiError {
  return new ApiError("invalid_request", `"${key}" must be ${what}.`);
}

function object(value: unknown, key: string): Body {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw wrong(key, "an object");
  }
  return value as Body;
}

export function readId(value: unknown, key: string): string {
  if (typeof value !== "string" || !ID.test(value)) throw wrong(key, "an id");
  return value;
}

const optionalId = (body: Body, key: string): string | null =>
  body[key] === null || body[key] === undefined ? null : readId(body[key], key);

function trackId(value: unknown, key: string): string {
  if (typeof value !== "string" || !TRACK_ID.test(value)) throw wrong(key, "a track's id");
  return value;
}

const optionalTrack = (body: Body, key: string): string | null =>
  body[key] === null || body[key] === undefined ? null : trackId(body[key], key);

function flag(body: Body, key: string, otherwise?: boolean): boolean {
  const value = body[key] ?? otherwise;
  if (typeof value !== "boolean") throw wrong(key, "true or false");
  return value;
}

function number(body: Body, key: string, least: number, most: number): number {
  const value = body[key];
  if (typeof value !== "number" || !Number.isFinite(value) || value < least || value > most) {
    throw wrong(key, `a number from ${least} to ${most}`);
  }
  return value;
}

const millis = (body: Body, key: string, least = 0): number =>
  Math.round(number(body, key, least, DAY_MS));

const optional = <T>(body: Body, key: string, read: () => T): T | null =>
  body[key] === null || body[key] === undefined ? null : read();

function oneOf<T extends string>(value: unknown, key: string, allowed: readonly T[]): T {
  if (typeof value !== "string" || !allowed.includes(value as T)) {
    throw wrong(key, `one of: ${allowed.join(", ")}`);
  }
  return value as T;
}

function list<T>(body: Body, key: string, most: number, read: (one: unknown) => T): T[] {
  const value = body[key] ?? [];
  if (!Array.isArray(value) || value.length > most) throw wrong(key, `a list of at most ${most}`);
  return value.map(read);
}

const tracks = (body: Body, key: string): Track[] =>
  list(body, key, MAX_TRACKS, (one) => {
    const track = object(one, key);
    const { label, language } = track;
    if (typeof label !== "string") throw wrong(`${key}.label`, "a string");
    if (language !== null && language !== undefined && typeof language !== "string") {
      throw wrong(`${key}.language`, "a string or null");
    }
    return {
      id: trackId(track["id"], `${key}.id`),
      label: label.slice(0, MAX_LABEL),
      language: language?.slice(0, 16) ?? null,
    };
  });

const queue = (body: Body): string[] =>
  list(body, "queue", MAX_QUEUE, (one) => readId(one, "queue"));

function readUpNext(value: unknown): UpNext | null {
  if (value === null || value === undefined) return null;
  const body = object(value, "player.upNext");
  return {
    kind: oneOf(body["kind"], "player.upNext.kind", UP_NEXT_KINDS),
    itemId: optionalId(body, "itemId"),
    countdownMs: optional(body, "countdownMs", () => millis(body, "countdownMs")),
    suggestions: list(body, "suggestions", MAX_SUGGESTIONS, (one) => readId(one, "suggestions")),
  };
}

/** What a device says it plays. `ageMs`, not a time: its clock may be wrong. */
function readPlayer(value: unknown, now: number): Player | null | undefined {
  if (value === null || value === undefined) return value;
  const body = object(value, "player");
  const age = optional(body, "ageMs", () => number(body, "ageMs", 0, DAY_MS)) ?? 0;
  return {
    itemId: optionalId(body, "itemId"),
    assetId: optionalId(body, "assetId"),
    profileId: optionalId(body, "profileId"),
    status: oneOf(body["status"], "status", STATUSES),
    positionMs: millis(body, "positionMs"),
    at: now - Math.round(Math.min(age, MAX_AGE_MS)),
    durationMs: optional(body, "durationMs", () => millis(body, "durationMs")),
    rate: optional(body, "rate", () => number(body, "rate", 0, 16)) ?? 1,
    audioTracks: tracks(body, "audioTracks"),
    audioTrackId: optionalTrack(body, "audioTrackId"),
    subtitleTracks: tracks(body, "subtitleTracks"),
    subtitleTrackId: optionalTrack(body, "subtitleTrackId"),
    volume: optional(body, "volume", () => number(body, "volume", 0, 1)),
    nextItemId: optionalId(body, "nextItemId"),
    queue: queue(body),
    upNext: readUpNext(body["upNext"]),
  };
}

export function readAnnouncement(body: Body, now: number): Announcement {
  return {
    order: Math.floor(number(body, "order", 0, Number.MAX_SAFE_INTEGER)),
    foreground: flag(body, "foreground"),
    canPlay: flag(body, "canPlay"),
    profileId: optionalId(body, "profileId"),
    capabilities: list(body, "capabilities", 32, (one) => one).filter(
      // A newer app may be able to do more than this server knows of.
      (one): one is CommandType => COMMANDS.includes(one as CommandType),
    ),
    player: readPlayer(body["player"], now),
  };
}

function readCommand(body: Body): Asked {
  const type = oneOf(body["type"], "type", [...COMMANDS, "handover"] as const);
  switch (type) {
    case "play":
      return {
        type,
        itemId: readId(body["itemId"], "itemId"),
        assetId: optionalId(body, "assetId"),
        profileId: readId(body["profileId"], "profileId"),
        startMs: optional(body, "startMs", () => millis(body, "startMs")),
        paused: flag(body, "paused", false),
        rate: optional(body, "rate", () => number(body, "rate", 0.25, 4)) ?? 1,
        audioTrackId: optionalTrack(body, "audioTrackId"),
        subtitleTrackId: optionalTrack(body, "subtitleTrackId"),
        queue: queue(body),
      };
    case "seek":
      return { type, positionMs: millis(body, "positionMs") };
    case "skip":
      return { type, deltaMs: millis(body, "deltaMs", -DAY_MS) };
    case "setAudio":
      return { type, trackId: trackId(body["trackId"], "trackId") };
    case "setSubtitle":
      return { type, trackId: optionalTrack(body, "trackId") };
    case "setVolume":
      return { type, volume: number(body, "volume", 0, 1) };
    case "upNext":
      return { type, action: oneOf(body["action"], "action", UP_NEXT_ACTIONS) };
    case "handover":
      return { type, toDeviceId: readId(body["toDeviceId"], "toDeviceId") };
    default:
      return { type };
  }
}

export function readCommandRequest(body: Body): CommandRequest {
  return {
    id: readId(body["id"], "id"),
    session: readId(body["session"], "session"),
    deviceId: readId(body["deviceId"], "deviceId"),
    command: readCommand(object(body["command"], "command")),
  };
}

/** `play` of `POST /v1/remote/wake`: a play command and its id, kept until the TV is open. */
export function readHeldPlay(value: unknown): { id: string; command: PlayCommand } {
  const body = object(value, "play");
  const command = readCommand(object(body["command"], "play.command"));
  if (command.type !== "play") throw wrong("play.command.type", `"play"`);
  return { id: readId(body["id"], "play.id"), command };
}

export function readResult(body: Body, now: number): CommandResult {
  const status = oneOf(body["status"], "status", ["done", "failed"] as const);
  return {
    commandId: readId(body["commandId"], "commandId"),
    status,
    code: status === "done" ? null : oneOf(body["code"], "code", FAILURES),
    player: readPlayer(body["player"], now),
  };
}
