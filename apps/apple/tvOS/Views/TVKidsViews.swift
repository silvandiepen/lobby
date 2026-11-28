// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// The app for a kids viewer on the TV: the same sidebar with fewer places, larger pictures and
/// fewer words. Everything on it is in `KidsLibrary`, which holds only what the viewer may watch.
struct TVKidsRootView: View {
    @Environment(AppModel.self) private var app
    @State private var selection = TVTab.home

    var body: some View {
        let screen = app.kidsControl.screen
        let tabs = TVTab.kids(
            for: app.kidsLibrary, listens: app.music.isAvailable,
            onlyListening: screen == .listening && app.kidsControl.now?.at.listening == true)
        @Bindable var player = app.music.player
        TabView(selection: $selection) {
            ForEach(tabs, id: \.self) { tab in
                Tab(value: tab) {
                    page(tab)
                } label: {
                    TVTabLabel(title: title(tab), symbol: symbol(tab), viewer: tab == .viewer ? app.activeProfile : nil)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .environment(\.lobbyIsPlayful, true)
        .preferredColorScheme(.dark)
        .onChange(of: tabs, initial: true) { _, tabs in
            if !tabs.contains(selection) { selection = TVTab.kidsStart(in: tabs) }
        }
        .fullScreenCover(isPresented: $player.showsNowPlaying) {
            TVKidsNowPlaying()
                .environment(app)
        }
    }

    private func title(_ tab: TVTab) -> String {
        switch tab {
        case .movies: "Movies"
        case .series: "Series"
        case .stories: "Stories"
        case .viewer: app.activeProfile.map { $0.name.isEmpty ? "You" : $0.name } ?? "You"
        default: "Home"
        }
    }

    private func symbol(_ tab: TVTab) -> String {
        switch tab {
        case .movies: AppSymbol.movies
        case .series: AppSymbol.series
        case .stories: AppSymbol.stories
        case .viewer: AppSymbol.viewers
        default: AppSymbol.library
        }
    }

    @ViewBuilder
    private func page(_ tab: TVTab) -> some View {
        // When and what: resting, listening or asking shows no films; the child's own page
        // stays, with the way out for grown-ups.
        let screen = app.kidsControl.screen
        if tab == .stories {
            TVKidsStack { TVKidsStories(onlyListening: !screen.showsFilms) }
        } else if !screen.showsFilms, tab != .viewer {
            TVKidsControlPage(screen: screen)
        } else {
            library(tab)
        }
    }

    @ViewBuilder
    private func library(_ tab: TVTab) -> some View {
        switch tab {
        case .movies: TVKidsStack { TVKidsPage(section: .movies) }
        case .series: TVKidsStack { TVKidsPage(section: .series) }
        case .viewer: TVKidsViewerPage()
        default: TVKidsStack { TVKidsPage(section: .home) }
        }
    }
}

/// What the TV shows instead of films when the plan says so, in a child's words.
private struct TVKidsControlPage: View {
    let screen: KidsScreen
    @Environment(AppModel.self) private var app

    private var isAsking: Bool {
        switch screen {
        case .asking(.sending), .asking(.waiting): true
        default: false
        }
    }

    var body: some View {
        VStack(spacing: 40) {
            if let profile = app.activeProfile {
                ProfileAvatar(profile: profile, size: 220)
                    .overlay(alignment: .bottomTrailing) { KidsDoorMark(size: 80).offset(x: 16, y: 8) }
            }
            Text(isAsking ? app.kidsControl.askingText : screen.title).font(.title.weight(.heavy))
            Text(screen.line(now: Date())).font(.title3).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
    }
}

/// Knows the kids' routes and no other: no page of the household can be opened in it.
private struct TVKidsStack<Root: View>: View {
    @ViewBuilder var root: Root
    @State private var path: [KidsRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            root.navigationDestination(for: KidsRoute.self) { route in
                if let story = route.storyID {
                    TVKidsStory(storyID: story)
                } else if let category = route.categoryID {
                    TVKidsPage(section: .home, categoryID: category)
                } else {
                    TVKidsTitle(itemID: route.itemID)
                }
            }
        }
        .environment(\.tvKidsOpen, TVKidsOpen { path.append($0) })
    }
}

private struct TVKidsOpen: Sendable {
    var open: @MainActor @Sendable (KidsRoute) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry fileprivate var tvKidsOpen = TVKidsOpen()
}

/// One of the child's places, or a category.
private struct TVKidsPage: View {
    let section: KidsSection
    var categoryID: String? = nil
    @Environment(AppModel.self) private var app
    @Environment(\.tvKidsOpen) private var tvOpen
    @State private var banner = BannerState()
    @State private var keeper = FocusKeeper()
    @State private var playedHere = false
    /// Of a category with others inside it: the one whose titles the grid shows. nil: all.
    @State private var sectionID: String?

    private struct Row: Identifiable, Equatable {
        var id: String
        var title: String
        var items: [Item]
    }

    var body: some View {
        let library = app.kidsLibrary
        let category = categoryID.flatMap(library.category)
        let slides = categoryID.map { library.categoryBanners[$0] ?? [] } ?? (section == .home ? library.banner : [])
        let shown = Set(slides.map(\.id))
        let cards = categoryID == nil ? self.cards(library).filter { !shown.contains($0.id) } : []
        let sections = category?.subcategories ?? []
        let chosen = sections.first { $0.id == sectionID }
        // A row per section, then everything of the chosen one.
        let rows = categoryID == nil
            ? self.rows(library)
            : chosen != nil ? [] : sections.map { Row(id: "section.\($0.categoryID)", title: $0.name, items: Array($0.items.prefix(12))) }
        let grid = rows.isEmpty || categoryID != nil
            ? (chosen?.items ?? self.items(library, category)).filter { item in !cards.contains { $0.id == item.id } } : []
        let categories = categoryID == nil && section == .home ? library.categories : []
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: TVMetrics.shelfGap) {
                        if slides.isEmpty {
                            Text(category?.name ?? (section == .home ? app.activeProfile?.name ?? "" : section.name))
                                .font(.system(size: 64, weight: .heavy, design: .rounded))
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier("kids.heading")
                        } else {
                            TVBanner(state: banner, look: category.map(app.look(of:)), insets: proxy.safeAreaInsets, isKids: true) {
                                keeper.forget()
                                playedHere = true
                            } toTop: {
                                withAnimation { scroller.scrollTo(TVBanner.id, anchor: .top) }
                            } open: {
                                tvOpen.open(KidsRoute(itemID: $0.item.id))
                            }
                            .id(TVBanner.id)
                        }
                        if !cards.isEmpty {
                            TVShelf(title: "Continue") {
                                ForEach(cards) { card in
                                    TVKidsWide(title: card.title, artwork: card.artwork, tint: card.tintTitle, fraction: card.fraction) {
                                        guard let request = card.action.request else { return }
                                        playedHere = true
                                        app.play(request)
                                    }
                                    .keepsFocus(keeper, shelf: "continue", item: card.id)
                                    .accessibilityLabel(card.accessibilityLabel)
                                }
                            }
                            .id("continue")
                        }
                        if !sections.isEmpty {
                            TVSectionTabs(sections: sections, selection: $sectionID)
                        }
                        if !categories.isEmpty {
                            TVShelf(title: "") {
                                ForEach(Array(categories.enumerated()), id: \.element.id) { index, one in
                                    NavigationLink(value: KidsRoute(categoryID: one.id)) {
                                        TVCategoryLabel(category: one, tint: NavigationTint.category(app.look(of: one), at: index))
                                    }
                                    .buttonStyle(.card)
                                    .accessibilityLabel(one.name)
                                }
                            }
                        }
                        ForEach(rows) { row in
                            TVShelf(title: row.title) {
                                ForEach(row.items) { TVKidsLink(item: $0) }
                            }
                        }
                        if grid.count >= 6 {
                            TVFilteredTitles(list: "kids:\(categoryID.map { "category:\($0)" } ?? section.rawValue)", items: grid) {
                                kidsGrid($0)
                            }
                        } else if !grid.isEmpty {
                            kidsGrid(grid)
                        }
                    }
                    .padding(.vertical, slides.isEmpty ? AppTheme.Space.xl : 0)
                    .padding(.bottom, AppTheme.Space.xl)
                }
                .scrollClipDisabled()
                .onChange(of: app.player == nil) { _, closed in
                    guard closed, playedHere else { return }
                    playedHere = false
                    guard let target = keeper.restore() else { return }
                    scroller.scrollTo(target.shelf, anchor: .center)
                    Task {
                        try? await Task.sleep(for: .milliseconds(700))
                        _ = keeper.restore()
                    }
                }
            }
        }
        .bannerBackground(banner, fallback: items(library, category).pageColours, kids: true)
        .onChange(of: slides, initial: true) { _, slides in banner.show(slides) }
        .onChange(of: cards.map(\.id), initial: true) { _, ids in keeper.rows = [.init(shelf: "continue", items: ids)] }
        .overlay {
            if slides.isEmpty, cards.isEmpty, rows.isEmpty, grid.isEmpty {
                nothing
            }
        }
    }

    @ViewBuilder
    private var nothing: some View {
        if app.hasLibraryCopy || app.serverIsOutOfReach {
            TVDeadEnd(title: "Nothing here right now", symbol: section.symbol, text: "")
                .accessibilityIdentifier("kids.nothing")
        } else {
            VStack(spacing: 40) {
                KidsDoorMark(size: 160)
                ProgressView()
            }
        }
    }

    private func cards(_ library: KidsLibrary) -> [ContinueCard] {
        switch section {
        case .home: library.continueWatching
        case .series: library.seriesToContinue
        case .stories, .movies, .onHere: []
        }
    }

    /// Rows need a few titles to be rows. Without, Home is a grid.
    private func rows(_ library: KidsLibrary) -> [Row] {
        guard section == .home, categoryID == nil, !library.banner.isEmpty else { return [] }
        return [
            Row(id: "new", title: "New", items: library.new.count >= BrowseBuilder.least ? library.new : []),
            Row(id: "favourites", title: "Favourites", items: library.favourites),
        ].filter { !$0.items.isEmpty }
    }

    private func items(_ library: KidsLibrary, _ category: CategoryShelf?) -> [Item] {
        if categoryID != nil { return category?.items ?? [] }
        return switch section {
        case .home: library.home
        case .movies: library.movies
        case .series: library.series
        case .stories, .onHere: []
        }
    }

    private func kidsGrid(_ items: [Item]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: TVMetrics.kidsPoster), spacing: TVMetrics.gap, alignment: .top)],
            alignment: .leading, spacing: TVMetrics.shelfGap
        ) {
            ForEach(items) { TVKidsLink(item: $0) }
        }
        .focusSection()
    }
}

