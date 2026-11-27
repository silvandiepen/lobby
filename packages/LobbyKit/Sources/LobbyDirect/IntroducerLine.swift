// SPDX-License-Identifier: MPL-2.0
import Foundation
import Synchronization

/// One conversation over the introducer's WebSocket. The introducer passes sealed messages on and
/// is not trusted with anything in them.
final class IntroducerLine: Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let closed = Mutex(false)

    init(_ url: URL) {
        // No cookies, no cache, nothing that tells one ring from another.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 130
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 20_000
        task.resume()
    }

    deinit { close() }

    func close() {
        guard closed.withLock({ was in defer { was = true }; return !was }) else { return }
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    struct Message: Decodable {
        var t: String
        var nonce: String?
        var session: String?
        var p: String?
    }

    func receive(within limit: Duration) async throws -> Message {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await Deadline.run(limit) {
                // Cancelling a task does not end a WebSocket's wait.
                try await withTaskCancellationHandler {
                    try await self.task.receive()
                } onCancel: {
                    self.task.cancel(with: .normalClosure, reason: nil)
                }
            }
        } catch {
            throw problem(error)
        }
        guard case .string(let text) = message, let read = try? JSONDecoder().decode(Message.self, from: Data(text.utf8))
        else { throw DirectError.notFromTheBox }
        return read
    }

    func send(_ message: [String: String]) async throws {
        let text = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        do {
            try await task.send(.string(text))
        } catch {
            throw problem(error)
        }
    }

    func send(envelope: String) async throws {
        try await send(["t": "msg", "p": envelope])
    }

    /// The next message for this device. Envelopes are strictly in turn.
    func envelope(within limit: Duration = .seconds(10)) async throws -> String {
        guard let envelope = try await receive(within: limit).p else { throw DirectError.notFromTheBox }
        return envelope
    }

    /// What the introducer means with the way it closed.
    private func problem(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let error = error as? DirectError { return error }
        switch task.closeCode.rawValue {
        case 4001: return DirectError.notAllowed
        case 4404: return DirectError.boxOffline
        case 4008: return DirectError.noAnswer
        case 4029, 4030: return DirectError.tooOften
        default: break
        }
        switch (task.response as? HTTPURLResponse)?.statusCode {
        case 404?: return DirectError.unknownRoom
        case 429?, 503?: return DirectError.tooOften
        default: return DirectError.introducerUnreachable
        }
    }
}

enum Deadline {
    /// `work`, or `noAnswer` after `limit`. The work is cancelled then.
    static func run<Value: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask(operation: work)
            group.addTask {
                try await Task.sleep(for: limit)
                throw DirectError.noAnswer
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw DirectError.noAnswer }
            return first
        }
    }
}
