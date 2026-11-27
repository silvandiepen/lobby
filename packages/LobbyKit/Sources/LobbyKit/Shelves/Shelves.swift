// SPDX-License-Identifier: MPL-2.0
import Foundation

/// One card on Continue Watching.
public struct ContinueWatchingEntry: Hashable, Sendable, Identifiable {
    public enum Reason: Hashable, Sendable {
        /// The viewer stopped part-way: Resume.
        case resume
        /// The viewer finished the episode before this one: Play Next.
        case nextEpisode
    }

    /// The film or episode to play.
    public var item: Item
    /// The episode's show, for the card's title and poster.
    public var show: Item?
    /// Where to resume. nil for a next episode that was never started.
    public var progress: PlaybackProgress?
    public var reason: Reason
    /// When the viewer last watched this film or show. The shelf is ordered by it.
    public var lastWatchedAt: Date

    /// One card per film and one per show.
    public var id: String { show?.id ?? item.id }
}

/// One card on Recently Added.
public enum RecentlyAddedEntry: Hashable, Sendable, Identifiable {
    /// A film, or a personal video.
    case item(Item)
    /// The episodes of one season, as one card.
    case season(season: Item, show: Item?, episodeCount: Int, addedAt: Date)

    public var id: String {
        switch self {
        case .item(let item): item.id
        case .season(let season, _, _, _): season.id
        }
    }

    public var addedAt: Date {
        switch self {
        case .item(let item): item.addedAt
        case .season(_, _, _, let addedAt): addedAt
        }
    }
}

/// A row of films and shows that share a category of the household's or a genre.
public struct CategoryShelf: Hashable, Sendable, Identifiable {
    public enum Source: String, Hashable, Sendable {
        /// One of the household's categories, from `Item.categoryIds`.
        case folder
        /// From `Item.genres`: the metadata match.
        case genre
    }

    /// The household's id for the category; a genre's own name.
    public var categoryID: String
    public var name: String
    public var source: Source
    /// For a category with others inside it, also everything that is in those.
    public var items: [Item]
    /// The categories inside this one that hold something, in the household's order.
    public var subcategories: [CategoryShelf]
    /// The category this one is inside of.
    public var parentID: String?

    /// Stays the same when the household renames or moves the category.
    public var id: String { "\(source.rawValue):\(categoryID)" }

    public init(
        categoryID: String? = nil, name: String, source: Source, items: [Item], subcategories: [CategoryShelf] = [],
        parentID: String? = nil
    ) {
        self.categoryID = categoryID ?? name
        self.name = name
        self.source = source
        self.items = items
        self.subcategories = subcategories
        self.parentID = parentID
    }

    /// It and the ones inside it.
    public var withSubcategories: [CategoryShelf] { [self] + subcategories }
}

/// A named part of the library, with the household's id for it.
public struct LibraryGroup: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Its top-level categories that hold something, in the household's order; those inside
    /// another are in that one's `subcategories`.
    public var categories: [CategoryShelf]
    /// Every film, show and home video in the part, by title.
    public var items: [Item]
}

/// The library by the household's groups. See `Shelves.library(in:groups:)`.
public struct GroupedLibrary: Hashable, Sendable {
    /// The main part's films, by title. No title of a named part is among them.
    public var movies: [Item]
    /// The main part's shows, by title.
    public var series: [Item]
    /// The main part's categories, without the ones that only repeat Movies or Series.
    public var categories: [CategoryShelf]
    /// The named parts that hold something, in the household's order.
    public var groups: [LibraryGroup]
}

/// The library screen's shelves, built from the local catalogue and a viewer's progress.
///
/// Pure functions: the same catalogue and progress always give the same shelves, with or without
/// a server.
public enum Shelves {
    /// What a mixed shelf shows as a card of its own. Seasons, episodes and extras are reached
    /// through their show or film.
    public static let topLevelKinds: Set<ItemKind> = [.movie, .show, .personal]

    // MARK: Continue Watching

