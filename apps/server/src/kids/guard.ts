// SPDX-License-Identifier: MPL-2.0
import type { MiddlewareHandler } from "hono";
import { matchedRoutes } from "hono/route";
import type { Device } from "../auth/devices.ts";
import type { Database } from "../db/database.ts";
import type { AppEnv } from "../http/app.ts";
import type { KidsControl } from "./control.ts";
import { kidsLimits, type KidsView } from "./limits.ts";
import type { ModeNow } from "./plan.ts";

/**
 * What a kids device may do at a route.
 *
 * - `open`: needs no credential, so it never comes here.
 * - `none`: nothing; it is not there for a kids device.
 * - `limited`: the handler itself answers with only what is allowed.
 * - `item`, `asset`, `artwork`, `logo`: only when the one it names is allowed.
 * - `viewer`: only for the device's own viewer. `viewer_item`: and only for an allowed title.
 * - `music_viewer`: music of the device's own viewer (`:profile`).
 */
export type KidsDecision =
  | "open"
  | "none"
  | "limited"
  | "item"
  | "asset"
  | "artwork"
  | "logo"
  | "viewer"
  | "viewer_item"
  | "music_viewer";

/**
 * A decision for every route there is. A route that is not here does not exist for a kids
 * device, and the tests fail until it is. `HEAD` follows `GET`.
 */
