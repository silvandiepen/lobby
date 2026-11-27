// SPDX-License-Identifier: MPL-2.0
import Foundation

// HomePods and other AirPlay speakers that Lobby Server plays to itself (docs/api.md, "Playing on
// a speaker"; docs/decisions.md, "Play on a speaker"). The app only says what to play and
// controls it; the sound goes from the server to the speaker, so the app can go.

public enum SpeakerKind: OpenStringEnum {
    case homepod, speaker
    case unknown(String)

    public static let knownCases: [SpeakerKind] = [.homepod, .speaker]

    public var rawValue: String {
        switch self {
        case .homepod: "homepod"
        case .speaker: "speaker"
        case .unknown(let raw): raw
        }
    }
}

/// Whether a speaker is likely to let Lobby Server play, as the server last saw it.
public enum SpeakerAccess: OpenStringEnum {
    case open
    /// It wants a password; a manager can enter it under Speakers.
    case password
    /// It lets only people of its Home play: Home app → Allow Speaker & TV Access.
    case homeOnly
    case unknown(String)

    public static let knownCases: [SpeakerAccess] = [.open, .password, .homeOnly]

    public var rawValue: String {
        switch self {
        case .open: "open"
        case .password: "password"
        case .homeOnly: "home_only"
        case .unknown(let raw): raw
        }
    }
}

/// Why a speaker stopped by itself.
public enum SpeakerProblem: OpenStringEnum {
    case refused, notFound, timeout, unavailable, driveAway, kidsMode, failed
    case unknown(String)

    public static let knownCases: [SpeakerProblem] = [.refused, .notFound, .timeout, .unavailable, .driveAway, .kidsMode, .failed]

    public var rawValue: String {
        switch self {
        case .refused: "refused"
        case .notFound: "not_found"
        case .timeout: "timeout"
        case .unavailable: "unavailable"
        case .driveAway: "drive_away"
        case .kidsMode: "kids_mode"
        case .failed: "failed"
        case .unknown(let raw): raw
        }
    }
}

/// What plays on a speaker, when this device may see it.
public struct SpeakerPlayState: Decodable, Hashable, Sendable {
    public enum Kind: OpenStringEnum {
        case story, music
        case unknown(String)

        public static let knownCases: [Kind] = [.story, .music]

        public var rawValue: String {
            switch self {
            case .story: "story"
            case .music: "music"
            case .unknown(let raw): raw
            }
        }
    }

    /// The viewer it plays for: their place in a story is kept.
    public var profileId: String
    public var kind: Kind
    public var bookId: String?
    public var albumId: String?
    public var trackIds: [String]
    public var index: Int
    public var trackId: String
    public var status: RemotePlayerStatus
    /// In the current track, at `at` (server time, ms); moves on by itself while playing.
    public var positionMs: Int
    public var at: Int64
    public var durationMs: Int?
    public var problem: SpeakerProblem?
    /// The device that started it.
    public var startedBy: String

    public init(
        profileId: String, kind: Kind, bookId: String? = nil, albumId: String? = nil, trackIds: [String], index: Int,
        trackId: String, status: RemotePlayerStatus, positionMs: Int, at: Int64, durationMs: Int?,
        problem: SpeakerProblem? = nil, startedBy: String
    ) {
        self.profileId = profileId
        self.kind = kind
        self.bookId = bookId
        self.albumId = albumId
        self.trackIds = trackIds
        self.index = index
        self.trackId = trackId
        self.status = status
        self.positionMs = positionMs
        self.at = at
        self.durationMs = durationMs
        self.problem = problem
        self.startedBy = startedBy
    }

    /// Where it is in the track at `serverNow`, as the server works it out.
    public func positionMs(at serverNow: Int64) -> Int {
        guard status == .playing else { return positionMs }
        let moved = positionMs + Int(max(0, serverNow - at))
        return durationMs.map { min(moved, $0) } ?? moved
    }

    public var hasNext: Bool { index + 1 < trackIds.count }
}

public enum SpeakerPlay: Decodable, Hashable, Sendable {
    /// Something plays that this device may not see (a child sees a grown-up's music so).
    case redacted(status: RemotePlayerStatus)
    case visible(SpeakerPlayState)

