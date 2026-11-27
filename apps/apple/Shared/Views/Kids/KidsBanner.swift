// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import Observation
import SwiftUI

// What the kids' pages are made of: the regular app's banner, rows and tiles with less on them,
// larger, and pages that follow the pictures on them.

/// Which picture colours a kids page: that of the topmost thing in sight. Read by the page's
/// background only.
@MainActor @Observable
final class KidsLead {
    /// By place on the page, from the top. A place without a picture of its own is the banner's.
    private var inSight: [Int: Artwork?] = [:]
    private(set) var artwork: Artwork?
    static let banner = 0

    func show(_ artwork: Artwork?, at place: Int, isVisible: Bool) {
        inSight[place] = isVisible ? .some(artwork) : nil
        // Nothing far enough in sight: what was stays.
        guard let top = inSight.keys.min() else { return }
        let now = inSight[top] ?? nil
        if now != self.artwork { self.artwork = now }
    }

    func clear() {
        inSight = [:]
        artwork = nil
    }
}

extension View {
    /// Colours the page while it is the topmost thing in sight.
    func leads(_ lead: KidsLead?, _ artwork: Artwork?, at place: Int) -> some View {
        onScrollVisibilityChange(threshold: 0.55) { lead?.show(artwork, at: place, isVisible: $0) }
    }

    /// The page in the colours of what is in sight, or of the banner's slide, or of `fallback`.
    func kidsBackground(_ lead: KidsLead, banner: BannerState, fallback: [Artwork]) -> some View {
        modifier(KidsBackground(lead: lead, banner: banner, fallback: fallback))
    }
}

private struct KidsBackground: ViewModifier {
    let lead: KidsLead
    let banner: BannerState
    let fallback: [Artwork]

    func body(content: Content) -> some View {
        let shown = lead.artwork ?? banner.current?.backdrop
        content.artworkBackground(shown.map { [$0] } ?? fallback, kids: true)
    }
}

/// The top of a kids page, from edge to edge: a few titles, one after the other, each with one
/// Play. A tap on the picture opens its page.
struct KidsBanner: View {
    let state: BannerState
    let size: CGSize
    let topInset: CGFloat
    /// A category's own mark, over the words.
    var look: CategoryLook? = nil

    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.motion) private var motion
    @State private var isHovered = false
    @GestureState private var isTouched = false

    private var isCompact: Bool { sizeClass != .regular }

    var body: some View {
        ZStack(alignment: isCompact ? .bottom : .bottomLeading) {
            Button {
                if let slide = state.current { app.kidsPath.append(KidsRoute(itemID: slide.id)) }
            } label: {
                BannerBackdrop(state: state, size: size, isCompact: isCompact)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.current.map { "About \($0.item.title)" } ?? "")
            .accessibilityIdentifier("kids.banner.open")

            ZStack(alignment: isCompact ? .bottom : .bottomLeading) {
                if let slide = state.current {
                    words(slide)
                        .id(slide.id)
                        .transition(Motion.wordChange)
                }
            }
            .padding(.horizontal, KidsTheme.margin)
            .padding(.bottom, isCompact ? 28 : BannerView.foot)
            .padding(.top, topInset)
            .frame(maxWidth: isCompact ? .infinity : 640, alignment: isCompact ? .bottom : .bottomLeading)
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .bottomTrailing) {
            if !isCompact {
                BannerDots(state: state)
                    .padding(.trailing, KidsTheme.margin)
                    .padding(.bottom, BannerView.foot + 26)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .updating($isTouched) { _, isTouched, _ in isTouched = true }
                .onEnded { value in
                    let across = value.translation.width
                    guard abs(across) > 44, abs(across) > 1.6 * abs(value.translation.height) else { return }
                    withAnimation(motion.slideChange) { state.step(across < 0 ? 1 : -1) }
                })
        .onHover { isHovered = $0 }
        .advancesBanner(state, isHeld: isHovered || isTouched)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kids.banner")
    }

    private func words(_ slide: BannerSlide) -> some View {
        VStack(alignment: isCompact ? .center : .leading, spacing: AppTheme.Space.l + 4) {
            VStack(alignment: isCompact ? .center : .leading, spacing: AppTheme.Space.m) {
                if let look, look.logo != nil {
                    CategoryMark(look: look, area: 5_000, maxWidth: 170, maxHeight: 46)
                        .foregroundStyle(KidsTheme.words)
                }
                TitleLogo(
                    title: slide.item.title, logo: slide.logo, font: .system(size: isCompact ? 46 : 64, weight: .heavy, design: .rounded),
                    maxWidth: isCompact ? 330 : 460, maxHeight: isCompact ? 124 : 170, alignment: isCompact ? .center : .leading)
            }
            .kidsWords()
            .allowsHitTesting(false)
            KidsPlayButton(title: slide.fraction == nil ? "Play" : "Resume") { app.play(slide.request) }
                .accessibilityLabel("\(slide.fraction == nil ? "Play" : "Resume") \(slide.item.title)")
                .accessibilityIdentifier("kids.banner.play")
            if isCompact { BannerDots(state: state) }
        }
    }
}

