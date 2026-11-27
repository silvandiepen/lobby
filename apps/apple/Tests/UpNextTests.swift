// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

/// What happens when something ends (docs/playback.md): the screen that comes, the countdown,
/// "Still watching?" and what resets it, the next episode over a season's end, and what is
/// suggested after a film.
struct UpNextTests {
    private let now = Make.epoch
    private let defaults = PlaybackPreferences.defaults

    private func streak(ended: Int, touchedHoursAgo hours: Double = 0) -> WatchStreak {
        var streak = WatchStreak(now: now.addingTimeInterval(-hours * 3600))
        for _ in 0..<ended { streak.itemEnded() }
        return streak
    }

    // MARK: The screen at the end

    @Test func anEpisodeGoesOnToTheNextAfterTheCountdown() {
        let plan = UpNextPlanner.plan(hasNextEpisode: true, hasSuggestions: false, preferences: defaults, streak: streak(ended: 1), now: now)
        #expect(plan == .show(.nextEpisode, countdownSeconds: 10))
    }

    @Test func aFilmSuggestsButStartsNothingByItself() {
        let plan = UpNextPlanner.plan(hasNextEpisode: false, hasSuggestions: true, preferences: defaults, streak: streak(ended: 1), now: now)
        #expect(plan == .show(.suggestions, countdownSeconds: nil))
        // Not even after many in a row: nothing would start, so nothing is asked.
        let many = UpNextPlanner.plan(hasNextEpisode: false, hasSuggestions: true, preferences: defaults, streak: streak(ended: 9), now: now)
        #expect(many == .show(.suggestions, countdownSeconds: nil))
    }

    @Test func aFilmWithNothingToSuggestOrSuggestionsOffCloses() {
        #expect(UpNextPlanner.plan(hasNextEpisode: false, hasSuggestions: false, preferences: defaults, streak: streak(ended: 1), now: now) == .close)
        var off = defaults
        off.filmSuggestions = false
        #expect(UpNextPlanner.plan(hasNextEpisode: false, hasSuggestions: true, preferences: off, streak: streak(ended: 1), now: now) == .close)
    }

    @Test func aViewerWhoWantsItGetsTheFirstSuggestionAfterTheCountdown() {
        var autoplay = defaults
        autoplay.filmAutoplay = true
        autoplay.countdownSeconds = 15
        let plan = UpNextPlanner.plan(hasNextEpisode: false, hasSuggestions: true, preferences: autoplay, streak: streak(ended: 1), now: now)
        #expect(plan == .show(.suggestions, countdownSeconds: 15))
    }

