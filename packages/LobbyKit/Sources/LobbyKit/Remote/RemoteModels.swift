// SPDX-License-Identifier: MPL-2.0
import Foundation

// Playing on another device (docs/api.md, "Playing on another device"). What the live channel
// says, what a device announces, and the commands one device sends another.

/// Where a player is.
public enum RemotePlayerStatus: OpenStringEnum {
    case loading, playing, paused, buffering, ended, error
    case unknown(String)

    public static let knownCases: [RemotePlayerStatus] = [.loading, .playing, .paused, .buffering, .ended, .error]

    public var rawValue: String {
        switch self {
        case .loading: "loading"
        case .playing: "playing"
        case .paused: "paused"
        case .buffering: "buffering"
        case .ended: "ended"
        case .error: "error"
        case .unknown(let raw): raw
        }
    }
}

/// A sound track or a subtitle as every device names it: sound by `AudioTrack.index` as a
/// string, subtitles by the subtitle track's `id`.
public struct RemoteTrack: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var language: String?

    public init(id: String, label: String, language: String?) {
        self.id = id
        self.label = label
        self.language = language
    }
}

/// What a player shows at the end (`docs/playback.md`, "When something ends"), as the live
/// channel tells it to the device that controls it.
public struct RemoteUpNext: Codable, Hashable, Sendable {
    public enum Kind: OpenStringEnum {
        /// The next episode, with Play Now and Cancel.
        case episode
        /// What goes with a film, or with a series that is over.
        case suggestions
        /// "Still watching?": the player waits for Continue Watching or Stop.
        case stillWatching
        case unknown(String)

        public static let knownCases: [Kind] = [.episode, .suggestions, .stillWatching]

        public var rawValue: String {
            switch self {
            case .episode: "episode"
            case .suggestions: "suggestions"
            case .stillWatching: "stillWatching"
            case .unknown(let raw): raw
            }
        }
    }

    /// What the controller may answer (`upNext` command).
    public enum Action: String, Codable, Hashable, Sendable {
        case playNow, cancel
        /// "Continue Watching".
        case `continue`
    }

    public var kind: Kind
    /// What starts by itself after the countdown, or with Play Now. nil: nothing does.
    public var itemId: String?
    /// How long until it starts by itself, when it was measured. nil: it waits.
    public var countdownMs: Int?
    /// What the viewer may pick from, the first first.
    public var suggestions: [String]

    public init(kind: Kind, itemId: String?, countdownMs: Int?, suggestions: [String] = []) {
        self.kind = kind
        self.itemId = itemId
        self.countdownMs = countdownMs
        self.suggestions = suggestions
    }

    private enum CodingKeys: String, CodingKey { case kind, itemId, countdownMs, suggestions }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        itemId = try c.decodeIfPresent(String.self, forKey: .itemId)
        countdownMs = try c.decodeIfPresent(Double.self, forKey: .countdownMs).map { Int($0) }
        suggestions = try c.decodeIfPresent([String].self, forKey: .suggestions) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(itemId, forKey: .itemId)
        try c.encode(countdownMs, forKey: .countdownMs)
        try c.encode(suggestions, forKey: .suggestions)
    }
}

/// What another device plays, as the server shows it to this one.
public struct RemotePlayerState: Codable, Hashable, Sendable {
    public var itemId: String?
    public var assetId: String?
    /// The viewer.
    public var profileId: String?
    public var status: RemotePlayerStatus
    /// Where it was at `at`, by the server's clock.
    public var positionMs: Int
    public var at: Int64
    public var durationMs: Int?
    public var rate: Double
    public var audioTracks: [RemoteTrack]
    public var audioTrackId: String?
    public var subtitleTracks: [RemoteTrack]
    public var subtitleTrackId: String?
    /// 0 to 1; nil when it cannot tell.
    public var volume: Double?
    public var nextItemId: String?
    public var queue: [String]
    /// What it shows at the end. nil: nothing, or a device from before.
    public var upNext: RemoteUpNext?

