// SPDX-License-Identifier: MPL-2.0
import Foundation
import Network
import Synchronization

/// HTTP/1.1 on 127.0.0.1, for this app and its player only: on a random port, under a path nobody
/// can guess, for one `Host`. It sends every request over the link and puts the device's credential
/// on it, so that no credential is ever given to a port of this device.
///
/// When the link's connection is replaced in the middle of a film, the answer goes on from the byte
/// that is missing, on the same connection to the player.
public final class LoopbackServer: Sendable {
    /// `http://127.0.0.1:<port>/<secret>`.
    public let base: URL
    private let port: NWEndpoint.Port
    private let secret: String
    private let listener: NWListener
    private let link: DirectLink
    private let slots: Slots
    private let connections = Mutex<[ObjectIdentifier: NWConnection]>([:])

    private static let mostHead = 32_768
    private static let mostBody = 1_048_576

    private init(listener: NWListener, port: NWEndpoint.Port, secret: String, link: DirectLink, slots: Slots) {
        self.listener = listener
        self.port = port
        self.secret = secret
        self.link = link
        self.slots = slots
        guard let base = URL(string: "http://127.0.0.1:\(port.rawValue)/\(secret)") else {
            preconditionFailure("A port and hexadecimal digits always make a URL.")
        }
        self.base = base
    }

    /// - Parameter previous: The one it takes the place of, after the system took that one's port
    ///   away. With the same port and path, what the player holds goes on working.
    public static func start(link: DirectLink, replacing previous: LoopbackServer? = nil) async throws -> LoopbackServer {
        if let previous {
            previous.stop()
            if let same = try? await start(link: link, port: previous.port, secret: previous.secret) { return same }
        }
        return try await start(link: link, port: .any, secret: Data.random(32).map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined())
    }

