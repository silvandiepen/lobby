// SPDX-License-Identifier: MPL-2.0
// Works docs/direct-vectors.json out again with what an app has: CryptoKit and CommonCrypto.
//
//   swiftc -O tools/check-direct-vectors.swift -o /tmp/check && /tmp/check docs/direct-vectors.json
//
// The scrypt here is RFC 7914, checked against its own vector first; CryptoKit has none.
import CommonCrypto
import CryptoKit
import Foundation

func un(_ text: String) -> Data {
    var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while s.count % 4 != 0 { s += "=" }
    return Data(base64Encoded: s)!
}
func b64(_ data: some DataProtocol) -> String {
    Data(data).base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
func raw(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
func hkdf(_ key: Data, _ salt: Data, _ info: String, _ length: Int = 32) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: key), salt: salt, info: Data(info.utf8),
        outputByteCount: length)
}

func pbkdf2(_ password: [UInt8], _ salt: [UInt8], _ length: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: length)
    password.withUnsafeBytes { p in
        _ = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress?.assumingMemoryBound(to: CChar.self),
            password.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 1, &out,
            length)
    }
    return out
}

func scrypt(_ password: [UInt8], _ salt: [UInt8], n: Int, r: Int, p: Int, length: Int) -> [UInt8] {
    let words = 32 * r
    var blocks = pbkdf2(password, salt, p * words * 4)
    var v = [UInt32](repeating: 0, count: words * n)
    var x = [UInt32](repeating: 0, count: words)
    var y = x
    var t = [UInt32](repeating: 0, count: 16)
    func blockMix(_ b: UnsafeMutablePointer<UInt32>, _ y: UnsafeMutablePointer<UInt32>,
                  _ t: UnsafeMutablePointer<UInt32>) {
        var l0 = (0..<16).map { b[words - 16 + $0] }
        l0.withUnsafeMutableBufferPointer { l in
            for i in 0..<(2 * r) {
                for k in 0..<16 { l[k] ^= b[i * 16 + k]; t[k] = l[k] }
                for _ in 0..<4 {
                    func q(_ a: Int, _ c: Int, _ d: Int, _ s: UInt32) {
                        let w = t[c] &+ t[d]
                        t[a] ^= (w << s) | (w >> (32 - s))
                    }
                    q(4, 0, 12, 7); q(8, 4, 0, 9); q(12, 8, 4, 13); q(0, 12, 8, 18)
                    q(9, 5, 1, 7); q(13, 9, 5, 9); q(1, 13, 9, 13); q(5, 1, 13, 18)
                    q(14, 10, 6, 7); q(2, 14, 10, 9); q(6, 2, 14, 13); q(10, 6, 2, 18)
                    q(3, 15, 11, 7); q(7, 3, 15, 9); q(11, 7, 3, 13); q(15, 11, 7, 18)
                    q(1, 0, 3, 7); q(2, 1, 0, 9); q(3, 2, 1, 13); q(0, 3, 2, 18)
                    q(6, 5, 4, 7); q(7, 6, 5, 9); q(4, 7, 6, 13); q(5, 4, 7, 18)
                    q(11, 10, 9, 7); q(8, 11, 10, 9); q(9, 8, 11, 13); q(10, 9, 8, 18)
                    q(12, 15, 14, 7); q(13, 12, 15, 9); q(14, 13, 12, 13); q(15, 14, 13, 18)
                }
                let to = (i / 2 + (i % 2) * r) * 16
                for k in 0..<16 { l[k] = l[k] &+ t[k]; y[to + k] = l[k] }
            }
        }
        b.update(from: y, count: words)
    }
    for one in 0..<p {
        let base = one * words * 4
        for i in 0..<words {
            x[i] = (0..<4).reduce(0) { $0 | UInt32(blocks[base + i * 4 + $1]) << UInt32(8 * $1) }
        }
        x.withUnsafeMutableBufferPointer { x in
            y.withUnsafeMutableBufferPointer { y in
                t.withUnsafeMutableBufferPointer { t in
                    v.withUnsafeMutableBufferPointer { v in
                        for i in 0..<n {
                            (v.baseAddress! + i * words).update(from: x.baseAddress!, count: words)
                            blockMix(x.baseAddress!, y.baseAddress!, t.baseAddress!)
                        }
                        for _ in 0..<n {
                            let j = Int(x[words - 16]) & (n - 1)
                            for k in 0..<words { x[k] ^= v[j * words + k] }
                            blockMix(x.baseAddress!, y.baseAddress!, t.baseAddress!)
                        }
                    }
                }
            }
        }
        for i in 0..<words {
            for k in 0..<4 { blocks[base + i * 4 + k] = UInt8(truncatingIfNeeded: x[i] >> UInt32(8 * k)) }
        }
    }
    return pbkdf2(password, blocks, length)
}