    public init(
        itemId: String?, assetId: String? = nil, profileId: String? = nil, status: RemotePlayerStatus,
        positionMs: Int, at: Int64, durationMs: Int?, rate: Double = 1, audioTracks: [RemoteTrack] = [],
        audioTrackId: String? = nil, subtitleTracks: [RemoteTrack] = [], subtitleTrackId: String? = nil,
        volume: Double? = nil, nextItemId: String? = nil, queue: [String] = [], upNext: RemoteUpNext? = nil
    ) {
        self.itemId = itemId
        self.assetId = assetId
        self.profileId = profileId
        self.status = status
        self.positionMs = positionMs
        self.at = at
        self.durationMs = durationMs
        self.rate = rate
        self.audioTracks = audioTracks
        self.audioTrackId = audioTrackId
        self.subtitleTracks = subtitleTracks
        self.subtitleTrackId = subtitleTrackId
        self.volume = volume
        self.nextItemId = nextItemId
        self.queue = queue
        self.upNext = upNext
    }

    private enum CodingKeys: String, CodingKey {
        case itemId, assetId, profileId, status, positionMs, at, durationMs, rate, audioTracks, audioTrackId
        case subtitleTracks, subtitleTrackId, volume, nextItemId, queue, upNext
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemId = try c.decodeIfPresent(String.self, forKey: .itemId)
        assetId = try c.decodeIfPresent(String.self, forKey: .assetId)
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId)
        status = try c.decode(RemotePlayerStatus.self, forKey: .status)
        positionMs = Int(try c.decode(Double.self, forKey: .positionMs))
        at = Int64(try c.decode(Double.self, forKey: .at))
        durationMs = try c.decodeIfPresent(Double.self, forKey: .durationMs).map { Int($0) }
        rate = try c.decodeIfPresent(Double.self, forKey: .rate) ?? 1
        audioTracks = try c.decodeIfPresent([RemoteTrack].self, forKey: .audioTracks) ?? []
        audioTrackId = try c.decodeIfPresent(String.self, forKey: .audioTrackId)
        subtitleTracks = try c.decodeIfPresent([RemoteTrack].self, forKey: .subtitleTracks) ?? []
        subtitleTrackId = try c.decodeIfPresent(String.self, forKey: .subtitleTrackId)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume)
        nextItemId = try c.decodeIfPresent(String.self, forKey: .nextItemId)
        queue = try c.decodeIfPresent([String].self, forKey: .queue) ?? []
        // One a newer device says in a way this app cannot read: as if there were none.
        upNext = (try? c.decodeIfPresent(RemoteUpNext.self, forKey: .upNext)) ?? nil
    }

    /// How long until Up Next starts by itself at `serverNow`. nil: it waits, or there is none.
    public func upNextRemainingMs(atServerTime serverNow: Int64) -> Int? {
        guard let countdown = upNext?.countdownMs else { return nil }
        return max(0, countdown - Int(max(0, serverNow - at)))
    }

    /// Where it is at `serverNow`: only a film that plays moves on, and never past its end.
    public func positionMs(atServerTime serverNow: Int64) -> Int {
        guard status == .playing else { return positionMs }
        let moved = Double(max(0, serverNow - at)) * max(0, rate)
        var position = positionMs + Int(moved.rounded())
        if let durationMs { position = min(position, durationMs) }
        return max(0, position)
    }
}

/// What plays on a device that this one sees: either what, or only that something does.
public enum ShownPlayer: Hashable, Sendable, Decodable {
    /// A title this device may not see, or no film of the library (music). Say "Playing".
    case redacted(status: RemotePlayerStatus)
    case visible(RemotePlayerState)

