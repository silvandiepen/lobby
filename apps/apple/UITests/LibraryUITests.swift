// SPDX-License-Identifier: MPL-2.0
import XCTest

final class LibraryUITests: LobbyUITestCase {
    /// The main path: pair with a code, pick a viewer, browse, play, stop, and find the film
    /// on Continue Watching for that viewer and not for the other.
    func testPairBrowsePlayAndResumePerViewer() async throws {
        let servers = try TestServers.load()
        launch()
        try await pair(with: servers)
        waitFor(app.buttons["profile.Kids"], "The other viewer")
        waitFor(app.buttons["profile.Alex"], "The viewer picker").tap()

        // Browse.
        waitFor(shelf("movies"), "The Movies shelf")
        XCTAssertTrue(element("shelf.series").exists)
        XCTAssertFalse(element("shelf.continueWatching").exists, "Nobody watched anything yet.")
        attachScreenshot("library")

        // A film Apple devices cannot decode, and the server converts: it plays, and a viewer
        // is not told how (only a server admin's page says so).
        let movies = shelf("movies")
        movies.buttons["Old Format, 2001"].tap()
        waitFor(app.buttons["detail.play"], "Play, of a film the server converts")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Lobby Server converts it")).firstMatch.exists)
        XCTAssertFalse(element("detail.unavailable").exists)
        app.navigationBars.buttons.firstMatch.tap()

        // Play a film for a while, then close the player.
        waitFor(movies.buttons["The Long Test, 2019"], "The film on its shelf").tap()
        XCTAssertEqual(waitFor(app.buttons["detail.play"], "Play").label, "Play")
        app.buttons["detail.play"].tap()
        try closePlayer(afterPlayingPast: 12)

        let resume = waitFor(app.buttons["detail.play"], "The film's page after closing the player")
        XCTAssertEqual(resume.label, "Resume")
        XCTAssertTrue(waitFor(element("detail.remaining"), "What is left").label.hasSuffix("left"))
        attachScreenshot("movie-resume")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(waitFor(element("shelf.continueWatching"), "Continue Watching for Alex").exists)

        // Its card plays at once. Closing that player leaves nothing of it behind: the card
        // plays again.
        let card = waitFor(app.scrollViews["shelf.continueWatching"].buttons.firstMatch, "The card that goes on")
        for seconds in [14, 16] {
            card.tap()
            try closePlayer(afterPlayingPast: seconds)
            waitFor(card, "The card after closing the player")
        }

        // Another viewer has their own Continue Watching.
        app.buttons["profile.menu"].tap()
        waitFor(viewerInMenu("Kids"), "Kids in the viewer menu").tap()
        waitFor(shelf("movies"), "The library for Kids")
        XCTAssertFalse(element("shelf.continueWatching").exists, "Kids did not watch anything.")

        // And Alex's is still there after closing and opening the app.
        app.buttons["profile.menu"].tap()
        waitFor(viewerInMenu("Alex"), "Alex in the viewer menu").tap()
        waitFor(element("shelf.continueWatching"), "Continue Watching back for Alex")
        app.terminate()
        launch(clean: false)
        waitFor(element("shelf.continueWatching"), "Continue Watching after relaunching")
    }

    func testAnEpisodePlaysToItsEndAndOffersTheNextOne() async throws {
        let servers = try TestServers.load()
        launch()
        try await pair(with: servers)
        // A viewer of this test's own: what is watched here stays out of the other tests.
        waitFor(app.buttons["profile.Guest"], "The viewer picker").tap()

        waitFor(shelf("series").buttons["Test Show"], "The show on its shelf").tap()
        XCTAssertEqual(waitFor(app.buttons["detail.play"], "The show's primary button").label, "Play S1 E1")
        // The episodes are under the Related row.
        scrolledTo(element("episode.2"), "The second episode")
        attachScreenshot("show")

        // The episodes are twelve seconds long. Play Next is offered, never started by itself.
        let play = app.buttons["detail.play"]
        for _ in 0..<6 where !play.isHittable { app.swipeDown(velocity: .slow) }
        play.tap()
        let playNext = waitFor(app.buttons["player.playNext"], "Play Next at the end of the episode", timeout: 40)
        XCTAssertEqual(playNext.value as? String, "S1 E2 · Second Thoughts")
        playNext.tap()
        try closePlayer(afterPlayingPast: 6)

        // Back on the show: the first episode is watched and the second is where the viewer is.
        XCTAssertEqual(waitFor(app.buttons["detail.play"], "The show's page").label, "Resume S1 E2")
        let first = scrolledTo(element("episode.1"), "The first episode")
        XCTAssertTrue(first.label.contains("Watched"), first.label)
    }

