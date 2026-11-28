// SPDX-License-Identifier: MPL-2.0
import Foundation
import Synchronization

/// One event of the live channel (`GET /v1/live`).
public enum LiveEvent: Hashable, Sendable {
    case hello(LiveHello)
    /// Replaces everything known.
    case snapshot([ShownDevice], serverTime: Int64)
    /// Replaces what is known of that device.
    case device(ShownDevice, serverTime: Int64)
    /// Not shown any more.
    case gone(deviceID: String, serverTime: Int64)
    case command(IncomingCommand)
    case result(RemoteResult)
    /// How waking a TV for this device goes.
    case wake(WakeProgress)
    case heartbeat(serverTime: Int64)
    /// What a child this session plays for may do now (docs/api.md, Kids control), and whether
    /// this device is to lock itself to Lobby for it (nil from a server from before the lock).
    case kidsMode(profileID: String, now: KidsNow, lock: Bool?)
    /// A child's question for this grown-up, or (on the child's device) what came of it.
    case kidsRequest(KidsRequest)
    /// A question this grown-up was asked was answered, taken back or expired.
    case kidsRequestClosed(KidsRequest)
    /// The HomePods and speakers this session may play on, and what plays on them. Replaces what
    /// was known.
    case speakers([ShownSpeaker], serverTime: Int64)
    /// An event this build does not know. Ignored.
    case unknown(String)
}

/// Reads `text/event-stream` line by line: `id:`, `event:`, `data:`, and an empty line that ends
/// an event. Only one `data` line per event, as the server sends it.
public struct LiveEventParser: Sendable {
    public struct Raw: Hashable, Sendable {
        public var id: String?
        public var event: String
        public var data: String

        public init(id: String?, event: String, data: String) {
            self.id = id
            self.event = event
            self.data = data
        }
    }

    private var id: String?
    private var event: String?
    private var data: [String] = []

    public init() {}

