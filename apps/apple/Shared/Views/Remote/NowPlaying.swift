// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

extension View {
    /// The bar of what another device plays, at the foot of the page, while something plays there.
    func nowPlayingBar() -> some View {
        modifier(NowPlayingInset())
    }
}

private struct NowPlayingInset: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if app.player == nil, let device = app.remote.nowPlaying.first {
                NowPlayingBar(device: device)
                    .padding(.horizontal, AppTheme.Space.m)
                    .padding(.bottom, AppTheme.Space.s)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: app.remote.nowPlaying.first?.id)
    }
}

/// "Wild Isles on Living Room", how far, and play or pause. Opens the full remote.
struct NowPlayingBar: View {
    let device: ShownDevice

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var isOpen = false

    var body: some View {
        let state = device.player?.state
        let item = state?.itemId.flatMap(app.item)
        HStack(spacing: AppTheme.Space.m) {
            Button {
                isOpen = true
            } label: {
                HStack(spacing: AppTheme.Space.m) {
                    ArtworkView(artwork: item?.artwork.poster ?? item.flatMap { app.wholeCatalogue.show(of: $0) }?.artwork.poster, width: 36) {
                        Image(systemName: RemoteTargets.symbol(device.platform))
                            .foregroundStyle(.lobbySecondary)
                    }
                    .frame(width: 36, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(RemoteWords.title(of: device, in: app))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("\(RemoteTargets.words(for: device.player?.status ?? .playing)) on \(app.remote.name(of: device))")
                            .font(.caption)
                            .foregroundStyle(.lobbySecondary)
                            .lineLimit(1)
                        if let state, let duration = state.durationMs, duration > 0 {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                ProgressView(value: Double(app.remote.positionMs(of: state)), total: Double(duration))
                                    .progressViewStyle(.linear)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the remote")
            .accessibilityIdentifier("nowPlaying.open")
            if device.controllable {
                RemotePlayPause(device: device)
            }
        }
        .padding(AppTheme.Space.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .sheet(isPresented: $isOpen) {
            RemoteScreen(deviceID: device.id)
        }
    }
}

/// What the screens say about what plays elsewhere.
@MainActor
enum RemoteWords {
    /// The title, or only "Playing" for one this device may not know.
    static func title(of device: ShownDevice, in app: AppModel) -> String {
        guard let state = device.player?.state, let id = state.itemId, let item = app.item(id) ?? app.wholeCatalogue.item(id) else {
            return "Playing"
        }
        guard item.kind == .episode else { return item.title }
        let show = app.wholeCatalogue.show(of: item)
        return show?.title ?? item.title
    }

    static func subtitle(of device: ShownDevice, in app: AppModel) -> String? {
        guard let id = device.player?.state?.itemId, let item = app.wholeCatalogue.item(id), item.kind == .episode else { return nil }
        return ItemText.episodeLine(item, show: app.wholeCatalogue.show(of: item))
    }
}

/// Play or pause on the other device.
struct RemotePlayPause: View {
    let device: ShownDevice
    @Environment(AppModel.self) private var app
    @State private var problem: String?

    var body: some View {
        let plays = device.player?.status == .playing || device.player?.status == .buffering
        Button {
            Task {
                let outcome = await app.remote.send(plays ? .pause : .resume, to: device.id)
                problem = outcome.words(device: app.remote.name(of: device))
            }
        } label: {
            Image(systemName: plays ? "pause.fill" : "play.fill")
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.lobbyIcon)
        .disabled(!device.can(plays ? "pause" : "resume"))
        .accessibilityLabel(plays ? "Pause" : "Play")
        .accessibilityIdentifier("nowPlaying.playPause")
        .alert("That did not work", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }
}

/// The remote: what plays on another device, and everything it can be asked to do.
struct RemoteScreen: View {
    let deviceID: String

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var dragged: Double?
    @State private var problem: String?
    @State private var busy = false
    @State private var shownID: String?

    var body: some View {
        let remote = app.remote
        let playing = remote.nowPlaying
        let device = remote.device(shownID ?? deviceID)
        LobbySheet(title: device.map { remote.name(of: $0) } ?? "Remote", width: 520, height: 640) {
            if let device, device.online {
                content(device)
            } else {
                ContentUnavailableView(
                    "Not there any more", systemImage: "appletv",
                    description: Text("The device closed Lobby, went to sleep or left the network."))
                    .accessibilityIdentifier("remote.gone")
            }
        }
        .toolbar {
            if playing.count > 1 {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(playing) { one in
                            Button(remote.name(of: one)) { shownID = one.id }
                        }
                    } label: {
                        Label("Devices", systemImage: AppSymbol.television)
                    }
                }
            }
        }
        .alert("That did not work", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    @ViewBuilder
    private func content(_ device: ShownDevice) -> some View {
        let state = device.player?.state
        let item = state?.itemId.flatMap { app.wholeCatalogue.item($0) }
        ScrollView {
            VStack(spacing: AppTheme.Space.l) {
                ArtworkView(artwork: item?.artwork.backdrop ?? item?.artwork.still ?? item.flatMap { app.wholeCatalogue.show(of: $0) }?.artwork.backdrop, width: 460) {
                    Image(systemName: RemoteTargets.symbol(device.platform))
                        .font(.largeTitle)
                        .foregroundStyle(.lobbySecondary)
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)

                VStack(spacing: AppTheme.Space.xs) {
                    Text(RemoteWords.title(of: device, in: app))
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("remote.title")
                    if let line = RemoteWords.subtitle(of: device, in: app) {
                        Text(line).font(.subheadline).foregroundStyle(.lobbySecondary)
                    }
                    Text(RemoteTargets.state(of: device) { _ in nil } + " on " + app.remote.name(of: device))
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                        .accessibilityIdentifier("remote.state")
                }

                if let state, let duration = state.durationMs, duration > 0 {
                    timeline(device, state: state, duration: duration)
                }

                if device.controllable, let state, let upNext = state.upNext {
                    RemoteUpNextView(device: device, state: state, upNext: upNext) { command in
                        await run(command, on: device)
                    } problem: { problem = $0 }
                }

                if device.controllable {
                    skipIntro(device, state: state)
                    transport(device, state: state)
                    tracks(device, state: state)
                } else {
                    Text("This cannot be controlled from here.")
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                }
            }
            .padding(AppTheme.Space.l)
        }
    }

    private func timeline(_ device: ShownDevice, state: RemotePlayerState, duration: Int) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let position = dragged ?? Double(app.remote.positionMs(of: state))
            VStack(spacing: AppTheme.Space.xs) {
                Slider(
                    value: Binding(get: { position }, set: { dragged = $0 }), in: 0...Double(duration)
                ) { editing in
                    guard !editing, let target = dragged else { return }
                    Task {
                        await run(.seek(positionMs: Int(target)), on: device)
                        dragged = nil
                    }
                }
                .disabled(!device.controllable || !device.can("seek"))
                .accessibilityLabel("Position")
                .accessibilityValue(MediaFormat.clock(ms: Int(position)))
                .accessibilityIdentifier("remote.position")
                HStack {
                    Text(MediaFormat.clock(ms: Int(position)))
                    Spacer()
                    Text("-" + MediaFormat.clock(ms: max(0, duration - Int(position))))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.lobbySecondary)
            }
        }
    }

    /// Skip Intro for the other device's player, while its intro plays.
    @ViewBuilder
    private func skipIntro(_ device: ShownDevice, state: RemotePlayerState?) -> some View {
        if let state, let itemID = state.itemId, device.can("seek"),
            let file = app.wholeCatalogue.item(itemID)?.files.first(where: { $0.assetId == state.assetId }),
            file.markers?.intro != nil
        {
            let preferences = app.profiles.first { $0.id == state.profileId }?.skipPreferences ?? .defaults
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let offset = file.startMs ?? 0
                if let end = SkipMoment.remoteIntroEnd(
                    fileMs: app.remote.positionMs(of: state) + offset, markers: file.markers, preferences: preferences)
                {
                    Button("Skip Intro", systemImage: "forward.fill") {
                        Task { await run(.seek(positionMs: end - offset), on: device) }
                    }
                    .buttonStyle(.lobbyText)
                    .accessibilityIdentifier("remote.skipIntro")
                }
            }
        }
    }

    private func transport(_ device: ShownDevice, state: RemotePlayerState?) -> some View {
        HStack(spacing: AppTheme.Space.xl) {
            control("Back 10 Seconds", "gobackward.10", device, command: "skip") { await run(.skip(deltaMs: -10_000), on: device) }
            RemotePlayPause(device: device)
                .font(.largeTitle)
            control("Forward 10 Seconds", "goforward.10", device, command: "skip") { await run(.skip(deltaMs: 10_000), on: device) }
            if state?.nextItemId != nil {
                control("Next Episode", "forward.end.fill", device, command: "next") { await run(.next, on: device) }
            }
        }
        .font(.title2)
    }

    @ViewBuilder
    private func tracks(_ device: ShownDevice, state: RemotePlayerState?) -> some View {
        VStack(spacing: AppTheme.Space.m) {
            HStack(spacing: AppTheme.Space.m) {
                if let state, state.audioTracks.count > 1, device.can("setAudio") {
                    Menu {
                        ForEach(state.audioTracks) { track in
                            Button {
                                Task { await run(.setAudio(trackId: track.id), on: device) }
                            } label: {
                                if track.id == state.audioTrackId { Label(track.label, systemImage: "checkmark") } else { Text(track.label) }
                            }
                        }
                    } label: {
                        Label("Sound", systemImage: "speaker.wave.2")
                    }
                    .accessibilityIdentifier("remote.sound")
                }
                if let state, !state.subtitleTracks.isEmpty, device.can("setSubtitle") {
                    Menu {
                        Button("Off") { Task { await run(.setSubtitle(trackId: nil), on: device) } }
                        ForEach(state.subtitleTracks) { track in
                            Button {
                                Task { await run(.setSubtitle(trackId: track.id), on: device) }
                            } label: {
                                if track.id == state.subtitleTrackId { Label(track.label, systemImage: "checkmark") } else { Text(track.label) }
                            }
                        }
                    } label: {
                        Label("Subtitles", systemImage: "captions.bubble")
                    }
                    .accessibilityIdentifier("remote.subtitles")
                }
            }
            HStack(spacing: AppTheme.Space.m) {
                if state != nil, app.player == nil {
                    Button("Watch Here", systemImage: AppSymbol.thisDevice) {
                        Task {
                            busy = true
                            defer { busy = false }
                            let outcome = await app.remote.watchHere(from: device)
                            if let words = outcome.words(device: app.remote.name(of: device)) { problem = words } else { dismiss() }
                        }
                    }
                    .buttonStyle(.lobbyText)
                    .disabled(busy)
                    .accessibilityIdentifier("remote.watchHere")
                }
                if device.can("stop") {
                    Button("Stop", systemImage: "stop.fill", role: .destructive) {
                        Task { await run(.stop, on: device) }
                    }
                    .buttonStyle(.lobbyText)
                    .accessibilityIdentifier("remote.stop")
                }
            }
        }
    }

    private func control(
        _ label: String, _ symbol: String, _ device: ShownDevice, command: String, action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol).frame(width: 44, height: 44)
        }
        .buttonStyle(.lobbyIcon)
        .disabled(!device.can(command))
        .accessibilityLabel(label)
    }

    private func run(_ command: RemoteCommand, on device: ShownDevice) async {
        let outcome = await app.remote.send(command, to: device.id)
        if let words = outcome.words(device: app.remote.name(of: device)) { problem = words }
    }
}

/// What the other device shows at the end, and its buttons: Up Next with Play Now and Cancel,
/// the suggestions to pick from, or "Still watching?" with Continue Watching and Stop. The same
/// as on its screen, by the same viewer's preferences.
private struct RemoteUpNextView: View {
    let device: ShownDevice
    let state: RemotePlayerState
    let upNext: RemoteUpNext
    let run: (RemoteCommand) async -> Void
    let problem: (String) -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.m) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(heading)
                    .font(.headline)
                    .accessibilityIdentifier("remote.upNext")
            }
            switch upNext.kind {
            case .episode:
                if let line = next.map({ ItemText.episodeLine($0, show: app.wholeCatalogue.show(of: $0)) }) {
                    Text(line).font(.subheadline).foregroundStyle(.lobbySecondary)
                }
                buttons(playNow: true)
            case .suggestions:
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppTheme.Space.m) {
                        ForEach(upNext.suggestions, id: \.self) { id in
                            if let item = app.wholeCatalogue.item(id) {
                                suggestion(item)
                            }
                        }
                    }
                }
                buttons(playNow: upNext.itemId != nil)
            case .stillWatching:
                HStack(spacing: AppTheme.Space.m) {
                    Button("Continue Watching") { Task { await run(.upNext(.continue)) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!device.can("upNext"))
                        .accessibilityIdentifier("remote.upNext.continue")
                    Button("Stop", role: .destructive) { Task { await run(.stop) } }
                        .buttonStyle(.bordered)
                        .disabled(!device.can("stop"))
                        .accessibilityIdentifier("remote.upNext.stop")
                }
            case .unknown:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Space.m)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
    }

    private var next: Item? { upNext.itemId.flatMap { app.wholeCatalogue.item($0) } }

    private var heading: String {
        let seconds = app.remote.upNextRemainingMs(of: state).map { Int(($0 + 999) / 1000) }
        switch upNext.kind {
        case .episode:
            return seconds.map { "Next episode in \($0) s" } ?? "Next episode"
        case .suggestions:
            if let seconds, let next { return "\(title(of: next)) starts in \(seconds) s" }
            return "Watch something next"
        case .stillWatching:
            return "Are you still watching?"
        case .unknown:
            return ""
        }
    }

    private func title(of item: Item) -> String {
        item.kind == .episode ? app.wholeCatalogue.show(of: item)?.title ?? item.title : item.title
    }

    @ViewBuilder
    private func buttons(playNow: Bool) -> some View {
        HStack(spacing: AppTheme.Space.m) {
            if playNow {
                Button("Play Now", systemImage: AppSymbol.play) { Task { await run(.upNext(.playNow)) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!device.can("upNext"))
                    .accessibilityIdentifier("remote.upNext.playNow")
            }
            if upNext.countdownMs != nil {
                Button("Cancel") { Task { await run(.upNext(.cancel)) } }
                    .buttonStyle(.bordered)
                    .disabled(!device.can("upNext"))
                    .accessibilityIdentifier("remote.upNext.cancel")
            }
        }
    }

    /// A suggestion: tapped, it plays there as the same viewer.
    private func suggestion(_ item: Item) -> some View {
        let show = item.kind == .episode ? app.wholeCatalogue.show(of: item) : nil
        return Button {
            guard let viewer = state.profileId else { return }
            Task {
                let outcome = await app.remote.play(item, on: device, start: .resume, profileID: viewer)
                if let words = outcome.words(device: app.remote.name(of: device)) { problem(words) }
            }
        } label: {
            VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                ArtworkView(artwork: show?.artwork.backdrop ?? item.artwork.backdrop ?? item.artwork.poster, width: 160) {
                    Color.lobbyTileFill[0]
                }
                .frame(width: 160, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.tile, style: .continuous))
                Text(show?.title ?? item.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(width: 160, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(!device.can("play") || state.profileId == nil)
        .accessibilityIdentifier("remote.upNext.suggestion.\(item.id)")
    }
}
