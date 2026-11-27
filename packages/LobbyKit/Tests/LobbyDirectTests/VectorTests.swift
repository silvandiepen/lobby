// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Foundation
import Testing

@testable import LobbyDirect

/// Every value of docs/direct-vectors.json, worked out by the app's own code.
struct VectorTests {
    private typealias Object = [String: Any]
    private let all: [String: Any]

    init() throws {
        let file = Repository.root.appending(path: "docs/direct-vectors.json")
        all = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    private func object(_ names: String...) throws -> [String: Any] {
        try names.reduce(all) { try #require($0[$1] as? [String: Any]) }
    }

    private func text(_ object: [String: Any], _ name: String) throws -> String {
        try #require(object[name] as? String)
    }

    private func bytes(_ object: [String: Any], _ name: String) throws -> Data {
        try #require(Data(base64URL: try text(object, name)))
    }

    private func envelope(_ vector: [String: Any], _ key: SymmetricKey, _ place: String) throws {
        #expect(DirectCrypto.bytes(key) == (try bytes(vector, "key")))
        #expect(place == (try text(vector, "aad")))
        let plain = Data(try text(vector, "plain").utf8)
        let sealed = try DirectCrypto.seal(
            plain, key: key, place: place, nonce: try .init(data: try bytes(vector, "nonce")))
        #expect(sealed == (try text(vector, "sealed")))
        #expect(try DirectCrypto.open(sealed, key: key, place: place) == plain)
        #expect(throws: DirectError.notFromTheBox) { try DirectCrypto.open(sealed, key: key, place: place + "x") }
    }

    @Test func scrypt() {
        // RFC 7914, section 12.
        let one = Scrypt.derive(password: Array("password".utf8), salt: Array("NaCl".utf8), n: 1024, r: 8, p: 16, length: 64)
        #expect(
            one.map { String(format: "%02x", $0) }.joined()
                == "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640")
    }

    @Test func enrolment() throws {
        let keys = try object("keys")
        let box = try Curve25519.Signing.PrivateKey(rawRepresentation: try bytes(keys, "boxSeed"))
        #expect(box.publicKey.rawRepresentation == (try bytes(keys, "boxKey")))
        #expect(DirectCrypto.boxID(ofKey: box.publicKey.rawRepresentation) == (try text(keys, "boxId")))
        let ring = try Curve25519.Signing.PrivateKey(rawRepresentation: try bytes(keys, "ringSeed"))
        #expect(ring.publicKey.rawRepresentation == (try bytes(keys, "ringKey")))
        let own = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: try bytes(keys, "deviceAgreementPrivate"))
        let theirs = try bytes(keys, "boxAgreementKey")
        let shared = try DirectCrypto.agree(own, theirs)
        #expect(shared == (try bytes(keys, "shared")))
        let secret = DirectCrypto.enrolledSecret(
            shared: shared, ownKey: own.publicKey.rawRepresentation, boxKey: theirs, boxID: try text(keys, "boxId"),
            ringKey: try text(keys, "ringKey"))
        #expect(secret == (try bytes(try object("enrolment"), "secret")))
        #expect(throws: DirectError.notFromTheBox) { try DirectCrypto.agree(own, Data(count: 32)) }
    }

    @Test func introduction() throws {
        let keys = try object("keys"), boxID = try text(keys, "boxId"), ringKey = try text(keys, "ringKey")
        let secret = try bytes(try object("enrolment"), "secret")
        let ring = try Curve25519.Signing.PrivateKey(rawRepresentation: try bytes(keys, "ringSeed")).publicKey

        let introducer = try object("introducer"), device = try object("introducer", "device")
        let message = DirectCrypto.signInMessage(boxID: boxID, nonce: try text(introducer, "nonce"))
        #expect(message == Data(try text(device, "message").utf8))
        #expect(ring.isValidSignature(try bytes(device, "signature"), for: message))

        let vector = try object("introduction"), session = try text(vector, "session")
        let nd = try bytes(vector, "deviceNonce"), nb = try bytes(vector, "boxNonce")
        func place(_ way: DirectCrypto.Way, _ count: Int) -> String {
            DirectCrypto.place(boxID: boxID, ringKey: ringKey, session: session, way: way, count: count)
        }
        try envelope(try object("introduction", "hello"), DirectCrypto.helloKey(secret), place(.toBox, 0))
        try envelope(try object("introduction", "welcome"), DirectCrypto.welcomeKey(secret, deviceNonce: nd), place(.toDevice, 0))
        try envelope(
            try object("introduction", "offer"), DirectCrypto.sessionKey(secret, deviceNonce: nd, boxNonce: nb, way: .toBox),
            place(.toBox, 1))
        try envelope(
            try object("introduction", "answer"), DirectCrypto.sessionKey(secret, deviceNonce: nd, boxNonce: nb, way: .toDevice),
            place(.toDevice, 1))
    }

    @Test func connection() throws {
        let keys = try object("keys"), vector = try object("connection")
        let ring = try Curve25519.Signing.PrivateKey(rawRepresentation: try bytes(keys, "ringSeed")).publicKey
        #expect(DirectCrypto.alpn == (try text(vector, "alpn")))
        #expect(DirectCrypto.exporterLabel == (try text(vector, "exporterLabel")))
        let message = DirectCrypto.connectMessage(boxID: try text(keys, "boxId"), exporter: try bytes(vector, "exporter"))
        #expect(message == Data(try text(vector, "message").utf8))
        let signature = try bytes(vector, "signature")
        #expect(ring.isValidSignature(signature, for: message))
        #expect(DirectCrypto.proofFrame(ringKey: ring.rawRepresentation, signature: signature) == (try bytes(vector, "frame")))
    }

