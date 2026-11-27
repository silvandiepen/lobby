// SPDX-License-Identifier: MPL-2.0
#if os(macOS)
import AVFoundation
import Foundation
import Testing

@testable import LobbyDirect
@testable import LobbyKit

/// A film that is prepared while it plays, at home: the stream grows and the copy is finished
/// under the player, which goes on as it was (`PlayerModel.copyIsComplete`).
extension EndToEndTests {
    @MainActor
    private final class Watching {
        let player = AVPlayer()
        private(set) var longestStall = Duration.zero
        private var last = 0.0
        private var since = ContinuousClock.now

        func open(_ url: URL, cookie: HTTPCookie?) async throws {
            let item = AVPlayerItem(asset: AVURLAsset(url: url, options: cookie.map { [AVURLAssetHTTPCookiesKey: [$0]] }))
            player.isMuted = true
            player.replaceCurrentItem(with: item)
            for _ in 0..<600 where item.status == .unknown { try await Task.sleep(for: .milliseconds(50)) }
            if let error = item.error { throw error }
            player.play()
        }

        /// One look: how far it came, and the longest time it stood still.
        func look() {
            let now = player.currentTime().seconds
            if now > last + 0.01 {
                last = now
                since = .now
            } else {
                longestStall = max(longestStall, ContinuousClock.now - since)
            }
        }

        var position: Double { player.currentTime().seconds }
    }

    @Test @MainActor func aCopyThatIsFinishedWhilePlayingGoesOnWithoutAStall() async throws {
        // As on the Pi: the copy is written a few times faster than the film plays.
        let h = try await Harness(prepareSpeed: 8)
        let home = try await h.home()
        let paired: Harness.Paired = try await h.ask("pair", ["name": "Apple TV", "outside": false])
        struct Playable: Decodable { var asset: String; var bytes: Int }
        let film: Playable = try await h.ask("playable", ["seconds": 240, "mbit": 2, "container": "mkv"])
        let client = try LobbyClient(baseURL: home, token: paired.token)
        var playback = try await client.playback(assetID: film.asset)
        while playback.streamURL == nil {
            try await Task.sleep(for: .milliseconds(500))
            playback = try await client.playback(assetID: film.asset)
        }
        #expect(playback.state == .preparing)
        let watching = Watching()
        try await watching.open(try #require(playback.streamURL), cookie: client.deviceCookie())
        // Playing the growing copy until the server says it is finished.
        while playback.state != .ready {
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(100))
                watching.look()
            }
            playback = try await client.playback(assetID: film.asset)
        }
        // The same item learns that the stream has ended, at its next look at the playlist, and
        // turns into a film of known length: nothing has to be opened again.
        let finished = ContinuousClock.now
        var length: Double?
        while length == nil, ContinuousClock.now - finished < .seconds(30) {
            try await Task.sleep(for: .milliseconds(100))
            watching.look()
            let duration = watching.player.currentItem?.duration ?? .indefinite
            if duration.isNumeric { length = duration.seconds }
        }
        let learned = ContinuousClock.now - finished
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            watching.look()
        }
        print("MEASURED a copy finished while playing: its length known to the same item \(learned) later, \(length ?? 0) s, longest stall \(watching.longestStall)")
        #expect(abs((length ?? 0) - 240) < 1)
        #expect(watching.longestStall < .seconds(2))
        watching.player.replaceCurrentItem(with: nil)
        await h.stop()
    }
}
#endif
