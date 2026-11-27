// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing

@testable import LobbyKit

@Suite struct EpisodeOrderTests {
    /// Bluey: two seasons, Specials, and one file whose number is unknown.
    static let catalogue = Catalogue(items: [
        Make.show("bluey", title: "Bluey"),
        Make.season("s2", show: "bluey", number: 2),
        Make.season("s0", show: "bluey", number: 0),
        Make.season("s1", show: "bluey", number: 1),
        Make.episode("s1e2", season: "s1", s: 1, e: 2),
        Make.episode("s1e10", season: "s1", s: 1, e: 10),
        Make.episode("s1e1", season: "s1", s: 1, e: 1),
        Make.episode("s1-unnumbered", season: "s1", s: 1, e: nil),
        Make.episode("s2e1", season: "s2", s: 2, e: 1),
        // The season number can also come from the season alone.
        Make.episode("s2e2", season: "s2", s: nil, e: 2),
        Make.episode("special-1", season: "s0", s: 0, e: 1),
        Make.episode("special-2", season: "s0", s: 0, e: 2),
        Item(id: "trailer", kind: .extra, parentId: "bluey", title: "Trailer", extraKind: .trailer, addedAt: Make.epoch),
    ])

    @Test func aCatalogueLimitedToSomeEpisodesKeepsTheirSeasonsAndShowAndNothingElse() throws {
        let limited = Self.catalogue.limited(to: ["s1e1", "s1e10", "s2e2", "gone"])
        #expect(Set(limited.itemsByID.keys) == ["bluey", "s1", "s2", "s1e1", "s1e10", "s2e2"])
        // The next episode is the next one that is there.
        #expect(EpisodeOrder.episodes(ofShow: "bluey", in: limited).map(\.id) == ["s1e1", "s1e10", "s2e2"])
        let first = try #require(limited.item("s1e1"))
        #expect(EpisodeOrder.chain(containing: first, in: limited).map(\.id) == ["s1e1", "s1e10", "s2e2"])
        #expect(Shelves.series(in: limited).map(\.id) == ["bluey"])
        #expect(Self.catalogue.limited(to: []).isEmpty)
    }

    @Test func ordersBySeasonThenEpisodeWithUnnumberedLastAndSpecialsApart() {
        let order = EpisodeOrder.episodes(ofShow: "bluey", in: Self.catalogue).map(\.id)
        #expect(order == ["s1e1", "s1e2", "s1e10", "s1-unnumbered", "s2e1", "s2e2"])
        #expect(EpisodeOrder.specials(ofShow: "bluey", in: Self.catalogue).map(\.id) == ["special-1", "special-2"])
    }

    @Test func listsSeasonsWithSpecialsAfterTheNumberedOnes() {
        #expect(EpisodeOrder.seasons(ofShow: "bluey", in: Self.catalogue).map(\.id) == ["s1", "s2", "s0"])
        #expect(EpisodeOrder.episodes(ofSeason: "s1", in: Self.catalogue).map(\.id) == ["s1e1", "s1e2", "s1e10", "s1-unnumbered"])
    }

    @Test func nextEpisodeCrossesSeasonsAndNeverLeadsIntoSpecials() throws {
        func next(_ id: String) throws -> String? {
            EpisodeOrder.nextEpisode(after: try #require(Self.catalogue.item(id)), in: Self.catalogue)?.id
        }
        #expect(try next("s1e1") == "s1e2")
        #expect(try next("s1e10") == "s1-unnumbered")
        #expect(try next("s1-unnumbered") == "s2e1")
        #expect(try next("s2e1") == "s2e2")
        #expect(try next("s2e2") == nil)
        #expect(try next("special-1") == "special-2")
        #expect(try next("special-2") == nil)
        #expect(try next("trailer") == nil)
    }
}

@Suite struct ShelvesTests {
    static let catalogue = Catalogue(items: EpisodeOrderTests.catalogue.items + [
        Make.movie("up", title: "Up", added: 50, genres: ["Animation", "Family"], categories: ["Pixar"]),
        Make.movie("jungle", title: "The Jungle Book", sortTitle: "Jungle Book", added: 10, genres: ["Animation"], categories: ["Disney"]),
        Make.movie("amelie", title: "Amélie", added: 20, genres: ["Comedy"]),
        Make.movie("toy10", title: "Toy Story 10", added: 1, categories: ["Pixar"]),
        Make.movie("toy2", title: "Toy Story 2", added: 2, categories: ["Pixar"]),
        Item(id: "gozo", kind: .personal, title: "Holiday in Gozo", matchStatus: .personal, addedAt: Make.date(30)),
        Make.show("andor", title: "Andor", genres: ["Drama"], categories: ["Series"]),
        Make.season("andor-s1", show: "andor", number: 1),
        Make.episode("andor-1", season: "andor-s1", s: 1, e: 1, title: "Kassa", added: 40),
        Make.episode("andor-2", season: "andor-s1", s: 1, e: 2, title: "That Would Be Me", added: 60),
    ])

