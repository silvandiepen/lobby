// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// The top of an album's, book's or playlist's page: the cover large, its name, a line about
/// it, and what can be done with it.
private struct CollectionHeader<Actions: View>: View {
    let coverID: String?
    let title: String
    let subtitle: String?
    let detail: String
    var symbol = AppSymbol.albums
    @ViewBuilder var actions: Actions

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let isWide = sizeClass == .regular
        let layout = isWide
            ? AnyLayout(HStackLayout(alignment: .bottom, spacing: AppTheme.Space.l))
            : AnyLayout(VStackLayout(alignment: .center, spacing: AppTheme.Space.m))
        layout {
            MusicCover(coverID: coverID, size: isWide ? 240 : 220, radius: AppTheme.Radius.card, symbol: symbol)
                .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
            VStack(alignment: isWide ? .leading : .center, spacing: AppTheme.Space.xs) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(isWide ? .leading : .center)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(Color.lobbyAccent(scheme))
                        .multilineTextAlignment(isWide ? .leading : .center)
                }
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
                actions
                    .padding(.top, AppTheme.Space.s)
            }
            .frame(maxWidth: isWide ? .infinity : nil, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, TileMetrics.margin(sizeClass))
        .padding(.top, AppTheme.Space.l)
    }
}

/// An album: its cover, Play and Shuffle, the download, and its songs in the sleeve's order.
struct MusicAlbumView: View {
    let albumID: String
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let music = app.music
        if let album = music.album(albumID) {
            let tracks = music.tracks(ofAlbum: album.id)
            let discs = Set(tracks.map { $0.disc ?? 1 }).count > 1
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Space.l) {
                    CollectionHeader(
                        coverID: album.coverId, title: album.title, subtitle: album.artistCredit,
                        detail: ([album.genres.first, album.year.map(String.init)].compactMap { $0 }
                            + ["\(album.trackCount) songs", MusicTime.long(album.durationMs)]).joined(separator: " · ")
                    ) {
                        VStack(spacing: AppTheme.Space.m) {
                            PlayButtons(
                                play: { music.play(album: album) }, shuffle: { music.play(album: album, shuffled: true) })
                            HStack(spacing: AppTheme.Space.s) {
                                MusicFavouriteButton(id: album.id, kind: .album)
                                MusicDownloadButton(collectionID: album.id) { music.download(album) }
                                Menu {
                                    MusicTrackMenu(tracks: tracks)
                                    if let artist = album.artistIds.first {
                                        NavigationLink(value: Route.musicArtist(artist)) {
                                            Label("Go to Artist", systemImage: AppSymbol.artists)
                                        }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.title2)
                                        .frame(width: 44, height: 44)
                                }
                                .menuStyle(.button)
                                .buttonStyle(.lobbyIcon)
                                .accessibilityLabel("More")
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            if discs, index == 0 || tracks[index - 1].disc != track.disc {
                                Text("Disc \(track.disc ?? 1)")
                                    .font(.headline)
                                    .foregroundStyle(.lobbySecondary)
                                    .padding(.top, AppTheme.Space.m)
                            }
                            MusicTrackRow(track: track, number: track.track ?? index + 1, showsArtist: track.artistCredit != album.artistCredit) {
                                music.play(album: album, startAt: index)
                            }
                            .rowEase()
                            Divider().opacity(0.4)
                        }
                    }
                    .padding(.horizontal, TileMetrics.margin(sizeClass))
                    .frame(maxWidth: AppTheme.listWidth)
                    .frame(maxWidth: .infinity)
                }
                .padding(.bottom, AppTheme.Space.xl)
            }
            .artworkBackground(album.coverId.map(Artwork.musicCover))
            .navigationTitle(sizeClass == .compact ? "" : album.title)
            .accessibilityIdentifier("music.albumPage")
        } else {
            gone
        }
    }

    private var gone: some View {
        ContentUnavailableView("No longer in the library", systemImage: AppSymbol.albums,
            description: Text("This album was removed from Lobby Server."))
    }
}

