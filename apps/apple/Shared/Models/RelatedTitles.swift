// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// What goes with a film or series, the closest first: the rest of its film series, then what
/// shares its categories and genres, then what is of its time and as well known. Only from what
/// is given, which is what the viewer may see; what plays first, what was watched last.
enum RelatedTitles {
    static let limit = 20

    /// - Parameters:
    ///   - candidates: Films, home videos and series the viewer may see.
    ///   - isPlayable: Whether a title can be played here now.
    ///   - isWatched: Whether the viewer has seen it.
    static func rank(
        _ item: Item, among candidates: [Item], isPlayable: (Item) -> Bool, isWatched: (Item) -> Bool
    ) -> [Item] {
        let family = familyKey(item.title)
        let named = Dictionary((item.related ?? []).enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let genres = Set(item.genres), folders = Set(item.categoryIds ?? item.categories)

        func score(_ other: Item) -> Double {
            var score = 0.0
            if let family, familyKey(other.title) == family { score += 100 }
            // A server that knows better says so; what it names first counts most.
            if let place = named[other.id] { score += 60 - Double(min(place, 30)) }
            score += 10 * Double(folders.intersection(other.categoryIds ?? other.categories).count)
            score += 6 * Double(genres.intersection(other.genres).count)
            if other.kind == item.kind { score += 2 }
            if let year = item.year, let theirs = other.year { score -= min(Double(abs(year - theirs)) * 0.25, 5) }
            if let renown = item.renown, let theirs = other.renown { score -= abs(renown - theirs) * 4 }
            return score
        }

        let others = candidates.filter { $0.id != item.id && Shelves.topLevelKinds.contains($0.kind) }
        let scored = others.map { (item: $0, score: score($0), playable: isPlayable($0), watched: isWatched($0)) }
        // What plays and is new to the viewer, then what was seen, then what does not play here.
        return scored.sorted { a, b in
            let aGroup = a.playable ? (a.watched ? 1 : 0) : 2, bGroup = b.playable ? (b.watched ? 1 : 0) : 2
            if aGroup != bGroup { return aGroup < bGroup }
            if a.score != b.score { return a.score > b.score }
            return (a.item.sortTitle, a.item.id) < (b.item.sortTitle, b.item.id)
        }
        .prefix(limit).map(\.item)
    }

    /// What the titles of one film series share: "Toy Story 2" and "Toy Story" are both
    /// "toy story". nil for a title that says nothing of the kind.
    static func familyKey(_ title: String) -> String? {
        var words = title.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        for mark in [":", " - ", " – "] {
            if let range = words.range(of: mark) { words = String(words[..<range.lowerBound]) }
        }
        var parts = words.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if parts.first == "the" || parts.first == "a" { parts.removeFirst() }
        let numbers: Set<String> = ["2", "3", "4", "5", "6", "7", "8", "9", "ii", "iii", "iv", "v", "vi", "two", "three", "part", "chapter"]
        while let last = parts.last, numbers.contains(last) || Int(last) != nil { parts.removeLast() }
        guard !parts.isEmpty, parts.joined().count >= 3 else { return nil }
        return parts.joined(separator: " ")
    }
}
