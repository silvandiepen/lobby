// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Foundation
import Network
import Security
import Synchronization

/// One encrypted connection to the box. ICE finds the path (direct, or over the owner's relay),
/// QUIC carries what is said over it, and the box's certificate is the one known from pairing.
/// The introducer passes sealed messages on and is not trusted.
public final class DirectSession: Sendable {
    public enum Path: Hashable, Sendable {
        case direct
        /// Over the owner's own relay.
        case relay
    }

    public let path: Path
    /// The certificates the box named when it answered.
    let fingerprints: [String]

    private let ice: Ice
    private let group: NWConnectionGroup
    private let state: Watch

    /// Whether it is still there, and who wants to know when it is not.
    private final class Watch: Sendable {
        struct Inside {
            var isOver = false
            var waiting: [UUID: AsyncStream<Void>.Continuation] = [:]
        }
        let inside = Mutex(Inside())

        func end() {
            let waiting = inside.withLock { inside in
                inside.isOver = true
                defer { inside.waiting = [:] }
                return inside.waiting
            }
            waiting.values.forEach { $0.finish() }
        }
    }

    private let iceWatch: Task<Void, Never>

    private init(ice: Ice, group: NWConnectionGroup, state: Watch, fingerprints: [String]) {
        self.ice = ice
        self.group = group
        self.state = state
        self.fingerprints = fingerprints
        path = ice.isRelayed ? .relay : .direct
        iceWatch = Task { [events = ice.events, group] in
            for await event in events {
                // The path is gone, and QUIC would take half a minute to notice.
                if case .state(.failed) = event {
                    state.end()
                    group.cancel()
                    return
                }
            }
        }
    }

    deinit {
        iceWatch.cancel()
        group.cancel()
    }

