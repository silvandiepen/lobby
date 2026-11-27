// SPDX-License-Identifier: MPL-2.0
import Foundation

// Filters and orders the films, series and videos of a list. The server does the same for
// `GET /v1/library/query` (apps/server/src/library/query.ts, docs/api.md "Filters and order"):
// change both, so a list is the same with the server out of reach.

/// What kind of title.
public enum TitleKind: String, Codable, CaseIterable, Hashable, Sendable {
    case movie, show, personal

    init?(_ kind: ItemKind) {
        switch kind {
        case .movie: self = .movie
        case .show: self = .show
        case .personal: self = .personal
        default: return nil
        }
    }
}

/// Where one viewer is with a title.
public enum TitleWatchState: String, Codable, CaseIterable, Hashable, Sendable {
    case unwatched
    case inProgress = "in_progress"
    case watched
}

/// How long a film is, or the episodes of a series are.
public enum TitleLength: String, Codable, CaseIterable, Hashable, Sendable {
    /// Under 40 minutes.
    case short
    case standard
    /// Over 150 minutes.
    case long

    public static let shortMs = 40 * 60_000
    public static let longMs = 150 * 60_000

    public init(ms: Int) {
        self = ms < Self.shortMs ? .short : ms > Self.longMs ? .long : .standard
    }
}

/// How recently a title came to the library.
public enum AddedWithin: String, Codable, CaseIterable, Hashable, Sendable {
    case week, month, year

    public var days: Int {
        switch self {
        case .week: 7
        case .month: 30
        case .year: 365
        }
    }
}

public enum TitleQuality: String, Codable, CaseIterable, Hashable, Sendable {
    /// A picture at least `uhdWidth` wide.
    case uhd = "4k"

    /// 3840 × 2160, or 3840 × 1600 for a wide film.
    public static let uhdWidth = 3_200
}

public enum TitleSortKey: String, Codable, CaseIterable, Hashable, Sendable {
    case title, year, added, popular, length, rating

    /// The way it goes by itself: A to Z and shortest first; the newest, most watched and best
    /// rated first.
    public var ascendingByDefault: Bool { self == .title || self == .length }
}

public struct TitleSort: Codable, Hashable, Sendable {
    public var key: TitleSortKey
    public var ascending: Bool

    public init(_ key: TitleSortKey, ascending: Bool? = nil) {
        self.key = key
        self.ascending = ascending ?? key.ascendingByDefault
    }

    public static let byTitle = TitleSort(.title)
}

/// Each part narrows the list; several values in one part are any of them. Empty: everything.
public struct TitleFilter: Codable, Hashable, Sendable {
    public var kinds: Set<TitleKind> = []
    public var yearFrom: Int?
    public var yearTo: Int?
    /// Genre names, whatever their case.
    public var genres: Set<String> = []
    /// `ItemStudio.id`s.
    public var studios: Set<String> = []
    /// Category ids. A category takes in the ones inside it.
    public var categories: Set<String> = []
    /// Of the viewer whose progress is given.
    public var watch: Set<TitleWatchState> = []
    public var lengths: Set<TitleLength> = []
    public var added: AddedWithin?
    public var quality: Set<TitleQuality> = []
    /// Audio languages, as the files name them ("eng").
    public var languages: Set<String> = []
    /// Only what is on this device. The server does not know it.
    public var downloaded = false

    public init() {}

    public static let none = TitleFilter()

    public var isEmpty: Bool { self == .none }

    /// How many parts narrow the list: for a badge.
    public var count: Int {
        [
            !kinds.isEmpty, yearFrom != nil || yearTo != nil, !genres.isEmpty, !studios.isEmpty, !categories.isEmpty,
            !watch.isEmpty, !lengths.isEmpty, added != nil, !quality.isEmpty, !languages.isEmpty, downloaded,
        ].filter { $0 }.count
    }

    /// A decade: 1990 for the 1990s.
    public var decade: Int? {
        guard let from = yearFrom, let to = yearTo, from % 10 == 0, to == from + 9 else { return nil }
        return from
    }

    public mutating func setDecade(_ decade: Int?) {
        yearFrom = decade
        yearTo = decade.map { $0 + 9 }
    }

