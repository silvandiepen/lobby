// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

@Suite struct ServerAddressTests {
    @Test func aBareHostGetsHTTPAndLobbysPort() {
        #expect(ServerAddress.parse("lobby.example.ts.net")?.absoluteString == "http://lobby.example.ts.net:8674")
        #expect(ServerAddress.parse("  192.168.1.20 ")?.absoluteString == "http://192.168.1.20:8674")
    }

    @Test func aPortThatWasTypedIsKept() {
        #expect(ServerAddress.parse("pi.local:9000")?.absoluteString == "http://pi.local:9000")
    }

    @Test func anAddressWithASchemeIsTakenAsWritten() {
        #expect(ServerAddress.parse("https://media.example.ts.net")?.absoluteString == "https://media.example.ts.net")
        #expect(ServerAddress.parse("HTTP://Pi.local:8674/v1/")?.absoluteString == "http://Pi.local:8674")
    }

    @Test(arguments: ["", "   ", "two words", "ftp://pi.local", "http://"])
    func whatIsNotAnAddressIsRefused(text: String) {
        #expect(ServerAddress.parse(text) == nil)
    }

    @Test func theResultIsWhatLobbyClientAccepts() throws {
        let url = try #require(ServerAddress.parse("media.example.ts.net"))
        #expect(try LobbyClient(baseURL: url).baseURL == url)
    }

    @Test func plainHTTPIsShownWithoutItsScheme() {
        #expect(ServerAddress.display(URL(string: "http://pi.local:8674")!) == "pi.local:8674")
        #expect(ServerAddress.display(URL(string: "https://media.example.ts.net")!) == "https://media.example.ts.net")
    }
}

@Suite struct MediaFormatTests {
    @Test func runtimes() {
        #expect(MediaFormat.runtime(ms: 6_120_000) == "1 h 42 min")
        #expect(MediaFormat.runtime(ms: 3_480_000) == "58 min")
        #expect(MediaFormat.runtime(ms: 7_200_000) == "2 h")
        #expect(MediaFormat.runtime(ms: 12_000) == "1 min")
        #expect(MediaFormat.runtime(ms: nil) == nil)
        #expect(MediaFormat.runtime(ms: 0) == nil)
    }

    @Test func positions() {
        #expect(MediaFormat.clock(ms: 2_057_000) == "34:17")
        #expect(MediaFormat.clock(ms: 6_128_000) == "1:42:08")
        #expect(MediaFormat.clock(ms: 0) == "0:00")
    }

    @Test func whatIsLeft() {
        #expect(MediaFormat.remaining(positionMs: 1_800_000, durationMs: 3_480_000) == "28 min left")
        #expect(MediaFormat.remaining(positionMs: 1_800_000, durationMs: nil) == nil)
        #expect(MediaFormat.remaining(positionMs: 4_000_000, durationMs: 3_480_000) == nil)
        #expect(MediaFormat.fraction(positionMs: 870_000, durationMs: 3_480_000) == 0.25)
        #expect(MediaFormat.fraction(positionMs: 870_000, durationMs: nil) == nil)
    }

    @Test func episodeCodesAndSeasonNames() {
        #expect(MediaFormat.episodeCode(season: 1, episode: 2) == "S1 E2")
        #expect(MediaFormat.episodeCode(season: 0, episode: 3) == "Specials E3")
        #expect(MediaFormat.episodeCode(season: nil, episode: 4) == "Episode 4")
        #expect(MediaFormat.episodeCode(season: 2, episode: nil) == nil)
        #expect(MediaFormat.seasonName(2, fallback: "x") == "Season 2")
        #expect(MediaFormat.seasonName(0, fallback: "x") == "Specials")
        #expect(MediaFormat.seasonName(nil, fallback: "Extras") == "Extras")
    }

    @Test func resolutions() {
        #expect(MediaFormat.resolution(height: 2160, width: 3840) == "4K")
        #expect(MediaFormat.resolution(height: 1080, width: 1920) == "1080p")
        // A scope film is 1920 wide and far less than 1080 high.
        #expect(MediaFormat.resolution(height: 800, width: 1920) == "1080p")
        #expect(MediaFormat.resolution(height: 720, width: 1280) == "720p")
        #expect(MediaFormat.resolution(height: 480, width: 720) == "SD")
        #expect(MediaFormat.resolution(height: nil, width: nil) == nil)
    }