    @Test func pairing() throws {
        let keys = try object("keys"), vector = try object("pairing")
        let code = try text(vector, "code")
        let began = ContinuousClock.now
        let stretched = DirectCrypto.codeKeys(code)
        print("scrypt of a pairing code took \(ContinuousClock.now - began)")
        #expect(stretched.room == (try text(vector, "room")))
        #expect(stretched.codeKey == (try bytes(vector, "codeKey")))
        let codeKeys = try object("pairing", "keys")
        let up = DirectCrypto.codeKey(stretched.codeKey, way: .toBox)
        #expect(DirectCrypto.bytes(up) == (try bytes(codeKeys, "d2b")))
        #expect(DirectCrypto.bytes(DirectCrypto.codeKey(stretched.codeKey, way: .toDevice)) == (try bytes(codeKeys, "b2d")))

        let nd = try bytes(try object("introduction"), "deviceNonce"), nb = try bytes(try object("introduction"), "boxNonce")
        let own = try bytes(keys, "deviceAgreementKey")
        let commitment = DirectCrypto.commitment(agreementKey: own, nonce: nd)
        #expect(commitment == (try bytes(vector, "commitment")))
        let session = try text(vector, "session")
        func place(_ step: String) -> String { DirectCrypto.pairingPlace(room: stretched.room, session: session, step: step) }
        try envelope(try object("pairing", "start"), up, place("start"))

        let transcript = DirectCrypto.Transcript(
            room: stretched.room, commitment: commitment, boxAgreement: try bytes(keys, "boxAgreementKey"), boxNonce: nb,
            boxKey: try bytes(keys, "boxKey"), deviceAgreement: own, deviceNonce: nd, ringKey: try bytes(keys, "ringKey"),
            deviceName: try text(vector, "deviceName"), platform: try text(vector, "platform"))
        #expect(transcript.hash == (try bytes(vector, "transcript")))
        let secrets = DirectCrypto.PairingSecrets(
            shared: try bytes(keys, "shared"), codeKey: stretched.codeKey, transcript: transcript.hash)
        let sessionKeys = try object("pairing", "sessionKeys")
        #expect(DirectCrypto.bytes(secrets.toBox) == (try bytes(sessionKeys, "d2b")))
        #expect(DirectCrypto.bytes(secrets.toDevice) == (try bytes(sessionKeys, "b2d")))
        #expect(secrets.secret == (try bytes(vector, "secret")))
        #expect(secrets.comparison == (try text(vector, "comparison")))
        try envelope(try object("pairing", "waiting"), secrets.toDevice, place("waiting"))
        try envelope(try object("pairing", "collect"), secrets.toBox, place("collect"))
    }
}

/// What people type, scan and keep.
struct InvitationTests {
    @Test func codes() {
        #expect(PairingCode.read("0123-4567-89ab-cdef") == "0123456789ABCDEF")
        #expect(PairingCode.read("O1I3 4567 l9ab cdef") == "0113456719ABCDEF")
        #expect(PairingCode.read("0123-4567-89ab-cde") == nil)
        #expect(PairingCode.read("U123-4567-89ab-cdef") == nil)
        #expect(PairingCode.clean("o1!u2") == "012")
        #expect(PairingCode.grouped("0123456789") == "0123-4567-89")
    }

    @Test func links() throws {
        let made = try #require(PairingInvitation(introducer: "introducer.example.com", code: "0123-4567-89AB-CDEF"))
        #expect(made.introducer.url.absoluteString == "wss://introducer.example.com")
        #expect(made.introducer.display == "introducer.example.com")
        #expect(PairingInvitation(link: made.link) == made)
        #expect(PairingInvitation(introducer: "https://introducer.example.com/", code: "0123456789ABCDEF") == made)
        for refused in ["ws://introducer.example.com", "wss://user@introducer.example.com", "http://a.example.com", "name", ""] {
            #expect(PairingInvitation(introducer: refused, code: "0123456789ABCDEF") == nil, "\(refused)")
        }
        for refused in ["https://pair?i=a.example.com&c=0123456789ABCDEF", "lobby://pair?i=a.example.com", "lobby://pair?i=a.example.com&c=1&c=2"] {
            #expect(PairingInvitation(link: refused) == nil, "\(refused)")
        }
    }

    /// The TV shows, the phone sends: over this machine, with the real listener.
    @Test func handOver() async throws {
        let invitation = try #require(PairingInvitation(introducer: "introducer.example.com", code: "0123456789ABCDEF"))
        let (got, sink) = AsyncStream.makeStream(of: PairingInvitation.self)
        let receiver = try await HandOverReceiver.start(addresses: ["127.0.0.1"]) { sink.yield($0) }
        defer { receiver.stop() }
        let target = try #require(HandOverTarget(link: receiver.target.link))
        #expect(target == receiver.target)
        // Who did not see the TV's screen cannot put anything in.
        let stranger = HandOverTarget(addresses: target.addresses, port: target.port, key: Data.random(32))
        await #expect(throws: (any Error).self) { try await stranger.send(invitation) }
        try await target.send(invitation)
        var iterator = got.makeAsyncIterator()
        #expect(await iterator.next() == invitation)
        // Once.
        await #expect(throws: (any Error).self) { try await target.send(invitation) }
    }
}
