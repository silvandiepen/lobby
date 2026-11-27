// SPDX-License-Identifier: MPL-2.0
import CoreGraphics
import Foundation
import LobbyKit
import Testing

@testable import Lobby

@Suite struct PlayActionTests {
    @Test func aDirectFileNobodyStartedPlaysFromTheBeginning() throws {
        let action = PlayActionBuilder.action(for: Make.movie("up"), progress: nil, context: Make.context)
        guard case .play(let request, .play, nil) = action else {
            Issue.record("Expected Play, got \(action)")
            return
        }
        #expect(request.source == .direct)
        #expect(request.startPositionMs == 0)
        #expect(request.durationMs == 6_000_000)
    }

    @Test func aPartWatchedFilmResumes() {
        let action = PlayActionBuilder.action(
            for: Make.movie("up"), progress: Make.progress("up", positionMs: 2_057_000), context: Make.context)
        guard case .play(let request, .resume(positionMs: 2_057_000), _) = action else {
            Issue.record("Expected Resume, got \(action)")
            return
        }
        #expect(request.startPositionMs == 2_057_000)
    }

    @Test func aWatchedFilmPlaysAgainFromTheBeginning() {
        let action = PlayActionBuilder.action(
            for: Make.movie("up"), progress: Make.progress("up", positionMs: 5_990_000, completed: true), context: Make.context)
        guard case .play(let request, .playAgain, _) = action else {
            Issue.record("Expected Play Again, got \(action)")
            return
        }
        #expect(request.startPositionMs == 0)
    }

    @Test func anMKVPlaysThroughTheServerAndSaysSo() {
        let mkv = Make.file(.remux, container: "mkv", reason: "The file is MKV, which has to be repackaged as MP4.")
        let action = PlayActionBuilder.action(for: Make.movie("brave", files: [mkv]), progress: nil, context: Make.context)
        guard case .play(let request, .play, let note?) = action else {
            Issue.record("Expected Play with a note, got \(action)")
            return
        }
        #expect(request.source == .prepared)
        #expect(note.contains("The file is MKV"))
    }

    @Test func anOldAVIShowsTheServersReason() {
        let avi = Make.file(.transcode, container: "avi", codec: "mpeg4", reason: "The video is MPEG4, which Apple devices do not play.")
        let action = PlayActionBuilder.action(for: Make.movie("old", files: [avi]), progress: nil, context: Make.context)
        #expect(action == .unavailable(headline: "Can't play on Apple devices yet", explanation: "The video is MPEG4, which Apple devices do not play."))
    }

    @Test func withoutAReasonFromTheServerTheFormatIsStillNamed() {
        let avi = Make.file(.transcode, container: "avi", codec: "mpeg4")
        let action = PlayActionBuilder.action(for: Make.movie("old", files: [avi]), progress: nil, context: Make.context)
        guard case .unavailable(_, let explanation) = action else {
            Issue.record("Expected a reason, got \(action)")
            return
        }
        #expect(explanation.hasPrefix("MPEG4 video in AVI"))
    }

    @Test func aFileOnAnUnpluggedDriveIsNotAvailable() {
        let action = PlayActionBuilder.action(
            for: Make.movie("up", files: [Make.file(available: false)]), progress: nil, context: Make.context)
        guard case .unavailable("Not available right now", _) = action else {
            Issue.record("Expected not available, got \(action)")
            return
        }
    }

    @Test func aSecondCopyThatPlaysIsPreferredOverOneThatDoesNot() {
        let avi = Make.file(.transcode, container: "avi", codec: "mpeg4")
        let mp4 = Make.file(.direct)
        let action = PlayActionBuilder.action(for: Make.movie("both", files: [avi, mp4]), progress: nil, context: Make.context)
        #expect(action.request?.file.container == "mp4")
    }

    @Test func anItemWithoutFilesSaysSo() {
        let action = PlayActionBuilder.action(for: Make.movie("none", files: []), progress: nil, context: Make.context)
        #expect(!action.isPlayable)
    }

