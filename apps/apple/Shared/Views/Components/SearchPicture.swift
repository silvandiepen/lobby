// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// A poster or a person's picture from TMDB, for what search found beyond the library. Fetched
/// through Lobby Server; while there is none, a quiet tile with a symbol stands in.
struct SearchPicture: View {
    let path: String?
    var symbol = "film"
    var maxPixels = 500
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.lobbyChip(scheme)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: path) {
            guard let path else { return }
            image = await app.searchPicture(path, maxPixels: maxPixels)
        }
        .accessibilityHidden(true)
    }
}

/// The ratings a title has, each with its source said: "TMDB 7.4 · IMDb 8.1 · Rotten Tomatoes 93%".
struct RatingsLine: View {
    let ratings: Ratings
    var font: Font = .caption

    var body: some View {
        let known = ratings.known
        if !known.isEmpty {
            Text(known.map { "\($0.source.shortName) \($0.source.text($0.value))" }.joined(separator: " · "))
                .font(font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel(known.map { "\($0.source.name) \($0.source.text($0.value))" }.joined(separator: ", "))
        }
    }
}

extension RatingSource {
    /// Short enough for under a poster.
    var shortName: String {
        switch self {
        case .tmdb: "TMDB"
        case .imdb: "IMDb"
        case .rottenTomatoes: "RT"
        case .metacritic: "MC"
        }
    }
}
