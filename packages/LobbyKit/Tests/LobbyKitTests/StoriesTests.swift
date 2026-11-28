// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing

@testable import LobbyKit

/// Stories: who reads them, which were begun, and the films of the same name.
@Suite struct StoriesTests {
    private func book(_ id: String, _ title: String, year: Int? = nil, authors: [String] = [], narrators: [String] = []) -> MusicBook {
        MusicBook(
            id: id, title: title, authors: authors, narrators: narrators, year: year, durationMs: 600_000,
            addedAt: Date(timeIntervalSince1970: 0), parts: [.init(trackId: "t-\(id)", startMs: 0, durationMs: 600_000)])
    }

    private func film(_ id: String, _ title: String, year: Int? = nil, kind: ItemKind = .movie) -> Item {
        Item(id: id, kind: kind, title: title, year: year, addedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func theReaderIsNotTheWriter() {
        // A read-along: the reader is in every name tag.
        let readAlong = book("b1", "The Brave Little Kettle", authors: ["Robin Reed"], narrators: ["robin reed"])
        #expect(readAlong.writers.isEmpty)
        #expect(readAlong.credit == "Read by robin reed")
        #expect(readAlong.readBy == "Read by robin reed")

        let novel = book("b2", "Harbour Lights", authors: ["Ada Penhallow"], narrators: ["Tom Wren"])
        #expect(novel.writers == ["Ada Penhallow"])
        #expect(novel.credit == "Ada Penhallow")
        #expect(novel.readBy == "Read by Tom Wren")

        let nobody = book("b3", "Dad tells one")
        #expect(nobody.credit == nil)
        #expect(nobody.readBy == nil)
    }

    @Test func continueListeningIsWhatWasBegunLatestFirst() {
        let catalogue = MusicCatalogue(books: [book("a", "A"), book("b", "B"), book("c", "C"), book("d", "D")])
        func progress(_ id: String, _ ms: Int, at seconds: TimeInterval, completed: Bool = false) -> PlaybackProgress {
            PlaybackProgress(itemId: id, positionMs: ms, durationMs: 600_000, completed: completed, revision: 1,
                             updatedAt: Date(timeIntervalSince1970: seconds))
        }
        let heard = [
            "a": progress("a", 10_000, at: 100),
            "b": progress("b", 20_000, at: 300),
            "c": progress("c", 600_000, at: 400, completed: true),
            "d": progress("d", 0, at: 500),
            // A book that is gone from the library.
            "gone": progress("gone", 5_000, at: 600),
        ]
        #expect(catalogue.continueListening(heard).map(\.id) == ["b", "a"])
        #expect(catalogue.continueListening(heard, limit: 1).map(\.id) == ["b"])
        #expect(catalogue.continueListening([:]).isEmpty)
    }

    @Test func titlesCompareByTheirWords() {
        #expect(TitleKey.of("The Lion King") == "lion king")
        #expect(TitleKey.of("lion king") == TitleKey.of("The Lion King"))
        #expect(TitleKey.of("Lilo & Stitch") == TitleKey.of("Lilo and Stitch"))
        #expect(TitleKey.of("Monsters, Inc.") == TitleKey.of("Monsters Inc"))
        #expect(TitleKey.of("Ariel’s Christmas") == TitleKey.of("Ariel's Christmas"))
        #expect(TitleKey.of("Amélie") == TitleKey.of("Amelie"))
        #expect(TitleKey.of("The Lion King II: Simba's Pride") == "lion king ii simbas pride")
        #expect(TitleKey.of("Up") != TitleKey.of("Cars"))
        #expect(TitleKey.of("Theodore") == "theodore")
        #expect(TitleKey.of("A") == "a")
    }

    @Test func storiesAndFilmsOfTheSameNameMeet() {
        let books = [
            book("s-kettle", "The Brave Little Kettle", year: 2009),
            book("s-moon", "Paper Moons", year: 2012),
            book("s-alone", "Nobody Filmed This"),
            book("s-lion", "The Lion King", year: 2009),
        ]
        let films = [
            film("f-kettle", "Brave Little Kettle", year: 1998),
            film("f-moon-show", "Paper Moons", kind: .show),
            film("f-lion-1", "The Lion King", year: 1994),
            film("f-lion-2", "The Lion King", year: 2019),
        ]
        let links = StoryFilms(books: books, films: films)
        #expect(links.film(ofBook: "s-kettle")?.id == "f-kettle")
        #expect(links.story(ofFilm: "f-kettle")?.id == "s-kettle")
        // A series of that name is not the film.
        #expect(links.film(ofBook: "s-moon") == nil)
        #expect(links.film(ofBook: "s-alone") == nil)
        // The film the story was made from: the latest before it, not the remake after it.
        #expect(links.film(ofBook: "s-lion")?.id == "f-lion-1")
        #expect(links.story(ofFilm: "f-lion-2") == nil)
        #expect(!links.isEmpty)

        // Without a year, the first.
        #expect(StoryFilms(books: [book("x", "The Lion King")], films: films).film(ofBook: "x")?.id == "f-lion-1")
        // A child who may not see the film has no link to it.
        #expect(StoryFilms(books: books, films: []).isEmpty)
    }
}
