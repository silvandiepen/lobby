// SPDX-License-Identifier: MPL-2.0
/**
 * When and what a kids viewer may do: the plan, and the mode it gives at a moment
 * (docs/kids-control.md). Pure: everything it needs comes in, so the tests and the apps'
 * own copy of it (LobbyKit's `KidsPlanResolver`) give the same answers.
 */

/** In the order of strictness: each one allows less than the one before. */
export const MODES = ["everything", "ask", "listening", "nothing"] as const;
export type Mode = (typeof MODES)[number];

/** What a grown-up's answer to Ask first gives. */
export const ANSWER_MODES = ["everything", "listening"] as const;
export type AnswerMode = (typeof ANSWER_MODES)[number];

export const ASK_STYLES = ["open", "title"] as const;
export type AskStyle = (typeof ASK_STYLES)[number];

export const rank = (mode: Mode): number => MODES.indexOf(mode);

/** The stricter of two. */
export const stricter = (a: Mode, b: Mode): Mode => (rank(b) > rank(a) ? b : a);

/** A time of the week with a mode. 1 is Monday, 7 Sunday; times are local, "HH:MM". */
export interface PlanBlock {
  days: number[];
  start: string;
  /** "24:00" for the end of the day. Before or at `start`: it goes on into the next day. */
  end: string;
  mode: Mode;
  label: string | null;
}

/** A place a grown-up drew on a map. Only the child's device looks whether it is inside. */
export interface PlanPlace {
  id: string;
  name: string;
  latitude: number;
  longitude: number;
  radiusMeters: number;
  /** "schedule": the place changes nothing, inside it the schedule or the default decides. */
  mode: PlaceMode;
}

/** A place that changes nothing, such as home (docs/decisions.md, D-069). */
export const AS_SCHEDULE = "schedule";
export type PlaceMode = Mode | typeof AS_SCHEDULE;
export const PLACE_MODES = [...MODES, AS_SCHEDULE] as const;

/** The mode a place names; null for one that changes nothing. */
const modeOfPlace = (place: PlanPlace): Mode | null =>
  place.mode === AS_SCHEDULE ? null : place.mode;

/** The strictest mode the places name; null when none names one. */
function strictestPlace(plan: KidsPlan): Mode | null {
  let mode: Mode | null = null;
  for (const place of plan.places) {
    const one = modeOfPlace(place);
    if (one) mode = mode ? stricter(mode, one) : one;
  }
  return mode;
}

/** What holds where a device cannot tell which place it is in (docs/decisions.md, D-069). */
export const STRICTEST_PLACE = "strictest";
export type WhenPlaceUnknown = Mode | typeof STRICTEST_PLACE | null;

export interface ScreenTime {
  /** Minutes of video a day, Monday to Friday; null: no limit. */
  weekdayMinutes: number | null;
  /** Saturday and Sunday. */
  weekendMinutes: number | null;
  whenOut: "listening" | "nothing";
}

export interface KidsPlan {
  defaultMode: Mode;
  blocks: PlanBlock[];
  askStyle: AskStyle;
  /** The household's music and audiobooks, where the mode allows listening. */
  music: boolean;
  screenTime: ScreenTime | null;
  /** The mode away from the home network; null: no rule. */
  away: Mode | null;
  places: PlanPlace[];
  /**
   * When the device cannot tell where it is: a mode, or "strictest" for the strictest of the
   * places' modes; null: the places do not apply, the schedule or the default decides.
   */
  whenPlaceUnknown: WhenPlaceUnknown;
  /** Devices of grown-ups who are asked; empty: all who may decide. Made from `askers`. */
  askDevices: string[];
  /** The grown-ups who are asked, as viewers with their devices; empty: all who may decide. */
  askers: Asker[];
  /** The music libraries (music sources) the child hears; null: all of them. */
  musicSourceIds: string[] | null;
  /**
   * Lock the child's iPhone or iPad to Lobby while it is in kids mode: every other app shielded
   * (docs/decisions.md, "Lock to Lobby"). A device of the child's can say otherwise.
   */
  lockToLobby: boolean;
}

export interface Asker {
  profileId: string;
  deviceIds: string[];
}