export const KIDS_ROUTES: Readonly<Record<string, KidsDecision>> = {
  "GET /v1/server": "open",
  "POST /v1/pairing/claim": "open",
  "POST /v1/pairing/requests": "open",
  "POST /v1/pairing/requests/:id/collect": "open",
  // Checked as the device that asked for the pass, with its limits, once inside.
  "GET /v1/airplay/:pass/*": "open",

  "GET /v1/me": "limited",
  "GET /v1/household": "limited",
  // Its own keys, and nothing of the library.
  "GET /v1/me/direct": "limited",
  "PUT /v1/me/direct": "limited",
  "PATCH /v1/me": "none",
  // Itself, to be told what to do, and the TVs it may play on. The hub decides what it sees:
  // only what plays as the child is controlled, and only what the child may see is started.
  "GET /v1/live": "limited",
  "POST /v1/live/:session": "limited",
  "POST /v1/live/:session/results": "limited",
  "POST /v1/remote/commands": "limited",
  // Only when the household lets kids turn on the TV (`remote.wake.kids`).
  "POST /v1/remote/wake": "limited",
  // Takes back only its own play.
  "DELETE /v1/remote/wake/:deviceId/plays/:id": "limited",
  "GET /v1/wake": "none",
  "PATCH /v1/wake": "none",
  "POST /v1/wake/scan": "none",
  "POST /v1/wake/pairings": "none",
  "POST /v1/wake/pairings/:id": "none",
  "DELETE /v1/wake/pairings/:id": "none",
  "PUT /v1/wake/televisions/:id": "none",
  "DELETE /v1/wake/televisions/:id": "none",
  // Kids control: its own plan, what it says of the places, its screen time, its questions.
  "GET /v1/me/kids": "limited",
  "PUT /v1/me/kids/place": "limited",
  "POST /v1/me/kids/screen-time": "limited",
  "POST /v1/me/kids/requests": "limited",
  "GET /v1/me/kids/requests/:id": "limited",
  "DELETE /v1/me/kids/requests/:id": "limited",
  // Grown-ups set and answer; a child does not.
  "GET /v1/kids/now": "none",
  "GET /v1/kids/requests": "none",
  "POST /v1/kids/requests/:id/answer": "none",
  "PUT /v1/household/time-zone": "none",
  "GET /v1/profiles/:id/kids/plan": "none",
  "PUT /v1/profiles/:id/kids/plan": "none",
  "PUT /v1/profiles/:id/kids/override": "none",
  "DELETE /v1/profiles/:id/kids/override": "none",
  "PATCH /v1/profiles/:id/kids/answer": "none",
  "DELETE /v1/profiles/:id/kids/answer": "none",
  // Push tokens and the push key: a child's device is told nothing, so it has none.
  "GET /v1/me/push": "none",
  "PUT /v1/me/push": "none",
  "DELETE /v1/me/push": "none",
  "GET /v1/settings/push": "none",
  "GET /v1/me/wanted": "limited",
  "POST /v1/me/downloads": "limited",
  "GET /v1/profiles": "limited",
  "GET /v1/library": "limited",
  // What it may see, filtered: the limits come first.
  "GET /v1/library/query": "limited",
  // The library within the limits; nothing from beyond it, a person only through allowed titles.
  "GET /v1/search": "limited",
  "GET /v1/search/people/:id": "limited",
  "GET /v1/search/outside": "none",
  "GET /v1/search/outside/:type/:id": "none",
  "GET /v1/search/picture": "none",
  "GET /v1/popular": "limited",
  "GET /v1/categories": "limited",
  "GET /v1/logos/:id": "logo",
  "GET /v1/items/:id": "item",
  "GET /v1/artwork/:id": "artwork",
  "GET /v1/profiles/:id/progress": "viewer",
  "PUT /v1/profiles/:id/progress/:item": "viewer_item",
  // The child's own picture, and nothing else of the viewer.
  "PUT /v1/profiles/:id/avatar": "viewer",
  // How the child's own subtitles look; offsets of allowed titles only.
  "PUT /v1/profiles/:id/subtitles": "viewer",
  // A grown-up chooses this for a child.
  "PUT /v1/profiles/:id/skipping": "none",
  "GET /v1/profiles/:id/subtitle-offsets/:item": "viewer_item",
  "PUT /v1/profiles/:id/subtitle-offsets/:item": "viewer_item",
  "GET /v1/assets/:id/content": "asset",
  "POST /v1/assets/:id/playback": "asset",
  "POST /v1/assets/:id/airplay": "asset",
  "GET /v1/assets/:id/prepared/:revision/master.m3u8": "asset",
  "GET /v1/assets/:id/prepared/:revision/subtitles/:playlist{[A-Za-z0-9_-]+\\.m3u8}": "asset",
  "GET /v1/assets/:id/prepared/:revision/:file": "asset",
  "GET /v1/assets/:id/subtitles/:subtitle{[A-Za-z0-9_-]+\\.vtt}": "asset",
  "GET /v1/assets/:id/subtitles/:subtitle{[A-Za-z0-9_-]+\\.json}": "asset",

  // Managers only.
  "GET /v1/households": "none",
  "POST /v1/households": "none",
  "GET /v1/households/:id": "none",
  "PATCH /v1/households/:id": "none",
  "DELETE /v1/households/:id": "none",
  "POST /v1/households/:id/invites": "none",
  "DELETE /v1/households/:id/invites/:invite": "none",
  "GET /v1/status": "none",
  "GET /v1/settings": "none",
  "PATCH /v1/settings": "none",
  "GET /v1/settings/history": "none",
  "POST /v1/settings/history/:version/restore": "none",
  "GET /v1/settings/audit": "none",
  "GET /v1/settings/browse": "none",
  "PUT /v1/settings/tmdb": "none",
  "DELETE /v1/settings/tmdb": "none",
  "PUT /v1/settings/omdb": "none",
  "DELETE /v1/settings/omdb": "none",
  "GET /v1/setup": "none",
  "POST /v1/setup/steps/:step": "none",
  "POST /v1/setup/finish": "none",
  "GET /v1/pairing/requests": "none",
  "DELETE /v1/pairing/requests/:id": "none",
  "GET /v1/household/invites": "none",
  "POST /v1/household/invites": "none",
  "DELETE /v1/household/invites/:invite": "none",
  "POST /v1/pairing/approve": "none",
  "GET /v1/outside": "none",
  "PATCH /v1/outside": "none",
  "POST /v1/outside/window": "none",
  "DELETE /v1/outside/window": "none",
  "POST /v1/outside/pairing/:id/approve": "none",
  "DELETE /v1/outside/pairing/:id": "none",
  "GET /v1/outside/access": "none",
  "GET /v1/devices": "none",
  "PATCH /v1/devices/:id": "none",
  "DELETE /v1/devices/:id": "none",
  "GET /v1/devices/wanted": "none",
  "GET /v1/devices/:id/wanted": "none",
  "POST /v1/devices/:id/wanted": "none",
  "DELETE /v1/devices/:id/wanted/:wantedId": "none",
  // A device that belongs to a child cannot be left at all.
  "GET /v1/kids/code": "none",
  "PUT /v1/kids/code": "none",
  "POST /v1/kids/code/check": "none",
  "POST /v1/profiles": "none",
  "PATCH /v1/profiles/:id": "none",
  // What happens at the end is the grown-ups' to choose for a child (docs/api.md, Profiles).
  "PUT /v1/profiles/:id/playback": "none",
  "DELETE /v1/profiles/:id": "none",
  "GET /v1/items/:id/edit": "none",
  "PATCH /v1/items/:id": "none",
  "GET /v1/items/:id/artwork-options": "none",
  "GET /v1/items/:id/artwork-options/preview": "none",
  "POST /v1/items/:id/artwork": "none",
  "POST /v1/items/:id/artwork/upload": "none",
  "DELETE /v1/items/:id/artwork": "none",
  "GET /v1/items/:id/match": "none",
  "PUT /v1/items/:id/match": "none",
  "DELETE /v1/items/:id/match": "none",
  "POST /v1/items/:id/match/automatic": "none",
  "GET /v1/categories/edit": "none",
  "POST /v1/categories/groups": "none",
  "PUT /v1/categories/groups/order": "none",
  "PATCH /v1/categories/groups/:id": "none",
  "DELETE /v1/categories/groups/:id": "none",
  "PUT /v1/categories/folders/:id": "none",
  "GET /v1/categories/logo-search": "none",
  "GET /v1/categories/logo-search/preview": "none",
  "PUT /v1/categories/groups/:id/logo": "none",
  "POST /v1/categories/groups/:id/logo/upload": "none",
  "DELETE /v1/categories/groups/:id/logo": "none",
  "PUT /v1/categories/:id/logo": "none",
  "POST /v1/categories/:id/logo/upload": "none",
  "DELETE /v1/categories/:id/logo": "none",
  "POST /v1/categories": "none",
  "PUT /v1/categories/order": "none",
  "POST /v1/categories/arrange": "none",
  "GET /v1/categories/suggestions": "none",
  "POST /v1/categories/suggestions/:id/accept": "none",
  "POST /v1/categories/suggestions/accept": "none",
  "POST /v1/categories/suggestions/:id/dismiss": "none",
  "POST /v1/categories/merge": "none",
  "POST /v1/categories/arrange/undo": "none",
  "PATCH /v1/categories/:id": "none",
  "DELETE /v1/categories/:id": "none",
  "GET /v1/imports": "none",
  "GET /v1/imports/items": "none",
  "GET /v1/imports/items/:id": "none",
  "POST /v1/imports/items/:id/confirm": "none",
  "POST /v1/imports/items/:id/dismiss": "none",
  "POST /v1/imports/items/:id/clean-up": "none",
  "POST /v1/imports/items/:id/convert": "none",
  "GET /v1/imports/activity": "none",
  "POST /v1/imports/scan": "none",
  "GET /v1/uploads": "none",
  "POST /v1/uploads": "none",
  "GET /v1/uploads/:id": "none",
  "PATCH /v1/uploads/:id": "none",
  "POST /v1/uploads/:id/complete": "none",
  "DELETE /v1/uploads/:id": "none",
  "GET /v1/markers": "none",
  "GET /v1/markers/assets/:id": "none",
  "PUT /v1/markers/assets/:id": "none",
  "DELETE /v1/markers/assets/:id": "none",
  "POST /v1/markers/items/:id/detect": "none",
  "GET /v1/conversion": "none",
  "POST /v1/conversion/jobs": "none",
  "POST /v1/conversion/pause": "none",
  "POST /v1/conversion/resume": "none",
  "DELETE /v1/conversion/jobs/:id": "none",
  "POST /v1/conversion/jobs/:id/move": "none",
  "POST /v1/conversion/claim": "none",
  "POST /v1/conversion/jobs/:id/heartbeat": "none",
  "GET /v1/conversion/jobs/:id/upload": "none",
  "PATCH /v1/conversion/jobs/:id/upload": "none",
  "POST /v1/conversion/jobs/:id/complete": "none",
  "POST /v1/conversion/jobs/:id/release": "none",
  "GET /v1/conversion/replacements": "none",
  "POST /v1/conversion/replacements/:id/undo": "none",
  "POST /v1/conversion/replacements/:id/purge": "none",

  // Music and audiobooks, all of the household's, once a grown-up turned them on for this
  // child; the plan's mode then says when (docs/decisions.md, "Kids control"). Without that, none of it is there.
  "GET /v1/music/library": "limited",
  "GET /v1/music/artists/:id": "limited",
  "GET /v1/music/albums/:id": "limited",
  "GET /v1/music/tracks/:id": "limited",
  "GET /v1/music/books/:id": "limited",
  "GET /v1/music/status": "none",
  "GET /v1/music/covers/:id": "limited",
  "GET /v1/music/tracks/:id/content": "limited",
  "POST /v1/music/tracks/:id/playback": "limited",
  "GET /v1/music/tracks/:id/copies/:revision/:file": "limited",
  "GET /v1/music/artists/:id/edit": "none",
  "PATCH /v1/music/artists/:id": "none",
  "GET /v1/music/albums/:id/edit": "none",
  "PATCH /v1/music/albums/:id": "none",
  "GET /v1/music/tracks/:id/edit": "none",
  "PATCH /v1/music/tracks/:id": "none",
  "GET /v1/music/books/:id/edit": "none",
  "PATCH /v1/music/books/:id": "none",
  "GET /v1/music/profiles/:profile/favourites": "music_viewer",
  "PUT /v1/music/profiles/:profile/favourites/:item": "music_viewer",
  "GET /v1/music/profiles/:profile/playlists": "music_viewer",
  "POST /v1/music/profiles/:profile/playlists": "music_viewer",
  "GET /v1/music/profiles/:profile/playlists/:id": "music_viewer",
  "PATCH /v1/music/profiles/:profile/playlists/:id": "music_viewer",
  "POST /v1/music/profiles/:profile/playlists/:id/tracks": "music_viewer",
  "DELETE /v1/music/profiles/:profile/playlists/:id": "music_viewer",
  "GET /v1/music/profiles/:profile/playlists/:id/export.m3u8": "music_viewer",
  "POST /v1/music/profiles/:profile/plays": "music_viewer",
  "GET /v1/music/profiles/:profile/plays": "music_viewer",
  "GET /v1/music/profiles/:profile/play-counts": "music_viewer",
  "DELETE /v1/music/profiles/:profile/plays": "music_viewer",
  "GET /v1/music/profiles/:profile/progress": "music_viewer",
  "PUT /v1/music/profiles/:profile/progress/:item": "music_viewer",
  // No statistics for children, their own included (docs/decisions.md, "Who sees which statistics").
  "GET /v1/stats/viewers/:id": "none",
  "DELETE /v1/stats/viewers/:id/history/:session": "none",
  "DELETE /v1/stats/viewers/:id": "none",
  "GET /v1/stats/household": "none",
  "GET /v1/stats/server": "none",
};

