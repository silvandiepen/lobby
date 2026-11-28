// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// A page of the library: its banner from edge to edge, its rows, and what it holds in full.
/// Home, Movies, Series, a category and a part of the library are all this.
struct BrowseView<Choices: View>: View {
    let scope: BrowseScope
    let title: String
    var look: CategoryLook = .plain
    /// The first page of its place, without a Back button. On a phone it has the viewer's
    /// menu at its top, and no bar.
    var isRoot = false
    /// Under the banner: the pills of a phone's Home.
    @ViewBuilder var choices: Choices

    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.motion) private var motion
    @State private var banner = BannerState()
    @State private var titleIsAway = false
    /// Of a category with others inside it: the one shown under the banner. nil: all of it.
    @State private var section: String?

    private var isCompact: Bool { sizeClass != .regular }

    var body: some View {
        let page = app.page(scope)
        let chosen = section.flatMap { id in page.sections.contains { $0.id == id } ? id : nil }
        let shown = chosen.map { app.page(scope, section: $0) } ?? page
        GeometryReader { proxy in
            let inset = proxy.safeAreaInsets.top
            let height = page.banner.isEmpty
                ? 0 : BannerView.height(in: proxy.size, topInset: inset, isCompact: isCompact)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if page.banner.isEmpty {
                        heading.padding(.top, isCompact && isRoot ? AppTheme.Space.s : AppTheme.Space.l)
                    } else {
                        BannerView(
                            state: banner, size: CGSize(width: proxy.size.width, height: height), topInset: inset,
                            look: look)
                    }
                    LazyVStack(alignment: .leading, spacing: AppTheme.Space.shelf) {
                        choices
                        ConnectivityNotice()
                        if !page.sections.isEmpty {
                            SectionChips(sections: page.sections, selection: $section)
                        }
                        BrowseRows(scope: scope, page: shown, listening: scope == .home)
                            .id(chosen)
                        if scope == .home {
                            StoryShelf()
                        }
                        BrowseGrid(scope: scope, items: shown.all, hasRows: !shown.rows.isEmpty)
                            .id(chosen)
                    }
                    .padding(.top, page.banner.isEmpty ? AppTheme.Space.l : isCompact ? AppTheme.Space.xs : 0)
                }
                .padding(.bottom, AppTheme.Space.xl)
            }
            .ignoresSafeArea(edges: page.banner.isEmpty ? [] : .top)
            .clearTop(!page.banner.isEmpty && !titleIsAway)
            .onScrollGeometryChange(for: Bool.self) {
                $0.contentOffset.y + (page.banner.isEmpty ? $0.contentInsets.top : 0) > max(44, height - inset - 60)
            } action: { _, isAway in
                titleIsAway = isAway
            }
            .overlay(alignment: .top) {
                if isCompact, isRoot { bar(hasBanner: !page.banner.isEmpty) }
            }
        }
        .staggersArrival()
        .bannerBackground(banner, fallback: page.all.isEmpty ? app.shelves.pageColours.map { [$0] } ?? [] : page.all.pageColours)
        .onChange(of: page.banner, initial: true) { _, slides in banner.show(slides) }
        // Another choice of the pills is another slideshow.
        .id(scope)
        .navigationTitle(title)
        .modifier(BrowseBar(title: title, look: look, isPlain: isCompact && isRoot, hasBanner: !page.banner.isEmpty, titleIsAway: titleIsAway || page.banner.isEmpty))
    }

    // MARK: Without a banner

    private var heading: some View {
        HStack(alignment: .center) {
            LogoOrText(title: title, look: look, area: 6_000, maxWidth: 240, maxHeight: 56) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                    .shrinksAway()
            }
            Spacer()
            if isCompact, isRoot { ProfileMenu(size: 36) }
        }
        .padding(.horizontal, TileMetrics.margin(sizeClass))
    }

    // MARK: A phone's top

    /// The viewer over the banner, and the page's name once the banner has gone.
    @ViewBuilder
    private func bar(hasBanner: Bool) -> some View {
        ZStack {
            Text(title)
                .font(.headline)
                .opacity(titleIsAway ? 1 : 0)
                .offset(y: titleIsAway || !motion.moves ? 0 : -AppTheme.Space.s)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            if hasBanner {
                HStack {
                    Spacer()
                    ProfileMenu(size: 34)
                }
                .padding(.horizontal, AppTheme.Space.page)
            }
        }
        .padding(.bottom, AppTheme.Space.s)
        .frame(maxWidth: .infinity)
        .background {
            // Takes the page's colour, which may come from its artwork.
            Rectangle().fill(.ultraThinMaterial)
                .mask(LinearGradient(
                    stops: [.init(color: .black, location: 0.8), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea()
                .opacity(titleIsAway ? 1 : 0)
                .allowsHitTesting(false)
        }
        .animation(motion.animation(.change), value: titleIsAway)
    }
}

extension BrowseView where Choices == EmptyView {
    init(scope: BrowseScope, title: String, look: CategoryLook = .plain) {
        self.init(scope: scope, title: title, look: look) { EmptyView() }
    }
}

/// The bar over a page that starts with a picture: nothing but its buttons, until the page's
/// name has scrolled away.
private struct BrowseBar: ViewModifier {
    let title: String
    let look: CategoryLook
    let isPlain: Bool
    let hasBanner: Bool
    let titleIsAway: Bool
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        #if os(macOS)
        content.modifier(PictureToolbar(isOn: hasBanner))
        #else
        content
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isPlain ? .hidden : .automatic, for: .navigationBar)
            .toolbar {
                if !isPlain {
                    ToolbarItem(placement: .principal) {
                        LogoOrText(title: title, look: look, area: 2_400, maxWidth: 170, maxHeight: 32) {
                            Text(title).font(.headline)
                        }
                        .opacity(titleIsAway ? 1 : 0)
                        .animation(motion.animation(.change), value: titleIsAway)
                        // Found by the page's own heading.
                        .accessibilityHidden(!titleIsAway)
                    }
                }
            }
        #endif
    }
}

