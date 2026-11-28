// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// The music on the TV: albums and books to browse and play, and what plays. No downloads:
/// tvOS keeps nothing (`AppEnvironment.keepsDownloads`).
private enum TVMusicRoute: Hashable {
    case album(String)
    case book(String)
}

struct TVMusicPage: View {
    @Environment(AppModel.self) private var app
    @State private var path: [TVMusicRoute] = []
    @State private var showsPlayer = false

    var body: some View {
        let music = app.music
        let catalogue = music.catalogue
        let player = music.player
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: TVMetrics.shelfGap) {
                    if let track = player.currentTrack {
                        Button {
                            showsPlayer = true
                        } label: {
                            HStack(spacing: AppTheme.Space.l) {
                                MusicCoverTV(coverID: player.currentCoverID, size: 120)
                                VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                                    Text(player.isPlaying ? "Now Playing" : "Paused")
                                        .font(.caption)
                                        .foregroundStyle(.lobbySecondary)
                                    Text(track.title).font(.headline)
                                    Text(player.book?.title ?? track.artistCredit).font(.subheadline).foregroundStyle(.lobbySecondary)
                                }
                            }
                            .padding(AppTheme.Space.m)
                        }
                        .buttonStyle(.card)
                        .accessibilityIdentifier("tv.music.nowPlaying")
                    }
                    let begun = app.continueListening
                    if !begun.isEmpty {
                        TVShelf(title: "Continue Listening") {
                            ForEach(begun) { bookLink($0) }
                        }
                    }
                    let recent = music.recentlyPlayed
                    if !recent.isEmpty {
                        TVShelf(title: "Recently Played") {
                            ForEach(recent) { entry in
                                switch entry {
                                case .album(let album): albumLink(album)
                                case .book(let book): bookLink(book)
                                }
                            }
                        }
                    }
                    TVShelf(title: "Recently Added") {
                        ForEach(catalogue.recentlyAddedAlbums.prefix(12)) { albumLink($0) }
                    }
                    TVShelf(title: "Albums") {
                        ForEach(catalogue.sortedAlbums) { albumLink($0) }
                    }
                    if !catalogue.books.isEmpty {
                        TVShelf(title: "Stories") {
                            ForEach(catalogue.sortedBooks) { bookLink($0) }
                        }
                    }
                }
                .padding(.vertical, AppTheme.Space.xl)
            }
            .scrollClipDisabled()
            .navigationDestination(for: TVMusicRoute.self) { route in
                switch route {
                case .album(let id): TVMusicAlbum(albumID: id, showsPlayer: $showsPlayer)
                case .book(let id): TVMusicBook(bookID: id, showsPlayer: $showsPlayer)
                }
            }
        }
        .onPlayPauseCommand { player.togglePlay() }
        .fullScreenCover(isPresented: $showsPlayer) {
            TVNowPlaying()
        }
        .overlay {
            if catalogue.isEmpty {
                TVDeadEnd(title: "No music yet", symbol: AppSymbol.music, text: "A manager adds music folders in Server Settings.")
            }
        }
    }

    private func albumLink(_ album: MusicAlbum) -> some View {
        NavigationLink(value: TVMusicRoute.album(album.id)) {
            TVMusicTile(title: album.title, subtitle: album.artistCredit, coverID: album.coverId)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("tv.music.album.\(album.title)")
    }

    private func bookLink(_ book: MusicBook) -> some View {
        NavigationLink(value: TVMusicRoute.book(book.id)) {
            TVMusicTile(title: book.title, subtitle: book.credit ?? "", coverID: book.coverId)
        }
        .buttonStyle(.borderless)
    }
}

/// A square cover that grows with the remote's focus, and its words under it.
private struct TVMusicTile: View {
    let title: String
    let subtitle: String
    let coverID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.s) {
            MusicCoverTV(coverID: coverID, size: 280)
                .hoverEffect(.highlight)
            Text(title).font(.callout.weight(.medium)).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(.lobbySecondary).lineLimit(1)
        }
        .frame(width: 280, alignment: .leading)
    }
}

struct MusicCoverTV: View {
    let coverID: String?
    let size: CGFloat

