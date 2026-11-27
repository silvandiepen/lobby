// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// The library: its places in the system's sidebar, the household's own parts among them.
struct TVLibraryView: View {
    @Environment(AppModel.self) private var app
    @Binding var selection: TVTab

    var body: some View {
        let shelves = app.shelves
        let hasMusic = app.music.isAvailable
        TabView(selection: $selection) {
            ForEach(TVTab.all(for: shelves, hasMusic: hasMusic), id: \.self) { tab in
                Tab(value: tab, role: tab == .search ? .search : nil) {
                    page(tab)
                } label: {
                    TVTabLabel(title: title(tab, shelves), symbol: symbol(tab), viewer: tab == .viewer ? app.activeProfile : nil)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .onAppear { selection = selection.resolved(for: shelves, hasMusic: hasMusic) }
        .onChange(of: shelves) { _, shelves in
            selection = selection.resolved(for: shelves, hasMusic: hasMusic)
        }
        .onChange(of: hasMusic) { _, hasMusic in
            selection = selection.resolved(for: shelves, hasMusic: hasMusic)
        }
        // A play from another device: its title's page is what is behind the player now.
        .onChange(of: app.remoteOpened) { _, opened in
            if opened != nil { selection = .home }
        }
    }

    private func title(_ tab: TVTab, _ shelves: LibraryShelves) -> String {
        switch tab {
        case .search: "Search"
        case .home: "Home"
        case .movies: "Movies"
        case .series: "Series"
        case .group(let id): shelves.group(id: id)?.name ?? ""
        case .viewer: app.activeProfile?.name ?? "Viewer"
        case .music: "Music"
        }
    }

    private func symbol(_ tab: TVTab) -> String {
        switch tab {
        case .search: AppSymbol.search
        case .home: AppSymbol.library
        case .movies: AppSymbol.movies
        case .series: AppSymbol.series
        case .group(let id): AppSymbol.existing(app.look(ofGroup: id).symbol) ?? AppSymbol.group
        case .viewer: AppSymbol.viewers
        case .music: AppSymbol.music
        }
    }

    @ViewBuilder
    private func page(_ tab: TVTab) -> some View {
        switch tab {
        case .search: TVStack { TVSearchView() }
        case .home: TVStack(takesRemotePlays: true) { TVBrowsePage(scope: .home) }
        case .movies: TVStack { TVBrowsePage(scope: .movies, title: "Movies") }
        case .series: TVStack { TVBrowsePage(scope: .series, title: "Series") }
        case .group(let id): TVStack { TVBrowsePage(scope: .group(id), title: app.shelves.group(id: id)?.name ?? "", look: app.look(ofGroup: id)) }
        case .viewer: TVStack { TVViewerPage() }
        case .music: TVMusicPage()
        }
    }
}

/// A place in the sidebar. The viewer's is their picture.
struct TVTabLabel: View {
    let title: String
    let symbol: String
    var viewer: Profile? = nil

    var body: some View {
        if let picture = viewer.flatMap(ProfileAvatar.menuImage) {
            Label { Text(title) } icon: { picture.renderingMode(.original) }
        } else {
            Label(title, systemImage: symbol)
        }
    }
}

/// A navigation stack that knows the library's routes.
struct TVStack<Root: View>: View {
    /// A play from another device opens its title here, in place of what was open.
    var takesRemotePlays = false
    @ViewBuilder var root: Root
    @Environment(AppModel.self) private var app
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            root.navigationDestination(for: Route.self) { TVRouteView(route: $0) }
        }
        .environment(\.tvOpen, TVOpen { path.append($0) })
        .onChange(of: app.remoteOpened) { _, opened in
            // What was open before goes, everywhere; the title that plays is opened in one.
            guard let opened else { return }
            path = takesRemotePlays ? [.item(opened.itemID)] : []
        }
    }
}

/// Opens a page from a button that is not itself a link.
struct TVOpen: Sendable {
    var open: @MainActor @Sendable (Route) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var tvOpen = TVOpen()
}

struct TVRouteView: View {
    let route: Route
    @Environment(AppModel.self) private var app

