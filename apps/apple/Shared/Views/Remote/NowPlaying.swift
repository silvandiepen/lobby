// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

extension View {
    /// What another device plays, while something plays there and nothing plays here. On iPad and
    /// Mac a black panel at the trailing edge beside the page, which gets narrower; on iPhone a bar
    /// at the foot of the page that opens the remote as a sheet.
    func nowPlayingBar() -> some View {
        modifier(NowPlayingInset())
    }
}

private struct NowPlayingInset: ViewModifier {
    @Environment(AppModel.self) private var app
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var usesPanel: Bool {
        #if os(iOS)
        sizeClass == .regular
        #else
        true
        #endif
    }

    func body(content: Content) -> some View {
        let device = app.player == nil ? app.remote.nowPlaying.first : nil
        // The same views in both layouts, so that the page keeps its place when the panel comes.
        HStack(spacing: 0) {
            content
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !usesPanel, let device {
                        NowPlayingBar(device: device)
                            .padding(.horizontal, AppTheme.Space.m)
                            .padding(.bottom, AppTheme.Space.s)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            if usesPanel, let device {
                RemoteSidePanel(device: device)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.default, value: device?.id)
    }
}

/// The bar on iPhone: black, with the picture, what plays, how far, and play or pause. Opens the remote.
struct NowPlayingBar: View {
    let device: ShownDevice

    @Environment(AppModel.self) private var app
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
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(width: 36, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(RemoteWords.title(of: device, in: app))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("\(RemoteTargets.words(for: device.player?.status ?? .playing)) on \(app.remote.name(of: device))")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                        if let state, let duration = state.durationMs, duration > 0 {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                let model = RemotePanelModel(device: device, positionMs: app.remote.positionMs(of: state))
                                Capsule().fill(.white.opacity(0.2)).frame(height: 3)
                                    .overlay(alignment: .leading) {
                                        GeometryReader { proxy in
                                            Capsule().fill(.white).frame(width: proxy.size.width * model.fraction)
                                        }
                                    }
                                    .padding(.top, 2)
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
                let model = RemotePanelModel(device: device, positionMs: 0)
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
                .accessibilityIdentifier("nowPlaying.playPause")
            }
        }
        .padding(AppTheme.Space.s)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .background(Color.black, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 2)
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

/// The remote as a sheet (iPhone, and from the bar): the same body as the side panel, on black.
struct RemoteScreen: View {
    let deviceID: String

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var shownID: String?

    var body: some View {
        let remote = app.remote
        let playing = remote.nowPlaying
        let device = remote.device(shownID ?? deviceID)
        LobbySheet(title: device.map { remote.name(of: $0) } ?? "Remote", width: 520, height: 640) {
            if let device, device.online {
                ScrollView {
                    RemotePanelBody(device: device) { dismiss() }
                        .padding(AppTheme.Space.l)
                }
            } else {
                ContentUnavailableView(
                    "Not there any more", systemImage: "appletv",
                    description: Text("The device closed Lobby, went to sleep or left the network."))
                    .accessibilityIdentifier("remote.gone")
            }
        }
        .foregroundStyle(.white)
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
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
    }
}

/// What the other device shows at the end, and its buttons: Up Next with Play Now and Cancel,
/// the suggestions to pick from, or "Still watching?" with Continue Watching and Stop. The same
/// as on its screen, by the same viewer's preferences.
struct RemoteUpNextView: View {
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
