// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// The top of a page on the big screen: two to four titles that play now. They follow each
/// other by themselves while the remote is elsewhere; with the remote on the banner they stand
/// still, and Next goes on.
///
/// The buttons are the same views for every slide: only the words and the picture change, so
/// the remote is never taken away from them.
struct TVBanner: View {
    static let id = "tv.banner"

    let state: BannerState
    let look: CategoryLook?
    let insets: EdgeInsets
    var isKids = false
    /// Called when it starts to play.
    let willPlay: () -> Void
    /// Scrolls the page so that the whole banner is in sight.
    let toTop: () -> Void
    /// What More Info opens. nil: the title's own page.
    var open: ((BannerSlide) -> Void)? = nil

    @Environment(AppModel.self) private var app
    @Environment(\.motion) private var motion
    @Environment(\.tvOpen) private var tvOpen
    @Environment(\.artworkColors) private var colors
    @Environment(\.colorScheme) private var scheme
    @FocusState private var button: Control?

    private enum Control { case play, info, next }
    /// Seven tenths of tvOS's 1080 points.
    private static let height: CGFloat = 756

    private var page: Color { colors.map { Color($0.base) } ?? .lobbyBackground(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.xl) {
            ZStack(alignment: .bottomLeading) {
                if let slide = state.current {
                    words(slide)
                        .id(slide.id)
                        .transition(Motion.wordChange)
                }
            }
            buttons
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(Color.lobbyOnArtwork)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, minHeight: Self.height - insets.top, alignment: .bottomLeading)
        .overlay(alignment: .bottomTrailing) { BannerDots(state: state).padding(.bottom, 64) }
        .background(alignment: .topLeading) { picture }
        .focusSection()
        .advancesBanner(state, isHeld: button != nil)
        .onChange(of: button != nil) { _, isIn in if isIn { toTop() } }
        .accessibilityIdentifier("banner")
    }

    private var picture: some View {
        let size = CGSize(width: 1920, height: Self.height + 60)
        // Laid over in the page's one colour, instead of a mask, which is drawn apart each time.
        return BannerPictures(state: state, size: size)
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.78), location: 0), .init(color: .black.opacity(0.5), location: 0.3),
                        .init(color: .black.opacity(0), location: 0.65),
                    ], startPoint: .leading, endPoint: .trailing)
            }
            .overlay {
                LinearGradient(
                    stops: [.init(color: page.opacity(0), location: 0.62), .init(color: page, location: 1)], startPoint: .top, endPoint: .bottom)
            }
            .offset(x: -insets.leading, y: -insets.top)
            .allowsHitTesting(false)
    }

    private var buttons: some View {
        HStack(spacing: TVMetrics.gap) {
            Button {
                guard let slide = state.current else { return }
                willPlay()
                app.play(slide.request)
            } label: {
                Label(playLabel, systemImage: AppSymbol.play)
                    // As wide for "Resume" as for "Play": nothing moves when the slide changes.
                    .frame(minWidth: 220)
            }
            .focused($button, equals: .play)
            .accessibilityIdentifier("banner.play")
            Button {
                guard let slide = state.current else { return }
                if let open { open(slide) } else { tvOpen.open(.item(slide.item.id)) }
            } label: {
                Label(isKids ? "Look" : "More Info", systemImage: "info.circle")
            }
            .focused($button, equals: .info)
            .accessibilityIdentifier("banner.info")
            if state.slides.count > 1 {
                Button {
                    withAnimation(motion.slideChange) { state.step(1) }
                } label: {
                    Label("Next", systemImage: "chevron.forward")
                }
                .focused($button, equals: .next)
                .accessibilityIdentifier("banner.next")
            }
        }
        .defaultFocus($button, .play)
    }

    private var playLabel: String {
        guard let slide = state.current else { return "Play" }
        return isKids ? (slide.fraction == nil ? "Play" : "Resume") : slide.playLabel
    }

    private func words(_ slide: BannerSlide) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.l) {
            if let look, look.logo != nil {
                CategoryMark(look: look, area: 9_000, maxWidth: 260, maxHeight: 70)
            }
            if !isKids {
                Text([look?.logo == nil ? slide.place : nil, slide.kicker].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.lobbyKicker)
            }
            TitleLogo(
                title: slide.item.title, logo: slide.logo,
                font: .system(size: 92, weight: .heavy, design: isKids ? .rounded : .default), maxWidth: 760, maxHeight: 240)
            if !isKids {
                if !slide.meta.isEmpty {
                    Text(slide.meta.joined(separator: "  ·  ")).font(.callout).opacity(0.9)
                }
                if let line = slide.line {
                    Text(line).font(.headline.weight(.regular)).lineLimit(2).frame(maxWidth: 900, alignment: .leading)
                }
            }
        }
    }
}

extension View {
    /// A tile on a shelf: the page knows when it has the remote, and can give it the remote.
    func keepsFocus(_ keeper: FocusKeeper, shelf: String, item: String) -> some View {
        modifier(KeepsFocus(keeper: keeper, id: TVFocusID(shelf: shelf, item: item)))
    }
}

private struct KeepsFocus: ViewModifier {
    let keeper: FocusKeeper
    let id: TVFocusID
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .onChange(of: isFocused) { _, isIn in
                if isIn { keeper.took(id) } else { keeper.left(id) }
            }
            // Also when it is made only now, because the page scrolled to it.
            .onChange(of: keeper.wanted == id, initial: true) { _, isWanted in
                if isWanted { isFocused = true }
            }
    }
}

/// A page with nothing on it, and the way back: something has the remote.
struct TVDeadEnd: View {
    let title: String
    let symbol: String
    let text: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(text)
        } actions: {
            if isPresented {
                Button("Go Back", systemImage: AppSymbol.back) { dismiss() }
            }
        }
    }
}
