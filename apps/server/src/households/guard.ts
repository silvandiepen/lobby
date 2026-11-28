// SPDX-License-Identifier: MPL-2.0
import type { MiddlewareHandler } from "hono";
import { matchedRoutes } from "hono/route";
import type { Database } from "../db/database.ts";
import type { AppEnv } from "../http/app.ts";
import type { Bandwidth } from "./bandwidth.ts";
import { OWNER_HOUSEHOLD } from "./owner.ts";

/**
 * What a route is to the households that share the server.
 *
 * - `open`: needs no credential, so it never comes here.
 * - `owner`: the server's own: its library, settings, folders, conversion, categories, the
 *   outside switch, Apple TVs and the households. Only devices of the owner's household; for
 *   any other it is not there.
 * - `household`: about the device's own household only; the handler keeps to it.
 * - `profile`: names a viewer (`:id`), who must be of the device's household.
 * - `device`: names a device (`:id`), which must be of the device's household.
 * - `library`: the library everybody shares, as far as the household and kids limits allow.
 * - `music`: the audio library, not for a household that sees only a part of the library: no
 *   part of it says what music is in it.
 * - `music_profile`: the same, for a viewer (`:profile`) of the device's household.
 * - `stats_profile`: a viewer (`:id`) of the device's household; for a server admin of any
 *   household (docs/decisions.md, "Who sees which statistics"). The routes say who else may.
 * - `kids_profile`: a kids viewer (`:id`) of the device's household; for a server admin also of
 *   a guest household, whose children the server owner may answer for too (docs/decisions.md, "Kids control").
 */
export type HouseholdDecision =
  | "open"
  | "owner"
  | "household"
  | "profile"
  | "kids_profile"
  | "stats_profile"
  | "device"
  | "library"
  | "music"
  | "music_profile";

/**
 * A decision for every route there is. A route that is not here does not exist for a guest
 * household, and the tests fail until it is. `HEAD` follows `GET`.
 */