/// The regular app's Play, larger.
struct KidsPlayButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: AppSymbol.play)
                .font(.title2.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(KidsTheme.onPlay)
                .padding(.horizontal, 44)
                .frame(minHeight: 68)
                .background(KidsTheme.play, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: KidsTheme.shadow, radius: 12, y: 5)
        }
        .buttonStyle(.lobbyPill)
        .accessibilityAddTraits(.startsMediaSession)
    }
}

/// A round control on a page or a picture.
struct KidsRoundButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 60
    var isSpeaking = false
    let action: () -> Void
    @Environment(\.motion) private var motion

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .symbolEffect(.variableColor.iterative, isActive: isSpeaking && motion.animatesSymbols)
                .foregroundStyle(KidsTheme.words)
                .frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
                .background(Color.black.opacity(0.25), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.lobbyPill)
        .accessibilityLabel(label)
    }
}

/// The big round way back.
struct KidsBackButton: View {
    let action: () -> Void

    var body: some View {
        KidsRoundButton(symbol: AppSymbol.back, label: "Back", action: action)
            .accessibilityIdentifier("kids.back")
    }
}

/// The title of a row.
struct KidsRowTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title2.weight(.bold))
            .kidsWords()
            .accessibilityAddTraits(.isHeader)
    }
}

/// A titled row of posters that scrolls sideways.
struct KidsRow: View {
    let title: String
    let items: [Item]
    let width: CGFloat
    var onlyOnDevice = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.m) {
            KidsRowTitle(title: title)
                .padding(.horizontal, KidsTheme.margin)
            ScrollView(.horizontal) {
                // A dozen at most: all of them are there.
                HStack(spacing: KidsTheme.gap) {
                    ForEach(items) { item in
                        KidsPosterLink(item: item, width: width, onlyOnDevice: onlyOnDevice)
                            .edgeEase(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .modifier(ShelfScrolling(margin: KidsTheme.margin))
        }
        .arrives(2)
    }
}

struct KidsPosterLink: View {
    let item: Item
    let width: CGFloat
    var onlyOnDevice = false

    var body: some View {
        let route = KidsRoute(itemID: item.id, onlyOnDevice: onlyOnDevice)
        NavigationLink(value: route) {
            KidsPoster(item: item, width: width)
        }
        .buttonStyle(.kidsTile(opens: route))
        .accessibilityIdentifier("kids.poster.\(item.title)")
    }
}

/// The household's categories that have something for this child, as large tiles in its order.
struct KidsCategories: View {
    let categories: [CategoryShelf]
    let isWide: Bool

    var body: some View {
        if !categories.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: KidsTheme.gap) {
                    ForEach(categories) { category in
                        KidsCategoryTile(category: category, width: isWide ? 250 : 184)
                    }
                }
                .scrollTargetLayout()
            }
            .modifier(ShelfScrolling(margin: KidsTheme.margin))
            .arrives(1)
            .accessibilityIdentifier("kids.categories")
        }
    }
}

/// Opens its page on a tap, and says its name when it is held.
private struct KidsCategoryTile: View {
    let category: CategoryShelf
    let width: CGFloat
    @Environment(AppModel.self) private var app
    @State private var speaker = TitleSpeaker()
    @State private var hasSpoken = false

    var body: some View {
        let route = KidsRoute(categoryID: category.id)
        Button {
            // The end of a long press is not a tap.
            if !hasSpoken { app.kidsPath.append(route) }
            hasSpoken = false
        } label: {
            CategoryTile(category: category, width: width, cornerRadius: KidsTheme.cardRadius, nameFont: .title3.weight(.bold))
                .shadow(color: KidsTheme.shadow, radius: 8, y: 4)
        }
        .buttonStyle(.kidsTile(opens: route))
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            hasSpoken = true
            speaker.say(category.name)
        })
        .accessibilityLabel(category.name)
        .accessibilityAction(named: "Say it") { speaker.say(category.name) }
        .accessibilityIdentifier("kids.category.\(category.name)")
        .onDisappear { speaker.stop() }
    }
}

