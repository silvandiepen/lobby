// SPDX-License-Identifier: MPL-2.0
import CLobbyIce
import Foundation
import Synchronization

/// One ICE agent with a port on this device in front of it. See `CLobbyIce.h`.
final class Ice: Sendable {
    enum Event: Sendable {
        case gathered
        case state(State)
    }

    /// libjuice's states, as far as they matter here.
    enum State: Int32, Sendable {
        case disconnected = 0, gathering, connecting, connected, completed, failed
    }

    struct Server: Codable, Hashable, Sendable {
        var host: String
        var port: UInt16
    }

    struct Relay: Codable, Hashable, Sendable {
        var host: String
        var port: UInt16
        var username: String
        var password: String
    }

    let events: AsyncStream<Event>
    private let id: Int32
    private static let sinks = Mutex<[Int32: AsyncStream<Event>.Continuation]>([:])

    init(stun: Server?, turn: Relay?, bind: String?) throws {
        let strings = [stun?.host, turn?.host, turn?.username, turn?.password, bind].map { $0.flatMap { strdup($0) } }
        defer { strings.forEach { free($0) } }
        let p = strings.map { UnsafePointer($0) }
        var config = lobby_ice_config(
            stun_host: p[0], stun_port: stun?.port ?? 0, turn_host: p[1], turn_port: turn?.port ?? 0, turn_user: p[2],
            turn_password: p[3], bind: p[4])
        let (stream, sink) = AsyncStream.makeStream(of: Event.self)
        // Nothing happens before `gather`, so that keeping the sink after opening is in time.
        let id = lobby_ice_open(&config) { id, event, value in
            let happened: Event? = event == 0 ? .gathered : State(rawValue: value).map(Event.state)
            guard let happened else { return }
            _ = Ice.sinks.withLock { $0[id] }?.yield(happened)
        }
        guard id >= 0 else { throw DirectError.noPath }
        self.id = id
        events = stream
        Ice.sinks.withLock { $0[id] = sink }
    }

    deinit {
        Ice.sinks.withLock { $0.removeValue(forKey: id) }?.finish()
        // It waits for the agent's own threads.
        DispatchQueue.global().async { [id] in lobby_ice_close(id) }
    }

    /// Some networks leave a STUN address unanswered, and the agent then waits long: what is known
    /// after `limit` is enough to try.
    func gather(limit: Duration) async -> String? {
        lobby_ice_gather(id)
        let ended = Task { [sink = Ice.sinks.withLock { $0[id] }] in
            if (try? await Task.sleep(for: limit)) != nil { sink?.yield(.gathered) }
        }
        defer { ended.cancel() }
        for await event in events {
            if case .gathered = event { break }
        }
        return local
    }

    /// Waits until the agent found a path.
    func connect(to sdp: String) async throws {
        guard lobby_ice_remote(id, sdp) == 0 else { throw DirectError.notFromTheBox }
        for await event in events {
            switch event {
            case .state(.connected), .state(.completed): return
            case .state(.failed): throw DirectError.noPath
            default: continue
            }
        }
        throw CancellationError()
    }

    var port: UInt16 { lobby_ice_port(id) }

    /// How long nothing came from the other end over the path. nil before anything did.
    var quiet: Duration? {
        let ms = lobby_ice_quiet_ms(id)
        return ms == UInt64.max ? nil : .milliseconds(Int64(clamping: ms))
    }

    private var local: String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        return lobby_ice_local(id, &buffer, buffer.count) == 0 ? Self.text(buffer) : nil
    }

    /// Whether the chosen path runs over the owner's relay.
    var isRelayed: Bool {
        var own = [CChar](repeating: 0, count: 256), theirs = own
        guard lobby_ice_pair(id, &own, &theirs, own.count) == 0 else { return false }
        return Self.text(own).contains("typ relay") || Self.text(theirs).contains("typ relay")
    }

    private static func text(_ characters: [CChar]) -> String {
        String(decoding: characters.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}
