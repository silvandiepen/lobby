// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// One film or show on a shelf or in a grid: its poster, with its title and year under it.
struct PosterTile: View {
    let title: String
    var year: Int? = nil
    var artwork: Artwork? = nil
    /// A wide picture to stand in while there is no poster.
    var picture: Artwork? = nil
    /// What stands under the title instead of the year, e.g. "Season 2" and "8 episodes".
    var captionLines: [String] = []
    var isAvailable = true
    let width: CGFloat
    /// Off in a row of a page: a poster has its title on it. What has no poster gets the words.
    var showsCaption = true

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.s) {
            ArtworkView(artwork: artwork, width: width) {
                // The caption below carries the title: a picture stands on its own, and only
                // a tile with no picture at all has the title set on its colour.
                TitleTile(
                    title: title, detail: year.map(String.init), picture: artwork == nil ? picture : nil,
                    showsTitle: picture == nil || !showsCaption, width: width)
            }
            .frame(width: width, height: width / AppTheme.posterAspect)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.tile, style: .continuous))
            .tileArtworkSource(cornerRadius: AppTheme.Radius.tile)
            .overlay(alignment: .topTrailing) {
                if !isAvailable {
                    // The drive is unplugged. Symbol and VoiceOver label, not colour alone.
                    Image(systemName: "externaldrive.badge.xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.lobbyOnArtwork)
                        .padding(AppTheme.Space.s)
                        .background(Color.lobbyArtworkScrim.opacity(0.6), in: Circle())
                        .padding(AppTheme.Space.s)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !showsCaption, artwork != nil, let first = captionLines.first {
                    // Which season it is, where no line under the poster says so.
                    Text(first)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.lobbyOnArtwork)
                        .padding(.horizontal, AppTheme.Space.s)
                        .padding(.vertical, 5)
                        .background(Color.lobbyArtworkScrim.opacity(0.72), in: Capsule())
                        .padding(AppTheme.Space.s)
                }
            }
            .opacity(isAvailable ? 1 : 0.55)

            if showsCaption { VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
            .frame(width: width, alignment: .leading) }
        }
        // The whole tile takes the tap, caption included.
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The line under the title: the year, or "Season 2 · 8 episodes".
    private var detail: String? {
        captionLines.isEmpty ? year.map(String.init) : captionLines.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        ([title] + (captionLines.isEmpty ? [year.map(String.init)].compactMap { $0 } : captionLines)
            + (isAvailable ? [] : ["Not available right now"]))
            .joined(separator: ", ")
    }
}

extension PosterTile {
    init(item: Item, width: CGFloat, showsCaption: Bool = true) {
        self.init(title: item.title, year: item.year, artwork: item.artwork.poster,
            picture: item.artwork.backdrop, isAvailable: item.available, width: width, showsCaption: showsCaption)
    }
}

/// The sizes of tiles and cards.
///
/// On a phone they come from the width of the screen: three posters fill it between the
/// margins, and of the second Continue Watching card a half is in sight. In a wide window
/// they follow the text size.
struct TileMetrics: DynamicProperty {
    @ScaledMetric(relativeTo: .body) private var regularPoster: CGFloat = 156
    @ScaledMetric(relativeTo: .body) private var regularWide: CGFloat = 272
    @ScaledMetric(relativeTo: .body) private var regularCategory: CGFloat = 208
    @ScaledMetric(relativeTo: .body) private var compactCategory: CGFloat = 150
    @Environment(\.lobbyContentWidth) private var contentWidth

    func poster(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        sizeClass == .regular
            ? min(regularPoster, 240) : Self.compactPoster(contentWidth: contentWidth)
    }

    func wide(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        sizeClass == .regular ? min(regularWide, 400) : Self.compactWide(contentWidth: contentWidth)
    }

    /// A category's tile, half as high as it is wide.
    func category(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        sizeClass == .regular ? min(regularCategory, 300) : min(compactCategory, 220)
    }

    /// The side margin of a shelf or grid, and the gap between two of its tiles.
    static func margin(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        sizeClass == .regular ? AppTheme.Space.l : AppTheme.Space.page
    }

    static func gap(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        sizeClass == .regular ? AppTheme.Space.m : AppTheme.Space.tile
    }

    /// A third of what is left of the width after the two margins and the two gaps.
    static func compactPoster(contentWidth: CGFloat) -> CGFloat {
        max(80, ((contentWidth - 2 * AppTheme.Space.page - 2 * AppTheme.Space.tile) / 3).rounded(.down))
    }

    /// Two thirds of a phone's width: a second one is half in sight.
    static func compactWide(contentWidth: CGFloat) -> CGFloat {
        min(320, max(220, (contentWidth * 0.64).rounded(.down)))
    }
}

extension EnvironmentValues {
    /// How wide the library's page is, for the tiles that divide it. A phone's width until
    /// it is measured.
    @Entry var lobbyContentWidth: CGFloat = 393
}

extension View {
    /// Tells the tiles inside how wide this view is.
    func measuresLobbyContentWidth() -> some View {
        modifier(ContentWidthReader())
    }
}

private struct ContentWidthReader: ViewModifier {
    @State private var width: CGFloat = 393

    func body(content: Content) -> some View {
        content
            .environment(\.lobbyContentWidth, width)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}