    private static func start(link: DirectLink, port: NWEndpoint.Port, secret: String) async throws -> LoopbackServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        parameters.acceptLocalOnly = true
        // Connections of the previous listener may still be closing at this port.
        parameters.allowLocalEndpointReuse = port != .any
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let listener = try NWListener(using: parameters)
        let server = Mutex<LoopbackServer?>(nil)
        listener.newConnectionHandler = { connection in
            if let server = server.withLock({ $0 }) { server.accept(connection) } else { connection.cancel() }
        }
        let (states, sink) = AsyncStream.makeStream(of: NWListener.State.self)
        listener.stateUpdateHandler = { sink.yield($0) }
        listener.start(queue: DispatchQueue(label: "lobby.loopback"))
        for await state in states {
            switch state {
            case .ready:
                guard let port = listener.port else { throw DirectError.closed }
                let made = LoopbackServer(
                    listener: listener, port: port, secret: secret, link: link, slots: Slots(all: 20, pictures: 6))
                server.withLock { $0 = made }
                return made
            case .failed(let error):
                listener.cancel()
                throw error
            case .waiting(let error):
                // The port is somebody else's now.
                listener.cancel()
                throw error
            case .cancelled:
                throw DirectError.closed
            default:
                continue
            }
        }
        listener.cancel()
        throw CancellationError()
    }

    public func stop() {
        listener.newConnectionHandler = nil
        listener.cancel()
        let all = connections.withLock { all in
            defer { all = [:] }
            return all
        }
        all.values.forEach { $0.forceCancel() }
    }

    /// Whether it still answers. The system takes a suspended app's ports away.
    public func isAlive() async -> Bool {
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        defer { connection.cancel() }
        connection.start(queue: DispatchQueue(label: "lobby.loopback.check"))
        let answer = try? await Deadline.run(.seconds(2)) {
            try await withTaskCancellationHandler {
                try await connection.sendKeepingOpen(Data(
                    "GET /\(self.secret)/alive HTTP/1.1\r\nHost: 127.0.0.1:\(self.port.rawValue)\r\n\r\n".utf8))
                return try await connection.receiveSome(atMost: 64).data
            } onCancel: {
                connection.cancel()
            }
        }
        return answer.map { $0.starts(with: Data("HTTP/1.1 204".utf8)) } ?? false
    }

    // MARK: One connection, one request

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections.withLock { $0[id] = connection }
        connection.start(queue: DispatchQueue(label: "lobby.loopback.connection"))
        Task {
            await Exchange(client: connection, link: link, slots: slots, port: port.rawValue, secret: secret).run()
            _ = connections.withLock { $0.removeValue(forKey: id) }
        }
    }

    /// How many requests go out at once. The box takes 28 streams a device; a wall of posters must
    /// not keep a film waiting.
    actor Slots {
        enum Kind { case picture, other }
        private let all: Int
        private let pictures: Int
        private var taken = 0
        private var takenByPictures = 0
        private var queue: [(id: UUID, kind: Kind, go: CheckedContinuation<Bool, Never>)] = []

        init(all: Int, pictures: Int) {
            self.all = all
            self.pictures = pictures
        }

        private func fits(_ kind: Kind) -> Bool {
            taken < all && (kind == .other || takenByPictures < pictures)
        }

        private func add(_ kind: Kind, _ amount: Int) {
            taken += amount
            if kind == .picture { takenByPictures += amount }
        }

        /// False when the task was cancelled while waiting.
        func take(_ kind: Kind) async -> Bool {
            if fits(kind) {
                add(kind, 1)
                return true
            }
            let id = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { go in
                    if Task.isCancelled { return go.resume(returning: false) }
                    queue.append((id, kind, go))
                }
            } onCancel: {
                Task { await self.leave(id) }
            }
        }

        private func leave(_ id: UUID) {
            guard let at = queue.firstIndex(where: { $0.id == id }) else { return }
            queue.remove(at: at).go.resume(returning: false)
        }

        func release(_ kind: Kind) {
            add(kind, -1)
            while let at = queue.firstIndex(where: { fits($0.kind) }) {
                let next = queue.remove(at: at)
                add(next.kind, 1)
                next.go.resume(returning: true)
            }
        }
    }

    // MARK: Exchange

    /// A request of the app or its player, and the answer to it.
    private final class Exchange: Sendable {
        private let client: NWConnection
        private let link: DirectLink
        private let slots: Slots
        private let port: UInt16
        private let secret: String
        private struct Inside {
            var isGone = false
            var upstream: Upstream?
            var work: Task<Void, Never>?
        }
        private let inside = Mutex(Inside())

        init(client: NWConnection, link: DirectLink, slots: Slots, port: UInt16, secret: String) {
            self.client = client
            self.link = link
            self.slots = slots
            self.port = port
            self.secret = secret
        }

        private var isGone: Bool { inside.withLock { $0.isGone } }

        /// Whoever asked went away.
        private func gone() {
            let (upstream, work) = inside.withLock { inside in
                inside.isGone = true
                return (inside.upstream, inside.work)
            }
            client.cancel()
            work?.cancel()
            upstream?.interrupt(.notWantedAnyMore)
        }

        func run() async {
            guard let request = try? await Deadline.run(.seconds(15), { try await self.read() }) else {
                return client.forceCancel()
            }
            // Host and path: a web page that points its own name at this device gets nothing, and
            // neither does another app that found the port.
            guard request.value("host") == "127.0.0.1:\(port)", request.target.hasPrefix("/\(secret)/") else {
                return await answer(404)
            }
            let path = String(request.target.dropFirst(secret.utf8.count + 1))
            if path == "/alive" { return await answer(204) }
            guard path.hasPrefix("/v1/"), request.value("origin") == nil, request.value("sec-fetch-site") == nil,
                !path.utf8.contains(where: { $0 <= 32 || $0 == 127 })
            else { return await answer(404) }
            guard ["GET", "HEAD", "PUT", "POST", "PATCH", "DELETE"].contains(request.method) else { return await answer(405) }

            watchClient()
            let kind: Slots.Kind =
                path.hasPrefix("/v1/artwork/") || path.hasPrefix("/v1/logos/") || path.hasPrefix("/v1/music/covers/")
                ? .picture : .other
            let work = Task {
                guard await slots.take(kind) else { return }
                await carry(request, path: path)
                await slots.release(kind)
            }
            let isGone = inside.withLock { inside in
                inside.work = work
                return inside.isGone
            }
            if isGone { work.cancel() }
            await work.value
            client.cancel()
        }

        /// The request is in: anything that comes now is the end.
        private func watchClient() {
            client.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, isComplete, error in
                if isComplete || error != nil { self.gone() } else { self.watchClient() }
            }
        }

        private struct Request: Sendable {
            var method: String
            var target: String
            var headers: [(name: String, value: String)]
            var body: Data

            func value(_ name: String) -> String? {
                let found = headers.filter { $0.name == name }
                return found.count == 1 ? found[0].value : nil
            }
        }

        private func read() async throws -> Request {
            try await withTaskCancellationHandler {
                var buffer = Data()
                let end = Data("\r\n\r\n".utf8)
                while true {
                    if let range = buffer.range(of: end) {
                        guard let head = HTTPHead(Data(buffer[..<range.lowerBound])) else { throw DirectError.closed }
                        let first = head.first.split(separator: " ")
                        guard first.count == 3 else { throw DirectError.closed }
                        var request = Request(
                            method: String(first[0]), target: String(first[1]), headers: head.headers,
                            body: Data(buffer[range.upperBound...]))
                        guard request.headers.allSatisfy({ $0.name != "transfer-encoding" }) else { throw DirectError.closed }
                        let length = request.value("content-length").map { Int($0) ?? -1 } ?? 0
                        guard (0...LoopbackServer.mostBody).contains(length) else { throw DirectError.closed }
                        while request.body.count < length {
                            let more = try await client.receiveSome()
                            request.body += more.data
                            if more.isComplete, request.body.count < length { throw DirectError.closed }
                        }
                        guard request.body.count == length else { throw DirectError.closed }
                        return request
                    }
                    guard buffer.count <= LoopbackServer.mostHead else { throw DirectError.closed }
                    let more = try await client.receiveSome(atMost: 16_384)
                    buffer += more.data
                    if more.isComplete, buffer.range(of: end) == nil { throw DirectError.closed }
                }
            } onCancel: {
                client.cancel()
            }
        }

        private func answer(_ status: Int) async {
            let reason = [204: "No Content", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "Error"
            let length = status == 204 ? "" : "Content-Length: 0\r\n"
            try? await client.sendKeepingOpen(Data("HTTP/1.1 \(status) \(reason)\r\n\(length)Connection: close\r\n\r\n".utf8))
            client.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                self.client.cancel()
            })
        }

        /// Nothing can be said any more: an answer that stops in the middle must not look whole.
        private func abort() {
            client.forceCancel()
        }

        // MARK: Carrying

        /// Enough of an answer to go on with it on another connection.
        private struct Remainder {
            var etag: String
            var end: Int64
            var next: Int64
        }

        private static let passedOn: Set<String> = [
            "accept", "accept-language", "content-type", "if-match", "if-modified-since", "if-none-match", "if-range",
            "range", "user-agent",
        ]
        private static let keptBack: Set<String> = [
            "connection", "keep-alive", "proxy-authenticate", "set-cookie", "strict-transport-security", "trailer",
            "upgrade", "alt-svc",
        ]

        private func carry(_ request: Request, path: String) async {
            let isSafe = request.method == "GET" || request.method == "HEAD"
            var remainder: Remainder?
            var hasAnswered = false
            var wasSent = false
            var began = ContinuousClock.now
            var tries = 0

            while !isGone, !Task.isCancelled {
                let upstream: Upstream
                do {
                    upstream = try await link.open(since: began)
                } catch {
                    return abort()
                }
                let isGone = inside.withLock { inside in
                    inside.upstream = upstream
                    return inside.isGone
                }
                if isGone { upstream.interrupt(.notWantedAnyMore) }
                defer { Task { [link] in await link.closed(upstream) } }
                do {
                    let token = await link.token ?? ""
                    try await upstream.send(head(of: request, path: path, via: upstream, token: token, from: remainder))
                    wasSent = true
                    let (answer, rest) = try await readHead(of: upstream)
                    if var going = remainder {
                        guard answer.status == 206, answer.value("etag") == going.etag,
                            let range = answer.contentRange, range.start == going.next, range.end == going.end
                        else {
                            // Another file now, or an answer that does not fit the half that was given.
                            upstream.interrupt(.notWantedAnyMore)
                            return abort()
                        }
                        try await give(rest, from: upstream, expecting: going.end - going.next + 1) {
                            going.next += Int64($0)
                            remainder = going
                            began = .now
                            tries = 0
                        }
                    } else {
                        let hasBody = request.method != "HEAD" && answer.status != 204 && answer.status != 304
                        let length = hasBody ? answer.value("content-length").flatMap(Int64.init) : 0
                        if request.method == "GET", let length, length > 0, let etag = answer.value("etag"), !etag.hasPrefix("W/"),
                            answer.value("content-encoding") == nil
                        {
                            if answer.status == 200 {
                                remainder = Remainder(etag: etag, end: length - 1, next: 0)
                            } else if answer.status == 206, let range = answer.contentRange, range.end - range.start + 1 == length {
                                remainder = Remainder(etag: etag, end: range.end, next: range.start)
                            }
                        }
                        hasAnswered = true
                        try await client.sendKeepingOpen(answer.passedOn(without: Self.keptBack))
                        began = .now
                        try await give(rest, from: upstream, expecting: length) {
                            remainder?.next += Int64($0)
                            began = .now
                            tries = 0
                        }
                    }
                    upstream.finish()
                    await finishClient()
                    return
                } catch is ClientGone {
                    upstream.interrupt(.notWantedAnyMore)
                    return
                } catch Upstream.Interruption.notWantedAnyMore {
                    return
                } catch {
                    upstream.interrupt(.superseded)
                    if let left = remainder, left.next > left.end {
                        await finishClient()
                        return
                    }
                    // Goes on from the missing byte, or is asked again when nothing came of it.
                    tries += 1
                    let canGoOn = remainder != nil || (!hasAnswered && (isSafe || !wasSent))
                    guard canGoOn, tries <= 8 else { return abort() }
                    if tries > 1 { try? await Task.sleep(for: .milliseconds(200 * tries)) }
                }
            }
        }

        private struct ClientGone: Error {}

        private func head(of request: Request, path: String, via upstream: Upstream, token: String, from remainder: Remainder?) -> Data {
            var text = "\(request.method) \(upstream.pathPrefix)\(path) HTTP/1.1\r\nHost: \(upstream.host)\r\nAuthorization: Bearer \(token)\r\nConnection: close\r\n"
            for header in request.headers where Self.passedOn.contains(header.name) {
                if remainder != nil, ["range", "if-range", "if-none-match", "if-modified-since"].contains(header.name) { continue }
                text += "\(header.name): \(header.value)\r\n"
            }
            if let remainder {
                text += "range: bytes=\(remainder.next)-\(remainder.end)\r\nif-range: \(remainder.etag)\r\n"
            }
            if !request.body.isEmpty || ["PUT", "POST", "PATCH"].contains(request.method) {
                text += "content-length: \(request.body.count)\r\n"
            }
            return Data((text + "\r\n").utf8) + request.body
        }

        private func readHead(of upstream: Upstream) async throws -> (HTTPHead, Data) {
            var buffer = Data()
            let end = Data("\r\n\r\n".utf8)
            while true {
                let more = try await upstream.receive()
                buffer += more.data
                if let range = buffer.range(of: end) {
                    guard let head = HTTPHead(Data(buffer[..<range.lowerBound])), head.status >= 200 else { throw DirectError.closed }
                    return (head, Data(buffer[range.upperBound...]))
                }
                guard !more.isComplete, buffer.count <= LoopbackServer.mostHead else { throw DirectError.closed }
            }
        }

        /// Passes the body on. The next piece is read only when the player took the last one, so that
        /// a paused player stops the box through QUIC's own windows.
        ///
        /// - Parameter expecting: How long it has to be. nil when the answer does not say.
        private func give(_ first: Data, from upstream: Upstream, expecting: Int64?, _ gave: (Int) -> Void) async throws {
            var piece = first
            var isComplete = false
            var given: Int64 = 0
            while true {
                if !piece.isEmpty {
                    if let expecting, given + Int64(piece.count) > expecting { throw DirectError.closed }
                    do {
                        try await client.sendKeepingOpen(piece)
                    } catch {
                        throw ClientGone()
                    }
                    given += Int64(piece.count)
                    gave(piece.count)
                }
                if let expecting, given == expecting { return }
                if isComplete {
                    if expecting == nil { return }
                    throw DirectError.closed
                }
                let more = try await upstream.receive()
                piece = more.data
                isComplete = more.isComplete
            }
        }

        private func finishClient() async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                client.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    done.resume()
                })
            }
        }
    }
}