/// An artist: their albums, and the songs where they are a guest.
struct MusicArtistView: View {
    let artistID: String
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let music = app.music
        if let artist = music.artist(artistID) {
            let albums = music.catalogue.albums(ofArtist: artist.id)
            let songs = music.catalogue.sortedSongs.filter { $0.artistIds.contains(artist.id) }
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Space.l) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(artist.name)
                            .font(.largeTitle.weight(.bold))
                        Spacer()
                        MusicFavouriteButton(id: artist.id, kind: .artist)
                    }
                    .padding(.horizontal, TileMetrics.margin(sizeClass))
                    PlayButtons(play: { music.play(songs) }, shuffle: { music.play(songs, shuffled: true) })
                        .padding(.horizontal, TileMetrics.margin(sizeClass))
                    Text("Albums")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, TileMetrics.margin(sizeClass))
                    CoverGrid { width in
                        ForEach(albums) { album in
                            NavigationLink(value: Route.musicAlbum(album.id)) {
                                MusicTile(
                                    title: album.title,
                                    subtitle: album.artistIds.contains(artist.id) ? album.year.map(String.init) : "Appears on",
                                    coverID: album.coverId, width: width, symbol: AppSymbol.albums)
                            }
                            .buttonStyle(.lobbyTile(opens: Route.musicAlbum(album.id)))
                        }
                    }
                    Text("Songs")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, TileMetrics.margin(sizeClass))
                    VStack(spacing: 0) {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { index, track in
                            MusicTrackRow(track: track, showsArtist: false) { music.play(songs, startAt: index) }
                        }
                    }
                    .padding(.horizontal, TileMetrics.margin(sizeClass))
                    .frame(maxWidth: AppTheme.listWidth, alignment: .leading)
                }
                .padding(.vertical, AppTheme.Space.l)
            }
            .artworkBackground(albums.compactMap(\.coverId).prefix(3).map(Artwork.musicCover))
            .navigationTitle(sizeClass == .compact ? "" : artist.name)
        } else {
            ContentUnavailableView("No longer in the library", systemImage: AppSymbol.artists,
                description: Text("This artist was removed from Lobby Server."))
        }
    }
}

/// A book: where the viewer is, Resume, the film of the same name, its chapters, how fast it is
/// read, and the download.
struct MusicBookView: View {
    let bookID: String
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let music = app.music
        if let book = music.book(bookID) {
            let progress = music.bookProgress[book.id]
            let isThisBook = music.player.book?.id == book.id
            let position = isThisBook ? music.player.bookPositionMs : progress.map { $0.completed ? 0 : $0.positionMs }
            let begun = (position ?? 0) > 0
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Space.l) {
                    CollectionHeader(
                        coverID: book.coverId, title: book.title,
                        subtitle: book.writers.isEmpty ? nil : book.writers.joined(separator: ", "),
                        detail: ([book.readBy, MusicTime.long(book.durationMs)].compactMap { $0 }).joined(separator: " · "),
                        symbol: AppSymbol.audiobooks
                    ) {
                        VStack(spacing: AppTheme.Space.m) {
                            if let fraction = music.fractionHeard(of: book), fraction > 0, fraction < 1 {
                                VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                                    ProgressBar(fraction: fraction, track: .lobbySurfaceRaised(scheme), fill: .lobbyAccent(scheme), height: 4)
                                    Text("\(MusicTime.long(book.durationMs - (position ?? 0))) left")
                                        .font(.caption)
                                        .foregroundStyle(.lobbySecondary)
                                }
                                .frame(maxWidth: AppTheme.readableWidth)
                            }
                            PlayButtons(playTitle: begun ? "Resume" : "Play", play: {
                                if isThisBook { music.player.resume() } else { music.player.play(book: book) }
                            })
                            StoryFilmLink(book: book)
                            HStack(spacing: AppTheme.Space.s) {
                                MusicFavouriteButton(id: book.id, kind: .book)
                                MusicDownloadButton(collectionID: book.id) { music.download(book) }
                                SpeedMenu()
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                    if let description = book.description {
                        Text(description)
                            .font(.body)
                            .foregroundStyle(.lobbySecondary)
                            .padding(.horizontal, TileMetrics.margin(sizeClass))
                            .frame(maxWidth: AppTheme.readableWidth, alignment: .leading)
                    }
                    if !book.chapters.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Chapters")
                                .font(.title3.weight(.semibold))
                                .padding(.bottom, AppTheme.Space.s)
                            let current = isThisBook ? music.player.currentChapterIndex : position.flatMap { book.chapterIndex(atBookMs: $0) }
                            ForEach(Array(book.chapters.enumerated()), id: \.offset) { index, chapter in
                                Button {
                                    if isThisBook { music.player.jump(toChapter: index) } else { music.player.play(book: book, chapter: index) }
                                } label: {
                                    HStack {
                                        Text(chapter.title ?? "Chapter \(index + 1)")
                                            .foregroundStyle(index == current ? Color.lobbyAccent(scheme) : .primary)
                                        Spacer()
                                        Text(MusicTime.short(chapter.endMs - chapter.startMs))
                                            .font(.footnote.monospacedDigit())
                                            .foregroundStyle(.lobbySecondary)
                                    }
                                    .padding(.vertical, AppTheme.Space.s)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.lobbyRow)
                                .accessibilityIdentifier("music.chapter.\(index)")
                                Divider().opacity(0.4)
                            }
                        }
                        .padding(.horizontal, TileMetrics.margin(sizeClass))
                        .frame(maxWidth: AppTheme.listWidth, alignment: .leading)
                    }
                }
                .padding(.bottom, AppTheme.Space.xl)
            }
            .artworkBackground(book.coverId.map(Artwork.musicCover))
            .navigationTitle(sizeClass == .compact ? "" : book.title)
            .accessibilityIdentifier("music.bookPage")
        } else {
            ContentUnavailableView("No longer in the library", systemImage: AppSymbol.audiobooks,
                description: Text("This book was removed from Lobby Server."))
        }
    }
}

