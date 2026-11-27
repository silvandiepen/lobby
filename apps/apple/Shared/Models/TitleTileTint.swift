// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A hash that gives the same number for the same text on every device and every launch.
/// (`Hasher` is seeded per process, so a tile would change colour each time the app starts.)
enum StableHash {
    /// FNV-1a over the UTF-8 bytes.
    static func value(of text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// The hash with its bits spread (the 64-bit finalizer of MurmurHash3). FNV-1a's low bits
    /// barely differ between texts with the same ending, so "… Movies" and "… Series" would
    /// land on the same few colours.
    static func mixed(of text: String) -> UInt64 {
        var hash = value(of: text)
        hash ^= hash >> 33
        hash = hash &* 0xFF51_AFD7_ED55_8CCD
        hash ^= hash >> 33
        hash = hash &* 0xC4CE_B9FE_1A85_EC53
        hash ^= hash >> 33
        return hash
    }
}

/// The colour of the tile that stands in for a poster: for a film or show Lobby has no artwork
/// for (not matched yet, or a home video). Derived from the title, so "Toy Story" is the same
/// colour on the iPad, the Mac and the television.
struct TitleTileTint: Hashable, Sendable {
    enum Shade { case top, bottom }

    /// 0…1.
    var hue: Double
    var saturation: Double

    /// Twenty-four hues, fifteen degrees apart, so neighbours on a shelf differ visibly.
    static let hueSteps = 24

    init(title: String) {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let hash = StableHash.mixed(of: folded)
        hue = Double(hash % UInt64(Self.hueSteps)) / Double(Self.hueSteps)
        // Two levels of saturation from other bits of the hash: enough variety, never garish.
        saturation = (hash >> 8) % 2 == 0 ? 0.72 : 0.55
    }
}
