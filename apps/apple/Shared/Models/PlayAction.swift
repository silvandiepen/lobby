// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// What the player needs to start one film or episode.
struct PlayRequest: Hashable, Sendable, Identifiable {
    enum Source: Hashable, Sendable {
        /// The file as it is on the drive.
        case direct
        /// A copy the server repackages first (MKV, DTS sound).
        case prepared
        /// The copy on this device. Needs no server.
        case local
    }

    var item: Item
    /// The episode's show, for the player's title.
    var show: Item?
    var file: MediaFile
    var source: Source
    /// Where playback starts, within the film or episode.
    var startPositionMs: Int
    var durationMs: Int?

    var id: String { item.id }

    /// "Wild Isles" for an episode of it, the film's own title otherwise.
    var title: String { show?.title ?? item.title }

    /// "S1 E2 · Coastal Worlds" for an episode, nil for a film.
    var subtitle: String? {
        guard item.kind == .episode else { return nil }
        return ItemText.episodeLine(item, show: show)
    }
}

/// What the primary button of a film or episode does, or why there is none.
enum PlayAction: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case play
        case resume(positionMs: Int)
        case playAgain
    }

    /// - Parameter note: A sentence shown under the button, e.g. that the server repackages
    ///   this file first.
    case play(PlayRequest, kind: Kind, note: String?)
    case unavailable(headline: String, explanation: String)

    var request: PlayRequest? {
        if case .play(let request, _, _) = self { return request }
        return nil
    }

    var isPlayable: Bool { request != nil }

    /// The same film or episode from its first second: offered where the button would resume.
    var fromBeginning: PlayRequest? {
        guard case .play(var request, .resume, _) = self else { return nil }
        request.startPositionMs = 0
        return request
    }
}

extension PlayAction.Kind {
    /// What the primary button says.
    var words: String {
        switch self {
        case .play: "Play"
        case .resume: "Resume"
        case .playAgain: "Play Again"
        }
    }
}

/// What decides whether a file can be played here.
struct PlaybackContext: Hashable, Sendable {
    var capabilities: DeviceCapabilities
    /// The copies on this device that can be played: the asset id by item id, and whether the
    /// copy is older than what the server has now.
    var localCopies: [String: LocalCopyInfo] = [:]
    /// The server answers at none of its addresses: only a copy on this device can play.
    var serverIsOutOfReach = false
    /// False on the Apple TV, which keeps nothing: words about downloads mean nothing there.
    var keepsDownloads = true
    /// A server admin's device: the note under Play says why a file is repackaged first. Others
    /// learn it in the player, where it matters, if the wait is long enough to notice.
    var explainsPreparation = false

    struct LocalCopyInfo: Hashable, Sendable {
        var assetID: String
        var isOutOfDate: Bool
    }
}

enum PlayActionBuilder {
    /// The action for a film, an episode or a personal video.
    static func action(
        for item: Item, show: Item? = nil, progress: PlaybackProgress?, context: PlaybackContext
    ) -> PlayAction {
        let candidates = item.mainFiles

        // A copy on this device plays whatever the server says about the file right now, and
        // whether or not the server can be reached.
        if let local = context.localCopies[item.id] {
            let file = item.files.first { $0.assetId == local.assetID } ?? candidates.first
            if let file {
                let duration = item.playbackDurationMs(of: file)
                let start = PlaybackPolicy.resumePosition(for: progress, durationMs: duration)
                return .play(
                    PlayRequest(item: item, show: show, file: file, source: .local, startPositionMs: start, durationMs: duration),
                    kind: kind(start: start, progress: progress),
                    note: local.isOutOfDate
                        ? "This plays the copy on this device, which is older than the file on Lobby Server."
                        : nil)
            }
        }

        // Without the server only a copy on this device can play.
        if context.serverIsOutOfReach, !context.keepsDownloads {
            return .unavailable(
                headline: "Lobby Server cannot be reached",
                explanation: "Lobby keeps looking for it. Check that this device is online, and away from home that Tailscale is connected.")
        }
        if context.serverIsOutOfReach {
            return .unavailable(
                headline: "Not on this device",
                explanation: "Lobby Server is out of reach, and this was not downloaded to this device. It plays again when the server is back.")
        }

        guard !candidates.isEmpty else {
            return .unavailable(
                headline: "No video file",
                explanation: "Lobby Server has no video file for this.")
        }

        // An item can have more than one file (two editions, or a second copy in another
        // format). Take the first one this device can play.
        let decisions = candidates.map { ($0, PlaybackPlanner.decide(for: $0, capabilities: context.capabilities)) }
        let playable = decisions.first { _, decision in
            switch decision {
            case .direct, .needsPreparedPlayback: true
            case .notPlayable: false
            }
        }

        guard let (file, decision) = playable else {
            return unavailable(file: decisions[0].0, decision: decisions[0].1)
        }

        let duration = item.playbackDurationMs(of: file)
        let start = PlaybackPolicy.resumePosition(for: progress, durationMs: duration)
        let request = PlayRequest(
            item: item, show: show, file: file, source: decision == .direct ? .direct : .prepared,
            startPositionMs: start, durationMs: duration)
        let note = decision == .direct || !context.explainsPreparation ? nil : preparationNote(file)
        return .play(request, kind: kind(start: start, progress: progress), note: note)
    }

