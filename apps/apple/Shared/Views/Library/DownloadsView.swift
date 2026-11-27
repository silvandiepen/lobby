// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// The Downloads screen: what is on this device and what is on its way. It is built from the
/// device's own records, so it opens the same with Lobby Server out of reach.
struct DownloadsView: View {
    @Environment(AppModel.self) private var app
    @Environment(ServersModel.self) private var servers
    @Environment(\.motion) private var motion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let whole = app.downloadsOverview
        let music = app.music.downloads.collections.sorted { $0.addedAt > $1.addedAt }
        let others = servers.otherServersDownloads
        let titles = Self.titles(of: whole, in: app.catalogue)
        // A few downloads say it all; more are filtered and ordered as the viewer chose.
        let filters = titles.count >= Self.fewest
        Group {
            if whole.isEmpty, music.isEmpty, others.isEmpty {
                ContentUnavailableView {
                    Label("Nothing is downloaded", systemImage: "arrow.down.circle")
                } description: {
                    Text("Films, episodes, albums, playlists and books you download are kept on this device and play without Lobby Server. Open one and choose Download.")
                }
                .accessibilityIdentifier("downloads.empty")
            } else if filters {
                FilteredTitles(list: "downloads", items: titles, fixed: [.downloaded]) { shown in
                    list(whole.keeping(shown.map(\.id)), music: music)
                }
                .padding(.top, AppTheme.Space.s)
            } else {
                list(whole, music: music)
            }
        }
        .animation(motion.animation(.list), value: whole.isEmpty && music.isEmpty && others.isEmpty)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.lobbyBackground(scheme))
        .navigationTitle("Downloads")
    }

    private static let fewest = 4

    /// The films and series of the downloads, as the catalogue knows them when it can.
    static func titles(of overview: DownloadsOverview, in catalogue: Catalogue) -> [Item] {
        overview.films.map { catalogue.item($0.id) ?? $0.item }
            + overview.shows.map { show in
                catalogue.item(show.id)
                    ?? Item(id: show.id, kind: .show, title: show.title, addedAt: show.rows.first?.item.addedAt ?? .distantPast)
            }
    }

    private func list(_ overview: DownloadsOverview, music: [MusicDownloads.Collection]) -> some View {
                List {
                    if !music.isEmpty {
                        Section {
                            ForEach(music) { collection in
                                MusicDownloadRow(collection: collection)
                                    .lobbyPanelRow(isFirst: collection.id == music.first?.id, isLast: collection.id == music.last?.id)
                            }
                        } header: {
                            Text("Music")
                                .lobbyPanelHeading()
                        }
                        .listSectionSeparator(.hidden)
                    }
                    if !overview.films.isEmpty {
                        Section {
                            ForEach(overview.films) { row in
                                DownloadRow(row: row)
                                    .lobbyPanelRow(isFirst: row.id == overview.films.first?.id, isLast: row.id == overview.films.last?.id)
                            }
                        } header: {
                            Text("Films")
                                .lobbyPanelHeading()
                        }
                        .listSectionSeparator(.hidden)
                    }
                    ForEach(overview.shows) { show in
                        Section {
                            ForEach(show.rows) { row in
                                DownloadRow(row: row)
                                    .lobbyPanelRow(isFirst: row.id == show.rows.first?.id, isLast: row.id == show.rows.last?.id)
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(show.title)
                                Text(show.summary)
                                    .font(.footnote)
                                    .textCase(nil)
                            }
                            .lobbyPanelHeading()
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("downloads.show.\(show.title)")
                        }
                    }
                    if let total = overview.total {
                        Section {
                        } footer: {
                            Text(total)
                                .lobbyPanelHeading()
                                .accessibilityIdentifier("downloads.total")
                        }
                    }
                    // What the other servers have on this device, each under its name.
                    OtherServersDownloads()
                }
                // Rows come and go; how far one is, its own bar animates.
                .animation(motion.animation(.list), value: overview.films.map(\.id) + overview.shows.flatMap { $0.rows.map(\.id) })
                .lobbyReadableList()
                .lobbyPage()
                .accessibilityIdentifier("downloads.list")
    }
}

extension DownloadsOverview {
    /// Only the films and series of `ids`, in that order.
    func keeping(_ ids: [String]) -> DownloadsOverview {
        let place = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var kept = self
        kept.films = films.filter { place[$0.id] != nil }.sorted { (place[$0.id] ?? 0) < (place[$1.id] ?? 0) }
        kept.shows = shows.filter { place[$0.id] != nil }.sorted { (place[$0.id] ?? 0) < (place[$1.id] ?? 0) }
        return kept
    }
}

