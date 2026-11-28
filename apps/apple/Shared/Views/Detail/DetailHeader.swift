// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// A film's or series' page: its picture from edge to edge, its name and what can be done with
/// it over that, and the rest below in the picture's colours.
struct TitlePage<Actions: View, Content: View>: View {
    let item: Item
    /// "2019", "1 h 42 min".
    let facts: [String]
    /// Play and what stands beside it.
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var titleIsAway = false

    private var isCompact: Bool { sizeClass != .regular }

    var body: some View {
        GeometryReader { proxy in
            let inset = proxy.safeAreaInsets.top
            let height = Self.heroHeight(in: proxy.size, topInset: inset, isCompact: isCompact)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TitleHero(
                        item: item, facts: facts, size: CGSize(width: proxy.size.width, height: height), topInset: inset,
                        isCompact: isCompact
                    ) { actions }
                    // On a phone Play and its actions sit right under the title and its year,
                    // with the summary close below: one block, as on Apple's own pages.
                    if isCompact {
                        VStack(spacing: AppTheme.Space.m) { actions }
                            .frame(maxWidth: 480)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, AppTheme.Space.l)
                            .padding(.top, AppTheme.Space.xs)
                            .padding(.bottom, AppTheme.Space.l)
                            .arrives(1)
                    }
                    LazyVStack(alignment: .leading, spacing: AppTheme.Space.shelf) {
                        content
                    }
                }
                .padding(.bottom, AppTheme.Space.xl)
            }
            .ignoresSafeArea(edges: .top)
            .clearTop(!titleIsAway)
            .onScrollGeometryChange(for: Bool.self) {
                $0.contentOffset.y > height - inset - 90
            } action: { _, isAway in
                titleIsAway = isAway
            }
        }
        .staggersArrival()
        .artworkBackground(item.artwork.pageColours)
        .modifier(TitleBar(title: item.title, titleIsAway: titleIsAway))
    }

    static func heroHeight(in page: CGSize, topInset: CGFloat, isCompact: Bool) -> CGFloat {
        let whole = page.height + topInset
        if isCompact {
            return page.width > page.height ? max(260, whole * 0.8) : min(max(360, whole * 0.54), page.width * 1.35)
        }
        return min(max(420, whole * 0.7), max(420, page.width * 0.62))
    }
}

