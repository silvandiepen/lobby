// SPDX-License-Identifier: MPL-2.0
import CommonCrypto
import Foundation

/// scrypt (RFC 7914). CryptoKit has none.
enum Scrypt {
    static func derive(password: [UInt8], salt: [UInt8], n: Int, r: Int, p: Int, length: Int) -> [UInt8] {
        let words = 32 * r
        var blocks = pbkdf2(password, salt, p * words * 4)
        var table = [UInt32](repeating: 0, count: words * n)
        var x = [UInt32](repeating: 0, count: words)
        var y = x
        table.withUnsafeMutableBufferPointer { table in
            y.withUnsafeMutableBufferPointer { y in
                for one in 0..<p {
                    let base = one * words * 4
                    for i in 0..<words {
                        x[i] = (0..<4).reduce(0) { $0 | UInt32(blocks[base + i * 4 + $1]) << UInt32(8 * $1) }
                    }
                    x.withUnsafeMutableBufferPointer { x in
                        let x = x.baseAddress!, table = table.baseAddress!
                        for i in 0..<n {
                            (table + i * words).update(from: x, count: words)
                            mixBlocks(x, y.baseAddress!, r)
                        }
                        for _ in 0..<n {
                            let row = table + (Int(x[words - 16]) & (n - 1)) * words
                            for k in 0..<words { x[k] ^= row[k] }
                            mixBlocks(x, y.baseAddress!, r)
                        }
                    }
                    for i in 0..<words {
                        for k in 0..<4 { blocks[base + i * 4 + k] = UInt8(truncatingIfNeeded: x[i] >> UInt32(8 * k)) }
                    }
                }
            }
        }
        return pbkdf2(password, blocks, length)
    }

    private static func pbkdf2(_ password: [UInt8], _ salt: [UInt8], _ length: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        let status = password.withUnsafeBytes { password in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), password.bindMemory(to: CChar.self).baseAddress, password.count, salt,
                salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 1, &out, length)
        }
        precondition(status == kCCSuccess, "PBKDF2 refused its arguments.")
        return out
    }

    private static func mixBlocks(_ b: UnsafeMutablePointer<UInt32>, _ y: UnsafeMutablePointer<UInt32>, _ r: Int) {
        let words = 32 * r
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 32) { space in
            let last = space.baseAddress!, t = last + 16
            last.initialize(from: b + (words - 16), count: 16)
            t.initialize(repeating: 0, count: 16)
            @inline(__always) func turn(_ a: Int, _ c: Int, _ d: Int, _ s: UInt32) {
                let w = t[c] &+ t[d]
                t[a] ^= (w << s) | (w >> (32 - s))
            }
            for i in 0..<(2 * r) {
                for k in 0..<16 {
                    last[k] ^= b[i * 16 + k]
                    t[k] = last[k]
                }
                for _ in 0..<4 {
                    turn(4, 0, 12, 7); turn(8, 4, 0, 9); turn(12, 8, 4, 13); turn(0, 12, 8, 18)
                    turn(9, 5, 1, 7); turn(13, 9, 5, 9); turn(1, 13, 9, 13); turn(5, 1, 13, 18)
                    turn(14, 10, 6, 7); turn(2, 14, 10, 9); turn(6, 2, 14, 13); turn(10, 6, 2, 18)
                    turn(3, 15, 11, 7); turn(7, 3, 15, 9); turn(11, 7, 3, 13); turn(15, 11, 7, 18)
                    turn(1, 0, 3, 7); turn(2, 1, 0, 9); turn(3, 2, 1, 13); turn(0, 3, 2, 18)
                    turn(6, 5, 4, 7); turn(7, 6, 5, 9); turn(4, 7, 6, 13); turn(5, 4, 7, 18)
                    turn(11, 10, 9, 7); turn(8, 11, 10, 9); turn(9, 8, 11, 13); turn(10, 9, 8, 18)
                    turn(12, 15, 14, 7); turn(13, 12, 15, 9); turn(14, 13, 12, 13); turn(15, 14, 13, 18)
                }
                let to = (i / 2 + (i % 2) * r) * 16
                for k in 0..<16 {
                    last[k] = last[k] &+ t[k]
                    y[to + k] = last[k]
                }
            }
            b.update(from: y, count: words)
        }
    }
}
