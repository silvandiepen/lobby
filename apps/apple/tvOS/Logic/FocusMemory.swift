// SPDX-License-Identifier: MPL-2.0
/// One thing the remote can be on, on a page of shelves.
struct TVFocusID: Hashable, Sendable {
    var shelf: String
    var item: String
}

/// Where the remote was when the player opened, so that it is there again afterwards.
///
/// What was watched may have moved (Continue Watching puts the newest first) or be gone (it
/// was finished). The same title gets the remote back wherever it is now on its shelf; one
/// that is gone hands it to what took its place.
struct FocusMemory: Hashable, Sendable {
    struct Row: Hashable, Sendable {
        var shelf: String
        var items: [String]
    }

    private var last: TVFocusID?
    private var index = 0

    mutating func remember(_ id: TVFocusID?, in rows: [Row]) {
        last = id
        index = id.flatMap { id in rows.first { $0.shelf == id.shelf }?.items.firstIndex(of: id.item) } ?? 0
    }

    func target(in rows: [Row]) -> TVFocusID? {
        guard let last else { return nil }
        if let row = rows.first(where: { $0.shelf == last.shelf }), !row.items.isEmpty {
            let item = row.items.contains(last.item) ? last.item : row.items[min(index, row.items.count - 1)]
            return TVFocusID(shelf: row.shelf, item: item)
        }
        // The shelf is gone with its last title.
        return rows.first { !$0.items.isEmpty }.map { TVFocusID(shelf: $0.shelf, item: $0.items[0]) }
    }
}