    // MARK: Continue Watching

    @Test func showsUnfinishedFilmsNewestFirstAndLeavesOutFinishedOnes() {
        let progress = Make.progressMap(
            Make.progress("up", at: 5),
            Make.progress("jungle", at: 9),
            Make.progress("amelie", completed: true, at: 20),
            Make.progress("toy2", position: 0, at: 30),
            Make.progress("gozo", at: 7),
            Make.progress("no-longer-in-the-library", at: 99))

        let shelf = Shelves.continueWatching(in: Self.catalogue, progress: progress)

        #expect(shelf.map(\.item.id) == ["jungle", "gozo", "up"])
        #expect(shelf.allSatisfy { $0.reason == .resume && $0.show == nil })
        #expect(shelf[0].progress?.positionMs == 60_000)
    }

    @Test func aShowResumesTheEpisodeTheViewerLeftPartWay() {
        let progress = Make.progressMap(
            Make.progress("s1e1", completed: true, at: 1),
            Make.progress("s1e2", position: 300_000, at: 2))

        let shelf = Shelves.continueWatching(in: Self.catalogue, progress: progress)

        #expect(shelf.count == 1)
        #expect(shelf[0].item.id == "s1e2")
        #expect(shelf[0].show?.id == "bluey")
        #expect(shelf[0].reason == .resume)
        #expect(shelf[0].progress?.positionMs == 300_000)
        #expect(shelf[0].id == "bluey")
    }

    @Test func aShowOffersTheNextUnwatchedEpisodeAfterAFinishedOne() {
        let progress = Make.progressMap(
            Make.progress("s1e1", completed: true, at: 1),
            Make.progress("s1e2", completed: true, at: 3),
            // Watched out of order earlier: skipped when looking for what is next.
            Make.progress("s1e10", completed: true, at: 2))

        let shelf = Shelves.continueWatching(in: Self.catalogue, progress: progress)

        #expect(shelf.map(\.item.id) == ["s1-unnumbered"])
        #expect(shelf[0].reason == .nextEpisode)
        #expect(shelf[0].progress == nil)
        #expect(shelf[0].lastWatchedAt == Make.date(3))
    }

    @Test func theNextEpisodeCrossesIntoTheNextSeason() {
        let progress = Make.progressMap(Make.progress("s1-unnumbered", completed: true, at: 4))
        #expect(Shelves.continueWatching(in: Self.catalogue, progress: progress).map(\.item.id) == ["s2e1"])
    }

    @Test func finishingTheLastEpisodeTakesTheShowOffTheShelf() {
        let finished = Make.progressMap(Make.progress("s2e2", completed: true, at: 4))
        #expect(Shelves.continueWatching(in: Self.catalogue, progress: finished).isEmpty)

        // Unless an earlier episode was left part-way.
        let withLeftover = Make.progressMap(
            Make.progress("s2e2", completed: true, at: 4),
            Make.progress("s1e2", at: 1))
        let shelf = Shelves.continueWatching(in: Self.catalogue, progress: withLeftover)
        #expect(shelf.map(\.item.id) == ["s1e2"])
        #expect(shelf[0].reason == .resume)
    }

