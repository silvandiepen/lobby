// SPDX-License-Identifier: MPL-2.0
import AVFoundation
import SwiftUI

/// The player: the system's, and the app's own controls where the system's would say something
/// that is not so.
struct TVPlayerScreen: View {
    let model: PlayerModel
    let close: () -> Void
    @State private var monitor: BufferMonitor

    init(model: PlayerModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        _monitor = State(initialValue: BufferMonitor(model: model))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch TVPlayerSurface(stage: model.stage, isBeingPrepared: model.preparing != nil) {
            case .system:
                TVSystemPlayer(
                    model: model, notice: monitor.notice, offersSkipIntro: model.offersSkipIntro,
                    offersPlayNext: model.offersPlayNext)
                    .ignoresSafeArea()
            case .own:
                TVPictureView(player: model.player)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                PictureSubtitleOverlay(model: model)
                    .ignoresSafeArea()
                SubtitleOverlay(model: model)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 240)
                controls
                    .onExitCommand(perform: model.stage == .playing ? nil : close)
            }
            if model.showsReconnecting {
                ReconnectingNotice(model: model)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, AppTheme.Space.xl)
            } else if let notice = monitor.notice, model.stage == .playing {
                TVBufferNotice(title: notice.title, explanation: monitor.explanation)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, AppTheme.Space.xl)
                    // Words only: the remote stays with the player.
                    .allowsHitTesting(false)
            }
            RemoteToastView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .environment(\.colorScheme, .dark)
        .task { await monitor.run() }
    }

    @ViewBuilder
    private var controls: some View {
        switch model.stage {
        case .loading:
            TVPlayerMessage(
                symbol: nil, title: Patience.askingToPlay(waited: monitor.askingFor), text: model.request.title
            ) {
                Button("Cancel", action: close)
            }
        case .preparing where model.isForKids:
            TVPlayerMessage(symbol: nil, title: "Almost ready", text: "") { Button("Back", action: close) }
        case .failed where model.isForKids:
            TVPlayerMessage(symbol: nil, showsSpinner: false, title: "This one does not work right now", text: "") { Button("Back", action: close) }
        case .preparing(let progress):
            TVPlayerMessage(
                symbol: nil, progress: progress,
                title: progress == nil ? "Waiting for Lobby Server" : "Lobby Server is getting this ready to play",
                text: "Files in a format Apple devices cannot open are repackaged once. Next time it starts at once."
            ) {
                Button("Cancel", action: close)
            }
        case .failed(let message):
            TVPlayerMessage(symbol: "exclamationmark.triangle.fill", title: "This cannot be played right now", text: message) {
                Button("Try Again", systemImage: AppSymbol.refresh) { model.tryAgain() }
                Button("Close", action: close)
            }
        case .ended where model.ending != nil:
            TVUpNextOverlay(model: model, close: close)
        case .ended:
            // After Cancel: the next episode stays offered.
            if model.upNext != nil {
                TVPlayerMessage(symbol: "forward.end.fill", title: "Up next", text: model.upNext?.subtitle ?? "") {
                    Button("Play Next", systemImage: "forward.end.fill") { model.playNext() }
                        .accessibilityIdentifier("player.playNext")
                    Button("Close", action: close)
                }
            }
        case .playing:
            TVPreparingTransport(model: model, canTryAgain: monitor.notice == .stalled, close: close)
        }
    }
}

/// What the player says while there is no film to show, with its buttons.
private struct TVPlayerMessage<Buttons: View>: View {
    /// nil: something is being waited for.
    let symbol: String?
    var progress: Double? = nil
    var showsSpinner = true
    let title: String
    let text: String
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(spacing: AppTheme.Space.xl) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.title2)
                    .accessibilityHidden(true)
            } else if let progress {
                ProgressView(value: progress).frame(width: 500)
            } else if showsSpinner {
                ProgressView()
            }
            Text(title).font(.title3.weight(.semibold))
            Text(text)
                .font(.callout)
                .opacity(0.8)
            HStack(spacing: TVMetrics.gap) { buttons }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(Color.lobbyOnArtwork)
        .frame(maxWidth: TVMetrics.readable)
        .padding(AppTheme.Space.xl * 2)
        .background(Color.lobbyArtworkScrim.opacity(0.7), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
    }
}

/// Why the picture stands still, in words.
private struct TVBufferNotice: View {
    let title: String
    let explanation: String?

