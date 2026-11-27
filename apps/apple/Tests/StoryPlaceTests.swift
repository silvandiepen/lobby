// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

/// Stories in the apps: what a story's button says, the kids' sleep timer, and where Stories
/// stand on the kids bar.
@Suite struct StoryPlaceTests {
    private let book = MusicBook(
        id: "b", title: "The Brave Little Kettle", narrators: ["Robin Reed"], durationMs: 600_000,
        addedAt: Date(timeIntervalSince1970: 0), parts: [.init(trackId: "t", startMs: 0, durationMs: 600_000)])

    private func progress(_ ms: Int, completed: Bool = false) -> PlaybackProgress {
        PlaybackProgress(itemId: "b", positionMs: ms, durationMs: 600_000, completed: completed, revision: 1,
                         updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func aStoryNotBegunPlays() {
        let place = StoryPlace(book: book, progress: nil)
        #expect(place.start == .play)
        #expect(place.label == "Play")
        #expect(place.fraction == nil)
        #expect(place.leftMs == nil)
        // A place of nothing is not begun.
        #expect(StoryPlace(book: book, progress: progress(0)).start == .play)
    }

    @Test func aStoryBegunResumesAndSaysWhatIsLeft() {
        let place = StoryPlace(book: book, progress: progress(150_000))
        #expect(place.start == .resume)
        #expect(place.label == "Resume")
        #expect(place.fraction == 0.25)
        #expect(place.leftMs == 450_000)
    }

    @Test func whilePlayingThePlayersPlaceCounts() {
        let place = StoryPlace(book: book, progress: progress(150_000), playingMs: 300_000)
        #expect(place.fraction == 0.5)
        #expect(place.leftMs == 300_000)
    }

    @Test func aStoryHeardToTheEndPlaysAgain() {
        let place = StoryPlace(book: book, progress: progress(600_000, completed: true))
        #expect(place.start == .again)
        #expect(place.label == "Play again")
        #expect(place.fraction == nil)
        // Started again on another device: it resumes there.
        #expect(StoryPlace(book: book, progress: progress(600_000, completed: true), playingMs: 5_000).start == .resume)
    }

    @Test func theSleepTimerInAChildsWords() {
        #expect(KidsSleep.allCases == [.endOfStory, .minutes15, .minutes30, .off])
        #expect(KidsSleep.endOfStory.title(isStory: true, chapters: false) == "When the story ends")
        #expect(KidsSleep.endOfStory.title(isStory: true, chapters: true) == "When this part ends")
        #expect(KidsSleep.endOfStory.title(isStory: false, chapters: false) == "When the song ends")
        #expect(KidsSleep.minutes15.minutes == 15)
        #expect(KidsSleep.minutes30.minutes == 30)
        #expect(KidsSleep.off.minutes == nil)
        #expect(KidsSleep.endOfStory.minutes == nil)
    }

    @Test func storiesAreOnTheKidsBarWhileTheChildMayListen() {
        #expect(KidsSection.places(listens: true) == [.home, .stories, .movies, .series, .onHere])
        #expect(KidsSection.places(listens: false) == [.home, .movies, .series, .onHere])
        #expect(KidsSection.stories.name == "Stories")
        #expect(KidsSection.stories.theme == .stories)
    }
}