    @Test func episodeTitles() {
        let show = Item(id: "s", kind: .show, title: "Wild Isles", addedAt: Make.epoch)
        func episode(_ title: String, _ number: Int?) -> Item {
            Item(id: "e", kind: .episode, title: title, seasonNumber: 1, episodeNumber: number, addedAt: Make.epoch)
        }
        #expect(ItemText.episodeTitle(episode("Coastal Worlds", 2), show: show) == "2. Coastal Worlds")
        // A file name that only said "Wild Isles S01E02" leaves the episode with the show's title.
        #expect(ItemText.episodeTitle(episode("Wild Isles", 2), show: show) == "Episode 2")
        #expect(ItemText.episodeTitle(episode("Behind the Scenes", nil), show: show) == "Behind the Scenes")
        // So does a file name without a title, which the server calls "Episode 2".
        #expect(ItemText.episodeTitle(episode("Episode 2", 2), show: show) == "Episode 2")
        #expect(ItemText.episodeLine(episode("Coastal Worlds", 2), show: show) == "S1 E2 · Coastal Worlds")
        #expect(ItemText.episodeLine(episode("Episode 2", 2), show: show) == "S1 E2")
        #expect(ItemText.episodeLine(episode("Wild Isles", 2), show: show) == "S1 E2")
    }
}

@Suite struct TitleTileTintTests {
    @Test func theSameTitleAlwaysHasTheSameColour() {
        #expect(TitleTileTint(title: "Toy Story") == TitleTileTint(title: "Toy Story"))
        #expect(TitleTileTint(title: "Toy Story") == TitleTileTint(title: "TOY STORY"))
        #expect(TitleTileTint(title: "Amélie") == TitleTileTint(title: "Amelie"))
    }

    @Test func fnv1aMatchesItsPublishedTestVectors() {
        #expect(StableHash.value(of: "") == 0xCBF2_9CE4_8422_2325)
        #expect(StableHash.value(of: "a") == 0xAF63_DC4C_8601_EC8C)
        #expect(StableHash.value(of: "foobar") == 0x8594_4171_F739_67E8)
    }

    @Test func titlesSpreadOverTheHues() {
        let titles = ["Up", "Coco", "Cars", "Brave", "Luca", "Soul", "Bolt", "Mulan", "Moana", "Frozen", "Tangled", "Encanto"]
        let hues = Set(titles.map { TitleTileTint(title: $0).hue })
        #expect(hues.count >= 8)
        #expect(hues.allSatisfy { (0..<1).contains($0) })
    }
}

@Suite struct PlaybackPolicyTests {
    @Test func aFilmIsWatchedInItsLastFivePercent() {
        let hour = 3_600_000
        #expect(!PlaybackPolicy.isCompleted(positionMs: Int(Double(hour) * 0.94), durationMs: hour))
        #expect(PlaybackPolicy.isCompleted(positionMs: Int(Double(hour) * 0.95), durationMs: hour))
        #expect(PlaybackPolicy.isCompleted(positionMs: hour, durationMs: hour))
    }

    @Test func aVeryLongFilmNeedsAllButItsLastEightMinutes() {
        let fourHours = 4 * 3_600_000
        // 5 % would be twelve minutes.
        #expect(!PlaybackPolicy.isCompleted(positionMs: fourHours - 9 * 60_000, durationMs: fourHours))
        #expect(PlaybackPolicy.isCompleted(positionMs: fourHours - 8 * 60_000, durationMs: fourHours))
    }

    @Test func withoutADurationOnlyTheEndCounts() {
        #expect(!PlaybackPolicy.isCompleted(positionMs: 9_999_999, durationMs: nil))
    }

    @Test func resumeStartsWhereTheViewerStopped() {
        #expect(PlaybackPolicy.resumePosition(for: Make.progress("m", positionMs: 2_057_000), durationMs: 6_000_000) == 2_057_000)
        #expect(PlaybackPolicy.resumePosition(for: nil, durationMs: 6_000_000) == 0)
    }

    @Test func resumeStartsOverAfterTheEndOrInTheCredits() {
        #expect(PlaybackPolicy.resumePosition(for: Make.progress("m", positionMs: 5_990_000, completed: true), durationMs: 6_000_000) == 0)
        // Stopped in the credits by a build that did not mark it watched.
        #expect(PlaybackPolicy.resumePosition(for: Make.progress("m", positionMs: 5_900_000), durationMs: 6_000_000) == 0)
    }

    @Test func theFirstSecondsAreNotWrittenDownUnlessThereWasProgress() {
        #expect(!PlaybackPolicy.isWorthRecording(positionMs: 3_000, hasProgress: false))
        #expect(PlaybackPolicy.isWorthRecording(positionMs: 5_000, hasProgress: false))
        #expect(PlaybackPolicy.isWorthRecording(positionMs: 0, hasProgress: true))
    }

    @Test func whilePlayingThePositionIsWrittenEveryTenSeconds() {
        #expect(PlaybackPolicy.shouldRecordTick(positionMs: 5_000, lastRecordedMs: nil))
        #expect(!PlaybackPolicy.shouldRecordTick(positionMs: 14_000, lastRecordedMs: 5_000))
        #expect(PlaybackPolicy.shouldRecordTick(positionMs: 15_000, lastRecordedMs: 5_000))
        // Scrubbing back is a change too.
        #expect(PlaybackPolicy.shouldRecordTick(positionMs: 1_000, lastRecordedMs: 600_000))
    }
}