/** The plan of a kids viewer nobody set one for: as before there were plans. */
export const NO_PLAN: KidsPlan = {
  defaultMode: "everything",
  blocks: [],
  askStyle: "open",
  // On unless a grown-up turns it off.
  music: true,
  screenTime: null,
  away: null,
  places: [],
  whenPlaceUnknown: null,
  askDevices: [],
  askers: [],
  musicSourceIds: null,
  lockToLobby: false,
};

export interface Override {
  mode: Mode;
  until: number;
  setBy: string;
  setAt: number;
}

/** A grown-up's answer to Ask first, while it runs. */
export interface Grant {
  id: string;
  mode: AnswerMode;
  /** Only this title (and what is inside it); null: the whole app. */
  itemId: string | null;
  until: number;
  by: string;
  at: number;
}

export type PlaceState =
  { state: "inside"; placeId: string } | { state: "outside" } | { state: "unknown" };

export interface PlanContext {
  timeZone: string;
  /** Not on the home network. */
  away: boolean;
  place: PlaceState;
  /** Seconds of video watched on a local day ("YYYY-MM-DD"). */
  videoSeconds: (day: string) => number;
  override: Override | null;
  grants: readonly Grant[];
}

export type Reason =
  "default" | "schedule" | "away" | "place" | "placeUnknown" | "screenTime" | "override";

/** What a kids viewer may do at one moment. */
export interface ModeAt {
  /** What the plan says, before any answer. */
  mode: Mode;
  reason: Reason;
  /** The block's label or the place's name, when that is the reason. */
  detail: string | null;
  /** Films and series can be looked at. */
  browse: boolean;
  /** Which video may play: all of it, only `titles`, or none. */
  video: "all" | "titles" | "none";
  titles: string[];
  /** Music and audiobooks may play. */
  listening: boolean;
  /** Ask to open, and no answer runs: the app only asks. */
  waiting: boolean;
  /** The answer that gives what there is now. */
  grantId: string | null;
}

export interface ModeNow extends ModeAt {
  /** When this changes by the clock; null: not within a week. */
  until: number | null;
  next: ModeAt | null;
  screenTime: { day: string; limitMinutes: number | null; usedSeconds: number } | null;
}

// ---- Local time ----

const formats = new Map<string, Intl.DateTimeFormat>();

function format(timeZone: string): Intl.DateTimeFormat {
  let found = formats.get(timeZone);
  if (!found) {
    found = new Intl.DateTimeFormat("en-US", {
      timeZone,
      hourCycle: "h23",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      weekday: "short",
    });
    formats.set(timeZone, found);
  }
  return found;
}

const WEEKDAYS: Record<string, number> = { Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7 };

export interface LocalTime {
  year: number;
  month: number;
  day: number;
  /** 1 is Monday. */
  weekday: number;
  /** Minutes since local midnight. */
  minute: number;
  second: number;
}

export function localTime(timeZone: string, at: number): LocalTime {
  const parts: Record<string, string> = {};
  for (const part of format(timeZone).formatToParts(new Date(at))) parts[part.type] = part.value;
  return {
    year: Number(parts["year"]),
    month: Number(parts["month"]),
    day: Number(parts["day"]),
    weekday: WEEKDAYS[parts["weekday"] ?? ""] ?? 1,
    minute: Number(parts["hour"]) * 60 + Number(parts["minute"]),
    second: Number(parts["second"]),
  };
}

const pad = (n: number): string => String(n).padStart(2, "0");

/** The local day, "YYYY-MM-DD". */
export function localDay(timeZone: string, at: number): string {
  const t = localTime(timeZone, at);
  return `${String(t.year)}-${pad(t.month)}-${pad(t.day)}`;
}

/** How far local time is ahead of UTC at a moment, in milliseconds. */
function offsetAt(timeZone: string, at: number): number {
  const t = localTime(timeZone, at);
  const wall = Date.UTC(t.year, t.month - 1, t.day, 0, t.minute, t.second);
  return wall - (at - (((at % 1000) + 1000) % 1000));
}

/**
 * The moments a local wall time can be: one, or two in the hour that is there twice, and near
 * the hour that is not there at all. Candidates only: what holds is worked out at each.
 */
function momentsOf(timeZone: string, year: number, month: number, day: number, minute: number) {
  const wall = Date.UTC(year, month - 1, day, 0, minute);
  const hours = 6 * 3_600_000;
  return [wall - offsetAt(timeZone, wall - hours), wall - offsetAt(timeZone, wall + hours)];
}

