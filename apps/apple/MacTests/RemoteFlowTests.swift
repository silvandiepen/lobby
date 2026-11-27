// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

/// Playing on another device, with the app's own model on both sides, against the real server
/// of this repository (`apps/server/test/support/remote-harness.ts`) over the live channel.
@MainActor
@Suite(.serialized, .enabled(if: RemoteHarness.isThere, "SKIPPED: there is no Node 24 or ffmpeg here."))
struct RemoteFlowTests {
    private struct Film: Decodable { var id: String; var title: String; var asset: String }
    private struct Films: Decodable { var items: [Film] }

    /// One device of the household: a paired app with its own stored state.
    @MainActor
    private final class Device {
        let test: TestApp
        let app: AppModel
        let id: String
        private var running: Task<Void, Never>?

        init(test: TestApp, app: AppModel, id: String) {
            self.test = test
            self.app = app
            self.id = id
        }

        func connect() { running = Task { await app.remote.run() } }
        func disconnect() { running?.cancel() }
    }

    private func device(_ name: String, _ platform: DevicePlatform, on h: RemoteHarness, as profileID: String?) async throws -> Device {
        let paired: RemoteHarness.Paired = try await h.ask("device", ["name": name, "platform": platform.rawValue])
        let me = try await LobbyClient(baseURL: h.home, token: paired.token).me()
        let test = try TestApp(Household(.init()))
        test.environment.session = .shared
        test.environment.sleep = { try await Task.sleep(for: $0) }
        await test.credentials.setToken(paired.token, forServer: me.server.id)
        test.environment.preferences.connection = SavedConnection(
            serverAddress: h.home, serverID: me.server.id, serverName: me.server.name, deviceID: paired.id)
        test.environment.preferences.activeProfileID = profileID
        let app = test.launch()
        await app.start()
        try await until("\(name) has its library") { app.hasLibraryCopy && !app.isRefreshing }
        if let profileID, let profile = app.profiles.first(where: { $0.id == profileID }) {
            await app.selectProfile(profile)
        }
        #expect(app.phase == .library)
        let device = Device(test: test, app: app, id: paired.id)
        device.connect()
        try await until("\(name) is on the channel") { app.remote.isConnected }
        return device
    }

    @Test func aPhonePlaysOnTheTelevisionFollowsItAndTakesItBack() async throws {
        let h = try await RemoteHarness()
        defer { Task { await h.stop() } }
        let films: Films = try await h.ask("items")
        let balloon = try #require(films.items.first { $0.title == "Balloon" })
        let parent: RemoteHarness.Made = try await h.ask("profile", ["name": "Tall one"])

        let tv = try await device("Living room", .tvos, on: h, as: parent.id)
        let phone = try await device("Phone", .ios, on: h, as: parent.id)
        defer {
            tv.disconnect()
            phone.disconnect()
        }

        // The television is listed, open and ready; the phone itself is not.
        try await until("the TV is a target") { phone.app.remote.targets.first?.canPlay == true }
        let target = try #require(phone.app.remote.targets.first)
        #expect(target.id == tv.id)
        #expect(target.platform == .tvos)
        #expect(phone.app.remote.targets.allSatisfy { $0.id != phone.id })
        #expect(phone.app.remote.name(of: target) == "Living room")
        // A phone is nobody's target unless it says so.
        #expect(tv.app.remote.targets.allSatisfy { $0.id != phone.id })

        // Play there: the television starts it itself, as the viewer.
        let item = try #require(phone.app.wholeCatalogue.item(balloon.id))
        let started = SteadyClock.nowMs()
        let outcome = await phone.app.remote.play(item, on: target, start: .beginning, profileID: parent.id)
        #expect(outcome == .done)
        let player = try #require(tv.app.player)
        player.player.isMuted = true
        #expect(player.request.item.id == balloon.id)
        #expect(tv.app.remote.toast == "Played from Phone")
        try await until("the phone sees it play") {
            phone.app.remote.device(tv.id)?.player?.state?.itemId == balloon.id
                && phone.app.remote.device(tv.id)?.player?.status == .playing
        }
        #expect(SteadyClock.nowMs() - started < 8_000)
        #expect(phone.app.remote.nowPlaying.first?.id == tv.id)
        #expect(RemoteWords.title(of: try #require(phone.app.remote.nowPlaying.first), in: phone.app) == "Balloon")

        // Pause from the phone; the phone's picture of it follows.
        #expect(await phone.app.remote.send(.pause, to: tv.id) == .done)
        #expect(player.player.timeControlStatus == .paused)
        try await until("the phone sees it paused") { phone.app.remote.device(tv.id)?.player?.status == .paused }

        // The television's own remote: a jump there reaches the phone within a second or so.
        player.remoteSeek(toMs: 20_000)
        let jumped = SteadyClock.nowMs()
        try await until("the phone sees the jump") {
            guard let state = phone.app.remote.device(tv.id)?.player?.state else { return false }
            return abs(phone.app.remote.positionMs(of: state) - 20_000) < 1_500
        }
        #expect(SteadyClock.nowMs() - jumped < 2_000)

        // Resume: the place moves on by the server's clock without anything more being said.
        #expect(await phone.app.remote.send(.resume, to: tv.id) == .done)
        try await until("the phone sees it play again") { phone.app.remote.device(tv.id)?.player?.status == .playing }
        let state = try #require(phone.app.remote.device(tv.id)?.player?.state)
        let first = phone.app.remote.positionMs(of: state)
        try await Task.sleep(for: .seconds(2))
        let second = phone.app.remote.positionMs(of: state)
        #expect(second - first > 1_500)
        #expect(second - first < 2_500)

        // Skip and seek.
        #expect(await phone.app.remote.send(.seek(positionMs: 10_000), to: tv.id) == .done)
        try await until("the TV is at 10 s") { abs((player.currentPositionMs ?? 0) - 10_000) < 1_500 }
        #expect(await phone.app.remote.send(.skip(deltaMs: 10_000), to: tv.id) == .done)
        try await until("the TV is at 20 s") { abs((player.currentPositionMs ?? 0) - 20_000) < 1_500 }

        // Watch here: the film goes on on the phone at the same place, and stops on the TV.
        let handing = try #require(phone.app.remote.device(tv.id))
        #expect(await phone.app.remote.watchHere(from: handing) == .done)
        try await until("the phone plays it") { phone.app.player?.request.item.id == balloon.id }
        phone.app.player?.player.isMuted = true
        try await until("the TV stopped") { tv.app.player == nil }
        let here = try #require(phone.app.player)
        #expect(here.request.startPositionMs > 15_000)
        #expect(here.request.startPositionMs < 30_000)

        // And back: send it to the television.
        try await until("the phone's film started") { here.hasStarted }
        #expect(await phone.app.remote.sendHere(to: handing) == .done)
        try await until("the TV plays it again") { tv.app.player?.request.item.id == balloon.id }
        tv.app.player?.player.isMuted = true
        try await until("the phone stopped") { phone.app.player == nil }

        // Stop from the phone.
        #expect(await phone.app.remote.send(.stop, to: tv.id) == .done)
        try await until("the TV stopped") { tv.app.player == nil }
        try await until("nothing plays") { phone.app.remote.nowPlaying.isEmpty }

        // The television goes away: within fifteen seconds it is shown as not open.
        tv.disconnect()
        let left = SteadyClock.nowMs()
        try await until("the TV is gone", seconds: 16) { phone.app.remote.targets.first(where: { $0.id == tv.id })?.online != true }
        #expect(SteadyClock.nowMs() - left < 15_000)
        #expect(await phone.app.remote.send(.pause, to: tv.id) != .done)
    }

