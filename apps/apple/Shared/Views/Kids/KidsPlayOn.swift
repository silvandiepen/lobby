// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

// Play on TV from the kids screens (docs/decisions.md, "Kids mode plays on the TV"): one large button, one tap for one TV and large cards
// with the TV's name for several. The server lets a child play only what it may see, as itself,
// and control only what plays as itself; the screens only make that simple.

/// What the kids screens do with a TV: start the title there, or send what plays here.
enum KidsPlayOnAction {
    case play(PlayRequest)
    case send
}

/// Does it and says how it goes, for the button and the cards alike.
@MainActor
@Observable
final class KidsPlayOnModel {
    /// "Waking Living Room…", while it goes.
    private(set) var progress: String?
    /// The TV being asked, while it goes.
    private(set) var busy: String?
    /// What went wrong, in a child's words.
    var problem: String?
    /// "Playing on Living Room", for a moment after it went.
    private(set) var started: String?

    /// - Returns: true when it plays there now.
    @discardableResult
    func run(_ action: KidsPlayOnAction, on device: ShownDevice, remote: RemoteModel) async -> Bool {
        guard busy == nil else { return false }
        let name = remote.name(of: device)
        busy = device.id
        progress = RemoteTargets.willWake(device) ? "Waking \(name)…" : "Starting on \(name)…"
        defer {
            busy = nil
            progress = nil
        }
        let step: @MainActor (RemoteModel.WakeStep) -> Void = { [weak self] step in
            let words = switch step {
            case .waking: "Waking \(name)…"
            case .opening: "Opening Lobby on \(name)…"
            case .profileHint, .notOpen: "If \(name) asks who is watching, ask a grown-up to choose."
            case .starting: "Starting on \(name)…"
            }
            self?.progress = words
        }
        let outcome = switch action {
        case .play(let request): await remote.playForKids(request, on: device, step: step)
        case .send: await remote.sendForKids(to: device, step: step)
        }
        if let words = outcome.kidsWords(device: name) {
            problem = words
            return false
        }
        started = "Playing on \(name)"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.started = nil
        }
        return true
    }
}

/// "Play on TV" on a kids title page: there while a TV can play it.
struct KidsPlayOnButton: View {
    let request: PlayRequest

    @Environment(AppModel.self) private var app
    @State private var model = KidsPlayOnModel()
    @State private var isChoosing = false

