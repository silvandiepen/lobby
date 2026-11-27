// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// Latest Added in full: films, and one card per season.
struct RecentlyAddedGridView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var metrics = TileMetrics()

    init() {}

    var body: some View {
        PosterGrid(width: metrics.poster(sizeClass)) { width in
            ForEach(app.shelves.recentlyAdded) { card in
                NavigationLink(value: Route.item(card.detailItemID)) {
                    PosterTile(
                        title: card.title, year: card.year, artwork: card.artwork, picture: card.picture, captionLines: card.captionLines,
                        width: width)
                }
                .buttonStyle(.lobbyTile(opens: Route.item(card.detailItemID)))
                .edgeEase(.vertical)
            }
        }
        .background(Color.lobbyBackground(scheme))
        .navigationTitle("Latest Added")
    }
}

/// A scrolling grid of posters: three across on a phone, as many as fit in a wide window.
struct PosterGrid<Content: View>: View {
    let width: CGFloat
    @ViewBuilder var content: (CGFloat) -> Content

    var body: some View {
        ScrollView {
            PosterGridBody(width: width) { content($0) }
        }
    }
}

/// The grid itself, for a page that scrolls more than the grid. In a wide window the posters
/// grow a little to fill the width, so that the gaps are those of a shelf on every page,
/// however many titles there are. The content is given how wide a poster is.
struct PosterGridBody<Content: View>: View {
    let width: CGFloat
    @ViewBuilder var content: (CGFloat) -> Content
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var available: CGFloat = 0

    var body: some View {
        let gap = TileMetrics.gap(sizeClass)
        let count = sizeClass == .regular ? max(1, Int((available + gap) / (width + gap))) : 3
        let poster = sizeClass == .regular ? max(width, ((available + gap) / CGFloat(count) - gap).rounded(.down)) : width
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(poster), spacing: gap, alignment: .top), count: count),
            alignment: .leading, spacing: AppTheme.Space.l
        ) {
            content(poster)
        }
        .arrives(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
        .padding(.horizontal, TileMetrics.margin(sizeClass))
        .padding(.vertical, AppTheme.Space.l)
    }
}

/// The films or shows of one section, as tiles that open them.
struct ItemTiles: View {
    let items: [Item]
    let width: CGFloat
    /// Which way they scroll: along a shelf, or down a grid.
    let axis: Axis
    var showsCaption = true

    var body: some View {
        ForEach(items) { item in
            NavigationLink(value: Route.item(item.id)) {
                PosterTile(item: item, width: width, showsCaption: showsCaption)
            }
            .buttonStyle(.lobbyTile(opens: Route.item(item.id)))
            .edgeEase(axis)
        }
    }
}