    /// For `GET /v1/library/query`. `downloaded` stays on the device.
    public func queryItems(profileID: String?) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        func add(_ name: String, _ values: some Sequence<String>) {
            items += values.sorted().map { URLQueryItem(name: name, value: $0) }
        }
        add("kind", kinds.map(\.rawValue))
        if let yearFrom { items.append(URLQueryItem(name: "yearFrom", value: String(yearFrom))) }
        if let yearTo { items.append(URLQueryItem(name: "yearTo", value: String(yearTo))) }
        add("genre", genres)
        add("studio", studios)
        add("category", categories)
        add("watch", watch.map(\.rawValue))
        add("length", lengths.map(\.rawValue))
        if let added { items.append(URLQueryItem(name: "added", value: added.rawValue)) }
        add("quality", quality.map(\.rawValue))
        add("language", languages)
        if !watch.isEmpty, let profileID { items.append(URLQueryItem(name: "profile", value: profileID)) }
        return items
    }
}

/// What a list was last filtered and ordered by: kept per list and viewer.
public struct TitleChoice: Codable, Hashable, Sendable {
    public var filter: TitleFilter
    public var sort: TitleSort

    public init(filter: TitleFilter = .none, sort: TitleSort = .byTitle) {
        self.filter = filter
        self.sort = sort
    }
}

/// What the device knows besides the titles themselves.
public struct TitleQueryContext: Sendable {
    public var catalogue: Catalogue
    /// The viewer's own progress, by item id.
    public var progress: [String: PlaybackProgress]
    /// Category id → the category it is inside of.
    public var categoryParents: [String: String]
    /// Ids of the films, videos and episodes on this device.
    public var downloaded: Set<String>
    /// Titles by how much they are watched, most first.
    public var popular: [String]
    public var now: Date

    public init(
        catalogue: Catalogue, progress: [String: PlaybackProgress] = [:], categoryParents: [String: String] = [:],
        downloaded: Set<String> = [], popular: [String] = [], now: Date = Date()
    ) {
        self.catalogue = catalogue
        self.progress = progress
        self.categoryParents = categoryParents
        self.downloaded = downloaded
        self.popular = popular
        self.now = now
    }

    public init(catalogue: Catalogue, progress: [String: PlaybackProgress] = [:], groups: CategoryGroups?,
                downloaded: Set<String> = [], popular: [String] = [], now: Date = Date()) {
        var parents: [String: String] = [:]
        for group in groups?.groups ?? [] {
            for entry in group.entries { if let parent = entry.parentId { parents[entry.id] = parent } }
        }
        self.init(
            catalogue: catalogue, progress: progress, categoryParents: parents, downloaded: downloaded, popular: popular,
            now: now)
    }
}

/// What a list offers to filter by: only what is in it.
public struct TitleFilterOptions: Hashable, Sendable {
    public var kinds: [TitleKind] = []
    /// The decades of its years, oldest first.
    public var decades: [Int] = []
    public var years: ClosedRange<Int>?
    /// The most common first.
    public var genres: [String] = []
    public var studios: [ItemStudio] = []
    public var languages: [String] = []
    public var lengths: [TitleLength] = []
    public var hasUHD = false
    public var hasDownloads = false

    public init() {}
}

