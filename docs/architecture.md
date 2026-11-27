# Architecture

Lobby is one server that a household runs on a computer that stays on, and Apple apps that pair
with it. Everything a viewer sees comes from that server; no Lobby service in the cloud holds a
catalogue, an account or a film. This page is the map. The details are in the topic docs it links
to, and the contract between the two sides is [api.md](api.md).

```
 iPhone / iPad / Mac / Apple TV                         the household's computer
 ┌───────────────────────────┐                          ┌──────────────────────────────┐
 │ Lobby app (SwiftUI)       │  home: HTTP, Bonjour     │ Lobby Server (Node 24, TS)   │
 │   └ LobbyKit              │ ───────────────────────▶ │   SQLite catalogue (lobby.db)│
 │       └ LobbyDirect       │  tailnet: HTTP           │   ffmpeg / ffprobe           │
 │           └ libjuice (C)  │ ───────────────────────▶ │   media folders (read-only)  │
 └───────────────────────────┘                          │   lobby-direct (Rust)        │
            │   outside: QUIC over an ICE path          └──────────────▲───────────────┘
            └──────────────────────────────────────────────────────────┘
                      found through the introducer (sealed messages only)
```

## The parts

| Part | Where | What it is |
| --- | --- | --- |
| Lobby Server | `apps/server` | TypeScript run directly by Node 24 (no build step), Hono for HTTP, SQLite through `node:sqlite`. Linux and macOS. Shipped as release archives, an installer and a container image ([release.md](release.md)). |
| lobby-direct | `apps/direct` | A small Rust program the server starts for the direct road: ICE through the vendored libjuice, QUIC through quinn and rustls. It listens on loopback only and joins each QUIC stream to the server's own socket. |
| The introducer | `apps/introducer` | Where a server and its devices find each other before a direct connection. One core for a Cloudflare Worker (`worker.ts`) or Node on a machine of one's own (`node.ts`). It passes sealed messages on and never sees what they say, an address to connect to or any media. |
| Apple apps | `apps/apple` | One XcodeGen project (`project.yml`) with targets for iPhone and iPad, Mac and Apple TV. Swift 6, SwiftUI, AVPlayer. `Shared/` holds the models and screens the platforms share. |
| LobbyKit | `packages/LobbyKit` | The Swift package the apps use: the API client, the catalogue cache, progress, shelves, downloads, uploads, music, remote play, kids, search. Its `LobbyDirect` target is the device half of the direct road, on libjuice through the small `CLobbyIce` bridge. No UI. |

Apps depend on the package, never on each other. `docs/api.md` is the one contract: a change to
the API changes that page, the server and LobbyKit together.

## Lobby Server

`apps/server/src`, by area:

| Folder | Does |
| --- | --- |
| `library/` | Scanner, file-name parser, ffprobe, the catalogue of films, series, seasons and episodes, categories and studios, overrides. See [library.md](library.md). |
| `enrich/`, `artwork/`, `search/` | Matching at TMDB with the operator's own key, artwork (fetched, uploaded, or a frame), search in the library and beyond it (D-061). |
| `auth/`, `revocations.ts` | Devices, pairing and the claim of a new server. |
| `http/` | The Hono app, the guards at home (Host and Origin checks) and the routes. |
| `playback/` | Repackaging for Apple playback: HLS with fragmented MP4 written while ffmpeg runs, a size-limited cache, subtitles to WebVTT, picture subtitles. See [playback.md](playback.md). |
| `conversion/` | Converting files Apple devices cannot play, with a proof before an original is replaced. See [conversion.md](conversion.md). |
| `markers/` | Finding intros and credits (Skip Intro, D-059). |
| `music/` | The audio library (music and audiobooks), apart from the films (D-025). |
| `remote/`, `push/` | Playing on another device (Play On), waking an Apple TV through a Python helper with pyatv (D-046, D-056), and push notifications through APNs. |
| `kids/` | Kids limits (which titles, D-027) and kids control (when and what, D-062). See [kids.md](kids.md). |
| `households/` | Several households on one server, one library (D-052, D-053). |
| `imports/` | Import folders and uploads, the only code that writes into a library folder, through a journal. See [imports.md](imports.md). |
| `settings/` | What managers change in the app, the first setup, the folder browser. |
| `stats/`, `devices-downloads/` | Watch statistics (D-060); downloads a manager puts on a device. |
| `outside/` | The entrance for devices away from home and the tailnet, and the direct road's server half. See [outside.md](outside.md). |
| `cli.ts` | The `lobby` command: `serve`, `status`, `scan`, `backup`, `devices`, `approve`, `revoke`, `setup-secret`, `outside`, `direct` and more. |

