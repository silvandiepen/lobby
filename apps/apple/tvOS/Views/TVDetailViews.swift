// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI
import UIKit

/// Picks the page for an item: a film or home video, or a show (a season opens its show).
struct TVItemPage: View {
    let itemID: String
    @Environment(AppModel.self) private var app

    var body: some View {
        if let item = app.item(itemID) {
            switch item.kind {
            case .show:
                TVShowPage(show: item, initialSeasonID: nil)
            case .season:
                if let show = app.wholeCatalogue.show(of: item) {
                    TVShowPage(show: show, initialSeasonID: item.id)
                } else {
                    missing
                }
            default:
                TVMoviePage(item: item)
            }
        } else {
            missing
        }
    }

    private var missing: some View {
        TVDeadEnd(title: "No longer in the library", symbol: "film.stack", text: "This was removed from Lobby Server.")
    }
}

/// The backdrop of a film or show behind its page, running into the background.
struct TVBackdrop: View {
    let title: String
    let artwork: ArtworkSet
    @Environment(\.artworkColors) private var colors
    @Environment(\.colorScheme) private var scheme

    private var page: Color { colors.map { Color($0.base) } ?? .lobbyBackground(scheme) }

    var body: some View {
        ZStack {
            page
            // 960 points are 1920 pixels on a 4K screen: the largest picture the server has.
            ArtworkView(artwork: artwork.backdrop, width: 960) { TintField(title: title).opacity(0.5) }
                .opacity(0.9)
            LinearGradient(
                colors: [page.opacity(0.95), page.opacity(0)],
                startPoint: .leading, endPoint: .trailing)
            LinearGradient(
                stops: [
                    .init(color: page.opacity(0), location: 0.4),
                    .init(color: page, location: 1),
                ],
                startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Title, facts and summary.
private struct TVDetailText: View {
    let title: String
    var logo: Artwork? = nil
    let facts: [String]
    let overview: String?
    @State private var showsAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.l) {
            TitleLogo(
                title: title, logo: logo, font: .system(size: 84, weight: .heavy), maxWidth: 760, maxHeight: 220, lines: 3)
                .accessibilityIdentifier("detail.title")
            if !facts.isEmpty {
                Text(facts.joined(separator: "  ·  "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let overview {
                // Four lines; the whole text on a click.
                Button { showsAll = true } label: {
                    Text(overview)
                        .font(.callout)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppTheme.Space.m)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, -AppTheme.Space.m)
            }
        }
        .frame(maxWidth: TVMetrics.readable, alignment: .leading)
        .arrives(0)
        .sheet(isPresented: $showsAll) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Space.l) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(overview ?? "").font(.headline.weight(.regular))
                }
                .frame(maxWidth: TVMetrics.readable, alignment: .leading)
                .padding(AppTheme.Space.xl)
                .focusable()
            }
        }
    }
}

/// What a page says instead of a Play button.
private struct TVUnavailable: View {
    let headline: String
    let explanation: String

    var body: some View {
        TVNotice(
            symbol: AppSymbol.problem, tint: Color.lobbyWarning, title: headline, text: explanation)
            .accessibilityIdentifier("detail.unavailable")
    }
}

struct TVMoviePage: View {
    let item: Item
    @Environment(AppModel.self) private var app
    @FocusState private var playIsFocused: Bool

    var body: some View {
        let detail = app.movieDetail(for: item)
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Space.xl) {
                Spacer(minLength: 220)
                TVDetailText(title: item.title, logo: item.artwork.logo, facts: detail.facts + detail.genres.prefix(3), overview: detail.overview)
                switch detail.action {
                case .play(let request, let kind, let note):
                    HStack(spacing: TVMetrics.gap) {
                        Button(kind.words, systemImage: AppSymbol.play) { app.play(request) }
                            .focused($playIsFocused)
                            .accessibilityIdentifier("detail.play")
                        TVMarkButtons(itemID: item.id, watch: detail.watch, action: detail.action)
                        TVTrailerButton(item: item)
                    }
                    .focusSection()
                    if case .inProgress(let fraction?) = detail.watch {
                        HStack(spacing: AppTheme.Space.l) {
                            ProgressBar(
                                fraction: fraction, track: Color.primary.opacity(0.2), fill: Color("AccentColor"), height: 6)
                                .frame(width: 360)
                            if let remaining = detail.remaining {
                                Text(remaining).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let note {
                        Text(note).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: TVMetrics.readable, alignment: .leading)
                    }
                case .unavailable(let headline, let explanation):
                    TVUnavailable(headline: headline, explanation: explanation)
                    HStack(spacing: TVMetrics.gap) {
                        if app.serverIsOutOfReach {
                            Button("Try Again", systemImage: AppSymbol.refresh) { Task { await app.refresh() } }
                        }
                        TVMarkButtons(itemID: item.id, watch: detail.watch, action: detail.action)
                    }
                }
                TVRelated(item: item)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, AppTheme.Space.xl)
        }
        .scrollClipDisabled()
        .staggersArrival()
        .background { TVBackdrop(title: item.title, artwork: item.artwork) }
        .artworkBackground(item.artwork.pageColours)
        .defaultFocus($playIsFocused, true)
    }
}

