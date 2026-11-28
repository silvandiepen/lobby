// SPDX-License-Identifier: MPL-2.0
import SwiftUI

// The one place colours, radii and spacing are defined. Views ask for a meaning
// (`Color.lobbySurface(scheme)`), never for a hex value.
//
// The surfaces are solid and the app's own: a deep aubergine, which sets off a warm accent and
// posters of any colour, and in light a warm off-white of the same hue. None of them takes a
// tint from the desktop picture. Dark is the designed appearance; light is a parallel set of
// the same roles, not an inversion. See "The palette" in docs/decisions.md.

extension Color {
    fileprivate init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }

    /// The window behind everything.
    static func lobbyBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x1C142B) : Color(hex: 0xF7F4F8)
    }

    /// The sidebar: a step darker than the window.
    static func lobbySidebar(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x140E20) : Color(hex: 0xEFEAF2)
    }

    /// A panel, control or row that sits on the background.
    static func lobbySurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x271E3B) : Color(hex: 0xFFFFFF)
    }

    /// A surface on a surface: a pressed control, a progress track.
    static func lobbySurfaceRaised(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x372B4E) : Color(hex: 0xE7E0EC)
    }

    /// The line between the rows of a panel.
    static func lobbyHairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x3E3356) : Color(hex: 0xE2DBE7)
    }

    /// Captions, symbols and whatever comes second, readable on every surface.
    static func lobbySecondaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xAFA5BD) : Color(hex: 0x635A6E)
    }

    /// Lobby's one accent hue: selection, progress, links.
    static func lobbyAccent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xFF7A3D) : Color(hex: 0xB8430A)
    }

    /// Selected rows, cards and tabs: a tinted fill and nothing else. Never a bar or a border.
    static func lobbySelection(_ scheme: ColorScheme) -> Color {
        lobbyAccent(scheme).opacity(scheme == .dark ? 0.2 : 0.14)
    }

    /// The primary button (Play, Resume): the warm white of the concept on dark, ink on light.
    static func lobbyProminentFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xF3EDE4) : Color(hex: 0x221A2E)
    }

    static func lobbyProminentLabel(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x16111F) : Color(hex: 0xFFFFFF)
    }

    /// Text and symbols on top of artwork or a title tile, whatever the appearance.
    static let lobbyOnArtwork = Color.white

    /// A tile of the app's own, with white on it, in both appearances.
    static let lobbyTileFill = [Color(hex: 0x3F3259), Color(hex: 0x261C3A)]

    /// Words on the bright accent, as on a chosen pill.
    static let lobbyOnAccent = Color(hex: 0x2A0E00)

    /// The small line over a title on artwork: the accent, light enough to read there.
    static let lobbyKicker = Color(hex: 0xFFB48C)

    /// The scrim that keeps a label readable on bright artwork.
    static let lobbyArtworkScrim = Color.black

    // Status colours keep their meaning in both appearances.
    static let lobbyWarning = Color.orange
    static let lobbyFailure = Color.red
    static let lobbySuccess = Color.green

    /// A viewer's colour, from the names the API uses for `Profile.color`.
    static func lobbyProfile(_ name: String) -> Color {
        switch name {
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "teal": .teal
        case "blue": .blue
        case "purple": .purple
        case "pink": .pink
        default: .gray
        }
    }

    /// The colour of a title tile, for a film or show without a poster.
    static func lobbyTile(_ tint: TitleTileTint, shade: TitleTileTint.Shade) -> Color {
        Color(hue: tint.hue, saturation: tint.saturation, brightness: shade == .top ? 0.46 : 0.18)
    }
}

/// Text and symbols that come second, in the app's own hue: the system's grey is too light to
/// read on a tinted surface.
struct LobbySecondary: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        .lobbySecondaryText(environment.colorScheme)
    }
}

extension ShapeStyle where Self == LobbySecondary {
    static var lobbySecondary: LobbySecondary { LobbySecondary() }
}

enum AppTheme {
    enum Radius {
        static let tile: CGFloat = 12
        static let card: CGFloat = 14
        static let control: CGFloat = 12
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 20
        static let xl: CGFloat = 32
        /// The page's side margin on a phone, and the gap between two posters there: three
        /// posters fill the width between the margins.
        static let page: CGFloat = 16
        static let tile: CGFloat = 8
        /// Between two shelves on a page.
        static let shelf: CGFloat = 28
    }

