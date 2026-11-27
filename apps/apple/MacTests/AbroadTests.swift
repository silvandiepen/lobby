// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Synchronization
import Testing

@testable import Lobby
@testable import LobbyDirect

/// The app's own model abroad, against the real server, introducer and lobby-direct of this repository.
@MainActor
@Suite(.serialized, .enabled(if: Harness.isThere, "SKIPPED: apps/direct is not built, or there is no node here."))
struct AbroadTests {
    private struct Requests: Decodable { var requests: [OutsideStatus.Request] }
    private struct Profiles: Decodable { var profiles: [Profile] }
    private struct Playable: Decodable { var asset: String; var bytes: Int }

    /// A new device that was never at home: pairs with the code, sees the library, plays a film through
    /// a change of network, and comes back without pairing again.
    @Test func aDeviceThatWasNeverAtHome() async throws {
        let h = try await Harness()
        let home = try await h.home()
        let manager: Harness.Paired = try await h.ask("manager")
        let profile = try await LobbyClient(baseURL: home, token: manager.token).createProfile(name: "Guest", color: "teal")
        let film: Playable = try await h.ask("playable", ["seconds": 80])
        let hotel = try await h.road(oneWayMs: 20, mbit: 16, queueMs: 100), mobile = try await h.road(oneWayMs: 35, mbit: 16, queueMs: 100)
        try await h.say("closeHome")

        let test = try TestApp(Household(.init()))
        let suite = "lobby.abroad.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let link = DirectLink(detours: Roads([hotel, mobile]).detours)
        test.environment.session = .shared
        test.environment.sleep = { try await Task.sleep(for: $0) }
        test.environment.road = ServerRoad(
            credentials: test.credentials, link: link, memory: RoadMemory(suiteName: suite),
            headStart: .milliseconds(200))
        let app = test.launch()
        await app.start()
        let watching = Task { await app.watchRoad() }
        defer { watching.cancel() }

        // Connect, as a person does it.
        let window: OutsideWindow = try await h.ask("window")
        let connect = ConnectModel(app: app)
        connect.chooseOutside()
        connect.useInvitation(try #require(window.invitation).link)
        await connect.pairOutside()
        guard case .outsideDigits(let waiting) = connect.step else {
            Issue.record("no digits: \(String(describing: connect.problem))")
            return await h.stop()
        }
        let asked: Requests = try await h.ask("requests")
        let request = try #require(asked.requests.first)
        #expect(request.comparison == waiting.comparison)
        try await h.say("approve", ["id": request.id, "comparison": waiting.comparison])
        try await until("paired") { app.phase == .chooseProfile || connect.problem != nil }
        #expect(connect.problem == nil)
        #expect(app.problem == nil)
        #expect(app.road == .direct)
        #expect(app.roadText == "Direct")
        #expect(app.hasDirect)
        try await until("the library") { app.hasLibraryCopy && !app.isRefreshing }
        #expect(await !app.hasOutsidePairing())
        #expect(app.profiles.map(\.name) == ["Guest"])
        await app.selectProfile(profile)
        let item = try #require(app.catalogue.items.first { $0.files.contains { $0.assetId == film.asset } })
        // Managing is for home, and says so.
        await #expect(throws: LobbyError.self) { try await app.asManager { try await $0.devices() } }

        // A film, and another network in the middle of it.
        let play = try #require(app.movieDetail(for: item).action.request)
        app.play(play)
        let player = try #require(app.player)
        player.player.isMuted = true
        try await until("the film") { player.player.currentTime().seconds > 1 }
        #expect(!player.player.allowsExternalPlayback)
        try await h.say("roadDown", ["road": hotel.road])
        await link.networkChanged()
        await player.player.seek(to: .init(seconds: 60, preferredTimescale: 600))
        player.player.play()
        try await until("the film on the other network") { player.player.currentTime().seconds > 62 }
        #expect(player.stage == .playing)
        await player.close()

        // Opened again: no pairing, the same road. The network it was paired over is gone.
        let later = test.launch()
        await later.start()
        #expect(later.phase == .library)
        #expect(later.connectivity == .online)
        #expect(later.road == .direct)

        // Switched off by the person, and on again.
        await later.setUsesDirect(false)
        #expect(later.roadText == "Offline")
        await later.setUsesDirect(true)
        #expect(later.roadText == "Direct")

        // No longer let in: the app says why, keeps its credential, and does not ring on and on.
        try await h.say("allow", ["id": try #require(later.device).id, "allow": false])
        try await until("the end of the connection") {
            if case .up = await link.state { false } else { true }
        }
        await later.refresh()
        #expect(later.roadText == "Offline")
        #expect(later.phase == .library)
        #expect(await link.state == .down(.notAllowed))
        await link.stop()
        await h.stop()
    }

    private func until(_ what: String, _ check: () async -> Bool) async throws {
        for _ in 0..<800 {
            if await check() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Harness.Problem(text: "\(what) did not happen")
    }
}
