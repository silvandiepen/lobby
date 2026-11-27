// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// Finds icons by everyday words, in English and Dutch, and by the names of symbols.
enum SymbolSearch {
    /// Lower case, without accents, in words. Punctuation separates, also inside a symbol's
    /// name ("star.fill" is two words).
    static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en"))
            // "foto's" and "auto's" stay one word.
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// The symbols every typed word fits, the closest first. The exact name of any symbol this
    /// system has finds that symbol, also one that is in no group.
    static func results(for query: String) -> [String] {
        let typed = words(in: query)
        guard !typed.isEmpty else { return [] }
        var found = SymbolCatalog.entries.enumerated().compactMap { place, entry -> (symbol: String, rank: Int, place: Int)? in
            var rank = 0
            for word in typed {
                guard let one = self.rank(of: word, in: entry) else { return nil }
                rank += one
            }
            return (entry.symbol, rank, place)
        }
        .sorted { ($0.rank, $0.place) < ($1.rank, $1.place) }
        .map(\.symbol)

        let name = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if AppSymbol.existing(name) != nil {
            found.removeAll { $0 == name }
            found.insert(name, at: 0)
        }
        return found
    }

    /// How well one typed word fits a symbol, 0 best. nil: not at all.
    private static func rank(of word: String, in entry: SymbolCatalog.Entry) -> Int? {
        if entry.keywords.contains(word) { return 0 }
        if entry.keywords.contains(where: { $0.hasPrefix(word) }) { return 1 }
        let name = words(in: entry.symbol)
        if name.contains(word) { return 2 }
        if name.contains(where: { $0.hasPrefix(word) }) { return 3 }
        // "tekenfilms" and "dieren" in the plural, "kerstfilm" for "kerst".
        if entry.keywords.contains(where: { Self.resembles(word, $0) }) { return 4 }
        return nil
    }

    // MARK: Suggestions

    /// Icons that could stand for a category: from the words of its name, then from what its
    /// titles are. A suggestion is only shown; a person chooses.
    ///
    /// - Parameter genres: The genres of the category's titles, the commonest first.
    static func suggestions(forName name: String, genres: [String] = [], limit: Int = 12) -> [String] {
        let nameWords = words(in: name).filter { !unspecific.contains($0) }
        let wholeName = points(for: nameWords)
        // Each word of the name, and each genre, gets its say. A symbol that fits more of the
        // name comes first.
        let fromName = inTurns(nameWords.map { word in
            ranked(points(for: [word]).reduce(into: [:]) { $0[$1.key] = $1.value + 10 * wholeName[$1.key, default: 0] })
        })
        let fromGenres = inTurns(genres.prefix(4).map { ranked(points(for: words(in: $0))) })
        let nameShare = fromGenres.isEmpty ? limit : limit * 2 / 3
        var seen = Set<String>()
        return (Array(fromName.prefix(nameShare)) + fromGenres + Array(fromName.dropFirst(nameShare)))
            .filter { seen.insert($0).inserted }
            .prefix(limit)
            .map { $0 }
    }

    /// How well each symbol fits any of `words`, together.
    private static func points(for words: [String]) -> [String: Int] {
        var points: [String: Int] = [:]
        for word in words {
            for entry in SymbolCatalog.entries {
                if entry.keywords.first == word {
                    points[entry.symbol, default: 0] += 4
                } else if entry.keywords.contains(word) {
                    points[entry.symbol, default: 0] += 3
                } else if entry.keywords.contains(where: { resembles(word, $0) }) {
                    points[entry.symbol, default: 0] += 2
                }
            }
        }
        return points
    }

    /// The best first; equals in the order of the list.
    private static func ranked(_ points: [String: Int]) -> [String] {
        let places = Dictionary(uniqueKeysWithValues: SymbolCatalog.entries.enumerated().map { ($1.symbol, $0) })
        return points
            .sorted { $0.value != $1.value ? $0.value > $1.value : places[$0.key, default: 0] < places[$1.key, default: 0] }
            .map(\.key)
    }

    /// The first of every list, then the second of every list, and so on, each once.
    private static func inTurns(_ lists: [[String]]) -> [String] {
        var seen = Set<String>()
        return (0..<(lists.map(\.count).max() ?? 0)).flatMap { place in
            lists.compactMap { $0.indices.contains(place) ? $0[place] : nil }
        }
        .filter { seen.insert($0).inserted }
    }

    /// The genres of a category's titles, the commonest first.
    static func genres(of items: [Item]) -> [String] {
        var count: [String: Int] = [:]
        for item in items {
            for genre in Set(item.genres) { count[genre, default: 0] += 1 }
        }
        return count.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// Whether a word is another one in the plural or at the start or end of a compound, as
    /// Dutch makes them: "ridders" and "ridder", "kerstfilms" and "kerst".
    private static func resembles(_ word: String, _ keyword: String) -> Bool {
        guard keyword.count >= 3, word.count > keyword.count else { return false }
        if word.hasPrefix(keyword), plurals.contains(String(word.dropFirst(keyword.count))) { return true }
        guard keyword.count >= 5 else { return false }
        return word.hasPrefix(keyword) || word.hasSuffix(keyword)
    }

    private static let plurals: Set<String> = ["s", "es", "n", "en", "je", "jes"]

    /// Words that say nothing about what a category is.
    private static let unspecific: Set<String> = [
        "a", "an", "and", "the", "of", "for", "in", "on", "all", "my", "our", "with", "to",
        "de", "het", "een", "en", "van", "voor", "op", "alle", "mijn", "ons", "onze", "met",
    ]
}

extension AppModel {
    /// The genres of what a category holds, for suggesting an icon. Empty for one that is new.
    func genres(ofCategory id: String, in groups: CategoryGroups) -> [String] {
        let name = groups.category(id: id)?.name
        return SymbolSearch.genres(of: wholeCatalogue.itemsByID.values.filter { item in
            item.categoryIds?.contains(id) ?? (name.map(item.categories.contains) ?? false)
        })
    }

    func genres(ofGroup id: String) -> [String] {
        SymbolSearch.genres(of: shelves.group(id: id)?.items ?? [])
    }
}
