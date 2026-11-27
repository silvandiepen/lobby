// SPDX-License-Identifier: MPL-2.0
import XCTest

/// The stories (audiobooks) on every screen that shows them, for a grown-up, a kids viewer and
/// a kids viewer who may only listen, with a screenshot of each. Not part of the automated
/// suite: it skips unless `build/stories-walkthrough.json` exists.
///
///     {
///       "server": { "url": "http://127.0.0.1:18800", "managerToken": "…" },
///       "screenshots": "/absolute/path",      PNGs are written here
///       "prefix": "after",                    put before each name
///       "story": "Title",                     a story that has a film of the same name
///       "grownUp": "Alex", "kid": "Robin", "listener": "Sam"
///     }
///
/// The server has audiobooks and music. The kid is allowed the films; the listener is in Only
/// listening. Some stories were begun.
final class StoriesWalkthrough: LobbyUITestCase {
    private struct Plan: Decodable {
        var server: TestServers.Paired
        var screenshots: String
        var prefix: String
        var story: String
        var grownUp: String
        var kid: String
        var listener: String
    }

    private func plan(file: StaticString = #filePath) throws -> Plan {
        let json = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "build/stories-walkthrough.json")
        guard let data = try? Data(contentsOf: json) else {
            throw XCTSkip("No build/stories-walkthrough.json: the walkthrough was not asked for.")
        }
        return try JSONDecoder().decode(Plan.self, from: data)
    }

    private var device: String {
        app.windows.firstMatch.frame.width > 700 ? "ipad" : "iphone"
    }

    private func save(_ name: String, _ plan: Plan, wait seconds: Double = 2) async throws {
        // Pictures arrive after the page.
        try await Task.sleep(for: .seconds(seconds))
        try XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: plan.screenshots).appending(path: "\(plan.prefix)-\(device)-\(name).png"))
    }

    /// A fresh app, paired, as this viewer.
    private func start(as viewer: String, _ plan: Plan) async throws {
        let manager = ManagerAPI(server: plan.server)
        try await manager.removeOtherDevices()
        app.terminate()
        app.launchArguments = ["-lobby-mute", "YES", "-lobby-namespace", "stories-walkthrough", "-lobby-reset", "YES"]
        app.launch()
        typeAddress(plan.server.url)
        waitFor(app.buttons["connect.pair"], "Pair").tap()
        let code = waitFor(element("connect.code"), "The pairing code")
        try await manager.approve(code: (code.value as? String ?? "").filter(\.isNumber))
        waitFor(app.buttons["profile.\(viewer)"], "The viewer picker").tap()
    }

    private func tapIfThere(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        for _ in 0..<6 where !element.isHittable { app.swipeUp(velocity: .slow) }
        element.tap()
        return true
    }

    func testStories() async throws {
        let plan = try plan()
        XCUIDevice.shared.appearance = .dark

        // A grown-up: Home, the stories, a story, and what plays.
        try await start(as: plan.grownUp, plan)
        _ = app.scrollViews.matching(NSPredicate(format: "identifier BEGINSWITH 'shelf.'")).firstMatch.waitForExistence(timeout: 20)
        try await save("grownup-home", plan, wait: 4)
        let row = app.scrollViews["shelf.Stories"]
        for _ in 0..<6 where !row.exists { app.swipeUp(velocity: .slow) }
        try await save("grownup-home-stories", plan)
        let stories = app.staticTexts["sidebar.Stories"].firstMatch
        if stories.waitForExistence(timeout: 3) {
            for _ in 0..<4 where !stories.isHittable { app.swipeUp(velocity: .slow) }
            stories.tap()
        } else if app.tabBars.buttons["Music"].exists {
            app.tabBars.buttons["Music"].tap()
            try await save("grownup-music", plan)
            _ = tapIfThere(element("music.section.books"))
        }
        try await save("grownup-stories", plan)
        if tapIfThere(element("music.book.\(plan.story)")) {
            try await save("grownup-story", plan)
            if tapIfThere(app.buttons["music.play"]) {
                if tapIfThere(element("music.mini")) {
                    try await save("grownup-player", plan, wait: 3)
                    _ = tapIfThere(app.buttons["music.player.close"])
                }
            }
            if tapIfThere(element("story.film"), timeout: 2) {
                try await save("grownup-film", plan)
            }
        }

        // A kids viewer: Home, the stories place, a story, and the kids player.
        try await start(as: plan.kid, plan)
        waitFor(app.buttons["kids.tab.home"], "The kids screens", timeout: 30)
        try await save("kid-home", plan, wait: 4)
        if tapIfThere(app.buttons["kids.tab.stories"]) {
            try await save("kid-stories", plan, wait: 3)
            if tapIfThere(element("kids.story.\(plan.story)")) {
                try await save("kid-story", plan)
                if tapIfThere(app.buttons["kids.story.play"]) {
                    waitFor(element("kids.player"), "The kids player")
                    try await save("kid-player", plan, wait: 3)
                    app.buttons["kids.player.sleep"].tap()
                    let endOfStory = waitFor(element("kids.player.sleep.endOfStory"), "The sleep timer's choices")
                    try await save("kid-sleep-choices", plan, wait: 1)
                    endOfStory.tap()
                    try await save("kid-player-sleep", plan)
                    app.buttons["kids.player.close"].tap()
                    waitFor(app.buttons["kids.story.play"], "The story's page")
                    try await save("kid-story-playing", plan)
                    app.buttons["kids.back"].tap()
                    try await save("kid-stories-playing", plan)
                }
            }
        }
        if tapIfThere(app.buttons["kids.tab.movies"]), tapIfThere(element("kids.poster.\(plan.story)")) {
            try await save("kid-film", plan)
        }

        // Only listening: where the child lands, a story, and the player.
        try await start(as: plan.listener, plan)
        _ = element("kids.listening").waitForExistence(timeout: 30)
        try await save("listener-home", plan, wait: 4)
        if tapIfThere(element("kids.story.\(plan.story)")) {
            try await save("listener-story", plan)
            if tapIfThere(app.buttons["kids.story.play"]) {
                try await save("listener-player", plan, wait: 3)
            }
        }
    }
}
