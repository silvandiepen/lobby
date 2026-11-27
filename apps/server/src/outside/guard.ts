// SPDX-License-Identifier: MPL-2.0
import type { MiddlewareHandler } from "hono";
import { matchedRoutes } from "hono/route";
import type { Device } from "../auth/devices.ts";
import type { Database } from "../db/database.ts";
import type { AppEnv } from "../http/app.ts";
import type { PlaybackService } from "../playback/index.ts";
import { RateLimiter, Slots } from "./limits.ts";

/**
 * What a device outside may ask for.
 *
 * - `closed`: nothing. Managers' routes are closed for managers too: they act from home.
 * - `household`: what a guest household's manager does for that household, which lives
 *   elsewhere and has no home here. Closed like the others for everyone else.
 * - `kids`: deciding for a child (answers, overrides): for its household's admins and the server
 *   admins, from anywhere, since a question from the couch is often answered from elsewhere.
 *   The routes check who may decide for which child.
 * - the others are open for a device that is let in, each within its own limits.
 */
export type OutsideDecision =
  | "closed"
  | "account"
  | "library"
  | "artwork"
  | "progress"
  | "downloads"
  | "playback"
  | "stream"
  | "subtitle"
  | "live"
  | "remote"
  | "household"
  | "kids";

/**
 * A decision for every route there is. A route that is not here does not exist outside, and the
 * tests fail until it is. `HEAD` follows `GET`.
 */