/// How fast a book is read.
struct SpeedMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let music = app.music
        let rate = music.player.book != nil ? music.player.rate : music.bookRate
        Menu {
            Picker("Speed", selection: Binding(
                get: { rate },
                set: { value in
                    music.bookRate = value
                    if music.player.book != nil { music.player.setRate(value) }
                })
            ) {
                ForEach(MusicPlayer.rates, id: \.self) { rate in
                    Text(Self.label(rate)).tag(rate)
                }
            }
        } label: {
            Text(Self.label(rate))
                .font(.headline.monospacedDigit())
                .frame(minWidth: 44, minHeight: 44)
        }
        .menuStyle(.button)
        .buttonStyle(.lobbyIcon)
        .accessibilityLabel("Speed, \(Self.label(rate))")
    }

    static func label(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}

/// A playlist: its songs in its order, to play, rearrange, rename or download.
struct MusicPlaylistView: View {
    let playlistID: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var renaming = false
    @State private var name = ""
    @State private var confirmsDelete = false

    var body: some View {
        let music = app.music
        if let playlist = music.playlists.first(where: { $0.id == playlistID }) {
            let tracks = music.tracks(of: playlist)
            List {
                Section {
                    CollectionHeader(
                        coverID: tracks.lazy.compactMap { music.catalogue.coverID(of: $0) }.first, title: playlist.name, subtitle: nil,
                        detail: "\(playlist.trackIds.count) songs · \(MusicTime.long(tracks.compactMap(\.durationMs).reduce(0, +)))",
                        symbol: AppSymbol.playlists
                    ) {
                        VStack(spacing: AppTheme.Space.m) {
                            PlayButtons(play: { music.play(tracks) }, shuffle: { music.play(tracks, shuffled: true) })
                            HStack(spacing: AppTheme.Space.s) {
                                MusicDownloadButton(collectionID: playlist.id) { music.downloadPlaylist(playlist) }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                Section {
                    // Offsets in the playlist itself: a song in it twice moves as itself.
                    ForEach(Array(playlist.trackIds.enumerated()), id: \.offset) { index, trackID in
                        if let track = music.catalogue.tracks[trackID] {
                            MusicTrackRow(track: track) {
                                music.play(tracks, startAt: tracks.firstIndex { $0.id == trackID } ?? 0)
                            }
                        }
                    }
                    .onMove { source, destination in
                        var ids = playlist.trackIds
                        ids.move(fromOffsets: source, toOffset: destination)
                        Task { await music.setTracks(ids, of: playlist) }
                    }
                    .onDelete { offsets in
                        var ids = playlist.trackIds
                        ids.remove(atOffsets: offsets)
                        Task { await music.setTracks(ids, of: playlist) }
                    }
                    .moveDisabled(!music.canEditPlaylists)
                    .deleteDisabled(!music.canEditPlaylists)
                }
            }
            .lobbyReadableList()
            .lobbyPage()
            .artworkBackground(tracks.lazy.compactMap { music.catalogue.coverID(of: $0) }.first.map(Artwork.musicCover))
            .navigationTitle(playlist.name)
            #if os(iOS)
            .environment(\.editMode, .constant(isEditing ? .active : .inactive))
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        #if os(iOS)
                        Button(isEditing ? "Done" : "Edit Order", systemImage: AppSymbol.reorder) { isEditing.toggle() }
                        #endif
                        Button("Rename…", systemImage: AppSymbol.edit) {
                            name = playlist.name
                            renaming = true
                        }
                        Button("Delete Playlist", systemImage: AppSymbol.remove, role: .destructive) { confirmsDelete = true }
                    } label: {
                        Label("Edit", systemImage: "ellipsis.circle")
                    }
                    .disabled(!music.canEditPlaylists)
                    .accessibilityIdentifier("music.playlist.edit")
                }
            }
            .alert("Rename Playlist", isPresented: $renaming) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    let name = name.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    Task { await music.rename(playlist, to: name) }
                }
            }
            .confirmationDialog("Delete “\(playlist.name)”?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete Playlist", role: .destructive) {
                    Task {
                        await music.delete(playlist)
                        dismiss()
                    }
                }
            } message: {
                Text("The songs stay in the library.")
            }
        } else {
            ContentUnavailableView("No such playlist", systemImage: AppSymbol.playlists,
                description: Text("It was deleted, here or on another device."))
        }
    }
}
