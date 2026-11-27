// SPDX-License-Identifier: MPL-2.0
import Foundation

// Stories are the household's audiobooks as the apps show them: for a child who listens, and
// beside the films they were made from (docs/decisions.md, "Stories").

extension MusicBook {
    /// Who wrote it, leaving out whoever only reads it. Read-along stories often carry the
    /// reader in every name tag; then nobody is known to have written it.
    public var writers: [String] {
        let readers = Set(narrators.map(TitleKey.fold))
        return authors.filter { !readers.contains(TitleKey.fold($0)) }
    }

    /// "Read by …", or nil when nobody is named.
    public var readBy: String? {
        narrators.isEmpty ? nil : "Read by " + narrators.joined(separator: ", ")
    }

    /// One line under the title: who wrote it, else who reads it.
    public var credit: String? {
        let writers = writers
        return writers.isEmpty ? readBy : writers.joined(separator: ", ")
    }
}

extension MusicCatalogue {
    /// The books this viewer began and has not finished, the one listened to last first.
    public func continueListening(_ progress: [String: PlaybackProgress], limit: Int = 12) -> [MusicBook] {
        progress.values
            .filter { !$0.completed && $0.positionMs > 0 }
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap { books[$0.itemId] }
            .prefix(limit)
            .map { $0 }
    }
}

/// What a title is when names are compared: the same words, whatever the case, accents,
/// punctuation or a leading article.
public enum TitleKey {
    private static let articles = ["the ", "a ", "an "]

    public static func of(_ title: String) -> String {
        var words = ""
        for character in fold(title).replacingOccurrences(of: "&", with: " and ") {
            if character.isLetter || character.isNumber {
                words.append(character)
            } else if character == "'" || character == "’" {
                // "Ariel's" is one word.
                continue
            } else if words.last != " " {
                words.append(" ")
            }
        }
        var key = words.trimmingCharacters(in: .whitespaces)
        for article in articles where key.hasPrefix(article) {
            key.removeFirst(article.count)
            break
        }
        return key
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// Stories and films of the same name, both ways: "Listen to the story" on a film's page,
/// "Watch the film" on a story's. Only from what the viewer has: a child's films are its own.
public struct StoryFilms: Sendable {
    private var filmOfBook: [String: Item] = [:]
    private var bookOfFilm: [String: MusicBook] = [:]

    public init(books: some Collection<MusicBook>, films: some Collection<Item>) {
        var filmsByKey: [String: [Item]] = [:]
        for film in films where film.kind == .movie {
            let key = TitleKey.of(film.title)
            if !key.isEmpty { filmsByKey[key, default: []].append(film) }
        }
        guard !filmsByKey.isEmpty else { return }
        // In title order, so that of two stories of one name the first is the film's.
        for book in books.sorted(by: { ($0.sortTitle, $0.id) < ($1.sortTitle, $1.id) }) {
            guard let candidates = filmsByKey[TitleKey.of(book.title)],
                let film = Self.choose(candidates, for: book)
            else { continue }
            filmOfBook[book.id] = film
            if bookOfFilm[film.id] == nil { bookOfFilm[film.id] = book }
        }
    }

    public func film(ofBook id: String) -> Item? { filmOfBook[id] }
    public func story(ofFilm id: String) -> MusicBook? { bookOfFilm[id] }
    public var isEmpty: Bool { filmOfBook.isEmpty }

    /// Of a film and its remake, the one the story was made from: the latest before the story
    /// came out, else the first.
    static func choose(_ films: [Item], for book: MusicBook) -> Item? {
        let ordered = films.sorted { ($0.year ?? .max, $0.id) < ($1.year ?? .max, $1.id) }
        if let year = book.year, let before = ordered.last(where: { ($0.year ?? .max) <= year }) {
            return before
        }
        return ordered.first
    }
}
