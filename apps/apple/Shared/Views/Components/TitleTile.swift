// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// What stands in for a poster when Lobby has no artwork for a film or show: its title, set
/// large on a colour that belongs to that title.
///
/// This is the real look of an item nobody matched yet (and of every home video), not a
/// loading state.
struct TitleTile: View {
    enum Shape { case poster, wide }

    let title: String
    var detail: String? = nil
    var shape: Shape = .poster
    /// A wide picture from the film itself, cropped to the tile behind its title.
    var picture: Artwork? = nil
    /// False where the title stands under the tile and the picture can be left alone.
    var showsTitle = true
    var width: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            TintField(title: title)
            if let picture {
                Color.clear
                    .overlay {
                        // Cropped to the tile's height, the picture is drawn much wider than the tile.
                        ArtworkView(
                            artwork: picture, width: width / AppTheme.posterAspect * AppTheme.wideAspect
                        ) { Color.clear }
                    }
                    .clipped()
            }
            if picture != nil, showsTitle {
                LinearGradient(
                    stops: [
                        .init(color: Color.lobbyArtworkScrim.opacity(0), location: 0.35),
                        .init(color: Color.lobbyArtworkScrim.opacity(0.85), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom)
            }
            if showsTitle {
            VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                Text(title)
                    .font(.system(Self.titleStyle(shape), design: .serif, weight: .semibold))
                    .lineLimit(shape == .poster ? 5 : 2)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(.leading)
                if let detail {
                    Text(detail)
                        .font(.caption.weight(.medium))
                        .opacity(0.75)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(Color.lobbyOnArtwork)
            .padding(AppTheme.Space.m)
            }
        }
        .accessibilityHidden(true)
    }

    private static func titleStyle(_ shape: Shape) -> Font.TextStyle {
        #if os(tvOS)
        // tvOS's titles are made for a whole screen, not for a tile.
        return shape == .poster ? .callout : .headline
        #else
        return shape == .poster ? .title3 : .title2
        #endif
    }
}

/// The colour that belongs to a title, as a field: lighter above, darker below, one hue.
/// Behind a title tile, and behind the header of a film or show without a backdrop.
struct TintField: View {
    let title: String

    var body: some View {
        let tint = TitleTileTint(title: title)
        LinearGradient(
            colors: [.lobbyTile(tint, shade: .top), .lobbyTile(tint, shade: .bottom)],
            startPoint: .top, endPoint: .bottom)
    }
}
