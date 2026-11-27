// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Foundation

/// What the box says about itself at home (`GET`/`PUT /v1/me/direct`).
public struct DirectOffer: Codable, Hashable, Sendable {
    public var introducer: String
    public var boxId: String
    public var boxKey: String
    public var fingerprints: [String]
    public var name: String
    /// The key this device enrolled with, if it did.
    public var ringKey: String?
    public var allowed: Bool?
    /// Only in the answer to enrolling.
    public var agreementKey: String?
}

/// What a device keeps to reach its box from outside. Secret: it lives in the Keychain, on this
/// device only.
public struct DirectIdentity: Codable, Hashable, Sendable {
    public var introducer: String
    public var boxId: String
    public var boxKey: String
    /// SHA-256 of the certificates the box may show.
    public var fingerprints: [String]
    /// The `Host` of every request.
    public var name: String
    /// Ed25519. Only opens the door to ringing.
    var ringPrivateKey: Data
    /// 32 bytes only the device and the box know.
    var secret: Data
    /// Whether a manager lets this device in, as far as it knew when it was last at home.
    public var allowed: Bool

    init(
        introducer: String, boxId: String, boxKey: String, fingerprints: [String], name: String, ringPrivateKey: Data,
        secret: Data, allowed: Bool
    ) throws {
        // The id is the key's hash: what is kept cannot be half of one box and half of another.
        guard let key = Data(base64URL: boxKey, count: 32), DirectCrypto.boxID(ofKey: key) == boxId,
            !fingerprints.isEmpty, fingerprints.allSatisfy({ Data(base64URL: $0, count: 32) != nil }),
            Self.isHostName(name), secret.count == 32, IntroducerAddress(introducer) != nil
        else { throw DirectError.badIdentity }
        self.introducer = introducer
        self.boxId = boxId
        self.boxKey = boxKey
        self.fingerprints = fingerprints
        self.name = name
        self.ringPrivateKey = ringPrivateKey
        self.secret = secret
        self.allowed = allowed
    }

    func ring() throws -> Curve25519.Signing.PrivateKey {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: ringPrivateKey) else {
            throw DirectError.badIdentity
        }
        return key
    }

    public var ringKey: String? {
        (try? ring())?.publicKey.rawRepresentation.base64URL
    }

    public func encoded() throws -> String {
        try JSONEncoder().encode(self).base64EncodedString()
    }

    public init?(encoded: String) {
        guard let data = Data(base64Encoded: encoded), let read = try? JSONDecoder().decode(Self.self, from: data),
            (try? read.ring()) != nil
        else { return nil }
        self = read
    }

    /// The same identity with what the box says now. nil when it has to enrol again.
    public func updated(with offer: DirectOffer) -> DirectIdentity? {
        guard offer.ringKey == ringKey, offer.boxId == boxId, offer.boxKey == boxKey else { return nil }
        return try? DirectIdentity(
            introducer: offer.introducer, boxId: boxId, boxKey: boxKey, fingerprints: offer.fingerprints, name: offer.name,
            ringPrivateKey: ringPrivateKey, secret: secret, allowed: offer.allowed ?? allowed)
    }

    /// It goes into a request's head as it is.
    private static func isHostName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 253
            && name.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 122) || ($0 >= 65 && $0 <= 90) || $0 == 45 || $0 == 46 }
    }
}

/// A device getting ready at home: the keys it makes, and what comes of the box's answer.
public struct DirectEnrolment: Sendable {
    private let ring = Curve25519.Signing.PrivateKey()
    private let agreement = Curve25519.KeyAgreement.PrivateKey()

    public init() {}

    public var ringKey: String { ring.publicKey.rawRepresentation.base64URL }
    public var agreementKey: String { agreement.publicKey.rawRepresentation.base64URL }

    public func finish(_ offer: DirectOffer) throws -> DirectIdentity {
        guard let theirs = offer.agreementKey.flatMap({ Data(base64URL: $0, count: 32) }), offer.ringKey == ringKey
        else { throw DirectError.badIdentity }
        let shared = try DirectCrypto.agree(agreement, theirs)
        return try DirectIdentity(
            introducer: offer.introducer, boxId: offer.boxId, boxKey: offer.boxKey, fingerprints: offer.fingerprints,
            name: offer.name, ringPrivateKey: ring.rawRepresentation,
            secret: DirectCrypto.enrolledSecret(
                shared: shared, ownKey: agreement.publicKey.rawRepresentation, boxKey: theirs, boxID: offer.boxId,
                ringKey: ringKey),
            allowed: offer.allowed ?? false)
    }
}

/// Where the introducer is. TLS, except on this very device (for tests).
public struct IntroducerAddress: Hashable, Sendable {
    public let url: URL

    /// What a person typed or a QR code says: `introducer.example.com`, with or without `wss://`.
    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if let range = text.range(of: "https://", options: [.anchored, .caseInsensitive]) {
            text.replaceSubrange(range, with: "wss://")
        }
        if !text.contains("://") { text = "wss://" + text }
        guard text.utf8.count <= 300, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
            let host = url.host, !host.isEmpty, url.user == nil, url.query == nil, url.fragment == nil,
            scheme == "wss" || (scheme == "ws" && host == "127.0.0.1")
        else { return nil }
        guard scheme == "ws" || host.contains(".") else { return nil }
        self.url = url
    }

    /// For a screen: without the scheme that everyone has.
    public var display: String {
        url.scheme == "wss" ? String(url.absoluteString.dropFirst("wss://".count)) : url.absoluteString
    }

    func address(_ kind: String, _ name: String) -> URL {
        url.appending(path: "v1").appending(path: kind).appending(path: name)
    }
}