typealias Object = [String: Any]
let file = CommandLine.arguments[1]
let all = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as! Object
let keys = all["keys"] as! [String: String]
var wrong = 0
func check(_ what: String, _ ok: Bool) {
    print(ok ? "ok   " : "WRONG", what)
    if !ok { wrong += 1 }
}
func text(_ o: Object, _ k: String) -> String { o[k] as! String }

// RFC 7914, section 12.
check("scrypt", Data(scrypt(Array("password".utf8), Array("NaCl".utf8), n: 1024, r: 8, p: 16, length: 64))
    .map { String(format: "%02x", $0) }.joined()
    == "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640")

let box = try Curve25519.Signing.PrivateKey(rawRepresentation: un(keys["boxSeed"]!))
let ring = try Curve25519.Signing.PrivateKey(rawRepresentation: un(keys["ringSeed"]!))
check("boxKey", b64(box.publicKey.rawRepresentation) == keys["boxKey"])
check("boxId", b64(Data(SHA256.hash(data: box.publicKey.rawRepresentation))) == keys["boxId"])
check("ringKey", b64(ring.publicKey.rawRepresentation) == keys["ringKey"])
let boxId = keys["boxId"]!, ringKey = keys["ringKey"]!
let deviceAgreement = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: un(keys["deviceAgreementPrivate"]!))
let boxAgreement = un(keys["boxAgreementKey"]!), ownAgreement = deviceAgreement.publicKey.rawRepresentation
check("deviceAgreementKey", b64(ownAgreement) == keys["deviceAgreementKey"])
let shared = try deviceAgreement.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: boxAgreement))
    .withUnsafeBytes { Data($0) }
check("shared", b64(shared) == keys["shared"])
let secret = raw(hkdf(shared, ownAgreement + boxAgreement, "lobby-direct/1|secret|\(boxId)|\(ringKey)"))
check("secret", b64(secret) == text(all["enrolment"] as! Object, "secret"))

func signed(_ name: String, _ o: Object, _ message: String, _ key: Curve25519.Signing.PublicKey) {
    check("\(name) message", text(o, "message") == message)
    check("\(name) signature", key.isValidSignature(un(text(o, "signature")), for: Data(message.utf8)))
}
let introducer = all["introducer"] as! Object
let challenge = text(introducer, "nonce")
signed("device", introducer["device"] as! Object, "lobby-introducer/1|device|\(boxId)|\(challenge)", ring.publicKey)
signed("box", introducer["box"] as! Object, "lobby-introducer/1|box|\(boxId)|\(challenge)", box.publicKey)

