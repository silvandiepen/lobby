// SPDX-License-Identifier: MPL-2.0
import AVKit
import SwiftUI

/// The film, filling the window, in AVKit's Mac player: its floating controls, its audio and
/// subtitle menu, full screen, Picture in Picture and AirPlay. What plays and where it resumes
/// is `PlayerModel`, the same as on iPhone and iPad.
struct MacPlayerScreen: View {
    let model: PlayerModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MacPlayerView(model: model, usesOwnTransport: model.preparing != nil)
                .ignoresSafeArea()
            PictureSubtitleOverlay(model: model)
                .ignoresSafeArea()
            VStack {
                Spacer()
                SubtitleOverlay(model: model)
                    .padding(.bottom, 120)
            }
            .allowsHitTesting(false)
            ReconnectingNotice(model: model)
                .padding(.top, 72)
                .frame(maxHeight: .infinity, alignment: .top)
            PlayerStatusView(model: model) { close() }
            UpNextOverlay(model: model) { close() }
            RemoteToastView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 40)
            if model.preparing != nil {
                // The server is still writing the copy: the film's own bar instead of AVKit's,
                // which would show a live broadcast.
                PreparingTransport(model: model) { close() }
            } else {
                systemChrome
            }
        }
        .environment(\.colorScheme, .dark)
        .onChange(of: model.isFinished) { _, finished in
            // A film that played to its end closes its player.
            if finished { close() }
        }
    }

    /// What the app adds around AVKit's own floating controls.
    private var systemChrome: some View {
        ZStack {
            VStack {
                HStack {
                    Button {
                        close()
                    } label: {
                        Label("Close", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                            .font(.headline)
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.lobbyIcon)
                    .keyboardShortcut(.cancelAction)
                    .help("Close the player (Esc)")
                    .accessibilityIdentifier("player.close")
                    Text([model.request.title, model.request.subtitle].compactMap { $0 }.joined(separator: " · "))
                        .font(.headline)
                        .foregroundStyle(Color.lobbyOnArtwork)
                        .shadow(color: Color.lobbyArtworkScrim.opacity(0.6), radius: 2)
                        .accessibilityIdentifier("player.title")
                    Spacer()
                    PlayerSendButton(model: model)
                    ExtraSubtitlesButton(model: model)
                }
                Spacer()
                HStack {
                    Spacer()
                    SkipIntroButton(model: model)
                    PlayNextButton(model: model)
                }
                .padding(.bottom, 96)
            }
            .padding(AppTheme.Space.l)
        }
    }

    private func close() {
        Task { await model.close() }
    }
}

/// `AVPlayerView`, at the AppKit edge.
private struct MacPlayerView: NSViewRepresentable {
    let model: PlayerModel
    /// Whether the app's own transport is up (a film that is still being prepared).
    let usesOwnTransport: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = model.player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = !model.isForKids
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== model.player {
            view.player = model.player
        }
        view.controlsStyle = usesOwnTransport ? .none : .floating
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}
