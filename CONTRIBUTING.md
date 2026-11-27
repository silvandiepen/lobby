# Contributing to Lobby

Thank you for wanting to help. This page says how to set up, what a change needs, and how it gets
in. `AGENTS.md` has the technical details of the code (layout, commands, what must stay true).

## Before you start

- **Bugs**: open an issue with the bug template. Leave out file names from your library and
  anything else private; the server's logs already strip paths.
- **Features**: open an issue first for anything larger than a small fix, so we can agree on the
  shape before you build it. Many choices are already recorded in `docs/decisions.md`.
- **Security problems**: never in a public issue. See `SECURITY.md`.

## Setting up

| For | You need |
| --- | --- |
| Server, introducer, push relay, release tools | Node 24 or later, npm, ffmpeg and ffprobe on `PATH` |
| `lobby-direct` | Rust 1.90 (`rustup`), a C compiler |
| Apple apps and LobbyKit | macOS with Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen) |

```sh
git clone https://github.com/silvandiepen/lobby.git
cd lobby
npm install
npm run check
```

### Building the Apple apps

The Xcode project is generated from `apps/apple/project.yml` and is not in git:

```sh
npm run apple:generate                          # unsigned: simulator and Mac only
LOBBY_TEAM=ABCDE12345 npm run apple:generate    # signed with your Apple team
```

`LOBBY_TEAM` is your Apple Developer team id. XcodeGen writes it into the project as
`DEVELOPMENT_TEAM`; you can also pass `DEVELOPMENT_TEAM=…` to `xcodebuild`. To install on your own
devices you also need bundle identifiers of your own: change `bundleIdPrefix` and the
`PRODUCT_BUNDLE_IDENTIFIER` values in `project.yml` locally, and do not commit that change. Never
edit the generated `.xcodeproj`: it is overwritten on the next generate.

Some tests need more than Xcode:

- The direct connection's end-to-end tests need `lobby-direct` built first:
  `cargo build --release --bins --examples --manifest-path apps/direct/Cargo.toml`. Without it
  they skip.
- The UI tests start a real Lobby Server on your Mac, so they need Node 24 and ffmpeg. Tests that
  pair need the Keychain, which a simulator build has only when it is signed.

## Making a change

1. Fork the repository and make a branch from `main`: `feat/…`, `fix/…`, `docs/…`, `chore/…`.
2. Keep a change to one purpose. Several small pull requests are easier to review than one large
   one.
3. Add or change tests with the code. A bug fix comes with a test that fails without it.
4. Run the checks for what you touched (below). Pull requests are checked by CI as well.
5. Open a pull request against `main` and fill in the template.

### Tests are required

| You changed | Run |
| --- | --- |
| `apps/server`, `apps/introducer`, `apps/push-relay`, `tools/` | `npm run check` |
| `apps/direct` | `cargo test --release` and `cargo clippy --all-targets -- -D warnings` in `apps/direct` |
| `packages/LobbyKit` | `swift test --package-path packages/LobbyKit` |
| `apps/apple` | the unit tests of the schemes you touched (`Lobby`, `LobbyMac`, `LobbyTV`) |

Tests use the real thing: real SQLite files, real temporary folders, video made by ffmpeg at test
time, the real `lobby-direct`. Please do not replace them with mocks. If a test is slow, make its
fixtures smaller or create them once per file instead.

### The API contract

`docs/api.md` is the contract between the server and the apps. A change to the API changes
`docs/api.md`, the server and LobbyKit in the same pull request.

### Decisions

When a change makes a choice the docs leave open, add an entry to `docs/decisions.md`: the next
free number, a **Context** line with the problem, the decision, its consequences and the
alternatives you rejected. To change an earlier decision, add a new entry that supersedes it. Code
comments point at a decision by its title (`docs/decisions.md, "Wake and Play"`).

## Commits

- **Conventional Commits**: `type(scope): imperative subject`, for example
  `fix(server): keep the chosen poster when the cap is reached`. Types: `feat`, `fix`, `docs`,
  `test`, `refactor`, `perf`, `build`, `ci`, `chore`. Scopes are the part you changed: `server`,
  `apple`, `lobbykit`, `direct`, `introducer`, `push-relay`, `release`, `docs`.
- The body says why, in plain words, when the subject does not.
- **Sign off every commit** (Developer Certificate of Origin, below): `git commit -s`.

### Developer Certificate of Origin

Lobby does not ask for a contributor licence agreement. Instead, each commit carries a
`Signed-off-by:` line with your real name and email, which certifies the
[Developer Certificate of Origin 1.1](https://developercertificate.org/): that you wrote the change
or otherwise have the right to submit it under the project's licence.

```
Signed-off-by: Your Name <you@example.com>
```

`git commit -s` adds it. To add it to commits you already made on your branch:
`git rebase --signoff main`. Pull requests with unsigned commits cannot be merged.

By contributing, you agree that your contribution is licensed under the Mozilla Public License
2.0, like the rest of the code. Artwork is different: please do not contribute icons or pictures
without talking to us first (`assets/LICENSE-ART`).

## Code style

- **TypeScript**: ESLint (strict type-checked) and Prettier, run by `npm run lint`. Node runs the
  TypeScript directly, so only erasable syntax: no `enum`, no parameter properties, no
  namespaces; relative imports end in `.ts`.
- **Swift**: Swift 6 with complete strict concurrency. No `@unchecked Sendable`, no
  `nonisolated(unsafe)` to silence the checker; fix the cause.
- **Rust**: `cargo fmt` and clippy with warnings as errors.
- **All**: comments explain why, not what. No commented-out code, no TODO without an issue. Errors
  are handled or passed on, not swallowed. Every source file starts with the line
  `SPDX-License-Identifier: MPL-2.0`, as a comment.
- **Docs**: plain, direct English. Use documentation values in examples: `lobby.example.ts.net`,
  `192.0.2.10`, `100.64.0.10`, invented names.

## AI-assisted contributions

You may use AI coding tools. You are responsible for what you submit, exactly as if you had typed
it: you understand it, you tested it, and you have the right to submit it (the sign-off says so).
AI-assisted pull requests are reviewed like any other, with the same bar for tests and clarity.
`AGENTS.md` is written for coding agents too. Please do not open pull requests or issues that were
generated and not read.

## Reviews and releases

A maintainer reviews every pull request. Expect questions; they are about the change, not about
you. Merged changes ship with the next release (`docs/release.md`).

## Conduct

Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).