private struct TVKidsLink: View {
    let item: Item

    var body: some View {
        NavigationLink(value: KidsRoute(itemID: item.id)) {
            TVPosterLabel(
                title: item.title, detail: "", year: nil, artwork: item.artwork.poster, picture: item.artwork.backdrop,
                width: TVMetrics.kidsPoster)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(item.title)
        .accessibilityIdentifier("kids.title.\(item.title)")
    }
}

/// A wide picture with a name that plays at once.
private struct TVKidsWide: View {
    let title: String
    let artwork: Artwork?
    let tint: String
    var fraction: Double? = nil
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            ArtworkView(artwork: artwork, width: 400) { TintField(title: tint) }
                .frame(width: TVMetrics.kidsWide, height: TVMetrics.kidsWide / AppTheme.wideAspect)
                .overlay {
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0.45), .init(color: KidsTheme.scrim, location: 1)],
                        startPoint: .top, endPoint: .bottom)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: AppTheme.Space.m) {
                        Label(title, systemImage: AppSymbol.play)
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let fraction {
                            ProgressBar(fraction: fraction, track: KidsTheme.track, fill: KidsTheme.progress, height: 10)
                        }
                    }
                    .foregroundStyle(KidsTheme.words)
                    .padding(AppTheme.Space.l)
                }
                .clipShape(RoundedRectangle(cornerRadius: KidsTheme.cardRadius, style: .continuous))
                .hoverEffect(.highlight)
        }
        .buttonStyle(.borderless)
    }
}