    @Test func aFinishedSpecialLeadsOnlyToTheNextSpecial() {
        let first = Make.progressMap(Make.progress("special-1", completed: true, at: 4))
        #expect(Shelves.continueWatching(in: Self.catalogue, progress: first).map(\.item.id) == ["special-2"])

        let last = Make.progressMap(Make.progress("special-2", completed: true, at: 4))
        #expect(Shelves.continueWatching(in: Self.catalogue, progress: last).isEmpty)
    }

    @Test func filmsAndShowsShareOneShelfByWhenTheyWereLastWatched() {
        let progress = Make.progressMap(
            Make.progress("up", at: 5),
            Make.progress("s1e1", completed: true, at: 8),
            Make.progress("andor-1", at: 2))

        let shelf = Shelves.continueWatching(in: Self.catalogue, progress: progress)

        #expect(shelf.map(\.id) == ["bluey", "up", "andor"])
        #expect(shelf.map(\.item.id) == ["s1e2", "up", "andor-1"])
    }

    @Test func eachViewerHasTheirOwnShelf() {
        let yeva = Make.progressMap(Make.progress("up", at: 5))
        let alex = Make.progressMap(Make.progress("andor-1", completed: true, at: 5))

        #expect(Shelves.continueWatching(in: Self.catalogue, progress: yeva).map(\.item.id) == ["up"])
        #expect(Shelves.continueWatching(in: Self.catalogue, progress: alex).map(\.item.id) == ["andor-2"])
        #expect(Shelves.continueWatching(in: Self.catalogue, progress: [:]).isEmpty)
    }

    // MARK: Recently Added

    @Test func recentlyAddedGroupsEpisodesIntoOneCardPerSeason() throws {
        let shelf = Shelves.recentlyAdded(in: Self.catalogue)

        // Andor's season is dated by its newest episode (60), before Up (50).
        #expect(shelf.prefix(4).map(\.id) == ["andor-s1", "up", "gozo", "amelie"])
        guard case .season(let season, let show, let episodeCount, let addedAt) = try #require(shelf.first) else {
            Issue.record("Expected a season card first")
            return
        }
        #expect(season.id == "andor-s1")
        #expect(show?.id == "andor")
        #expect(episodeCount == 2)
        #expect(addedAt == Make.date(60))

        // One card per season, none for episodes, shows or extras.
        #expect(Set(shelf.map(\.id)) == ["andor-s1", "s0", "s1", "s2", "up", "jungle", "amelie", "toy10", "toy2", "gozo"])
        #expect(Shelves.recentlyAdded(in: Self.catalogue, limit: 2).map(\.id) == ["andor-s1", "up"])
    }

    // MARK: Sections

    @Test func moviesAndSeriesAreInSortTitleOrder() {
        // "The Jungle Book" files under J, and 2 comes before 10.
        #expect(Shelves.movies(in: Self.catalogue).map(\.id) == ["amelie", "jungle", "toy2", "toy10", "up"])
        #expect(Shelves.series(in: Self.catalogue).map(\.id) == ["andor", "bluey"])
    }

    @Test func categoriesComeFromFoldersAndGenres() {
        let shelves = Shelves.categories(in: Self.catalogue)

        #expect(shelves.map(\.id) == ["folder:Disney", "folder:Pixar", "folder:Series", "genre:Animation", "genre:Comedy", "genre:Drama", "genre:Family"])
        #expect(shelves[1].items.map(\.id) == ["toy2", "toy10", "up"])
        #expect(shelves[2].items.map(\.id) == ["andor"])
        #expect(shelves[3].items.map(\.id) == ["jungle", "up"])
    }

    // MARK: Search

    @Test func searchesTitlesIgnoringCaseAndAccents() {
        #expect(Shelves.search("amelie", in: Self.catalogue).map(\.id) == ["amelie"])
        #expect(Shelves.search("  TOY  story ", in: Self.catalogue).map(\.id) == ["toy2", "toy10"])
        #expect(Shelves.search("book jungle", in: Self.catalogue).map(\.id) == ["jungle"])
        #expect(Shelves.search("zzz", in: Self.catalogue).isEmpty)
        #expect(Shelves.search("   ", in: Self.catalogue).isEmpty)
    }

