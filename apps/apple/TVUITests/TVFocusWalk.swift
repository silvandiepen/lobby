// SPDX-License-Identifier: MPL-2.0
import XCTest

/// Walks the Apple TV app with the arrows alone, as the Remote app does, against the local Lobby
/// Server of `Scripts/ui-test-server.sh`: on every page the remote is always somewhere, a press
/// moves it, and Back goes one step.
@MainActor
final class TVFocusWalk: XCTestCase {
    let app = XCUIApplication()
    let remote = XCUIRemote.shared

    override func setUp() async throws {
        continueAfterFailure = false
    }

    /// What has the remote. Fails when nothing has it.
    @discardableResult
    private func focused(_ step: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Nothing has the remote after \(step).", file: file, line: line)
        return element
    }

    private func describe(_ element: XCUIElement) -> String {
        "\(element.elementType.rawValue)|\(element.identifier)|\(element.label)|\(element.frame.integral)"
    }

    /// Presses `button` up to `times` times. Every press keeps the remote somewhere; at least one
    /// moves it, unless `mayStay`.
    private func walk(_ button: XCUIRemote.Button, times: Int, on page: String, mayStay: Bool = false) {
        var moved = false
        var last = describe(focused("\(page): before \(button)"))
        for press in 0..<times {
            remote.press(button)
            let now = describe(focused("\(page): \(button) \(press + 1)"))
            if now != last { moved = true }
            last = now
        }
        if !mayStay { XCTAssertTrue(moved, "\(page): \(button) never moved the remote.") }
    }

    private func press(_ button: XCUIRemote.Button, _ step: String) {
        remote.press(button)
        focused(step)
    }

    private func waitFor(_ identifier: String, _ what: String, timeout: TimeInterval = 20) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(what) did not appear.")
        return element
    }

    /// Moves the remote onto `identifier` with presses of `button`.
    private func reach(_ identifier: String, with button: XCUIRemote.Button, tries: Int = 12) -> Bool {
        for _ in 0..<tries {
            if focused("looking for \(identifier)").identifier == identifier { return true }
            remote.press(button)
        }
        return focused("looking for \(identifier)").identifier == identifier
    }

    func testEveryPageCanBeWalkedWithTheArrows() async throws {
        let servers = try TestServers.load()
        app.launchArguments = ["-lobby-mute", "YES", "-lobby-namespace", "tv-ui-tests", "-lobby-reset", "YES"]
        app.launch()

        // Connect: Enter Address, type it, Continue, Pair.
        let enter = waitFor("connect.enterAddress", "Enter Address")
        XCTAssertTrue(reach("connect.enterAddress", with: .down), "Enter Address cannot be reached.")
        _ = enter
        press(.select, "Enter Address")
        let field = waitFor("connect.address", "The address field")
        XCTAssertTrue(reach("connect.address", with: .up))
        remote.press(.select)
        field.typeText(servers.paired.url.absoluteString)
        // Back puts the keyboard away with what was typed, as on the Remote app.
        remote.press(.menu)
        _ = waitFor("connect.continue", "Continue")
        XCTAssertTrue(reach("connect.continue", with: .down))
        press(.select, "Continue")
        _ = waitFor("connect.pair", "Pair This Apple TV")
        XCTAssertTrue(reach("connect.pair", with: .up))
        press(.select, "Pair")

        let either = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", ["connect.code", "connect.problem"])).firstMatch
        XCTAssertTrue(either.waitForExistence(timeout: 20))
        if either.identifier == "connect.problem", either.label.contains("Keychain") {
            throw XCTSkip("This build has no Keychain. Build it signed for the simulator.")
        }
        let digits = (app.descendants(matching: .any)["connect.code"].value as? String ?? "").filter(\.isNumber)
        try await ManagerAPI(server: servers.paired).approve(code: digits)

        // Who is watching: the whole row with the arrows, and a choice.
        _ = waitFor("profile.Alex", "The viewers", timeout: 30)
        walk(.right, times: 3, on: "Who is watching")
        walk(.left, times: 3, on: "Who is watching")
        walk(.down, times: 1, on: "Who is watching")
        walk(.up, times: 1, on: "Who is watching", mayStay: true)
        XCTAssertTrue(reach("profile.Alex", with: .left))
        press(.select, "Choosing Alex")

        // Home: the banner when the library has pictures for one (the test server's films have
        // none), the rows down and back, each row sideways.
        let shelf = app.scrollViews.matching(NSPredicate(format: "identifier BEGINSWITH 'shelf.'")).firstMatch
        let banner = app.buttons["banner.play"]
        XCTAssertTrue(banner.waitForExistence(timeout: 40) || shelf.waitForExistence(timeout: 10), "Home did not appear.")
        let top = describe(focused("Home"))
        if banner.exists {
            XCTAssertEqual(focused("Home").identifier, "banner.play", "Home does not open on the banner's Play.")
            walk(.right, times: 2, on: "the banner")
            walk(.left, times: 2, on: "the banner")
            // The slideshow stands still while the remote is on it.
            let onBanner = describe(focused("banner"))
            try await Task.sleep(for: .seconds(10))
            XCTAssertEqual(describe(focused("waiting on the banner")), onBanner, "The banner moved the remote.")
        }
        walk(.down, times: 6, on: "Home")
        walk(.right, times: 3, on: "a row")
        walk(.left, times: 3, on: "a row")
        walk(.up, times: 8, on: "Home")
        XCTAssertEqual(describe(focused("back up")), top, "Up does not lead back to the top of Home.")

        // A title's page: its buttons, its rows, Back to where the remote was.
        walk(.down, times: 1, on: "Home")
        let tile = describe(focused("a tile"))
        press(.select, "A tile")
        focused("the page a tile opened")
        walk(.right, times: 3, on: "the page a tile opened", mayStay: true)
        walk(.down, times: 4, on: "the page a tile opened", mayStay: true)
        walk(.up, times: 4, on: "the page a tile opened", mayStay: true)
        press(.menu, "Back from that page")
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(describe(focused("back on Home")), tile, "Back did not return to the tile.")
        walk(.up, times: 8, on: "Home", mayStay: true)

        // Back at the top of a place: the sidebar, and every place in it.
        press(.menu, "Back to the sidebar")
        walk(.up, times: 6, on: "the sidebar")
        walk(.down, times: 8, on: "the sidebar")
        // The viewer's page, at the top of the sidebar.
        walk(.up, times: 8, on: "the sidebar", mayStay: true)
        press(.select, "The viewer's place")
        _ = waitFor("viewer.switch", "Switch Viewer")
        XCTAssertTrue(reach("viewer.switch", with: .up, tries: 4) || reach("viewer.switch", with: .right, tries: 4))
        walk(.down, times: 3, on: "the viewer's page")
        walk(.up, times: 3, on: "the viewer's page")
        XCTAssertTrue(reach("viewer.switch", with: .left, tries: 3))
        press(.select, "Switch Viewer")
        _ = waitFor("profile.Alex", "Who is watching")
        press(.menu, "Back from Who is watching")
        _ = waitFor("viewer.switch", "The viewer's page again")
    }
}
