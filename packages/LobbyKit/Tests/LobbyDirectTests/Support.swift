// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Foundation
import Testing

@testable import LobbyDirect
@testable import LobbyKit

enum Repository {
    static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

#if os(macOS)
/// The real server, introducer and lobby-direct of this repository, on this Mac.
/// `apps/server/test/support/direct-harness.ts` starts them and does what a manager would.
actor Harness {
    private let process = Process()
    private let input = Pipe()
    private var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator

    static let program = Repository.root.appending(path: "apps/direct/target/release/lobby-direct")

    /// Only where the programs are: `cargo build --release --bins --examples` in apps/direct, and node.
    static var isThere: Bool {
        FileManager.default.isExecutableFile(atPath: program.path) && node != nil
    }

    /// Node 24 or later: what a shell has, or what nvm keeps. Xcode's own PATH has neither.
    private static let node: String? = {
        let nvm = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".nvm/versions/node")
        let kept = ((try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? [])
            .filter { (Int($0.dropFirst().prefix { $0 != "." }) ?? 0) >= 24 }.sorted()
            .map { nvm.appending(path: "\($0)/bin").path }
        let folders = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return (kept + folders + ["/opt/homebrew/bin"]).map { $0 + "/node" }
            .first(where: FileManager.default.isExecutableFile(atPath:))
    }()

    /// - Parameters:
    ///   - maxUploadMbit: What the box may send, as on a Pi that sets it.
    ///   - prepareSpeed: How many times the film's speed a copy is prepared at, as on a Pi.
    init(maxUploadMbit: Int? = nil, prepareSpeed: Double? = nil) async throws {
        process.executableURL = URL(filePath: try #require(Self.node))
        process.arguments = [Repository.root.appending(path: "apps/server/test/support/direct-harness.ts").path]
        var environment = ProcessInfo.processInfo.environment
        environment["LOBBY_DIRECT_TARGET"] = Self.program.deletingLastPathComponent().path
        environment["PATH"] = (environment["PATH"] ?? "") + ":/opt/homebrew/bin"
        if let maxUploadMbit { environment["LOBBY_HARNESS_MAX_UPLOAD_MBIT"] = String(maxUploadMbit) }
        if let prepareSpeed { environment["LOBBY_HARNESS_PREPARE_SPEED"] = String(prepareSpeed) }
        process.environment = environment
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        lines = output.fileHandleForReading.bytes.lines.makeAsyncIterator()
        try process.run()
        _ = try await answer()
    }

    func stop() {
        try? input.fileHandleForWriting.close()
    }

    private func answer() async throws -> Data {
        var iterator = lines
        defer { lines = iterator }
        while let line = try await iterator.next(isolation: self) {
            guard line.hasPrefix("{") else { continue }
            let data = Data(line.utf8)
            let said = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if said?["ok"] as? Bool == false { throw Problem(text: said?["error"] as? String ?? "") }
            return data
        }
        throw Problem(text: "The harness ended.")
    }

    struct Problem: Error { var text: String }

    @discardableResult
    func say(_ command: String, _ more: [String: any Sendable] = [:]) async throws -> Data {
        var message: [String: any Sendable] = more
        message["do"] = command
        let data = try JSONSerialization.data(withJSONObject: message) + Data("\n".utf8)
        try input.fileHandleForWriting.write(contentsOf: data)
        return try await answer()
    }

    func ask<Answer: Decodable>(_ command: String, _ more: [String: any Sendable] = [:]) async throws -> Answer {
        try LobbyJSON.decoder().decode(Answer.self, from: try await say(command, more))
    }

    struct Paired: Decodable, Sendable { var id: String; var token: String }
    struct Port: Decodable { var port: Int }
    struct Film: Decodable { var asset: String; var copy: String }
    struct Road: Decodable, Sendable { var road: Int; var offer: Int; var answer: Int }
    struct Counts: Decodable { var toDevice: Int; var carriedBytes: Int }

    func home() async throws -> URL {
        let port: Port = try await ask("openHome")
        return try #require(URL(string: "http://127.0.0.1:\(port.port)"))
    }

    /// A device that was paired and got ready at home.
    func device(_ name: String, at home: URL, outside: Bool = true) async throws -> (Paired, DirectIdentity) {
        let paired: Paired = try await ask("pair", ["name": name, "outside": outside])
        let client = try LobbyClient(baseURL: home, token: paired.token)
        let identity = try #require(try await client.directIdentity(keeping: nil))
        try await say("told")
        return (paired, identity)
    }

    /// A road with a delay, a speed and losses, between the two.
    func road(oneWayMs: Int = 0, loss: Double = 0, mbit: Int = 1000, queueMs: Int = 200) async throws -> Road {
        try await ask("road", ["oneWayMs": oneWayMs, "loss": loss, "mbit": mbit, "queueMs": queueMs])
    }
}

/// The roads a device goes over, one after the other: what another network is here.
final class Roads: Sendable {
    private let next: MutexBox<[Harness.Road]>
    private let taken: MutexBox<Harness.Road?> = .init(nil)

    init(_ roads: [Harness.Road]) { next = .init(roads) }

    var detours: DirectSession.Detours {
        @Sendable func replaced(_ sdp: String, _ port: Int) -> String {
            sdp.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("a=candidate") && !$0.hasPrefix("a=end-of") }
                .joined(separator: "\r\n")
                + "\r\na=candidate:1 1 UDP 2122317823 127.0.0.1 \(port) typ host\r\na=end-of-candidates\r\n"
        }
        return DirectSession.Detours(
            bind: "127.0.0.1",
            offer: { [self] sdp in
                let road = next.value.withLock { $0.count > 1 ? $0.removeFirst() : $0.first }
                taken.value.withLock { $0 = road }
                return road.map { replaced(sdp, $0.offer) } ?? sdp
            },
            answer: { [self] sdp in taken.value.withLock { $0 }.map { replaced(sdp, $0.answer) } ?? sdp })
    }
}

import Synchronization

final class MutexBox<Value: Sendable>: Sendable {
    let value: Mutex<Value>
    init(_ value: Value) { self.value = Mutex(value) }
}
#endif
