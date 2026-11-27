// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// The categories of one group as a manager arranges them: the top-level ones in order, each
/// followed by those inside it, and the arrangements that moving them asks the server for.
/// Pure: the server checks every arrangement again and answers with what it is then.
struct CategoryTree: Hashable, Sendable {
    struct Row: Hashable, Sendable, Identifiable {
        var category: LibraryCategory
        /// The category it is inside of, as far as this group knows it.
        var parentID: String?
        var hasChildren: Bool

        var id: String { category.id }
        var isInside: Bool { parentID != nil }
    }

    let groupID: String
    let rows: [Row]

    /// - Parameter group: Its entries as the server lists them. One inside a category that is
    ///   not in the group (a server from before, or a moment between two changes) stands by itself.
    init(_ group: CategoryGroup) {
        groupID = group.id
        let listed = Set(group.entries.map(\.id))
        let parent: (LibraryCategory) -> String? = { entry in entry.parentId.flatMap { listed.contains($0) ? $0 : nil } }
        let top = group.entries.filter { parent($0) == nil }
        rows = top.flatMap { category -> [Row] in
            let inside = group.entries.filter { parent($0) == category.id }
            return [Row(category: category, parentID: nil, hasChildren: !inside.isEmpty)]
                + inside.map { Row(category: $0, parentID: category.id, hasChildren: false) }
        }
    }

    var topLevel: [Row] { rows.filter { !$0.isInside } }

    func row(_ id: String) -> Row? { rows.first { $0.id == id } }

    func children(of id: String) -> [Row] { rows.filter { $0.parentID == id } }

    /// The top-level categories one can be put inside: not itself, and only when it holds none.
    func parents(for id: String) -> [Row] {
        guard let row = row(id), !row.hasChildren else { return [] }
        return topLevel.filter { $0.id != id && $0.id != row.parentID }
    }

    // MARK: Arrangements

    /// What a drag in the list asks for: the row lands between two others and goes inside the
    /// category those are in. Right under a category that has others inside it, before the
    /// first of those, it goes inside too; anywhere else between two top-level ones it is
    /// top-level. A category with others inside it stays top-level. nil when nothing changes.
    func moving(from offsets: IndexSet, to destination: Int) -> CategoryArrangement? {
        guard offsets.count == 1, let from = offsets.first, rows.indices.contains(from) else { return nil }
        let moved = rows[from]
        let ids = CategoriesModel.moved(rows.map(\.id), from: offsets, to: destination)
        guard let at = ids.firstIndex(of: moved.id) else { return nil }
        let above = at > 0 ? row(ids[at - 1]) : nil
        let below = at + 1 < ids.count ? row(ids[at + 1]) : nil

        let parent: String?
        if moved.hasChildren {
            parent = nil
        } else if let above, let inside = above.parentID {
            parent = inside
        } else if let above, let below, below.parentID == above.id {
            parent = above.id
        } else {
            parent = nil
        }
        func parentAfter(_ id: String) -> String? { id == moved.id ? parent : row(id)?.parentID }
        let siblings = ids.filter { parentAfter($0) == parent }
        let before = rows.filter { $0.parentID == parent }.map(\.id)
        guard parent != moved.parentID || siblings != before else { return nil }

        return CategoryArrangement(
            categories: parent != moved.parentID ? [.init(id: moved.id, parentID: .some(parent))] : [],
            order: [.init(groupID: groupID, parentID: parent, ids: siblings)])
    }

    /// Inside another top-level category, last there.
    func putting(_ id: String, inside parent: String) -> CategoryArrangement? {
        guard parents(for: id).contains(where: { $0.id == parent }) else { return nil }
        return CategoryArrangement(categories: [.init(id: id, parentID: .some(parent))])
    }

    /// Out of the category it is in: top-level, right after that one.
    func takingOut(_ id: String) -> CategoryArrangement? {
        guard let row = row(id), let parent = row.parentID else { return nil }
        var order = topLevel.map(\.id)
        order.insert(id, at: (order.firstIndex(of: parent) ?? order.endIndex - 1) + 1)
        return CategoryArrangement(
            categories: [.init(id: id, parentID: .some(nil))],
            order: [.init(groupID: groupID, parentID: nil, ids: order)])
    }

    /// A new category with some top-level ones inside it, where the first of them was.
    ///
    /// - Parameters:
    ///   - names: New names for some of those, by id: the old name can then be the new one's.
    ///   - logoFrom: A category whose logo, colour and symbol the new one takes.
    func makingParent(
        named name: String, of ids: [String], renaming names: [String: String] = [:], logoFrom: String? = nil
    ) -> CategoryArrangement? {
        let chosen = topLevel.filter { ids.contains($0.id) && !$0.hasChildren }.map(\.id)
        guard !chosen.isEmpty else { return nil }
        let key = "parent"
        let made = CategoryArrangement.newID(key)
        let look = logoFrom.flatMap(row)?.category
        var order = topLevel.map(\.id).filter { !chosen.contains($0) }
        let place = topLevel.map(\.id).firstIndex(of: chosen[0]).map { index in
            topLevel.prefix(index).filter { !chosen.contains($0.id) }.count
        } ?? order.endIndex
        order.insert(made, at: place)
        return CategoryArrangement(
            create: [.init(
                key: key, groupID: groupID, name: name, icon: look.map(\.icon), color: look.map(\.color),
                logoFrom: look?.id)],
            categories: chosen.map { id in
                let renamed = names[id]?.trimmingCharacters(in: .whitespacesAndNewlines)
                return .init(id: id, name: renamed?.isEmpty == false ? renamed : nil, parentID: .some(made))
            },
            order: [
                .init(groupID: groupID, parentID: nil, ids: order),
                .init(groupID: groupID, parentID: made, ids: chosen),
            ])
    }
}
