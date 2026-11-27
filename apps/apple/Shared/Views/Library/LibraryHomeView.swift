// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// Home. On a phone it has pills under its banner, which choose between everything, Movies,
/// Series and the household's own parts ("Kids"). In a wide window the sidebar does the
/// choosing and this is always everything.
struct LibraryHomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.motion) private var motion

    private var isCompact: Bool { sizeClass != .regular }

    var body: some View {
        let shelves = app.shelves
        let filter = isCompact ? shelves.resolved(app.libraryFilter) : .all
        BrowseView(scope: filter.scope, title: "Home", isRoot: true) {
            if isCompact { pills(shelves: shelves, selected: filter) }
        }
        .overlay {
            if app.catalogue.isEmpty {
                EmptyLibraryView()
                    .transition(.opacity)
            }
        }
        .animation(motion.animation(.list), value: app.catalogue.isEmpty)
        .refreshable { await app.refresh() }
    }

    private func pills(shelves: LibraryShelves, selected: LibraryFilter) -> some View {
        // A few pills share the width; more than fit scroll sideways.
        ViewThatFits(in: .horizontal) {
            pills(shelves: shelves, selected: selected, fill: true)
            ScrollView(.horizontal) {
                pills(shelves: shelves, selected: selected, fill: false)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func pills(shelves: LibraryShelves, selected: LibraryFilter, fill: Bool) -> some View {
        HStack(spacing: AppTheme.Space.s) {
            ForEach(shelves.filters, id: \.self) { filter in
                FilterPill(title: shelves.title(of: filter), symbol: AppSymbol.filter(filter) { AppSymbol.existing(app.look(ofGroup: $0).symbol) }, isSelected: filter == selected, fills: fill) {
                    withAnimation(motion.animation(.section)) { app.libraryFilter = filter }
                }
            }
        }
        .padding(.horizontal, AppTheme.Space.page)
        .sensoryFeedback(.selection, trigger: selected)
    }
}

extension LibraryFilter {
    var scope: BrowseScope {
        switch self {
        case .all: .home
        case .movies: .movies
        case .series: .series
        case .group(let id): .group(id)
        }
    }
}

/// One choice under the banner. The chosen one has the accent's fill and heavier type: a fill
/// only, never a border.
private struct FilterPill: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    /// Takes its share of the row's width, instead of only what its title needs.
    let fills: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.motion) private var motion

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Space.xs) {
                Image(systemName: symbol)
                    .font(.footnote)
                    .accessibilityHidden(true)
                Text(title)
            }
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.lobbyOnAccent : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, AppTheme.Space.m)
                .frame(minWidth: 72, maxWidth: fills ? .infinity : nil, minHeight: 36)
                .background(
                    isSelected ? Color.lobbyAccent(.dark) : Color.lobbyChip(scheme), in: Capsule())
                .contentShape(Capsule())
                .animation(motion.animation(.change), value: isSelected)
                #if os(iOS)
                // As high as a finger, without looking it.
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                #endif
        }
        .buttonStyle(.lobbyPill)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("filter.\(title)")
    }
}

/// Continue Watching plays at once. A card that cannot play opens its film or show, where the
/// reason is written out.
struct ContinueButton: View {
    let card: ContinueCard
    let width: CGFloat
    @Environment(AppModel.self) private var app

    var body: some View {
        if let request = card.action.request {
            Button {
                app.play(request)
            } label: {
                ContinueCardView(card: card, width: width)
            }
            .buttonStyle(.lobbyTile(opens: Route.item(card.detailItemID)))
            .contextMenu {
                NavigationLink(value: Route.item(card.detailItemID)) {
                    Label("Go to \(card.title)", systemImage: "info.circle")
                }
            }
        } else {
            NavigationLink(value: Route.item(card.detailItemID)) {
                ContinueCardView(card: card, width: width)
            }
            .buttonStyle(.lobbyTile(opens: Route.item(card.detailItemID)))
        }
    }
}

/// A small, calm sign that the Library shows only what is on this device: because the server
/// is out of reach, or because the viewer asked for it.
struct ConnectivityNotice: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if app.showsDownloadedOnly, !app.catalogue.isEmpty {
            let isOffline = app.serverIsOutOfReach
            Label(
                isOffline ? "Offline. Showing what is on this device." : "Showing only what is on this device.",
                systemImage: isOffline ? "wifi.slash" : "arrow.down.circle")
                .font(.footnote)
                .foregroundStyle(.lobbySecondary)
                .padding(.vertical, AppTheme.Space.s)
                .padding(.horizontal, AppTheme.Space.m)
                .background(Color.lobbySurface(scheme), in: Capsule())
                .padding(.horizontal, TileMetrics.margin(sizeClass))
                .accessibilityIdentifier(isOffline ? "notice.offline" : "notice.downloadedOnly")
        }
    }
}

/// Nothing to show: because the library is empty, or because it was never fetched.
struct EmptyLibraryView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.hasLibraryCopy, app.showsDownloadedOnly {
            // The library is there, but none of it is on this device.
            ContentUnavailableView {
                Label("Nothing is downloaded", systemImage: "arrow.down.circle")
            } description: {
                Text(app.serverIsOutOfReach
                    ? "Lobby Server is out of reach, and no film or episode is on this device. Download some while you are connected, to watch them anywhere."
                    : "No film or episode is on this device. Turn off Downloaded Only in Settings to see the whole library.")
            } actions: {
                if app.serverIsOutOfReach {
                    Button("Try Again", systemImage: AppSymbol.refresh) {
                        Task { await app.refresh() }
                    }
                }
            }
            .accessibilityIdentifier("library.nothingDownloaded")
        } else if app.hasLibraryCopy {
            ContentUnavailableView {
                Label("The library is empty", systemImage: "film.stack")
            } description: {
                Text("Whoever looks after Lobby Server adds films and series by copying them into the folders it watches. They appear here a moment after the copy is complete.")
            }
            .accessibilityIdentifier("library.empty")
        } else if app.connectivity == .offline {
            ContentUnavailableView {
                Label("Lobby Server cannot be reached", systemImage: "wifi.slash")
            } description: {
                Text("The library was not fetched yet. Check that this device is on the home network or connected to Tailscale.")
            } actions: {
                Button("Try Again", systemImage: AppSymbol.refresh) {
                    Task { await app.refresh() }
                }
            }
        } else {
            ProgressView("Fetching the library…")
        }
    }
}
