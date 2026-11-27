// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// One of the music's places, by its section.
struct MusicSectionView: View {
    let section: MusicSection

    var body: some View {
        switch section {
        case .home: MusicHomeView()
        case .artists: MusicArtistsView()
        case .albums: MusicAlbumsView()
        case .songs: MusicSongsView()
        case .books: MusicBooksView()
        case .playlists: MusicPlaylistsView()
        case .favourites: MusicFavouritesView()
        }
    }
}

/// When there is nothing to show: no music on the server, or none on this device.
struct MusicEmpty: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.music.showsDownloadedOnly {
            ContentUnavailableView(
                "No music on this device", systemImage: AppSymbol.music,
                description: Text("Albums, playlists and books you download play here without Lobby Server."))
        } else {
            ContentUnavailableView(
                "No music yet", systemImage: AppSymbol.music,
                description: Text("Lobby Server shows music from library folders marked Music or Audiobooks. A manager adds them in Server Settings."))
        }
    }
}

/// The music's front page: the places, what was played and added lately, albums, playlists
/// and books.
struct MusicHomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    private let metrics = MusicShelfMetrics()

    var body: some View {
        let music = app.music
        let catalogue = music.catalogue
        let width = metrics.cover(sizeClass)
        let recent = music.recentlyPlayed
        let added = Array(catalogue.recentlyAddedAlbums.prefix(12))
        ScrollView {
            if catalogue.isEmpty {
                MusicEmpty()
                    .padding(.top, 80)
            } else {
                VStack(alignment: .leading, spacing: AppTheme.Space.shelf) {
                    places
                    if !recent.isEmpty {
                        Shelf(title: "Recently Played") {
                            ForEach(recent) { entry in
                                switch entry {
                                case .album(let album):
                                    albumLink(album, width: width)
                                case .book(let book):
                                    NavigationLink(value: Route.musicBook(book.id)) {
                                        MusicTile(book: book, width: width, music: music)
                                    }
                                    .buttonStyle(.lobbyTile(opens: Route.musicBook(book.id)))
                                }
                            }
                        }
                    }
                    if !added.isEmpty {
                        Shelf(title: "Recently Added") {
                            ForEach(added) { albumLink($0, width: width) }
                        }
                    }
                    Shelf(title: "Albums", seeAll: .music(.albums)) {
                        ForEach(catalogue.sortedAlbums.prefix(20)) { albumLink($0, width: width) }
                    }
                    if !music.playlists.isEmpty {
                        Shelf(title: "Playlists", seeAll: .music(.playlists)) {
                            ForEach(music.playlists) { playlist in
                                NavigationLink(value: Route.musicPlaylist(playlist.id)) {
                                    MusicTile(
                                        title: playlist.name, subtitle: "\(playlist.trackIds.count) songs",
                                        coverID: music.tracks(of: playlist).lazy.compactMap { catalogue.coverID(of: $0) }.first,
                                        width: width, symbol: AppSymbol.playlists)
                                }
                                .buttonStyle(.lobbyTile(opens: Route.musicPlaylist(playlist.id)))
                            }
                        }
                    }
                    if !catalogue.books.isEmpty {
                        Shelf(title: "Audiobooks", seeAll: .music(.books)) {
                            ForEach(catalogue.sortedBooks) { book in
                                NavigationLink(value: Route.musicBook(book.id)) {
                                    MusicTile(book: book, width: width, music: music)
                                }
                                .buttonStyle(.lobbyTile(opens: Route.musicBook(book.id)))
                            }
                        }
                    }
                }
                .padding(.vertical, AppTheme.Space.l)
                .staggersArrival()
            }
        }
        .artworkBackground((recent.first.map(Self.cover) ?? added.first?.coverId).map(Artwork.musicCover))
        .navigationTitle("Music")
        .refreshable { await app.refresh() }
        .accessibilityIdentifier("music.home")
    }

    private static func cover(_ entry: MusicModel.RecentlyPlayed) -> String? {
        switch entry {
        case .album(let album): album.coverId
        case .book(let book): book.coverId
        }
    }

    private func albumLink(_ album: MusicAlbum, width: CGFloat) -> some View {
        NavigationLink(value: Route.musicAlbum(album.id)) {
            MusicTile(album: album, width: width, music: app.music)
        }
        .buttonStyle(.lobbyTile(opens: Route.musicAlbum(album.id)))
        .contextMenu { MusicCollectionMenu(album: album) }
        .accessibilityIdentifier("music.album.\(album.title)")
    }

    /// The other places, as pills: on a phone there is no sidebar to hold them.
    @ViewBuilder
    private var places: some View {
        if sizeClass == .compact {
            ScrollView(.horizontal) {
                HStack(spacing: AppTheme.Space.s) {
                    ForEach(MusicSection.allCases.filter { $0 != .home }, id: \.self) { section in
                        NavigationLink(value: Route.music(section)) {
                            Label(section.title, systemImage: section.symbol)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, AppTheme.Space.m)
                                .padding(.vertical, AppTheme.Space.s)
                                .background(Color.lobbyChip(scheme), in: Capsule())
                        }
                        .buttonStyle(.lobbyPill)
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("music.section.\(section.rawValue)")
                    }
                }
                .padding(.horizontal, AppTheme.Space.page)
            }
            .scrollIndicators(.never)
        }
    }

    @Environment(\.colorScheme) private var scheme
}

