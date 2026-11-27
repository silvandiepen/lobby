// SPDX-License-Identifier: MPL-2.0
#if os(macOS)
import Foundation
import AVFoundation
import Network
import Testing

@testable import LobbyDirect
@testable import LobbyKit

/// Seeking away from home: a person drags the bar, the player gives up what it asked for and asks
/// for another place. What it gave up must not stand in front of what it asks for now.
extension EndToEndTests {
    /// One request through the app's local server, as the player makes it.
    private final class Asking: Sendable {
        let connection: NWConnection
        let began = ContinuousClock.now

        init(port: UInt16, path: String, range: String) async throws {
            connection = NWConnection(host: "127.0.0.1", port: .init(integerLiteral: port), using: .tcp)
            connection.start(queue: .global())
            try await connection.sendKeepingOpen(Data(
                "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nRange: bytes=\(range)\r\n\r\n".utf8))
        }

        /// Reads until `bytes` of the body came, and says when the first of them did.
        func read(_ bytes: Int) async throws -> (first: Duration, all: Duration, body: Data) {
            var all = Data(), first: Duration?, body: Data?
            while (body?.count ?? 0) < bytes {
                let more = try await connection.receiveSome(atMost: 65_536)
                all += more.data
                if body == nil, let range = all.range(of: Data("\r\n\r\n".utf8)) { body = Data(all[range.upperBound...]) }
                else if body != nil { body! += more.data }
                if let body, !body.isEmpty, first == nil { first = ContinuousClock.now - began }
                if more.isComplete { break }
            }
            return (first ?? .zero, ContinuousClock.now - began, body ?? Data())
        }
    }

    /// A person drags the bar over a mobile network: the player asks for one place after the
    /// other and gives each up after a little. The place where the bar is let go comes quickly.
    @Test func aDraggedBarLandsQuicklyOnAMobileNetwork() async throws {
        let h = try await Harness()
        let home = try await h.home()
        let (paired, identity) = try await h.device("Far phone", at: home)
        let film: Harness.Film = try await h.ask("film", ["bytes": 60_000_000])
        let bytes = try Data(contentsOf: URL(filePath: film.copy))
        // 70 ms there and back, 1.5% lost, a mobile network's speed.
        let road = try await h.road(oneWayMs: 35, loss: 0.015, mbit: 20, queueMs: 150)
        let link = DirectLink(detours: Roads([road]).detours)
        await link.use(identity, token: paired.token)
        _ = try await link.connect()
        let server = try await LoopbackServer.start(link: link)
        let client = try LobbyClient(
            baseURL: server.base, token: paired.token, session: URLSession(configuration: .ephemeral), isCarriedByRoad: true)
        _ = try await client.me()
        let port = UInt16(client.baseURL.port ?? 0)
        let path = client.mediaURL(assetID: film.asset).path(percentEncoded: true)

        var landings: [Duration] = [], firsts: [Duration] = [], wastes: [Int] = []
        for round in 0..<3 {
            // Playing: one request read along, as the player does.
            let playing = try await Asking(port: port, path: path, range: "\(round * 1_000_000)-")
            _ = try await playing.read(1_500_000)
            let before: Harness.Counts = try await h.ask("roadCounts", ["road": road.road])
            // The drag: six places, each given up after a fifth of a second.
            var given: [Asking] = [playing]
            for step in 0..<6 {
                let place = 10_000_000 + round * 12_000_000 + step * 1_500_000
                let asked = try await Asking(port: port, path: path, range: "\(place)-")
                try await Task.sleep(for: .milliseconds(200))
                given.append(asked)
                given.removeFirst().connection.cancel()
            }
            given.forEach { $0.connection.cancel() }
            // Let go: from here to a second of film (4 Mbit/s).
            let place = 20_000_000 + round * 12_000_000
            let landing = try await Asking(port: port, path: path, range: "\(place)-")
            let (first, all, body) = try await landing.read(500_000)
            landing.connection.cancel()
            #expect(body.prefix(500_000) == bytes[place..<(place + min(500_000, body.count))])
            landings.append(all)
            firsts.append(first)
            try await Task.sleep(for: .seconds(2))
            let after: Harness.Counts = try await h.ask("roadCounts", ["road": road.road])
            wastes.append(after.toDevice - before.toDevice - 500_000)
        }
        print("MEASURED a dragged bar at 20 Mbit/s, 70 ms, 1.5% lost: first byte after \(firsts), a second of film after \(landings), wasted \(wastes) bytes")
        #expect(landings.allSatisfy { $0 < .seconds(2) })
        server.stop()
        await link.stop()
        await h.stop()
    }

    @MainActor
    private final class Scrubbing {
        let player = AVPlayer()

