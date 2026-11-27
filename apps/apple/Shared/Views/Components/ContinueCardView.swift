// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// A card on Continue Watching: a wide picture fading to dark, the title, what is left, a
/// play button, and how far the viewer is along its lower edge.
struct ContinueCardView: View {
    let card: ContinueCard
    let width: CGFloat

    var body: some View {
        ArtworkView(artwork: card.artwork, width: width) {
            // The label carries the title, so without a picture the colour is enough.
            TintField(title: card.tintTitle)
        }
        .frame(width: width, height: width / AppTheme.wideAspect)
        .overlay {
            // Keeps the label readable whatever is in the picture.
            LinearGradient(
                stops: [
                    .init(color: Color.lobbyArtworkScrim.opacity(0), location: 0.3),
                    .init(color: Color.lobbyArtworkScrim.opacity(0.9), location: 1),
                ],
                startPoint: .top, endPoint: .bottom)
        }
        .overlay(alignment: .bottom) { label }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        .tileArtworkSource(cornerRadius: AppTheme.Radius.card)
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.s + 2) {
            HStack(alignment: .bottom, spacing: AppTheme.Space.s) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(card.line)
                        .font(.footnote)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .opacity(0.85)
                }
                Spacer(minLength: 0)
                Image(systemName: card.action.isPlayable ? "play.fill" : "exclamationmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color.lobbyArtworkScrim)
                    .frame(width: 32, height: 32)
                    .background(Color.lobbyOnArtwork, in: Circle())
            }
            if let fraction = card.fraction {
                ProgressBar(fraction: fraction, track: Color.lobbyOnArtwork.opacity(0.3), fill: Color.lobbyAccent(.dark), height: 4)
            }
        }
        .foregroundStyle(Color.lobbyOnArtwork)
        .padding(AppTheme.Space.m + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