/// A film or series: its picture, its name, one Play, and a series' episodes as large pictures.
private struct TVKidsTitle: View {
    let itemID: String
    @Environment(AppModel.self) private var app
    @State private var seasonID: String?
    @FocusState private var playIsFocused: Bool

    private static let columns = Array(
        repeating: GridItem(.fixed(TVMetrics.kidsWide), spacing: TVMetrics.gap, alignment: .top), count: 3)

    var body: some View {
        let catalogue = app.kidsLibrary.catalogue
        if let item = catalogue.item(itemID) {
            let show = item.kind == .show
                ? ShowDetail(show: item, catalogue: catalogue, progress: app.progress, context: app.playbackContext) : nil
            page(item, show: show, action: show.map { $0.primary?.action } ?? app.movieDetail(for: item).action)
        } else {
            TVDeadEnd(title: "Nothing here right now", symbol: AppSymbol.library, text: "")
        }
    }

    private func page(_ item: Item, show: ShowDetail?, action: PlayAction?) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppTheme.Space.xl) {
                Spacer(minLength: show == nil ? 380 : 220)
                TitleLogo(
                    title: item.title, logo: item.artwork.logo, font: .system(size: 92, weight: .heavy, design: .rounded),
                    maxWidth: 820, maxHeight: 260, lines: 3)
                    .accessibilityIdentifier("kids.title")
                if let action, let request = action.request {
                    let isResume = if case .play(_, .resume, _) = action { true } else { false }
                    Button { app.play(request) } label: {
                        Label(isResume ? "Resume" : "Play", systemImage: AppSymbol.play).frame(minWidth: 300)
                    }
                    .focused($playIsFocused)
                    .accessibilityIdentifier("kids.play")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusSection()
                }
                if let story = app.story(ofFilm: item) {
                    NavigationLink(value: KidsRoute(storyID: story.id)) {
                        Label("Listen to the story", systemImage: AppSymbol.stories)
                    }
                    .accessibilityIdentifier("kids.film.story")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusSection()
                }
                if let show { episodes(show) }
            }
            .padding(.bottom, AppTheme.Space.xl)
        }
        .scrollClipDisabled()
        .background { TVBackdrop(title: item.title, artwork: item.artwork) }
        .artworkBackground(item.artwork.pageColours, kids: true)
        .defaultFocus($playIsFocused, true)
    }

    @ViewBuilder
    private func episodes(_ show: ShowDetail) -> some View {
        let season = show.seasons.first { $0.id == seasonID ?? show.currentSeasonID } ?? show.seasons.first
        if show.seasons.count > 1 {
            TVShelf(title: "") {
                ForEach(show.seasons) { one in
                    Button(one.name) { seasonID = one.id }
                        .tint(one.id == season?.id ? Color("AccentColor") : nil)
                        .accessibilityAddTraits(one.id == season?.id ? .isSelected : [])
                        .accessibilityIdentifier("kids.season.\(one.name)")
                }
            }
        }
        if let season {
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: TVMetrics.gap) {
                ForEach(season.episodes) { episode in
                    TVKidsWide(
                        title: episode.title, artwork: episode.item.artwork.still ?? show.show.artwork.backdrop, tint: episode.title,
                        fraction: fraction(episode)
                    ) {
                        if let request = episode.action.request { app.play(request) }
                    }
                    .accessibilityLabel([episode.title, episode.watch.label].compactMap { $0 }.joined(separator: ", "))
                    .accessibilityIdentifier("kids.episode.\(episode.item.episodeNumber.map(String.init) ?? episode.title)")
                }
            }
            .focusSection()
        }
    }

    private func fraction(_ episode: ShowDetail.Episode) -> Double? {
        if case .inProgress(let fraction?) = episode.watch { fraction } else { nil }
    }
}

