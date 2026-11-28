// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// What the screens do with HomePods and speakers (docs/decisions.md, "Play on a speaker"): which
/// to offer, what each says, what to send when music that plays here goes there, and the words for
/// what went wrong. No view computes any of it.
enum SpeakerTargets {
    /// For grown-ups: those that can play now, then those that play something, by name.
    static func ordered(_ speakers: [ShownSpeaker]) -> [ShownSpeaker] {
        speakers
            .filter { $0.canPlay || $0.play != nil }
            .sorted { a, b in
                if a.canPlay != b.canPlay { return a.canPlay }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    /// For a child: only those that will play, and not one where someone else's music plays.
    static func forKids(_ speakers: [ShownSpeaker]) -> [ShownSpeaker] {
        ordered(speakers).filter { $0.canPlay && $0.access == .open && ($0.play == nil || $0.controllable) }
    }

    /// The one whose remote to show at the foot of the page: what plays there for this device.
    static func playing(_ speakers: [ShownSpeaker]) -> ShownSpeaker? {
        speakers
            .filter { $0.controllable && $0.play?.state != nil && $0.play?.status != .ended }
            .sorted { ($0.play?.status == .playing ? 0 : 1) < ($1.play?.status == .playing ? 0 : 1) }
            .first
    }

    /// What a speaker does, in a few words, under its name in Play On.
    static func state(of speaker: ShownSpeaker, title: (SpeakerPlayState) -> String?) -> String {
        if let play = speaker.play {
            guard let state = play.state else { return "Playing" }
            let what = title(state)
            switch state.status {
            case .playing: return what.map { "Playing \($0)" } ?? "Playing"
            case .paused: return what.map { "Paused: \($0)" } ?? "Paused"
            case .loading, .buffering: return "Starting…"
            default: break
            }
        }
        switch speaker.access {
        case .homeOnly: return "Only for people in its Home"
        case .password: return "Needs its password"
        default: return speaker.canPlay ? "Ready" : "Not found"
        }
    }

    /// Said before trying a speaker that will probably refuse.
    static func accessHint(_ speaker: ShownSpeaker) -> String? {
        switch speaker.access {
        case .homeOnly:
            "\(speaker.name) lets only people in its Home play. In the Home app, open its settings and set Allow Speaker & TV Access to “Everyone on the Same Network”."
        case .password:
            "\(speaker.name) needs a password. A manager can enter it in Server Settings → Speakers."
        default:
            nil
        }
    }

    /// The symbol for a speaker.
    static func symbol(_ speaker: ShownSpeaker) -> String {
        speaker.kind == .homepod ? "homepod.fill" : "hifispeaker.fill"
    }

    /// What goes to the speaker when what plays here goes there: the same tracks from the same one
    /// and the same place; a story from its place on its own line of time.
    static func handover(
        trackIDs: [String], index: Int, elapsedMs: Int, book: MusicBook?, bookPositionMs: Int?, profileID: String
    ) -> SpeakerPlayRequest? {
        if let book {
            return .story(profileID: profileID, bookID: book.id, startMs: bookPositionMs ?? 0)
        }
        guard trackIDs.indices.contains(index) else { return nil }
        // The server takes at most 500: the rest of the queue from the one that plays.
        let from = Array(trackIDs[index...].prefix(500))
        return .music(profileID: profileID, trackIDs: from, index: 0, startMs: max(0, elapsedMs))
    }

    /// Where a story is on its own line of time, from where the speaker is in one of its files.
    static func bookPositionMs(_ state: SpeakerPlayState, book: MusicBook, trackMs: Int) -> Int? {
        book.bookMs(trackID: state.trackId, trackMs: trackMs)
    }

    /// What to tell the person when a speaker would not, or could not. nil when it went.
    static func words(_ outcome: SpeakerOutcome, speaker name: String) -> String? {
        switch outcome {
        case .done: return nil
        case .unreachable: return "Lobby Server could not be reached."
        case .refused(let reason, let message):
            switch reason {
            case "speaker_refused":
                return message ?? "\(name) did not let Lobby Server play. In the Home app, set Allow Speaker & TV Access to “Everyone on the Same Network”."
            case "speaker_not_found": return "\(name) was not found on the network. Is it plugged in?"
            case "speaker_timeout": return "\(name) did not answer in time. Try again."
            case "speaker_busy": return "Something else plays on \(name)."
            case "home_only": return "Speakers can only be played on from home."
            case "kids_mode": return "This is not for now."
            case "title_not_allowed": return "This cannot be played there."
            case "nothing_playing": return "Nothing plays on \(name) any more."
            case "drive_away": return "The drive this music is on is not connected right now."
            default: return message ?? "That did not work on \(name)."
            }
        }
    }

    /// The same for a child, in a few plain words.
    static func kidsWords(_ outcome: SpeakerOutcome, speaker name: String) -> String? {
        switch outcome {
        case .done: return nil
        case .refused(let reason, _) where reason == "speaker_busy": return "Someone else is listening on \(name)."
        case .refused(let reason, _) where reason == "kids_mode": return "It is not time to listen now."
        default: return "That did not work on \(name). Ask a grown-up for help."
        }
    }
}

/// How asking a speaker went.
enum SpeakerOutcome: Hashable, Sendable {
    case done
    /// The server said no: its reason and its words.
    case refused(reason: String?, message: String?)
    case unreachable

    var succeeded: Bool { self == .done }
}