public enum TitleQuery {
    /// The films, series and videos of `items` that pass `filter`, in the order of `sort`.
    /// Anything else in `items` (seasons, episodes) is left out.
    public static func apply(_ filter: TitleFilter, sort: TitleSort, to items: [Item], context: TitleQueryContext) -> [Item] {
        let facts = items.compactMap { Facts($0, context: context) }
        let wanted = filter.categories.isEmpty ? nil : withInside(filter.categories, parents: context.categoryParents)
        let genres = Set(filter.genres.map { $0.lowercased() })
        let languages = Set(filter.languages.map { $0.lowercased() })
        let since = filter.added.map { context.now.addingTimeInterval(-Double($0.days) * 86_400) }
        let passed = facts.filter { one in
            if !filter.kinds.isEmpty, !filter.kinds.contains(one.kind) { return false }
            if let from = filter.yearFrom, (one.item.year ?? .min) < from { return false }
            if let to = filter.yearTo, (one.item.year ?? .max) > to || one.item.year == nil { return false }
            if !genres.isEmpty, !one.item.genres.contains(where: { genres.contains($0.lowercased()) }) { return false }
            if !filter.studios.isEmpty, !(one.item.studios ?? []).contains(where: { filter.studios.contains($0.id) }) {
                return false
            }
            if let wanted {
                let own = (one.item.categoryIds ?? []) + (one.item.ruleCategoryIds ?? [])
                if !own.contains(where: wanted.contains) { return false }
            }
            if !filter.watch.isEmpty, !filter.watch.contains(one.watchState(context.progress)) { return false }
            if !filter.lengths.isEmpty, !(one.lengthMs.map { filter.lengths.contains(TitleLength(ms: $0)) } ?? false) {
                return false
            }
            if let since, one.item.addedAt < since { return false }
            if filter.quality.contains(.uhd), !one.leaves.contains(where: isUHD) { return false }
            if !languages.isEmpty, !one.leaves.contains(where: { leaf in
                leaf.mainFiles.contains { file in file.audio.contains { $0.language.map { languages.contains($0.lowercased()) } ?? false } }
            }) { return false }
            if filter.downloaded, !one.leaves.contains(where: { context.downloaded.contains($0.id) }) { return false }
            return true
        }
        return sorted(passed, by: sort, popular: context.popular).map(\.item)
    }

    /// What there is to filter `items` by.
    public static func options(of items: [Item], context: TitleQueryContext) -> TitleFilterOptions {
        let facts = items.compactMap { Facts($0, context: context) }
        var options = TitleFilterOptions()
        options.kinds = TitleKind.allCases.filter { kind in facts.contains { $0.kind == kind } }
        let years = facts.compactMap(\.item.year)
        if let low = years.min(), let high = years.max() { options.years = low...high }
        options.decades = Set(years.map { $0 / 10 * 10 }).sorted()
        var genres: [String: (name: String, count: Int)] = [:]
        var studios: [String: (studio: ItemStudio, count: Int)] = [:]
        var languages: [String: Int] = [:]
        var lengths = Set<TitleLength>()
        for one in facts {
            for name in Set(one.item.genres) { genres[name.lowercased(), default: (name, 0)].count += 1 }
            for studio in one.item.studios ?? [] { studios[studio.id, default: (studio, 0)].count += 1 }
            for code in Set(one.leaves.flatMap { $0.mainFiles.flatMap { $0.audio.compactMap { $0.language?.lowercased() } } }) {
                languages[code, default: 0] += 1
            }
            if let length = one.lengthMs { lengths.insert(TitleLength(ms: length)) }
            if !options.hasUHD, one.leaves.contains(where: isUHD) { options.hasUHD = true }
            if !options.hasDownloads, one.leaves.contains(where: { context.downloaded.contains($0.id) }) { options.hasDownloads = true }
        }
        options.genres = genres.values.sorted { ($0.count, $1.name) > ($1.count, $0.name) }.map(\.name)
        options.studios = studios.values.sorted { ($0.count, $1.studio.name) > ($1.count, $0.studio.name) }.map(\.studio)
        options.languages = languages.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        options.lengths = TitleLength.allCases.filter(lengths.contains)
        return options
    }

    /// Where a viewer is with a film or series.
    public static func watchState(of item: Item, progress: [String: PlaybackProgress], in catalogue: Catalogue) -> TitleWatchState {
        guard let facts = Facts(item, context: TitleQueryContext(catalogue: catalogue)) else { return .unwatched }
        return facts.watchState(progress)
    }

    /// The length a list goes by: a film's own, the average of a series' episodes.
    public static func lengthMs(of item: Item, in catalogue: Catalogue) -> Int? {
        Facts(item, context: TitleQueryContext(catalogue: catalogue))?.lengthMs
    }

    // MARK: -

    private struct Facts {
        let item: Item
        let kind: TitleKind
        /// The film itself, or the series' episodes.
        let leaves: [Item]
        let lengthMs: Int?