    public func close() {
        state.end()
        group.cancel()
        // The goodbye goes out over the path: without it the box keeps the connection until ICE
        // gives up on it half a minute later, and calls that "no path".
        let ice = ice
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.goodbye) { withExtendedLifetime(ice) {} }
    }

    /// For the last packet to go out, as on the box.
    static let goodbye = 0.4

    public var isOver: Bool { state.inside.withLock { $0.isOver } }

    /// How long nothing came from the box. With `keepsAsking` on it answers at least every second.
    var quiet: Duration? { ice.quiet }

    /// While something is carried: Apple's QUIC asks the box every second, so that a path that
    /// broke is noticed within a few seconds, also when the player has enough and reads nothing.
    /// Off when nothing is carried, so that an idle app does not keep the radio awake.
    func keepsAsking(_ isOn: Bool) {
        // Set once a change: setting it again would start its clock again.
        guard let quic = group.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata,
            asking.withLock({ was in defer { was = isOn }; return was != isOn })
        else { return }
        quic.keepAlive = isOn ? .seconds(1) : .off
    }
    private let asking = Mutex(false)

    /// Returns when the connection is over.
    func waitForEnd() async {
        let (stream, sink) = AsyncStream.makeStream(of: Void.self)
        let id = UUID()
        let over = state.inside.withLock { inside in
            if !inside.isOver { inside.waiting[id] = sink }
            return inside.isOver
        }
        if over { return }
        for await _ in stream {}
        _ = state.inside.withLock { $0.waiting.removeValue(forKey: id) }
    }

    /// A new stream: one HTTP connection to the box. Not started yet.
    func stream() -> NWConnection? {
        isOver ? nil : NWConnection(from: group)
    }

    // MARK: Connecting

    /// Where a test's road bends: not used by the apps.
    struct Detours: Sendable {
        var bind: String?
        /// Changes the descriptions on their way, so that a test's road lies between the two.
        var offer: (@Sendable (String) -> String)?
        var answer: (@Sendable (String) -> String)?
        var proof: (@Sendable (Data) -> Data)?
        var fingerprints: (@Sendable ([String]) -> [String])?
    }

    /// Rings, finds a path, connects and proves itself. Gives up after `limit`.
    ///
    /// - Parameter stunTurn: Which of the box's STUN servers to ask: another one each time.
    static func connect(
        _ identity: DirectIdentity, stunTurn: Int = 0, limit: Duration = .seconds(30), detours: Detours = Detours()
    ) async throws -> DirectSession {
        try await Deadline.run(limit) {
            try await ring(identity, stunTurn: stunTurn, detours: detours)
        }
    }

    private struct Hello: Codable {
        var t = "hello"
        var nonce: String
    }

    private struct Welcome: Decodable {
        struct Servers: Decodable {
            var stun: [Ice.Server]
            var turn: Ice.Relay?
        }
        var t: String
        var nonce: String
        var fingerprints: [String]
        var ice: Servers
    }

    private struct Description: Codable {
        var t: String
        var sdp: String?
        var error: String?
    }

    private static func ring(_ identity: DirectIdentity, stunTurn: Int, detours: Detours) async throws -> DirectSession {
        guard let introducer = IntroducerAddress(identity.introducer) else { throw DirectError.badIdentity }
        let key = try identity.ring()
        let ringKey = key.publicKey.rawRepresentation.base64URL
        let line = IntroducerLine(introducer.address("box", identity.boxId))
        defer { line.close() }

        guard let challenge = try await line.receive(within: .seconds(10)).nonce else { throw DirectError.notFromTheBox }
        let signature = try key.signature(for: DirectCrypto.signInMessage(boxID: identity.boxId, nonce: challenge))
        try await line.send(["t": "auth", "role": "device", "key": ringKey, "signature": signature.base64URL])
        guard let session = try await line.receive(within: .seconds(10)).session else { throw DirectError.notFromTheBox }
        func place(_ way: DirectCrypto.Way, _ count: Int) -> String {
            DirectCrypto.place(boxID: identity.boxId, ringKey: ringKey, session: session, way: way, count: count)
        }

        // The box names its STUN servers and hands out a short-lived password for its relay,
        // sealed: the introducer learns neither.
        let deviceNonce = Data.random(32)
        let hello = try JSONEncoder().encode(Hello(nonce: deviceNonce.base64URL))
        try await line.send(
            envelope: try DirectCrypto.seal(hello, key: DirectCrypto.helloKey(identity.secret), place: place(.toBox, 0)))
        let opened = try DirectCrypto.open(
            try await line.envelope(), key: DirectCrypto.welcomeKey(identity.secret, deviceNonce: deviceNonce),
            place: place(.toDevice, 0))
        guard let welcome = try? JSONDecoder().decode(Welcome.self, from: opened), welcome.t == "welcome",
            let boxNonce = Data(base64URL: welcome.nonce, count: 32), !welcome.fingerprints.isEmpty
        else { throw DirectError.notFromTheBox }

        let servers = welcome.ice.stun
        let ice = try Ice(
            stun: servers.isEmpty ? nil : servers[abs(stunTurn) % servers.count], turn: welcome.ice.turn, bind: detours.bind)
        guard var offer = await ice.gather(limit: .seconds(4)) else { throw DirectError.noPath }
        try Task.checkCancellation()
        if let change = detours.offer { offer = change(offer) }
        func sessionKey(_ way: DirectCrypto.Way) -> SymmetricKey {
            DirectCrypto.sessionKey(identity.secret, deviceNonce: deviceNonce, boxNonce: boxNonce, way: way)
        }
        try await line.send(envelope: try DirectCrypto.seal(
            try JSONEncoder().encode(Description(t: "offer", sdp: offer)), key: sessionKey(.toBox), place: place(.toBox, 1)))
        let said = try DirectCrypto.open(try await line.envelope(), key: sessionKey(.toDevice), place: place(.toDevice, 1))
        guard let answer = try? JSONDecoder().decode(Description.self, from: said) else { throw DirectError.notFromTheBox }
        line.close()
        guard answer.t == "answer", var theirs = answer.sdp else {
            throw answer.error == "busy" ? DirectError.busy : DirectError.noAnswer
        }
        if let change = detours.answer { theirs = change(theirs) }
        try await ice.connect(to: theirs)
        try Task.checkCancellation()
        return try await quic(over: ice, identity: identity, key: key, fingerprints: detours.fingerprints?(welcome.fingerprints) ?? welcome.fingerprints,
            detours: detours)
    }

    /// Apple's QUIC, to the agent's port on this device.
    private static func quic(
        over ice: Ice, identity: DirectIdentity, key: Curve25519.Signing.PrivateKey, fingerprints: [String], detours: Detours
    ) async throws -> DirectSession {
        guard let port = NWEndpoint.Port(rawValue: ice.port), ice.port != 0 else { throw DirectError.noPath }
        let options = NWProtocolQUIC.Options(alpn: [DirectCrypto.alpn])
        options.direction = .bidirectional
        options.idleTimeout = 30_000
        options.maxUDPPayloadSize = 1350
        // What the box has under way when a player jumps is wasted: these bound it.
        options.initialMaxData = 4 << 20
        options.initialMaxStreamDataBidirectionalLocal = 1 << 20
        let accepted = Set(fingerprints)
        // nil: the certificate is not the box's. Apple's QUIC goes on trying after that.
        let (states, sink) = AsyncStream.makeStream(of: NWConnectionGroup.State?.self)
        sec_protocol_options_set_verify_block(
            options.securityProtocolOptions,
            { _, trust, done in
                let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
                let leaf = chain?.first.map { DirectCrypto.sha256(SecCertificateCopyData($0) as Data).base64URL }
                let isTheBox = leaf.map(accepted.contains) ?? false
                if !isTheBox { sink.yield(nil) }
                done(isTheBox)
            }, DispatchQueue(label: "lobby.direct.verify"))

        let group = NWConnectionGroup(
            with: NWMultiplexGroup(to: .hostPort(host: "127.0.0.1", port: port)), using: NWParameters(quic: options))
        // The box opens no streams.
        group.newConnectionHandler = { $0.cancel() }
        let watch = Watch()
        group.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: watch.end()
            default: break
            }
            sink.yield(state)
        }
        group.start(queue: DispatchQueue(label: "lobby.direct.quic"))
        do {
            try await withTaskCancellationHandler {
                for await state in states {
                    switch state {
                    case nil: throw DirectError.wrongCertificate
                    case .ready?: return
                    case .failed?, .cancelled?: throw DirectError.noPath
                    // It passes through .waiting on the way to .ready.
                    default: continue
                    }
                }
                throw CancellationError()
            } onCancel: {
                group.cancel()
            }
            try await prove(on: group, identity: identity, key: key, detours: detours)
        } catch {
            group.cancel()
            throw error
        }
        return DirectSession(ice: ice, group: group, state: watch, fingerprints: fingerprints)
    }

    /// The first stream says who this is: a signature over something only this very connection has.
    private static func prove(
        on group: NWConnectionGroup, identity: DirectIdentity, key: Curve25519.Signing.PrivateKey, detours: Detours
    ) async throws {
        guard let quic = group.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata,
            let exported = DirectCrypto.exporterLabel.withCString({ label in
                sec_protocol_metadata_create_secret(
                    quic.securityProtocolMetadata, DirectCrypto.exporterLabel.utf8.count, label, 32)
            })
        else { throw DirectError.proofRefused }
        let exporter = Data(copying: exported as DispatchData)
        let signature = try key.signature(for: DirectCrypto.connectMessage(boxID: identity.boxId, exporter: exporter))
        let honest = DirectCrypto.proofFrame(ringKey: key.publicKey.rawRepresentation, signature: signature)
        let frame = detours.proof?(honest) ?? honest
        guard let stream = NWConnection(from: group) else { throw DirectError.closed }
        stream.start(queue: DispatchQueue(label: "lobby.direct.proof"))
        let answer = try await Deadline.run(.seconds(10)) {
            try await withTaskCancellationHandler {
                try await stream.sendKeepingOpen(frame)
                return try await stream.receiveSome(atMost: 1).data
            } onCancel: {
                stream.cancel()
            }
        }
        guard answer == Data([0]) else { throw DirectError.proofRefused }
        // Ended, and read to its end: what is cancelled with data under way breaks the connection.
        stream.endAndDrain()
    }
}