    /// The reading width of a column of text or a form.
    static let readableWidth: CGFloat = 560

    /// A poster is two wide by three high, a still or backdrop sixteen by nine.
    static let posterAspect: CGFloat = 2.0 / 3.0
    static let wideAspect: CGFloat = 16.0 / 9.0
}

/// The colours of the navigation symbols. Colourful and recognisable, as the concept has them.
enum NavigationTint {
    static let library = Color.orange
    static let movies = Color.purple
    static let series = Color.blue
    static let downloads = Color.green
    static let search = Color.gray
    static let manage = Color.teal

    /// A category's colour: the household's choice, or by its place.
    static func category(_ look: CategoryLook, at index: Int) -> Color {
        look.color.map(Color.lobbyProfile) ?? category(at: index)
    }

    /// A category's colour, by its place in the list of categories: neighbours always differ.
    static func category(at index: Int) -> Color {
        let palette: [Color] = [.pink, .yellow, .teal, .indigo, .red, .brown, .mint, .purple]
        return palette[index % palette.count]
    }
}

/// The kids screens: the regular app, simpler, larger and richer in colour. Their pages take
/// their colours from the pictures on them (`ArtworkColors.Style.kids`); this is the rest.
enum KidsTheme {
    enum Section: Hashable, Sendable {
        case home, stories, movies, series, onHere
    }

    /// Behind everything while there is no picture.
    static func page(_ contrast: ColorSchemeContrast) -> LinearGradient {
        LinearGradient(
            colors: contrast == .increased ? [Color(hex: 0x2A1A4A), Color(hex: 0x160E2B)] : [Color(hex: 0x4A2C82), Color(hex: 0x241547)],
            startPoint: UnitPoint(x: 0.3, y: 0), endPoint: UnitPoint(x: 0.7, y: 1))
    }

    /// A place's colour on the tab bar, when chosen: light enough on the dark glass.
    static func tab(_ section: Section) -> Color {
        switch section {
        case .home: Color(hex: 0xFFB27A)
        case .stories: Color(hex: 0xFFD970)
        case .movies: Color(hex: 0xCDB0FF)
        case .series: Color(hex: 0x8CCBFF)
        case .onHere: Color(hex: 0x84E3AE)
        }
    }

    static let words = Color.white
    /// A chosen thing of the child's own: the mark on their picture.
    static let avatar = Color(hex: 0xE0316B)
    /// Round white things on the page.
    static let button = Color.white
    /// Darker than any page, so that white on it is at least as readable as beside it.
    static let quiet = Color.black.opacity(0.22)
    static let play = Color(hex: 0xF6F1EA)
    static let onPlay = Color(hex: 0x1B1226)
    static let progress = Color(hex: 0xFF8A4D)
    static let track = Color.white.opacity(0.35)
    static let scrim = Color.black.opacity(0.75)
    static let shadow = Color.black.opacity(0.28)

    /// A little rounder than the regular app's.
    static let posterRadius: CGFloat = 16
    static let cardRadius: CGFloat = 20
    static let barRadius: CGFloat = 30
    static let margin: CGFloat = 20
    static let gap: CGFloat = 16
}

extension View {
    /// The rounded corners and the soft shadow of every picture on the kids screens.
    func kidsFrame(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return clipShape(shape)
            .contentShape(shape)
            .shadow(color: KidsTheme.shadow, radius: 10, y: 5)
    }

    /// White words straight on a kids page.
    func kidsWords() -> some View {
        foregroundStyle(KidsTheme.words)
            .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
    }
}

extension View {
    /// A translucent bar or panel, or a solid one when the viewer turned transparency down.
    func lobbyPanel(cornerRadius: CGFloat = AppTheme.Radius.card) -> some View {
        modifier(PanelBackground(cornerRadius: cornerRadius))
    }
}

private struct PanelBackground: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if os(tvOS)
        content.background(Color.lobbySurface(scheme), in: shape)
        #else
        if reduceTransparency {
            content.background(Color.lobbySurface(scheme), in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
        #endif
    }
}
