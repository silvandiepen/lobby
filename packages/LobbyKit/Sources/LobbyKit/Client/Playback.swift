// SPDX-License-Identifier: MPL-2.0
import Foundation

// `POST /v1/assets/{assetId}/playback` and the subtitle route, as `docs/api.md` describes them.
// What the apps must do with the answer is in `docs/playback.md`.

public enum PlaybackState: OpenStringEnum {
    /// The URLs can be used: the original file, or a complete repackaged copy.
    case ready
    /// A copy is being written. Playable as soon as `streamURL` is set, up to `preparedMs`.
    case preparing
    /// Waiting for another file to finish.
    case queued
    /// ffmpeg could not read the file, or the cache has no room. Asking again tries again.
    case failed
    /// The picture needs re-encoding, or there is none.
    case unsupported
    case unknown(String)

    public static let knownCases: [PlaybackState] = [.ready, .preparing, .queued, .failed, .unsupported]

    public var rawValue: String {
        switch self {
        case .ready: "ready"
        case .preparing: "preparing"
        case .queued: "queued"
        case .failed: "failed"
        case .unsupported: "unsupported"
        case .unknown(let raw): raw
        }
    }
}

public enum PlaybackMode: OpenStringEnum {
    /// The URLs are the original file.
    case direct
    /// The URLs are a repackaged copy.
    case prepared
    case unknown(String)

    public static let knownCases: [PlaybackMode] = [.direct, .prepared]

    public var rawValue: String {
        switch self {
        case .direct: "direct"
        case .prepared: "prepared"
        case .unknown(let raw): raw
        }
    }
}

/// One sound track of what is played. In a prepared copy the default track comes first.
public struct PlaybackAudio: Codable, Hashable, Sendable {
    /// `AudioTrack.index` of the original track.
    public var index: Int
    /// The codec as played: the original's, or "aac" when it was converted.
    public var codec: String
    public var converted: Bool
    public var language: String?
    public var title: String?
    public var channels: Int?
    public var isDefault: Bool

    public init(
        index: Int, codec: String, converted: Bool, language: String?, title: String?, channels: Int?,
        isDefault: Bool
    ) {
        self.index = index
        self.codec = codec
        self.converted = converted
        self.language = language
        self.title = title
        self.channels = channels
        self.isDefault = isDefault
    }
}

/// The answer of `POST /v1/assets/{assetId}/playback`: how to play or download one file now.
public struct Playback: Hashable, Sendable {
    public var state: PlaybackState
    /// nil when `state` is `.unsupported`.
    public var mode: PlaybackMode?
    /// The file revision the URLs belong to. Store it with a download.
    public var revision: String
    /// 0…1.
    public var progress: Double
    /// How far into the film the stream reaches already. A seek beyond it has to wait.
    public var preparedMs: Int
    public var durationMs: Int?
    /// What AVPlayer plays. nil until there is enough to start (a few seconds).
    public var streamURL: URL?
    /// One MP4 file to download for offline use. nil until `state` is `.ready`. Never stream it.
    public var downloadURL: URL?
    /// The exact length of `downloadURL`. Check the finished download against it.
    public var downloadBytes: Int64?
    public var audio: [PlaybackAudio]
    /// True when the picture is converted to H.264 (old AVI films). That takes minutes, not
    /// seconds.
    public var videoConverted: Bool
    /// While `state` is `.preparing`: how fast the copy is written, as a multiple of playback
    /// speed (4 = four minutes of film per minute). nil otherwise, and before the first segment.
    public var speed: Double?
    /// A sentence for the viewer when `state` is `.failed` or `.unsupported`.
    public var message: String?

    public init(
        state: PlaybackState, mode: PlaybackMode?, revision: String, progress: Double, preparedMs: Int,
        durationMs: Int?, streamURL: URL?, downloadURL: URL?, downloadBytes: Int64?, audio: [PlaybackAudio] = [],
        videoConverted: Bool = false, speed: Double? = nil, message: String? = nil
    ) {
        self.state = state
        self.mode = mode
        self.revision = revision
        self.progress = progress
        self.preparedMs = preparedMs
        self.durationMs = durationMs
        self.streamURL = streamURL
        self.downloadURL = downloadURL
        self.downloadBytes = downloadBytes
        self.audio = audio
        self.videoConverted = videoConverted
        self.speed = speed
        self.message = message
    }

