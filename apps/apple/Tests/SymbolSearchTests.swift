// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

@Suite struct SymbolSearchTests {
    @Test func everySymbolOfTheListExistsHereAndIsListedOnce() {
        #expect(SymbolCatalog.entries.count > 350)
        let symbols = SymbolCatalog.entries.map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
        #expect(symbols.allSatisfy { AppSymbol.existing($0) != nil })
        #expect(SymbolCatalog.entries.allSatisfy { !$0.keywords.isEmpty })
        #expect(SymbolCatalog.groups.allSatisfy { !$0.entries.isEmpty })
    }

    @Test(arguments: [
        ("christmas", "snowflake"), ("kerst", "snowflake"), ("horse", "figure.equestrian.sports"), ("paarden", "figure.equestrian.sports"),
        ("boerderijdieren", "pawprint.fill"), ("pirate", "sailboat.fill"), ("piraten", "sailboat.fill"), ("tekenfilm", "paintpalette.fill"),
        ("tekenfilms", "paintpalette.fill"), ("cartoon", "paintpalette.fill"), ("voetbal", "soccerball"), ("koken", "fork.knife"),
        ("space", "moon.circle.fill"), ("ruimte", "moon.circle.fill"), ("detective", "magnifyingglass"), ("sprookje", "wand.and.stars"),
    ])
    func anEverydayWordFindsAFittingSymbol(word: String, symbol: String) {
        #expect(SymbolSearch.results(for: word).contains(symbol), "\(word)")
    }

    @Test func caseAccentsAndAnUnfinishedWordDoNotMatter() {
        #expect(SymbolSearch.results(for: "KNUFFEL").first == "teddybear.fill")
        #expect(SymbolSearch.results(for: "skien").contains("figure.skiing.downhill"))
        #expect(SymbolSearch.results(for: "skiën").contains("figure.skiing.downhill"))
        #expect(SymbolSearch.results(for: "dinos").contains("lizard.fill"))
        #expect(SymbolSearch.results(for: "foto's").contains("photo.stack.fill"))
    }

    @Test func everyTypedWordHasToFit() {
        let both = SymbolSearch.results(for: "winter sport")
        #expect(both.contains("figure.skiing.downhill"))
        #expect(!both.contains("snowflake"))
        #expect(!both.contains("soccerball"))
    }

    @Test func aSymbolsNameFindsItAlsoWhenItIsInNoGroup() {
        #expect(SymbolSearch.results(for: "star.fill").first == "star.fill")
        let other = "chevron.left.forwardslash.chevron.right"
        #expect(!SymbolCatalog.entries.map(\.symbol).contains(other))
        #expect(SymbolSearch.results(for: " \(other) ") == [other])
    }

    @Test func nothingFoundIsEmptyAndNothingTypedToo() {
        #expect(SymbolSearch.results(for: "qwxzq").isEmpty)
        #expect(SymbolSearch.results(for: "  ").isEmpty)
        #expect(SymbolSearch.results(for: "...").isEmpty)
    }

    @Test func suggestionsFollowTheNameAsItIsTyped() {
        #expect(SymbolSearch.suggestions(forName: "").isEmpty)
        #expect(SymbolSearch.suggestions(forName: "Horror Nights").first == "moon.haze.fill")
        #expect(SymbolSearch.suggestions(forName: "Kerstfilms").contains("snowflake"))
        #expect(SymbolSearch.suggestions(forName: "Muziek").first?.hasPrefix("music") == true)
        #expect(SymbolSearch.suggestions(forName: "De dieren van de boerderij").contains("pawprint.fill"))
        // A word that says nothing suggests nothing.
        #expect(SymbolSearch.suggestions(forName: "The of en de").isEmpty)
        #expect(SymbolSearch.suggestions(forName: "Horror Western Music Sport", limit: 5).count == 5)
    }

    @Test func aNameThatSaysNothingIsHelpedByTheGenresOfItsTitles() {
        #expect(SymbolSearch.suggestions(forName: "Qwxzq").isEmpty)
        let fromGenres = SymbolSearch.suggestions(forName: "Qwxzq", genres: ["Science Fiction", "Western"])
        #expect(fromGenres.contains("atom"))
        #expect(fromGenres.contains("hat.widebrim.fill"))
        // The name counts most.
        #expect(SymbolSearch.suggestions(forName: "Voetbal", genres: ["Documentary"]).first == "soccerball")
    }

    @Test func genresAreCountedCommonestFirst() {
        var one = Make.movie("one"), two = Make.movie("two"), three = Make.movie("three")
        one.genres = ["Drama", "Music"]
        two.genres = ["Music"]
        three.genres = ["Crime", "Music", "Drama"]
        #expect(SymbolSearch.genres(of: [one, two, three]) == ["Music", "Drama", "Crime"])
    }

    @Test func aSymbolIsSpokenByWhatItShows() {
        #expect(SymbolCatalog.spokenName(of: "pawprint.fill") == "animal, pawprint fill")
        #expect(SymbolCatalog.spokenName(of: "star.fill") == "star fill")
    }
}

@Suite struct SidebarCategoriesTests {
    private let films = (0..<20).map { Make.movie("film\($0)") }
    private let shows = (0..<10).map { Make.movie("show\($0)") }

    private func shelf(_ name: String, _ items: [Item], _ source: CategoryShelf.Source = .folder) -> CategoryShelf {
        CategoryShelf(name: name, source: source, items: items)
    }

    @Test func aCategoryThatIsTheListItselfIsNotListedTwiceWhateverItsName() {
        let sidebar = SidebarCategories(
            categories: [shelf("Bios", films), shelf("Avonden", Array(shows.dropLast())), shelf("Parels", Array(films.prefix(6)))],
            movies: films, series: shows)
        #expect(sidebar.own.map(\.name) == ["Parels"])
    }

    @Test func aTitleOrTwoInTheOtherFolderDoNotMakeItAnotherList() {
        let sidebar = SidebarCategories(categories: [shelf("Bios", films + shows.prefix(2))], movies: films, series: shows)
        #expect(sidebar.own.isEmpty)
        // Everything together is a list of its own.
        let all = SidebarCategories(categories: [shelf("Alles", films + shows)], movies: films, series: shows)
        #expect(all.own.map(\.name) == ["Alles"])
    }

    @Test func genresAreApartAndAlwaysStay() {
        let sidebar = SidebarCategories(categories: [shelf("Drama", films, .genre)], movies: films, series: shows)
        #expect(sidebar.own.isEmpty)
        #expect(sidebar.genres.map(\.name) == ["Drama"])
    }
}