export const HOUSEHOLD_ROUTES: Readonly<Record<string, HouseholdDecision>> = {
  "GET /v1/server": "open",
  "POST /v1/pairing/claim": "open",
  "POST /v1/pairing/requests": "open",
  "POST /v1/pairing/requests/:id/collect": "open",
  "GET /v1/airplay/:pass/*": "open",

  "GET /v1/me": "household",
  "GET /v1/me/direct": "household",
  "PUT /v1/me/direct": "household",
  "PATCH /v1/me": "household",
  "GET /v1/household": "household",
  // Only the devices of the same household are seen, controlled and woken.
  "GET /v1/live": "household",
  "POST /v1/live/:session": "household",
  "POST /v1/live/:session/results": "household",
  "POST /v1/remote/commands": "household",
  "GET /v1/me/wanted": "household",
  "POST /v1/me/downloads": "household",
  "GET /v1/profiles": "household",
  "POST /v1/profiles": "household",
  "PATCH /v1/profiles/:id": "profile",
  "DELETE /v1/profiles/:id": "profile",
  "PUT /v1/profiles/:id/avatar": "profile",
  "PUT /v1/profiles/:id/subtitles": "profile",
  "PUT /v1/profiles/:id/playback": "profile",
  "PUT /v1/profiles/:id/skipping": "profile",
  "GET /v1/profiles/:id/subtitle-offsets/:item": "profile",
  "PUT /v1/profiles/:id/subtitle-offsets/:item": "profile",
  "GET /v1/profiles/:id/progress": "profile",
  "PUT /v1/profiles/:id/progress/:item": "profile",
  "GET /v1/kids/code": "household",
  // Kids control (docs/kids-control.md): the device's own child, or a kids viewer it names,
  // which must be of its household; the routes check that too.
  "GET /v1/me/push": "household",
  "PUT /v1/me/push": "household",
  "DELETE /v1/me/push": "household",
  "GET /v1/settings/push": "owner",
  "GET /v1/me/kids": "household",
  "PUT /v1/me/kids/place": "household",
  "POST /v1/me/kids/screen-time": "household",
  "POST /v1/me/kids/requests": "household",
  "GET /v1/me/kids/requests/:id": "household",
  "DELETE /v1/me/kids/requests/:id": "household",
  "GET /v1/kids/now": "household",
  "GET /v1/kids/requests": "household",
  "POST /v1/kids/requests/:id/answer": "household",
  "PUT /v1/household/time-zone": "household",
  "GET /v1/profiles/:id/kids/plan": "kids_profile",
  "PUT /v1/profiles/:id/kids/plan": "kids_profile",
  "PUT /v1/profiles/:id/kids/override": "kids_profile",
  "DELETE /v1/profiles/:id/kids/override": "kids_profile",
  "PATCH /v1/profiles/:id/kids/answer": "kids_profile",
  "DELETE /v1/profiles/:id/kids/answer": "kids_profile",
  "PUT /v1/kids/code": "household",
  "POST /v1/kids/code/check": "household",
  "GET /v1/pairing/requests": "household",
  "POST /v1/pairing/approve": "household",
  // A server admin's no to a device a household admin let in at home.
  "DELETE /v1/pairing/requests/:id": "owner",
  "GET /v1/household/invites": "household",
  "POST /v1/household/invites": "household",
  "DELETE /v1/household/invites/:invite": "household",
  "GET /v1/devices": "household",
  "PATCH /v1/devices/:id": "device",
  "DELETE /v1/devices/:id": "device",
  "GET /v1/devices/wanted": "household",
  "GET /v1/devices/:id/wanted": "device",
  "POST /v1/devices/:id/wanted": "device",
  "DELETE /v1/devices/:id/wanted/:wantedId": "device",
  // A household's manager lets its own devices in, from wherever that household is.
  "POST /v1/outside/window": "household",
  "DELETE /v1/outside/window": "household",
  "POST /v1/outside/pairing/:id/approve": "household",
  "DELETE /v1/outside/pairing/:id": "household",
  "GET /v1/outside/access": "household",

  "GET /v1/library": "library",
  // Filtered through the household's and kids limits like the library itself.
  "GET /v1/library/query": "library",
  // The library as far as the household sees it; beyond it what TMDB says, which is nobody's.
  "GET /v1/search": "library",
  "GET /v1/search/people/:id": "library",
  "GET /v1/search/outside": "library",
  "GET /v1/search/outside/:type/:id": "library",
  "GET /v1/search/picture": "library",
  "GET /v1/popular": "library",
  "GET /v1/categories": "library",
  "GET /v1/logos/:id": "library",
  "GET /v1/items/:id": "library",
  "GET /v1/artwork/:id": "library",
  "GET /v1/assets/:id/content": "library",
  "POST /v1/assets/:id/playback": "library",
  "POST /v1/assets/:id/airplay": "library",
  "GET /v1/assets/:id/prepared/:revision/master.m3u8": "library",
  "GET /v1/assets/:id/prepared/:revision/subtitles/:playlist{[A-Za-z0-9_-]+\\.m3u8}": "library",
  "GET /v1/assets/:id/prepared/:revision/:file": "library",
  "GET /v1/assets/:id/subtitles/:subtitle{[A-Za-z0-9_-]+\\.vtt}": "library",
  "GET /v1/assets/:id/subtitles/:subtitle{[A-Za-z0-9_-]+\\.json}": "library",

  "GET /v1/households": "owner",
  "POST /v1/households": "owner",
  "GET /v1/households/:id": "owner",
  "PATCH /v1/households/:id": "owner",
  "DELETE /v1/households/:id": "owner",
  "POST /v1/households/:id/invites": "owner",
  "DELETE /v1/households/:id/invites/:invite": "owner",
  "GET /v1/status": "owner",
  "GET /v1/settings": "owner",
  "PATCH /v1/settings": "owner",
  "GET /v1/settings/history": "owner",
  "POST /v1/settings/history/:version/restore": "owner",
  "GET /v1/settings/audit": "owner",
  "GET /v1/settings/browse": "owner",
  "PUT /v1/settings/tmdb": "owner",
  "DELETE /v1/settings/tmdb": "owner",
  "PUT /v1/settings/omdb": "owner",
  "DELETE /v1/settings/omdb": "owner",
  "GET /v1/setup": "owner",
  "POST /v1/setup/steps/:step": "owner",
  "POST /v1/setup/finish": "owner",
  "GET /v1/outside": "owner",
  "PATCH /v1/outside": "owner",
  // The Apple TVs that can be woken are on the owner's network: another household's cannot be
  // reached from here (docs/decisions.md, "Households").
  "GET /v1/wake": "owner",
  "PATCH /v1/wake": "owner",
  "POST /v1/wake/scan": "owner",
  "POST /v1/wake/pairings": "owner",
  "POST /v1/wake/pairings/:id": "owner",
  "DELETE /v1/wake/pairings/:id": "owner",
  "PUT /v1/wake/televisions/:id": "owner",
  "DELETE /v1/wake/televisions/:id": "owner",
  "POST /v1/remote/wake": "owner",
  "DELETE /v1/remote/wake/:deviceId/plays/:id": "owner",
  // The speakers are on the owner's network, as the Apple TVs that can be woken.
  "GET /v1/speakers": "owner",
  "PATCH /v1/speakers": "owner",
  "POST /v1/speakers/scan": "owner",
  "PATCH /v1/speakers/:id": "owner",
  "PUT /v1/speakers/:id/password": "owner",
  "POST /v1/speakers/:id/play": "owner",
  "POST /v1/speakers/:id/control": "owner",
  "GET /v1/items/:id/edit": "owner",
  "PATCH /v1/items/:id": "owner",
  "GET /v1/items/:id/artwork-options": "owner",
  "GET /v1/items/:id/artwork-options/preview": "owner",
  "POST /v1/items/:id/artwork": "owner",
  "POST /v1/items/:id/artwork/upload": "owner",
  "DELETE /v1/items/:id/artwork": "owner",
  "GET /v1/markers": "owner",
  "GET /v1/markers/assets/:id": "owner",
  "PUT /v1/markers/assets/:id": "owner",
  "DELETE /v1/markers/assets/:id": "owner",
  "POST /v1/markers/items/:id/detect": "owner",
  "GET /v1/items/:id/match": "owner",
  "PUT /v1/items/:id/match": "owner",
  "DELETE /v1/items/:id/match": "owner",
  "POST /v1/items/:id/match/automatic": "owner",
  "GET /v1/categories/edit": "owner",
  "POST /v1/categories/groups": "owner",
  "PUT /v1/categories/groups/order": "owner",
  "PATCH /v1/categories/groups/:id": "owner",
  "DELETE /v1/categories/groups/:id": "owner",
  "PUT /v1/categories/folders/:id": "owner",
  "GET /v1/categories/logo-search": "owner",
  "GET /v1/categories/logo-search/preview": "owner",
  "PUT /v1/categories/groups/:id/logo": "owner",
  "POST /v1/categories/groups/:id/logo/upload": "owner",
  "DELETE /v1/categories/groups/:id/logo": "owner",
  "PUT /v1/categories/:id/logo": "owner",
  "POST /v1/categories/:id/logo/upload": "owner",
  "DELETE /v1/categories/:id/logo": "owner",
  "POST /v1/categories": "owner",
  "PUT /v1/categories/order": "owner",
  "POST /v1/categories/arrange": "owner",
  "GET /v1/categories/suggestions": "owner",
  "POST /v1/categories/suggestions/:id/accept": "owner",
  "POST /v1/categories/suggestions/:id/dismiss": "owner",
  "POST /v1/categories/suggestions/accept": "owner",
  "POST /v1/categories/merge": "owner",
  "POST /v1/categories/arrange/undo": "owner",
  "PATCH /v1/categories/:id": "owner",
  "DELETE /v1/categories/:id": "owner",
  "GET /v1/conversion": "owner",
  "POST /v1/conversion/jobs": "owner",
  "POST /v1/conversion/pause": "owner",
  "POST /v1/conversion/resume": "owner",
  "DELETE /v1/conversion/jobs/:id": "owner",
  "POST /v1/conversion/jobs/:id/move": "owner",
  "POST /v1/conversion/claim": "owner",
  "POST /v1/conversion/jobs/:id/heartbeat": "owner",
  "GET /v1/conversion/jobs/:id/upload": "owner",
  "PATCH /v1/conversion/jobs/:id/upload": "owner",
  "POST /v1/conversion/jobs/:id/complete": "owner",
  "POST /v1/conversion/jobs/:id/release": "owner",
  "GET /v1/conversion/replacements": "owner",
  "POST /v1/conversion/replacements/:id/undo": "owner",
  "POST /v1/conversion/replacements/:id/purge": "owner",
  // Import folders and uploads write into the library folders: the server's own (docs/decisions.md, "Import folders and uploads").
  "GET /v1/imports": "owner",
  "GET /v1/imports/items": "owner",
  "GET /v1/imports/items/:id": "owner",
  "POST /v1/imports/items/:id/confirm": "owner",
  "POST /v1/imports/items/:id/dismiss": "owner",
  "POST /v1/imports/items/:id/clean-up": "owner",
  "POST /v1/imports/items/:id/convert": "owner",
  "GET /v1/imports/activity": "owner",
  "POST /v1/imports/scan": "owner",
  "GET /v1/uploads": "owner",
  "POST /v1/uploads": "owner",
  "GET /v1/uploads/:id": "owner",
  "PATCH /v1/uploads/:id": "owner",
  "POST /v1/uploads/:id/complete": "owner",
  "DELETE /v1/uploads/:id": "owner",
  "GET /v1/music/status": "owner",
  "GET /v1/music/artists/:id/edit": "owner",
  "PATCH /v1/music/artists/:id": "owner",
  "GET /v1/music/albums/:id/edit": "owner",
  "PATCH /v1/music/albums/:id": "owner",
  "GET /v1/music/tracks/:id/edit": "owner",
  "PATCH /v1/music/tracks/:id": "owner",
  "GET /v1/music/books/:id/edit": "owner",
  "PATCH /v1/music/books/:id": "owner",

  "GET /v1/music/library": "music",
  "GET /v1/music/artists/:id": "music",
  "GET /v1/music/albums/:id": "music",
  "GET /v1/music/tracks/:id": "music",
  "GET /v1/music/books/:id": "music",
  "GET /v1/music/covers/:id": "music",
  "GET /v1/music/tracks/:id/content": "music",
  "POST /v1/music/tracks/:id/playback": "music",
  "GET /v1/music/tracks/:id/copies/:revision/:file": "music",
  "GET /v1/music/profiles/:profile/favourites": "music_profile",
  "PUT /v1/music/profiles/:profile/favourites/:item": "music_profile",
  "GET /v1/music/profiles/:profile/playlists": "music_profile",
  "POST /v1/music/profiles/:profile/playlists": "music_profile",
  "GET /v1/music/profiles/:profile/playlists/:id": "music_profile",
  "PATCH /v1/music/profiles/:profile/playlists/:id": "music_profile",
  "POST /v1/music/profiles/:profile/playlists/:id/tracks": "music_profile",
  "DELETE /v1/music/profiles/:profile/playlists/:id": "music_profile",
  "GET /v1/music/profiles/:profile/playlists/:id/export.m3u8": "music_profile",
  "POST /v1/music/profiles/:profile/plays": "music_profile",
  "GET /v1/music/profiles/:profile/plays": "music_profile",
  "GET /v1/music/profiles/:profile/play-counts": "music_profile",
  "DELETE /v1/music/profiles/:profile/plays": "music_profile",
  "GET /v1/music/profiles/:profile/progress": "music_profile",
  "PUT /v1/music/profiles/:profile/progress/:item": "music_profile",
  // Statistics: a viewer of the household's own, any for a server admin; a household's overview
  // for its admins; the server's for the owner's admins. The routes keep a viewer to their own.
  "GET /v1/stats/viewers/:id": "stats_profile",
  "DELETE /v1/stats/viewers/:id/history/:session": "stats_profile",
  "DELETE /v1/stats/viewers/:id": "stats_profile",
  "GET /v1/stats/household": "household",
  "GET /v1/stats/server": "owner",
};