    /// How long until the copy is complete, from `speed`. nil when the server does not say how
    /// fast it is going, or the length of the film is unknown.
    public var estimatedTimeLeft: Duration? {
        guard state == .preparing, let speed, speed > 0, let durationMs, durationMs > preparedMs else { return nil }
        return .milliseconds(Int((Double(durationMs - preparedMs) / speed).rounded()))
    }

    /// The stream reaches `positionMs`: playback can start or resume there now.
    ///
    /// Always true for the original file and for a complete copy. While a copy is being
    /// written it is true up to `preparedMs`.
    public func canStart(atMs positionMs: Int) -> Bool {
        guard streamURL != nil else { return false }
        if state == .ready { return true }
        return state == .preparing && positionMs <= preparedMs
    }
}

extension LobbyClient {
    /// `POST /v1/assets/{assetId}/playback`: asks how to play or download a file.
    ///
    /// Ask for every file, direct or not, and use the URLs that come back. For a file that
    /// needs repackaging the first call starts the work and every later call reports on it:
    /// call again, about once a second, until `streamURL` is set (and, to resume, until
    /// `canStart(atMs:)`). A prepared copy can be evicted at any time. Its URLs then answer
    /// 404: ask again.
    ///
    /// The URLs carry no credential. For AVPlayer pass `deviceCookie()`, for `URLSession` use
    /// `authorizedRequest(for:)`.
    public func playback(assetID: String) async throws -> Playback {
        struct Answer: Decodable {
            var state: PlaybackState
            var mode: PlaybackMode?
            var revision: String
            var progress: Double
            var preparedMs: Int
            var durationMs: Int?
            var streamUrl: String?
            var downloadUrl: String?
            var downloadBytes: Int64?
            var audio: [PlaybackAudio]
            // Added with the conversion of old AVI films. A server from before that sends neither.
            var videoConverted: Bool?
            var speed: Double?
            var message: String?
        }
        let answer: Answer = try await send("POST", ["assets", assetID, "playback"])
        return Playback(
            state: answer.state,
            mode: answer.mode,
            revision: answer.revision,
            progress: answer.progress,
            preparedMs: answer.preparedMs,
            durationMs: answer.durationMs,
            streamURL: answer.streamUrl.flatMap(resolve(serverPath:)),
            downloadURL: answer.downloadUrl.flatMap(resolve(serverPath:)),
            downloadBytes: answer.downloadBytes,
            audio: answer.audio,
            videoConverted: answer.videoConverted ?? false,
            speed: answer.speed,
            message: answer.message
        )
    }

    /// `GET /v1/assets/{assetId}/subtitles/{subtitleId}.vtt`: a text subtitle as WebVTT, for
    /// any asset, also one that plays directly. Only for a track whose `isText` is true.
    public func subtitleURL(assetID: String, subtitle: SubtitleTrack) -> URL {
        url(["assets", assetID, "subtitles", subtitle.id + ".vtt"])
    }

    /// Fetches a text subtitle as WebVTT, for an app that draws the cues itself: a file that
    /// plays directly has no playlist to list its subtitles, and a stream that started while
    /// its copy was being written lists only some.
    ///
    /// For an embedded track of a file that was never prepared, the first request makes the
    /// server read the whole video file (about 20 s per 2 GB on the Pi).
    public func subtitle(assetID: String, subtitle: SubtitleTrack) async throws -> String {
        let data = try await data(at: subtitleURL(assetID: assetID, subtitle: subtitle))
        guard let text = String(data: data, encoding: .utf8) else {
            throw LobbyError.invalidResponse("The subtitle is not UTF-8 text.")
        }
        return text
    }

    /// Fetches a subtitle stored as pictures, each cue a placed PNG. The first request reads the
    /// whole file for it, which can take a while.
    public func pictureSubtitles(assetID: String, subtitle: SubtitleTrack) async throws -> PictureSubtitles {
        let data = try await data(at: url(["assets", assetID, "subtitles", subtitle.id + ".json"]))
        do {
            return try LobbyJSON.decoder().decode(PictureSubtitles.self, from: data)
        } catch {
            throw LobbyError.invalidResponse("The picture subtitles could not be read.")
        }
    }
}
