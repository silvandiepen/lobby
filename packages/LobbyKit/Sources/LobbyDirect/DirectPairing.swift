// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Foundation

/// Pairing a device that was never at home, with the code of a window a manager opened. The
/// introducer, which passes the messages on, learns nothing; the six digits on both screens say
/// that nobody stands in between.
public actor DirectPairing {
    public struct Waiting: Hashable, Sendable {
        /// To show. A manager compares them with those on their screen.
        public var comparison: String
        public var expiresAt: Date
    }

    public struct Approved: Sendable {
        /// The answer as the server gave it: `device` and `token`.
        public var answer: Data
        /// How to reach it from outside from now on.
        public var identity: DirectIdentity
    }

    private let invitation: PairingInvitation
    private let deviceName: String
    private let platform: String
    private let ring = Curve25519.Signing.PrivateKey()
    private let pollEvery: Duration

    private var room = ""
    private var secrets: DirectCrypto.PairingSecrets?
    private var boxKey = Data()
    private var line: IntroducerLine?
    private var session = ""

    public init(invitation: PairingInvitation, deviceName: String, platform: String, pollEvery: Duration = .seconds(3)) {
        self.invitation = invitation
        self.deviceName = String(deviceName.prefix(200))
        self.platform = platform
        self.pollEvery = pollEvery
    }

    public func close() {
        line?.close()
        line = nil
    }

    @concurrent
    private static func stretch(_ code: String) async -> DirectCrypto.CodeKeys {
        DirectCrypto.codeKeys(code)
    }

    private func openLine() async throws -> IntroducerLine {
        line?.close()
        let fresh = IntroducerLine(invitation.introducer.address("pair", room))
        line = fresh
        guard let session = try await fresh.receive(within: .seconds(10)).session else { throw DirectError.notFromTheBox }
        self.session = session
        return fresh
    }

    private func place(_ step: String) -> String {
        DirectCrypto.pairingPlace(room: room, session: session, step: step)
    }

    private struct Start: Codable { var commitment: String }
    private struct Key: Codable {
        var agreementKey: String
        var nonce: String
        var boxKey: String
    }
    private struct Reveal: Codable {
        var agreementKey: String
        var nonce: String
        var ringKey: String
        var deviceName: String
        var platform: String
    }
    private struct Status: Codable {
        var status: String
        var expiresAt: Double?
        var direct: DirectOffer?
        /// "admin": its household admin said yes, and a server admin is still to.
        var waitingFor: String?
    }
    private struct Collect: Codable {
        var nonce: String
        var done: Bool?
    }

    /// Asks to be paired. Returns the digits to show.
    public func begin() async throws -> Waiting {
        let stretched = await Self.stretch(invitation.code)
        room = stretched.room
        let codeKey = stretched.codeKey
        let line = try await openLine()

        let agreement = Curve25519.KeyAgreement.PrivateKey()
        let ownKey = agreement.publicKey.rawRepresentation
        let nonce = Data.random(32)
        // Bound to this half before the box's is seen, so that the digits cannot be steered.
        let commitment = DirectCrypto.commitment(agreementKey: ownKey, nonce: nonce)
        let toBox = DirectCrypto.codeKey(codeKey, way: .toBox)
        try await line.send(envelope: try DirectCrypto.seal(
            try JSONEncoder().encode(Start(commitment: commitment.base64URL)), key: toBox, place: place("start")))
        let opened = try DirectCrypto.open(
            try await line.envelope(), key: DirectCrypto.codeKey(codeKey, way: .toDevice), place: place("key"))
        guard let key = try? JSONDecoder().decode(Key.self, from: opened),
            let theirs = Data(base64URL: key.agreementKey, count: 32), let boxNonce = Data(base64URL: key.nonce, count: 32),
            let boxKey = Data(base64URL: key.boxKey, count: 32)
        else { throw DirectError.notFromTheBox }
        self.boxKey = boxKey

        let ringKey = ring.publicKey.rawRepresentation
        let reveal = Reveal(
            agreementKey: ownKey.base64URL, nonce: nonce.base64URL, ringKey: ringKey.base64URL, deviceName: deviceName,
            platform: platform)
        try await line.send(envelope: try DirectCrypto.seal(
            try JSONEncoder().encode(reveal), key: toBox, place: place("reveal")))
        let transcript = DirectCrypto.Transcript(
            room: room, commitment: commitment, boxAgreement: theirs, boxNonce: boxNonce, boxKey: boxKey,
            deviceAgreement: ownKey, deviceNonce: nonce, ringKey: ringKey, deviceName: deviceName, platform: platform)
        let secrets = DirectCrypto.PairingSecrets(
            shared: try DirectCrypto.agree(agreement, theirs), codeKey: codeKey, transcript: transcript.hash)
        self.secrets = secrets

        let said = try DirectCrypto.open(try await line.envelope(), key: secrets.toDevice, place: place("waiting"))
        guard let waiting = try? JSONDecoder().decode(Status.self, from: said), waiting.status == "pending",
            let expires = waiting.expiresAt
        else { throw DirectError.notFromTheBox }
        return Waiting(comparison: secrets.comparison, expiresAt: Date(timeIntervalSince1970: expires / 1000))
    }

    /// Waits for the manager. What it returns has to be kept before `done` is said.
    ///
    /// - Parameter waitingForAdmin: told when its household admin said yes and the server's
    ///   owner is still to (the request then lasts longer, as the server says).
    public func approval(
        until expiresAt: Date, waitingForAdmin: @escaping @Sendable () -> Void = {}
    ) async throws -> Approved {
        var expiresAt = expiresAt
        while Date() < expiresAt {
            try await Task.sleep(for: pollEvery)
            let plain: Data
            do {
                plain = try await ask(done: nil)
            } catch DirectError.unknownRoom, DirectError.notFromTheBox {
                throw DirectError.pairingRefused
            } catch let error as DirectError where [.introducerUnreachable, .noAnswer, .boxOffline, .tooOften].contains(error) {
                // A line that broke is opened again, with the same keys.
                close()
                continue
            }
            guard let status = try? JSONDecoder().decode(Status.self, from: plain) else { throw DirectError.notFromTheBox }
            switch status.status {
            case "pending":
                if let later = status.expiresAt.map({ Date(timeIntervalSince1970: $0 / 1000) }), later > expiresAt {
                    expiresAt = later
                }
                if status.waitingFor == "admin" { waitingForAdmin() }
                continue
            case "approved":
                guard let offer = status.direct, let secrets,
                    offer.boxKey == boxKey.base64URL, offer.boxId == DirectCrypto.boxID(ofKey: boxKey)
                else { throw DirectError.notFromTheBox }
                return Approved(answer: plain, identity: try DirectIdentity(
                    introducer: offer.introducer, boxId: offer.boxId, boxKey: offer.boxKey, fingerprints: offer.fingerprints,
                    name: offer.name, ringPrivateKey: ring.rawRepresentation, secret: secrets.secret, allowed: true))
            default:
                throw DirectError.pairingRefused
            }
        }
        throw DirectError.pairingExpired
    }

    /// Everything was kept: the box need not say it again.
    public func done() async {
        _ = try? await ask(done: true)
        close()
    }

    private func ask(done: Bool?) async throws -> Data {
        guard let secrets else { throw DirectError.closed }
        let line = if let line { line } else { try await openLine() }
        let nonce = Data.random(16).base64URL
        try await line.send(envelope: try DirectCrypto.seal(
            try JSONEncoder().encode(Collect(nonce: nonce, done: done)), key: secrets.toBox, place: place("collect")))
        return try DirectCrypto.open(try await line.envelope(), key: secrets.toDevice, place: place("answer|\(nonce)"))
    }
}
