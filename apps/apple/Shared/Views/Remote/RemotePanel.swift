// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// The remote for what plays on another device, drawn on black: a picture, what it is, how far,
/// and the buttons of a remote. The side panel on iPad and Mac and the sheet on iPhone show this
/// same body. All the buttons are the commands of the live channel (`app.remote.send`).
struct RemotePanelBody: View {
    let device: ShownDevice
    /// Called when "Watch Here" took the film over, so that a sheet can close.
    var didWatchHere: () -> Void = {}

    @Environment(AppModel.self) private var app
    @State private var dragged: Double?
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        let state = device.player?.state
        VStack(alignment: .leading, spacing: AppTheme.Space.l) {
            artwork
            heading
            if let state {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let model = RemotePanelModel(device: device, positionMs: app.remote.positionMs(of: state))
                    VStack(spacing: AppTheme.Space.l) {
                        scrubber(model)
                        transport(model)
                    }
                }
                skipIntro(state)
                if device.controllable, let upNext = state.upNext {
                    RemoteUpNextView(device: device, state: state, upNext: upNext) { command in
                        await run(command)
                    } problem: { problem = $0 }
                }
                if device.controllable {
                    secondary(state)
                }
            } else {
                Text("This cannot be controlled from here.")
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
            }
        }
        .alert("That did not work", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: What it is

    private var item: Item? { device.player?.state?.itemId.flatMap { app.wholeCatalogue.item($0) } }

    private var artwork: some View {
        let show = item.flatMap { app.wholeCatalogue.show(of: $0) }
        return ArtworkView(artwork: item?.artwork.backdrop ?? item?.artwork.still ?? show?.artwork.backdrop ?? item?.artwork.poster ?? show?.artwork.poster, width: 460) {
            ZStack {
                Color.white.opacity(0.08)
                Image(systemName: RemoteTargets.symbol(device.platform))
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .aspectRatio(AppTheme.wideAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        .accessibilityHidden(true)
    }

    private var heading: some View {
        let name = app.remote.name(of: device)
        let model = RemotePanelModel(device: device, positionMs: 0)
        return VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
            Label("\(model.statusWords) on \(name)", systemImage: RemoteTargets.symbol(device.platform))
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(.lobbySecondary)
                .accessibilityIdentifier("remote.state")
            Text(RemoteWords.title(of: device, in: app))
                .font(.title2.weight(.bold))
                .lineLimit(3)
                .accessibilityIdentifier("remote.title")
            if let line = RemoteWords.subtitle(of: device, in: app) {
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(.lobbySecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: How far

    private func scrubber(_ model: RemotePanelModel) -> some View {
        let shown = dragged ?? model.fraction
        let position = dragged.flatMap { model.seekTarget(fraction: $0) } ?? model.positionMs
        return VStack(spacing: AppTheme.Space.s) {
            PanelScrubber(fraction: shown, isEnabled: model.canSeek) { value in
                dragged = value
            } onEnd: { value in
                Task {
                    if let target = model.seekTarget(fraction: value) { await run(.seek(positionMs: target)) }
                    dragged = nil
                }
            }
            .frame(height: 28)
            .accessibilityElement()
            .accessibilityLabel("Position")
            .accessibilityValue(MediaFormat.clock(ms: position))
            .accessibilityAdjustableAction { direction in
                guard model.canSeek else { return }
                let seconds = direction == .increment ? RemotePanelModel.forwardSeconds : -RemotePanelModel.backSeconds
                Task { await run(.seek(positionMs: model.skipTarget(seconds: seconds))) }
            }
            .accessibilityIdentifier("remote.position")
            HStack {
                Text(MediaFormat.clock(ms: position))
                Spacer()
                Text(model.remainingText)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.lobbySecondary)
        }
    }

    // MARK: Buttons

    private func transport(_ model: RemotePanelModel) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            button("Back \(RemotePanelModel.backSeconds) Seconds", "gobackward.\(RemotePanelModel.backSeconds)", size: 30, enabled: model.canSkip, id: "remote.back") {
                await run(.skip(deltaMs: -RemotePanelModel.backSeconds * 1000))
            }
            Spacer(minLength: 0)
            Button {
                Task { _ = await run(model.isPlaying ? .pause : .resume) }
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 64, height: 64)
                    .background(.white, in: Circle())
            }
            .buttonStyle(.lobbyIcon)
            .disabled(!model.canPlayPause)
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("nowPlaying.playPause")
            Spacer(minLength: 0)
            button("Forward \(RemotePanelModel.forwardSeconds) Seconds", "goforward.\(RemotePanelModel.forwardSeconds)", size: 30, enabled: model.canSkip, id: "remote.forward") {
                await run(.skip(deltaMs: RemotePanelModel.forwardSeconds * 1000))
            }
            Spacer(minLength: 0)
            if model.canNext {
                button("Next Episode", "forward.end.fill", size: 24, enabled: true, id: "remote.next") { await run(.next) }
                Spacer(minLength: 0)
            }
        }
    }

    private func button(_ label: String, _ symbol: String, size: CGFloat, enabled: Bool, id: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.lobbyIcon)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    /// Skip Intro for the other device's player, while its intro plays.
    @ViewBuilder
    private func skipIntro(_ state: RemotePlayerState) -> some View {
        if device.controllable, let itemID = state.itemId, device.can("seek"),
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
                        Task { await run(.seek(positionMs: end - offset)) }
                    }
                    .buttonStyle(.lobbyText)
                    .accessibilityIdentifier("remote.skipIntro")
                }
            }
        }
    }

    /// Sound, subtitles, watch here, stop.
    @ViewBuilder
    private func secondary(_ state: RemotePlayerState) -> some View {
        HStack(spacing: AppTheme.Space.m) {
            if state.audioTracks.count > 1, device.can("setAudio") {
                Menu {
                    ForEach(state.audioTracks) { track in
                        Button {
                            Task { await run(.setAudio(trackId: track.id)) }
                        } label: {
                            if track.id == state.audioTrackId { Label(track.label, systemImage: "checkmark") } else { Text(track.label) }
                        }
                    }
                } label: {
                    chip("Sound", "speaker.wave.2")
                }
                .accessibilityIdentifier("remote.sound")
            }
            if !state.subtitleTracks.isEmpty, device.can("setSubtitle") {
                Menu {
                    Button("Off") { Task { await run(.setSubtitle(trackId: nil)) } }
                    ForEach(state.subtitleTracks) { track in
                        Button {
                            Task { await run(.setSubtitle(trackId: track.id)) }
                        } label: {
                            if track.id == state.subtitleTrackId { Label(track.label, systemImage: "checkmark") } else { Text(track.label) }
                        }
                    }
                } label: {
                    chip("Subtitles", "captions.bubble")
                }
                .accessibilityIdentifier("remote.subtitles")
            }
            if app.player == nil {
                Button {
                    Task {
                        busy = true
                        defer { busy = false }
                        let outcome = await app.remote.watchHere(from: device)
                        if let words = outcome.words(device: app.remote.name(of: device)) { problem = words } else { didWatchHere() }
                    }
                } label: {
                    chip("Watch Here", AppSymbol.thisDevice)
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityIdentifier("remote.watchHere")
            }
            if device.can("stop") {
                Button {
                    Task { await run(.stop) }
                } label: {
                    chip("Stop", "stop.fill")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("remote.stop")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.footnote.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, AppTheme.Space.m)
            .frame(minHeight: 36)
            .background(.white.opacity(0.12), in: Capsule())
            .foregroundStyle(.white)
    }

    @discardableResult
    private func run(_ command: RemoteCommand) async -> Bool {
        let outcome = await app.remote.send(command, to: device.id)
        if let words = outcome.words(device: app.remote.name(of: device)) {
            problem = words
            return false
        }
        return true
    }
}

/// A thin bar that fills as the film goes on and is dragged to move it: a plain capsule, as on
/// a remote, with a knob only while it is held.
struct PanelScrubber: View {
    let fraction: Double
    let isEnabled: Bool
    let onChange: (Double) -> Void
    let onEnd: (Double) -> Void

    @State private var isHeld = false

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let value = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2)).frame(height: isHeld ? 10 : 6)
                Capsule().fill(.white).frame(width: max(value * width, 0), height: isHeld ? 10 : 6)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard isEnabled else { return }
                        isHeld = true
                        onChange(min(max(drag.location.x / width, 0), 1))
                    }
                    .onEnded { drag in
                        guard isEnabled else { return }
                        isHeld = false
                        onEnd(min(max(drag.location.x / width, 0), 1))
                    }
            )
            .animation(.easeOut(duration: 0.12), value: isHeld)
            .opacity(isEnabled ? 1 : 0.5)
        }
    }
}