private struct TitleHero<Actions: View>: View {
    let item: Item
    let facts: [String]
    let size: CGSize
    let topInset: CGFloat
    let isCompact: Bool
    @ViewBuilder var actions: Actions

    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .largeTitle) private var wideSize: CGFloat = 54
    @ScaledMetric(relativeTo: .largeTitle) private var compactSize: CGFloat = 38

    var body: some View {
        ZStack(alignment: isCompact ? .bottom : .bottomLeading) {
            SlidePicture(artwork: item.artwork.backdrop, title: item.title, size: size, grows: false)
                .overlay { scrim }
                .parallaxHeader(height: size.height)
                .mask { fade }
                .extendsUnderSidebar()
                .accessibilityHidden(true)
            VStack(alignment: isCompact ? .center : .leading, spacing: AppTheme.Space.m) {
                TitleLogo(
                    title: item.title, logo: item.artwork.logo,
                    font: .system(size: min(isCompact ? compactSize : wideSize, 80), weight: .heavy),
                    maxWidth: isCompact ? 310 : 440, maxHeight: isCompact ? 110 : 170, lines: 3, alignment: isCompact ? .center : .leading)
                    .accessibilityIdentifier("detail.title")
                    .arrives(0)
                if !facts.isEmpty {
                    Text(facts.joined(separator: "  ·  "))
                        .font(.subheadline.weight(.medium))
                        .opacity(0.9)
                        .multilineTextAlignment(isCompact ? .center : .leading)
                        .shadow(color: .black.opacity(0.6), radius: 5)
                        .arrives(1)
                }
                if !isCompact {
                    if let line = item.tagline, !line.isEmpty {
                        Text(line)
                            .font(.title3)
                            .lineLimit(2)
                            .frame(maxWidth: 520, alignment: .leading)
                            .shadow(color: .black.opacity(0.5), radius: 6)
                            .arrives(1)
                    }
                    VStack(alignment: .leading, spacing: AppTheme.Space.m) { actions }
                        .padding(.top, AppTheme.Space.s)
                        .arrives(2)
                }
            }
            .foregroundStyle(Color.lobbyOnArtwork)
            .padding(.horizontal, AppTheme.Space.l)
            .padding(.bottom, isCompact ? AppTheme.Space.m : 52)
            .padding(.top, topInset)
            .frame(maxWidth: isCompact ? .infinity : min(680, max(420, size.width * 0.62)), alignment: isCompact ? .bottom : .bottomLeading)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var scrim: some View {
        let dark = Color.lobbyArtworkScrim
        LinearGradient(
            stops: [.init(color: dark.opacity(0.4), location: 0), .init(color: dark.opacity(0), location: 0.2)],
            startPoint: .top, endPoint: .bottom)
        if isCompact {
            LinearGradient(
                stops: [
                    .init(color: dark.opacity(0), location: 0.45), .init(color: dark.opacity(0.62), location: 0.86),
                    .init(color: dark.opacity(0.4), location: 1),
                ], startPoint: .top, endPoint: .bottom)
        } else {
            LinearGradient(
                stops: [
                    .init(color: dark.opacity(0.76), location: 0), .init(color: dark.opacity(0.5), location: 0.3),
                    .init(color: dark.opacity(0), location: 0.68),
                ], startPoint: .leading, endPoint: .trailing)
        }
    }

    private var fade: some View {
        // Into a light page it goes late and fast: the words over it are white.
        let isDark = scheme == .dark
        return LinearGradient(
            stops: [
                .init(color: .black, location: 0), .init(color: .black, location: isDark ? 0.74 : 0.84),
                .init(color: .black.opacity(0.55), location: isDark ? 0.9 : 0.94), .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            // Where the picture is pulled out above its frame.
            .overlay(alignment: .top) { Color.black.frame(height: 600).offset(y: -600) }
    }
}

/// The bar over the picture: its buttons, and the page's title once that has scrolled away.
private struct TitleBar: ViewModifier {
    let title: String
    let titleIsAway: Bool
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .navigationTitle(title)
            .modifier(PictureToolbar(isOn: true))
        #else
        content
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .opacity(titleIsAway ? 1 : 0)
                        .offset(y: titleIsAway || !motion.moves ? 0 : AppTheme.Space.s)
                        .animation(motion.animation(.change), value: titleIsAway)
                        // The page has its title already.
                        .accessibilityHidden(true)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// A part of a title's page between its margins.
struct DetailColumn<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.l) {
            content
        }
        .arrives(2)
        .padding(.horizontal, sizeClass == .regular ? AppTheme.Space.l : AppTheme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A round action beside Play. On a phone its word stands under it.
struct RoundAction<Label: View>: View {
    let name: String
    @ViewBuilder var label: Label
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .regular {
            label.help(name)
        } else {
            VStack(spacing: AppTheme.Space.xs + 2) {
                label
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.lobbySecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityHidden(true)
            }
            // A few stand together in the middle; many share the row's width, narrower.
            .frame(minWidth: 60, maxWidth: 88)
        }
    }
}

/// Play, and the round actions: beside it in a wide window, under it on a phone.
struct TitleActions<Circles: View>: View {
    let action: PlayAction
    var label: String? = nil
    @ViewBuilder var circles: Circles
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .regular {
            HStack(alignment: .top, spacing: AppTheme.Space.m) {
                PlayActionView(action: action, label: label, isWide: true)
                circles
            }
        } else {
            VStack(spacing: AppTheme.Space.l) {
                PlayActionView(action: action, label: label)
                // All in one row across the width; with more than fit (large text), the row
                // scrolls rather than cutting the last one off.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 0) { circles }
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: AppTheme.Space.s) { circles }
                            .padding(.horizontal, AppTheme.Space.l)
                    }
                    .scrollIndicators(.hidden)
                    .padding(.horizontal, -AppTheme.Space.l)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// Watched or not, as a round button that changes it.
struct WatchedCircle: View {
    let isWatched: Bool
    let change: (Bool) -> Void
    @Environment(\.motion) private var motion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundAction(name: "Watched") {
            Button { change(!isWatched) } label: {
                Image(systemName: isWatched ? "checkmark" : "eye")
                    .contentTransition(motion.animatesSymbols ? .symbolEffect(.replace) : .opacity)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isWatched ? AnyShapeStyle(Color.lobbyAccent(scheme)) : AnyShapeStyle(.primary))
                    .frame(width: 48, height: 48)
                    .background { RoundFill() }
                    .contentShape(Circle())
            }
            .buttonStyle(.lobbyPill)
            .accessibilityLabel(isWatched ? "Mark as Unwatched" : "Mark as Watched")
            .accessibilityIdentifier("detail.watched")
        }
    }
}

/// Trailer: YouTube's own player in a sheet, or a trailer file in Lobby's player. Several make
/// a menu. Nothing when there is none that can play now.
struct TrailerCircle: View {
    let item: Item
    @Environment(AppModel.self) private var app
    @State private var playing: String?

    var body: some View {
        let trailers = app.trailers(of: item)
        if !trailers.isEmpty {
            RoundAction(name: "Trailer") {
                Group {
                    if trailers.count == 1, let only = trailers.first {
                        Button { open(only) } label: { RoundLabel(symbol: AppSymbol.trailer) }
                    } else {
                        Menu {
                            ForEach(trailers) { trailer in
                                Button(trailer.title) { open(trailer) }
                            }
                        } label: {
                            RoundLabel(symbol: AppSymbol.trailer)
                        }
                        .menuIndicator(.hidden)
                    }
                }
                .buttonStyle(.lobbyPill)
                .accessibilityLabel("Trailer")
                .accessibilityHint("Plays the trailer")
                .accessibilityIdentifier("detail.trailer")
            }
            .sheet(item: Binding(get: { playing.map(TrailerKey.init) }, set: { playing = $0?.key })) { key in
                TrailerSheet(key: key.key, title: item.title)
            }
        }
    }

    private func open(_ trailer: Trailer) {
        switch trailer {
        case .youtube(let key): playing = key
        case .file(let request, _): app.play(request)
        }
    }
}

private struct TrailerKey: Identifiable {
    var key: String
    var id: String { key }
}

/// What kind of film or series it is and where it is kept, as quiet chips. Those with a page
/// of their own lead there.
struct FactChips: View {
    let genres: [String]
    let categories: [String]
    @Environment(AppModel.self) private var app

    var body: some View {
        let shelves = app.shelves
        let all = shelves.categories + shelves.groups.flatMap(\.categories)
        if !genres.isEmpty || !categories.isEmpty {
            FlowLayout(spacing: AppTheme.Space.s) {
                ForEach(genres, id: \.self) { name in
                    chip(name, shelf: all.first { $0.source == .genre && $0.name == name })
                }
                ForEach(categories, id: \.self) { name in
                    chip(name, shelf: all.first { $0.source == .folder && $0.name == name })
                }
            }
        }
    }

    @ViewBuilder
    private func chip(_ name: String, shelf: CategoryShelf?) -> some View {
        if let shelf {
            NavigationLink(value: Route.category(shelf.id)) { FactChip(text: name) }
                .buttonStyle(.lobbyPill)
        } else {
            FactChip(text: name)
        }
    }
}

struct FactChip: View {
    let text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, AppTheme.Space.m)
            .frame(minHeight: 30)
            .background(Color.lobbyChip(scheme), in: Capsule())
            .contentShape(Capsule())
    }
}