    private enum CodingKeys: String, CodingKey { case redacted, status }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if try c.decodeIfPresent(Bool.self, forKey: .redacted) == true {
            self = .redacted(status: try c.decode(RemotePlayerStatus.self, forKey: .status))
        } else {
            self = .visible(try RemotePlayerState(from: decoder))
        }
    }

    public var status: RemotePlayerStatus {
        switch self {
        case .redacted(let status): status
        case .visible(let state): state.status
        }
    }

    public var state: RemotePlayerState? {
        if case .visible(let state) = self { return state }
        return nil
    }
}

/// A device of the household as the live channel shows it.
public struct ShownDevice: Decodable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var platform: DevicePlatform
    public var isSelf: Bool
    /// It belongs to a kids viewer: only that viewer and that viewer's titles play there.
    public var isKids: Bool
    /// Lobby is open on it. A target that is off is listed too, with false.
    public var online: Bool
    public var foreground: Bool
    /// A title can be started on it now.
    public var canPlay: Bool
    /// What plays on it can be paused, moved and so on now.
    public var controllable: Bool
    /// The commands it can do. Offer no others.
    public var capabilities: [String]
    public var player: ShownPlayer?
    /// Lobby Server can turn it on and open Lobby on it (`POST /v1/remote/wake`).
    public var wakeable: Bool

    public init(
        id: String, name: String, platform: DevicePlatform, isSelf: Bool = false, isKids: Bool = false,
        online: Bool, foreground: Bool = true, canPlay: Bool, controllable: Bool = false,
        capabilities: [String] = [], player: ShownPlayer? = nil, wakeable: Bool = false
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.isSelf = isSelf
        self.isKids = isKids
        self.online = online
        self.foreground = foreground
        self.canPlay = canPlay
        self.controllable = controllable
        self.capabilities = capabilities
        self.player = player
        self.wakeable = wakeable
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, platform, isSelf, isKids, online, foreground, canPlay, controllable, capabilities, player, wakeable
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        platform = try c.decode(DevicePlatform.self, forKey: .platform)
        isSelf = try c.decodeIfPresent(Bool.self, forKey: .isSelf) ?? false
        isKids = try c.decodeIfPresent(Bool.self, forKey: .isKids) ?? false
        online = try c.decodeIfPresent(Bool.self, forKey: .online) ?? false
        foreground = try c.decodeIfPresent(Bool.self, forKey: .foreground) ?? false
        canPlay = try c.decodeIfPresent(Bool.self, forKey: .canPlay) ?? false
        controllable = try c.decodeIfPresent(Bool.self, forKey: .controllable) ?? false
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        player = try c.decodeIfPresent(ShownPlayer.self, forKey: .player)
        wakeable = try c.decodeIfPresent(Bool.self, forKey: .wakeable) ?? false
    }

    public func can(_ command: String) -> Bool { capabilities.contains(command) }
}

// MARK: What this device says

/// What this device plays, as it announces it. Its own clock is never sent: `ageMs` is how long
/// ago `positionMs` was measured.
public struct PlayerReport: Codable, Hashable, Sendable {
    public var itemId: String?
    public var assetId: String?
    public var profileId: String?
    public var status: RemotePlayerStatus
    public var positionMs: Int
    public var ageMs: Int
    public var durationMs: Int?
    public var rate: Double
    public var audioTracks: [RemoteTrack]
    public var audioTrackId: String?
    public var subtitleTracks: [RemoteTrack]
    public var subtitleTrackId: String?
    public var volume: Double?
    public var nextItemId: String?
    public var queue: [String]
    /// What the player shows at the end. nil: nothing.
    public var upNext: RemoteUpNext?

