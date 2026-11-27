// SPDX-License-Identifier: MPL-2.0
import LobbyKit

/// What the sidebar lists under Movies and Series: the household's own categories of the main
/// library, and the genres.
struct SidebarCategories: Hashable, Sendable {
    /// The household's own, without one that only repeats Movies or Series.
    var own: [CategoryShelf]
    var genres: [CategoryShelf]

    init(categories: [CategoryShelf], movies: [Item], series: [Item]) {
        genres = categories.filter { $0.source == .genre }
        own = categories.filter { shelf in
            shelf.source == .folder && !Self.repeats(shelf, all: movies) && !Self.repeats(shelf, all: series)
        }
    }

    /// Whether a category is what is listed already, by what is in it and never by its name:
    /// nearly everything of the list is in it, and it holds nearly nothing else. Nearly,
    /// because a title or two that landed in the other folder does not make it another list.
    private static func repeats(_ shelf: CategoryShelf, all: [Item]) -> Bool {
        guard !all.isEmpty, !shelf.items.isEmpty else { return false }
        let listed = Set(all.map(\.id))
        let shared = Double(shelf.items.filter { listed.contains($0.id) }.count)
        return shared >= 0.9 * Double(listed.count) && shared >= 0.9 * Double(shelf.items.count)
    }
}