    var body: some View {
        ArtworkView(artwork: coverID.map(Artwork.musicCover), width: size) {
            ZStack {
                LinearGradient(colors: Color.lobbyTileFill, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: AppSymbol.music).font(.system(size: size * 0.3)).foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
    }
}

private struct TVMusicAlbum: View {
    let albumID: String
    @Binding var showsPlayer: Bool
    @Environment(AppModel.self) private var app

    var body: some View {
        let music = app.music
        if let album = music.album(albumID) {
            let tracks = music.tracks(ofAlbum: album.id)
            HStack(alignment: .top, spacing: 80) {
                VStack(alignment: .leading, spacing: AppTheme.Space.l) {
                    MusicCoverTV(coverID: album.coverId, size: 460)
                    Text(album.title).font(.title2.weight(.bold))
                    Text(album.artistCredit).font(.headline).foregroundStyle(.lobbySecondary)
                    HStack {
                        Button("Play", systemImage: AppSymbol.play) {
                            music.play(album: album)
                            showsPlayer = true
                        }
                        .accessibilityIdentifier("tv.music.play")
                        Button("Shuffle", systemImage: "shuffle") {
                            music.play(album: album, shuffled: true)
                            showsPlayer = true
                        }
                    }
                }
                .frame(width: 460)
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            Button {
                                music.play(album: album, startAt: index)
                                showsPlayer = true
                            } label: {
                                HStack {
                                    Text("\(track.track ?? index + 1)").foregroundStyle(.lobbySecondary).frame(width: 50, alignment: .leading)
                                    Text(track.title)
                                    Spacer()
                                    Text(MusicTime.short(track.durationMs ?? 0)).foregroundStyle(.lobbySecondary)
                                }
                            }
                            .accessibilityIdentifier("tv.music.track.\(track.title)")
                        }
                    }
                }
                .focusSection()
            }
            .padding(60)
            .artworkBackground(album.coverId.map(Artwork.musicCover))
        }
    }
}

private struct TVMusicBook: View {
    let bookID: String
    @Binding var showsPlayer: Bool
    @Environment(AppModel.self) private var app

    var body: some View {
        let music = app.music
        if let book = music.book(bookID) {
            HStack(alignment: .top, spacing: 80) {
                VStack(alignment: .leading, spacing: AppTheme.Space.l) {
                    MusicCoverTV(coverID: book.coverId, size: 460)
                    Text(book.title).font(.title2.weight(.bold))
                    if !book.writers.isEmpty {
                        Text(book.writers.joined(separator: ", ")).font(.headline).foregroundStyle(.lobbySecondary)
                    }
                    Text([book.readBy, MusicTime.long(book.durationMs)].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.lobbySecondary)
                    Button((music.fractionHeard(of: book) ?? 0) > 0 ? "Resume" : "Play", systemImage: AppSymbol.play) {
                        music.player.play(book: book)
                        showsPlayer = true
                    }
                }
                .frame(width: 460)
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                        ForEach(Array(book.chapters.enumerated()), id: \.offset) { index, chapter in
                            Button {
                                music.player.play(book: book, chapter: index)
                                showsPlayer = true
                            } label: {
                                HStack {
                                    Text(chapter.title ?? "Chapter \(index + 1)")
                                    Spacer()
                                    Text(MusicTime.short(chapter.endMs - chapter.startMs)).foregroundStyle(.lobbySecondary)
                                }
                            }
                        }
                    }
                }
                .focusSection()
            }
            .padding(60)
            .artworkBackground(book.coverId.map(Artwork.musicCover))
        }
    }
}

/// What plays, across the room: the cover, the words, the time, and the three buttons.
private struct TVNowPlaying: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let player = app.music.player
        HStack(spacing: 100) {
            MusicCoverTV(coverID: player.currentCoverID, size: 560)
                .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
            VStack(alignment: .leading, spacing: AppTheme.Space.l) {
                if let track = player.currentTrack {
                    Text(track.title).font(.title.weight(.bold)).lineLimit(2)
                    Text(player.book.map { [$0.title, $0.credit].compactMap { $0 }.joined(separator: " · ") }
                        ?? [track.artistCredit, player.currentCollection].compactMap { $0 }.joined(separator: " · "))
                        .font(.headline).foregroundStyle(.lobbySecondary)
                }
                ProgressBar(
                    fraction: player.duration > 0 ? min(1, player.elapsed / player.duration) : 0,
                    track: .lobbySurfaceRaised(scheme), fill: .lobbyAccent(scheme), height: 8)
                HStack {
                    Text(MusicTime.clock(player.elapsed))
                    Spacer()
                    Text("-" + MusicTime.clock(max(0, player.duration - player.elapsed)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.lobbySecondary)
                HStack(spacing: AppTheme.Space.l) {
                    if player.book != nil {
                        Button { player.skip(by: -15) } label: { Image(systemName: "gobackward.15") }
                            .accessibilityLabel("Back 15 seconds")
                    }
                    Button { player.previous() } label: { Image(systemName: "backward.fill") }
                    Button { player.togglePlay() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
                        .accessibilityIdentifier("tv.music.toggle")
                    Button { player.next() } label: { Image(systemName: "forward.fill") }
                    if player.book != nil {
                        Button { player.skip(by: 30) } label: { Image(systemName: "goforward.30") }
                            .accessibilityLabel("Forward 30 seconds")
                    }
                }
                .font(.title2)
            }
            .frame(maxWidth: 800)
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .artworkBackground(player.currentCoverID.map(Artwork.musicCover))
        .onPlayPauseCommand { player.togglePlay() }
        .onExitCommand { dismiss() }
    }
}
