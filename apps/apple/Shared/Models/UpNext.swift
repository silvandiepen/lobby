// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

// What happens when something ends (docs/playback.md, "When something ends"). The decisions,
// apart from the player: which screen comes, whether it counts down, when "Still watching?" is
// asked, and what is suggested. `PlayerModel` carries them out.

/// What the player shows at the end of a film or episode.
enum UpNextScreen: Hashable, Sendable {
    /// The next episode: a card with Play Now and Cancel.
    case nextEpisode
    /// What goes with the film, or with a series that is over: big artwork, pick one.
    case suggestions
    /// "Still watching?": the player waits for Continue Watching or Stop.
    case stillWatching
}

/// What to do at the end, decided from the viewer's preferences.
enum UpNextPlan: Hashable, Sendable {
    /// Nothing to show: the player closes.
    case close
    /// Show `screen`. With `countdownSeconds`, what comes next starts by itself after it; nil:
    /// it waits for the viewer.
    case show(UpNextScreen, countdownSeconds: Int?)
}

/// Titles that played on by themselves since the viewer last touched anything, and since when.
/// Any touch (play, pause, a jump, a choice, a command from a remote) starts it again.
struct WatchStreak: Hashable, Sendable {
    /// Films or episodes that ended since the last touch.
    private(set) var ended = 0
    private(set) var lastTouch: Date

    init(now: Date) {
        lastTouch = now
    }

    mutating func touched(at now: Date) {
        ended = 0
        lastTouch = now
    }

    mutating func itemEnded() {
        ended += 1
    }

    /// Whether to ask before anything else starts by itself.
    func asksStillWatching(_ preferences: PlaybackPreferences, now: Date) -> Bool {
        if preferences.stillWatchingEpisodes > 0, ended >= preferences.stillWatchingEpisodes { return true }
        if preferences.stillWatchingHours > 0,
            now.timeIntervalSince(lastTouch) >= TimeInterval(preferences.stillWatchingHours) * 3600
        {
            return true
        }
        return false
    }
}

enum UpNextPlanner {
    /// What comes at the end of a title.
    ///
    /// - Parameters:
    ///   - hasNextEpisode: An episode follows this one, in this season or the next.
    ///   - hasSuggestions: There is something to suggest (after a film, or a series' last episode).
    ///   - streak: Counted with this title's end already in it.
    static func plan(
        hasNextEpisode: Bool, hasSuggestions: Bool, preferences: PlaybackPreferences, streak: WatchStreak, now: Date
    ) -> UpNextPlan {
        let countdown = preferences.countdownSeconds > 0 ? preferences.countdownSeconds : nil
        if hasNextEpisode {
            let automatic = preferences.episodeAutoplay ? countdown : nil
            if automatic != nil, streak.asksStillWatching(preferences, now: now) {
                return .show(.stillWatching, countdownSeconds: nil)
            }
            return .show(.nextEpisode, countdownSeconds: automatic)
        }
        guard preferences.filmSuggestions, hasSuggestions else { return .close }
        let automatic = preferences.filmAutoplay ? countdown : nil
        if automatic != nil, streak.asksStillWatching(preferences, now: now) {
            return .show(.stillWatching, countdownSeconds: nil)
        }
        return .show(.suggestions, countdownSeconds: automatic)
    }

    /// Up Next at an episode's credits, while it still plays: the card and its countdown, or nil
    /// to wait for the end. Only where the credits are known (`creditsStartMs`, nil when the
    /// viewer turned Next Episode at the credits off) and the viewer wants it there.
    /// "Still watching?" is never asked over the credits: that waits for the end.
    ///
    /// - Parameter streak: Without this episode's end: it is counted here.
    static func atCredits(
        positionMs: Int, creditsStartMs: Int?, preferences: PlaybackPreferences, streak: WatchStreak, now: Date
    ) -> UpNextPlan? {
        guard preferences.startAtCredits, let creditsStartMs, positionMs >= creditsStartMs else { return nil }
        var counted = streak
        counted.itemEnded()
        let plan = plan(hasNextEpisode: true, hasSuggestions: false, preferences: preferences, streak: counted, now: now)
        guard case .show(.nextEpisode, _) = plan else { return nil }
        return plan
    }
}

/// Seconds left until what comes next starts by itself.
struct UpNextCountdown: Hashable, Sendable {
    let total: Int
    private(set) var remaining: Int

    init(seconds: Int) {
        total = max(1, seconds)
        remaining = total
    }

