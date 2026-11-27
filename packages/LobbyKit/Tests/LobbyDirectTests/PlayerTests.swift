// SPDX-License-Identifier: MPL-2.0
#if os(macOS)
import AVFoundation
import Foundation
import Testing

@testable import LobbyDirect
@testable import LobbyKit

/// The system's player over the app's local server.
extension EndToEndTests {
    private struct Playable: Decodable { var asset: String; var bytes: Int }

    @MainActor
    private final class Watching {
        let player = AVPlayer()
        private(set) var longestStall = Duration.zero

        func open(_ url: URL, cookie: HTTPCookie?) async throws {
            let asset = AVURLAsset(url: url, options: cookie.map { [AVURLAssetHTTPCookiesKey: [$0]] })
            let item = AVPlayerItem(asset: asset)
            player.isMuted = true
            player.replaceCurrentItem(with: item)
            player.play()
            try await wait("ready") { item.status != .unknown }
            if let error = item.error { throw error }
        }

        func wait(_ what: String, _ check: () -> Bool) async throws {
            for _ in 0..<600 {
                if check() { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw Harness.Problem(text: "\(what) did not happen")
        }

        /// Watches for a while and says how far the film came.
        func watch(_ seconds: Double) async throws -> Double {
            let from = player.currentTime().seconds
            var last = from, since = ContinuousClock.now
            for _ in 0..<Int(seconds * 20) {
                try await Task.sleep(for: .milliseconds(50))
                let now = player.currentTime().seconds
                if now > last + 0.01 {
                    last = now
                    since = .now
                } else {
                    longestStall = max(longestStall, ContinuousClock.now - since)
                }
            }
            return last - from
        }

        func jump(to seconds: Double) async throws -> Duration {
            let began = ContinuousClock.now
            await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            try await wait("playing again") { player.currentTime().seconds > seconds + 0.05 }
            return ContinuousClock.now - began
        }
    }

    @Test @MainActor func thePlayerGoesOnWhenTheNetworkChanges() async throws {
        let h = try await Harness()
        let home = try await h.home()
        let (paired, identity) = try await h.device("Far phone", at: home)
        let film: Playable = try await h.ask("playable", ["seconds": 100])
        let wifi = try await h.road(oneWayMs: 20, mbit: 20, queueMs: 100), mobile = try await h.road(oneWayMs: 35, mbit: 20, queueMs: 100)
        let link = DirectLink(detours: Roads([wifi, mobile]).detours)
        await link.use(identity, token: paired.token)
        _ = try await link.connect()
        let server = try await LoopbackServer.start(link: link)
        let client = try LobbyClient(baseURL: server.base, token: paired.token, isCarriedByRoad: true)
        let stream = try #require(try await client.playback(assetID: film.asset).streamURL)
        #expect(stream.absoluteString.hasPrefix(server.base.absoluteString + "/v1/"))

        let watching = Watching()
        let began = ContinuousClock.now
        try await watching.open(stream, cookie: client.deviceCookie())
        try await watching.wait("the first picture") { watching.player.currentTime().seconds > 0.05 }
        print("MEASURED the player's first picture after \(ContinuousClock.now - began)")
        _ = try await watching.watch(3)
        try await h.say("roadDown", ["road": wifi.road])
        await link.networkChanged()
        // Far beyond what it had: this comes over the new road.
        let jump = try await watching.jump(to: 70)
        let came = try await watching.watch(6)
        print("MEASURED after the network changed: a jump of the player took \(jump), longest stall \(watching.longestStall)")
        #expect(came > 3)
        #expect(watching.player.currentItem?.status == .readyToPlay)

        // Jumps, and what they waste: bytes over the road against the film's.
        let before: Harness.Counts = try await h.ask("roadCounts", ["road": mobile.road])
        var jumps: [Duration] = []
        for place in [10.0, 85, 35, 55, 20] {
            jumps.append(try await watching.jump(to: place))
            try await Task.sleep(for: .seconds(1))
        }
        let after: Harness.Counts = try await h.ask("roadCounts", ["road": mobile.road])
        print("MEASURED five jumps of the player at 20 Mbit/s, 70 ms: \(jumps), \(after.toDevice - before.toDevice) bytes of a film of \(film.bytes)")
        #expect(jumps.allSatisfy { $0 < .seconds(6) })
        watching.player.replaceCurrentItem(with: nil)
        server.stop()
        await link.stop()
        await h.stop()
    }

    /// At home the credential goes to the player as a cookie no script may read.
    @Test @MainActor func atHomeThePlayerTakesTheCookie() async throws {
        let h = try await Harness()
        let home = try await h.home()
        let paired: Harness.Paired = try await h.ask("pair", ["name": "Phone", "outside": false])
        let film: Playable = try await h.ask("playable", ["seconds": 4])
        let client = try LobbyClient(baseURL: home, token: paired.token)
        let cookie = try #require(client.deviceCookie())
        #expect(cookie.isHTTPOnly)
        let watching = Watching()
        try await watching.open(client.mediaURL(assetID: film.asset), cookie: cookie)
        #expect(try await watching.watch(1.5) > 0.2)
        watching.player.replaceCurrentItem(with: nil)
        await h.stop()
    }
}
#endif
