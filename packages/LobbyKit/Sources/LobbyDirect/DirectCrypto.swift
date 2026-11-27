// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Foundation

/// The values of `docs/api.md`, Direct. `docs/direct-vectors.json` works every one of them out.
enum DirectCrypto {
    static func hkdf(_ key: Data, salt: Data = Data(), info: String, length: Int = 32) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: key), salt: salt, info: Data(info.utf8), outputByteCount: length)
    }

    static func bytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// `base64url(nonce ‖ ciphertext ‖ tag)`.
    static func seal(_ plain: Data, key: SymmetricKey, place: String, nonce: ChaChaPoly.Nonce = .init()) throws -> String {
        try ChaChaPoly.seal(plain, using: key, nonce: nonce, authenticating: Data(place.utf8)).combined.base64URL
    }

    static func open(_ envelope: String, key: SymmetricKey, place: String) throws -> Data {
        guard envelope.utf8.count <= 16_384, let raw = Data(base64URL: envelope),
            let box = try? ChaChaPoly.SealedBox(combined: raw),
            let plain = try? ChaChaPoly.open(box, using: key, authenticating: Data(place.utf8))
        else { throw DirectError.notFromTheBox }
        return plain
    }

    static func agree(_ own: Curve25519.KeyAgreement.PrivateKey, _ theirs: Data) throws -> Data {
        guard let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirs),
            let shared = try? own.sharedSecretFromKeyAgreement(with: key)
        else { throw DirectError.notFromTheBox }
        let bytes = shared.withUnsafeBytes { Data($0) }
        // A key of small order agrees on nothing.
        guard bytes.contains(where: { $0 != 0 }) else { throw DirectError.notFromTheBox }
        return bytes
    }

    // MARK: Enrolling

    static func enrolledSecret(shared: Data, ownKey: Data, boxKey: Data, boxID: String, ringKey: String) -> Data {
        bytes(hkdf(shared, salt: ownKey + boxKey, info: "lobby-direct/1|secret|\(boxID)|\(ringKey)"))
    }

    static func boxID(ofKey key: Data) -> String {
        sha256(key).base64URL
    }

    // MARK: Introduction

    enum Way: String { case toBox = "d2b", toDevice = "b2d" }

    static func place(boxID: String, ringKey: String, session: String, way: Way, count: Int) -> String {
        "lobby-direct/1|\(boxID)|\(ringKey)|\(session)|\(way.rawValue)|\(count)"
    }

    static func helloKey(_ secret: Data) -> SymmetricKey {
        hkdf(secret, info: "lobby-direct/1|hello|d2b")
    }

    static func welcomeKey(_ secret: Data, deviceNonce: Data) -> SymmetricKey {
        hkdf(secret, salt: deviceNonce, info: "lobby-direct/1|welcome|b2d")
    }

    static func sessionKey(_ secret: Data, deviceNonce: Data, boxNonce: Data, way: Way) -> SymmetricKey {
        hkdf(secret, salt: deviceNonce + boxNonce, info: "lobby-direct/1|session|\(way.rawValue)")
    }

    static func signInMessage(boxID: String, nonce: String) -> Data {
        Data("lobby-introducer/1|device|\(boxID)|\(nonce)".utf8)
    }

    // MARK: Connection

    static let alpn = "lobby-direct/1"
    static let exporterLabel = "EXPORTER-lobby-direct-1"

    static func connectMessage(boxID: String, exporter: Data) -> Data {
        Data("lobby-direct/1|connect|\(boxID)|\(exporter.base64URL)".utf8)
    }

    static func proofFrame(ringKey: Data, signature: Data) -> Data {
        Data("LDA1".utf8) + ringKey + signature
    }

    // MARK: Pairing

    struct CodeKeys {
        var room: String
        var codeKey: Data
    }

    /// 32 MB and about half a second: not on the main thread.
    static func codeKeys(_ code: String) -> CodeKeys {
        let stretched = Data(Scrypt.derive(
            password: Array(code.utf8), salt: Array("lobby-pair/1|code".utf8), n: 32_768, r: 8, p: 1, length: 64))
        return CodeKeys(room: stretched[0..<16].base64URL, codeKey: Data(stretched[32..<64]))
    }

    static func codeKey(_ codeKey: Data, way: Way) -> SymmetricKey {
        hkdf(codeKey, info: "lobby-pair/1|code|\(way.rawValue)")
    }

    static func commitment(agreementKey: Data, nonce: Data) -> Data {
        sha256(Data("lobby-pair/1|commit|".utf8) + agreementKey + nonce)
    }

    static func pairingPlace(room: String, session: String, step: String) -> String {
        "lobby-pair/1|\(room)|\(session)|\(step)"
    }

    struct Transcript {
        var room: String
        var commitment: Data
        var boxAgreement: Data
        var boxNonce: Data
        var boxKey: Data
        var deviceAgreement: Data
        var deviceNonce: Data
        var ringKey: Data
        var deviceName: String
        var platform: String

        var hash: Data {
            var all = Data()
            for part in [
                Data("lobby-pair/1".utf8), Data(room.utf8), commitment, boxAgreement, boxNonce, boxKey, deviceAgreement,
                deviceNonce, ringKey, Data(deviceName.utf8), Data(platform.utf8),
            ] {
                all += [UInt8(part.count >> 8), UInt8(part.count & 255)] + part
            }
            return DirectCrypto.sha256(all)
        }
    }

    struct PairingSecrets: Sendable {
        var toBox: SymmetricKey
        var toDevice: SymmetricKey
        var secret: Data
        /// Six digits that both screens show.
        var comparison: String

        init(shared: Data, codeKey: Data, transcript: Data) {
            let from = shared + codeKey
            toBox = DirectCrypto.hkdf(from, salt: transcript, info: "lobby-pair/1|session|d2b")
            toDevice = DirectCrypto.hkdf(from, salt: transcript, info: "lobby-pair/1|session|b2d")
            secret = DirectCrypto.bytes(DirectCrypto.hkdf(from, salt: transcript, info: "lobby-pair/1|secret"))
            let number = DirectCrypto.bytes(
                DirectCrypto.hkdf(from, salt: transcript, info: "lobby-pair/1|comparison", length: 8)
            ).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % 1_000_000
            let digits = String(number)
            comparison = String(repeating: "0", count: 6 - digits.count) + digits
        }
    }
}
