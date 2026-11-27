// SPDX-License-Identifier: MPL-2.0
import Foundation

// The household's audio as `docs/api.md` ("Music and audiobooks") describes it. Apart from the
// films: none of this is an `Item`.

public struct MusicArtist: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var sortName: String
    public var mbid: String?
    public var addedAt: Date

    public init(id: String, name: String, sortName: String? = nil, mbid: String? = nil, addedAt: Date) {
        self.id = id
        self.name = name
        self.sortName = sortName ?? name.lowercased()
        self.mbid = mbid
        self.addedAt = addedAt
    }
}

public struct MusicAlbum: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var sortTitle: String
    /// As the sleeve says it; "Various Artists" for a compilation without album artists.
    public var artistCredit: String
    public var artistIds: [String]
    public var compilation: Bool
    public var year: Int?
    public var genres: [String]
    public var trackCount: Int
    public var discCount: Int
    public var durationMs: Int
    public var coverId: String?
    public var mbid: String?
    public var addedAt: Date

    public init(
        id: String, title: String, sortTitle: String? = nil, artistCredit: String, artistIds: [String],
        compilation: Bool = false, year: Int? = nil, genres: [String] = [], trackCount: Int, discCount: Int = 1,
        durationMs: Int, coverId: String? = nil, mbid: String? = nil, addedAt: Date
    ) {
        self.id = id
        self.title = title
        self.sortTitle = sortTitle ?? title.lowercased()
        self.artistCredit = artistCredit
        self.artistIds = artistIds
        self.compilation = compilation
        self.year = year
        self.genres = genres
        self.trackCount = trackCount
        self.discCount = discCount
        self.durationMs = durationMs
        self.coverId = coverId
        self.mbid = mbid
        self.addedAt = addedAt
    }
}

/// A part of a track or a book with a name.
public struct MusicChapter: Codable, Hashable, Sendable {
    public var title: String?
    public var startMs: Int
    public var endMs: Int

    public init(title: String?, startMs: Int, endMs: Int) {
        self.title = title
        self.startMs = startMs
        self.endMs = endMs
    }
}

public struct ReplayGain: Codable, Hashable, Sendable {
    public var trackGainDb: Double?
    public var trackPeak: Double?
    public var albumGainDb: Double?
    public var albumPeak: Double?

    public init(trackGainDb: Double? = nil, trackPeak: Double? = nil, albumGainDb: Double? = nil, albumPeak: Double? = nil) {
        self.trackGainDb = trackGainDb
        self.trackPeak = trackPeak
        self.albumGainDb = albumGainDb
        self.albumPeak = albumPeak
    }
}

public enum MusicPlayability: OpenStringEnum {
    /// AVPlayer plays the file itself.
    case direct
    /// AVPlayer does not (Ogg, Opus, WMA…): a 256 kbit/s copy is played.
    case convert
    case unknown(String)

    public static let knownCases: [MusicPlayability] = [.direct, .convert]

    public var rawValue: String {
        switch self {
        case .direct: "direct"
        case .convert: "convert"
        case .unknown(let raw): raw
        }
    }
}

public struct MusicFile: Codable, Hashable, Sendable {
    /// Changes when the file's bytes change. A download made from another revision is stale.
    public var revision: String
    public var sizeBytes: Int64
    public var container: String
    public var codec: String
    public var lossless: Bool
    public var bitRate: Int?
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var channels: Int?
    public var playability: MusicPlayability
    /// The compact qualities that are smaller than the file itself.
    public var compact: [Int]

    public init(
        revision: String, sizeBytes: Int64, container: String, codec: String, lossless: Bool = false,
        bitRate: Int? = nil, sampleRate: Int? = nil, bitDepth: Int? = nil, channels: Int? = nil,
        playability: MusicPlayability = .direct, compact: [Int] = []
    ) {
        self.revision = revision
        self.sizeBytes = sizeBytes
        self.container = container
        self.codec = codec
        self.lossless = lossless
        self.bitRate = bitRate
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.playability = playability
        self.compact = compact
    }

    /// The file name extension AVPlayer needs to open a copy of this file on the device.
    public var fileExtension: String {
        switch container.lowercased() {
        case "mp3": "mp3"
        case "flac": "flac"
        case "wav", "wave": "wav"
        case "aiff", "aif", "aifc": "aiff"
        case "caf": "caf"
        case "aac": "aac"
        case "ac3": "ac3"
        case "eac3": "eac3"
        default: "m4a"
        }
    }
}

