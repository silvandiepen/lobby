// SPDX-License-Identifier: MPL-2.0
import Foundation

// What is watched, when and by whom (`/v1/stats…`), as `docs/api.md` ("Statistics") describes
// it. Amounts of time are milliseconds, amounts of data bytes.

/// The stretch of time a statistics page covers. Each ends today.
public enum StatsRange: String, Codable, CaseIterable, Hashable, Sendable {
    case week, month, year, all
}

/// The range a page covers, in the viewer's time zone.
public struct StatsPeriod: Codable, Hashable, Sendable {
    public var name: StatsRange
    public var timeZone: String
    /// `yyyy-MM-dd`, both included.
    public var firstDay: String
    public var lastDay: String
    public var from: Date
    public var to: Date
}

/// Time spent on one day.
public struct StatsDay: Codable, Hashable, Sendable, Identifiable {
    /// `yyyy-MM-dd` in the page's time zone.
    public var day: String
    public var watchedMs: Int
    /// Not on the server's page: nil there.
    public var listenedMs: Int?
    /// The server's page: sittings begun that day, and how many viewers began one.
    public var sessions: Int?
    public var viewers: Int?
    public var id: String { day }

    public init(day: String, watchedMs: Int, listenedMs: Int? = nil, sessions: Int? = nil, viewers: Int? = nil) {
        self.day = day
        self.watchedMs = watchedMs
        self.listenedMs = listenedMs
        self.sessions = sessions
        self.viewers = viewers
    }
}

public struct StatsMonth: Codable, Hashable, Sendable, Identifiable {
    /// `yyyy-MM`.
    public var month: String
    public var watchedMs: Int
    public var listenedMs: Int
    public var id: String { month }
}

/// When in the day and the week.
public struct StatsWhen: Codable, Hashable, Sendable {
    public var mornings: Int
    public var afternoons: Int
    public var evenings: Int
    public var nights: Int
    public var weekdays: Int
    public var weekends: Int
}

public struct StatsTitle: Codable, Hashable, Sendable, Identifiable {
    public var itemId: String
    public var title: String
    public var kind: ItemKind?
    public var watchedMs: Int
    public var sessions: Int
    public var lastAt: Date?
    /// The server's page: how many viewers watched it.
    public var viewers: Int?
    public var id: String { itemId }
}

public struct StatsSeries: Codable, Hashable, Sendable, Identifiable {
    public var itemId: String
    public var title: String
    public var episodesWatched: Int
    public var episodes: Int
    public var lastEpisodeId: String
    /// "S1 E2", or the episode's title.
    public var lastEpisode: String?
    public var lastAt: Date
    public var id: String { itemId }
}

/// A genre, studio or category, and the time spent on its titles.
public struct StatsShare: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var watchedMs: Int
}

public struct StatsStreak: Codable, Hashable, Sendable {
    public var current: Int
    public var longest: Int
}

public struct StatsAlbum: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var artist: String
    public var coverId: String?
    public var listenedMs: Int
    public var plays: Int
}

public struct StatsArtist: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var listenedMs: Int
    public var id: String { name }
}

public struct StatsMusic: Codable, Hashable, Sendable {
    public var listenedMs: Int
    public var plays: Int
    public var topAlbums: [StatsAlbum]
    public var topArtists: [StatsArtist]
}

public struct StatsDevice: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var platform: String?
    public var watchedMs: Int
    public var sessions: Int?
}

/// One sitting with a film or an episode.
public struct StatsSitting: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var itemId: String
    public var titleId: String
    /// The film, or the series.
    public var title: String
    /// For an episode "S1 E2 · Its title"; for a film its year.
    public var subtitle: String?
    public var startedAt: Date
    public var endedAt: Date
    /// False for what is known from before: only its day.
    public var timed: Bool
    public var watchedMs: Int
    public var completed: Bool
    public var device: String?
    /// `home`, `tailnet`, `relay`, `direct` or `unknown`.
    public var road: String
    /// `direct`, `prepared`, `download` or `unknown`.
    public var delivery: String
    public var playOnFrom: String?
}

public struct StatsViewer: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var color: String
    public var avatar: String?
    public var kids: Bool
}

public struct ViewerStatsTotals: Codable, Hashable, Sendable {
    public var watchedMs: Int
    public var sessions: Int
    public var titles: Int
    public var filmsFinished: Int
    public var episodesFinished: Int
    public var listenedMs: Int
    public var tracksPlayed: Int
    public var activeDays: Int
}

/// `GET /v1/stats/viewers/{id}`: one viewer's page.
public struct ViewerStats: Codable, Hashable, Sendable {
    public var viewer: StatsViewer
    public var keptDays: Int
    /// A child's own device: no history, devices or roads.
    public var simple: Bool
    public var range: StatsPeriod
    public var totals: ViewerStatsTotals
    public var days: [StatsDay]
    public var months: [StatsMonth]
    /// Seven rows, Monday first, of 24 hours.
    public var heatmap: [[Int]]
    public var when: StatsWhen
    public var topTitles: [StatsTitle]
    public var series: [StatsSeries]
    public var genres: [StatsShare]
    public var studios: [StatsShare]
    public var categories: [StatsShare]
    public var streak: StatsStreak
    public var music: StatsMusic
    public var playOnSessions: Int?
    public var roads: [String: Int]?
    public var deliveries: [String: Int]?
    public var devices: [StatsDevice]?
    public var history: [StatsSitting]?
}