/// The child's own page: their picture, and the way out for a grown-up.
private struct TVKidsViewerPage: View {
    @Environment(AppModel.self) private var app
    @State private var picking: Profile?
    @State private var asks = false
    @FocusState private var pictureIsFocused: Bool

    var body: some View {
        VStack(spacing: AppTheme.Space.xl * 2) {
            if let profile = app.activeProfile {
                ProfileAvatar(profile: profile, size: 320)
                Text(profile.name).font(.system(size: 64, weight: .heavy, design: .rounded))
            }
            VStack(spacing: AppTheme.Space.xl) {
                if let profile = app.activeProfile, app.offersAvatars, !profile.name.isEmpty {
                    Button("Change Picture", systemImage: AppSymbol.picture) { picking = profile }
                        .focused($pictureIsFocused)
                        .accessibilityIdentifier("kids.picture")
                }
                Button("For Grown-ups", systemImage: AppSymbol.secret) { asks = true }
                    .accessibilityIdentifier("kids.grownUps")
            }
            .frame(maxWidth: .infinity)
            .focusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultFocus($pictureIsFocused, true)
        .fullScreenCover(item: $picking) { TVAvatarPicker(app: app, profileID: $0.id) }
        .fullScreenCover(isPresented: $asks) { TVGrownUpGate { asks = false } }
    }
}

/// Four digits that only a grown-up knows, or the words why there is no way out here.
private struct TVGrownUpGate: View {
    let close: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var entry = CodeEntry()
    @State private var answer: KidsCodeCheck?
    @State private var isChecking = false
    /// nil: not known yet.
    @State private var hasCode: Bool?
    @FocusState private var key: Int?