    /// Unfinished films and episodes for one viewer, most recently watched first.
    ///
    /// A show appears once. Its card is the episode the viewer last touched if that is unfinished,
    /// or the next unwatched episode after it if it is finished. Finishing the last episode takes
    /// the show off the shelf, unless an earlier episode was left part-way.
    ///
    /// - Parameter progress: The viewer's progress by item id (`ProgressStore.progress(profileID:)`).
    public static func continueWatching(in catalogue: Catalogue, progress: [String: PlaybackProgress]) -> [ContinueWatchingEntry] {
        var entries: [ContinueWatchingEntry] = []
        var episodeActivity: [String: [(episode: Item, progress: PlaybackProgress)]] = [:]

        for progress in progress.values {
            guard let item = catalogue.item(progress.itemId) else { continue }
            if item.kind == .episode, let show = catalogue.show(of: item) {
                if progress.completed || progress.isInProgress {
                    episodeActivity[show.id, default: []].append((item, progress))
                }
            } else if progress.isInProgress, item.kind == .movie || item.kind == .personal || item.kind == .episode {
                entries.append(ContinueWatchingEntry(
                    item: item, show: nil, progress: progress, reason: .resume, lastWatchedAt: progress.updatedAt))
            }
        }

        for (showID, activity) in episodeActivity {
            guard let show = catalogue.item(showID) else { continue }
            if let entry = showEntry(show: show, activity: activity, catalogue: catalogue, progress: progress) {
                entries.append(entry)
            }
        }

        return entries.sorted {
            $0.lastWatchedAt != $1.lastWatchedAt ? $0.lastWatchedAt > $1.lastWatchedAt : $0.id < $1.id
        }
    }

    private static func showEntry(
        show: Item, activity: [(episode: Item, progress: PlaybackProgress)], catalogue: Catalogue,
        progress: [String: PlaybackProgress]
    ) -> ContinueWatchingEntry? {
        let newestFirst = activity.sorted {
            $0.progress.updatedAt != $1.progress.updatedAt
                ? $0.progress.updatedAt > $1.progress.updatedAt : $0.episode.id < $1.episode.id
        }
        guard let latest = newestFirst.first else { return nil }

        if latest.progress.completed {
            let chain = EpisodeOrder.chain(containing: latest.episode, in: catalogue)
            let index = chain.firstIndex { $0.id == latest.episode.id } ?? chain.endIndex - 1
            let upNext = chain.dropFirst(index + 1).first { progress[$0.id]?.completed != true }
            if let upNext {
                let started = progress[upNext.id].flatMap { $0.isInProgress ? $0 : nil }
                return ContinueWatchingEntry(
                    item: upNext, show: show, progress: started,
                    reason: started == nil ? .nextEpisode : .resume, lastWatchedAt: latest.progress.updatedAt)
            }
        }

        // Nothing follows the last finished episode: an episode left part-way still counts.
        guard let unfinished = newestFirst.first(where: { $0.progress.isInProgress }) else { return nil }
        return ContinueWatchingEntry(
            item: unfinished.episode, show: show, progress: unfinished.progress, reason: .resume,
            lastWatchedAt: unfinished.progress.updatedAt)
    }

    // MARK: Recently Added

    /// Films, personal videos and seasons, newest first. A season's episodes make one card,
    /// dated by its newest episode.
    public static func recentlyAdded(in catalogue: Catalogue, limit: Int? = nil) -> [RecentlyAddedEntry] {
        var entries: [RecentlyAddedEntry] = []
        var episodesBySeason: [String: [Item]] = [:]

        for item in catalogue.itemsByID.values {
            switch item.kind {
            case .movie, .personal:
                entries.append(.item(item))
            case .episode:
                if let season = catalogue.parent(of: item), season.kind == .season {
                    episodesBySeason[season.id, default: []].append(item)
                } else {
                    // An episode that is not in a season yet still shows up, on its own.
                    entries.append(.item(item))
                }
            default:
                break
            }
        }

        for (seasonID, episodes) in episodesBySeason {
            guard let season = catalogue.item(seasonID), let newest = episodes.map(\.addedAt).max() else { continue }
            entries.append(.season(
                season: season, show: catalogue.show(of: season), episodeCount: episodes.count, addedAt: newest))
        }

        let sorted = entries.sorted { $0.addedAt != $1.addedAt ? $0.addedAt > $1.addedAt : $0.id < $1.id }
        return limit.map { Array(sorted.prefix($0)) } ?? sorted
    }

    // MARK: Sections