/**
 * Who in a household may ask at a route, beside where it is: `admin` a server admin only,
 * `householdAdmin` an admin of the device's own household (or a server admin), `anyone` every
 * device it is there for. A route that is not here is for a server admin only. The routes check
 * it again themselves; this says it in one place, and the tests hold every route to it.
 */
export type HouseholdLevel = "anyone" | "householdAdmin" | "admin";

export const HOUSEHOLD_LEVELS: Readonly<Record<string, HouseholdLevel>> = {
  "GET /v1/server": "anyone",
  "POST /v1/pairing/claim": "anyone",
  "POST /v1/pairing/requests": "anyone",
  "POST /v1/pairing/requests/:id/collect": "anyone",
  "GET /v1/airplay/:pass/*": "anyone",
  "GET /v1/me": "anyone",
  "GET /v1/me/direct": "anyone",
  "PUT /v1/me/direct": "anyone",
  "PATCH /v1/me": "anyone",
  "GET /v1/household": "anyone",
  "GET /v1/live": "anyone",
  "POST /v1/live/:session": "anyone",
  "POST /v1/live/:session/results": "anyone",
  "POST /v1/remote/commands": "anyone",
  "GET /v1/me/wanted": "anyone",
  "POST /v1/me/downloads": "anyone",
  "GET /v1/profiles": "anyone",
  "POST /v1/profiles": "householdAdmin",
  "PATCH /v1/profiles/:id": "householdAdmin",
  "DELETE /v1/profiles/:id": "householdAdmin",
  "PUT /v1/profiles/:id/avatar": "anyone",
  "PUT /v1/profiles/:id/subtitles": "anyone",
  // A kids viewer's only from a household admin: the handler asks.
  "PUT /v1/profiles/:id/playback": "anyone",
  "PUT /v1/profiles/:id/skipping": "anyone",
  "GET /v1/profiles/:id/subtitle-offsets/:item": "anyone",
  "PUT /v1/profiles/:id/subtitle-offsets/:item": "anyone",
  "GET /v1/profiles/:id/progress": "anyone",
  "PUT /v1/profiles/:id/progress/:item": "anyone",
  "GET /v1/kids/code": "anyone",
  "GET /v1/me/push": "anyone",
  "PUT /v1/me/push": "anyone",
  "DELETE /v1/me/push": "anyone",
  "GET /v1/settings/push": "admin",
  "GET /v1/me/kids": "anyone",
  "PUT /v1/me/kids/place": "anyone",
  "POST /v1/me/kids/screen-time": "anyone",
  "POST /v1/me/kids/requests": "anyone",
  "GET /v1/me/kids/requests/:id": "anyone",
  "DELETE /v1/me/kids/requests/:id": "anyone",
  "GET /v1/kids/now": "anyone",
  "GET /v1/kids/requests": "householdAdmin",
  "POST /v1/kids/requests/:id/answer": "householdAdmin",
  "PUT /v1/household/time-zone": "householdAdmin",
  "GET /v1/profiles/:id/kids/plan": "anyone",
  "PUT /v1/profiles/:id/kids/plan": "householdAdmin",
  "PUT /v1/profiles/:id/kids/override": "householdAdmin",
  "DELETE /v1/profiles/:id/kids/override": "householdAdmin",
  "PATCH /v1/profiles/:id/kids/answer": "householdAdmin",
  "DELETE /v1/profiles/:id/kids/answer": "householdAdmin",
  "PUT /v1/kids/code": "householdAdmin",
  "POST /v1/kids/code/check": "anyone",
  "GET /v1/pairing/requests": "householdAdmin",
  "POST /v1/pairing/approve": "householdAdmin",
  "DELETE /v1/pairing/requests/:id": "admin",
  "GET /v1/household/invites": "householdAdmin",
  "POST /v1/household/invites": "householdAdmin",
  "DELETE /v1/household/invites/:invite": "householdAdmin",
  "GET /v1/devices": "householdAdmin",
  "PATCH /v1/devices/:id": "householdAdmin",
  "DELETE /v1/devices/:id": "householdAdmin",
  "GET /v1/devices/wanted": "householdAdmin",
  "GET /v1/devices/:id/wanted": "householdAdmin",
  "POST /v1/devices/:id/wanted": "householdAdmin",
  "DELETE /v1/devices/:id/wanted/:wantedId": "householdAdmin",
  "POST /v1/outside/window": "householdAdmin",
  "DELETE /v1/outside/window": "householdAdmin",
  "POST /v1/outside/pairing/:id/approve": "householdAdmin",
  "DELETE /v1/outside/pairing/:id": "householdAdmin",
  "GET /v1/outside/access": "householdAdmin",
  "GET /v1/library": "anyone",
  "GET /v1/library/query": "anyone",
  "GET /v1/search": "anyone",
  "GET /v1/search/outside": "anyone",
  "GET /v1/search/outside/:type/:id": "anyone",
  "GET /v1/search/people/:id": "anyone",
  "GET /v1/search/picture": "anyone",
  "GET /v1/popular": "anyone",
  "GET /v1/categories": "anyone",
  "GET /v1/logos/:id": "anyone",
  "GET /v1/items/:id": "anyone",
  "GET /v1/artwork/:id": "anyone",
  "GET /v1/assets/:id/content": "anyone",
  "POST /v1/assets/:id/playback": "anyone",
  "POST /v1/assets/:id/airplay": "anyone",
  "GET /v1/assets/:id/prepared/:revision/master.m3u8": "anyone",
  "GET /v1/assets/:id/prepared/:revision/subtitles/:playlist{[A-Za-z0-9_-]+\\.m3u8}": "anyone",
  "GET /v1/assets/:id/prepared/:revision/:file": "anyone",
  "GET /v1/assets/:id/subtitles/:subtitle{[A-Za-z0-9_-]+\\.vtt}": "anyone",
  "GET /v1/assets/:id/subtitles/:subtitle{[A-Za-z0-9_-]+\\.json}": "anyone",
  "GET /v1/households": "admin",
  "POST /v1/households": "admin",
  "GET /v1/households/:id": "admin",
  "PATCH /v1/households/:id": "admin",
  "DELETE /v1/households/:id": "admin",
  "POST /v1/households/:id/invites": "admin",
  "DELETE /v1/households/:id/invites/:invite": "admin",
  "GET /v1/status": "admin",
  "GET /v1/settings": "admin",
  "PATCH /v1/settings": "admin",
  "GET /v1/settings/history": "admin",
  "POST /v1/settings/history/:version/restore": "admin",
  "GET /v1/settings/audit": "admin",
  "GET /v1/settings/browse": "admin",
  "PUT /v1/settings/tmdb": "admin",
  "DELETE /v1/settings/tmdb": "admin",
  "PUT /v1/settings/omdb": "admin",
  "DELETE /v1/settings/omdb": "admin",
  "GET /v1/setup": "admin",
  "POST /v1/setup/steps/:step": "admin",
  "POST /v1/setup/finish": "admin",
  "GET /v1/outside": "admin",
  "PATCH /v1/outside": "admin",
  "GET /v1/wake": "admin",
  "PATCH /v1/wake": "admin",
  "POST /v1/wake/scan": "admin",
  "POST /v1/wake/pairings": "admin",
  "POST /v1/wake/pairings/:id": "admin",
  "DELETE /v1/wake/pairings/:id": "admin",
  "PUT /v1/wake/televisions/:id": "admin",
  "DELETE /v1/wake/televisions/:id": "admin",
  "POST /v1/remote/wake": "anyone",
  // Only the sender's own play.
  "DELETE /v1/remote/wake/:deviceId/plays/:id": "anyone",
  "GET /v1/speakers": "admin",
  "PATCH /v1/speakers": "admin",
  "POST /v1/speakers/scan": "admin",
  "PATCH /v1/speakers/:id": "admin",
  "PUT /v1/speakers/:id/password": "admin",
  "POST /v1/speakers/:id/play": "anyone",
  "POST /v1/speakers/:id/control": "anyone",
  "GET /v1/items/:id/edit": "admin",
  "PATCH /v1/items/:id": "admin",
  "GET /v1/items/:id/artwork-options": "admin",
  "GET /v1/items/:id/artwork-options/preview": "admin",
  "POST /v1/items/:id/artwork": "admin",
  "POST /v1/items/:id/artwork/upload": "admin",
  "DELETE /v1/items/:id/artwork": "admin",
  "GET /v1/markers": "admin",
  "GET /v1/markers/assets/:id": "admin",
  "PUT /v1/markers/assets/:id": "admin",
  "DELETE /v1/markers/assets/:id": "admin",
  "POST /v1/markers/items/:id/detect": "admin",
  "GET /v1/items/:id/match": "admin",
  "PUT /v1/items/:id/match": "admin",
  "DELETE /v1/items/:id/match": "admin",
  "POST /v1/items/:id/match/automatic": "admin",
  "GET /v1/categories/edit": "admin",
  "POST /v1/categories/groups": "admin",
  "PUT /v1/categories/groups/order": "admin",
  "PATCH /v1/categories/groups/:id": "admin",
  "DELETE /v1/categories/groups/:id": "admin",
  "PUT /v1/categories/folders/:id": "admin",
  "GET /v1/categories/logo-search": "admin",
  "GET /v1/categories/logo-search/preview": "admin",
  "PUT /v1/categories/groups/:id/logo": "admin",
  "POST /v1/categories/groups/:id/logo/upload": "admin",
  "DELETE /v1/categories/groups/:id/logo": "admin",
  "PUT /v1/categories/:id/logo": "admin",
  "POST /v1/categories/:id/logo/upload": "admin",
  "DELETE /v1/categories/:id/logo": "admin",
  "POST /v1/categories": "admin",
  "PUT /v1/categories/order": "admin",
  "POST /v1/categories/arrange": "admin",
  "GET /v1/categories/suggestions": "admin",
  "POST /v1/categories/suggestions/:id/accept": "admin",
  "POST /v1/categories/suggestions/:id/dismiss": "admin",
  "POST /v1/categories/suggestions/accept": "admin",
  "POST /v1/categories/merge": "admin",
  "POST /v1/categories/arrange/undo": "admin",
  "PATCH /v1/categories/:id": "admin",
  "DELETE /v1/categories/:id": "admin",
  "GET /v1/conversion": "admin",
  "POST /v1/conversion/jobs": "admin",
  "POST /v1/conversion/pause": "admin",
  "POST /v1/conversion/resume": "admin",
  "DELETE /v1/conversion/jobs/:id": "admin",
  "POST /v1/conversion/jobs/:id/move": "admin",
  "POST /v1/conversion/claim": "admin",
  "POST /v1/conversion/jobs/:id/heartbeat": "admin",
  "GET /v1/conversion/jobs/:id/upload": "admin",
  "PATCH /v1/conversion/jobs/:id/upload": "admin",
  "POST /v1/conversion/jobs/:id/complete": "admin",
  "POST /v1/conversion/jobs/:id/release": "admin",
  "GET /v1/conversion/replacements": "admin",
  "POST /v1/conversion/replacements/:id/undo": "admin",
  "POST /v1/conversion/replacements/:id/purge": "admin",
  "GET /v1/imports": "admin",
  "GET /v1/imports/items": "admin",
  "GET /v1/imports/items/:id": "admin",
  "POST /v1/imports/items/:id/confirm": "admin",
  "POST /v1/imports/items/:id/dismiss": "admin",
  "POST /v1/imports/items/:id/clean-up": "admin",
  "POST /v1/imports/items/:id/convert": "admin",
  "GET /v1/imports/activity": "admin",
  "POST /v1/imports/scan": "admin",
  "GET /v1/uploads": "admin",
  "POST /v1/uploads": "admin",
  "GET /v1/uploads/:id": "admin",
  "PATCH /v1/uploads/:id": "admin",
  "POST /v1/uploads/:id/complete": "admin",
  "DELETE /v1/uploads/:id": "admin",
  "GET /v1/music/status": "admin",
  "GET /v1/music/artists/:id/edit": "admin",
  "PATCH /v1/music/artists/:id": "admin",
  "GET /v1/music/albums/:id/edit": "admin",
  "PATCH /v1/music/albums/:id": "admin",
  "GET /v1/music/tracks/:id/edit": "admin",
  "PATCH /v1/music/tracks/:id": "admin",
  "GET /v1/music/books/:id/edit": "admin",
  "PATCH /v1/music/books/:id": "admin",
  "GET /v1/music/library": "anyone",
  "GET /v1/music/artists/:id": "anyone",
  "GET /v1/music/albums/:id": "anyone",
  "GET /v1/music/tracks/:id": "anyone",
  "GET /v1/music/books/:id": "anyone",
  "GET /v1/music/covers/:id": "anyone",
  "GET /v1/music/tracks/:id/content": "anyone",
  "POST /v1/music/tracks/:id/playback": "anyone",
  "GET /v1/music/tracks/:id/copies/:revision/:file": "anyone",
  "GET /v1/music/profiles/:profile/favourites": "anyone",
  "PUT /v1/music/profiles/:profile/favourites/:item": "anyone",
  "GET /v1/music/profiles/:profile/playlists": "anyone",
  "POST /v1/music/profiles/:profile/playlists": "anyone",
  "GET /v1/music/profiles/:profile/playlists/:id": "anyone",
  "PATCH /v1/music/profiles/:profile/playlists/:id": "anyone",
  "POST /v1/music/profiles/:profile/playlists/:id/tracks": "anyone",
  "DELETE /v1/music/profiles/:profile/playlists/:id": "anyone",
  "GET /v1/music/profiles/:profile/playlists/:id/export.m3u8": "anyone",
  "POST /v1/music/profiles/:profile/plays": "anyone",
  "GET /v1/music/profiles/:profile/plays": "anyone",
  "GET /v1/music/profiles/:profile/play-counts": "anyone",
  "DELETE /v1/music/profiles/:profile/plays": "anyone",
  "GET /v1/music/profiles/:profile/progress": "anyone",
  "PUT /v1/music/profiles/:profile/progress/:item": "anyone",
  "GET /v1/stats/viewers/:id": "anyone",
  "DELETE /v1/stats/viewers/:id/history/:session": "anyone",
  "DELETE /v1/stats/viewers/:id": "householdAdmin",
  "GET /v1/stats/household": "householdAdmin",
  "GET /v1/stats/server": "admin",
};

