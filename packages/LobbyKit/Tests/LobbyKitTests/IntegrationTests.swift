// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing

@testable import LobbyKit

/// Runs against a real Lobby Server. Skipped unless both variables are set:
///
///     LOBBY_TEST_SERVER_URL=http://127.0.0.1:8674
///     LOBBY_TEST_SETUP_SECRET=<what `lobby setup-secret` prints>
///
/// The server must be freshly started with an empty data folder (the test claims it) and have
/// at least one film or episode in its library. See the package README for the commands.
enum IntegrationEnvironment {
    static let serverURL = ProcessInfo.processInfo.environment["LOBBY_TEST_SERVER_URL"].flatMap(URL.init(string:))
    static let setupSecret = ProcessInfo.processInfo.environment["LOBBY_TEST_SETUP_SECRET"]
    static var isConfigured: Bool { serverURL != nil && setupSecret?.isEmpty == false }
}

@Suite(.enabled(if: IntegrationEnvironment.isConfigured, "Set LOBBY_TEST_SERVER_URL and LOBBY_TEST_SETUP_SECRET to run against a real server."))
struct IntegrationTests {
    @Test func claimsPairsSyncsAndRoundTripsProgress() async throws {
        let serverURL = try #require(IntegrationEnvironment.serverURL)
        let setupSecret = try #require(IntegrationEnvironment.setupSecret)
        let directory = try TemporaryDirectory()
        let anonymous = try LobbyClient(baseURL: serverURL, session: URLSession(configuration: .ephemeral))

        // Connect screen, then the first manager claims the server.
        let info = try await anonymous.serverInfo()
        #expect(info.apiVersion == 1)
        try #require(!info.claimed, "The server is already claimed. Start it with an empty data folder.")

        await #expect(throws: LobbyError.self) {
            try await anonymous.claim(setupSecret: "not-the-secret", deviceName: "Intruder", platform: .cli)
        }
        let managerGrant = try await anonymous.claim(setupSecret: setupSecret, deviceName: "LobbyKit test Mac", platform: .macos)
        #expect(managerGrant.device.role == .manager)
        let manager = anonymous.authenticated(with: managerGrant.token)

        let me = try await manager.me()
        #expect(me.device.id == managerGrant.device.id)
        #expect(me.server.claimed)
        #expect(me.server.id == info.id)

