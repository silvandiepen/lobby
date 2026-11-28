// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// The top of a page, from edge to edge: two to four titles that can be played now, one after
/// the other.
struct BannerView: View {
    let state: BannerState
    let size: CGSize
    /// What the window's or screen's own bars cover.
    let topInset: CGFloat
    /// The category's or group's own mark, over the words.
    var look: CategoryLook? = nil

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var scheme
    @Environment(\.motion) private var motion
    @State private var isHovered = false
    /// Back to false by itself, also when the page takes the touch to scroll.
    @GestureState private var isTouched = false
    @FocusState private var hasKeys: Bool

    private var isCompact: Bool { sizeClass != .regular }

    var body: some View {
        ZStack(alignment: isCompact ? .bottom : .bottomLeading) {
            BannerBackdrop(state: state, size: size, isCompact: isCompact)
                .environment(\.colorScheme, scheme)
            words
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .bottomTrailing) {
            if !isCompact {
                BannerDots(state: state)
                    .padding(.trailing, AppTheme.Space.l)
                    .padding(.bottom, Self.foot + 22)
            }
        }
        .overlay { if isHovered { arrows } }
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .simultaneousGesture(swipe)
        #if os(macOS)
        .onHover { isHovered = $0 }
        .focusable(state.slides.count > 1)
        .focusEffectDisabled()
        .focused($hasKeys)
        .onTapGesture { hasKeys = true }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        #else
        .onHover { isHovered = $0 }
        #endif
        .advancesBanner(state, isHeld: isHovered || isTouched)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("banner")
    }

    /// How high the part is that runs into the page, under the words.
    static let foot: CGFloat = 64

    /// The banner's height in a page of this size, with what the bars cover.
    static func height(in page: CGSize, topInset: CGFloat, isCompact: Bool) -> CGFloat {
        let whole = page.height + topInset
        if isCompact {
            // A phone on its side has little height: there it is most of it.
            return page.width > page.height ? max(300, whole * 0.86) : min(max(420, whole * 0.6), page.width * 1.5)
        }
        return min(max(400, whole * 0.64), max(400, page.width * 0.6))
    }

    private func step(_ by: Int) {
        withAnimation(motion.slideChange) { state.step(by) }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .updating($isTouched) { _, isTouched, _ in isTouched = true }
            .onEnded { value in
                let across = value.translation.width
                guard abs(across) > 44, abs(across) > 1.6 * abs(value.translation.height) else { return }
                step(across < 0 ? 1 : -1)
            }
    }

    // MARK: The words

    private var words: some View {
        ZStack(alignment: isCompact ? .bottom : .bottomLeading) {
            if let slide = state.current {
                SlideWords(slide: slide, look: look, isCompact: isCompact, dots: isCompact ? state : nil)
                    .id(slide.id)
                    .transition(Motion.wordChange)
            }
        }
        .padding(.horizontal, isCompact ? AppTheme.Space.l : AppTheme.Space.l)
        .padding(.bottom, isCompact ? 26 : Self.foot)
        .padding(.top, topInset)
        .frame(maxWidth: isCompact ? .infinity : min(620, max(380, size.width * 0.56)), alignment: isCompact ? .bottom : .bottomLeading)
    }

    // MARK: Arrows

    private var arrows: some View {
        HStack {
            arrow("chevron.backward", "Previous", -1)
            Spacer()
            arrow("chevron.forward", "Next", 1)
        }
        .padding(.horizontal, AppTheme.Space.s)
        .opacity(state.slides.count > 1 && !isCompact ? 1 : 0)
        .transition(.opacity.animation(motion.animation(.hover)))
        // VoiceOver goes through the slides at the dots.
        .accessibilityHidden(true)
    }

    private func arrow(_ symbol: String, _ name: String, _ by: Int) -> some View {
        Button { step(by) } label: {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.lobbyOnArtwork)
                .frame(width: 38, height: 64)
                .contentShape(Rectangle())
                .shadow(color: .black.opacity(0.6), radius: 6)
        }
        .buttonStyle(.lobbyIcon)
        .help(name)
    }
}