public struct MusicTrack: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var sortTitle: String
    public var artistCredit: String
    /// Empty for a track of a book.
    public var artistIds: [String]
    /// Both nil for a loose track.
    public var albumId: String?
    public var bookId: String?
    public var disc: Int?
    public var track: Int?
    public var year: Int?
    public var genres: [String]
    public var composers: [String]
    public var durationMs: Int?
    public var chapters: [MusicChapter]
    public var replayGain: ReplayGain?
    /// Only a loose track has its own; others show their album's or book's.
    public var coverId: String?
    public var mbid: String?
    public var addedAt: Date
    public var available: Bool
    public var file: MusicFile

    public init(
        id: String, title: String, sortTitle: String? = nil, artistCredit: String, artistIds: [String] = [],
        albumId: String? = nil, bookId: String? = nil, disc: Int? = nil, track: Int? = nil, year: Int? = nil,
        genres: [String] = [], composers: [String] = [], durationMs: Int?, chapters: [MusicChapter] = [],
        replayGain: ReplayGain? = nil, coverId: String? = nil, mbid: String? = nil, addedAt: Date,
        available: Bool = true, file: MusicFile
    ) {
        self.id = id
        self.title = title
        self.sortTitle = sortTitle ?? title.lowercased()
        self.artistCredit = artistCredit
        self.artistIds = artistIds
        self.albumId = albumId
        self.bookId = bookId
        self.disc = disc
        self.track = track
        self.year = year
        self.genres = genres
        self.composers = composers
        self.durationMs = durationMs
        self.chapters = chapters
        self.replayGain = replayGain
        self.coverId = coverId
        self.mbid = mbid
        self.addedAt = addedAt
        self.available = available
        self.file = file
    }

    /// The album's order: disc (none is 1), then track (none last), then title.
    public static func albumOrder(_ a: MusicTrack, _ b: MusicTrack) -> Bool {
        let discs = (a.disc ?? 1, b.disc ?? 1)
        if discs.0 != discs.1 { return discs.0 < discs.1 }
        switch (a.track, b.track) {
        case (let x?, let y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.sortTitle < b.sortTitle
        }
    }
}

public struct MusicBook: Codable, Hashable, Sendable, Identifiable {
    public struct Part: Codable, Hashable, Sendable {
        public var trackId: String
        /// On the book's own line of time.
        public var startMs: Int
        public var durationMs: Int?

        public init(trackId: String, startMs: Int, durationMs: Int?) {
            self.trackId = trackId
            self.startMs = startMs
            self.durationMs = durationMs
        }
    }

    public struct Chapter: Codable, Hashable, Sendable {
        public var title: String?
        /// On the book's line of time.
        public var startMs: Int
        public var endMs: Int
        public var trackId: String
        /// Where the chapter starts in its file.
        public var trackStartMs: Int

        public init(title: String?, startMs: Int, endMs: Int, trackId: String, trackStartMs: Int) {
            self.title = title
            self.startMs = startMs
            self.endMs = endMs
            self.trackId = trackId
            self.trackStartMs = trackStartMs
        }
    }

    public var id: String
    public var title: String
    public var sortTitle: String
    public var authors: [String]
    public var narrators: [String]
    public var series: String?
    public var seriesPosition: Double?
    public var year: Int?
    public var genres: [String]
    public var description: String?
    public var language: String?
    public var durationMs: Int
    public var coverId: String?
    public var addedAt: Date
    public var parts: [Part]
    public var chapters: [Chapter]

    public init(
        id: String, title: String, sortTitle: String? = nil, authors: [String] = [], narrators: [String] = [],
        series: String? = nil, seriesPosition: Double? = nil, year: Int? = nil, genres: [String] = [],
        description: String? = nil, language: String? = nil, durationMs: Int, coverId: String? = nil,
        addedAt: Date, parts: [Part], chapters: [Chapter] = []
    ) {
        self.id = id
        self.title = title
        self.sortTitle = sortTitle ?? title.lowercased()
        self.authors = authors
        self.narrators = narrators
        self.series = series
        self.seriesPosition = seriesPosition
        self.year = year
        self.genres = genres
        self.description = description
        self.language = language
        self.durationMs = durationMs
        self.coverId = coverId
        self.addedAt = addedAt
        self.parts = parts
        self.chapters = chapters
    }

    /// Where a moment of the book is: its part and the position in that file.
    public func place(atBookMs bookMs: Int) -> (part: Int, trackMs: Int)? {
        guard !parts.isEmpty else { return nil }
        let clamped = max(0, min(bookMs, durationMs))
        let index = parts.lastIndex { $0.startMs <= clamped } ?? 0
        return (index, clamped - parts[index].startMs)
    }

    /// The moment on the book's line of time of a position in one of its files.
    public func bookMs(trackID: String, trackMs: Int) -> Int? {
        parts.first { $0.trackId == trackID }.map { $0.startMs + max(0, trackMs) }
    }