/// Rows of other titles at the end of a title's page.
private struct TVRelated: View {
    let item: Item
    @Environment(AppModel.self) private var app

    var body: some View {
        ForEach(app.related(to: item)) { row in
            if case .items(let items) = row.content {
                TVShelf(title: row.title) { ForEach(items) { TVItemLink(item: $0) } }
            }
        }
    }
}

/// Start from Beginning and the marks, as buttons in a row.
private struct TVMarkButtons: View {
    let itemID: String
    let watch: WatchState
    let action: PlayAction
    @Environment(AppModel.self) private var app

    var body: some View {
        if let request = action.fromBeginning {
            Button("Start from Beginning", systemImage: AppSymbol.startOver) { app.play(request) }
        }
        // One button that changes its words: a button that goes away takes the remote with it.
        let isWatched = watch == .watched
        Button(isWatched ? "Mark as Unwatched" : "Mark as Watched", systemImage: isWatched ? AppSymbol.markUnwatched : AppSymbol.markWatched) {
            Task {
                if isWatched { await app.markUnwatched(itemID: itemID) } else { await app.markWatched(itemID: itemID) }
            }
        }
        .accessibilityIdentifier("detail.mark")
    }
}

struct TVShowPage: View {
    let show: Item
    /// The season to open on, when the viewer came from a season card.
    let initialSeasonID: String?

    @Environment(AppModel.self) private var app
    @State private var chosenSeasonID: String?
    @State private var explained: ShowDetail.Episode?
    @FocusState private var playIsFocused: Bool

    var body: some View {
        let detail = app.showDetail(for: show)
        let seasonID = chosenSeasonID ?? initialSeasonID ?? detail.currentSeasonID
        let season = detail.seasons.first { $0.id == seasonID } ?? detail.seasons.first

        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppTheme.Space.xl) {
                Spacer(minLength: 120)
                TVDetailText(title: show.title, logo: show.artwork.logo, facts: detail.facts + detail.genres.prefix(3), overview: detail.overview)
                actions(detail)
                if detail.seasons.count > 1 {
                    seasonPicker(detail, current: season)
                }
                if let season {
                    Text(season.name)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(season.episodes) { episode in
                        TVEpisodeRow(episode: episode) { explained = episode }
                    }
                    marks(id: season.id, watched: season.episodes.allSatisfy { $0.watch == .watched }, name: "Season")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .focusSection()
                } else {
                    Text("Lobby Server has no episodes for this show yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                TVRelated(item: show)
            }
            .padding(.bottom, AppTheme.Space.xl)
        }
        .scrollClipDisabled()
        .staggersArrival()
        .background { TVBackdrop(title: show.title, artwork: show.artwork) }
        .artworkBackground(show.artwork.pageColours)
        .defaultFocus($playIsFocused, true)
        .alert(
            headline, isPresented: Binding(get: { explained != nil }, set: { if !$0 { explained = nil } }),
            presenting: explained
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { episode in
            if case .unavailable(_, let explanation) = episode.action { Text(explanation) }
        }
    }

    private var headline: String {
        if case .unavailable(let headline, _)? = explained?.action { headline } else { "" }
    }

    @ViewBuilder
    private func actions(_ detail: ShowDetail) -> some View {
        if let primary = detail.primary {
            switch primary.action {
            case .play(let request, _, let note):
                HStack(spacing: TVMetrics.gap) {
                    Button(primary.label, systemImage: AppSymbol.play) { app.play(request) }
                        .focused($playIsFocused)
                        .accessibilityIdentifier("detail.play")
                    if let beginning = detail.fromBeginning {
                        Button("Start from Beginning", systemImage: AppSymbol.startOver) { app.play(beginning) }
                    }
                    marks(id: show.id, watched: detail.watch == .watched, name: "Series")
                    TVTrailerButton(item: show)
                }
                .focusSection()
                if let note {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
            case .unavailable(let headline, let explanation):
                TVUnavailable(headline: headline, explanation: explanation)
                if app.serverIsOutOfReach {
                    Button("Try Again", systemImage: AppSymbol.refresh) { Task { await app.refresh() } }
                }
            }
        }
    }

    private func seasonPicker(_ detail: ShowDetail, current: ShowDetail.Season?) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: AppTheme.Space.l) {
                ForEach(detail.seasons) { season in
                    let isCurrent = season.id == current?.id
                    Button(season.name) { chosenSeasonID = season.id }
                        // The chosen one has a fill of its own: never a bar or a border.
                        .tint(isCurrent ? Color("AccentColor") : nil)
                        .accessibilityAddTraits(isCurrent ? .isSelected : [])
                }
            }
            .padding(.vertical, AppTheme.Space.l)
        }
        .scrollClipDisabled()
        .focusSection()
        .accessibilityIdentifier("show.season")
    }

    private func marks(id: String, watched: Bool, name: String) -> some View {
        Button(
            watched ? "Mark \(name) as Unwatched" : "Mark \(name) as Watched",
            systemImage: watched ? AppSymbol.markUnwatched : AppSymbol.markWatched
        ) {
            Task { await app.markEpisodes(of: id, watched: !watched) }
        }
    }
}

