// SPDX-License-Identifier: MPL-2.0
import XCTest

/// The now-playing panel for what plays on a television: a black panel beside the page on iPad,
/// a black bar that opens a sheet on iPhone. The television is a device this test pairs with the
/// local Lobby Server; what the panel's buttons send reaches it through the server.
final class NowPlayingPanelUITests: LobbyUITestCase {
    func testThePanelShowsWhatPlaysAndControlsIt() async throws {
        let servers = try TestServers.load()
        let manager = ManagerAPI(server: servers.paired)
        try await manager.removeOtherDevices()
        let livingRoom = try await Television.pair("Living Room", servers: servers)
        try await livingRoom.open()
        defer { Task { await livingRoom.close() } }
        let film = try await manager.itemID(titled: "The Long Test")
        let next = try await manager.itemID(titled: "Matroska Morning")
        try await livingRoom.show(itemId: film, positionMs: 95_000, durationMs: 240_000, nextItemId: next)

        launch()
        try await pair(with: servers)
        waitFor(app.buttons["profile.Alex"], "The viewer picker").tap()

        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        if isPad {
            waitFor(element("nowPlaying.panel"), "The side panel", timeout: 20)
            XCTAssertTrue(element("remote.title").waitForExistence(timeout: 5))
            attachScreenshot("panel-side")
        } else {
            waitFor(element("nowPlaying.open"), "The bar", timeout: 20)
            attachScreenshot("panel-bar")
            element("nowPlaying.open").tap()
            waitFor(element("remote.title"), "The remote")
            attachScreenshot("panel-sheet")
        }

        XCTAssertEqual(element("remote.title").label, "The Long Test")
        app.buttons["Back 10 Seconds"].tap()
        let back = try await livingRoom.next(timeout: 10)
        XCTAssertEqual(back.type, "skip")
        XCTAssertEqual(back.deltaMs, -10_000)
        app.buttons["Forward 30 Seconds"].tap()
        let forward = try await livingRoom.next(timeout: 10)
        XCTAssertEqual(forward.deltaMs, 30_000)
        app.buttons["Pause"].firstMatch.tap()
        let pause = try await livingRoom.next(timeout: 10)
        XCTAssertEqual(pause.type, "pause")
        try await livingRoom.show(itemId: film, positionMs: 95_000, durationMs: 240_000, nextItemId: next, status: "paused")
        waitFor(app.buttons["Play"].firstMatch, "Play after a pause")
        attachScreenshot("panel-paused")

        if isPad {
            element("nowPlaying.collapse").tap()
            waitFor(element("nowPlaying.expand"), "The folded panel")
            attachScreenshot("panel-folded")
            element("nowPlaying.expand").tap()
            waitFor(element("remote.title"), "The panel again")
        }
    }
}
