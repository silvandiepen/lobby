// SPDX-License-Identifier: MPL-2.0
import XCTest

/// What the UI tests share: launching the app in its own namespace, and the steps of pairing.
@MainActor
class LobbyUITestCase: XCTestCase {
    let app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
    }

    /// Launches the app with state of its own, apart from the copy a person uses on this
    /// simulator.
    ///
    /// - Parameter clean: Start with nothing stored. Pass false to relaunch and find what the
    ///   last launch left.
    func launch(clean: Bool = true, more: [String] = []) {
        app.launchArguments = ["-lobby-mute", "YES", "-lobby-namespace", "ui-tests"] + (clean ? ["-lobby-reset", "YES"] : []) + more
        app.launch()
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @discardableResult
    func waitFor(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(what) did not appear.", file: file, line: line)
        return element
    }

    /// A row of Home. It is made when it comes into sight, below others that depend on what was
    /// watched: scrolls down to it.
    func shelf(_ name: String) -> XCUIElement {
        let row = app.scrollViews["shelf.\(name)"]
        _ = app.scrollViews.matching(NSPredicate(format: "identifier BEGINSWITH 'shelf.'")).firstMatch.waitForExistence(timeout: 20)
        for _ in 0..<6 where !row.exists { app.swipeUp(velocity: .slow) }
        return row
    }

    /// A row of a list that is only made when it comes into sight, such as the Household rows
    /// at the end of Settings on a phone: scrolls down to it, then waits for it.
    @discardableResult
    func scrolledTo(_ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        _ = element.waitForExistence(timeout: 5)
        for _ in 0..<6 where !element.isHittable { app.swipeUp(velocity: .slow) }
        return waitFor(element, what, file: file, line: line)
    }

    /// A viewer in the open viewer menu, whatever the system makes of a choice there: not the
    /// pill of a part of the library with the same name.
    func viewerInMenu(_ name: String) -> XCUIElement {
        // A choice in a menu with a picture beside it is not always a button.
        app.descendants(matching: .any).matching(NSPredicate(
            format: "(label == %@ OR label BEGINSWITH %@) AND identifier != %@ AND NOT (identifier BEGINSWITH 'profile.')",
            name, "\(name),", "filter.\(name)")).firstMatch
    }

    func typeAddress(_ url: URL) {
        // The servers of the test run are on 127.0.0.1 and announce nothing: type the address.
        waitFor(app.buttons["connect.enterAddress"], "Enter Address").tap()
        let field = waitFor(app.textFields["connect.address"], "The address field")
        field.tap()
        if let existing = field.value as? String, !existing.isEmpty, existing != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(url.absoluteString)
        app.buttons["connect.continue"].tap()
    }

    /// Connect to the paired server, show a code, and have the manager approve it.
    func pair(with servers: TestServers, role: String = "viewer") async throws {
        typeAddress(servers.paired.url)
        XCTAssertTrue(waitFor(element("connect.server"), "The server's name").label.hasPrefix("Lobby UI Test, "))
        app.buttons["connect.pair"].tap()

        try skipWithoutAKeychain(unless: "connect.code")
        let code = waitFor(element("connect.code"), "The pairing code")
        let digits = (code.value as? String ?? "").filter(\.isNumber)
        XCTAssertEqual(digits.count, 6, "The pairing code should be six digits.")
        try await ManagerAPI(server: servers.paired).approve(code: digits, role: role)
    }

    /// Pairing stores the device credential in the Keychain, which a simulator build made with
    /// `CODE_SIGNING_ALLOWED=NO` does not have (it carries no application identifier). The app
    /// says so before it pairs. The tests that pair then skip: run them from a signed build,
    /// which is what `xcodebuild test` makes without that flag.
    func skipWithoutAKeychain(unless expected: String) throws {
        let either = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", [expected, "connect.problem"])).firstMatch
        waitFor(either, "The next step, or an explanation")
        let problem = element("connect.problem")
        if problem.exists, problem.label.contains("Keychain") {
            throw XCTSkip("This build has no Keychain (CODE_SIGNING_ALLOWED=NO). Run the UI tests without that flag.")
        }
    }

    // MARK: The player

    // A film plays under one of two sets of controls: the system player's, or the app's own
    // while Lobby Server is still writing the film's copy (an MKV played for the first time).
    // Which one a test meets depends on how fast the server was, so these look for both.

    /// The Close button of whichever controls are up.
    private var playerCloseButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier IN %@", ["Close Button", "player.close"])).firstMatch
    }

    /// Both hide their controls while a film plays. A tap on the picture, away from the
    /// buttons in its middle, brings them back.
    func showPlayerControls() {
        if !playerCloseButton.exists {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        }
    }

    /// Where the player says it is: the system player's "0:13 elapsed", or the "0:13" of the
    /// app's own bar.
    func playerElapsedSeconds() -> Int? {
        showPlayerControls()
        let elapsed = app.staticTexts.matching(
            NSPredicate(format: "identifier IN %@", ["Elapsed Time", "player.elapsed"])).firstMatch
        guard elapsed.waitForExistence(timeout: 3) else { return nil }
        let clock = elapsed.label.split(separator: " ").first ?? ""
        let parts = clock.split(separator: ":").map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    /// Lets the player run until the film is past `seconds`, then closes it with the system
    /// player's own Close button.
    func closePlayer(afterPlayingPast seconds: Int) throws {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds) + 45)
        var position = 0
        while position < seconds, Date() < deadline {
            position = playerElapsedSeconds() ?? position
        }
        XCTAssertGreaterThanOrEqual(position, seconds, "The film did not play.")
        // The controls hide themselves after a few seconds, which can be just now: bring
        // them back until the Close button is there to be tapped.
        for _ in 0..<5 {
            showPlayerControls()
            if playerCloseButton.waitForExistence(timeout: 2), playerCloseButton.isHittable {
                playerCloseButton.tap()
                return
            }
        }
        XCTFail("The player's Close button did not appear.")
    }

    func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
