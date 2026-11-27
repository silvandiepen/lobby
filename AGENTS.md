# Working in the Lobby repository

Guidance for anyone changing this repository: people, and AI coding agents working for them.
`README.md` says what Lobby is; `CONTRIBUTING.md` says how a change gets in. This file is the
short version of how the code is put together and what must stay true.

## Layout

```
apps/server/        Lobby Server. TypeScript on Node 24, no build step. Linux and macOS.
apps/direct/        lobby-direct: the Rust helper for direct connections (ICE through libjuice, QUIC).
apps/introducer/    Introduces a server and its devices. A Cloudflare Worker, or Node on any machine.
apps/push-relay/    Sends every server's pushes to the App Store apps with the publisher's key. A Worker.
apps/apple/         One XcodeGen project: iOS/iPadOS, macOS and tvOS targets, sharing Shared/.
packages/LobbyKit/  Shared Swift: API client, catalogue cache, progress, shelves, downloads,
                    LobbyDirect, the apps' half of the direct connection, and LobbyPush, which
                    opens sealed pushes. No UI.
docs/               The API contract, the decision log, and guides per topic.
tools/release/      Builds what is shipped: the server archives, install.sh, the Docker image.
tools/              Other tools and experiments (demo server, deploy to a Pi). Not shipped.
assets/             The artwork licence.
```

Apps depend on packages, never on each other.

## Commands

```bash
npm install
npm run check                 # lint, typecheck, all Node tests (needs ffmpeg and ffprobe on PATH)
npm run lint                  # eslint + prettier --check
npm run typecheck
npm test -w apps/server       # the server suite: real SQLite, real ffmpeg, several minutes
npm test -w apps/introducer   # in Node and in workerd
npm test -w apps/push-relay   # the relay's rules, and in workerd with APNs played
npm test -w tools/release     # builds real archives and installs one (downloads Node once)
cargo test --release --manifest-path apps/direct/Cargo.toml
cargo clippy --all-targets --manifest-path apps/direct/Cargo.toml -- -D warnings
swift test --package-path packages/LobbyKit
npm run apple:generate        # LOBBY_TEAM=<team id> to sign; unset builds unsigned
npm run server:dev            # needs lobby.config.json, see below
```

The Xcode schemes are `Lobby` (iPhone and iPad), `LobbyMac`, `LobbyTV`, and the UI-test schemes
`LobbyMacUI` and `LobbyTVUI`. Unit tests:

```bash
xcodebuild test -project apps/apple/Lobby.xcodeproj -scheme LobbyMac -destination 'platform=macOS'
xcodebuild test -project apps/apple/Lobby.xcodeproj -scheme Lobby \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:LobbyTests
```

Use a simulator that already exists on the machine; do not create new ones from scripts.

A config for local runs (`lobby.config.json` is git-ignored):

```json
{
  "dataDir": "./apps/server/data",
  "roots": [{ "path": "/absolute/path/to/Movies", "name": "Movies", "hint": "movies" }]
}
```

`hint` is `movies`, `series`, `personal` or `mixed`, and `music` or `audiobooks` for audio. `roots`
may be left out: a manager then picks the folders in the app's first setup. Once the server has
started, what managers change lives in `<dataDir>/settings/settings.json` and wins over the file
(`docs/operations.md`). The setup secret that claims the first manager is printed at first start
and by `node apps/server/src/cli.ts setup-secret`.

## The contract

- `docs/api.md` is the contract between the server and the apps. Change it in the same change as
  the code, on both sides (server and LobbyKit).
- `docs/decisions.md` records every choice the guides leave open. Add an entry rather than
  deciding silently. Code comments point at decisions by title, not by number.
- `docs/kids.md` is the one guide to everything for children; keep it true when a kids part
  changes.

## Server (`apps/server`)

- **Node 24 or later, no build step.** Node runs the TypeScript directly: relative imports end in
  `.ts`, and only erasable syntax is allowed (no `enum`, no parameter properties, no namespaces).
  `tsc` is for type checking only.