/// Words that follow each other and go on to the next line.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let places = places(in: proposal.width ?? .infinity, subviews)
        return CGSize(width: places.map(\.maxX).max() ?? 0, height: places.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, place) in zip(subviews, places(in: bounds.width, subviews)) {
            view.place(at: CGPoint(x: bounds.minX + place.minX, y: bounds.minY + place.minY), proposal: ProposedViewSize(place.size))
        }
    }

    private func places(in width: CGFloat, _ subviews: Subviews) -> [CGRect] {
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0
        return subviews.map { view in
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += height + spacing
                height = 0
            }
            defer {
                x += size.width + spacing
                height = max(height, size.height)
            }
            return CGRect(origin: CGPoint(x: x, y: y), size: size)
        }
    }
}

/// Rows of other titles at the end of a title's page.
struct RelatedRows: View {
    let item: Item
    /// Only the row of this id, or all but it.
    var only: String? = nil
    var except: String? = nil
    @Environment(AppModel.self) private var app

    var body: some View {
        let rows = app.related(to: item).filter { row in only.map { row.id == $0 } ?? true && row.id != except }
        BrowseRows(scope: .home, page: BrowsePage(rows: rows))
    }
}

/// What few want to know, folded away.
struct MoreFacts<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var isOpen = false
    @Environment(\.motion) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.m) {
            Button {
                withAnimation(motion.animation(.section)) { isOpen.toggle() }
            } label: {
                HStack(spacing: AppTheme.Space.s) {
                    Text("Details")
                        .font(.headline)
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .foregroundStyle(.lobbySecondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.lobbyRow)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("detail.facts")
            if isOpen { content }
        }
    }
}

/// The primary button, or the plain reason there is none.
struct PlayActionView: View {
    let action: PlayAction
    /// "Resume S1 E2" on a show. A film uses the action's own words.
    var label: String? = nil
    /// In a wide window the button is as wide as its words.
    var isWide = false

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch action {
        case .play(let request, let kind, let note):
            VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                Button {
                    app.play(request)
                } label: {
                    Label(label ?? kind.words, systemImage: AppSymbol.play)
                }
                .buttonStyle(ProminentButtonStyle())
                .frame(minWidth: isWide ? 190 : nil, maxWidth: isWide ? nil : 480)
                .fixedSize(horizontal: isWide, vertical: false)
                .accessibilityIdentifier("detail.play")
                .accessibilityHint(Self.hint(for: kind))

                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                        .frame(maxWidth: isWide ? 380 : nil, alignment: .leading)
                }
            }
        case .unavailable(let headline, let explanation):
            Label {
                VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                    Text(headline)
                        .font(.headline)
                    Text(explanation)
                        .font(.subheadline)
                        .foregroundStyle(.lobbySecondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color.lobbyWarning)
            }
            .padding(AppTheme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.lobbySurface(scheme), in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("detail.unavailable")
        }
    }

    private static func hint(for kind: PlayAction.Kind) -> String {
        if case .resume(let positionMs) = kind {
            return "Continues from \(MediaFormat.clock(ms: positionMs))"
        }
        return ""
    }
}

/// Where the viewer stopped: a bar and what is left.
struct ResumeLine: View {
    let fraction: Double?
    let remaining: String?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: AppTheme.Space.m) {
            if let fraction {
                ProgressBar(fraction: fraction, track: Color.lobbySurfaceRaised(scheme), fill: Color.lobbyAccent(scheme))
                    .frame(maxWidth: 220)
            }
            if let remaining {
                Text(remaining)
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
                    .accessibilityIdentifier("detail.remaining")
            }
        }
    }
}
