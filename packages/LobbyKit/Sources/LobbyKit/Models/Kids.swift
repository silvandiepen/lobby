// SPDX-License-Identifier: MPL-2.0
/// What a kids viewer may watch, by id. Nothing here means nothing to watch.
public struct KidsSettings: Codable, Hashable, Sendable {
    public var allowedGroupIds: [String]
    /// A category here covers the categories inside it.
    public var allowedCategoryIds: [String]
    /// Titles allowed by themselves, whatever their categories. A show's id covers its episodes.
    public var allowedItemIds: [String]
    /// Titles that are never shown, whatever else allows them. A show's id covers its episodes.
    public var blockedItemIds: [String]
    /// Categories whose titles are never shown, also those of the categories inside them and
    /// what they take in by a studio. Blocked wins. A server from before sends none; leaving
    /// it out of a change keeps what is there.
    public var blockedCategoryIds: [String]
    /// The server said which categories are blocked, also when none: then an empty list is
    /// sent back, which unblocks. A server from before never hears of the list.
    public var knowsBlockedCategories: Bool

    public init(
        allowedGroupIds: [String] = [], allowedCategoryIds: [String] = [], allowedItemIds: [String] = [],
        blockedItemIds: [String] = [], blockedCategoryIds: [String] = [], knowsBlockedCategories: Bool = false
    ) {
        self.allowedGroupIds = allowedGroupIds
        self.allowedCategoryIds = allowedCategoryIds
        self.allowedItemIds = allowedItemIds
        self.blockedItemIds = blockedItemIds
        self.blockedCategoryIds = blockedCategoryIds
        self.knowsBlockedCategories = knowsBlockedCategories
    }

    private enum CodingKeys: String, CodingKey {
        case allowedGroupIds, allowedCategoryIds, allowedItemIds, blockedItemIds, blockedCategoryIds
    }

    /// A list that is missing allows nothing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func ids(_ key: CodingKeys) throws -> [String] { try container.decodeIfPresent([String].self, forKey: key) ?? [] }
        allowedGroupIds = try ids(.allowedGroupIds)
        allowedCategoryIds = try ids(.allowedCategoryIds)
        allowedItemIds = try ids(.allowedItemIds)
        blockedItemIds = try ids(.blockedItemIds)
        blockedCategoryIds = try ids(.blockedCategoryIds)
        knowsBlockedCategories = container.contains(.blockedCategoryIds)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(allowedGroupIds, forKey: .allowedGroupIds)
        try container.encode(allowedCategoryIds, forKey: .allowedCategoryIds)
        try container.encode(allowedItemIds, forKey: .allowedItemIds)
        try container.encode(blockedItemIds, forKey: .blockedItemIds)
        if knowsBlockedCategories || !blockedCategoryIds.isEmpty {
            try container.encode(blockedCategoryIds, forKey: .blockedCategoryIds)
        }
    }
}

/// Decides what of the library a kids viewer may watch: the rule the server has too
/// (`apps/server/src/kids/limits.ts`), for a device that holds the whole catalogue.
///
/// Blocked wins, by the title (or its show or season) and by a category (or the one it is
/// inside of). Then a title is allowed by its own id, by one of its categories or the one that
/// is inside of, or by the group one of its categories is in. A category that takes a title in
/// by its studios allows it only by itself or its parent, never by its group. Nothing allowed
/// is nothing.
public struct KidsFilter: Sendable {
    private let blocked: Set<String>
    private let allowedItems: Set<String>
    private let allowedCategories: Set<String>
    private let blockedCategories: Set<String>
    private let allowedGroupCategories: Set<String>
    private let groups: CategoryGroups
    private let idsByName: [String: String]
    /// The main part is allowed, and with it titles that are in no category.
    private let allowsUncategorised: Bool

