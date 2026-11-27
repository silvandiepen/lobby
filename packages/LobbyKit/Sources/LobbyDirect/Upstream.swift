// SPDX-License-Identifier: MPL-2.0
import Foundation
import Network
import Synchronization

/// Where a request goes: a stream of the direct connection, or a plain connection to the server's
/// own address at home or in the tailnet.
final class Upstream: Sendable {
    enum Interruption: Error, Hashable {
        /// Whoever asked went away.
        case notWantedAnyMore
        /// There is a newer connection: what can go on, goes on there.
        case superseded
    }

    /// The connection it belongs to, counted.
    let generation: Int
    let host: String
    /// In front of the request's own path.
    let pathPrefix: String
    private let connection: NWConnection
    /// Held for as long as the stream is in use. nil for a plain connection.
    private let session: DirectSession?
    private let heard: @Sendable () -> Void

    private struct Inside {
        var waiting: CheckedContinuation<NWConnection.Received, any Error>?
        var sending: CheckedContinuation<Void, any Error>?
        var isReceiving = false
        var interruption: Interruption?
        var isOver = false
    }
    private let inside = Mutex(Inside())

    init(
        _ connection: NWConnection, session: DirectSession?, generation: Int, host: String, pathPrefix: String,
        heard: @escaping @Sendable () -> Void
    ) {
        self.connection = connection
        self.session = session
        self.generation = generation
        self.host = host
        self.pathPrefix = pathPrefix
        self.heard = heard
        if session == nil {
            // An address that is not there any more. It would wait for another network by itself.
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .waiting, .failed: self?.interrupt(.superseded)
                default: break
                }
            }
        }
        connection.start(queue: DispatchQueue(label: "lobby.upstream"))
    }

    /// Waits for the box: for what it sends, or to take what is sent to it.
    var isWaiting: Bool { inside.withLock { ($0.isReceiving || $0.sending != nil) && $0.interruption == nil } }

    /// Sends and leaves this side open. A stream of a connection that ended unheard may never
    /// say that it was sent: an interruption ends the wait.
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let interruption = inside.withLock { inside in
                if inside.interruption == nil { inside.sending = continuation }
                return inside.interruption
            }
            if let interruption { return continuation.resume(throwing: interruption) }
            connection.send(content: data, contentContext: .finalMessage, isComplete: false, completion: .contentProcessed { error in
                let sending = self.inside.withLock { inside in
                    defer { inside.sending = nil }
                    return inside.sending
                }
                if let error { sending?.resume(throwing: error) } else { sending?.resume() }
            })
        }
    }

    func receive() async throws -> NWConnection.Received {
        try await withCheckedThrowingContinuation { continuation in
            let interruption = inside.withLock { inside in
                if inside.interruption == nil {
                    inside.waiting = continuation
                    inside.isReceiving = true
                }
                return inside.interruption
            }
            if let interruption { return continuation.resume(throwing: interruption) }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { data, _, isComplete, error in
                self.arrived(data ?? Data(), isComplete: isComplete, error: error)
            }
        }
    }

    private func arrived(_ data: Data, isComplete: Bool, error: NWError?) {
        if !data.isEmpty { heard() }
        let (waiting, interrupted) = inside.withLock { inside in
            inside.isReceiving = false
            if isComplete || error != nil { inside.isOver = true }
            defer { inside.waiting = nil }
            return (inside.waiting, inside.interruption != nil)
        }
        if interrupted {
            // Nobody waits for this any more. Apple's QUIC loses count of the connection's window
            // when a stream with data under way is cancelled, and then breaks the connection: it
            // is read to its end instead.
            return drain(after: isComplete || error != nil)
        }
        if !data.isEmpty || (isComplete && error == nil) {
            waiting?.resume(returning: .init(data: data, isComplete: isComplete))
        } else {
            waiting?.resume(throwing: error ?? NWError.posix(.ECONNRESET))
        }
    }

    private func drain(after isOver: Bool) {
        if isOver || session == nil { return connection.cancel() }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { _, _, isComplete, error in
            self.drain(after: isComplete || error != nil)
        }
    }

    /// Ends it in the middle, from anywhere. Who is waiting for data is told why.
    func interrupt(_ reason: Interruption) {
        let (waiting, sending, isReceiving, first) = inside.withLock { inside in
            let first = inside.interruption == nil
            if first { inside.interruption = reason }
            defer {
                inside.waiting = nil
                inside.sending = nil
            }
            return (inside.waiting, inside.sending, inside.isReceiving, first)
        }
        guard first else { return }
        end(isReceiving: isReceiving)
        waiting?.resume(throwing: reason)
        sending?.resume(throwing: reason)
    }

    /// Everything that was asked for arrived.
    func finish() {
        let first = inside.withLock { inside in
            defer { inside.interruption = inside.interruption ?? .notWantedAnyMore }
            return inside.interruption == nil
        }
        if first { end(isReceiving: false) }
    }

    private func end(isReceiving: Bool) {
        guard session != nil else { return connection.cancel() }
        // Ending this side is how the box learns that nobody wants the rest.
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        if !isReceiving { drain(after: inside.withLock { $0.isOver }) }
    }
}

/// A server's own address, for a request that goes there from the app's local server.
public struct Origin: Hashable, Sendable {
    let host: NWEndpoint.Host
    let port: NWEndpoint.Port
    let isTLS: Bool
    let hostHeader: String
    let pathPrefix: String

    public init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let name = url.host(percentEncoded: false), !name.isEmpty
        else { return nil }
        isTLS = scheme == "https"
        let number = url.port ?? (isTLS ? 443 : 80)
        guard let port = UInt16(exactly: number).flatMap(NWEndpoint.Port.init(rawValue:)) else { return nil }
        self.port = port
        host = NWEndpoint.Host(name)
        let bracketed = name.contains(":") ? "[\(name)]" : name
        hostHeader = url.port.map { "\(bracketed):\($0)" } ?? bracketed
        var path = url.path(percentEncoded: true)
        while path.hasSuffix("/") { path.removeLast() }
        pathPrefix = path
    }

    func connection() -> NWConnection {
        let parameters: NWParameters = isTLS ? .tls : .tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = 5
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 5
            tcp.keepaliveInterval = 2
            tcp.keepaliveCount = 3
        }
        return NWConnection(host: host, port: port, using: parameters)
    }
}
