// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

// A child's stories and music on the TV: big covers across the room, a page per story, and a
// player with few, large buttons (docs/kids.md, "Kids music and stories").

/// The stories place, and all there is in Only listening: what was begun, the stories, the music.
struct TVKidsStories: View {
    var onlyListening = false
    @Environment(AppModel.self) private var app

    private static let columns = Array(
        repeating: GridItem(.fixed(TVMetrics.kidsPoster), spacing: TVMetrics.gap, alignment: .top), count: 5)

    var body: some View {
        let music = app.music
        let books = music.isAvailable ? music.catalogue.sortedBooks : []
        let albums = music.isAvailable ? music.catalogue.sortedAlbums : []
        let begun = app.continueListening
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TVMetrics.shelfGap) {
                HStack(spacing: AppTheme.Space.l) {
                    if onlyListening { KidsDoorMark(size: 72) }
                    Text(onlyListening ? "Time to listen" : "Stories")
                        .font(.system(size: 64, weight: .heavy, design: .rounded))
                        .accessibilityAddTraits(.isHeader)
                }
                if books.isEmpty, albums.isEmpty {
                    Text("There is nothing to listen to yet.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .focusable()
                }
                if !begun.isEmpty {
                    TVShelf(title: "Keep listening") {
                        ForEach(begun) { book in
                            Button {
                                app.listen(to: book)
                            } label: {
                                TVStoryCover(title: book.title, coverID: book.coverId, fraction: app.storyPlace(book).fraction, plays: true)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Keep listening to \(book.title)")
                            .accessibilityIdentifier("kids.keepListening.\(book.title)")
                        }
                    }
                }
                if !books.isEmpty {
                    section("Stories") {
                        ForEach(books) { book in
                            NavigationLink(value: KidsRoute(storyID: book.id)) {
                                TVStoryCover(title: book.title, coverID: book.coverId, fraction: app.storyPlace(book).fraction)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(book.title)
                            .accessibilityIdentifier("kids.story.\(book.title)")
                        }
                    }
                }
                if !albums.isEmpty {
                    section("Music") {
                        ForEach(albums) { album in
                            Button {
                                app.listen(to: album)
                            } label: {
                                TVStoryCover(title: album.title, coverID: album.coverId, fraction: nil, plays: true)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(album.title)
                            .accessibilityIdentifier("kids.album.\(album.title)")
                        }
                    }
                }
            }
            .padding(.vertical, AppTheme.Space.xl)
        }
        .scrollClipDisabled()
        .artworkBackground((begun.prefix(1) + books.prefix(2)).compactMap(\.coverId).map(Artwork.musicCover), kids: true)
        .onPlayPauseCommand { app.music.player.togglePlay() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(onlyListening ? "kids.listening" : "kids.stories")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.l) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: TVMetrics.gap) {
                content()
            }
        }
        .focusSection()
    }
}