/// Posters below each other, the topmost row in sight colouring the page.
struct KidsGrid: View {
    let items: [Item]
    let room: CGFloat
    let isWide: Bool
    let lead: KidsLead
    /// The places of its rows on the page come after this one.
    var firstPlace = 10
    var onlyOnDevice = false

    private var columns: Int { isWide ? max(3, Int(room / 240)) : 2 }

    var body: some View {
        let width = ((room - CGFloat(columns - 1) * KidsTheme.gap) / CGFloat(columns)).rounded(.down)
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(width), spacing: KidsTheme.gap), count: columns), spacing: KidsTheme.gap + 2
        ) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                KidsPosterLink(item: item, width: width, onlyOnDevice: onlyOnDevice)
                    .edgeEase(.vertical)
                    .leads(
                        index.isMultiple(of: columns) ? lead : nil, item.artwork.poster ?? item.artwork.backdrop,
                        at: firstPlace + index / columns)
            }
        }
        .padding(.horizontal, KidsTheme.margin)
        .arrives(1)
    }
}

/// A category as a page: its banner, and all of it as big posters.
struct KidsCategoryView: View {
    let categoryID: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var banner = BannerState()
    @State private var lead = KidsLead()
    @State private var speaker = TitleSpeaker()
    /// Of a category with others inside it: the one whose titles the grid shows. nil: all.
    @State private var section: String?

    private var isWide: Bool { sizeClass == .regular }

    var body: some View {
        let library = app.kidsLibrary
        let category = library.category(categoryID)
        let sections = category?.subcategories ?? []
        let chosen = sections.first { $0.id == section }
        let slides = library.categoryBanners[categoryID] ?? []
        GeometryReader { proxy in
            let inset = proxy.safeAreaInsets.top
            ScrollView {
                if let category {
                    VStack(alignment: .leading, spacing: KidsTheme.gap + 4) {
                        if slides.isEmpty {
                            heading(category).padding(.top, inset + 84)
                        } else {
                            KidsBanner(
                                state: banner,
                                size: CGSize(
                                    width: proxy.size.width,
                                    height: BannerView.height(in: proxy.size, topInset: inset, isCompact: !isWide)),
                                topInset: inset, look: app.look(of: category))
                                .leads(lead, nil, at: KidsLead.banner)
                            if app.look(of: category).logo == nil { heading(category) }
                        }
                        if !sections.isEmpty {
                            SectionChips(sections: sections, selection: $section)
                            if chosen == nil {
                                ForEach(sections) { sub in
                                    KidsRow(title: sub.name, items: Array(sub.items.prefix(12)), width: isWide ? 190 : 150)
                                }
                            }
                        }
                        KidsGrid(
                            items: chosen?.items ?? category.items, room: max(200, proxy.size.width - 2 * KidsTheme.margin), isWide: isWide,
                            lead: lead)
                            .id(chosen?.id)
                    }
                    .padding(.bottom, AppTheme.Space.xl)
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .top) {
                HStack {
                    KidsBackButton { dismiss() }
                    Spacer()
                    KidsRoundButton(symbol: AppSymbol.sayIt, label: "Say it", isSpeaking: speaker.isSpeaking) {
                        speaker.say(category?.name ?? "")
                    }
                    .accessibilityHint("Says the name")
                    .accessibilityIdentifier("kids.sayIt")
                }
                .padding(.horizontal, KidsTheme.margin)
                .padding(.top, AppTheme.Space.s)
            }
        }
        .staggersArrival()
        .kidsBackground(lead, banner: banner, fallback: category?.items.pageColours ?? [])
        .kidsWithoutBars()
        .accessibilityAction(.escape) { dismiss() }
        #if os(macOS)
        .onExitCommand { dismiss() }
        #endif
        .onChange(of: slides, initial: true) { _, slides in banner.show(slides) }
        .onChange(of: category == nil) { _, isGone in
            // A manager took it away, or the server went out of reach.
            if isGone { dismiss() }
        }
        .onDisappear { speaker.stop() }
    }

    private func heading(_ category: CategoryShelf) -> some View {
        LogoOrText(title: category.name, look: app.look(of: category), area: 12_000, maxWidth: 240, maxHeight: 64) {
            Text(category.name)
                .kidsHeading(38)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .kidsWords()
        .padding(.horizontal, KidsTheme.margin)
        .accessibilityIdentifier("kids.heading")
    }
}
