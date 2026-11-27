// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import Observation
import SwiftUI

// What every banner is made of, on every platform: the pictures that follow each other, the
// dots, and the words over them.

/// Which picture of a banner is on. Read by the banner and by the page's background only, so
/// that the rest of the page is not evaluated again for every slide.
@MainActor @Observable
final class BannerState {
    private(set) var slides: [BannerSlide] = []
    private(set) var index = 0
    /// Counts what the person did, so that the next slide waits its full time after it.
    private(set) var turns = 0

    var current: BannerSlide? { slides.indices.contains(index) ? slides[index] : slides.first }
    var next: BannerSlide? { slides.count > 1 ? slides[(index + 1) % slides.count] : nil }

    /// The slides changed (a film was watched, something new came): the one that is on stays.
    func show(_ new: [BannerSlide]) {
        guard new != slides else { return }
        let id = current?.id
        slides = new
        index = new.firstIndex { $0.id == id } ?? 0
    }

    func step(_ by: Int) {
        guard slides.count > 1 else { return }
        index = (index + by + slides.count) % slides.count
        turns += 1
    }

    func go(to place: Int) {
        guard slides.indices.contains(place) else { return }
        index = place
        turns += 1
    }
}

extension Motion {
    /// One picture of a banner becomes the next.
    var slideChange: Animation { .easeInOut(duration: moves ? 0.9 : 0.35) }
    /// The words of one slide leave before those of the next come: two titles are never read
    /// through each other.
    @MainActor
    static let wordChange = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeIn(duration: 0.35).delay(0.3)), removal: .opacity.animation(.easeOut(duration: 0.25)))
    /// How long a slide is on.
    static let slideSeconds: Double = 8
    /// How much a banner's picture grows while it is on.
    var slideZoom: CGFloat { isFull ? 1.07 : 1 }
}

extension View {
    /// Goes on to the next slide by itself, and fetches its picture meanwhile. Not with Reduce
    /// Motion or VoiceOver, behind the player, or out of sight.
    func advancesBanner(_ state: BannerState, isHeld: Bool) -> some View {
        modifier(AdvancesBanner(state: state, isHeld: isHeld))
    }

    /// The page in the colours of the slide that is on, or of `fallback` without a banner.
    func bannerBackground(_ state: BannerState, fallback: [Artwork], kids: Bool = false) -> some View {
        modifier(BannerBackground(state: state, fallback: fallback, isKids: kids))
    }
}

private struct BannerBackground: ViewModifier {
    let state: BannerState
    let fallback: [Artwork]
    let isKids: Bool

    func body(content: Content) -> some View {
        #if os(tvOS)
        // One colour for as long as the page is open: a screen that changes colour behind every
        // slide is drawn anew for it.
        content.artworkBackground(state.slides.first.map { [$0.backdrop] } ?? fallback, kids: isKids)
        #else
        content.artworkBackground(state.current.map { [$0.backdrop] } ?? fallback, kids: isKids)
        #endif
    }
}

private struct AdvancesBanner: ViewModifier {
    let state: BannerState
    let isHeld: Bool
    @Environment(AppModel.self) private var app
    @Environment(\.motion) private var motion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.displayScale) private var displayScale
    @State private var isInSight = false
    @State private var isAppeared = false

    private struct Turn: Hashable {
        var isRunning: Bool
        var index: Int
        var turns: Int
        var count: Int
    }

    private var isRunning: Bool {
        state.slides.count > 1 && !isHeld && isInSight && isAppeared && motion.moves && !voiceOver
            && app.player == nil && scenePhase != .background
    }

    func body(content: Content) -> some View {
        content
            .onScrollVisibilityChange(threshold: 0.4) { isInSight = $0 }
            .onAppear { isAppeared = true }
            .onDisappear { isAppeared = false }
            .task(id: Turn(isRunning: isRunning, index: state.index, turns: state.turns, count: state.slides.count)) {
                guard isRunning else { return }
                if let next = state.next {
                    _ = await app.artwork(next.backdrop, pixelWidth: ArtworkWidth.w1920.rawValue)
                    if let logo = next.logo { _ = await app.artwork(logo, pixelWidth: ArtworkWidth.w800.rawValue) }
                }
                do { try await Task.sleep(for: .seconds(Motion.slideSeconds)) } catch { return }
                withAnimation(motion.slideChange) { state.step(1) }
            }
    }
}

