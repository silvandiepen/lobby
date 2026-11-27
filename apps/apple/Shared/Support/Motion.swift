// SPDX-License-Identifier: MPL-2.0
import SwiftUI

// The one place movement is defined, beside `AppTheme`, where colours are. A view asks for a
// meaning (`motion.animation(.open)`, `motion.pressScale`), never for a number of its own.
//
// Every meaning has three forms:
//   full   as designed
//   light  Low Power Mode: the same presses and fades, without what moves while scrolling or
//          covers the whole screen
//   still  Reduce Motion: nothing changes place or size. What appears, fades.

/// How this device moves right now. `@Environment(\.motion)`.
struct Motion: Equatable, Sendable {
    enum Level: Sendable {
        case full, light, still
    }

    /// What is moving.
    enum Role: CaseIterable, Sendable {
        /// A button goes down under a finger: at once.
        case press
        /// It comes back up.
        case release
        /// The pointer comes over a tile, or the remote's focus.
        case hover
        /// A small thing takes another state: a symbol, a label, a pill.
        case change
        /// Items come, go or change places.
        case list
        /// A page or the player opens.
        case open
        /// Content arrives on a page that just opened.
        case arrive
        /// Another section, season or category in the same place.
        case section
        /// A shelf goes on to its next page.
        case shelf
        /// A picture appears over its placeholder.
        case artwork
    }

    /// An animation as a value, so that it can be tested.
    enum Curve: Equatable, Sendable {
        case spring(response: Double, damping: Double)
        case ease(duration: Double)

        var animation: Animation {
            switch self {
            case .spring(let response, let damping): .spring(response: response, dampingFraction: damping)
            case .ease(let duration): .easeOut(duration: duration)
            }
        }
    }

    let level: Level
    /// The kids screens: a little softer and longer.
    let isPlayful: Bool

    init(reduceMotion: Bool, lowPower: Bool = false, isPlayful: Bool = false) {
        level = reduceMotion ? .still : lowPower ? .light : .full
        self.isPlayful = isPlayful
    }

    /// Whether anything may change place or size.
    var moves: Bool { level != .still }
    /// Whether the costly ones are on: what moves while scrolling, and what covers the screen.
    var isFull: Bool { level == .full }

    // MARK: Springs and durations

    func curve(_ role: Role) -> Curve {
        guard moves else {
            return .ease(duration: role == .press ? 0.08 : 0.18)
        }
        return switch role {
        case .press: .ease(duration: 0.08)
        case .release: isPlayful ? .spring(response: 0.38, damping: 0.66) : .spring(response: 0.32, damping: 0.62)
        case .hover: .spring(response: 0.3, damping: 0.78)
        case .change: isPlayful ? .spring(response: 0.34, damping: 0.78) : .spring(response: 0.28, damping: 0.8)
        case .list: .spring(response: 0.4, damping: 0.86)
        case .open: isPlayful ? .spring(response: 0.46, damping: 0.84) : .spring(response: 0.4, damping: 0.86)
        case .arrive: isPlayful ? .spring(response: 0.5, damping: 0.84) : .spring(response: 0.44, damping: 0.88)
        case .section: isPlayful ? .spring(response: 0.42, damping: 0.86) : .spring(response: 0.34, damping: 0.9)
        case .shelf: .spring(response: 0.5, damping: 0.9)
        case .artwork: .ease(duration: 0.25)
        }
    }

    func animation(_ role: Role) -> Animation { curve(role).animation }

    /// What arrives together arrives a moment after each other, and all of it within a third of
    /// a second.
    func arrivalDelay(_ index: Int) -> Double {
        isFull ? Double(min(max(index, 0), 6)) * 0.045 : 0
    }

    // MARK: Distances