    var body: some View {
        switch route {
        case .item(let id):
            TVItemPage(itemID: id)
        case .movies:
            TVBrowsePage(scope: .movies, title: "Movies")
        case .series:
            TVBrowsePage(scope: .series, title: "Series")
        case .category(let id):
            let shelf = app.shelves.category(id: id)
            TVBrowsePage(scope: .category(id), title: shelf?.name ?? "", look: shelf.map(app.look(of:)))
        case .group(let id):
            TVBrowsePage(scope: .group(id), title: app.shelves.group(id: id)?.name ?? "", look: app.look(ofGroup: id))
        case .recentlyAdded:
            TVBrowsePage(scope: .home)
        case .viewerStats(let id):
            TVStatsPage(app: app, profileID: id)
        case .person(let id):
            TVPersonPage(personID: id)
        default:
            // The manager's pages: not on the TV, and nothing here leads to one.
            TVDeadEnd(title: "Not on Apple TV", symbol: AppSymbol.television, text: "")
        }
    }
}

/// A page of the library: its banner, and its rows under it.
struct TVBrowsePage: View {
    let scope: BrowseScope
    var title = ""
    var look: CategoryLook? = nil
    @Environment(AppModel.self) private var app
    @State private var keeper = FocusKeeper()
    @State private var banner = BannerState()
    /// The player was opened from this page, not from one on top of it.
    @State private var playedHere = false
    /// Of a category with others inside it: the one shown under the banner. nil: all of it.
    @State private var section: String?

    var body: some View {
        let whole = app.page(scope)
        let chosen = section.flatMap { id in whole.sections.contains { $0.id == id } ? id : nil }
        let page = chosen.map { app.page(scope, section: $0) } ?? whole
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: TVMetrics.shelfGap) {
                        if page.banner.isEmpty {
                            TVConnectionNotice()
                            if !title.isEmpty { heading }
                        } else {
                            TVBanner(state: banner, look: look, insets: proxy.safeAreaInsets) {
                                keeper.forget()
                                playedHere = true
                            } toTop: {
                                withAnimation { scroller.scrollTo(TVBanner.id, anchor: .top) }
                            }
                            .id(TVBanner.id)
                            TVConnectionNotice()
                        }
                        if !whole.sections.isEmpty {
                            TVSectionTabs(sections: whole.sections, selection: $section)
                        }
                        ForEach(page.rows) { row in
                            TVShelf(title: row.title, look: look(of: row)) { tiles(row) }
                                .id(row.id)
                        }
                        if !page.all.isEmpty {
                            TVFilteredTitles(list: scope.tvTitleList, items: page.all, fixed: scope.tvFixedFilters) { TVGrid(items: $0) }
                        }
                    }
                    .padding(.vertical, page.banner.isEmpty ? AppTheme.Space.xl : 0)
                    .padding(.bottom, AppTheme.Space.xl)
                }
                .scrollClipDisabled()
                .onChange(of: app.player == nil) { _, closed in
                    guard closed, playedHere else { return }
                    playedHere = false
                    guard let target = keeper.restore() else { return }
                    scroller.scrollTo(target.shelf, anchor: .center)
                    // While the player still slides away it has the remote: ask again after that,
                    // unless the viewer moved on already.
                    Task {
                        try? await Task.sleep(for: .milliseconds(700))
                        _ = keeper.restore()
                    }
                }
            }
        }
        .bannerBackground(banner, fallback: page.all.isEmpty ? app.shelves.pageColours.map { [$0] } ?? [] : page.all.pageColours)
        .onChange(of: page.banner, initial: true) { _, slides in banner.show(slides) }
        .onChange(of: page, initial: true) { _, page in keeper.rows = TVHome.rows(of: page) }
        .overlay {
            if app.catalogue.isEmpty {
                TVEmptyLibrary()
            } else if scope != .home, page == .empty {
                TVDeadEnd(title: "Nothing here yet", symbol: "film.stack", text: "")
            }
        }
    }

    private var heading: some View {
        LogoOrText(title: title, look: look ?? .plain, area: 24_000, maxWidth: 520, maxHeight: 110) {
            Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
        }
    }

    private func look(of row: BrowseRow) -> CategoryLook? {
        row.groupID.map(app.look(ofGroup:)) ?? row.categoryID.map(app.look(ofCategory:))
    }

    @ViewBuilder
    private func tiles(_ row: BrowseRow) -> some View {
        switch row.content {
        case .continuing(let cards):
            ForEach(cards) { card in
                TVContinueButton(card: card) { playedHere = true }
                    .keepsFocus(keeper, shelf: row.id, item: card.id)
            }
        case .recent(let cards):
            ForEach(cards) { card in
                NavigationLink(value: Route.item(card.detailItemID)) {
                    TVPosterLabel(
                        title: card.title, detail: card.captionLines.joined(separator: " · "), year: card.year,
                        artwork: card.artwork, picture: card.picture)
                }
                .buttonStyle(.borderless)
                .keepsFocus(keeper, shelf: row.id, item: card.id)
                .accessibilityLabel(card.accessibilityLabel)
            }
        case .items(let items):
            ForEach(items) { item in
                TVItemLink(item: item)
                    .keepsFocus(keeper, shelf: row.id, item: item.id)
            }
        case .categories(let categories):
            ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                TVCategoryTile(category: category, tint: NavigationTint.category(app.look(of: category), at: index))
                    .keepsFocus(keeper, shelf: row.id, item: category.id)
            }
        }
    }
}

