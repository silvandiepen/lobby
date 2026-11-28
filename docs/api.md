# Lobby Server API

The contract between Lobby Server and the Apple apps. Version 1. The server in `apps/server` implements it and `packages/LobbyKit` consumes it. Change this page in the same change as the code.

Status per section is marked **Built** or **Planned**. A planned section is the agreed shape, with nothing behind it yet.

## Conventions

- Base path `/v1`. Requests and responses are JSON in UTF-8 unless a section says otherwise.
- Instants are integers: milliseconds since the Unix epoch, UTC. Their names end in `At`. Durations and positions are integer milliseconds and end in `Ms`. Dates without a time (`airDate`) are `YYYY-MM-DD` strings.
- Ids are opaque strings. They are stable for the life of the catalogue: a rename, a rescan or a changed match never changes an id.
- A missing value is `null`. Fields are never omitted.
- Clients must ignore fields they do not know.

### Authentication

Every route needs a device credential, except the ones marked **Open**.

Send it as `Authorization: Bearer <token>`, or as the cookie `lobby_device=<token>`. The cookie exists for AVPlayer and for image and download requests, which can carry cookies but not custom headers through every Apple API. The token never goes in a URL.

A route marked **Manager** needs an admin of the device's own household: a household admin or a server admin (`access`, see [Households](#households)). **Owner** needs a server admin; for a device of a guest household those routes are not there (`404`), for a household admin or viewer of the owner's household they are `403`.

### Who may ask

At home a request must be for a name the server goes by there (`Host`): any IP address, `localhost`, a name of one word, a name ending in `.local`, `.lan`, `.home`, `.home.arpa`, `.internal`, `.localdomain` or `.ts.net`, the machine's own name, or the host of an address in `addresses.remote`. An `Origin`, which only web pages send, must be of that same host. Anything else is `403 forbidden` on every route, also the open ones: a web page that points its own name at the server, or sends a form to it, gets nothing done. Apps send neither and need to do nothing.

A JSON body is at most 2 MB, and 16 KB on the open routes; a longer one is `400 invalid_request`.

### Errors

```json
{ "error": { "code": "forbidden", "message": "Only a manager can approve devices." } }
```

| Status | `code` | Meaning |
| --- | --- | --- |
| 400 | `invalid_request` | The body or a parameter is malformed. |
| 401 | `unauthorized` | No credential, or one the server does not know. |
| 401 | `device_revoked` | The credential was valid and a manager revoked it. Pair again. |
| 403 | `forbidden` | The device's role does not allow this. |
| 404 | `not_found` | No such item, category, asset, profile or pairing code. |
| 409 | `conflict` | A progress update lost to a newer one. The body also carries the current `progress`. Or an edit based on an older revision: the body then carries the current edit view (of the item, or of the categories). |
| 410 | `gone` | A pairing request expired or was already collected. Or there is no such live channel: open it again. |
| 416 | `range_not_satisfiable` | A byte range lies outside the file. |
| 422 | `unsupported_subtitle` | An image subtitle (PGS, DVD) or a track that cannot be converted to text. |
| 429 | `rate_limited` | Too many wrong codes or secrets, too many devices asking to be paired, or a queue that is full (preparing, subtitles, pictures). Carries `Retry-After`. |
| 503 | `unavailable` | The file's drive is not mounted, or TMDB is needed and cannot be reached. |

`message` is written for a person and may be shown as it is.

## Server

### `GET /v1/server` — Open. Built.

For the Connect screen: lets the family check they found the right server before pairing.

```json
{ "id": "b3c1…", "name": "Lobby", "version": "0.1.0", "apiVersion": 1, "minAppVersion": "0.1.0", "claimed": true, "claim": "open" }
```

`claimed` is false until the first manager has claimed the server.

`minAppVersion` is the oldest app version this server works with. An app older than that tells its manager to update the app; an app that needs a newer server than `version` tells its manager to update the server (D-047). A server without the field is taken to work with every app. `GET /v1/me` carries it too.

### `GET /v1/me` — Built.

```json
{
  "device": Device,
  "household": { "id": "owner", "name": "Home", "owner": true },
  "server": {
    "id": "…", "name": "Lobby", "version": "0.1.0", "apiVersion": 1, "minAppVersion": "0.1.0", "claimed": true,
    "addresses": { "home": ["http://lobby-7c3f9a12.local:8674"], "remote": ["http://media.example.ts.net:8674"] }
  }
}
```

`household` is the household the device is in: the apps say whose server it is (`server.name`) and, for a guest, whose household (`household.name`). Null only on a server from before households.

For a manager of the owner's household at home `server` also carries `setup` (see [Server settings](#server-settings)); for others and outside it is not there.

`server.addresses` says where this server can be reached, for paired devices only: the open `GET /v1/server` never carries it. `home` is the name the server announces on the home network (empty when it does not announce itself). `remote` is what the household listed under `addresses.remote` in the server's config, for example its name in their tailnet; it is empty until someone does. Each entry is an origin: `http://` or `https://`, host and optional port, no path.

A device stores all of them at pairing and refreshes them whenever it calls `/v1/me`. It tries `home` first and `remote` after, and before it sends its credential to an address it has not used before it asks that address for `GET /v1/server` and checks that `id` is the server it paired with. Listing an address opens nothing on the server: the road itself (Tailscale, a tunnel) is set up outside Lobby.

### `GET /v1/status` — Manager. Built.

```json
{
  "scanning": true,
  "sources": [
    { "id": "…", "name": "Pixar", "hint": "movies", "available": true, "lastScanStartedAt": 1795530000000, "lastScanFinishedAt": 1795530060000, "files": 34 }
  ],
  "files": { "total": 3070, "waiting": 12, "failed": 3, "missing": 0 },
  "playability": { "direct": 920, "remux": 1380, "transcode": 620, "unsupported": 4 },
  "items": { "movies": 380, "shows": 50, "episodes": 2500, "extras": 40, "personal": 0, "needsReview": 62, "unmatched": 310 }
}
```

`hint` is what the household said the folder holds: `movies`, `series`, `personal` or `mixed`.

## Pairing and devices

```ts
interface Device {
  id: string;
  name: string;
  platform: "ios" | "ipados" | "macos" | "tvos" | "cli";
  /** What it may do: a server admin everything, a household admin their own household, a viewer watch. */
  access: "admin" | "householdAdmin" | "viewer";
  /** For apps from before `access`: "manager" only for a server admin, "viewer" for everyone else. */
  role: "manager" | "viewer";
  createdAt: number;
  lastUsedAt: number | null;
  revokedAt: number | null;
  /** The kids viewer this device belongs to (see Kids limits); null: no limits. */
  kidsProfileId: string | null;
  /** Whether it is let in from outside (see Outside). False for every device paired at home. */
  allowOutside: boolean;
  lastOutsideAt: number | null;
  /** See Playing on another device. */
  isTarget: boolean;
  allowRemote: boolean;
  remoteOutside: boolean;
  /** The household it is in: "owner" for the server owner's own (see Households). */
  householdId: string;
}
```

### `POST /v1/pairing/claim` — Open. Built.

The first manager claims a new server. Works only while `claimed` is false. `GET /v1/server` says how in `claim`:

- `"open"` (the default): the first device to ask sets the server up; `setupSecret` is left out.
- `"secret"`: the request must carry the setup secret, which the server prints at start and keeps in its data folder. Set `"claim": "secret"` in the config for this.

Request `{ "deviceName": "Alex's MacBook Pro", "platform": "macos" }`, plus `"setupSecret": "…"` in secret mode.