    /// How far a button goes down.
    var pressScale: CGFloat { moves ? 0.96 : 1 }
    /// A large tile moves as many points as a small button: its scale is nearer to one.
    var tilePressScale: CGFloat { moves ? 0.97 : 1 }
    /// How much darker it gets meanwhile. Without movement this is all there is.
    var pressDim: Double { moves ? 0.06 : 0.14 }
    /// A tile under the pointer, or with the remote's focus.
    var hoverScale: CGFloat { moves ? 1.035 : 1 }
    var hoverBrightness: Double { 0.05 }
    /// Where content arrives from, below its place.
    var arrivalOffset: CGFloat { isFull ? (isPlayful ? 18 : 14) : 0 }
    /// The size a page or the player opens from.
    var openScale: CGFloat { isFull ? 0.94 : 1 }
    /// The size the page that was behind it comes back from.
    var returnScale: CGFloat { isFull ? 0.985 : 1 }

    // MARK: Scrolling

    /// A tile half out of sight.
    var edgeScale: CGFloat { isFull ? 0.94 : 1 }
    var edgeOpacity: Double { isFull ? 0.6 : 1 }
    var edgeOffset: CGFloat { isFull ? 8 : 0 }
    /// How much of the scrolling the picture of a film's page stays behind.
    var parallax: CGFloat { isFull ? 0.35 : 0 }
    /// Pulling down makes it larger.
    var stretches: Bool { moves }

    // MARK: Opening

    /// Whether a poster grows into its page (iPhone and iPad).
    var zooms: Bool { isFull }
    /// Symbols that bounce, pulse or replace each other.
    var animatesSymbols: Bool { moves }
}

extension EnvironmentValues {
    /// Low Power Mode. `lobbyMotion()` keeps it.
    @Entry var lobbyLowPower = false
    /// Set by the kids screens for everything in them.
    @Entry var lobbyIsPlayful = false

    var motion: Motion {
        Motion(reduceMotion: accessibilityReduceMotion, lowPower: lobbyLowPower, isPlayful: lobbyIsPlayful)
    }
}

extension View {
    /// At the root of a window: follows Low Power Mode for everything inside.
    func lobbyMotion() -> some View {
        modifier(FollowsLowPower())
    }
}

private struct FollowsLowPower: ViewModifier {
    @State private var isLow = ProcessInfo.processInfo.isLowPowerModeEnabled

    func body(content: Content) -> some View {
        content
            .environment(\.lobbyLowPower, isLow)
            .onReceive(
                NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)
            ) { _ in
                isLow = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
    }
}

// MARK: - Scrolling

extension View {
    /// Eases a tile in and out where it crosses the edge of what scrolls it. Drawn by the
    /// render server from the scroll position: no state, and no view is evaluated again.
    func edgeEase(_ axis: Axis) -> some View {
        modifier(EdgeEase(axis: axis, scales: true))
    }

    /// The same for a row as wide as the page, which would lose its margins when scaled.
    func rowEase() -> some View {
        modifier(EdgeEase(axis: .vertical, scales: false))
    }

    /// A picture at the top of a page: slower than the page while it scrolls away, larger while
    /// it is pulled down.
    func parallaxHeader(height: CGFloat) -> some View {
        modifier(ParallaxHeader(height: height))
    }
}

private struct EdgeEase: ViewModifier {
    let axis: Axis
    let scales: Bool
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        #if os(tvOS)
        // The remote scrolls in steps: what moves there is the tile in focus.
        content
        #else
        let motion = motion
        // One shape of view at every level: a change of power mode must not make it anew.
        content.scrollTransition(.interactive.threshold(.visible(0.35)), axis: axis) { view, phase in
            let edge = phase.value
            return view
                .scaleEffect(scales ? 1 - (1 - motion.edgeScale) * abs(edge) : 1)
                .opacity(1 - (1 - motion.edgeOpacity) * abs(edge))
                .offset(y: axis == .vertical ? motion.edgeOffset * edge : 0)
        }
        #endif
    }
}

private struct ParallaxHeader: ViewModifier {
    let height: CGFloat
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        let motion = motion
        content
            .visualEffect { [height] view, proxy in
                let y = proxy.frame(in: .scrollView(axis: .vertical)).minY
                let stretch = y > 0 && motion.stretches ? y : 0
                return view
                    .scaleEffect(1 + stretch / max(height, 1), anchor: .bottom)
                    .offset(y: y < 0 ? -y * motion.parallax : 0)
            }
            // It may grow upwards, and not down over the text.
            .clipShape(OpenAbove())
    }
}