/// The pictures of a banner, one fading into the next, each growing a little while it is on.
struct BannerPictures: View {
    let state: BannerState
    let size: CGSize

    var body: some View {
        ZStack {
            if let slide = state.current {
                SlidePicture(artwork: slide.backdrop, title: slide.item.title, size: size)
                    .id(slide.backdrop.id)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}

struct SlidePicture: View {
    let artwork: Artwork?
    let title: String
    let size: CGSize
    /// The slow growing. A title's own page stands still.
    var grows = true
    @Environment(\.motion) private var motion
    @State private var hasGrown = false

    var body: some View {
        let height = max(size.height, size.width / AppTheme.wideAspect)
        let width = height * AppTheme.wideAspect
        ArtworkView(artwork: artwork, width: width) { TintField(title: title) }
            .frame(width: width, height: height)
            // Of a picture that is too high for a wide banner, more of the upper part: faces.
            .offset(y: -(height - size.height) * 0.25)
            .frame(width: size.width, height: size.height, alignment: .top)
            .scaleEffect(hasGrown ? motion.slideZoom : 1, anchor: UnitPoint(x: 0.6, y: 0.3))
            .clipped()
            .onAppear {
                #if os(tvOS)
                let isStill = true
                #else
                let isStill = !grows || !motion.isFull
                #endif
                guard !isStill else { return }
                withAnimation(.linear(duration: Motion.slideSeconds * 1.8)) { hasGrown = true }
            }
    }
}

/// Where the slideshow is. One element for VoiceOver, which goes to the next with a swipe up.
struct BannerDots: View {
    let state: BannerState
    @Environment(\.motion) private var motion

    var body: some View {
        if state.slides.count > 1 {
            HStack(spacing: 7) {
                ForEach(Array(state.slides.enumerated()), id: \.element.id) { place, _ in
                    let isOn = place == state.index
                    Capsule()
                        .fill(isOn ? Color.lobbyAccent(.dark) : Color.lobbyOnArtwork.opacity(0.5))
                        .frame(width: isOn ? 26 : 8, height: 8)
                        .contentShape(Rectangle().inset(by: -8))
                        #if !os(tvOS)
                        .onTapGesture { withAnimation(motion.slideChange) { state.go(to: place) } }
                        #endif
                }
            }
            .shadow(color: .black.opacity(0.4), radius: 4)
            .animation(motion.animation(.change), value: state.index)
            .accessibilityElement()
            .accessibilityLabel("Slideshow")
            .accessibilityValue("\(state.index + 1) of \(state.slides.count)")
            .accessibilityAdjustableAction { direction in
                state.step(direction == .increment ? 1 : -1)
            }
            .accessibilityIdentifier("banner.dots")
        }
    }
}

/// A title's word mark, or its words, large, until there is one.
struct TitleLogo: View {
    let title: String
    let logo: Artwork?
    let font: Font
    var maxWidth: CGFloat
    var maxHeight: CGFloat
    var lines = 2
    var alignment: TextAlignment = .leading

    @Environment(AppModel.self) private var app
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                let size = LogoMetrics.size(
                    width: image.width, height: image.height, area: maxWidth * maxHeight * 0.62, maxWidth: maxWidth, maxHeight: maxHeight)
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .shadow(color: .black.opacity(0.35), radius: 12)
                    .transition(.opacity)
            } else {
                Text(title)
                    .font(font)
                    .tracking(-0.6)
                    .lineLimit(lines)
                    .minimumScaleFactor(0.5)
                    .multilineTextAlignment(alignment)
                    .shadow(color: .black.opacity(0.45), radius: 12, y: 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
        .task(id: logo?.id) {
            guard let logo else {
                image = nil
                return
            }
            image = await app.artwork(logo, pixelWidth: ArtworkWidth.w800.rawValue)
        }
    }
}
