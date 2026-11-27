// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum ItemKind: OpenStringEnum {
    case movie, show, season, episode, extra, personal
    case unknown(String)

    public static let knownCases: [ItemKind] = [.movie, .show, .season, .episode, .extra, .personal]

    public var rawValue: String {
        switch self {
        case .movie: "movie"
        case .show: "show"
        case .season: "season"
        case .episode: "episode"
        case .extra: "extra"
        case .personal: "personal"
        case .unknown(let raw): raw
        }
    }
}

public enum MatchStatus: OpenStringEnum {
    case unmatched, matched, needsReview, locked, personal
    case unknown(String)

    public static let knownCases: [MatchStatus] = [.unmatched, .matched, .needsReview, .locked, .personal]

    public var rawValue: String {
        switch self {
        case .unmatched: "unmatched"
        case .matched: "matched"
        case .needsReview: "needs_review"
        case .locked: "locked"
        case .personal: "personal"
        case .unknown(let raw): raw
        }
    }
}

public enum ExtraKind: OpenStringEnum {
    case trailer, featurette, sample
    case unknown(String)

    public static let knownCases: [ExtraKind] = [.trailer, .featurette, .sample]

    public var rawValue: String {
        switch self {
        case .trailer: "trailer"
        case .featurette: "featurette"
        case .sample: "sample"
        case .unknown(let raw): raw
        }
    }
}

public enum TMDBKind: OpenStringEnum {
    case movie, tv
    case unknown(String)

    public static let knownCases: [TMDBKind] = [.movie, .tv]

    public var rawValue: String {
        switch self {
        case .movie: "movie"
        case .tv: "tv"
        case .unknown(let raw): raw
        }
    }
}

public enum TrailerProvider: OpenStringEnum {
    case youtube
    case unknown(String)

    public static let knownCases: [TrailerProvider] = [.youtube]

    public var rawValue: String {
        switch self {
        case .youtube: "youtube"
        case .unknown(let raw): raw
        }
    }
}

public struct TMDBReference: Codable, Hashable, Sendable {
    public var type: TMDBKind
    public var id: Int

    public init(type: TMDBKind, id: Int) {
        self.type = type
        self.id = id
    }
}

/// An online trailer. Local trailers are child items of kind `.extra`.
public struct OnlineTrailer: Codable, Hashable, Sendable {
    public var provider: TrailerProvider
    public var key: String

    public init(provider: TrailerProvider, key: String) {
        self.provider = provider
        self.key = key
    }
}

public struct Artwork: Codable, Hashable, Sendable, Identifiable {
    /// Never changes its picture, so anything fetched for it can be cached forever.
    public var id: String
    public var width: Int?
    public var height: Int?

    public init(id: String, width: Int? = nil, height: Int? = nil) {
        self.id = id
        self.width = width
        self.height = height
    }
}

public struct ArtworkSet: Codable, Hashable, Sendable {
    public var poster: Artwork?
    public var backdrop: Artwork?
    public var still: Artwork?
    /// The title as a drawn word mark, with transparency. nil: write the title.
    public var logo: Artwork?

    public init(poster: Artwork? = nil, backdrop: Artwork? = nil, still: Artwork? = nil, logo: Artwork? = nil) {
        self.poster = poster
        self.backdrop = backdrop
        self.still = still
        self.logo = logo
    }
}