extension Data {
    init(copying data: DispatchData) {
        var copy = Data(capacity: data.count)
        data.enumerateBytes { bytes, _, _ in copy.append(contentsOf: bytes) }
        self = copy
    }
}

extension NWConnection {
    struct Received: Sendable {
        var data: Data
        var isComplete: Bool
    }

    /// Sends and leaves this side of the stream open: a side that ends says that the device went away.
    func sendKeepingOpen(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            send(content: data, contentContext: .finalMessage, isComplete: false, completion: .contentProcessed { error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            })
        }
    }

    func receiveSome(atMost: Int = 262_144) async throws -> Received {
        try await withCheckedThrowingContinuation { done in
            receive(minimumIncompleteLength: 1, maximumLength: atMost) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    done.resume(returning: Received(data: data, isComplete: isComplete))
                } else if let error {
                    done.resume(throwing: error)
                } else {
                    done.resume(returning: Received(data: Data(), isComplete: isComplete))
                }
            }
        }
    }

    /// Ends this side and reads the other to its end.
    func endAndDrain() {
        send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        drain()
    }

    private func drain() {
        receive(minimumIncompleteLength: 1, maximumLength: 262_144) { _, _, isComplete, error in
            if isComplete || error != nil { self.cancel() } else { self.drain() }
        }
    }
}
