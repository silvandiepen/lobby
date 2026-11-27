// SPDX-License-Identifier: MPL-2.0
#if os(macOS)
import Foundation
import Network
import Synchronization
import Testing

@testable import LobbyDirect
@testable import LobbyKit

/// The app's side against the real server, introducer and lobby-direct of this repository.
@Suite(.serialized, .enabled(if: Harness.isThere, "SKIPPED: apps/direct is not built, or there is no node here."))
struct EndToEndTests {
    private static let plain = DirectSession.Detours(bind: "127.0.0.1")

    private func link(_ detours: DirectSession.Detours = plain, silence: Duration = .seconds(10), patience: Duration = .seconds(30)) -> DirectLink {
        DirectLink(detours: detours, patience: patience, silence: silence)
    }

    /// A link in use, its local server, and the client the app would have.
    private func up(
        _ h: Harness, _ paired: Harness.Paired, _ identity: DirectIdentity, _ link: DirectLink
    ) async throws -> (LoopbackServer, LobbyClient) {
        await link.use(identity, token: paired.token)
        _ = try await link.connect()
        let server = try await LoopbackServer.start(link: link)
        return (server, try LobbyClient(baseURL: server.base, token: paired.token, session: URLSession(configuration: .ephemeral), isCarriedByRoad: true))
    }

    @Test func carriesTheAPI() async throws {
        let h = try await Harness()
        let home = try await h.home()
        let (paired, identity) = try await h.device("Far phone", at: home)
        let link = link()
        let began = ContinuousClock.now
        let (server, client) = try await up(h, paired, identity, link)
        print("MEASURED connected after \(ContinuousClock.now - began)")
        let me = try await client.me()
        #expect(me.device.id == paired.id)
        _ = try await client.profiles()
        // Managing is for home.
        await #expect(throws: LobbyError.self) { try await client.outsideStatus() }
        #expect(await server.isAlive())

        // Nobody else gets anything from the local server.
        func status(_ text: String) async throws -> String {
            let connection = NWConnection(host: "127.0.0.1", port: .init(integerLiteral: UInt16(server.base.port ?? 0)), using: .tcp)
            connection.start(queue: .global())
            defer { connection.cancel() }
            try await connection.sendKeepingOpen(Data(text.utf8))
            return String(decoding: try await connection.receiveSome().data.prefix(12), as: UTF8.self)
        }
        let port = server.base.port ?? 0, secret = server.base.lastPathComponent
        #expect(try await status("GET /v1/me HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n") == "HTTP/1.1 404")
        #expect(try await status("GET /\(secret)/v1/me HTTP/1.1\r\nHost: evil.example:\(port)\r\n\r\n") == "HTTP/1.1 404")
        #expect(try await status("GET /\(secret)/v1/me HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nOrigin: http://evil.example\r\n\r\n") == "HTTP/1.1 404")
        #expect(try await status("GET /\(secret)/other HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n") == "HTTP/1.1 404")
        #expect(try await status("TRACE /\(secret)/v1/me HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n") == "HTTP/1.1 405")
        #expect(try await status("GET /\(secret)/v1/me HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n") == "HTTP/1.1 200")
        server.stop()
        await link.stop()
        await h.stop()
    }

