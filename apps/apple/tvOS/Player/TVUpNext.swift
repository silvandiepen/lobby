// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// What the Apple TV shows at the end, over the last picture (docs/playback.md, "When something
/// ends"): Up Next for the next episode, the suggestions after a film or a series that is over,
/// or "Still watching?". Back closes the player (`TVPlayerScreen`).
struct TVUpNextOverlay: View {
    let model: PlayerModel
    let close: () -> Void

    var body: some View {
        switch model.ending {
        case .nextEpisode:
            TVUpNextCard(model: model, close: close)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(80)
        case .suggestions:
            TVSuggestionsScreen(model: model)
        case .stillWatching:
            TVStillWatching(model: model, close: close)
        case nil:
            EmptyView()
        }
    }
}

private struct TVUpNextCard: View {
    let model: PlayerModel
    let close: () -> Void
    @FocusState private var playNowIsFocused: Bool

    var body: some View {
        if let next = model.upNext {
            HStack(spacing: TVMetrics.gap) {
                ArtworkView(artwork: next.item.artwork.still ?? next.show?.artwork.backdrop, width: TVMetrics.still) {
                    Color.lobbyArtworkScrim
                }
                .frame(width: TVMetrics.still, height: TVMetrics.still / AppTheme.wideAspect)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AppTheme.Space.m) {
                    Text(UpNextWords.heading(model.countdown))
                        .font(.callout.weight(.semibold))
                        .opacity(0.8)
                    Text(next.subtitle ?? next.title)
                        .font(.headline)
                        .lineLimit(2)
                    HStack(spacing: AppTheme.Space.l) {
                        Button("Play Now", systemImage: AppSymbol.play) { model.playUpNextNow() }
                            .focused($playNowIsFocused)
                            .accessibilityIdentifier("upNext.playNow")
                        if model.countdown != nil {
                            Button("Cancel") { model.cancelUpNext() }
                                .accessibilityIdentifier("upNext.cancel")
                        } else {
                            Button("Close", action: close)
                        }
                    }
                }
            }
            .padding(AppTheme.Space.xl)
            .frame(maxWidth: TVMetrics.readable)
            .foregroundStyle(Color.lobbyOnArtwork)
            .background(Color.lobbyArtworkScrim.opacity(0.75), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            .focusSection()
            .onAppear { playNowIsFocused = true }
            .accessibilityIdentifier("upNext.card")
        }
    }
}

private struct TVSuggestionsScreen: View {
    let model: PlayerModel
    @FocusState private var focused: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color.lobbyArtworkScrim.opacity(0.3), Color.lobbyArtworkScrim.opacity(0.92)],
                startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: TVMetrics.gap) {
                VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                    Text(model.request.title)
                        .font(.title2.weight(.bold))
                    Text(UpNextWords.suggestionsLine(model.countdown, first: model.suggestions.first))
                        .font(.callout)
                        .opacity(0.85)
                    if model.countdown != nil {
                        Button("Cancel") { model.cancelUpNext() }
                            .accessibilityIdentifier("upNext.cancel")
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: TVMetrics.gap) {
                        ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            Button {
                                model.play(suggestion)
                            } label: {
                                ArtworkView(artwork: suggestion.artwork, width: TVMetrics.wide) {
                                    ZStack {
                                        Color.lobbyTileFill[0]
                                        Text(suggestion.title)
                                            .font(.headline)
                                            .multilineTextAlignment(.center)
                                            .padding(AppTheme.Space.l)
                                    }
                                }
                                .frame(width: TVMetrics.wide, height: TVMetrics.wide / AppTheme.wideAspect)
                                .overlay(alignment: .bottom) {
                                    if index == 0, let countdown = model.countdown {
                                        ProgressView(value: countdown.fraction)
                                            .tint(Color.lobbyOnArtwork)
                                            .padding(AppTheme.Space.l)
                                    }
                                }
                            }
                            .buttonStyle(.card)
                            .focused($focused, equals: suggestion.id)
                            .accessibilityLabel([suggestion.title, suggestion.line].compactMap { $0 }.joined(separator: ", "))
                            .accessibilityIdentifier("upNext.suggestion.\(suggestion.id)")
                        }
                    }
                    .padding(.vertical, AppTheme.Space.xl)
                }
                .scrollClipDisabled()
                Text(focusedLine)
                    .font(.callout)
                    .opacity(0.85)
                    .lineLimit(1)
            }
            .padding(80)
        }
        .foregroundStyle(Color.lobbyOnArtwork)
        .onAppear { focused = model.suggestions.first?.id }
        .accessibilityIdentifier("upNext.suggestions")
    }

    private var focusedLine: String {
        let one = model.suggestions.first { $0.id == focused } ?? model.suggestions.first
        return [one?.title, one?.line].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct TVStillWatching: View {
    let model: PlayerModel
    let close: () -> Void
    @FocusState private var continueIsFocused: Bool

    var body: some View {
        ZStack {
            Color.lobbyArtworkScrim.opacity(0.75)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(spacing: TVMetrics.gap) {
                Text(UpNextWords.stillWatching(kids: model.isForKids))
                    .font(.title2.weight(.bold))
                    .accessibilityIdentifier("upNext.stillWatching")
                if let next = model.upNext?.subtitle ?? model.suggestions.first?.title {
                    Text(next)
                        .font(.callout)
                        .opacity(0.8)
                }
                HStack(spacing: TVMetrics.gap) {
                    Button("Continue Watching") { model.continueWatching() }
                        .focused($continueIsFocused)
                        .accessibilityIdentifier("upNext.continue")
                    Button("Stop", action: close)
                        .accessibilityIdentifier("upNext.stop")
                }
            }
            .foregroundStyle(Color.lobbyOnArtwork)
            .frame(maxWidth: TVMetrics.readable)
        }
        .focusSection()
        .onAppear { continueIsFocused = true }
    }
}
