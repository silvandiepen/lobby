// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// Where dragged categories would land.
enum CategoryDropTarget: Hashable, Sendable {
    /// Right before or after a category, among those beside it (inside the same one, or top-level).
    case before(String)
    case after(String)
    /// Inside a top-level category, last there.
    case onto(String)
    /// Top-level, last in a group.
    case endOf(group: String)
}

/// Why a drop cannot be made. Shown while dragging, never sent to the server.
enum CategoryDropRefusal: Error, Hashable, Sendable {
    /// Onto itself, or onto one of those being dragged.
    case ontoItself
    /// Inside a category that is inside another: two levels.
    case twoLevels
    /// A category with others inside it cannot go inside another.
    case holdsOthers
    /// A category into one that is inside it.
    case intoOwnChild

    var message: String {
        switch self {
        case .ontoItself: "A category cannot go inside itself."
        case .twoLevels: "Categories go one level deep: this one is inside another already."
        case .holdsOthers: "A category with others inside it stays at the top."
        case .intoOwnChild: "A category cannot go into one that is inside it."
        }
    }
}

/// What a drop of categories asks the server for, worked out from the setup on screen. Pure:
/// the server checks the arrangement again. The rules are the server's (one level, a parent
/// is never inside another, those inside one are in its group), so what it would refuse is
/// refused here first, while dragging.
struct CategoryDrop: Sendable {
    let setup: CategoryGroups

    /// - Parameter ids: What is dragged. One inside a category that is dragged as well goes along
    ///   with that one.
    /// - Returns: The arrangement, nil when nothing would change, or why it cannot be.
    func arrangement(moving ids: [String], to target: CategoryDropTarget) -> Result<CategoryArrangement?, CategoryDropRefusal> {
        let all = setup.categories
        let wanted = Set(ids)
        // In the household's order; one whose parent goes along is carried.
        let dragged = all.filter { wanted.contains($0.id) && !($0.parentId.map(wanted.contains) ?? false) }
        guard !dragged.isEmpty else { return .success(nil) }
        let draggedIDs = Set(dragged.map(\.id))
        let holdsOthers = dragged.contains { one in all.contains { $0.parentId == one.id } }

        let groupID: String
        let parentID: String?
        let index: (_ siblings: [String]) -> Int
        switch target {
        case .onto(let id):
            guard let host = setup.category(id: id), let group = group(of: id) else { return .success(nil) }
            if draggedIDs.contains(id) || wanted.contains(id) { return .failure(.ontoItself) }
            if host.parentId != nil { return .failure(.twoLevels) }
            if holdsOthers { return .failure(.holdsOthers) }
            groupID = group
            parentID = id
            index = { $0.count }
        case .before(let id), .after(let id):
            guard let neighbour = setup.category(id: id), let group = group(of: id) else { return .success(nil) }
            if wanted.contains(id) { return .success(nil) }
            if let parent = neighbour.parentId {
                if wanted.contains(parent) { return .failure(.intoOwnChild) }
                if holdsOthers { return .failure(.holdsOthers) }
            }
            groupID = group
            parentID = neighbour.parentId
            let after = if case .after = target { true } else { false }
            index = { siblings in
                guard let at = siblings.firstIndex(of: id) else { return siblings.endIndex }
                return after ? at + 1 : at
            }
        case .endOf(let group):
            guard setup.group(id: group) != nil else { return .success(nil) }
            groupID = group
            parentID = nil
            index = { $0.count }
        }

        let before = siblings(in: groupID, parent: parentID)
        var order = before.filter { !draggedIDs.contains($0) }
        order.insert(contentsOf: dragged.map(\.id), at: min(index(order), order.count))

        let changes = dragged.compactMap { one -> CategoryArrangement.Change? in
            let from = group(of: one.id)
            guard one.parentId != parentID || from != groupID else { return nil }
            // Inside one, its group follows that one's; at the top, the group is said.
            let movesGroup = parentID == nil && from != groupID
            return .init(id: one.id, groupID: movesGroup ? groupID : nil, parentID: .some(parentID))
        }
        guard !changes.isEmpty || order != before else { return .success(nil) }
        return .success(CategoryArrangement(
            categories: changes, order: [.init(groupID: groupID, parentID: parentID, ids: order)]))
    }

    /// Whether the drop can be made; nil when it can, or when it changes nothing.
    func refusal(moving ids: [String], to target: CategoryDropTarget) -> CategoryDropRefusal? {
        if case .failure(let refusal) = arrangement(moving: ids, to: target) { return refusal }
        return nil
    }

    private func group(of id: String) -> String? {
        setup.groups.first { $0.entries.contains { $0.id == id } }?.id
    }

    /// The ids of a group's top-level categories, or of those inside one, in order.
    private func siblings(in groupID: String, parent: String?) -> [String] {
        guard let group = setup.group(id: groupID) else { return [] }
        let listed = Set(group.entries.map(\.id))
        return group.entries.filter { entry in
            let inside = entry.parentId.flatMap { listed.contains($0) ? $0 : nil }
            return inside == parent
        }.map(\.id)
    }
}

/// Which part of a row a drag is over: the upper quarter places before it, the lower quarter
/// after it, the middle inside it. A row that cannot hold others (one inside another) has no
/// middle: its upper half is before, its lower half after.
enum DropZone {
    static func target(for id: String, y: CGFloat, height: CGFloat, canHold: Bool) -> CategoryDropTarget {
        guard height > 0 else { return .onto(id) }
        let part = y / height
        if canHold {
            if part < 0.25 { return .before(id) }
            if part > 0.75 { return .after(id) }
            return .onto(id)
        }
        return part < 0.5 ? .before(id) : .after(id)
    }
}