    @Test func carriesAFilmByteForByte() async throws {
        let h = try await Harness()
        let home = try await h.home()
        let (paired, identity) = try await h.device("Far phone", at: home)
        let film: Harness.Film = try await h.ask("film", ["bytes": 12_000_000])
        let bytes = try Data(contentsOf: URL(filePath: film.copy))
        let link = link()
        let (server, client) = try await up(h, paired, identity, link)
        let session = URLSession(configuration: .ephemeral)
        let url = client.mediaURL(assetID: film.asset)
        // Ranges side by side, and jumps that are left in the middle.
        for round in 0..<6 {
            let left = Task {
                var request = client.authorizedRequest(for: url)
                request.setValue("bytes=0-", forHTTPHeaderField: "Range")
                _ = try await session.data(for: request)
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for one in 1...4 {
                    group.addTask {
                        let from = (round * 5 + one) * 300_000
                        var request = client.authorizedRequest(for: url)
                        request.setValue("bytes=\(from)-\(from + 199_999)", forHTTPHeaderField: "Range")
                        let (data, response) = try await session.data(for: request)
                        #expect((response as? HTTPURLResponse)?.statusCode == 206)
                        #expect(data == bytes[from..<(from + 200_000)])
                    }
                }
                try await group.waitForAll()
            }
            left.cancel()
        }
        let began = ContinuousClock.now
        let (whole, _) = try await session.data(for: client.authorizedRequest(for: url))
        #expect(whole == bytes)
        print("MEASURED 12 MB over the direct road on this Mac: \(ContinuousClock.now - began)")
        if case .up = await link.state {} else { Issue.record("the connection broke: \(await link.state)") }
        server.stop()
        await link.stop()
        await h.stop()
    }