/// A view's own rectangle, and all there is above it.
private struct OpenAbove: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY - 2_000, width: rect.width, height: rect.height + 2_000))
    }
}

// MARK: - Arriving

extension EnvironmentValues {
    /// False for the moment a page opens. True outside a page that staggers.
    @Entry fileprivate var hasArrived = true
}

extension View {
    /// A page whose `arrives(_:)` content comes in a moment after each other: once, when the
    /// page opens. What scrolling makes later is simply there.
    func staggersArrival() -> some View {
        modifier(StaggersArrival())
    }

    /// The place of this view in the order in which the page's content arrives.
    func arrives(_ index: Int) -> some View {
        modifier(Arrives(index: index))
    }
}

private struct StaggersArrival: ViewModifier {
    @State private var hasArrived = false

    func body(content: Content) -> some View {
        content
            .environment(\.hasArrived, hasArrived)
            .onAppear { hasArrived = true }
    }
}

private struct Arrives: ViewModifier {
    let index: Int
    @Environment(\.hasArrived) private var hasArrived
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        #if os(tvOS)
        // What is transparent cannot have the remote: a page is all there when it opens.
        content
        #else
        // Only these two: a grid that finds its width in the same moment does not fly into place.
        content.animation(motion.animation(.arrive).delay(motion.arrivalDelay(index))) {
            $0
                .opacity(hasArrived ? 1 : 0)
                .offset(y: hasArrived ? 0 : motion.arrivalOffset)
        }
        #endif
    }
}

// MARK: - Opening

/// Where pages were opened from: the tile that was pressed, so that its page can grow out of it
/// and go back into it. Not observed: it is written before the page is made.
@MainActor
final class OpenOrigins {
    private var sources: [AnyHashable: UUID] = [:]

    func opened(_ value: AnyHashable, from source: UUID) { sources[value] = source }
    func source(of value: AnyHashable) -> UUID? { sources[value] }
}

extension EnvironmentValues {
    /// The namespace and the origins of the navigation stack this is in.
    @Entry fileprivate var openSpace: OpenSpace? = nil
    /// The tile this picture belongs to.
    @Entry fileprivate var tileSource: UUID? = nil
}

private struct OpenSpace {
    let namespace: Namespace.ID
    let origins: OpenOrigins
}

extension View {
    /// Around a `NavigationStack`: its tiles and its pages find each other.
    func opensFromTiles() -> some View {
        modifier(OpensFromTiles())
    }

    /// The part of a tile that becomes the page: its picture, with its corners and without what
    /// shadow it casts.
    func tileArtworkSource(cornerRadius: CGFloat) -> some View {
        modifier(TileArtworkSource(cornerRadius: cornerRadius))
    }

    /// The page that `value` opens.
    func opensPage(_ value: some Hashable & Sendable) -> some View {
        modifier(OpensPage(value: AnyHashable(value)))
    }

    /// A tile that opens `value`: it tells where the page comes from when it is pressed.
    func opensOnPress(_ value: AnyHashable?, isPressed: Bool) -> some View {
        modifier(OpensOnPress(value: value, isPressed: isPressed))
    }
}

private struct OpensFromTiles: ViewModifier {
    @Namespace private var namespace
    @State private var origins = OpenOrigins()

    func body(content: Content) -> some View {
        content.environment(\.openSpace, OpenSpace(namespace: namespace, origins: origins))
    }
}

