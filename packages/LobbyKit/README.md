# LobbyKit

The Swift package the iPhone, iPad, Mac and Apple TV apps share to talk to Lobby Server and to keep working when it is unreachable. No UI and no third-party Swift packages. Swift 6, iOS 18, macOS 15, tvOS 18.

Three targets: `LobbyKit` (the client, caches and stores below), `LobbyDirect` (the app's end of the direct connection: what is said, finding the path, QUIC, a local server for AVPlayer; [`docs/outside.md`](../../docs/outside.md)) and `CLobbyIce`, which holds [libjuice](https://github.com/paullouisageneau/libjuice) 1.7.5 vendored unchanged (MPL-2.0, its own `LICENSE`; see [`NOTICE.md`](../../NOTICE.md)) and a small C bridge to a socket on the device.

Licensed under MPL-2.0, as the rest of Lobby ([`LICENSE`](../../LICENSE)).

It implements [`docs/api.md`](../../docs/api.md). Change that page, the server and this package together.

## What is in it

| Area | Types | Notes |
| --- | --- | --- |
| Models | `Item`, `MediaFile`, `Device`, `Profile`, `PlaybackProgress`, … | Instants are `Date` in Swift and integer milliseconds in JSON (`LobbyJSON`). Enums are open: a value from a newer server decodes to `.unknown("…")`. |
| Client | `LobbyClient`, `LobbyError` | A `Sendable` value over `URLSession`. Typed errors: `.unreachable`, `.deviceRevoked`, `.unauthorized`, `.forbidden`, `.conflict(progress:)` and the rest of the API's codes. |
| Credentials | `CredentialStore`, `KeychainCredentialStore`, `InMemoryCredentialStore`, `ConnectionPreferences` | The token is in the Keychain, keyed by server id. The server address, device id and chosen viewer are preferences. |
| Catalogue | `Catalogue`, `CatalogueStore` | The device's copy of the library, kept up to date with `GET /v1/library`. |
| Shelves | `Shelves`, `EpisodeOrder` | Pure functions: Continue Watching, Recently Added, Movies, Series, Categories, search, next episode. |
| Progress | `ProgressStore` | Progress per viewer and the queue of changes that have not reached the server. |
| Downloads | `DownloadManager`, `DownloadRecord` | Films and episodes kept on the device: queue, transfers that pause and continue, verification, stale flags. |
| Playback | `PlaybackPlanner`, `DeviceCapabilities`, `Playback` | Direct, needs prepared playback, or not playable and why. `LobbyClient.playback(assetID:)` asks the server how to play a file now. |
| Direct (`LobbyDirect`) | `ServerRoad`, `PairingInvitation`, `LoopbackServer`, … | Reaching the server from outside without an open port: introducer, ICE (libjuice), QUIC, and a loopback server that AVPlayer plays from. |

`PlaybackProgress` is `Progress` in the API. It has another name here because Foundation has a `Progress` too, and every app file imports Foundation.

## Using it

```swift
let directory = try LobbyStorage.defaultDirectory()
let catalogueStore = CatalogueStore(fileURL: LobbyStorage.catalogueFile(in: directory))
let progressStore = ProgressStore(fileURL: LobbyStorage.progressFile(in: directory))
let credentials = KeychainCredentialStore(service: "mt.sil.lobby")

// Connect and pair.
let anonymous = try LobbyClient(baseURL: address)
let server = try await anonymous.serverInfo()
let request = try await anonymous.requestPairing(deviceName: "Living room Apple TV", platform: .tvos)
// Show request.code. A manager approves it.
let grant = try await anonymous.awaitPairingApproval(of: request)
try await credentials.setToken(grant.token, forServer: server.id)
let client = anonymous.authenticated(with: grant.token)

// Shelves: from the file first, then from the server when it answers.
var catalogue = await catalogueStore.catalogue()
do {
    catalogue = try await catalogueStore.sync(using: client)
    try await progressStore.synchronise(profileID: profile.id, using: client)
} catch let error as LobbyError where error.isUnreachable {
    // Offline: keep showing what is cached.
} catch let error as LobbyError where error.requiresPairing {
    // .deviceRevoked or .unauthorized: back to the Connect screen.
}
let progress = await progressStore.progress(profileID: profile.id)
let continueWatching = Shelves.continueWatching(in: catalogue, progress: progress)

// Playback. Ask first, play what comes back. The token goes in the cookie, never in the URL.
let playback = try await client.playback(assetID: file.assetId)   // again each second while streamURL is nil
let asset = AVURLAsset(
    url: playback.streamURL!,
    options: [AVURLAssetHTTPCookiesKey: [client.deviceCookie()!]])
try await progressStore.record(profileID: profile.id, itemID: item.id, positionMs: 61_000, durationMs: 5_400_000, completed: false)
try await progressStore.flush(using: client)
```

Call `ProgressStore.flush(using:)` when the app comes to the foreground, when the server becomes reachable, and when playback pauses or ends. The store has no timer of its own.

## Decisions

### The catalogue is one JSON file, not SQLite

`CatalogueStore` is an actor that holds the catalogue in memory and writes it to one versioned JSON file, atomically, at the end of each sync.

- Every shelf reads the whole catalogue (Continue Watching and Recently Added walk shows, seasons and episodes), so it has to be in memory anyway. A database would be read into the same dictionary at launch.
- Writes are rare: once per sync, never per row.
- The real size is about 4,000 items with their files. `aCatalogueOfTheRealSizeSavesAndLoads` syncs, saves and loads that many in about half a second in a debug build.
- An atomic file write cannot leave half a catalogue behind. The file is a cache: a missing, damaged or newer-format file costs one full fetch and nothing else.

Move to SQLite when a single screen needs a query it cannot afford to run over the dictionary, or the catalogue grows by an order of magnitude. `Catalogue` is the only type shelves see, so the store can change behind it.

### Sync rules

- No cursor: full fetch, page by page. Each page is applied with its cursor, so a fetch that breaks off continues where it stopped.
- `removed`: the item goes, with everything below it.
- `reset: true`: the pages that follow are collected apart and replace the local copy only when `more` is false. If that fetch breaks off, the old catalogue and the old cursor stay, and the next sync starts over.

### Progress queue

- Each change gets a fresh operation id and is written to the file before it is sent. Retries reuse the id.
- A change that was never sent is replaced by a newer one for the same viewer and item. A change that was sent, with the answer unknown, is kept and the newer one queues behind it.
- `baseRevision` is the revision the device had seen when the viewer made the change, and is never updated afterwards. That is what lets the server tell a stale offline change from a fresh one.
- `409 conflict`: the server's progress replaces the local one and the change is dropped.
- Unreachable, 5xx, `unavailable`, `rate_limited`: the flush stops and the queue waits. `unauthorized` and `device_revoked` stop it too and keep the queue for after pairing again.
- Any other refusal (`not_found`, `invalid_request`, `forbidden`) can never succeed. The change is dropped and reported in `ProgressFlushResult.rejected`.
- A progress file this build cannot read is moved to `progress.json.unreadable`, not overwritten.

### File formats

Both files carry `"version": 1` and store instants as integer milliseconds since the Unix epoch, UTC. To change a format: raise `formatVersion` and add the older shape to `migrate(version:data:)` in the same change.

### Playback

`LobbyClient.playback(assetID:)` is `POST /v1/assets/{id}/playback`. The apps ask it for every file, direct or not, and play the `streamURL` it returns (`docs/playback.md`, "What the Apple apps must do"). While a copy is being written the answer is `202`, which the client treats like any other success: `state` says where things are, and `Playback.canStart(atMs:)` says whether the stream reaches a resume position yet. The types are in `Sources/LobbyKit/Client/Playback.swift`.

### Downloads

`DownloadManager` is an actor that owns one folder (`LobbyStorage.downloadsDirectory(in:)`) and one `URLSession`. The apps give it a background session configuration, so the system carries a transfer on while the app is not running; call `start(using:)` at launch and `handleBackgroundEvents(completion:)` from the app delegate.

- A download asks `POST …/playback` until `state` is `ready`, checks free space, fetches `downloadUrl`, and accepts the body only if the HTTP status, the length (`downloadBytes`) and the `ETag` (the revision) agree. Then it moves it into place in one step as `<revision>.mp4` and fetches the text subtitles as `.vtt` beside it.
- Pause, a broken connection and a relaunch keep what arrived (`URLSession` resume data) and continue with `Range` and `If-Range`. One automatic retry; after that the record is `failed` and Try Again continues from the same place.
- Another revision on the server discards a partial transfer. A finished copy of an older revision stays, and stays playable, until its replacement is verified.
- `reconcile(with:)` compares the copies with a freshly synced catalogue and sets `staleness` (`changedOnServer`, `removedFromServer`). A stale copy is never reported as verified and current. Nothing is deleted without the viewer.
- With the server out of reach a queued download waits (`isWaitingForNetwork`); `retryWaiting()` tries again.
- Not for Apple TV: tvOS has no durable storage for it.

`DownloadManagerTests` runs the engine against `LocalHTTPServer`, a small HTTP server on a real local socket, because `URLSession` only produces resume data and `Range` requests against a real connection.

### Artwork

Artwork URLs and widths are in `Sources/LobbyKit/Client/Artwork.swift`.

### Storage on Apple TV

tvOS gives an app no durable local storage. `LobbyStorage.defaultDirectory()` uses Caches there, which the system may empty while the app is not running: the catalogue is then fetched again, and progress that had not reached the server is lost.

## Tests

```sh
cd packages/LobbyKit
swift build
swift test
xcodebuild build -scheme LobbyKit -destination 'generic/platform=iOS Simulator'
xcodebuild build -scheme LobbyKit -destination 'generic/platform=tvOS Simulator'
```

The network in unit tests is a `URLProtocol` stub (`Tests/LobbyKitTests/Support/StubServer.swift`). The client, the cache, the queue and, on macOS, the Keychain are the real ones.

`xcodebuild` needs the tvOS platform installed in Xcode (Settings → Components). Without it, this compiles the package against the tvOS SDK:

```sh
swift build --triple arm64-apple-tvos18.0-simulator --sdk "$(xcrun --sdk appletvsimulator --show-sdk-path)"
```

### Against a real server

`IntegrationTests` claims a server, pairs a second device, syncs, round-trips progress through a conflict, reads a byte range, and revokes a device. It is skipped unless both variables are set. The server must be unclaimed (an empty data folder) and have at least one film or episode.

```sh
# A config outside the repo, with "dataDir", "port", "stabilityMs": 100 and "roots" pointing at a folder of test media.
cd apps/server
node src/cli.ts scan --config /path/to/lobby.config.json
node src/cli.ts serve --config /path/to/lobby.config.json &

cd ../../packages/LobbyKit
LOBBY_TEST_SERVER_URL=http://127.0.0.1:8674 \
LOBBY_TEST_SETUP_SECRET="$(cd ../../apps/server && node src/cli.ts setup-secret --config /path/to/lobby.config.json)" \
swift test --filter IntegrationTests
```

### Captured responses

`Tests/LobbyKitTests/Captured/*.json` are answers from the real server, saved with `curl` and not edited. `CapturedResponseTests` decodes them. They contain no token. Capture them again when the server's output changes.
