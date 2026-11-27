// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

// A page in the colours of the artwork it shows. See "A page takes its colours from its artwork" in docs/decisions.md.

extension View {
    /// The page's background, from the colours of `artwork`; the app's own while there is none.
    func artworkBackground(_ artwork: Artwork?, kids: Bool = false) -> some View {
        artworkBackground([artwork].compactMap { $0 }, kids: kids)
    }

    /// The same from a few pictures together.
    func artworkBackground(_ artworks: [Artwork], kids: Bool = false) -> some View {
        modifier(ArtworkBackground(artworks: artworks, isKids: kids))
    }
}

extension ArtworkSet {
    /// What a film's or series' page takes its colours from.
    var pageColours: Artwork? { backdrop ?? poster }
}

extension [Item] {
    /// What a category's page takes its colours from: the first of its titles with a picture.
    var pageColours: [Artwork] {
        [Artwork](lazy.compactMap { $0.artwork.poster ?? $0.artwork.backdrop }.prefix(ArtworkPalette.limit))
    }
}

extension LibraryShelves {
    /// What the Library takes its colours from: the title on top.
    var pageColours: Artwork? {
        if let first = continueWatching.first { return first.artwork }
        return recentlyAdded.first.flatMap { $0.picture ?? $0.artwork }
    }
}

extension EnvironmentValues {
    /// The colours of the page a view is on, when they are from its artwork.
    @Entry var artworkColors: ArtworkColors?
}

extension Color {
    /// A chip on a page of any colour: the page, a step lighter.
    static func lobbyChip(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.11) : .white.opacity(0.85)
    }

    init(_ color: PlainColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue)
    }
}

/// The colours of the page in front, for what is around it: the sidebar. One per sidebar layout.
@MainActor @Observable
final class PageTint {
    /// The pages in sight, the one in front last: a page may stay while another lies on it.
    private var pages: [(id: UUID, palette: ArtworkPalette?)] = []

    var palette: ArtworkPalette? { pages.last?.palette }

    func show(_ palette: ArtworkPalette?, of page: UUID) {
        if let index = pages.firstIndex(where: { $0.id == page }) {
            pages[index].palette = palette
        } else {
            pages.append((page, palette))
        }
    }

    func leave(_ page: UUID) {
        pages.removeAll { $0.id == page }
    }
}

private struct ArtworkBackground: ViewModifier {
    let artworks: [Artwork]
    let isKids: Bool

    @Environment(AppModel.self) private var app
    @Environment(PageTint.self) private var tint: PageTint?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var palette: ArtworkPalette?
    @State private var page = UUID()
    @State private var isInSight = false

    private var style: ArtworkColors.Style {
        if isKids { return contrast == .increased ? .kidsDeep : .kids }
        return scheme == .dark ? .dark : .light
    }

    func body(content: Content) -> some View {
        content
            .background {
                ArtworkBackdrop(isKids: isKids)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: palette)
            }
            .environment(\.artworkColors, palette.flatMap { ArtworkColors($0, style: style) })
            .task(id: artworks.map(\.id)) {
                let found = await app.palette(of: artworks)
                guard !Task.isCancelled else { return }
                palette = found
            }
            .onAppear {
                isInSight = true
                tint?.show(palette, of: page)
            }
            .onChange(of: palette) {
                if isInSight { tint?.show(palette, of: page) }
            }
            .onDisappear {
                isInSight = false
                tint?.leave(page)
            }
    }
}

/// What lies behind the page: soft fields of its colours, drawn once. Flat for whoever turned
/// transparency down or asked for more contrast.
struct ArtworkBackdrop: View {
    let isKids: Bool
    @Environment(\.artworkColors) private var colors
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            plain
            if let colors {
                fields(colors)
                    .id(colors)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var plain: some View {
        #if os(tvOS)
        Color.lobbyBackground(scheme)
        #else
        if isKids {
            KidsTheme.page(contrast)
        } else {
            Color.lobbyBackground(scheme)
        }
        #endif
    }

    @ViewBuilder
    private func fields(_ colors: ArtworkColors) -> some View {
        #if os(tvOS)
        Color(colors.base)
        #else
        if reduceTransparency || contrast == .increased {
            Color(colors.base)
        } else {
            Color(colors.base)
                .overlay { field(colors.glows[2], UnitPoint(x: 0.75, y: 1.05), 0.6) }
                .overlay { field(colors.glows[1], UnitPoint(x: 0, y: 1), 0.7) }
                .overlay {
                    // The top half is the picture's, as far as words on it stay readable.
                    LinearGradient(
                        stops: [
                            .init(color: Color(colors.top), location: 0), .init(color: Color(colors.top), location: 0.4),
                            .init(color: Color(colors.top).opacity(0.5), location: 0.68), .init(color: Color(colors.top).opacity(0), location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                }
                .overlay { field(colors.glows[0], UnitPoint(x: 0.9, y: 0), 0.9) }
        }
        #endif
    }

    private func field(_ color: PlainColor, _ center: UnitPoint, _ radius: CGFloat) -> some View {
        EllipticalGradient(
            colors: [Color(color), Color(color).opacity(0)], center: center, startRadiusFraction: 0, endRadiusFraction: radius)
    }
}
