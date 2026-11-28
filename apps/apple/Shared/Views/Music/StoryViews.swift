// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

// Stories in the grown-ups' screens: rows on Home and on the music's front page, and the links
// between a story and the film of the same name (docs/decisions.md, "Stories").

/// The stories this viewer began: a tap goes on where they were.
struct ContinueListeningShelf: View {
    let width: CGFloat
    @Environment(AppModel.self) private var app

    var body: some View {
        let books = app.continueListening
        if !books.isEmpty {
            Shelf(title: "Continue Listening") {
                ForEach(books) { book in
                    Button {
                        app.listen(to: book)
                    } label: {
                        MusicTile(book: book, width: width, music: app.music)
                    }
                    .buttonStyle(.lobbyTile(opens: Route.musicBook(book.id)))
                    .accessibilityAddTraits(.startsMediaSession)
                    .accessibilityHint("Goes on where you were")
                    .contextMenu {
                        NavigationLink(value: Route.musicBook(book.id)) {
                            Label("Go to \(book.title)", systemImage: "info.circle")
                        }
                    }
                    .accessibilityIdentifier("continueListening.\(book.title)")
                }
            }
        }
    }
}

/// Home's row of the stories, to choose one.
struct StoryShelf: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    private let metrics = MusicShelfMetrics()

    var body: some View {
        let music = app.music
        let books = music.isAvailable ? music.catalogue.sortedBooks : []
        if !books.isEmpty {
            let width = metrics.cover(sizeClass) * 0.85
            Shelf(title: "Stories", seeAll: .music(.books)) {
                ForEach(books.prefix(24)) { book in
                    NavigationLink(value: Route.musicBook(book.id)) {
                        MusicTile(book: book, width: width, music: music)
                    }
                    .buttonStyle(.lobbyTile(opens: Route.musicBook(book.id)))
                    .accessibilityIdentifier("music.book.\(book.title)")
                }
            }
            .accessibilityIdentifier("shelf.stories")
        }
    }
}

/// On a film's page: its story, to listen to.
struct StoryCircle: View {
    let item: Item
    @Environment(AppModel.self) private var app

    var body: some View {
        if let book = app.story(ofFilm: item) {
            RoundAction(name: "Story") {
                NavigationLink(value: Route.musicBook(book.id)) {
                    RoundLabel(symbol: AppSymbol.stories)
                }
                .buttonStyle(.lobbyPill)
                .accessibilityLabel("Listen to the Story")
                .accessibilityHint("Opens \(book.title)")
                .accessibilityIdentifier("detail.story")
            }
        }
    }
}

/// On a story's page: the film of the same name.
struct StoryFilmLink: View {
    let book: MusicBook
    @Environment(AppModel.self) private var app

    var body: some View {
        if let film = app.film(ofStory: book) {
            NavigationLink(value: Route.item(film.id)) {
                Label("Watch the Film", systemImage: AppSymbol.movies)
            }
            .buttonStyle(QuietButtonStyle())
            .frame(maxWidth: AppTheme.readableWidth)
            .accessibilityIdentifier("story.film")
        }
    }
}