/// One download: what it is, where it is, how large, and the one thing to do next.
private struct DownloadRow: View {
    let row: DownloadsOverview.Row

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: AppTheme.Space.m) {
            Button {
                play()
            } label: {
                VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                    Text(row.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Label {
                        Text([row.caption, row.status.label, row.status.percentText, row.sizeText].compactMap { $0 }.joined(separator: " · "))
                    } icon: {
                        Image(systemName: row.status.symbol)
                            .contentTransition(.symbolEffect(.replace))
                            .foregroundStyle(tint)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.lobbySecondary)
                    if let fraction = row.status.fraction {
                        ProgressBar(fraction: fraction, track: Color.lobbySurfaceRaised(scheme), fill: Color.lobbyAccent(scheme))
                    }
                    if let detail = row.status.detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.lobbySecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.lobbyRow)
            .disabled(!row.isPlayable)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityHint(row.isPlayable ? "Plays the copy on this device" : "")
            .accessibilityIdentifier("download.\(row.title)")

            if let action = row.status.actions.first, action != .remove {
                Button {
                    Task { await app.perform(action, on: row.item) }
                } label: {
                    Image(systemName: DownloadButton.symbol(action))
                        .contentTransition(.symbolEffect(.replace))
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.lobbyIcon)
                .accessibilityLabel(DownloadButton.name(action))
                .accessibilityIdentifier("download.action.\(row.title)")
            } else if row.isPlayable {
                Image(systemName: "play.circle")
                    .font(.title2)
                    .foregroundStyle(.lobbySecondary)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Remove", systemImage: "trash", role: .destructive) {
                Task { await app.removeDownload(itemID: row.id) }
            }
        }
        .contextMenu {
            ForEach(row.status.actions, id: \.self) { action in
                Button(
                    DownloadButton.name(action), systemImage: DownloadButton.symbol(action),
                    role: action == .remove ? .destructive : nil
                ) {
                    Task { await app.perform(action, on: row.item) }
                }
            }
        }
    }

    private var tint: Color {
        switch row.status.kind {
        case .failed: .lobbyFailure
        case .outOfDate, .waitingForNetwork: .lobbyWarning
        case .downloaded: .lobbyAccent(scheme)
        default: .secondary
        }
    }

    /// Plays the copy on this device, from the item stored with it: this works when the
    /// catalogue no longer has the film.
    private func play() {
        let item = app.item(row.id) ?? row.item
        let show = item.kind == .episode ? app.catalogue.show(of: item) : nil
        let action = PlayActionBuilder.action(
            for: item, show: show, progress: app.progress[item.id], context: app.playbackContext)
        if let request = action.request {
            app.play(request)
        }
    }
}

/// An album, playlist or book on this device: how far it is, and its page.
private struct MusicDownloadRow: View {
    let collection: MusicDownloads.Collection

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let music = app.music
        let state = music.downloadState(of: collection.id)
        let (done, total) = music.downloads.progress(of: collection.id)
        let bytes = collection.trackIDs.compactMap { music.downloads.records[$0]?.bytes }.reduce(0, +)
        NavigationLink(value: route) {
            HStack(spacing: AppTheme.Space.m) {
                MusicCover(coverID: coverID, size: 52, radius: 8, symbol: symbol)
                VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                    Text(collection.title)
                        .font(.headline)
                    Text([kind, status(state, done: done, total: total), bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.lobbySecondary)
                    if state != .done, total > 0 {
                        ProgressBar(fraction: Double(done) / Double(total), track: Color.lobbySurfaceRaised(scheme), fill: Color.lobbyAccent(scheme))
                    }
                }
            }
        }
        .accessibilityIdentifier("download.music.\(collection.title)")
        .swipeActions(edge: .trailing) {
            Button("Remove", systemImage: "trash", role: .destructive) { music.removeDownload(collection.id) }
        }
        .contextMenu {
            Button("Remove Download", systemImage: "trash", role: .destructive) { music.removeDownload(collection.id) }
        }
    }

    private var route: Route {
        switch collection.kind {
        case .album: .musicAlbum(collection.id)
        case .playlist: .musicPlaylist(collection.id)
        case .book: .musicBook(collection.id)
        }
    }

    private var kind: String {
        switch collection.kind {
        case .album: "Album"
        case .playlist: "Playlist"
        case .book: "Audiobook"
        }
    }

    private var symbol: String {
        switch collection.kind {
        case .album: AppSymbol.albums
        case .playlist: AppSymbol.playlists
        case .book: AppSymbol.audiobooks
        }
    }

    private var coverID: String? {
        let catalogue = app.music.wholeCatalogue
        switch collection.kind {
        case .album: return catalogue.albums[collection.id]?.coverId
        case .book: return catalogue.books[collection.id]?.coverId
        case .playlist: return collection.trackIDs.lazy.compactMap { catalogue.tracks[$0].flatMap(catalogue.coverID(of:)) }.first
        }
    }

    private func status(_ state: MusicModel.DownloadState, done: Int, total: Int) -> String? {
        switch state {
        case .done: "Downloaded"
        case .downloading: "\(done) of \(total)"
        case .waitingForWiFi: "Waiting for Wi-Fi"
        case .failed: "Some songs failed"
        case .none: nil
        }
    }
}
