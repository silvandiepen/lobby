// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// Where a viewer is in a story, as its page and its tile say it: Play, Resume or Play again,
/// how far, and how long is left.
struct StoryPlace: Equatable {
    enum Start: Equatable {
        case play, resume, again
    }

    var start: Start
    /// 0…1 of a story that was begun and not finished.
    var fraction: Double?
    /// What is left of it, once begun.
    var leftMs: Int?

    /// - Parameter playingMs: Where the player is, when it plays this story now.
    init(book: MusicBook, progress: PlaybackProgress?, playingMs: Int? = nil) {
        let position = playingMs ?? progress.map { $0.completed ? 0 : $0.positionMs } ?? 0
        if position > 0, book.durationMs > 0 {
            start = .resume
            fraction = min(1, Double(position) / Double(book.durationMs))
            leftMs = max(0, book.durationMs - position)
        } else {
            start = progress?.completed == true ? .again : .play
            fraction = nil
            leftMs = nil
        }
    }

    var label: String {
        switch start {
        case .play: "Play"
        case .resume: "Resume"
        case .again: "Play again"
        }
    }
}

/// When the kids' player stops by itself: few choices, in a child's words.
enum KidsSleep: Hashable, CaseIterable {
    case endOfStory, minutes15, minutes30, off

    var minutes: Int? {
        switch self {
        case .minutes15: 15
        case .minutes30: 30
        case .endOfStory, .off: nil
        }
    }

    /// - Parameter chapters: The story has chapters, which is where it stops.
    func title(isStory: Bool, chapters: Bool) -> String {
        switch self {
        case .endOfStory: isStory ? (chapters ? "When this part ends" : "When the story ends") : "When the song ends"
        case .minutes15: "In 15 minutes"
        case .minutes30: "In 30 minutes"
        case .off: "Keep playing"
        }
    }

    var symbol: String {
        switch self {
        case .endOfStory: "moon.stars.fill"
        case .minutes15, .minutes30: "moon.zzz.fill"
        case .off: "play.circle.fill"
        }
    }
}

extension KidsSection {
    /// The places on a child's bar. Stories are there while the child may listen.
    static func places(listens: Bool) -> [KidsSection] {
        listens ? [.home, .stories, .movies, .series, .onHere] : [.home, .movies, .series, .onHere]
    }
}
