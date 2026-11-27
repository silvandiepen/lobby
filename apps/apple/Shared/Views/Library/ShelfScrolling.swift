// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// Sideways scrolling without a bar, coming to rest with a tile at the margin (the content
/// says `scrollTargetLayout()`). On the Mac, where a mouse has no sideways movement, an arrow
/// appears at each side there is more on while the pointer is over the shelf.
struct ShelfScrolling: ViewModifier {
    let margin: CGFloat

    /// Room above and below for a tile that rises: a scroll view cuts off what is outside it.
    private static let lift: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, margin, for: .scrollContent)
            .contentMargins(.vertical, Self.lift, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .modifier(WithArrows())
            .padding(.vertical, -Self.lift)
    }
}

private struct WithArrows: ViewModifier {
    #if os(macOS)
    @State private var position = ScrollPosition(edge: .leading)
    /// What the arrows need to know: not where the shelf is, which changes with every frame.
    @State private var hasBefore = false
    @State private var hasAfter = false
    @State private var last = Last()
    @State private var isHovered = false
    @Environment(\.motion) private var motion

    /// Where the shelf is, for the next press of an arrow. Not observed.
    @MainActor
    private final class Last {
        var place = Place()
    }

    /// From 0 at the shelf's start.
    private struct Place: Equatable {
        var offset: CGFloat = 0
        var visible: CGFloat = 0
        var content: CGFloat = 0

        var hasBefore: Bool { offset > 1 }
        var hasAfter: Bool { offset + visible < content - 1 }
        func next(_ direction: CGFloat) -> CGFloat {
            min(max(offset + direction * visible * 0.8, 0), max(content - visible, 0))
        }
    }

    func body(content: Content) -> some View {
        content
            // "Hidden" still shows a bar to a Mac with a mouse.
            .scrollIndicators(.never)
            .scrollPosition($position)
            .onScrollGeometryChange(for: Place.self) {
                Place(
                    // The container is what is between the margins.
                    offset: $0.contentOffset.x + $0.contentInsets.leading, visible: $0.containerSize.width, content: $0.contentSize.width)
            } action: { _, now in
                last.place = now
                if hasBefore != now.hasBefore { hasBefore = now.hasBefore }
                if hasAfter != now.hasAfter { hasAfter = now.hasAfter }
            }
            .overlay {
                HStack {
                    arrow("chevron.backward", "Scroll back", -1, isShown: isHovered && hasBefore)
                    Spacer()
                    arrow("chevron.forward", "Scroll on", 1, isShown: isHovered && hasAfter)
                }
                .animation(motion.animation(.hover), value: isHovered)
                .animation(motion.animation(.hover), value: hasBefore)
                .animation(motion.animation(.hover), value: hasAfter)
            }
            .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private func arrow(_ symbol: String, _ name: String, _ direction: CGFloat, isShown: Bool) -> some View {
        if isShown {
            Button {
                withAnimation(motion.animation(.shelf)) { position.scrollTo(x: last.place.next(direction)) }
            } label: {
                Image(systemName: symbol)
                    .font(.headline)
                    .frame(width: 32, height: 32)
                    .lobbyPanel(cornerRadius: 16)
                    .contentShape(Circle())
            }
            .buttonStyle(.lobbyIcon)
            .padding(.horizontal, AppTheme.Space.s)
            .help(name)
            // VoiceOver scrolls by itself.
            .accessibilityHidden(true)
            .transition(
                motion.moves ? .scale(scale: 0.7).combined(with: .opacity) : .opacity)
        }
    }
    #else
    func body(content: Content) -> some View {
        content.scrollIndicators(.hidden)
    }
    #endif
}