    @Test func anEpisodeInASharedFilePlaysItsOwnPart() {
        let shared = Make.file(durationMs: 2_640_000, startMs: 1_320_000, endMs: 2_640_000)
        let episode = Item(id: "e2", kind: .episode, title: "Part Two", seasonNumber: 1, episodeNumber: 2, addedAt: Make.epoch, files: [shared])
        let action = PlayActionBuilder.action(for: episode, progress: nil, context: Make.context)
        #expect(action.request?.durationMs == 1_320_000)
    }
}

@Suite struct MovieDetailTests {
    @Test func aMatchedFilmShowsItsSummaryAndGenresApartFromItsCategories() {
        let item = Item(
            id: "heat", kind: .movie, title: "Heat", overview: "A crew of thieves.", genres: ["Crime", "Drama"],
            categories: ["Movies"], addedAt: Make.epoch)
        let detail = MovieDetail(item: item, progress: nil, context: Make.context)
        #expect(detail.overview == "A crew of thieves.")
        #expect(detail.genres == ["Crime", "Drama"])
        #expect(detail.categories == ["Movies"])
    }

    @Test func aFilmShowsItsYearRuntimeCategoriesAndFile() {
        let detail = MovieDetail(item: Make.movie("up", title: "Up", year: 2009), progress: nil, context: Make.context)
        #expect(detail.facts == ["2009", "1 h 40 min"])
        #expect(detail.categories == ["Pixar"])
        #expect(detail.watch == .unwatched)
        #expect(detail.remaining == nil)
        #expect(detail.fileFacts == ["On Lobby Server", MediaFormat.size(bytes: 2_100_000_000), "MP4", "1080p"])
    }

    @Test func aPartWatchedFilmShowsWhatIsLeft() {
        let detail = MovieDetail(
            item: Make.movie("up"), progress: Make.progress("up", positionMs: 1_500_000), context: Make.context)
        #expect(detail.watch == .inProgress(fraction: 0.25))
        #expect(detail.remaining == "1 h 15 min left")
    }

    @Test func aWatchedFilmSaysWatched() {
        let detail = MovieDetail(
            item: Make.movie("up"), progress: Make.progress("up", positionMs: 5_990_000, completed: true), context: Make.context)
        #expect(detail.watch == .watched)
        #expect(detail.watch.label == "Watched")
    }
}

@Suite struct ShowDetailTests {
    let catalogue = Catalogue(items: Make.show("wild", title: "Wild Isles", episodesPerSeason: [3, 2]))

    private func detail(_ progress: [PlaybackProgress] = []) throws -> ShowDetail {
        let show = try #require(catalogue.item("wild"))
        return ShowDetail(
            show: show, catalogue: catalogue,
            progress: Dictionary(uniqueKeysWithValues: progress.map { ($0.itemId, $0) }), context: Make.context)
    }

    @Test func seasonsAndEpisodesAreInOrder() throws {
        let detail = try detail()
        #expect(detail.facts == ["Series", "2 Seasons"])
        #expect(detail.seasons.map(\.name) == ["Season 1", "Season 2"])
        #expect(detail.seasons[0].episodes.map(\.title) == ["1. Chapter 1", "2. Chapter 2", "3. Chapter 3"])
        #expect(detail.seasons[0].episodes[0].runtime == "20 min")
    }

    @Test func someoneWhoNeverWatchedStartsAtTheFirstEpisode() throws {
        let detail = try detail()
        #expect(detail.primary?.label == "Play S1 E1")
        #expect(detail.currentSeasonID == "wild-s1")
    }

    @Test func aPartWatchedEpisodeIsResumed() throws {
        let detail = try detail([Make.progress("wild-s1e2", positionMs: 300_000, durationMs: 1_200_000)])
        #expect(detail.primary?.label == "Resume S1 E2")
        #expect(detail.primary?.action.request?.startPositionMs == 300_000)
        #expect(detail.seasons[0].episodes[1].watch == .inProgress(fraction: 0.25))
    }

    @Test func afterAFinishedEpisodeTheNextOneIsUp() throws {
        let detail = try detail([Make.progress("wild-s1e3", positionMs: 1_200_000, durationMs: 1_200_000, completed: true)])
        #expect(detail.primary?.label == "Play S2 E1")
        #expect(detail.currentSeasonID == "wild-s2")
        #expect(detail.seasons[0].episodes[2].watch == .watched)
    }

