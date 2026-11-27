// SPDX-License-Identifier: MPL-2.0
import Foundation

// What `GET /v1/search…` answers (docs/api.md, Search). Library results can be played; what is
// "Not in your library" comes from TMDB and only links out.

/// Where a rating comes from. TMDB's is always there; the others only when the server's owner set
/// an OMDb key.
public enum RatingSource: String, Codable, CaseIterable, Hashable, Sendable {
    case tmdb, imdb, rottenTomatoes, metacritic

    /// The highest score: TMDB and IMDb out of 10, the others out of 100.
    public var scale: Double {
        switch self {
        case .tmdb, .imdb: 10
        case .rottenTomatoes, .metacritic: 100
        }
    }

    public var name: String {
        switch self {
        case .tmdb: "TMDB"
        case .imdb: "IMDb"
        case .rottenTomatoes: "Rotten Tomatoes"
        case .metacritic: "Metacritic"
        }
    }

    /// How the query language names it.
    public var queryKey: String {
        switch self {
        case .tmdb: "tmdb"
        case .imdb: "imdb"
        case .rottenTomatoes: "rt"
        case .metacritic: "metacritic"
        }
    }

    /// "8.1", "87%".
    public func text(_ value: Double) -> String {
        scale == 100 ? "\(Int(value.rounded()))%" : String(format: "%.1f", value)
    }
}

/// Every rating a title has, each on its own scale.
public struct Ratings: Codable, Hashable, Sendable {
    public var tmdb: Double?
    public var imdb: Double?
    public var rottenTomatoes: Double?
    public var metacritic: Double?

    public init(tmdb: Double? = nil, imdb: Double? = nil, rottenTomatoes: Double? = nil, metacritic: Double? = nil) {
        self.tmdb = tmdb
        self.imdb = imdb
        self.rottenTomatoes = rottenTomatoes
        self.metacritic = metacritic
    }

    public subscript(source: RatingSource) -> Double? {
        switch source {
        case .tmdb: tmdb
        case .imdb: imdb
        case .rottenTomatoes: rottenTomatoes
        case .metacritic: metacritic
        }
    }

    /// The ones there are, in the order of `RatingSource`.
    public var known: [(source: RatingSource, value: Double)] {
        RatingSource.allCases.compactMap { source in self[source].map { (source, $0) } }
    }
}

public enum SearchMatchField: OpenStringEnum {
    case title, alias, person, character, collection, studio, genre, overview
    case unknown(String)

    public static let knownCases: [SearchMatchField] = [.title, .alias, .person, .character, .collection, .studio, .genre, .overview]

    public var rawValue: String {
        switch self {
        case .title: "title"
        case .alias: "alias"
        case .person: "person"
        case .character: "character"
        case .collection: "collection"
        case .studio: "studio"
        case .genre: "genre"
        case .overview: "overview"
        case .unknown(let raw): raw
        }
    }
}

/// Why a title is in the results.
public struct SearchMatch: Codable, Hashable, Sendable {
    public var field: SearchMatchField
    public var text: String?

    public init(field: SearchMatchField, text: String? = nil) {
        self.field = field
        self.text = text
    }

    /// "With Tom Hanks", "As Woody"; nil for the title itself.
    public var reason: String? {
        switch field {
        case .person: text.map { "With \($0)" }
        case .character: text.map { "As \($0)" }
        case .alias: text.map { "Also “\($0)”" }
        case .collection: text
        case .studio: text.map { "By \($0)" }
        case .genre: text
        case .overview: "In the summary"
        case .title, .unknown: nil
        }
    }
}

public struct SearchTitle: Codable, Hashable, Sendable, Identifiable {
    public var item: Item
    public var ratings: Ratings
    public var match: SearchMatch?
    public var id: String { item.id }
}

public struct SearchEpisode: Codable, Hashable, Sendable, Identifiable {
    public var item: Item
    public var showId: String?
    public var match: SearchMatch?
    public var id: String { item.id }
}

public enum CreditRole: OpenStringEnum {
    case cast, director, writer, creator
    case unknown(String)

    public static let knownCases: [CreditRole] = [.cast, .director, .writer, .creator]

    public var rawValue: String {
        switch self {
        case .cast: "cast"
        case .director: "director"
        case .writer: "writer"
        case .creator: "creator"
        case .unknown(let raw): raw
        }
    }

    public var title: String {
        switch self {
        case .cast: "Actor"
        case .director: "Director"
        case .writer: "Writer"
        case .creator: "Creator"
        case .unknown(let raw): raw.capitalized
        }
    }
}

public struct SearchPerson: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    /// For `searchPictureURL(path:)`.
    public var picture: String?
    public var titles: Int
    public var roles: [CreditRole]
}

public struct SearchCollection: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var itemIds: [String]
}

public struct SearchGroup<Element: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var total: Int
    public var items: [Element]

    public init(total: Int = 0, items: [Element] = []) {
        self.total = total
        self.items = items
    }
}

