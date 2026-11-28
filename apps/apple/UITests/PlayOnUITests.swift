// SPDX-License-Identifier: MPL-2.0
import XCTest

/// Play On, from a film's page, to a television of the household. The television is a device
/// this test pairs with the local Lobby Server and opens the live channel for, over the real API:
/// what the app sends reaches it through the server, and what it says the app shows.
final class PlayOnUITests: LobbyUITestCase {
    func testPlayOnATelevisionAndOfferAirPlayToOneThatIsOff() async throws {
        let servers = try TestServers.load()
        let manager = ManagerAPI(server: servers.paired)
        try await manager.removeOtherDevices()
        let livingRoom = try await Television.pair("Living Room", servers: servers)
        _ = try await Television.pair("Bedroom", servers: servers)
        try await livingRoom.open()
        defer { Task { await livingRoom.close() } }

        launch()
        try await pair(with: servers)
        waitFor(app.buttons["profile.Alex"], "The viewer picker").tap()
        waitFor(shelf("movies").buttons["The Long Test, 2019"], "The film on its shelf").tap()

        // Play On is there because a television is.
        waitFor(app.buttons["detail.playOn"], "Play On", timeout: 20).tap()
        waitFor(element("playOn.device.Living Room"), "The open television")
        let bedroom = waitFor(element("playOn.device.Bedroom"), "The television that is off")
        XCTAssertTrue(bedroom.label.contains("Lobby is not open"), bedroom.label)
        attachScreenshot("play-on")

        // One that is off: AirPlay, which wakes it, and what that does not do.
        app.buttons["playOn.airPlay.Bedroom"].tap()
        waitFor(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Open Lobby on Bedroom")).firstMatch, "What AirPlay does not do")
        attachScreenshot("play-on-airplay")

        // One that is open plays it, and the app shows what it plays.
        app.buttons["playOn.play.Living Room"].tap()
        let command = try await livingRoom.nextPlay(timeout: 15)
        let alex = try await manager.viewerIDForTests("Alex")
        let film = try await manager.itemID(titled: "The Long Test")
        XCTAssertEqual(command.profileId, alex)
        XCTAssertEqual(command.itemId, film)
        if UIDevice.current.userInterfaceIdiom == .pad {
            // iPad: a panel beside the page, with the remote in it.
            waitFor(element("nowPlaying.panel"), "The now-playing panel", timeout: 15)
            XCTAssertTrue(waitFor(element("remote.title"), "The remote").label.contains("The Long Test"))
            attachScreenshot("now-playing")
        } else {
            waitFor(element("nowPlaying.open"), "The now-playing bar", timeout: 15)
            XCTAssertTrue(element("nowPlaying.open").label.contains("The Long Test"), element("nowPlaying.open").label)
            attachScreenshot("now-playing")

            element("nowPlaying.open").tap()
            waitFor(element("remote.title"), "The remote")
        }
        app.buttons["Back 10 Seconds"].tap()
        let skip = try await livingRoom.next(timeout: 10)
        XCTAssertEqual(skip.type, "skip")
        XCTAssertEqual(skip.deltaMs, -10_000)
        attachScreenshot("remote")
    }
}

extension ManagerAPI {
    func viewerIDForTests(_ name: String) async throws -> String {
        var request = URLRequest(url: server.url.appending(path: "v1/profiles"))
        request.setValue("Bearer \(server.managerToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let list = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let all = list?["profiles"] as? [[String: Any]] ?? []
        guard let id = all.first(where: { $0["name"] as? String == name })?["id"] as? String else {
            throw NSError(domain: "ManagerAPI", code: 404, userInfo: [NSLocalizedDescriptionKey: "No viewer \(name)."])
        }
        return id
    }
}

/// A television of the household as the server sees one: paired, its channel open, and doing
/// what it is asked as far as saying so. It plays nothing itself.
actor Television {
    let name: String
    private let base: URL
    private let token: String
    private let session = UUID().uuidString.lowercased()
    /// What it was asked, as the channel said it.
    struct Asked: Decodable, Sendable {
        var type: String
        var itemId: String?
        var profileId: String?
        var deltaMs: Int?
    }

    private var commands: [Asked] = []
    private var reading: Task<Void, Never>?
    private var order = 0
    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration)
    }()

    private init(name: String, base: URL, token: String) {
        self.name = name
        self.base = base
        self.token = token
    }

