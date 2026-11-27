// SPDX-License-Identifier: MPL-2.0
import Foundation
import Synchronization
import Testing

@testable import LobbyKit

@Suite struct LobbyClientTests {
    static let server = #"{ "id": "srv-1", "name": "Lobby", "version": "0.1.0", "apiVersion": 1, "claimed": true }"#

    @Test func rejectsAnAddressThatIsNotAServer() {
        #expect(throws: LobbyError.invalidServerAddress) {
            try LobbyClient(baseURL: URL(string: "ftp://lobby.local")!)
        }
        #expect(throws: LobbyError.invalidServerAddress) {
            try LobbyClient(baseURL: URL(string: "lobby")!)
        }
    }

    @Test func serverInfoNeedsNoCredential() async throws {
        let stub = StubServer { _ in .json(200, Self.server) }
        let info = try await stub.client(token: nil).serverInfo()

        #expect(info == ServerInfo(id: "srv-1", name: "Lobby", version: "0.1.0", apiVersion: 1, claimed: true))
        let request = try #require(stub.recorded.first)
        #expect(request.method == "GET")
        #expect(request.path == "/v1/server")
        #expect(request.headers["Authorization"] == nil)
    }

    @Test func sendsTheTokenAsABearerHeaderAndNeverInTheURL() async throws {
        let stub = StubServer { _ in .json(200, #"{ "device": \#(Fixtures.device), "server": \#(Self.server) }"#) }
        let me = try await stub.client(token: "secret-token").me()

        #expect(me.device.id == "dev-1")
        #expect(me.server.name == "Lobby")
        let request = try #require(stub.recorded.first)
        #expect(request.headers["Authorization"] == "Bearer secret-token")
        #expect(!request.path.contains("secret-token"))
        #expect(request.query.isEmpty)
    }

    @Test func aTrailingSlashOnTheAddressDoesNotDoubleUp() async throws {
        let stub = StubServer { _ in .json(200, Self.server) }
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [StubURLProtocol.self]
        let client = try LobbyClient(
            baseURL: URL(string: "http://\(stub.host)/")!, session: URLSession(configuration: session))
        _ = try await client.serverInfo()

        #expect(stub.recorded.first?.path == "/v1/server")
    }

    @Test func theServerSaysHowItIsClaimed() async throws {
        func info(_ extra: String) throws -> ServerInfo {
            let json = #"{ "id": "srv-1", "name": "Lobby", "version": "0.1.0", "apiVersion": 1, "claimed": false\#(extra) }"#
            return try JSONDecoder().decode(ServerInfo.self, from: Data(json.utf8))
        }
        #expect(try info(#", "claim": "open""#).claim == .open)
        #expect(try info(#", "claim": "secret""#).claim == .secret)
        // An older server does not say, and a newer one may say something else: ask for the secret.
        #expect(try info("").claim == .secret)
        #expect(try info(#", "claim": "passkey""#).claim == .secret)
    }

    @Test func anOpenServerIsClaimedWithoutASecret() async throws {
        let stub = StubServer { _ in .json(201, #"{ "device": \#(Fixtures.device), "token": "tok-1" }"#) }
        let grant = try await stub.client(token: nil).claim(deviceName: "Alex's MacBook Pro", platform: .macos)
        #expect(grant.token == "tok-1")
        let body = try #require(stub.recorded.first).json()
        #expect(body["setupSecret"] == nil)
        #expect(Set(body.keys) == ["deviceName", "platform"])
    }

    @Test func claimsANewServer() async throws {
        let stub = StubServer { _ in .json(201, #"{ "device": \#(Fixtures.device), "token": "tok-1" }"#) }
        let grant = try await stub.client(token: nil).claim(
            setupSecret: "setup", deviceName: "Alex's MacBook Pro", platform: .macos)

        #expect(grant.token == "tok-1")
        #expect(grant.device.role == .manager)
        let request = try #require(stub.recorded.first)
        #expect(request.method == "POST")
        #expect(request.path == "/v1/pairing/claim")
        #expect(request.headers["Content-Type"] == "application/json")
        let body = try request.json()
        #expect(body["setupSecret"] as? String == "setup")
        #expect(body["deviceName"] as? String == "Alex's MacBook Pro")
        #expect(body["platform"] as? String == "macos")
    }

    @Test func pairsByPollingUntilAManagerApproves() async throws {
        let polls = Mutex(0)
        let stub = StubServer { request in
            switch request.path {
            case "/v1/pairing/requests":
                return .json(201, #"{ "id": "req-1", "code": "482913", "pollSecret": "poll", "expiresAt": 1795530600000 }"#)
            case "/v1/pairing/requests/req-1/collect":
                let count = polls.withLock { $0 += 1; return $0 }
                return count < 3
                    ? .json(202, #"{ "status": "pending", "expiresAt": 1795530600000 }"#)
                    : .json(200, #"{ "status": "approved", "device": \#(Fixtures.device), "token": "tok-2" }"#)
            default:
                return .error(404, "not_found")
            }
        }
        let client = try stub.client(token: nil)

        let request = try await client.requestPairing(deviceName: "Living room Apple TV", platform: .tvos)
        #expect(request.code == "482913")
        #expect(request.expiresAt.millisecondsSince1970 == 1_795_530_600_000)
        #expect(try await client.collectPairing(request) == .pending(expiresAt: request.expiresAt))

        let waits = Mutex<[Duration]>([])
        let grant = try await client.awaitPairingApproval(
            of: request, pollEvery: .seconds(3), sleep: { duration in waits.withLock { $0.append(duration) } })

        #expect(grant.token == "tok-2")
        #expect(waits.withLock { $0 } == [.seconds(3)])
        let collect = try #require(stub.recorded.last)
        #expect(try collect.json()["pollSecret"] as? String == "poll")
    }

    @Test func pollingKeepsGoingWhileTheServerIsBrieflyUnreachableAndStopsWhenTheRequestIsGone() async throws {
        let polls = Mutex(0)
        let stub = StubServer { _ in
            let count = polls.withLock { $0 += 1; return $0 }
            if count == 1 { throw URLError(.networkConnectionLost) }
            return .error(410, "gone", "This pairing request expired.")
        }
        let request = PairingRequest(
            id: "req-1", code: "482913", pollSecret: "poll", expiresAt: Date(millisecondsSince1970: 1_795_530_600_000))
        let clock = TestClock()

        await #expect(throws: LobbyError.gone(message: "This pairing request expired.")) {
            try await stub.client(token: nil).awaitPairingApproval(of: request, now: { clock.now }, sleep: { _ in })
        }
        #expect(polls.withLock { $0 } == 2)
    }

    @Test func aManagerApprovesAndListsDevices() async throws {
        let stub = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/v1/pairing/requests"):
                .json(200, #"{ "requests": [ { "id": "req-1", "deviceName": "Living room Apple TV", "platform": "tvos", "createdAt": 1795530000000, "expiresAt": 1795530600000 } ] }"#)
            case ("POST", "/v1/pairing/approve"):
                .json(200, #"{ "deviceName": "Living room Apple TV", "platform": "tvos", "role": "viewer" }"#)
            case ("GET", "/v1/devices"):
                .json(200, #"{ "devices": [\#(Fixtures.device)], "currentDeviceId": "dev-1" }"#)
            case ("DELETE", "/v1/devices/dev-2"):
                StubResponse(status: 204)
            default:
                .error(404, "not_found")
            }
        }
        let client = try stub.client()

        #expect(try await client.pendingPairingRequests().map(\.deviceName) == ["Living room Apple TV"])
        let approval = try await client.approvePairing(code: "482913", role: .viewer)
        #expect(approval == PairingApproval(deviceName: "Living room Apple TV", platform: .tvos, role: .viewer))
        let approve = try #require(stub.recorded.last)
        #expect(try approve.json()["code"] as? String == "482913")
        #expect(try approve.json()["role"] as? String == "viewer")

        _ = try await client.approvePairing(requestID: "req-1", role: .manager)
        let picked = try #require(stub.recorded.last)
        #expect(try picked.json()["requestId"] as? String == "req-1")
        #expect(try picked.json()["code"] == nil)
        #expect(try picked.json()["role"] as? String == "manager")

        let list = try await client.devices()
        #expect(list.currentDeviceId == "dev-1")
        #expect(list.devices.count == 1)
        try await client.revokeDevice(id: "dev-2")
    }

    @Test func managesProfiles() async throws {
        let stub = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/v1/profiles"):
                .json(200, #"{ "profiles": [ { "id": "p1", "name": "Robin", "color": "teal" } ] }"#)
            case ("POST", "/v1/profiles"):
                .json(201, #"{ "id": "p2", "name": "Alex", "color": "blue" }"#)
            case ("PATCH", "/v1/profiles/p2"):
                .json(200, #"{ "id": "p2", "name": "Alex", "color": "red" }"#)
            case ("DELETE", "/v1/profiles/p2"):
                StubResponse(status: 204)
            default:
                .error(404, "not_found")
            }
        }
        let client = try stub.client()

        #expect(try await client.profiles() == [Profile(id: "p1", name: "Robin", color: "teal")])
        #expect(try await client.createProfile(name: "Alex", color: "blue").id == "p2")
        #expect(try await client.updateProfile(id: "p2", color: "red").color == "red")
        let patch = try #require(stub.recorded.last)
        #expect(try patch.json().keys.sorted() == ["color"])
        try await client.deleteProfile(id: "p2")
    }

    @Test func fetchesALibraryPageAndAnItem() async throws {
        let stub = StubServer { request in
            request.path == "/v1/library"
                ? .json(200, Fixtures.libraryPage(items: [Fixtures.movie], cursor: "c-2"))
                : .json(200, #"{ "item": \#(Fixtures.movie), "children": [] }"#)
        }
        let client = try stub.client()

        let page = try await client.library(cursor: "c-1", limit: 250)
        #expect(page.cursor == "c-2")
        #expect(stub.recorded[0].query == ["cursor": "c-1", "limit": "250"])

        _ = try await client.library(cursor: nil)
        #expect(stub.recorded[1].query.isEmpty)

        let detail = try await client.item(id: "a/b c")
        #expect(detail.item.id == "movie-1")
        #expect(stub.recorded[2].path == "/v1/items/a%2Fb%20c")
    }

    @Test func getsAndPutsProgress() async throws {
        let stub = StubServer { request in
            request.method == "GET"
                ? .json(200, #"{ "progress": [\#(Fixtures.progress(itemId: "movie-1", positionMs: 1000, revision: 4812, updatedAt: 1795531000000))], "revision": 4812 }"#)
                : .json(200, #"{ "progress": \#(Fixtures.progress(itemId: "movie-1", positionMs: 1264000, revision: 4813, updatedAt: 1795531000000)) }"#)
        }
        let client = try stub.client()

        let list = try await client.progress(profileID: "p1", since: 4790)
        #expect(list.revision == 4812)
        #expect(list.progress[0].positionMs == 1000)
        #expect(stub.recorded[0].path == "/v1/profiles/p1/progress")
        #expect(stub.recorded[0].query == ["since": "4790"])

        let update = ProgressUpdate(
            opId: "op-1", baseRevision: 4790, positionMs: 1_264_000, durationMs: 3_480_000, completed: false,
            updatedAt: Date(millisecondsSince1970: 1_795_531_000_000))
        let accepted = try await client.putProgress(profileID: "p1", itemID: "movie-1", update: update)
        #expect(accepted.revision == 4813)

        let put = stub.recorded[1]
        #expect(put.method == "PUT")
        #expect(put.path == "/v1/profiles/p1/progress/movie-1")
        let body = try put.json()
        #expect(body["opId"] as? String == "op-1")
        #expect(body["baseRevision"] as? Int == 4790)
        #expect(body["positionMs"] as? Int == 1_264_000)
        #expect(body["durationMs"] as? Int == 3_480_000)
        #expect(body["completed"] as? Bool == false)
        #expect(body["updatedAt"] as? Int == 1_795_531_000_000)
    }

    // MARK: Errors

    @Test func aConflictCarriesTheServersProgress() async throws {
        let server = Fixtures.progress(itemId: "movie-1", positionMs: 0, revision: 4900, updatedAt: 1_795_532_000_000)
        let stub = StubServer { _ in
            .error(409, "conflict", "A newer change exists.", extra: #", "progress": \#(server)"#)
        }
        let update = ProgressUpdate(opId: "op", baseRevision: 1, positionMs: 5, durationMs: nil, completed: false, updatedAt: Date())

        let error = await #expect(throws: LobbyError.self) {
            try await stub.client().putProgress(profileID: "p1", itemID: "movie-1", update: update)
        }
        guard case .conflict(let message, let progress) = error else {
            Issue.record("Expected a conflict, got \(String(describing: error))")
            return
        }
        #expect(message == "A newer change exists.")
        #expect(progress?.revision == 4900)
        #expect(progress?.positionMs == 0)
    }

    @Test func tellsRevokedFromUnauthorizedFromUnreachable() async throws {
        let revoked = StubServer { _ in .error(401, "device_revoked", "This device was removed.") }
        let unknown = StubServer { _ in .error(401, "unauthorized", "Pair this device first.") }
        let offline = StubServer { _ in throw URLError(.cannotConnectToHost) }

        let revokedError = await #expect(throws: LobbyError.self) { try await revoked.client().profiles() }
        #expect(revokedError == .deviceRevoked(message: "This device was removed."))
        #expect(revokedError?.requiresPairing == true)
        #expect(revokedError?.isUnreachable == false)

        let unknownError = await #expect(throws: LobbyError.self) { try await unknown.client().profiles() }
        #expect(unknownError == .unauthorized(message: "Pair this device first."))
        #expect(unknownError?.requiresPairing == true)

        let offlineError = await #expect(throws: LobbyError.self) { try await offline.client().profiles() }
        #expect(offlineError == .unreachable(.cannotConnectToHost))
        #expect(offlineError?.isUnreachable == true)
        #expect(offlineError?.requiresPairing == false)
    }

    @Test(arguments: [
        (400, "invalid_request", LobbyError.invalidRequest(message: "No.")),
        (403, "forbidden", .forbidden(message: "No.")),
        (404, "not_found", .notFound(message: "No.")),
        (409, "conflict", .conflict(message: "No.", progress: nil)),
        (410, "gone", .gone(message: "No.")),
        (416, "range_not_satisfiable", .rangeNotSatisfiable(message: "No.")),
        (503, "unavailable", .unavailable(message: "No.")),
        (418, "teapot", .server(status: 418, code: "teapot", message: "No.")),
    ])
    func mapsEveryErrorCode(status: Int, code: String, expected: LobbyError) async throws {
        let stub = StubServer { _ in .error(status, code) }
        await #expect(throws: expected) { try await stub.client().profiles() }
    }

    @Test func rateLimitingCarriesRetryAfter() async throws {
        let stub = StubServer { _ in
            .json(429, #"{ "error": { "code": "rate_limited", "message": "Too many wrong codes." } }"#, headers: ["Retry-After": "120"])
        }
        await #expect(throws: LobbyError.rateLimited(message: "Too many wrong codes.", retryAfter: 120)) {
            try await stub.client().approvePairing(code: "000000", role: .viewer)
        }
    }

    @Test func anErrorThatIsNotFromLobbyStillMapsByStatus() async throws {
        let gateway = StubServer { _ in StubResponse(status: 502, body: Data("<html>Bad gateway</html>".utf8)) }
        let error = await #expect(throws: LobbyError.self) { try await gateway.client().profiles() }
        guard case .server(status: 502, code: nil, _) = error else {
            Issue.record("Expected a 502, got \(String(describing: error))")
            return
        }
        #expect(error?.isTransient == true)

        let plain401 = StubServer { _ in StubResponse(status: 401) }
        let unauthorized = await #expect(throws: LobbyError.self) { try await plain401.client().profiles() }
        #expect(unauthorized?.requiresPairing == true)
    }

    @Test func anAnswerInAnotherShapeIsAnInvalidResponse() async throws {
        let stub = StubServer { _ in .json(200, #"{ "profiles": "none" }"#) }
        let error = await #expect(throws: LobbyError.self) { try await stub.client().profiles() }
        guard case .invalidResponse = error else {
            Issue.record("Expected an invalid response, got \(String(describing: error))")
            return
        }
    }

    // MARK: Media

    @Test func buildsMediaURLsAndTheDeviceCookie() throws {
        let client = try LobbyClient(baseURL: URL(string: "https://lobby.example.ts.net:8443")!, token: "secret-token")

        let media = client.mediaURL(assetID: "asset 1")
        #expect(media.absoluteString == "https://lobby.example.ts.net:8443/v1/assets/asset%201/content")
        #expect(!media.absoluteString.contains("secret-token"))
        #expect(client.authorizedRequest(for: media).value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")

        let cookie = try #require(client.deviceCookie())
        #expect(cookie.name == "lobby_device")
        #expect(cookie.value == "secret-token")
        #expect(cookie.domain == "lobby.example.ts.net")
        #expect(cookie.path == "/")
        #expect(cookie.isSecure)

        let plain = try LobbyClient(baseURL: URL(string: "http://192.168.1.20:8484")!, token: "secret-token")
        #expect(plain.deviceCookie()?.isSecure == false)
        #expect(plain.deviceCookie()?.domain == "192.168.1.20")
        #expect(try LobbyClient(baseURL: URL(string: "http://lobby.local")!).deviceCookie() == nil)
    }

    // MARK: Artwork and subtitles

    @Test func buildsArtworkAndSubtitleURLs() throws {
        let client = try LobbyClient(baseURL: URL(string: "http://lobby.local:8484")!, token: "secret-token")
        let subtitle = SubtitleTrack(id: "s3", source: .embedded, codec: "subrip", language: "nld", title: nil, isForced: false, isText: true)

        #expect(client.artworkURL(Artwork(id: "art-1"), width: .w400).absoluteString == "http://lobby.local:8484/v1/artwork/art-1?w=400")
        #expect(client.subtitleURL(assetID: "asset-1", subtitle: subtitle).absoluteString == "http://lobby.local:8484/v1/assets/asset-1/subtitles/s3.vtt")
        #expect(ArtworkWidth.covering(pixels: 390) == .w400)
        #expect(ArtworkWidth.covering(pixels: 401) == .w800)
        #expect(ArtworkWidth.covering(pixels: 801) == .w1280)
        #expect(ArtworkWidth.covering(pixels: 1601) == .w1920)
        #expect(ArtworkWidth.covering(pixels: 4000) == .w1920)
    }

    // MARK: Playback

    @Test func aFileThatPlaysDirectlyIsReadyAtOnce() async throws {
        // Captured from the Pi (asset id shortened).
        let stub = StubServer { _ in
            .json(200, #"{"state":"ready","mode":"direct","revision":"fae00098914695ce","progress":1,"preparedMs":4129208,"durationMs":4129208,"streamUrl":"/v1/assets/asset-1/content","downloadUrl":"/v1/assets/asset-1/content","downloadBytes":1322669077,"audio":[{"index":1,"codec":"aac","converted":false,"language":"eng","title":null,"channels":2,"isDefault":true}],"message":null}"#)
        }
        let playback = try await stub.client().playback(assetID: "asset-1")

        #expect(playback.state == .ready)
        #expect(playback.mode == .direct)
        #expect(playback.revision == "fae00098914695ce")
        // The relative URL is resolved against the server, and carries no credential.
        #expect(playback.streamURL?.absoluteString == "http://\(stub.host)/v1/assets/asset-1/content")
        #expect(playback.downloadURL == playback.streamURL)
        #expect(playback.downloadBytes == 1_322_669_077)
        #expect(playback.audio == [PlaybackAudio(index: 1, codec: "aac", converted: false, language: "eng", title: nil, channels: 2, isDefault: true)])
        #expect(playback.canStart(atMs: 4_000_000))
        #expect(stub.recorded.first?.method == "POST")
        #expect(stub.recorded.first?.path == "/v1/assets/asset-1/playback")
        #expect(stub.recorded.first?.body.isEmpty == true)
    }

    @Test func aCopyBeingWrittenAnswers202AndIsPlayableUpToWhatIsPrepared() async throws {
        let stub = StubServer { _ in
            .json(202, #"{"state":"preparing","mode":"prepared","revision":"r1","progress":0.25,"preparedMs":1500000,"durationMs":6000000,"streamUrl":"/v1/assets/asset-1/prepared/r1/master.m3u8","downloadUrl":null,"downloadBytes":null,"audio":[{"index":1,"codec":"aac","converted":true,"language":null,"title":"DTS-HD","channels":6,"isDefault":true}],"message":null}"#)
        }
        let playback = try await stub.client().playback(assetID: "asset-1")

        #expect(playback.state == .preparing)
        #expect(playback.mode == .prepared)
        #expect(playback.progress == 0.25)
        #expect(playback.streamURL?.path == "/v1/assets/asset-1/prepared/r1/master.m3u8")
        #expect(playback.downloadURL == nil)
        #expect(playback.audio.first?.converted == true)
        #expect(playback.canStart(atMs: 0))
        #expect(playback.canStart(atMs: 1_500_000))
        // Resuming further in has to wait for the copy to get there.
        #expect(!playback.canStart(atMs: 3_000_000))
    }

    @Test func aQueuedOrJustStartedCopyHasNothingToPlayYet() async throws {
        let stub = StubServer { _ in
            .json(202, #"{"state":"queued","mode":"prepared","revision":"r1","progress":0,"preparedMs":0,"durationMs":6000000,"streamUrl":null,"downloadUrl":null,"downloadBytes":null,"audio":[],"message":null}"#)
        }
        let playback = try await stub.client().playback(assetID: "asset-1")
        #expect(playback.state == .queued)
        #expect(playback.streamURL == nil)
        #expect(!playback.canStart(atMs: 0))
    }

    @Test func aFileThatCannotBePlayedCarriesTheReason() async throws {
        let stub = StubServer { _ in
            .json(200, #"{"state":"unsupported","mode":null,"revision":"r1","progress":0,"preparedMs":0,"durationMs":null,"streamUrl":null,"downloadUrl":null,"downloadBytes":null,"audio":[],"message":"The video is MPEG4, which Apple devices do not play."}"#)
        }
        let playback = try await stub.client().playback(assetID: "asset-1")
        #expect(playback.state == .unsupported)
        #expect(playback.mode == nil)
        #expect(playback.message == "The video is MPEG4, which Apple devices do not play.")
        #expect(!playback.canStart(atMs: 0))
    }

    @Test func anOldAVIBeingConvertedSaysSoAndHowFast() async throws {
        let stub = StubServer { _ in
            .json(202, #"{"state":"preparing","mode":"prepared","revision":"r1","progress":0.1,"preparedMs":600000,"durationMs":6000000,"streamUrl":"/v1/assets/asset-1/prepared/r1/master.m3u8","downloadUrl":null,"downloadBytes":null,"audio":[],"videoConverted":true,"speed":1.5,"message":null}"#)
        }
        let playback = try await stub.client().playback(assetID: "asset-1")
        #expect(playback.videoConverted)
        #expect(playback.speed == 1.5)
        // 90 minutes of film to go, at one and a half times playback speed: an hour.
        #expect(playback.estimatedTimeLeft == .seconds(3600))
    }

    @Test func withoutASpeedThereIsNoEstimate() async throws {
        let stub = StubServer { _ in
            .json(202, #"{"state":"preparing","mode":"prepared","revision":"r1","progress":0,"preparedMs":0,"durationMs":6000000,"streamUrl":null,"downloadUrl":null,"downloadBytes":null,"audio":[],"videoConverted":false,"speed":null,"message":null}"#)
        }
        let playback = try await stub.client().playback(assetID: "asset-1")
        #expect(!playback.videoConverted)
        #expect(playback.speed == nil)
        #expect(playback.estimatedTimeLeft == nil)
    }

    @Test func aTextSubtitleIsFetchedWithTheCredential() async throws {
        let stub = StubServer { _ in StubResponse(status: 200, body: Data("WEBVTT\n\n00:01.000 --> 00:02.000\nHallo\n".utf8)) }
        let track = SubtitleTrack(id: "s3", source: .sidecar, codec: "subrip", language: "nld", title: nil, isForced: false, isText: true)
        let text = try await stub.client().subtitle(assetID: "asset-1", subtitle: track)
        #expect(text.hasPrefix("WEBVTT"))
        #expect(stub.recorded.first?.path == "/v1/assets/asset-1/subtitles/s3.vtt")
        #expect(stub.recorded.first?.headers["Authorization"] == "Bearer test-token")
    }

    @Test func aStateFromANewerServerSurvives() async throws {
        let stub = StubServer { _ in
            .json(200, #"{"state":"paused","mode":"prepared","revision":"r1","progress":0,"preparedMs":0,"durationMs":null,"streamUrl":null,"downloadUrl":null,"downloadBytes":null,"audio":[],"message":null}"#)
        }
        #expect(try await stub.client().playback(assetID: "asset-1").state == .unknown("paused"))
    }

    @Test func anEvictedOrUnknownAssetIsNotFoundAndAMissingDriveUnavailable() async throws {
        let missing = StubServer { _ in .error(404, "not_found") }
        await #expect(throws: LobbyError.notFound(message: "No.")) {
            try await missing.client().playback(assetID: "gone")
        }
        let unplugged = StubServer { _ in .error(503, "unavailable") }
        await #expect(throws: LobbyError.unavailable(message: "No.")) {
            try await unplugged.client().playback(assetID: "asset-1")
        }
    }
}

@Suite struct WantedClientTests {
    static let list = #"""
        { "revision": "w7", "leftOut": 0, "assets": [
          { "assetId": "a1", "itemId": "film", "revision": "r1", "order": 1, "bytes": 1048576, "bytesExact": true, "state": "ready",
            "mode": "direct", "downloadUrl": "/v1/assets/a1/content", "message": null, "why": [{ "wantedId": "w1", "kind": "item" }] },
          { "assetId": "a2", "itemId": "ep", "revision": "r1", "order": 2, "bytes": 5, "bytesExact": false, "state": "something_new",
            "mode": null, "downloadUrl": null, "message": "Later.", "why": [] } ] }
        """#

    @Test func aDeviceReadsItsListAndIsToldWhenNothingChanged() async throws {
        let stub = StubServer { request in
            request.headers["If-None-Match"] == "\"w7\"" ? StubResponse(status: 304) : .json(200, Self.list)
        }
        let list = try #require(try await stub.client().myWanted())
        #expect(list.revision == "w7")
        #expect(list.assets.map(\.state) == [.ready, .unknown])
        #expect(list.assets[0].downloadUrl == "/v1/assets/a1/content")
        #expect(stub.recorded[0].path == "/v1/me/wanted")
        #expect(try await stub.client().myWanted(knownRevision: "w7") == nil)
    }

    @Test func aDeviceReportsWhatItHas() async throws {
        let stub = StubServer { _ in .json(200, #"{ "accepted": 1, "wantedRevision": "w8" }"#) }
        let report = DownloadsReport(freeBytes: 10, totalBytes: 20, downloads: [
            .init(assetId: "a1", revision: "r1", state: .failed, bytesDone: 0, bytesTotal: 5, error: .noSpace, own: false)
        ])
        #expect(try await stub.client().reportDownloads(report) == "w8")
        let request = try #require(stub.recorded.first)
        #expect(request.method == "POST" && request.path == "/v1/me/downloads")
        let entry = try #require((try request.json()["downloads"] as? [[String: Any]])?.first)
        #expect(entry["state"] as? String == "failed")
        #expect(entry["error"] as? String == "no_space")
        #expect(entry["own"] as? Bool == false)
    }

    @Test func aManagerPutsATitleAndARuleOnADeviceAndTakesThemOff() async throws {
        let entry = #"{ "entry": { "id": "w1", "kind": "next_unwatched", "itemId": "show", "itemKind": "show", "profileId": "p1", "count": 3, "addedBy": null, "addedAt": 1795530000000 } }"#
        let stub = StubServer { request in request.method == "DELETE" ? StubResponse(status: 204) : .json(201, entry) }
        let client = try stub.client()
        _ = try await client.addWanted(deviceID: "d 1", itemID: "film")
        let rule = try await client.addWantedNextEpisodes(deviceID: "d1", showID: "show", profileID: "p1", count: 3)
        #expect(rule.kind == .nextUnwatched && rule.count == 3)
        try await client.removeWanted(deviceID: "d1", wantedID: "w1")

        #expect(stub.recorded.map(\.path) == ["/v1/devices/d%201/wanted", "/v1/devices/d1/wanted", "/v1/devices/d1/wanted/w1"])
        #expect(try stub.recorded[0].json()["kind"] as? String == "item")
        let body = try stub.recorded[1].json()
        #expect(body["kind"] as? String == "next_unwatched")
        #expect(body["showId"] as? String == "show" && body["count"] as? Int == 3)
    }
}

@Suite struct ServerSettingsClientTests {
    @Test func aValueGoesBackAsItCame() throws {
        let json = #"{"a":null,"b":true,"c":30,"d":2.5,"e":"x","f":[1,"y"],"g":{"h":false}}"#
        let value = try JSONDecoder().decode(SettingValue.self, from: Data(json.utf8))
        guard case .object(let fields) = value else { return #expect(Bool(false)) }
        #expect(fields["a"] == .null)
        #expect(fields["b"] == .bool(true))
        #expect(fields["c"] == .number(30))
        #expect(fields["e"] == .string("x"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // A whole number stays one: the server tells 30 from 30.5.
        #expect(String(decoding: try encoder.encode(value), as: UTF8.self) == json)
    }

    @Test func aLibraryFolderKeepsWhatItDoesNotShow() throws {
        let value = SettingValue.object([
            "path": .string("/media/Pixar"), "hint": .string("movies"), "group": .string("Kids"), "logo": .string("/abc.png"),
        ])
        let folder = try #require(LibraryFolder(value))
        #expect(folder.isForKids)
        #expect(folder.displayName == "Pixar")
        #expect(folder.value == value)
        #expect(LibraryFolder(.string("nope")) == nil)
    }

    @Test func aManagerIsToldWhetherTheSetupIsToDo() throws {
        let json = #"{ "id": "srv-1", "name": "Lobby", "version": "0.1.0", "apiVersion": 1, "claimed": true, "claim": "open", "setup": {"needed": true, "steps": [{"id": "folders", "done": false, "skipped": false}]} }"#
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(json.utf8))
        #expect(info.setup?.needed == true)
        #expect(info.setup?.isDone("folders") == false)
        let older = try JSONDecoder().decode(ServerInfo.self, from: Data(LobbyClientTests.server.utf8))
        #expect(older.setup == nil)
    }

    @Test func theServerSaysTheOldestAppItWorksWith() throws {
        let json = #"{ "id": "srv-1", "name": "Lobby", "version": "0.2.0", "apiVersion": 1, "minAppVersion": "0.1.0", "claimed": true }"#
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(json.utf8))
        #expect(info.minAppVersion == "0.1.0")
        let older = try JSONDecoder().decode(ServerInfo.self, from: Data(LobbyClientTests.server.utf8))
        #expect(older.minAppVersion == nil)
    }

    @Test func changesGoWithTheirVersionAndAsADryRun() async throws {
        let answer = #"{"dryRun":true,"version":2,"changed":["serverName"],"effects":[{"key":"serverName","title":"Name","apply":"live","message":"Devices will show “Den”."}],"restart":false,"restarting":false,"rescanFolders":0,"bootId":"b"}"#
        let stub = StubServer { _ in .json(200, answer) }
        let change = try await stub.client(token: "t").changeSettings(["serverName": .string("Den")], baseVersion: 2, dryRun: true)
        #expect(change.effects.first?.message == "Devices will show “Den”.")
        let request = try #require(stub.recorded.first)
        #expect(request.method == "PATCH")
        #expect(request.path == "/v1/settings")
        let body = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["dryRun"] as? Bool == true)
        #expect(body["baseVersion"] as? Int == 2)
        #expect((body["changes"] as? [String: Any])?["serverName"] as? String == "Den")
    }
}
