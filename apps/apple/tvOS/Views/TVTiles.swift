// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// A titled row that scrolls sideways. The remote moves between rows, and each keeps its place.
struct TVShelf<Content: View>: View {
    let title: String
    /// A category's or group's own look: its logo stands for the title.
    var look: CategoryLook? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.l) {
            if !title.isEmpty { LogoOrText(title: title, look: look ?? .plain, area: 9_000, maxWidth: 340, maxHeight: 64) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            } }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: TVMetrics.gap) {
                    content
                }
                // Room for the one that has the remote to grow.
                .padding(.vertical, AppTheme.Space.l)
            }
            .scrollClipDisabled()
            .accessibilityIdentifier("shelf.\(title)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }
}

/// A film or show that opens its page.
struct TVItemLink: View {
    let item: Item
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationLink(value: Route.item(item.id)) {
            TVPosterLabel(
                title: item.title, detail: "", year: item.year, artwork: item.artwork.poster,
                picture: item.artwork.backdrop, isAvailable: item.available, watch: watch)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(
            [item.title, item.year.map(String.init), watch?.label, item.available ? nil : "Not available right now"]
                .compactMap { $0 }.joined(separator: ", "))
    }

    /// For a film. A show's state is on its page.
    private var watch: WatchState? {
        guard item.kind != .show else { return nil }
        return WatchState(progress: app.progress[item.id], durationMs: item.displayDurationMs)
    }
}

/// A poster with its title under it, the way the system lifts it towards the viewer.
struct TVPosterLabel: View {
    let title: String
    let detail: String
    let year: Int?
    let artwork: Artwork?
    let picture: Artwork?
    var width = TVMetrics.poster
    var isAvailable = true
    var watch: WatchState? = nil
    @Environment(\.isFocused) private var isFocused
    @Environment(\.motion) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.m) {
            // Pictures one size smaller than a 4K screen could show: four times less to fetch
            // on a slow link, and to keep in memory.
            ArtworkView(artwork: artwork, width: width * 0.8) {
                TitleTile(
                    title: title, detail: year.map(String.init), picture: artwork == nil ? picture : nil,
                    showsTitle: picture == nil, width: 150)
            }
            .frame(width: width, height: width / AppTheme.posterAspect)
            .overlay(alignment: .topTrailing) { badge }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.tile, style: .continuous))
            .opacity(isAvailable ? 1 : 0.55)
            .hoverEffect(.highlight)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                let line = detail.isEmpty ? year.map(String.init) ?? "" : detail
                if !line.isEmpty {
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
            // Out of the way of the poster that grows over it.
            .offset(y: isFocused && motion.moves ? AppTheme.Space.m : 0)
            .opacity(isFocused ? 1 : 0.85)
            .animation(motion.animation(.hover), value: isFocused)
        }
    }

    @ViewBuilder
    private var badge: some View {
        let symbol = isAvailable ? (watch == .watched ? "checkmark" : nil) : "externaldrive.badge.xmark"
        if let symbol {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.lobbyOnArtwork)
                .padding(AppTheme.Space.m)
                .background(Color.lobbyArtworkScrim.opacity(0.6), in: Circle())
                .padding(AppTheme.Space.m)
                .accessibilityHidden(true)
        }
    }
}

/// Continue Watching plays at once. A card that cannot play opens its film or show, where the
/// reason is written out. A long press has the rest.
struct TVContinueButton: View {
    let card: ContinueCard
    /// Called when it starts to play.
    let willPlay: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.tvOpen) private var tvOpen

    var body: some View {
        Button {
            if let request = card.action.request { play(request) } else { openPage() }
        } label: {
            picture
                .hoverEffect(.highlight)
        }
        .buttonStyle(.borderless)
        .contextMenu {
            Button("Go to \(card.title)", systemImage: "info.circle") { openPage() }
            if let request = card.action.fromBeginning {
                Button("Start from Beginning", systemImage: AppSymbol.startOver) { play(request) }
            }
            if let item = card.action.request?.item {
                Button("Mark as Watched", systemImage: AppSymbol.markWatched) {
                    Task { await app.markWatched(itemID: item.id) }
                }
            }
        }
        .accessibilityLabel(card.accessibilityLabel)
    }

    private func play(_ request: PlayRequest) {
        willPlay()
        app.play(request)
    }

    private func openPage() {
        tvOpen.open(.item(card.detailItemID))
    }

    private var picture: some View {
        ArtworkView(artwork: card.artwork, width: 400) { TintField(title: card.tintTitle) }
            .frame(width: TVMetrics.wide, height: TVMetrics.wide / AppTheme.wideAspect)
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: Color.lobbyArtworkScrim.opacity(0), location: 0.35),
                        .init(color: Color.lobbyArtworkScrim.opacity(0.9), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                    Text(card.title).font(.headline).lineLimit(2)
                    HStack(spacing: AppTheme.Space.s) {
                        Image(systemName: card.action.isPlayable ? AppSymbol.play : "exclamationmark")
                        Text(card.line).lineLimit(1)
                    }
                    .font(.callout)
                    if let fraction = card.fraction {
                        ProgressBar(
                            fraction: fraction, track: Color.lobbyOnArtwork.opacity(0.25), fill: Color.lobbyAccent(.dark), height: 6)
                    }
                }
                .foregroundStyle(Color.lobbyOnArtwork)
                .padding(AppTheme.Space.l)
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
    }
}

/// A category as a wide tile: the household's logo for it, or its symbol and name.
struct TVCategoryTile: View {
    let category: CategoryShelf
    let tint: Color

    var body: some View {
        NavigationLink(value: Route.category(category.id)) {
            TVCategoryLabel(category: category, tint: tint)
        }
        .buttonStyle(.card)
        .accessibilityLabel(category.name)
        .accessibilityValue(category.items.count == 1 ? "1 title" : "\(category.items.count) titles")
    }
}

struct TVCategoryLabel: View {
    let category: CategoryShelf
    let tint: Color
    @Environment(AppModel.self) private var app

    var body: some View {
        let look = app.look(of: category)
        Group {
            VStack(spacing: AppTheme.Space.m) {
                CategoryMark(
                    look: look, fallback: category.source == .genre ? AppSymbol.genre : AppSymbol.category, area: 16_000,
                    maxWidth: 260, maxHeight: 110)
                    .font(.title3)
                // A logo says the name itself.
                if look.logo == nil {
                    Text(category.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(AppTheme.Space.l)
            .foregroundStyle(Color.lobbyOnArtwork)
            .frame(width: 340, height: 190)
            .background {
                let own = look.color.map(Color.lobbyProfile)
                LinearGradient(
                    colors: own.map { [$0.mix(with: .black, by: 0.35), $0.mix(with: .black, by: 0.65)] } ?? Color.lobbyTileFill,
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }
}
