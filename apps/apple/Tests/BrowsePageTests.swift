// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

/// What Home and the other pages show, and what their banner may hold.
@Suite struct BrowsePageTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func film(
        _ id: String, daysAgo: Double, width: Int? = 1920, genres: [String] = [], categories: [String] = [], renown: Double? = nil,
        file: MediaFile? = nil, status: MatchStatus = .matched
    ) -> Item {
        var item = Make.movie(id, title: "Title \(id)", year: 2001)
        item.addedAt = now.addingTimeInterval(-daysAgo * 86_400)
        item.artwork = ArtworkSet(
            poster: Artwork(id: "\(id)-p"), backdrop: width.map { Artwork(id: "\(id)-b", width: $0, height: $0 * 9 / 16) })
        item.genres = genres
        item.categories = categories
        item.categoryIds = categories
        item.renown = renown
        item.matchStatus = status
        for index in item.files.indices { item.files[index].assetId = "asset-\(id)" }
        if let file { item.files = [file] }
        return item
    }

    private func context(local: [String] = [], outOfReach: Bool = false) -> PlaybackContext {
        PlaybackContext(
            capabilities: .init(hardwareAV1Decode: false), localCopies: Dictionary(uniqueKeysWithValues: local.map { ($0, .init(assetID: "asset-\($0)", isOutOfDate: false)) }),
            serverIsOutOfReach: outOfReach)
    }

    private func builder(
        _ items: [Item], progress: [String: PlaybackProgress] = [:], groups: CategoryGroups = .none, context: PlaybackContext? = nil,
        popular: Popular = .none, viewers: [[String: PlaybackProgress]] = []
    ) -> BrowseBuilder {
        let catalogue = Catalogue(items: items), context = context ?? self.context()
        return BrowseBuilder(
            catalogue: catalogue, shelves: LibraryShelves(catalogue: catalogue, groups: groups, progress: progress, context: context),
            progress: progress, context: context, popular: popular, viewers: viewers, now: now)
    }

    private func started(_ id: String, at position: Int = 600_000, completed: Bool = false, updated: Double = 0) -> PlaybackProgress {
        PlaybackProgress(
            itemId: id, positionMs: position, durationMs: 6_000_000, completed: completed, revision: 1,
            updatedAt: now.addingTimeInterval(updated))
    }

    // MARK: Banner

    @Test func theBannerHasTheNewestAndWhatTheViewerIsIn() {
        let items = (0..<9).map { film("f\($0)", daysAgo: Double($0)) }
        let slides = builder(items, progress: ["f7": started("f7")]).page(.home).banner
        #expect(slides.map(\.id) == ["f0", "f7", "f1", "f2"])
        #expect(slides.map(\.kicker) == ["Latest added", "Continue watching", "Latest added", "Latest added"])
        #expect(slides[1].playLabel == "Resume" && slides[1].request.startPositionMs == 600_000)
        #expect(slides[0].playLabel == "Play" && slides[0].fraction == nil)
    }

    @Test func nothingThatCannotPlayOrHasNoLargePictureIsInTheBanner() {
        let small = film("small", daysAgo: 0, width: 780), none = film("none", daysAgo: 0, width: nil)
        var broken = film("broken", daysAgo: 0)
        broken.files = []
        // A frame the server only made larger: the file itself is small.
        var frame = film("frame", daysAgo: 0, width: 1280, status: .unmatched)
        frame.files = frame.files.map { file in
            var file = file
            file.video?.width = 640
            return file
        }
        let good = [film("a", daysAgo: 3), film("b", daysAgo: 4)]
        #expect(builder([small, none, broken, frame] + good).page(.home).banner.map(\.id) == ["a", "b"])
    }

    @Test func withoutTheServerTheBannerAndTheRowsAreWhatIsOnTheDevice() {
        let items = (0..<8).map { film("f\($0)", daysAgo: Double($0)) }
        let here = ["f2", "f5", "f6"]
        let limited = Array(Catalogue(items: items).limited(to: Set(here)).items)
        let page = builder(limited, context: context(local: here, outOfReach: true)).page(.home)
        #expect(Set(page.banner.map(\.id)) == Set(here))
        #expect(page.banner.allSatisfy { $0.request.source == .local })
        #expect(Set(page.rows.flatMap(\.titleIDs)).isSubset(of: Set(here)))
        // Even when somebody hands it more than is here.
        #expect(Set(builder(items, context: context(local: here, outOfReach: true)).page(.home).banner.map(\.id)) == Set(here))
    }

    @Test func aFinishedFilmIsShownOnlyWhenThereIsNothingElse() {
        let items = (0..<6).map { film("f\($0)", daysAgo: Double($0)) }
        let slides = builder(items, progress: ["f0": started("f0", completed: true)]).page(.home).banner
        #expect(!slides.map(\.id).contains("f0") && slides.count >= 2)
    }

    @Test func anotherPagesBannerIsNotTheSameOneAgain() {
        let items = (0..<8).map { film("f\($0)", daysAgo: Double($0)) }
        let built = builder(items)
        let home = Set(built.page(.home).banner.map(\.id))
        let movies = built.page(.movies, avoiding: home).banner.map(\.id)
        #expect(movies.count >= 2 && home.isDisjoint(with: movies))
        // With too little to choose from they come back.
        let few = builder(Array(items.prefix(2)))
        #expect(few.page(.movies, avoiding: ["f0", "f1"]).banner.count == 2)
    }

    @Test func aSeriesPlaysTheEpisodeTheViewerIsAt() throws {
        var items = Make.show("wild", title: "Wild", episodesPerSeason: [3])
        for index in items.indices where items[index].kind == .show {
            items[index].artwork.backdrop = Artwork(id: "wild-b", width: 1920)
        }
        let episodes = EpisodeOrder.episodes(ofShow: "wild", in: Catalogue(items: items))
        let first = try #require(builder(items).page(.home).banner.first)
        #expect(first.request.item.id == episodes[0].id && first.playLabel == "Play S1 E1")
        let next = try #require(builder(items, progress: [episodes[0].id: started(episodes[0].id, completed: true)]).page(.home).banner.first)
        #expect(next.request.item.id == episodes[1].id && next.id == "wild")
    }

    // MARK: Rows

    @Test func popularIsPlaysFirstAndThenTheWellKnown() throws {
        let items = (0..<8).map { film("f\($0)", daysAgo: Double($0), renown: $0 > 3 ? Double($0) / 10 : nil) }
        let popular = Popular(titles: [.init(itemId: "f3", plays: 9), .init(itemId: "gone", plays: 5), .init(itemId: "f1", plays: 2)])
        let row = try #require(builder(items, popular: popular).page(.home).rows.first { $0.id == "popular" })
        #expect(Set(row.titleIDs) == ["f3", "f1", "f7", "f6", "f5", "f4"])
        #expect(row.title == "Popular at Home" && row.note == "And well-known titles")
        let known = try #require(builder(items).page(.home).rows.first { $0.id == "popular" })
        #expect(known.title == "Popular" && known.note == nil)
        // An older server, and nothing watched: no number is made up.
        #expect(!builder((0..<8).map { film("f\($0)", daysAgo: 1) }).page(.home).rows.contains { $0.id == "popular" })
    }

    @Test func withoutTheServersCountTheDevicesOwnViewersCount() {
        let items = (0..<6).map { film("f\($0)", daysAgo: Double($0)) }
        let catalogue = Catalogue(items: items)
        let one = ["f1": started("f1", completed: true), "f2": started("f2"), "f3": started("f3", updated: 5)]
        let other = ["f3": started("f3", completed: true), "f4": started("f4", updated: 9)]
        #expect(BrowseBuilder.played(by: [one, other], in: catalogue) == ["f3", "f1", "f4", "f2"])
        #expect(BrowseBuilder.played(by: [one], in: catalogue) == [], "Three titles say too little.")
    }

    @Test func rowsThatSayNothingAreLeftOut() {
        let few = builder([film("a", daysAgo: 1), film("b", daysAgo: 2)]).page(.home)
        #expect(few.rows.map(\.id) == ["recentlyAdded", "movies"])
        let items = (0..<14).map { film("f\($0)", daysAgo: Double($0), genres: $0 < 6 ? ["Mystery"] : $0 < 8 ? ["Comedy"] : []) }
        let rows = builder(items, progress: ["f1": started("f1", completed: true)]).page(.home).rows
        #expect(rows.map(\.id) == ["recentlyAdded", "notWatched", "genre.Mystery", "movies"])
        #expect(rows[1].titleIDs.contains("f1") == false)
    }

    @Test func noRowStartsLikeTheOneAboveIt() {
        let a = BrowseRow(id: "a", title: "A", content: .items((0..<8).map { film("f\($0)", daysAgo: 1) }))
        let b = BrowseRow(id: "b", title: "B", content: .items((0..<8).map { film("f\($0)", daysAgo: 1) }))
        let rows = BrowseBuilder.apart([a, b])
        #expect(Set(rows[0].titleIDs.prefix(4)).isDisjoint(with: rows[1].titleIDs.prefix(4)))
        #expect(Set(rows[1].titleIDs).count == 8)
        // A list by title stays by title.
        let list = BrowseRow(id: "movies", title: "Movies", content: b.content, seeAll: .movies)
        #expect(BrowseBuilder.apart([a, list])[1].titleIDs == b.titleIDs)
    }

    @Test func newEpisodesAreOfSeriesThatGrewLately() {
        var items = Make.show("old", title: "Old", episodesPerSeason: [3]) + Make.show("new", title: "New", episodesPerSeason: [3])
            + Make.show("third", title: "Third", episodesPerSeason: [3]) + Make.show("news", title: "News", episodesPerSeason: [3])
        for index in items.indices where items[index].kind == .show {
            let days: Double? = ["new": 2, "third": 5, "news": 1, "old": 400][items[index].id]
            items[index].newEpisodesAt = days.map { now.addingTimeInterval(-$0 * 86_400) }
        }
        let row = builder(items).page(.home).rows.first { $0.id == "newEpisodes" }
        #expect(row?.titleIDs.prefix(1) == ["news"])
        #expect(Set(row?.titleIDs ?? []) == ["news", "new", "third"])
    }

    @Test func aCategoryHasItsOwnBannerRowsAndAllOfIt() throws {
        let items = (0..<10).map { film("f\($0)", daysAgo: Double($0), categories: $0 < 9 ? ["Own"] : ["Other"]) }
        let built = builder(items)
        let id = try #require(built.shelves.categories.first { $0.name == "Own" }?.id)
        let page = built.page(.category(id))
        #expect(page.all.count == 9 && !page.all.contains { $0.id == "f9" })
        #expect(page.banner.allSatisfy { $0.place == "Own" && $0.id != "f9" })
        #expect(page.rows.map(\.title).contains("Latest in Own"))
        #expect(built.page(.category("gone")) == .empty)
    }

    // MARK: Kids

    @Test func aChildChoosesOnlyFromCategoriesWithinTheLimits() {
        let groups = CategoryGroups(groups: [
            CategoryGroup(id: "main", name: nil, entries: [
                LibraryCategory(id: "scary", name: "Scary"), LibraryCategory(id: "other", name: "Other"),
            ]),
            CategoryGroup(id: "kids", name: "Little", entries: [
                LibraryCategory(id: "two", name: "Two"), LibraryCategory(id: "one", name: "One"), LibraryCategory(id: "empty", name: "Empty"),
            ]),
        ])
        let limits = KidsSettings(allowedGroupIds: ["kids"])
        // "b" is allowed for being in One, and is in Scary too: Scary is not shown for it.
        let all = [
            film("a", daysAgo: 1, categories: ["two"]), film("b", daysAgo: 2, categories: ["one", "scary"]),
            film("c", daysAgo: 3, categories: ["scary"]), film("d", daysAgo: 4, categories: ["other"]),
        ]
        let allowed = Catalogue(items: all).limited(to: limits, groups: groups)
        let kids = KidsLibrary(catalogue: allowed, groups: groups, limits: limits, progress: [:], context: context())
        #expect(kids.categories.map(\.categoryID) == ["two", "one"], "The household's order, not the alphabet's.")
        #expect(kids.category("folder:scary") == nil)
        #expect(Set(kids.banner.map(\.id)) == ["a", "b"])
        #expect(kids.categoryBanners["folder:one"]?.map(\.id) == ["b"])
        // Offline only what is here, and one category is no choice.
        let here = KidsLibrary(
            catalogue: allowed.limited(to: ["a"]), groups: groups, limits: limits, progress: [:],
            context: context(local: ["a"], outOfReach: true))
        #expect(here.categories.isEmpty && here.banner.map(\.id) == ["a"])
        // A title allowed by itself brings its category.
        let single = KidsSettings(allowedGroupIds: ["kids"], allowedItemIds: ["c", "d"])
        let more = KidsLibrary(
            catalogue: Catalogue(items: all).limited(to: single, groups: groups), groups: groups, limits: single, progress: [:],
            context: context())
        #expect(Set(more.categories.map(\.categoryID)) == ["scary", "other", "two", "one"])
    }
}