    private static let keys = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]

    /// There is nothing to type: only to read.
    private var isClosed: Bool { app.isBoundToKids || hasCode == false || answer == .noCode || answer == .bound }

    var body: some View {
        VStack(spacing: AppTheme.Space.xl * 1.5) {
            Text("For Grown-ups")
                .font(.system(size: 64, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            if isClosed {
                Text(app.isBoundToKids || answer == .bound ? KidsCodeCheck.boundText : KidsCodeCheck.noCodeText)
                    .font(.headline.weight(.regular))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: TVMetrics.readable)
                    .accessibilityIdentifier("gate.closed")
                Button("Back", action: close)
                    .accessibilityIdentifier("gate.back")
            } else {
                dots
                Text(isChecking ? "Checking…" : answer?.explanation ?? "Type the code for grown-ups.")
                    .font(.headline.weight(.regular))
                    .foregroundStyle(answer == nil || isChecking ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.lobbyWarning))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: TVMetrics.readable)
                    .accessibilityIdentifier("gate.message")
                keypad
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.lobbyBackground(scheme).ignoresSafeArea())
        .task {
            guard !app.isBoundToKids else { return }
            // Not known without the server: the question stands, and its answer says so.
            hasCode = try? await app.hasKidsCode()
        }
        .defaultFocus($key, 5)
    }

    private var dots: some View {
        HStack(spacing: TVMetrics.gap) {
            ForEach(0..<CodeEntry.length, id: \.self) { place in
                Circle()
                    .fill(place < entry.digits.count ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                    .frame(width: 32, height: 32)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Code")
        .accessibilityValue("\(entry.digits.count) of \(CodeEntry.length) digits")
    }

    private var keypad: some View {
        VStack(spacing: AppTheme.Space.l) {
            ForEach(Self.keys, id: \.self) { row in
                HStack(spacing: AppTheme.Space.l) { ForEach(row, id: \.self) { digit($0) } }
            }
            HStack(spacing: AppTheme.Space.l) {
                Button { entry.delete() } label: { Image(systemName: "delete.backward").frame(width: 160) }
                    .accessibilityLabel("Delete")
                    .accessibilityIdentifier("gate.delete")
                digit(0)
                Button(action: close) { Text("Back").frame(width: 160) }
                    .accessibilityIdentifier("gate.back")
            }
        }
        .focusSection()
    }

    private func digit(_ digit: Int) -> some View {
        Button { type(digit) } label: {
            Text(String(digit)).font(.title3.weight(.semibold)).frame(width: 160)
        }
        .focused($key, equals: digit)
        .accessibilityIdentifier("gate.\(digit)")
    }

    private func type(_ digit: Int) {
        guard !isChecking else { return }
        answer = nil
        entry.add(digit)
        guard entry.isComplete else { return }
        isChecking = true
        Task {
            let code = entry.digits
            let answer = await app.leaveKidsMode(code: code)
            isChecking = false
            entry.clear()
            self.answer = answer
            if answer == .confirmed { close() }
        }
    }
}
