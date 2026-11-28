// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

// A story or music on a HomePod from the kids screens (docs/decisions.md, "Play on a speaker"):
// one large button per speaker, and a remote a small child can use alone. The server plays as
// the child, only while it may listen, and stops it when that ends.

/// "Play on Kitchen" on a story's page, under Play: there while a speaker will play for the child.
struct KidsSpeakerButtons: View {
    let audio: SpeakerAudio

    @Environment(AppModel.self) private var app
    @State private var busy: String?
    @State private var problem: String?

    var body: some View {
        let speakers = app.remote.kidsSpeakers
        if !speakers.isEmpty {
            VStack(spacing: AppTheme.Space.s) {
                ForEach(speakers) { speaker in
                    button(speaker)
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

    private func button(_ speaker: ShownSpeaker) -> some View {
        Button {
            Task { await play(on: speaker) }
        } label: {
            Label {
                Text(busy == speaker.id ? "Starting…" : "Play on \(speaker.name)")
            } icon: {
                if busy == speaker.id {
                    ProgressView().tint(KidsTheme.words)
                } else {
                    Image(systemName: SpeakerTargets.symbol(speaker))
                }
            }
            .font(.title2.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(KidsTheme.words)
            .padding(.horizontal, 32)
            .frame(minHeight: 68)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.lobbyPill)
        .disabled(busy != nil)
        .accessibilityLabel("Play on \(speaker.name)")
        .accessibilityAddTraits(.startsMediaSession)
        .accessibilityIdentifier("kids.playOnSpeaker.\(speaker.name)")
    }

    private func play(on speaker: ShownSpeaker) async {
        guard let kid = app.activeProfile?.id, busy == nil else { return }
        busy = speaker.id
        defer { busy = nil }
        let outcome: SpeakerOutcome = switch audio {
        case .story(let book):
            await app.remote.play(.story(profileID: kid, bookID: book.id), on: speaker.id)
        case .album(let album):
            await app.remote.play(
                .music(profileID: kid, trackIDs: app.music.tracks(ofAlbum: album.id).map(\.id), albumID: album.id),
                on: speaker.id)
        case .nowPlaying:
            await app.remote.sendMusic(to: speaker.id)
        }
        if let words = SpeakerTargets.kidsWords(outcome, speaker: speaker.name) {
            problem = words
            return
        }
        app.remote.openSpeaker = speaker.id
    }
}

/// Over the kids bar while a speaker plays for the child and nothing plays here.
struct KidsSpeakerBar: View {
    let speaker: ShownSpeaker

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if let state = speaker.play?.state {
            let title = SpeakerWords.title(of: state, in: app.music) ?? "Playing"
            let plays = state.status == .playing || state.status == .loading
            HStack(spacing: AppTheme.Space.m) {
                Button {
                    app.remote.openSpeaker = speaker.id
                } label: {
                    HStack(spacing: AppTheme.Space.m) {
                        MusicCover(coverID: SpeakerWords.coverID(of: state, in: app.music), size: 54, radius: 12)
                        VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                            Text(title)
                                .font(.headline.weight(.bold))
                                .lineLimit(1)
                            Label("On \(speaker.name)", systemImage: SpeakerTargets.symbol(speaker))
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.lobbyPill)
                .accessibilityLabel("\(title), on \(speaker.name)")
                .accessibilityHint("Opens the player")
                .accessibilityIdentifier("kids.speakerBar")
                KidsRoundButton(symbol: plays ? "pause.fill" : "play.fill", label: plays ? "Pause" : "Play", size: 56) {
                    Task { _ = await app.remote.control(plays ? .pause : .resume, on: speaker.id) }
                }
            }
            .foregroundStyle(KidsTheme.words)
            .padding(AppTheme.Space.s)
            .padding(.leading, 2)
            .background {
                let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
                if reduceTransparency {
                    shape.fill(Color.lobbySurface(.dark))
                } else {
                    shape.fill(.ultraThinMaterial).background(Color.black.opacity(0.3), in: shape)
                }
            }
            .shadow(color: KidsTheme.shadow, radius: 14, y: 6)
            .frame(maxWidth: 560)
            .padding(.horizontal, AppTheme.Space.m)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// The child's remote of a speaker: the cover, the name, where it plays, how far, a big play and
/// pause, back 15 and forward 30 for a story (previous and next for music), quieter and louder,
/// and stop. Nothing small, nothing to scrub.
struct KidsSpeakerRemote: View {
    let speakerID: String

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?

    var body: some View {
        let speaker = app.remote.speaker(speakerID)
        let state = speaker?.play?.state
        GeometryReader { proxy in
            let cover = min(proxy.size.width - 2 * KidsTheme.margin - 24, proxy.size.height * 0.36, 420)
            VStack(spacing: KidsTheme.gap) {
                HStack {
                    KidsRoundButton(symbol: "chevron.down", label: "Close", size: 60) { dismiss() }
                        .accessibilityIdentifier("kids.speaker.close")
                    Spacer()
                }
                Spacer(minLength: 0)
                if let speaker, let state {
                    MusicCover(
                        coverID: SpeakerWords.coverID(of: state, in: app.music), size: max(160, cover), radius: 32,
                        symbol: AppSymbol.audiobooks)
                        .kidsFrame(radius: 32)
                    VStack(spacing: AppTheme.Space.s) {
                        Text(SpeakerWords.title(of: state, in: app.music) ?? "Playing")
                            .kidsHeading(34)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                            .kidsWords()
                            .accessibilityIdentifier("kids.speaker.title")
                        Label("On \(speaker.name)", systemImage: SpeakerTargets.symbol(speaker))
                            .font(.title3.weight(.bold))
                            .accessibilityIdentifier("kids.speaker.where")
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let duration = max(state.durationMs ?? 0, 1)
                        ProgressBar(
                            fraction: min(1, Double(app.remote.positionMs(of: state)) / Double(duration)),
                            track: KidsTheme.track, fill: KidsTheme.progress, height: 12)
                            .frame(maxWidth: 420)
                    }
                    .accessibilityHidden(true)
                    controls(speaker, state)
                } else {
                    Text("Nothing plays there now.")
                        .font(.title2.weight(.bold))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, KidsTheme.margin)
            .padding(.vertical, AppTheme.Space.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(KidsTheme.words)
        .artworkBackground(state.flatMap { SpeakerWords.coverID(of: $0, in: app.music) }.map(Artwork.musicCover), kids: true)
        .environment(\.lobbyIsPlayful, true)
        .preferredColorScheme(.dark)
        .accessibilityAction(.escape) { dismiss() }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 720)
        .onExitCommand { dismiss() }
        #endif
        .alert(
            "That did not work",
            isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kids.speaker")
    }

    private func controls(_ speaker: ShownSpeaker, _ state: SpeakerPlayState) -> some View {
        let plays = state.status == .playing || state.status == .loading
        let isStory = state.kind == .story
        return VStack(spacing: KidsTheme.gap) {
            HStack(spacing: AppTheme.Space.xl) {
                if isStory {
                    KidsRoundButton(symbol: "gobackward.15", label: "Back 15 seconds", size: 84) { act(.skip(deltaMs: -15_000), speaker) }
                        .accessibilityIdentifier("kids.speaker.back")
                } else {
                    KidsRoundButton(symbol: "backward.fill", label: "Previous", size: 84) { act(.previous, speaker) }
                        .accessibilityIdentifier("kids.speaker.back")
                }
                Button {
                    act(plays ? .pause : .resume, speaker)
                } label: {
                    Image(systemName: plays ? "pause.fill" : "play.fill")
                        .font(.system(size: 48, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(KidsTheme.onPlay)
                        .offset(x: plays ? 0 : 5)
                        .frame(width: 120, height: 120)
                        .background(KidsTheme.play, in: Circle())
                        .contentShape(Circle())
                        .shadow(color: KidsTheme.shadow, radius: 12, y: 5)
                }
                .buttonStyle(.lobbyPill)
                .accessibilityLabel(plays ? "Pause" : "Play")
                .accessibilityIdentifier("kids.speaker.play")
                if isStory {
                    KidsRoundButton(symbol: "goforward.30", label: "Forward 30 seconds", size: 84) { act(.skip(deltaMs: 30_000), speaker) }
                        .accessibilityIdentifier("kids.speaker.forward")
                } else {
                    KidsRoundButton(symbol: "forward.fill", label: "Next", size: 84) { act(.next, speaker) }
                        .accessibilityIdentifier("kids.speaker.forward")
                }
            }
            HStack(spacing: AppTheme.Space.xl) {
                KidsRoundButton(symbol: "speaker.minus.fill", label: "Quieter", size: 64) {
                    act(.volume(max(0, (speaker.volume ?? 0.5) - 0.1)), speaker)
                }
                .accessibilityIdentifier("kids.speaker.quieter")
                KidsRoundButton(symbol: "stop.fill", label: "Stop", size: 64) {
                    act(.stop, speaker)
                    dismiss()
                }
                .accessibilityIdentifier("kids.speaker.stop")
                KidsRoundButton(symbol: "speaker.plus.fill", label: "Louder", size: 64) {
                    act(.volume(min(1, (speaker.volume ?? 0.5) + 0.1)), speaker)
                }
                .accessibilityIdentifier("kids.speaker.louder")
            }
        }
    }

    private func act(_ action: SpeakerAction, _ speaker: ShownSpeaker) {
        Task {
            let outcome = await app.remote.control(action, on: speaker.id)
            if case .stop = action { return }
            if let words = SpeakerTargets.kidsWords(outcome, speaker: speaker.name) { problem = words }
        }
    }
}

/// What plays over the kids bar: here, or else on a speaker for the child.
struct KidsListeningBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if !app.music.player.isActive, let speaker = app.remote.speakerPlaying {
            KidsSpeakerBar(speaker: speaker)
        } else {
            KidsNowPlayingBar()
        }
    }
}
