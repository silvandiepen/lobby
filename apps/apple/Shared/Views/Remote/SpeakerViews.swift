// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

// Play on a HomePod or another AirPlay speaker (docs/decisions.md, "Play on a speaker"): Lobby
// Server streams the music or the story there itself, so this device is only the remote and can
// go. The speakers are in Play On for audio; what the screens say comes from `SpeakerTargets`.

/// What would go to a speaker.
enum SpeakerAudio: Hashable {
    /// What plays here now: it goes on there, at its place.
    case nowPlaying
    case album(MusicAlbum)
    case story(MusicBook)
}

/// "Play On" for music and stories: there while there is a speaker to play on.
struct SpeakerPlayOnButton: View {
    let audio: SpeakerAudio

    @Environment(AppModel.self) private var app
    @State private var isOpen = false

    var body: some View {
        if !app.remote.speakerTargets.isEmpty {
            Button {
                isOpen = true
            } label: {
                Image(systemName: "homepod.and.homepodmini")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.lobbyIcon)
            .accessibilityLabel("Play On")
            .accessibilityHint("Chooses a HomePod or speaker for Lobby Server to play this on")
            .accessibilityIdentifier("music.playOn")
            .sheet(isPresented: $isOpen) {
                SpeakerPlayOnSheet(audio: audio)
                    .environment(app)
            }
        }
    }
}

/// Which speaker to play on. Lobby Server plays there itself.
struct SpeakerPlayOnSheet: View {
    let audio: SpeakerAudio

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var busy: String?
    @State private var problem: String?

    var body: some View {
        let remote = app.remote
        LobbySheet(title: "Play On", width: 480, height: 520) {
            LobbyForm {
                Section {
                    LabeledContent("What", value: title)
                }
                Section {
                    ForEach(remote.speakerTargets) { speaker in
                        row(speaker)
                    }
                } header: {
                    Label("HomePods and Speakers", systemImage: "homepod.and.homepodmini")
                } footer: {
                    Text("Lobby Server plays to the speaker itself: you can close Lobby here, or leave. The place in a story is kept for \(app.activeProfile?.name ?? "this viewer"), as when it plays here.")
                }
            }
            .alert(
                "That did not work",
                isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
        }
    }

    private var title: String {
        switch audio {
        case .nowPlaying:
            let player = app.music.player
            return player.book?.title ?? player.currentTrack?.title ?? "What plays here"
        case .album(let album): return album.title
        case .story(let book): return book.title
        }
    }

    private func row(_ speaker: ShownSpeaker) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
            HStack(spacing: AppTheme.Space.m) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(speaker.name)
                        Text(SpeakerTargets.state(of: speaker) { SpeakerWords.title(of: $0, in: app.music) })
                            .font(.footnote)
                            .foregroundStyle(.lobbySecondary)
                    }
                } icon: {
                    Image(systemName: SpeakerTargets.symbol(speaker))
                        .foregroundStyle(.lobbySecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("playOn.speaker.\(speaker.name)")
                Spacer(minLength: 0)
                if busy == speaker.id {
                    ProgressView().controlSize(.small)
                } else if speaker.canPlay {
                    Button("Play", systemImage: AppSymbol.play) {
                        Task { await play(on: speaker) }
                    }
                    .buttonStyle(.lobbyText)
                    .disabled(busy != nil || app.activeProfile == nil)
                    .accessibilityLabel("Play on \(speaker.name)")
                    .accessibilityIdentifier("playOn.playSpeaker.\(speaker.name)")
                }
            }
            if let hint = SpeakerTargets.accessHint(speaker) {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
            }
        }
    }

    private func play(on speaker: ShownSpeaker) async {
        guard let profileID = app.activeProfile?.id else { return }
        busy = speaker.id
        defer { busy = nil }
        let remote = app.remote
        let outcome: SpeakerOutcome = switch audio {
        case .nowPlaying:
            await remote.sendMusic(to: speaker.id)
        case .album(let album):
            await remote.play(
                .music(profileID: profileID, trackIDs: app.music.tracks(ofAlbum: album.id).map(\.id), albumID: album.id),
                on: speaker.id)
        case .story(let book):
            await remote.play(.story(profileID: profileID, bookID: book.id), on: speaker.id)
        }
        if let words = SpeakerTargets.words(outcome, speaker: speaker.name) {
            problem = words
            return
        }
        // What plays here is not shown over the speaker's remote.
        app.music.player.showsNowPlaying = false
        dismiss()
        remote.openSpeaker = speaker.id
    }
}

/// The words for what plays on a speaker, from the music this device knows.
enum SpeakerWords {
    @MainActor
    static func title(of state: SpeakerPlayState, in music: MusicModel) -> String? {
        if let id = state.bookId, let book = music.book(id) { return book.title }
        return music.track(state.trackId)?.title
    }

    @MainActor
    static func subtitle(of state: SpeakerPlayState, in music: MusicModel) -> String? {
        if let id = state.bookId, let book = music.book(id) { return book.readBy ?? book.credit }
        guard let track = music.track(state.trackId) else { return nil }
        return [track.artistCredit, music.wholeCatalogue.collectionTitle(of: track)].compactMap { $0 }.joined(separator: " · ")
    }