/// A company that made a title, or a network that showed it, as TMDB names it.
public struct ItemStudio: Codable, Hashable, Sendable, Identifiable {
    /// "company:3", "network:49".
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct Item: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: ItemKind
    /// A season's show, an episode's season, an extra's film or show.
    public var parentId: String?
    public var title: String
    public var sortTitle: String
    public var year: Int?
    /// 0 is Specials. nil on an episode means its number is unknown.
    public var seasonNumber: Int?
    public var episodeNumber: Int?
    public var overview: String?
    /// A date without a time, `YYYY-MM-DD`.
    public var airDate: String?
    public var runtimeMs: Int?
    public var genres: [String]
    /// The names of the household's categories it is in.
    public var categories: [String]
    /// The same by id. nil when it was fetched before categories had ids. Only its own
    /// categories: never the one they are inside of (`LibraryCategory.parentId`).
    public var categoryIds: [String]?
    /// Of a film or show: the categories that take it in because they follow its studios. It is
    /// on their pages too, but for the part of the library it is in only `categoryIds` count.
    /// nil from an older server.
    public var ruleCategoryIds: [String]?
    /// Of a film or show: who made or showed it, the most important first. nil from an older
    /// server, or a copy fetched before it said so.
    public var studios: [ItemStudio]?
    public var matchStatus: MatchStatus
    public var imdbId: String?
    public var tmdb: TMDBReference?
    /// For kind `.extra`.
    public var extraKind: ExtraKind?
    public var trailer: OnlineTrailer?
    public var artwork: ArtworkSet
    /// One line about a film or show.
    public var tagline: String?
    /// How well known it is, 0 to 1. Fame, not quality, and not this household's. nil when
    /// nobody rated it, or from an older server.
    public var renown: Double?
    /// TMDB's average rating, 0 to 10. nil when too few rated it, or from an older server.
    public var rating: Double?
    /// Titles that belong with this one, the closest first: its film series, then what is like
    /// it. From a newer server; nil until then, and the apps work it out themselves.
    public var related: [String]?
    /// When Lobby first saw it. For a season or show: when its newest episode arrived.
    public var addedAt: Date
    /// For a season or show: when its newest episode arrived, if that was a day or more after
    /// the first. nil otherwise, or from an older server.
    public var newEpisodesAt: Date?
    /// For a season or show: the latest air date of the episodes that are here.
    public var latestAirDate: String?
    /// False when none of its files (or its children's files) can be reached right now.
    public var available: Bool
    /// Empty for shows and seasons.
    public var files: [MediaFile]

    public init(
        id: String, kind: ItemKind, parentId: String? = nil, title: String, sortTitle: String? = nil,
        year: Int? = nil, seasonNumber: Int? = nil, episodeNumber: Int? = nil, overview: String? = nil,
        airDate: String? = nil, runtimeMs: Int? = nil, genres: [String] = [], categories: [String] = [],
        categoryIds: [String]? = nil, ruleCategoryIds: [String]? = nil, studios: [ItemStudio]? = nil,
        matchStatus: MatchStatus = .matched, imdbId: String? = nil, tmdb: TMDBReference? = nil,
        extraKind: ExtraKind? = nil, trailer: OnlineTrailer? = nil, artwork: ArtworkSet = ArtworkSet(),
        tagline: String? = nil, renown: Double? = nil, rating: Double? = nil, related: [String]? = nil, addedAt: Date, newEpisodesAt: Date? = nil,
        latestAirDate: String? = nil, available: Bool = true, files: [MediaFile] = []
    ) {
        self.id = id
        self.kind = kind
        self.parentId = parentId
        self.title = title
        self.sortTitle = sortTitle ?? title
        self.year = year
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.overview = overview
        self.airDate = airDate
        self.runtimeMs = runtimeMs
        self.genres = genres
        self.categories = categories
        self.categoryIds = categoryIds
        self.ruleCategoryIds = ruleCategoryIds
        self.studios = studios
        self.matchStatus = matchStatus
        self.imdbId = imdbId
        self.tmdb = tmdb
        self.extraKind = extraKind
        self.trailer = trailer
        self.artwork = artwork
        self.tagline = tagline
        self.renown = renown
        self.rating = rating
        self.related = related
        self.addedAt = addedAt
        self.newEpisodesAt = newEpisodesAt
        self.latestAirDate = latestAirDate
        self.available = available
        self.files = files
    }

    /// The files that are the film or episode itself (not trailers or extras), parts in order.
    public var mainFiles: [MediaFile] {
        files.filter { $0.role == .main }.sorted { ($0.part ?? 0) < ($1.part ?? 0) }
    }
}

/// `GET /v1/items/{id}`. Children of a show are its seasons and extras, of a season its episodes,
/// of a film its extras.
public struct ItemDetail: Codable, Hashable, Sendable {
    public var item: Item
    public var children: [Item]
}

/// One page of `GET /v1/library`.
public struct LibraryPage: Codable, Hashable, Sendable {
    public var items: [Item]
    /// Items that no longer exist. Drop them, and their children.
    public var removed: [String]
    public var cursor: String
    /// Keep calling with `cursor` while this is true.
    public var more: Bool
    /// The server could not continue from the cursor sent: this response starts a full fetch.
    public var reset: Bool

    public init(items: [Item], removed: [String] = [], cursor: String, more: Bool = false, reset: Bool = false) {
        self.items = items
        self.removed = removed
        self.cursor = cursor
        self.more = more
        self.reset = reset
    }
}
