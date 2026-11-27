# Releasing Lobby Server

Lobby Server runs on any computer that stays on: a Raspberry Pi, a NAS, an old Mac, a mini PC. A release is four archives, an installer that installs one of them, and a container image (D-045). Releases are published on this repository's [GitHub Releases](https://github.com/silvandiepen/lobby/releases). The first is Lobby Server 1.0.0 (`apps/server/package.json`), released from the tag `v1.0.0`.

| Archive                                   | For                                                     |
| ----------------------------------------- | ------------------------------------------------------- |
| `lobby-server-<v>-linux-arm64.tar.xz`     | Raspberry Pi 4 and 5 (64-bit Raspberry Pi OS), ARM boxes |
| `lobby-server-<v>-linux-x64.tar.xz`       | mini PCs, NAS boxes with Intel or AMD, servers           |
| `lobby-server-<v>-macos-arm64.tar.xz`     | Macs with Apple silicon, macOS 13.5 or later             |
| `lobby-server-<v>-macos-x64.tar.xz`       | Intel Macs, macOS 13.5 or later                          |

Linux needs glibc 2.28 or later (Debian 10, Ubuntu 20.04 and newer), which the official Node.js needs. On Alpine and other musl systems, and on a NAS that runs everything as root, the image is the way. Windows is not planned. Every platform needs `ffmpeg` and `ffprobe` from the system; nothing installs them for you.

## What is in an archive

```
lobby-server-<v>-<platform>/
  app/                    apps/server without its tests, and its production node_modules from package-lock.json
  runtime/bin/node        the official Node.js named in tools/release/node-runtime.json, and its LICENSE
  bin/lobby               the command (tools/release/lobby.sh)
  bin/lobby-direct        the direct connection's helper, when it was built for the platform
  installer/install.sh    for `lobby update` and `lobby uninstall`
  LICENSES/LICENSE        Lobby's licence, the Mozilla Public License 2.0
  LICENSES/THIRD-PARTY-NOTICES.txt   Node.js, every npm package, and every crate and C library in lobby-direct
  VERSION  BUILD.json  README.txt
```

Beside the archives: `install.sh` and `SHA256SUMS` (all archives and the installer). The installer refuses an archive whose SHA-256 is not the one in `SHA256SUMS`. Both come from the same place, so this protects against a broken or swapped download, not against whoever controls the release: the site shows the checksums too, to compare.

**Licence.** Lobby's code is licensed under the Mozilla Public License 2.0 ([LICENSE](../LICENSE)); every archive carries it as `LICENSES/LICENSE`, beside `LICENSES/THIRD-PARTY-NOTICES.txt` with the licence texts of everything else in it. The artwork (name, icons, avatars) is not under the code licence: [assets/LICENSE-ART](../assets/LICENSE-ART) and [TRADEMARKS.md](../TRADEMARKS.md).

## Building the archives

```bash
node tools/release/build.ts                        # all four, into dist/release (git-ignored)
node tools/release/build.ts macos-arm64            # one
node tools/release/build.ts --build-direct         # and build lobby-direct where this machine can
node tools/release/build.ts --direct-dir direct    # with lobby-direct built elsewhere: direct/<platform>/lobby-direct
```

It needs Node 24, npm, git, tar and xz, and cargo for the notices of lobby-direct. Node.js is downloaded once from nodejs.org into `~/.cache/lobby-release` (`--cache`, `LOBBY_RELEASE_CACHE`) and checked against the SHA-256 pinned in `tools/release/node-runtime.json`. To move to another Node: take the four lines for `node-<v>-{linux,darwin}-{arm64,x64}.tar.xz` from `https://nodejs.org/dist/<v>/SHASUMS256.txt` into that file. `tools/deploy-pi.sh` reads the version from it too.

The installer knows where releases are published, for downloading without `--archive`: `RELEASES_DEFAULT` in `tools/release/install.sh` is `https://github.com/silvandiepen/lobby/releases`. `--releases <url>` writes another address into the archives' installer (a fork's own releases page, for example); the workflow passes the releases page of the repository it runs in, which for this repository is the same.