// Ids are words of these. Anything that would need decoding is not an id.
const ID = /^[A-Za-z0-9_-]{1,128}$/;

/** The value of a parameter of `pattern` in `path`. */
function param(pattern: string, path: string, name: string): string | null {
  const index = pattern.split("/").indexOf(`:${name}`);
  const value = index === -1 ? undefined : path.split("/")[index];
  return value !== undefined && ID.test(value) ? value : null;
}

interface HouseholdRow {
  owner: number;
  scoped: number;
  bandwidth: number | null;
}

interface GuardDeps {
  db: Database;
  bandwidth: Bandwidth;
  notFound: () => Error;
  /** A device of the household that may not do this: it is told so. */
  forbidden: () => Error;
}

/** The route that answers this request, as `METHOD /pattern`, and its pattern. */
export function routeKey(c: Parameters<MiddlewareHandler<AppEnv>>[0]): {
  key: string;
  pattern: string;
} {
  // Middleware is registered for all methods; the first other match answers the request.
  const route = matchedRoutes(c).find((one) => one.method !== "ALL");
  const pattern = route?.path ?? "";
  const method = route?.method === "HEAD" ? "GET" : (route?.method ?? "");
  return { key: `${method} ${pattern}`, pattern };
}

/**
 * Stands between every route and a device, right after its credential: what belongs to another
 * household is not there for it, and a guest household is sent no more than its cap.
 */