    public init(
        itemId: String?, assetId: String?, profileId: String?, status: RemotePlayerStatus, positionMs: Int,
        ageMs: Int = 0, durationMs: Int?, rate: Double, audioTracks: [RemoteTrack] = [], audioTrackId: String? = nil,
        subtitleTracks: [RemoteTrack] = [], subtitleTrackId: String? = nil, volume: Double? = nil,
        nextItemId: String? = nil, queue: [String] = [], upNext: RemoteUpNext? = nil
    ) {
        self.itemId = itemId
        self.assetId = assetId
        self.profileId = profileId
        self.status = status
        self.positionMs = positionMs
        self.ageMs = ageMs
        self.durationMs = durationMs
        self.rate = rate
        self.audioTracks = audioTracks
        self.audioTrackId = audioTrackId
        self.subtitleTracks = subtitleTracks
        self.subtitleTrackId = subtitleTrackId
        self.volume = volume
        self.nextItemId = nextItemId
        self.queue = queue
        self.upNext = upNext
    }

    /// The same, apart from the place: what makes another announcement worth sending. A
    /// countdown that runs down by itself is like a film that plays: only its start is news.
    public func sameApartFromPlace(as other: PlayerReport) -> Bool {
        var a = self, b = other
        a.positionMs = 0
        a.ageMs = 0
        b.positionMs = 0
        b.ageMs = 0
        if a.upNext?.countdownMs != nil, b.upNext?.countdownMs != nil {
            a.upNext?.countdownMs = 0
            b.upNext?.countdownMs = 0
        }
        return a == b
    }

    /// Where it will be `laterMs` after it was measured, if it plays on as it does.
    public func expectedPositionMs(afterMs laterMs: Int) -> Int {
        guard status == .playing else { return positionMs }
        var position = positionMs + Int((Double(laterMs) * rate).rounded())
        if let durationMs { position = min(position, durationMs) }
        return position
    }
}

/// `POST /v1/live/{session}`.
public struct Announcement: Encodable, Hashable, Sendable {
    public enum PlayerField: Hashable, Sendable {
        /// Left out: as it was.
        case unchanged
        /// Nothing plays.
        case nothing
        case playing(PlayerReport)
    }

    public var order: Int
    public var foreground: Bool
    public var canPlay: Bool
    public var profileId: String?
    public var capabilities: [String]
    public var player: PlayerField

    public init(order: Int, foreground: Bool, canPlay: Bool, profileId: String?, capabilities: [String], player: PlayerField) {
        self.order = order
        self.foreground = foreground
        self.canPlay = canPlay
        self.profileId = profileId
        self.capabilities = capabilities
        self.player = player
    }

    private enum CodingKeys: String, CodingKey { case order, foreground, canPlay, profileId, capabilities, player }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(order, forKey: .order)
        try c.encode(foreground, forKey: .foreground)
        try c.encode(canPlay, forKey: .canPlay)
        try c.encode(profileId, forKey: .profileId)
        try c.encode(capabilities, forKey: .capabilities)
        switch player {
        case .unchanged: break
        case .nothing: try c.encodeNil(forKey: .player)
        case .playing(let report): try c.encode(report, forKey: .player)
        }
    }
}

/// The answer to an announcement: the server's clock, to work out where another device is now.
public struct AnnounceReply: Codable, Hashable, Sendable {
    public var serverTime: Int64
    public var epoch: String?
    public var seq: Int?
}

// MARK: Commands

/// `play`: a film, episode, extra or home video, as a viewer.
public struct PlayCommand: Codable, Hashable, Sendable {
    public var itemId: String
    /// nil: the device's own choice.
    public var assetId: String?
    public var profileId: String
    /// nil: where this viewer was. 0: from the start.
    public var startMs: Int?
    public var paused: Bool
    public var rate: Double
    /// nil: the device's own choice.
    public var audioTrackId: String?
    /// nil: the device's own choice. `PlayCommand.subtitlesOff`: none.
    public var subtitleTrackId: String?
    public var queue: [String]

    public static let subtitlesOff = "off"