/** Where the offset changes between two moments, to the minute; null when it does not. */
function transition(timeZone: string, from: number, to: number): number | null {
  const before = offsetAt(timeZone, from);
  if (offsetAt(timeZone, to) === before) return null;
  // Offsets change on a whole minute: search over minutes.
  let low = Math.floor(from / 60_000);
  let high = Math.ceil(to / 60_000);
  while (high - low > 1) {
    const middle = Math.floor((low + high) / 2);
    if (offsetAt(timeZone, middle * 60_000) === before) low = middle;
    else high = middle;
  }
  return high * 60_000;
}

// ---- The plan ----

const TIME = /^([01]\d|2[0-3]):([0-5]\d)$|^24:00$/;

export const minutesOf = (time: string): number => {
  const [hours = "0", minutes = "0"] = time.split(":");
  return Number(hours) * 60 + Number(minutes);
};

const previousDay = (weekday: number): number => (weekday === 1 ? 7 : weekday - 1);

/** Whether a block holds at this local weekday and minute. */
export function blockHolds(block: PlanBlock, weekday: number, minute: number): boolean {
  const start = minutesOf(block.start);
  const end = minutesOf(block.end);
  if (start < end) return block.days.includes(weekday) && minute >= start && minute < end;
  // Into the next day: 19:30–07:00 on Monday is Monday evening and Tuesday morning.
  return (
    (block.days.includes(weekday) && minute >= start) ||
    (block.days.includes(previousDay(weekday)) && minute < end)
  );
}

/** The video minutes a day allows; null: no limit. */
export function screenLimit(plan: KidsPlan, weekday: number): number | null {
  if (!plan.screenTime) return null;
  return weekday >= 6 ? plan.screenTime.weekendMinutes : plan.screenTime.weekdayMinutes;
}

/** The strictest mode the plan names anywhere: what holds when nothing more is known. */
export function strictestOf(plan: KidsPlan): Mode {
  let mode = plan.defaultMode;
  for (const block of plan.blocks) mode = stricter(mode, block.mode);
  const place = strictestPlace(plan);
  if (place) mode = stricter(mode, place);
  if (plan.away) mode = stricter(mode, plan.away);
  // "strictest" names no mode of its own: the places are counted already.
  if (plan.whenPlaceUnknown && plan.whenPlaceUnknown !== STRICTEST_PLACE) {
    mode = stricter(mode, plan.whenPlaceUnknown);
  }
  if (plan.screenTime) mode = stricter(mode, plan.screenTime.whenOut);
  return mode;
}

interface Source {
  mode: Mode;
  reason: Reason;
  detail: string | null;
}

/** What the plan says at a moment, before any answer: the override, else the strictest source. */
export function planModeAt(plan: KidsPlan, context: PlanContext, at: number): Source {
  const { override } = context;
  if (override && override.until > at) {
    return { mode: override.mode, reason: "override", detail: null };
  }
  const local = localTime(context.timeZone, at);
  let source: Source = { mode: plan.defaultMode, reason: "default", detail: null };
  const consider = (one: Source): void => {
    if (rank(one.mode) > rank(source.mode)) source = one;
  };
  for (const block of plan.blocks) {
    if (blockHolds(block, local.weekday, local.minute)) {
      // A block says the same as the default when it is no stricter; it is still the reason.
      if (source.reason === "default" && block.mode === source.mode) {
        source = { mode: block.mode, reason: "schedule", detail: block.label };
      } else consider({ mode: block.mode, reason: "schedule", detail: block.label });
    }
  }
  if (plan.away && context.away) consider({ mode: plan.away, reason: "away", detail: null });
  if (plan.places.length > 0) {
    const { place } = context;
    const inside =
      place.state === "inside" ? plan.places.find((one) => one.id === place.placeId) : undefined;
    if (inside) {
      // A place "as schedule" changes nothing.
      const mode = modeOfPlace(inside);
      if (mode) consider({ mode, reason: "place", detail: inside.name });
    } else if (place.state !== "outside" && plan.whenPlaceUnknown !== null) {
      // Cannot tell, or a place that is no longer in the plan: as strict as asked. Nothing asked:
      // the places do not apply, and the schedule or the default decides (D-069).
      const unknown =
        plan.whenPlaceUnknown === STRICTEST_PLACE ? strictestPlace(plan) : plan.whenPlaceUnknown;
      if (unknown) consider({ mode: unknown, reason: "placeUnknown", detail: null });
    }
  }
  const limit = screenLimit(plan, local.weekday);
  if (plan.screenTime && limit !== null) {
    const day = `${String(local.year)}-${pad(local.month)}-${pad(local.day)}`;
    if (context.videoSeconds(day) >= limit * 60) {
      consider({ mode: plan.screenTime.whenOut, reason: "screenTime", detail: null });
    }
  }
  return source;
}