    private enum CodingKeys: String, CodingKey { case redacted, status }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if try c.decodeIfPresent(Bool.self, forKey: .redacted) == true {
            self = .redacted(status: try c.decode(RemotePlayerStatus.self, forKey: .status))
        } else {
            self = .visible(try SpeakerPlayState(from: decoder))
        }
    }

    public var status: RemotePlayerStatus {
        switch self {
        case .redacted(let status): status
        case .visible(let state): state.status
        }
    }

    public var state: SpeakerPlayState? {
        if case .visible(let state) = self { return state }
        return nil
    }
}

/// A speaker in Play On, from the live channel's `speakers` event.
public struct ShownSpeaker: Decodable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: SpeakerKind
    /// Something can be started on it now.
    public var canPlay: Bool
    public var access: SpeakerAccess
    /// 0 to 1, as the speaker last said; nil before it played.
    public var volume: Double?
    /// What plays on it is this device's to pause, stop and so on.
    public var controllable: Bool
    public var play: SpeakerPlay?

    public init(
        id: String, name: String, kind: SpeakerKind = .homepod, canPlay: Bool = true, access: SpeakerAccess = .open,
        volume: Double? = nil, controllable: Bool = false, play: SpeakerPlay? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.canPlay = canPlay
        self.access = access
        self.volume = volume
        self.controllable = controllable
        self.play = play
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, canPlay, access, volume, controllable, play }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(SpeakerKind.self, forKey: .kind) ?? .speaker
        canPlay = try c.decodeIfPresent(Bool.self, forKey: .canPlay) ?? false
        access = try c.decodeIfPresent(SpeakerAccess.self, forKey: .access) ?? .open
        volume = try c.decodeIfPresent(Double.self, forKey: .volume)
        controllable = try c.decodeIfPresent(Bool.self, forKey: .controllable) ?? false
        play = try c.decodeIfPresent(SpeakerPlay.self, forKey: .play)
    }
}

/// `POST /v1/speakers/{id}/play`: music from a track of a list, or a story from where the viewer was.
public struct SpeakerPlayRequest: Encodable, Hashable, Sendable {
    public var profileId: String
    public var trackIds: [String]?
    public var index: Int
    public var bookId: String?
    /// In the track for music, on the book's line of time for a story; nil: from the start, or
    /// where the viewer was in the story.
    public var startMs: Int?
    public var albumId: String?

    public static func music(profileID: String, trackIDs: [String], index: Int = 0, startMs: Int? = nil, albumID: String? = nil) -> Self {
        Self(profileId: profileID, trackIds: trackIDs, index: index, bookId: nil, startMs: startMs, albumId: albumID)
    }

    public static func story(profileID: String, bookID: String, startMs: Int? = nil) -> Self {
        Self(profileId: profileID, trackIds: nil, index: 0, bookId: bookID, startMs: startMs, albumId: nil)
    }
}

/// `POST /v1/speakers/{id}/control`.
public enum SpeakerAction: Hashable, Sendable, Encodable {
    case pause, resume, stop, next, previous
    case skip(deltaMs: Int)
    case seek(positionMs: Int)
    case volume(Double)

    private enum CodingKeys: String, CodingKey { case type, deltaMs, positionMs, volume }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pause: try c.encode("pause", forKey: .type)
        case .resume: try c.encode("resume", forKey: .type)
        case .stop: try c.encode("stop", forKey: .type)
        case .next: try c.encode("next", forKey: .type)
        case .previous: try c.encode("previous", forKey: .type)
        case .skip(let delta):
            try c.encode("skip", forKey: .type)
            try c.encode(delta, forKey: .deltaMs)
        case .seek(let position):
            try c.encode("seek", forKey: .type)
            try c.encode(position, forKey: .positionMs)
        case .volume(let volume):
            try c.encode("volume", forKey: .type)
            try c.encode(volume, forKey: .volume)
        }
    }
}

/// `GET /v1/speakers`: a speaker as a manager sees it.
public struct ManagedSpeaker: Decodable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var foundName: String
    public var customName: String?
    public var model: String
    public var kind: SpeakerKind
    public var hidden: Bool
    public var found: Bool
    public var access: SpeakerAccess
    public var hasPassword: Bool
    public var playing: Bool

    public init(
        id: String, name: String, foundName: String, customName: String? = nil, model: String = "", kind: SpeakerKind = .homepod,
        hidden: Bool = false, found: Bool = true, access: SpeakerAccess = .open, hasPassword: Bool = false, playing: Bool = false
    ) {
        self.id = id
        self.name = name
        self.foundName = foundName
        self.customName = customName
        self.model = model
        self.kind = kind
        self.hidden = hidden
        self.found = found
        self.access = access
        self.hasPassword = hasPassword
        self.playing = playing
    }
}

