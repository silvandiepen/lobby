// SPDX-License-Identifier: MPL-2.0
import SwiftUI

// The app's buttons, as one family: they go down at once under a finger or the pointer, come
// back with a spring, rise under the pointer on the Mac, and show a ring for the keyboard.
// What they look like differs, how they move does not. The numbers are in `Motion`.

extension EnvironmentValues {
    /// A prominent or quiet button at work: its words make room for a spinner.
    @Entry var lobbyIsBusy = false
}

extension View {
    func busy(_ isBusy: Bool) -> some View {
        environment(\.lobbyIsBusy, isBusy)
    }
}

// MARK: - How every button moves

/// How large the thing is that goes down.
enum PressSize {
    case button, tile
    /// A row as wide as its list: it lights up, and keeps its width.
    case row
}

private struct PressFeel<S: InsettableShape>: ViewModifier {
    let isPressed: Bool
    let size: PressSize
    /// For the focus ring and the hit area.
    let shape: S
    /// A tile that rises under the pointer casts a shadow.
    var lifts = false

    @State private var isHovered = false
    @Environment(\.motion) private var motion
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        let isRaised = isHovered && isEnabled && !isPressed
        content
            .brightness(isPressed ? -motion.pressDim : isRaised ? motion.hoverBrightness : 0)
            .background {
                // Drawn from the shape alone, and only while it is there: a tile at rest costs
                // no shadow.
                if lifts, isRaised, motion.moves {
                    shape.fill(Color.black.opacity(0.28))
                        .blur(radius: 12)
                        .offset(y: 8)
                        .transition(.opacity)
                }
            }
            .scaleEffect(scale(isRaised: isRaised))
            .animation(motion.animation(isPressed ? .press : .release), value: isPressed)
            .animation(motion.animation(.hover), value: isRaised)
            #if os(macOS)
            .contentShape(.focusEffect, shape)
            .onHover { isHovered = $0 }
            .pointerStyle(isEnabled ? .link : nil)
            #elseif os(iOS)
            .contentShape(.hoverEffect, shape)
            .hoverEffect(lifts ? .lift : .highlight)
            #endif
    }

    private func scale(isRaised: Bool) -> CGFloat {
        switch size {
        case .row: 1
        case .tile: isPressed ? motion.tilePressScale : isRaised ? motion.hoverScale : 1
        case .button: isPressed ? motion.pressScale : 1
        }
    }
}

private let controlShape = RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
private let tileShape = RoundedRectangle(cornerRadius: AppTheme.Radius.tile, style: .continuous)

/// A button's words, or a spinner in their place while it is at work. The button keeps its size.
private struct BusyLabel<Label: View>: View {
    let label: Label
    let tint: Color
    @Environment(\.lobbyIsBusy) private var isBusy
    @Environment(\.motion) private var motion

    var body: some View {
        label
            .opacity(isBusy ? 0 : 1)
            .scaleEffect(isBusy && motion.moves ? 0.9 : 1)
            .overlay {
                if isBusy {
                    ProgressView()
                        .tint(tint)
                        #if os(macOS)
                        .controlSize(.small)
                        #endif
                        .transition(motion.moves ? .scale(scale: 0.7).combined(with: .opacity) : .opacity)
                }
            }
            .animation(motion.animation(.change), value: isBusy)
    }
}

// MARK: - The family

/// The primary action of a screen: Play, Resume, Pair.
struct ProminentButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.lobbyIsBusy) private var isBusy

    func makeBody(configuration: Configuration) -> some View {
        BusyLabel(label: configuration.label, tint: .lobbyProminentLabel(scheme))
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 28)
            .padding(.vertical, AppTheme.Space.m)
            .padding(.horizontal, AppTheme.Space.l)
            .foregroundStyle(Color.lobbyProminentLabel(scheme))
            .background(Color.lobbyProminentFill(scheme), in: controlShape)
            .opacity(isEnabled || isBusy ? 1 : 0.4)
            .modifier(PressFeel(isPressed: configuration.isPressed, size: .button, shape: controlShape))
    }
}

/// A secondary action beside or below the primary one.
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.artworkColors) private var colors
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.lobbyIsBusy) private var isBusy

    func makeBody(configuration: Configuration) -> some View {
        BusyLabel(label: configuration.label, tint: .primary)
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 28)
            .padding(.vertical, AppTheme.Space.m)
            .padding(.horizontal, AppTheme.Space.l)
            .foregroundStyle(.primary)
            .background(configuration.isPressed ? Color.lobbySurfaceRaised(scheme) : colors.map { Color($0.panel) } ?? Color.lobbySurface(scheme), in: controlShape)
            .opacity(isEnabled || isBusy ? 1 : 0.4)
            .modifier(PressFeel(isPressed: configuration.isPressed, size: .button, shape: controlShape))
    }
}

/// A symbol on its own. Never smaller than a finger on iPhone and iPad.
struct IconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            #if os(iOS)
            .frame(minWidth: 44, minHeight: 44)
            #endif
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
            .modifier(PressFeel(isPressed: configuration.isPressed, size: .button, shape: Circle()))
    }
}

/// A choice that looks like a pill, a swatch or a chip: it brings its own fill.
struct PillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.4)
            .modifier(PressFeel(isPressed: configuration.isPressed, size: .button, shape: Capsule()))
    }
}

/// A button that is only words: "See all", "Add a Category".
struct TextButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.lobbyAccent(scheme))
            #if os(iOS)
            .frame(minHeight: 44)
            #endif
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
            .modifier(PressFeel(isPressed: configuration.isPressed, size: .button, shape: tileShape))
    }
}

/// A row or a panel as wide as its page.
struct RowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.5)
            .modifier(PressFeel(isPressed: configuration.isPressed, size: .row, shape: tileShape))
    }
}

/// A poster, a card or a category: it goes down as a whole, rises under the pointer, and its
/// page grows out of it.
struct TileButtonStyle: ButtonStyle {
    /// What it opens, for the page to grow out of this tile. nil for what opens no page.
    var opens: AnyHashable? = nil
    /// A shadow under the pointer. For a tile that is all picture or panel.
    var lifts = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opensOnPress(opens, isPressed: configuration.isPressed)
            .modifier(PressFeel(isPressed: configuration.isPressed, size: .tile, shape: tileShape, lifts: lifts))
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var lobbyIcon: IconButtonStyle { IconButtonStyle() }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var lobbyPill: PillButtonStyle { PillButtonStyle() }
}

extension ButtonStyle where Self == TextButtonStyle {
    static var lobbyText: TextButtonStyle { TextButtonStyle() }
}

extension ButtonStyle where Self == RowButtonStyle {
    static var lobbyRow: RowButtonStyle { RowButtonStyle() }
}

extension ButtonStyle where Self == TileButtonStyle {
    static var lobbyTile: TileButtonStyle { TileButtonStyle() }

    static func lobbyTile(opens route: some Hashable & Sendable) -> TileButtonStyle {
        TileButtonStyle(opens: AnyHashable(route))
    }
}
