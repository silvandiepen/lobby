// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Subtitles stored as pictures (Blu-ray PGS, DVD, DVB), as the server reads them: each cue a
/// PNG with its place on a screen of the video's size (docs/decisions.md, "Subtitles per viewer"). The app draws them over the
/// picture: no player shows them in a stream, and they cannot become text.
public struct PictureSubtitles: Codable, Hashable, Sendable {
    public struct Cue: Codable, Hashable, Sendable {
        public var startMs: Int
        public var endMs: Int
        /// Where the picture goes on a screen of `PictureSubtitles.width` × `height`.
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int
        /// A PNG with transparency.
        public var png: Data

        public init(startMs: Int, endMs: Int, x: Int, y: Int, width: Int, height: Int, png: Data) {
            self.startMs = startMs
            self.endMs = endMs
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.png = png
        }
    }

    /// The screen the cues are placed on.
    public var width: Int
    public var height: Int
    /// In time order.
    public var cues: [Cue]

    public init(width: Int, height: Int, cues: [Cue]) {
        self.width = width
        self.height = height
        self.cues = cues.sorted { $0.startMs < $1.startMs }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            width: try container.decode(Int.self, forKey: .width),
            height: try container.decode(Int.self, forKey: .height),
            cues: try container.decode([Cue].self, forKey: .cues))
    }

    /// The cue on screen at a moment of the file, or nil.
    public func cue(atMs position: Int) -> Cue? {
        // The last cue that started by then; cues do not overlap.
        var low = 0
        var high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].startMs <= position { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        let cue = cues[low - 1]
        return position < cue.endMs ? cue : nil
    }
}

extension SubtitleTrack {
    /// The codecs of subtitles stored as pictures, which the server reads into placed PNGs.
    public static let pictureCodecs: Set<String> = [
        "hdmv_pgs_subtitle", "pgssub", "dvd_subtitle", "dvdsub", "dvb_subtitle", "dvbsub",
    ]

    /// Stored as pictures: `pictureSubtitles` has them, the WebVTT call does not.
    public var isPicture: Bool { !isText && Self.pictureCodecs.contains(codec) }
}
