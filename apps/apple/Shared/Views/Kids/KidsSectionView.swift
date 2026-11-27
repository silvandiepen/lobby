// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// One of the four places: the banner on Home, what to go on with, the categories, and posters.
struct KidsSectionView: View {
    let section: KidsSection
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.motion) private var motion
    @State private var banner = BannerState()
    @State private var lead = KidsLead()

    private var isWide: Bool { sizeClass == .regular }

    var body: some View {
        let library = app.kidsLibrary
        let slides = section == .home ? library.banner : []
        // The room there is, whatever is in it: pictures sized from what they make the page
        // themselves would chase their own width.
        GeometryReader { proxy in
            page(library, slides: slides, size: proxy.size, inset: proxy.safeAreaInsets.top)
        }
        .kidsBackground(lead, banner: banner, fallback: items(library, below: []).pageColours)
        .onChange(of: slides, initial: true) { _, slides in banner.show(slides) }
    }

    private func page(_ library: KidsLibrary, slides: [BannerSlide], size: CGSize, inset: CGFloat) -> some View {
        let room = max(200, size.width - 2 * KidsTheme.margin)
        // What is on the banner is not a card under it too.
        let shown = Set(slides.map(\.id))
        let cards = Array(cards(library).filter { !shown.contains($0.id) }.prefix(isWide ? 3 : 4))
        let items = items(library, below: cards)
        return ScrollView {
            VStack(alignment: .leading, spacing: KidsTheme.gap + 10) {
                if slides.isEmpty {
                    heading.padding(.top, inset + AppTheme.Space.m)
                } else {
                    KidsBanner(
                        state: banner,
                        size: CGSize(width: size.width, height: BannerView.height(in: size, topInset: inset, isCompact: !isWide)),
                        topInset: inset)
                        .leads(lead, nil, at: KidsLead.banner)
                        .padding(.bottom, isWide ? -KidsTheme.gap : 0)
                }
                if !cards.isEmpty { continuing(cards, room: room) }
                KidsCategories(categories: categories(library), isWide: isWide)
                if section == .home, hasRows(library) {
                    if library.new.count >= BrowseBuilder.least {
                        KidsRow(title: "New", items: library.new, width: isWide ? 210 : 172)
                            .leads(lead, library.new.first.flatMap { $0.artwork.poster ?? $0.artwork.backdrop }, at: 3)
                    }
                    if !library.favourites.isEmpty {
                        KidsRow(title: "Favourites", items: library.favourites, width: isWide ? 210 : 172)
                            .leads(lead, library.favourites.first.flatMap { $0.artwork.poster ?? $0.artwork.backdrop }, at: 4)
                    }
                } else {
                    // A few titles need no filters.
                    if items.count >= 6 {
                        FilteredTitles(list: "kids:\(section.rawValue)", items: items) { titles in
                            KidsGrid(items: titles, room: room, isWide: isWide, lead: lead, onlyOnDevice: section == .onHere)
                        }
                    } else {
                        KidsGrid(items: items, room: room, isWide: isWide, lead: lead, onlyOnDevice: section == .onHere)
                    }
                }
                if cards.isEmpty, items.isEmpty, slides.isEmpty { nothing }
            }
            .padding(.bottom, KidsTheme.gap)
            .overlay(alignment: .top) { avatar.padding(.top, inset) }
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
        .staggersArrival()
        .animation(motion.animation(.list), value: cards.map(\.id))
        .refreshable { await app.refresh() }
    }

    /// Who this is, quietly: the picture, and on Home the name beside it.
    private var avatar: some View {
        HStack(spacing: AppTheme.Space.m) {
            if section == .home {
                KidsAvatar()
                Text(app.activeProfile?.name ?? "")
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                    .kidsWords()
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("kids.heading")
                Spacer(minLength: 0)
                KidsDoorMark(size: 40)
            } else {
                Spacer(minLength: 0)
                KidsAvatar()
            }
        }
        .padding(.horizontal, KidsTheme.margin)
        .padding(.top, AppTheme.Space.s)
    }

    /// The place's name. On Home the viewer's own stands there.
    private var heading: some View {
        Text(section == .home ? " " : section.name)
            .kidsHeading(42)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .kidsWords()
            .padding(.horizontal, KidsTheme.margin)
            .padding(.trailing, 80)
            .accessibilityHidden(section == .home)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(section == .home ? "" : "kids.heading")
    }

    private func continuing(_ cards: [ContinueCard], room: CGFloat) -> some View {
        let width = isWide ? min(420, (room - KidsTheme.gap) / 2) : room * 0.82
        return ScrollView(.horizontal) {
            HStack(spacing: KidsTheme.gap) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    KidsContinueCard(card: card, width: cards.count == 1 && !isWide ? room : width)
                        .edgeEase(.horizontal)
                        .leads(index == 0 ? lead : nil, card.artwork, at: 1)
                }
            }
            .scrollTargetLayout()
        }
        .modifier(ShelfScrolling(margin: KidsTheme.margin))
        .arrives(0)
    }

    @ViewBuilder
    private var nothing: some View {
        Group {
            if app.hasLibraryCopy || app.serverIsOutOfReach {
                VStack(spacing: AppTheme.Space.m) {
                    KidsDoorMark(size: 96)
                    Text(section == .onHere ? "Nothing is on here yet" : "Nothing here right now")
                        .font(.title.weight(.bold))
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("kids.nothing")
                }
                .kidsWords()
            } else {
                VStack(spacing: AppTheme.Space.l) {
                    KidsDoorMark(size: 96)
                    ProgressView()
                        .controlSize(.large)
                        .tint(KidsTheme.words)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    // MARK: What is in it

    /// Those with something of this place in them. One is no choice.
    private func categories(_ library: KidsLibrary) -> [CategoryShelf] {
        let kinds: Set<ItemKind> = switch section {
        case .home: Shelves.topLevelKinds
        case .movies: [.movie, .personal]
        case .series: [.show]
        case .onHere: []
        }
        let fitting = library.categories.filter { $0.items.contains { kinds.contains($0.kind) } }
        return fitting.count > 1 ? fitting : []
    }

    /// Rows need a few titles to be rows, and the banner over them. Without, Home is a grid.
    private func hasRows(_ library: KidsLibrary) -> Bool {
        !library.banner.isEmpty && (library.new.count >= BrowseBuilder.least || !library.favourites.isEmpty)
    }

    private func cards(_ library: KidsLibrary) -> [ContinueCard] {
        switch section {
        case .home: library.continueWatching
        case .series: library.seriesToContinue
        case .movies, .onHere: []
        }
    }

    /// The posters, without what already stands above them as a card.
    private func items(_ library: KidsLibrary, below cards: [ContinueCard]) -> [Item] {
        let shown = Set(cards.map(\.id))
        let all = switch section {
        case .home: library.home
        case .movies: library.movies
        case .series: library.series
        case .onHere: library.onHere
        }
        return all.filter { !shown.contains($0.id) }
    }
}

extension View {
    /// A heading in the size of the design, which follows the person's text size.
    func kidsHeading(_ size: CGFloat) -> some View {
        modifier(KidsHeading(base: size))
    }
}

/// Large, rounded and heavy, and larger with the person's text size.
private struct KidsHeading: ViewModifier {
    @ScaledMetric private var size: CGFloat

    init(base: CGFloat) {
        _size = ScaledMetric(wrappedValue: base, relativeTo: .largeTitle)
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: .heavy, design: .rounded))
    }
}

/// The viewer's picture or initial. It opens the child's pictures, with a grown-up's way out on
/// that page. With a server that knows no pictures it is the way out itself.
struct KidsAvatar: View {
    @Environment(AppModel.self) private var app
    @State private var choosing: Profile?
    @State private var wantsOut = false

    #if os(macOS)
    private static let hint = "Asks for Touch ID or the password"
    #else
    private static let hint = "Asks for Face ID or the passcode"
    #endif

    var body: some View {
        Button {
            if app.offersAvatars, let profile = app.activeProfile {
                choosing = profile
            } else {
                Task { await app.askToLeaveKidsMode() }
            }
        } label: {
            face
                .frame(width: 60, height: 60)
                .background(KidsTheme.button, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.lobbyPill)
        .accessibilityLabel(app.offersAvatars ? "Your picture" : "For grown-ups")
        .accessibilityHint(app.offersAvatars ? "Choose another picture. The way out for grown-ups is there too." : Self.hint)
        .accessibilityIdentifier("kids.avatar")
        .sheet(item: $choosing) {
            // The question comes when this page is gone: what may follow it is a page too.
            guard wantsOut else { return }
            wantsOut = false
            Task { await app.askToLeaveKidsMode() }
        } content: { profile in
            KidsAvatarPicker(app: app, profileID: profile.id) {
                wantsOut = true
                choosing = nil
            }
        }
    }

    @ViewBuilder
    private var face: some View {
        if let picture = Avatar(id: app.activeProfile?.avatar) {
            AvatarPicture(avatar: picture, size: 60 - 2 * 3)
        } else {
            Text(app.activeProfile.map { $0.name.trimmingCharacters(in: .whitespaces).prefix(1).uppercased() } ?? "")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(KidsTheme.avatar)
        }
    }
}

/// The kids' pictures have a shadow already.
extension ButtonStyle where Self == TileButtonStyle {
    static func kidsTile(opens route: KidsRoute) -> TileButtonStyle {
        TileButtonStyle(opens: AnyHashable(route), lifts: false)
    }

    static var kidsPlayer: TileButtonStyle { TileButtonStyle(lifts: false) }
}

/// A poster, and nothing under it.
struct KidsPoster: View {
    let item: Item
    let width: CGFloat

    var body: some View {
        ArtworkView(artwork: item.artwork.poster, width: width) {
            TitleTile(title: item.title, picture: item.artwork.poster == nil ? item.artwork.backdrop : nil, width: width)
        }
        .frame(width: width, height: width / AppTheme.posterAspect)
        .kidsFrame(radius: KidsTheme.posterRadius)
        .tileArtworkSource(cornerRadius: KidsTheme.posterRadius)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
    }
}

/// Goes on with a film or series at once.
private struct KidsContinueCard: View {
    let card: ContinueCard
    let width: CGFloat
    @Environment(AppModel.self) private var app

    var body: some View {
        Button {
            if let request = card.action.request { app.play(request) }
        } label: {
            ArtworkView(artwork: card.artwork, width: width) {
                TintField(title: card.tintTitle)
            }
            .frame(width: width, height: width / AppTheme.wideAspect)
            .overlay {
                LinearGradient(
                    stops: [.init(color: .clear, location: 0.45), .init(color: KidsTheme.scrim, location: 1)],
                    startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: AppTheme.Space.m) {
                    HStack(spacing: AppTheme.Space.m) {
                        KidsPlayCircle(size: 52)
                        Text(card.title)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(KidsTheme.words)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    if let fraction = card.fraction {
                        ProgressBar(fraction: fraction, track: KidsTheme.track, fill: KidsTheme.progress, height: 8)
                    }
                }
                .padding(KidsTheme.gap)
            }
            .kidsFrame(radius: KidsTheme.cardRadius)
        }
        .buttonStyle(.kidsPlayer)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilityLabel)
        .accessibilityAddTraits([.isButton, .startsMediaSession])
        .accessibilityIdentifier("kids.continue.\(card.title)")
    }
}

/// White, with a play sign.
struct KidsPlayCircle: View {
    var size: CGFloat

    var body: some View {
        Image(systemName: AppSymbol.play)
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(KidsTheme.onPlay)
            // A triangle's middle is left of its box's.
            .offset(x: size * 0.04)
            .frame(width: size, height: size)
            .background(KidsTheme.play, in: Circle())
            .accessibilityHidden(true)
    }
}