    var body: some View {
        VStack(spacing: AppTheme.Space.s) {
            Text(title).font(.headline)
            if let explanation {
                Text(explanation)
                    .font(.callout)
                    .opacity(0.85)
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(Color.lobbyOnArtwork)
        .padding(AppTheme.Space.l)
        .frame(maxWidth: TVMetrics.readable)
        .background(Color.lobbyArtworkScrim.opacity(0.75), in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The transport of a film whose copy the server is still writing: the film's own length, how
/// far the copy reaches, and the remote's usual moves. No LIVE, no time of day.
private struct TVPreparingTransport: View {
    let model: PlayerModel
    /// Nothing arrives any more: offer to ask again.
    let canTryAgain: Bool
    let close: () -> Void

    private enum Control: Hashable { case picture, bar, playPause, tryAgain, next }

    @FocusState private var focused: Control?
    @State private var showsControls = true
    /// Counts what the viewer does, so that the controls go away some time after the last.
    @State private var touches = 0
    @Environment(\.motion) private var motion

    private var isShown: Bool { showsControls || !model.isPlaying || canTryAgain }

    var body: some View {
        if let timeline = model.preparing {
            ZStack(alignment: .bottom) {
                if isShown {
                    LinearGradient(
                        colors: [.clear, Color.lobbyArtworkScrim.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                        .ignoresSafeArea()
                        .accessibilityHidden(true)
                    controls(timeline)
                } else {
                    // Takes the remote while the controls are away: a click or a move brings
                    // them back, left and right also skip.
                    Color.clear
                        .contentShape(Rectangle())
                        .focusable()
                        .focused($focused, equals: .picture)
                        .onTapGesture { show() }
                        .onMoveCommand { direction in
                            skip(direction)
                            show()
                        }
                        .accessibilityLabel("Show controls")
                        .accessibilityAddTraits(.isButton)
                }
            }
            .foregroundStyle(Color.lobbyOnArtwork)
            .animation(motion.animation(.section), value: isShown)
            .onPlayPauseCommand {
                model.togglePlayback()
                show()
            }
            // One step: first the controls go, then the film.
            .onExitCommand {
                if isShown, model.isPlaying, !canTryAgain { showsControls = false } else { close() }
            }
            .onAppear { focused = .playPause }
            .onChange(of: isShown) { _, shown in focused = shown ? .playPause : .picture }
            .onChange(of: focused) { touches += 1 }
            .onChange(of: canTryAgain) { _, can in if can { focused = .tryAgain } }
            .task(id: touches) {
                do { try await Task.sleep(for: .seconds(6)) } catch { return }
                showsControls = false
            }
        }
    }

    private func show() {
        showsControls = true
        touches += 1
    }

    private func skip(_ direction: MoveCommandDirection) {
        switch direction {
        case .left: model.skip(bySeconds: -10)
        case .right: model.skip(bySeconds: 10)
        default: break
        }
    }

    private func controls(_ timeline: PreparingTimeline) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.l) {
            Text([model.request.title, model.request.subtitle].compactMap { $0 }.joined(separator: " · "))
                .font(.headline)
            Text(timeline.hasCaughtUp ? "Waiting for Lobby Server to prepare more of this film." : timeline.statusText)
                .font(.callout)
                .opacity(0.85)
                .accessibilityIdentifier("player.preparingStatus")
            HStack(spacing: AppTheme.Space.l) {
                Text(timeline.elapsedText).monospacedDigit()
                PreparingBar(timeline: timeline, played: timeline.positionFraction)
                    .frame(height: focused == .bar ? 16 : 10)
                Text(timeline.remainingText).monospacedDigit()
            }
            .font(.callout.weight(.medium))
            .padding(.vertical, AppTheme.Space.m)
            .padding(.horizontal, AppTheme.Space.l)
            .background(
                Color.lobbyOnArtwork.opacity(focused == .bar ? 0.2 : 0.08),
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
            // On the bar, left and right move ten seconds.
            .focusable()
            .focused($focused, equals: .bar)
            .onMoveCommand { direction in
                skip(direction)
                show()
                // Up and down leave the bar, as they would anywhere else.
                if direction == .down { focused = .playPause }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Position in the film")
            .accessibilityValue(timeline.accessibilityValue)
            .accessibilityAdjustableAction { model.skip(bySeconds: $0 == .increment ? 10 : -10) }

            HStack(spacing: TVMetrics.gap) {
                Button {
                    model.skip(bySeconds: -10)
                    show()
                } label: {
                    Image(systemName: "gobackward.10")
                }
                .accessibilityLabel("Back 10 seconds")
                Button {
                    model.togglePlayback()
                    show()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : AppSymbol.play)
                }
                .focused($focused, equals: .playPause)
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("player.playPause")
                Button {
                    model.skip(bySeconds: 10)
                    show()
                } label: {
                    Image(systemName: "goforward.10")
                }
                .accessibilityLabel("Forward 10 seconds")
                Menu {
                    PlayerChoiceItems(model: model)
                } label: {
                    Image(systemName: "captions.bubble")
                }
                .accessibilityLabel("Sound and subtitles")
                if canTryAgain {
                    Button("Try Again", systemImage: AppSymbol.refresh) { model.tryAgain() }
                        .focused($focused, equals: .tryAgain)
                }
                if model.offersSkipIntro {
                    Button("Skip Intro", systemImage: "forward.fill") { model.skipIntro() }
                        .accessibilityIdentifier("player.skipIntro")
                }
                if model.offersPlayNext {
                    Button("Play Next", systemImage: "forward.end.fill") { model.playNext() }
                        .focused($focused, equals: .next)
                        .accessibilityIdentifier("player.playNext")
                }
            }
            .focusSection()
        }
        .padding(AppTheme.Space.xl)
    }
}
