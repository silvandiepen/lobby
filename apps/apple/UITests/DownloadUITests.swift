// SPDX-License-Identifier: MPL-2.0
import XCTest

final class DownloadUITests: LobbyUITestCase {
    /// A film is kept on the device, survives a relaunch, plays from the Downloads screen and
    /// can be removed again.
    func testAFilmIsDownloadedListedPlayedAndRemoved() async throws {
        let servers = try TestServers.load()
        launch()
        try await pair(with: servers)
        waitFor(app.buttons["profile.Guest"], "The viewer picker").tap()

        waitFor(shelf("movies").buttons["Short Notice, 2021"], "The film on its shelf").tap()
        let download = waitFor(app.buttons["detail.download"], "The Download button")
        XCTAssertTrue(download.label.hasPrefix("Download · "), "It should say how large the file is: \(download.label)")
        download.tap()
        waitFor(
            app.buttons.matching(NSPredicate(format: "identifier == 'detail.download' AND label == 'Downloaded'")).firstMatch,
            "The film to be downloaded", timeout: 60)
        attachScreenshot("movie-downloaded")

        app.tabBars.buttons["Downloads"].tap()
        let row = waitFor(element("download.Short Notice"), "The film on the Downloads screen")
        XCTAssertTrue(row.label.contains("Downloaded"), row.label)
        XCTAssertTrue(waitFor(element("downloads.total"), "The total").label.hasPrefix("1 item · "))
        attachScreenshot("downloads")

        // Still there after closing and opening the app, and it plays from here.
        app.terminate()
        launch(clean: false)
        waitFor(app.tabBars.buttons["Downloads"], "The tab bar").tap()
        waitFor(element("download.Short Notice"), "The film after relaunching").tap()
        try closePlayer(afterPlayingPast: 3)

        // Removing it empties the screen. The film is still in the library.
        let again = waitFor(element("download.Short Notice"), "The Downloads screen after playing")
        again.swipeLeft()
        waitFor(app.buttons["Remove"], "Remove").tap()
        waitFor(element("downloads.empty"), "The empty Downloads screen")
        app.tabBars.buttons["Home"].tap()
        waitFor(shelf("movies").buttons["Short Notice, 2021"], "The film on its shelf").tap()
        XCTAssertTrue(waitFor(app.buttons["detail.download"], "The film's page").label.hasPrefix("Download · "))
    }

    /// Download Season says what it needs first, then fetches every episode.
    func testASeasonIsDownloadedAfterSayingWhatItNeeds() async throws {
        let servers = try TestServers.load()
        launch()
        try await pair(with: servers)
        waitFor(app.buttons["profile.Guest"], "The viewer picker").tap()

        waitFor(shelf("series").buttons["Test Show"], "The show on its shelf").tap()
        // The seasons are under the Related row.
        scrolledTo(app.buttons["show.downloadSeason"], "Download Season").tap()
        let alert = waitFor(app.alerts["Download 2 episodes?"], "What the season needs")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'is free for downloads'")).firstMatch.exists)
        alert.buttons["show.confirmDownloadSeason"].firstMatch.tap()

        app.tabBars.buttons["Downloads"].tap()
        let done = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'downloads.show.Test Show' AND label CONTAINS ', 2 episodes downloaded'")).firstMatch
        waitFor(done, "Both episodes to be downloaded", timeout: 60)
        XCTAssertTrue(element("download.1. Pilot").exists)
        XCTAssertTrue(element("download.2. Second Thoughts").exists)
        attachScreenshot("downloads-season")
    }

    /// A subtitle file beside an MP4 is not in the system player's menu. The app offers it
    /// with a button of its own and draws the lines, from the server and, once the film is
    /// downloaded, from the copy stored with it.
    func testASubtitleFileIsOfferedAndShownAlsoFromADownload() async throws {
        let servers = try TestServers.load()
        launch()
        try await pair(with: servers)
        waitFor(app.buttons["profile.Guest"], "The viewer picker").tap()
        waitFor(shelf("movies").buttons["The Long Test, 2019"], "The film on its shelf").tap()

        // From the server.
        waitFor(app.buttons["detail.play"], "Play").tap()
        try chooseDutchAndReadALine()
        showPlayerControls()
        waitFor(app.buttons["Close Button"], "The player's Close button").tap()

        // Downloaded, then from the stored copy.
        waitFor(app.buttons["detail.download"], "The Download button").tap()
        waitFor(
            app.buttons.matching(NSPredicate(format: "identifier == 'detail.download' AND label == 'Downloaded'")).firstMatch,
            "The film to be downloaded", timeout: 60)
        app.tabBars.buttons["Downloads"].tap()
        waitFor(element("download.The Long Test"), "The film on the Downloads screen").tap()
        try chooseDutchAndReadALine()
        attachScreenshot("player-subtitle-from-download")
    }

    private func chooseDutchAndReadALine() throws {
        // The button is up for a few seconds when the player opens, and comes back with a tap
        // on the picture, like the system's controls.
        let more = app.buttons["player.moreSubtitles"]
        if !more.waitForExistence(timeout: 3) {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        }
        waitFor(more, "The button for more subtitles").tap()
        waitFor(app.buttons["Dutch"], "The subtitle file in the menu").tap()
        let line = waitFor(element("player.subtitle"), "A line of the subtitle")
        XCTAssertTrue(line.label.hasPrefix("Regel "), line.label)
    }
}
