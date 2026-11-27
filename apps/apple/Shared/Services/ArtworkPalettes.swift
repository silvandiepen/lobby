// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// The colours of pictures, each worked out once and kept in a file, so that a page has them
/// without the server too.
struct ArtworkPalettes {
    static let fileName = "colours-2.json"

    /// More than a household has titles. What is left out is worked out again.
    private static let limit = 5000

    private let file: URL
    private var known: [String: ArtworkPalette]?

    init(directory: URL) {
        file = directory.appending(path: Self.fileName, directoryHint: .notDirectory)
    }

    mutating func palette(of id: String) -> ArtworkPalette? {
        load()[id]
    }

    mutating func keep(_ palette: ArtworkPalette, of id: String) {
        var all = load()
        if all.count >= Self.limit { all = [:] }
        all[id] = palette
        known = all
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(all).write(to: file, options: .atomic)
    }

    mutating func forget() {
        known = nil
        try? FileManager.default.removeItem(at: file)
    }

    private mutating func load() -> [String: ArtworkPalette] {
        if let known { return known }
        let read = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: ArtworkPalette].self, from: $0) } ?? [:]
        known = read
        return read
    }
}