    public init(
        itemId: String, assetId: String? = nil, profileId: String, startMs: Int?, paused: Bool = false, rate: Double = 1,
        audioTrackId: String? = nil, subtitleTrackId: String? = nil, queue: [String] = []
    ) {
        self.itemId = itemId
        self.assetId = assetId
        self.profileId = profileId
        self.startMs = startMs
        self.paused = paused
        self.rate = rate
        self.audioTrackId = audioTrackId
        self.subtitleTrackId = subtitleTrackId
        self.queue = queue
    }

    private enum CodingKeys: String, CodingKey {
        case itemId, assetId, profileId, startMs, paused, rate, audioTrackId, subtitleTrackId, queue
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemId = try c.decode(String.self, forKey: .itemId)
        assetId = try c.decodeIfPresent(String.self, forKey: .assetId)
        profileId = try c.decode(String.self, forKey: .profileId)
        startMs = try c.decodeIfPresent(Double.self, forKey: .startMs).map { Int($0) }
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        rate = try c.decodeIfPresent(Double.self, forKey: .rate) ?? 1
        audioTrackId = try c.decodeIfPresent(String.self, forKey: .audioTrackId)
        subtitleTrackId = try c.decodeIfPresent(String.self, forKey: .subtitleTrackId)
        queue = try c.decodeIfPresent([String].self, forKey: .queue) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(itemId, forKey: .itemId)
        try c.encode(assetId, forKey: .assetId)
        try c.encode(profileId, forKey: .profileId)
        try c.encode(startMs, forKey: .startMs)
        try c.encode(paused, forKey: .paused)
        try c.encode(rate, forKey: .rate)
        try c.encode(audioTrackId, forKey: .audioTrackId)
        try c.encode(subtitleTrackId, forKey: .subtitleTrackId)
        try c.encode(queue, forKey: .queue)
    }
}

/// What one device asks another, and what the server asks in a handover (`yield`).
public enum RemoteCommand: Hashable, Sendable, Codable {
    case play(PlayCommand)
    case pause, resume, next, stop
    case seek(positionMs: Int)
    case skip(deltaMs: Int)
    case setAudio(trackId: String)
    /// nil: no subtitles.
    case setSubtitle(trackId: String?)
    case setVolume(Double)
    /// The answer to Up Next or "Still watching?".
    case upNext(RemoteUpNext.Action)
    /// What plays on the device the command is for goes on at `toDeviceId`.
    case handover(toDeviceId: String)
    /// From the server only, first in a handover: pause, write the progress, answer with the player.
    case yield
    /// A command a newer server knows of.
    case unknown(String)

    public var type: String {
        switch self {
        case .play: "play"
        case .pause: "pause"
        case .resume: "resume"
        case .next: "next"
        case .stop: "stop"
        case .seek: "seek"
        case .skip: "skip"
        case .setAudio: "setAudio"
        case .setSubtitle: "setSubtitle"
        case .setVolume: "setVolume"
        case .upNext: "upNext"
        case .handover: "handover"
        case .yield: "yield"
        case .unknown(let type): type
        }
    }

    private enum CodingKeys: String, CodingKey { case type, positionMs, deltaMs, trackId, volume, toDeviceId, action }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "play": self = .play(try PlayCommand(from: decoder))
        case "pause": self = .pause
        case "resume": self = .resume
        case "next": self = .next
        case "stop": self = .stop
        case "yield": self = .yield
        case "seek": self = .seek(positionMs: Int(try c.decode(Double.self, forKey: .positionMs)))
        case "skip": self = .skip(deltaMs: Int(try c.decode(Double.self, forKey: .deltaMs)))
        case "setAudio": self = .setAudio(trackId: try c.decode(String.self, forKey: .trackId))
        case "setSubtitle": self = .setSubtitle(trackId: try c.decodeIfPresent(String.self, forKey: .trackId))
        case "setVolume": self = .setVolume(try c.decode(Double.self, forKey: .volume))
        case "upNext":
            // An answer a newer device knows of: a command this one does not.
            guard let action = try? c.decode(RemoteUpNext.Action.self, forKey: .action) else {
                self = .unknown(type)
                return
            }
            self = .upNext(action)
        case "handover": self = .handover(toDeviceId: try c.decode(String.self, forKey: .toDeviceId))
        default: self = .unknown(type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if case .play(let play) = self {
            try play.encode(to: encoder)
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .seek(let position): try c.encode(position, forKey: .positionMs)
        case .skip(let delta): try c.encode(delta, forKey: .deltaMs)
        case .setAudio(let track): try c.encode(track, forKey: .trackId)
        case .setSubtitle(let track): try c.encode(track, forKey: .trackId)
        case .setVolume(let volume): try c.encode(volume, forKey: .volume)
        case .upNext(let action): try c.encode(action, forKey: .action)
        case .handover(let to): try c.encode(to, forKey: .toDeviceId)
        default: break
        }
    }
}