/// One episode: a still or its number, the title, the running time, and whether it was watched.
private struct TVEpisodeRow: View {
    let episode: ShowDetail.Episode
    /// Called for an episode that cannot play, to show why.
    let explain: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            if let request = episode.action.request { app.play(request) } else { explain() }
        } label: {
            HStack(spacing: TVMetrics.gap) {
                still
                VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                    Text(episode.title).font(.headline).lineLimit(2)
                    Text(line).font(.callout).foregroundStyle(.secondary)
                    if let overview = episode.item.overview, !overview.isEmpty {
                        Text(overview).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: symbol)
                    .font(.headline)
                    .foregroundStyle(episode.action.isPlayable ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.lobbyWarning))
                    .padding(.trailing, AppTheme.Space.l)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.lobbySurface(scheme))
        }
        .buttonStyle(.card)
        .contextMenu {
            ItemMenuActions(itemID: episode.id, watch: episode.watch, action: episode.action)
        }
        .accessibilityLabel([episode.title, line].joined(separator: ", "))
        .accessibilityIdentifier("episode.\(episode.item.episodeNumber.map(String.init) ?? episode.id)")
    }

    private var still: some View {
        ArtworkView(artwork: episode.item.artwork.still, width: TVMetrics.still) {
            ZStack {
                Color.lobbySurfaceRaised(scheme)
                Text(episode.item.episodeNumber.map(String.init) ?? "")
                    .font(.system(.title2, design: .serif, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: TVMetrics.still, height: TVMetrics.still / AppTheme.wideAspect)
        .overlay(alignment: .bottom) {
            if case .inProgress(let fraction?) = episode.watch {
                ProgressBar(
                    fraction: fraction, track: Color.lobbyOnArtwork.opacity(0.3), fill: Color.lobbyAccent(.dark), height: 6)
                    .padding(AppTheme.Space.m)
            }
        }
        .clipped()
        .opacity(episode.action.isPlayable ? 1 : 0.5)
    }

    private var symbol: String {
        if !episode.action.isPlayable { return AppSymbol.problem }
        return episode.watch == .watched ? AppSymbol.done : "play.circle"
    }

    private var line: String {
        var state = episode.watch.label
        if case .unavailable(let headline, _) = episode.action { state = headline }
        return [episode.runtime, state].compactMap { $0 }.joined(separator: " · ")
    }
}


/// Trailer, in the YouTube app: tvOS has no web views. Only where that app is there, and the
/// household's own trailer file in Lobby's player otherwise. The choice is made once per page, so
/// that no button goes away under the remote.
private struct TVTrailerButton: View {
    let item: Item
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var trailer: Trailer?
    @State private var looked = false

    var body: some View {
        Group {
            if let trailer {
                Button("Trailer", systemImage: AppSymbol.trailer) {
                    switch trailer {
                    case .youtube(let key): if let url = Trailer.appURL(key: key) { openURL(url) }
                    case .file(let request, _): app.play(request)
                    }
                }
                .accessibilityIdentifier("detail.trailer")
            }
        }
        .onAppear {
            guard !looked else { return }
            looked = true
            trailer = app.trailers(of: item).first { one in
                guard case .youtube(let key) = one else { return true }
                return Trailer.appURL(key: key).map { UIApplication.shared.canOpenURL($0) } ?? false
            }
        }
    }
}