public struct ServerStatsTotals: Codable, Hashable, Sendable {
    public var watchedMs: Int
    public var sessions: Int
    public var viewers: Int
    public var devices: Int
    public var listenedMs: Int
    public var tracksPlayed: Int
}

public struct ServerStatsViewer: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var color: String?
    public var avatar: String?
    public var kids: Bool
    public var watchedMs: Int
    public var sessions: Int
    public var lastAt: Date
}

public struct ServerStatsHousehold: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var owner: Bool
    public var watchedMs: Int
    public var sessions: Int
    public var viewers: Int
    public var devices: Int
    public var bytesSent: Int
}

public struct StatsTrafficDay: Codable, Hashable, Sendable, Identifiable {
    public var day: String
    public var homeBytes: Int
    public var awayBytes: Int
    public var id: String { day }
}

public struct StatsTraffic: Codable, Hashable, Sendable {
    public var homeBytes: Int
    public var awayBytes: Int
    public var byRoad: [String: Int]
    public var days: [StatsTrafficDay]
}

public struct StatsPreparations: Codable, Hashable, Sendable {
    public var count: Int
    public var converted: Int
    public var ahead: Int
    public var timeMs: Int
    public var bytes: Int
}

public struct StatsConversions: Codable, Hashable, Sendable {
    public var done: Int
    public var failed: Int
    public var waiting: Int
    public var timeMs: Int
    public var savedBytes: Int
    public var savedInAllBytes: Int
}

public struct StatsLibraryMonth: Codable, Hashable, Sendable, Identifiable {
    public var month: String
    public var films: Int
    public var episodes: Int
    public var id: String { month }
}

public struct StatsLibrary: Codable, Hashable, Sendable {
    public var films: Int
    public var shows: Int
    public var episodes: Int
    public var months: [StatsLibraryMonth]
}

public struct StatsPlayOnTarget: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var sessions: Int
}

public struct StatsPlayOn: Codable, Hashable, Sendable {
    public var sessions: Int
    public var watchedMs: Int
    public var targets: [StatsPlayOnTarget]
}

/// How full the caches and the drive are. What the server cannot tell is nil.
public struct StatsStorage: Codable, Hashable, Sendable {
    public var playbackCacheBytes: Int?
    public var playbackCacheMaxBytes: Int?
    public var musicCacheBytes: Int?
    public var musicCacheMaxBytes: Int?
    public var databaseBytes: Int?
    public var dataFreeBytes: Int?
    public var dataTotalBytes: Int?
}

/// `GET /v1/stats/server`: the server's page, for its admins.
public struct ServerStats: Codable, Hashable, Sendable {
    public var keptDays: Int
    public var range: StatsPeriod
    /// The household the admin opened; nil: the owner's.
    public var household: HouseholdName?
    public var totals: ServerStatsTotals
    public var days: [StatsDay]
    public var heatmap: [[Int]]
    public var hours: [Int]
    public var topTitles: [StatsTitle]
    public var viewers: [ServerStatsViewer]
    public var devices: [StatsDevice]
    public var households: [ServerStatsHousehold]
    public var roads: [String: Int]
    public var deliveries: [String: Int]
    public var traffic: StatsTraffic
    public var preparations: StatsPreparations
    public var conversions: StatsConversions
    public var library: StatsLibrary
    public var playOn: StatsPlayOn
    public var storage: StatsStorage

    public struct HouseholdName: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
    }
}

extension LobbyClient {
    /// `GET /v1/stats/viewers/{id}`. Any device of the viewer's household; a child's device only
    /// for its own child.
    public func viewerStats(profileID: String, range: StatsRange, timeZone: TimeZone = .current) async throws -> ViewerStats {
        try await get(
            ["stats", "viewers", profileID],
            query: [URLQueryItem(name: "range", value: range.rawValue), URLQueryItem(name: "tz", value: timeZone.identifier)])
    }

    /// `DELETE /v1/stats/viewers/{id}/history/{session}`: one sitting out of the history.
    public func removeFromHistory(profileID: String, sittingID: String) async throws {
        try await sendDiscardingAnswer("DELETE", ["stats", "viewers", profileID, "history", sittingID])
    }

    /// `DELETE /v1/stats/viewers/{id}`. Household admin: everything the viewer watched and
    /// listened to. Their places in titles stay.
    public func forgetHistory(profileID: String) async throws {
        try await sendDiscardingAnswer("DELETE", ["stats", "viewers", profileID])
    }

    /// `GET /v1/stats/server`. Server admin, at home.
    ///
    /// - Parameter householdID: Opens a guest household: its viewers and devices in place of
    ///   the owner's.
    public func serverStats(range: StatsRange, timeZone: TimeZone = .current, householdID: String? = nil) async throws -> ServerStats {
        var query = [URLQueryItem(name: "range", value: range.rawValue), URLQueryItem(name: "tz", value: timeZone.identifier)]
        if let householdID { query.append(URLQueryItem(name: "household", value: householdID)) }
        return try await get(["stats", "server"], query: query)
    }
}