    /// Every film, by sort title.
    public static func movies(in catalogue: Catalogue) -> [Item] {
        sortedByTitle(catalogue.items(ofKind: .movie))
    }

    /// Every show, by sort title.
    public static func series(in catalogue: Catalogue) -> [Item] {
        sortedByTitle(catalogue.items(ofKind: .show))
    }

    /// One shelf per library folder, then one per genre, each by name. A show appears once.
    public static func categories(in catalogue: Catalogue) -> [CategoryShelf] {
        var folders: [String: [Item]] = [:]
        var genres: [String: [Item]] = [:]
        for item in catalogue.itemsByID.values where topLevelKinds.contains(item.kind) {
            for name in Set(item.categories) { folders[name, default: []].append(item) }
            for name in Set(item.genres) { genres[name, default: []].append(item) }
        }

        func shelves(_ groups: [String: [Item]], _ source: CategoryShelf.Source) -> [CategoryShelf] {
            groups
                .map { CategoryShelf(name: $0.key, source: source, items: sortedByTitle($0.value)) }
                .sorted { titleOrder($0.name, $1.name) }
        }
        return shelves(folders, .folder) + shelves(genres, .genre)
    }

    // MARK: Parts of the library

    /// The library by the household's groups: the main part, and each named part ("Kids")
    /// with its categories in the household's order.
    ///
    /// A film or show is in a named part when one of its categories is, and in the main part
    /// when none is: no title is in the main part and in a named one. Without groups (a server
    /// that has none) everything is in the main part, with `categories(in:)` as its categories.
    public static func library(in catalogue: Catalogue, groups: CategoryGroups) -> GroupedLibrary {
        guard !groups.groups.isEmpty else {
            return GroupedLibrary(
                movies: movies(in: catalogue), series: series(in: catalogue), categories: categories(in: catalogue),
                groups: [])
        }
        let named = groups.groups.filter { $0.name != nil }
        let byName = groups.idsByName

        var groupOfCategory: [String: Int] = [:]
        for (index, group) in named.enumerated() {
            for category in group.entries where groupOfCategory[category.id] == nil {
                groupOfCategory[category.id] = index
            }
        }

        // On a category's page: its own titles, those its studios bring, and all of the ones
        // inside it. For the part of the library a title is in only its own count.
        var onPage: [String: [Item]] = [:]
        // The main part's own categories hold only its titles, as before; a studio brings its own.
        var onMainPage: [String: [Item]] = [:]
        var main: [Item] = []
        var members: [[Item]] = Array(repeating: [], count: named.count)
        for item in catalogue.itemsByID.values where topLevelKinds.contains(item.kind) {
            let own = groups.categoryIDs(of: item, byName: byName)
            let ruled = Set(item.ruleCategoryIds ?? [])
            for category in own.union(ruled) { onPage[category, default: []].append(item) }
            let inGroups = Set(own.compactMap { groupOfCategory[$0] })
            for category in inGroups.isEmpty ? own.union(ruled) : ruled { onMainPage[category, default: []].append(item) }
            if inGroups.isEmpty {
                main.append(item)
            } else {
                for index in inGroups { members[index].append(item) }
            }
        }

        let parts = named.enumerated().compactMap { index, group -> LibraryGroup? in
            guard let name = group.name, !members[index].isEmpty else { return nil }
            return LibraryGroup(
                id: group.id, name: name, categories: nested(group.entries, onPage: onPage), items: sortedByTitle(members[index]))
        }

        return GroupedLibrary(
            movies: sortedByTitle(main.filter { $0.kind == .movie }),
            series: sortedByTitle(main.filter { $0.kind == .show }),
            categories: mainCategories(of: main, groups: groups, byName: byName, onPage: onMainPage),
            groups: parts)
    }

