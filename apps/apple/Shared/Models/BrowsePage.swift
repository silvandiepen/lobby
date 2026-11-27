// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// What a page of the library is about.
enum BrowseScope: Hashable, Sendable {
    case home
    case movies
    case series
    /// `CategoryShelf.id`.
    case category(String)
    /// `LibraryGroup.id`.
    case group(String)
}

/// One picture of a banner: a title that can be played now.
struct BannerSlide: Hashable, Sendable, Identifiable {
    /// The film or series.
    var item: Item
    /// The category or part of the library the banner is of. nil on Home.
    var place: String?
    /// Why it is here: "Latest added".
    var kicker: String
    /// "2016", "1 h 42 min", "Adventure".
    var meta: [String]
    /// One line about it.
    var line: String?
    /// What Play starts: the film, or the episode the viewer is at.
    var request: PlayRequest
    /// "Play", "Resume", "Resume S1 E2".
    var playLabel: String
    /// 0…1 of the film or episode, when part-watched.
    var fraction: Double?
    var backdrop: Artwork

    var id: String { item.id }
    var logo: Artwork? { item.artwork.logo }
}

/// A row of a page.
struct BrowseRow: Hashable, Sendable, Identifiable {
    enum Content: Hashable, Sendable {
        case continuing([ContinueCard])
        case recent([RecentCard])
        case items([Item])
        case categories([CategoryShelf])

        var count: Int {
            switch self {
            case .continuing(let cards): cards.count
            case .recent(let cards): cards.count
            case .items(let items): items.count
            case .categories(let shelves): shelves.count
            }
        }
    }

    /// "continue", "popular", "genre:Adventure". Stable, for focus and tests.
    var id: String
    var title: String
    /// A quiet word about how the row is made.
    var note: String?
    var content: Content
    var seeAll: Route?
    /// The part of the library whose logo stands for the title.
    var groupID: String?
    /// The category whose logo stands for the title.
    var categoryID: String?

    /// The films and series in it, in order.
    var titleIDs: [String] {
        switch content {
        case .continuing(let cards): cards.map(\.id)
        case .recent(let cards): cards.map(\.titleID)
        case .items(let items): items.map(\.id)
        case .categories: []
        }
    }
}

/// A page of the library: its banner, its rows, and what it lists in full below them.
struct BrowsePage: Hashable, Sendable {
    var banner: [BannerSlide] = []
    var rows: [BrowseRow] = []
    /// Everything on the page, by title: the grid at its end. Empty on Home.
    var all: [Item] = []
    /// The categories inside the page's category, for the chips under its banner. Empty for
    /// any other page.
    var sections: [CategoryShelf] = []

    static let empty = BrowsePage()
}

/// Makes the pages from the device's copy of the catalogue. Pure: with the server out of reach
/// the same code makes the same pages of what is on the device.
struct BrowseBuilder: Sendable {
    static let bannerLimit = 4
    static let bannerWidth = 1280
    /// A row with less says nothing.
    static let least = 3
    static let rowLimit = 20
    /// New episodes are news for so long.
    static let newsDays: TimeInterval = 90 * 86_400

    let catalogue: Catalogue
    let shelves: LibraryShelves
    let progress: [String: PlaybackProgress]
    let context: PlaybackContext
    let now: Date
    /// Films, home videos and series by how much the household watches them, most first, with
    /// what is known of it. Empty: too little is known.
    let played: [String]
    private let continuing: [ContinueWatchingEntry]
    private let continuingByID: [String: ContinueWatchingEntry]

