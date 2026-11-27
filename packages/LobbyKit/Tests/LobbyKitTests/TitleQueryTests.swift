// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing

@testable import LobbyKit

/// The same library as apps/server/test/query.test.ts: both must answer the same.
@Suite struct TitleQueryTests {
    static let now = Make.epoch.addingTimeInterval(400 * 86_400)

    static func film(
        _ id: String, year: Int?, minutes: Int, width: Int = 1920, languages: [String] = ["eng"], daysAgo: Int = 400,
        genres: [String] = [], studios: [ItemStudio] = [], rating: Double? = nil, renown: Double? = nil,
        categories: [String] = [], rules: [String] = []
    ) -> Item {
        Item(
            id: id, kind: .movie, title: id, year: year, genres: genres, categoryIds: categories, ruleCategoryIds: rules,
            studios: studios, renown: renown, rating: rating, addedAt: now.addingTimeInterval(-Double(daysAgo) * 86_400),
            files: [file(id, minutes: minutes, width: width, languages: languages)])
    }

    static func file(_ id: String, minutes: Int, width: Int = 1920, languages: [String] = ["eng"]) -> MediaFile {
        MediaFile(
            assetId: "a-\(id)", sizeBytes: 1, durationMs: minutes * 60_000, container: "mp4", revision: "1", playability: .direct,
            video: VideoTrack(codec: "h264", width: width, height: width * 9 / 16, bitDepth: 8),
            audio: languages.enumerated().map {
                AudioTrack(index: $0.offset + 1, codec: "aac", language: $0.element, title: nil, channels: 2, isDefault: $0.offset == 0)
            })
    }

    static func episode(_ id: String, minutes: Int, daysAgo: Int) -> Item {
        Item(
            id: id, kind: .episode, parentId: "bluey-1", title: id, seasonNumber: 1, episodeNumber: id == "e1" ? 1 : 2,
            addedAt: now.addingTimeInterval(-Double(daysAgo) * 86_400), files: [file(id, minutes: minutes)])
    }

    static let pixar = ItemStudio(id: "company:3", name: "Pixar")
    static let legendary = ItemStudio(id: "company:923", name: "Legendary")

    static let catalogue = Catalogue(items: [
        film("Up", year: 2009, minutes: 96, daysAgo: 3, genres: ["Animation", "Adventure"], studios: [pixar], rating: 8, renown: 0.9, categories: ["pixar"]),
        film("Heat", year: 1995, minutes: 170, width: 3840, languages: ["eng", "fre"], genres: ["Crime", "Thriller"], rating: 8.3, renown: 0.7),
        film("Piper", year: 2016, minutes: 6, daysAgo: 20, genres: ["Animation"], studios: [pixar]),
        film("Dune", year: 2021, minutes: 155, width: 3840, daysAgo: 200, genres: ["Science Fiction", "Adventure"], studios: [legendary], rating: 7.8, renown: 0.8, rules: ["big"]),
        film("Metropolis", year: nil, minutes: 120, languages: ["ger"]),
        Item(id: "Bluey", kind: .show, title: "Bluey", addedAt: now.addingTimeInterval(-2 * 86_400)),
        Item(id: "bluey-1", kind: .season, parentId: "Bluey", title: "Season 1", seasonNumber: 1, addedAt: now),
        episode("e1", minutes: 7, daysAgo: 10),
        episode("e2", minutes: 8, daysAgo: 2),
    ])

    static let context = TitleQueryContext(
        catalogue: catalogue, categoryParents: ["pixar": "studios"], downloaded: ["e2", "Piper"], now: now)

    func titles(_ filter: TitleFilter = .none, sort: TitleSort = .byTitle, context: TitleQueryContext = context) -> [String] {
        TitleQuery.apply(filter, sort: sort, to: Self.catalogue.items, context: context).map(\.title)
    }

    func filter(_ change: (inout TitleFilter) -> Void) -> TitleFilter {
        var filter = TitleFilter()
        change(&filter)
        return filter
    }

    @Test func listsEveryTitleByTitleWithoutAny() {
        #expect(titles() == ["Bluey", "Dune", "Heat", "Metropolis", "Piper", "Up"])
    }