export const OUTSIDE_ROUTES: Readonly<Record<string, OutsideDecision>> = {
  // Open at home. Outside there is no such thing as an open route.
  "GET /v1/server": "closed",
  "POST /v1/pairing/claim": "closed",
  "POST /v1/pairing/requests": "closed",
  "POST /v1/pairing/requests/:id/collect": "closed",
  // An AirPlay receiver fetches from the home network.
  "GET /v1/airplay/:pass/*": "closed",
  "POST /v1/assets/:id/airplay": "closed",

  // Getting ready for the direct road is for home.
  "GET /v1/me/direct": "closed",
  "PUT /v1/me/direct": "closed",

  "GET /v1/me": "account",
  "GET /v1/profiles": "account",
  "PATCH /v1/me": "remote",
  // Only itself, until a manager lets it see other devices from outside.
  "GET /v1/live": "live",
  "POST /v1/live/:session": "remote",
  "POST /v1/live/:session/results": "remote",
  "POST /v1/remote/commands": "remote",
  "PUT /v1/profiles/:id/avatar": "account",
  "PUT /v1/profiles/:id/subtitles": "account",
  "PUT /v1/profiles/:id/playback": "account",
  "PUT /v1/profiles/:id/skipping": "account",
  "GET /v1/kids/code": "account",
  // Kids control: a child's own plan, places, screen time and questions; a viewer's glance.
  // A device far from home is told of questions too; whether pushes go out is told at home.
  "GET /v1/me/push": "account",
  "PUT /v1/me/push": "account",
  "DELETE /v1/me/push": "account",
  "GET /v1/settings/push": "closed",
  "GET /v1/me/kids": "account",
  "PUT /v1/me/kids/place": "account",
  "POST /v1/me/kids/screen-time": "account",
  "POST /v1/me/kids/requests": "account",
  "GET /v1/me/kids/requests/:id": "account",
  "DELETE /v1/me/kids/requests/:id": "account",
  "GET /v1/kids/now": "account",
  "GET /v1/profiles/:id/kids/plan": "account",
  "POST /v1/kids/code/check": "account",
  "GET /v1/me/wanted": "downloads",
  "POST /v1/me/downloads": "downloads",
  "GET /v1/library": "library",
  "GET /v1/library/query": "library",
  "GET /v1/search": "library",
  "GET /v1/search/outside": "library",
  "GET /v1/search/outside/:type/:id": "library",
  "GET /v1/search/people/:id": "library",
  "GET /v1/search/picture": "library",
  "GET /v1/popular": "library",
  "GET /v1/categories": "library",
  "GET /v1/items/:id": "library",
  "GET /v1/logos/:id": "artwork",
  "GET /v1/artwork/:id": "artwork",
  "GET /v1/profiles/:id/progress": "progress",
  "PUT /v1/profiles/:id/progress/:item": "progress",
  "GET /v1/profiles/:id/subtitle-offsets/:item": "progress",
  "PUT /v1/profiles/:id/subtitle-offsets/:item": "progress",
  "POST /v1/assets/:id/playback": "playback",
  "GET /v1/assets/:id/content": "stream",
  "GET /v1/assets/:id/prepared/:revision/master.m3u8": "stream",
  "GET /v1/assets/:id/prepared/:revision/subtitles/:playlist{[A-Za-z0-9_-]+\\.m3u8}": "stream",
  "GET /v1/assets/:id/prepared/:revision/:file": "stream",
  "GET /v1/assets/:id/subtitles/:subtitle{[A-Za-z0-9_-]+\\.vtt}": "subtitle",
  "GET /v1/assets/:id/subtitles/:subtitle{[A-Za-z0-9_-]+\\.json}": "subtitle",

  // A guest household's manager, for that household (households/guard.ts keeps it to it).
  "GET /v1/pairing/requests": "household",
  "GET /v1/household/invites": "household",
  "POST /v1/household/invites": "household",
  "DELETE /v1/household/invites/:invite": "household",
  "DELETE /v1/pairing/requests/:id": "closed",
  "POST /v1/outside/window": "household",
  "DELETE /v1/outside/window": "household",
  "POST /v1/outside/pairing/:id/approve": "household",
  "DELETE /v1/outside/pairing/:id": "household",
  "GET /v1/outside/access": "household",
  "GET /v1/devices": "household",
  "PATCH /v1/devices/:id": "household",
  "DELETE /v1/devices/:id": "household",
  "GET /v1/devices/wanted": "household",
  "GET /v1/devices/:id/wanted": "household",
  "POST /v1/devices/:id/wanted": "household",
  "DELETE /v1/devices/:id/wanted/:wantedId": "household",
  "POST /v1/profiles": "household",
  "PATCH /v1/profiles/:id": "household",
  "DELETE /v1/profiles/:id": "household",
  "PUT /v1/kids/code": "household",
  // Answering and stepping in are open from outside to whoever may decide (docs/decisions.md, "Kids control"); changing
  // the plan and the clock stays with the household's managing, as the rest of its kids (docs/decisions.md, "Households").
  "GET /v1/kids/requests": "kids",
  "POST /v1/kids/requests/:id/answer": "kids",
  "PUT /v1/profiles/:id/kids/override": "kids",
  "DELETE /v1/profiles/:id/kids/override": "kids",
  "PATCH /v1/profiles/:id/kids/answer": "kids",
  "DELETE /v1/profiles/:id/kids/answer": "kids",
  "PUT /v1/household/time-zone": "household",
  "PUT /v1/profiles/:id/kids/plan": "household",
  "GET /v1/household": "account",

  // Managers only, and only at home.
  "GET /v1/households": "closed",
  "POST /v1/households": "closed",
  "GET /v1/households/:id": "closed",
  "PATCH /v1/households/:id": "closed",
  "DELETE /v1/households/:id": "closed",
  "POST /v1/households/:id/invites": "closed",
  "DELETE /v1/households/:id/invites/:invite": "closed",
  "GET /v1/status": "closed",
  "GET /v1/settings": "closed",
  "PATCH /v1/settings": "closed",
  "GET /v1/settings/history": "closed",
  "POST /v1/settings/history/:version/restore": "closed",
  "GET /v1/settings/audit": "closed",
  "GET /v1/settings/browse": "closed",
  "PUT /v1/settings/tmdb": "closed",
  "DELETE /v1/settings/tmdb": "closed",
  "PUT /v1/settings/omdb": "closed",
  "DELETE /v1/settings/omdb": "closed",
  "GET /v1/setup": "closed",
  "POST /v1/setup/steps/:step": "closed",
  "POST /v1/setup/finish": "closed",
  "GET /v1/outside": "closed",
  "PATCH /v1/outside": "closed",
  "POST /v1/pairing/approve": "closed",
  "GET /v1/items/:id/edit": "closed",
  "PATCH /v1/items/:id": "closed",
  "GET /v1/items/:id/artwork-options": "closed",
  "GET /v1/items/:id/artwork-options/preview": "closed",
  "POST /v1/items/:id/artwork": "closed",
  "POST /v1/items/:id/artwork/upload": "closed",
  "DELETE /v1/items/:id/artwork": "closed",
  "GET /v1/markers": "closed",
  "GET /v1/markers/assets/:id": "closed",
  "PUT /v1/markers/assets/:id": "closed",
  "DELETE /v1/markers/assets/:id": "closed",
  "POST /v1/markers/items/:id/detect": "closed",
  "GET /v1/items/:id/match": "closed",
  "PUT /v1/items/:id/match": "closed",
  "DELETE /v1/items/:id/match": "closed",
  "POST /v1/items/:id/match/automatic": "closed",
  "GET /v1/categories/edit": "closed",
  "POST /v1/categories/groups": "closed",
  "PUT /v1/categories/groups/order": "closed",
  "PATCH /v1/categories/groups/:id": "closed",
  "DELETE /v1/categories/groups/:id": "closed",
  "PUT /v1/categories/folders/:id": "closed",
  "GET /v1/categories/logo-search": "closed",
  "GET /v1/categories/logo-search/preview": "closed",
  "PUT /v1/categories/groups/:id/logo": "closed",
  "POST /v1/categories/groups/:id/logo/upload": "closed",
  "DELETE /v1/categories/groups/:id/logo": "closed",
  "PUT /v1/categories/:id/logo": "closed",
  "POST /v1/categories/:id/logo/upload": "closed",
  "DELETE /v1/categories/:id/logo": "closed",
  "POST /v1/categories": "closed",
  "PUT /v1/categories/order": "closed",
  "POST /v1/categories/arrange": "closed",
  "GET /v1/categories/suggestions": "closed",
  "POST /v1/categories/suggestions/:id/accept": "closed",
  "POST /v1/categories/suggestions/accept": "closed",
  "POST /v1/categories/suggestions/:id/dismiss": "closed",
  "POST /v1/categories/merge": "closed",
  "POST /v1/categories/arrange/undo": "closed",
  "PATCH /v1/categories/:id": "closed",
  "DELETE /v1/categories/:id": "closed",
  "GET /v1/conversion": "closed",
  "POST /v1/conversion/jobs": "closed",
  "POST /v1/conversion/pause": "closed",
  "POST /v1/conversion/resume": "closed",
  "DELETE /v1/conversion/jobs/:id": "closed",
  "POST /v1/conversion/jobs/:id/move": "closed",
  "POST /v1/conversion/claim": "closed",
  "POST /v1/conversion/jobs/:id/heartbeat": "closed",
  "GET /v1/conversion/jobs/:id/upload": "closed",
  "PATCH /v1/conversion/jobs/:id/upload": "closed",
  "POST /v1/conversion/jobs/:id/complete": "closed",
  "POST /v1/conversion/jobs/:id/release": "closed",
  "GET /v1/conversion/replacements": "closed",
  "POST /v1/conversion/replacements/:id/undo": "closed",
  "POST /v1/conversion/replacements/:id/purge": "closed",

  // Music: listening and what keeps its place. Changing lists and edits wait for home.
  "GET /v1/music/library": "library",
  "GET /v1/music/artists/:id": "library",
  "GET /v1/music/albums/:id": "library",
  "GET /v1/music/tracks/:id": "library",
  "GET /v1/music/books/:id": "library",
  "GET /v1/music/covers/:id": "artwork",
  "GET /v1/music/tracks/:id/content": "stream",
  "POST /v1/music/tracks/:id/playback": "playback",
  "GET /v1/music/tracks/:id/copies/:revision/:file": "stream",
  "GET /v1/music/profiles/:profile/favourites": "progress",
  "GET /v1/music/profiles/:profile/playlists": "progress",
  "GET /v1/music/profiles/:profile/playlists/:id": "progress",
  "POST /v1/music/profiles/:profile/plays": "progress",
  "GET /v1/music/profiles/:profile/plays": "progress",
  "GET /v1/music/profiles/:profile/play-counts": "progress",
  "GET /v1/music/profiles/:profile/progress": "progress",
  "PUT /v1/music/profiles/:profile/progress/:item": "progress",
  "GET /v1/music/status": "closed",
  "GET /v1/music/artists/:id/edit": "closed",
  "PATCH /v1/music/artists/:id": "closed",
  "GET /v1/music/albums/:id/edit": "closed",
  "PATCH /v1/music/albums/:id": "closed",
  "GET /v1/music/tracks/:id/edit": "closed",
  "PATCH /v1/music/tracks/:id": "closed",
  "GET /v1/music/books/:id/edit": "closed",
  "PATCH /v1/music/books/:id": "closed",
  "PUT /v1/music/profiles/:profile/favourites/:item": "closed",
  "POST /v1/music/profiles/:profile/playlists": "closed",
  "PATCH /v1/music/profiles/:profile/playlists/:id": "closed",
  "POST /v1/music/profiles/:profile/playlists/:id/tracks": "closed",
  "DELETE /v1/music/profiles/:profile/playlists/:id": "closed",
  "GET /v1/music/profiles/:profile/playlists/:id/export.m3u8": "closed",
  "DELETE /v1/music/profiles/:profile/plays": "closed",

  // A viewer's statistics are read like their places; forgetting waits for home, as do the
  // server's.
  "GET /v1/stats/viewers/:id": "progress",
  "DELETE /v1/stats/viewers/:id/history/:session": "closed",
  "DELETE /v1/stats/viewers/:id": "closed",
  // A guest household's admins live elsewhere: their overview is theirs from there.
  "GET /v1/stats/household": "household",
  "GET /v1/stats/server": "closed",
};