/// A square cover that grows with the remote's focus, its name under it.
private struct TVStoryCover: View {
    let title: String
    let coverID: String?
    let fraction: Double?
    var plays = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.m) {
            MusicCoverTV(coverID: coverID, size: TVMetrics.kidsPoster)
                .overlay(alignment: .bottom) {
                    if let fraction, fraction > 0 {
                        ProgressBar(fraction: fraction, track: KidsTheme.track, fill: KidsTheme.progress, height: 10)
                            .padding(AppTheme.Space.l)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if plays, fraction == nil {
                        Image(systemName: AppSymbol.play)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(KidsTheme.onPlay)
                            .offset(x: 3)
                            .frame(width: 72, height: 72)
                            .background(KidsTheme.play, in: Circle())
                            .padding(AppTheme.Space.m)
                            .accessibilityHidden(true)
                    }
                }
                .hoverEffect(.highlight)
            Text(title)
                .font(.system(.callout, design: .rounded, weight: .bold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(width: TVMetrics.kidsPoster, alignment: .leading)
    }
}

/// A story's page: the cover, its name, who reads it, Play or Resume, and the film while the
/// child may watch.
struct TVKidsStory: View {
    let storyID: String
    @Environment(AppModel.self) private var app
    @FocusState private var playIsFocused: Bool

    var body: some View {
        if let book = app.music.book(storyID) {
            let place = app.storyPlace(book)
            HStack(alignment: .center, spacing: 100) {
                MusicCoverTV(coverID: book.coverId, size: 600)
                    .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
                VStack(alignment: .leading, spacing: AppTheme.Space.l) {
                    Text(book.title)
                        .font(.system(size: 76, weight: .heavy, design: .rounded))
                        .lineLimit(3)
                        .minimumScaleFactor(0.6)
                        .accessibilityIdentifier("kids.story.title")
                    Text([book.readBy, MusicTime.long(book.durationMs)].compactMap { $0 }.joined(separator: " · "))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    if let fraction = place.fraction, let left = place.leftMs {
                        ProgressBar(fraction: fraction, track: KidsTheme.track, fill: KidsTheme.progress, height: 12)
                            .frame(maxWidth: 500)
                        Text("\(MusicTime.long(left)) left").font(.headline)
                    }
                    Button {
                        app.listen(to: book)
                    } label: {
                        Label(place.label, systemImage: AppSymbol.play).frame(minWidth: 300)
                    }
                    .focused($playIsFocused)
                    .accessibilityIdentifier("kids.story.play")
                    if let film = app.film(ofStory: book) {
                        NavigationLink(value: KidsRoute(itemID: film.id)) {
                            Label("Watch the film", systemImage: AppSymbol.movies).frame(minWidth: 300)
                        }
                        .accessibilityIdentifier("kids.story.film")
                    }
                }
                .frame(maxWidth: 900, alignment: .leading)
            }
            .padding(80)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .artworkBackground(book.coverId.map(Artwork.musicCover), kids: true)
            .defaultFocus($playIsFocused, true)
            .onPlayPauseCommand { app.listen(to: book) }
        } else {
            TVDeadEnd(title: "Nothing here right now", symbol: AppSymbol.stories, text: "")
        }
    }
}

/// What plays, for a child across the room: the cover, the name, how far, back a little, play
/// and pause, and when to stop.
struct TVKidsNowPlaying: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @FocusState private var playIsFocused: Bool

    var body: some View {
        let player = app.music.player
        let isStory = player.book != nil
        HStack(spacing: 100) {
            MusicCoverTV(coverID: player.currentCoverID, size: 600)
                .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
                .scaleEffect(player.isPlaying ? 1 : 0.92)
                .animation(.easeInOut(duration: 0.3), value: player.isPlaying)
            VStack(alignment: .leading, spacing: AppTheme.Space.l) {
                if let track = player.currentTrack {
                    Text(player.book?.title ?? track.title)
                        .font(.system(size: 64, weight: .heavy, design: .rounded))
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .accessibilityIdentifier("kids.player.title")
                    if let line = player.book.flatMap(\.readBy) ?? (isStory ? nil : track.artistCredit) {
                        Text(line).font(.title3).foregroundStyle(.secondary)
                    }
                }
                ProgressBar(
                    fraction: player.duration > 0 ? min(1, player.elapsed / player.duration) : 0,
                    track: KidsTheme.track, fill: KidsTheme.progress, height: 14)
                HStack {
                    Text(MusicTime.clock(player.elapsed))
                    Spacer()
                    Text("-" + MusicTime.clock(max(0, player.duration - player.elapsed)))
                }
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                HStack(spacing: AppTheme.Space.xl) {
                    Button {
                        isStory ? player.skip(by: -15) : player.previous()
                    } label: {
                        Image(systemName: isStory ? "gobackward.15" : "backward.fill").font(.title)
                    }
                    .accessibilityLabel(isStory ? "Back 15 seconds" : "Previous")
                    Button {
                        player.togglePlay()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 64, weight: .bold))
                            .frame(width: 140, height: 120)
                    }
                    .focused($playIsFocused)
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    .accessibilityIdentifier("kids.player.play")
                    Button {
                        isStory ? player.skip(by: 30) : player.next()
                    } label: {
                        Image(systemName: isStory ? "goforward.30" : "forward.fill").font(.title)
                    }
                    .accessibilityLabel(isStory ? "Forward 30 seconds" : "Next")
                    Menu {
                        ForEach(KidsSleep.allCases, id: \.self) { choice in
                            Button(choice.title(isStory: isStory, chapters: !(player.book?.chapters.isEmpty ?? true)),
                                   systemImage: choice.symbol) {
                                switch choice {
                                case .endOfStory: player.setSleepTimer(.endOfTrack)
                                case .off: player.setSleepTimer(nil)
                                case .minutes15, .minutes30: player.sleep(inMinutes: choice.minutes ?? 15)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: player.sleepTimer == nil ? "moon.zzz" : "moon.zzz.fill").font(.title)
                    }
                    .accessibilityLabel("Sleep timer")
                    .accessibilityValue(player.sleepTimer == nil ? "Off" : "On")
                    .accessibilityIdentifier("kids.player.sleep")
                }
                if case .at(let moment)? = player.sleepTimer {
                    Label {
                        Text(timerInterval: Date()...max(Date(), moment), countsDown: true)
                    } icon: {
                        Image(systemName: "moon.zzz.fill")
                    }
                    .font(.headline.monospacedDigit())
                } else if player.sleepTimer == .endOfTrack {
                    Label(KidsSleep.endOfStory.title(isStory: isStory, chapters: !(player.book?.chapters.isEmpty ?? true)),
                          systemImage: "moon.zzz.fill")
                        .font(.headline)
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .artworkBackground(player.currentCoverID.map(Artwork.musicCover), kids: true)
        .preferredColorScheme(.dark)
        .defaultFocus($playIsFocused, true)
        .onPlayPauseCommand { player.togglePlay() }
        .onExitCommand { dismiss() }
        .onChange(of: player.isActive) { _, active in if !active { dismiss() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kids.player")
    }
}
