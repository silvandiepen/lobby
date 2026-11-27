// SPDX-License-Identifier: MPL-2.0
import LobbyKit

/// What the kids screens show, built from what the viewer may watch. Everything in it plays:
/// a title that does not (or only after the server converted it) is not here at all.
struct KidsLibrary: Equatable, Sendable {
    static let homeLimit = 24

    /// Only what plays. The next episode after one of these is one of these.
    var catalogue = Catalogue()
    /// The part of that which is on this device.
    var onDevice = Catalogue()
    var continueWatching: [ContinueCard] = []
    /// The series among those.
    var seriesToContinue: [ContinueCard] = []
    /// Films and series, the newest first, without the ones already above them as cards.
    var home: [Item] = []
    /// Films and home videos, by title.
    var movies: [Item] = []
    var series: [Item] = []
    var onHere: [Item] = []
    /// What Home opens with: large pictures that play.
    var banner: [BannerSlide] = []
    /// What came last, without what the banner shows.
    var new: [Item] = []
    /// What this child, or the household's children, watch most.
    var favourites: [Item] = []
    /// The household's top-level categories with something to watch in them, in its order,
    /// each with those inside it. Empty when there is only one: that is no choice.
    var categories: [CategoryShelf] = []
    /// The banner of each of those and of the ones inside them, by `CategoryShelf.id`.
    var categoryBanners: [String: [BannerSlide]] = [:]

    /// One of `categories`, or one inside one of them.
    func category(_ id: String) -> CategoryShelf? { categories.lazy.flatMap(\.withSubcategories).first { $0.id == id } }

    static let empty = KidsLibrary()

    init() {}

    /// - Parameters:
    ///   - limits: What the viewer may watch, for which categories to offer.
    ///   - popular, viewers: What the household's children watch.
    init(
        catalogue whole: Catalogue, groups: CategoryGroups = .none, limits: KidsSettings? = nil,
        progress: [String: PlaybackProgress], context: PlaybackContext, popular: Popular = .none,
        viewers: [[String: PlaybackProgress]] = []
    ) {
        let playable = whole.items.compactMap { item -> Item? in
            guard [.movie, .episode, .personal].contains(item.kind) else { return nil }
            let shown = Self.withoutConverting(item, context: context)
            return PlayActionBuilder.action(for: shown, progress: nil, context: context).isPlayable ? shown : nil
        }
        let ids = Set(playable.map(\.id))
        var changed = Dictionary(playable.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in whole.limited(to: ids).items where changed[item.id] == nil { changed[item.id] = item }
        catalogue = Catalogue(items: Array(changed.values))
        onDevice = catalogue.limited(to: ids.intersection(context.localCopies.keys))

        continueWatching = Shelves.continueWatching(in: catalogue, progress: progress).map { ContinueCard(entry: $0, context: context) }
        seriesToContinue = continueWatching.filter { catalogue.item($0.id)?.kind == .show }
        movies = Self.films(in: catalogue)
        series = Shelves.series(in: catalogue)
        onHere = Self.films(in: onDevice) + Shelves.series(in: onDevice)

        var seen = Set(continueWatching.prefix(2).map(\.id))
        for entry in Shelves.recentlyAdded(in: catalogue) {
            let item: Item? = switch entry {
            case .item(let item): catalogue.show(of: item) ?? item
            case .season(let season, let show, _, _): show ?? season
            }
            guard let item, seen.insert(item.id).inserted else { continue }
            home.append(item)
            if home.count == Self.homeLimit { break }
        }

        var shelves = LibraryShelves(catalogue: catalogue, groups: groups, progress: progress, context: context)
        let builder = BrowseBuilder(
            catalogue: catalogue, shelves: shelves, progress: progress, context: context, popular: popular, viewers: viewers)
        let everything = catalogue.items.filter { Shelves.topLevelKinds.contains($0.kind) }
        banner = builder.banner(of: everything)
        let shown = Set(banner.map(\.id))
        new = Array(builder.newest(everything).filter { !shown.contains($0.id) }.prefix(12))
        let byID = Dictionary(everything.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Their own first; then what the others watch.
        let mine = BrowseBuilder.played(by: [progress], in: catalogue)
        favourites = Array((mine + builder.played.filter { !mine.contains($0) }).compactMap { byID[$0] }.prefix(12))
        if favourites.count < BrowseBuilder.least { favourites = [] }

        shelves.categories.removeAll { $0.source == .genre }
        let all = shelves.categories + shelves.groups.flatMap(\.categories)
        let offered = all.filter { Self.offers($0, groups: groups, limits: limits, in: catalogue) }
        guard offered.count > 1 else { return }
        categories = offered
        categoryBanners = Dictionary(
            offered.flatMap(\.withSubcategories).map { ($0.id, builder.banner(of: $0.items)) }, uniquingKeysWith: { first, _ in first })
    }

    /// A title can be in a category that is allowed and in one that is not: the second is not
    /// offered for that. It is when a title of it was allowed by itself. A category with others
    /// inside it is offered when one of those is.
    private static func offers(_ category: CategoryShelf, groups: CategoryGroups, limits: KidsSettings?, in catalogue: Catalogue) -> Bool {
        guard let limits else { return true }
        let ids = category.withSubcategories.map(\.categoryID)
        if ids.contains(where: limits.allowedCategoryIds.contains) { return true }
        if groups.groups.contains(where: { group in
            limits.allowedGroupIds.contains(group.id) && group.entries.contains { ids.contains($0.id) }
        }) {
            return true
        }
        let single = Set(limits.allowedItemIds)
        return category.items.contains { item in
            single.contains(item.id) || catalogue.descendants(of: item.id).contains { single.contains($0.id) }
        }
    }

    /// The item without files the server would have to convert first: a child does not wait
    /// for those. A copy on this device plays whatever it was made from.
    private static func withoutConverting(_ item: Item, context: PlaybackContext) -> Item {
        guard context.localCopies[item.id] == nil else { return item }
        var item = item
        item.files.removeAll { $0.playability == .transcode && $0.convertible == true }
        return item
    }

    private static func films(in catalogue: Catalogue) -> [Item] {
        (Shelves.movies(in: catalogue) + catalogue.items(ofKind: .personal))
            .sorted { $0.sortTitle.localizedStandardCompare($1.sortTitle) == .orderedAscending }
    }
}
