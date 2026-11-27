// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// Where a manager puts studio suggestions, as they fill it in. Nothing is chosen for them: a
/// suggestion goes nowhere until a place is picked.
struct SuggestionChoice: Hashable, Sendable {
    enum Destination: Hashable, Sendable {
        /// New categories inside a top-level one.
        case inside(categoryID: String)
        /// Their studios join a category's rule: its page shows their titles too.
        case join(categoryID: String)
        /// New top-level categories of a group.
        case newCategory(groupID: String)
    }

    /// The suggestions, in the order they were listed.
    var ids: [String]
    var destination: Destination?
    /// For several new ones: one category for all of them instead of one each.
    var together = false
    /// The name of the one new category; empty keeps the suggested name.
    var name = ""

    /// Starts where a category of the same name is: there it joins, as the server suggests.
    init(_ suggestions: [CategorySuggestions.Suggestion]) {
        ids = suggestions.map(\.id)
        if suggestions.count == 1, let same = suggestions[0].categoryId {
            destination = .join(categoryID: same)
        }
    }

    /// Whether a name is asked for: one new category is made.
    var makesOne: Bool {
        switch destination {
        case .join, nil: false
        case .inside, .newCategory: ids.count == 1 || together
        }
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What is sent; nil until a place is chosen, or while the name is too long.
    var placement: SuggestionPlacement? {
        guard !ids.isEmpty, let destination, trimmedName.count <= 60 else { return nil }
        let name = makesOne && !trimmedName.isEmpty ? trimmedName : nil
        let together = ids.count > 1 && together
        switch destination {
        case .join(let id): return .join(categoryID: id)
        case .inside(let id): return .inside(parentID: id, together: together, name: name)
        case .newCategory(let id): return .newCategory(groupID: id, together: together, name: name)
        }
    }

    /// The top-level categories that can take new ones inside them, by group.
    static func parents(in setup: CategoryGroups) -> [(group: CategoryGroup, categories: [LibraryCategory])] {
        setup.groups.map { group in (group, group.entries.filter { $0.parentId == nil }) }
            .filter { !$0.categories.isEmpty }
    }

    /// What the choice will do, in a sentence for the sheet.
    func summary(in setup: CategoryGroups) -> String? {
        guard let destination else { return nil }
        let several = ids.count > 1
        switch destination {
        case .join(let id):
            let name = setup.category(id: id)?.name ?? "that category"
            return "\(name) shows \(several ? "their" : "its") titles as well. No new category is made."
        case .inside(let id):
            let name = setup.category(id: id)?.name ?? "that category"
            return several && !together
                ? "A category for each, inside \(name)." : "One category inside \(name)."
        case .newCategory(let id):
            let group = setup.group(id: id).map(CategoriesModel.name(of:)) ?? "that group"
            return several && !together ? "A category for each, at the top of \(group)." : "One category at the top of \(group)."
        }
    }
}