    @Test func searchPutsTitlesThatStartWithTheQueryFirst() {
        let catalogue = Catalogue(items: [
            Make.movie("a", title: "Finding Up"),
            Make.movie("b", title: "Up"),
            Make.movie("c", title: "Supper"),
        ])
        #expect(Shelves.search("up", in: catalogue).map(\.id) == ["b", "a", "c"])
    }

    @Test func searchFindsEpisodesOnlyWhenAsked() {
        #expect(Shelves.search("kassa", in: Self.catalogue).isEmpty)
        #expect(Shelves.search("kassa", in: Self.catalogue, kinds: [.episode]).map(\.id) == ["andor-1"])
        #expect(Shelves.search("bluey", in: Self.catalogue).map(\.id) == ["bluey"])
    }
}

@Suite struct PlaybackPlannerTests {
    let modern = DeviceCapabilities(hardwareAV1Decode: true)
    let older = DeviceCapabilities(hardwareAV1Decode: false)

    @Test func aPictureTheServerConvertsPlaysAfterPreparing() {
        var file = Make.file(playability: .transcode, container: "avi", video: "mpeg4")
        file.convertible = true
        #expect(PlaybackPlanner.decide(for: file, capabilities: DeviceCapabilities(hardwareAV1Decode: false)) == .needsPreparedPlayback)
        file.convertible = nil
        #expect(PlaybackPlanner.decide(for: file, capabilities: DeviceCapabilities(hardwareAV1Decode: false)) != .needsPreparedPlayback)
    }

    @Test func followsTheServersJudgement() {
        #expect(PlaybackPlanner.decide(for: Make.file(playability: .direct), capabilities: older) == .direct)
        #expect(PlaybackPlanner.decide(for: Make.file(playability: .remux, container: "mkv"), capabilities: older) == .needsPreparedPlayback)
        #expect(
            PlaybackPlanner.decide(for: Make.file(playability: .transcode, container: "avi", video: "mpeg4", reason: "The video is MPEG4, which Apple devices do not play."), capabilities: modern)
                == .notPlayable(.needsTranscode(message: "The video is MPEG4, which Apple devices do not play.")))
        #expect(
            PlaybackPlanner.decide(for: Make.file(playability: .unsupported, video: nil, reason: "The file has no video track."), capabilities: modern)
                == .notPlayable(.unsupported(message: "The file has no video track.")))
    }

    @Test func av1PlaysOnlyWhereItIsDecodedInHardware() {
        let mp4 = Make.file(playability: .transcode, container: "mp4", video: "av1", reason: "The video is AV1, which Apple devices do not play.")
        #expect(PlaybackPlanner.decide(for: mp4, capabilities: modern) == .direct)
        #expect(PlaybackPlanner.decide(for: mp4, capabilities: older) == .notPlayable(.needsTranscode(message: "The video is AV1, which Apple devices do not play.")))

        // The picture decodes, the container or the sound still needs repackaging.
        let mkv = Make.file(playability: .transcode, container: "mkv", video: "av1")
        #expect(PlaybackPlanner.decide(for: mkv, capabilities: modern) == .needsPreparedPlayback)
        let dts = Make.file(playability: .transcode, container: "mp4", video: "av1", audio: ["dts"])
        #expect(PlaybackPlanner.decide(for: dts, capabilities: modern) == .needsPreparedPlayback)
        let silent = Make.file(playability: .transcode, container: "mp4", video: "av1", audio: [])
        #expect(PlaybackPlanner.decide(for: silent, capabilities: modern) == .direct)
    }

    @Test func aFileOnAMissingDriveOrOfAnUnknownKindIsNotPlayable() {
        #expect(PlaybackPlanner.decide(for: Make.file(playability: .direct, available: false), capabilities: modern) == .notPlayable(.unavailable))

        let future = Make.file(playability: .unknown("cloud"), reason: "Ask the server.")
        let decision = PlaybackPlanner.decide(for: future, capabilities: modern)
        #expect(decision == .notPlayable(.unknownPlayability("cloud", message: "Ask the server.")))
        if case .notPlayable(let reason) = decision {
            #expect(reason.serverMessage == "Ask the server.")
        }
    }

    @Test func readsThisDevicesCapabilities() {
        // Whatever this Mac answers, asking must work on every platform the package builds for.
        _ = DeviceCapabilities.current()
    }
}
