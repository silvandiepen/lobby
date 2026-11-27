# Lobby

Your films, series and music, on every screen at home, and with you when you leave.

Lobby is a media library for a household. **Lobby Server** runs on a computer that stays on (a
Raspberry Pi, a NAS, an old Mac, a mini PC) and serves the films, series and music in its folders.
The **Lobby apps** for iPhone, iPad, Mac and Apple TV browse them, play them, and keep downloads
for when there is no connection. Nothing goes through a cloud service of ours: your library stays
on your server, and the apps talk to it directly.

<!-- Screenshots: to be added (iPhone, iPad, Mac and Apple TV, from the demo library in tools/demo). -->

## Features

- **Library**: scans folders of films, series, music and audiobooks, recognises titles from their
  file names, and fills in posters and summaries from TMDB with your own key.
- **Playback**: plays what Apple devices play natively, and repackages or converts the rest on the
  server (MKV, older formats), with subtitles per viewer and Skip Intro.
- **Viewers and households**: one server, several viewers with their own progress and
  Continue Watching; several households on one server, each with its own people.
- **Kids**: kids viewers and devices with limits on what they see, and kids control for when and
  what (school hours, bedtime, ask a grown-up first).
- **Downloads**: keep films and episodes on a device and watch them offline; progress syncs back.
- **Play On**: start something on the Apple TV from a phone, and wake the TV for it.
- **Uploads and imports**: add files from the Mac app or an import folder; Lobby files them safely.
- **Away from home**: on the home network, over Tailscale, or through the outside entrance with a
  direct, end-to-end encrypted connection (`docs/outside.md`).

## Status

Lobby Server 1.0.0 is released (Linux and macOS, arm64 and x64, and a Docker image). The Apple
apps are in development and testing. Lobby is developed in the open from here on; expect changes
in the API until the apps' first public release.

## How it fits together

```
 iPhone, iPad, Mac, Apple TV  ──  LobbyKit (Swift)  ──┐
                                                      │  HTTP API (docs/api.md)
                                                      │  home network, Tailscale, or
                                                      │  the outside entrance (QUIC, direct)
                                                      ▼
                         Lobby Server (Node 24, SQLite)  ── lobby-direct (Rust)
                         your media folders, read-only        │
                                                              ▼
                                                  introducer (Cloudflare Worker or Node):
                                                  introduces devices, sees nothing it can read

 Lobby Server ── sealed pushes ──▶ push relay (Cloudflare Worker) ──▶ Apple's push service ──▶ apps
```

`docs/architecture.md` explains each part.

## Install the server

Lobby Server needs Linux or macOS (arm64 or x64), and ffmpeg and ffprobe.

- **Release archive and installer.** Every release on
  [GitHub Releases](https://github.com/silvandiepen/lobby/releases) has an archive per platform,
  `SHA256SUMS` and `install.sh`. The installer checks the archive, installs it with its own Node
  runtime into your home folder, and sets it up as a service (systemd or launchd):

  ```sh
  curl -fsSLO https://github.com/silvandiepen/lobby/releases/latest/download/install.sh
  sh install.sh
  ```

- **Docker.** `tools/release/docker/` has the Dockerfile and a `compose.yaml`.

Then open a Lobby app on the same network, find the server, and claim it with the setup secret it
prints. `docs/release.md` covers the archives, the installer and updates; `docs/operations.md`
covers running a server.

## Build from source

Prerequisites: Node 24 or later, ffmpeg and ffprobe; Rust 1.90 for `lobby-direct`; Xcode 26 and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) for the apps.

```sh
npm install
npm run check            # lint, typecheck and the Node test suites
npm run server:dev       # with a lobby.config.json, see AGENTS.md
```

The apps:

```sh
LOBBY_TEAM=<your Apple team id> npm run apple:generate
open apps/apple/Lobby.xcodeproj
```

Without `LOBBY_TEAM` the project builds unsigned for the simulator and the Mac. To run on your own
devices, also change the bundle identifiers to your own (`bundleIdPrefix` and
`PRODUCT_BUNDLE_IDENTIFIER` in `apps/apple/project.yml`); push notifications to those builds then
need your own APNs key (`docs/operations.md`): the push relay sends only to the App Store apps.

## Tests

| Part | Command |
| --- | --- |
| Server, introducer, push relay, release tools | `npm run check` (or `npm test -w apps/server`) |
| lobby-direct | `cargo test --release --manifest-path apps/direct/Cargo.toml` |
| LobbyKit | `swift test --package-path packages/LobbyKit` |
| Apple apps | `xcodebuild test` with the `Lobby`, `LobbyMac` or `LobbyTV` scheme |

The server's tests run against real SQLite, real folders and video made with ffmpeg; nothing is
mocked. `CONTRIBUTING.md` has the details.

## Repository

```
apps/server/        Lobby Server (TypeScript on Node 24)
apps/direct/        lobby-direct, the direct connection's helper (Rust)
apps/introducer/    the introducer (Cloudflare Worker or Node)
apps/push-relay/    the push relay for the App Store apps (Cloudflare Worker)
apps/apple/         the Apple apps: iPhone and iPad, Mac, Apple TV
packages/LobbyKit/  Swift code the apps share
docs/               the API contract, decisions and guides
tools/              release builds, the demo server, experiments
```

## Documentation

| Guide | What it covers |
| --- | --- |
| [Product](docs/product.md) | What Lobby does, for whom, and what is not built yet |
| [Architecture](docs/architecture.md) | The parts and how they talk |
| [Status and roadmap](docs/delivery.md) | What is built and what is next |
| [Releases and installing](docs/release.md) | Archives, the installer, Docker, updates, the apps |
| [Operating a server](docs/operations.md) | Configuration, backups, push, troubleshooting |
| [Server API](docs/api.md) | The contract between the server and the apps |
| [Library and matching](docs/library.md) | Folders, names, series, matching and artwork |
| [Playback](docs/playback.md) | What plays directly, repackaging, and the cache |
| [Conversion](docs/conversion.md) | Converting files that cannot be repackaged |
| [Imports and uploads](docs/imports.md) | Import folders, the Inbox and uploads |
| [Outside](docs/outside.md) | Reaching the server from outside: the entrance, the introducer, the direct road |
| [Kids](docs/kids.md) and [kids control](docs/kids-control.md) | Kids viewers and devices, limits, when and what |
| [Apple apps](docs/apple-apps.md) | How the apps work and their design direction |
| [Plugins](docs/plugins.md) | Extending Lobby |
| [Decisions](docs/decisions.md) | Every choice the guides leave open, with reasons |

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first: commits are signed off
under the [Developer Certificate of Origin](https://developercertificate.org/). Please follow the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Licence and trademarks

The code is licensed under the [Mozilla Public License 2.0](LICENSE). The Lobby name, the icons,
the avatars and the other artwork are not: see [assets/LICENSE-ART](assets/LICENSE-ART) and
[TRADEMARKS.md](TRADEMARKS.md). Forks need their own name and icons. Third-party notices are in
[NOTICE.md](NOTICE.md).

## Support and security

Questions and bugs: [GitHub issues](https://github.com/silvandiepen/lobby/issues), or
support@hakobs.com. Report security problems privately, as [SECURITY.md](SECURITY.md) describes.
