// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

/// Playing on another device, apart from the network: what the channel says, where a film on
/// another device is now, and how the screens list the household's devices.
struct RemoteTests {
    private static let fixtures = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appending(path: "docs/fixtures/remote")

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixtures.appending(path: name))
    }

    private func state(_ status: RemotePlayerStatus, at position: Int = 600_000, time: Int64 = 1_000_000, duration: Int? = 5_400_000, rate: Double = 1) -> RemotePlayerState {
        RemotePlayerState(itemId: "film", status: status, positionMs: position, at: time, durationMs: duration, rate: rate)
    }

    // MARK: Where it is now

    @Test func aPlayingFilmMovesOnByTheServersClock() {
        let playing = state(.playing)
        #expect(playing.positionMs(atServerTime: 1_000_000) == 600_000)
        #expect(playing.positionMs(atServerTime: 1_002_500) == 602_500)
        // A clock that is behind does not take it back.
        #expect(playing.positionMs(atServerTime: 999_000) == 600_000)
    }

    @Test func aPausedOrWaitingFilmStaysWhereItWas() {
        for status in [RemotePlayerStatus.paused, .loading, .buffering, .ended, .error] {
            #expect(state(status).positionMs(atServerTime: 1_060_000) == 600_000)
        }
    }

    @Test func aFilmDoesNotRunPastItsEndAndFollowsItsSpeed() {
        #expect(state(.playing, at: 5_399_000).positionMs(atServerTime: 1_010_000) == 5_400_000)
        #expect(state(.playing, rate: 2).positionMs(atServerTime: 1_001_000) == 602_000)
        #expect(state(.playing, duration: nil).positionMs(atServerTime: 1_001_000) == 601_000)
    }

    @Test func theServersClockIsTakenFromTheQuickestAnswer() {
        var clock = ServerClock()
        #expect(clock.serverNow(steadyMs: 0) == nil)
        // Heard in an event first: the best there is.
        clock.heard(serverTime: 5_000, atMs: 100)
        #expect(clock.serverNow(steadyMs: 200) == 5_100)
        // A post answered in 40 ms: half of it is on the way back.
        clock.measure(serverTime: 10_000, sentMs: 1_000, receivedMs: 1_040)
        #expect(clock.serverNow(steadyMs: 1_040) == 10_020)
        // A slow answer does not replace a quick one.
        clock.measure(serverTime: 20_000, sentMs: 2_000, receivedMs: 2_900)
        #expect(clock.serverNow(steadyMs: 2_900) == 11_880)
        // A quicker one does.
        clock.measure(serverTime: 30_000, sentMs: 3_000, receivedMs: 3_010)
        #expect(clock.serverNow(steadyMs: 3_010) == 30_005)
    }

    @Test func aReportIsSentAgainOnlyWhenItSaysSomethingNew() {
        let report = PlayerReport(itemId: "film", assetId: "a", profileId: "p", status: .playing, positionMs: 10_000, durationMs: 60_000, rate: 1)
        var later = report
        later.positionMs = 15_000
        #expect(later.sameApartFromPlace(as: report))
        #expect(report.expectedPositionMs(afterMs: 5_000) == 15_000)
        var paused = report
        paused.status = .paused
        #expect(!paused.sameApartFromPlace(as: report))
        #expect(paused.expectedPositionMs(afterMs: 5_000) == 10_000)
    }

    // MARK: What the channel says

    @Test func theChannelIsReadLineByLine() throws {
        let text = String(decoding: try fixture("stream.txt"), as: UTF8.self)
        var parser = LiveEventParser()
        var raws: [LiveEventParser.Raw] = []
        // With the line endings of a server that writes CR LF too.
        for line in text.replacingOccurrences(of: "\n", with: "\r\n").components(separatedBy: "\r\n") {
            if let raw = parser.feed(line) { raws.append(raw) }
        }
        if let raw = parser.feed("") { raws.append(raw) }
        let events = raws.compactMap(LiveEventParser.decode)
        #expect(raws.map(\.event) == ["hello", "snapshot", "heartbeat", "gone"])
        #expect(raws.map(\.id) == [nil, "1f0c2d3e.1", nil, "1f0c2d3e.2"])
        guard case .hello(let hello) = events.first else {
            Issue.record("no hello")
            return
        }
        #expect(hello.heartbeatMs == 5_000)
        #expect(hello.silentMs == 12_000)
        #expect(hello.resumed == false)
        #expect(events.last == .gone(deviceID: "device-tv", serverTime: 1_795_640_006_000))
    }

    @Test func everyEventOfTheContractIsUnderstood() throws {
        struct Example: Decodable {
            var event: String
            var data: AnyJSON
        }
        let examples = try JSONDecoder().decode([Example].self, from: try fixture("events.json"))
        #expect(!examples.isEmpty)
        for example in examples {
            let data = String(decoding: try JSONEncoder().encode(example.data), as: UTF8.self)
            let event = LiveEventParser.decode(.init(id: nil, event: example.event, data: data))
            #expect(event != nil, "\(example.event) was not read")
            if case .unknown = event { Issue.record("\(example.event) is not known") }
        }
        // And one a newer server might send is passed over.
        #expect(LiveEventParser.decode(.init(id: nil, event: "weather", data: "{}")) == .unknown("weather"))
    }

    @Test func aTitleThisDeviceMayNotSeeIsOnlyPlaying() throws {
        let json = #"{"id":"tv","name":"Living room","platform":"tvos","isSelf":false,"isKids":true,"online":true,"foreground":true,"canPlay":true,"controllable":false,"capabilities":["pause"],"player":{"redacted":true,"status":"playing"}}"#
        let device = try JSONDecoder().decode(ShownDevice.self, from: Data(json.utf8))
        #expect(device.player == .redacted(status: .playing))
        #expect(device.player?.state == nil)
        #expect(RemoteTargets.state(of: device) { _ in "Never this" } == "Playing")
    }

    @Test func commandsAreSentAsTheContractHasThem() throws {
        struct Sent: Decodable {
            var id: String
            var session: String
            var deviceId: String
            var command: AnyJSON
        }
        let examples = try JSONDecoder().decode([Sent].self, from: try fixture("commands.json"))
        for example in examples {
            let data = try JSONEncoder().encode(example.command)
            let command = try JSONDecoder().decode(RemoteCommand.self, from: data)
            if case .unknown(let type) = command { Issue.record("\(type) is not known") }
            let again = try JSONDecoder().decode(AnyJSON.self, from: try LobbyJSON.encoder().encode(command))
            #expect(again == example.command, "\(command.type) changed on the way")
        }
    }

    @Test func anAnnouncementLeavesOutOrSaysNothingAsAsked() throws {
        func encoded(_ field: Announcement.PlayerField) throws -> [String: Any] {
            let announcement = Announcement(order: 1, foreground: true, canPlay: true, profileId: nil, capabilities: ["play"], player: field)
            return try #require(JSONSerialization.jsonObject(with: try LobbyJSON.encoder().encode(announcement)) as? [String: Any])
        }
        #expect(try encoded(.unchanged)["player"] == nil)
        #expect(try encoded(.nothing)["player"] is NSNull)
        let report = PlayerReport(itemId: "film-a", assetId: "file-a", profileId: "viewer-1", status: .playing, positionMs: 600_000, ageMs: 40, durationMs: 5_400_000, rate: 1)
        let player = try #require(try encoded(.playing(report))["player"] as? [String: Any])
        let expected = try #require(JSONSerialization.jsonObject(with: try fixture("announce-playing.json")) as? [String: Any])
        let shape = try #require(expected["player"] as? [String: Any])
        // Every field of the contract is there; those without a value say null or nothing.
        for key in shape.keys where !["volume", "nextItemId"].contains(key) {
            #expect(player[key] != nil || report.isNil(key), "\(key) is missing")
        }
    }

    // MARK: How the devices are listed

    private func device(_ id: String, _ name: String, _ platform: DevicePlatform, online: Bool = true, isSelf: Bool = false, player: ShownPlayer? = nil, controllable: Bool = false) -> ShownDevice {
        ShownDevice(id: id, name: name, platform: platform, isSelf: isSelf, online: online, canPlay: online, controllable: controllable, player: player)
    }

    @Test func openDevicesComeFirstThenTelevisionsAndMacs() {
        let all = [
            device("1", "Study", .macos),
            device("2", "Bedroom", .tvos, online: false),
            device("3", "Living Room", .tvos),
            device("4", "Phone", .ios, isSelf: true),
            device("5", "Kitchen", .ipados),
            device("6", "Attic", .tvos),
        ]
        #expect(RemoteTargets.ordered(all).map(\.name) == ["Attic", "Living Room", "Study", "Kitchen", "Bedroom"])
    }

    @Test func twoTelevisionsOfTheSameNameAreToldApart() {
        let names = RemoteTargets.names(of: [device("b", "Apple TV", .tvos), device("a", "Apple TV", .tvos), device("c", "Study", .macos)])
        #expect(names["a"] == "Apple TV 1")
        #expect(names["b"] == "Apple TV 2")
        #expect(names["c"] == "Study")
    }

    @Test func aDeviceSaysWhatItDoes() {
        let playing = ShownPlayer.visible(state(.playing))
        let paused = ShownPlayer.visible(state(.paused))
        let title: (String) -> String? = { $0 == "film" ? "Wild Isles" : nil }
        #expect(RemoteTargets.state(of: device("1", "TV", .tvos, player: playing), title: title) == "Playing Wild Isles")
        #expect(RemoteTargets.state(of: device("1", "TV", .tvos, player: paused), title: title) == "Paused Wild Isles")
        #expect(RemoteTargets.state(of: device("1", "TV", .tvos), title: title) == "Idle")
        #expect(RemoteTargets.state(of: device("1", "TV", .tvos, online: false), title: title) == "Lobby is not open")
        // A title this device does not know is not named.
        #expect(RemoteTargets.state(of: device("1", "TV", .tvos, player: playing)) { _ in nil } == "Playing")
    }

    @Test func nowPlayingIsWhatPlaysElsewhereControllableFirst() {
        let all = [
            device("1", "Here", .ios, isSelf: true, player: .visible(state(.playing))),
            device("2", "Bedroom", .tvos, player: .visible(state(.paused)), controllable: true),
            device("3", "Kids", .tvos, player: .redacted(status: .playing)),
            device("4", "Living Room", .tvos, player: .visible(state(.playing)), controllable: true),
            device("5", "Study", .macos, player: .visible(state(.ended)), controllable: true),
            device("6", "Off", .tvos, online: false, player: .visible(state(.playing))),
        ]
        #expect(RemoteTargets.nowPlaying(all).map(\.name) == ["Living Room", "Bedroom", "Kids"])
    }

    @Test func whatWentWrongIsSaidPlainly() {
        #expect(RemoteOutcome.done.words(device: "TV") == nil)
        #expect(RemoteOutcome.offline.words(device: "Living Room")?.contains("Lobby is not open on Living Room") == true)
        #expect(RemoteOutcome.failed(code: "title_not_allowed").words(device: "TV")?.contains("viewer") == true)
        #expect(RemoteOutcome.expired.words(device: "TV")?.contains("did not answer") == true)
    }

    // MARK: Trailers

    @Test func onlyAYouTubeKeyGoesIntoThePage() throws {
        let page = try #require(Trailer.embedPage(key: "dQw4w9WgXcQ", origin: "https://mt.sil.lobby", language: "nl"))
        #expect(page.contains("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?"))
        #expect(page.contains("origin=https://mt.sil.lobby"))
        #expect(page.contains("hl=nl"))
        #expect(page.contains(#"referrerpolicy="strict-origin-when-cross-origin""#))
        #expect(Trailer.embedPage(key: "\"><script>", origin: "https://mt.sil.lobby", language: nil) == nil)
        #expect(Trailer.appURL(key: "dQw4w9WgXcQ")?.scheme == "youtube")
        #expect(Trailer.appURL(key: "a/b") == nil)
    }
}

/// Any JSON, compared by value.
enum AnyJSON: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([AnyJSON]), object([String: AnyJSON])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([AnyJSON].self) { self = .array(value) }
        else { self = .object(try c.decode([String: AnyJSON].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
}

private extension PlayerReport {
    func isNil(_ key: String) -> Bool {
        switch key {
        case "audioTrackId": audioTrackId == nil
        case "subtitleTrackId": subtitleTrackId == nil
        case "upNext": upNext == nil
        default: false
        }
    }
}