#if os(macOS)
/// The Mac's toolbar over a picture: its buttons, clear, at the window's right. The sidebar says
/// where this is, and the picture what it is.
struct PictureToolbar: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        content
            .toolbar(removing: isOn ? .title : nil)
            .toolbarBackgroundVisibility(isOn ? .hidden : .automatic, for: .windowToolbar)
    }
}
#endif

// MARK: - Rows

struct BrowseRows: View {
    let scope: BrowseScope
    let page: BrowsePage
    /// Home: the stories to go on with stand under the films to go on with.
    var listening = false

    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.motion) private var motion
    private var metrics = TileMetrics()
    private let musicMetrics = MusicShelfMetrics()

    init(scope: BrowseScope, page: BrowsePage, listening: Bool = false) {
        self.scope = scope
        self.page = page
        self.listening = listening
    }

    var body: some View {
        let listensAfter = listening ? page.rows.firstIndex { if case .continuing = $0.content { true } else { false } } ?? -1 : nil
        if listensAfter == -1 { continueListening }
        ForEach(Array(page.rows.enumerated()), id: \.element.id) { index, row in
            Shelf(title: row.title, note: row.note, look: look(of: row), seeAll: row.seeAll) {
                tiles(row)
            }
            .animation(motion.animation(.list), value: row.titleIDs)
            .arrives(min(index, 5))
            .accessibilityIdentifier("shelf.\(row.id)")
            if listensAfter == index { continueListening }
        }
    }

    private var continueListening: some View {
        ContinueListeningShelf(width: musicMetrics.cover(sizeClass) * 0.85)
            .accessibilityIdentifier("shelf.continueListening")
    }

    private func look(of row: BrowseRow) -> CategoryLook? {
        row.groupID.map(app.look(ofGroup:)) ?? row.categoryID.map(app.look(ofCategory:))
    }

    @ViewBuilder
    private func tiles(_ row: BrowseRow) -> some View {
        switch row.content {
        case .continuing(let cards):
            ForEach(cards) { card in
                ContinueButton(card: card, width: metrics.wide(sizeClass))
                    .edgeEase(.horizontal)
            }
        case .recent(let cards):
            ForEach(cards) { card in
                NavigationLink(value: Route.item(card.detailItemID)) {
                    PosterTile(
                        title: card.title, year: card.year, artwork: card.artwork, picture: card.picture, captionLines: card.captionLines,
                        width: metrics.poster(sizeClass), showsCaption: false)
                }
                .buttonStyle(.lobbyTile(opens: Route.item(card.detailItemID)))
                .edgeEase(.horizontal)
            }
        case .items(let items):
            ItemTiles(items: items, width: metrics.poster(sizeClass), axis: .horizontal, showsCaption: false)
        case .categories(let categories):
            ForEach(Array(categories.enumerated()), id: \.element.id) { _, category in
                NavigationLink(value: Route.category(category.id)) {
                    CategoryTile(category: category, width: metrics.category(sizeClass))
                }
                .buttonStyle(.lobbyTile(opens: Route.category(category.id)))
                .edgeEase(.horizontal)
                .accessibilityIdentifier("tile.category.\(category.name)")
            }
        }
    }
}