/**
 * What the mode of a child's plan has to allow for a route (docs/kids-control.md), for every
 * route a kids device may use at all. One that is missing is refused: the tests fail until it
 * has one.
 *
 * - `always`: what keeps the app going and tells it its mode; never a title or a song.
 * - `app`: anything but Nothing (and Ask to open before an answer).
 * - `browse`: films and series may be looked at.
 * - `watch`: video may play: all of it, or the title an answer allowed.
 * - `listen`: music and audiobooks may play.
 */
export type ModeNeed = "always" | "app" | "browse" | "watch" | "listen";

export const KIDS_MODE_ROUTES: Readonly<Record<string, ModeNeed>> = {
  "GET /v1/me": "always",
  "GET /v1/household": "always",
  "GET /v1/me/direct": "always",
  "PUT /v1/me/direct": "always",
  "GET /v1/live": "always",
  "POST /v1/live/:session": "always",
  "POST /v1/live/:session/results": "always",
  // The hub decides per command: stopping is always allowed, playing only what may play.
  "POST /v1/remote/commands": "always",
  "POST /v1/remote/wake": "watch",
  // Taking back its own play for a woken TV is stopping, which is always allowed.
  "DELETE /v1/remote/wake/:deviceId/plays/:id": "always",
  "GET /v1/me/kids": "always",
  "PUT /v1/me/kids/place": "always",
  "POST /v1/me/kids/screen-time": "always",
  "POST /v1/me/kids/requests": "always",
  "GET /v1/me/kids/requests/:id": "always",
  "DELETE /v1/me/kids/requests/:id": "always",
  "GET /v1/profiles": "always",
  // What it has on the device, said to the server; and where a film stopped at a switch.
  "POST /v1/me/downloads": "always",
  "PUT /v1/profiles/:id/progress/:item": "always",
  "PUT /v1/profiles/:id/avatar": "app",
  "PUT /v1/profiles/:id/subtitles": "app",
  "GET /v1/me/wanted": "browse",
  "GET /v1/library": "browse",
  "GET /v1/library/query": "browse",
  "GET /v1/popular": "browse",
  "GET /v1/categories": "browse",
  "GET /v1/logos/:id": "browse",
  "GET /v1/items/:id": "browse",
  "GET /v1/artwork/:id": "browse",
  "GET /v1/profiles/:id/progress": "browse",
  "GET /v1/search": "browse",
  "GET /v1/search/people/:id": "browse",
  "GET /v1/assets/:id/content": "watch",
  "POST /v1/assets/:id/playback": "watch",
  "POST /v1/assets/:id/airplay": "watch",
  "GET /v1/assets/:id/prepared/:revision/master.m3u8": "watch",
  "GET /v1/assets/:id/prepared/:revision/subtitles/:playlist{[A-Za-z0-9_-]+\\.m3u8}": "watch",
  "GET /v1/assets/:id/prepared/:revision/:file": "watch",
  "GET /v1/assets/:id/subtitles/:subtitle{[A-Za-z0-9_-]+\\.vtt}": "watch",
  "GET /v1/assets/:id/subtitles/:subtitle{[A-Za-z0-9_-]+\\.json}": "watch",
  "GET /v1/profiles/:id/subtitle-offsets/:item": "watch",
  "PUT /v1/profiles/:id/subtitle-offsets/:item": "watch",
  "GET /v1/music/library": "listen",
  "GET /v1/music/artists/:id": "listen",
  "GET /v1/music/albums/:id": "listen",
  "GET /v1/music/tracks/:id": "listen",
  "GET /v1/music/books/:id": "listen",
  "GET /v1/music/covers/:id": "listen",
  "GET /v1/music/tracks/:id/content": "listen",
  "POST /v1/music/tracks/:id/playback": "listen",
  "GET /v1/music/tracks/:id/copies/:revision/:file": "listen",
  "GET /v1/music/profiles/:profile/favourites": "listen",
  "PUT /v1/music/profiles/:profile/favourites/:item": "listen",
  "GET /v1/music/profiles/:profile/playlists": "listen",
  "POST /v1/music/profiles/:profile/playlists": "listen",
  "GET /v1/music/profiles/:profile/playlists/:id": "listen",
  "PATCH /v1/music/profiles/:profile/playlists/:id": "listen",
  "POST /v1/music/profiles/:profile/playlists/:id/tracks": "listen",
  "DELETE /v1/music/profiles/:profile/playlists/:id": "listen",
  "GET /v1/music/profiles/:profile/playlists/:id/export.m3u8": "listen",
  "POST /v1/music/profiles/:profile/plays": "listen",
  "GET /v1/music/profiles/:profile/plays": "listen",
  "GET /v1/music/profiles/:profile/play-counts": "listen",
  "DELETE /v1/music/profiles/:profile/plays": "listen",
  "GET /v1/music/profiles/:profile/progress": "listen",
  "PUT /v1/music/profiles/:profile/progress/:item": "listen",
};