    @MainActor
    static func coverID(of state: SpeakerPlayState, in music: MusicModel) -> String? {
        if let id = state.bookId, let book = music.book(id) { return book.coverId }
        return music.track(state.trackId).flatMap { music.wholeCatalogue.coverID(of: $0) }
    }
}

/// At the foot of the page while a speaker plays for this device and nothing plays here.
struct SpeakerMiniPlayer: View {
    let speaker: ShownSpeaker

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let remote = app.remote
        if let state = speaker.play?.state {
            HStack(spacing: AppTheme.Space.m) {
                Button {
                    remote.openSpeaker = speaker.id
                } label: {
                    HStack(spacing: AppTheme.Space.m) {
                        MusicCover(coverID: SpeakerWords.coverID(of: state, in: app.music), size: 42, radius: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(SpeakerWords.title(of: state, in: app.music) ?? "Playing")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Label("\(RemoteTargets.words(for: state.status)) on \(speaker.name)", systemImage: SpeakerTargets.symbol(speaker))
                                .font(.caption)
                                .foregroundStyle(.lobbySecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.lobbyRow)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens the remote")
                .accessibilityIdentifier("speaker.mini")
                SpeakerPlayPause(speaker: speaker, state: state)
            }
            .foregroundStyle(.primary)
            .padding(.leading, AppTheme.Space.s)
            .padding(.trailing, AppTheme.Space.xs)
            .padding(.vertical, AppTheme.Space.s)
            .overlay(alignment: .bottom) {
                if let duration = state.durationMs, duration > 0 {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        ProgressBar(
                            fraction: min(1, Double(remote.positionMs(of: state)) / Double(duration)), track: .clear,
                            fill: .lobbyAccent(scheme), height: 2)
                    }
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

/// Play and pause of a speaker.
private struct SpeakerPlayPause: View {
    let speaker: ShownSpeaker
    let state: SpeakerPlayState
    var size: CGFloat = 40

    @Environment(AppModel.self) private var app

    var body: some View {
        let playing = state.status == .playing || state.status == .loading
        Button {
            Task { _ = await app.remote.control(playing ? .pause : .resume, on: speaker.id) }
        } label: {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.title3)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
        }
        .buttonStyle(.lobbyIcon)
        .accessibilityLabel(playing ? "Pause" : "Play")
        .accessibilityIdentifier("speaker.mini.play")
    }
}

/// The remote of a speaker: what plays, how far, play and pause, back 15 and forward 30 for a
/// story, previous and next for music, the volume, and stop.
struct SpeakerRemoteView: View {
    let speakerID: String

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var volume: Double?
    @State private var problem: String?

    var body: some View {
        let remote = app.remote
        NavigationStack {
            Group {
                if let speaker = remote.speaker(speakerID), let state = speaker.play?.state {
                    content(speaker, state)
                } else {
                    ContentUnavailableView("Nothing plays there now", systemImage: "homepod.fill")
                }
            }
            .artworkBackground(remote.speaker(speakerID)?.play?.state.flatMap { SpeakerWords.coverID(of: $0, in: app.music) }.map(Artwork.musicCover))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "chevron.down") { dismiss() }
                        .accessibilityIdentifier("speaker.remote.close")
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 600)
        #endif
        .alert(
            "That did not work",
            isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
        .accessibilityIdentifier("speaker.remote")
    }

    private func content(_ speaker: ShownSpeaker, _ state: SpeakerPlayState) -> some View {
        let isStory = state.kind == .story
        return ScrollView {
            VStack(spacing: AppTheme.Space.l) {
                MusicCover(
                    coverID: SpeakerWords.coverID(of: state, in: app.music), size: 300, radius: AppTheme.Radius.card,
                    symbol: isStory ? AppSymbol.audiobooks : AppSymbol.music)
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 14)
                    .padding(.top, AppTheme.Space.l)
                VStack(spacing: AppTheme.Space.xs) {
                    Text(SpeakerWords.title(of: state, in: app.music) ?? "Playing")
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("speaker.remote.title")
                    if let line = SpeakerWords.subtitle(of: state, in: app.music) {
                        Text(line).foregroundStyle(.lobbySecondary).lineLimit(1)
                    }
                    Label("On \(speaker.name)", systemImage: SpeakerTargets.symbol(speaker))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.lobbyAccent(scheme))
                        .accessibilityIdentifier("speaker.remote.where")
                }
                progress(state)
                transport(speaker, state)
                volumeRow(speaker)
                if let problem = state.problem {
                    Text(Self.words(problem, speaker: speaker.name))
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                        .multilineTextAlignment(.center)
                }
                Button("Stop", systemImage: "stop.fill", role: .destructive) {
                    Task {
                        await act(.stop, on: speaker)
                        dismiss()
                    }
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("speaker.remote.stop")
            }
            .padding(.horizontal, AppTheme.Space.xl)
            .padding(.bottom, AppTheme.Space.xl)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }

    private func progress(_ state: SpeakerPlayState) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let position = app.remote.positionMs(of: state)
            let duration = max(state.durationMs ?? 0, 1)
            VStack(spacing: AppTheme.Space.xs) {
                ProgressBar(
                    fraction: min(1, Double(position) / Double(duration)), track: .lobbySurfaceRaised(scheme),
                    fill: .lobbyAccent(scheme), height: 4)
                HStack {
                    Text(MusicTime.clock(Double(position) / 1000))
                    Spacer()
                    if state.status == .loading { ProgressView().controlSize(.small) }
                    Spacer()
                    Text("-" + MusicTime.clock(Double(max(0, duration - position)) / 1000))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.lobbySecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Position")
            .accessibilityValue("\(MusicTime.clock(Double(position) / 1000)) of \(MusicTime.clock(Double(duration) / 1000))")
        }
    }

    private func transport(_ speaker: ShownSpeaker, _ state: SpeakerPlayState) -> some View {
        let playing = state.status == .playing || state.status == .loading
        let isStory = state.kind == .story
        return HStack(spacing: AppTheme.Space.xl) {
            if isStory {
                control("gobackward.15", "Back 15 seconds") { await act(.skip(deltaMs: -15_000), on: speaker) }
            } else {
                control("backward.fill", "Previous") { await act(.previous, on: speaker) }
            }
            Button {
                Task { await act(playing ? .pause : .resume, on: speaker) }
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(Color.lobbyProminentLabel(scheme))
                    .frame(width: 72, height: 72)
                    .background(Color.lobbyProminentFill(scheme), in: Circle())
            }
            .buttonStyle(.lobbyIcon)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(playing ? "Pause" : "Play")
            .accessibilityIdentifier("speaker.remote.play")
            if isStory {
                control("goforward.30", "Forward 30 seconds") { await act(.skip(deltaMs: 30_000), on: speaker) }
            } else {
                control("forward.fill", "Next") { await act(.next, on: speaker) }
                    .disabled(!state.hasNext)
            }
        }
        .font(.title2)
        .foregroundStyle(.primary)
        .padding(.vertical, AppTheme.Space.s)
    }

    private func control(_ symbol: String, _ label: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.lobbyIcon)
        .accessibilityLabel(label)
    }

    private func volumeRow(_ speaker: ShownSpeaker) -> some View {
        HStack(spacing: AppTheme.Space.m) {
            Image(systemName: "speaker.fill").foregroundStyle(.lobbySecondary)
            Slider(
                value: Binding(get: { volume ?? speaker.volume ?? 0.5 }, set: { volume = $0 }),
                in: 0...1
            ) { editing in
                guard !editing, let chosen = volume else { return }
                Task {
                    await act(.volume(chosen), on: speaker)
                    volume = nil
                }
            }
            .tint(Color.lobbyAccent(scheme))
            .accessibilityLabel("Volume of \(speaker.name)")
            .accessibilityIdentifier("speaker.remote.volume")
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.lobbySecondary)
        }
    }

    private func act(_ action: SpeakerAction, on speaker: ShownSpeaker) async {
        let outcome = await app.remote.control(action, on: speaker.id)
        if let words = SpeakerTargets.words(outcome, speaker: speaker.name) { problem = words }
    }

    static func words(_ problem: SpeakerProblem, speaker name: String) -> String {
        switch problem {
        case .refused: "\(name) stopped letting Lobby Server play."
        case .notFound: "\(name) is no longer on the network."
        case .timeout, .unavailable: "\(name) could not be reached. Press play to try again."
        case .driveAway: "The drive this music is on is not connected right now."
        case .kidsMode: "It is not time to listen now."
        case .failed, .unknown: "It stopped. Press play to try again."
        }
    }
}

extension View {
    /// The remote of a speaker, when one is opened.
    func speakerRemoteSheet() -> some View {
        modifier(SpeakerRemoteSheet())
    }
}

private struct SpeakerRemoteSheet: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        @Bindable var remote = app.remote
        let forKids = app.showsKidsScreens
        let grownUps = Binding(
            get: { remote.openSpeaker != nil && !forKids },
            set: { if !$0 { remote.openSpeaker = nil } })
        let kids = Binding(
            get: { remote.openSpeaker != nil && forKids },
            set: { if !$0 { remote.openSpeaker = nil } })
        // Each on a view of its own: the music player's sheets hang on the same root.
        content
            .background {
                Color.clear.sheet(isPresented: grownUps) {
                    if let id = remote.openSpeaker {
                        SpeakerRemoteView(speakerID: id)
                            .environment(app)
                            #if os(iOS)
                            .presentationDragIndicator(.visible)
                            #endif
                    }
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: kids) {
                if let id = remote.openSpeaker {
                    KidsSpeakerRemote(speakerID: id)
                        .environment(app)
                }
            }
            #else
            .background {
                Color.clear.sheet(isPresented: kids) {
                    if let id = remote.openSpeaker {
                        KidsSpeakerRemote(speakerID: id)
                            .environment(app)
                    }
                }
            }
            #endif
    }
}