    private static func kind(start: Int, progress: PlaybackProgress?) -> PlayAction.Kind {
        if start > 0 { return .resume(positionMs: start) }
        return progress?.completed == true ? .playAgain : .play
    }

    /// The file a download fetches: the one Play would use from the server. nil when nothing
    /// of this item can be played on this device.
    static func fileToDownload(for item: Item, capabilities: DeviceCapabilities) -> MediaFile? {
        item.mainFiles.first { file in
            switch PlaybackPlanner.decide(for: file, capabilities: capabilities) {
            case .direct, .needsPreparedPlayback: true
            case .notPlayable: false
            }
        }
    }

    private static func preparationNote(_ file: MediaFile) -> String {
        if file.convertible == true {
            return "An older format: Lobby Server converts it the first time it is played."
        }
        let reason = file.playabilityReason.map { "\($0) " } ?? ""
        return "\(reason)Lobby Server does that once, when it is first played."
    }

    private static func unavailable(file: MediaFile, decision: PlaybackDecision) -> PlayAction {
        switch decision {
        case .direct, .needsPreparedPlayback:
            preconditionFailure("A file that plays, directly or after repackaging, is never unavailable.")
        case .notPlayable(.unavailable):
            return .unavailable(
                headline: "Not available right now",
                explanation: "The drive this is on is not connected to Lobby Server.")
        case .notPlayable(.needsTranscode(let message)):
            return .unavailable(
                headline: "Can't play on Apple devices yet",
                explanation: message ?? formatSentence(file, "has to be converted first, which Lobby Server cannot do."))
        case .notPlayable(.unsupported(let message)):
            return .unavailable(
                headline: "Can't be played",
                explanation: message ?? formatSentence(file, "is not something Lobby can play."))
        case .notPlayable(.unknownPlayability(_, let message)):
            return .unavailable(
                headline: "Needs a newer Lobby",
                explanation: message ?? "This file needs a newer version of the Lobby app.")
        }
    }

    /// Names the format, so the owner knows what to look for: "MPEG4 video in AVI has to be …".
    private static func formatSentence(_ file: MediaFile, _ rest: String) -> String {
        let codec = file.video.map { "\($0.codec.uppercased()) video" } ?? "This file"
        return "\(codec) in \(file.container.uppercased()) \(rest)"
    }
}

extension Item {
    /// How long the film or episode is when played from `file`.
    ///
    /// For a file that holds several episodes with known boundaries, that is this episode's
    /// part of it.
    func playbackDurationMs(of file: MediaFile) -> Int? {
        if let start = file.startMs, let end = file.endMs, end > start { return end - start }
        return file.durationMs ?? runtimeMs
    }

    /// The running time to show: the matched runtime, or the file's own length.
    var displayDurationMs: Int? {
        runtimeMs ?? mainFiles.first.flatMap { playbackDurationMs(of: $0) }
    }
}

/// How items are named in lists and cards.
enum ItemText {
    /// The episode's own title, or nil when the file name gave it none: the catalogue then
    /// holds the show's title, or "Episode 2", which the number already says.
    static func ownTitle(of episode: Item, show: Item?) -> String? {
        let title = episode.title.trimmingCharacters(in: .whitespaces)
        if title.isEmpty { return nil }
        if let show, title.caseInsensitiveCompare(show.title) == .orderedSame { return nil }
        if let number = episode.episodeNumber, title.caseInsensitiveCompare("Episode \(number)") == .orderedSame {
            return nil
        }
        return title
    }

    /// "2. Coastal Worlds", or "Episode 2" when the episode has no title of its own.
    static func episodeTitle(_ episode: Item, show: Item?) -> String {
        switch (episode.episodeNumber, ownTitle(of: episode, show: show)) {
        case (let number?, let title?): "\(number). \(title)"
        case (let number?, nil): "Episode \(number)"
        case (nil, let title?): title
        case (nil, nil): "Episode"
        }
    }

    /// "S1 E2 · Coastal Worlds", "S1 E2", or just the title.
    static func episodeLine(_ episode: Item, show: Item? = nil) -> String {
        let code = MediaFormat.episodeCode(season: episode.seasonNumber, episode: episode.episodeNumber)
        let parts = [code, ownTitle(of: episode, show: show)].compactMap { $0 }
        return parts.isEmpty ? episode.title : parts.joined(separator: " · ")
    }
}