/** How often a running answer is checked again. */
const RECHECK_MS = 1_000;

// Ids are words of these. Anything that would need decoding is not an id.
const ID = /^[A-Za-z0-9_-]{1,128}$/;

/** The value of a parameter of `pattern` in `path`. */
function param(pattern: string, path: string, name: string): string | null {
  const index = pattern.split("/").indexOf(`:${name}`);
  const value = index === -1 ? undefined : path.split("/")[index];
  return value !== undefined && ID.test(value) ? value : null;
}

/** The same body, cut off as soon as `allowed` says no. */
function guarded(
  body: ReadableStream<Uint8Array>,
  allowed: () => boolean,
): ReadableStream<Uint8Array> {
  const reader = body.getReader();
  let checkedAt = Date.now();
  // Not in the same turn as a read: a file that was just asked for more still hands it over
  // when that turn ends, and Node throws from outside any handler if its stream is closed then.
  const stop = async (reason: unknown): Promise<void> => {
    await new Promise((done) => setImmediate(done));
    await reader.cancel(reason);
  };
  return new ReadableStream<Uint8Array>(
    {
      async pull(controller) {
        const { done, value } = await reader.read();
        if (done) {
          controller.close();
          return;
        }
        if (Date.now() - checkedAt >= RECHECK_MS) {
          checkedAt = Date.now();
          if (!allowed()) {
            const error = new Error("This device may no longer have this.");
            controller.error(error);
            await stop(error);
            return;
          }
        }
        controller.enqueue(value);
      },
      cancel: stop,
    },
    { highWaterMark: 0 },
  );
}

