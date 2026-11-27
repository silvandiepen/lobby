// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// Asked for again when the server comes into reach.
private struct LogoAsk: Hashable {
    var id: String?
    var connectivity: AppModel.Connectivity
}

/// What stands for a category beside or instead of its name: the household's logo for it,
/// drawn in one colour, or a symbol.
struct CategoryMark: View {
    let look: CategoryLook
    /// The symbol when the household chose none: a folder, or a tag for a genre.
    var fallback = AppSymbol.category
    /// How much room a logo takes, as an area, so that logos of different shapes weigh the same.
    var area: CGFloat = 1_400
    var maxWidth: CGFloat = 110
    var maxHeight: CGFloat = 44

    @Environment(AppModel.self) private var app
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let logo = look.logo, let image {
                let size = LogoMetrics.size(
                    width: logo.width, height: logo.height, area: area, maxWidth: maxWidth, maxHeight: maxHeight)
                LogoImage(logo: logo, image: image)
                    .frame(width: size.width, height: size.height)
            } else {
                Image(systemName: AppSymbol.existing(look.symbol) ?? fallback)
            }
        }
        .accessibilityHidden(true)
        .task(id: LogoAsk(id: look.logo?.id, connectivity: app.connectivity)) {
            guard let logo = look.logo else {
                image = nil
                return
            }
            // What was there stays while it is asked for again.
            image = await app.logo(logo) ?? image
        }
    }
}

/// A category as a wide tile: its logo, or its symbol and name, in white on the household's
/// colour for it, or on the colours of what is in it.
struct CategoryTile: View {
    let category: CategoryShelf
    var width: CGFloat = 208
    var cornerRadius = AppTheme.Radius.card
    var nameFont: Font = .headline
    @Environment(AppModel.self) private var app
    @State private var palette: ArtworkPalette?

    var body: some View {
        let look = app.look(of: category)
        let height = (width * 0.5).rounded()
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        LogoOrText(title: category.name, look: look, area: width * height * 0.24, maxWidth: width * 0.66, maxHeight: height * 0.54) {
            VStack(spacing: AppTheme.Space.s) {
                Image(systemName: AppSymbol.existing(look.symbol) ?? (category.source == .genre ? AppSymbol.genre : AppSymbol.category))
                    .font(.title2)
                Text(category.name)
                    .font(nameFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .foregroundStyle(Color.lobbyOnArtwork)
        .padding(.horizontal, AppTheme.Space.m)
        .frame(width: width, height: height)
        .background { fill(look) }
        .clipShape(shape)
        .tileArtworkSource(cornerRadius: cornerRadius)
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(category.name)
        .accessibilityValue(category.items.count == 1 ? "1 title" : "\(category.items.count) titles")
        .task(id: look.color == nil ? category.items.pageColours.map(\.id) : []) {
            guard look.color == nil else { return }
            palette = await app.palette(of: Array(category.items.pageColours.prefix(2)))
        }
    }

    @ViewBuilder
    private func fill(_ look: CategoryLook) -> some View {
        if let color = look.color {
            Color.lobbyProfile(color)
                .overlay { LinearGradient(colors: [.black.opacity(0.3), .black.opacity(0.62)], startPoint: .topLeading, endPoint: .bottomTrailing) }
        } else if let colors = palette.flatMap({ ArtworkColors($0, style: .tile) }) {
            LinearGradient(colors: [Color(colors.glows[0]), Color(colors.base)], startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            LinearGradient(colors: Color.lobbyTileFill, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

/// A logo's picture. Of a transparent one only the shape is used, in the colour around it:
/// its own colours are often black. An opaque picture is shown as it is.
private struct LogoImage: View {
    let logo: CategoryLogo
    let image: CGImage
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Image(decorative: image, scale: displayScale)
            .renderingMode(logo.transparent ? .template : .original)
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: logo.transparent ? 0 : 6, style: .continuous))
    }
}

/// A heading that is a category's logo, or its words until the logo is there and when it
/// cannot be fetched.
struct LogoOrText<Words: View>: View {
    let title: String
    let look: CategoryLook
    let area: CGFloat
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    @ViewBuilder var words: Words

    @Environment(AppModel.self) private var app
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let logo = look.logo, let image {
                let size = LogoMetrics.size(
                    width: logo.width, height: logo.height, area: area, maxWidth: maxWidth, maxHeight: maxHeight)
                LogoImage(logo: logo, image: image)
                    .frame(width: size.width, height: size.height)
                    .foregroundStyle(.primary)
                    .accessibilityElement()
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(.isHeader)
            } else {
                words
            }
        }
        .task(id: LogoAsk(id: look.logo?.id, connectivity: app.connectivity)) {
            guard let logo = look.logo else {
                image = nil
                return
            }
            // What was there stays while it is asked for again.
            image = await app.logo(logo) ?? image
        }
    }
}