// MARK: - All of it

/// Everything on the page, by title, with the filters and order of the list above it.
private struct BrowseGrid: View {
    let scope: BrowseScope
    let items: [Item]
    /// There is more above it: it says what it is.
    let hasRows: Bool

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.motion) private var motion
    private var metrics = TileMetrics()

    init(scope: BrowseScope, items: [Item], hasRows: Bool) {
        self.scope = scope
        self.items = items
        self.hasRows = hasRows
    }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Space.m) {
                if hasRows {
                    Text("All")
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, TileMetrics.margin(sizeClass))
                }
                FilteredTitles(list: scope.titleList, items: items, fixed: scope.fixedFilters) { titles in
                    PosterGridBody(width: metrics.poster(sizeClass)) { width in
                        ItemTiles(items: titles, width: width, axis: .vertical)
                    }
                    .animation(motion.animation(.section), value: titles.map(\.id))
                    .padding(.top, -AppTheme.Space.m)
                }
            }
        } else if scope != .home, !hasRows {
            ContentUnavailableView("Nothing here yet", systemImage: "film.stack")
                .frame(maxWidth: .infinity)
                .padding(.top, AppTheme.Space.xl)
        }
    }
}

extension BrowseScope {
    /// The key a list's filters are remembered by.
    var titleList: String {
        switch self {
        case .home: "home"
        case .movies: "movies"
        case .series: "series"
        case .category(let id): "category:\(id)"
        case .group(let id): "group:\(id)"
        }
    }

    /// What every title of the page has in common.
    var fixedFilters: Set<TitleFilterPart> {
        switch self {
        case .movies, .series: [.kind]
        case .category: [.category]
        case .home, .group: []
        }
    }
}

/// The sections of a category with others inside it: All, then each of those.
struct SectionChips: View {
    let sections: [CategoryShelf]
    @Binding var selection: String?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var scheme
    @Environment(\.motion) private var motion

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: AppTheme.Space.s) {
                chip("All", id: nil)
                ForEach(sections) { chip($0.name, id: $0.id) }
            }
            .padding(.horizontal, TileMetrics.margin(sizeClass))
        }
        .scrollIndicators(.never)
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityIdentifier("sections")
    }

    private func chip(_ name: String, id: String?) -> some View {
        let isSelected = selection == id
        return Button {
            withAnimation(motion.animation(.section)) { selection = id }
        } label: {
            Text(name)
                .font(.headline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.lobbyOnAccent : Color.primary)
                .padding(.horizontal, AppTheme.Space.m + 4)
                .frame(minHeight: 38)
                .background(isSelected ? Color.lobbyAccent(.dark) : Color.lobbyChip(scheme), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.lobbyPill)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("section.\(name)")
    }
}
