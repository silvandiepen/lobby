// SPDX-License-Identifier: MPL-2.0
import XCTest

/// Music against the local Lobby Server and its invented library (`tools/music-sample`): an
/// album plays, keeps playing with the app in the background, and is in the mini player when
/// the app comes back, from where the full player opens.
final class MusicUITests: LobbyUITestCase {
    func testAnAlbumPlaysOnInTheBackgroundAndWaitsInTheMiniPlayer() async throws {
        let servers = try TestServers.load()
        launch()
        try await pair(with: servers)
        // Guest: what is played here stays off the shelves the other tests look at.
        waitFor(app.buttons["profile.Guest"], "The viewer picker").tap()

        if UIDevice.current.userInterfaceIdiom == .pad {
            waitFor(app.staticTexts["sidebar.Music"].firstMatch, "Music in the sidebar", timeout: 30).tap()
        } else {
            waitFor(app.tabBars.buttons["Music"], "The Music tab", timeout: 30).tap()
        }
        waitFor(element("music.album.Harbour Lights"), "The album on Music's home").tap()
        waitFor(app.buttons["music.play"], "The album's Play").tap()

        let mini = waitFor(element("music.mini"), "The mini player")
        XCTAssertTrue(mini.label.contains("Low Tide Signal"), "The mini player should name the first song, not \(mini.label).")
        let toggle = waitFor(app.buttons["music.mini.play"], "Play and pause in the mini player")
        XCTAssertTrue(toggle.wait(for: \.label, toEqual: "Pause", timeout: 15), "The song should be playing.")

        // Home: the sound goes on, so the system keeps the app running instead of suspending it.
        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(4))
        XCTAssertEqual(app.state, .runningBackground, "With music playing the app keeps running in the background.")

        app.activate()
        XCTAssertTrue(waitFor(element("music.mini"), "The mini player after coming back").exists)
        XCTAssertEqual(app.buttons["music.mini.play"].label, "Pause", "It should still be playing.")

        // The full player, and the music paused from it.
        element("music.mini").tap()
        let title = waitFor(element("music.player.title"), "The full player")
        XCTAssertEqual(title.label, "Low Tide Signal")
        waitFor(app.buttons["music.player.play"], "Pause in the full player").tap()
        XCTAssertTrue(app.buttons["music.player.play"].wait(for: \.label, toEqual: "Play", timeout: 5))
        app.buttons["music.player.close"].tap()
        XCTAssertEqual(waitFor(app.buttons["music.mini.play"], "The mini player again").label, "Play")
    }
}
