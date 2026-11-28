// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// A film (or a home video): what it is, Play or Resume, and where the file is.
struct MovieDetailView: View {
    let item: Item

    @Environment(AppModel.self) private var app
    @Environment(\.motion) private var motion

    var body: some View {
        let detail = app.movieDetail(for: item)
        let status = app.downloadStatus(for: item.id)
        TitlePage(item: item, facts: detail.facts) {
            TitleActions(action: detail.action) {
                if app.canDownload(item) || app.downloads[item.id] != nil {
                    RoundAction(name: status.kind == .notDownloaded ? "Download" : status.label) {
                        DownloadCircle(item: item)
                            .accessibilityIdentifier("detail.download")
                    }
                }
                PlayOnButton(item: item)
                SendToDeviceButton(item: item)
                WatchedCircle(isWatched: detail.watch == .watched) { watched in
                    Task {
                        if watched { await app.markWatched(itemID: item.id) } else { await app.markUnwatched(itemID: item.id) }
                    }
                }
                TrailerCircle(item: item)
                StoryCircle(item: item)
            }
            if case .inProgress(let fraction) = detail.watch {
                ResumeLine(fraction: fraction, remaining: detail.remaining)
            }
            if status.kind != .notDownloaded, let line = status.detail {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
                    .accessibilityIdentifier("detail.downloadDetail")
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
            RelatedRows(item: item)
            ExtrasRow(item: item)
            if !detail.fileFacts.isEmpty {
                DetailColumn {
                    MoreFacts {
                        FactRow(symbol: "externaldrive", title: "File", text: detail.fileFacts.joined(separator: " · "))
                            .accessibilityIdentifier("detail.file")
                        if !detail.categories.isEmpty {
                            FactRow(symbol: "folder", title: "Categories", text: detail.categories.joined(separator: ", "))
                        }
                    }
                }
            }
        }
        // Watched, a download's lines: what comes moves the rest aside.
        .animation(motion.animation(.list), value: detail.watch)
        .sensoryFeedback(.success, trigger: detail.watch) { _, now in now == .watched }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ItemMenu(itemID: item.id, watch: detail.watch, action: detail.action)
            }
        }
    }
}

/// The trailers and other extras that are files beside a film, as wide cards that play.
struct ExtrasRow: View {
    let item: Item
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var metrics = TileMetrics()

    init(item: Item) {
        self.item = item
    }

    var body: some View {
        let extras = app.extras(of: item)
        if !extras.isEmpty {
            Shelf(title: "Trailers and Extras") {
                ForEach(extras) { extra in
                    Button {
                        app.play(extra.request)
                    } label: {
                        let width = metrics.wide(sizeClass) * 0.82
                        ArtworkView(artwork: extra.artwork, width: width) { TintField(title: extra.title) }
                            .frame(width: width, height: width / AppTheme.wideAspect)
                            .overlay {
                                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                            }
                            .overlay(alignment: .bottomLeading) {
                                Label(extra.title, systemImage: AppSymbol.play)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.lobbyOnArtwork)
                                    .lineLimit(1)
                                    .padding(AppTheme.Space.m)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
                    }
                    .buttonStyle(.lobbyTile)
                    .accessibilityLabel(extra.title)
                }
            }
        }
    }
}

/// A labelled fact under the summary.
struct FactRow: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
                Text(text)
                    .font(.subheadline)
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.lobbySecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The More menu of a film: what any viewer may do with it beside playing it, and Edit for a
/// manager.
struct ItemMenu: View {
    let itemID: String
    let watch: WatchState
    let action: PlayAction

    @Environment(AppModel.self) private var app
    @State private var isEditing = false

    var body: some View {
        Menu {
            ItemMenuActions(itemID: itemID, watch: watch, action: action)
            // The library is the server owner's: only their managers edit it.
            if app.isOwnerManager {
                Divider()
                Button("Edit…", systemImage: AppSymbol.edit) { isEditing = true }
            }
        } label: {
            Label("More", systemImage: AppSymbol.more)
        }
        .accessibilityIdentifier("detail.more")
        .sheet(isPresented: $isEditing) {
            ItemEditView(app: app, itemID: itemID)
        }
    }
}

/// The More menu of a series: the same for the whole of it and for the season on screen.
struct ShowMenu: View {
    let detail: ShowDetail
    let season: ShowDetail.Season?

    @Environment(AppModel.self) private var app
    @State private var edited: Edited?
    @State private var markersAnswer: String?

    private struct Edited: Identifiable {
        var id: String
    }

    var body: some View {
        Menu {
            if let request = detail.primary?.action.fromBeginning, request.item.id != detail.fromBeginning?.item.id {
                Button("Start This Episode from Beginning", systemImage: AppSymbol.startOver) { app.play(request) }
            }
            if let request = detail.fromBeginning {
                Button("Start from Beginning", systemImage: AppSymbol.startOver) { app.play(request) }
            }
            Section("Series") {
                marks(id: detail.show.id, isWatched: detail.watch == .watched, isTouched: detail.watch != .unwatched)
                if app.isOwnerManager {
                    Button("Edit Series…", systemImage: AppSymbol.edit) { edited = Edited(id: detail.show.id) }
                }
            }
            if let season {
                Section(season.name) {
                    marks(
                        id: season.id, isWatched: season.episodes.allSatisfy { $0.watch == .watched },
                        isTouched: season.episodes.contains { $0.watch != .unwatched })
                    if app.isOwnerManager {
                        Button("Edit \(season.name)…", systemImage: AppSymbol.edit) { edited = Edited(id: season.id) }
                        Button("Find Intros and Credits Again", systemImage: "forward.fill") {
                            Task { await findMarkers(seasonID: season.id) }
                        }
                        .accessibilityIdentifier("detail.findMarkers")
                    }
                }
            }
        } label: {
            Label("More", systemImage: AppSymbol.more)
        }
        .accessibilityIdentifier("detail.more")
        .sheet(item: $edited) { edited in
            ItemEditView(app: app, itemID: edited.id)
        }
        .alert(
            "Intros and Credits",
            isPresented: Binding(get: { markersAnswer != nil }, set: { if !$0 { markersAnswer = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(markersAnswer ?? "")
        }
    }

    private func findMarkers(seasonID: String) async {
        do {
            let files = try await app.findMarkers(itemID: seasonID)
            markersAnswer = files == 0
                ? "This season has no episodes Lobby Server can look at."
                : "Lobby Server is comparing the \(files) episodes of this season now. Skip Intro appears once it found the intros."
        } catch {
            markersAnswer = await app.managerProblem(error)
        }
    }

    @ViewBuilder
    private func marks(id: String, isWatched: Bool, isTouched: Bool) -> some View {
        if !isWatched {
            Button("Mark All as Watched", systemImage: AppSymbol.markWatched) {
                Task { await app.markEpisodes(of: id, watched: true) }
            }
        }
        if isTouched {
            Button("Mark All as Unwatched", systemImage: AppSymbol.markUnwatched) {
                Task { await app.markEpisodes(of: id, watched: false) }
            }
        }
    }
}