/// The pictures of a banner with their edges: dark where the words are, and their foot running
/// into the page's own colours, which are the picture's.
struct BannerBackdrop: View {
    let state: BannerState
    let size: CGSize
    let isCompact: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        BannerPictures(state: state, size: size)
            .overlay { scrim }
            .parallaxHeader(height: size.height)
            // Over the picture's movement: its foot runs into the page wherever it is.
            .mask { fade }
            .extendsUnderSidebar()
    }

    @ViewBuilder
    private var scrim: some View {
        let dark = Color.lobbyArtworkScrim
        if isCompact {
            LinearGradient(
                stops: [
                    .init(color: dark.opacity(0.35), location: 0), .init(color: dark.opacity(0), location: 0.2),
                    .init(color: dark.opacity(0), location: 0.34), .init(color: dark.opacity(0.42), location: 0.58), .init(color: dark.opacity(0.72), location: 0.86),
                    .init(color: dark.opacity(0.6), location: 1),
                ], startPoint: .top, endPoint: .bottom)
        } else {
            LinearGradient(
                stops: [
                    .init(color: dark.opacity(0.74), location: 0), .init(color: dark.opacity(0.5), location: 0.26),
                    .init(color: dark.opacity(0), location: 0.62),
                ], startPoint: .leading, endPoint: .trailing)
            LinearGradient(
                stops: [.init(color: dark.opacity(0.4), location: 0), .init(color: dark.opacity(0), location: 0.2)],
                startPoint: .top, endPoint: .bottom)
        }
    }

    /// The picture runs into the page's own colours, which are the picture's.
    private var fade: some View {
        // Into a light page it goes late and fast: the words over it are white.
        let isDark = scheme == .dark
        return LinearGradient(
            stops: [
                .init(color: .black, location: 0), .init(color: .black, location: isDark ? 0.72 : 0.84),
                .init(color: .black.opacity(0.55), location: isDark ? 0.88 : 0.94), .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            // Where the picture is pulled out above its frame.
            .overlay(alignment: .top) { Color.black.frame(height: 600).offset(y: -600) }
    }
}

/// One title on a banner: why it is there, its name, and what can be done with it.
private struct SlideWords: View {
    let slide: BannerSlide
    let look: CategoryLook?
    let isCompact: Bool
    /// On a phone the dots are under the buttons.
    let dots: BannerState?

    @Environment(AppModel.self) private var app
    @ScaledMetric(relativeTo: .largeTitle) private var wideSize: CGFloat = 58
    @ScaledMetric(relativeTo: .largeTitle) private var compactSize: CGFloat = 42

    var body: some View {
        VStack(alignment: isCompact ? .center : .leading, spacing: 0) {
            if let look, look.logo != nil {
                CategoryMark(look: look, area: 3_000, maxWidth: 130, maxHeight: 36)
                    .foregroundStyle(Color.lobbyOnArtwork)
                    .shadow(color: .black.opacity(0.5), radius: 8)
                    .padding(.bottom, AppTheme.Space.m)
            }
            // A logo above says the category itself.
            Text([look?.logo == nil ? slide.place : nil, slide.kicker].compactMap { $0 }.joined(separator: " · "))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.lobbyKicker)
                .shadow(color: .black.opacity(0.6), radius: 5)
                .padding(.bottom, AppTheme.Space.s)
                .accessibilityIdentifier("banner.kicker")
            TitleLogo(
                title: slide.item.title, logo: slide.logo,
                font: .system(size: min(isCompact ? compactSize : wideSize, 84), weight: .heavy),
                maxWidth: isCompact ? 300 : 400, maxHeight: isCompact ? 100 : 140, alignment: isCompact ? .center : .leading)
                .accessibilityIdentifier("banner.title")
            if !slide.meta.isEmpty {
                Text(slide.meta.joined(separator: "  ·  "))
                    .font(.subheadline.weight(.medium))
                    .opacity(0.88)
                    .padding(.top, AppTheme.Space.m)
            }
            if let line = slide.line, !isCompact {
                Text(line)
                    .font(.title3)
                    .lineLimit(2)
                    .opacity(0.94)
                    .frame(maxWidth: 500, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, AppTheme.Space.s)
            }
            actions
                .padding(.top, AppTheme.Space.l)
            if let dots {
                BannerDots(state: dots)
                    .padding(.top, AppTheme.Space.l)
            }
        }
        .foregroundStyle(Color.lobbyOnArtwork)
        .shadow(color: .black.opacity(0.25), radius: 10)
    }

    private var actions: some View {
        HStack(spacing: AppTheme.Space.m) {
            Button {
                app.play(slide.request)
            } label: {
                Label(slide.playLabel, systemImage: AppSymbol.play)
                    .lineLimit(1)
            }
            .buttonStyle(ProminentButtonStyle())
            .frame(minWidth: 150)
            .fixedSize()
            .accessibilityIdentifier("banner.play")

            if app.canDownload(slide.request.item) || app.downloads[slide.request.item.id] != nil {
                DownloadCircle(item: slide.request.item)
                    .accessibilityIdentifier("banner.download")
            }

            NavigationLink(value: Route.item(slide.item.id)) {
                RoundLabel(symbol: "info")
            }
            .buttonStyle(.lobbyPill)
            .help("More Info")
            .accessibilityLabel("More Info about \(slide.item.title)")
            .accessibilityIdentifier("banner.info")
        }
    }
}

/// A symbol in a circle, on a picture or on a page.
struct RoundLabel: View {
    let symbol: String
    var size: CGFloat = 48
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(scheme == .dark ? Color.lobbyOnArtwork : Color.primary)
            .frame(width: size, height: size)
            .background { RoundFill() }
            .contentShape(Circle())
    }
}

/// What lies behind a round control: light on dark, and the page through it.
struct RoundFill: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            Circle().fill(Color.lobbySurfaceRaised(scheme))
        } else {
            Circle()
                .fill(scheme == .dark ? Color.white.opacity(0.17) : Color.black.opacity(0.07))
                .background(.ultraThinMaterial, in: Circle())
        }
    }
}

extension View {
    /// A page whose picture runs up behind the bars: the system's blur of what scrolls under
    /// them stays off until the picture has gone.
    @ViewBuilder
    func clearTop(_ isClear: Bool) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            scrollEdgeEffectHidden(isClear, for: .top)
        } else {
            self
        }
    }

    /// A picture at the top of a page carries on, mirrored and blurred, under the floating
    /// sidebar and above it, as on Apple's own pages: without it the picture stops at the
    /// sidebar's edge, and the strip over the sidebar is the page's plain colour beside it.
    @ViewBuilder
    func extendsUnderSidebar() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            backgroundExtensionEffect()
        } else {
            self
        }
    }
}
