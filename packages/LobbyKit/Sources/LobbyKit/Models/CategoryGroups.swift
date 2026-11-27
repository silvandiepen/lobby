// SPDX-License-Identifier: MPL-2.0
import Foundation

/// `GET /v1/categories`: the household's categories in its own order, by the part of the
/// library they belong to.
///
/// Groups and categories are known by id: a rename or a move never changes one. A server from
/// before categories had ids gives names only; the name is the id then.
public struct CategoryGroups: Codable, Hashable, Sendable {
    /// Counts changes to the setup.
    public var revision: Int
    public var groups: [CategoryGroup]

    /// What a server without the route gives: no parts, every title in the one library.
    public static let none = CategoryGroups(groups: [])

    /// - Parameter logos: By category name, as an older server sends them.
    public init(groups: [CategoryGroup], revision: Int = 0, logos: [String: CategoryLogo] = [:]) {
        self.revision = revision
        self.groups = groups
        giveLogos(logos)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        groups = try container.decode([CategoryGroup].self, forKey: .groups)
        giveLogos(try container.decodeIfPresent([String: CategoryLogo].self, forKey: .logos) ?? [:])
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(revision, forKey: .revision)
        try container.encode(groups, forKey: .groups)
    }

    private enum CodingKeys: String, CodingKey {
        case revision, groups, logos
    }

    private mutating func giveLogos(_ logos: [String: CategoryLogo]) {
        guard !logos.isEmpty else { return }
        for group in groups.indices {
            for entry in groups[group].entries.indices where groups[group].entries[entry].logo == nil {
                groups[group].entries[entry].logo = logos[groups[group].entries[entry].name]
            }
        }
    }

    /// Every category, in the household's order.
    public var categories: [LibraryCategory] { groups.flatMap(\.entries) }

    public func category(id: String) -> LibraryCategory? {
        groups.lazy.flatMap(\.entries).first { $0.id == id }
    }

    public func group(id: String) -> CategoryGroup? {
        groups.first { $0.id == id }
    }

    /// The ids of the categories an item is in. An item fetched before categories had ids
    /// names them; a name nobody listed stands for itself.
    func categoryIDs(of item: Item, byName: [String: String]) -> Set<String> {
        if let ids = item.categoryIds { return Set(ids) }
        return Set(item.categories.map { byName[$0] ?? $0 })
    }

    /// The top-level category it is inside of, or nil for a top-level one or an id nobody listed.
    public func parent(of id: String) -> LibraryCategory? {
        category(id: id)?.parentId.flatMap { category(id: $0) }
    }

    /// The categories inside one, in the household's order.
    public func children(of id: String) -> [LibraryCategory] {
        categories.filter { $0.parentId == id }
    }

    /// The category itself, or the one it is inside of: what a sidebar and tiles show.
    public func topLevelID(of id: String) -> String {
        parent(of: id)?.id ?? id
    }

    /// Every category a title is on the page of: its own, those that follow its studios, and
    /// the ones these are inside of. A title names only its own; the parent comes from here.
    public func pageCategoryIDs(of item: Item) -> Set<String> {
        let own = categoryIDs(of: item, byName: idsByName).union(item.ruleCategoryIds ?? [])
        return own.union(own.compactMap { parent(of: $0)?.id })
    }

    var idsByName: [String: String] {
        Dictionary(categories.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
    }
}

/// A picture that stands for a category or a group (`GET /v1/logos/{id}`).
public struct CategoryLogo: Codable, Hashable, Sendable, Identifiable {
    /// Never changes its picture.
    public var id: String
    public var width: Int
    public var height: Int
    /// Only its shape matters and it is drawn in one colour. An opaque picture is drawn as it is.
    public var transparent: Bool

    public init(id: String, width: Int, height: Int, transparent: Bool = true) {
        self.id = id
        self.width = width
        self.height = height
        self.transparent = transparent
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        transparent = try container.decodeIfPresent(Bool.self, forKey: .transparent) ?? true
    }
}

/// One category, as the household set it up.
public struct LibraryCategory: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// The category it is inside of, one level deep and in the same group. nil for a top-level
    /// one, and always from a server from before categories could be inside another.
    public var parentId: String?
    public var name: String
    /// An SF Symbol's name.
    public var icon: String?
    /// One of the API's colour names.
    public var color: String?
    public var logo: CategoryLogo?
    /// It also takes in the titles of these studios.
    public var rule: CategoryRule?

    public init(
        id: String, parentId: String? = nil, name: String, icon: String? = nil, color: String? = nil,
        logo: CategoryLogo? = nil, rule: CategoryRule? = nil
    ) {
        self.id = id
        self.parentId = parentId
        self.name = name
        self.icon = icon
        self.color = color
        self.logo = logo
        self.rule = rule
    }
}

/// What a category takes in besides its folders and the titles put in it: the films and shows
/// of some studios, as TMDB names them ("company:12", "network:34").
public struct CategoryRule: Codable, Hashable, Sendable {
    public var studioIds: [String]

    public init(studioIds: [String]) {
        self.studioIds = studioIds
    }
}

/// One part of the library and its categories in the household's order.
public struct CategoryGroup: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// nil for the main part of the library.
    public var name: String?
    public var icon: String?
    public var color: String?
    public var logo: CategoryLogo?
    public var entries: [LibraryCategory]

    /// The entries' names, for the same order.
    public var categories: [String] { entries.map(\.name) }

    public init(
        id: String, name: String?, icon: String? = nil, color: String? = nil, logo: CategoryLogo? = nil,
        entries: [LibraryCategory]
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.logo = logo
        self.entries = entries
    }

    /// A group of a server from before categories had ids: the names are the ids.
    public init(name: String?, categories: [String]) {
        self.init(id: name ?? "", name: name, entries: categories.map { LibraryCategory(id: $0, name: $0) })
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? name ?? ""
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        logo = try container.decodeIfPresent(CategoryLogo.self, forKey: .logo)
        if let entries = try container.decodeIfPresent([LibraryCategory].self, forKey: .entries) {
            self.entries = entries
        } else {
            entries = try container.decode([String].self, forKey: .categories).map { LibraryCategory(id: $0, name: $0) }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(color, forKey: .color)
        try container.encodeIfPresent(logo, forKey: .logo)
        try container.encode(entries, forKey: .entries)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, color, logo, entries, categories
    }
}