func envelope(_ name: String, _ o: Object, _ key: SymmetricKey, _ aad: String) throws {
    check("\(name) key", b64(raw(key)) == text(o, "key"))
    check("\(name) aad", aad == text(o, "aad"))
    let plain = Data(text(o, "plain").utf8)
    let made = try ChaChaPoly.seal(
        plain, using: key, nonce: .init(data: un(text(o, "nonce"))), authenticating: Data(aad.utf8))
    check("\(name) sealed", b64(made.combined) == text(o, "sealed"))
    let opened = try ChaChaPoly.open(
        .init(combined: un(text(o, "sealed"))), using: key, authenticating: Data(aad.utf8))
    check("\(name) opened", opened == plain)
}
let intro = all["introduction"] as! Object
let session = text(intro, "session")
let nd = un(text(intro, "deviceNonce")), nb = un(text(intro, "boxNonce"))
func aad(_ way: String, _ count: Int) -> String { "lobby-direct/1|\(boxId)|\(ringKey)|\(session)|\(way)|\(count)" }
try envelope("hello", intro["hello"] as! Object, hkdf(secret, Data(), "lobby-direct/1|hello|d2b"), aad("d2b", 0))
try envelope("welcome", intro["welcome"] as! Object, hkdf(secret, nd, "lobby-direct/1|welcome|b2d"), aad("b2d", 0))
try envelope("offer", intro["offer"] as! Object, hkdf(secret, nd + nb, "lobby-direct/1|session|d2b"), aad("d2b", 1))
try envelope("answer", intro["answer"] as! Object, hkdf(secret, nd + nb, "lobby-direct/1|session|b2d"), aad("b2d", 1))

let connection = all["connection"] as! Object
signed("connection", connection, "lobby-direct/1|connect|\(boxId)|\(text(connection, "exporter"))", ring.publicKey)
check("frame", un(text(connection, "frame"))
    == Data("LDA1".utf8) + ring.publicKey.rawRepresentation + un(text(connection, "signature")))

let pairing = all["pairing"] as! Object
let began = Date()
let stretched = Data(scrypt(Array(text(pairing, "code").utf8), Array("lobby-pair/1|code".utf8), n: 32768, r: 8, p: 1, length: 64))
print("     scrypt took \(Int(Date().timeIntervalSince(began) * 1000)) ms")
let room = b64(stretched[0..<16]), codeKey = Data(stretched[32..<64])
check("room", room == text(pairing, "room"))
check("codeKey", b64(codeKey) == text(pairing, "codeKey"))
let d2b = hkdf(codeKey, Data(), "lobby-pair/1|code|d2b"), b2d = hkdf(codeKey, Data(), "lobby-pair/1|code|b2d")
let codeKeys = pairing["keys"] as! [String: String]
check("code keys", b64(raw(d2b)) == codeKeys["d2b"] && b64(raw(b2d)) == codeKeys["b2d"])
let commitment = Data(SHA256.hash(data: Data("lobby-pair/1|commit|".utf8) + ownAgreement + nd))
check("commitment", b64(commitment) == text(pairing, "commitment"))
func place(_ step: String) -> String { "lobby-pair/1|\(room)|\(session)|\(step)" }
try envelope("start", pairing["start"] as! Object, d2b, place("start"))
var transcript = Data()
for part in [
    Data("lobby-pair/1".utf8), Data(room.utf8), commitment, boxAgreement, nb,
    box.publicKey.rawRepresentation, ownAgreement, nd, ring.publicKey.rawRepresentation,
    Data(text(pairing, "deviceName").utf8), Data(text(pairing, "platform").utf8),
] {
    transcript += [UInt8(part.count >> 8), UInt8(part.count & 255)] + part
}
let hash = Data(SHA256.hash(data: transcript))
check("transcript", b64(hash) == text(pairing, "transcript"))
let from = shared + codeKey
let up = hkdf(from, hash, "lobby-pair/1|session|d2b"), down = hkdf(from, hash, "lobby-pair/1|session|b2d")
let sessionKeys = pairing["sessionKeys"] as! [String: String]
check("session keys", b64(raw(up)) == sessionKeys["d2b"] && b64(raw(down)) == sessionKeys["b2d"])
check("pairing secret", b64(raw(hkdf(from, hash, "lobby-pair/1|secret"))) == text(pairing, "secret"))
let digits = raw(hkdf(from, hash, "lobby-pair/1|comparison", 8)).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % 1_000_000
check("comparison", String(format: "%06llu", digits) == text(pairing, "comparison"))
try envelope("waiting", pairing["waiting"] as! Object, down, place("waiting"))
try envelope("collect", pairing["collect"] as! Object, up, place("collect"))
print(wrong == 0 ? "all as they should be" : "\(wrong) wrong")
exit(wrong == 0 ? 0 : 1)