**Reproducible.** The files of a commit, the pinned Node and the same lobby-direct give the same archive, byte for byte: every file has the commit's time (`SOURCE_DATE_EPOCH` overrides it), owner 0, fixed modes, names in sorted order, and xz runs on one thread. GNU tar (Linux) and bsdtar (macOS) write slightly different archives, so compare archives made with the same kind of tar. Checked on a Mac: two builds of the same commit, the same SHA-256. Work that is not committed goes in too, and `BUILD.json` says so.

## lobby-direct per platform

`tools/release/build-direct.sh <platform> <file>` builds it. Building it needs more than building Lobby, so an archive may come without it; the server then says under `GET /v1/outside` that the program is not there, and everything but the direct connection works.

- **Linux arm64 and x86_64:** a static musl program, built in a throw-away container from the pinned `rust:1.90-alpine3.22` image, so one program runs on every distribution. Needs Docker; about 1.5 GB while it builds. On a machine of the other architecture Docker needs QEMU and takes much longer, so the workflow builds each on its own kind of runner. Same sources, same bytes.
- **macOS arm64 and x86_64:** on a Mac, with rustup's toolchain 1.90.0 and its target: `rustup toolchain install 1.90.0 && rustup target add --toolchain 1.90.0 aarch64-apple-darwin x86_64-apple-darwin` (some hundred MB). For macOS 13.5 and later. The workflow builds both on a macOS runner.
- **Adding it later to an installed server:** build it as above on any machine with that toolchain (or with `tools/build-direct-pi.sh <user@host>` on a Pi with Docker; the host is its argument or `LOBBY_HOST`, there is no default), copy it to `~/lobby/bin/lobby-direct`, `chmod 755`, not writable by others, and set `outside.direct.binary` to `bin/lobby-direct` ([outside.md](outside.md#the-direct-road)). `lobby update` keeps a `bin/lobby-direct` that the new archive does not replace.

## The container image

`tools/release/docker/Dockerfile`: Alpine with ffmpeg and tzdata, the server, its dependencies, and lobby-direct (`/opt/lobby/bin/lobby-direct`), running as uid 1000. Everything Lobby keeps is in the volume `/lobby`; the config is made there on the first start (`LOBBY_NAME`, `LOBBY_PORT`), without folders, like the installer's. `tools/release/docker/compose.yaml` is the example to start from.

```bash
docker build -f tools/release/docker/Dockerfile -t lobby-server .
docker compose -f tools/release/docker/compose.yaml up -d --build
docker compose -f tools/release/docker/compose.yaml exec lobby node /opt/lobby/app/src/cli.ts status --config /lobby/lobby.config.json
```

- **Host networking (Linux).** Bonjour, by which the apps find the server, does not cross Docker's own network, and behind published ports every request seems to come from Docker's private network. That would make every device "nearby", which is what lets a device set a fresh server up: with `ports:`, put `"claim": "secret"` in the config and use the secret from the log. Docker Desktop on a Mac does not reach the home network this way: use the macOS archive there.
- **Media read-only.** Mount each library folder `:ro`. Converting needs Lobby's own folder and the library on one writable mount of the drive (a replacement is a rename between them, which does not cross mounts); leave it out to keep the library read-only.
- **The open-file check** (below) sees only the container's own processes.
- **Waking Apple TVs is not in the image**, nor in the archives: pyatv is a second runtime most households have no use for. It is optional; [operations.md](operations.md#waking-the-apple-tv) has the venv to make and the one line of config. The image has no Python, and a venv points at the Python it was made with, so a mounted one does not run there: for waking from a container, build an image of one's own on this one with `apk add python3`, a venv with pyatv in it, and `remote.wake.pyatv` pointing at its `bin`. Not tried.
- No image is published. The workflow builds one per architecture as an OCI archive artifact.

## The release workflow

`.github/workflows/release.yml` runs when a tag `v<version>` is pushed to this repository, and on nothing else. The tag must be `apps/server/package.json`'s version. It runs the installer tests on Linux and macOS, builds lobby-direct on Linux x86_64, Linux arm64 and macOS runners, the four archives with them, and the image for amd64 and arm64. It needs no secrets and publishes nothing: the archives, `SHA256SUMS`, `install.sh` and the images are the run's artifacts.

To release, by hand:

1. Set the version in `apps/server/package.json`, commit, tag `v<version>`, push the tag.
2. Download the run's artifacts. Install the archive for one Linux computer and one Mac with `sh install.sh --archive …`, and update one older install.
3. Publish them: a GitHub release on the tag with the archives, `SHA256SUMS` and `install.sh` (`gh release create v<version> lobby-server-* SHA256SUMS install.sh`). The installer looks in `<releases>/latest/download/` and `<releases>/download/v<version>/`, so the repository has to be public for downloads to work, or `--releases` has to name another place with the same layout.
4. Update the download links and checksums on the website, which point at this repository's releases.

## The installer

`tools/release/install.sh`, POSIX sh, ASCII, checked with shellcheck and run under dash and macOS's sh by the tests. Read it before running it; the top says what it writes.

```bash
curl -fsSLO <releases>/latest/download/install.sh
less install.sh
sh install.sh                     # the newest release, into ~/lobby
sh install.sh --archive lobby-server-<v>-linux-arm64.tar.xz   # one downloaded already, SHA256SUMS beside it
```

- Runs as the user Lobby runs as; refuses root. Writes only to its folder (`--prefix`, default `~/lobby`) and one service file.
- **A new config** without folders, `host` `0.0.0.0`, port 8674, and the default claim: the first device that connects from the home network or the tailnet sets the server up (the server refuses others, [api.md](api.md#who-may-ask)). An existing config, data folder and log are never overwritten.
- **Services.** Linux: a systemd user service (`~/.config/systemd/user/lobby.service`); it starts at boot and survives logging out only when the user lingers (`sudo loginctl enable-linger <user>`; the installer says so when it is off). `--service system`: `/etc/systemd/system/lobby.service`, running as the user, written with sudo, for a computer nobody logs in to. macOS: a launch agent (`~/Library/LaunchAgents/lobby.server.plist`), which runs while the user is logged in; `--service system` writes a launch daemon in `/Library/LaunchDaemons` with `UserName` instead. `--service none`: start `bin/lobby serve` yourself. All restart the server when it exits with 75 to take new settings: systemd by `RestartForceExitStatus=75`, launchd and Docker because `LOBBY_SUPERVISED=1` makes the server exit instead of restarting in its own process.
- **Waking Apple TVs** is optional and not installed: see [operations.md](operations.md#waking-the-apple-tv) for pyatv in a venv beside the install (`~/lobby/pyatv`).
- **ffmpeg** is checked, not installed: the installer prints the command for the distribution (apt, dnf, pacman, zypper, apk, …) or Homebrew.
- **`lobby update`** downloads and checks the newer archive, stops the service, backs the catalogue up with the version that wrote it (`lobby backup`, into `data/backups`), puts the new version in place, and starts it. The data folder and the config are not touched; the version before stays in `.previous/` until the next update. Refuses the installed version and older ones (an older server may not read a newer catalogue) without `--force`.
- **`lobby uninstall`** removes the program and the service it wrote, and keeps the data folder, the config and the log. `--delete-data` deletes those too, after typing "delete" (or `--yes`); a data folder outside the prefix is never deleted. Library folders are never touched.
- A server deployed with `tools/deploy-pi.sh <user@host>` (or `LOBBY_HOST`; no default host) has the same layout; `sh install.sh update --prefix ~/lobby` updates it and leaves its own systemd unit as it is.

## macOS: what differs

- **Whether another program has a file open** is checked before converting replaces a file, from `/proc`, which only Linux has. On a Mac (and in a container, for programs outside it) the check finds nothing, so a file that another program is writing to could be replaced. Converting already waits for a file to keep its size and date, and does not start while anyone plays; on a Mac, also keep `conversion.hours` to hours when nothing copies into the library. A replaced file that is open elsewhere keeps working for that program: a rename does not disturb it.
- **Privacy.** macOS asks before a program reads Desktop, Documents, Downloads, iCloud Drive or a removable or network volume, and a launch agent cannot show the question. When the library is in one of those, allow `~/lobby/runtime/bin/node` in System Settings → Privacy & Security → Full Disk Access (or Files and Folders). Not yet tried on a Mac with a library on an external drive.
- **Sleep.** A Mac that sleeps is not there. Set it to stay awake on power (System Settings → Energy) and to start after a power failure.
- The folder browser offers the drives under `/Volumes` and the home folder.

## Tests

```bash
npm test -w tools/release
```

`tools/release/test/install.test.ts`: the installer's pieces (platform, checksums, versions, the services, which `plutil` checks on a Mac) in sh and in dash; then three real archives for this computer's platform are built, and installed into a temporary home with stand-ins for launchctl, systemctl, loginctl and sudo, which start and stop the installed server as the service manager would. It checks a wrong checksum is refused, the config and the service, that the server runs from the installed copy and answers, an update with the server running (backup, data and config unchanged, a `bin/lobby-direct` put there kept, the new version answering), no update to the same or an older version, uninstalling (data and config kept) and deleting the data only when asked. The release workflow runs it on Ubuntu and on macOS.

# Releasing the Apple apps

The App Store builds of Lobby (iPhone and iPad, Mac and Apple TV: one free, universal purchase, bundle id `mt.sil.lobby`) are published by the maintainer, who holds the signing team and the App Store listing. App Review connects to a demo server with open movies: [tools/demo/README.md](../tools/demo/README.md). A fork that is distributed uses its own bundle id, signing team and name, and its own icons ([TRADEMARKS.md](../TRADEMARKS.md)); building and signing the apps yourself is in [CONTRIBUTING.md](../CONTRIBUTING.md).

**Versions.** `MARKETING_VERSION` in `apps/apple/project.yml` is the version people see (1.0 for the first release), the same on every platform. `CURRENT_PROJECT_VERSION` is the build: raise it by one before every upload, of any platform. App Store Connect refuses a build number it already has for that version and platform, and one counter for all of them keeps a build of each platform from the same commit recognisable.

**Encryption (export compliance).** `ITSAppUsesNonExemptEncryption` is `false` in all three apps, so App Store Connect asks nothing at upload. Checked against Apple's "Complying with Encryption Export Regulations" and "Overview of export compliance" (2026-11-27). What the apps use:

- HTTPS through `URLSession`, and QUIC with TLS 1.3 through Network.framework: the operating system's encryption.
- CryptoKit (X25519, Ed25519, ChaCha20-Poly1305, HKDF, SHA-256) and CommonCrypto (PBKDF2-HMAC-SHA256 inside scrypt, RFC 7914): the operating system's libraries, with standard algorithms only (IETF RFCs). Nothing proprietary.
- libjuice (ICE, STUN): message integrity and authentication of STUN requests, no encryption of content.

They protect the user's own connection to their own server, and authenticate devices and pairing. The apps' primary function is playing the household's films and music: entertainment, not information security, nor sending or storing information for others. That is the case of Note 4 to Category 5, Part 2 of the US EAR (its "except in support of entertainment" wording), and Apple's exempt case of encryption built into the operating system. So no export documentation is uploaded, and no year-end self-classification report is filed for it. Not a secure-communications app in the sense of France's ANSSI controls either. Revisit when the apps start to bring their own implementation of an algorithm, or when encryption becomes a feature in itself (an encrypted vault, messages to others).

**The new-version notice** (D-047) asks Apple's lookup by bundle id (`itunes.apple.com/lookup?bundleId=mt.sil.lobby`), so it needs no App Store id in the code; the answer carries it.

**What the Mac sandbox allows** (`com.apple.security.*` in `project.yml`): `app-sandbox`; `network.client` (Lobby Server, the introducer, Apple's lookup); `network.server` (the app's own server on 127.0.0.1 for the player over the direct connection, and the Apple TV hand-over listener; local connections only); `files.user-selected.read-only` (uploads: files and folders a manager picks or drops, read while the app is open; the Mac reads by path and keeps no bookmark, so no bookmark entitlement); `personal-information.location` (a kids viewer's places). Downloads stay inside the app's container, so no Downloads folder access. Bonjour browsing needs nothing beyond `network.client`.