    @Test func kidsLimitsHoldOnBothSides() async throws {
        let h = try await RemoteHarness()
        defer { Task { await h.stop() } }
        let films: Films = try await h.ask("items")
        let balloon = try #require(films.items.first { $0.title == "Balloon" })
        let scary = try #require(films.items.first { $0.title == "Scary" })
        let parent: RemoteHarness.Made = try await h.ask("profile", ["name": "Tall one"])
        let kid: RemoteHarness.Made = try await h.ask("profile", ["name": "Small one", "kids": [balloon.id]])
        let other: RemoteHarness.Made = try await h.ask("profile", ["name": "Other one", "kids": [String]()])

        let tv = try await device("Kids room", .tvos, on: h, as: parent.id)
        try await h.say("bind", ["device": tv.id, "profile": kid.id])
        await tv.app.refresh()
        #expect(tv.app.isBoundToKids)
        let phone = try await device("Phone", .ios, on: h, as: parent.id)
        defer {
            tv.disconnect()
            phone.disconnect()
        }
        try await until("the kids TV is a target") { phone.app.remote.targets.first?.canPlay == true }
        let target = try #require(phone.app.remote.targets.first)
        #expect(target.isKids)

        // Not as another viewer, and not a title the child may not see.
        let scaryItem = try #require(phone.app.wholeCatalogue.item(scary.id))
        let balloonItem = try #require(phone.app.wholeCatalogue.item(balloon.id))
        #expect(await phone.app.remote.play(balloonItem, on: target, start: .beginning, profileID: parent.id) == .failed(code: "title_not_allowed"))
        #expect(await phone.app.remote.play(scaryItem, on: target, start: .beginning, profileID: kid.id) == .failed(code: "title_not_allowed"))
        #expect(tv.app.player == nil)
        // As the child, what the child may see.
        #expect(await phone.app.remote.play(balloonItem, on: target, start: .beginning, profileID: kid.id) == .done)
        tv.app.player?.player.isMuted = true
        #expect(tv.app.player?.request.item.id == balloon.id)

        // A kids device controls nothing but itself, and lists nobody.
        #expect(tv.app.remote.targets.isEmpty)
        #expect(tv.app.remote.nowPlaying.isEmpty)
        let toPhone = try #require(tv.app.remote.device(tv.id))
        #expect(await tv.app.remote.send(.pause, to: phone.id) != .done)
        #expect(toPhone.isSelf)

        // Another child's TV is not there for a kids viewer on a shared device (docs/decisions.md, "Kids mode plays on the TV") ...
        let tablet = try await device("Tablet", .ipados, on: h, as: other.id)
        defer { tablet.disconnect() }
        try await until("the tablet is on the channel") { tablet.app.remote.me != nil }
        #expect(tablet.app.remote.device(tv.id) == nil)
        #expect(tablet.app.remote.kidsTargets.isEmpty)

        // ... and a grown-up's TV shows it that something plays, not what, even a title it may see.
        let living = try await device("Living room", .tvos, on: h, as: parent.id)
        defer { living.disconnect() }
        try await until("the living room TV is a target") { phone.app.remote.device(living.id)?.canPlay == true }
        let livingTarget = try #require(phone.app.remote.device(living.id))
        #expect(await phone.app.remote.play(balloonItem, on: livingTarget, start: .beginning, profileID: parent.id) == .done)
        living.app.player?.player.isMuted = true
        try await until("the tablet sees the TV play") { tablet.app.remote.device(living.id)?.player?.status == .playing }
        let seen = try #require(tablet.app.remote.device(living.id))
        #expect(seen.player?.state == nil)
        #expect(!seen.controllable)
        #expect(RemoteWords.title(of: seen, in: tablet.app) == "Playing")
        #expect(RemoteTargets.state(of: seen) { tablet.app.wholeCatalogue.item($0)?.title } == "Playing")
    }