private struct TileArtworkSource: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.openSpace) private var space
    @Environment(\.tileSource) private var source

    func body(content: Content) -> some View {
        #if os(iOS)
        if let space, let source {
            content.matchedTransitionSource(id: source, in: space.namespace) {
                $0.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct OpensOnPress: ViewModifier {
    let value: AnyHashable?
    let isPressed: Bool
    @State private var source = UUID()
    @Environment(\.openSpace) private var space
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        content
            .environment(\.tileSource, value == nil ? nil : source)
            .onChange(of: isPressed) { _, isPressed in
                guard isPressed else { return }
                #if os(macOS)
                PressPoint.remember()
                #endif
                if let value, motion.zooms { space?.origins.opened(value, from: source) }
            }
    }
}

private struct OpensPage: ViewModifier {
    let value: AnyHashable
    @Environment(\.openSpace) private var space

    func body(content: Content) -> some View {
        #if os(iOS)
        if let space, let source = space.origins.source(of: value) {
            content.navigationTransition(.zoom(sourceID: source, in: space.namespace))
        } else {
            // Opened without a tile (a menu, VoiceOver), or with less motion: the system's own.
            content
        }
        #elseif os(macOS)
        content.modifier(GrowsIn(origin: PressPoint.recent))
        #else
        content
        #endif
    }
}

/// Where the system gives no transition of its own (the Mac's navigation): the page grows a little out of the place that was pressed, and fades in.
struct GrowsIn: ViewModifier {
    /// In the window's coordinates. nil: out of the middle.
    var origin: CGPoint? = nil
    @State private var isIn = false
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        let scale = isIn ? 1 : motion.openScale
        content.animation(motion.animation(.open)) {
            $0.visualEffect { [origin] view, proxy in
                let frame = proxy.frame(in: .global)
                var anchor = UnitPoint.center
                if let origin, frame.width > 0, frame.height > 0 {
                    anchor = UnitPoint(
                        x: min(max((origin.x - frame.minX) / frame.width, 0), 1),
                        y: min(max((origin.y - frame.minY) / frame.height, 0), 1))
                }
                return view.scaleEffect(scale, anchor: anchor)
            }
            .opacity(isIn ? 1 : 0)
        }
        .onAppear { isIn = true }
    }
}

#if os(macOS)
/// Where the pointer last pressed a tile, in the window, from its top left corner.
@MainActor
enum PressPoint {
    private static var last: (point: CGPoint, at: Date)?

    static func remember() {
        guard let event = NSApp.currentEvent, let content = event.window?.contentView else { return }
        let point = event.locationInWindow
        last = (CGPoint(x: point.x, y: content.bounds.height - point.y), Date())
    }

    /// The press that opens what opens now.
    static var recent: CGPoint? {
        guard let last, Date().timeIntervalSince(last.at) < 1 else { return nil }
        return last.point
    }
}

extension View {
    /// The page under the one that was opened comes back as it goes: the Mac's own navigation
    /// shows it at once.
    func returns(isInFront: Bool) -> some View {
        modifier(Returns(isInFront: isInFront))
    }
}

private struct Returns: ViewModifier {
    let isInFront: Bool
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        content.animation(motion.animation(.open)) {
            $0
                .scaleEffect(isInFront ? 1 : motion.returnScale)
                .opacity(isInFront ? 1 : 0)
        }
    }
}
#endif

// MARK: - Small movements

extension View {
    /// A large title that gets smaller while it scrolls away.
    func shrinksAway() -> some View {
        modifier(ShrinksAway())
    }
}

private struct ShrinksAway: ViewModifier {
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        let isOn = motion.isFull
        content.visualEffect { view, proxy in
            let y = proxy.frame(in: .scrollView(axis: .vertical)).minY
            // From its place under the clock to out of sight.
            let gone = isOn ? min(max(-y / 60, 0), 1) : 0
            return view.scaleEffect(1 - 0.3 * gone, anchor: .bottomLeading).opacity(1 - gone)
        }
    }
}

/// A page that takes the place of another.
struct FadesIn: ViewModifier {
    @State private var isIn = false
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        content
            .animation(motion.animation(.section)) {
                $0
                    .opacity(isIn ? 1 : 0)
                    .offset(y: isIn ? 0 : motion.arrivalOffset / 2)
            }
            .onAppear { isIn = true }
    }
}

extension AnyTransition {
    /// The episodes of another season, the titles of another choice: out with a fade, in from a
    /// little below.
    @MainActor
    static func lobbySwap(_ motion: Motion) -> AnyTransition {
        .asymmetric(
            insertion: .offset(y: motion.arrivalOffset).combined(with: .opacity),
            removal: .opacity.animation(.easeOut(duration: 0.1)))
    }
}
