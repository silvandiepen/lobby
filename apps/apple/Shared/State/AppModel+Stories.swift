// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

// Stories: the household's audiobooks, for a child who listens and beside the films they were
// made from (docs/decisions.md, "Stories").
extension AppModel {
    /// The places on the kids bar: Stories while the child may listen now.
    var kidsSections: [KidsSection] {
        KidsSection.places(listens: music.isAvailable)
    }

    /// Stories and the films of the same name that this viewer has. A child's are only what
    /// it may see.
    var storyFilms: StoryFilms {
        guard music.isAvailable, !music.catalogue.books.isEmpty else { return StoryFilms(books: [], films: []) }
        let films = (showsKidsScreens ? kidsLibrary.catalogue : catalogue).items(ofKind: .movie)
        return StoryFilms(books: music.catalogue.books.values, films: films)
    }

    /// The film of a story, where it may be opened: for a child only while it may look at
    /// films at all.
    func film(ofStory book: MusicBook) -> Item? {
        if showsKidsScreens, !kidsControl.screen.showsFilms { return nil }
        return storyFilms.film(ofBook: book.id)
    }

    /// The story of a film, while the viewer may listen.
    func story(ofFilm item: Item) -> MusicBook? {
        guard item.kind == .movie else { return nil }
        return storyFilms.story(ofFilm: item.id)
    }

    /// Where this viewer is in a story, with the player's own place while it plays.
    func storyPlace(_ book: MusicBook) -> StoryPlace {
        let player = music.player
        let playing = player.book?.id == book.id ? player.bookPositionMs : nil
        return StoryPlace(book: book, progress: music.bookProgress[book.id], playingMs: playing)
    }

    /// Plays a story from where this viewer was, and shows the player.
    func listen(to book: MusicBook) {
        let player = music.player
        if player.book?.id == book.id {
            if !player.isPlaying { player.resume() }
        } else {
            player.play(book: book)
        }
        player.showsNowPlaying = true
    }

    /// Plays an album from its start, and shows the player.
    func listen(to album: MusicAlbum) {
        music.play(album: album)
        music.player.showsNowPlaying = true
    }

    /// The stories this viewer began, the latest first.
    var continueListening: [MusicBook] {
        music.isAvailable ? music.catalogue.continueListening(music.bookProgress) : []
    }
}