    @Test func aSeasonWithoutEpisodesIsLeftOut() throws {
        let items = Make.show("empty", title: "Empty", episodesPerSeason: [0, 1])
        let catalogue = Catalogue(items: items)
        let detail = ShowDetail(show: items[0], catalogue: catalogue, progress: [:], context: Make.context)
        #expect(detail.seasons.map(\.name) == ["Season 2"])
        #expect(detail.facts.contains("1 Season"))
    }
}

@Suite struct LibraryShelvesTests {
    @Test func continueWatchingCardsSayWhatIsLeft() throws {
        let items = [Make.movie("up", title: "Up")] + Make.show("wild", title: "Wild Isles", episodesPerSeason: [2])
        let progress = [
            "up": Make.progress("up", positionMs: 1_500_000, minutesAgo: 5),
            "wild-s1e1": Make.progress("wild-s1e1", positionMs: 1_200_000, durationMs: 1_200_000, completed: true, minutesAgo: 1),
        ]
        let shelves = LibraryShelves(catalogue: Catalogue(items: items), progress: progress, context: Make.context)

        #expect(shelves.continueWatching.map(\.title) == ["Wild Isles", "Up"])
        let episode = shelves.continueWatching[0]
        #expect(episode.subtitle == "S1 E2 · Chapter 2")
        #expect(episode.status == "Next episode")
        #expect(episode.fraction == nil)
        #expect(episode.detailItemID == "wild")
        let film = shelves.continueWatching[1]
        #expect(film.status == "1 h 15 min left")
        #expect(film.fraction == 0.25)
        #expect(film.accessibilityLabel == "Up, 1 h 15 min left")
        // The card's one line: the episode's number and what is left, without its title.
        #expect(episode.line == "S1 E2 · Next episode")
        #expect(film.line == "1 h 15 min left")
    }

    @Test func aStartedFilmCanBeStartedFromItsBeginning() throws {
        let film = Make.movie("up", title: "Up")
        let started = PlayActionBuilder.action(
            for: film, progress: Make.progress("up", positionMs: 1_500_000, minutesAgo: 5), context: Make.context)
        #expect(started.request?.startPositionMs == 1_500_000)
        #expect(try #require(started.fromBeginning).startPositionMs == 0)
        // Nothing to offer for a film that starts at its beginning anyway.
        #expect(PlayActionBuilder.action(for: film, progress: nil, context: Make.context).fromBeginning == nil)
    }

    @Test func thePillsAreAllMoviesSeriesAndTheHouseholdsOwnParts() {
        let items = [Make.movie("up", title: "Up")] + Make.show("wild", title: "Wild Isles", episodesPerSeason: [1])
        let groups = CategoryGroups(groups: [
            CategoryGroup(name: nil, categories: ["Series"]),
            CategoryGroup(name: "Kids", categories: ["Pixar"]),
            CategoryGroup(name: "Concerts", categories: ["Live"]),
        ])
        let shelves = LibraryShelves(catalogue: Catalogue(items: items), groups: groups, progress: [:], context: Make.context)
        // "Concerts" holds nothing, so it has no pill; nor has Movies, as the only film is in Kids.
        #expect(shelves.filters == [.all, .series, .group("Kids")])
        #expect(shelves.filters.map(shelves.title(of:)) == ["Home", "Series", "Kids"])
        #expect(shelves.resolved(.group("Kids")) == .group("Kids"))
        // A part of the library that is gone falls back to everything.
        #expect(shelves.resolved(.group("Concerts")) == .all)

        // A server without groups: the three fixed pills.
        let plain = LibraryShelves(catalogue: Catalogue(items: items), progress: [:], context: Make.context)
        #expect(plain.filters == [.all, .movies, .series])
    }

