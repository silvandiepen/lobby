// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import LobbyKit

struct SearchQueryTests {
    @Test func writesNothingForNothing() {
        #expect(SearchFilters.none.query(text: "  ") == "")
        #expect(!SearchFilters.none.asksAnything(text: ""))
        #expect(SearchFilters.none.query(text: " toy ") == "toy")
    }

    @Test func writesTheChipsAsTheServerReadsThem() {
        let filters = SearchFilters(
            yearFrom: 1990, yearTo: 1999, rating: .init(source: .rottenTomatoes, minimum: 80),
            people: [.init(name: "Tom Hanks", role: .cast), .init(name: "Nolan", role: .director)],
            genres: ["Science Fiction"], kind: .movie)
        #expect(
            filters.query(text: "story")
                == #"story kind:film year:1990..1999 rt>=80 actor:"Tom Hanks" director:Nolan genre:"Science Fiction""#)
        #expect(filters.count == 6)
    }

    @Test func writesOpenYearsAndDecimalRatings() {
        #expect(SearchFilters(yearFrom: 2000).tokens == ["year>=2000"])
        #expect(SearchFilters(yearTo: 1980).tokens == ["year<=1980"])
        #expect(SearchFilters(yearFrom: 1999, yearTo: 1990).tokens == ["year:1990..1999"])
        #expect(SearchFilters(yearFrom: 1994, yearTo: 1994).tokens == ["year:1994"])
        #expect(SearchFilters(rating: .init(source: .imdb, minimum: 7.5)).tokens == ["imdb>=7.5"])
        #expect(SearchFilters(rating: .init(source: .tmdb, minimum: 7)).tokens == ["tmdb>=7"])
    }

    @Test func makesAnExactTitle() {
        #expect(SearchFilters(exactTitle: true).query(text: "Toy Story") == #"title="Toy Story""#)
        #expect(SearchFilters(exactTitle: true).query(text: "Up") == "title=Up")
        #expect(SearchFilters(people: [.init(name: #"The "Rock""#)]).tokens == ["person:\"The Rock\""])
    }
}

struct RecentSearchesTests {
    @Test func keepsTheNewestFirstOnceAndAtMostTwelve() {
        var recent = RecentSearches()
        recent.add("toy")
        recent.add("Amélie")
        recent.add("TOY")
        #expect(recent.queries == ["TOY", "Amélie"])
        recent.add("amelie")
        #expect(recent.queries == ["amelie", "TOY"])
        recent.add(" ")
        recent.add("x")
        #expect(recent.queries.count == 2)
        for index in 0..<20 { recent.add("search \(index)") }
        #expect(recent.queries.count == RecentSearches.most)
        #expect(recent.queries.first == "search 19")
        recent.remove("search 19")
        #expect(recent.queries.first == "search 18")
    }

    @Test func keepsThemPerViewer() {
        let suite = "lobby.test.recent.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = RecentSearchStore(suiteName: suite)
        var one = RecentSearches()
        one.add("bluey")
        store.save(one, viewer: "a")
        #expect(store.load(viewer: "a").queries == ["bluey"])
        #expect(store.load(viewer: "b").queries.isEmpty)
        store.save(RecentSearches(), viewer: "a")
        #expect(store.load(viewer: "a").queries.isEmpty)
    }
}

struct SearchDecodingTests {
    @Test func readsTheServersAnswers() throws {
        let json = #"""
        {"query":"tom rt>80","text":"tom","understood":[{"key":"rottenTomatoes","label":"Rotten Tomatoes ≥ 81%","token":"rt>80"}],
         "unknownPeople":[],"ratingSources":["tmdb","imdb","rottenTomatoes","metacritic","someday"],
         "films":{"total":0,"items":[]},"series":{"total":0,"items":[]},"videos":{"total":0,"items":[]},
         "episodes":{"total":0,"items":[]},
         "people":{"total":1,"items":[{"id":31,"name":"Tom Hanks","picture":null,"titles":3,"roles":["cast","producer"]}]},
         "collections":{"total":0,"items":[]}}
        """#
        let answer = try LobbyJSON.decoder().decode(SearchAnswer.self, from: Data(json.utf8))
        #expect(answer.sources == [.tmdb, .imdb, .rottenTomatoes, .metacritic])
        #expect(answer.people.items.first?.roles == [.cast, .unknown("producer")])
        #expect(answer.understood.first?.token == "rt>80")
        #expect(!answer.isEmpty)

        let outside = #"""
        {"available":false,"reason":"no_key","films":[],"series":[],"people":[],"notApplied":[],"attribution":["This product uses the TMDB API but is not endorsed or certified by TMDB."]}
        """#
        let none = try LobbyJSON.decoder().decode(OutsideAnswer.self, from: Data(outside.utf8))
        #expect(none.reason == .noKey)
        #expect(none.isEmpty)

        let title = #"""
        {"available":true,"reason":null,"films":[{"tmdb":{"type":"movie","id":301528},"title":"Toy Story 4","originalTitle":"Toy Story 4",
          "year":2019,"overview":null,"poster":"/p.jpg","ratings":{"tmdb":7.4,"imdb":null,"rottenTomatoes":97,"metacritic":null},
          "votes":500,"imdbId":"tt1979376","links":{"tmdb":"https://www.themoviedb.org/movie/301528","imdb":"https://www.imdb.com/title/tt1979376/"},
          "itemId":null}],"series":[],"people":[],"notApplied":["rottenTomatoes"],"attribution":[]}
        """#
        let found = try LobbyJSON.decoder().decode(OutsideAnswer.self, from: Data(title.utf8))
        #expect(found.films.first?.links.imdb?.absoluteString == "https://www.imdb.com/title/tt1979376/")
        #expect(found.films.first?.ratings.known.map(\.source) == [.tmdb, .rottenTomatoes])
        #expect(RatingSource.rottenTomatoes.text(97) == "97%")
        #expect(RatingSource.imdb.text(8) == "8.0")
    }

    @Test func saysWhyATitleIsThere() {
        #expect(SearchMatch(field: .person, text: "Tom Hanks").reason == "With Tom Hanks")
        #expect(SearchMatch(field: .character, text: "Woody").reason == "As Woody")
        #expect(SearchMatch(field: .title).reason == nil)
    }

    @Test func buildsTheSearchURLs() throws {
        let client = try LobbyClient(baseURL: URL(string: "http://lobby.local:8484")!)
        #expect(client.searchPictureURL(path: "/abc.jpg").absoluteString == "http://lobby.local:8484/v1/search/picture?path=/abc.jpg")
    }
}