/// The sections of a category with others inside it: All, then each of those. A click shows
/// one under the banner; the tabs themselves stay where they are.
struct TVSectionTabs: View {
    let sections: [CategoryShelf]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: TVMetrics.gap) {
                tab("All", id: nil)
                ForEach(sections) { tab($0.name, id: $0.id) }
            }
            .padding(.vertical, AppTheme.Space.m)
        }
        .scrollClipDisabled()
        .focusSection()
        .accessibilityIdentifier("sections")
    }

    private func tab(_ name: String, id: String?) -> some View {
        Button {
            selection = id
        } label: {
            Text(name)
                .font(.headline.weight(selection == id ? .bold : .regular))
                .padding(.horizontal, AppTheme.Space.s)
        }
        .buttonStyle(.bordered)
        .tint(selection == id ? Color.lobbyAccent(.dark) : nil)
        .accessibilityAddTraits(selection == id ? .isSelected : [])
        .accessibilityIdentifier("section.\(name)")
    }
}

struct TVGrid: View {
    let items: [Item]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: TVMetrics.poster), spacing: TVMetrics.gap, alignment: .top)],
            alignment: .leading, spacing: TVMetrics.shelfGap
        ) {
            ForEach(items) { TVItemLink(item: $0) }
        }
        .focusSection()
    }
}

/// The server is out of reach: said once, above the library, with a way to look again.
struct TVConnectionNotice: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.serverIsOutOfReach, !app.catalogue.isEmpty {
            HStack(spacing: TVMetrics.gap) {
                TVNotice(
                    symbol: "wifi.slash", tint: Color.lobbyWarning, title: "Lobby Server cannot be reached",
                    text: "This is the library as it was. Lobby keeps looking. Away from home, check that Tailscale is connected.")
                Button {
                    Task { await app.refresh() }
                } label: {
                    TVWorkingLabel(title: "Try Again", symbol: AppSymbol.refresh, isWorking: app.isRefreshing)
                }
            }
            .focusSection()
        }
    }
}

/// Nothing to show: because the library is empty, or because it was never fetched.
struct TVEmptyLibrary: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.serverSetup?.needed == true {
            // Read only here: the setup and the settings are on an iPhone, an iPad or a Mac.
            ContentUnavailableView(
                "Lobby Server is being set up", systemImage: AppSymbol.server,
                description: Text("Finish setting it up on an iPhone, iPad or Mac: its name, its folders and the TMDB key. Films appear here once it has looked through the folders."))
        } else if app.hasLibraryCopy {
            ContentUnavailableView(
                "The library is empty", systemImage: "film.stack",
                description: Text("Films and series appear here a moment after they were copied into the folders Lobby Server watches."))
        } else if app.connectivity == .offline, !app.isRefreshing {
            ContentUnavailableView {
                Label("Lobby Server cannot be reached", systemImage: "wifi.slash")
            } description: {
                Text("The library was not fetched yet. Lobby keeps trying. Away from home, check that Tailscale is connected.")
            } actions: {
                Button("Try Again", systemImage: AppSymbol.refresh) { Task { await app.refresh() } }
            }
        } else {
            WaitedReader { waited in
                ProgressView(Patience.fetchingLibrary(waited: waited, titles: app.wholeCatalogue.itemsByID.count))
            }
        }
    }
}

extension BrowseScope {
    /// The key a list's filters are remembered by: the same as on the other devices.
    var tvTitleList: String {
        switch self {
        case .home: "home"
        case .movies: "movies"
        case .series: "series"
        case .category(let id): "category:\(id)"
        case .group(let id): "group:\(id)"
        }
    }

    var tvFixedFilters: Set<TVFilterPart> {
        switch self {
        case .movies, .series: [.kind]
        case .category: [.category]
        case .home, .group: []
        }
    }
}