/** What a kids viewer may do at a moment: the plan's mode, and the answers that run then. */
export function modeAt(plan: KidsPlan, context: PlanContext, at: number): ModeAt {
  const source = planModeAt(plan, context, at);
  const base = { ...source, titles: [] as string[], waiting: false, grantId: null };
  const music = plan.music;
  switch (source.mode) {
    case "everything":
      return { ...base, browse: true, video: "all", listening: music };
    case "listening":
      return { ...base, browse: false, video: "none", listening: music };
    case "nothing":
      return { ...base, browse: false, video: "none", listening: false };
    case "ask":
      break;
  }
  const running = context.grants.filter((one) => one.until > at);
  // The latest answer for the whole app decides; one for a title adds that title.
  const app = running
    .filter((one) => one.itemId === null)
    .sort((a, b) => b.at - a.at || b.until - a.until)[0];
  if (plan.askStyle === "open") {
    if (!app) return { ...base, browse: false, video: "none", listening: false, waiting: true };
    const watch = app.mode === "everything";
    return {
      ...base,
      browse: watch,
      video: watch ? "all" : "none",
      listening: music,
      grantId: app.id,
    };
  }
  // Ask per title: looking and listening are free, video needs a yes.
  if (app?.mode === "everything") {
    return { ...base, browse: true, video: "all", listening: music, grantId: app.id };
  }
  const titles = running.filter((one) => one.itemId !== null && one.mode === "everything");
  return {
    ...base,
    browse: true,
    video: titles.length > 0 ? "titles" : "none",
    titles: [...new Set(titles.map((one) => one.itemId ?? ""))].sort(),
    listening: music,
    grantId: titles[0]?.id ?? null,
  };
}

/** Whether two moments allow the same. */
export function sameMode(a: ModeAt, b: ModeAt): boolean {
  return (
    a.mode === b.mode &&
    a.browse === b.browse &&
    a.video === b.video &&
    a.listening === b.listening &&
    a.waiting === b.waiting &&
    a.titles.join(" ") === b.titles.join(" ")
  );
}

const DAY = 86_400_000;
/** How far ahead the next switch is looked for. */
const HORIZON_DAYS = 8;

/**
 * Every moment within the horizon at which what holds can change: local midnights, the edges of
 * blocks, changes of the offset, the end of an override or answer. More than are needed: what
 * holds is worked out at each.
 */
function candidates(plan: KidsPlan, context: PlanContext, now: number): number[] {
  const { timeZone } = context;
  const found = new Set<number>();
  const today = localTime(timeZone, now);
  const edges = new Set<number>([0]);
  for (const block of plan.blocks) {
    edges.add(minutesOf(block.start));
    edges.add(minutesOf(block.end) % 1440);
  }
  for (let k = 0; k <= HORIZON_DAYS; k += 1) {
    const date = new Date(Date.UTC(today.year, today.month - 1, today.day + k));
    const [y, m, d] = [date.getUTCFullYear(), date.getUTCMonth() + 1, date.getUTCDate()];
    for (const minute of edges)
      for (const at of momentsOf(timeZone, y, m, d, minute)) found.add(at);
    const [midnight] = momentsOf(timeZone, y, m, d, 0);
    if (midnight !== undefined) {
      const changed = transition(timeZone, midnight, midnight + DAY);
      if (changed !== null) found.add(changed);
    }
  }
  if (context.override) found.add(context.override.until);
  for (const grant of context.grants) found.add(grant.until);
  return [...found]
    .filter((at) => at > now && at <= now + HORIZON_DAYS * DAY)
    .sort((a, b) => a - b);
}