/// The head of an HTTP/1.1 message.
struct HTTPHead: Sendable {
    var first: String
    /// Names in small letters.
    var headers: [(name: String, value: String)]

    init?(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first, !first.isEmpty else { return nil }
        self.first = first
        headers = []
        for line in lines.dropFirst() {
            // No folding, no bare line ends, no spaces before the colon.
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                !line.utf8.contains(where: { $0 == 10 || $0 == 13 || $0 == 0 }),
                !line[..<colon].contains(where: \.isWhitespace)
            else { return nil }
            headers.append((line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
    }

    func value(_ name: String) -> String? {
        headers.first { $0.name == name }?.value
    }

    /// Of an answer; 0 when it is none.
    var status: Int {
        let parts = first.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1.") else { return 0 }
        return Int(parts[1]) ?? 0
    }

    var contentRange: (start: Int64, end: Int64)? {
        guard let value = value("content-range"), value.hasPrefix("bytes ") else { return nil }
        let range = value.dropFirst(6).split(separator: "/").first?.split(separator: "-") ?? []
        guard range.count == 2, let start = Int64(range[0]), let end = Int64(range[1]), end >= start else { return nil }
        return (start, end)
    }

    func passedOn(without kept: Set<String>) -> Data {
        var text = first + "\r\n"
        for header in headers where !kept.contains(header.name) { text += "\(header.name): \(header.value)\r\n" }
        return Data((text + "Connection: close\r\n\r\n").utf8)
    }
}