        func open(_ url: URL) async throws {
            let item = AVPlayerItem(asset: AVURLAsset(url: url))
            player.isMuted = true
            player.replaceCurrentItem(with: item)
            player.play()
            try await wait("ready", seconds: 30) { item.status != .unknown }
            if let error = item.error { throw error }
            try await wait("the first picture", seconds: 30) { self.player.currentTime().seconds > 0.05 }
        }

        func wait(_ what: String, seconds: Double, _ check: () -> Bool) async throws {
            for _ in 0..<Int(seconds * 20) {
                if check() { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw Harness.Problem(text: "\(what) did not happen")
        }

        /// A drag over the bar, as the system's transport does it: seeks one after the other, then
        /// let go. Says how long it took from letting go to playing on.
        func drag(through places: [Double]) async throws -> Duration {
            for place in places.dropLast() {
                player.seek(to: CMTime(seconds: place, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
                try await Task.sleep(for: .milliseconds(150))
            }
            let target = places.last ?? 0
            let began = ContinuousClock.now
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
            try await wait("playing again at \(target)", seconds: 60) { self.player.currentTime().seconds > target + 0.3 }
            return ContinuousClock.now - began
        }
    }

    /// The system's player, dragged over the bar on a mobile network, for a film that plays as it
    /// is and for one that is prepared.
    @Test(arguments: ["mp4", "mkv"]) @MainActor func theSystemPlayerLandsQuicklyAfterADrag(container: String) async throws {
        let h = try await Harness(maxUploadMbit: 45)
        let home = try await h.home()
        let (paired, identity) = try await h.device("Far phone", at: home)
        struct Playable: Decodable { var asset: String; var bytes: Int }
        let film: Playable = try await h.ask("playable", ["seconds": 400, "mbit": 3, "container": container])
        let road = try await h.road(oneWayMs: 35, loss: 0.015, mbit: 20, queueMs: 150)
        let link = DirectLink(detours: Roads([road]).detours)
        await link.use(identity, token: paired.token)
        _ = try await link.connect()
        let server = try await LoopbackServer.start(link: link)
        let client = try LobbyClient(baseURL: server.base, token: paired.token, isCarriedByRoad: true)
        var playback = try await client.playback(assetID: film.asset)
        while playback.state != .ready {
            try await Task.sleep(for: .milliseconds(500))
            playback = try await client.playback(assetID: film.asset)
        }
        let stream = try #require(playback.streamURL)
        let scrubbing = Scrubbing()
        let began = ContinuousClock.now
        try await scrubbing.open(stream)
        let first = ContinuousClock.now - began
        try await Task.sleep(for: .seconds(8))
        var landings: [Duration] = []
        for (from, to) in [(50.0, 200.0), (220.0, 370.0), (30.0, 150.0)] {
            let before: Harness.Counts = try await h.ask("roadCounts", ["road": road.road])
            let places = stride(from: from, through: to, by: (to - from) / 8).map { $0 }
            landings.append(try await scrubbing.drag(through: places))
            try await Task.sleep(for: .seconds(4))
            let after: Harness.Counts = try await h.ask("roadCounts", ["road": road.road])
            print("MEASURED \(container): \(after.toDevice - before.toDevice) bytes over the road for a drag and 4 s")
        }
        print("MEASURED \(container) of \(film.bytes) bytes at 20 Mbit/s, 70 ms, 1.5% lost: first picture after \(first), after a drag playing again after \(landings)")
        #expect(landings.allSatisfy { $0 < .seconds(4) })
        scrubbing.player.replaceCurrentItem(with: nil)
        server.stop()
        await link.stop()
        await h.stop()
    }

    /// The path breaks under a playing film while the phone stays on the same network: the road
    /// goes silent, or the mobile network's NAT gives the phone another port. A jump right after
    /// must not wait for long.
    @Test(arguments: ["silent", "rebound"]) @MainActor func aJumpAfterThePathBrokeDoesNotWaitLong(how: String) async throws {
        let h = try await Harness(maxUploadMbit: 45)
        let home = try await h.home()
        let (paired, identity) = try await h.device("Far phone", at: home)
        struct Playable: Decodable { var asset: String; var bytes: Int }
        let film: Playable = try await h.ask("playable", ["seconds": 300, "mbit": 3])
        let first = try await h.road(oneWayMs: 35, loss: 0.01, mbit: 20, queueMs: 150)
        let second = try await h.road(oneWayMs: 35, loss: 0.01, mbit: 20, queueMs: 150)
        let link = DirectLink(detours: Roads([first, second]).detours)
        await link.use(identity, token: paired.token)
        _ = try await link.connect()
        let server = try await LoopbackServer.start(link: link)
        let client = try LobbyClient(baseURL: server.base, token: paired.token, isCarriedByRoad: true)
        let stream = try #require(try await client.playback(assetID: film.asset).streamURL)
        let scrubbing = Scrubbing()
        try await scrubbing.open(stream)
        try await Task.sleep(for: .seconds(6))
        if how == "silent" {
            try await h.say("roadDown", ["road": first.road])
        } else {
            try await h.say("roadRebind", ["road": first.road])
        }
        try await Task.sleep(for: .seconds(1))
        let landing = try await scrubbing.drag(through: [200])
        print("MEASURED the path \(how): a jump played again after \(landing)")
        #expect(landing < .seconds(8))
        scrubbing.player.replaceCurrentItem(with: nil)
        server.stop()
        await link.stop()
        await h.stop()
    }

    /// The path breaks while the player has enough and asks for nothing: the link makes a new
    /// connection by itself, and a jump some seconds later finds it there.
    @Test func aBrokenPathIsMadeAgainBeforeThePlayerNeedsIt() async throws {
        let h = try await Harness()
        let home = try await h.home()
        let (paired, identity) = try await h.device("Far phone", at: home)
        let film: Harness.Film = try await h.ask("film", ["bytes": 20_000_000])
        let bytes = try Data(contentsOf: URL(filePath: film.copy))
        let first = try await h.road(oneWayMs: 35, mbit: 20), second = try await h.road(oneWayMs: 35, mbit: 20)
        let link = DirectLink(detours: Roads([first, second]).detours)
        await link.use(identity, token: paired.token)
        _ = try await link.connect()
        let server = try await LoopbackServer.start(link: link)
        let client = try LobbyClient(
            baseURL: server.base, token: paired.token, session: URLSession(configuration: .ephemeral), isCarriedByRoad: true)
        _ = try await client.me()
        let port = UInt16(client.baseURL.port ?? 0)
        let path = client.mediaURL(assetID: film.asset).path(percentEncoded: true)
        // The player's request, read for a while and then left alone: its buffer is full.
        let playing = try await Asking(port: port, path: path, range: "0-")
        _ = try await playing.read(1_000_000)
        try await h.say("roadRebind", ["road": first.road])
        try await Task.sleep(for: .seconds(7))
        let jump = try await Asking(port: port, path: path, range: "15000000-")
        let (_, took, body) = try await jump.read(300_000)
        #expect(body.prefix(300_000) == bytes[15_000_000..<(15_000_000 + min(300_000, body.count))])
        print("MEASURED a jump 7 s after the path broke under a full player: \(took)")
        #expect(took < .seconds(2))
        jump.connection.cancel()
        playing.connection.cancel()
        server.stop()
        await link.stop()
        await h.stop()
    }

    /// A connection the device leaves says goodbye over the path: the box ends it at once, as
    /// "left", instead of keeping it half a minute until ICE gives up and calls it "no path".
    @Test func aConnectionThatIsLeftEndsOnTheBoxAtOnce() async throws {
        let h = try await Harness()
        let home = try await h.home()
        let (paired, identity) = try await h.device("Far phone", at: home)
        let road = try await h.road(oneWayMs: 35, mbit: 20)
        let link = DirectLink(detours: Roads([road]).detours)
        await link.use(identity, token: paired.token)
        _ = try await link.connect()
        await link.stop()
        struct Endings: Decodable { var endings: [String] }
        var endings: [String] = []
        for _ in 0..<20 where endings.isEmpty {
            try await Task.sleep(for: .milliseconds(250))
            endings = (try await h.ask("endings") as Endings).endings
        }
        #expect(endings == ["left"])
        await h.stop()
    }

    /// A player that has enough reads nothing for a while: the box hears it ask every second and
    /// answers, so that this is not taken for a broken path.
    @Test func aQuietPlayerIsNotTakenForABrokenPath() async throws {
        let h = try await Harness()
        let home = try await h.home()
        let (paired, identity) = try await h.device("Far phone", at: home)
        let film: Harness.Film = try await h.ask("film", ["bytes": 20_000_000])
        let road = try await h.road(oneWayMs: 35, loss: 0.01, mbit: 20)
        let link = DirectLink(detours: Roads([road]).detours)
        await link.use(identity, token: paired.token)
        _ = try await link.connect()
        let server = try await LoopbackServer.start(link: link)
        let client = try LobbyClient(
            baseURL: server.base, token: paired.token, session: URLSession(configuration: .ephemeral), isCarriedByRoad: true)
        _ = try await client.me()
        let states = Task {
            var seen: [DirectLink.State] = []
            for await state in await link.states() { seen.append(state) }
            return seen
        }
        let port = UInt16(client.baseURL.port ?? 0)
        let playing = try await Asking(port: port, path: client.mediaURL(assetID: film.asset).path(percentEncoded: true), range: "0-")
        _ = try await playing.read(1_000_000)
        // Long beyond the box's own keep-alive of eight seconds.
        try await Task.sleep(for: .seconds(12))
        await link.stop()
        states.cancel()
        let seen = await states.value
        #expect(!seen.contains(.reconnecting), "\(seen)")
        playing.connection.cancel()
        server.stop()
        await h.stop()
    }
}
#endif
