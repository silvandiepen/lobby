// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Observation

/// One viewer's statistics (docs/api.md, Statistics): their own, or for an admin any viewer's,
/// a child's too.
@MainActor
@Observable
final class ViewerStatsModel {
    let profileID: String
    var range: StatsRange
    private(set) var stats: ViewerStats?
    private(set) var isLoading = false
    /// The server is from before statistics.
    private(set) var isUnavailable = false
    /// The server would not give them: not this device's to see (docs/decisions.md, "Who sees
    /// which statistics"), or it does not know yet who is in front here.
    private(set) var refusal: String?
    var problem: String?
    private let app: AppModel
    private let timeZone: TimeZone

    init(app: AppModel, profileID: String, range: StatsRange = .month, timeZone: TimeZone = .current) {
        self.app = app
        self.profileID = profileID
        self.range = range
        self.timeZone = timeZone
    }

    var profile: Profile? { app.profiles.first { $0.id == profileID } }

    /// The viewer this device watches as: their page says "Your".
    var isOwn: Bool { app.activeProfile?.id == profileID }

    var headline: String { StatsSummary.headline(range, name: isOwn ? nil : (stats?.viewer.name ?? profile?.name)) }

    var cards: [StatsCard] { stats.map(StatsSummary.cards) ?? [] }

    var bars: [StatsBar] {
        guard let stats else { return [] }
        return StatsSummary.bars(days: stats.days, months: stats.months, range: stats.range)
    }

    var heat: [StatsHeatCell] { stats.map { StatsSummary.heatCells($0.heatmap) } ?? [] }

    /// Nothing watched or listened to in this range.
    var isEmpty: Bool { (stats?.totals.watchedMs ?? 0) == 0 && (stats?.totals.listenedMs ?? 0) == 0 }

    /// A grown-up's view of a child: screen time and when.
    var isKid: Bool { stats?.viewer.kids ?? (profile?.kids != nil) }

    /// Forgetting everything is for whoever manages the household; not in kids mode.
    var canForget: Bool { app.statsAccess.mayForget }

    /// Taking one sitting out of the history: whoever may see it.
    var canRemove: Bool { stats != nil && app.statsAccess.mayRemove(viewerID: profileID, kids: isKid) }

    /// The titles the page takes its colours from: the most watched.
    var artworks: [Artwork] {
        (stats?.topTitles ?? []).lazy.compactMap { [app] in
            app.item($0.itemId).flatMap { $0.artwork.backdrop ?? $0.artwork.poster }
        }.prefix(ArtworkPalette.limit).map { $0 }
    }

    /// The evening and weekend part of a child's watching, in words.
    var whenSummary: String? {
        guard let when = stats?.when else { return nil }
        let timed = when.weekdays + when.weekends
        guard timed > 0 else { return nil }
        let evenings = StatsSummary.share(when.evenings + when.nights, of: timed) ?? "0%"
        let weekends = StatsSummary.share(when.weekends, of: timed) ?? "0%"
        return "\(evenings) in the evening or later, \(weekends) at the weekend."
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let range = range
        let profileID = profileID
        let timeZone = timeZone
        // A viewer's own are theirs while they are in front: the server is told first.
        if app.statsAccess.level == .viewer { await app.remote.sayWhoIsWatching() }
        do {
            stats = try await app.asViewer { try await $0.viewerStats(profileID: profileID, range: range, timeZone: timeZone) }
            isUnavailable = false
            refusal = nil
        } catch LobbyError.notFound {
            isUnavailable = true
            stats = nil
        } catch LobbyError.forbidden(let message) {
            refusal = message
            stats = nil
        } catch {
            problem = await app.managerProblem(error)
        }
    }

    func select(_ range: StatsRange) async {
        guard range != self.range else { return }
        self.range = range
        await load()
    }

