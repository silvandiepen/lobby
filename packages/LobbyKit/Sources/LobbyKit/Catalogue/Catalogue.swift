// SPDX-License-Identifier: MPL-2.0
/// The catalogue as the device knows it: every item, and who is whose child.
///
/// A value, so a shelf can be built from a snapshot on any thread while a sync goes on.
public struct Catalogue: Sendable, Equatable {
    public private(set) var itemsByID: [String: Item]
    private var childIDsByParent: [String: [String]]

    public init(items: [Item] = []) {
        itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        childIDsByParent = [:]
        rebuildIndex()
    }

    public var isEmpty: Bool { itemsByID.isEmpty }
    public var count: Int { itemsByID.count }
    public var items: [Item] { Array(itemsByID.values) }

    public func item(_ id: String) -> Item? {
        itemsByID[id]
    }

    public func items(ofKind kind: ItemKind) -> [Item] {
        itemsByID.values.filter { $0.kind == kind }
    }

    /// Direct children, in no particular order. `EpisodeOrder` sorts seasons and episodes.
    public func children(of id: String) -> [Item] {
        (childIDsByParent[id] ?? []).compactMap { itemsByID[$0] }
    }

    /// Children, grandchildren and so on.
    public func descendants(of id: String) -> [Item] {
        var found: [Item] = []
        var visited: Set<String> = [id]
        var queue = [id]
        while let next = queue.popLast() {
            for child in children(of: next) where visited.insert(child.id).inserted {
                found.append(child)
                queue.append(child.id)
            }
        }
        return found
    }

    public func parent(of item: Item) -> Item? {
        item.parentId.flatMap { itemsByID[$0] }
    }

    /// The show an episode, season or extra belongs to. A show is its own show.
    public func show(of item: Item) -> Item? {
        var current: Item? = item
        var visited: Set<String> = []
        while let candidate = current, visited.insert(candidate.id).inserted {
            if candidate.kind == .show { return candidate }
            current = parent(of: candidate)
        }
        return nil
    }

    /// Applies one page of `GET /v1/library`: new and changed items replace what is there, and
    /// removed items go together with everything below them.
    public mutating func apply(_ page: LibraryPage) {
        for id in page.removed {
            for descendant in descendants(of: id) {
                itemsByID[descendant.id] = nil
            }
            itemsByID[id] = nil
        }
        for item in page.items {
            itemsByID[item.id] = item
        }
        rebuildIndex()
    }

    private mutating func rebuildIndex() {
        var index: [String: [String]] = [:]
        for item in itemsByID.values {
            if let parentId = item.parentId {
                index[parentId, default: []].append(item.id)
            }
        }
        // A stable order, so two catalogues with the same items are equal.
        childIDsByParent = index.mapValues { $0.sorted() }
    }
}

extension Catalogue {
    /// The part of the catalogue that can be watched from a set of films and episodes: those
    /// items, and the seasons and shows they belong to. For a device without its server,
    /// where only what was downloaded can play.
    ///
    /// A show keeps only the seasons that hold one of the items, and a season only those
    /// episodes, so the next episode is the next one that is there.
    public func limited(to itemIDs: Set<String>) -> Catalogue {
        var kept: [String: Item] = [:]
        for id in itemIDs {
            var next = itemsByID[id]
            // Up through season and show. A parent chain is two long; the count guards a loop
            // in damaged data.
            var steps = 0
            while let item = next, kept[item.id] == nil, steps < 8 {
                kept[item.id] = item
                next = item.parentId.flatMap { itemsByID[$0] }
                steps += 1
            }
        }
        return Catalogue(items: Array(kept.values))
    }
}