### Storage

Everything the server keeps is under its data folder (`dataDir`):

- `lobby.db`: the SQLite catalogue, devices, viewers, progress, households, kids plans and
  statistics. Schema changes are new entries in `src/db/migrations.ts`; shipped migrations are
  never edited.
- `artwork/` and `cache/`: pictures and repackaged copies. Both can be rebuilt.
- `settings/settings.json`: what managers changed in the app. It wins over `lobby.config.json`.
- Secrets (the setup secret, keys for the outside entrance) and backups.

The media folders are read-only to Lobby, with the one exception of `imports/`. Files are
identified by a fingerprint, not by a file-system id, and an item's id comes from what its files
say (title, year, season, episode), never from a match: a changed match or a rename keeps the id,
so downloads and progress on devices stay valid.

### Trust

- **Devices.** A device pairs once with a short code that a manager approves, or claims a new
  server with the setup secret. It gets a random 32-byte credential that the server stores only as
  a hash. The app keeps it in the Keychain and sends it as a bearer token, or as the
  `lobby_device` cookie for AVPlayer. It never goes in a URL. Revoking a device ends its access.
- **Roles.** A server admin, a household admin or a viewer device (D-053). The server enforces
  every role and every kids rule; the app on a child's device is not trusted (D-027).
- **At home**, requests must name a host the server goes by, and an `Origin` must match, against
  DNS rebinding and cross-site requests.
- **Files** are served only after a containment check of their real path, and nothing logs a
  token, a pairing code or a file name.

## How devices reach the server

| Road | How it works |
| --- | --- |
| Home | Plain HTTP on the local network. The server announces itself over Bonjour (`_lobby._tcp`) and tells paired devices its addresses (`addresses.home`). |
| Tailscale | Plain HTTP to the server's tailnet name or address, encrypted by Tailscale underneath (`addresses.remote`). |
| Outside, direct | Off by default. The device and the server find each other through the introducer, ICE finds a path, and QUIC runs over it between the app (LobbyDirect) and lobby-direct. The device proves itself with its own key, bound to the TLS session. No port is opened at home. |
| Outside, relay | TLS from the device to the server through a relay that only passes bytes on. Built, not yet verified against a real relay. |

The app picks the road by itself and moves when the network changes. From outside, the server's
entrance has its own default-deny table of routes, and a device may use it only once a manager
allowed it (D-028, D-034). [outside.md](outside.md) has the threat model.

## The apps

- One `AppModel` per server the app knows (`ServersModel` holds them), driven by LobbyKit.
- The catalogue is synced incrementally (`GET /v1/library`) and kept on the device, so shelves are
  built locally and downloads open offline (D-003).
- Playback is AVPlayer over HLS from the server, or over the direct road through a loopback server
  in the app (`LoopbackServer`).
- Downloads use background `URLSession` and are verified before they count. Progress is queued per
  viewer while offline and reconciled later.
- Managers upload files from the Mac (files and folders) and from iPhone and iPad (from Files).
  The Apple TV app has its own focus-driven screens in `tvOS/`.

## Where to read on

[api.md](api.md) (the contract) · [decisions.md](decisions.md) (why things are as they are) ·
[library.md](library.md) · [playback.md](playback.md) · [outside.md](outside.md) ·
[kids.md](kids.md) · [imports.md](imports.md) · [operations.md](operations.md) ·
[release.md](release.md)
