// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Foundation
import Network
import Synchronization

/// Giving an Apple TV its invitation without typing: the TV shows a QR code with where it listens on
/// the network and a key made for this once. A phone on the same network reads it and sends the
/// invitation, sealed with that key: who is on the network sees nothing and can put nothing in.
public struct HandOverTarget: Hashable, Sendable {
    public var addresses: [String]
    public var port: UInt16
    var key: Data

    public init?(link: String) {
        guard link.utf8.count <= 600, let parts = URLComponents(string: link), parts.scheme?.lowercased() == "lobby",
            parts.host == "tv", let items = parts.queryItems
        else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let port = value("p").flatMap(UInt16.init), port != 0, let key = value("k").flatMap({ Data(base64URL: $0, count: 32) }),
            let addresses = value("a")?.split(separator: ",").map(String.init), (1...4).contains(addresses.count),
            addresses.allSatisfy({ IPv4Address($0) != nil })
        else { return nil }
        self.addresses = addresses
        self.port = port
        self.key = key
    }

    init(addresses: [String], port: UInt16, key: Data) {
        self.addresses = addresses
        self.port = port
        self.key = key
    }

    public var link: String {
        var parts = URLComponents()
        parts.scheme = "lobby"
        parts.host = "tv"
        parts.queryItems = [
            URLQueryItem(name: "a", value: addresses.joined(separator: ",")), URLQueryItem(name: "p", value: String(port)),
            URLQueryItem(name: "k", value: key.base64URL),
        ]
        return parts.string ?? ""
    }

    fileprivate func sealingKey(_ way: String) -> SymmetricKey {
        DirectCrypto.hkdf(key, info: "lobby-tv/1|\(way)")
    }
    fileprivate static let place = "lobby-tv/1|invitation"

    /// Sends the invitation to the TV. Throws when it is not on this network.
    public func send(_ invitation: PairingInvitation) async throws {
        let message = try DirectCrypto.seal(Data(invitation.link.utf8), key: sealingKey("to"), place: Self.place) + "\n"
        var problem: any Error = DirectError.noPath
        for address in addresses {
            let connection = NWConnection(
                host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port) ?? .any, using: .tcp)
            defer { connection.cancel() }
            connection.start(queue: DispatchQueue(label: "lobby.handover"))
            do {
                let answer = try await Deadline.run(.seconds(6)) {
                    try await withTaskCancellationHandler {
                        try await connection.sendKeepingOpen(Data(message.utf8))
                        return try await HandOverReceiver.line(from: connection)
                    } onCancel: {
                        connection.cancel()
                    }
                }
                _ = try DirectCrypto.open(answer, key: sealingKey("back"), place: Self.place)
                return
            } catch {
                problem = error
            }
        }
        throw problem
    }
}

/// The TV's side: listens on the network it is on until an invitation came or it is stopped.
public final class HandOverReceiver: Sendable {
    public let target: HandOverTarget
    private let listener: NWListener
    private let tries = Mutex(0)

    private init(target: HandOverTarget, listener: NWListener) {
        self.target = target
        self.listener = listener
    }

    deinit { listener.cancel() }

    public func stop() {
        listener.newConnectionHandler = nil
        listener.cancel()
    }

    /// - Parameter received: Called once.
    public static func start(_ received: @escaping @Sendable (PairingInvitation) -> Void) async throws -> HandOverReceiver {
        try await start(addresses: localAddresses(), received)
    }

    static func start(addresses: [String], _ received: @escaping @Sendable (PairingInvitation) -> Void) async throws -> HandOverReceiver {
        guard !addresses.isEmpty else { throw DirectError.noPath }
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters)
        let slot = Mutex<HandOverReceiver?>(nil)
        listener.newConnectionHandler = { connection in
            guard let receiver = slot.withLock({ $0 }) else { return connection.cancel() }
            receiver.accept(connection, received) { slot.withLock { $0 = nil } }
        }
        let (states, sink) = AsyncStream.makeStream(of: NWListener.State.self)
        listener.stateUpdateHandler = { sink.yield($0) }
        listener.start(queue: DispatchQueue(label: "lobby.handover"))
        for await state in states {
            switch state {
            case .ready:
                let receiver = HandOverReceiver(
                    target: HandOverTarget(addresses: addresses, port: listener.port?.rawValue ?? 0, key: Data.random(32)),
                    listener: listener)
                slot.withLock { $0 = receiver }
                return receiver
            case .failed(let error), .waiting(let error):
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

    private func accept(
        _ connection: NWConnection, _ received: @escaping @Sendable (PairingInvitation) -> Void, over: @escaping @Sendable () -> Void
    ) {
        let mayTry = tries.withLock { tries in
            tries += 1
            return tries <= 20
        }
        guard mayTry else { return connection.cancel() }
        connection.start(queue: DispatchQueue(label: "lobby.handover"))
        let target = target
        Task { [weak self] in
            defer { connection.cancel() }
            let said = try? await Deadline.run(.seconds(10)) {
                try await withTaskCancellationHandler {
                    try await Self.line(from: connection)
                } onCancel: {
                    connection.cancel()
                }
            }
            guard let said, let plain = try? DirectCrypto.open(said, key: target.sealingKey("to"), place: HandOverTarget.place),
                let invitation = PairingInvitation(link: String(decoding: plain, as: UTF8.self)),
                let answer = try? DirectCrypto.seal(Data("ok".utf8), key: target.sealingKey("back"), place: HandOverTarget.place)
            else { return }
            try? await connection.sendKeepingOpen(Data((answer + "\n").utf8))
            self?.stop()
            over()
            received(invitation)
            // Time for the answer to arrive before the connection goes.
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    fileprivate static func line(from connection: NWConnection) async throws -> String {
        var buffer = Data()
        while buffer.last != 10 {
            let more = try await connection.receiveSome(atMost: 2048)
            buffer += more.data
            guard buffer.count <= 2048, !more.isComplete || buffer.last == 10 else { throw DirectError.notFromTheBox }
        }
        return String(decoding: buffer.dropLast(), as: UTF8.self)
    }

    /// The addresses other devices on this network find this one at.
    static func localAddresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var found: [String] = []
        for one in sequence(first: first, next: { $0?.pointee.ifa_next }).compactMap({ $0?.pointee }) {
            guard let address = one.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                one.ifa_flags & UInt32(IFF_LOOPBACK) == 0, one.ifa_flags & UInt32(IFF_UP) != 0,
                String(cString: one.ifa_name).hasPrefix("en")
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            found.append(String(decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self))
        }
        return Array(found.prefix(4))
    }
}
