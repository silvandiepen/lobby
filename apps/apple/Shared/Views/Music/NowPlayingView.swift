// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// The full player: the cover large in its own colours, the scrubber, the controls, where the
/// sound goes, the sleep timer, and the queue or a book's chapters.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var scheme
    @Environment(\.motion) private var motion
    @State private var showsQueue = false
    /// While the scrubber is held: where it would go.
    @State private var scrubbing: Double?

    var body: some View {
        let player = app.music.player
        NavigationStack {
            Group {
                if let track = player.currentTrack {
                    content(player, track)
                } else {
                    ContentUnavailableView("Nothing is playing", systemImage: AppSymbol.music)
                }
            }
            .artworkBackground(player.currentCoverID.map(Artwork.musicCover))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "chevron.down") { dismiss() }
                        .accessibilityIdentifier("music.player.close")
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 640)
        #endif
        .onChange(of: player.isActive) { _, active in if !active { dismiss() } }
        .accessibilityIdentifier("music.player")
    }

    @ViewBuilder
    private func content(_ player: MusicPlayer, _ track: MusicTrack) -> some View {
        let wide = sizeClass == .regular
        GeometryReader { proxy in
            let coverSize = min(proxy.size.width - 2 * AppTheme.Space.xl, wide ? 380 : 340, proxy.size.height * 0.42)
            ScrollView {
                VStack(spacing: AppTheme.Space.l) {
                    if showsQueue {
                        queue(player)
                            .transition(.opacity)
                    } else {
                        MusicCover(coverID: player.currentCoverID, size: max(160, coverSize), radius: AppTheme.Radius.card)
                            .scaleEffect(player.isPlaying || !motion.moves ? 1 : 0.88)
                            .shadow(color: .black.opacity(0.35), radius: 24, y: 14)
                            .animation(motion.animation(.open), value: player.isPlaying)
                            .padding(.top, AppTheme.Space.l)
                            .transition(.opacity)
                    }
                    titles(player, track)
                    scrubber(player)
                    transport(player)
                    extras(player)
                }
                .padding(.horizontal, AppTheme.Space.xl)
                .padding(.bottom, AppTheme.Space.xl)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
        }
        .animation(motion.animation(.section), value: showsQueue)
    }

    private func titles(_ player: MusicPlayer, _ track: MusicTrack) -> some View {
        HStack(alignment: .center, spacing: AppTheme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(chapterTitle(player) ?? track.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .accessibilityIdentifier("music.player.title")
                Text(player.book.map { [$0.title, $0.credit].compactMap { $0 }.joined(separator: " · ") }
                    ?? [track.artistCredit, player.currentCollection].compactMap { $0 }.joined(separator: " · "))
                    .font(.body)
                    .foregroundStyle(.lobbySecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if player.book == nil {
                MusicFavouriteButton(id: track.id, kind: .track)
            }
        }
    }

    private func chapterTitle(_ player: MusicPlayer) -> String? {
        guard let book = player.book, let index = player.currentChapterIndex else { return nil }
        return book.chapters[index].title ?? "Chapter \(index + 1)"
    }

    private func scrubber(_ player: MusicPlayer) -> some View {
        let duration = max(player.duration, 0.1)
        let shown = scrubbing ?? player.elapsed
        return VStack(spacing: AppTheme.Space.xs) {
            Slider(
                value: Binding(get: { min(shown, duration) }, set: { scrubbing = $0 }),
                in: 0...duration
            ) { editing in
                if !editing, let scrubbing {
                    player.seek(to: scrubbing)
                    self.scrubbing = nil
                }
            }
            .tint(Color.lobbyAccent(scheme))
            .accessibilityLabel("Position")
            .accessibilityValue("\(MusicTime.clock(shown)) of \(MusicTime.clock(duration))")
            HStack {
                Text(MusicTime.clock(shown))
                Spacer()
                if player.isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Text("-" + MusicTime.clock(max(0, duration - shown)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.lobbySecondary)
        }
    }

    private func transport(_ player: MusicPlayer) -> some View {
        HStack(spacing: AppTheme.Space.xl) {
            if player.book != nil {
                control("gobackward.15", "Back 15 seconds") { player.skip(by: -15) }
            }
            control("backward.fill", player.book == nil ? "Previous" : "Previous chapter") { player.previous() }
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(Color.lobbyProminentLabel(scheme))
                    .frame(width: 72, height: 72)
                    .background(Color.lobbyProminentFill(scheme), in: Circle())
            }
            .buttonStyle(.lobbyIcon)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("music.player.play")
            control("forward.fill", player.book == nil ? "Next" : "Next chapter") { player.next() }
            if player.book != nil {
                control("goforward.30", "Forward 30 seconds") { player.skip(by: 30) }
            }
        }
        .font(.title2)
        .foregroundStyle(.primary)
        .padding(.vertical, AppTheme.Space.s)
    }

    private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.lobbyIcon)
        .accessibilityLabel(label)
    }

    private func extras(_ player: MusicPlayer) -> some View {
        HStack {
            if player.book == nil {
                Button {
                    player.setShuffled(!player.queue.isShuffled)
                } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(player.queue.isShuffled ? Color.lobbyAccent(scheme) : .primary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.lobbyIcon)
                .accessibilityLabel("Shuffle")
                .accessibilityValue(player.queue.isShuffled ? "On" : "Off")
                .accessibilityIdentifier("music.player.shuffle")
                Spacer()
                Button {
                    player.setRepeat(player.queue.repeatMode.next)
                } label: {
                    Image(systemName: player.queue.repeatMode == .one ? "repeat.1" : "repeat")
                        .foregroundStyle(player.queue.repeatMode == .off ? .primary : Color.lobbyAccent(scheme))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.lobbyIcon)
                .accessibilityLabel("Repeat")
                .accessibilityValue(Self.repeatLabel(player.queue.repeatMode))
                .accessibilityIdentifier("music.player.repeat")
            } else {
                SpeedMenu()
            }
            Spacer()
            SleepTimerMenu()
            Spacer()
            RoutePickerButton()
            SpeakerPlayOnButton(audio: .nowPlaying)
            Spacer()
            Button {
                showsQueue.toggle()
            } label: {
                Image(systemName: player.book == nil ? "list.bullet" : "list.bullet.indent")
                    .foregroundStyle(showsQueue ? Color.lobbyAccent(scheme) : .primary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.lobbyIcon)
            .accessibilityLabel(player.book == nil ? "Up Next" : "Chapters")
            .accessibilityIdentifier("music.player.queue")
        }
        .font(.title3)
        .foregroundStyle(.primary)
    }

    private static func repeatLabel(_ mode: MusicQueue.Repeat) -> String {
        switch mode {
        case .off: "Off"
        case .all: "All"
        case .one: "This song"
        }
    }

    @ViewBuilder
    private func queue(_ player: MusicPlayer) -> some View {
        if let book = player.book {
            VStack(alignment: .leading, spacing: 0) {
                Text("Chapters").font(.headline).padding(.bottom, AppTheme.Space.s)
                ForEach(Array(book.chapters.enumerated()), id: \.offset) { index, chapter in
                    Button {
                        player.jump(toChapter: index)
                    } label: {
                        HStack {
                            Text(chapter.title ?? "Chapter \(index + 1)")
                                .foregroundStyle(index == player.currentChapterIndex ? Color.lobbyAccent(scheme) : .primary)
                            Spacer()
                            Text(MusicTime.short(chapter.startMs)).foregroundStyle(.lobbySecondary).font(.footnote.monospacedDigit())
                        }
                        .padding(.vertical, AppTheme.Space.s)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.lobbyRow)
                }
            }
            .frame(minHeight: 280, alignment: .top)
        } else {
            let upNext = player.upNext
            VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                HStack {
                    Text("Up Next").font(.headline)
                    Spacer()
                    if !upNext.isEmpty {
                        Button("Clear") { player.clearUpNext() }
                            .buttonStyle(.lobbyText)
                    }
                }
                if upNext.isEmpty {
                    Text("Nothing after this song.")
                        .foregroundStyle(.lobbySecondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    List {
                        ForEach(upNext, id: \.entry.id) { entry, track in
                            HStack(spacing: AppTheme.Space.m) {
                                MusicCover(coverID: app.music.wholeCatalogue.coverID(of: track), size: 40, radius: 6)
                                VStack(alignment: .leading) {
                                    Text(track.title).lineLimit(1)
                                    Text(track.artistCredit).font(.footnote).foregroundStyle(.lobbySecondary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { player.jump(to: entry.id) }
                            .listRowBackground(Color.clear)
                            .accessibilityAddTraits(.isButton)
                        }
                        .onMove { player.moveUpNext(fromOffsets: $0, toOffset: $1) }
                        .onDelete { offsets in
                            for offset in offsets { player.remove(entryID: upNext[offset].entry.id) }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(height: 300)
                    #if os(iOS)
                    .environment(\.editMode, .constant(.active))
                    #endif
                }
            }
        }
    }
}

/// Stop after some minutes, or at the end of the song or chapter.
struct SleepTimerMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let player = app.music.player
        Menu {
            Button("Off") { player.setSleepTimer(nil) }
            ForEach([5, 15, 30, 45, 60], id: \.self) { minutes in
                Button("\(minutes) Minutes") { player.sleep(inMinutes: minutes) }
            }
            Button(player.book == nil ? "End of Song" : "End of Chapter") { player.setSleepTimer(.endOfTrack) }
        } label: {
            Group {
                if case .at(let moment) = player.sleepTimer {
                    Text(timerInterval: Date()...max(Date(), moment), countsDown: true)
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 44)
                } else {
                    Image(systemName: player.sleepTimer == nil ? "moon.zzz" : "moon.zzz.fill")
                }
            }
            .foregroundStyle(player.sleepTimer == nil ? .primary : Color.lobbyAccent(scheme))
            .frame(minWidth: 44, minHeight: 44)
        }
        .menuStyle(.button)
        .buttonStyle(.lobbyIcon)
        .accessibilityLabel("Sleep timer")
        .accessibilityValue(player.sleepTimer == nil ? "Off" : "On")
        .accessibilityIdentifier("music.player.sleep")
    }
}