        // No credential, and a credential the server never issued.
        let withoutCredential = await #expect(throws: LobbyError.self) { try await anonymous.profiles() }
        #expect(withoutCredential?.requiresPairing == true)
        let stranger = await #expect(throws: LobbyError.self) {
            try await anonymous.authenticated(with: "not-a-token").profiles()
        }
        #expect(stranger?.requiresPairing == true)

        // A second device pairs with a code the manager approves.
        let request = try await anonymous.requestPairing(deviceName: "LobbyKit test Apple TV", platform: .tvos)
        #expect(request.code.count == 6)
        #expect(request.expiresAt > Date())
        guard case .pending = try await anonymous.collectPairing(request) else {
            Issue.record("An unapproved request should be pending")
            return
        }
        let waiting = try await manager.pendingPairingRequests()
        #expect(waiting.contains { $0.id == request.id && $0.platform == .tvos })

        let approval = try await manager.approvePairing(code: request.code, role: .viewer)
        #expect(approval.deviceName == "LobbyKit test Apple TV")
        #expect(approval.role == .viewer)

        let viewerGrant = try await anonymous.awaitPairingApproval(of: request, sleep: { _ in })
        #expect(viewerGrant.device.role == .viewer)
        #expect(viewerGrant.device.platform == .tvos)
        let viewer = anonymous.authenticated(with: viewerGrant.token)
        #expect(try await viewer.me().device.id == viewerGrant.device.id)

        // The token is handed out exactly once.
        let collectedTwice = await #expect(throws: LobbyError.self) { try await anonymous.collectPairing(request) }
        guard case .gone = collectedTwice else {
            Issue.record("A second collect should be gone, got \(String(describing: collectedTwice))")
            return
        }

        // Roles are enforced by the server.
        let forbidden = await #expect(throws: LobbyError.self) { try await viewer.devices() }
        guard case .forbidden = forbidden else {
            Issue.record("A viewer listing devices should be forbidden, got \(String(describing: forbidden))")
            return
        }
        let devices = try await manager.devices()
        #expect(devices.currentDeviceId == managerGrant.device.id)
        #expect(Set(devices.devices.map(\.id)).isSuperset(of: [managerGrant.device.id, viewerGrant.device.id]))
        _ = try await manager.status()

        // Profiles.
        let profile = try await manager.createProfile(name: "Robin", color: "teal")
        #expect(try await viewer.profiles().contains(profile))
        #expect(try await manager.updateProfile(id: profile.id, color: "pink").color == "pink")

        // Catalogue sync, paged, then incremental, then from the file alone.
        let store = CatalogueStore(fileURL: directory.file("catalogue.json"))
        let catalogue = try await store.sync(using: viewer, pageSize: 2)
        try #require(!catalogue.isEmpty, "The server's library is empty. Give it at least one film.")
        #expect(try await store.sync(using: viewer) == catalogue)
        #expect(await CatalogueStore(fileURL: directory.file("catalogue.json")).catalogue() == catalogue)

        let playable = try #require(
            catalogue.items.sorted { $0.id < $1.id }.first { $0.kind == .movie || $0.kind == .episode },
            "The library has no film or episode.")
        let detail = try await viewer.item(id: playable.id)
        #expect(detail.item == playable)
        let missing = await #expect(throws: LobbyError.self) { try await viewer.item(id: "no-such-item") }
        guard case .notFound = missing else {
            Issue.record("An unknown item should be not found, got \(String(describing: missing))")
            return
        }
        // Shelves build from what the real server sent.
        #expect(!Shelves.recentlyAdded(in: catalogue).isEmpty)

        // Progress: recorded on one device, flushed, and seen by another.
        // The viewer's clock, an hour back so that every change below is in the past: the server
        // clamps a future `updatedAt` to its own clock, which would reorder them.
        let clock = TestClock(Date().addingTimeInterval(-3600))
        let appleTV = ProgressStore(fileURL: directory.file("progress-tv.json"), now: { clock.now })
        try await appleTV.record(profileID: profile.id, itemID: playable.id, positionMs: 61_000, durationMs: 120_000, completed: false)
        let sent = try await appleTV.flush(using: viewer)
        #expect(sent.accepted == 1)
        #expect(sent.remaining == 0)
        let accepted = try #require(await appleTV.progress(profileID: profile.id, itemID: playable.id))
        #expect(accepted.positionMs == 61_000)
        #expect(accepted.revision > 0)

        let mac = ProgressStore(fileURL: directory.file("progress-mac.json"), now: { clock.now })
        try await mac.refresh(profileID: profile.id, using: manager)
        #expect(await mac.progress(profileID: profile.id, itemID: playable.id) == accepted)
        #expect(Shelves.continueWatching(in: catalogue, progress: await mac.progress(profileID: profile.id)).contains { $0.item.id == playable.id })

        // A retry of the same operation is answered the same way and changes nothing.
        let update = ProgressUpdate(
            opId: UUID().uuidString.lowercased(), baseRevision: accepted.revision, positionMs: 70_000,
            durationMs: 120_000, completed: false, updatedAt: clock.now.addingTimeInterval(1))
        let first = try await viewer.putProgress(profileID: profile.id, itemID: playable.id, update: update)
        let retried = try await viewer.putProgress(profileID: profile.id, itemID: playable.id, update: update)
        #expect(first == retried)

        // The Mac marks it unwatched now. The Apple TV, which has not heard, comes back with an
        // older position: the server answers 409 and the queue takes the server's progress.
        clock.advance(by: 10)
        try await appleTV.record(profileID: profile.id, itemID: playable.id, positionMs: 90_000, durationMs: 120_000, completed: false)
        clock.advance(by: 10)
        try await mac.refresh(profileID: profile.id, using: manager)
        try await mac.markUnwatched(profileID: profile.id, itemID: playable.id)
        #expect(try await mac.flush(using: manager).accepted == 1)

        let stale = try await appleTV.flush(using: viewer)
        #expect(stale.conflicts == 1)
        #expect(stale.remaining == 0)
        let reconciled = try #require(await appleTV.progress(profileID: profile.id, itemID: playable.id))
        #expect(reconciled.positionMs == 0)
        #expect(!reconciled.completed)
        #expect(reconciled == (await mac.progress(profileID: profile.id, itemID: playable.id)))

        // Media: the token goes in a header or the cookie, and byte ranges work.
        if let file = playable.mainFiles.first(where: \.available) {
            var range = viewer.authorizedRequest(for: viewer.mediaURL(assetID: file.assetId))
            range.setValue("bytes=0-99", forHTTPHeaderField: "Range")
            let (bytes, response) = try await URLSession(configuration: .ephemeral).data(for: range)
            #expect((response as? HTTPURLResponse)?.statusCode == 206)
            #expect(bytes.count == 100)

            let cookie = try #require(viewer.deviceCookie())
            var byCookie = URLRequest(url: viewer.mediaURL(assetID: file.assetId))
            byCookie.httpMethod = "HEAD"
            byCookie.setValue("\(cookie.name)=\(cookie.value)", forHTTPHeaderField: "Cookie")
            let (_, cookieResponse) = try await URLSession(configuration: .ephemeral).data(for: byCookie)
            #expect((cookieResponse as? HTTPURLResponse)?.statusCode == 200)
            #expect((cookieResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag") == "\"\(file.revision)\"")
        }

        // Revoking the Apple TV: its next request says so, and its queue keeps what it had.
        try await appleTV.record(profileID: profile.id, itemID: playable.id, positionMs: 5_000, durationMs: 120_000, completed: false)
        try await manager.revokeDevice(id: viewerGrant.device.id)
        let revoked = await #expect(throws: LobbyError.self) { try await viewer.profiles() }
        guard case .deviceRevoked = revoked else {
            Issue.record("A revoked device should be told so, got \(String(describing: revoked))")
            return
        }
        let afterRevoke = try await appleTV.flush(using: viewer)
        #expect(afterRevoke.remaining == 1)
        guard case .deviceRevoked = afterRevoke.stoppedBy else {
            Issue.record("The flush should stop on the revoked device, got \(String(describing: afterRevoke.stoppedBy))")
            return
        }
        // The last manager cannot be removed.
        let lastManager = await #expect(throws: LobbyError.self) { try await manager.revokeDevice(id: managerGrant.device.id) }
        guard case .conflict(_, nil) = lastManager else {
            Issue.record("Removing the last manager should conflict, got \(String(describing: lastManager))")
            return
        }

        try await manager.deleteProfile(id: profile.id)
        #expect(try await manager.profiles().contains { $0.id == profile.id } == false)
    }
}
