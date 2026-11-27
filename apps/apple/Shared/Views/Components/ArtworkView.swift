// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// A poster, backdrop or still from Lobby Server, or `fallback` while there is none.
///
/// Every `artwork` field is nil until an item is matched, and stays nil for what cannot be
/// matched. The fallback is then what the viewer sees for good. A picture that is on its way
/// has a calm surface in its place, and fades in over it; one that takes long has the fallback
/// meanwhile.
struct ArtworkView<Fallback: View>: View {
    let artwork: Artwork?
    /// How wide the picture is drawn, in points.
    let width: CGFloat
    @ViewBuilder var fallback: Fallback

    @Environment(AppModel.self) private var app
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.motion) private var motion
    @State private var image: CGImage?
    /// It is not there, or not soon.
    @State private var showsFallback = false

    var body: some View {
        ZStack {
            if artwork == nil || showsFallback {
                fallback
                    .transition(.opacity)
            } else if image == nil {
                Color.lobbySurface(scheme)
            }
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFill()
                    // A picture that fills its frame is drawn beyond it and clipped. Clipping
                    // does not stop touches: without this it takes the taps of its neighbours.
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .task(id: artwork?.id) {
            guard let artwork else {
                image = nil
                return
            }
            let asked = ContinuousClock.now
            let patience = Task {
                try await Task.sleep(for: .milliseconds(400))
                withAnimation(motion.animation(.artwork)) { showsFallback = true }
            }
            let picture = await app.artwork(artwork, pixelWidth: Int(width * displayScale))
            patience.cancel()
            // A tile that scrolled away: its picture is asked for again when it comes back.
            guard !Task.isCancelled else { return }
            // What was in memory is there at once: scrolling back does not flicker.
            withAnimation(ContinuousClock.now - asked > .milliseconds(60) ? motion.animation(.artwork) : nil) {
                image = picture
                if picture == nil { showsFallback = true }
            }
        }
    }
}