    var body: some View {
        let targets = app.remote.kidsTargets
        VStack(spacing: AppTheme.Space.s) {
            if !targets.isEmpty {
                Button {
                    if targets.count == 1, let only = targets.first {
                        Task { await model.run(.play(request), on: only, remote: app.remote) }
                    } else {
                        isChoosing = true
                    }
                } label: {
                    Label {
                        Text(model.busy == nil ? "Play on TV" : "Starting…")
                    } icon: {
                        if model.busy == nil {
                            Image(systemName: AppSymbol.television)
                        } else {
                            ProgressView().tint(KidsTheme.words)
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
                .disabled(model.busy != nil)
                .accessibilityLabel(targets.count == 1 ? "Play on \(app.remote.name(of: targets[0]))" : "Play on TV")
                .accessibilityAddTraits(.startsMediaSession)
                .accessibilityIdentifier("kids.playOn")
            }
            KidsPlayOnStatus(model: model)
        }
        .sheet(isPresented: $isChoosing) {
            KidsTVChooser(action: .play(request), model: model)
                .environment(app)
                .lobbyMotion()
        }
        .kidsPlayOnAlert(model)
    }
}

/// How it goes, under the button.
private struct KidsPlayOnStatus: View {
    let model: KidsPlayOnModel

    var body: some View {
        if let words = model.progress ?? model.started {
            Text(words)
                .font(.headline)
                .foregroundStyle(KidsTheme.words)
                .padding(.horizontal, AppTheme.Space.m)
                .padding(.vertical, AppTheme.Space.s)
                .background(KidsTheme.quiet, in: Capsule())
                .accessibilityIdentifier("kids.playOn.status")
        }
    }
}

extension View {
    fileprivate func kidsPlayOnAlert(_ model: KidsPlayOnModel) -> some View {
        alert(
            "That did not work",
            isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
    }
}

/// Which TV, when there are several: a large card for each, with its name.
struct KidsTVChooser: View {
    let action: KidsPlayOnAction
    let model: KidsPlayOnModel

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let targets = app.remote.kidsTargets
        ScrollView {
            VStack(spacing: KidsTheme.gap) {
                Text("Which TV?")
                    .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                    .foregroundStyle(KidsTheme.words)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                ForEach(targets) { device in
                    card(device)
                }
                if targets.isEmpty {
                    Text("No TV can play right now.")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(KidsTheme.words)
                }
                KidsPlayOnStatus(model: model)
            }
            .padding(KidsTheme.margin)
        }
        .background(KidsTheme.page(.standard).ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            KidsRoundButton(symbol: "xmark", label: "Close", size: 52) { dismiss() }
                .padding(KidsTheme.margin)
                .accessibilityIdentifier("kids.playOn.close")
        }
        .presentationDetents([.medium, .large])
        .kidsPlayOnAlert(model)
    }

    private func card(_ device: ShownDevice) -> some View {
        let name = app.remote.name(of: device)
        return Button {
            Task {
                if await model.run(action, on: device, remote: app.remote) { dismiss() }
            }
        } label: {
            HStack(spacing: AppTheme.Space.l) {
                Image(systemName: RemoteTargets.symbol(device.platform))
                    .font(.system(size: 40, weight: .semibold))
                    .frame(width: 72)
                Text(name)
                    .font(.title.weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if model.busy == device.id {
                    ProgressView().tint(KidsTheme.onPlay)
                }
            }
            .foregroundStyle(KidsTheme.onPlay)
            .padding(AppTheme.Space.l)
            .frame(maxWidth: .infinity, minHeight: 110)
            .background(KidsTheme.play, in: RoundedRectangle(cornerRadius: KidsTheme.cardRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: KidsTheme.cardRadius, style: .continuous))
        }
        .buttonStyle(.lobbyPill)
        .disabled(model.busy != nil)
        .accessibilityLabel("Play on \(name)")
        .accessibilityIdentifier("kids.playOn.tv.\(name)")
    }
}

/// What the child plays on a TV: pause, back a little, and stop. Nothing else of the TV.
struct KidsTVRemote: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let device = app.remote.kidsPlaying, let state = device.player?.state {
            let name = app.remote.name(of: device)
            let plays = state.status == .playing || state.status == .loading || state.status == .buffering
            HStack(spacing: AppTheme.Space.m) {
                Image(systemName: AppSymbol.television)
                    .font(.title2.weight(.semibold))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("On \(name)")
                        .font(.headline)
                    if let itemID = state.itemId, let title = app.kidsLibrary.catalogue.item(itemID)?.title {
                        Text(title)
                            .font(.subheadline)
                            .opacity(0.85)
                    }
                }
                .lineLimit(1)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("kids.tvRemote.title")
                Spacer(minLength: 0)
                KidsRoundButton(symbol: "gobackward.10", label: "Back 10 Seconds", size: 52) {
                    send(.skip(deltaMs: -10_000), to: device)
                }
                KidsRoundButton(symbol: plays ? "pause.fill" : "play.fill", label: plays ? "Pause" : "Play", size: 52) {
                    send(plays ? .pause : .resume, to: device)
                }
                .accessibilityIdentifier("kids.tvRemote.playPause")
                KidsRoundButton(symbol: "stop.fill", label: "Stop", size: 52) {
                    send(.stop, to: device)
                }
                .accessibilityIdentifier("kids.tvRemote.stop")
            }
            .foregroundStyle(KidsTheme.words)
            .padding(AppTheme.Space.m)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: KidsTheme.cardRadius, style: .continuous))
            .background(KidsTheme.quiet, in: RoundedRectangle(cornerRadius: KidsTheme.cardRadius, style: .continuous))
            .accessibilityElement(children: .contain)
        }
    }

    private func send(_ command: RemoteCommand, to device: ShownDevice) {
        Task { _ = await app.remote.send(command, to: device.id) }
    }
}

#if os(iOS)
/// In the kids player: what plays here goes on at the TV. A round button among the player's own.
struct KidsPlayerTVButton: View {
    let model: PlayerModel
    @State private var playOn = KidsPlayOnModel()
    @State private var isChoosing = false

    var body: some View {
        if let app = model.appModel, model.isForKids {
            let targets = app.remote.kidsTargets
            if !targets.isEmpty {
                Button {
                    if targets.count == 1, let only = targets.first {
                        Task { await playOn.run(.send, on: only, remote: app.remote) }
                    } else {
                        isChoosing = true
                    }
                } label: {
                    Group {
                        if playOn.busy == nil {
                            Image(systemName: AppSymbol.television)
                        } else {
                            ProgressView()
                        }
                    }
                    .font(.title2.weight(.semibold))
                    .frame(width: 52, height: 52)
                    .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.lobbyIcon)
                .disabled(playOn.busy != nil)
                .accessibilityLabel(targets.count == 1 ? "Play on \(app.remote.name(of: targets[0]))" : "Play on TV")
                .accessibilityIdentifier("player.kidsPlayOn")
                .sheet(isPresented: $isChoosing) {
                    KidsTVChooser(action: .send, model: playOn)
                        .environment(app)
                        .lobbyMotion()
                }
                .kidsPlayOnAlert(playOn)
            }
        }
    }
}
#endif
