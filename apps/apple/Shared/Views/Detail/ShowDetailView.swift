// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// A show: where the viewer is in it, its seasons and their episodes.
struct ShowDetailView: View {
    let show: Item
    /// The season to open on, when the viewer came from a season card.
    let initialSeasonID: String?

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var chosenSeasonID: String?
    @State private var explained: ShowDetail.Episode?
    @Environment(\.motion) private var motion
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let detail = app.showDetail(for: show)
        let seasonID = chosenSeasonID ?? initialSeasonID ?? detail.currentSeasonID
        let season = detail.seasons.first { $0.id == seasonID } ?? detail.seasons.first

        TitlePage(item: show, facts: detail.facts) {
            if let primary = detail.primary {
                TitleActions(action: primary.action, label: primary.label) {
                    if app.canDownload(primary.episode) || app.downloads[primary.episode.id] != nil {
                        let status = app.downloadStatus(for: primary.episode.id)
                        RoundAction(name: status.kind == .notDownloaded ? "Download" : status.label) {
                            DownloadCircle(item: primary.episode)
                        }
                    }
                    PlayOnButton(item: primary.episode)
                    SendToDeviceButton(item: show)
                    WatchedCircle(isWatched: detail.watch == .watched) { watched in
                        Task { await app.markEpisodes(of: show.id, watched: watched) }
                    }
                    TrailerCircle(item: show)
                }
            }
        } content: {
            DetailColumn {
                if let overview = detail.overview {
                    Text(overview)
                        .font(.body)
                        .lineSpacing(3)
                        .frame(maxWidth: 680, alignment: .leading)
                }
                FactChips(genres: detail.genres, categories: detail.categories)
            }
            RelatedRows(item: show, only: "related")
            DetailColumn {
                if let season {
                    seasonTabs(detail: detail, current: season)
                    VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                        ForEach(season.episodes) { episode in
                            EpisodeRow(episode: episode, show: show) {
                                explained = episode
                            }
                        }
                    }
                    // Another season is another list.
                    .id(season.id)
                    .transition(.lobbySwap(motion))
                } else {
                    Text("Lobby Server has no episodes for this show yet.")
                        .font(.subheadline)
                        .foregroundStyle(.lobbySecondary)
                }
            }
            RelatedRows(item: show, except: "related")
        }
        .sensoryFeedback(.selection, trigger: chosenSeasonID)
        .sensoryFeedback(.success, trigger: detail.watch) { _, now in now == .watched }
        .alert(
            explained.map { Self.headline($0.action) } ?? "",
            isPresented: Binding(get: { explained != nil }, set: { if !$0 { explained = nil } }),
            presenting: explained
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { episode in
            Text(Self.explanation(episode.action))
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShowMenu(detail: detail, season: season)
            }
        }
    }

    /// The seasons beside each other, and what can be done with the one that is open.
    private func seasonTabs(detail: ShowDetail, current: ShowDetail.Season) -> some View {
        let layout = sizeClass == .regular
            ? AnyLayout(HStackLayout(spacing: AppTheme.Space.l)) : AnyLayout(VStackLayout(alignment: .leading, spacing: AppTheme.Space.s))
        return layout {
            if detail.seasons.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: AppTheme.Space.s) {
                        ForEach(detail.seasons) { season in
                            seasonTab(season, isSelected: season.id == current.id)
                        }
                    }
                }
                .scrollIndicators(.never)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("show.season")
            } else {
                Text(current.name)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            if sizeClass == .regular { Spacer(minLength: 0) }
            HStack(spacing: AppTheme.Space.l) {
                DownloadSeasonButton(seasonID: current.id, seasonName: current.name)
                SendSeasonButton(seasonID: current.id, seasonName: current.name)
            }
            .fixedSize()
        }
    }

    private func seasonTab(_ season: ShowDetail.Season, isSelected: Bool) -> some View {
        Button {
            withAnimation(motion.animation(.section)) { chosenSeasonID = season.id }
        } label: {
            Text(season.name)
                .font(.headline)
                .foregroundStyle(isSelected ? Color.lobbyOnAccent : Color.primary)
                .padding(.horizontal, AppTheme.Space.l)
                .frame(minHeight: 40)
                .background(
                    isSelected ? Color.lobbyAccent(.dark) : Color.lobbyChip(scheme), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.lobbyPill)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("show.season.\(season.name)")
    }

    private static func headline(_ action: PlayAction) -> String {
        if case .unavailable(let headline, _) = action { return headline }
        return ""
    }

    private static func explanation(_ action: PlayAction) -> String {
        if case .unavailable(_, let explanation) = action { return explanation }
        return ""
    }
}