    @Test func narrowsByKindYearGenreAndStudio() {
        #expect(titles(filter { $0.kinds = [.show] }) == ["Bluey"])
        #expect(titles(filter { $0.kinds = [.movie]; $0.yearFrom = 2000; $0.yearTo = 2016 }) == ["Piper", "Up"])
        #expect(titles(filter { $0.setDecade(1990) }) == ["Heat"])
        #expect(filter { $0.setDecade(1990) }.decade == 1990)
        #expect(!titles(filter { $0.yearTo = 2100 }).contains("Metropolis"))
        #expect(titles(filter { $0.genres = ["animation", "Crime"] }) == ["Heat", "Piper", "Up"])
        #expect(titles(filter { $0.genres = ["Adventure"]; $0.yearFrom = 2015 }) == ["Dune"])
        #expect(titles(filter { $0.studios = ["company:3"] }) == ["Piper", "Up"])
    }

    @Test func narrowsByLengthWhenItCameQualityLanguageAndWhatIsHere() {
        #expect(titles(filter { $0.lengths = [.short] }) == ["Bluey", "Piper"])
        #expect(titles(filter { $0.lengths = [.long] }) == ["Dune", "Heat"])
        #expect(titles(filter { $0.lengths = [.standard] }) == ["Metropolis", "Up"])
        #expect(titles(filter { $0.added = .week }) == ["Bluey", "Up"])
        #expect(titles(filter { $0.added = .month }) == ["Bluey", "Piper", "Up"])
        #expect(titles(filter { $0.added = .year }) == ["Bluey", "Dune", "Piper", "Up"])
        #expect(titles(filter { $0.quality = [.uhd] }) == ["Dune", "Heat"])
        #expect(titles(filter { $0.languages = ["FRE", "ger"] }) == ["Heat", "Metropolis"])
        // A series is here when an episode is.
        #expect(titles(filter { $0.downloaded = true }) == ["Bluey", "Piper"])
    }

    @Test func narrowsByWhatTheViewerWatched() {
        var context = Self.context
        context.progress = Make.progressMap(
            Make.progress("Up", position: 6_000_000, completed: true, at: 1),
            Make.progress("Heat", position: 1_200_000, at: 1),
            Make.progress("e1", position: 420_000, completed: true, at: 1))
        #expect(titles(filter { $0.watch = [.watched] }, context: context) == ["Up"])
        #expect(titles(filter { $0.watch = [.inProgress] }, context: context) == ["Bluey", "Heat"])
        #expect(titles(filter { $0.watch = [.unwatched] }, context: context) == ["Dune", "Metropolis", "Piper"])
        context.progress = Make.progressMap(
            Make.progress("e1", position: 420_000, completed: true, at: 1),
            Make.progress("e2", position: 480_000, completed: true, at: 1))
        #expect(titles(filter { $0.watch = [.watched] }, context: context) == ["Bluey"])
    }

    @Test func narrowsByCategoryWithThoseInsideItAndByStudioRule() {
        #expect(titles(filter { $0.categories = ["pixar"] }) == ["Up"])
        #expect(titles(filter { $0.categories = ["studios"] }) == ["Up"])
        #expect(titles(filter { $0.categories = ["big", "pixar"] }) == ["Dune", "Up"])
    }

    @Test func ordersWithWhatIsNotKnownLastEitherWay() {
        #expect(titles(sort: TitleSort(.year)) == ["Dune", "Piper", "Up", "Heat", "Bluey", "Metropolis"])
        #expect(titles(sort: TitleSort(.year, ascending: true)) == ["Heat", "Up", "Piper", "Dune", "Bluey", "Metropolis"])
        #expect(titles(sort: TitleSort(.added)) == ["Bluey", "Up", "Piper", "Dune", "Heat", "Metropolis"])
        let films = filter { $0.kinds = [.movie] }
        #expect(titles(films, sort: TitleSort(.length)) == ["Piper", "Up", "Metropolis", "Dune", "Heat"])
        #expect(titles(films, sort: TitleSort(.rating)) == ["Heat", "Up", "Dune", "Metropolis", "Piper"])
        #expect(titles(films, sort: TitleSort(.title, ascending: false)) == ["Up", "Piper", "Metropolis", "Heat", "Dune"])
    }