    @Test func aCategoryLooksAsTheHouseholdSetItAndNeutralOtherwise() {
        let groups = CategoryGroups(
            groups: [CategoryGroup(name: "G", categories: ["A", "B"])],
            logos: ["A": CategoryLogo(id: "logo1", width: 500, height: 105)])
        #expect(CategoryLook(category: "A", in: groups).logo?.id == "logo1")
        // Nothing is made up from a name: no logo and no symbol unless the server said so.
        #expect(CategoryLook(category: "B", in: groups) == .plain)
        #expect(CategoryLook(category: "Kids", in: .none) == .plain)
        #expect(CategoryLook(group: "G", in: groups) == .plain)
        // By id, whatever it is called, with what the household chose.
        let set = CategoryGroups(groups: [CategoryGroup(id: "g1", name: "Later Name", icon: "star.fill", color: "teal", entries: [
            LibraryCategory(id: "c1", name: "Other Name", icon: "leaf.fill", color: "green", logo: CategoryLogo(id: "l", width: 1, height: 1, transparent: false)),
        ])])
        #expect(CategoryLook(group: "g1", in: set) == CategoryLook(symbol: "star.fill", color: "teal"))
        #expect(CategoryLook(category: "c1", in: set).symbol == "leaf.fill")
        #expect(CategoryLook(category: "c1", in: set).logo?.transparent == false)
        #expect(CategoryLook(category: "Other Name", in: set) == .plain)
        // A symbol the system does not have falls back to the neutral one.
        #expect(AppSymbol.existing("tv.fill") == "tv.fill")
        #expect(AppSymbol.existing("no.such.symbol.anywhere") == nil)
        #expect(AppSymbol.existing(nil) == nil)
        #expect(AppSymbol.filter(.movies) { _ in nil } == AppSymbol.movies)
        #expect(AppSymbol.filter(.group("G")) { _ in nil } == AppSymbol.group)
        #expect(AppSymbol.filter(.group("G")) { _ in "star.fill" } == "star.fill")
    }

    @Test func logosOfDifferentShapesTakeTheSameRoom() {
        // A long wordmark and a compact mark, sized to the same area.
        let wide = LogoMetrics.size(width: 500, height: 105, area: 3_000, maxWidth: 200, maxHeight: 100)
        let compact = LogoMetrics.size(width: 300, height: 280, area: 3_000, maxWidth: 200, maxHeight: 100)
        #expect(abs(wide.width * wide.height - compact.width * compact.height) < 200)
        #expect(wide.width > compact.width && wide.height < compact.height)
        // Never beyond the room it has.
        let capped = LogoMetrics.size(width: 1000, height: 50, area: 3_000, maxWidth: 124, maxHeight: 52)
        #expect(capped.width == 124 && capped.height <= 52)
        #expect(LogoMetrics.size(width: 0, height: 10, area: 3_000, maxWidth: 10, maxHeight: 10) == .zero)
    }

    #if !os(tvOS)
    @Test func threePostersFillAPhonesWidthBetweenTheMargins() {
        for width: CGFloat in [320, 375, 393, 402, 440] {
            let poster = TileMetrics.compactPoster(contentWidth: width)
            let used = 3 * poster + 2 * AppTheme.Space.tile + 2 * AppTheme.Space.page
            #expect(used <= width && width - used < 3, "At \(width) points three posters use \(used).")
            // The Continue Watching card leaves room for the next one to peek in.
            let wide = TileMetrics.compactWide(contentWidth: width)
            #expect(wide + AppTheme.Space.page + AppTheme.Space.tile < width)
        }
    }
    #endif

    @Test func recentlyAddedHasOneCardPerSeason() throws {
        let items = [Make.movie("up", title: "Up", year: 2009)] + Make.show("wild", title: "Wild Isles", episodesPerSeason: [3])
        let shelves = LibraryShelves(catalogue: Catalogue(items: items), progress: [:], context: Make.context)
        let season = try #require(shelves.recentlyAdded.first { $0.id == "wild-s1" })
        #expect(season.title == "Wild Isles")
        #expect(season.captionLines == ["Season 1", "3 episodes"])
        #expect(season.accessibilityLabel == "Wild Isles, Season 1, 3 episodes")
        #expect(season.detailItemID == "wild-s1")
        #expect(shelves.recentlyAdded.count == 2)
        #expect(shelves.movies.map(\.id) == ["up"])
        #expect(shelves.series.map(\.id) == ["wild"])
        #expect(shelves.categories.map(\.name) == ["Pixar", "Series"])
    }
}