interface GuardDeps {
  db: Database;
  /** Whether a logo belongs to a category or group this viewer sees. */
  showsLogo: (view: KidsView, logoId: string) => boolean;
  notFound: () => Error;
  /** When and what: the plan of the child a device belongs to. */
  control: KidsControl;
  /** Whether a request came from away: the outside entrance, or the tailnet. */
  isAway: (c: Parameters<MiddlewareHandler<AppEnv>>[0]) => boolean;
  /** The plan's mode does not allow this now; the app is told the mode. */
  modeRefusal: (state: ModeNow) => Error;
}

/** Whether an asset belongs to one of these titles, or to something inside one. */
function inTitles(db: Database, assetId: string, titles: readonly string[]): boolean {
  if (titles.length === 0) return false;
  return (
    db.get(
      `with recursive up (id, parent_id) as (
         select item.id, item.parent_id from item_asset join item on item.id = item_asset.item_id
         where item_asset.asset_id = ?
         union select item.id, item.parent_id from item join up on item.id = up.parent_id)
       select 1 as x from up where id in (select value from json_each(?)) limit 1`,
      [assetId, JSON.stringify(titles)],
    ) !== undefined
  );
}

/**
 * Whether the mode allows what a route needs. Music not turned on for the child is not there at
 * all (`null`), as before there were plans.
 */