    /// An MKV cannot be opened by Apple's player. The server repackages it and the app plays
    /// that copy, after saying so on the film's page.
    func testAnMKVPlaysThroughTheServersRepackagedCopy() async throws {
        let servers = try TestServers.load()
        launch()
        try await pair(with: servers)
        // Guest, so that what is watched here stays off the shelves the other tests look at.
        waitFor(app.buttons["profile.Guest"], "The viewer picker").tap()

        waitFor(shelf("movies").buttons["Matroska Morning, 2015"], "The film on its shelf").tap()
        waitFor(app.buttons["detail.play"], "Play")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "The file is MKV")).firstMatch.exists)
        app.buttons["detail.play"].tap()
        try closePlayer(afterPlayingPast: 6)

        XCTAssertFalse(element("player.failed").exists)
        XCTAssertEqual(waitFor(app.buttons["detail.play"], "The film's page after closing the player").label, "Resume")
    }

    /// The household's own part of the library: its films are under "Kids", in its categories,
    /// and not among the main Movies.
    func testAGroupOfTheLibraryIsApartFromMoviesAndShowsItsCategories() async throws {
        let servers = try TestServers.load()
        launch()
        try await pair(with: servers)
        waitFor(app.buttons["profile.Alex"], "The viewer picker").tap()
        waitFor(shelf("movies"), "The library")

        // Movies in full: the four test films, and neither kids' film.
        app.buttons["See all Movies"].tap()
        waitFor(app.buttons["Short Notice, 2021"].firstMatch, "The Movies grid")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertFalse(app.buttons["Stripes, 2012"].exists, "A kids' film is on the main Movies page.")
        XCTAssertFalse(app.buttons["Paper Boats, 2010"].exists, "A kids' film is on the main Movies page.")
        app.navigationBars.buttons.firstMatch.tap()

        // Kids, with its categories as shelves.
        let seeKids = app.buttons["See all Kids"]
        for _ in 0..<4 where !seeKids.isHittable { app.swipeUp() }
        waitFor(seeKids, "See All of the Kids shelf").tap()
        // Its categories lead the page as tiles, in the household's order, not the alphabet's.
        let first = waitFor(app.buttons["tile.category.Zebra Tales"], "The first category of Kids")
        let second = waitFor(app.buttons["tile.category.Animal Films"], "The second category of Kids")
        XCTAssertLessThan(first.frame.minX, second.frame.minX)
        waitFor(app.buttons["Stripes, 2012"].firstMatch, "The film in the first category")
        waitFor(app.buttons["Paper Boats, 2010"].firstMatch, "The film in the second category")
        XCTAssertFalse(app.buttons["Short Notice, 2021"].exists, "A main film is under Kids.")
        attachScreenshot("group")

        // A category's own page carries its name, whether in words or as its logo.
        first.tap()
        waitFor(app.navigationBars["Zebra Tales"], "The category's page")
        waitFor(app.buttons["Stripes, 2012"].firstMatch, "Its film")
        attachScreenshot("category")
    }

    func testDownloadsAndSearchAreOneTapFromTheLibrary() async throws {
        let servers = try TestServers.load()
        launch()
        try await pair(with: servers)
        waitFor(app.buttons["profile.Alex"], "The viewer picker").tap()
        waitFor(shelf("movies"), "The library")

        app.tabBars.buttons["Downloads"].tap()
        XCTAssertTrue(waitFor(element("downloads.empty"), "The Downloads screen").exists)

        app.tabBars.buttons["Search"].tap()
        let field = waitFor(app.searchFields.firstMatch, "The search field")
        field.tap()
        field.typeText("short")
        waitFor(app.buttons["Short Notice, 2021"].firstMatch, "The film that matches")
        XCTAssertFalse(app.buttons["The Long Test, 2019"].exists)
    }
}