    @Test func wrongCertificateIsNotTheBox() async throws {
        let h = try await Harness()
        let home = try await h.home()
        let (_, identity) = try await h.device("Far phone", at: home)
        // Another secret opens no envelope, so nothing that is not the box gets as far as QUIC.
        var forged = identity
        forged.secret = Data.random(32)
        await #expect(throws: DirectError.self) { try await DirectSession.connect(forged, limit: .seconds(15), detours: Self.plain) }
        // A wrong signature is not this device.
        var detours = Self.plain
        detours.proof = { frame in
            var changed = frame
            changed[99] ^= 1
            return changed
        }
        await #expect(throws: (any Error).self) { try await DirectSession.connect(identity, limit: .seconds(15), detours: detours) }
        // A certificate the box did not name.
        var pinned = Self.plain
        pinned.fingerprints = { _ in [Data.random(32).base64URL] }
        await #expect(throws: DirectError.wrongCertificate) {
            try await DirectSession.connect(identity, limit: .seconds(15), detours: pinned)
        }
        let good = try await DirectSession.connect(identity, detours: Self.plain)
        #expect(good.path == .direct)
        good.close()
        await h.stop()
    }

    /// Reads a film slowly through the local server while `meanwhile` happens, and says what came.
    private func read(_ client: LobbyClient, _ asset: String, pieces: Int = 65_536, meanwhile: (Int) async throws -> Void) async throws -> (Data, Duration) {
        let connection = NWConnection(
            host: "127.0.0.1", port: .init(integerLiteral: UInt16(client.baseURL.port ?? 0)), using: .tcp)
        connection.start(queue: .global())
        defer { connection.cancel() }
        let path = client.mediaURL(assetID: asset).path(percentEncoded: true)
        try await connection.sendKeepingOpen(Data(
            "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(client.baseURL.port ?? 0)\r\nRange: bytes=0-\r\n\r\n".utf8))
        var all = Data()
        var longest = Duration.zero
        var body: Int?
        while true {
            let began = ContinuousClock.now
            let more = try await connection.receiveSome(atMost: pieces)
            longest = max(longest, ContinuousClock.now - began)
            all += more.data
            if body == nil, let range = all.range(of: Data("\r\n\r\n".utf8)) {
                all = Data(all[range.upperBound...])
                body = 0
            }
            if more.isComplete { break }
            try await meanwhile(all.count)
        }
        return (all, longest)
    }

    @Test func aFilmGoesOnWhenTheNetworkChanges() async throws {
        let h = try await Harness()
        let home = try await h.home()
        let (paired, identity) = try await h.device("Far phone", at: home)
        let film: Harness.Film = try await h.ask("film", ["bytes": 16_000_000])
        let bytes = try Data(contentsOf: URL(filePath: film.copy))
        // Wi-Fi, then 5G: another road, and the first one takes everything that enters it along.
        let wifi = try await h.road(oneWayMs: 10, mbit: 40), mobile = try await h.road(oneWayMs: 30, mbit: 30)
        let link = link(Roads([wifi, mobile]).detours)
        let (server, client) = try await up(h, paired, identity, link)
        var changed = false
        let (all, longest) = try await read(client, film.asset) { count in
            guard count > 4_000_000, !changed else { return }
            changed = true
            try await h.say("roadDown", ["road": wifi.road])
            await link.networkChanged()
        }
        #expect(changed)
        #expect(all == bytes)
        #expect(longest < .seconds(8))
        print("MEASURED the network changed in a film: longest pause \(longest)")
        server.stop()
        await link.stop()
        await h.stop()
    }

    @Test func aSilentNetworkIsNoticed() async throws {
        let h = try await Harness()
        let home = try await h.home()
        let (paired, identity) = try await h.device("Far phone", at: home)
        let film: Harness.Film = try await h.ask("film", ["bytes": 12_000_000])
        let bytes = try Data(contentsOf: URL(filePath: film.copy))
        let first = try await h.road(oneWayMs: 5, mbit: 40), second = try await h.road(oneWayMs: 5, mbit: 40)
        let link = link(Roads([first, second]).detours, silence: .seconds(2))
        let (server, client) = try await up(h, paired, identity, link)
        var changed = false
        // Nobody says that the network changed.
        let (all, longest) = try await read(client, film.asset) { count in
            guard count > 3_000_000, !changed else { return }
            changed = true
            try await h.say("roadDown", ["road": first.road])
        }
        #expect(all == bytes)
        print("MEASURED a silent network: longest pause \(longest)")
        server.stop()
        await link.stop()
        await h.stop()
    }

    @Test func comesHomeInTheMiddleOfAFilm() async throws {
        let h = try await Harness()
        let home = try await h.home()
        let (paired, identity) = try await h.device("Far phone", at: home)
        let film: Harness.Film = try await h.ask("film", ["bytes": 12_000_000])
        let bytes = try Data(contentsOf: URL(filePath: film.copy))
        let link = link()
        let (server, client) = try await up(h, paired, identity, link)
        let origin = try #require(Origin(home))
        var changed = false
        let (all, _) = try await read(client, film.asset) { count in
            guard count > 2_000_000, !changed else { return }
            changed = true
            await link.use(origin, token: paired.token)
        }
        #expect(all == bytes)
        #expect(await link.state == .origin)
        server.stop()
        await link.stop()
        await h.stop()
    }

    @Test func endsForARemovedDeviceInTheMiddleOfAFilm() async throws {
        let h = try await Harness()
        let home = try await h.home()
        let (paired, identity) = try await h.device("Far phone", at: home)
        let film: Harness.Film = try await h.ask("film", ["bytes": 40_000_000])
        let link = link(patience: .seconds(12))
        let (server, client) = try await up(h, paired, identity, link)
        var revoked = false
        let got = try? await read(client, film.asset) { count in
            guard count > 2_000_000, !revoked else { return }
            revoked = true
            try await h.say("revoke", ["id": paired.id])
        }
        #expect(revoked)
        #expect((got?.0.count ?? 0) < 40_000_000)
        // And it does not ring again by itself.
        await #expect(throws: DirectError.notAllowed) { try await link.connect() }
        server.stop()
        await link.stop()
        await h.stop()
    }

    @Test func endsWithTheSwitchAndComesBackWithIt() async throws {
        let h = try await Harness()
        let home = try await h.home()
        let (paired, identity) = try await h.device("Far phone", at: home)
        let film: Harness.Film = try await h.ask("film", ["bytes": 16_000_000])
        let bytes = try Data(contentsOf: URL(filePath: film.copy))
        let link = link()
        let (server, client) = try await up(h, paired, identity, link)
        var off = false
        let (all, longest) = try await read(client, film.asset) { count in
            guard count > 2_000_000, !off else { return }
            off = true
            try await h.say("enabled", ["on": false])
            try await Task.sleep(for: .seconds(3))
            try await h.say("enabled", ["on": true])
            try await h.say("told")
        }
        #expect(all == bytes)
        print("MEASURED switched off for 3 s: longest pause \(longest)")
        // The program died.
        try await h.say("kill")
        try await h.say("up")
        #expect(try await client.me().device.id == paired.id)
        server.stop()
        await link.stop()
        await h.stop()
    }

    /// What the system does to a suspended app: its ports are gone. And the same port again after.
    @Test func comesBackAfterSuspension() async throws {
        let h = try await Harness()
        let home = try await h.home()
        let (paired, identity) = try await h.device("Far phone", at: home)
        let link = link()
        let (server, client) = try await up(h, paired, identity, link)
        _ = try await client.me()
        await link.enteredBackground()
        for _ in 0..<40 where await link.state != .idle { try await Task.sleep(for: .milliseconds(50)) }
        #expect(await link.state == .idle)
        server.stop()
        #expect(await !server.isAlive())
        await link.becameActive()
        let fresh = try await LoopbackServer.start(link: link, replacing: server)
        #expect(fresh.base == server.base)
        #expect(try await client.me().device.id == paired.id)
        fresh.stop()
        await link.stop()
        await h.stop()
    }

    @Test func aJumpWastesLittle() async throws {
        let h = try await Harness()
        let home = try await h.home()
        let (paired, identity) = try await h.device("Far phone", at: home)
        let film: Harness.Film = try await h.ask("film", ["bytes": 40_000_000])
        let bytes = try Data(contentsOf: URL(filePath: film.copy))
        let road = try await h.road(oneWayMs: 30, mbit: 40, queueMs: 100)
        let link = link(Roads([road]).detours)
        let (server, client) = try await up(h, paired, identity, link)
        _ = try await client.me()
        let port = UInt16(client.baseURL.port ?? 0)
        let path = client.mediaURL(assetID: film.asset).path(percentEncoded: true)
        var wastes: [Int] = [], jumps: [Duration] = []
        for round in 0..<5 {
            let before: Harness.Counts = try await h.ask("roadCounts", ["road": road.road])
            let connection = NWConnection(host: "127.0.0.1", port: .init(integerLiteral: port), using: .tcp)
            connection.start(queue: .global())
            let from = round * 3_000_000
            try await connection.sendKeepingOpen(Data(
                "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nRange: bytes=\(from)-\r\n\r\n".utf8))
            var read = 0
            while read < 2_000_000 { read += try await connection.receiveSome(atMost: 65_536).data.count }
            connection.cancel()
            // The jump: from asking to a tenth of a second of film.
            let began = ContinuousClock.now
            var request = client.authorizedRequest(for: client.mediaURL(assetID: film.asset))
            let to = 25_000_000 + round * 500_000
            request.setValue("bytes=\(to)-\(to + 99_999)", forHTTPHeaderField: "Range")
            let (data, _) = try await URLSession(configuration: .ephemeral).data(for: request)
            jumps.append(ContinuousClock.now - began)
            #expect(data == bytes[to..<(to + 100_000)])
            try await Task.sleep(for: .seconds(1))
            let after: Harness.Counts = try await h.ask("roadCounts", ["road": road.road])
            wastes.append(after.toDevice - before.toDevice - read - 100_000)
        }
        print("MEASURED jumps at 40 Mbit/s, 60 ms: wasted \(wastes) bytes, took \(jumps)")
        #expect(wastes.allSatisfy { $0 < 2_000_000 })
        #expect(jumps.allSatisfy { $0 < .seconds(3) })
        server.stop()
        await link.stop()
        await h.stop()
    }

    /// A download over the direct road, through the app being closed and opened again.
    @Test func aDownloadGoesOnWhenTheAppIsOpenedAgain() async throws {
        let h = try await Harness()
        let home = try await h.home()
        let (paired, identity) = try await h.device("Far phone", at: home)
        let film: Harness.Film = try await h.ask("film", ["bytes": 14_000_000])
        let bytes = try Data(contentsOf: URL(filePath: film.copy))
        let item = try #require(try await LobbyClient(baseURL: home, token: paired.token).library(cursor: nil).items.first)
        let file = try #require(item.files.first)
        let road = try await h.road(oneWayMs: 5, mbit: 30)
        let folder = FileManager.default.temporaryDirectory.appending(path: "lobby-carried-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        func open() async throws -> (DownloadManager, LoopbackServer, DirectLink) {
            let link = self.link(Roads([road]).detours)
            let (server, client) = try await up(h, paired, identity, link)
            let downloads = DownloadManager(directory: folder, sessionConfiguration: .ephemeral, spaceReserveBytes: 0)
            await downloads.start(using: client)
            return (downloads, server, link)
        }
        let (first, server, link) = try await open()
        // Mobile data is not for downloads unless the person said so.
        await first.setOnMobileData(true)
        await first.enqueue(item, file: file, allowsCellular: false)
        try await Task.sleep(for: .milliseconds(400))
        #expect(await first.record(itemID: item.id)?.state == .queued)
        #expect(await first.record(itemID: item.id)?.isWaitingForNetwork == true)
        await first.setOnMobileData(false)
        for _ in 0..<400 where await (first.record(itemID: item.id)?.transfer?.receivedBytes ?? 0) < 4_000_000 {
            try await Task.sleep(for: .milliseconds(25))
        }
        await first.setClient(nil)
        server.stop()
        await link.stop()
        let partial = DownloadPaths.partial(item.id, in: folder)
        let arrived = try Data(contentsOf: partial).count
        #expect(arrived >= 4 << 20 && arrived < bytes.count)

        let (second, again, other) = try await open()
        var states: DownloadState?
        for _ in 0..<600 {
            states = await second.record(itemID: item.id)?.state
            if states == .verified { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(states == .verified)
        let local = try #require(await second.localFile(itemID: item.id))
        #expect(try Data(contentsOf: local) == bytes)
        again.stop()
        await other.stop()
        await h.stop()
    }

    @Test func pairsFromOutsideWithTheCode() async throws {
        let h = try await Harness()
        let window: OutsideWindow = try await h.ask("window")
        let invitation = try #require(window.invitation)
        // A wrong code finds nothing.
        let wrong = try #require(PairingInvitation(introducer: invitation.introducer.url.absoluteString, code: "0000000000000000"))
        await #expect(throws: DirectError.unknownRoom) {
            try await DirectPairing(invitation: wrong, deviceName: "Nobody", platform: "tvos").begin()
        }
        let pairing = DirectPairing(invitation: invitation, deviceName: "Télé abroad", platform: "tvos", pollEvery: .milliseconds(300))
        let waiting = try await pairing.begin()
        struct Requests: Decodable { var requests: [OutsideStatus.Request] }
        let asked: Requests = try await h.ask("requests")
        let request = try #require(asked.requests.first)
        #expect(request.comparison == waiting.comparison)
        #expect(request.deviceName == "Télé abroad")
        async let approval = pairing.approval(until: waiting.expiresAt)
        try await h.say("approve", ["id": request.id, "comparison": waiting.comparison])
        let grant = try DirectGrant(try await approval)
        await pairing.done()
        #expect(grant.grant.device.allowOutside == true)

        // And it is in, without ever having been at home.
        try await h.say("told")
        let link = link()
        let (server, client) = try await up(h, .init(id: grant.grant.device.id, token: grant.grant.token), grant.identity, link)
        #expect(try await client.me().device.id == grant.grant.device.id)
        server.stop()
        await link.stop()

        // Refused: the manager's digits were others.
        let second: OutsideWindow = try await h.ask("window")
        let other = DirectPairing(invitation: try #require(second.invitation), deviceName: "Other", platform: "ios", pollEvery: .milliseconds(300))
        let digits = try await other.begin()
        let again: Requests = try await h.ask("requests")
        let wrongDigits = digits.comparison == "000000" ? "000001" : "000000"
        try await h.say("approve", ["id": try #require(again.requests.first).id, "comparison": wrongDigits])
        await #expect(throws: DirectError.pairingRefused) { try await other.approval(until: digits.expiresAt) }
        await h.stop()
    }

    /// Another certificate, and keys that somebody else took the place of.
    @Test func keepsItselfReady() async throws {
        let h = try await Harness()
        let home = try await h.home()
        let (paired, identity) = try await h.device("Phone", at: home)
        let client = try LobbyClient(baseURL: home, token: paired.token)
        // Nothing changed: the same keys.
        #expect(try await client.directIdentity(keeping: identity) == identity)
        try await h.say("allow", ["id": paired.id, "allow": false])
        let closed = try #require(try await client.directIdentity(keeping: identity))
        #expect(!closed.allowed)
        #expect(closed.ringKey == identity.ringKey)
        // Enrolled anew elsewhere with this credential: what is kept here is no use any more.
        let other = try await client.enrolDirect()
        let fresh = try #require(try await client.directIdentity(keeping: identity))
        #expect(fresh.ringKey != identity.ringKey && fresh.ringKey != other.ringKey)
        // What is kept survives being written down, and nothing half is read.
        #expect(DirectIdentity(encoded: try fresh.encoded()) == fresh)
        #expect(DirectIdentity(encoded: "bm90aGluZw==") == nil)
        await h.stop()
    }

    // MARK: Choosing

    private func connection(_ server: String, home: URL) -> SavedConnection {
        SavedConnection(
            serverAddress: home, serverID: server, serverName: "Lobby", deviceID: "device",
            addresses: ServerAddresses(home: [home], remote: []))
    }

    @Test func choosesTheRoad() async throws {
        let h = try await Harness()
        let home = try await h.home()
        let info = try await LobbyClient(baseURL: home).serverInfo()
        let paired: Harness.Paired = try await h.ask("pair", ["name": "Far phone", "outside": true])
        let credentials = InMemoryCredentialStore()
        let suite = "lobby.direct-tests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let memory = RoadMemory(suiteName: suite)
        let link = link()
        let road = ServerRoad(credentials: credentials, link: link, memory: memory, headStart: .milliseconds(300))
        await road.networkChanged(NetworkSignature(id: "here", isUsable: true, isExpensive: false))
        let saved = connection(info.id, home: home)
        @Sendable func locate() async -> URL? {
            await ServerLocator.locate(serverID: info.id, among: [home], timeout: 2)
        }

        // At home: the address, and it gets ready for the direct road.
        let atHome = try #require(await road.find(saved, token: paired.token, locate: locate))
        #expect(atHome.road == .home)
        #expect(atHome.client.baseURL == home)
        #expect(await link.state == .idle)
        await road.keepReady(atHome.client, serverID: info.id)
        let identity = try #require(await road.identity(forServer: info.id))
        #expect(identity.allowed)
        try await h.say("told")

        // Away: direct.
        try await h.say("closeHome")
        let detour = ServerRoad(credentials: credentials, link: link, memory: memory, headStart: .milliseconds(300))
        await detour.networkChanged(NetworkSignature(id: "there", isUsable: true, isExpensive: true))
        let began = ContinuousClock.now
        let away = try #require(await detour.find(saved, token: paired.token, locate: locate))
        print("MEASURED from asking to the direct road, home silent: \(ContinuousClock.now - began)")
        #expect(away.road == .direct)
        #expect(away.client.isCarriedByRoad)
        #expect(away.client.deviceCookie() == nil)
        #expect(away.client.authorizedRequest(for: away.client.baseURL).allHTTPHeaderFields?["Authorization"] == nil)
        #expect(try await away.client.me().device.id == paired.id)
        #expect(await detour.isOnMobileData)
        #expect(memory.road(on: "there", server: info.id) == .direct)

        // Home again: its own address, and what holds the local one goes on there.
        _ = try await h.say("openHome", ["port": home.port ?? 0])
        let back = try #require(await detour.find(saved, token: paired.token, locate: locate))
        #expect(back.road == .home)
        #expect(try await away.client.me().device.id == paired.id)

        // Switched off by the person: nothing but the addresses.
        await detour.setUsesDirect(false)
        try await h.say("closeHome")
        #expect(await detour.find(saved, token: paired.token, locate: locate) == nil)

        // Signed out: nothing is left.
        await detour.forget(serverID: info.id)
        #expect(await detour.identity(forServer: info.id) == nil)
        await h.stop()
    }
}
#endif
