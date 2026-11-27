// SPDX-License-Identifier: MPL-2.0
public enum MediaFileRole: OpenStringEnum {
    case main, trailer, extra
    case unknown(String)

    public static let knownCases: [MediaFileRole] = [.main, .trailer, .extra]

    public var rawValue: String {
        switch self {
        case .main: "main"
        case .trailer: "trailer"
        case .extra: "extra"
        case .unknown(let raw): raw
        }
    }
}

/// What Apple's player needs to play a file, as the server judged it.
public enum Playability: OpenStringEnum {
    /// Plays as it is.
    case direct
    /// The picture is fine, the container or sound is not.
    case remux
    /// The picture must be re-encoded.
    case transcode
    /// No usable video.
    case unsupported
    case unknown(String)

    public static let knownCases: [Playability] = [.direct, .remux, .transcode, .unsupported]

    public var rawValue: String {
        switch self {
        case .direct: "direct"
        case .remux: "remux"
        case .transcode: "transcode"
        case .unsupported: "unsupported"
        case .unknown(let raw): raw
        }
    }
}

public enum SubtitleSource: OpenStringEnum {
    case embedded, sidecar
    case unknown(String)

    public static let knownCases: [SubtitleSource] = [.embedded, .sidecar]

    public var rawValue: String {
        switch self {
        case .embedded: "embedded"
        case .sidecar: "sidecar"
        case .unknown(let raw): raw
        }
    }
}

public struct VideoTrack: Codable, Hashable, Sendable {
    public var codec: String
    public var width: Int?
    public var height: Int?
    public var bitDepth: Int

    public init(codec: String, width: Int?, height: Int?, bitDepth: Int) {
        self.codec = codec
        self.width = width
        self.height = height
        self.bitDepth = bitDepth
    }
}

public struct AudioTrack: Codable, Hashable, Sendable {
    public var index: Int
    public var codec: String
    public var language: String?
    public var title: String?
    public var channels: Int?
    public var isDefault: Bool

    public init(index: Int, codec: String, language: String?, title: String?, channels: Int?, isDefault: Bool) {
        self.index = index
        self.codec = codec
        self.language = language
        self.title = title
        self.channels = channels
        self.isDefault = isDefault
    }
}

public struct SubtitleTrack: Codable, Hashable, Sendable, Identifiable {
    /// Use in the subtitle URL.
    public var id: String
    public var source: SubtitleSource
    public var codec: String
    public var language: String?
    public var title: String?
    public var isForced: Bool
    /// Text subtitles, as WebVTT. Picture subtitles (PGS, DVD) are `isPicture`, drawn from placed PNGs.
    public var isText: Bool

    public init(
        id: String, source: SubtitleSource, codec: String, language: String?, title: String?,
        isForced: Bool, isText: Bool
    ) {
        self.id = id
        self.source = source
        self.codec = codec
        self.language = language
        self.title = title
        self.isForced = isForced
        self.isText = isText
    }
}

public struct MediaFile: Codable, Hashable, Sendable {
    public var assetId: String
    public var role: MediaFileRole
    public var edition: String?
    /// Part number of a film split over several files.
    public var part: Int?
    /// Set when one file holds several episodes and the boundaries are known.
    public var startMs: Int?
    public var endMs: Int?
    /// How many episodes share this file. 1 normally.
    public var sharedBy: Int
    public var available: Bool
    public var sizeBytes: Int64
    public var durationMs: Int?
    public var container: String
    /// Changes when the file's bytes change. A download made from another revision is stale.
    public var revision: String
    public var playability: Playability
    /// A sentence for the viewer when playability is not `.direct`.
    public var playabilityReason: String?
    /// The server converts the picture itself. nil from a server that does not say.
    public var convertible: Bool?
    public var video: VideoTrack?
    public var audio: [AudioTrack]
    public var subtitles: [SubtitleTrack]
    /// Where its intro and credits are, when the server knows. nil from a server before them.
    public var markers: PlaybackMarkers?

    public init(
        assetId: String, role: MediaFileRole = .main, edition: String? = nil, part: Int? = nil,
        startMs: Int? = nil, endMs: Int? = nil, sharedBy: Int = 1, available: Bool = true,
        sizeBytes: Int64, durationMs: Int?, container: String, revision: String,
        playability: Playability, playabilityReason: String? = nil, convertible: Bool? = nil, video: VideoTrack?,
        audio: [AudioTrack] = [], subtitles: [SubtitleTrack] = [], markers: PlaybackMarkers? = nil
    ) {
        self.assetId = assetId
        self.role = role
        self.edition = edition
        self.part = part
        self.startMs = startMs
        self.endMs = endMs
        self.sharedBy = sharedBy
        self.available = available
        self.sizeBytes = sizeBytes
        self.durationMs = durationMs
        self.container = container
        self.revision = revision
        self.playability = playability
        self.playabilityReason = playabilityReason
        self.convertible = convertible
        self.video = video
        self.audio = audio
        self.subtitles = subtitles
        self.markers = markers
    }
}

/// Where a file's intro and credits are, in milliseconds from the start of the file
/// (`docs/api.md`, Library). From the file's chapters, found by comparing the episodes of a
/// season, or set by a manager.
public struct PlaybackMarkers: Codable, Hashable, Sendable {
    public struct Intro: Codable, Hashable, Sendable {
        public var startMs: Int
        public var endMs: Int
        public var source: String?

        public init(startMs: Int, endMs: Int, source: String? = nil) {
            self.startMs = startMs
            self.endMs = endMs
            self.source = source
        }
    }

    public struct Credits: Codable, Hashable, Sendable {
        public var startMs: Int
        public var source: String?

        public init(startMs: Int, source: String? = nil) {
            self.startMs = startMs
            self.source = source
        }
    }

    public var intro: Intro?
    public var credits: Credits?

    public init(intro: Intro? = nil, credits: Credits? = nil) {
        self.intro = intro
        self.credits = credits
    }

    private enum CodingKeys: String, CodingKey { case intro, credits }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // One that cannot be read is as good as none: the film plays without the buttons.
        intro = (try? container.decodeIfPresent(Intro.self, forKey: .intro)).flatMap { $0 }
        credits = (try? container.decodeIfPresent(Credits.self, forKey: .credits)).flatMap { $0 }
    }
}