/** How much one device, and all of them together, may ask for at once. */
export const OUTSIDE_SLOTS = {
  stream: { perDevice: 8, inAll: 24 },
  library: { perDevice: 4, inAll: 8 },
  artwork: { perDevice: 12, inAll: 24 },
  // Reading a subtitle out of a film reads the whole film.
  subtitle: { perDevice: 1, inAll: 2 },
  live: { perDevice: 6, inAll: 24 },
} as const;

/** New repackaging or converting a device may start. Asking how one is doing is free. */
export const OUTSIDE_STARTS = { burst: 6, perMinute: 0.5 } as const;
/** Copies of one device that may be made or wait at the same time. */
export const OUTSIDE_PENDING = 2;
/** Compact copies of songs a device may ask for: they are short, and have their own queue. */
export const OUTSIDE_SONGS = { burst: 60, perMinute: 6 } as const;

/** What the entrance hands over with a request. */
export interface OutsideRequest {
  device: Device;
  /** Calls back once the answer is sent or the connection is gone. */
  onClosed: (done: () => void) => void;
  /** Told which kind of route it was, for the log. */
  routeClass: string;
  /** The road it came by ("relay", "direct"), for the statistics. */
  transport?: string;
}

interface GuardDeps {
  db: Database;
  playback: PlaybackService | undefined;
  refusal: (
    code: "forbidden" | "not_found" | "rate_limited" | "unavailable",
    message: string,
  ) => Error;
}