/// A filter the server understood in the query, to show as a chip.
public struct UnderstoodFilter: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var label: String
    /// How it is written in the query, to take it out again.
    public var token: String
    public var id: String { token }

    public init(key: String, label: String, token: String) {
        self.key = key
        self.label = label
        self.token = token
    }
}

/// `GET /v1/search`: the library.
public struct SearchAnswer: Codable, Hashable, Sendable {
    public var query: String
    public var text: String
    public var understood: [UnderstoodFilter]
    public var unknownPeople: [String]
    /// The sources this server has ratings from, as it names them.
    public var ratingSources: [String]
    public var films: SearchGroup<SearchTitle>
    public var series: SearchGroup<SearchTitle>
    public var videos: SearchGroup<SearchTitle>
    public var episodes: SearchGroup<SearchEpisode>
    public var people: SearchGroup<SearchPerson>
    public var collections: SearchGroup<SearchCollection>

    /// The sources this build knows of those.
    public var sources: [RatingSource] { ratingSources.compactMap(RatingSource.init(rawValue:)) }

    public var isEmpty: Bool {
        films.items.isEmpty && series.items.isEmpty && videos.items.isEmpty && episodes.items.isEmpty
            && people.items.isEmpty && collections.items.isEmpty
    }
}

public struct ExternalLinks: Codable, Hashable, Sendable {
    public var tmdb: URL
    public var imdb: URL?
}

/// A film or show at TMDB that is not in the library. It cannot be played.
public struct OutsideTitle: Codable, Hashable, Sendable, Identifiable {
    public var tmdb: TMDBReference
    public var title: String
    public var originalTitle: String
    public var year: Int?
    public var overview: String?
    public var poster: String?
    public var ratings: Ratings
    public var votes: Int
    public var imdbId: String?
    public var links: ExternalLinks
    /// Set when it is in the library after all.
    public var itemId: String?
    /// On a person's page: what they did in it.
    public var roles: [String]?

    public var id: String { "\(tmdb.type.rawValue):\(tmdb.id)" }
}

public struct OutsidePerson: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var knownFor: String?
    public var knownForTitles: [String]
    public var picture: String?
    public var links: ExternalLinks
}

/// Why there is nothing from outside.
public enum OutsideReason: OpenStringEnum {
    case noKey, unavailable, rateLimited
    case unknown(String)

    public static let knownCases: [OutsideReason] = [.noKey, .unavailable, .rateLimited]

    public var rawValue: String {
        switch self {
        case .noKey: "no_key"
        case .unavailable: "unavailable"
        case .rateLimited: "rate_limited"
        case .unknown(let raw): raw
        }
    }

    public var message: String {
        switch self {
        case .noKey: "Lobby Server has no TMDB key, so it cannot look beyond the library."
        case .unavailable: "TMDB cannot be reached right now."
        case .rateLimited: "That was a lot at once. Try again in a moment."
        case .unknown: "Nothing could be found beyond the library."
        }
    }
}

/// `GET /v1/search/outside`: TMDB, beyond the library.
public struct OutsideAnswer: Codable, Hashable, Sendable {
    public var available: Bool
    public var reason: OutsideReason?
    public var films: [OutsideTitle]
    public var series: [OutsideTitle]
    public var people: [OutsidePerson]
    /// Filters that could not be applied out there, by source name.
    public var notApplied: [String]
    public var attribution: [String]

    public var isEmpty: Bool { films.isEmpty && series.isEmpty && people.isEmpty }
}

/// `GET /v1/search/outside/{type}/{id}`.
public struct OutsideTitleDetail: Codable, Hashable, Sendable {
    public struct Person: Codable, Hashable, Sendable, Identifiable {
        public var id: Int
        public var name: String
        public var role: CreditRole
        public var character: String?
        public var picture: String?
    }

    public var tmdb: TMDBReference
    public var title: String
    public var year: Int?
    public var overview: String?
    public var poster: String?
    public var ratings: Ratings
    public var imdbId: String?
    public var links: ExternalLinks
    public var itemId: String?
    public var genres: [String]
    public var runtimeMinutes: Int?
    public var people: [Person]
    public var attribution: [String]
}

/// `GET /v1/search/people/{id}`: a person, their titles here first, then the others.
public struct PersonPage: Codable, Hashable, Sendable {
    public struct Person: Codable, Hashable, Sendable {
        public var id: Int
        public var name: String
        public var picture: String?
    }

    public struct Role: Codable, Hashable, Sendable {
        public var role: CreditRole
        public var character: String?
    }

    public struct LibraryTitle: Codable, Hashable, Sendable, Identifiable {
        public var item: Item
        public var ratings: Ratings
        public var roles: [Role]
        public var id: String { item.id }
    }

    public struct Outside: Codable, Hashable, Sendable {
        public var id: Int
        public var name: String
        public var biography: String?
        public var birthday: String?
        public var deathday: String?
        public var knownFor: String?
        public var picture: String?
        public var links: ExternalLinks
        public var elsewhere: [OutsideTitle]
    }

    public var person: Person
    public var titles: [LibraryTitle]
    public var outside: Outside?
    public var outsideReason: OutsideReason?
}