    /// - Parameters:
    ///   - popular: The server's count of plays.
    ///   - viewers: The progress this device knows of every viewer who counts: what is gone by
    ///     without the server's count.
    init(
        catalogue: Catalogue, shelves: LibraryShelves, progress: [String: PlaybackProgress], context: PlaybackContext,
        popular: Popular = .none, viewers: [[String: PlaybackProgress]] = [], now: Date = Date()
    ) {
        self.catalogue = catalogue
        self.shelves = shelves
        self.progress = progress
        self.context = context
        self.now = now
        continuing = Shelves.continueWatching(in: catalogue, progress: progress)
        continuingByID = Dictionary(continuing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        played = popular.titles.isEmpty ? Self.played(by: viewers, in: catalogue) : popular.titles.map(\.itemId)
    }

    /// How much titles are watched here, from where the viewers are in them: a viewer who
    /// finished one counts twice, one who started it once. With fewer than four titles there
    /// is nothing to say.
    static func played(by viewers: [[String: PlaybackProgress]], in catalogue: Catalogue) -> [String] {
        var points: [String: Int] = [:]
        var latest: [String: Date] = [:]
        for viewer in viewers {
            var mine: [String: Int] = [:]
            for progress in viewer.values where progress.completed || progress.isInProgress {
                guard let item = catalogue.item(progress.itemId) else { continue }
                let id = catalogue.show(of: item)?.id ?? item.id
                mine[id] = max(mine[id] ?? 0, progress.completed ? 2 : 1)
                latest[id] = max(latest[id] ?? .distantPast, progress.updatedAt)
            }
            points.merge(mine, uniquingKeysWith: +)
        }
        guard points.count >= 4 else { return [] }
        return points.keys.sorted {
            (points[$0]!, latest[$0]!, $1) > (points[$1]!, latest[$1]!, $0)
        }
    }

    // MARK: Pages

    /// - Parameters:
    ///   - avoiding: The titles of another page's banner, left out while there are others.
    ///   - section: Of a category with others inside it: the one of those whose rows and titles
    ///     the page shows under its own banner. nil: all of it.
    func page(_ scope: BrowseScope, avoiding: Set<String> = [], section: String? = nil) -> BrowsePage {
        switch scope {
        case .home: home()
        case .movies: list(shelves.movies, avoiding: avoiding)
        case .series: list(shelves.series, avoiding: avoiding)
        case .category(let id):
            shelves.category(id: id).map { category($0, avoiding: avoiding, section: section) } ?? .empty
        case .group(let id): shelves.group(id: id).map { group($0, avoiding: avoiding) } ?? .empty
        }
    }

    private func home() -> BrowsePage {
        let everything = catalogue.items.filter { Shelves.topLevelKinds.contains($0.kind) }
        var rows: [BrowseRow] = []
        if !shelves.continueWatching.isEmpty {
            rows.append(BrowseRow(id: "continueWatching", title: "Continue Watching", content: .continuing(shelves.continueWatching)))
        }
        // The household's own: its named parts' categories after the main part's.
        let categories = shelves.categories.filter { $0.source == .folder } + shelves.groups.flatMap(\.categories)
        if categories.count > 1 {
            rows.append(BrowseRow(id: "categories", title: "Categories", content: .categories(categories)))
        }
        if !shelves.recentlyAdded.isEmpty {
            rows.append(BrowseRow(
                id: "recentlyAdded", title: "Latest Added", content: .recent(shelves.recentlyAdded), seeAll: .recentlyAdded))
        }
        rows += [popularRow(everything, title: "Popular at Home", plain: "Popular")].compactMap { $0 }
        rows += [notWatchedRow(everything)].compactMap { $0 }
        let news = newEpisodes(everything)
        if news.count >= Self.least {
            rows.append(BrowseRow(id: "newEpisodes", title: "New Episodes", content: .items(news)))
        }
        rows += genreRows()
        // What there is in full: a way in, so also when it is short.
        if !shelves.movies.isEmpty {
            rows.append(BrowseRow(id: "movies", title: "Movies", content: .items(shelves.movies), seeAll: .movies))
        }
        if !shelves.series.isEmpty {
            rows.append(BrowseRow(id: "series", title: "Series", content: .items(shelves.series), seeAll: .series))
        }
        for group in shelves.groups {
            rows.append(BrowseRow(
                id: "group.\(group.name)", title: group.name, content: .items(group.items), seeAll: .group(group.id), groupID: group.id))
        }
        return BrowsePage(banner: banner(of: everything), rows: Self.apart(rows))
    }

    private func list(_ items: [Item], avoiding: Set<String>) -> BrowsePage {
        BrowsePage(banner: banner(of: items, avoiding: avoiding), all: items)
    }

    private func category(_ shelf: CategoryShelf, avoiding: Set<String>, section: String? = nil) -> BrowsePage {
        let banner = banner(of: shelf.items, named: shelf.name, avoiding: avoiding)
        guard !shelf.subcategories.isEmpty else {
            return BrowsePage(banner: banner, rows: Self.apart(rows(of: shelf.items, named: shelf.name)), all: shelf.items)
        }
        // A section: the banner stays the whole category's, the rest is the section's.
        if let sub = shelf.subcategories.first(where: { $0.id == section }) {
            return BrowsePage(
                banner: banner, rows: Self.apart(rows(of: sub.items, named: sub.name)), all: sub.items,
                sections: shelf.subcategories)
        }
        var rows = rows(of: shelf.items, named: shelf.name)
        let place = rows.first?.id == "continueWatching" ? 1 : 0
        // A row per section, also a short one: it is the way in.
        rows.insert(contentsOf: shelf.subcategories.map { sub in
            BrowseRow(
                id: "section.\(sub.categoryID)", title: sub.name, content: .items(Array(sub.items.prefix(Self.rowLimit))),
                seeAll: .category(sub.id), categoryID: sub.categoryID)
        }, at: place)
        return BrowsePage(banner: banner, rows: Self.apart(rows), all: shelf.items, sections: shelf.subcategories)
    }

    private func group(_ group: LibraryGroup, avoiding: Set<String>) -> BrowsePage {
        var rows = rows(of: group.items, named: group.name)
        if group.categories.count > 1 {
            let place = rows.first?.id == "continueWatching" ? 1 : 0
            rows.insert(BrowseRow(id: "categories", title: "Categories", content: .categories(group.categories)), at: place)
        }
        rows += group.categories.map {
            BrowseRow(
                id: "category.\($0.name)", title: $0.name, content: .items($0.items), seeAll: .category($0.id),
                categoryID: $0.categoryID)
        }
        return BrowsePage(banner: banner(of: group.items, named: group.name, avoiding: avoiding), rows: Self.apart(rows))
    }

    /// The rows within a part of the library. A small part has none: its grid says it all.
    private func rows(of items: [Item], named name: String) -> [BrowseRow] {
        let ids = Set(items.map(\.id))
        var rows: [BrowseRow] = []
        let started = shelves.continueWatching.filter { ids.contains($0.id) }
        if !started.isEmpty {
            rows.append(BrowseRow(id: "continueWatching", title: "In Progress", content: .continuing(started)))
        }
        guard items.count >= 8 else { return rows }
        rows.append(BrowseRow(id: "latest", title: "Latest in \(name)", content: .items(Array(newest(items).prefix(Self.rowLimit)))))
        rows += [popularRow(items, title: "Popular in \(name)", plain: "Popular in \(name)")].compactMap { $0 }
        rows += [notWatchedRow(items)].compactMap { $0 }
        return rows
    }

    /// What goes with a film or series: Related first, then more of its category and its kind.
    func related(to item: Item) -> [BrowseRow] {
        let everything = catalogue.items.filter { Shelves.topLevelKinds.contains($0.kind) }
        let ranked = RelatedTitles.rank(item, among: everything, isPlayable: isPlayable, isWatched: isWatched)
        var rows: [BrowseRow] = []
        if ranked.count >= Self.least {
            rows.append(BrowseRow(id: "related", title: "Related", content: .items(ranked)))
        }
        var shown = Set([item.id] + ranked.prefix(6).map(\.id))
        func row(_ shelf: CategoryShelf, _ title: String) -> BrowseRow? {
            let others = mixed(shelf.items.filter { !shown.contains($0.id) }).prefix(Self.rowLimit)
            guard others.count >= Self.least else { return nil }
            shown.formUnion(others.prefix(6).map(\.id))
            return BrowseRow(id: "related.\(shelf.name)", title: title, content: .items(Array(others)), seeAll: .category(shelf.id))
        }
        let own = shelves.allCategories.filter { shelf in shelf.items.contains { $0.id == item.id } }
        // The smallest says most about it.
        let folder = own.filter { $0.source == .folder }.min { $0.items.count < $1.items.count }
        let genre = own.first { $0.source == .genre }
        rows += [folder.flatMap { row($0, "More in \($0.name)") }, genre.flatMap { row($0, "More \($0.name)") }].compactMap { $0 }
        return rows
    }

    /// Whether a film, or an episode of a series, plays here now.
    func isPlayable(_ item: Item) -> Bool {
        guard item.kind == .show else {
            return PlayActionBuilder.action(for: item, progress: nil, context: context).isPlayable
        }
        return EpisodeOrder.episodes(ofShow: item.id, in: catalogue).prefix(3)
            .contains { PlayActionBuilder.action(for: $0, show: item, progress: nil, context: context).isPlayable }
    }

    func isWatched(_ item: Item) -> Bool {
        guard item.kind == .show else { return progress[item.id]?.completed == true }
        let episodes = EpisodeOrder.episodes(ofShow: item.id, in: catalogue)
        return !episodes.isEmpty && episodes.allSatisfy { progress[$0.id]?.completed == true }
    }

    // MARK: Rows

    func newest(_ items: [Item]) -> [Item] {
        items.sorted { ($0.addedAt, $1.id) > ($1.addedAt, $0.id) }
    }

    private func popularRow(_ items: [Item], title: String, plain: String) -> BrowseRow? {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let watched = played.compactMap { byID[$0] }
        var row = Array(watched.prefix(Self.rowLimit))
        // Few plays say little: the well known ones of the library fill it up.
        if row.count < 10 {
            let shown = Set(row.map(\.id))
            row += wellKnown(items).filter { !shown.contains($0.id) }.prefix(Self.rowLimit - row.count)
        }
        guard row.count >= Self.least else { return nil }
        let isFilled = !watched.isEmpty && row.count > watched.count
        return BrowseRow(
            id: "popular", title: watched.isEmpty ? plain : title, note: isFilled ? "And well-known titles" : nil, content: .items(row))
    }

    private func wellKnown(_ items: [Item]) -> [Item] {
        items.filter { ($0.renown ?? 0) >= 0.35 }
            .sorted { ($0.renown!, $1.id) > ($1.renown!, $0.id) }
    }

    /// What the viewer did not start. Left out when that is nearly everything, or so little
    /// that the row above already shows it.
    private func notWatchedRow(_ items: [Item]) -> BrowseRow? {
        let unseen = items.filter { !isStarted($0) }
        guard unseen.count >= Self.least, items.count >= 12 || unseen.count < items.count else { return nil }
        let row = unseen.sorted {
            ($0.renown ?? 0, StableHash.mixed(of: $0.id)) > ($1.renown ?? 0, StableHash.mixed(of: $1.id))
        }
        return BrowseRow(id: "notWatched", title: "Not Watched Yet", content: .items(Array(row.prefix(Self.rowLimit))))
    }

    private func isStarted(_ item: Item) -> Bool {
        func touched(_ id: String) -> Bool { progress[id].map { $0.completed || $0.isInProgress } ?? false }
        guard item.kind == .show else { return touched(item.id) }
        return continuingByID[item.id] != nil || catalogue.descendants(of: item.id).contains { touched($0.id) }
    }

    /// Series an episode was added to later than the rest, the newest first.
    private func newEpisodes(_ items: [Item]) -> [Item] {
        let dated = items.filter { $0.kind == .show }.compactMap { show -> (Item, Date)? in
            let date = show.newEpisodesAt ?? Self.later(catalogue.descendants(of: show.id).filter { $0.kind == .episode }.map(\.addedAt))
            guard let date, now.timeIntervalSince(date) < Self.newsDays else { return nil }
            return (show, date)
        }
        return dated.sorted { ($0.1, $1.0.id) > ($1.1, $0.0.id) }.prefix(Self.rowLimit).map(\.0)
    }

    /// The last of some dates, when it is a day or more after the first.
    private static func later(_ dates: [Date]) -> Date? {
        guard let first = dates.min(), let last = dates.max(), last.timeIntervalSince(first) >= 86_400 else { return nil }
        return last
    }

    /// The three genres of which there is the most, what the viewer watches counting more.
    private func genreRows() -> [BrowseRow] {
        shelves.categories.filter { $0.source == .genre && $0.items.count >= 5 }
            .map { shelf in (shelf, shelf.items.count + 4 * shelf.items.filter(isStarted).count) }
            .sorted { ($0.1, $1.0.name) > ($1.1, $0.0.name) }
            .prefix(3)
            .map { shelf, _ in
                BrowseRow(
                    id: "genre.\(shelf.name)", title: shelf.name, content: .items(Array(mixed(shelf.items).prefix(Self.rowLimit))),
                    seeAll: .category(shelf.id))
            }
    }

    /// In no order to speak of, and always the same one.
    private func mixed(_ items: [Item]) -> [Item] {
        items.sorted { ($0.renown ?? 0, StableHash.mixed(of: $0.id)) > ($1.renown ?? 0, StableHash.mixed(of: $1.id)) }
    }

    /// No row starts with what the one above it starts with. A list by title keeps its order.
    static func apart(_ rows: [BrowseRow]) -> [BrowseRow] {
        var result: [BrowseRow] = []
        var above: Set<String> = []
        for row in rows {
            var row = row
            if case .items(let items) = row.content, row.seeAll == nil || row.id.hasPrefix("genre.") {
                let later = items.filter { above.contains($0.id) }
                // With nothing else to start with, the order stays.
                if items.count - later.count >= least { row.content = .items(items.filter { !above.contains($0.id) } + later) }
            }
            if row.content.count > 0, case .categories = row.content {} else { above = Set(row.titleIDs.prefix(4)) }
            result.append(row)
        }
        return result
    }

    // MARK: The banner

    /// Two to four titles with a picture that fills a screen: the newest, and something the
    /// viewer is in. Only what plays here and now.
    func banner(of items: [Item], named name: String? = nil, avoiding: Set<String> = []) -> [BannerSlide] {
        let fitting = items.filter(hasBanner)
        func preferred(_ items: [Item]) -> [Item] {
            items.filter { !avoiding.contains($0.id) } + items.filter { avoiding.contains($0.id) }
        }
        func isFinished(_ item: Item) -> Bool { progress[item.id]?.completed == true }
        let newest = newest(fitting)
        let byID = Dictionary(fitting.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var latest = preferred(newest.filter { !isFinished($0) } + newest.filter(isFinished))
        var started = preferred(continuing.compactMap { byID[$0.id] })
        let loved = preferred(played.compactMap { byID[$0] })
        var popular = loved + preferred(wellKnown(fitting).filter { item in !loved.contains { $0.id == item.id } })

        var slides: [BannerSlide] = []
        func add(_ kicker: String, from list: inout [Item]) {
            while slides.count < Self.bannerLimit, !list.isEmpty {
                let item = list.removeFirst()
                guard !slides.contains(where: { $0.id == item.id }), let slide = slide(item, in: name, kicker: kicker) else { continue }
                return slides.append(slide)
            }
        }
        add("Latest added", from: &latest)
        add("Continue watching", from: &started)
        add("Latest added", from: &latest)
        add("Popular", from: &popular)
        // Not enough of one kind: the newest fill it.
        for _ in slides.count..<Self.bannerLimit { add("Latest added", from: &latest) }
        // What was on the page before is seen again only to make it a slideshow at all.
        let fresh = slides.filter { !avoiding.contains($0.id) }
        return fresh.count >= 2 ? fresh : slides
    }

    /// Wide enough to fill a window. A frame the server took from a small file was only made
    /// larger, and is left out.
    private func hasBanner(_ item: Item) -> Bool {
        guard let backdrop = item.artwork.backdrop, (backdrop.width ?? 0) >= Self.bannerWidth else { return false }
        if item.matchStatus == .matched || item.matchStatus == .locked { return true }
        let files = item.kind == .show
            ? catalogue.descendants(of: item.id).first { !$0.mainFiles.isEmpty }?.mainFiles : item.mainFiles
        return files?.contains { ($0.video?.width ?? 0) >= Self.bannerWidth } == true
    }

    /// nil for what cannot be played.
    func slide(_ item: Item, in place: String? = nil, kicker: String) -> BannerSlide? {
        let entry = continuingByID[item.id]
        let target: Item
        if item.kind == .show {
            guard let episode = entry?.item ?? EpisodeOrder.seasons(ofShow: item.id, in: catalogue).lazy
                .compactMap({ EpisodeOrder.episodes(ofSeason: $0.id, in: catalogue).first }).first
            else { return nil }
            target = episode
        } else {
            target = item
        }
        let action = PlayActionBuilder.action(
            for: target, show: item.kind == .show ? item : nil, progress: progress[target.id], context: context)
        guard case .play(let request, let kind, _) = action, let backdrop = item.artwork.backdrop else { return nil }
        let code = item.kind == .show ? MediaFormat.episodeCode(season: target.seasonNumber, episode: target.episodeNumber) : nil
        var fraction: Double?
        if case .inProgress(let part) = WatchState(progress: progress[target.id], durationMs: target.displayDurationMs) { fraction = part }
        let seasons = item.kind == .show ? EpisodeOrder.seasons(ofShow: item.id, in: catalogue).count : 0
        return BannerSlide(
            item: item, place: place, kicker: kicker,
            meta: ([
                item.year.map(String.init),
                item.kind == .show ? (seasons == 1 ? "1 Season" : "\(seasons) Seasons") : MediaFormat.runtime(ms: item.displayDurationMs),
            ].compactMap { $0 }) + item.genres.prefix(2),
            line: [item.tagline, item.overview].compactMap { $0 }.first { !$0.isEmpty },
            request: request, playLabel: [kind.words, code].compactMap { $0 }.joined(separator: " "), fraction: fraction, backdrop: backdrop)
    }
}

extension RecentCard {
    /// The film, or the series a season is of.
    var titleID: String { showID ?? id }
}