export function householdGuard(deps: GuardDeps): MiddlewareHandler<AppEnv> {
  const { db, bandwidth } = deps;

  const household = (id: string): HouseholdRow | undefined =>
    db.get<HouseholdRow>(
      `select owner, scope_json is not null as scoped, bandwidth from household
       where id = ? and removed_at is null`,
      [id],
    );

  // One that is nobody's goes on to the route, which says so as it always did (and first asks
  // whether the device may ask at all); one of another household is not there.
  const ownProfile = (id: string | null, householdId: string): boolean => {
    if (id === null) return false;
    const row = db.get<{ household_id: string }>("select household_id from profile where id = ?", [
      id,
    ]);
    return row === undefined || row.household_id === householdId;
  };

  const ownDevice = (id: string | null, householdId: string): boolean => {
    if (id === null) return false;
    const row = db.get<{ household_id: string }>("select household_id from device where id = ?", [
      id,
    ]);
    return row === undefined || row.household_id === householdId;
  };

  return async (c, next) => {
    const device = c.get("device");
    const { key, pattern } = routeKey(c);
    const path = c.req.path;
    const mine = household(device.householdId);
    if (!mine) throw deps.notFound();
    const guest = mine.owner !== 1;
    const decision = Object.hasOwn(HOUSEHOLD_ROUTES, key) ? HOUSEHOLD_ROUTES[key] : undefined;
    // Not decided: there for the owner's household as before, and not there for guests.
    if (decision === undefined && guest) throw deps.notFound();
    const allowed = ((): boolean => {
      switch (decision) {
        case "owner":
          return !guest;
        case "profile":
          return ownProfile(param(pattern, path, "id"), device.householdId);
        case "kids_profile":
        case "stats_profile":
          return (
            ownProfile(param(pattern, path, "id"), device.householdId) ||
            (device.access === "admin" && device.kidsProfileId === null)
          );
        case "device":
          return ownDevice(param(pattern, path, "id"), device.householdId);
        case "music":
          return mine.scoped !== 1;
        case "music_profile":
          return (
            mine.scoped !== 1 && ownProfile(param(pattern, path, "profile"), device.householdId)
          );
        default:
          return true;
      }
    })();
    if (!allowed) throw deps.notFound();
    const level = Object.hasOwn(HOUSEHOLD_LEVELS, key) ? HOUSEHOLD_LEVELS[key] : "admin";
    const may =
      level === "anyone" ||
      device.access === "admin" ||
      (level === "householdAdmin" && device.access === "householdAdmin");
    // A kids device is told nothing of what is there for others: the kids guard says 404.
    if (decision !== "open" && decision !== undefined && !may && device.kidsProfileId === null) {
      throw deps.forbidden();
    }

    await next();

    if (!guest) return;
    const streams = key.startsWith("GET /v1/assets/") || key.startsWith("GET /v1/music/tracks/");
    if (!streams || !c.res.body || c.req.method === "HEAD") return;
    const response = c.res;
    let now = { cap: mine.bandwidth, active: true };
    let checkedAt = Date.now();
    const body = bandwidth.limit(
      device.householdId,
      response.body as ReadableStream<Uint8Array>,
      // Looked at again every second: the owner may change the cap, pause or remove meanwhile.
      () => {
        if (Date.now() - checkedAt >= 1_000) {
          checkedAt = Date.now();
          const row = db.get<HouseholdRow & { paused: number }>(
            `select owner, scope_json is not null as scoped, bandwidth, paused_at is not null as paused
             from household where id = ? and removed_at is null`,
            [device.householdId],
          );
          now = { cap: row?.bandwidth ?? null, active: row !== undefined && row.paused !== 1 };
        }
        return now;
      },
    );
    c.res = new Response(body, { status: response.status, headers: response.headers });
  };
}

export { OWNER_HOUSEHOLD };