    public init(_ settings: KidsSettings, groups: CategoryGroups) {
        self.groups = groups
        blocked = Set(settings.blockedItemIds)
        allowedItems = Set(settings.allowedItemIds)
        idsByName = groups.idsByName
        let allowedGroups = groups.groups.filter { settings.allowedGroupIds.contains($0.id) }
        allowedCategories = Set(settings.allowedCategoryIds)
        blockedCategories = Set(settings.blockedCategoryIds)
        allowedGroupCategories = Set(allowedGroups.flatMap { $0.entries.map(\.id) })
        allowsUncategorised = allowedGroups.contains { $0.name == nil }
    }

    /// Whether a film, episode, home video or extra may be watched. Shows and seasons follow
    /// from what is in them.
    public func allows(_ item: Item, in catalogue: Catalogue) -> Bool {
        let line = Self.line(of: item, in: catalogue)
        if line.contains(where: { blocked.contains($0.id) }) { return false }
        let own = ownCategories(of: item, line: line)
        let ruled = Set(line.last?.ruleCategoryIds ?? [])
        if own.union(ruled).contains(where: { named($0, in: blockedCategories) }) { return false }
        // An extra belongs to its film: without the film there is nowhere to show it.
        if item.kind == .extra, let film = catalogue.parent(of: item), film.kind == .movie, !allows(film, in: catalogue) {
            return false
        }
        if line.contains(where: { allowedItems.contains($0.id) }) { return true }
        if ruled.contains(where: { named($0, in: allowedCategories) }) { return true }
        return allows(own)
    }

    /// Whether its categories alone allow it: what single titles are the exceptions to.
    public func allowsCategories(of item: Item, in catalogue: Catalogue) -> Bool {
        let line = Self.line(of: item, in: catalogue)
        let own = ownCategories(of: item, line: line)
        let ruled = Set(line.last?.ruleCategoryIds ?? [])
        if own.union(ruled).contains(where: { named($0, in: blockedCategories) }) { return false }
        return ruled.contains { named($0, in: allowedCategories) } || allows(own)
    }

    private func allows(_ own: Set<String>) -> Bool {
        own.isEmpty ? allowsUncategorised : own.contains { named($0, in: allowedCategories) || allowedGroupCategories.contains($0) }
    }

    private func ownCategories(of item: Item, line: [Item]) -> Set<String> {
        var categories = groups.categoryIDs(of: item, byName: idsByName)
        if item.categoryIds == nil, categories.isEmpty {
            // Fetched before categories had ids, when only the show named them.
            for above in line.dropFirst() {
                categories.formUnion(groups.categoryIDs(of: above, byName: idsByName))
            }
        }
        return categories
    }

    /// A category is named by itself or by the one it is inside of.
    private func named(_ id: String, in ids: Set<String>) -> Bool {
        ids.contains(id) || groups.category(id: id)?.parentId.map(ids.contains) == true
    }

    /// The item and what it belongs to: an episode's season and show.
    private static func line(of item: Item, in catalogue: Catalogue) -> [Item] {
        var line = [item]
        while let parent = catalogue.parent(of: line[line.count - 1]), line.count < 8, !line.contains(where: { $0.id == parent.id }) {
            line.append(parent)
        }
        return line
    }
}

extension Catalogue {
    /// What a kids viewer may watch of it: the films and episodes the rule allows, and the
    /// seasons and shows they belong to. A show without any such episode is left out, and so
    /// is a file that also holds something the viewer may not watch.
    public func limited(to kids: KidsSettings, groups: CategoryGroups) -> Catalogue {
        let filter = KidsFilter(kids, groups: groups)
        let above: Set<ItemKind> = [.show, .season]
        var allowed: Set<String> = []
        var refusedAssets: Set<String> = []
        for item in items where !above.contains(item.kind) {
            if filter.allows(item, in: self) {
                allowed.insert(item.id)
            } else {
                refusedAssets.formUnion(item.files.map(\.assetId))
            }
        }
        return Catalogue(items: limited(to: allowed).items.map { item in
            var item = item
            item.files.removeAll { refusedAssets.contains($0.assetId) }
            return item
        })
    }
}
