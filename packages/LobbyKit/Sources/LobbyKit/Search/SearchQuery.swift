// SPDX-License-Identifier: MPL-2.0
import Foundation

/// The filters of the search screen's chips, written in the server's query language
/// (docs/api.md, Search: `actor:"Tom Hanks" year:1990..1999 rt>80`). The chips build exactly
/// what someone could type; the server reads both the same (apps/server `search/syntax.ts`).
public struct SearchFilters: Codable, Hashable, Sendable {
    public enum Role: String, Codable, CaseIterable, Hashable, Sendable {
        case any, cast, director, writer

        var key: String {
            switch self {
            case .any: "person"
            case .cast: "actor"
            case .director: "director"
            case .writer: "writer"
            }
        }

        public var title: String {
            switch self {
            case .any: "Anyone"
            case .cast: "Actor"
            case .director: "Director"
            case .writer: "Writer"
            }
        }
    }

    public struct Person: Codable, Hashable, Sendable {
        public var name: String
        public var role: Role

        public init(name: String, role: Role = .any) {
            self.name = name
            self.role = role
        }
    }

    public struct Rating: Codable, Hashable, Sendable {
        public var source: RatingSource
        /// On the source's own scale.
        public var minimum: Double

        public init(source: RatingSource, minimum: Double) {
            self.source = source
            self.minimum = minimum
        }
    }

    public var yearFrom: Int?
    public var yearTo: Int?
    public var rating: Rating?
    public var people: [Person]
    public var genres: [String]
    public var kind: TitleKind?
    /// Only the exact title, not words in it.
    public var exactTitle: Bool

    public init(
        yearFrom: Int? = nil, yearTo: Int? = nil, rating: Rating? = nil, people: [Person] = [], genres: [String] = [],
        kind: TitleKind? = nil, exactTitle: Bool = false
    ) {
        self.yearFrom = yearFrom
        self.yearTo = yearTo
        self.rating = rating
        self.people = people
        self.genres = genres
        self.kind = kind
        self.exactTitle = exactTitle
    }

    public static let none = SearchFilters()

    public var isEmpty: Bool { self == .none }

    /// How many chips are on.
    public var count: Int {
        (yearFrom != nil || yearTo != nil ? 1 : 0) + (rating == nil ? 0 : 1) + people.count + genres.count
            + (kind == nil ? 0 : 1) + (exactTitle ? 1 : 0)
    }

    /// The filters as query words, in a fixed order.
    public var tokens: [String] {
        var tokens: [String] = []
        if let kind {
            tokens.append("kind:\(kind == .movie ? "film" : kind == .show ? "series" : "video")")
        }
        switch (yearFrom, yearTo) {
        case let (from?, to?): tokens.append(from == to ? "year:\(from)" : "year:\(min(from, to))..\(max(from, to))")
        case let (from?, nil): tokens.append("year>=\(from)")
        case let (nil, to?): tokens.append("year<=\(to)")
        case (nil, nil): break
        }
        if let rating {
            let value = rating.source.scale == 100 ? String(Int(rating.minimum.rounded())) : Self.decimal(rating.minimum)
            tokens.append("\(rating.source.queryKey)>=\(value)")
        }
        for person in people where !person.name.trimmingCharacters(in: .whitespaces).isEmpty {
            tokens.append("\(person.role.key):\(Self.quoted(person.name))")
        }
        for genre in genres { tokens.append("genre:\(Self.quoted(genre))") }
        return tokens
    }

    /// What is sent: what was typed, with the chips' filters after it. With `exactTitle` the
    /// typed words are the title itself.
    public func query(text: String) -> String {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = exactTitle && !typed.isEmpty ? "title=\(Self.quoted(typed))" : typed
        return ([words] + tokens).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Whether anything would be asked.
    public func asksAnything(text: String) -> Bool {
        !query(text: text).isEmpty
    }

    static func quoted(_ value: String) -> String {
        let clean = value.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
        return clean.contains(where: \.isWhitespace) ? "\"\(clean)\"" : clean
    }

    static func decimal(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// The searches a viewer made last, newest first. Kept per viewer on the device.
public struct RecentSearches: Codable, Hashable, Sendable {
    public static let most = 12

    public private(set) var queries: [String]

    public init(queries: [String] = []) {
        self.queries = Array(queries.prefix(Self.most))
    }

    /// Puts a search first; the same one again moves up, whatever its case.
    public mutating func add(_ query: String) {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2 else { return }
        queries.removeAll { $0.compare(clean, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        queries.insert(clean, at: 0)
        if queries.count > Self.most { queries.removeLast(queries.count - Self.most) }
    }

    public mutating func remove(_ query: String) {
        queries.removeAll { $0 == query }
    }

    public mutating func clear() {
        queries = []
    }
}

/// Recent searches per viewer, on this device only: nothing of it goes to the server.
public struct RecentSearchStore: Sendable {
    /// nil: the app's own defaults.
    private let suiteName: String?
    private static let prefix = "lobby.recentSearches."

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// - Parameter viewer: The viewer's profile id; nil before one is chosen.
    public func load(viewer: String?) -> RecentSearches {
        RecentSearches(queries: defaults.stringArray(forKey: Self.prefix + (viewer ?? "-")) ?? [])
    }

    public func save(_ recent: RecentSearches, viewer: String?) {
        let key = Self.prefix + (viewer ?? "-")
        if recent.queries.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(recent.queries, forKey: key) }
    }
}