/// Play, shuffle, download and the rest for an album, as a context menu.
struct MusicCollectionMenu: View {
    let album: MusicAlbum
    @Environment(AppModel.self) private var app

    var body: some View {
        let music = app.music
        Button("Play", systemImage: AppSymbol.play) { music.play(album: album) }
        Button("Shuffle", systemImage: "shuffle") { music.play(album: album, shuffled: true) }
        MusicTrackMenu(tracks: music.tracks(ofAlbum: album.id))
        if music.downloadState(of: album.id) == .none {
            Button("Download", systemImage: AppSymbol.download) { music.download(album) }
        } else {
            Button("Remove Download", systemImage: AppSymbol.remove, role: .destructive) { music.removeDownload(album.id) }
        }
    }
}

/// Every album, as covers.
struct MusicAlbumsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let albums = app.music.catalogue.sortedAlbums
        ScrollView {
            if albums.isEmpty {
                MusicEmpty().padding(.top, 80)
            } else {
                CoverGrid { width in
                    ForEach(albums) { album in
                        NavigationLink(value: Route.musicAlbum(album.id)) {
                            MusicTile(album: album, width: width, music: app.music)
                        }
                        .buttonStyle(.lobbyTile(opens: Route.musicAlbum(album.id)))
                        .contextMenu { MusicCollectionMenu(album: album) }
                        .accessibilityIdentifier("music.album.\(album.title)")
                    }
                }
            }
        }
        .lobbyPage()
        .navigationTitle("Albums")
    }
}

/// Every artist, by name.
struct MusicArtistsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let artists = app.music.catalogue.sortedArtists
        Group {
            if artists.isEmpty {
                MusicEmpty()
            } else {
                List(artists) { artist in
                    NavigationLink(value: Route.musicArtist(artist.id)) {
                        HStack(spacing: AppTheme.Space.m) {
                            MusicCover(
                                coverID: app.music.catalogue.albums(ofArtist: artist.id).first?.coverId, size: 44, radius: 22,
                                symbol: AppSymbol.artists)
                            Text(artist.name)
                                .font(.body)
                        }
                    }
                    .lobbyPanelRow(isFirst: artist.id == artists.first?.id, isLast: artist.id == artists.last?.id)
                    .accessibilityIdentifier("music.artist.\(artist.name)")
                }
                .lobbyReadableList()
            }
        }
        .lobbyPage()
        .navigationTitle("Artists")
    }
}

/// Every song, by title, with Shuffle on top.
struct MusicSongsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let songs = app.music.catalogue.sortedSongs
        Group {
            if songs.isEmpty {
                MusicEmpty()
            } else {
                List {
                    Section {
                        PlayButtons(play: { app.music.play(songs) }, shuffle: { app.music.play(songs, shuffled: true) })
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    Section {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { index, track in
                            MusicTrackRow(track: track) { app.music.play(songs, startAt: index) }
                                .lobbyPanelRow(isFirst: index == 0, isLast: index == songs.count - 1)
                        }
                    }
                }
                .lobbyReadableList()
            }
        }
        .lobbyPage()
        .navigationTitle("Songs")
    }
}