    /// Pairs as the television would: it asks, the manager types its code, it collects.
    static func pair(_ name: String, servers: TestServers) async throws -> Television {
        let base = servers.paired.url
        var ask = URLRequest(url: base.appending(path: "v1/pairing/requests"))
        ask.httpMethod = "POST"
        ask.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ask.httpBody = try JSONSerialization.data(withJSONObject: ["deviceName": name, "platform": "tvos"])
        let (asked, _) = try await URLSession.shared.data(for: ask)
        let waiting = try JSONSerialization.jsonObject(with: asked) as? [String: Any] ?? [:]
        let code = waiting["code"] as? String ?? ""
        try await ManagerAPI(server: servers.paired).approve(code: code)
        var collect = URLRequest(url: base.appending(path: "v1/pairing/requests/\(waiting["id"] as? String ?? "")/collect"))
        collect.httpMethod = "POST"
        collect.setValue("application/json", forHTTPHeaderField: "Content-Type")
        collect.httpBody = try JSONSerialization.data(withJSONObject: ["pollSecret": waiting["pollSecret"] as? String ?? ""])
        let (collected, _) = try await URLSession.shared.data(for: collect)
        let grant = try JSONSerialization.jsonObject(with: collected) as? [String: Any] ?? [:]
        guard let token = grant["token"] as? String else { throw XCTSkip("The television could not pair: \(String(decoding: collected, as: UTF8.self))") }
        return Television(name: name, base: base, token: token)
    }

    /// Opens the channel and says that Lobby is open, idle, and can play.
    func open() async throws {
        var request = URLRequest(url: base.appending(path: "v1/live").appending(queryItems: [URLQueryItem(name: "session", value: session)]))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await urlSession.bytes(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        reading = Task { [weak self] in
            var event = ""
            do {
                for try await line in bytes.lines {
                    if line.hasPrefix("event: ") { event = String(line.dropFirst(7)) }
                    guard line.hasPrefix("data: "), let self else { continue }
                    if Task.isCancelled { return }
                    let data = Data(line.dropFirst(6).utf8)
                    if event == "command" { await self.take(data) }
                }
            } catch {}
        }
        try await announce(player: NSNull())
        // At least every five seconds, as a device does.
        Task { [weak self] in
            while let self, await self.isOpen {
                try? await Task.sleep(for: .seconds(4))
                try? await self.announce(player: nil)
            }
        }
    }

    private var isOpen: Bool { reading != nil }

    /// Says that a film plays here, part-way, and what comes after it.
    func show(itemId: String, positionMs: Int, durationMs: Int, nextItemId: String?, status: String = "playing") async throws {
        try await announce(player: [
            "itemId": itemId, "assetId": NSNull(), "profileId": NSNull(), "status": status, "positionMs": positionMs, "ageMs": 0,
            "durationMs": durationMs, "rate": 1, "audioTracks": [], "audioTrackId": NSNull(), "subtitleTracks": [],
            "subtitleTrackId": NSNull(), "volume": NSNull(), "nextItemId": nextItemId ?? NSNull(), "queue": [],
        ] as [String: Any])
    }

    func close() {
        reading?.cancel()
        reading = nil
    }

    private func take(_ data: Data) async {
        guard let said = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = said["commandId"] as? String, let command = said["command"] as? [String: Any] else { return }
        if let data = try? JSONSerialization.data(withJSONObject: command),
            let asked = try? JSONDecoder().decode(Asked.self, from: data)
        {
            commands.append(asked)
        }
        var player: Any?
        if command["type"] as? String == "play" {
            player = [
                "itemId": command["itemId"] ?? NSNull(), "assetId": NSNull(), "profileId": command["profileId"] ?? NSNull(),
                "status": "playing", "positionMs": 30_000, "ageMs": 0, "durationMs": 60_000, "rate": 1,
                "audioTracks": [], "audioTrackId": NSNull(), "subtitleTracks": [], "subtitleTrackId": NSNull(),
                "volume": NSNull(), "nextItemId": NSNull(), "queue": [],
            ] as [String: Any]
        }
        var body: [String: Any] = ["commandId": id, "status": "done"]
        if let player { body["player"] = player }
        _ = try? await post("v1/live/\(session)/results", body)
    }

    private func announce(player: Any?) async throws {
        order += 1
        var body: [String: Any] = [
            "order": order, "foreground": true, "canPlay": true, "profileId": NSNull(),
            "capabilities": ["play", "pause", "resume", "seek", "skip", "next", "stop"],
        ]
        if let player { body["player"] = player }
        _ = try await post("v1/live/\(session)", body)
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await urlSession.data(for: request).0
    }

    /// The next command, whatever it is.
    func next(timeout: TimeInterval) async throws -> Asked {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if !commands.isEmpty { return commands.removeFirst() }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "Television", code: 0, userInfo: [NSLocalizedDescriptionKey: "\(name) was asked nothing."])
    }

    /// The next `play`, with what came before it left aside.
    func nextPlay(timeout: TimeInterval) async throws -> Asked {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let command = try await next(timeout: end.timeIntervalSinceNow)
            if command.type == "play" { return command }
        }
        throw NSError(domain: "Television", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(name) was not asked to play."])
    }
}
