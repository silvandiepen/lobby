// SPDX-License-Identifier: MPL-2.0
import Foundation

// Posters, backdrops and stills as the server scales them (`docs/api.md`, `GET /v1/artwork/{artworkId}`).

/// The widths the artwork endpoint scales to. Other values round up on the server.
public enum ArtworkWidth: Int, Sendable, CaseIterable {
    case w200 = 200
    case w400 = 400
    case w800 = 800
    case w1280 = 1280
    case w1600 = 1600
    /// A server from before banners answers its largest, 1600.
    case w1920 = 1920

    /// The smallest width that covers `pixels` (points × display scale), or the largest there is.
    public static func covering(pixels: Int) -> ArtworkWidth {
        allCases.first { $0.rawValue >= pixels } ?? .w1920
    }
}

extension LobbyClient {
    /// `GET /v1/artwork/{artworkId}?w=<width>`: a poster, backdrop or still as JPEG.
    ///
    /// An artwork id never changes its picture, so the result can be cached forever.
    public func artworkURL(_ artwork: Artwork, width: ArtworkWidth) -> URL {
        if let cover = artwork.musicCoverID { return musicCoverURL(cover, width: width.rawValue) }
        return url(["artwork", artwork.id], query: [URLQueryItem(name: "w", value: String(width.rawValue))])
    }
}
