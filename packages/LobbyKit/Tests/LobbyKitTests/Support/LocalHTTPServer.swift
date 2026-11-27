// SPDX-License-Identifier: MPL-2.0
import Foundation
import Network
import Synchronization

/// A small HTTP server on a real socket on this machine, for the download tests.
///
/// `URLSession` download tasks only pause, continue and retry the way they do in the apps when
/// they talk to a real connection: resume data needs real `ETag` and `Accept-Ranges` headers,
/// and a broken transfer needs a connection that really closes. This serves what
/// `docs/api.md` describes for one asset: the playback answer, the file with byte ranges and
/// `If-Range`, and a subtitle. The tests decide what it holds and when it stalls.
final class LocalHTTPServer: Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var headers: [String: String]
    }

    struct State: Sendable {
        /// Answers of `POST …/playback`, one per call. The last one repeats.
        var playback: [(status: Int, json: String)] = []
        var content = Data()
        /// Without the quotes.
        var etag = "r1"
        /// The status of the file route when it is not 200/206.
        var contentStatus: Int?
        /// Send this many bytes of the body, then hold the rest until `release()`.
        var holdAfterBytes: Int?
        /// Send this many bytes of the body, then close the connection. Once.
        var dropAfterBytes: Int?
        var subtitles: [String: String] = [:]
        var requests: [Request] = []
        var held: [@Sendable () -> Void] = []
    }

    let port: UInt16
    private let listener: NWListener
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "LocalHTTPServer")

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        let ready = AsyncStream<UInt16?>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.continuation.yield(listener.port?.rawValue)
            case .failed, .cancelled: ready.continuation.yield(nil)
            default: break
            }
        }
        // `self` is not complete yet, so connections wait on the queue until the handler is set.
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: queue)
        guard let port = await ready.stream.first(where: { _ in true }) ?? nil else {
            throw URLError(.cannotConnectToHost)
        }
        self.port = port
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            connection.start(queue: self.queue)
            self.read(connection, buffer: Data())
        }
    }

    deinit {
        listener.cancel()
    }

    func change(_ body: (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    var requests: [Request] { state.withLock { $0.requests } }

    func requests(_ method: String, containing fragment: String) -> [Request] {
        requests.filter { $0.method == method && $0.path.contains(fragment) }
    }

    /// Lets held responses finish.
    func release() {
        let held = state.withLock { state in
            defer { state.held = [] }
            state.holdAfterBytes = nil
            return state.held
        }
        held.forEach { $0() }
    }

    // MARK: HTTP

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.answer(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if isComplete {
                connection.cancel()
            } else {
                self.read(connection, buffer: buffer)
            }
        }
    }

    private func answer(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ").map(String.init)
        guard start.count >= 2 else { return connection.cancel() }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let request = Request(method: start[0], path: start[1], headers: headers)

        enum Plan {
            case whole(status: Int, headers: [String], body: Data)
            case file(head: String, body: Data, holdAfter: Int?, dropAfter: Int?)
        }
        let plan: Plan = state.withLock { state in
            state.requests.append(request)
            if request.path.hasSuffix("/playback") {
                guard let next = state.playback.first else {
                    return .whole(status: 404, headers: ["Content-Type: application/json"], body: Data(#"{"error":{"code":"not_found","message":"No such asset."}}"#.utf8))
                }
                if state.playback.count > 1 { state.playback.removeFirst() }
                return .whole(status: next.status, headers: ["Content-Type: application/json"], body: Data(next.json.utf8))
            }
            if let name = request.path.split(separator: "/").last, name.hasSuffix(".vtt") {
                guard let text = state.subtitles[String(name.dropLast(4))] else {
                    return .whole(status: 404, headers: [], body: Data())
                }
                return .whole(status: 200, headers: ["Content-Type: text/vtt; charset=utf-8"], body: Data(text.utf8))
            }
            guard request.path.hasSuffix("/content") || request.path.hasSuffix("/media.mp4") else {
                return .whole(status: 404, headers: [], body: Data())
            }
            if let status = state.contentStatus {
                return .whole(status: status, headers: ["Content-Type: application/json"], body: Data(#"{"error":{"code":"not_found","message":"Gone."}}"#.utf8))
            }

            // The file, as `docs/api.md` has it: one range, and `If-Range` that must match.
            let total = state.content.count
            let quoted = "\"\(state.etag)\""
            var from = 0
            if let range = headers["range"], range.hasPrefix("bytes="), headers["if-range"].map({ $0 == quoted }) ?? true,
                let first = Int(range.dropFirst(6).split(separator: "-").first ?? ""), first < total
            {
                from = first
            }
            let body = state.content.subdata(in: from..<total)
            var head = from > 0 ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
            if from > 0 { head += "Content-Range: bytes \(from)-\(total - 1)/\(total)\r\n" }
            head += "Content-Length: \(body.count)\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\n"
            head += "ETag: \(quoted)\r\nLast-Modified: Tue, 24 Nov 2026 12:00:00 GMT\r\nConnection: close\r\n\r\n"
            let drop = state.dropAfterBytes
            state.dropAfterBytes = nil
            return .file(head: head, body: body, holdAfter: state.holdAfterBytes, dropAfter: drop)
        }

        switch plan {
        case .whole(let status, let headers, let body):
            var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : status == 202 ? "Accepted" : "Status")\r\n"
            for header in headers { head += header + "\r\n" }
            head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })

        case .file(let head, let body, let holdAfter, let dropAfter):
            if let dropAfter, dropAfter < body.count {
                // The connection breaks part-way: the client got less than it was promised.
                connection.send(content: Data(head.utf8) + body.prefix(dropAfter), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else if let holdAfter, holdAfter < body.count {
                connection.send(content: Data(head.utf8) + body.prefix(holdAfter), completion: .contentProcessed { _ in })
                let rest = body.dropFirst(holdAfter)
                state.withLock {
                    $0.held.append {
                        connection.send(content: rest, completion: .contentProcessed { _ in connection.cancel() })
                    }
                }
            } else {
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