    /// The top-level ones of some categories in the household's order, each with those inside
    /// it. A category that holds nothing, also through those inside it, is left out. One inside
    /// another that is not listed (a server from before) stands by itself.
    private static func nested(_ entries: [LibraryCategory], onPage: [String: [Item]]) -> [CategoryShelf] {
        let listed = Set(entries.map(\.id))
        let top = entries.filter { $0.parentId.map { !listed.contains($0) } ?? true }
        return top.compactMap { category in
            let subcategories = entries.filter { $0.parentId == category.id }.compactMap { sub -> CategoryShelf? in
                guard let items = onPage[sub.id] else { return nil }
                return CategoryShelf(
                    categoryID: sub.id, name: sub.name, source: .folder, items: sortedByTitle(items), parentID: category.id)
            }
            var items = onPage[category.id] ?? []
            var seen = Set(items.map(\.id))
            for item in subcategories.flatMap(\.items) where seen.insert(item.id).inserted { items.append(item) }
            guard !items.isEmpty else { return nil }
            return CategoryShelf(
                categoryID: category.id, name: category.name, source: .folder, items: sortedByTitle(items),
                subcategories: subcategories)
        }
    }

    /// The main part's categories: the household's own in its order, then ones it did not
    /// list and genres, each by name. A category that holds exactly the main part's films, or
    /// exactly its shows, is left out: Movies and Series are already there.
    private static func mainCategories(
        of items: [Item], groups: CategoryGroups, byName: [String: String], onPage: [String: [Item]]
    ) -> [CategoryShelf] {
        var unlisted: [String: [Item]] = [:]
        var unlistedNames: [String: String] = [:]
        var genres: [String: [Item]] = [:]
        let known = Set(groups.categories.map(\.id))
        for item in items {
            for id in groups.categoryIDs(of: item, byName: byName) {
                if !known.contains(id) { unlisted[id, default: []].append(item) }
            }
            for (id, name) in zip(item.categoryIds ?? item.categories, item.categories) { unlistedNames[id] = name }
            for name in Set(item.genres) { genres[name, default: []].append(item) }
        }
        let allMovies = Set(items.filter { $0.kind == .movie }.map(\.id))
        let allSeries = Set(items.filter { $0.kind == .show }.map(\.id))

        var shelves = nested(groups.groups.filter { $0.name == nil }.flatMap(\.entries), onPage: onPage)
        shelves += unlisted
            .map { CategoryShelf(categoryID: $0.key, name: unlistedNames[$0.key] ?? $0.key, source: .folder, items: sortedByTitle($0.value)) }
            .sorted { titleOrder($0.name, $1.name) }
        shelves.removeAll { shelf in
            let ids = Set(shelf.items.map(\.id))
            return shelf.subcategories.isEmpty && (ids == allMovies || ids == allSeries)
        }
        return shelves + genres
            .map { CategoryShelf(name: $0.key, source: .genre, items: sortedByTitle($0.value)) }
            .sorted { titleOrder($0.name, $1.name) }
    }

    // MARK: Search

    /// Films, shows and personal videos whose title contains every word of `query`, ignoring
    /// case and accents. Titles that start with the query come first.
    ///
    /// - Parameter kinds: Pass `.episode` as well to search episode titles.
    public static func search(
        _ query: String, in catalogue: Catalogue, kinds: Set<ItemKind> = topLevelKinds
    ) -> [Item] {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let phrase = words.joined(separator: " ")

        let matches: [(rank: Int, item: Item)] = catalogue.itemsByID.values.compactMap { item in
            guard kinds.contains(item.kind) else { return nil }
            let title = fold(item.title)
            let sortTitle = fold(item.sortTitle)
            guard words.allSatisfy({ title.contains($0) || sortTitle.contains($0) }) else { return nil }
            let rank =
                if title.hasPrefix(phrase) || sortTitle.hasPrefix(phrase) { 0 }
                else if title.split(separator: " ").contains(where: { $0.hasPrefix(words[0]) }) { 1 }
                else { 2 }
            return (rank, item)
        }
        return matches
            .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : titleOrder($0.item, $1.item) }
            .map(\.item)
    }

    // MARK: Ordering

    static func sortedByTitle(_ items: [Item]) -> [Item] {
        items.sorted(by: titleOrder)
    }

    static func titleOrder(_ a: Item, _ b: Item) -> Bool {
        if a.sortTitle != b.sortTitle { return titleOrder(a.sortTitle, b.sortTitle) }
        return a.id < b.id
    }

    /// Case- and accent-insensitive, with numbers in numeric order ("Toy Story 2" before
    /// "Toy Story 10"). Not tied to the device's language, so the order is the same everywhere.
    private static func titleOrder(_ a: String, _ b: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .numeric]
        let result = a.compare(b, options: options)
        return result == .orderedSame ? a < b : result == .orderedAscending
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
