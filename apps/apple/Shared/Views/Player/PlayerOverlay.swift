// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// What the player says while there is no picture: the server is still repackaging the file,
/// or it cannot be played. Drawn in the middle of each platform's player view.
struct PlayerStatusView: View {
    let model: PlayerModel
    let close: () -> Void

    var body: some View {
        switch model.stage {
        case .loading, .playing, .ended:
            EmptyView()
        case .preparing where model.isForKids:
            VStack(spacing: AppTheme.Space.l) {
                ProgressView()
                    .controlSize(.large)
                Text("Almost ready")
                    .font(.system(.title, design: .rounded, weight: .heavy))
                Button("Back", action: close)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            .panel()
            .accessibilityIdentifier("player.preparing")
        case .failed where model.isForKids:
            VStack(spacing: AppTheme.Space.l) {
                Text("This one does not work right now")
                    .font(.system(.title, design: .rounded, weight: .heavy))
                    .multilineTextAlignment(.center)
                Button("Back", action: close)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("player.close")
            }
            .panel()
            .accessibilityIdentifier("player.failed")
        case .preparing(let progress):
            VStack(spacing: AppTheme.Space.m) {
                if let progress {
                    ProgressView(value: progress)
                        .frame(width: 220)
                } else {
                    ProgressView()
                }
                Text(progress == nil ? "Waiting for Lobby Server" : "Lobby Server is getting this ready to play")
                    .font(.headline)
                Text("Files in a format Apple devices cannot open are repackaged once. Next time it starts at once.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .opacity(0.75)
                Button("Cancel", action: close)
                    .buttonStyle(.bordered)
            }
            .panel()
            .accessibilityIdentifier("player.preparing")
        case .failed(let message):
            VStack(spacing: AppTheme.Space.m) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(Color.lobbyWarning)
                Text("This cannot be played")
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .opacity(0.75)
                Button("Close", action: close)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("player.close")
            }
            .panel()
            .accessibilityIdentifier("player.failed")
        }
    }
}

/// A film over the direct connection waits while that is made again: calm, and gone by itself.
struct ReconnectingNotice: View {
    let model: PlayerModel
    @Environment(\.motion) private var motion

    var body: some View {
        ZStack {
            if model.showsReconnecting {
                Label("Reconnecting…", systemImage: AppSymbol.reconnecting)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.lobbyOnArtwork)
                    .padding(.vertical, AppTheme.Space.s)
                    .padding(.horizontal, AppTheme.Space.l)
                    .background(Color.lobbyArtworkScrim.opacity(0.7), in: Capsule())
                    .transition(.opacity)
                    .accessibilityIdentifier("player.reconnecting")
            }
        }
        .animation(motion.animation(.change), value: model.showsReconnecting)
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }
}

/// Skip Intro, while the intro plays. Where it is and what the viewer wants are the model's.
struct SkipIntroButton: View {
    let model: PlayerModel

    var body: some View {
        if model.offersSkipIntro {
            Button {
                model.skipIntro()
            } label: {
                Label("Skip Intro", systemImage: "forward.fill")
                    .font(.headline)
                    .padding(.vertical, AppTheme.Space.m)
                    .padding(.horizontal, AppTheme.Space.l)
                    .foregroundStyle(Color.lobbyProminentLabel(.dark))
                    .background(
                        Color.lobbyProminentFill(.dark),
                        in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
            }
            .buttonStyle(.lobbyPill)
            .accessibilityIdentifier("player.skipIntro")
        }
    }
}

/// Play Next: offered in the credits and at the end of an episode, while Up Next is not up.
/// Never started by itself: the countdown of Up Next is (`UpNextOverlay`).
struct PlayNextButton: View {
    let model: PlayerModel

    var body: some View {
        if model.offersPlayNext, model.ending == nil, let next = model.upNext {
            Button {
                model.playNext()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Play Next", systemImage: "forward.end.fill")
                        .font(.headline)
                    if let subtitle = next.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .lineLimit(1)
                            .opacity(0.8)
                    }
                }
                .padding(.vertical, AppTheme.Space.m)
                .padding(.horizontal, AppTheme.Space.l)
                .foregroundStyle(Color.lobbyProminentLabel(.dark))
                .background(
                    Color.lobbyProminentFill(.dark),
                    in: RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
            }
            .buttonStyle(.lobbyPill)
            .accessibilityLabel("Play next episode")
            .accessibilityValue(next.subtitle ?? "")
            .accessibilityIdentifier("player.playNext")
        }
    }
}

private extension View {
    /// A message over the black of the player. Always dark: the player is.
    func panel() -> some View {
        self
            .foregroundStyle(Color.lobbyOnArtwork)
            .padding(AppTheme.Space.xl)
            .frame(maxWidth: 420)
            .environment(\.colorScheme, .dark)
    }
}