// MARK: The side panel

/// iPad and Mac: a black panel at the trailing edge, beside the page (the page gets narrower, it is
/// not covered). It can fold into a narrow strip with the picture and play and pause.
struct RemoteSidePanel: View {
    let device: ShownDevice

    @Environment(AppModel.self) private var app
    @AppStorage("remotePanel.collapsed") private var isCollapsed = false

    static let width: CGFloat = 340
    static let collapsedWidth: CGFloat = 68

    var body: some View {
        Group {
            if isCollapsed { strip } else { full }
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .frame(width: isCollapsed ? Self.collapsedWidth : Self.width)
        .frame(maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nowPlaying.panel")
        .animation(.snappy(duration: 0.25), value: isCollapsed)
    }

    private var full: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Now Playing")
                    .font(.headline)
                Spacer()
                Button {
                    isCollapsed = true
                } label: {
                    Image(systemName: "sidebar.trailing")
                        .font(.body)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.lobbyIcon)
                .accessibilityLabel("Fold Away Panel")
                .accessibilityIdentifier("nowPlaying.collapse")
            }
            .padding(.horizontal, AppTheme.Space.l)
            .padding(.top, AppTheme.Space.m)
            ScrollView {
                RemotePanelBody(device: device)
                    .padding(AppTheme.Space.l)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var strip: some View {
        let state = device.player?.state
        let item = state?.itemId.flatMap { app.wholeCatalogue.item($0) }
        let model = RemotePanelModel(device: device, positionMs: state.map { app.remote.positionMs(of: $0) } ?? 0)
        return VStack(spacing: AppTheme.Space.m) {
            Button {
                isCollapsed = false
            } label: {
                Image(systemName: "sidebar.trailing")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.lobbyIcon)
            .accessibilityLabel("Show Now Playing")
            .accessibilityIdentifier("nowPlaying.expand")
            ArtworkView(artwork: item?.artwork.poster ?? item.flatMap { app.wholeCatalogue.show(of: $0) }?.artwork.poster, width: 44) {
                Color.white.opacity(0.1)
            }
            .frame(width: 44, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
            if device.controllable {
                Button {
                    Task { _ = await app.remote.send(model.isPlaying ? .pause : .resume, to: device.id) }
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.lobbyIcon)
                .disabled(!model.canPlayPause)
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("nowPlaying.strip.playPause")
            }
            Spacer(minLength: 0)
        }
        .padding(.top, AppTheme.Space.m)
    }
}