    @Test func withoutAutoplayOrWithTheCountdownOffUpNextWaitsForPlayNow() {
        var manual = defaults
        manual.episodeAutoplay = false
        #expect(UpNextPlanner.plan(hasNextEpisode: true, hasSuggestions: false, preferences: manual, streak: streak(ended: 5), now: now)
            == .show(.nextEpisode, countdownSeconds: nil))
        var noCountdown = defaults
        noCountdown.countdownSeconds = 0
        #expect(UpNextPlanner.plan(hasNextEpisode: true, hasSuggestions: false, preferences: noCountdown, streak: streak(ended: 5), now: now)
            == .show(.nextEpisode, countdownSeconds: nil))
    }

    // MARK: Still watching?

    @Test func theThirdEpisodeInARowWithoutATouchAsks() {
        for (ended, asks) in [(1, false), (2, false), (3, true), (4, true)] {
            let plan = UpNextPlanner.plan(hasNextEpisode: true, hasSuggestions: false, preferences: defaults, streak: streak(ended: ended), now: now)
            #expect(plan == (asks ? .show(.stillWatching, countdownSeconds: nil) : .show(.nextEpisode, countdownSeconds: 10)), "after \(ended)")
        }
    }

    @Test func aKidsViewerIsAskedAfterTwo() {
        let kids = PlaybackPreferences.kidsDefaults
        #expect(kids.stillWatchingEpisodes == 2)
        #expect(UpNextPlanner.plan(hasNextEpisode: true, hasSuggestions: false, preferences: kids, streak: streak(ended: 2), now: now)
            == .show(.stillWatching, countdownSeconds: nil))
        #expect(Profile(id: "k", name: "K", color: "red", kids: KidsSettings()).playbackPreferences == kids)
        #expect(Profile(id: "a", name: "A", color: "red").playbackPreferences == .defaults)
    }

    @Test func anyTouchStartsTheCountAgain() {
        var streak = WatchStreak(now: now)
        streak.itemEnded()
        streak.itemEnded()
        #expect(streak.ended == 2)
        streak.touched(at: now.addingTimeInterval(60))
        #expect(streak.ended == 0)
        #expect(streak.lastTouch == now.addingTimeInterval(60))
        // The episode during which the viewer paused counts as the first again.
        streak.itemEnded()
        #expect(!streak.asksStillWatching(defaults, now: now.addingTimeInterval(120)))
    }

    @Test func afterSoManyHoursWithoutATouchItAsksToo() {
        var hours = defaults
        hours.stillWatchingEpisodes = 0
        hours.stillWatchingHours = 2
        #expect(!streak(ended: 1, touchedHoursAgo: 1.9).asksStillWatching(hours, now: now))
        #expect(streak(ended: 1, touchedHoursAgo: 2).asksStillWatching(hours, now: now))
        // Off is off.
        var never = hours
        never.stillWatchingHours = 0
        #expect(!streak(ended: 9, touchedHoursAgo: 9).asksStillWatching(never, now: now))
    }

    // MARK: The countdown

    @Test func upNextComesAtTheCreditsWhereTheyAreKnown() {
        let now = now
        let fresh = streak(ended: 0)
        let at = { (position: Int, credits: Int?, preferences: PlaybackPreferences, streak: WatchStreak) in
            UpNextPlanner.atCredits(
                positionMs: position, creditsStartMs: credits, preferences: preferences, streak: streak, now: now)
        }
        // Not before the credits, and not without them: then it comes at the end.
        #expect(at(1_299_000, 1_300_000, .defaults, fresh) == nil)
        #expect(at(2_000_000, nil, .defaults, fresh) == nil)
        #expect(at(1_300_000, 1_300_000, .defaults, fresh) == .show(.nextEpisode, countdownSeconds: 10))
        var off = PlaybackPreferences.defaults
        off.startAtCredits = false
        #expect(at(1_300_000, 1_300_000, off, fresh) == nil)
        var waits = PlaybackPreferences.defaults
        waits.episodeAutoplay = false
        #expect(at(1_300_000, 1_300_000, waits, fresh) == .show(.nextEpisode, countdownSeconds: nil))
        // The third in a row: "Still watching?" waits for the end, the credits play out.
        #expect(at(1_300_000, 1_300_000, .defaults, streak(ended: 2)) == nil)
        #expect(at(1_300_000, 1_300_000, .defaults, streak(ended: 1)) == .show(.nextEpisode, countdownSeconds: 10))
    }

    @Test func theCountdownRunsDownToItsEnd() {
        var countdown = UpNextCountdown(seconds: 5)
        #expect(countdown.remaining == 5 && countdown.fraction == 0)
        for second in 1...4 {
            let over = countdown.tick()
            #expect(!over, "second \(second)")
        }
        #expect(countdown.remaining == 1)
        let over = countdown.tick()
        #expect(over)
        #expect(countdown.isOver && countdown.fraction == 1)
        // It stays over.
        let still = countdown.tick()
        #expect(still && countdown.remaining == 0)
        #expect(UpNextWords.heading(UpNextCountdown(seconds: 10)) == "Next episode in 10 s")
        #expect(UpNextWords.heading(nil) == "Next episode")
    }

    // MARK: The next episode

    @Test func theLastEpisodeOfASeasonGoesOnToTheNextSeasonsFirst() throws {
        let catalogue = Catalogue(items: Make.show("wild", title: "Wild Isles", episodesPerSeason: [2, 3]))
        let last = try #require(catalogue.item("wild-s1e2"))
        #expect(EpisodeOrder.nextEpisode(after: last, in: catalogue)?.id == "wild-s2e1")
        // The series' last: nothing follows, so the suggestions come.
        let end = try #require(catalogue.item("wild-s2e3"))
        #expect(EpisodeOrder.nextEpisode(after: end, in: catalogue) == nil)
    }

    // MARK: What is suggested

    private func card(_ item: Item, show: Item? = nil, progress: PlaybackProgress? = nil) -> UpNextSuggestion {
        let request = PlayActionBuilder.action(for: item, show: show, progress: progress, context: Make.context).request!
        return UpNextSuggestion(id: show?.id ?? item.id, title: show?.title ?? item.title, line: "Continue", artwork: nil, request: request)
    }

    @Test func relatedComeFirstThenWhatTheViewerWasWatching() {
        let source = Make.movie("up", title: "Up")
        let related = (1...10).map { Make.movie("r\($0)", title: "Related \($0)") }
        let continuing = [card(Make.movie("c1")), card(Make.movie("c2"))]
        let made = UpNextSuggestions.make(after: source, related: related, continuing: continuing) {
            PlayActionBuilder.action(for: $0, progress: nil, context: Make.context).request
        }
        #expect(made.map(\.id) == ["r1", "r2", "r3", "r4", "r5", "r6", "c1", "c2", "r7", "r8", "r9", "r10"])
        #expect(made.count <= UpNextSuggestions.limit)
        #expect(made.first?.line == "2019")
    }

    @Test func neitherTheTitleItselfNorWhatCannotPlayNorTwiceTheSame() {
        let source = Make.movie("up", title: "Up")
        let broken = Make.movie("broken", files: [])
        let related = [source, broken, Make.movie("a"), Make.movie("b")]
        // The series that just ended is in Continue Watching still: not again.
        let continuing = [card(Make.movie("a")), card(Make.movie("up"))]
        let made = UpNextSuggestions.make(after: source, related: related, continuing: continuing) {
            PlayActionBuilder.action(for: $0, progress: nil, context: Make.context).request
        }
        #expect(made.map(\.id) == ["a", "b"])
    }

    @Test func aSuggestedSeriesPlaysWhereTheViewerWasOrFromItsFirstEpisode() throws {
        let catalogue = Catalogue(items: Make.show("wild", title: "Wild Isles", episodesPerSeason: [2, 2]))
        let show = try #require(catalogue.item("wild"))
        let fresh = UpNextSuggestions.request(for: show, catalogue: catalogue, progress: [:], context: Make.context)
        #expect(fresh?.item.id == "wild-s1e1")
        #expect(fresh?.show?.id == "wild")
        let watched = ["wild-s1e1": Make.progress("wild-s1e1", positionMs: 1_200_000, durationMs: 1_200_000, completed: true),
                       "wild-s1e2": Make.progress("wild-s1e2", positionMs: 300_000, durationMs: 1_200_000)]
        let resumed = UpNextSuggestions.request(for: show, catalogue: catalogue, progress: watched, context: Make.context)
        #expect(resumed?.item.id == "wild-s1e2")
        #expect(resumed?.startPositionMs == 300_000)
        let film = Make.movie("up")
        #expect(UpNextSuggestions.request(for: film, catalogue: Catalogue(items: [film]), progress: [:], context: Make.context)?.item.id == "up")
    }

    @Test func aContinueWatchingCardBecomesASuggestionOfItsTitle() throws {
        let items = Make.show("wild", title: "Wild Isles", episodesPerSeason: [2])
        let catalogue = Catalogue(items: items)
        let progress = ["wild-s1e1": Make.progress("wild-s1e1", positionMs: 300_000, durationMs: 1_200_000)]
        let entry = try #require(Shelves.continueWatching(in: catalogue, progress: progress).first)
        let card = ContinueCard(entry: entry, context: Make.context)
        let suggestion = try #require(UpNextSuggestions.suggestion(from: card, catalogue: catalogue))
        #expect(suggestion.id == "wild")
        #expect(suggestion.title == "Wild Isles")
        #expect(suggestion.request.item.id == "wild-s1e1")
        #expect(suggestion.line?.hasPrefix("Continue · ") == true)
    }

    // MARK: The preferences

    @Test func preferencesAreReadWithDefaultsForWhatIsMissingOrUnknown() throws {
        let decoded = try JSONDecoder().decode(PlaybackPreferences.self, from: Data(#"{"filmAutoplay":true,"countdownSeconds":12,"stillWatchingEpisodes":9,"newThing":1}"#.utf8))
        #expect(decoded.filmAutoplay)
        #expect(decoded.filmSuggestions)
        // A value a newer server allows: the nearest one this app knows.
        #expect(decoded.countdownSeconds == 10)
        #expect(decoded.stillWatchingEpisodes == 5)
        #expect(decoded.stillWatchingHours == 0)
        let profile = try JSONDecoder().decode(Profile.self, from: Data(#"{"id":"a","name":"A","color":"red","playback":{"episodeAutoplay":false}}"#.utf8))
        #expect(profile.playback?.episodeAutoplay == false)
        // A server from before says nothing: the defaults, and what was known is kept.
        let older = try JSONDecoder().decode(Profile.self, from: Data(#"{"id":"a","name":"A","color":"red"}"#.utf8))
        #expect(older.playback == nil && older.playbackPreferences == .defaults)
        #expect(older.keepingUnsaid(of: profile).playback?.episodeAutoplay == false)
        let again = try JSONDecoder().decode(PlaybackPreferences.self, from: try JSONEncoder().encode(decoded))
        #expect(again == decoded)
    }

    @Test func theSettingsSayItShortly() {
        #expect(PlaybackWords.summary(.defaults) == "Autoplay · asks after 3")
        var manual = PlaybackPreferences.defaults
        manual.episodeAutoplay = false
        manual.stillWatchingEpisodes = 0
        #expect(PlaybackWords.summary(manual) == "Up Next waits")
        #expect(PlaybackWords.countdown(0) == "Off")
        #expect(PlaybackWords.hours(1) == "1 hour")
    }

    // MARK: On the remote

    @Test func theRemoteShowsHowLongTheCountdownHasLeft() throws {
        let state = RemotePlayerState(
            itemId: "a", status: .ended, positionMs: 0, at: 1_000_000, durationMs: nil,
            upNext: RemoteUpNext(kind: .episode, itemId: "b", countdownMs: 8_000))
        #expect(state.upNextRemainingMs(atServerTime: 1_003_000) == 5_000)
        #expect(state.upNextRemainingMs(atServerTime: 1_020_000) == 0)
        let waiting = RemotePlayerState(itemId: "a", status: .ended, positionMs: 0, at: 0, durationMs: nil, upNext: RemoteUpNext(kind: .stillWatching, itemId: "b", countdownMs: nil))
        #expect(waiting.upNextRemainingMs(atServerTime: 5) == nil)
        // A countdown running down is not news; a new one, or another screen, is.
        let report = { (countdown: Int?, kind: RemoteUpNext.Kind) in
            PlayerReport(itemId: "a", assetId: nil, profileId: nil, status: .ended, positionMs: 0, durationMs: nil, rate: 1,
                         upNext: RemoteUpNext(kind: kind, itemId: "b", countdownMs: countdown))
        }
        #expect(report(9_000, .episode).sameApartFromPlace(as: report(8_000, .episode)))
        #expect(!report(nil, .episode).sameApartFromPlace(as: report(8_000, .episode)))
        #expect(!report(nil, .episode).sameApartFromPlace(as: report(nil, .stillWatching)))
        let decoded = try JSONDecoder().decode(RemoteCommand.self, from: Data(#"{"type":"upNext","action":"continue"}"#.utf8))
        #expect(decoded == .upNext(.continue))
        #expect(try JSONDecoder().decode(RemoteCommand.self, from: Data(#"{"type":"upNext","action":"later"}"#.utf8)) == .unknown("upNext"))
    }
}