    private func until(_ what: String, seconds: Double = 12, _ check: () async -> Bool) async throws {
        let end = SteadyClock.nowMs() + seconds * 1000
        while SteadyClock.nowMs() < end {
            if await check() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw RemoteHarness.Problem(text: "\(what) did not happen")
    }
}

/// `apps/server/test/support/remote-harness.ts`: the real server with two films, and what a
/// manager would do.
actor RemoteHarness {
    private let process: Process
    private let input: Pipe
    private var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator
    nonisolated let home: URL

    struct Problem: Error { var text: String }
    struct Paired: Decodable, Sendable { var id: String; var token: String }
    struct Made: Decodable, Sendable { var id: String }
    private struct Started: Decodable { var port: Int }

    private static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// Node 24 or later, from a shell's PATH or nvm, and ffmpeg.
    nonisolated static let node: String? = {
        // The person's own home, not the sandbox's container.
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        let nvm = URL(filePath: home).appending(path: ".nvm/versions/node")
        let kept = ((try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? [])
            .filter { (Int($0.dropFirst().prefix { $0 != "." }) ?? 0) >= 24 }.sorted().reversed()
            .map { nvm.appending(path: "\($0)/bin").path }
        let folders = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return (kept + ["/opt/homebrew/bin"] + folders + ["/usr/local/bin"]).map { $0 + "/node" }
            .first { FileManager.default.isExecutableFile(atPath: $0) && major(of: $0) >= 24 }
    }()

    /// The major version of a node: an older one cannot run TypeScript as it is.
    private nonisolated static func major(of node: String) -> Int {
        let process = Process()
        process.executableURL = URL(filePath: node)
        process.arguments = ["-p", "process.versions.node.split('.')[0]"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return 0 }
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    nonisolated static var isThere: Bool {
        node != nil && ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].contains(where: FileManager.default.isExecutableFile(atPath:))
    }

    init() async throws {
        guard let node = Self.node else { throw Problem(text: "no node") }
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(filePath: node)
        process.arguments = [Self.root.appending(path: "apps/server/test/support/remote-harness.ts").path]
        process.currentDirectoryURL = Self.root
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (environment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
        process.environment = environment
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        let errors = Pipe()
        process.standardError = errors
        var iterator = output.fileHandleForReading.bytes.lines.makeAsyncIterator()
        try process.run()
        var first: Data?
        while let line = try await iterator.next() {
            if line.hasPrefix("{") {
                first = Data(line.utf8)
                break
            }
        }
        guard let first, let started = try? JSONDecoder().decode(Started.self, from: first),
            let home = URL(string: "http://127.0.0.1:\(started.port)")
        else {
            let said = String(decoding: errors.fileHandleForReading.availableData.prefix(2000), as: UTF8.self)
            throw Problem(text: "the harness did not start: \(said)")
        }
        self.process = process
        self.input = input
        self.lines = iterator
        self.home = home
    }

    func stop() {
        try? input.fileHandleForWriting.close()
    }

    @discardableResult
    func say(_ command: String, _ more: [String: any Sendable] = [:]) async throws -> Data {
        var message: [String: any Sendable] = more
        message["do"] = command
        try input.fileHandleForWriting.write(contentsOf: try JSONSerialization.data(withJSONObject: message) + Data("\n".utf8))
        var iterator = lines
        defer { lines = iterator }
        while let line = try await iterator.next(isolation: self) {
            guard line.hasPrefix("{") else { continue }
            let data = Data(line.utf8)
            let said = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if said?["ok"] as? Bool == false { throw Problem(text: said?["error"] as? String ?? "") }
            return data
        }
        throw Problem(text: "the harness ended")
    }

    func ask<Answer: Decodable>(_ command: String, _ more: [String: any Sendable] = [:]) async throws -> Answer {
        try JSONDecoder().decode(Answer.self, from: try await say(command, more))
    }
}
