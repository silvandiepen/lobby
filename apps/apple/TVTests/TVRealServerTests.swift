// SPDX-License-Identifier: MPL-2.0
import AVFoundation
import Foundation
import LobbyKit
import Testing

@testable import Lobby

/// The Apple TV's way through the app against a real Lobby Server on this Mac, with the real
/// player: `Scripts/ui-test-server.sh start` first. Skipped when none is running.
@MainActor
@Suite(.serialized, .enabled(if: TVRealServer.server != nil, "Run Scripts/ui-test-server.sh start first."))
struct TVRealServerTests {
    @Test func pairAsAnAppleTVThenPlayAConvertedFilmResumeAndCloseAtOnce() async throws {
        let server = try #require(TVRealServer.server)
        let test = try TestApp()
        var environment = test.environment
        environment.keepsDownloads = false
        environment.session = .shared
        environment.device = DeviceIdentity(name: "Apple TV", platform: .tvos)
        environment.locateGrace = {}
        environment.sleep = { try await Task.sleep(for: $0) }

        // Typed address, code, approval by a manager elsewhere.
        var app = AppModel(environment: environment)
        await app.start()
        let connect = ConnectModel(app: app)
        connect.enterAddress()
        connect.addressText = server.url.absoluteString
        await connect.findServer()
        await connect.requestCode()
        guard case .code(let request, _) = connect.step else {
            Issue.record("No code: \(String(describing: connect.problem))")
            return
        }
        let manager = try LobbyClient(baseURL: server.url, token: server.managerToken)
        _ = try await manager.approvePairing(code: request.code, role: .viewer)
        await connect.waitUntilPaired()
        #expect(app.phase == .chooseProfile)
        #expect(app.device?.platform == .tvos)

        // A new start finds the credential and the library.
        app = AppModel(environment: environment)
        await app.start()
        await app.selectProfile(try #require(app.profiles.first { $0.name == "Guest" }))
        let film = try #require(app.shelves.movies.first { $0.title == "Old Format" })
        // From the start, also when an earlier run watched some of it.
        await app.markUnwatched(itemID: film.id)
        try await play(film, in: app, until: 7)

        // Closed: the position is there, and playing again resumes from it.
        guard case .inProgress = app.movieDetail(for: film).watch else {
            Issue.record("Nothing was kept of what was watched.")
            return
        }
        let again = try #require(app.movieDetail(for: film).action.request)
        #expect(again.startPositionMs >= 5_000)
        try await play(film, in: app, until: Double(again.startPositionMs) / 1000 + 2, retriesOnce: true)

        // The server has it too.
        let profile = try #require(app.activeProfile)
        let kept = await environment.progressStore.progress(profileID: profile.id, itemID: film.id)
        #expect((kept?.revision ?? 0) > 0)
        await app.signOut()
        for device in try await manager.devices().devices where device.name == "Apple TV" && device.revokedAt == nil {
            try await manager.revokeDevice(id: device.id)
        }
    }

    private func play(_ film: Item, in app: AppModel, until seconds: Double, retriesOnce: Bool = false) async throws {
        app.play(try #require(app.movieDetail(for: film).action.request))
        let player = try #require(app.player)
        player.player.isMuted = true
        if retriesOnce {
            try await reach(seconds - 1, player)
            // As from the Try Again button: on from here, not from the start.
            player.tryAgain()
        }
        try await reach(seconds, player)
        await player.close()
        #expect(app.player == nil)
    }

    private func reach(_ seconds: Double, _ player: PlayerModel) async throws {
        for _ in 0..<300 {
            if player.hasStarted, player.stage == .playing, player.player.currentTime().seconds >= seconds { return }
            if case .failed(let why) = player.stage {
                Issue.record("Playback failed: \(why)")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("The film did not get to \(seconds) s: \(player.stage)")
    }
}

/// What `ui-test-server.sh` wrote down.
struct TVRealServer: Decodable {
    var url: URL
    var managerToken: String

    static let server: TVRealServer? = {
        struct File: Decodable { var paired: TVRealServer }
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/ui-test-server/server.json")
        return (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(File.self, from: $0).paired }
    }()
}