    /// One second went by. True once it is over.
    @discardableResult
    mutating func tick() -> Bool {
        remaining = max(0, remaining - 1)
        return remaining == 0
    }

    var isOver: Bool { remaining == 0 }
    /// 0 at the start, 1 at the end: for a ring that fills.
    var fraction: Double { Double(total - remaining) / Double(total) }
}

/// One title the end screen suggests, ready to play.
struct UpNextSuggestion: Hashable, Sendable, Identifiable {
    /// The film or series shown.
    var id: String
    var title: String
    /// "Continue · S1 E3", "2019".
    var line: String?
    var artwork: Artwork?
    /// What plays when it is picked: the film, or the series' episode to watch.
    var request: PlayRequest
}

enum UpNextSuggestions {
    /// As many as the screen shows.
    static let limit = 12
    /// What goes with the title comes first; then what the viewer was watching, so that it is
    /// at hand; then the rest of what goes with it.
    static let relatedFirst = 6
    static let continuingAtMost = 4

    /// The suggestions after `source` (the film, or the series of the episode that ended).
    ///
    /// - Parameters:
    ///   - related: What goes with it, the closest first (`RelatedTitles`), of what the viewer may see.
    ///   - continuing: Continue Watching, the most recent first.
    ///   - request: What plays for a title; nil when it cannot play here now.
    static func make(
        after source: Item, related: [Item], continuing: [UpNextSuggestion], request: (Item) -> PlayRequest?
    ) -> [UpNextSuggestion] {
        var seen: Set<String> = [source.id]
        var picked: [UpNextSuggestion] = []
        var related = related.makeIterator()

        func takeRelated(upTo count: Int) {
            while picked.count < count, let item = related.next() {
                guard !seen.contains(item.id), let request = request(item) else { continue }
                seen.insert(item.id)
                picked.append(UpNextSuggestion(
                    id: item.id, title: item.title, line: item.year.map(String.init),
                    artwork: item.artwork.backdrop ?? item.artwork.poster, request: request))
            }
        }

        takeRelated(upTo: relatedFirst)
        var added = 0
        for one in continuing where added < continuingAtMost && picked.count < limit {
            guard !seen.contains(one.id) else { continue }
            seen.insert(one.id)
            picked.append(one)
            added += 1
        }
        takeRelated(upTo: limit)
        return picked
    }

    /// What plays for a suggested title: a film from where the viewer was (or the start), a
    /// series from the episode Continue Watching names, else its first episode.
    static func request(
        for item: Item, catalogue: Catalogue, progress: [String: PlaybackProgress], context: PlaybackContext
    ) -> PlayRequest? {
        guard item.kind == .show else {
            return PlayActionBuilder.action(for: item, progress: progress[item.id], context: context).request
        }
        let continuing = Shelves.continueWatching(in: catalogue, progress: progress).first { $0.show?.id == item.id }
        let episode = continuing?.item ?? EpisodeOrder.episodes(ofShow: item.id, in: catalogue).first
        guard let episode else { return nil }
        return PlayActionBuilder.action(for: episode, show: item, progress: progress[episode.id], context: context).request
    }

    /// A Continue Watching card as a suggestion.
    static func suggestion(from card: ContinueCard, catalogue: Catalogue) -> UpNextSuggestion? {
        guard let request = card.action.request else { return nil }
        let title = catalogue.item(card.detailItemID)
        return UpNextSuggestion(
            id: card.detailItemID, title: card.title, line: "Continue · \(card.line)",
            artwork: title?.artwork.backdrop ?? card.artwork ?? title?.artwork.poster, request: request)
    }
}

/// The words of the playback settings, on every platform.
enum PlaybackWords {
    static func countdown(_ seconds: Int) -> String {
        seconds == 0 ? "Off" : "\(seconds) seconds"
    }

    static func episodes(_ count: Int) -> String {
        count == 0 ? "Never" : "\(count) episodes"
    }

    static func hours(_ hours: Int) -> String {
        switch hours {
        case 0: "Never"
        case 1: "1 hour"
        default: "\(hours) hours"
        }
    }

    /// "Next episode after 10 s · asks after 3", for a row that opens the settings.
    static func summary(_ preferences: PlaybackPreferences) -> String {
        let next = preferences.episodeAutoplay && preferences.countdownSeconds > 0 ? "Autoplay" : "Up Next waits"
        let ask = preferences.stillWatchingEpisodes > 0 ? "asks after \(preferences.stillWatchingEpisodes)" : nil
        return [next, ask].compactMap { $0 }.joined(separator: " · ")
    }
}