export function modeAllows(
  db: Database,
  need: ModeNeed | undefined,
  state: ModeNow,
  music: boolean,
  assetId: string | null,
): boolean | null {
  switch (need) {
    case "always":
      return true;
    case "app":
      return state.browse || state.listening || state.video !== "none";
    case "browse":
      return state.browse;
    case "watch":
      if (state.video === "all") return true;
      return state.video === "titles" && assetId !== null && inTitles(db, assetId, state.titles);
    case "listen":
      return music ? state.listening : null;
    default:
      return false;
  }
}

/**
 * Stands between every route and a kids device. Mount it right after the device is known:
 * what it refuses must not reach anything else, not even to count as activity.
 */
export function kidsGuard(deps: GuardDeps): MiddlewareHandler<AppEnv> {
  const { db } = deps;
  const limits = kidsLimits(db);

  const permits = (
    device: Device,
    view: KidsView,
    key: string,
    pattern: string,
    path: string,
  ): boolean => {
    const id = param(pattern, path, "id");
    const decision = KIDS_ROUTES[key];
    // A guest household with a part of the library: only what names a title is looked at here.
    // What else it may do is the household guard's to say (households/guard.ts).
    if (device.kidsProfileId === null) {
      if (decision === "viewer_item") {
        const item = param(pattern, path, "item");
        return item !== null && view.items.has(item);
      }
      const named = decision === "item" || decision === "asset" || decision === "artwork";
      if (!named && decision !== "logo") return true;
    }
    switch (decision) {
      case "limited":
        return true;
      case "item":
        return id !== null && view.items.has(id);
      case "asset":
        return id !== null && view.assets.has(id);
      case "artwork": {
        const art =
          id === null
            ? undefined
            : db.get<{ item_id: string }>("select item_id from artwork where id = ?", [id]);
        return art !== undefined && view.items.has(art.item_id);
      }
      case "logo":
        return id !== null && deps.showsLogo(view, id);
      case "viewer":
        return id !== null && id === device.kidsProfileId;
      case "viewer_item": {
        const item = param(pattern, path, "item");
        return id !== null && id === device.kidsProfileId && item !== null && view.items.has(item);
      }
      case "music_viewer":
        return param(pattern, path, "profile") === device.kidsProfileId;
      default:
        return false;
    }
  };

  /** What the child's plan allows here now; null for a device that is no child's. */
  const allowedNow = (
    device: Device,
    key: string,
    pattern: string,
    path: string,
    away: boolean,
  ): { state: ModeNow; allowed: boolean | null } | null => {
    if (device.kidsProfileId === null) return null;
    const state = control.state(device.kidsProfileId, device.id, away);
    const plan = control.plan(device.kidsProfileId);
    const asset = key.includes("/v1/assets/") ? param(pattern, path, "id") : null;
    const need = Object.hasOwn(KIDS_MODE_ROUTES, key) ? KIDS_MODE_ROUTES[key] : undefined;
    const allowed = modeAllows(db, need, state, plan.music, asset);
    // A song of a music library the child was not given is not there for it.
    if (
      allowed === true &&
      plan.musicSourceIds !== null &&
      key.startsWith("GET /v1/music/tracks/:id")
    ) {
      const track = param(pattern, path, "id");
      const source = db.get<{ source_id: string }>(
        "select source_id from music_track where id = ?",
        [track ?? ""],
      )?.source_id;
      if (source === undefined || !plan.musicSourceIds.includes(source)) {
        return { state, allowed: null };
      }
    }
    if (
      allowed === true &&
      plan.musicSourceIds !== null &&
      key === "POST /v1/music/tracks/:id/playback"
    ) {
      const source = db.get<{ source_id: string }>(
        "select source_id from music_track where id = ?",
        [param(pattern, path, "id") ?? ""],
      )?.source_id;
      if (source === undefined || !plan.musicSourceIds.includes(source))
        return { state, allowed: null };
    }
    return { state, allowed };
  };

  const { control } = deps;

  return async (c, next) => {
    const device = c.get("device");
    const away = deps.isAway(c);
    control.noteRoad(device.id, away);
    const view = limits.deviceView(device);
    c.set("kids", view);
    // Middleware is registered for all methods; the first other match answers the request.
    const route = matchedRoutes(c).find((one) => one.method !== "ALL");
    const pattern = route?.path ?? "";
    const key = `${route?.method === "HEAD" ? "GET" : (route?.method ?? "")} ${pattern}`;
    const path = c.req.path;
    if (view && !permits(device, view, key, pattern, path)) throw deps.notFound();
    // When and what: after which, so a known id still tells nothing.
    const mode = allowedNow(device, key, pattern, path, away);
    if (mode?.allowed === null) throw deps.notFound();
    if (mode?.allowed === false) throw deps.modeRefusal(mode.state);

    await next();

    // A film that is being sent goes on for as long as it plays, so it is looked at again. Also
    // for a device that had no limits when it began: it may get them, or be removed, meanwhile.
    const streams = key.startsWith("GET /v1/assets/") || key.startsWith("GET /v1/music/tracks/");
    if (!streams || !c.res.body || c.req.method === "HEAD") return;
    const response = c.res;
    const body = guarded(response.body as ReadableStream<Uint8Array>, () => {
      const row = db.get<{ kids_profile_id: string | null }>(
        "select kids_profile_id from device where id = ? and revoked_at is null",
        [device.id],
      );
      if (!row) return false;
      const bound = { ...device, kidsProfileId: row.kids_profile_id };
      const now = limits.deviceView(bound);
      if (now === null) return true;
      // Also a switch of the plan's mode: a film stops at bedtime.
      const again = allowedNow(bound, key, pattern, path, away);
      if (again && again.allowed !== true) return false;
      return permits(bound, now, key, pattern, path);
    });
    c.res = new Response(body, { status: response.status, headers: response.headers });
  };
}