/// `POST /v1/remote/commands`.
public struct CommandRequest: Encodable, Hashable, Sendable {
    public var id: String
    public var session: String
    public var deviceId: String
    public var command: RemoteCommand

    public init(id: String, session: String, deviceId: String, command: RemoteCommand) {
        self.id = id
        self.session = session
        self.deviceId = deviceId
        self.command = command
    }
}

/// `202` to a command: it went to the device.
public struct CommandReply: Decodable, Hashable, Sendable {
    public var id: String
    public var expiresAt: Int64
    public var serverTime: Int64
}

/// Why the server did not pass a command on. The reasons are a fixed list.
public struct RemoteRefusal: Error, Hashable, Sendable {
    public var status: Int
    public var code: String?
    public var reason: String?
    public var message: String

    public init(status: Int, code: String?, reason: String?, message: String) {
        self.status = status
        self.code = code
        self.reason = reason
        self.message = message
    }

    /// Lobby is not open there. Nothing is kept for later.
    public var isDeviceOffline: Bool { reason == "device_offline" }
    /// The channel of this device is not known: open it and announce.
    public var needsChannel: Bool { status == 410 && reason == "session" }
}

/// A command for this device, from the channel.
public struct IncomingCommand: Decodable, Hashable, Sendable {
    public struct From: Decodable, Hashable, Sendable {
        public var deviceId: String
        public var name: String
    }

    public var commandId: String
    public var requestId: String?
    public var handoverId: String?
    public var from: From?
    public var command: RemoteCommand
    public var expiresInMs: Int
    public var serverTime: Int64

    private enum CodingKeys: String, CodingKey { case commandId, requestId, handoverId, from, command, expiresInMs, serverTime }

    public init(
        commandId: String, requestId: String? = nil, handoverId: String? = nil, from: From? = nil,
        command: RemoteCommand, expiresInMs: Int, serverTime: Int64
    ) {
        self.commandId = commandId
        self.requestId = requestId
        self.handoverId = handoverId
        self.from = from
        self.command = command
        self.expiresInMs = expiresInMs
        self.serverTime = serverTime
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        commandId = try c.decode(String.self, forKey: .commandId)
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
        handoverId = try c.decodeIfPresent(String.self, forKey: .handoverId)
        from = try c.decodeIfPresent(From.self, forKey: .from)
        command = try c.decode(RemoteCommand.self, forKey: .command)
        expiresInMs = Int(try c.decodeIfPresent(Double.self, forKey: .expiresInMs) ?? 10_000)
        serverTime = Int64(try c.decodeIfPresent(Double.self, forKey: .serverTime) ?? 0)
    }
}