/** What holds now, until when, and what comes then. */
export function resolve(plan: KidsPlan, context: PlanContext, now: number): ModeNow {
  const current = modeAt(plan, context, now);
  let until: number | null = null;
  let next: ModeAt | null = null;
  // Video counted later is not known yet: a later day starts again at none.
  const today = localDay(context.timeZone, now);
  const later: PlanContext = {
    ...context,
    videoSeconds: (day) => (day === today ? context.videoSeconds(day) : 0),
  };
  for (const at of candidates(plan, context, now)) {
    const then = modeAt(plan, later, at);
    if (!sameMode(then, current)) {
      until = at;
      next = then;
      break;
    }
  }
  const local = localTime(context.timeZone, now);
  return {
    ...current,
    until,
    next,
    screenTime: plan.screenTime
      ? {
          day: today,
          limitMinutes: screenLimit(plan, local.weekday),
          usedSeconds: context.videoSeconds(today),
        }
      : null,
  };
}

/**
 * The next moment the plan itself switches, leaving out the override: "until the next switch".
 * Null when it does not within a week.
 */
export function nextSwitch(plan: KidsPlan, context: PlanContext, now: number): number | null {
  return resolve(plan, { ...context, override: null, grants: [] }, now).until;
}

// ---- Reading a plan from a request ----

export class PlanError extends Error {}

const MAX_BLOCKS = 50;
const MAX_PLACES = 10;
export const PLACE_RADIUS = { min: 100, max: 10_000 } as const;
const MAX_MINUTES = 24 * 60;
const MAX_ASKED = 50;
const NAME_LENGTH = 40;
const ID = /^[A-Za-z0-9_-]{1,64}$/;

function oneOf<T extends string>(value: unknown, allowed: readonly T[], key: string): T {
  if (typeof value !== "string" || !allowed.includes(value as T)) {
    throw new PlanError(`"${key}" must be one of: ${allowed.join(", ")}.`);
  }
  return value as T;
}

function orNull<T>(value: unknown, read: (value: unknown) => T): T | null {
  return value === null || value === undefined ? null : read(value);
}

function name(value: unknown, key: string): string {
  if (typeof value !== "string" || value.trim() === "" || value.length > NAME_LENGTH) {
    throw new PlanError(`"${key}" must be a name of at most ${String(NAME_LENGTH)} characters.`);
  }
  return value.trim();
}

function minutes(value: unknown, key: string): number | null {
  if (value === null || value === undefined) return null;
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0 || value > MAX_MINUTES) {
    throw new PlanError(
      `"${key}" must be whole minutes from 0 to ${String(MAX_MINUTES)}, or null.`,
    );
  }
  return value;
}

function readBlock(value: unknown, index: number): PlanBlock {
  const key = `blocks[${String(index)}]`;
  if (typeof value !== "object" || value === null)
    throw new PlanError(`"${key}" must be an object.`);
  const one = value as Record<string, unknown>;
  const days = one["days"];
  if (
    !Array.isArray(days) ||
    days.length === 0 ||
    !days.every((day) => typeof day === "number" && Number.isInteger(day) && day >= 1 && day <= 7)
  ) {
    throw new PlanError(`"${key}.days" must be weekdays from 1 (Monday) to 7 (Sunday).`);
  }
  for (const edge of ["start", "end"] as const) {
    const time = one[edge];
    if (typeof time !== "string" || !TIME.test(time) || (edge === "start" && time === "24:00")) {
      throw new PlanError(`"${key}.${edge}" must be a time "HH:MM".`);
    }
  }
  const start = one["start"] as string;
  const end = one["end"] as string;
  if (minutesOf(start) === minutesOf(end)) {
    throw new PlanError(`"${key}" must not start and end at the same time.`);
  }
  return {
    days: [...new Set(days as number[])].sort(),
    start,
    end,
    mode: oneOf(one["mode"], MODES, `${key}.mode`),
    label: orNull(one["label"], (label) => name(label, `${key}.label`)),
  };
}

function readPlace(value: unknown, index: number): PlanPlace {
  const key = `places[${String(index)}]`;
  if (typeof value !== "object" || value === null)
    throw new PlanError(`"${key}" must be an object.`);
  const one = value as Record<string, unknown>;
  const id = one["id"];
  if (typeof id !== "string" || !ID.test(id)) throw new PlanError(`"${key}.id" must be an id.`);
  const number = (field: string, low: number, high: number): number => {
    const n = one[field];
    if (typeof n !== "number" || !Number.isFinite(n) || n < low || n > high) {
      throw new PlanError(
        `"${key}.${field}" must be a number from ${String(low)} to ${String(high)}.`,
      );
    }
    return n;
  };
  return {
    id,
    name: name(one["name"], `${key}.name`),
    latitude: number("latitude", -90, 90),
    longitude: number("longitude", -180, 180),
    radiusMeters: Math.round(number("radiusMeters", PLACE_RADIUS.min, PLACE_RADIUS.max)),
    mode: oneOf(one["mode"], PLACE_MODES, `${key}.mode`),
  };
}

