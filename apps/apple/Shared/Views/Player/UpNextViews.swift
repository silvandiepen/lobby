// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

#if !os(tvOS)
/// What the player shows at the end, over the last picture (docs/playback.md, "When something
/// ends"): Up Next for the next episode, the suggestions after a film, or "Still watching?".
/// The Apple TV has its own, for the remote (`TVUpNextOverlay`).
struct UpNextOverlay: View {
    let model: PlayerModel
    let close: () -> Void
    @Environment(\.motion) private var motion

    var body: some View {
        ZStack {
            switch model.ending {
            case .nextEpisode:
                UpNextCard(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(AppTheme.Space.l)
                    .padding(.bottom, 72)
                    .transition(.opacity)
            case .suggestions:
                SuggestionsScreen(model: model, close: close)
                    .transition(.opacity)
            case .stillWatching:
                StillWatchingPanel(model: model, close: close)
                    .transition(.opacity)
            case nil:
                EmptyView()
            }
        }
        .animation(motion.animation(.section), value: model.ending)
        .foregroundStyle(Color.lobbyOnArtwork)
        .environment(\.colorScheme, .dark)
    }
}

/// The next episode, with the seconds left: Play Now and Cancel.
private struct UpNextCard: View {
    let model: PlayerModel

    var body: some View {
        if let next = model.upNext {
            HStack(alignment: .center, spacing: AppTheme.Space.m) {
                ArtworkView(artwork: next.item.artwork.still ?? next.show?.artwork.backdrop, width: 160) {
                    Color.lobbyArtworkScrim
                }
                .frame(width: 160, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.tile, style: .continuous))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                    Text(UpNextWords.heading(model.countdown))
                        .font(.caption.weight(.semibold))
                        .opacity(0.8)
                        .accessibilityIdentifier("upNext.heading")
                    Text(next.subtitle ?? next.title)
                        .font(.headline)
                        .lineLimit(2)
                    HStack(spacing: AppTheme.Space.s) {
                        Button {
                            model.playUpNextNow()
                        } label: {
                            Label("Play Now", systemImage: AppSymbol.play)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("upNext.playNow")
                        if model.countdown != nil {
                            Button("Cancel") { model.cancelUpNext() }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("upNext.cancel")
                        }
                    }
                    .controlSize(.regular)
                }
            }
            .padding(AppTheme.Space.m)
            .frame(maxWidth: 440)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("upNext.card")
        }
    }
}

/// After a film, or a series that is over: what goes with it, big, to pick. Back closes.
private struct SuggestionsScreen: View {
    let model: PlayerModel
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color.lobbyArtworkScrim.opacity(0.35), Color.lobbyArtworkScrim.opacity(0.9)],
                startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppTheme.Space.l) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                        Text(model.request.title)
                            .font(.title2.weight(.bold))
                        Text(UpNextWords.suggestionsLine(model.countdown, first: model.suggestions.first))
                            .font(.subheadline)
                            .opacity(0.85)
                            .accessibilityIdentifier("upNext.suggestionsLine")
                    }
                    Spacer()
                    if model.countdown != nil {
                        Button("Cancel") { model.cancelUpNext() }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("upNext.cancel")
                    }
                    Button("Close", systemImage: "xmark", action: close)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("upNext.close")
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: AppTheme.Space.m) {
                        ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            Button {
                                model.play(suggestion)
                            } label: {
                                SuggestionTile(suggestion: suggestion, countdown: index == 0 ? model.countdown : nil)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("upNext.suggestion.\(suggestion.id)")
                        }
                    }
                    .padding(.vertical, AppTheme.Space.xs)
                }
                .scrollClipDisabled()
            }
            .padding(AppTheme.Space.l)
            .padding(.bottom, AppTheme.Space.l)
        }
        .accessibilityIdentifier("upNext.suggestions")
    }
}

private struct SuggestionTile: View {
    let suggestion: UpNextSuggestion
    let countdown: UpNextCountdown?
    private static let width: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.s) {
            ArtworkView(artwork: suggestion.artwork, width: Self.width) {
                ZStack {
                    Color.lobbyTileFill[0]
                    Text(suggestion.title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(AppTheme.Space.m)
                }
            }
            .frame(width: Self.width, height: Self.width / AppTheme.wideAspect)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.tile, style: .continuous))
            .overlay(alignment: .bottom) {
                if let countdown {
                    // How soon this one starts by itself.
                    ProgressView(value: countdown.fraction)
                        .progressViewStyle(.linear)
                        .tint(Color.lobbyOnArtwork)
                        .padding(AppTheme.Space.s)
                }
            }
            Text(suggestion.title)
                .font(.headline)
                .lineLimit(1)
            if let line = suggestion.line {
                Text(line)
                    .font(.caption)
                    .opacity(0.75)
                    .lineLimit(1)
            }
        }
        .frame(width: Self.width, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// "Still watching?": playback waits. Continue Watching plays on, Stop closes.
private struct StillWatchingPanel: View {
    let model: PlayerModel
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.lobbyArtworkScrim.opacity(0.7)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(spacing: AppTheme.Space.l) {
                Text(UpNextWords.stillWatching(kids: model.isForKids))
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("upNext.stillWatching")
                if let next = model.upNext?.subtitle ?? model.suggestions.first?.title {
                    Text(next)
                        .font(.subheadline)
                        .opacity(0.8)
                }
                HStack(spacing: AppTheme.Space.m) {
                    Button("Continue Watching") { model.continueWatching() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("upNext.continue")
                    Button("Stop", action: close)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("upNext.stop")
                }
                .controlSize(.large)
            }
            .padding(AppTheme.Space.xl)
            .frame(maxWidth: 480)
        }
    }
}
#endif

/// The words of the end screens, on every platform and on the remote.
enum UpNextWords {
    /// "Next episode in 8 s", or "Next episode".
    static func heading(_ countdown: UpNextCountdown?) -> String {
        guard let countdown else { return "Next episode" }
        return "Next episode in \(countdown.remaining) s"
    }

    static func suggestionsLine(_ countdown: UpNextCountdown?, first: UpNextSuggestion?) -> String {
        if let countdown, let first { return "\(first.title) starts in \(countdown.remaining) s" }
        return "Pick something to watch next"
    }

    static func stillWatching(kids: Bool) -> String {
        kids ? "Still watching?" : "Are you still watching?"
    }
}