Response `201` `{ "device": Device, "token": "…", "setup": Setup }`. Store the token in the Keychain. It is shown once. `setup` says whether the first setup is still to do (see [Server settings](#server-settings)); an app goes on with it when `setup.needed` is true.

In `"open"` mode only from nearby: a private address, the tailnet, or a network the server itself is in. `claim` can be `"secret"` although the config says open: after a restore that left no manager.

`403 forbidden` for a wrong or missing secret in secret mode, from far away in open mode, or a server that is already claimed. `429` after repeated wrong secrets.

### `POST /v1/pairing/requests` — Open. Built.

A new device asks to join. It shows `code` on its screen.

Request `{ "deviceName": "Living room Apple TV", "platform": "tvos" }`

Response `201`

```json
{ "id": "…", "code": "482913", "pollSecret": "…", "expiresAt": 1795530600000 }
```

The code is six digits, works once and expires after ten minutes.

`429 rate_limited` after twenty requests at once from one address, or when forty devices wait. One address has at most eight waiting: the next takes the place of its oldest, whose code then is `404`.

### `POST /v1/pairing/requests/{id}/collect` — Open. Built.

The new device polls this (every two or three seconds) until a manager has approved it.

Request `{ "pollSecret": "…" }`

- `202` `{ "status": "pending", "expiresAt": 1795530600000 }`
- `200` `{ "status": "approved", "device": Device, "token": "…" }`. Returned exactly once.
- `410 gone` when the request expired (for an hour after) or the token was already collected.
- `404 not_found` for an unknown id, one that expired longer ago, or a wrong `pollSecret`.

### `GET /v1/pairing/requests` — Manager. Built.

Devices waiting for approval, with the code each one shows, so a manager can compare it before approving. `code` is null for a device that was waiting when the server restarted.

```json
{ "requests": [ { "id": "…", "deviceName": "Living room Apple TV", "platform": "tvos", "code": "482913", "createdAt": 1795530000000, "expiresAt": 1795530600000 } ], "outsideRequests": [] }
```

`outsideRequests` holds devices that ask from outside (see Outside). `POST /v1/pairing/approve` cannot approve those. Each carries `householdId` and `invited` (it came with a household's invitation and will be its manager).

A guest household's manager gets `requests: []` (pairing at home is pairing into the owner's household) and in `outsideRequests` those at their own household's window; the owner's managers get those at the owner's window and those who came with an invitation. `POST /v1/pairing/approve` is `403` for a guest household's manager.

### `POST /v1/pairing/approve` — Manager. Built.

Request `{ "requestId": "…", "access": "viewer" }` for a device picked from the list, or `{ "code": "482913", "access": "viewer" }` for a typed code. `access` is `viewer`, `householdAdmin` or `admin`, at most the approver's own (`403` above it); an older app sends `role` instead, `manager` being `admin`. Home pairing is pairing into the owner's household, so a household admin of the owner's household approves here too.

Response `200` `{ "deviceName": "Living room Apple TV", "platform": "tvos", "role": "viewer", "access": "viewer", "awaitsAdmin": false }`. With `awaitsAdmin` the owner's household needs a server admin's yes too (`requiresAdminApproval`): the device's collect answers `202` `{ "status": "pending", "expiresAt", "waitingFor": "admin" }` until a server admin sends `{ "requestId" }` here (without `access`), and `410 gone` once a server admin said no with `DELETE /v1/pairing/requests/{id}` — Owner, `204`. `GET /v1/pairing/requests` also carries `awaitingAdmin` (those, for everyone of the owner's household who manages it) and, for a household admin, `refused` (those a server admin turned away, until they would have expired).

`404 not_found` for a code or id that matches no waiting request. `429 rate_limited` after five wrong codes in ten minutes.

### `GET /v1/devices` — Manager. Built.

`{ "devices": [Device], "currentDeviceId": "…" }`: the devices of the manager's own household.

### `PATCH /v1/devices/{id}` — Manager. Built.

`{ "kidsProfileId"?: "profile id" | null, "allowOutside"?: boolean, "isTarget"?: boolean | null, "allowRemote"?: boolean, "remoteOutside"?: boolean, "access"?: "admin" | "householdAdmin" | "viewer" }`, at least one → `200` `Device`. `access` goes up to the manager's own: only a server admin makes a server admin, and only in the owner's household (`404` for another household's device, `409` for a device bound to a kids viewer). A household admin cannot change or remove a server admin's device (`403`). The last server admin, and a guest household's last household admin, cannot stop being one (`409`). The last three are in [Playing on another device](#playing-on-another-device). `kidsProfileId` says which kids viewer the device belongs to, or none. `allowOutside` lets it in from outside, or no longer: its connections from outside are then cut at once. All are changed or none is.

`409 conflict` for `kidsProfileId` on a manager's device, and for a viewer without `kids`. `404 not_found` for an unknown or removed device and an unknown viewer.

### `DELETE /v1/devices/{id}` — Manager. Built.

Revokes the device. `204`. Only a device of the manager's own household; another's is `404`, as any other route that names a device or a viewer of another household. Its next request gets `401 device_revoked`, and what is being sent to it is cut off within a second or so. Only who holds the removed credential itself is told that it was removed. Restoring an older backup does not bring it back. Copies it already downloaded stay on it. The last manager of a household cannot be revoked (`409 conflict`); the owner removes a guest household as a whole instead.

## Outside

Built on the server, off until it is set up. How it is set up, and against what it protects: [outside.md](outside.md).

A device outside the home and the tailnet reaches the server through a separate entrance, over whatever road was made for it, with HTTP/1.1 requests whose `Host` is the configured name. It is the same API with these differences.

**Not let in.** No credential, an unknown one, one of a removed device and one of a device without `allowOutside` all get the same empty `404`, whatever the address or method: there is no `GET /v1/server`, no claim and no `401`. An app that gets an empty `404` on `GET /v1/me` from outside can only say: this device is not let in from outside; ask a manager. It must not throw its credential away on it. Too many of them give an empty `429` with `Retry-After`. A good credential is never held up by the bad tries of others.

**Let in.** The device's own credential, as `Authorization: Bearer`; the cookie works for `GET` and `HEAD` only. Kids limits hold as at home.

| Routes | From outside |
| --- | --- |
| `GET` of `/v1/me`, `/v1/profiles`, `/v1/library`, `/v1/categories`, `/v1/items/{id}`, `/v1/logos/{id}`, `/v1/artwork/{id}` | Yes. |
| `/v1/me/wanted`, `POST /v1/me/downloads`, `/v1/profiles/{id}/progress…`, `/v1/profiles/{id}/subtitle-offsets…`, `PUT /v1/profiles/{id}/avatar`, `PUT /v1/profiles/{id}/subtitles` | Yes. |
| `/v1/live…`, `POST /v1/remote/commands`, `PATCH /v1/me` | Yes; other devices only with `remoteOutside`. Six channels per device, 24 in all. |
| `/v1/assets/{id}/…` (content, playback, prepared files, subtitles) | Yes, within limits. |
| `/v1/music`: library, artists, albums, tracks, books, covers, sound, playback; reading favourites, playlists, plays; adding plays; progress | Yes. |
| `/v1/music`: changing favourites and playlists, the export, clearing plays, editing | `403 forbidden`: only at home. |
| Everything for managers, all pairing and claiming at home, `/v1/outside…` | `403 forbidden`, for a manager's device too. `404` for a kids device. |
| For a household admin: `/v1/household/invites…`, `/v1/devices…`, `POST`/`PATCH`/`DELETE /v1/profiles…`, `PUT /v1/kids/code`, `GET /v1/pairing/requests`, `POST`/`DELETE /v1/outside/window`, `/v1/outside/pairing/{id}…`, `GET /v1/outside/access` | Yes, for their own household (see Households): it lives elsewhere, so this is its home. `403` for everyone else, as above. |
| `GET /v1/household` | Yes. |
| A route nobody decided about | `404`. |

Limits, each answered with `429 rate_limited` (or an empty `429`) and `Retry-After`: 8 streams at once per device and 24 in all; 6 new copies (repackaging or converting) and then one every two minutes, 2 in the making at once, per device; asking about a copy that is being made is free; 1 embedded subtitle at once; 12 pictures at once; 1,200 requests and then 10 a second; 24 connections. Bodies over 64 KB (1 MB for `/v1/me/downloads`) are `413`. Send a `Content-Length`: chunked bodies are refused. One request at a time per connection, and one credential per connection.

### Pairing from outside

Needs a window that a manager opened at home or in the tailnet. Both calls need no credential and answer the same empty `404` when anything is not right.

- `POST /v1/outside-pairing` `{ "code": "…", "deviceName": "Apple TV", "platform": "tvos" }` → `201` `{ "id": "…", "pollSecret": "…", "comparison": "482913", "expiresAt": … }`. The code is **16 characters** of Crockford base32 (80 bits), shown as `XXXX-XXXX-XXXX-XXXX`: digits and letters without I, L, O and U. Capitals, spaces and hyphens do not matter; O is read as 0, I and L as 1. It works once. Show `comparison` on the screen. `platform` is any but `cli`.
- `POST /v1/outside-pairing/collect` `{ "id": "…", "pollSecret": "…" }` every three seconds → `202` `{ "status": "pending", "expiresAt": … }`, then once `200` `{ "status": "approved", "device": Device, "token": "…" }`. Stop on `404` and at `expiresAt` (ten minutes): the manager said no, or it is over.

After five wrong codes from one address, or thirty from everywhere in a short time, `429`.

### `GET /v1/outside` — Manager. Built.

```json
{
  "configured": true,
  "enabled": true,
  "transports": [ { "name": "relay", "open": true, "problem": null } ],
  "connections": 2,
  "direct": { "running": true, "introducer": true, "connections": 1, "relayed": 0, "devices": 3 },
  "window": { "openedBy": "device id", "openedAt": 1795530000000, "expiresAt": 1795530600000 },
  "requests": [ { "id": "…", "outside": true, "deviceName": "Apple TV", "platform": "tvos", "address": "203.0.113.7", "comparison": "482913", "createdAt": 1795530000000, "expiresAt": 1795530600000 } ]
}
```

`direct` is null when the direct road is not set up. `running`: the program that makes the connections runs; `introducer`: the box is signed in there; `connections`: live ones, of which `relayed` go over the owner's own relay; `devices`: how many may ring now. `window` is null when none is open. `problem` is a sentence. `address` can be null, and can be a shared one.

### `PATCH /v1/outside` — Manager. Built.

`{ "enabled": true }` → `200` as above. Stays as it is over a restart. Off closes every road, connection, window and request at once. `409 conflict` when it is not set up.

### `POST /v1/outside/window` — Manager. Built.

`{ "minutes"?: 1…30 }`, 10 when left out, for one device of the manager's own household → `201` `{ "code": "XXXX-XXXX-XXXX-XXXX", "expiresAt": …, "direct": { "introducer": "wss://…" } | null }`. With `direct`, a device can pair through that introducer (see Direct). Shown once. For one device; a new window replaces the one before and whoever waited. Each household has its own window: a guest household's manager opens theirs from outside, and the device becomes a viewer of that household. `409 conflict` while the entrance is off. `DELETE /v1/outside/window` closes it and turns a waiting device away, `204`.

### `POST /v1/outside/pairing/{id}/approve` — Manager. Built.

`{ "comparison": "482913" }` → `200` `{ "deviceName": "…", "platform": "tvos", "role": "viewer", "householdId": "…" }`. Show the manager the address, the name and the digits, and have them say that the digits are the ones on the new device's screen. Wrong digits are `409 conflict` and turn the device away. The device becomes a viewer with `allowOutside`, never a manager, except one that came with an invitation: it becomes the manager of the guest household it was for (`role: "manager"`). Only a manager of the request's household approves it; one that came with an invitation, only the owner's. `DELETE /v1/outside/pairing/{id}` says no, `204`. `404` when it does not wait any more, for both.

### `GET /v1/outside/access?limit=<1…500>&before=<entry id>` — Manager. Built.

```json
{ "entries": [ { "id": 12, "at": 1795530000000, "until": 1795530050000, "count": 40, "deviceId": "…", "transport": "relay", "address": "203.0.113.7", "routeClass": "stream", "outcome": "ok" } ] }
```

The owner's managers see every entry, also those of guests' devices and of no device: they answer for the whole server. A guest household's manager sees those of its own devices.

Newest first, 100 when `limit` is left out. Requests that are alike within a minute are one entry. `deviceId` is null for who was not let in. `routeClass`: `account`, `library`, `artwork`, `progress`, `downloads`, `playback`, `stream`, `subtitle`, `pairing`, `closed` or `none`. `outcome`: `ok`, `refused`, `closed`, `limited` or `error`. `address` is null when the road knows none, and `many` when there were too many. Kept for 30 days.

## Server settings

A manager changes the server from the app instead of in `lobby.config.json`, and sets a fresh server up there. **Built.** Every route here is **Manager**, at home or in the tailnet only: from any other address it is `403 forbidden`, the outside entrance does not have these routes (`404`), and neither does a kids device. Answers carry `Cache-Control: no-store`. A body is at most 128 KB (4 KB for the TMDB key and the setup steps). Per device at most 20 changes in a row and then 10 a minute, 60 looks at folders and then 60 a minute, 5 TMDB checks and then 1 a minute; more is `429` with `Retry-After`.

**Where a setting comes from.** The file stays what the server starts from: where it listens (`host`, `port`), its data folder (`dataDir`), the programs it runs (`ffmpegPath`, `ffprobePath`, `outside.direct.binary`), how it is claimed, files with keys and certificates, backups' folder and the outside entrance's set-up. Those cannot be changed here. The keys listed under `settings` are kept in `settings/settings.json` in the data folder, versioned; for those the store wins over the file. The store is made from the file the first time the server starts, so the server runs as before. A key the store does not hold has its default.

### `GET /v1/settings` — Manager. Built.

```json
{
  "version": 4, "updatedAt": 1795530000000, "updatedBy": { "id": "…", "name": "Mac" }, "bootId": "…", "restarting": false,
  "sections": [{ "id": "general", "title": "General" }],
  "settings": [
    { "key": "serverName", "section": "general", "title": "Name", "help": "Shown when a device looks for servers, …", "type": "text",
      "apply": "live", "default": "Lobby", "nullable": false, "value": "Lobby", "available": true }
  ],
  "secrets": { "tmdbKey": { "set": true, "source": "settings" } },
  "fixed": { "configFile": "…", "dataDir": "…", "host": "0.0.0.0", "port": 8674, "claim": "open", "outside": null },
  "setup": Setup
}
```

- `sections`: `general`, `library`, `converting`, `away`, `backups`, `advanced`, in this order.
- `type`: `text`, `toggle`, `integer`, `number` (with `min` and `max`), `hours` (`"01:00-07:00"`, or null for any hour), `folder` (an absolute path, or null), `folders` (the library folders: `{ path, hint, name?, group?, logo? }` with `hint` one of `movies`, `series`, `personal`, `mixed`, `music`, `audiobooks`; `group: "Kids"` puts a folder in the kids part), `addresses` (a list of `http(s)://` origins), `language` (`en-US`).
- `apply`: `live`, taken at once; `restart`, the server restarts itself to take it.
- `available: false` with `unavailableReason`: the key belongs to something the file has not set up (the upload limit without a direct connection, waking Apple TVs without `remote.wake`).
- `secrets` says only whether a secret is set and where from (`settings`, or `environment` for `LOBBY_TMDB_API_KEY`, which the app cannot change): `tmdbKey` and `omdbKey`. No route ever returns a secret.
- `bootId` changes with every start: after a restart an app waits until it is another one.

| Key | Section | Taken |
| --- | --- | --- |
| `serverName` | general | live, and announced again under the new name |
| `advertise` | general | restart |
| `language` | general | restart |
| `roots` | library | live for film and series folders: added ones are looked through at once, removed ones leave the library (watch history is kept); a change to music or audiobook folders restarts |
| `rescanMinutes` | library | live |
| `conversion.dir` | converting | restart. Only on the drives (see browsing), outside every library folder; once Lobby's folder holds originals it can only be that folder again |
| `conversion.hours`, `conversion.server`, `conversion.repackage`, `conversion.minFreeGb` | converting | live; a job under way finishes as it started |
| `addresses.remote` | away | live, also for which names the server answers to |
| `outside.direct.maxUploadMbit` | away | restart |
| `remote.wake.enabled` | general | live: whether Play On wakes Apple TVs ([Waking an Apple TV](#waking-an-apple-tv)). Where pyatv is stays in the file |
| `remote.wake.kids` | general | live: "Kids can turn on the TV" |
| `remote.wake.pickProfile` | general | live: "Get past “Who is watching?”", on by default. A woken TV that does not open Lobby gets one press of select, which picks whichever profile is focused there ([Waking an Apple TV](#waking-an-apple-tv)) |
| `backup.everyHours`, `backup.keep` | backups | live |
| `stabilityMs`, `probeConcurrency`, `playback.maxCacheGb`, `playback.maxConcurrent`, `music.maxCacheGb` | advanced | restart |

The outside entrance's switch is `PATCH /v1/outside`, live as before.

### `PATCH /v1/settings` — Manager. Built.

Request `{ "changes": { "serverName": "Den", "conversion.hours": null }, "baseVersion": 4, "dryRun": true }`. `baseVersion` is the `version` that was shown; when the settings changed meanwhile it is `409 conflict` and nothing is changed. Left out, the change goes on top of whatever there is.

Response `200`:

```json
{
  "dryRun": true, "version": 4, "changed": ["roots"], "restart": false, "restarting": false, "rescanFolders": 1, "bootId": "…",
  "effects": [{ "key": "roots", "title": "Folders", "apply": "live", "message": "Will look through 1 new folder." }]
}
```

`dryRun: true` checks everything and says what would happen, and changes nothing. Without it the change is made and `version` is the new one. When `restarting` is true the server restarts about a third of a second after this answer: requests fail for a few seconds, then `GET /v1/settings` answers with another `bootId`. Meanwhile a change is `503`.

A wrong value is `400 invalid_request` with `problems: [{ "key": "conversion.hours", "message": "Hours must look like 01:00-07:00, or be empty for any hour." }]`, and nothing is changed. So is a key that is not a setting (`host`, `ffmpegPath`, …), and a folder that is not on the server's drives or in its home folder, does not exist, or is reached through a link from elsewhere. A change the running server cannot take is undone and is `409`; one that cannot be written is `503`; either way the server is as it was. Every change and every refusal is in the audit log.

### `GET /v1/settings/history` — Manager. Built.

`{ "versions": [{ "version": 4, "at": …, "by": { "id", "name" } | null, "reason": "changed", "changed": ["serverName"], "current": true }] }`, newest first; the 50 before the current one are kept. Version 1 is `"imported from lobby.config.json"`, by null.

### `POST /v1/settings/history/{version}/restore` — Manager. Built.

Request `{ "dryRun": false }`. Makes that version's values the current ones again, as a new version, checked and applied like a `PATCH`; the answer is the same. `404` for a version that is not kept.

### `GET /v1/settings/audit?limit=<1…500>` — Manager. Built.

`{ "entries": [{ "id", "at", "by", "action", "version", "keys", "note" }] }`, newest first. `action`: `change`, `restore`, `refused`, `tmdb_set`, `tmdb_removed`, `omdb_set`, `omdb_removed`, `setup`. No secret is ever in it.

### `GET /v1/settings/browse?path=<absolute path>` — Manager. Built.

For picking library folders and Lobby's folder. Without `path`, the places to start: the mounted drives (`/proc/mounts` on Linux: devices under `/media`, `/mnt`, `/srv`, `/run/media` and the like, never `/`, `/boot`, `/proc`, `/sys`, `/dev`, `/run`; `/Volumes` on a Mac) and the home folder of the user the server runs as. With `path`, the folders in it:

```json
{
  "path": "/media/user/Media", "parent": "/media/user", "videoFiles": 0, "truncated": false,
  "folders": [{ "name": "Films", "path": "/media/user/Media/Films", "videoFiles": 412, "audioFiles": 0, "more": false }]
}
```

Only folders, read only, sorted by name, at most 500. Hidden ones (a dot first, `lost+found`, `$RECYCLE.BIN`, `System Volume Information`, `@eaDir`) are left out and cannot be asked for. A link is shown where it really leads, and only when that is in an allowed place. `videoFiles` and `audioFiles` count down to six levels and 4000 entries; `more: true` when the count stopped there. `parent` is null at a place to start. `403` outside the allowed places (also by `..` or a link), `404` for one that does not exist, `400` for a relative path or a file.

### `PUT /v1/settings/tmdb` — Manager. Built.

Request `{ "key": "…" }`: a TMDB API key (32 hex characters) or an API read access token. The server asks TMDB (`GET /3/configuration`) before it keeps it. Response `{ "tmdbKey": { "set": true, "source": "settings" } }`. `400` when it is not a key or TMDB does not accept it, `503` when TMDB cannot be reached (nothing is kept), `409` when the environment sets the key. Kept in `secrets.json` (mode 600), never in a backup, a log, the audit log or an answer. Looking titles up starts with it at once. Without a key titles come from the file names and pictures from the films.

### `DELETE /v1/settings/tmdb` — Manager. Built.

Forgets the key. Same answer, `set: false`. What was looked up stays.

### `PUT /v1/settings/omdb` — Manager. Built.

Request `{ "key": "…" }`: an OMDb key (omdbapi.com; free ones allow 1,000 requests a day, CC BY-NC data). Off until the owner sets one: without it OMDb is never asked, and search has TMDB's rating only. The server asks OMDb about one title before it keeps the key. Response `{ "omdbKey": { "set": true, "source": "settings" } }`. `400` when it is not a key or OMDb does not take it, `503` when OMDb cannot be reached. Kept in `secrets.json` like the TMDB key. With a key the server reads IMDb's rating, Rotten Tomatoes' Tomatometer and the Metascore of the library's titles by their IMDb id, a hundred a run and at most 900 a day, and again after 30 days (D-061).

### `DELETE /v1/settings/omdb` — Manager. Built.

Forgets the key. Same answer, `set: false`. Ratings that were read stay, and are no longer refreshed.

### The first setup — Manager. Built.

```ts
interface Setup {
  /** True on a fresh server (no folders when it first started with this version) until it is finished. */
  needed: boolean;
  steps: { id: "name" | "folders" | "tmdb" | "scan"; done: boolean; skipped: boolean }[];
}
```

While `needed` is true the server looks through nothing, also not the folders a manager adds; the app sets the name and the folders with `PATCH /v1/settings` and the key with `PUT /v1/settings/tmdb`. A server that already had folders never needs it.

- `GET /v1/setup` → `Setup`.
- `POST /v1/setup/steps/{name|tmdb}` `{ "state": "done" | "skipped" }` → `Setup`: the name kept as it is, or no key for now (`done` for `tmdb` needs a key: `409`). Changing `serverName` marks `name` done by itself. `404` for another step.
- `POST /v1/setup/finish` → `Setup`: starts looking through the folders. `409` without a folder. Progress is in `GET /v1/status`.

## Direct

Built on the server and in the apps, off until it is set up. How it is set up, and against what it protects: [outside.md](outside.md#the-direct-road). Every value below is worked out in [direct-vectors.json](direct-vectors.json); `tools/check-direct-vectors.swift` does it with CryptoKit.

Binary values are base64url without padding, in their one way of writing it. `‖` joins bytes. `HKDF(key, salt, info)` is HKDF-SHA256, 32 bytes unless it says otherwise. **An envelope** is `base64url(nonce ‖ ciphertext ‖ tag)`: ChaCha20-Poly1305, 12 random bytes of nonce, the associated data (AAD) as UTF-8, which is `ChaChaPoly.SealedBox.combined`. What is sealed is a JSON object in UTF-8. Ignore fields you do not know.

### 1. Getting ready, at home — Built.

Only at home or in the tailnet (`403` from outside), for every paired device, children's too.

`PUT /v1/me/direct` `{ "ringKey": "…", "agreementKey": "…" }` → `200`

```json
{ "introducer": "wss://introducer.example.com", "boxId": "…", "boxKey": "…", "fingerprints": ["…", "…"], "name": "lobby.example.com", "ringKey": "…", "allowed": false, "agreementKey": "…" }
```

The device makes an Ed25519 key (`ringKey`, kept in the Keychain, never leaves the device) and an X25519 key for this once (`agreementKey`). With the box's `agreementKey` from the answer both work out the same secret, which is never sent:

`secret = HKDF(X25519(own, theirs), deviceAgreementKey ‖ boxAgreementKey, "lobby-direct/1|secret|" + boxId + "|" + ringKey)`

Keep `ring private key`, `secret` and the rest in the Keychain, this device only, readable after first unlock. `400 invalid_request` for keys that are none or that another device has; `404 not_found` when the direct road is not set up. Again replaces what was there and ends its connections.

`GET /v1/me/direct` → the same without `agreementKey`; `ringKey` is the one enrolled with, or null. Ask it at home when the app starts; enrol when `ringKey` is not your own or `boxId` changed, and keep the new `introducer`, `fingerprints` and `name`. `allowed` is whether a manager lets the device in from outside. A device that is not may enrol, so that it works from the moment it is allowed, also when it is already away.

### 2. Ringing, at the introducer — Built.

A WebSocket at `<introducer>/v1/box/<boxId>`, without an `Origin`. Text messages of JSON.

1. ← `{ "t": "challenge", "nonce": "…" }`
2. → `{ "t": "auth", "role": "device", "key": "<ringKey>", "signature": "…" }`, Ed25519 over `lobby-introducer/1|device|<boxId>|<nonce>`.
3. ← `{ "t": "ready", "session": "…" }`
4. → and ← `{ "t": "msg", "p": "<envelope>" }`

Refused before the socket opens: `404` (no such box, or a page), `429` (too often), `503` (the day's limit). Closed with: `4001` not let in: a manager has to allow this device, or it was removed; `4404` the box is not there; `4008` too late (10 s to sign in, 2 min in all); `4003` not a message, or over 16,384 characters of envelope; `4029` too much; `4030` the day's limit. After `4001` do not try again until the app was at home or a person asks; after the others wait 2 s, doubling to a minute, with some chance in it. Close the socket once the answer is there.

### 3. The introduction, in envelopes — Built.

AAD: `lobby-direct/1|<boxId>|<ringKey>|<session>|<direction>|<count>`, direction `d2b` or `b2d`. `count` is 0 for `hello` and `welcome`, 1 for `offer` and `answer`.

| | Key | Content |
| --- | --- | --- |
| `hello` → | `HKDF(secret, "", "lobby-direct/1|hello|d2b")` | `{ "t": "hello", "nonce": nd }`, 32 random bytes |
| `welcome` ← | `HKDF(secret, nd, "lobby-direct/1|welcome|b2d")` | `{ "t": "welcome", "nonce": nb, "fingerprints": […], "ice": { "stun": [{ "host", "port" }], "turn": { "host", "port", "username", "password", "until" } \| null } }` |
| `offer` → | `HKDF(secret, nd ‖ nb, "lobby-direct/1|session|d2b")` | `{ "t": "offer", "sdp": "…" }` |
| `answer` ← | `HKDF(secret, nd ‖ nb, "lobby-direct/1|session|b2d")` | `{ "t": "answer", "sdp": "…" }` or `{ "t": "error", "error": "busy" \| "unavailable" \| "invalid" }` |

Anything that does not open is nobody: close, and treat it as no answer. The box says nothing to what does not open, to a device that is not let in and to a device that rings more than 30 times a minute. Wait 10 s for each. One offer a session. Replace the stored `fingerprints` by the welcome's: only the box can have sealed it.

`sdp` is libjuice's description: `a=ice-ufrag`, `a=ice-pwd`, `a=candidate` of UDP, component 1. Gather first (stop after 4 s; some networks never answer one of the STUN addresses), then send all candidates at once; there is no trickle. The box only takes and gives addresses of the internet at large: at home and in the tailnet use those roads. The device is the controlling end. Start with one entry of `stun`, and take the next one the next time.

### 4. The connection — Built.

QUIC (version 1, TLS 1.3, ALPN `lobby-direct/1`) over the path ICE found, the device as the client. **Accept exactly a certificate whose SHA-256 (of its DER) is in `fingerprints`**, and look at neither name nor date.

Then the device proves itself on a bidirectional stream that **it** opens: `"LDA1"` ‖ its ringKey (32 bytes) ‖ its signature (64 bytes), 100 bytes. Signed is `lobby-direct/1|connect|<boxId>|<base64url of the exporter>`; the exporter is TLS's (RFC 8446, 7.5), label `EXPORTER-lobby-direct-1`, no context, 32 bytes. With Network.framework: `sec_protocol_metadata_create_secret` on `NWProtocolQUIC.Metadata.securityProtocolMetadata` of the group. The box answers with one byte `0` and ends its side. Wait for it before anything else: what is opened before is thrown away, and the box closes the connection after 10 s, for a wrong proof, or with more than 4 streams before it.

From then on **each bidirectional stream is one HTTP/1.1 connection** to the entrance of Outside: same rules, same limits, `Host` is `name`, and `Authorization: Bearer` or the cookie with this device's own credential; another device's is an empty `404`. Streams may be used for one request after another. At most 28 at once. Nothing is accepted on unidirectional streams or datagrams, and the box opens none.

What was found with Apple's QUIC, and has to be done so:

- `NWConnectionGroup` opens a stream by itself on which nothing comes. The box allows for it.
- Send with `contentContext: .finalMessage, isComplete: false` to keep the stream open. A device that ends its side says that it went away: the box then stops sending and ends its own.
- Never cancel a stream with data under way: the whole connection breaks. End it and read it to its end.
- Keep the stream's receive window at 1 MB or less (`initialMaxStreamDataBidirectionalLocal`), and all of them at 4 MB. The box has at most 1 MB under way per device; what the app holds on top of that is the app's waste.

Keep-alive every 8 s, idle timeout 30 s, at most 3 connections per device (the oldest is ended) and 16 in all (`busy`). The box closes with QUIC code 0 when it is turned off or the device may not be here any more, and with 1 when the proof was wrong.

### 5. When the network changes — Built.

There is no ICE restart and no QUIC migration. The device makes a **new** connection, from ringing on, beside the old one, and closes the old one when the new one is proven. Do this when `NWPathMonitor` shows another path, after the app was suspended, and when nothing was heard for 10 s although something was asked. Until then requests in flight on the old one may still end well; those that fail are asked again on the new one, with `Range` from the byte that is missing. The loopback server in the app stays at its port, so the player notices only a pause. Expect 1 to 3 s; give up after 30 s and say what failed.

Off the direct road because home or the tailnet answers: close the connection. Nothing rings while the app is in the background.

### 6. Pairing with a code — Built.

For a device that was never at home. The manager opens a window (`POST /v1/outside/window`) and gives along the `introducer` and the code. The app asks for both, or reads `lobby://pair?i=<introducer>&c=<code>`. `lobby://join?c=<code>&i=<introducer>` (the introducer may be left out) is read the same way: the hook for a household's invitation. On a device that is already paired, either link adds another server (D-048).

From the code (16 characters, as under Pairing from outside): `scrypt(code as ASCII, salt "lobby-pair/1|code", N 32768, r 8, p 1, 64 bytes)`. Bytes 0…15 are the `room`, bytes 32…63 the `codeKey`. It takes 32 MB and about half a second in plain Swift.

WebSocket at `<introducer>/v1/pair/<room>`; `404` before it opens when there is no such room (a wrong code, or over), `429` when three devices are in it already. Every open code of a server has its room, so it does not matter which other codes are open. Closed with `1000` when the code is over. ← `{ "t": "ready", "session": "…" }`, no signing in. Then envelopes as above, AAD `lobby-pair/1|<room>|<session>|<step>`:

| Step | Key | Content |
| --- | --- | --- |
| `start` → | `HKDF(codeKey, "", "lobby-pair/1|code|d2b")` | `{ "commitment": SHA256("lobby-pair/1|commit|" ‖ agreementKey ‖ nonce) }` |
| `key` ← | `HKDF(codeKey, "", "lobby-pair/1|code|b2d")` | `{ "agreementKey", "nonce", "boxKey" }` |
| `reveal` → | as `start` | `{ "agreementKey", "nonce", "ringKey", "deviceName", "platform" }` |
| `waiting` ← | `HKDF(from, transcript, "lobby-pair/1|session|b2d")` | `{ "status": "pending", "expiresAt" }` |
| `collect` → | `HKDF(from, transcript, "lobby-pair/1|session|d2b")` | `{ "nonce": 16 random bytes, "done"?: true }` |
| `answer\|<that nonce>` ← | as `waiting` | `{ "status": "pending", "expiresAt" }`, `{ "status": "refused" }`, `{ "status": "approved", "device": Device, "token": "…", "direct": { … as in 1 } \| null }` or `{ "status": "done" }` |

X25519 and 32-byte nonces, all of them new. `from = X25519(own, theirs) ‖ codeKey`. `transcript` is SHA-256 over, each with its length as two bytes (big endian) in front: `"lobby-pair/1"`, the room (as text), commitment, the box's agreementKey, the box's nonce, boxKey, the device's agreementKey, the device's nonce, ringKey, deviceName, platform.

The six digits both screens show: `HKDF(from, transcript, "lobby-pair/1|comparison")`, 8 bytes, as a big endian number modulo 1,000,000, six digits. **Show them; the manager compares them** and approves with them (`POST /v1/outside/pairing/{id}/approve`). The lasting secret is `HKDF(from, transcript, "lobby-pair/1|secret")`, and the ring key that was revealed is the device's. Check that `boxKey` in `direct` is the one from `key`, and that `boxId` is its SHA-256.

The introducer hears of the new device within a second or so: its first ring can be refused with `4001`, and is tried again a few times.

`collect` every three seconds until `expiresAt`. A line that breaks after `waiting` is opened again and `collect` goes on with the same keys and the new session. Keep everything, then say `collect` with `done`. A wrong envelope gets no answer; five devices may `start` with one code, one gets to `waiting`, and it works once.

## Households

Built on the server (D-052). The server owner shares the library with other households. Each has its own viewers, devices, managers, progress, kids limits and code for grown-ups, downloads, Play On and access log; none sees anything of another's. Everything that was there before is in the owner's household, id `"owner"`.

```ts
interface Household {
  id: string;
  name: string;
  /** The server owner's own household. */
  owner: boolean;
  /** What of the library it sees, said as kids limits are (allowed groups and categories,
   * blocked ones); null: all of it. Always null for the owner's. */
  scope: KidsSettings | null;
  /** What all its devices are sent together, in megabits a second; null: no cap. */
  maxMbps: number | null;
  /** Whether its devices come in from outside. True for a guest: it lives elsewhere. */
  allowOutside: boolean;
  /** Devices it may have that are not removed; null: no limit. */
  maxDevices: number | null;
  /** A new device needs a server admin's yes too, after its household admin's. On for a new
   * guest household unless said otherwise; off for the owner's household unless turned on. */
  requiresAdminApproval: boolean;
  paused: boolean;
  pausedAt: number | null;
  createdAt: number;
  devices: number;
  managers: number;
  viewers: number;
}
```

**Who does what: three levels in every household** (`Device.access`, D-053).

| `access` | What |
| --- | --- |
| `admin` (server admin) | Everything: the library, its edits, categories, settings, folders, conversion, music edits, Apple TVs, the outside switch and the households (the routes marked **Owner**), and their own household. Only in the owner's household; they manage from home or the tailnet. The owner's managers from before households are server admins. |
| `householdAdmin` | Their own household only: its viewers, kids, kids limits and code, devices (up to household admin), downloads lists, invitations into it and its outside window (routes marked **Manager**). Never the server, folders, categories, settings or other households. From home and from outside alike. A guest household's managers from the round before are household admins. |
| `viewer` | Watches. |

An app from before `access` reads `role`: `manager` for a server admin, `viewer` for the others. A household admin is told `viewer` there: such an app would offer the server's screens to someone who may not use them, and the server refuses them anyway; it can watch, and an update brings its screens. An older server never reads a household admin as more than a viewer either: the catalogue's own `role` column says the same.

**Every route has a decision** (`HOUSEHOLD_ROUTES` in `apps/server/src/households/guard.ts`, checked by the tests to be there for every route): open, owner, about the device's own household, naming a viewer or a device that must be of its household, the library everybody shares, or the music. A route without one is not there for a guest (`404`). A viewer or device of another household is `404`, as one that does not exist.

**The library a guest sees.** All of it, or with `scope` only what that allows, by the same rules as kids limits, everywhere a kids device is limited (library, items, files, pictures, categories, popular, Play On, downloads). A kids viewer of a guest household sees what both allow, and with nothing allowed nothing. A household with a `scope` gets no music: no part of the library says what music is in it.

**Cap.** `maxMbps` holds for everything its devices are sent from the library (`/v1/assets/…`, `/v1/music/tracks/…`), at home and from outside, all of them together. Changing it takes effect within a second, also for what is being sent.

**A server admin's yes too.** With `requiresAdminApproval` every new device of the household (from its windows, its invitations, and for the owner's household home pairing) needs, after its household admin's yes with the six digits, a server admin's yes as well: `POST /v1/outside/pairing/{id}/approve` without `comparison`. Meanwhile the request is `state: "awaitingAdmin"` and the device's collect says `202` `{ "status": "pending", "waitingFor": "admin" }` (on the direct road the same in `answer`): it shows "Waiting for the server owner to approve". Server admins see it among `outsideRequests` of `GET /v1/pairing/requests` with `householdName`. A server admin's no (`DELETE /v1/outside/pairing/{id}`) turns it away and leaves it as `state: "refused"` for its household admin until it would have expired. A server admin approving a device of their own is final. Only a server admin changes the setting.

**Paused.** Its devices get `404` on every route at home and the empty `404` from outside, and what is being sent stops within a second. Nothing is removed; its invitations are taken back.

**Removed.** Its devices are removed at once (`401 device_revoked`, or the empty `404` from outside), with its viewers, their progress and plays, its downloads lists, invitations and code. Nothing of the library is touched.

### `GET /v1/household` — Built.

Any device: `{ "household": Household, "serverName": "Lobby" }`, its own.

### `GET /v1/households` — Owner. Built.

`{ "households": [Household] }`, the owner's first.

### `POST /v1/households` — Owner. Built.

`{ "name": "The neighbours", "scope"?, "maxMbps"?, "allowOutside"?, "maxDevices"?, "requiresAdminApproval"?, "inviteHours"?: 1…336 }` → `201` `{ "household": Household, "invite": Invite }`. Makes the household and an invitation for its first device, which becomes its household admin. This is "New household"; "This household" is below. `inviteHours` is 72 when left out.

```ts
interface Invite {
  id: string;
  householdId: string;
  /** What its device becomes in the household. */
  access: "householdAdmin" | "viewer";
  createdBy: string;
  createdAt: number;
  expiresAt: number;
  usedAt: number | null;
  revokedAt: number | null;
  /** Only in the answer that made it: shown once. */
  code: string;
  /** The introducer of the direct road, when there is one. */
  introducer: string | null;
  /** lobby://pair?i=<introducer>&c=<code>&h=<household>&s=<server>, for a QR code and a link. */
  link: string | null;
}
```

The code is a pairing code as under [Pairing from outside](#pairing-from-outside) (16 characters, 80 bits), and it is used the same way: over the outside entrance (`POST /v1/outside-pairing`) or the direct road ([Pairing with a code](#6-pairing-with-a-code--built)), with the six digits that both screens show. It works once, for one device, until `expiresAt`; the first device to show it uses it up, whatever comes of it. It waits for an admin of its household, or a server admin, who sees it among `outsideRequests` with `invited: true` and approves it with the digits the guest reads out (`POST /v1/outside/pairing/{id}/approve`); a new household's first device, which has no admin yet, waits for a server admin. Further devices come in through an invitation or the household's own window (`POST /v1/outside/window`, from outside).

`h` and `s` in the link are for the app to say whose household and whose server it is joining; an app from before ignores them and pairs as with any window. A link of the form `https://<site>/join#i=…&c=…&h=…&s=…`, for a web page that opens the app, is **Planned**: there is no site yet.

Only the code's hash is kept, and for the direct road the room and the key stretched from it, so an invitation outlives a restart. Every open code has its own room at the introducer, windows and invitations alike, so they all pair, in any order and at the same time (D-063); up to 64 of a server, those a device is pairing in first, then the newest. An introducer from before keeps one: that of a device that is pairing, else of the newest code. The rooms are said again every 30 minutes.

### `GET /v1/households/{id}` — Owner. Built.

`{ "household": Household, "devices": [{ "id", "name", "platform", "role", "createdAt", "lastUsedAt", "lastOutsideAt" }], "invites": [Invite without code] }`. Which devices, not what they watch.

### `PATCH /v1/households/{id}` — Owner. Built.

Any of `name`, `scope`, `maxMbps`, `allowOutside`, `maxDevices` (1…100 or null), `paused` → `200` `Household`. What is left out stays. Its devices are told at once: connections that may no longer be there are cut. For the owner's household only `name`; anything else is `409 conflict`.

### `DELETE /v1/households/{id}` — Owner. Built.

`204`. Removes a guest household, as above. `409 conflict` for the owner's.

### `POST /v1/households/{id}/invites` — Owner. Built.

`{ "access"?: "householdAdmin" | "viewer", "inviteHours"? }` → `201` `Invite`, `householdAdmin` when left out: into any household, the owner's too (a device of the owner's household that lives elsewhere comes in from outside the same way). `409` for a paused one. `DELETE /v1/households/{id}/invites/{inviteId}` takes one back, `204`.

### `POST /v1/household/invites` — Manager. Built.

"This household": `{ "access"?: "householdAdmin" | "viewer", "inviteHours"? }` → `201` `Invite`, into the manager's own household. `GET /v1/household/invites` lists them (`{ "invites": [Invite without code] }`), `DELETE /v1/household/invites/{inviteId}` takes one back. Open from outside for a household admin.

## Profiles

A profile is a viewer: one person's progress and Continue Watching. A shared device holds several.

```ts
interface Profile {
  id: string;
  name: string;
  /** A colour name from the app's palette: "red", "orange", "yellow", "green", "teal", "blue", "purple", "pink". */
  color: string;
  /** The id of a picture the apps carry ("viking-man", "panda"); null: the letter. */
  avatar: string | null;
  /** What a kids viewer may see; null: not a kids viewer. */
  kids: null | {
    allowedGroupIds: string[];
    allowedCategoryIds: string[];
    allowedItemIds: string[];
    blockedItemIds: string[];
  };
  /** How this viewer wants subtitles. Always there; a server from before leaves it out. */
  subtitles: SubtitlePreferences;
  /** What happens when something ends. Always there; a server from before leaves it out. */
  playback: PlaybackPreferences;
  /** What this viewer wants at intros and credits (D-059). Always there; a server from before leaves it out. */
  skipping: SkipPreferences;
}

interface SkipPreferences {
  /** "show": a Skip Intro button while the intro plays (the default); "skip": the player jumps over it by itself, once per film; "off": nothing. */
  intro: "show" | "skip" | "off";
  /** "show": Next Episode from where the credits start (the default); "off": only at the end. */
  credits: "show" | "off";
}

interface SubtitlePreferences {
  /** ISO 639 codes ("nl", "eng"), lower case, in order of preference. Empty: subtitles off. */
  languages: string[];
  /** "Forced subtitles (foreign speech)": the lines for speech in another language, when the film has them. */
  forced: boolean;
  size: "small" | "medium" | "large";
  /** A dark box behind the lines. */
  background: boolean;
}

/** What happens when something ends (docs/playback.md, "When something ends"). */
interface PlaybackPreferences {
  /** At the end of a film, and of a series' last episode: what goes with it. Default true. */
  filmSuggestions: boolean;
  /** The first suggestion starts by itself after the countdown. Default false. */
  filmAutoplay: boolean;
  /** The next episode starts by itself after the countdown. Default true. */
  episodeAutoplay: boolean;
  /** 0, 5, 10 or 15; default 10. 0: no countdown, Up Next waits for Play Now. */
  countdownSeconds: number;
  /** Up Next comes at the credits when the server knows where they begin. Default true. */
  startAtCredits: boolean;
  /** "Still watching?" after so many titles in a row without a touch: 0 (never), 2–5. Default 3, kids 2. */
  stillWatchingEpisodes: number;
  /** "Still watching?" after so many hours without a touch: 0 (never), 1–4. Default 0. */
  stillWatchingHours: number;
}
```

Every viewer is of one household: a device sees, changes and watches as the viewers of its own household only.

- `GET /v1/profiles` — Built. `{ "profiles": [Profile] }`, of the device's household.
- `POST /v1/profiles` — Manager. Built. `{ "name": "Robin", "color": "teal" }` → `201` `Profile`. `avatar` and `kids` are optional, also here.
- `PATCH /v1/profiles/{id}` — Manager. Built. `{ "name"?: …, "color"?: …, "avatar"?: …, "kids"?: … }` → `200` `Profile`. What is left out stays as it is, so an app that does not know a field never wipes it. `kids` replaces the whole object: all four lists, at most 5,000 ids each, or null. An id that does not exist means nothing. `kids: null` is `409 conflict` while a device belongs to the viewer.
- `PUT /v1/profiles/{id}/avatar` — Built. `{ "avatar": "panda" | null }`, required → `200` `Profile`. Changes the picture and nothing else. For every device: an ordinary one may watch as any viewer, so it may do this for any viewer; one that belongs to a kids viewer only for that viewer (`404` for another). At most 16 KB.
- `PUT /v1/profiles/{id}/subtitles` — Built. Any of `SubtitlePreferences`' fields → `200` `Profile`. What is left out stays as it is. For every device, as the avatar: one that belongs to a kids viewer only for that viewer. `POST` and `PATCH /v1/profiles…` take `subtitles` too (a manager), `null` is not allowed. At most 8 languages of 2 or 3 letters; a code is not checked against a list, so a newer app may send one this server does not know.
- `PUT /v1/profiles/{id}/playback` — Built. Any of `PlaybackPreferences`' fields → `200` `Profile`. What is left out stays as it is. For an ordinary viewer any device that may watch as them; for a kids viewer only a manager (`403` otherwise), and `404` for a device that belongs to a kids viewer: the grown-ups choose. `POST` and `PATCH /v1/profiles…` take `playback` too (a manager); `null` is not allowed. A value that is not one of those listed is `400`. Only what was chosen is kept; the rest follows the defaults of the viewer's kind, so a viewer who never chose is asked after 2 once they are a kids viewer and after 3 again when they are not. Kids control (D-062) goes before these where it says something: a mode that allows no video starts nothing.
- `GET` and `PUT /v1/profiles/{id}/subtitle-offsets/{itemId}` — Built. `{ "offsetMs": -1500 }`: how far this viewer moved the subtitles of this title against the picture, kept for the next time (negative: earlier). `0` when never moved; a `PUT` of `0` forgets it. At most 600000 either way, whole milliseconds. `404` for a title or viewer there is not. A kids device: its own viewer, allowed titles.
- `PUT /v1/profiles/{id}/skipping` — Built. Any of `SkipPreferences`' fields → `200` `Profile`. What is left out stays as it is; an unknown value is `400 invalid_request`. For every device but one that belongs to a kids viewer: a grown-up chooses this for a child, so a kids device gets `404` here. `POST` and `PATCH /v1/profiles…` take `skipping` too (a manager), for a kids viewer as for any other.
- `DELETE /v1/profiles/{id}` — Manager. Built. `204`. Removes the profile and its progress. `409 conflict` while a device belongs to it: first say whose device it is instead.

An avatar id is words of `a`–`z` and `0`–`9` joined by dashes, at most 40 characters; anything else is `400 invalid_request`. The server does not know which there are: the pictures are in the apps. An app shows the letter for an id it has no picture for, keeps the id, and never sends another one by itself. A server from before avatars leaves the field out and answers the `PUT` with `404`: no avatar is known then, which is not the same as none chosen.

## Kids limits

Built on the server. A viewer with `kids` is a kids viewer. A device with `kidsProfileId` belongs to one, and gets only what that viewer may see. Only a manager sets either; the device cannot. `GET /v1/me` tells a device its own `kidsProfileId`.

A title may be seen when its id or that of something above it is in `allowedItemIds`, or one of its categories is in `allowedCategoryIds` or in a group in `allowedGroupIds`. A title that is in a category only by its studio rule is allowed by that category (or its parent) in `allowedCategoryIds`, never by its group in `allowedGroupIds`: the group was allowed for what was put in it by hand, and a studio makes films of every kind. A rule category that is blocked blocks what it takes in. A category in `allowedCategoryIds` or `blockedCategoryIds` covers the categories inside it; one inside can be allowed or blocked by itself. A title with one blocked category (by itself or by its parent) is not seen, whatever allows it: blocked wins, also over `allowedItemIds`. `blockedCategoryIds` is new: a viewer read from an older server has none, and an app that does not send it keeps what is there (it cannot unblock by leaving it out; send `[]` for that). A title without categories is in the main part, so it comes with that group. Blocked wins: an id in `blockedItemIds` takes everything under it away. Nothing allowed is nothing shown. A show or season is there when something in it is, also for a single allowed episode. A file that holds several episodes is there only when all of them may be seen. What a manager blocked stays blocked when its file is renamed, or is removed and comes back, also for a single season, episode, extra, home video or unrecognised file: it is known again by its content, by its path, or by its place (the same episode of the same show, an extra of that title of the same film). A copy of a blocked file is blocked. When it is not sure, it is blocked; its new id is then in `blockedItemIds`, where a manager can take it out. While a blocked title is away its old id stays in the list: send it back, for leaving it out unblocks it.

For such a device everything else is `404 not_found`, also by a known id:

| Routes | A kids device gets |
| --- | --- |
| `/v1/library`, `/v1/library/query`, `/v1/items/{id}` | Allowed titles. Their `categories`, `available`, `files`, and a show's dates, are those of what is allowed in them. |
| `/v1/popular` | Plays of kids viewers only, of allowed titles. |
| `/v1/search`, `/v1/search/people/{id}` | Allowed titles, and people only through them. Nothing from beyond the library. |
| `/v1/search/outside…`, `/v1/search/picture` | `404`. |
| `/v1/assets/{id}/…` (content, playback, prepared files, subtitles), `/v1/artwork/{id}` | Those of allowed titles. An answer that is being sent is cut off within a second or so of the title being blocked, also when the device was only bound meanwhile. |
| `/v1/categories`, `/v1/logos/{id}` | Categories and groups with an allowed title in them, the parent of such a category (as a group is there for its categories, so the app can show the page; nothing in the parent that is not allowed comes with it), the main part always (it can be empty), and their logos. `revision` does not change with the limits: fetch it after each library refresh that brought something. |
| `GET /v1/me`, `POST /v1/me/downloads` | As any device. |
| `/v1/live…`, `/v1/remote/commands` | Itself, and the TVs it may play on: it plays there as its viewer, and controls only what plays as its viewer (see [Who may](#who-may)). |
| `/v1/remote/wake` | Only when the household lets kids turn on the TV (`remote.wake.kids`); otherwise `404 not_wakeable`. |
| `/v1/me/wanted` | The allowed part of its list. A rule counts its episodes after the limits. The manager's view of the device shows the same. |
| `GET /v1/profiles` | Its own viewer only. |
| `PUT /v1/profiles/{id}/avatar`, `PUT /v1/profiles/{id}/subtitles` | Its own viewer's picture and subtitles. Name, colour, limits and playback preferences stay with managers (`PUT /v1/profiles/{id}/playback` is `404`). |
| `/v1/profiles/{id}/subtitle-offsets/{itemId}` | Its own viewer's, for allowed titles. |
| `/v1/profiles/{id}/progress…` | Its own viewer's, for allowed titles. `since` is ignored: the answer is complete every time, so a title that is allowed again brings its progress. |
| `/v1/music/…` | `404`, all of it, until a manager turns on music for the viewer in its plan ([Kids control](#kids-control)); then all of the household's music and audiobooks while the mode allows listening, and its own favourites, playlists, plays and places. Editing stays `404`. |
| Everything for managers, and any route nobody decided about | `404`, where another viewer's device gets `403`. |

The library cursor keeps working when limits begin, change or end: the next refresh sends in `removed` what is no longer allowed and in `items` what is, whatever changed (the limits, a title, a category, a folder, the device's binding). `reset` is not used for it. After a change of binding `removed` may hold ids the device never had.

A device stays bound to a viewer that is gone or no longer a kids viewer, should that ever happen: it then gets nothing, until a manager says otherwise.

## The code for grown-ups

Built. A device without a lock of its own, the Apple TV, leaves kids mode only with a four-digit code that a manager chooses for the household. Each household has its own: a guest household's manager chooses theirs. The server keeps a salted scrypt hash of it (in `meta`, no table of its own), never the digits.

- `GET /v1/kids/code` — `{ "set": boolean }`.
- `PUT /v1/kids/code` — Manager. `{ "code": "1234" | null }` → `200 { "set": boolean }`. Four digits, or null for none; anything else is `400`.
- `POST /v1/kids/code/check` — `{ "code": "1234" }` → `200 { "correct": boolean }`. `409 conflict` while there is no code. Five wrong codes from one device in ten minutes lock it out for the rest of them: `429 rate_limited` with `Retry-After`, also for the right code. A guess counts before it is checked, so guesses at once are counted too. The count lives in memory, apart for the home and the outside entrance.

All three are `404` for a device that belongs to a kids viewer: it cannot be left. From outside the `GET` and the check are open to a device that is let in, the `PUT` is not.

## Kids control

Built on the server (D-062; the whole model is [kids-control.md](kids-control.md)). When and what a kids viewer may do: a plan per kids viewer with a weekly schedule, an away rule, places, screen time and Ask first; a grown-up's override; answers to the child's questions. Kids limits still say which titles.

```ts
type Mode = "everything" | "ask" | "listening" | "nothing"; // in the order of strictness

interface KidsPlan {
  defaultMode: Mode;
  /** Days 1 (Monday) to 7; local times "HH:MM", end "24:00" for midnight. An end at or before
   * the start goes on into the next day (19:30–07:00). At most 50. */
  blocks: { days: number[]; start: string; end: string; mode: Mode; label: string | null }[];
  /** Ask first: "open" asks before the app opens, "title" asks per film. */
  askStyle: "open" | "title";
  /** The household's music and audiobooks, where the mode allows listening. On unless turned off. */
  music: boolean;
  /** The music libraries (music sources) the child hears; null: all. Checked when a song plays. */
  musicSourceIds: string[] | null;
  /** Video minutes a day (0…1440, null: no limit); after that `whenOut`. */
  screenTime: null | { weekdayMinutes: number | null; weekendMinutes: number | null; whenOut: "listening" | "nothing" };
  /** The mode away from the home network (outside entrance, direct road, tailnet). */
  away: Mode | null;
  /** At most 10; radius 100…10000 m. Watched only on the child's device. */
  /** "schedule": the place changes nothing, inside it the schedule or the default decides. */
  places: { id: string; name: string; latitude: number; longitude: number; radiusMeters: number; mode: Mode | "schedule" }[];
  /** When the device cannot tell where it is: a mode, or "strictest" for the strictest of the
   * places' modes (places "schedule" passed by); null: the places do not apply (D-069). */
  whenPlaceUnknown: Mode | "strictest" | null;
  /** Who is asked: grown-up viewers with their devices; []: every admin device of the child's
   * household, named by all its grown-up viewers. */
  askers: { profileId: string; deviceIds: string[] }[];
  /** Made by the server from `askers` (an older app may send it instead). */
  askDevices: string[];
}

/** What the child may do now. */
interface KidsNow {
  mode: Mode;                 // what the plan says, before answers
  reason: "default" | "schedule" | "away" | "place" | "placeUnknown" | "screenTime" | "override";
  detail: string | null;      // the block's label or the place's name
  browse: boolean;            // films and series may be looked at
  video: "all" | "titles" | "none";
  titles: string[];           // with "titles": the ones an answer allowed
  listening: boolean;         // music and audiobooks may play
  waiting: boolean;           // Ask to open without an answer: the app only asks
  grantId: string | null;
  until: number | null;       // when this changes by the clock; null: not within a week
  next: KidsNow | null;       // what comes then (without until/next)
  screenTime: null | { day: string; limitMinutes: number | null; usedSeconds: number };
}
```

**How the mode is worked out.** An override wins while it runs. Otherwise the strictest of: the schedule's block (the strictest of overlapping ones) or the default; the away rule when away; the place the device is in (none for a place `"schedule"`), or `whenPlaceUnknown` when it cannot tell (also when it said nothing for six hours, or since the server started) and that is not null; screen time when the day's minutes are used. Ask first is lifted only by an answer, and never past a stricter mode. A viewer without a plan: Everything, with music.

**Enforcement.** For a device bound to a kids viewer, every route it may use has a need (`KIDS_MODE_ROUTES` in `src/kids/guard.ts`, tested to be there for every route): its own `GET /v1/me`, `/v1/me/kids…`, `/v1/me/direct`, `/v1/household`, `/v1/profiles`, the live channel and `POST /v1/remote/commands` always (the hub checks each play), `PUT …/progress/{item}` always (where a film stopped at a switch), the avatar unless Nothing, library, items, categories, logos, artwork, popular, progress and `/v1/me/wanted` when `browse`, `/v1/assets/…` and `POST /v1/remote/wake` when `video` allows that file, music when `listening`. Otherwise `403 kids_mode`, with `now: KidsNow`; an app keeps what it has (downloads, the catalogue) and shows the mode. What is being sent stops within a second of a switch. Play On as a kids viewer needs video allowed on the target and, when the child sends it, on its own device: otherwise `403` with `reason: "kids_mode"`. A grown-up's device in kids mode is limited by the app, as for kids limits; the server checks its Play On, wake and questions by the `profileId` it names.

**Live channel.** A session used by a child (its own device, the kids screens by their `profileId`, a TV playing as the child) gets `event: kidsMode` `{ profileId, now: KidsNow }` when it starts and whenever that changes: at a switch, an override, an answer, a change of the plan. The app then ends a film with a gentle word and fetches `GET /v1/me/kids` again. The grown-ups who may decide get `event: kidsRequest` `{ request: Request & { viewer, title } }` for a new question and `event: kidsRequestClosed` when it is answered, taken back or expired; the child's device gets `kidsRequest` with what came of it.

### For the child's device — Built.

A device bound to a kids viewer speaks for it; a grown-up's device in kids mode names the viewer (`profileId` in the query or body), which must be a kids viewer of its household.

- `GET /v1/me/kids` → `{ profileId, now: KidsNow, plan: KidsPlan, timeZone, request: Request | null, askNames: string[], musicLibraries: [{ id, name, hint }], signed: { payload, signature }, publicKey, serverTime }`. `askNames`: who the asking screen names ("Asking Mum and Dad…"). `request` is this device's latest question. `signed.payload` is base64url JSON `{ v: 1, profileId, deviceId, issuedAt, validUntil, timeZone, plan, override, grants, screenTime: { day, seconds } }`, valid for seven days; `signature` is Ed25519 over the payload's bytes, base64url; `publicKey` the raw 32-byte key, base64url, the same every time: the app pins it.
- `PUT /v1/me/kids/place` `{ "state": "inside", "placeId": "school" }` or `{ "state": "outside" }` or `{ "state": "unknown" }` → `{ now }`. Nothing else is taken: any other field (coordinates above all) is `400`. Kept in memory, only the last one per device.
- `POST /v1/me/kids/screen-time` `{ "day": "2026-11-24", "seconds": 1800 }` → `204`. What the device counted offline; the larger of the two counts holds.
- `POST /v1/me/kids/requests` `{ "kind": "open" }` or `{ "kind": "title", "itemId" }` → `201 { request }`. Only while the mode is Ask first (`409 not_asking` otherwise); a title only that the child's limits allow (`404`). One at a time: the same question again is the one that waits, another replaces it. At most six an hour: `429` with `Retry-After`.
- `GET /v1/me/kids/requests/{id}` → `{ request }`; `DELETE` takes it back → `{ request }`.

```ts
interface Request {
  id: string; profileId: string; deviceId: string;
  kind: "open" | "title"; itemId: string | null;
  state: "waiting" | "allowed" | "declined" | "expired" | "cancelled";
  createdAt: number; expiresAt: number;              // ten minutes
  answer: "watch" | "listen" | "no" | null; answeredBy: string | null; answeredAt: number | null;
  grantId: string | null;
}
```

### For grown-ups — Built.

Admins of the child's household, and the server's admins (also for a guest household's child). `404` for another guest household's child and for a kids device; `403` for a viewer's device, which may only read.

- `GET /v1/kids/now` → `{ viewers: [{ profileId, now: KidsNow }] }`, the glance for the viewer list: for each child the strictest of its own devices.
- `GET /v1/profiles/{id}/kids/plan` → `{ profileId, plan, planned, timeZone, now, grants, musicLibraries, grownUps: [{ profileId, name }], adminDevices: [{ id, name }] }`. Any device of the household. `grownUps` and `adminDevices` are whom `askers` can name.
- `PUT /v1/profiles/{id}/kids/plan` `{ "plan": KidsPlan }` → the same. The whole plan; what is left out is as in no plan.
- `PUT /v1/profiles/{id}/kids/override` `{ "mode", "minutes"? | "until"? | "untilNext": true }` → the same. With no length: until the plan's next switch when that is today, else 60 minutes; at most a day. `untilNext`: until the plan's next switch (`409 no_switch` when there is none within a week). `DELETE` ends it.
- `GET /v1/kids/requests` → `{ requests: [Request & { viewer: { name, avatar, color }, title: { id, title } | null, answeredByName: string | null, grant: { mode, until, itemId } | null }] }`, those waiting for this device. The same shape is in the answer's reply and in `kidsRequest` / `kidsRequestClosed` on the live channel, which every grown-up who was asked gets at once: "Answered by Mum — Watch until 19:30".
- `POST /v1/kids/requests/{id}/answer` `{ "answer": "watch" | "listen" | "no", "minutes"? | "until"? | "untilNext"?, "titleOnly"? }` → `{ request }`. With no length: until the plan's next switch when that is today, else an hour. A title question is answered `watch` (that title, or with `titleOnly: false` everything for that long) or `no`. The first answer counts: a later one is `409` with the state as `reason`.
- `PATCH /v1/profiles/{id}/kids/answer` `{ "answer": "watch" | "listen" }` switches the answer that runs; `DELETE` ends every answer (the child asks again).
- `PUT /v1/household/time-zone` `{ "timeZone": "Europe/Amsterdam" | null }` → `{ timeZone }`: the household's clock for its plans; null the server's.

From outside, the child's routes and the glance are open to a device that is let in; questions, answers, overrides and ending them are open to whoever may decide (`kids` in `OUTSIDE_ROUTES`). Changing the plan and the time zone is a household admin's as the rest of the household's kids: for a guest household from outside, for the owner's household from home or the tailnet (D-052).

### Push notifications — Built.

Through Apple's push service, in one of three ways (`push.mode`, operations.md, Push notifications; D-064): through the **push relay**, which holds the publisher's key for the App Store apps; **directly**, with a key of one's own for apps under one's own bundle id; or **off**.

- `GET /v1/me/push` → how this device registers: `{ "mode": "relay", "relay": { "url", "ticket" } }`, `{ "mode": "direct" }` or `{ "mode": "off" }`. The ticket is `<box key>.<until>.<signature>`: the box's Ed25519 key (the one it uses with the introducer, base64url), a time in milliseconds ten minutes ahead, and the box's signature over `lobby-push/1|ticket|<box id>|<until>`. A server from before the relay answers `404`; it takes a token.
- In relay mode the app registers with the relay itself (below) and then `PUT /v1/me/push` `{ "handle": "<the relay's handle>", "key": "<32 bytes, base64url>", "environment" }` → `204`. The key is made by the app for this server, and the server seals every notification for this device with it. The server never learns the device token. A body with `token` is refused with `400 invalid_request`.
- Directly: `PUT /v1/me/push` `{ "token": "<hex device token>", "environment": "development" | "production" }` → `204`, as before the relay. One per device, replaced by the next. `development` for a build from Xcode (APNs sandbox), `production` for TestFlight and the App Store.
- `503 unavailable` when the server pushes nothing. Not there for a kids device.
- `DELETE /v1/me/push` → `204`.
- `GET /v1/settings/push` — Server admin. `{ "configured": boolean, "mode": "relay" | "direct" | "off" }`: whether pushes go out, and how. Nothing of a key is ever told.

**The relay** (`apps/push-relay`, outside.md "The push relay"), HTTPS, JSON, no credential:

- `POST /v1/tokens` `{ "ticket", "token": "<hex>", "environment" }` → `{ "handle", "until" }`, from the app. The same token for the same box keeps its handle. `403` for a ticket that is not the box's or no longer holds, `429` past the limits.
- `POST /v1/tokens/forget` `{ "box": "<box id>", "handle" }` → `204`, whether or not it knew it.
- `POST /v1/send`, from the server: body `{ "t": <ms, growing>, "expires"?: <ms>, "to": [{ "h": "<handle>", "s": "<sealed>" }] }`, at most 32; headers `x-lobby-box` (the box's key) and `x-lobby-signature` (Ed25519 over `lobby-push/1|send|<box id>|<body>`). → `{ "results": ["sent" | "gone" | "unknown" | "limited" | "failed", …] }`, one per entry. `gone` and `unknown` handles are forgotten by the server; the app registers again. `409` for a `t` that is not newer than the last.
- **Sealed:** ChaCha20-Poly1305 with the device's key, additional data `lobby-push/1|alert`, nonce (12 bytes) then ciphertext then tag (16), base64url, at most 2,800 characters. Inside: `{ "title", "body", "category"?, "thread"?, "data": { "kind", "requestId"?, "serverId" } }`. `docs/push-vectors.json` has the exact bytes.
- What Apple gets from the relay: `{ "aps": { "alert": { "title": "Lobby", "body": "A request is waiting." }, "sound": "default", "mutable-content": 1 }, "lobby": { "v": 1, "s": "<sealed>" } }`. The iPhone and iPad app's notification service opens `s` and shows its title and body, with its category (Watch, Listen, No), thread and `data` as `lobby`, so the notification is the same as one sent directly. What it cannot open shows as it came.

Directly, a child's question: `{ "aps": { "alert": { "title", "body" }, "category": "LOBBY_KIDS_QUESTION", "sound": "default", "thread-id": "kids-<profileId>" }, "lobby": { "kind": "kidsRequest", "requestId", "serverId" } }`, to every grown-up who is asked, expiring with the question; the category's Watch, Listen and No answer with `POST /v1/kids/requests/{id}/answer` on the server named by `serverId`. A device waiting to be paired at home: `{ "aps": { "alert" }, "lobby": { "kind": "pairing", "serverId" } }` to the owner's household admins. A token Apple calls gone is forgotten.

## Library

The apps keep their own copy of the catalogue, so that shelves and Downloads open with the server unreachable. They fetch everything once and then only what changed.

### `GET /v1/library?cursor=<cursor>&limit=<1…1000>` — Built.

Without `cursor`: the whole catalogue, in pages. With the `cursor` from the previous response: what changed since.

```json
{
  "items": [Item],
  "removed": ["item id", "…"],
  "cursor": "opaque string",
  "more": false,
  "reset": false
}
```

- Keep calling with the returned `cursor` while `more` is true. Then store the last `cursor` for next time.
- `removed` lists items that no longer exist. Drop them, and their children.
- `reset: true` means the server could not continue from the cursor sent (it was too old or from another catalogue). The response then starts a full fetch: discard the local copy once the full fetch is complete and replace it. `reset` is true only on that first page; the pages that follow it are ordinary.
- Every returned `cursor` stays valid, including one from a page with `more: true`. A fetch that was interrupted continues from the last cursor it received.
- Items arrive in the order they changed, not in display order. A parent may arrive after its children.
- `limit` defaults to 500.

```ts
interface Item {
  id: string;
  kind: "movie" | "show" | "season" | "episode" | "extra" | "personal";
  /** A season's show, an episode's season, an extra's film or show. */
  parentId: string | null;
  title: string;
  sortTitle: string;
  year: number | null;
  /** 0 is Specials; show them after the numbered seasons. null means unknown: on a season, "Other episodes", shown last. */
  seasonNumber: number | null;
  episodeNumber: number | null;
  overview: string | null;
  airDate: string | null;
  runtimeMs: number | null;
  genres: string[];
  /** The library folders this came from, e.g. ["Pixar"], or the categories a manager chose instead. */
  categories: string[];
  /** Their ids, in the same order as `categories`. */
  categoryIds: string[];
  /** Of a film, show or video (empty below it): categories that take it in by their studio rule, besides its own. */
  ruleCategoryIds: string[];
  /** Of a film or show (empty below it): who made or showed it as TMDB says, the most important first. "company:3", "network:49". Not sent by older servers. */
  studios: { id: string; name: string }[];
  matchStatus: "unmatched" | "matched" | "needs_review" | "locked" | "personal";
  imdbId: string | null;
  tmdb: { type: "movie" | "tv"; id: number } | null;
  /** For kind "extra". */
  extraKind: "trailer" | "featurette" | "sample" | null;
  /** An online trailer. Local trailers are child items of kind "extra". */
  trailer: { provider: "youtube"; key: string } | null;
  artwork: { poster: Artwork | null; backdrop: Artwork | null; still: Artwork | null; logo: Artwork | null };
  /** One line from TMDB, for a film or show. */
  tagline: string | null;
  /** How well known it is, 0 to 1, from TMDB's numbers. Null when nobody rated it there, or it is not matched. */
  renown: number | null;
  /** TMDB's average rating, 0 to 10, one decimal. Null with fewer than 10 votes, or not matched. Not sent by older servers. */
  rating: number | null;
  /** When Lobby first saw it. For a season or show: when its newest episode arrived. A replaced, converted or renamed file does not change it. */
  addedAt: number;
  /** For a season or show: when its newest episode arrived, if that was at least a day after the first. Else null. */
  newEpisodesAt: number | null;
  /** For a season or show: the latest air date of the episodes that are here. */
  latestAirDate: string | null;
  /** False when none of its files (or its children's files) can be reached right now. */
  available: boolean;
  /** Empty for shows and seasons. */
  files: MediaFile[];
}

interface Artwork {
  id: string;
  width: number | null;
  height: number | null;
}

interface MediaFile {
  assetId: string;
  role: "main" | "trailer" | "extra";
  edition: string | null;
  /** Part number of a film split over several files. */
  part: number | null;
  /** Set when one file holds several episodes and the boundaries are known. */
  startMs: number | null;
  endMs: number | null;
  /** How many episodes share this file. 1 normally. */
  sharedBy: number;
  available: boolean;
  sizeBytes: number;
  durationMs: number | null;
  container: string;
  /** Changes when the file's bytes change. A download made from another revision is stale. */
  revision: string;
  playability: "direct" | "remux" | "transcode" | "unsupported";
  /** A sentence for the viewer when playability is not "direct". */
  playabilityReason: string | null;
  /** For "transcode": the server converts the picture itself, so POST …/playback works. */
  convertible: boolean;
  video: { codec: string; width: number | null; height: number | null; bitDepth: number } | null;
  audio: AudioTrack[];
  subtitles: SubtitleTrack[];
  /** Where its intro and credits are, in milliseconds of the file; null when not known. Not sent by older servers. See "Intros and credits". */
  markers: {
    intro: { startMs: number; endMs: number; source: MarkerSource } | null;
    credits: { startMs: number; source: MarkerSource } | null;
  };
}

/** Who said so: a manager, the file's chapters, or Lobby by comparing the episodes of a season. */
type MarkerSource = "manual" | "chapters" | "detected";

interface AudioTrack {
  index: number;
  codec: string;
  language: string | null;
  title: string | null;
  channels: number | null;
  isDefault: boolean;
}

interface SubtitleTrack {
  /** Use in the subtitle URL. */
  id: string;
  source: "embedded" | "sidecar";
  codec: string;
  language: string | null;
  title: string | null;
  /** Only the lines for speech in another language. A file beside the film says so in its name. */
  isForced: boolean;
  /** Text subtitles can be shown. Image subtitles (PGS, DVD) cannot yet. */
  isText: boolean;
}
```

A subtitle file beside a video belongs to it when its name starts with the video's (or it sits in a `Subs` folder beside the only video there). What follows the video's name tells the language and whether it is forced: `Film.en.srt`, `Film.eng.forced.srt`, `Film.Dutch.vtt`, `Film.fre.ass`. SubRip, WebVTT and ASS/SSA are text; `.sub`/`.idx` are pictures.

`playability` describes what Apple's player needs:

| Value | Meaning | What the app does |
| --- | --- | --- |
| `direct` | Plays as it is. | Stream or download `/v1/assets/{id}/content`. |
| `remux` | The picture is fine, the container or sound is not (MKV, DTS). | Ask for prepared playback (see Playback). |
| `transcode` | The picture must be converted (MPEG-4/XviD, AV1, 10-bit H.264). | Ask for prepared playback (see Playback). The server converts MPEG-4 Part 2 and MS-MPEG-4 v3 to H.264; for the rest the answer is `unsupported` with a reason. A device that decodes AV1 in hardware may play an AV1 MP4 directly from `/content`. |
| `unsupported` | No usable video. | Show `playabilityReason`. |

#### For home and category pages

The apps compose these pages themselves from their copy of the catalogue, so they are the same offline, made of what is on the device.

- **Logo** (`artwork.logo`): the title as a drawn word mark, for films and shows. A PNG with transparency, at most 800 pixels wide, with its own colours. Null: write the title. In the household's language, else English, else one without a language.
- **Banner**: `artwork.backdrop`, without words when TMDB has such a picture. `width` says how wide it really is: 1920, or 1280 for a picture TMDB has no wider, or made from the file.
- An episode or season has no logo or backdrop of its own: use its show's, up the `parentId`s.
- **Latest Added**: by `addedAt`, newest first. **New episodes**: shows by `newEpisodesAt`.
- **Popular**: `GET /v1/popular` first, then by `renown`. `renown` is fame, not quality, and not the household's: 0.6 × how many people rated it (log scale, full at 20,000) + 0.2 × the same × the average rating (few ratings count towards 6.5) + 0.2 × TMDB's popularity now (log scale, full at 200), in steps of 0.01. Looked at again about once a month.
- **For a download**: fetch `artwork.backdrop` at `w=1280` (or 1920) and `artwork.logo` at `w=800`, of the film or show, and keep them by artwork id; `tagline`, `renown` and the rest are in the item. Keep the last answer of `/v1/popular`.
- Null in all of these is normal: TMDB may not have it, or the server has not come to this title yet. It then arrives as a change through the sync.

### `GET /v1/library/query` — Built.

The films, shows and videos of a list (Movies, Series, a category, a genre, search results), filtered and in order. The apps make their lists from their own copy of the catalogue with the same rules (LobbyKit `TitleQuery`), so a list is the same offline; this is for a device that wants the server to do it. Kids limits come first: a kids device filters only what its viewer may see, as in `/v1/library`.

Each filter is a query parameter; one sent several times is any of them (`genre=Drama&genre=Comedy`), and different filters all apply. Left out: no filter.

| Parameter | Values | A title passes when |
| --- | --- | --- |
| `kind` | `movie`, `show`, `personal` | it is of that kind. |
| `yearFrom`, `yearTo` | a year, once each | its year (a manager's change counts) is in the range, both ends in. A decade is `yearFrom=1990&yearTo=1999`. A title without a year is in no range. |
| `genre` | a genre name | it has the genre, whatever the case. |
| `studio` | a studio id (`company:3`) | TMDB says that studio made or showed it. |
| `category` | a category id | it is in the category or one inside it, also by a studio rule. |
| `watch` | `unwatched`, `in_progress`, `watched` | for the viewer in `profile`: a film is watched when finished, in progress when started; a show is watched when every episode is finished, in progress when one is started or finished, unwatched otherwise. Needs `profile`; a kids device only its own viewer (`404` for another). |
| `length` | `short`, `standard`, `long` | its length is under 40 minutes, 40 to 150, or over 150. A film's length is its runtime, else its first file's; a show's the average of its episodes'. Unknown: in none. |
| `added` | `week`, `month`, `year`, once | it came in the last 7, 30 or 365 days (`addedAt`; a show when its newest episode did). |
| `quality` | `4k` | a file of it (an episode's, of a show) is at least 3,200 pixels wide. HDR is not known yet. |
| `language` | a language as the files name it (`eng`) | a file of it has sound in that language, whatever the case. |

`sort` is `title` (the default), `year`, `added`, `popular`, `length` or `rating`, and `order` is `asc` or `desc`. Left out, `title` and `length` go up, the others down: newest, most watched and best rated first. What is not known (no year, no rating, no length) comes last either way; titles that are the same come by title. `popular` is what the household watched (`/v1/popular`, a kids device kids' plays), then the rest by `renown`.

`offset` (default 0) and `limit` (0 to 500, default 100) page the answer:

```ts
interface TitleQueryAnswer {
  /** How many titles pass, all pages together. */
  total: number;
  offset: number;
  /** This page, in order. */
  items: Item[];
}
```

Anything else is `400 invalid_request`: a value it does not know, a year that is not four digits, `added`, `sort` or `order` sent twice, more than 100 values of one filter. What is on a device (Downloaded) is filtered by the app alone. The server works out what it needs of every title once per library revision; 3,000 titles answer in a few tens of milliseconds after that (`test/query.test.ts`).

### `GET /v1/popular?viewers=<all|kids>` — Built

What the device's household watched in the last 180 days, most first: nobody counts in another household's. Made to be kept for offline: a few kilobytes, with an `ETag` (`If-None-Match` answers `304`). Fetch it with a library refresh.

```ts
interface Popular {
  days: 180;
  viewers: "all" | "kids";
  /** Films, home videos and shows, by plays, then most recent. Only titles with a play. */
  titles: { itemId: string; plays: number }[];
}
```

A play is one viewer and one title on one day (the server's), with at least 10 minutes or a quarter of it watched. Episodes count for their show, once a day however many. It is worked out from the progress the devices send: a position that moves forward counts as far as the time in between allows, so jumping ahead, marking as watched and retries do not. A film watched offline arrives as one position and counts.

Only counts of all viewers together, never who or when. A removed viewer's plays go with them, and everything goes after 180 days. A kids device always gets `viewers: "kids"`: plays of kids viewers only, of what its viewer may see (of a show, of the episodes it may see). `viewers=kids` is the same for kids mode on a device without limits: show what that viewer may see of it.

### `GET /v1/categories` — Built

The household's categories in its own order, by the part of the library (group) they belong to. The group with `name: null` is the main part and comes first.

```ts
interface Categories {
  /** Counts changes to this setup. */
  revision: number;
  groups: {
    /** Stable: a rename or a move never changes an id. Refer to groups and categories by id. */
    id: string;
    name: string | null;
    /** An SF Symbol name. */
    icon: string | null;
    color: "red" | "orange" | "yellow" | "green" | "teal" | "blue" | "purple" | "pink" | null;
    logo: Logo | null;
    /** The entries' names, in the same order, for apps from before categories had ids. */
    categories: string[];
    /** Every category of the group, each top-level one followed by those inside it. */
    entries: { id: string; parentId: string | null; name: string; icon: string | null; color: string | null; logo: Logo | null;
      /** Titles of these studios are in it too. */
      rule: { studioIds: string[] } | null }[];
  }[];
  /** By category name, for apps from before categories had ids. */
  logos: { [name: string]: { id: string; width: number; height: number } };
}

interface Logo {
  id: string;
  width: number;
  height: number;
  /** False for an opaque picture: draw it as it is, its shape is only a rectangle. */
  transparent: boolean;
}
```

`GET /v1/logos/{id}` answers a PNG that never changes; draw a transparent one's shape in one colour (its own colours are often black). A category without one gets its icon.

An item is in a group when one of its categories is; an item without categories is in the main part. Category names are unique across groups, whatever their case. A category may hold films, shows or both. Every change moves the library cursor, also when no item changed.

**Categories inside a category**. An entry with a `parentId` is inside that category: one level deep (a category inside another holds none itself), always in the same group, in its own order among the others inside the same parent. A parent can have folders and titles of its own as well.

- An item's `categories` and `categoryIds` hold only its own categories, never the parent they are in. A title in "Early" inside "Lantern" says `["Early"]`. An app works out the parent from `parentId` (a title is in the parent when it is in the parent itself or in one inside it). So an edit that sends back what it read never puts a title in a parent by accident.
- An app from before reads `entries` and `categories` as one flat list in which each parent is followed by those inside it, and every title in its own category. It shows them side by side, as before; a parent that has no titles of its own is an empty category there, which those apps leave out. Its order requests and moves keep working (see Editing categories).
- Logos, icons and colours are per category, also for those inside another.

**Categories that follow studios**. A category with a `rule` holds, besides its folders' titles and the titles chosen for it, every film and show that TMDB says one of those studios made (`"company:<TMDB company id>"`) or showed (`"network:<TMDB network id>"`). Such a title is in it in `ruleCategoryIds` and keeps its own `categoryIds`: a rule never takes a title out of its own categories, it is in both. An app shows it on that category's page and shelves too; for the group a title belongs to, and for apps from before, only `categoryIds` count. What is inside a film or show (episodes, extras) follows it. A rule category can be inside another and hold others. The studios are read from TMDB with the title; for what was matched before, with the next refreshes, a few dozen titles a run.

### `GET /v1/items/{id}` — Built.

`{ "item": Item, "children": [Item] }`. Children of a show are its seasons and extras, of a season its episodes, of a film its extras.

## Editing items

Managers only: every route here answers a viewer with `403`. Edits never rename or change a file, an item's id or anyone's progress. They are kept apart from the automatic values and laid over them, so they survive rescans and TMDB refreshes, and putting a field back shows the newest automatic value. Every change bumps the library revision, so it reaches other devices through `GET /v1/library`.

### `GET /v1/items/{id}/edit` — Manager. Built.

```ts
interface EditView {
  item: Item;
  /** Counts edits to this item only; scans and lookups do not change it. Send it with every change. */
  revision: number;
  /** Only the fields this kind of item has. */
  fields: { [field in "title" | "sortTitle" | "year" | "overview" | "genres" | "categories"]?: {
    automatic: unknown;
    /** A changed field can hold null or an empty list, so look here and not at `override`. */
    overridden: boolean;
    override: unknown;
    effective: unknown;
  } };
  /** The categories to choose from; empty when the item has no categories of its own. */
  categories: { id: string; name: string }[];
  /** The item's own categories by id; `fields.categories` has the same by name. */
  categoryIds: { automatic: string[]; overridden: boolean; effective: string[] };
  /** The names alone, for apps from before categories had ids. */
  categoryNames: string[];
  /** The pictures on the server, the selected one first. Keys are the kinds this item has. */
  artwork: { [kind in "poster" | "backdrop" | "still" | "logo"]?: ArtworkOption[] };
  /** A manager chose that there is no logo. */
  withoutLogo: boolean;
  match: {
    status: Item["matchStatus"];
    /** A manager decided: this match, or none. */
    chosen: boolean;
    tmdb: { type: "movie" | "tv"; id: number } | null;
    /** Only films and shows. */
    canChange: boolean;
    /** False when the server has no TMDB key. */
    available: boolean;
    /** Why it was not matched, and what it might be. */
    reason: string | null;
    candidates: { type: "movie" | "tv" | "episode"; id: number; title: string; originalTitle: string | null;
      year: number | null; overview: string | null; posterPath: string | null;
      season?: number; episode?: number; evidence: string[] }[];
    /** What was read from the file names. */
    evidence: string[];
  };
}

interface ArtworkOption {
  source: "tmdb" | "frame" | "upload";
  /** Null for a picture that is still only at TMDB. */
  artworkId: string | null;
  /** For source "tmdb". */
  path: string | null;
  /** A small version, on this server. */
  previewUrl: string;
  width: number | null;
  height: number | null;
  language: string | null;
  selected: boolean;
  /** Selected by a manager, so no refresh replaces it. */
  chosen: boolean;
}
```

Fields: a film, show or personal video has all six; a season or episode has `title`, `sortTitle` and `overview`; an extra has `title` and `sortTitle`. Pictures: film, show and personal have `poster`, `backdrop` and `logo`, a season `poster`, an episode `still`.

Every change below answers `200` with the new `EditView`, `409 conflict` with the current `EditView` (beside `error`) when `revision` is not the current one, and `400 invalid_request` for anything malformed.

### `PATCH /v1/items/{id}` — Manager. Built.

`{ "revision": 3, "set": { "title": "Up", "year": null }, "reset": ["overview"] }`

`title` and `sortTitle`: one line of 1 to 300 characters. `year`: 1850 to 2200 or null. `overview`: at most 10000 characters or null. `genres`: at most 20 names of at most 60 characters. `categoryIds`: at least one, all from `GET /v1/categories` (or `categories`, the same by name, for older apps; `reset` calls the field `categories`); a show's categories also apply to its seasons, episodes and extras. `reset` puts fields back to automatic. A new title also changes the order unless `sortTitle` is set. The item's `sortTitle` is the normalised form of what was typed.

### `GET /v1/items/{id}/artwork-options?kind=<kind>` — Manager. Built.

`{ "kind": "poster", "revision": 3, "tmdbAvailable": true, "options": [ArtworkOption] }`: what is on the server, then at most 30 pictures from TMDB, the household's language first. TMDB pictures need a matched item.

`GET /v1/items/{id}/artwork-options/preview?kind=<kind>&path=<path>` is the small JPEG (PNG for a logo) a `previewUrl` points at. Logos from TMDB are PNGs only; SVGs are not listed, fetched or served.

### `POST /v1/items/{id}/artwork` — Manager. Built.

Chooses a picture; it stays until it is put back.

- `{ "revision": 3, "kind": "poster", "source": "tmdb", "path": "/abc.jpg" }`
- `{ "revision": 3, "kind": "poster", "source": "existing", "artworkId": "…" }`
- `{ "revision": 3, "kind": "backdrop", "source": "frame", "positionMs": 754000, "assetId": "…" }`. `assetId` is optional: the item's first file, or a show's first episode. Not for a logo.
- `{ "revision": 3, "kind": "logo", "source": "none" }`: no logo, the title in words. Only for a logo. `DELETE` goes back to the automatic one.

### `POST /v1/items/{id}/artwork/upload?kind=<kind>&revision=<revision>` — Manager. Built.

The body is the JPEG, PNG or HEIC itself, at most 20 MB, at least 100 pixels and at most 12000 on a side. The server recognises it by its contents, decodes it and stores a new JPEG of at most 1600 pixels wide, without location or other data. A logo is stored as a PNG of at most 800 pixels on a side, with its transparency, and may be 40 pixels low. Anything else is `400`. An app does well to send a JPEG: a HEIC the server's ffmpeg cannot put together is refused.

### `DELETE /v1/items/{id}/artwork?kind=<kind>&revision=<revision>` — Manager. Built.

Back to the picture Lobby chooses.

### `GET /v1/items/{id}/match?query=<title>&year=<year>` — Manager. Built.

Searches TMDB for a film or show. `year` is optional. `{ "results": [{ "tmdb": { "type": "movie", "id": 14160 }, "title": "Up", "originalTitle": "Up", "year": 2009, "overview": "…", "previewUrl": "…" }] }`, at most 20.

### `PUT /v1/items/{id}/match` — Manager. Built.

`{ "revision": 3, "tmdbType": "movie", "tmdbId": 14160 }`. `tmdbType` is `movie` for a film and `tv` for a show. The item becomes `locked` and is filled in before the answer; a show's seasons and episodes follow in the background and arrive through the library sync. What the old match brought is removed; edits and chosen pictures stay. A lookup that fails after this is tried again later.

### `DELETE /v1/items/{id}/match?revision=<revision>` — Manager. Built.

There is no match: the item shows what its files say and is not looked up again. `matchStatus` is `locked` and `tmdb` is null.

### `POST /v1/items/{id}/match/automatic` — Manager. Built.

`{ "revision": 3 }`. Lets Lobby look the item up by itself again.

## Editing categories

Managers only: a viewer gets `403`. Nothing here removes or changes a title or a file. The config names a folder's category, group and logo once, when the folder is new to the catalogue; after that the setup lives in the catalogue and its backups.

### `GET /v1/categories/edit` — Manager. Built.

`Categories` (above) with `folders: { id, name, hint, available, categoryId: string | null }[]` (the library folders) and `colors: string[]`.

Every change below sends the `revision` it is based on (in the body, or `?revision=` for DELETE and uploads) and answers `200` with this view; `409 conflict` with the current view beside `error` when someone was first; `400` for anything malformed or a name that is taken; `404` for an unknown id.

| Request | Body or query | Does |
| --- | --- | --- |
| `POST /v1/categories/groups` | `{ name, icon?, color? }` | Adds a group, last. |
| `PATCH /v1/categories/groups/{id}` | `{ name?, icon?, color? }` | The main part has no name to change. |
| `PUT /v1/categories/groups/order` | `{ ids }` | All named groups, each once. The main part stays first. |
| `DELETE /v1/categories/groups/{id}` | `moveTo=<group id>` | `moveTo` is required while it holds categories. Not the main part. |
| `POST /v1/categories` | `{ groupId?, parentId?, name, icon?, color? }` | Adds a category, last in its group, or with `parentId` last inside that one (`groupId` may then be left out, and must be the parent's when sent). |
| `PATCH /v1/categories/{id}` | `{ name?, groupId?, parentId?, icon?, color? }` | `groupId` of another group moves it to the end of that group, out of the category it was in. `parentId` puts it at the end inside that category, in that one's group; `null` makes it top-level, last in its group. The categories inside one that moves go along. |
| `PUT /v1/categories/order` | `{ groupId, parentId?, ids }` | With `parentId` (a category, or `null` for the group's top-level ones): those, each once. Without it, as apps from before send it: all categories of the group, each once; each keeps its parent, and the list says the order among neighbours. |
| `DELETE /v1/categories/{id}` | `foldersTo=<category id>` or `none` | Required while folders feed it. Titles put in it by hand keep their other categories, or go back to their folder's. Categories inside it move up one level, in its place, with their folders and titles. |
| `POST /v1/categories/arrange` | see below | Several changes as one. |
| `POST /v1/categories/arrange/undo` | `{ token }` | Takes the last arrangement back. |
| `POST /v1/categories/merge` | `{ into, ids }` | Several become one, see below. |
| `PUT /v1/categories/folders/{id}` | `{ categoryId }` | The category the folder feeds, or null. |
| `PUT /v1/categories/{id}/logo` | `{ path }` | A logo from the search. |
| `POST /v1/categories/{id}/logo/upload` | a JPEG, PNG or HEIC as the body | Checked like an artwork upload, stored as a PNG of at most 600 pixels a side that keeps its transparency. |
| `DELETE /v1/categories/{id}/logo` | | No logo. |

Refused with `400`: a category inside one that is inside another, inside itself, or in another group than its parent (also `groupId` and `parentId` that disagree); a parent of a category that holds categories itself. Deleting a group keeps what is inside what.

`rule` is accepted wherever a category's look is (`POST`, `PATCH`, arrange): `{ "studioIds": ["company:7", "network:12"] }` (1 to 50) or `null`. Giving a category a rule, or changing it, always counts as a change about kids viewers (below).

#### Several at once: `POST /v1/categories/arrange`

```ts
{
  revision: number;
  /** New ones. Elsewhere in the request "new:<key>" stands for its id. */
  create?: { key: string; groupId?: string; parentId?: string | null; name: string; icon?: string | null; color?: string | null }[];
  /** As PATCH /v1/categories/{id}, each category once. `logoFrom` (also on `create`): the logo
   *  that category has before the request, which it keeps too. */
  categories?: { id: string; logoFrom?: string; name?: string; groupId?: string; parentId?: string | null; icon?: string | null; color?: string | null }[];
  /** As PUT /v1/categories/order with parentId, applied after the rest. */
  order?: { groupId: string; parentId?: string | null; ids: string[] }[];
}
```

Only the result has to fit, so two can swap names, a new category can take the name of one that is renamed in the same request, and a category inside another can become its parent. All of it happens or nothing does. The answer is the edit view with `created: { [key]: id }`. `key`: 1 to 64 of `A-Z a-z 0-9 - _`; at most 500 entries per list.

Example, three categories under one new "Lantern", one of them renamed because it had that name:

```json
{ "revision": 7,
  "create": [{ "key": "top", "groupId": "g-small", "name": "Lantern" }],
  "categories": [{ "id": "c-lantern", "parentId": "new:top", "name": "Early" },
                 { "id": "c-meadow", "parentId": "new:top" }, { "id": "c-harbour", "parentId": "new:top" }],
  "order": [{ "groupId": "g-small", "parentId": "new:top", "ids": ["c-meadow", "c-harbour", "c-lantern"] }] }
```

The household's studio, in one step: a new parent named after the old category, which takes its logo and colour, with the old one, its second folder's category and a third one under it, renamed:

```json
{ "revision": 9,
  "create": [{ "key": "studio", "groupId": "g-kids", "name": "Lantern", "color": "blue", "logoFrom": "c-lantern" }],
  "categories": [{ "id": "c-lantern", "parentId": "new:studio", "name": "Classics" },
                 { "id": "c-lantern-2", "parentId": "new:studio", "name": "Sequels" },
                 { "id": "c-actors", "parentId": "new:studio" }] }
```

Folders, chosen titles, icons and kids limits stay with each category's id, so a viewer allowed the old category sees the same as before (and the new parent is allowed for nobody).

#### Several into one: `POST /v1/categories/merge`

`{ revision, into, ids }`: the categories in `ids` (each once, not `into`) become `into`. Their folders feed it, the titles put in them by hand are in it (once), their studios join its rule (at most 50 in all) and the categories inside them go inside it. Then they are removed. `into` keeps its name, place, look and kids limits; without a logo it takes the first one's that has one. No title is removed. Refused with `400`: `into` inside one of `ids`, or categories inside one of `ids` while `into` is inside another (two levels). The answer is the edit view with `categoryId: into`. It always counts as a change about kids viewers: a viewer allowed `into` sees what the others brought, so that is asked first. Limits that named a removed category keep its id, which no longer allows or blocks anything. It is not an arrangement: `undo` is null after it.

**Undo.** `GET /v1/categories/edit` and every answer carry `undo: string | null`: a token while the setup is still the one the last arrangement made. `POST /v1/categories/arrange/undo { revision, token }` puts names, places, order, icons and colours back and removes the categories it created (titles put in one by hand go back to their folder's category, as with a delete; no title is removed). After any other change to the categories it is `409 conflict`. Logos are set with their own routes, after an arrangement.

#### Kids viewers

Every change above (also uploads and deletes, with `?dryRun=true&kidsToken=…` in the query) takes `dryRun` and `kidsToken`, and every answer has:

```ts
{
  /** One per kids viewer whose titles change. */
  kidsChanges: {
    profileId: string; name: string;
    /** Films, shows and videos with something in them the viewer did not see before; the first 50 by title. */
    appearing: { count: number; titles: { id: string; title: string }[] };
    disappearing: { count: number; titles: { id: string; title: string }[] };
  }[];
  /** Names exactly what would appear. */
  kidsToken: string;
}
```

- `dryRun: true` changes nothing and answers `200` with the setup as it would be (with the current `revision`, `undo: null`), `dryRun: true`, `kidsChanges`, `kidsToken` and `needsConfirmation`.
- **Fail-closed rule.** A change that concerns categories inside others or blocked categories (one that has, gets or loses a parent, holds others, or is in a kids viewer's `blockedCategoryIds`, including deleting it and moving folders out of it) and that lets any kids viewer see something they did not see before is refused with `409 kids_confirmation`, the current edit view, `kidsChanges` and `kidsToken`, unless the request carries that `kidsToken`. Show `kidsChanges` to the manager, then send the same request with the token. A token is for exactly what would appear: when something else would appear by then (a title arrived, the limits changed), it is refused again with the new token. Taking something away never asks; it is in `disappearing`.
- With a `kidsToken`, any change (also a flat one) is refused unless it matches. An app that always asks first sends the dry run's token. Without one, a change of flat categories that are not blocked goes through as before, so apps from before can still move them; they get `409` with a message to show for the rest.
- A title's own categories (`PATCH /v1/items/{id}`) and the limits themselves (`PATCH /v1/profiles/{id}`) are explicit choices about a title or a viewer and do not ask. Names are one line of 1 to 60 characters; `icon` is an SF Symbol name of at most 64 characters (`star.fill`) or null; `color` is one of `colors` or null.

### `GET /v1/categories/suggestions?min=<n>` — Manager. Built.

Studios with at least `min` (8) films and shows in the household that no category's rule names and no manager dismissed. Companies of one studio come as one suggestion: their names without words for the kind of company ("Pictures", "Animation", "Studios", …) are the same. Nothing is made by itself.

```ts
{ min: number; suggestions: {
    /** Stays the same while the same studios are in it. */
    id: string;
    name: string;
    studios: { id: string; name: string; logoPath: string | null; titles: number }[];
    count: number;
    /** The first six by title. */
    titles: { id: string; title: string }[];
    /** For GET /v1/categories/logo-search/preview?path=… */
    logoPath: string | null;
    /** A category of the same name, which could take the rule instead. */
    categoryId: string | null;
  }[] }
```

- `POST /v1/categories/suggestions/{id}/accept` `{ revision, groupId?, parentId?, name?, icon?, color?, logo?: false }`: a new category with the suggestion's studios as its rule, named as suggested unless `name` is sent, with the logo from TMDB (when it can be fetched; `logo: false` for none). Or `{ revision, categoryId }`: the studios join that category's rule (it gets one when it had none; at most 50 studios). Answers as every change, with `categoryId`, and takes `dryRun` and `kidsToken`.
- `POST /v1/categories/suggestions/accept` `{ revision, ids, categoryId? | groupId?, parentId?, together?, name?, icon?, color?, logo?: false }`: several suggestions in one place as one change. With `categoryId` all their studios join that category's rule. Otherwise in the group, or inside `parentId`: one new category per suggestion, named and with the logo as suggested, or with `together: true` one category for all of them (named `name`, or as the first; the first's logo). `name` without `together` is for a single suggestion. Answers as every change, with `categoryIds` (what was made or joined, in the order of `ids`) and `categoryId` (the first), and takes `dryRun` and `kidsToken`. `404` when one of `ids` is no longer suggested.
- Apps never put a suggestion anywhere by themselves: the manager says where (D-049).
- `POST /v1/categories/suggestions/{id}/dismiss?min=<n>`: its studios are not suggested again. Answers the list.
- `lobby studios [min]` prints the same on the server, with how many titles have their studios read.

### `GET /v1/categories/logo-search?query=<studio>` — Manager. Built.

`{ "results": [{ "name": "Pixar", "country": "US", "path": "/….png", "previewUrl": "…" }] }`, at most 20 studios on TMDB that have a logo. `503` when TMDB cannot be reached.

## Search

Built (D-061). One search for the library, by words and filters, and for what TMDB has that is not in the library. Library results play; the others only link out. Kids limits and the household's part of the library come first, failing closed.

### The query language

`q` is words and filters together, as typed. The apps' filter chips write the same words (LobbyKit `SearchFilters`); the server reads both with one parser (`apps/server/src/search/syntax.ts`). What is not a filter it knows stays a word: `rt>500` or `colour:red` are searched for as words.

| Filter | Means |
| --- | --- |
| `title:toy` | the title has the word |
| `title="Toy Story"`, `exact:Up` | the title is exactly that (case and accents aside) |
| `year:1994`, `year:1990..1999`, `year:1990-1999`, `year>=2000`, `year<1980`, `year:..1980`, `year:90s`, `decade:1990s` | years, both ends in |
| `actor:"Tom Hanks"` (`cast:`, `star:`), `director:Nolan`, `writer:…`, `person:…` (`with:`) | that person is in it in that role; a name with nobody of it in the library gives nothing and is named in `unknownPeople` |
| `rating>=7` (`tmdb`), `imdb:7.5..9`, `rt>80` (`tomatoes`, `tomatometer`), `metacritic<=60` (`mc`, `metascore`) | the rating of that source, on its own scale: TMDB and IMDb 0 to 10, Rotten Tomatoes (critics) and Metacritic 0 to 100. `>` and `<` on a whole number are the next whole number. A title without that rating passes no rating filter |
| `runtime<90`, `runtime:90..120`, `runtime:90` (85 to 95) | minutes |
| `genre:Drama`, `studio:Pixar`, `collection:"Toy Story"` | as named, whatever the case |
| `kind:film`, `kind:series`, `kind:video`, `is:film` | the kind |
| `is:watched`, `is:unwatched`, `is:started` | for the viewer in `profile` |

Values with spaces go in quotes. Several filters all apply; several people must all be in it.

### `GET /v1/search?q=<query>&profile=<viewer>&limit=<0…200>` — Built.

The library. Also takes every filter of `GET /v1/library/query` (`kind`, `yearFrom`, `genre`, `category`, …), `sort` and `order`, and `person=<TMDB person id>` (several) with `role=any|cast|director|writer`. `limit` is per group, 30 when left out. With `profile` a kids viewer's limits hold on any device, also one without limits of its own. Without words and without filters every group is empty.

```ts
interface SearchAnswer {
  query: string;
  /** The words that are left after the filters. */
  text: string;
  /** The filters understood, for chips: `token` is how it is written in `query`, to take it out. */
  understood: { key: string; label: string; token: string }[];
  unknownPeople: string[];
  /** "tmdb", and "imdb", "rottenTomatoes", "metacritic" when the server has an OMDb key. */
  ratingSources: string[];
  films: Group<SearchTitle>;
  series: Group<SearchTitle>;
  videos: Group<SearchTitle>;
  episodes: Group<{ item: Item; showId: string | null; match: Match | null }>;
  /** People in the library whose name has the words (or the people of a person filter). */
  people: Group<{ id: number; name: string; picture: string | null; titles: number; roles: ("cast" | "director" | "writer" | "creator")[] }>;
  collections: Group<{ id: number; name: string; itemIds: string[] }>;
}
interface Group<T> { total: number; items: T[] }
interface SearchTitle { item: Item; ratings: Ratings; match: Match | null }
/** Why it is there: "title", "alias", "person", "character", "collection", "studio", "genre", "overview". `text` is the name, character, other title… */
interface Match { field: string; text: string | null }
/** Each on its own scale; null when not known. */
interface Ratings { tmdb: number | null; imdb: number | null; rottenTomatoes: number | null; metacritic: number | null }
```

Words match from their start, without case or accents ("amelie" finds "Amélie"), in the title, other titles (TMDB's alternative titles and translations), people and the characters they played, studios, genres, the collection and the summary; an episode by its title and its show's. With few results a word that is a letter or two off (none in words under four letters), and parts of words ("atrix"), count too. Best match first: a title that is what was typed, then by how well it matches, unless `sort` says otherwise; with a rating filter and no words, best rated first. People come with a title's details from TMDB; what was matched before gets them in the next refreshes, 40 titles a run, so a person may be found by fewer titles for a while. The index follows the library in batches of 2,000 titles, in the background after each scan; a search writes at most one batch first, so after an upgrade a large library is fully searchable a little after the first scan.

### `GET /v1/search/outside?q=<query>&profile=<viewer>` — Built.

What TMDB has for the same query that is not in the library: films, shows and people, at most 12 each. The words go to TMDB, nothing else. Years and TMDB's rating filter these; filters of other sources cannot be applied out there and are listed in `notApplied`. With a person filter and no words, the titles of that person at TMDB. Never kept as items. `404` for a kids device or a kids viewer. Each device may ask 30 times a minute (40 at once) for all the routes beyond the library together; more is `429` with `Retry-After`.

```ts
interface OutsideAnswer {
  available: boolean;
  /** Why there is nothing: "no_key" (the server has no TMDB key), "unavailable", "rate_limited". */
  reason: string | null;
  films: OutsideTitle[];
  series: OutsideTitle[];
  people: { id: number; name: string; knownFor: string | null; knownForTitles: string[]; picture: string | null; links: Links }[];
  notApplied: string[];
  /** Notices to show with these results: TMDB's, and OMDb's when its ratings are used. */
  attribution: string[];
}
interface OutsideTitle {
  tmdb: { type: "movie" | "tv"; id: number };
  title: string; originalTitle: string; year: number | null; overview: string | null;
  /** For `GET /v1/search/picture`. */
  poster: string | null;
  /** TMDB's (null with fewer than 10 votes); OMDb's only where already known. */
  ratings: Ratings;
  votes: number;
  /** Looked up for the first six films and six series; null for the rest until opened. */
  imdbId: string | null;
  links: Links;
  itemId: null;
}
interface Links { tmdb: string; imdb: string | null }
```

### `GET /v1/search/outside/{movie|tv}/{id}` — Built.

One of those: `OutsideTitle` and `genres`, `runtimeMinutes`, `people` (the first 20: `{ id, name, role, character, picture }`), `attribution`, with OMDb's ratings when the server has an OMDb key (asked then, if not known). `itemId` is set when it is in the library after all. `404` for a kids device; `409` without a TMDB key, `503` when TMDB cannot be reached.

### `GET /v1/search/people/{id}?profile=<viewer>&outside=<true|false>` — Built.

A person by TMDB's id: their titles in the library first, then elsewhere.

```ts
interface PersonPage {
  person: { id: number; name: string; picture: string | null };
  /** In the library, as far as the device may see; newest first. */
  titles: { item: Item; ratings: Ratings; roles: { role: string; character: string | null }[] }[];
  /** From TMDB: biography, dates, links, and `elsewhere`: their titles not in the library, most popular first (OutsideTitle with `roles`). Null for a kids device, with `outside=false`, or when TMDB could not be asked. */
  outside: { id; name; biography; birthday; deathday; knownFor; picture; links: Links; elsewhere: (OutsideTitle & { roles: string[] })[] } | null;
  outsideReason: string | null;
}
```

A kids device, or a kids viewer, gets only the titles the child may see, and `404` when there are none: no person beyond them.

### `GET /v1/search/picture?path=<TMDB path>` — Built.

A poster or a person's picture from TMDB, small (185 pixels wide), through the server: devices never ask TMDB themselves. A JPEG, `Cache-Control: private, max-age=604800`. `400` for a path that is not TMDB's, `404` for a kids device.

## Progress

Progress belongs to a profile. Devices may be offline for days, so every update carries an operation id and can be retried safely.

```ts
interface Progress {
  itemId: string;
  positionMs: number;
  durationMs: number | null;
  /** True once the viewer finished it. Continue Watching leaves it out. */
  completed: boolean;
  /** Increases with every accepted change on this server. */
  revision: number;
  /** When the viewer did it, by their device's clock. */
  updatedAt: number;
}
```

### `GET /v1/profiles/{profileId}/progress?since=<revision>` — Built.

`{ "progress": [Progress], "revision": 4812 }`. Without `since`: everything for the profile. Pass the returned `revision` next time. A cleared position comes back as `positionMs: 0, completed: false`, so the row is never missing.

### `PUT /v1/profiles/{profileId}/progress/{itemId}` — Built.

```json
{
  "opId": "a fresh UUID per change, reused on every retry of that change",
  "baseRevision": 4790,
  "positionMs": 1264000,
  "durationMs": 3480000,
  "completed": false,
  "updatedAt": 1795531000000
}
```

`baseRevision` is the `revision` of the progress the device last saw for this item, or `null` if it never saw one.

- `200` `{ "progress": Progress }`: accepted. Also the answer to every retry of an `opId` that was accepted before.
- `409 conflict` with `{ "error": …, "progress": Progress }`: the server holds a change this device had not seen, made later than this one (`updatedAt`). Take the returned progress. A retry of the same `opId` gets the same 409.

`updatedAt` later than the server's clock is stored as the server's time of arrival. Two changes stamped in the future therefore order by when they arrived, so a device with a fast clock cannot win every conflict.

The rule: when `baseRevision` matches the stored revision, the update applies. When it does not, the later `updatedAt` wins. So a restart or a mark-unwatched done yesterday on the Mac is not undone by an iPad that comes back online with positions from last week. `updatedAt` in the future is clamped to the server's clock.

Mark unwatched: `positionMs: 0, completed: false`. Mark watched: `completed: true`.

## Statistics

What is watched, when and by whom (docs/decisions.md, D-060). The server keeps sittings: one viewer with one film or episode on one device, from the places the apps report (`PUT …/progress`), with no pause longer than 30 minutes. A sitting says how much was really watched (as `GET /v1/popular` counts it: never more than the clock allows at twice the speed), whether it was finished, the road (`home`, `tailnet`, `relay`, `direct`), how the film was sent (`direct`, `prepared`, a `download` on the device, or `unknown`) and, after Play On, the device that sent it. Listening comes from the music library's play history (`POST /v1/music/profiles/{id}/plays`). The server also counts the bytes it sends of films and songs, per hour, household and road, and the copies it prepared and the files it converted, with the time they took.

Everything is kept for `statistics.keepDays` (a setting, 730 days by default, 30 to 3650) and then deleted, the music play history with it. Nothing older is taken in. Places in titles (progress) are not statistics and stay.

**Who sees which** (docs/decisions.md, D-066):

| Device | A viewer's page | The household's overview | The server's page |
| --- | --- | --- | --- |
| Server admin | every viewer of every household, children included | any household's (`?household=`) | yes |
| Household admin | every viewer of their own household, children included | their own household's | no (`403`) |
| Anyone else | only the viewer in front on the device, never a child | no (`403`) | no (`403`) |
| A child's own device | none (`404`) | none (`404`) | none (`404`) |

There is no sign-in per viewer, so "the viewer in front" is the viewer the device's app last said was in front on its live channel (`POST /v1/live/{session}`, `profileId`), kept per device while the server runs. Until it has said so, after a start of the server for instance, a device that is not an admin sees no viewer's page (`403`). A device whose viewer in front is a child (the kids screens of a grown-up's device) sees no statistics at all, an admin's included (`403`). A viewer of another household is `404`, except for a server admin.

All pages take:

- `range`: `week` (the last 7 local days, today included), `month` (30), `year` (365) or `all` (as far back as is kept). Default `month`.
- `tz`: the viewer's time zone, such as `Europe/Amsterdam`. Days, months, weekdays and hours are the viewer's there. Default the server's. A sitting's time is spread over the hours it took, so one across midnight counts for both days. Sittings known from before statistics (migration 24, from the daily plays) only have a day: they count for days and months, not for hours.

Times are milliseconds since the epoch; amounts of time `…Ms`, of data `…Bytes`.

### `GET /v1/stats/viewers/{profileId}?range=&tz=` — Built.

As the table above says. A guest household with a part of the library sees only titles of that part. Rate limited per device (`429`).

```ts
interface ViewerStats {
  viewer: { id: string; name: string; color: string; avatar: string | null; kids: boolean };
  keptDays: number;
  /** Always false. Older apps read it, from when a child's own device had a page of its own. */
  simple: false;
  range: { name: "week" | "month" | "year" | "all"; timeZone: string; firstDay: string; lastDay: string; from: number; to: number };
  totals: { watchedMs: number; sessions: number; titles: number; filmsFinished: number; episodesFinished: number; listenedMs: number; tracksPlayed: number; activeDays: number };
  /** Every day of the range, oldest first, also the empty ones. */
  days: { day: string; watchedMs: number; listenedMs: number }[];
  months: { month: string; watchedMs: number; listenedMs: number }[];
  /** 7 rows, Monday first, of 24 hours each: time watched. */
  heatmap: number[][];
  /** Mornings 6–12, afternoons 12–18, evenings 18–23, nights 23–6; weekends are Saturday and Sunday. */
  when: { mornings: number; afternoons: number; evenings: number; nights: number; weekdays: number; weekends: number };
  /** Films and series (an episode counts for its series), most watched first; ten at most. */
  topTitles: { itemId: string; title: string; kind: string | null; watchedMs: number; sessions: number; lastAt: number | null }[];
  /** Series watched in the range, last watched first: how far along (completed episodes) and where. */
  series: { itemId: string; title: string; episodesWatched: number; episodes: number; lastEpisodeId: string; lastEpisode: string | null; lastAt: number }[];
  genres: { id: string; name: string; watchedMs: number }[];
  studios: { id: string; name: string; watchedMs: number }[];
  /** The categories of the library folders the files are in. */
  categories: { id: string; name: string; watchedMs: number }[];
  /** Days in a row with watching: the run up to today (or yesterday), and the longest kept. */
  streak: { current: number; longest: number };
  music: {
    listenedMs: number;
    plays: number;
    topAlbums: { id: string; title: string; artist: string; coverId: string | null; listenedMs: number; plays: number }[];
    topArtists: { name: string; listenedMs: number }[];
  };
  playOnSessions: number;
  roads: Record<"home" | "tailnet" | "relay" | "direct" | "unknown", number>;
  deliveries: Record<"direct" | "prepared" | "download" | "unknown", number>;
  devices: { id: string; name: string; platform: string | null; watchedMs: number }[];
  /** The last 50 sittings of the range, newest first. */
  history: {
    id: string; itemId: string; titleId: string;
    /** The film, or the series; for an episode `subtitle` is "S1 E2 · Its title". */
    title: string; subtitle: string | null;
    startedAt: number; endedAt: number; timed: boolean; watchedMs: number; completed: boolean;
    device: string | null; road: string; delivery: string; playOnFrom: string | null;
  }[];
}
```

A kids viewer's page is the grown-ups' view of that child: `days` is their screen time in Lobby (watching and listening), `when` says how much of it is in the evening and at weekends. Kids schedules, when they come, link here; nothing here depends on them.

### `DELETE /v1/stats/viewers/{profileId}/history/{sessionId}` — Built.

Takes one sitting out of a viewer's history, and that day of that title out of what is popular. `204`; `404` when it is not this viewer's. Whoever may see the viewer's page, as the table above says; at home only (outside: `403`).

### `DELETE /v1/stats/viewers/{profileId}` — Household admin. Built.

Forgets everything the viewer watched and listened to: sittings, the daily plays behind `GET /v1/popular`, and the music play history. Their places in titles stay. `204`. An admin of the viewer's household, or a server admin for any household. At home only.

### `GET /v1/stats/household?range=&tz=&household=` — Household admin. Built.

A household's own overview: the server's page cut to that household's watching. A household admin gets their own household (`household` left out, or their own id; another is `404`); a server admin any household, their own without `household`. Every number is the household's alone: sittings of its viewers, the music its viewers played, the bytes sent to its devices. Nothing of the server (preparing, converting, the library, storage) or of other households is in it. A guest household's admins read it from outside too; for everyone else it waits for home. A household with a part of the library sees only titles of that part.

```ts
type HouseholdStats = Pick<
  ServerStats,
  "keptDays" | "range" | "totals" | "days" | "heatmap" | "hours" | "topTitles" | "viewers" | "devices" | "roads" | "deliveries" | "traffic" | "playOn"
> & { household: { id: string; name: string } };
```

### `GET /v1/stats/server?range=&tz=&household=` — Server admin. Built.

The owner's household only, at home only. Without `household`, `viewers`, `devices`, `topTitles` and `playOn` are the owner's household's; other households are in `households` as totals. With `household=<id>` the server admin opens that household: those four are then its own. Everything else is the whole server.

```ts
interface ServerStats {
  keptDays: number;
  range: ViewerStats["range"];
  household: { id: string; name: string } | null;
  totals: { watchedMs: number; sessions: number; viewers: number; devices: number; listenedMs: number; tracksPlayed: number };
  /** `sessions`: sittings begun that day; `viewers`: who began one. */
  days: { day: string; watchedMs: number; sessions: number; viewers: number }[];
  heatmap: number[][];
  /** Time watched per hour of the day, the busiest hours. */
  hours: number[];
  topTitles: { itemId: string; title: string; kind: string | null; viewers: number; sessions: number; watchedMs: number }[];
  viewers: { id: string; name: string; color: string | null; avatar: string | null; kids: boolean; watchedMs: number; sessions: number; lastAt: number }[];
  devices: { id: string; name: string; platform: string | null; watchedMs: number; sessions: number }[];
  households: { id: string; name: string; owner: boolean; watchedMs: number; sessions: number; viewers: number; devices: number; bytesSent: number }[];
  /** Time watched by road, and by how it was sent. */
  roads: Record<"home" | "tailnet" | "relay" | "direct" | "unknown", number>;
  deliveries: Record<"direct" | "prepared" | "download" | "unknown", number>;
  /** Bytes of films and songs sent. Away is everything but home. */
  traffic: { homeBytes: number; awayBytes: number; byRoad: Record<string, number>; days: { day: string; homeBytes: number; awayBytes: number }[] };
  /** Copies prepared for playback; `converted`: of them with the video converted, `ahead`: before anyone asked. */
  preparations: { count: number; converted: number; ahead: number; timeMs: number; bytes: number };
  /** Files converted to replace their originals: in the range, and `savedInAllBytes` over all time. */
  conversions: { done: number; failed: number; waiting: number; timeMs: number; savedBytes: number; savedInAllBytes: number };
  /** The library now, and what came in per month of the range (films, and episodes). */
  library: { films: number; shows: number; episodes: number; months: { month: string; films: number; episodes: number }[] };
  playOn: { sessions: number; watchedMs: number; targets: { id: string; name: string; sessions: number }[] };
  /** As far as the server can tell; a value it cannot tell is null or left out. */
  storage: { playbackCacheBytes?: number; playbackCacheMaxBytes?: number; musicCacheBytes?: number; musicCacheMaxBytes?: number; databaseBytes?: number; dataFreeBytes?: number | null; dataTotalBytes?: number | null };
}
```

## Media

### `GET` or `HEAD /v1/assets/{assetId}/content` — Built.

The file's bytes, exactly as on the drive.

- Headers: `Content-Length`, `Content-Type`, `Accept-Ranges: bytes`, `ETag: "<revision>"`, `Last-Modified`.
- `Range: bytes=…` (one range) answers `206` with `Content-Range`. A range outside the file answers `416` with `Content-Range: bytes */<length>`.
- `If-Range` with an ETag that no longer matches answers `200` with the whole file, so a resumed download of a changed file starts over instead of splicing two versions.
- `503 unavailable` when the drive is missing. `404` for an unknown asset.

### `POST /v1/assets/{assetId}/playback` — Built.

Asks how to play or download a file. For a file that needs repackaging (`playability: "remux"`) or whose picture the server can convert (`playability: "transcode"` with MPEG-4 Part 2 or MS-MPEG-4 v3 video, the old AVI films) the first call starts the work, and every later call reports on it, so the app calls it again (about once a second) until it has what it needs. Calling it for a file that plays directly costs nothing. Why it works this way, and what it costs on the Pi, is in [playback.md](playback.md).

No request body. `200` when `state` is `ready` or `unsupported`, `202` while there is work in progress.

```ts
interface Playback {
  state: "ready" | "preparing" | "queued" | "failed" | "unsupported";
  /** "direct": the URLs are the original file. "prepared": a repackaged or converted copy. null when unsupported. */
  mode: "direct" | "prepared" | null;
  /** The file revision the URLs belong to. Store it with a download. */
  revision: string;
  /** 0 to 1. */
  progress: number;
  /** How far into the film the stream reaches already. A seek beyond it has to wait. */
  preparedMs: number;
  durationMs: number | null;
  /**
   * Give this to AVPlayer. null until a viewer who starts now would not catch up with
   * the copy: a second or two for a repackaged file, about 5 seconds for a converted one,
   * longer when the server is converting more slowly than the film plays (see `speed`).
   */
  streamUrl: string | null;
  /** One MP4 file to download for offline use. null until `state` is `ready`. */
  downloadUrl: string | null;
  /** The exact length of `downloadUrl`. Check the finished download against it. */
  downloadBytes: number | null;
  /** The sound tracks of what is played. In a prepared copy the default track comes first. */
  audio: PlaybackAudio[];
  /** True when the picture is converted to H.264 (old AVI films). Converting takes minutes, not seconds. */
  videoConverted: boolean;
  /**
   * While `state` is `preparing`: how fast the copy is written, as a multiple of playback
   * speed (4 = four minutes of film per minute). null otherwise, and before the first
   * segment is written. `(durationMs - preparedMs) / speed` estimates the time left.
   */
  speed: number | null;
  /** A sentence for the viewer when `state` is `failed` or `unsupported`. */
  message: string | null;
}

interface PlaybackAudio {
  /** `AudioTrack.index` of the original track. */
  index: number;
  /** The codec as played: the original's, or, when it was converted, "ac3" (surround DTS and the like) or "aac" (stereo MP3, Opus and the like). */
  codec: string;
  converted: boolean;
  language: string | null;
  title: string | null;
  channels: number | null;
  isDefault: boolean;
}
```

| `state` | Meaning | What the app does |
| --- | --- | --- |
| `ready`, `mode: "direct"` | The file plays as it is. | Play `streamUrl` (it is `/v1/assets/{id}/content`). Download the same URL. |
| `queued` | Waiting for another file to finish. Only one file's picture is converted at a time. | Show that it is being prepared. Ask again. |
| `preparing`, `streamUrl: null` | The first seconds are being written, or a conversion is too slow to start watching yet. | Ask again. Normally one or two calls; for a converted file show `progress` and say it is being converted. |
| `preparing`, `streamUrl` set | Playable now, up to `preparedMs`. | Start AVPlayer on `streamUrl`. To resume beyond `preparedMs`, keep asking until it is past the position. A download waits for `ready`. |
| `ready`, `mode: "prepared"` | The whole copy exists. | Play `streamUrl`. Download `downloadUrl`. |
| `failed` | ffmpeg could not read the file, or the cache has no room for it. | Show `message`. Asking again tries again. |
| `unsupported` | The picture needs a conversion the server does not do (AV1, 10-bit H.264), or there is none. | Show `message`. |

`streamUrl` of a prepared copy is an HLS master playlist. `downloadUrl` is a single fragmented MP4 that holds the video (H.264 when it was converted) and every sound track; AVPlayer plays it from a local file and offers the sound tracks itself. Do not stream `downloadUrl` over the network: without a playlist AVPlayer first reads through every fragment of the file.

A prepared copy can be evicted from the server's cache at any time. Its URLs then answer `404`: ask for playback again, which prepares it again. The same goes for URLs of an older `revision` after the file changed.

`503 unavailable` when the drive is missing and no copy exists yet. `404` for an unknown asset.

### `GET` or `HEAD /v1/assets/{assetId}/prepared/{revision}/{file}` — Built.

The files behind `streamUrl` and `downloadUrl`. Apps do not build these URLs; they come from the playback answer and from inside the playlists.

| `file` | What it is |
| --- | --- |
| `master.m3u8` | HLS master playlist: the stream, one audio rendition per sound track when there are several, one subtitle rendition per text subtitle that is ready. Starts playback at the beginning (`EXT-X-START`). |
| `index.m3u8` | The stream's playlist. It grows while the copy is written (`EVENT`) and gets its end marker when the copy is complete. |
| `media.mp4` | The copy: video and all sound tracks in one fragmented MP4. The playlists address it by byte range. |
| `audio-N.m3u8`, `audio-N.mp4` | Sound track N+1 on its own, so the stream can switch to it. |
| `subtitles/{subtitleId}.m3u8` | A one-segment playlist around the subtitle's WebVTT. |

`media.mp4` and `audio-N.mp4` take `Range` like `/content`: `206` with `Content-Range`, `416` outside the file. A finished file carries `ETag: "<revision>-prepared"` and honours `If-Range`, so a resumed download of a replaced copy starts over. While a file is still being written it is served up to its current length with `Cache-Control: no-store` and no `ETag`.

`404 not_found` for any other name, for a `revision` that is not the file's current one, and for a copy that does not exist (any more).

### `GET` or `HEAD /v1/assets/{assetId}/subtitles/{subtitleId}.vtt` — Built.

A text subtitle (`SubtitleTrack.isText`) as WebVTT in UTF-8, for any asset, also one that plays directly. `subtitleId` is `SubtitleTrack.id`.

- A sidecar file is converted on the first request, in milliseconds. Windows-1252 files come out as UTF-8.
- An embedded track of a file that was prepared is ready with the copy: it is written in the same pass. For any other file the first request reads the whole video file to collect the lines (about 20 s per 2 GB on a Raspberry Pi 5) and the result is kept.
- Styling of ASS/SSA subtitles is dropped; the text and timing are kept.

`422 unsupported_subtitle` for a picture subtitle (ask for its `.json`) or a track ffmpeg cannot read. `404 not_found` for an id the asset does not have. `503 unavailable` when the drive is missing and the subtitle was not converted before.

### `GET` or `HEAD /v1/assets/{assetId}/subtitles/{subtitleId}.json` — Built.

A subtitle stored as pictures (Blu-ray PGS, DVD, DVB; `codec` `hdmv_pgs_subtitle`, `dvd_subtitle`, `dvb_subtitle`, also `.sup` and `.idx` sidecars) as cues the app draws itself (D-057):

```json
{ "width": 1920, "height": 1080,
  "cues": [{ "startMs": 61000, "endMs": 63500, "x": 610, "y": 940, "width": 700, "height": 90, "png": "<base64>" }] }
```

`width` and `height` are the screen the cues are placed on, the video's size. Each cue's `png` is the part of that screen it draws on, with transparency, at `x`, `y`. Times are the file's, as for WebVTT. The first request reads the whole file (an embedded track) and the result is kept; the request can outlast the app's, which then asks again. Same guards as `.vtt`: kids limits, households, from outside as subtitles.

`422 unsupported_subtitle` for a text subtitle or a track ffmpeg cannot read; `404`, `503` as for `.vtt`.

### `POST /v1/assets/{assetId}/airplay` — Built.

For AirPlay. The receiver (an Apple TV) fetches the film itself and gets neither the device's header nor its cookie, so the app asks for a pass first: a path under which this one file can be read without a credential, for a while.

`{}` → `200` `{ "prefix": "/v1/airplay/<pass>", "expiresAt": 1795670000000, "assetId": "…" }`. Replace `/v1` at the start of any of the file's paths with `prefix`: `/v1/assets/{id}/content`, `/v1/assets/{id}/prepared/{revision}/master.m3u8`, its playlists, segments and subtitles. Relative paths in a playlist stay under the pass by themselves.

- Only `GET` and `HEAD` under `/v1/assets/{assetId}/`, of that asset. Anything else under the prefix is `404`, and a credential sent along changes nothing.
- As the device that asked for it: its kids limits hold, also when they change after, and the pass ends when the device is removed.
- Eight hours, eight per device; another drops the oldest. Kept in memory: a restart of the server ends them all.
- Home only: from outside `POST` is closed, and so is the prefix. The receiver is on the home network.

`404 not_found` for an asset that is not there (or not for a kids device).

### `GET /v1/artwork/{artworkId}?w=<width>` — Built

A poster, backdrop or still as JPEG, a title's logo as PNG, scaled to at most `w` pixels wide (one of 200, 400, 800, 1280, 1600, 1920; other values round up, above 1920 down). It is never made larger than it is. Cache it forever: an artwork id never changes its picture. A backdrop may gain width under the same id (`width` in the item says so); fetch it again only for a size larger than you have.

## Downloads a manager puts on a device

A manager decides what each device holds; the device fetches it by itself. The server keeps a _wanted list_ per device, turns it into files, prepares the files that need a copy before the device asks, and shows the manager what the device says it has. Built on the server and in the iPhone, iPad and Mac app.

Two things are kept apart: what a manager wants on a device, and what the person on the device downloaded themselves. The wanted list never touches the second.

### The wanted list

```ts
interface WantedEntry {
  id: string;
  /** "item": one title. "next_unwatched": the next episodes of a series a viewer has not watched. */
  kind: "item" | "next_unwatched";
  /** The film, episode, season or show. For a rule: the show. */
  itemId: string;
  itemKind: "movie" | "show" | "season" | "episode" | "extra" | "personal";
  /** For a rule: whose watching decides what "next" is. null otherwise. */
  profileId: string | null;
  /** For a rule: how many episodes ahead, 1 to 50. null otherwise. */
  count: number | null;
  /** The manager device that added it. */
  addedBy: string | null;
  addedAt: number;
}
```

- A season or show stands for all its episodes, in watching order (specials last). A film stands for its main file: the first edition, all its parts; not its trailers or extras.
- A rule stands for the first `count` episodes of the show, in order, that the viewer has not completed. Specials (season 0) are left out. It follows the viewer's progress: when an episode is watched to the end on any device, it leaves the list and the next one enters. A rule for a viewer who was removed asks for nothing.
- A device holds at most 500 entries, and is told at most 2,000 files; what is beyond that is counted in `leftOut`.
- Removing a device (`DELETE /v1/devices/{id}`) drops its list and everything it reported.

### `GET /v1/devices/wanted` — Manager. Built.

One line per paired device, for the list of devices.

```ts
{ devices: {
    id: string; name: string; platform: string; role: "manager" | "viewer";
    /** When the device last talked to the server, to the minute. */
    lastSeenAt: number | null;
    entries: number;        // wanted entries
    files: number;          // files they stand for
    downloaded: number;     // of those, on the device
    failed: number;         // of those, that cannot be done as things are (see the device's page for why)
    bytesToFetch: number;
    ownDownloads: number;   // what the person downloaded themselves
    storage: { freeBytes: number | null; totalBytes: number | null; reportedAt: number } | null;
  }[] }
```

### `GET /v1/devices/{deviceId}/wanted` — Manager. Built.

Everything about one device.

```ts
{
  device: { id; name; platform; role; lastSeenAt };
  wanted: WantedEntry[];
  /** The files the entries stand for, in the order the device fetches them. */
  assets: (WantedAsset & {
    /** 0 to 1: how far the server is with the copy. 1 when the file needs none. */
    prepareProgress: number;
    /** What the device last said about this file; null when it has not mentioned it. */
    device: { revision: string; state: ReportState; bytesDone: number; bytesTotal: number | null;
              error: ReportError | null; reportedAt: number } | null;
  })[];
  leftOut: number;
  storage: { freeBytes: number | null; totalBytes: number | null; reportedAt: number } | null;
  /** Bytes of wanted files the device does not have yet. */
  bytesToFetch: number;
  /** Whether that fits in the free space the device reported. null when it reported none. */
  fits: boolean | null;
  /** What the device holds that is on no list: the person's own downloads (`own: true`), and leftovers. */
  other: { assetId; revision; state; bytesDone; bytesTotal; error; own: boolean; reportedAt; itemId: string | null }[];
}
```

A file is on the device when `device.state` is `downloaded` and `device.revision` equals `revision`. `404 not_found` for a device that does not exist or was removed.

### `POST /v1/devices/{deviceId}/wanted` — Manager. Built.

Body: `{ "kind": "item", "itemId": "…" }` or `{ "kind": "next_unwatched", "showId": "…", "profileId": "…", "count": 3 }`.

→ `201 { "entry": WantedEntry }`. Saying the same thing again answers `200` with the entry that exists; for a rule it also sets the new `count`. `400 invalid_request` for a malformed body, a `count` outside 1 to 50, or a rule on something that is not a show. `404 not_found` for an unknown device, title or viewer. `409 conflict` when the device already has 500 entries.

### `DELETE /v1/devices/{deviceId}/wanted/{wantedId}` — Manager. Built.

→ `204`. `404` when that entry is not on this device's list. The device removes the files it fetched for the entry the next time it reads its list, unless another entry still asks for them or the person downloaded them themselves.

### `GET /v1/me/wanted` — Built.

A device's own list. The device is the one the credential belongs to; nothing in the request can name another.

```ts
interface DeviceList {
  /** Changes when anything below does. Also sent as the ETag. */
  revision: string;
  assets: WantedAsset[];
  leftOut: number;
}

interface WantedAsset {
  assetId: string;
  itemId: string;
  /** The file's revision. Store it with the download; a new revision means: fetch again. */
  revision: string;
  /** 1 is fetched first. */
  order: number;
  /** Size of the download. Exact once `state` is "ready"; before that the original's size, as an estimate. */
  bytes: number;
  bytesExact: boolean;
  state: "ready" | "waiting" | "preparing" | "does_not_fit" | "unsupported" | "failed" | "unavailable";
  /** "direct": the original file. "prepared": a repackaged or converted copy. null until ready. */
  mode: "direct" | "prepared" | null;
  /** Fetch this, with `Range` and `If-Range` as for any download. null until `state` is "ready". */
  downloadUrl: string | null;
  /** A sentence for the manager when the file cannot be fetched now. */
  message: string | null;
  /** The entries that ask for this file. */
  why: { wantedId: string; kind: "item" | "next_unwatched" }[];
}
```

| `state` | Meaning | The device |
| --- | --- | --- |
| `ready` | `downloadUrl` is there. | Fetches it, checks the length against `bytes`. |
| `waiting` | A copy has to be prepared and it is not this file's turn. | Waits. |
| `preparing` | The copy is being written. | Waits. |
| `does_not_fit` | The server's cache has no room for the copy: the file is larger than the cache, or the cache is full of copies other downloads still need. | Waits; says why. The second kind clears by itself as devices fetch their files. |
| `unsupported` | The file cannot be made playable on Apple devices (AV1, no video). | Skips it; says why. |
| `failed` | Preparing went wrong. The server tries again later by itself, less and less often. | Waits. |
| `unavailable` | The drive the file is on is not connected. | Waits. |

- Poll with `If-None-Match: "<revision>"`: `304` and no body while nothing changed. Once a minute while the app is open is enough; also after sending a report, whose answer carries the current revision.
- **Do not call `POST /v1/assets/{id}/playback` for a file that is not `ready`** just because it is wanted. That call means "someone wants to watch this now" and takes the file out of the quiet queue.
- A file the device holds that is no longer in `assets`, and that the person did not download themselves, is removed by the device, but not while it is playing.
- What does not fit on the device is reported (`error: "no_space"`), not half done; the device deletes nothing to make room.

### `POST /v1/me/downloads` — Built.

A device says what it has. The report is the whole truth each time: it replaces the previous one.

```ts
{
  freeBytes?: number | null;   // free space for downloads on the device
  totalBytes?: number | null;
  downloads: {
    assetId: string;
    /** The revision that was, or is being, downloaded. */
    revision: string;
    state: "waiting" | "downloading" | "paused" | "downloaded" | "failed";
    bytesDone: number;
    bytesTotal?: number | null;
    /** Only read when `state` is "failed". */
    error?: "no_space" | "network" | "not_found" | "unsupported" | "verification_failed" | "cancelled" | "other" | null;
    /** true: the person on the device downloaded this themselves. */
    own?: boolean;
  }[];
}
```

→ `200 { "accepted": <count>, "wantedRevision": "<revision of GET /v1/me/wanted>" }`.

Limits: 1 MB body, 5,000 files, ids of at most 64 letters, digits, `-` and `_`, byte counts as whole numbers from 0 to 2^50, `bytesDone` not above `bytesTotal`, `freeBytes` not above `totalBytes`, no file named twice. Anything else is `400 invalid_request` and nothing is stored. Send a report when a download starts, finishes or fails, about every 30 s while one runs, and when the app comes to the front.

### Preparing ahead

Files on a wanted list that need a copy (MKV, old AVI) and are not on the device yet are prepared before the device asks, so `downloadUrl` is there when the device looks. It is the quietest work the server does: one file at a time, at the lowest priority, standing still while anyone plays, downloads or asks for playback (and for 90 s after), and while any other file is being prepared. A copy made this way never pushes out a copy that is in use, that another download still waits for, or that anyone used in the last day; when there is no room without doing that, the file is `does_not_fit` until there is. If someone asks to watch a file that is being prepared ahead, it becomes an ordinary preparation at once.

## Playing on another device

Built on the server. A device with Lobby open can see what another one plays, start a title there, control it, and move what plays from one to the other. Everything goes through the server, so it also works when the two are on different networks. Examples of every message, which the server's tests check against the server and the apps can use in theirs: [`fixtures/remote`](fixtures/remote).

Nothing of it is stored but the three settings: what plays is in memory, and gone when the server stops. The device that plays writes the progress itself, as always.

### Settings

`Device` carries them. A manager changes them with `PATCH /v1/devices/{id}`.

| Field | Default | Meaning |
| --- | --- | --- |
| `isTarget` | true for `tvos` and `macos` | Others see it and can play on it. The device itself sets it with `PATCH /v1/me`. `null` goes back to the default. |
| `allowRemote` | true | A manager's switch. Off: the device neither sees nor controls others, and they do not see it. |
| `remoteOutside` | false | Also while the device is outside (see [Outside](#outside)). Off: from outside it sees only itself, and while it is outside others do not see it. |

### `PATCH /v1/me` — Built.

`{ "isTarget": boolean | null }` → `200` `Device`. `404` for a kids device: there a manager decides.

### `GET /v1/live?session=<id>&last=<event id>` — Built.

The channel: a `200` `text/event-stream` that does not end. `session` is an id (letters, digits, `-`, `_`) the app makes when it starts and keeps until it quits. `last` (or `Last-Event-ID`) is the id of the last event it got; leave it out the first time. The session belongs to the device and to the entrance it came in by.

An event is the lines `id:` (not always), `event:` and one line `data:` with JSON, and then an empty line. Every `data` has `serverTime`. Ignore an event that is not known.

| `event` | `data` | |
| --- | --- | --- |
| `hello` | `session`, `deviceId`, `resumed`, `heartbeatMs`, `silentMs`, `pendingPlay` | Always first. No id. `pendingPlay`: a play waits for this device, which was woken for it ([Waking an Apple TV](#waking-an-apple-tv)): go to it, not to who is watching. |
| `snapshot` | `devices: ShownDevice[]` | Replaces everything known. After `hello`, unless `resumed`. |
| `device` | `device: ShownDevice` | Replaces what is known of that device. |
| `gone` | `deviceId` | Not shown any more: removed, or no longer for this device. |
| `command` | see [Being controlled](#being-controlled) | Do this. |
| `result` | `commandId`, `deviceId`, `status`, `code` | How a command this device sent went. `commandId` is the id it was sent with. Also for a play kept for a woken TV. |
| `wake` | `deviceId`, `commandId`, `step`, `reason` | How waking a TV for this device goes after `202`: `profile` (Lobby did not come up, select was pressed on the TV), `not_open` (it did not come up after that either, `reason: "timeout"`; a kept play still waits). `commandId` is the kept play's, or null. |
| `upload` | `upload: Upload` | To managers' channels at home: an upload changed, or more of it arrived (at most once a second). See [Uploads](#uploads--manager-built). |
| `import` | `item: ImportItem` | To managers' channels at home: a file of an import folder or an upload changed state. |
| `speakers` | `speakers: ShownSpeaker[]` | The HomePods and speakers this session may play on, and what plays there ([Playing on a speaker](#playing-on-a-speaker)). Replaces what is known. After the snapshot, and when it changes. Not sent by a server without `remote.wake`. |
| `heartbeat` | | Every `heartbeatMs` (5 s). No id. |

```ts
interface ShownDevice {
  id: string;
  name: string;
  platform: "ios" | "ipados" | "macos" | "tvos" | "cli";
  isSelf: boolean;
  /** It belongs to a kids viewer, so only that viewer and that viewer's titles can be played there. */
  isKids: boolean;
  /** Lobby is open on it. A target that is off is listed too, with false. */
  online: boolean;
  foreground: boolean;
  /** A title can be started on it now. */
  canPlay: boolean;
  /** What plays on it can be paused, moved and so on now. */
  controllable: boolean;
  /** The commands it can do; offer no others. */
  capabilities: string[];
  player: ShownPlayer | null;
  /**
   * Lobby Server can turn it on and open Lobby on it (`POST /v1/remote/wake`): an Apple TV a
   * manager connected and linked, with waking on. False for this device, from outside, for
   * a device that may not control others, and for a child unless `remote.wake.kids` is on.
   */
  wakeable: boolean;
}

type ShownPlayer =
  /**
   * A title this device may not see, or no film of the library (music). Say "Playing". For a
   * child also whatever does not play as that child, a title it may see included.
   */
  | { redacted: true; status: Status }
  | {
      redacted: false;
      itemId: string;
      assetId: string | null;
      /** The viewer. */
      profileId: string | null;
      status: Status;
      /** Where it was at `at`, by the server's clock. */
      positionMs: number;
      at: number;
      durationMs: number | null;
      rate: number;
      audioTracks: Track[];
      audioTrackId: string | null;
      subtitleTracks: Track[];
      subtitleTrackId: string | null;
      /** 0 to 1; null when it cannot tell. */
      volume: number | null;
      nextItemId: string | null;
      queue: string[];
      /** What it shows at the end; null: nothing (also from a device from before). */
      upNext: UpNext | null;
    };
type Status = "loading" | "playing" | "paused" | "buffering" | "ended" | "error";
interface UpNext {
  /** Up Next with Play Now and Cancel; the suggestions after a film; "Still watching?". */
  kind: "episode" | "suggestions" | "stillWatching";
  /** What starts by itself after the countdown, or with Play Now. Null: nothing. */
  itemId: string | null;
  /** How long until it starts, at `at`. Null: it waits. */
  countdownMs: number | null;
  /** What may be picked, the first first; at most 20. Empty but for suggestions. */
  suggestions: string[];
}
interface Track { id: string; label: string; language: string | null }
```

`upNext.itemId` and `suggestions` hold only what the device that looks may see, like `nextItemId`. The countdown runs on by itself: at `serverNow` it has `countdownMs - (serverNow - at)` left, and a device sends `upNext` again only when it changes otherwise (begins, stops, another kind).

Track ids must mean the same on every device. Sound: `AudioTrack.index` as a string. Subtitles: the `id` of the subtitle track.

**Where it is now.** Only while `status` is `playing`: `positionMs + (serverNow - at) * rate`, at most `durationMs`; otherwise `positionMs`. `serverNow` is the device's own steady clock plus the difference to `serverTime`, taken from the answers to its own posts (with half the round trip). The place is sent only when it is more than a second from that, so it is not sent while a film just goes on.

**The connection.** Use a `URLSession` of its own: the channel takes one connection as long as it is open. Nothing for `silentMs` (12 s) means it is dead. Open it again with the same `session` and `last`, at once and then with growing waits up to 15 s, and then announce at once. Ids are `<epoch>.<number>` and only go up; numbers may be skipped, because of one device only the newest state is kept. The server keeps 60 s and 128 events of a session; otherwise, and after it started again, `resumed` is false and a `snapshot` follows. Opening a session again ends its previous connection. Four sessions per device, 64 in all; more is `429`. A device has one player: of its sessions, the one that plays is shown and controlled, or else the one in front. A removed device, or one whose kids viewer changes, has its channel ended within a second or so: the next open says why. An app connected to several servers has a channel and a session for each.

### `POST /v1/live/{session}` — Built.

What this device does. On opening, on every change, and at least every 5 s.

```json
{
  "order": 7, "foreground": true, "canPlay": true, "profileId": "…",
  "capabilities": ["play", "pause", "resume", "seek", "skip", "next", "stop", "setAudio", "setSubtitle", "upNext"],
  "player": {
    "itemId": "…", "assetId": "…", "profileId": "…", "status": "playing",
    "positionMs": 600000, "ageMs": 40, "durationMs": 5400000, "rate": 1,
    "audioTracks": [{ "id": "0", "label": "English 5.1", "language": "eng" }], "audioTrackId": "0",
    "subtitleTracks": [], "subtitleTrackId": null,
    "volume": null, "nextItemId": null, "queue": [],
    "upNext": { "kind": "episode", "itemId": "…", "countdownMs": 8000, "suggestions": [] }
  }
}
```

→ `200` `{ "serverTime", "epoch", "seq" }`. `order` goes up with every post of a session: an older one that comes in later counts as a sign of life only. `profileId` is the viewer chosen in the app, or null. `player`: left out is unchanged, `null` is nothing. `ageMs` is how long ago `positionMs` was measured, by the device's own steady clock (at most 10 s counts); times of a device are not sent, because its clock may be wrong. 32 tracks of a kind, 50 ids in `queue`, 32 KB in all.

Until its first announcement a device sees only itself. Before the app goes to the background without playing, announce `foreground: false`. A device that says nothing for 12 s, or stays away for 5 s after its connection broke, is offline (others know within 14 s) and has to announce everything again.

`410 gone`, `reason: "session"`: there is no such channel. Open it, then announce. `429` after 60 at once and 4 a second: while a slider is dragged, send four a second.

### `POST /v1/remote/commands` — Built.

```json
{ "id": "…", "session": "…", "deviceId": "…", "command": { "type": "seek", "positionMs": 600000 } }
```

`id` is made by the sender, new for each command and the same when it is sent again: it is then done once. `session` is the sender's own channel.

| `type` | With | |
| --- | --- | --- |
| `play` | `itemId`, `profileId`, `assetId` (null: its choice), `startMs` (null: where this viewer was; 0: from the start), `paused`, `rate`, `audioTrackId` (null: its choice), `subtitleTrackId` (null: its choice, `"off"`: none), `queue` | A film, episode, extra or home video, as this viewer. |
| `pause`, `resume`, `next`, `stop` | | |
| `seek` | `positionMs` | |
| `skip` | `deltaMs`, also negative | |
| `setAudio` | `trackId` | |
| `setSubtitle` | `trackId`, null: none | |
| `setVolume` | `volume`, 0 to 1 | |
| `upNext` | `action`: `playNow`, `cancel` or `continue` | The answer to what it shows at the end: Play Now, Cancel (the countdown stops), Continue Watching. Stop is `stop`; a suggestion is a `play` of it as the same viewer. `playNow` is `403 title_not_allowed` when `upNext.itemId` is not for the viewer, as `next`. |
| `handover` | `toDeviceId` | What plays on `deviceId` goes on there. Either may be this device itself. |

→ `202` `{ "id", "expiresAt", "serverTime" }`: it was sent to the device. How it went comes as `result`:

| `status` | `code` | |
| --- | --- | --- |
| `done` | null | |
| `failed` | `not_allowed`, `not_found`, `cannot_play`, `nothing_playing`, `unsupported`, `expired`, `busy`, `declined`, `error`: said by the device. `device_offline`, `title_not_allowed`: by the server. | |
| `expired` | `expired` | No answer within 10 s. It will not be done later either. |
| `superseded` | null | A newer one of the same kind came: the last one counts. `play` and `stop` replace everything; `pause` and `resume` each other; `seek`, `setAudio`, `setSubtitle`, `setVolume` their own kind. |

Commands for a device arrive in the order the server took them. A refusal has a `reason` beside `error`:

| Status | `reason` | |
| --- | --- | --- |
| 503 | `device_offline` | Lobby is not open there. **Nothing is kept for later.** Offer AirPlay, or ask to open Lobby on it. |
| 503 | `cannot_play` | It is there, and cannot play now (in the background, no viewer, busy). |
| 409 | `nothing_playing`, `unsupported` | |
| 409 | `busy` | Something is being handed over from or to it. |
| 409 | `used_id` | The id was used for another command. |
| 403 | `title_not_allowed` | Not for the viewer it would play for, or not for who asks. |
| 403 | `control_off` | A manager turned it off for this device, or it is outside. |
| 404 | | No such device (or none that this one sees), viewer, title or file. |
| 410 | `session` | Open the channel and announce. |
| 429 | | 30 at once and 4 a second per sender; 60 and 8 a second per target; 32 unanswered. |

### Being controlled

```json
{ "commandId": "…", "requestId": "…", "handoverId": null, "from": { "deviceId": "…", "name": "Phone" },
  "command": { "type": "pause" }, "expiresAt": 1795640010000, "expiresInMs": 9990, "serverTime": 1795640000010 }
```

Do them one after another. Do not do one whose `commandId` was done already (answer again), or whose `expiresInMs` is over by the device's own steady clock (answer `expired`). Then:

`POST /v1/live/{session}/results` `{ "commandId", "status": "done" | "failed", "code"?, "player"? }` → `204`, also for one that was settled before. `code` is needed with `failed`. `done` means that it was taken on: for `play`, that the first picture is there or the film is certain to start. With `player` as in an announcement the new state goes along.

For `play` the device asks the server for the file and its progress as for any film, and writes the progress itself. A device with more than one viewer plays as `profileId`.

`yield` comes from the server only, first in a handover: pause, write the progress, and answer with `player`. Keep the player for 25 s: `stop` with the same `handoverId` ends it, `resume` takes it up again. Without either, stay paused.

### Who may

| | |
| --- | --- |
| A child: a kids device, or a kids viewer on a shared device | With `allowRemote`, sees only targets where it can play: Lobby is open there (or the TV is `wakeable` for it), and it does not belong to another kids viewer. Without, itself only. It starts only titles its viewer may see, as that viewer, also on a grown-up's TV: the TV plays as the child and the child's limits are checked for it. It controls only what plays as its viewer (pause, seek, stop and so on, `next` to an allowed title, a handover of that); anything else, a title it may see included, is `redacted` to it and `403 title_not_allowed`. A grown-up's film is not replaced by its `play` either. It cannot change the TV's settings (`PATCH /v1/me` is `404` for a kids device). For a kids viewer on a shared device this follows what the app says in `profileId`; a bound kids device is the same, and a real limit. |
| Starting a title on a kids device | Only as its own viewer, and only what that viewer may see. The rest of `queue` is left out. `next` is refused when the next title is not allowed; everything the device then asks for is checked as always. |
| Starting a title for a kids viewer elsewhere | Only what that viewer may see. |
| A title that is not in the library, music | `redacted` for everybody; it can be paused and stopped. |
| Outside | `allowOutside` to come in at all; sees and controls others only with `remoteOutside`. |
| Another household | Not there: a device sees, controls and is controlled by the devices of its own household only. Of what plays, a guest household with a part of the library sees only that part. |
| Waking an Apple TV | At home only, by a device with `allowRemote`; by a child only when the household lets kids turn on the TV (`remote.wake.kids`, off by default). See [Waking an Apple TV](#waking-an-apple-tv). |
| A speaker | The owner's household, with `allowRemote`; started at home only. A child only as itself and while it may listen. See [Playing on a speaker](#playing-on-a-speaker). |

### How it goes

```
Phone                    server                     TV
  |-- GET live ----------->|<----------- GET live ----|
  |<- hello, snapshot -----|------ hello, snapshot -->|
  |-- POST live/{s} ------>|<------ POST live/{s} ----|   every 5 s and on every change
  |<- device (TV) ---------|                          |
  |-- POST commands play ->|                          |
  |<- 202 -----------------|------ command play ----->|
  |<- device (loading) ----|<------ POST live/{s} ----|
  |<- result done ---------|<------ POST results -----|
  |<- device (jumped) -----|<------ POST live/{s} ----|   its own remote was used
```

```
Handover TV to phone, asked by the phone
  |-- POST handover ------>|------ command yield ---->|   pauses, writes progress
  |                        |<- results done, player --|
  |<- command play --------|                          |   from exactly there
  |-- results done ------->|------ command stop ----->|
  |<- result done ---------|                          |

  The phone cannot: failed ->|---- command resume --->|
  |<- result failed -------|                          |
```

```
Server starts again: connections break -> open with `last` -> hello resumed:false, snapshot
(itself only) -> announce everything -> device events as the others come back.
```

## Waking an Apple TV

Built (D-046). Lobby Server turns an Apple TV on and opens Lobby on it, so Play On can play on a TV that is asleep. It speaks Apple's Companion protocol through [pyatv](https://pyatv.dev), which is not an interface Apple offers: a tvOS update can break it. Then waking fails with a reason, and AirPlay is there as before.

It exists only when `remote.wake` is in `lobby.config.json` ([operations](operations.md#waking-the-apple-tv)). A manager connects each TV once, with the code the TV shows, and says which Lobby device it is. The credentials stay in pyatv's file on the server; no answer carries them, and the code is not kept.

Every route here is on the home entrance only: the outside entrance does not have them. They are **Owner** routes, `POST /v1/remote/wake` too: the Apple TVs that can be woken are on the owner's network, and a TV is linked only to a device of the owner's household. Another household's Apple TVs cannot be woken from here (D-052). The manager's routes also refuse a request from an address that is neither at home nor in the tailnet.

```ts
interface WakeStatus {
  /** `remote.wake` is in lobby.config.json. */
  configured: boolean;
  /** The setting `remote.wake.enabled`. */
  enabled: boolean;
  /** The setting `remote.wake.kids`, "Kids can turn on the TV": off by default. */
  kids: boolean;
  /** The helper runs. */
  running: boolean;
  /** Why it does not run, in words. */
  problem: string | null;
  pyatv: string | null;
  scannedAt: number | null;
  televisions: Television[];
  /** A pairing that waits for the code. */
  pairing: { id: string; televisionId: string; expiresAt: number } | null;
}

interface Television {
  /** pyatv's identifier for the TV. */
  id: string;
  name: string;
  model: string;
  /** Lobby Server holds credentials for it. */
  paired: boolean;
  /** It answered the last look on the network. */
  found: boolean;
  /** The Lobby device it is, as a manager confirmed. One device is at most one TV. */
  deviceId: string | null;
  /** The Apple TV device of the same name, until a manager confirms one. tvOS gives an app no
   * identifier the Companion protocol knows, so the name is all there is to go on. */
  suggestedDeviceId: string | null;
}
```

### `GET /v1/wake` — Manager. Built.

`200` `WakeStatus`. Without `remote.wake`: `configured: false` and no TVs.

### `PATCH /v1/wake` — Manager. Built.

`{ "enabled"?: boolean, "kids"?: boolean }`, at least one → `200` `WakeStatus`. Changes the settings `remote.wake.enabled` and `remote.wake.kids`, as `PATCH /v1/settings` would, with the same history and audit. `404` `wake_not_configured` without `remote.wake`.

### `POST /v1/wake/scan` — Manager. Built.

Looks on the network for five seconds (or asks only `remote.wake.hosts`) → `200` `WakeStatus`. TVs Lobby Server has credentials for are remembered, also ones paired by hand with `atvremote`.

### `POST /v1/wake/pairings` — Manager. Built.

`{ "televisionId" }` → `201` `{ id, televisionId, expiresAt }`. The TV shows a four-digit code now. One pairing at a time: a new one ends the one before. The connection to the TV stays open for 60 s.

### `POST /v1/wake/pairings/{id}` — Manager. Built.

`{ "pin": "1234" }` → `200` `Television`. `410` `pairing_expired` after 60 s or after a wrong code: start again. `403` `wake_pairing_failed` when the TV did not take the code.

### `DELETE /v1/wake/pairings/{id}` — Manager. Built.

`204`. The TV takes the code away.

### `PUT /v1/wake/televisions/{id}` — Manager. Built.

`{ "deviceId": string | null }` → `200` `Television`. The manager's confirmation of which Lobby device the TV is; `null` unlinks. Only a `tvos` device. Linking a device unlinks it from another TV. `404` `not_paired` for a TV without credentials.

### `DELETE /v1/wake/televisions/{id}` — Manager. Built.

`204`. Lobby Server forgets the credentials. The TV keeps "Lobby" under Settings → Remotes and Devices until someone removes it there.

### `POST /v1/remote/wake` — Built.

`{ "deviceId", "session"?, "play"?: { "id", "command": PlayCommand } }` → `202` `{ deviceId, wokenAt, lobbyInFront, play }` once the TV is on and was told to open Lobby (about 4 s). For a device that has `allowRemote` and is at home (`403` `home_only`). The TV must be a target with `allowRemote`. `session` is the sender's channel: when its viewer is a kids viewer, or the device is a kids device, it is a child's wake, which needs `remote.wake.kids` on and a TV that does not belong to another kids viewer (else `404 not_wakeable`). A session that is not there is `410` `session`. Leaving it out counts the device only. `lobbyInFront` is whether Lobby is in front on the TV as pyatv tells it, null when it cannot tell (over Companion alone it cannot).

**With `play`** (D-056), the server keeps the play for that TV and sends it, as a `play` command from the sender with the sender's `id`, the moment the TV's Lobby is open on the live channel and can play: for `remote.wake.holdPlaySeconds` (180 by default, in the file), also when the sender is gone by then. `session` is needed with it. `play` in the answer is `{ id, expiresAt }` (server time, ms). The play is checked as one sent at once before the TV is woken (`403 title_not_allowed`, `404`: then nothing is woken), and again when it is sent, with what is true then: the sender still there, not removed, with `allowRemote`; the TV still a target of the same household; the kids limits of the viewer the sender had when it asked, and of the one its session has now; a child's wake still allowed; a grown-up's film on the TV not replaced by a child's. If any of it fails, nothing is sent. Only the latest play per TV counts: an earlier one, of any sender, ends as `superseded`. How it goes comes to the sender's session as for any command: `result` with the play's `id` (`done`, `failed` with the reason above, `expired` when the TV did not open in time, `superseded`), and `wake` events on the way. The app shows "Waking…", "Opening Lobby…", and after about 10 s without the TV "Choose a profile on the TV if it asks".

**Without `play`**, wait for the TV on the live channel: `online` and `canPlay`, then send `play` as always. An app that knows a server without `play` in the answer does this.

**The profile picker.** tvOS can ask "who is watching" when it wakes, and opens no app until someone answers: `launch_app` is taken and nothing happens. So after waking, Lobby Server waits a few seconds (6) for Lobby to announce itself on the live channel; when it does not, and `remote.wake.pickProfile` is on, it presses select once on the TV, which picks **whichever profile is focused there** (normally the last one used), and opens Lobby again. At most one select per wake: a wake asked for while one is under way for the TV joins it. When pyatv can tell which app is in front (not over Companion alone in pyatv 0.18), the helper looks itself and presses select only when Lobby is not in front. Switching "show profiles on wake" off on the TV avoids the picker altogether.

### `DELETE /v1/remote/wake/{deviceId}/plays/{id}` — Built.

`204`: the sender's play that waits for that TV is not sent. `404` when none of the sender's with that id waits any more: sent, replaced or over. Home only, as waking.

| Status | `reason` | |
| --- | --- | --- |
| `403` | `wake_off` | A manager turned waking off. |
| `404` | `not_wakeable` | Also: a child, while kids cannot turn on the TV. |
| `404` | `not_wakeable` | Not a connected and linked Apple TV. |
| `404` | `wake_not_found` | The TV did not answer on the network: unplugged, or on another network. |
| `403` | `wake_not_paired` | The TV no longer accepts Lobby Server: connect it again. |
| `503` | `wake_timeout`, `wake_failed`, `wake_unavailable` | It did not answer in time, something else broke, or the helper does not run. |
| `429` | | 4 at once and 6 a minute per device, 3 at once and 4 a minute per TV. A wake that is under way for the TV is joined, not repeated. |

```
Phone                     server                       Apple TV (asleep)
  |-- POST remote/wake ---->|-- Companion: turn on ------->|
  |                         |-- Companion: launch Lobby -->|
  |<- 202 ------------------|                              |
  |                         |<------------- GET live ------|   Lobby opens
  |<- device (online) ------|<------------- POST live -----|
  |-- POST commands play -->|-------------- command play ->|
```

```
With play: the server keeps it; the phone may be gone meanwhile
Phone                     server                       Apple TV (asleep)
  |-- POST wake + play ---->|-- turn on, launch Lobby ---->|
  |<- 202 play {id} --------|                              |   "who is watching?"
  |                         |   6 s, no Lobby              |
  |<- wake profile ---------|-- select, launch Lobby ----->|   the focused profile
  |                         |<------------- GET live ------|   hello pendingPlay: true
  |                         |<------------- POST live -----|   re-checks who asked
  |                         |-------------- command play ->|
  |<- result done ----------|<------------- POST results --|
```

## Playing on a speaker

Built (D-068). Lobby Server plays music and stories to the HomePods and other AirPlay speakers on its network itself: the app says what, and is then only the remote; it can be closed or leave. The server streams the files of its own library, decoded by ffmpeg, with the helper of the Apple TVs ([pyatv](https://pyatv.dev)'s RAOP). It exists only when `remote.wake` is in `lobby.config.json` ([operations](operations.md#playing-on-speakers)) and the setting `remote.wake.speakers` is on (the default). Speakers are found by themselves, every minute; Apple TVs and Macs are not among them.

Every route here is on the home entrance only, and an **Owner** route: the speakers are on the owner's network (D-052). Starting needs an address at home or in the tailnet (`403 home_only` otherwise). What plays is kept in memory; the place in a story and the listens are written for the viewer it plays for, as an app writes them: `/v1/music/profiles/{id}/progress` every 15 s and at pause, stop and the end, and `/v1/music/profiles/{id}/plays` for every track heard.

```ts
interface ShownSpeaker {
  /** Lobby Server's own id for it. */
  id: string;
  /** As a manager named it, or its own. */
  name: string;
  kind: "homepod" | "speaker";
  /** Something can be started on it now: it is on the network and the helper runs. */
  canPlay: boolean;
  /**
   * "home_only": it lets only people of its Home play (Home app: Allow Speaker & TV Access →
   * Everyone on the Same Network). "password": it wants one, and none is kept. Said before trying.
   */
  access: "open" | "password" | "home_only";
  /** 0 to 1, as the speaker last said; null before it played. */
  volume: number | null;
  /** What plays is this session's to pause, stop and so on. A child's only when it plays as itself. */
  controllable: boolean;
  play: SpeakerPlay | null;
}

type SpeakerPlay =
  /** Something plays that this session may not see: a grown-up's music, to a child. */
  | { redacted: true; status: Status }
  | {
      redacted: false;
      /** The viewer it plays for. */
      profileId: string;
      kind: "story" | "music";
      bookId: string | null;
      albumId: string | null;
      /** The queue, in the order it plays. A story's files. */
      trackIds: string[];
      index: number;
      trackId: string;
      /** "loading", "playing", "paused", "ended" or "error". */
      status: Status;
      /** In the current track, at `at` (server time); moves on while "playing", at most `durationMs`. */
      positionMs: number;
      at: number;
      durationMs: number | null;
      /** Why it stopped by itself: refused, not_found, timeout, unavailable, drive_away, kids_mode, failed. */
      problem: string | null;
      /** The device that started it. */
      startedBy: string;
    };
```

### `POST /v1/speakers/{id}/play` — Built.

`{ "session", "profileId", "trackIds"?, "index"?, "bookId"?, "startMs"?, "albumId"? }` → `200` `ShownSpeaker` once the speaker plays (a second or two). `session` is the sender's channel: who uses it (a child in the kids screens) counts, as for waking. Either `trackIds` (at most 500, played from `index`, `startMs` into that track) or `bookId` (its files in order, from `startMs` on the book's line of time, or where this viewer was when it is left out). What played there before is stopped and its place kept.

A child (a bound kids device, or a session whose viewer is a kids viewer) plays only as itself (`403 title_not_allowed`), only while its plan allows listening (`403 kids_mode`), only from the music libraries it was given and only with music on for it (`404`), and not over what plays as someone else (`409 speaker_busy`). A kids viewer started from a grown-up's device is held to the same.

### `POST /v1/speakers/{id}/control` — Built.

`{ "session", "type": "pause" | "resume" | "stop" | "next" | "previous" | "skip" | "seek" | "volume", "deltaMs"?, "positionMs"?, "volume"? }` → `200` `ShownSpeaker`. `skip` goes across the files of the queue (back 15 s at the start of a story's second file is in the first); `previous` goes to the start of the track after three seconds of it. `volume` is 0 to 1, kept for the next stream while nothing plays. Pause stops the stream and keeps the place; resume streams again from there. `409 nothing_playing`; a child only what plays as itself (`403 title_not_allowed`), and going on only while it may listen (pausing and stopping always). When a child's plan stops allowing listening, what plays as the child stops within seconds (`problem: "kids_mode"`).

| Status | `reason` | |
| --- | --- | --- |
| `403` | `speaker_refused` | The speaker did not let Lobby Server play: its access in the Home app, or a password. The message says what to do. |
| `404` | `speaker_not_found` | It did not answer on the network. |
| `503` | `speaker_timeout`, `speaker_unavailable` | It did not answer in time; the helper does not run. |
| `503` | `drive_away` | The drive of that file is not connected. |
| `409` | `speaker_busy`, `nothing_playing` | |
| `403` | `home_only`, `title_not_allowed`, `kids_mode` | |
| `429` | | 10 at once and 30 plays a minute, 30 and 240 controls a minute, per device. |

### For managers — Built.

At home or in the tailnet only, as the Apple TVs.

- `GET /v1/speakers` → `{ configured, enabled, running, problem, scannedAt, speakers: ManagedSpeaker[] }`; `ManagedSpeaker` is `{ id, name, foundName, customName, model, kind, hidden, found, access, hasPassword, playing }`. A speaker that missed two looks in a row is `found: false` and not in Play On.
- `PATCH /v1/speakers` `{ "enabled": boolean }` → the same: the setting `remote.wake.speakers`, as `PATCH /v1/settings` would change it. Off stops what plays. `404 speakers_not_configured` without `remote.wake`.
- `POST /v1/speakers/scan` → the same, after a look of five seconds.
- `PATCH /v1/speakers/{id}` `{ "name"?: string | null, "hidden"?: boolean }` → `ManagedSpeaker`. `null` gives it its own name again. A hidden speaker is not in Play On, and what played there stops.
- `PUT /v1/speakers/{id}/password` `{ "password": string | null }` → `ManagedSpeaker`. Kept in pyatv's credentials file on the server, never in an answer or a log; `null` removes it.

```
Phone                      server                          HomePod
  |-- POST speakers/k/play -->|-- ffmpeg file → FLAC --------->|   RAOP, from the server
  |<- 200 playing ------------|                                |
  |      (the phone may go)   |-- next track, by itself ------>|
  |                           |   the story's place, every 15 s, for the viewer
  |-- POST control pause ---->|-- stop the stream ------------>|   the place is kept
  |-- POST control resume --->|-- stream again from there ---->|
```

## Music and audiobooks

The household's own audio, from library folders with the hint `music` or `audiobooks`. Built on the server and in the apps (the apps' part is D-044). It stands beside the films: nothing here appears in `/v1/library`, `/v1/categories` or `/v1/status`, so an app that does not know it is unaffected. Everything comes from the files; nothing is looked up at other services, and the files are never written. Every route needs a paired device; the ones marked **Manager** need a manager.

### `GET /v1/music/library?cursor=<cursor>&limit=<1…1000>` — Built.

Works like `GET /v1/library`: everything at first, then what changed. `limit` counts all kinds together and defaults to 500.

```ts
{
  artists: Artist[]; albums: Album[]; tracks: Track[]; books: Book[];
  /** Ids of any kind that are gone. */
  removed: string[];
  cursor: string; more: boolean; reset: boolean;
}

interface Artist { id: string; name: string; sortName: string; mbid: string | null; addedAt: number; }

interface Album {
  id: string;
  title: string;
  sortTitle: string;
  /** As the sleeve says it; "Various Artists" for a compilation without album artists. */
  artistCredit: string;
  artistIds: string[];
  compilation: boolean;
  year: number | null;
  genres: string[];
  trackCount: number;
  discCount: number;
  durationMs: number;
  coverId: string | null;
  mbid: string | null;
  addedAt: number;
}

interface Track {
  id: string;
  title: string;
  sortTitle: string;
  artistCredit: string;
  /** Empty for a track of a book. */
  artistIds: string[];
  /** Both null for a loose track. */
  albumId: string | null;
  bookId: string | null;
  disc: number | null;
  track: number | null;
  year: number | null;
  genres: string[];
  composers: string[];
  durationMs: number | null;
  chapters: { title: string | null; startMs: number; endMs: number }[];
  /** Opus gains are converted to ReplayGain's reference of -18 LUFS. */
  replayGain: { trackGainDb: number | null; trackPeak: number | null;
                albumGainDb: number | null; albumPeak: number | null } | null;
  /** Only a loose track has its own; others show their album's or book's. */
  coverId: string | null;
  mbid: string | null;
  addedAt: number;
  available: boolean;
  file: {
    /** Changes when the file's bytes change. A download made from another revision is stale. */
    revision: string;
    sizeBytes: number;
    container: string;
    codec: string;
    lossless: boolean;
    bitRate: number | null;
    sampleRate: number | null;
    bitDepth: number | null;
    channels: number | null;
    /** "convert": AVPlayer does not play it (Ogg, Opus, WMA, APE, WavPack…); a 256 kbit/s copy is played. */
    playability: "direct" | "convert";
    /** The compact qualities that are smaller than the file itself. */
    compact: (256 | 128)[];
  };
}

interface Book {
  id: string;
  title: string;
  sortTitle: string;
  authors: string[];
  narrators: string[];
  series: string | null;
  seriesPosition: number | null;
  year: number | null;
  genres: string[];
  description: string | null;
  language: string | null;
  durationMs: number;
  coverId: string | null;
  addedAt: number;
  /** The files in order; `startMs` is on the book's own line of time. */
  parts: { trackId: string; startMs: number; durationMs: number | null }[];
  /** On the same line of time. Without chapters in the files, one per file; empty for a single file without any. */
  chapters: { title: string | null; startMs: number; endMs: number; trackId: string; trackStartMs: number }[];
}
```

Order tracks of an album by `disc` (null is 1), then `track` (null last). An album of one track, or an artist with one, is ordinary.

- `GET /v1/music/artists/{id}` — `{ artist, albums }`: albums under the artist's name or with them on a track.
- `GET /v1/music/albums/{id}` — `{ album, tracks }`, in order.
- `GET /v1/music/books/{id}` — `{ book, tracks }`, in order.
- `GET /v1/music/tracks/{id}` — `{ track }`.
- `GET /v1/music/covers/{coverId}?w=<width>` — a JPEG at most `w` wide (200, 400, 800, 1600; others round up). Cache it forever. `404` for a picture that cannot be read, `503` when the drive is away and this size was not made before.
- `GET /v1/music/status` — Manager. `{ scanning, sources, files: { total, waiting, failed, missing }, items: { artists, albums, tracks, books }, copies: { bytes } }`.

### Playing and downloading — Built.

`GET` or `HEAD /v1/music/tracks/{id}/content` is the file exactly as on the drive, with `Range`, `If-Range`, `ETag` and `416` like `/v1/assets/{id}/content`. Lossless files that AVPlayer plays (FLAC, ALAC, WAV, AIFF) are played from here.

`POST /v1/music/tracks/{id}/playback` says what to fetch, for playing and for downloading.

Request `{ "quality": "original" | 256 | 128, "purpose": "play" | "download" }`; both optional, `original` and `play` by default. A copy for `play` is made before those for `download`.

```ts
{
  state: "ready" | "preparing" | "queued" | "failed" | "does_not_fit";
  /** "direct": the file itself. "copy": AAC in an M4A. */
  mode: "direct" | "copy";
  revision: string;
  kbps: 256 | 128 | null;
  /** null until ready. */
  url: string | null;
  bytes: number | null;
  progress: number;
  message: string | null;
}
```

`202` while `queued` or `preparing`: ask again (about once a second; a song takes seconds, a long book minutes). Ask for the next tracks of the queue ahead of time. A file that is already as small as the quality asked for is sent as it is (`mode: "direct"`), so `file.compact` tells where a compact download saves anything. Surround becomes stereo in a copy. `failed` and `does_not_fit` are tried again when asked half a minute later. `429` with `Retry-After` when 500 copies are waiting. `503` when the drive is away and there is no copy yet.

`url` takes `Range` and `If-Range`; its ETag belongs to these exact bytes. A copy can be evicted at any time: `404`, ask again.

### What viewers keep — Built.

Under `/v1/music/profiles/{profileId}`; `404` for an unknown viewer. Removing a viewer removes all of it.

| Request | Body → answer |
| --- | --- |
| `GET /favourites?since=<revision>` | `{ favourites: { itemId, kind: "artist" \| "album" \| "track" \| "book", favourite, updatedAt }[], revision }`. `favourite: false` is one that was taken back. |
| `PUT /favourites/{itemId}` | `{ favourite, updatedAt }` → `{ favourite }`. The later `updatedAt` wins (clamped to the server's clock); an older one gets `409 conflict` with the current `favourite`. Safe to retry. |
| `GET /playlists?since=<revision>` | `{ playlists: Playlist[], removed: string[], revision }` |
| `POST /playlists` | `{ id, name, trackIds? }` → `201 { playlist }`. The device makes the id (a UUID), so a retry is the same playlist. |
| `GET /playlists/{id}` | `{ playlist }` |
| `PATCH /playlists/{id}` | `{ revision, name?, trackIds? }` → `{ playlist }`. The whole new order. `409` with the current `playlist` when someone was first; a retry of a change that arrived is `200`. |
| `POST /playlists/{id}/tracks` | `{ opId, trackIds }` → `{ playlist }`. Adds to the end, never a conflict; the same `opId` adds once. |
| `DELETE /playlists/{id}?revision=` | `204`; `409` with the current `playlist`. |
| `GET /playlists/{id}/export.m3u8` | An M3U in UTF-8 with each file's path inside its library folder. |
| `POST /plays` | `{ plays: { opId, trackId, playedAt, playedMs, completed }[] }`, at most 500 → `{ accepted, unknown }`. The same `opId` counts once. |
| `GET /plays?limit=&before=` | `{ plays, next }`, newest first; pass `next` as `before`. |
| `GET /play-counts` | `{ counts: { trackId, plays, lastPlayedAt }[] }`; `plays` counts completed ones. |
| `DELETE /plays` | `204`. Clears the history. |
| `GET /progress?since=`, `PUT /progress/{itemId}` | Exactly the rules of [Progress](#progress), for a book (`positionMs` on the book's line of time) or a track (a mix, a live set). Its revisions are its own. |

`Playlist` is `{ id, name, trackIds, revision, createdAt, updatedAt }`. A track may be in it more than once. `400` for a track the library does not have; 10,000 tracks and 500 playlists at most (`409`). A track whose file has been gone for thirty days leaves the playlists.

### Editing — Manager. Built.

`GET /v1/music/{artists|albums|tracks|books}/{id}/edit` → `{ kind, item, revision, fields: { [field]: { automatic, overridden, override, effective } } }`.

`PATCH /v1/music/{artists|albums|tracks|books}/{id}` with `{ revision, set?, reset? }` answers the same view; `409` with the current view beside `error`; `400` for anything malformed. Kept apart from the files, which are never changed; `reset` goes back to what the file says.

| Kind | Fields |
| --- | --- |
| artist | `name`, `sortName` |
| album | `title`, `sortTitle`, `artists`, `year`, `genres`, `compilation` |
| track | `title`, `sortTitle`, `artists`, `album`, `albumArtists`, `compilation`, `disc`, `track`, `year`, `genres`, `composers` |
| book | `title`, `sortTitle`, `authors`, `narrators`, `series`, `seriesPosition`, `year`, `genres`, `description` |

A track's `album`, `albumArtists`, `compilation` or `artists` can move it to another album or artist; ids of the track itself never change.

### Not there yet

Wanted downloads (`/v1/devices/{id}/wanted`) know films and series only. Covers cannot be edited, and a single file with a cue sheet is one track.

## Imports and uploads

Built. How files are judged, named and moved: [imports.md](imports.md). Every route here is for **managers only**, at home or over Tailscale (`403 forbidden` for a viewer, from another address, and for a kids device; the outside entrance has none of them, D-050). Without Lobby's folder (`conversion.dir`), or while its drive is not connected, uploads answer `503 unavailable` and files wait in the Inbox instead of being moved.

```ts
interface ImportItem {
  id: string;
  origin: "folder" | "upload";
  /** The import folder; null for an upload. */
  folder: string | null;
  name: string;
  /** Below the import folder, or the name the upload was sent with. */
  relPath: string;
  sizeBytes: number;
  state: "waiting" | "inbox" | "moving" | "imported" | "listed" | "ignored" | "failed" | "dismissed";
  /** Why it waits, why it is in the Inbox, why it was left out. A sentence to show. */
  reason: string | null;
  kind: "movie" | "episode" | null;
  title: string | null;
  year: number | null;
  season: number | null;
  episode: number | null;
  episodeTitle: string | null;
  tmdbId: number | null;
  /** TMDB's titles that fit, when there was not one clear match. */
  candidates: { title: string; year: number | null; tmdbId: number }[];
  /** The library folder chosen for it; null: the films' or series' folder. */
  destination: string | null;
  /** Where it went in the library. */
  targetPath: string | null;
  subtitles: string[];
  /** What is left of its folder and may be removed (`clean-up`). */
  leftovers: { dir: string; files: string[] } | null;
  uploadId: string | null;
  /** An old format; once imported it can be put in the conversion queue. */
  convertible: boolean;
  /** What can be done with it now; offer nothing else. */
  actions: ("move" | "list" | "dismiss" | "cleanUp" | "convert")[];
  firstSeenAt: number;
  updatedAt: number;
  doneAt: number | null;
}
```

| State | |
| --- | --- |
| `waiting` | Not finished, not quiet long enough, open in another program, or TMDB could not be reached. |
| `inbox` | Needs a manager: what it is is not clear, the name is taken, it is on another drive. |
| `moving` | Being moved now. |
| `imported` | In the library at `targetPath`. |
| `listed` | In an indexed folder, listed in the library where it is. |
| `ignored` | Left out by the rules (a sample, too small, not a video). Never moved or listed unless a manager chooses `move`. |
| `failed` | Moving failed; nothing was replaced. |
| `dismissed` | A manager said to leave it alone. It is looked at again only when it changes. |

### `GET /v1/imports` — Manager. Built.

`{ folders: FolderStatus[], counts: Record<state, number>, moving: boolean, driveConnected: boolean, destinations: { path, name, hint }[], settings: { waitMinutes, copyAcrossDrives, maxFileGb, quotaGb } }`. `FolderStatus` is `{ path, name, mode: "move" | "index", looksLikeDownloads, connected, counts, lastLookAt, problem }`. `moving` is false without Lobby's folder. `destinations` are the library's video folders a file can be sent to (not personal ones). The folders themselves are the setting `import.folders` (`PATCH /v1/settings`, section `imports`, type `importFolders`: a list of `{ path, mode?, name? }`; a `mode` left out is `index` for a folder that looks like a download program's and `move` otherwise).

### `GET /v1/imports/items?view=<inbox|waiting|ignored|done|all>&limit=<1…1000>` — Manager. Built.

`{ items: ImportItem[] }`, newest change first. `inbox`: `inbox` and `failed`. `waiting`: `waiting` and `moving`. `ignored`: `ignored` and `dismissed`. `done`: `imported` and `listed`. `GET /v1/imports/items/{id}` → `{ item }`.

### `POST /v1/imports/items/{id}/confirm` — Manager. Built.

`{ action: "move", kind: "movie" | "episode", title, year?, season?, episode?, episodeTitle?, destination? }` moves it into the library under that title (`destination` a path from `destinations`, or null). `{ action: "list" }` lists a file of an indexed folder where it is. → `{ item }`. `409 conflict` when it changed since it was looked at, is not finished, another program has it open, or is already in the library.

### `POST /v1/imports/items/{id}/dismiss` — Manager. Built.

Leaves it alone. For an upload, Lobby's copy is removed. → `{ item }`.

### `POST /v1/imports/items/{id}/clean-up` — Manager. Built.

Body `{ "confirm": "delete leftovers" }`. Removes `leftovers.files` and the empty folders, after judging each again; `409` when anything else is in that folder now. → `{ item }`.

### `POST /v1/imports/items/{id}/convert` — Manager. Built.

Puts an imported file of an old format in the conversion queue: the answer of `POST /v1/conversion/jobs`. `409` until the library has read it, `503` without converting.

### `GET /v1/imports/activity?limit=<1…500>` — Manager. Built.

`{ entries: [{ id, at, itemId, deviceId, action, message }] }`, newest first. `action` is one of `uploaded`, `listed`, `inbox`, `ignored`, `confirmed`, `imported`, `dismissed`, `cleaned`, `failed`, `gone`; `message` is a sentence to show.

### `POST /v1/imports/scan` — Manager. Built.

Looks through the import folders now; answers like `GET /v1/imports` without `destinations` and `settings`.

### Uploads — Manager. Built.

1. `POST /v1/uploads`, body `{ relPath, sizeBytes, destination, sha256?, batch? }` → `201 { upload, url }` with `Upload-Offset` and `Upload-Length`. `relPath` is the file's name, or its path in a folder that was dropped (`Show/Season 1/Show S01E01.mkv`, at most 8 parts, none starting with a dot); only videos and subtitles. `destination` is `{ "kind": "movies" }`, `{ "kind": "series" }` or `{ "kind": "folder", "path": <a destination> }`. `batch` (an id the app makes) groups the files of one drop: their folders are kept, and a subtitle lands beside its video. The same request again for an unfinished upload answers `200` with that upload. Refused: larger than `uploads.maxFileGb` (`400`), eight unfinished on this device, beyond `uploads.quotaGb` together, or not enough free space on the drive (`409`).
2. `PATCH {url}` with the bytes, `Content-Length` (at most 256 MB a piece), `Upload-Offset: <where this piece starts>` and, recommended, `Upload-Checksum: sha256 <base64 of the piece's SHA-256>` → `204` with the new `Upload-Offset`. `409 conflict` with `{ "offset": <where to go on> }` beside `error` when the piece does not start there, is shorter than it said, or does not match its checksum: nothing of that piece is kept. One piece at a time per upload.
3. `HEAD` or `GET {url}` → `Upload-Offset`, `Upload-Length`, and `{ upload, offset }`.
4. `POST {url}/complete`, body `{ "sha256": "<hex>" }` (or nothing, when it was given at the start) → `200 { upload }` in state `done`, with `itemId`; or `202` in state `verifying` when the server started again during the upload and reads the file once more. When the whole file does not match, the upload goes back to `receiving` at offset 0.
5. `DELETE {url}` cancels and removes what arrived. `GET /v1/uploads` → `{ uploads: Upload[] }`, the newest 200.

```ts
interface Upload {
  id: string;
  batch: string | null;
  relPath: string;
  name: string;
  sizeBytes: number;
  receivedBytes: number;
  state: "receiving" | "verifying" | "done" | "failed" | "cancelled";
  reason: string | null;
  destination: { kind: "movies" } | { kind: "series" } | { kind: "folder"; path: string };
  /** The import it became. */
  itemId: string | null;
  createdAt: number;
  updatedAt: number;
}
```

An upload, a piece and the routes above for another device's upload answer `404`.

## Converting files

Old files are converted once, in the background, and the result takes the original's place when it is proven good. What happens to the files, the proof and what a crash leaves are in [conversion.md](conversion.md). Built on the server; not yet verified on a Raspberry Pi.

Every route here is for **managers only** (`403 forbidden` for a viewer device). When the server has no `conversion.dir` in its config, everything but reading the status answers `503 unavailable`. While the drive with Lobby's folder is not connected, claiming a job, uploading, undo and purge answer `503`; queueing still works, and the files wait.

```ts
interface ConversionJob {
  id: string;
  assetId: string;
  itemId: string | null;
  /** h264: old MPEG-4 video to H.264. hevc: AV1 to HEVC. repackage: MKV into MP4, nothing re-encoded. */
  kind: "h264" | "hevc" | "repackage" | null;
  /** "mac": too heavy for the server; it waits for a Mac. */
  worker: "any" | "mac";
  state: "queued" | "claimed" | "converting" | "uploaded" | "verifying" | "done" | "failed" | "skipped" | "cancelled";
  /** 1 is done first. */
  position: number;
  /** 0 to 1 within the current state. */
  progress: number;
  /** Why it was skipped or failed, or what it is waiting for. Show it as it is. */
  reason: string | null;
  originalBytes: number;
  /** The Mac that has it, and until when without a heartbeat. */
  claimedBy: string | null;
  leaseExpiresAt: number | null;
  /** "server", or the id of the device that converted it. */
  doneBy: string | null;
  /** The checks and what they measured, once the result was proven. */
  proof: { ok: boolean; reason: string | null; ssim: { mean: number; worst: number } | null;
           checks: { name: string; ok: boolean; detail: string }[] } | null;
  requestedBy: string | null;
  createdAt: number;
  updatedAt: number;
}
```

| `state` | Meaning |
| --- | --- |
| `queued` | Waiting. `reason` may say what for (free space, the drive, someone watching). |
| `claimed` | A Mac is converting it. |
| `converting` | The server is converting it. |
| `uploaded` | The result is there and waits to be proven, or is proven and waits until nobody watches the title. |
| `verifying` | The proof is running. |
| `done` | The converted file is in the library; the original is kept in Lobby's folder. |
| `failed` | ffmpeg failed, or the result did not pass the proof. Nothing in the library changed. Queue it again to retry. |
| `skipped` | This file is not converted; `reason` says why. |
| `cancelled` | A manager took it out. |

### `GET /v1/conversion` — Manager. Built.

```ts
{
  enabled: boolean;            // false: no conversion folder configured
  driveConnected: boolean;
  paused: boolean;
  serverConverts: boolean;     // false: only Macs take jobs
  hours: { from: number; to: number } | null;   // minutes after local midnight; null: any hour
  serverIdleBecause: string | null;             // why the server is not converting right now
  repackage: boolean;          // whether MKV files may be repackaged
  counts: Record<ConversionJob["state"], number>;
  /** Replacements that were interrupted and are left for a person. While there are any, nothing is replaced. */
  needsAttention: { id: string; reason: string }[];
  jobs: ConversionJob[];       // what waits or runs first, then the rest, newest first; at most 200
}
```

### `POST /v1/conversion/jobs` — Manager. Built.

Body: `{ "scope": "item", "itemId": "…" }` (a film, episode, season or show), `{ "scope": "category", "categoryId": "…" }` (the files of its folders, of the titles its rule takes in, and the same of the categories inside it), or `{ "scope": "old" }` (every file with MPEG-4, MS-MPEG-4 or AV1 video).

→ `201 { "queued": 12, "skipped": 3, "alreadyQueued": 0, "jobs": ConversionJob[] }`. A file is in the queue once. Files that will not be converted come back as `skipped` with the reason; for `category` and `old`, files that simply play as they are are left out. At most 5,000 files per request. `404` for an unknown title or category.

### `POST /v1/conversion/pause` and `/resume` — Manager. Built.

→ the status. While paused the server's own conversion stands still where it is, and Macs are given no jobs. A replacement that is already proven is not held back by this.

### `DELETE /v1/conversion/jobs/{jobId}` — Manager. Built.

Cancels a job that waits or runs. `409` once it is done, failed or skipped. A file that already took its original's place is not affected: undo that instead.

### `POST /v1/conversion/jobs/{jobId}/move` — Manager. Built.

Body `{ "to": "top" | "bottom" }`. Only for a job that waits.

### A Mac that takes jobs

A paired **manager** device may convert for the server. The server proves everything it is sent, so a Mac cannot put a wrong file into the library.

1. `POST /v1/conversion/claim`, body `{ "kinds"?: ["h264", "hevc", "repackage"] }` → `204` when there is nothing, or

   ```ts
   {
     job: ConversionJob;        // state "claimed", yours for 5 minutes at a time
     original: { assetId; url: string; bytes: number; durationMs: number | null; container: string; tracks: Track[] };
     /** What the result must contain. */
     target: {
       container: "mp4"; faststart: true;
       video: { index: number; action: "h264" | "hevc" | "copy"; codec: string; codecTag?: string | null };   // copied HEVC is labelled hvc1 (dvh1 when codecTag is dvhe/dvh1)
       audio: { index: number; action: "copy" | "aac" | "ac3"; channels: number | null; language: string | null }[];
       subtitles: { index: number; language: string | null }[];   // text tracks to keep, as mov_text
       keepChapters: true;
       reference: { encoder: "libx264"; preset: "veryfast"; crf: 21 };   // what the server itself uses
     };
     uploadUrl: string;
   }
   ```

   Asking again while holding a job returns the same job.
2. Fetch `original.url` with `Range` requests and the header `X-Lobby-Purpose: convert` (so the fetch does not count as someone watching).
3. `POST /v1/conversion/jobs/{id}/heartbeat`, body `{ "progress": 0.4 }`, at least every few minutes. Without one for 5 minutes the job goes back into the queue and what was uploaded is deleted.
4. Upload the result in pieces: `PATCH {uploadUrl}` with the bytes as the body, `Content-Length` (at most 64 MB a piece) and `Upload-Offset: <where this piece starts>` → `204` with the new `Upload-Offset`. A piece that does not start where the last one ended is refused with `409` and `{ "offset": <where to continue> }`. `GET` or `HEAD {uploadUrl}` says where the upload is. A result of more than three times the original's size is refused.
5. `POST /v1/conversion/jobs/{id}/complete`, body `{ "sizeBytes": <size>, "sha256"?: "<hex>" }` → `202` with the job in state `uploaded`. `409` with `offset` when not everything arrived or the hash does not match (then the upload starts over).
6. Watch the job in `GET /v1/conversion`: `done`, or `failed` with the reason.

`POST /v1/conversion/jobs/{id}/release` gives a job back. `410 gone` on any of these when the job is no longer this device's.

### `GET /v1/conversion/replacements` — Manager. Built.

```ts
{ replacements: { id: string; jobId: string; assetId: string; itemId: string | null;
                  state: "replaced" | "undone" | "purged";
                  originalBytes: number; newBytes: number;
                  replacedAt: number; undoneAt: number | null; purgedAt: number | null }[] }
```

### `POST /v1/conversion/replacements/{id}/undo` — Manager. Built.

Puts the original back where it was; the converted file is set aside in Lobby's folder, not deleted. `409` when it was undone or purged already, when the converted file was changed or moved since, when a file is again where the original was, or while someone watches the title.

### `POST /v1/conversion/replacements/{id}/purge` — Manager. Built.

Body `{ "confirm": "delete for good" }`, exactly. Deletes what Lobby keeps for this replacement: the original, or after an undo the converted file. **This is the only thing in Lobby that deletes a household's media file, and it only happens through this request.** The app asks the person first, every time. `400` without the words.

## Intros and credits

Where an episode's intro is and where its credits start, so the apps can offer Skip Intro and Next Episode (D-059). Built on the server and in the apps; not yet verified on a Raspberry Pi.

They come to the apps in each file's `markers` (Library). Of three sources, the first that says something wins: a server admin by hand (`manual`), the file's chapters (`chapters`: a chapter called "Intro", "Opening", "Credits", "End Credits", "Ending" and the like), or what Lobby found by comparing the sound of the episodes of a season (`detected`). A detected marker is given only when it is sure enough. Chapters and detected markers hold for the version of the file they were read from: a file that changed is looked at again. A manual marker stays, also after the file was converted. Films get markers from their chapters only.

Finding them is a background job (docs/decisions.md, D-059). It runs only when converting may: inside `conversion.hours`, and not while someone watches or downloads. A server admin can have a season looked at again at once.

Every route here is for **server admins** (`403 forbidden` for every other device), at home only. A guest household does not see them.

### `GET /v1/markers` — Server admin. Built.

```json
{
  "waitingBecause": "It is outside the hours set for converting.",
  "working": null,
  "pending": { "chapters": 0, "episodes": 14, "requested": 0 },
  "found": { "intro": 120, "credits": 97 }
}
```

`waitingBecause` is null while the job may work. `pending.episodes` counts episodes still to be compared, `requested` the files a server admin asked for that are not done yet.

### `GET /v1/markers/assets/{assetId}` — Server admin. Built.

The file's `markers` as the apps get them, what each source says (`sources: [{ kind, source, startMs, endMs, confidence, used, updatedAt }]`; a manual one with `startMs: null` says there is none), and how far the job got (`scan: { chaptersRead, compared, requested, failures, reason } | null`). `404` for a file there is not.

### `PUT /v1/markers/assets/{assetId}` — Server admin. Built.

`{ "intro"?: { "startMs": 61000, "endMs": 118500 } | null, "credits"?: { "startMs": 1290000 } | null }` → `200`, as `GET`. Sets them by hand: they win over chapters and what was found. `null` says there is none (and nothing found is shown either); left out stays as it is. Whole milliseconds from the start of the file, before its end; an intro's end after its start. Anything else is `400 invalid_request`.

### `DELETE /v1/markers/assets/{assetId}?kind=<intro|credits>` — Server admin. Built.

Forgets what was set by hand, for one kind or both: what the chapters say or what was found counts again. `200`, as `GET`.

### `POST /v1/markers/items/{itemId}/detect` — Server admin. Built.

For a season, a show (all its seasons), an episode (its season) or a film: its chapters are read again, its episodes compared again and the season's theme found again, now and at any hour, one file at a time and at the lowest priority. → `202 { "files": 10, "status": <as GET /v1/markers> }`. `404` for a title there is not.