/** The decision about the route that answers this request, and its key. */
export function outsideDecision(method: string, pattern: string): OutsideDecision | null {
  const key = `${method === "HEAD" ? "GET" : method} ${pattern}`;
  return Object.hasOwn(OUTSIDE_ROUTES, key) ? (OUTSIDE_ROUTES[key] ?? null) : null;
}

/**
 * Stands before everything on the app for outside: a route without a decision is not there, and
 * a request the entrance did not let in gets nothing at all.
 */
export function outsideGuard(deps: GuardDeps): MiddlewareHandler<AppEnv> {
  const { db, refusal } = deps;
  const slots = {
    stream: new Slots(OUTSIDE_SLOTS.stream.perDevice, OUTSIDE_SLOTS.stream.inAll),
    library: new Slots(OUTSIDE_SLOTS.library.perDevice, OUTSIDE_SLOTS.library.inAll),
    artwork: new Slots(OUTSIDE_SLOTS.artwork.perDevice, OUTSIDE_SLOTS.artwork.inAll),
    subtitle: new Slots(OUTSIDE_SLOTS.subtitle.perDevice, OUTSIDE_SLOTS.subtitle.inAll),
    live: new Slots(OUTSIDE_SLOTS.live.perDevice, OUTSIDE_SLOTS.live.inAll),
  };
  const starts = new RateLimiter(OUTSIDE_STARTS, Date.now);
  const songs = new RateLimiter(OUTSIDE_SONGS, Date.now);
  const started = new Map<string, Set<string>>();

  /** Starting ffmpeg is the most expensive thing there is to ask for. */
  const mayStart = (device: Device, pattern: string, path: string): boolean => {
    const id = path.split("/")[pattern.split("/").indexOf(":id")] ?? "";
    if (pattern.startsWith("/v1/music/")) return songs.take(device.id) === 0;
    const asset = db.get<{ revision: string; playability: string | null }>(
      "select revision, playability from asset where id = ?",
      [id],
    );
    // Nothing to make: the handler says what there is.
    if (!asset || (asset.playability !== "remux" && asset.playability !== "transcode")) return true;
    const state = deps.playback?.peek(id, asset.revision);
    // Nobody waits for one made ahead; to ask for it is to put it before everyone's.
    if (state && state.state !== "failed" && !state.background) return true;
    const mine = started.get(device.id) ?? new Set<string>();
    for (const one of mine) {
      const current = db.get<{ revision: string }>("select revision from asset where id = ?", [
        one,
      ]);
      const copy = current ? deps.playback?.peek(one, current.revision) : null;
      if (!copy || copy.state === "ready" || copy.state === "failed") mine.delete(one);
    }
    if (mine.size >= OUTSIDE_PENDING || starts.take(device.id) > 0) return false;
    mine.add(id);
    started.set(device.id, mine);
    return true;
  };

  return async (c, next) => {
    const { outside } = (c.env as AppEnv["Bindings"] | undefined) ?? {};
    // Not from the entrance: whatever went wrong, nothing is given.
    if (!outside) return c.body(null, 404);
    const route = matchedRoutes(c).find((one) => one.method !== "ALL");
    const pattern = route?.path ?? "";
    const decision = route ? outsideDecision(route.method, pattern) : null;
    const { device } = outside;
    // A household admin manages their household from wherever they are; a server admin acts
    // from home, as before.
    const householdAdmin = device.access === "householdAdmin";
    const closed =
      decision === "closed" ||
      (decision === "household" && !householdAdmin) ||
      (decision === "kids" && device.access === "viewer");
    outside.routeClass = closed ? "closed" : (decision ?? "none");
    if (decision === null) throw refusal("not_found", "There is nothing at this address.");
    if (closed) {
      // A child's device is not told what there is for others.
      throw device.kidsProfileId !== null
        ? refusal("not_found", "There is nothing here for this device.")
        : refusal("forbidden", "This can only be done at home.");
    }
    const busy = (): Error =>
      refusal("rate_limited", "This device is asking for a lot at once. Try again in a moment.");

    if (decision === "playback" && !mayStart(device, pattern, c.req.path)) {
      c.header("Retry-After", "30");
      throw busy();
    }
    const pool =
      decision === "stream" ||
      decision === "library" ||
      decision === "artwork" ||
      decision === "subtitle" ||
      decision === "live"
        ? slots[decision]
        : null;
    const release = pool ? pool.take(device.id) : undefined;
    if (release === null) {
      c.header("Retry-After", "5");
      throw busy();
    }
    if (release) {
      // Kept for as long as it costs something: until it is made, and until it is sent.
      let made = false;
      let sent = false;
      const done = (): void => {
        if (made && sent) release();
      };
      outside.onClosed(() => {
        sent = true;
        done();
      });
      try {
        await next();
      } finally {
        made = true;
        done();
      }
      return;
    }
    await next();
  };
}