/// Every book, as covers with how far this viewer is.
struct MusicBooksView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let books = app.music.catalogue.sortedBooks
        ScrollView {
            if books.isEmpty {
                MusicEmpty().padding(.top, 80)
            } else {
                CoverGrid { width in
                    ForEach(books) { book in
                        NavigationLink(value: Route.musicBook(book.id)) {
                            MusicTile(book: book, width: width, music: app.music)
                        }
                        .buttonStyle(.lobbyTile(opens: Route.musicBook(book.id)))
                        .accessibilityIdentifier("music.book.\(book.title)")
                    }
                }
            }
        }
        .lobbyPage()
        .navigationTitle("Audiobooks")
    }
}

/// The viewer's playlists, and a new one.
struct MusicPlaylistsView: View {
    @Environment(AppModel.self) private var app
    @State private var asksName = false
    @State private var name = ""

    var body: some View {
        let music = app.music
        let playlists = music.playlists
        Group {
            if playlists.isEmpty {
                ContentUnavailableView {
                    Label("No playlists yet", systemImage: AppSymbol.playlists)
                } description: {
                    Text("Make one here, or add songs to a new one from their menu.")
                } actions: {
                    newButton
                }
            } else {
                List(playlists) { playlist in
                    NavigationLink(value: Route.musicPlaylist(playlist.id)) {
                        HStack(spacing: AppTheme.Space.m) {
                            MusicCover(
                                coverID: music.tracks(of: playlist).lazy.compactMap { music.catalogue.coverID(of: $0) }.first,
                                size: 52, radius: 8, symbol: AppSymbol.playlists)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                Text("\(playlist.trackIds.count) songs")
                                    .font(.footnote)
                                    .foregroundStyle(.lobbySecondary)
                            }
                        }
                    }
                    .lobbyPanelRow(isFirst: playlist.id == playlists.first?.id, isLast: playlist.id == playlists.last?.id)
                    .accessibilityIdentifier("music.playlist.\(playlist.name)")
                }
                .lobbyReadableList()
            }
        }
        .lobbyPage()
        .navigationTitle("Playlists")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { newButton }
        }
        .alert("New Playlist", isPresented: $asksName) {
            TextField("Name", text: $name)
                .accessibilityIdentifier("music.playlist.name")
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = name.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task { await music.createPlaylist(name: name) }
            }
        }
    }

    private var newButton: some View {
        Button("New Playlist", systemImage: AppSymbol.add) {
            name = ""
            asksName = true
        }
        .disabled(!app.music.canEditPlaylists)
        .accessibilityIdentifier("music.playlist.new")
    }
}