- **SQLite through `node:sqlite`** (`src/db/database.ts`). Schema changes are new entries at the
  end of `src/db/migrations.ts`. Never edit a migration that has shipped: servers in use hold
  watch history in that database.
- Run-time dependencies are `hono`, `@hono/node-server`, `bonjour-service` and `multicast-dns`.
  Prefer what Node has before adding one.
- `src/library/` scanner, parser, probe, catalogue. `src/auth/` devices and pairing. `src/http/`
  the API. `src/playback/` repackaging for Apple playback. `src/music/` the audio library.
  `src/remote/` playing on another device. `src/settings/` what managers change in the app.
  `src/imports/` import folders, the Inbox and uploads. `src/outside/` the entrance from outside.
  `src/kids/` limits and kids control. `src/households/` several households on one server.
  `src/cli.ts` the `lobby` command.
- **The media folders are read-only to Lobby**, with one exception: `src/imports/` renames files
  into a library folder through its journal, on one drive, never over an existing file
  (`docs/imports.md`). Nothing else writes, renames or deletes under a library root.
- Tests use real SQLite files, real temp folders and real video made by ffmpeg at test time
  (`test/support/media.ts`). No mocked ffprobe, no mocked file system. Keep the media small and
  make fixtures once per file where the tests only read them.
- `test/direct.test.ts` runs the real `lobby-direct`: it is built when cargo is there and skipped
  with a message when it is not. `LOBBY_DIRECT_TARGET` points at programs built elsewhere.
- Never log a token, a pairing code or a file name from someone's library (`src/log.ts` strips
  paths from error text).

## Apple apps (`apps/apple`, `packages/LobbyKit`)

- Swift 6 with complete strict concurrency, SwiftUI, XcodeGen. Never edit the `.xcodeproj`: edit
  `project.yml` and run `npm run apple:generate`. The project is git-ignored.
- Playback is AVPlayer. The device credential goes to AVPlayer as a cookie (`lobby_device`),
  never in a URL.
- Most tests drive the real `AppModel` and `LobbyClient` against an HTTP stub of the API
  (`apps/apple/Tests/Support/Household.swift`). Await a model signal or the injected clock
  instead of sleeping.
- The direct connection's end-to-end tests (`packages/LobbyKit/Tests/LobbyDirectTests`,
  `apps/apple/MacTests/AbroadTests`) start the real server, introducer and `lobby-direct`. Build
  it first with `cargo build --release --bins --examples --manifest-path apps/direct/Cargo.toml`.
  Without it, or without Node 24, they skip.
- The iOS notification service extension (`apps/apple/NotificationService`) opens what a server
  sealed for the push relay and links only `LobbyPush`: keep that module small and free of the
  rest of LobbyKit.
- The UI tests start a local Lobby Server (`apps/apple/Scripts/ui-test-server.sh`). Tests that
  pair need the Keychain and so a signed build; unsigned, they skip and say so.

## Style

- Conventional Commits: `type(scope): imperative subject`. Sign off every commit (`git commit -s`).
- Plain words in docs, comments and messages. Comments say why, not what, and do not tell the
  history of the code: git has it.
- No secrets, no real people's names, hosts or library contents in code, tests or docs. Use
  documentation values: `lobby.example.ts.net`, `192.0.2.x`, `100.64.0.10`, viewers like Alex
  and Robin.
- Source files start with `SPDX-License-Identifier: MPL-2.0` (as a comment in the file's syntax).

## Gotchas

- In zsh, `"$HOST:lobby"` applies the `:l` modifier and lower-cases the variable. Write
  `"${HOST}:lobby"`.
- A new file is indexed only after it kept its size and date for `stabilityMs` (30 s by default),
  so a fresh copy does not appear at once. That is deliberate.
- An item's id comes from what the file names say (title, year, season, episode), never from
  TMDB. A changed match must not change an id: devices hold downloads by id.