/// How a command went, said by the device that did it.
public struct CommandOutcome: Encodable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable { case done, failed }

    public var commandId: String
    public var status: Status
    /// Needed with `failed`: one of the fixed reasons (`RemoteFailure`).
    public var code: String?
    public var player: Announcement.PlayerField

    public init(commandId: String, status: Status, code: String? = nil, player: Announcement.PlayerField = .unchanged) {
        self.commandId = commandId
        self.status = status
        self.code = code
        self.player = player
    }

    private enum CodingKeys: String, CodingKey { case commandId, status, code, player }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(commandId, forKey: .commandId)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(code, forKey: .code)
        switch player {
        case .unchanged: break
        case .nothing: try c.encodeNil(forKey: .player)
        case .playing(let report): try c.encode(report, forKey: .player)
        }
    }
}

/// Why a device did not do what it was asked. No free text: it could hold a title.
public enum RemoteFailure {
    public static let notAllowed = "not_allowed"
    public static let notFound = "not_found"
    public static let cannotPlay = "cannot_play"
    public static let nothingPlaying = "nothing_playing"
    public static let unsupported = "unsupported"
    public static let expired = "expired"
    public static let busy = "busy"
    public static let declined = "declined"
    public static let error = "error"
}

/// How a command this device sent went: from the channel.
public struct RemoteResult: Decodable, Hashable, Sendable {
    public enum Status: OpenStringEnum {
        case done, failed, expired, superseded
        case unknown(String)

        public static let knownCases: [Status] = [.done, .failed, .expired, .superseded]

        public var rawValue: String {
            switch self {
            case .done: "done"
            case .failed: "failed"
            case .expired: "expired"
            case .superseded: "superseded"
            case .unknown(let raw): raw
            }
        }
    }

    public var commandId: String
    public var deviceId: String?
    public var status: Status
    public var code: String?
}

/// The first event of every connection of the channel.
public struct LiveHello: Decodable, Hashable, Sendable {
    public var session: String
    public var deviceId: String
    public var resumed: Bool
    public var heartbeatMs: Int
    public var silentMs: Int
    public var serverTime: Int64
    /// A play waits for this device: it was woken for it (docs/decisions.md, "Wake and Play"). Go to it, not to who is watching.
    public var pendingPlay: Bool?
}

/// `play` of `POST /v1/remote/wake`: what the server keeps until Lobby is open on the TV.
public struct HeldPlayRequest: Encodable, Hashable, Sendable {
    /// Made by this device, as a command's; the `result` for it carries it.
    public var id: String
    public var command: PlayCommand

    public init(id: String, command: PlayCommand) {
        self.id = id
        self.command = command
    }

    private enum CodingKeys: String, CodingKey { case id, command }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(RemoteCommand.play(command), forKey: .command)
    }
}

/// The answer to `POST /v1/remote/wake`.
public struct WakeReply: Decodable, Hashable, Sendable {
    public struct Held: Decodable, Hashable, Sendable {
        public var id: String
        /// Server time, in ms: the play is not sent after this.
        public var expiresAt: Int64
    }

    public var deviceId: String
    /// Lobby is in front on the TV, as Lobby Server could tell; nil when it cannot.
    public var lobbyInFront: Bool?
    /// The play the server keeps; nil from a server that keeps none.
    public var play: Held?

    public init(deviceId: String, lobbyInFront: Bool? = nil, play: Held? = nil) {
        self.deviceId = deviceId
        self.lobbyInFront = lobbyInFront
        self.play = play
    }
}

/// `wake` on the channel: how waking a TV for this device goes, after the server answered.
public struct WakeProgress: Decodable, Hashable, Sendable {
    public enum Step: OpenStringEnum {
        /// Lobby did not come up: tvOS probably asks who is watching. Select was pressed on the TV.
        case profile
        /// Lobby did not come up at all; the play still waits.
        case notOpen
        case unknown(String)

        public static let knownCases: [Step] = [.profile, .notOpen]

        public var rawValue: String {
            switch self {
            case .profile: "profile"
            case .notOpen: "not_open"
            case .unknown(let raw): raw
            }
        }
    }

    public var deviceId: String
    public var commandId: String?
    public var step: Step
    public var reason: String?
}