/// What the viewer loves: songs, albums, artists and books.
struct MusicFavouritesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    private let metrics = MusicShelfMetrics()

    var body: some View {
        let music = app.music
        let songs = music.favouriteSongs
        let albums = music.favouriteAlbums
        let artists = music.favouriteArtists
        let books = music.favouriteBooks
        let width = metrics.cover(sizeClass)
        ScrollView {
            if songs.isEmpty, albums.isEmpty, artists.isEmpty, books.isEmpty {
                ContentUnavailableView(
                    "No favourites yet", systemImage: AppSymbol.favourite,
                    description: Text("Tap the heart on a song, album, artist or book."))
                    .padding(.top, 80)
            } else {
                VStack(alignment: .leading, spacing: AppTheme.Space.shelf) {
                    if !albums.isEmpty {
                        Shelf(title: "Albums") {
                            ForEach(albums) { album in
                                NavigationLink(value: Route.musicAlbum(album.id)) {
                                    MusicTile(album: album, width: width, music: music)
                                }
                                .buttonStyle(.lobbyTile(opens: Route.musicAlbum(album.id)))
                            }
                        }
                    }
                    if !artists.isEmpty {
                        Shelf(title: "Artists") {
                            ForEach(artists) { artist in
                                NavigationLink(value: Route.musicArtist(artist.id)) {
                                    MusicTile(
                                        title: artist.name, subtitle: nil,
                                        coverID: music.catalogue.albums(ofArtist: artist.id).first?.coverId, width: width,
                                        symbol: AppSymbol.artists)
                                }
                                .buttonStyle(.lobbyTile(opens: Route.musicArtist(artist.id)))
                            }
                        }
                    }
                    if !books.isEmpty {
                        Shelf(title: "Audiobooks") {
                            ForEach(books) { book in
                                NavigationLink(value: Route.musicBook(book.id)) {
                                    MusicTile(book: book, width: width, music: music)
                                }
                                .buttonStyle(.lobbyTile(opens: Route.musicBook(book.id)))
                            }
                        }
                    }
                    if !songs.isEmpty {
                        VStack(alignment: .leading, spacing: AppTheme.Space.m) {
                            HStack {
                                Text("Songs").font(.title3.weight(.semibold))
                                Spacer()
                                Button("Shuffle", systemImage: "shuffle") { music.play(songs, shuffled: true) }
                                    .buttonStyle(.lobbyText)
                            }
                            ForEach(Array(songs.enumerated()), id: \.element.id) { index, track in
                                MusicTrackRow(track: track) { music.play(songs, startAt: index) }
                            }
                        }
                        .padding(.horizontal, TileMetrics.margin(sizeClass))
                        .frame(maxWidth: AppTheme.listWidth, alignment: .leading)
                    }
                }
                .padding(.vertical, AppTheme.Space.l)
            }
        }
        .lobbyPage()
        .navigationTitle("Favourites")
    }
}

/// Play and Shuffle, side by side, as every collection starts.
struct PlayButtons: View {
    var playTitle = "Play"
    let play: () -> Void
    var shuffle: (() -> Void)?

    var body: some View {
        HStack(spacing: AppTheme.Space.m) {
            Button(action: play) {
                Label(playTitle, systemImage: AppSymbol.play)
            }
            .buttonStyle(ProminentButtonStyle())
            .accessibilityIdentifier("music.play")
            if let shuffle {
                Button(action: shuffle) {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("music.shuffle")
            }
        }
        .frame(maxWidth: AppTheme.readableWidth)
    }
}

/// What of the music matches a search: artists, albums and books as covers, songs as rows.
struct MusicSearchResults: View {
    let result: MusicCatalogue.SearchResult
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    private let metrics = MusicShelfMetrics()

    var body: some View {
        let music = app.music
        let width = metrics.cover(sizeClass) * 0.85
        VStack(alignment: .leading, spacing: AppTheme.Space.l) {
            if !result.artists.isEmpty || !result.albums.isEmpty || !result.books.isEmpty {
                Shelf(title: "Music") {
                    ForEach(result.artists) { artist in
                        NavigationLink(value: Route.musicArtist(artist.id)) {
                            MusicTile(
                                title: artist.name, subtitle: "Artist",
                                coverID: music.catalogue.albums(ofArtist: artist.id).first?.coverId, width: width,
                                symbol: AppSymbol.artists)
                        }
                        .buttonStyle(.lobbyTile(opens: Route.musicArtist(artist.id)))
                    }
                    ForEach(result.albums) { album in
                        NavigationLink(value: Route.musicAlbum(album.id)) {
                            MusicTile(album: album, width: width, music: music)
                        }
                        .buttonStyle(.lobbyTile(opens: Route.musicAlbum(album.id)))
                        .accessibilityIdentifier("search.album.\(album.title)")
                    }
                    ForEach(result.books) { book in
                        NavigationLink(value: Route.musicBook(book.id)) {
                            MusicTile(book: book, width: width, music: music)
                        }
                        .buttonStyle(.lobbyTile(opens: Route.musicBook(book.id)))
                    }
                }
            }
            if !result.songs.isEmpty {
                VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                    Text("Songs")
                        .font(.title3.weight(.semibold))
                    ForEach(Array(result.songs.enumerated()), id: \.element.id) { index, track in
                        MusicTrackRow(track: track) { music.play(result.songs, startAt: index) }
                    }
                }
                .padding(.horizontal, TileMetrics.margin(sizeClass))
                .frame(maxWidth: AppTheme.listWidth, alignment: .leading)
            }
        }
        .padding(.bottom, AppTheme.Space.l)
    }
}