        init?(_ item: Item, context: TitleQueryContext) {
            guard let kind = TitleKind(item.kind) else { return nil }
            self.item = item
            self.kind = kind
            if kind == .show {
                leaves = context.catalogue.children(of: item.id).filter { $0.kind == .season }
                    .flatMap { context.catalogue.children(of: $0.id).filter { $0.kind == .episode } }
            } else {
                leaves = [item]
            }
            let known = leaves.compactMap(TitleQuery.lengthMs(ofLeaf:))
            if known.isEmpty {
                lengthMs = nil
            } else if kind == .show {
                lengthMs = Int((Double(known.reduce(0, +)) / Double(known.count)).rounded())
            } else {
                lengthMs = known.first
            }
        }

        /// Finished when every part is; started when a part is started or finished.
        func watchState(_ progress: [String: PlaybackProgress]) -> TitleWatchState {
            var finished = 0
            var touched = 0
            for leaf in leaves {
                guard let own = progress[leaf.id] else { continue }
                if own.completed { finished += 1 }
                if own.completed || own.positionMs > 0 { touched += 1 }
            }
            if !leaves.isEmpty, finished == leaves.count { return .watched }
            return touched > 0 ? .inProgress : .unwatched
        }
    }

    static func lengthMs(ofLeaf item: Item) -> Int? {
        if let runtime = item.runtimeMs { return runtime }
        guard let file = item.mainFiles.first else { return nil }
        if let start = file.startMs, let end = file.endMs, end > start { return end - start }
        return file.durationMs
    }

    private static func isUHD(_ leaf: Item) -> Bool {
        leaf.mainFiles.contains { ($0.video?.width ?? 0) >= TitleQuality.uhdWidth }
    }

    private static func withInside(_ ids: Set<String>, parents: [String: String]) -> Set<String> {
        ids.union(parents.compactMap { child, parent in ids.contains(parent) ? child : nil })
    }

    private static func sorted(_ facts: [Facts], by sort: TitleSort, popular: [String]) -> [Facts] {
        let rank = Dictionary(popular.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let count = Double(max(1, popular.count))
        func value(_ one: Facts) -> Double? {
            switch sort.key {
            case .title: 0
            case .year: one.item.year.map(Double.init)
            case .added: one.item.addedAt.timeIntervalSince1970
            case .length: one.lengthMs.map(Double.init)
            case .rating: one.item.rating
            // Watched here first, by how much; then how well known.
            case .popular: rank[one.item.id].map { 1 + (count - Double($0)) / count } ?? one.item.renown
            }
        }
        let keyed = facts.map { ($0, value($0)) }
        return keyed.sorted { a, b in
            if sort.key == .title {
                return sort.ascending ? Shelves.titleOrder(a.0.item, b.0.item) : Shelves.titleOrder(b.0.item, a.0.item)
            }
            switch (a.1, b.1) {
            // Unknown goes last, either way.
            case (nil, nil): return Shelves.titleOrder(a.0.item, b.0.item)
            case (nil, _): return false
            case (_, nil): return true
            case (let x?, let y?):
                if x != y { return sort.ascending ? x < y : x > y }
                return Shelves.titleOrder(a.0.item, b.0.item)
            }
        }.map(\.0)
    }
}

/// Keeps what each list was last filtered and ordered by, per viewer, on this device.
public struct TitleChoiceStore: Sendable {
    /// nil: the app's own defaults.
    private let suiteName: String?
    private static let prefix = "lobby.titleChoice."

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// - Parameters:
    ///   - list: Stable for the list: "movies", "category:<id>".
    ///   - viewer: The viewer's profile id; nil before one is chosen.
    public func choice(for list: String, viewer: String?) -> TitleChoice? {
        guard let data = defaults.data(forKey: key(list, viewer)) else { return nil }
        // A choice this build cannot read (a newer one's) is no choice: the list starts plain.
        return try? JSONDecoder().decode(TitleChoice.self, from: data)
    }

    public func save(_ choice: TitleChoice?, for list: String, viewer: String?) {
        guard let choice, choice != TitleChoice() else { return defaults.removeObject(forKey: key(list, viewer)) }
        // Sets of strings and enums: encoding them cannot fail.
        defaults.set(try! JSONEncoder().encode(choice), forKey: key(list, viewer))
    }

    private func key(_ list: String, _ viewer: String?) -> String {
        Self.prefix + (viewer ?? "-") + "." + list
    }
}