    @Test func ordersByWhatTheHouseholdWatchesThenByHowWellKnown() {
        var context = Self.context
        context.popular = ["Metropolis"]
        let order = titles(filter { $0.kinds = [.movie] }, sort: TitleSort(.popular), context: context)
        #expect(order == ["Metropolis", "Up", "Dune", "Heat", "Piper"])
    }

    @Test func offersOnlyWhatIsInTheList() {
        let options = TitleQuery.options(of: Self.catalogue.items, context: Self.context)
        #expect(options.kinds == [.movie, .show])
        #expect(options.decades == [1990, 2000, 2010, 2020])
        #expect(options.years == 1995...2021)
        #expect(options.genres.first == "Adventure" || options.genres.first == "Animation")
        #expect(options.studios.map(\.id) == ["company:3", "company:923"])
        #expect(options.languages.first == "eng")
        #expect(options.lengths == [.short, .standard, .long])
        #expect(options.hasUHD && options.hasDownloads)
    }

    @Test func asksTheServerTheSameAndKeepsDownloadsToItself() {
        let items = filter {
            $0.kinds = [.movie]; $0.setDecade(1990); $0.watch = [.unwatched]; $0.genres = ["Drama", "Comedy"]; $0.downloaded = true
        }.queryItems(profileID: "one")
        #expect(items.map { "\($0.name)=\($0.value ?? "")" } == [
            "kind=movie", "yearFrom=1990", "yearTo=1999", "genre=Comedy", "genre=Drama", "watch=unwatched", "profile=one",
        ])
    }

    @Test func remembersAChoicePerListAndViewer() {
        let store = TitleChoiceStore(suiteName: "TitleQueryTests.\(UUID().uuidString)")
        let choice = TitleChoice(filter: filter { $0.lengths = [.short] }, sort: TitleSort(.added))
        store.save(choice, for: "movies", viewer: "one")
        #expect(store.choice(for: "movies", viewer: "one") == choice)
        #expect(store.choice(for: "movies", viewer: "two") == nil)
        #expect(store.choice(for: "series", viewer: "one") == nil)
        store.save(TitleChoice(), for: "movies", viewer: "one")
        #expect(store.choice(for: "movies", viewer: "one") == nil)
    }

    @Test func decodesStudiosAndRatingAndLivesWithoutThem() throws {
        let json = Fixtures.item(id: "m1")
        let old = try LobbyJSON.decoder().decode(Item.self, from: Data(json.utf8))
        #expect(old.studios == nil && old.rating == nil)
        let newer = json.replacingOccurrences(
            of: #""addedAt""#, with: #""studios": [{ "id": "company:3", "name": "Pixar" }], "rating": 7.9, "addedAt""#)
        let item = try LobbyJSON.decoder().decode(Item.self, from: Data(newer.utf8))
        #expect(item.studios == [ItemStudio(id: "company:3", name: "Pixar")])
        #expect(item.rating == 7.9)
    }

    @Test func answersThreeThousandTitlesQuickly() {
        let genres = ["Drama", "Comedy", "Action", "Animation", "Horror", "Family"]
        let items = (0..<3_000).map { index in
            Self.film(
                "t\(index)", year: 1950 + index % 75, minutes: 20 + index % 160, width: index % 7 == 0 ? 3840 : 1920,
                languages: index % 3 == 0 ? ["eng", "fre"] : ["eng"], daysAgo: index % 500, genres: [genres[index % 6]],
                rating: index % 4 == 0 ? 5 + Double(index % 50) / 10 : nil)
        }
        let catalogue = Catalogue(items: items)
        let context = TitleQueryContext(catalogue: catalogue, now: Self.now)
        let filter = filter { $0.kinds = [.movie]; $0.yearFrom = 1980; $0.yearTo = 2009; $0.genres = ["Drama", "Comedy"]; $0.lengths = [.standard] }
        let clock = ContinuousClock()
        var count = 0
        let took = clock.measure {
            count = TitleQuery.apply(filter, sort: TitleSort(.rating), to: items, context: context).count
        }
        #expect(count > 50)
        #expect(took < .milliseconds(500))
    }
}