    /// A line without its line ending. Returns an event when the line ended one.
    public mutating func feed(_ line: String) -> Raw? {
        if line.isEmpty {
            defer {
                id = nil
                event = nil
                data = []
            }
            guard event != nil || !data.isEmpty else { return nil }
            return Raw(id: id, event: event ?? "message", data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "id": id = String(value)
        case "event": event = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }

    /// What a raw event means. nil for one that cannot be read: the channel goes on.
    public static func decode(_ raw: Raw) -> LiveEvent? {
        let data = Data(raw.data.utf8)
        let decoder = JSONDecoder()
        struct Time: Decodable { var serverTime: Double? }
        let time = Int64((try? decoder.decode(Time.self, from: data))?.serverTime ?? 0)
        do {
            switch raw.event {
            case "hello":
                return .hello(try decoder.decode(LiveHello.self, from: data))
            case "snapshot":
                struct Body: Decodable { var devices: [ShownDevice] }
                return .snapshot(try decoder.decode(Body.self, from: data).devices, serverTime: time)
            case "device":
                struct Body: Decodable { var device: ShownDevice }
                return .device(try decoder.decode(Body.self, from: data).device, serverTime: time)
            case "gone":
                struct Body: Decodable { var deviceId: String }
                return .gone(deviceID: try decoder.decode(Body.self, from: data).deviceId, serverTime: time)
            case "command":
                return .command(try decoder.decode(IncomingCommand.self, from: data))
            case "result":
                return .result(try decoder.decode(RemoteResult.self, from: data))
            case "wake":
                return .wake(try decoder.decode(WakeProgress.self, from: data))
            case "heartbeat":
                return .heartbeat(serverTime: time)
            case "kidsMode":
                struct Body: Decodable {
                    var profileId: String
                    var now: KidsNow
                    var lock: Bool?
                }
                let body = try decoder.decode(Body.self, from: data)
                return .kidsMode(profileID: body.profileId, now: body.now, lock: body.lock)
            case "speakers":
                struct Body: Decodable { var speakers: [ShownSpeaker] }
                return .speakers(try decoder.decode(Body.self, from: data).speakers, serverTime: time)
            case "kidsRequest", "kidsRequestClosed":
                struct Body: Decodable { var request: KidsRequest }
                let request = try decoder.decode(Body.self, from: data).request
                return raw.event == "kidsRequest" ? .kidsRequest(request) : .kidsRequestClosed(request)
            default:
                return .unknown(raw.event)
            }
        } catch {
            return nil
        }
    }
}

/// The server's clock, as this device can know it: its own steady clock plus a difference,
/// taken from the answers to its own posts with half the round trip.
public struct ServerClock: Hashable, Sendable {
    /// Server time minus this device's steady time, in milliseconds.
    public private(set) var offsetMs: Double?
    /// The round trip of the measurement in use. A shorter one is a better one.
    public private(set) var roundTripMs: Double = .infinity
    private var measuredAtMs: Double = 0

    public init() {}

    /// The answer to a post came: sent at `sentMs`, answered at `receivedMs`, both by the
    /// steady clock.
    public mutating func measure(serverTime: Int64, sentMs: Double, receivedMs: Double) {
        let roundTrip = max(0, receivedMs - sentMs)
        // A measurement gets older: after a minute a slower one counts as much.
        let aged = roundTripMs + max(0, receivedMs - measuredAtMs) / 60
        guard offsetMs == nil || roundTrip <= aged else { return }
        offsetMs = Double(serverTime) + roundTrip / 2 - receivedMs
        roundTripMs = roundTrip
        measuredAtMs = receivedMs
    }

    /// A time the server said in an event, when there is no measurement yet. It arrived a little
    /// after it was written: that is the best there is until a post is answered.
    public mutating func heard(serverTime: Int64, atMs: Double) {
        guard offsetMs == nil, serverTime > 0 else { return }
        offsetMs = Double(serverTime) - atMs
    }

    /// The server's time now, or nil while it is not known.
    public func serverNow(steadyMs: Double) -> Int64? {
        offsetMs.map { Int64(($0 + steadyMs).rounded()) }
    }
}

/// The steady clock of this device in milliseconds, from an origin of its own. Never goes back.
public enum SteadyClock {
    private static let origin = ContinuousClock.now

    public static func nowMs() -> Double {
        let elapsed = ContinuousClock.now - origin
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }
}

/// The live channel: one long answer that says what the household's devices do, opened again
/// when it breaks. `updates()` runs it for as long as it is read.
public struct LiveChannel: Sendable {
    public enum Update: Hashable, Sendable {
        /// A connection is open; `hello` follows as an event.
        case event(LiveEvent)
        /// The connection broke or fell silent. It is opened again by itself.
        case lost
        /// The server will not have it: this device is not paired any more, or the server does
        /// not know the channel. It is not opened again.
        case refused(LobbyError)
    }

    public let client: LobbyClient
    public let session: String
    private let urlSession: URLSession
    private let sleep: @Sendable (Duration) async throws -> Void

    /// - Parameter urlSession: One of its own: the channel holds a connection as long as it is open.
    public init(
        client: LobbyClient, session: String, urlSession: URLSession = LiveChannel.makeSession(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.session = session
        self.urlSession = urlSession
        self.sleep = sleep
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        // Between two bytes: the server says something every five seconds.
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldUsePipelining = false
        return URLSession(configuration: configuration)
    }

    /// The waits between tries after a connection broke: at once, and then longer, up to 15 s.
    public static func wait(afterFailures failures: Int) -> Duration {
        let steps: [Duration] = [.zero, .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)]
        return steps[min(max(0, failures), steps.count - 1)]
    }

    /// Opens the channel, and again whenever it breaks, until the stream is no longer read.
    public func updates() -> AsyncStream<Update> {
        AsyncStream { continuation in
            let task = Task {
                await run { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ say: @escaping @Sendable (Update) -> Void) async {
        let state = ChannelState()
        while !Task.isCancelled {
            let (last, silentMs) = state.value.withLock { ($0.last, $0.silentMs) }
            let outcome = await connect(last: last, silentMs: silentMs) { raw in
                if let id = raw.id { state.value.withLock { $0.last = id } }
                guard let event = LiveEventParser.decode(raw) else { return }
                if case .hello(let hello) = event {
                    state.value.withLock {
                        $0.failures = 0
                        $0.silentMs = max(hello.silentMs, 3_000)
                    }
                }
                say(.event(event))
            }
            if Task.isCancelled { return }
            switch outcome {
            case .refused(let error):
                say(.refused(error))
                return
            case .busy(let seconds):
                say(.lost)
                do { try await sleep(.seconds(seconds)) } catch { return }
            case .broke:
                say(.lost)
                let failures = state.value.withLock {
                    $0.failures += 1
                    return $0.failures
                }
                do { try await sleep(Self.wait(afterFailures: failures - 1)) } catch { return }
            }
        }
    }

    private enum Outcome: Sendable {
        case broke
        case refused(LobbyError)
        case busy(Double)
    }

    private func connect(
        last: String?, silentMs: Int, take: @escaping @Sendable (LiveEventParser.Raw) -> Void
    ) async -> Outcome {
        var request = client.liveRequest(session: session, last: last)
        request.timeoutInterval = 30
        let heard = Heard()
        let urlSession = urlSession
        let reading = Task { [request] () -> Outcome in
            do {
                let (bytes, response) = try await urlSession.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { return .broke }
                guard http.statusCode == 200 else {
                    var data = Data()
                    for try await byte in bytes {
                        data.append(byte)
                        if data.count > 16_384 { break }
                    }
                    let error = LobbyError.from(status: http.statusCode, data: data, headers: http)
                    switch error {
                    case .rateLimited(_, let after): return .busy(min(60, max(1, after ?? 5)))
                    case .unauthorized, .deviceRevoked, .notFound, .forbidden: return .refused(error)
                    default: return .broke
                    }
                }
                await heard.now()
                var parser = LiveEventParser()
                var line: [UInt8] = []
                for try await byte in bytes {
                    if byte == 0x0A {
                        if line.last == 0x0D { line.removeLast() }
                        let text = String(decoding: line, as: UTF8.self)
                        line.removeAll(keepingCapacity: true)
                        await heard.now()
                        if let raw = parser.feed(text) { take(raw) }
                    } else {
                        line.append(byte)
                    }
                }
                return .broke
            } catch {
                return .broke
            }
        }
        // Nothing for `silentMs` means the connection is dead, however open it looks.
        let watchdog = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if await heard.silence() > Double(silentMs) {
                    reading.cancel()
                    return
                }
            }
        }
        let outcome = await withTaskCancellationHandler {
            await reading.value
        } onCancel: {
            reading.cancel()
        }
        watchdog.cancel()
        return outcome
    }
}

/// What the channel keeps from one connection to the next.
private final class ChannelState: Sendable {
    struct Value {
        var last: String?
        var failures = 0
        var silentMs = 12_000
    }

    let value = Mutex(Value())
}

/// When the channel last said anything.
private actor Heard {
    private var at = SteadyClock.nowMs()
    func now() { at = SteadyClock.nowMs() }
    func silence() -> Double { SteadyClock.nowMs() - at }
}