/** Reads a whole plan from a request. What is left out is as in a plan nobody set. */
export function readPlan(value: unknown): KidsPlan {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new PlanError(`"plan" must be an object.`);
  }
  const body = value as Record<string, unknown>;
  const list = (key: string, most: number): unknown[] => {
    const items = body[key] ?? [];
    if (!Array.isArray(items) || items.length > most) {
      throw new PlanError(`"${key}" must be a list of at most ${String(most)}.`);
    }
    return items;
  };
  const places = list("places", MAX_PLACES).map(readPlace);
  if (new Set(places.map((one) => one.id)).size !== places.length) {
    throw new PlanError(`"places" must have different ids.`);
  }
  const screen = body["screenTime"];
  let screenTime: ScreenTime | null = null;
  if (screen !== null && screen !== undefined) {
    if (typeof screen !== "object") throw new PlanError(`"screenTime" must be an object or null.`);
    const one = screen as Record<string, unknown>;
    screenTime = {
      weekdayMinutes: minutes(one["weekdayMinutes"], "screenTime.weekdayMinutes"),
      weekendMinutes: minutes(one["weekendMinutes"], "screenTime.weekendMinutes"),
      whenOut: oneOf(one["whenOut"] ?? "listening", ["listening", "nothing"], "screenTime.whenOut"),
    };
  }
  const ids = (value: unknown, key: string): string[] => {
    if (!Array.isArray(value) || value.length > MAX_ASKED) {
      throw new PlanError(`"${key}" must be a list of at most ${String(MAX_ASKED)} ids.`);
    }
    if (!value.every((id) => typeof id === "string" && ID.test(id))) {
      throw new PlanError(`"${key}" must be a list of ids.`);
    }
    return [...new Set(value as string[])];
  };
  const askers = list("askers", MAX_ASKED).map((one, index): Asker => {
    if (typeof one !== "object" || one === null) {
      throw new PlanError(`"askers[${String(index)}]" must be an object.`);
    }
    const asker = one as Record<string, unknown>;
    const profileId = asker["profileId"];
    if (typeof profileId !== "string" || !ID.test(profileId)) {
      throw new PlanError(`"askers[${String(index)}].profileId" must be a viewer's id.`);
    }
    return {
      profileId,
      deviceIds: ids(asker["deviceIds"] ?? [], `askers[${String(index)}].deviceIds`),
    };
  });
  // Who is asked: the askers' devices when there are askers, else what an older app sent.
  const asked =
    askers.length > 0
      ? [...new Set(askers.flatMap((one) => one.deviceIds))]
      : ids(body["askDevices"] ?? [], "askDevices");
  const sources = body["musicSourceIds"];
  const music = body["music"] ?? true;
  if (typeof music !== "boolean") throw new PlanError(`"music" must be true or false.`);
  const lockToLobby = body["lockToLobby"] ?? false;
  if (typeof lockToLobby !== "boolean") {
    throw new PlanError(`"lockToLobby" must be true or false.`);
  }
  return {
    defaultMode: oneOf(body["defaultMode"] ?? "everything", MODES, "defaultMode"),
    blocks: list("blocks", MAX_BLOCKS).map(readBlock),
    askStyle: oneOf(body["askStyle"] ?? "open", ASK_STYLES, "askStyle"),
    music,
    screenTime,
    away: orNull(body["away"], (mode) => oneOf(mode, MODES, "away")),
    places,
    whenPlaceUnknown: orNull(body["whenPlaceUnknown"], (mode) =>
      oneOf(mode, [...MODES, STRICTEST_PLACE], "whenPlaceUnknown"),
    ),
    askDevices: asked,
    askers,
    musicSourceIds:
      sources === null || sources === undefined ? null : ids(sources, "musicSourceIds"),
    lockToLobby,
  };
}

/** Whether a time zone is one this server knows. */
export function isTimeZone(value: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: value });
    return value.length <= 64;
  } catch {
    return false;
  }
}

/** The server's own time zone. */
export const serverTimeZone = (): string =>
  Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
