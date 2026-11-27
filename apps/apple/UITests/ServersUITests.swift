// SPDX-License-Identifier: MPL-2.0
import XCTest

/// Two servers in one app, against two real Lobby Servers on this Mac on different
/// ports: the household's own ("Lobby UI Test") and another one's ("Lobby UI Test Two").
final class ServersUITests: LobbyUITestCase {
    /// A choice in the open menu by its words: a toggle in a menu is not always a button.
    private func menuChoice(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "(label == %@ OR label BEGINSWITH %@) AND NOT (identifier BEGINSWITH 'servers.')", label, "\(label),")).firstMatch
    }

    private func openViewerMenu() {
        waitFor(app.buttons["profile.menu"], "The viewer menu").tap()
    }

    func testASecondServerIsAddedSwitchedToAndRemoved() async throws {
        let servers = try TestServers.load()
        guard let second = servers.second else {
            throw XCTSkip("The test servers were started by an older script, without the second server.")
        }
        try await ManagerAPI(server: second).removeOtherDevices()
        launch()

        // The household's own server first, as any device has it.
        try await pair(with: servers)
        waitFor(app.buttons["profile.Alex"], "The viewer picker").tap()
        waitFor(shelf("movies"), "The library")

        // Add Server comes up on the Connect screen, with a way back.
        openViewerMenu()
        waitFor(menuChoice("Add Server…"), "Add Server in the viewer menu").tap()
        waitFor(app.buttons["server.cancelAdding"], "Back to the server in use")
        typeAddress(second.url)
        XCTAssertTrue(waitFor(element("connect.server"), "The other server's name").label.hasPrefix("Lobby UI Test Two"))
        app.buttons["connect.pair"].tap()
        try skipWithoutAKeychain(unless: "connect.code")
        let digits = (waitFor(element("connect.code"), "The pairing code").value as? String ?? "").filter(\.isNumber)
        try await ManagerAPI(server: second).approve(code: digits)

        // The other household's viewers, and the switcher on Who is watching.
        waitFor(app.buttons["profile.Oma"], "The other server's viewer")
        XCTAssertFalse(app.buttons["profile.Alex"].exists, "The first server's viewers do not come along.")
        XCTAssertTrue(element("server.switcher").exists)
        app.buttons["profile.Oma"].tap()
        waitFor(shelf("movies"), "The other server's library")
        attachScreenshot("servers-second-library")

        // Back to the first from the viewer menu: "Which library?", then that library's viewers.
        openViewerMenu()
        waitFor(menuChoice("Switch Library…"), "Switch Library in the viewer menu").tap()
        waitFor(element("library.screen"), "Which library?")
        XCTAssertTrue(element("library.choose.Lobby UI Test Two").exists)
        waitFor(element("library.choose.Lobby UI Test"), "The first library").tap()
        waitFor(app.buttons["profile.Alex"], "The first library's viewers")
        XCTAssertFalse(app.buttons["profile.Oma"].exists, "Viewers are never of two libraries.")
        app.buttons["profile.Alex"].tap()
        waitFor(shelf("movies"), "The first server's library again")
        XCTAssertEqual(app.buttons["profile.menu"].label, "Viewer: Alex")

        // A new launch asks which library, then opens it with its viewer as it was left.
        app.terminate()
        launch(clean: false)
        waitFor(element("library.screen"), "Which library? at the start")
        attachScreenshot("servers-which-library")
        waitFor(element("library.choose.Lobby UI Test"), "The first library").tap()
        waitFor(app.buttons["profile.Alex"], "Its viewers").tap()
        waitFor(shelf("movies"), "The library after relaunching")

        // Remembered: the next start opens it without asking.
        app.terminate()
        launch(clean: false)
        waitFor(app.switches["library.remember"], "Remember my choice").tap()
        element("library.choose.Lobby UI Test").tap()
        waitFor(app.buttons["profile.Alex"], "Its viewers").tap()
        app.terminate()
        launch(clean: false)
        waitFor(shelf("movies"), "The library, without the question")
        XCTAssertFalse(element("library.screen").exists)
        XCTAssertEqual(app.buttons["profile.menu"].label, "Viewer: Alex")

        // Settings → Servers lists both; the second one is removed, after asking.
        openViewerMenu()
        waitFor(menuChoice("Settings…"), "The Settings entry").tap()
        waitFor(app.buttons["settings.servers"], "Servers in Settings").tap()
        let row = waitFor(element("servers.row.Lobby UI Test Two"), "The second server's row")
        XCTAssertTrue(element("servers.row.Lobby UI Test").exists)
        attachScreenshot("servers-settings")
        row.swipeLeft()
        waitFor(app.buttons["Remove"].firstMatch, "Remove on the row").tap()
        waitFor(app.buttons["servers.confirmRemove"].firstMatch, "The confirmation").tap()
        let gone = NSPredicate(format: "exists == false")
        await fulfillment(of: [expectation(for: gone, evaluatedWith: element("servers.row.Lobby UI Test Two"))], timeout: 10)
        XCTAssertTrue(element("servers.row.Lobby UI Test").exists, "The first server stays.")
    }
}