    /// Takes one sitting out of the history; it goes from the page at once.
    func remove(_ sitting: StatsSitting) async {
        guard canRemove else { return }
        let before = stats
        stats?.history?.removeAll { $0.id == sitting.id }
        let profileID = profileID
        do {
            try await app.asViewer { try await $0.removeFromHistory(profileID: profileID, sittingID: sitting.id) }
            await load()
        } catch {
            stats = before
            problem = await app.managerProblem(error)
        }
    }

    /// Forgets everything this viewer watched and listened to.
    func forget() async {
        guard canForget else { return }
        let profileID = profileID
        do {
            try await app.asManager { try await $0.forgetHistory(profileID: profileID) }
            await load()
        } catch {
            problem = await app.managerProblem(error)
        }
    }
}

/// The server's statistics, for a server admin, with other households as totals unless one is
/// opened; or a household's overview, for its admins.
@MainActor
@Observable
final class ServerStatsModel {
    enum Scope: Equatable {
        /// `GET /v1/stats/server`.
        case server
        /// `GET /v1/stats/household`: the device's own household, without the server's parts.
        case household
    }

    let scope: Scope
    var range: StatsRange
    /// The guest household opened; nil: the owner's.
    private(set) var householdID: String?
    private(set) var stats: ServerStats?
    private(set) var isLoading = false
    private(set) var isUnavailable = false
    var problem: String?
    private let app: AppModel
    private let timeZone: TimeZone

    init(app: AppModel, scope: Scope = .server, range: StatsRange = .month, timeZone: TimeZone = .current) {
        self.app = app
        self.scope = scope
        self.range = range
        self.timeZone = timeZone
    }

    /// Whether this device may open the page at all.
    var isOffered: Bool {
        switch scope {
        case .server: app.statsAccess.showsServerPage
        case .household: app.statsAccess.showsHouseholdOverview
        }
    }

    /// Whether a viewer in the list opens their page here.
    func opens(_ viewer: ServerStatsViewer) -> Bool {
        app.statsAccess.mayOpen(viewerID: viewer.id, kids: viewer.kids, householdID: householdID ?? stats?.household?.id)
    }

    var cards: [StatsCard] { stats.map(StatsSummary.cards) ?? [] }

    var bars: [StatsBar] {
        guard let stats else { return [] }
        return stats.days.compactMap { day in
            StatsSummary.date(day: day.day, timeZone: stats.range.timeZone).map {
                StatsBar(id: day.day, date: $0, watchedHours: Double(day.watchedMs) / 3_600_000, listenedHours: 0)
            }
        }
    }

    var heat: [StatsHeatCell] { stats.map { StatsSummary.heatCells($0.heatmap) } ?? [] }

    /// How full the cache for playback is, from 0 to 1.
    var cacheFill: Double? {
        guard let used = stats?.storage?.playbackCacheBytes, let most = stats?.storage?.playbackCacheMaxBytes, most > 0 else { return nil }
        return min(1, Double(used) / Double(most))
    }

    var artworks: [Artwork] {
        (stats?.topTitles ?? []).lazy.compactMap { [app] in
            app.item($0.itemId).flatMap { $0.artwork.backdrop ?? $0.artwork.poster }
        }.prefix(ArtworkPalette.limit).map { $0 }
    }

    func load() async {
        guard isOffered else { return }
        isLoading = true
        defer { isLoading = false }
        let range = range
        let household = householdID
        let timeZone = timeZone
        let scope = scope
        do {
            stats = try await app.asManager {
                switch scope {
                case .server: try await $0.serverStats(range: range, timeZone: timeZone, householdID: household)
                case .household: try await $0.householdStats(range: range, timeZone: timeZone)
                }
            }
            isUnavailable = false
        } catch LobbyError.notFound {
            isUnavailable = true
        } catch {
            problem = await app.managerProblem(error)
        }
    }

    func select(_ range: StatsRange) async {
        guard range != self.range else { return }
        self.range = range
        await load()
    }

    /// Opens a guest household, or goes back to the owner's with nil.
    func open(household id: String?) async {
        householdID = id == HouseholdSummary.ownerID ? nil : id
        await load()
    }
}
