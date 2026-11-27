// SPDX-License-Identifier: MPL-2.0
import Foundation

/// How much of a group the sidebar shows: a long group shows its first few and "More…", and any
/// group can be folded away under its heading. What was opened or folded is remembered.
struct SidebarFold: Hashable, Sendable {
    /// A group with more than this shows this many until "More…".
    static let shown = 6

    var folded: Set<String> = []
    var showsAll: Set<String> = []

    /// The categories of a group the sidebar lists, and how many wait behind "More…".
    func visible<Category>(_ categories: [Category], ofGroup id: String) -> (rows: [Category], hidden: Int) {
        if folded.contains(id) { return ([], 0) }
        if showsAll.contains(id) || categories.count <= Self.shown + 1 { return (categories, 0) }
        return (Array(categories.prefix(Self.shown)), categories.count - Self.shown)
    }

    /// Whether the group could show fewer: "Less" then.
    func canShowLess(_ count: Int, ofGroup id: String) -> Bool {
        !folded.contains(id) && showsAll.contains(id) && count > Self.shown + 1
    }

    mutating func toggleFolded(_ id: String) {
        if folded.remove(id) == nil { folded.insert(id) }
    }

    mutating func toggleAll(_ id: String) {
        if showsAll.remove(id) == nil { showsAll.insert(id) }
    }
}
