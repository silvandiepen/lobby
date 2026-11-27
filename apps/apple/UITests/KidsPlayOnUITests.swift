// SPDX-License-Identifier: MPL-2.0
import XCTest

/// Play on TV from the kids screens (docs/decisions.md, "Kids mode plays on the TV"), against the local Lobby Server: a television of the
/// household is a device this test pairs and opens the live channel for. Nothing plays on this
/// device: the title goes to the television, which only says that it plays.
final class KidsPlayOnUITests: LobbyUITestCase {
    private static let child = "Child"

    func testOneTVIsOneTapAndTheChildControlsOnlyItsOwnFilm() async throws {
        let servers = try TestServers.load()
        let manager = ManagerAPI(server: servers.paired)
        try await manager.removeOtherDevices()
        try await manager.addViewer(Self.child)
        addTeardownBlock {
            try await manager.removeOtherDevices()
            try await manager.removeViewer(Self.child)
        }
        guard try await manager.setKids(["allowedGroupIds": try await manager.groupIDs()], ofViewer: Self.child) else {
            throw XCTSkip("This Lobby Server does not know kids viewers yet.")
        }
        let livingRoom = try await Television.pair("Living Room", servers: servers)
        // Off, and the household does not let kids turn on the TV: not offered.
        _ = try await Television.pair("Bedroom", servers: servers)
        try await livingRoom.open()
        defer { Task { await livingRoom.close() } }

        launch()
        try await pair(with: servers)
        waitFor(app.buttons["profile.\(Self.child)"], "The viewer picker").tap()
        waitFor(app.buttons["kids.tab.movies"], "The kids screens").tap()
        waitFor(app.buttons["kids.poster.The Long Test"], "A film on Movies").tap()

        // One TV that can play: the button names it, and one tap plays there as the child.
        let playOn = waitFor(app.buttons["kids.playOn"], "Play on TV", timeout: 20)
        XCTAssertEqual(playOn.label, "Play on Living Room")
        attachScreenshot("kids-play-on")
        playOn.tap()
        let command = try await livingRoom.nextPlay(timeout: 15)
        let child = try await manager.viewerIDForTests(Self.child)
        let film = try await manager.itemID(titled: "The Long Test")
        XCTAssertEqual(command.profileId, child)
        XCTAssertEqual(command.itemId, film)
        XCTAssertFalse(app.buttons["kids.playOn.close"].exists, "One TV needs no choosing")

        // The TV plays it as the child: the child's remote is there, with pause and stop only.
        let remote = waitFor(element("kids.tvRemote.title"), "What plays on the TV", timeout: 15)
        XCTAssertTrue(remote.label.contains("Living Room"), remote.label)
        XCTAssertFalse(app.buttons["playOn.routePicker"].exists, "No AirPlay picker in kids mode")
        attachScreenshot("kids-tv-remote")
        app.buttons["kids.tvRemote.playPause"].tap()
        let paused = try await livingRoom.next(timeout: 10)
        XCTAssertEqual(paused.type, "pause")
        app.buttons["kids.tvRemote.stop"].tap()
        let stopped = try await livingRoom.next(timeout: 10)
        XCTAssertEqual(stopped.type, "stop")
    }
}
