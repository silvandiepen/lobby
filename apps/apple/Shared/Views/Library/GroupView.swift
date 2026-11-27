// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// A named part of the library as a page.
struct GroupView: View {
    /// The household's id for it.
    let id: String
    @Environment(AppModel.self) private var app

    var body: some View {
        BrowseView(scope: .group(id), title: app.shelves.group(id: id)?.name ?? "", look: app.look(ofGroup: id))
    }
}

/// Everything in one category, under its name or its logo.
struct CategoryPage: View {
    /// `CategoryShelf.id`.
    let id: String
    @Environment(AppModel.self) private var app

    var body: some View {
        let shelf = app.shelves.category(id: id)
        BrowseView(scope: .category(id), title: shelf?.name ?? "Category", look: shelf.map(app.look(of:)) ?? .plain)
    }
}