/// One episode: a still or its number, the title, the running time, and whether it was watched.
private struct EpisodeRow: View {
    let episode: ShowDetail.Episode
    let show: Item
    /// Called for an episode that cannot play, to show why.
    let explain: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Environment(\.motion) private var motion
    @State private var isSending = false
    @State private var isEditing = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .body) private var wideStill: CGFloat = 232
    @ScaledMetric(relativeTo: .body) private var compactStill: CGFloat = 140

    private var stillWidth: CGFloat { sizeClass == .regular ? min(wideStill, 320) : min(compactStill, 170) }

    var body: some View {
        HStack(spacing: 0) {
            playRow
            if app.canDownload(episode.item) || app.downloads[episode.id] != nil {
                DownloadGlyph(item: episode.item)
            }
        }
    }

    private var playRow: some View {
        Button {
            if let request = episode.action.request {
                app.play(request)
            } else {
                explain()
            }
        } label: {
            HStack(alignment: .center, spacing: sizeClass == .regular ? AppTheme.Space.l : AppTheme.Space.m) {
                still
                VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                    Text(episode.title)
                        .font(.headline)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                    Text(detailLine)
                        .font(.subheadline)
                        .foregroundStyle(.lobbySecondary)
                    if sizeClass == .regular, let overview = episode.item.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.subheadline)
                            .foregroundStyle(.lobbySecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: 620, alignment: .leading)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: AppTheme.Space.s)
                trailing
                    .animation(motion.animation(.change), value: episode.watch == .watched)
            }
            .padding(.vertical, AppTheme.Space.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lobbyRow)
        .contextMenu {
            ItemMenuActions(itemID: episode.id, watch: episode.watch, action: episode.action)
            if app.isManager {
                Button("Send to Device…", systemImage: AppSymbol.sendToDevice) { isSending = true }
            }
            if app.isOwnerManager {
                Button("Edit…", systemImage: AppSymbol.edit) { isEditing = true }
            }
        }
        .sheet(isPresented: $isEditing) {
            ItemEditView(app: app, itemID: episode.id)
        }
        .sheet(isPresented: $isSending) {
            SendToDeviceView(model: SendToDeviceModel(app: app, item: episode.item))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("episode.\(episode.item.episodeNumber.map(String.init) ?? episode.id)")
    }

    private var still: some View {
        ArtworkView(artwork: episode.item.artwork.still, width: stillWidth) {
            ZStack {
                if let backdrop = show.artwork.backdrop {
                    ArtworkView(artwork: backdrop, width: stillWidth) { Color.lobbySurface(scheme) }
                        .overlay { Color.lobbyArtworkScrim.opacity(0.55) }
                } else {
                    Color.lobbySurface(scheme)
                }
                Text(episode.item.episodeNumber.map(String.init) ?? "")
                    .font(.system(.title2, design: .serif, weight: .semibold))
                    .foregroundStyle(show.artwork.backdrop == nil ? Color.lobbySecondaryText(scheme) : Color.lobbyOnArtwork)
            }
        }
        .frame(width: stillWidth, height: stillWidth / AppTheme.wideAspect)
        .overlay(alignment: .bottom) {
            if case .inProgress(let fraction?) = episode.watch {
                ProgressBar(fraction: fraction, track: Color.lobbySurfaceRaised(scheme), fill: Color.lobbyAccent(scheme))
                    .padding(AppTheme.Space.xs)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.tile, style: .continuous))
        .opacity(episode.action.isPlayable ? 1 : 0.5)
    }

    @ViewBuilder
    private var trailing: some View {
        if !episode.action.isPlayable {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Color.lobbyWarning)
        } else if episode.watch == .watched {
            stateSymbol(AppSymbol.done)
        } else {
            stateSymbol("play.circle")
        }
    }

    private func stateSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.title2)
            .foregroundStyle(.lobbySecondary)
            .transition(motion.moves ? .scale(scale: 0.5).combined(with: .opacity) : .opacity)
    }

    private var unavailableHeadline: String? {
        if case .unavailable(let headline, _) = episode.action { return headline }
        return nil
    }

    /// "Downloaded", "Out of date" …: said in words, in the row, for an episode on this device.
    private var downloadWord: String? {
        let status = app.downloadStatus(for: episode.id)
        return status.kind == .notDownloaded ? nil : status.label
    }

    private var detailLine: String {
        [episode.runtime, unavailableHeadline ?? episode.watch.label, downloadWord].compactMap { $0 }.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        [episode.title, episode.runtime, unavailableHeadline ?? episode.watch.label, downloadWord]
            .compactMap { $0 }.joined(separator: ", ")
    }
}