/// `GET /v1/speakers`.
public struct SpeakersStatus: Decodable, Hashable, Sendable {
    /// `remote.wake` is in lobby.config.json: the helper is set up.
    public var configured: Bool
    /// The setting "Play on HomePods and speakers".
    public var enabled: Bool
    public var running: Bool
    public var problem: String?
    public var scannedAt: Int64?
    public var speakers: [ManagedSpeaker]

    public init(
        configured: Bool, enabled: Bool, running: Bool, problem: String? = nil, scannedAt: Int64? = nil,
        speakers: [ManagedSpeaker]
    ) {
        self.configured = configured
        self.enabled = enabled
        self.running = running
        self.problem = problem
        self.scannedAt = scannedAt
        self.speakers = speakers
    }
}

extension LobbyClient {
    /// `POST /v1/speakers/{id}/play`. Answers once the speaker plays. Throws `RemoteRefusal`;
    /// `speaker_refused` says the speaker would not let Lobby Server play.
    ///
    /// - Parameter session: this device's channel, so that the server knows who asks (the kids
    ///   screens play only as their child).
    public func playOnSpeaker(id: String, session: String, request: SpeakerPlayRequest) async throws -> ShownSpeaker {
        struct Body: Encodable {
            var session: String
            var request: SpeakerPlayRequest

            func encode(to encoder: any Encoder) throws {
                try request.encode(to: encoder)
                var c = encoder.container(keyedBy: Key.self)
                try c.encode(session, forKey: .session)
            }

            enum Key: String, CodingKey { case session }
        }
        return try decode(try await remote("POST", ["speakers", id, "play"], body: Body(session: session, request: request)))
    }

    /// `POST /v1/speakers/{id}/control`. Throws `RemoteRefusal`.
    public func controlSpeaker(id: String, session: String, action: SpeakerAction) async throws -> ShownSpeaker {
        struct Body: Encodable {
            var session: String
            var action: SpeakerAction

            func encode(to encoder: any Encoder) throws {
                try action.encode(to: encoder)
                var c = encoder.container(keyedBy: Key.self)
                try c.encode(session, forKey: .session)
            }

            enum Key: String, CodingKey { case session }
        }
        return try decode(try await remote("POST", ["speakers", id, "control"], body: Body(session: session, action: action)))
    }

    /// `GET /v1/speakers`. Manager.
    public func speakers() async throws -> SpeakersStatus {
        var request = request("GET", ["speakers"])
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return try decode(try await perform(request).0)
    }

    /// `PATCH /v1/speakers`: "Play on HomePods and speakers". Manager.
    public func setSpeakers(enabled: Bool) async throws -> SpeakersStatus {
        struct Body: Encodable { var enabled: Bool }
        return try await send("PATCH", ["speakers"], body: Body(enabled: enabled))
    }

    /// `POST /v1/speakers/scan`: looks on the network for a few seconds. Manager.
    public func scanForSpeakers() async throws -> SpeakersStatus {
        try await send("POST", ["speakers", "scan"])
    }

    /// `PATCH /v1/speakers/{id}` `{ name }`: nil gives it its own name again. Manager.
    public func renameSpeaker(id: String, name: String?) async throws -> ManagedSpeaker {
        struct Body: Encodable {
            var name: String?
            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: Key.self)
                try c.encode(name, forKey: .name)
            }
            enum Key: String, CodingKey { case name }
        }
        return try await send("PATCH", ["speakers", id], body: Body(name: name))
    }

    /// `PATCH /v1/speakers/{id}` `{ hidden }`: a hidden speaker is not in Play On. Manager.
    public func hideSpeaker(id: String, hidden: Bool) async throws -> ManagedSpeaker {
        struct Body: Encodable { var hidden: Bool }
        return try await send("PATCH", ["speakers", id], body: Body(hidden: hidden))
    }

    /// `PUT /v1/speakers/{id}/password`: kept in pyatv's file on the server; nil removes it. Manager.
    public func setSpeakerPassword(id: String, password: String?) async throws -> ManagedSpeaker {
        struct Body: Encodable {
            var password: String?
            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: Key.self)
                try c.encode(password, forKey: .password)
            }
            enum Key: String, CodingKey { case password }
        }
        return try await send("PUT", ["speakers", id, "password"], body: Body(password: password))
    }
}
