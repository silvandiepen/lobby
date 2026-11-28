// SPDX-License-Identifier: MPL-2.0
import XCTest

/// Play on a HomePod (docs/decisions.md, "Play on a speaker"), for a grown-up and for a kids
/// viewer, with a screenshot of each screen. Not part of the automated suite: it skips unless
/// `build/speakers-walkthrough.json` exists, and needs a Lobby Server whose helper is a stand-in
/// speaker (`apps/server/test/support/fake-pyatv`), never a real one.
///
///     {
///       "server": { "url": "http://127.0.0.1:18790", "managerToken": "…" },
///       "screenshots": "/absolute/path",      PNGs are written here
///       "story": "Title",                     a story of the server's
///       "speaker": "Kitchen",                 the stand-in's HomePod
///       "grownUp": "Alex", "kid": "Robin"
///     }
final class SpeakersWalkthrough: LobbyUITestCase {
    private struct Plan: Decodable {
        var server: TestServers.Paired
        var screenshots: String
        var story: String
        var speaker: String
        var grownUp: String
        var kid: String
    }

    private func plan(file: StaticString = #filePath) throws -> Plan {
        let json = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "build/speakers-walkthrough.json")
        guard let data = try? Data(contentsOf: json) else {
            throw XCTSkip("No build/speakers-walkthrough.json: the walkthrough was not asked for.")
        }
        return try JSONDecoder().decode(Plan.self, from: data)
    }

    private var device: String {
        app.windows.firstMatch.frame.width > 700 ? "ipad" : "iphone"
    }

    private func save(_ name: String, _ plan: Plan, wait seconds: Double = 2) async throws {
        try await Task.sleep(for: .seconds(seconds))
        try XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: plan.screenshots).appending(path: "\(device)-\(name).png"))
    }

    /// A fresh app, paired, as this viewer.
    private func start(as viewer: String, _ plan: Plan) async throws {
        let manager = ManagerAPI(server: plan.server)
        try await manager.removeOtherDevices()
        app.terminate()
        app.launchArguments = ["-lobby-mute", "YES", "-lobby-namespace", "speakers-walkthrough", "-lobby-reset", "YES"]
        app.launch()
        typeAddress(plan.server.url)
        waitFor(app.buttons["connect.pair"], "Pair").tap()
        let code = waitFor(element("connect.code"), "The pairing code")
        try await manager.approve(code: (code.value as? String ?? "").filter(\.isNumber))
        waitFor(app.buttons["profile.\(viewer)"], "The viewer picker").tap()
    }

    private func tapIfThere(_ element: XCUIElement, timeout: TimeInterval = 8) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        for _ in 0..<6 where !element.isHittable { app.swipeUp(velocity: .slow) }
        element.tap()
        return true
    }

    func testSpeakers() async throws {
        let plan = try plan()
        XCUIDevice.shared.appearance = .dark

        // A grown-up: a story's page, Play On with the speakers, the speaker's remote, the bar.
        try await start(as: plan.grownUp, plan)
        _ = app.scrollViews.matching(NSPredicate(format: "identifier BEGINSWITH 'shelf.'")).firstMatch.waitForExistence(timeout: 20)
        if app.tabBars.buttons["Music"].waitForExistence(timeout: 5) {
            app.tabBars.buttons["Music"].tap()
            _ = tapIfThere(element("music.section.books"))
        }
        XCTAssertTrue(tapIfThere(element("music.book.\(plan.story)")), "The story's page")
        XCTAssertTrue(tapIfThere(app.buttons["music.playOn"], timeout: 20), "Play On, once the speakers are known")
        waitFor(element("playOn.speaker.\(plan.speaker)"), "The speaker in Play On")
        try await save("playon-speakers", plan)
        app.buttons["playOn.playSpeaker.\(plan.speaker)"].tap()
        waitFor(element("speaker.remote.title"), "The speaker's remote", timeout: 20)
        try await save("speaker-remote", plan, wait: 3)
        _ = tapIfThere(app.buttons["speaker.remote.close"])
        if element("speaker.mini").waitForExistence(timeout: 5) {
            try await save("speaker-mini", plan)
            element("speaker.mini").tap()
            waitFor(app.buttons["speaker.remote.stop"], "The remote again").tap()
        }

        // A kids viewer: the story's page with Play on the speaker, and the kids remote.
        try await start(as: plan.kid, plan)
        waitFor(app.buttons["kids.tab.home"], "The kids screens", timeout: 30)
        XCTAssertTrue(tapIfThere(app.buttons["kids.tab.stories"]), "Stories")
        XCTAssertTrue(tapIfThere(element("kids.story.\(plan.story)")), "The story's page")
        let button = app.buttons["kids.playOnSpeaker.\(plan.speaker)"]
        XCTAssertTrue(button.waitForExistence(timeout: 20), "Play on the speaker")
        for _ in 0..<4 where !button.isHittable { app.swipeUp(velocity: .slow) }
        try await save("kid-story-speaker", plan)
        button.tap()
        waitFor(element("kids.speaker.title"), "The kids remote", timeout: 20)
        try await save("kid-speaker-remote", plan, wait: 3)
        app.buttons["kids.speaker.stop"].tap()
    }
}
