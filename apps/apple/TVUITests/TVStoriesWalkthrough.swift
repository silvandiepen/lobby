// SPDX-License-Identifier: MPL-2.0
import XCTest

/// The stories on the Apple TV for a kids viewer, one who may only listen, and a grown-up, with
/// a screenshot of each page. Not part of the automated suite: it skips unless
/// `build/stories-walkthrough.json` exists (see `UITests/StoriesWalkthrough.swift`).
@MainActor
final class TVStoriesWalkthrough: XCTestCase {
    private struct Plan: Decodable {
        var server: TestServers.Paired
        var screenshots: String
        var prefix: String
        var story: String
        var grownUp: String
        var kid: String
        var listener: String
    }

    let app = XCUIApplication()
    let remote = XCUIRemote.shared

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func plan(file: StaticString = #filePath) throws -> Plan {
        let json = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/stories-walkthrough.json")
        guard let data = try? Data(contentsOf: json) else {
            throw XCTSkip("No build/stories-walkthrough.json: the walkthrough was not asked for.")
        }
        return try JSONDecoder().decode(Plan.self, from: data)
    }

    private func save(_ name: String, _ plan: Plan, wait seconds: Double = 2) async throws {
        try await Task.sleep(for: .seconds(seconds))
        try XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: plan.screenshots).appending(path: "\(plan.prefix)-tv-\(name).png"))
    }

    private var focused: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Moves the remote with presses of `button` until what has it matches.
    @discardableResult
    private func reach(_ button: XCUIRemote.Button, tries: Int = 14, _ matches: (XCUIElement) -> Bool) -> Bool {
        for _ in 0..<tries {
            if focused.waitForExistence(timeout: 3), matches(focused) { return true }
            remote.press(button)
        }
        return matches(focused)
    }

    private func start(as viewer: String, _ plan: Plan) async throws {
        try await ManagerAPI(server: plan.server).removeOtherDevices()
        app.terminate()
        app.launchArguments = ["-lobby-mute", "YES", "-lobby-namespace", "tv-stories", "-lobby-reset", "YES"]
        app.launch()
        XCTAssertTrue(element("connect.enterAddress").waitForExistence(timeout: 20))
        reach(.down) { $0.identifier == "connect.enterAddress" }
        remote.press(.select)
        let field = element("connect.address")
        if !field.waitForExistence(timeout: 10) {
            // Enter Address was not the one that had the remote: look for it again.
            reach(.up) { $0.identifier == "connect.enterAddress" }
            remote.press(.select)
        }
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        reach(.up) { $0.identifier == "connect.address" }
        remote.press(.select)
        field.typeText(plan.server.url.absoluteString)
        remote.press(.menu)
        XCTAssertTrue(element("connect.continue").waitForExistence(timeout: 10))
        reach(.down) { $0.identifier == "connect.continue" }
        remote.press(.select)
        XCTAssertTrue(element("connect.pair").waitForExistence(timeout: 20))
        reach(.up) { $0.identifier == "connect.pair" }
        remote.press(.select)
        let code = element("connect.code")
        XCTAssertTrue(code.waitForExistence(timeout: 20))
        try await ManagerAPI(server: plan.server).approve(code: (code.value as? String ?? "").filter(\.isNumber))
        XCTAssertTrue(element("profile.\(viewer)").waitForExistence(timeout: 30))
        reach(.right) { $0.identifier == "profile.\(viewer)" }
        reach(.left) { $0.identifier == "profile.\(viewer)" }
        remote.press(.select)
    }

    /// The sidebar, and the place of this name in it.
    private func open(_ place: String) {
        // Back from the sidebar itself would leave the app.
        let places = ["Home", "Stories", "Movies", "Series", "Music", "Search"]
        if !(focused.waitForExistence(timeout: 5) && places.contains(where: { focused.label.contains($0) })) {
            remote.press(.menu)
        }
        if !reach(.down, { $0.label.contains(place) }) { reach(.up) { $0.label.contains(place) } }
        remote.press(.select)
    }

    func testStories() async throws {
        let plan = try plan()

        try await start(as: plan.kid, plan)
        try await save("kid-home", plan, wait: 6)
        open("Stories")
        _ = element("kids.stories").waitForExistence(timeout: 20)
        try await save("kid-stories", plan, wait: 4)
        remote.press(.right)
        reach(.down, tries: 20) { $0.identifier == "kids.story.\(plan.story)" || $0.identifier.hasPrefix("kids.story.") }
        reach(.right, tries: 12) { $0.identifier == "kids.story.\(plan.story)" }
        try await save("kid-stories-focused", plan, wait: 1)
        remote.press(.select)
        _ = element("kids.story.play").waitForExistence(timeout: 10)
        try await save("kid-story", plan, wait: 3)
        remote.press(.select)
        _ = element("kids.player").waitForExistence(timeout: 15)
        try await save("kid-player", plan, wait: 4)
        remote.press(.menu)

        try await start(as: plan.listener, plan)
        try await save("listener-home", plan, wait: 8)

        try await start(as: plan.grownUp, plan)
        try await save("grownup-home", plan, wait: 6)
        open("Music")
        try await save("grownup-music", plan, wait: 4)
    }
}
