// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

/// The search screen's model: what it asks, when it looks beyond the library, recent searches.
@MainActor
@Suite struct SearchModelTests {
    /// What was asked, in order.
    actor Asked {
        var library: [String] = []
        var outside: [String] = []
        var profiles: [String?] = []
        func note(library query: String, profile: String?) {
            library.append(query)
            profiles.append(profile)
        }
        func note(outside query: String) { outside.append(query) }
    }

    struct Refused: Error {}

    private func answer(_ query: String, films: [String] = []) throws -> SearchAnswer {
        let items = films.map { id in
            #"{"item":\#(String(decoding: try! LobbyJSON.encoder().encode(Make.movie(id, title: "Title \(id)", year: 2001)), as: UTF8.self)),"ratings":{"tmdb":7.5,"imdb":null,"rottenTomatoes":null,"metacritic":null},"match":{"field":"person","text":"Tom Hanks"}}"#
        }
        let json = #"""
        {"query":"\#(query.replacingOccurrences(of: "\"", with: "\\\""))","text":"","understood":[{"key":"year","label":"Year 1990–1999","token":"year:1990..1999"}],"unknownPeople":[],
         "ratingSources":["tmdb"],"films":{"total":\#(films.count),"items":[\#(items.joined(separator: ","))]},
         "series":{"total":0,"items":[]},"videos":{"total":0,"items":[]},"episodes":{"total":0,"items":[]},
         "people":{"total":0,"items":[]},"collections":{"total":0,"items":[]}}
        """#
        return try LobbyJSON.decoder().decode(SearchAnswer.self, from: Data(json.utf8))
    }

    private static let nothingOutside = try! LobbyJSON.decoder().decode(
        OutsideAnswer.self,
        from: Data(#"{"available":true,"reason":null,"films":[],"series":[],"people":[],"notApplied":[],"attribution":[]}"#.utf8))

    private func model(
        _ asked: Asked, viewer: String? = "dad", lookBeyond: Bool = true, fails: Bool = false, suite: String
    ) throws -> SearchModel {
        let found = try answer("", films: ["1"])
        let outside = Self.nothingOutside
        let asking = SearchModel.Asking(
            library: { query, profile in
                await asked.note(library: query, profile: profile)
                if fails { throw Refused() }
                return found
            },
            outside: { query, _ in
                await asked.note(outside: query)
                return outside
            },
            person: { _, _ in throw Refused() },
            title: { _, _ in throw Refused() })
        return SearchModel(asking: asking, store: RecentSearchStore(suiteName: suite), viewer: viewer, lookBeyond: lookBeyond)
    }

    private func suite() -> String { "lobby.test.search.\(UUID().uuidString)" }

    @Test func asksNothingForNothing() async throws {
        let asked = Asked()
        let model = try model(asked, suite: suite())
        await model.search(text: "   ")
        #expect(model.phase == .idle)
        #expect(await asked.library.isEmpty)
    }

    @Test func asksTheLibraryWithTheChipsThenWhatIsBeyond() async throws {
        let asked = Asked()
        let model = try model(asked, suite: suite())
        model.filters = SearchFilters(yearFrom: 1990, yearTo: 1999, people: [.init(name: "Tom Hanks", role: .cast)])
        await model.search(text: "toy")
        #expect(await asked.library == [#"toy year:1990..1999 actor:"Tom Hanks""#])
        #expect(await asked.profiles == ["dad"])
        #expect(model.phase == .done)
        #expect(model.answer?.films.items.map(\.id) == ["1"])
        #expect(model.answer?.films.items.first?.match?.reason == "With Tom Hanks")
        #expect(model.isCurrent(text: "toy"))
        #expect(!model.isCurrent(text: "toys"))
        #expect(await asked.outside == [#"toy year:1990..1999 actor:"Tom Hanks""#])
        #expect(model.outside != nil)
    }

    @Test func neverLooksBeyondTheLibraryInKidsMode() async throws {
        let asked = Asked()
        let model = try model(asked, viewer: "kid", lookBeyond: false, suite: suite())
        await model.search(text: "bluey")
        #expect(await asked.library == ["bluey"])
        #expect(await asked.outside.isEmpty)
        #expect(model.outside == nil)
    }

    @Test func fallsBackWhenTheServerCannotAnswer() async throws {
        let asked = Asked()
        let model = try model(asked, fails: true, suite: suite())
        await model.search(text: "toy")
        #expect(model.phase == .failed)
        #expect(model.answer == nil)
        #expect(await asked.outside.isEmpty)
    }

    @Test func keepsRecentSearchesPerViewer() throws {
        let name = suite()
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let model = try model(Asked(), suite: name)
        model.remember(text: "toy story")
        model.filters.kind = .movie
        model.remember(text: "hanks")
        #expect(model.recent.queries == ["hanks kind:film", "toy story"])
        model.setViewer("kid", lookBeyond: false)
        #expect(model.recent.queries.isEmpty)
        #expect(!model.lookBeyond)
        model.setViewer("dad", lookBeyond: true)
        #expect(model.recent.queries == ["hanks kind:film", "toy story"])
        model.forget("toy story")
        #expect(model.recent.queries == ["hanks kind:film"])
    }

    @Test func takesATypedFilterOutOfTheWords() throws {
        let model = try model(Asked(), suite: suite())
        let typed = UnderstoodFilter(key: "year", label: "Year 1990–1999", token: "year:1990..1999")
        #expect(model.removing(typed, from: "toy year:1990..1999 story") == "toy story")
        #expect(model.removing(typed, from: "toy") == "toy")
    }
}
