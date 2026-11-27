// SPDX-License-Identifier: MPL-2.0
import AVKit
import LobbyKit
import SwiftUI

// The pieces every music screen is made of. Covers are square; everything else is the app's
// own look: its surfaces, its buttons and how they move.

/// A cover from Lobby Server, or a quiet tile with a note while there is none.
struct MusicCover: View {
    let coverID: String?
    let size: CGFloat
    var radius: CGFloat = AppTheme.Radius.tile
    var symbol = AppSymbol.music

    var body: some View {
        ArtworkView(artwork: coverID.map(Artwork.musicCover), width: size) {
            ZStack {
                LinearGradient(colors: Color.lobbyTileFill, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: symbol)
                    .font(.system(size: size * 0.32, weight: .semibold))
                    .foregroundStyle(Color.lobbyOnArtwork.opacity(0.75))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .tileArtworkSource(cornerRadius: radius)
        .accessibilityHidden(true)
    }
}

/// An album, book or playlist in a grid or on a shelf: its cover with two lines under it.
struct MusicTile: View {
    let title: String
    let subtitle: String?
    let coverID: String?
    let width: CGFloat
    var symbol = AppSymbol.music
    /// 0…1 of a book that was begun.
    var fraction: Double? = nil
    var isDownloaded = false

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.s) {
            MusicCover(coverID: coverID, size: width, symbol: symbol)
                .overlay(alignment: .bottom) {
                    if let fraction, fraction > 0 {
                        ProgressBar(fraction: fraction, track: .white.opacity(0.35), fill: .lobbyAccent(scheme))
                            .padding(AppTheme.Space.s)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: AppTheme.Space.xs) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if isDownloaded {
                        Image(systemName: AppSymbol.done)
                            .font(.caption2)
                            .foregroundStyle(.lobbySecondary)
                            .accessibilityLabel("Downloaded")
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
            .frame(width: width, alignment: .leading)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension MusicTile {
    init(album: MusicAlbum, width: CGFloat, music: MusicModel) {
        self.init(
            title: album.title, subtitle: album.artistCredit, coverID: album.coverId, width: width, symbol: AppSymbol.albums,
            isDownloaded: music.downloadState(of: album.id) == .done)
    }

    init(book: MusicBook, width: CGFloat, music: MusicModel) {
        self.init(
            title: book.title, subtitle: book.credit, coverID: book.coverId, width: width,
            symbol: AppSymbol.audiobooks, fraction: music.fractionHeard(of: book),
            isDownloaded: music.downloadState(of: book.id) == .done)
    }
}

/// Square tiles in rows: two across on a phone, as many as fit in a wide window.
struct CoverGrid<Content: View>: View {
    @ViewBuilder var content: (CGFloat) -> Content
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var available: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var regular: CGFloat = 170

    var body: some View {
        let gap = sizeClass == .regular ? AppTheme.Space.l : AppTheme.Space.m
        let count = sizeClass == .regular ? max(2, Int((available + gap) / (min(regular, 240) + gap))) : 2
        let width = max(80, ((available + gap) / CGFloat(count) - gap).rounded(.down))
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(width), spacing: gap, alignment: .top), count: count),
            alignment: .leading, spacing: AppTheme.Space.l
        ) {
            if available > 0 { content(width) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
        .padding(.horizontal, TileMetrics.margin(sizeClass))
        .padding(.vertical, AppTheme.Space.m)
    }
}

/// How wide an album on a shelf is.
struct MusicShelfMetrics: DynamicProperty {
    @ScaledMetric(relativeTo: .body) private var regular: CGFloat = 164
    @Environment(\.lobbyContentWidth) private var contentWidth

    func cover(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        sizeClass == .regular ? min(regular, 230) : max(120, ((contentWidth - 2 * AppTheme.Space.page - AppTheme.Space.tile) / 2.4).rounded(.down))
    }
}

/// One song in a list: its number or cover, title, artist and length. A tap plays it from
/// here; the menu has the rest.
struct MusicTrackRow: View {
    let track: MusicTrack
    /// The number on the sleeve, in an album; nil shows the cover.
    var number: Int? = nil
    var showsArtist = true
    var action: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let music = app.music
        let isCurrent = music.player.currentTrack?.id == track.id
        HStack(spacing: AppTheme.Space.m) {
            Button(action: action) {
                HStack(spacing: AppTheme.Space.m) {
                    Group {
                        if let number {
                            ZStack {
                                if isCurrent {
                                    Image(systemName: music.player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                                        .foregroundStyle(Color.lobbyAccent(scheme))
                                        .symbolEffect(.variableColor.iterative, isActive: music.player.isPlaying)
                                } else {
                                    Text(String(number))
                                        .foregroundStyle(.lobbySecondary)
                                }
                            }
                            .font(.subheadline.monospacedDigit())
                            .frame(width: 28)
                        } else {
                            MusicCover(coverID: music.wholeCatalogue.coverID(of: track), size: 44, radius: 6)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.body)
                            .foregroundStyle(isCurrent ? Color.lobbyAccent(scheme) : .primary)
                            .lineLimit(1)
                        if showsArtist {
                            Text(track.artistCredit)
                                .font(.footnote)
                                .foregroundStyle(.lobbySecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: AppTheme.Space.s)
                    if music.isFavourite(track.id) {
                        Image(systemName: AppSymbol.favourite)
                            .font(.caption)
                            .foregroundStyle(Color.lobbyAccent(scheme))
                            .accessibilityLabel("Favourite")
                    }
                    if let ms = track.durationMs {
                        Text(MusicTime.short(ms))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.lobbySecondary)
                    }
                }
                .padding(.vertical, AppTheme.Space.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.lobbyRow)
            .accessibilityIdentifier("music.track.\(track.title)")
            .opacity(track.available || music.downloads.records[track.id]?.isPlayable == true ? 1 : 0.5)

            Menu {
                MusicTrackMenu(tracks: [track])
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.lobbySecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.lobbyIcon)
            .accessibilityLabel("More for \(track.title)")
        }
        .contextMenu { MusicTrackMenu(tracks: [track]) }
    }
}

/// What can be done with songs: next, later, a playlist, a favourite.
struct MusicTrackMenu: View {
    let tracks: [MusicTrack]
    @Environment(AppModel.self) private var app

    var body: some View {
        let music = app.music
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            music.player.playNext(tracks.map(\.id))
        }
        Button("Play Later", systemImage: "text.line.last.and.arrowtriangle.forward") {
            music.player.addToQueue(tracks.map(\.id))
        }
        AddToPlaylistMenu(trackIDs: tracks.map(\.id))
        if tracks.count == 1, let track = tracks.first {
            let isFavourite = music.isFavourite(track.id)
            Button(isFavourite ? "Remove from Favourites" : "Add to Favourites", systemImage: isFavourite ? "heart.slash" : "heart") {
                music.toggleFavourite(track.id, kind: .track)
            }
            if let album = track.albumId {
                NavigationLink(value: Route.musicAlbum(album)) {
                    Label("Go to Album", systemImage: AppSymbol.albums)
                }
            }
            if let artist = track.artistIds.first {
                NavigationLink(value: Route.musicArtist(artist)) {
                    Label("Go to Artist", systemImage: AppSymbol.artists)
                }
            }
        }
    }
}

/// The viewer's playlists, and a new one.
struct AddToPlaylistMenu: View {
    let trackIDs: [String]
    @Environment(AppModel.self) private var app
    @State private var asksName = false
    @State private var name = ""

    var body: some View {
        let music = app.music
        Menu("Add to Playlist", systemImage: "text.badge.plus") {
            Button("New Playlist…", systemImage: AppSymbol.add) {
                name = ""
                asksName = true
            }
            ForEach(music.playlists) { playlist in
                Button(playlist.name) {
                    Task { await music.add(trackIDs, to: playlist) }
                }
            }
        }
        .disabled(!music.canEditPlaylists)
        .alert("New Playlist", isPresented: $asksName) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = name.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task { await music.createPlaylist(name: name, trackIDs: trackIDs) }
            }
        }
    }
}

/// Download, its progress, or that it is here, for an album, playlist or book.
struct MusicDownloadButton: View {
    let collectionID: String
    let start: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let music = app.music
        let state = music.downloadState(of: collectionID)
        Menu {
            switch state {
            case .none:
                Button("Download", systemImage: AppSymbol.download, action: start)
            case .failed:
                Button("Try Again", systemImage: "arrow.clockwise") { music.retryDownloads() }
                Button("Remove Download", systemImage: AppSymbol.remove, role: .destructive) { music.removeDownload(collectionID) }
            default:
                Button("Remove Download", systemImage: AppSymbol.remove, role: .destructive) { music.removeDownload(collectionID) }
            }
        } label: {
            Group {
                switch state {
                case .none:
                    Image(systemName: AppSymbol.download)
                case .done:
                    Image(systemName: AppSymbol.done)
                        .foregroundStyle(Color.lobbyAccent(scheme))
                case .downloading(let done, let total), .waitingForWiFi(let done, let total), .failed(let done, let total):
                    ZStack {
                        Circle().stroke(Color.lobbySurfaceRaised(scheme), lineWidth: 3)
                        Circle().trim(from: 0, to: total > 0 ? Double(done) / Double(total) : 0)
                            .stroke(Color.lobbyAccent(scheme), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 22, height: 22)
                }
            }
            .font(.title2)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        } primaryAction: {
            if state == .none { start() }
        }
        .menuStyle(.button)
        .buttonStyle(.lobbyIcon)
        .accessibilityLabel(label(state))
        .accessibilityIdentifier("music.download")
    }

    private func label(_ state: MusicModel.DownloadState) -> String {
        switch state {
        case .none: "Download"
        case .done: "Downloaded"
        case .downloading(let done, let total): "Downloading, \(done) of \(total)"
        case .waitingForWiFi: "Waiting for Wi-Fi"
        case .failed: "Download failed"
        }
    }
}

/// The heart of an album, artist or book.
struct MusicFavouriteButton: View {
    let id: String
    let kind: MusicKind
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let isFavourite = app.music.isFavourite(id)
        Button {
            app.music.toggleFavourite(id, kind: kind)
        } label: {
            Image(systemName: isFavourite ? "heart.fill" : "heart")
                .font(.title2)
                .foregroundStyle(isFavourite ? Color.lobbyAccent(scheme) : .primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.lobbyIcon)
        .sensoryFeedback(.selection, trigger: isFavourite)
        .accessibilityLabel(isFavourite ? "Remove from Favourites" : "Add to Favourites")
    }
}

/// Where the sound goes: this device, AirPlay, headphones.
struct RoutePickerButton: View {
    var body: some View {
        RoutePicker()
            .frame(width: 44, height: 44)
            .accessibilityLabel("AirPlay")
    }
}

#if os(iOS)
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = .label
    }
}
#elseif os(macOS)
private struct RoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}
#else
private struct RoutePicker: View {
    var body: some View { EmptyView() }
}
#endif