/// Related on a title's page.
@Suite struct RelatedTitlesTests {
    private func film(_ id: String, _ title: String, year: Int = 2010, genres: [String] = [], categories: [String] = []) -> Item {
        var item = Make.movie(id, title: title, year: year, categories: categories)
        item.categoryIds = categories
        item.genres = genres
        return item
    }

    @Test func aFilmSeriesIsKnownByItsTitles() {
        #expect(RelatedTitles.familyKey("The Snow Ledger 2") == "snow ledger")
        #expect(RelatedTitles.familyKey("Snow Ledger: The Thaw") == "snow ledger")
        #expect(RelatedTitles.familyKey("Snow Ledger III") == "snow ledger")
        #expect(RelatedTitles.familyKey("Up") == nil)
    }

    @Test func theSeriesComesFirstThenWhatIsAlikeAndWhatWasSeenLast() {
        let item = film("one", "Snow Ledger", year: 2005, genres: ["Mystery"], categories: ["films"])
        let all = [
            item, film("two", "Snow Ledger 2", year: 2012), film("alike", "Nine Lamps", year: 2006, genres: ["Mystery"], categories: ["films"]),
            film("seen", "Paper Hills", year: 2005, genres: ["Mystery"], categories: ["films"]), film("other", "Orbit", year: 2022),
            film("dead", "Tin Roads", genres: ["Mystery"], categories: ["films"]),
        ]
        let ranked = RelatedTitles.rank(item, among: all, isPlayable: { $0.id != "dead" }, isWatched: { $0.id == "seen" })
        #expect(ranked.map(\.id) == ["two", "alike", "other", "seen", "dead"])
        #expect(!ranked.contains { $0.id == "one" })
    }

    @Test func whatTheServerNamesCountsWhenItIsThere() {
        var item = film("one", "Kettle", genres: ["Drama"])
        item.related = ["far"]
        let all = [item, film("far", "Moon"), film("near", "Spoon", genres: ["Drama"])]
        #expect(RelatedTitles.rank(item, among: all, isPlayable: { _ in true }, isWatched: { _ in false }).first?.id == "far")
    }
}