    /// The chapter a moment of the book is in.
    public func chapterIndex(atBookMs bookMs: Int) -> Int? {
        chapters.lastIndex { $0.startMs <= bookMs }
    }
}

/// `GET /v1/music/library`: one page.
public struct MusicLibraryPage: Codable, Hashable, Sendable {
    public var artists: [MusicArtist]
    public var albums: [MusicAlbum]
    public var tracks: [MusicTrack]
    public var books: [MusicBook]
    /// Ids of any kind that are gone.
    public var removed: [String]
    public var cursor: String
    public var more: Bool
    public var reset: Bool

    public init(
        artists: [MusicArtist] = [], albums: [MusicAlbum] = [], tracks: [MusicTrack] = [], books: [MusicBook] = [],
        removed: [String] = [], cursor: String, more: Bool = false, reset: Bool = false
    ) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
        self.books = books
        self.removed = removed
        self.cursor = cursor
        self.more = more
        self.reset = reset
    }
}

public enum MusicQuality: Hashable, Sendable {
    case original
    /// A compact AAC copy, in kbit/s: 256 or 128.
    case compact(Int)

    var json: String {
        switch self {
        case .original: "\"original\""
        case .compact(let kbps): String(kbps)
        }
    }
}

public enum MusicPurpose: String, Sendable {
    case play, download
}

/// The answer of `POST /v1/music/tracks/{id}/playback`.
public struct MusicPlayback: Codable, Hashable, Sendable {
    public enum State: OpenStringEnum {
        case ready, preparing, queued, failed, doesNotFit
        case unknown(String)

        public static let knownCases: [State] = [.ready, .preparing, .queued, .failed, .doesNotFit]

        public var rawValue: String {
            switch self {
            case .ready: "ready"
            case .preparing: "preparing"
            case .queued: "queued"
            case .failed: "failed"
            case .doesNotFit: "does_not_fit"
            case .unknown(let raw): raw
            }
        }
    }

    public var state: State
    /// "direct": the file itself. "copy": AAC in an M4A.
    public var mode: String
    public var revision: String
    public var kbps: Int?
    /// A path on the server; resolve it with the client. nil until ready.
    public var url: String?
    public var bytes: Int64?
    public var progress: Double
    public var message: String?

    public init(
        state: State, mode: String, revision: String, kbps: Int? = nil, url: String?, bytes: Int64?,
        progress: Double = 1, message: String? = nil
    ) {
        self.state = state
        self.mode = mode
        self.revision = revision
        self.kbps = kbps
        self.url = url
        self.bytes = bytes
        self.progress = progress
        self.message = message
    }

    public var isCopy: Bool { mode == "copy" }
}

public enum MusicKind: OpenStringEnum {
    case artist, album, track, book
    case unknown(String)

    public static let knownCases: [MusicKind] = [.artist, .album, .track, .book]

    public var rawValue: String {
        switch self {
        case .artist: "artist"
        case .album: "album"
        case .track: "track"
        case .book: "book"
        case .unknown(let raw): raw
        }
    }
}

public struct MusicFavourite: Codable, Hashable, Sendable {
    public var itemId: String
    public var kind: MusicKind
    public var favourite: Bool
    public var updatedAt: Date

    public init(itemId: String, kind: MusicKind, favourite: Bool, updatedAt: Date) {
        self.itemId = itemId
        self.kind = kind
        self.favourite = favourite
        self.updatedAt = updatedAt
    }
}

public struct MusicPlaylist: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// A track may be in it more than once.
    public var trackIds: [String]
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, name: String, trackIds: [String], revision: Int, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.name = name
        self.trackIds = trackIds
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One listen, as `POST …/plays` takes it. The same `opId` counts once.
public struct MusicPlay: Codable, Hashable, Sendable {
    public var opId: String
    public var trackId: String
    public var playedAt: Date
    public var playedMs: Int
    /// The server counts only these.
    public var completed: Bool

    public init(opId: String = UUID().uuidString.lowercased(), trackId: String, playedAt: Date, playedMs: Int, completed: Bool) {
        self.opId = opId
        self.trackId = trackId
        self.playedAt = playedAt
        self.playedMs = playedMs
        self.completed = completed
    }

    /// When a listen counts as one: it went to the end, or past half of the track, or four
    /// minutes of a long one. A skip in the first moments is no listen at all (nil).
    public static func judge(listenedMs: Int, durationMs: Int?, reachedEnd: Bool) -> Bool? {
        if reachedEnd { return true }
        let duration = durationMs ?? 0
        if duration > 0, listenedMs * 2 >= duration { return true }
        if listenedMs >= 240_000 { return true }
        // Less than half a minute, and less than half of a short one: not heard.
        return listenedMs >= min(30_000, max(duration / 2, 1)) ? false : nil
    }
}