/// What plays, at the foot of every page: tap for the full player.
struct MiniPlayer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Environment(\.motion) private var motion

    var body: some View {
        let player = app.music.player
        if let track = player.currentTrack {
            HStack(spacing: AppTheme.Space.m) {
                Button {
                    player.showsNowPlaying = true
                } label: {
                    HStack(spacing: AppTheme.Space.m) {
                        MusicCover(coverID: player.currentCoverID, size: 42, radius: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            // A story of one file is its own title: who reads it says more.
                            Text(player.book.map { $0.title == track.title ? $0.credit ?? $0.title : $0.title } ?? track.artistCredit)
                                .font(.caption)
                                .foregroundStyle(.lobbySecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.lobbyRow)
                .accessibilityLabel("Now playing: \(track.title), \(track.artistCredit)")
                .accessibilityHint("Opens the player")
                .accessibilityIdentifier("music.mini")

                Button {
                    player.togglePlay()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.lobbyIcon)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("music.mini.play")

                Button {
                    player.book == nil ? player.next() : player.skip(by: 30)
                } label: {
                    Image(systemName: player.book == nil ? "forward.fill" : "goforward.30")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.lobbyIcon)
                .accessibilityLabel(player.book == nil ? "Next" : "Forward 30 seconds")
            }
            .foregroundStyle(.primary)
            .padding(.leading, AppTheme.Space.s)
            .padding(.trailing, AppTheme.Space.xs)
            .padding(.vertical, AppTheme.Space.s)
            .overlay(alignment: .bottom) {
                if player.duration > 0 {
                    ProgressBar(fraction: min(1, player.elapsed / player.duration), track: .clear, fill: .lobbyAccent(scheme), height: 2)
                        .padding(.horizontal, AppTheme.Space.m)
                }
            }
            .lobbyPanel(cornerRadius: AppTheme.Radius.card)
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .padding(.horizontal, AppTheme.Space.s)
            .padding(.bottom, AppTheme.Space.xs)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

extension View {
    /// The mini player at the foot of the page while something plays.
    func musicMiniPlayer() -> some View {
        modifier(MiniPlayerInset())
    }
}

private struct MiniPlayerInset: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MiniPlayer()
                    .frame(maxWidth: AppTheme.listWidth)
                    .animation(motion.animation(.open), value: app.music.player.isActive)
            }
    }
}

extension View {
    /// The full player, over everything, when the mini player is tapped.
    func musicPlayerSheet() -> some View {
        modifier(MusicPlayerSheet())
    }
}

private struct MusicPlayerSheet: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        let player = app.music.player
        // A child gets its own player, over the whole screen.
        let forKids = app.showsKidsScreens
        let grownUps = Binding(get: { player.showsNowPlaying && !forKids }, set: { player.showsNowPlaying = $0 })
        let kids = Binding(get: { player.showsNowPlaying && forKids }, set: { player.showsNowPlaying = $0 })
        content
            .sheet(isPresented: grownUps) {
                NowPlayingView()
                    .environment(app)
                    #if os(iOS)
                    .presentationDragIndicator(.visible)
                    #endif
            }
            #if os(iOS)
            .fullScreenCover(isPresented: kids) {
                KidsNowPlaying()
                    .environment(app)
            }
            #else
            .background {
                // One view holds one sheet here: the kids player hangs on a view of its own.
                Color.clear.sheet(isPresented: kids) {
                    KidsNowPlaying()
                        .environment(app)
                }
            }
            #endif
            .alert(
                "Music",
                isPresented: Binding(
                    get: { app.music.problem != nil || app.music.player.problem != nil },
                    set: { if !$0 { app.music.problem = nil; app.music.player.problem = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(app.music.problem ?? app.music.player.problem ?? "")
            }
    }
}
