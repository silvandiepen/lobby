// SPDX-License-Identifier: MPL-2.0
import XCTest

/// Every kids screen against a server somebody set up for looking at them, with a screenshot
/// of each. Not part of the automated suite: it skips unless `build/kids-walkthrough.json`
/// exists.
///
///     {
///       "server": { "url": "http://127.0.0.1:18690", "managerToken": "…" },
///       "screenshots": "/absolute/path",     PNGs are written here
///       "onHere": ["Title"]                  films sent to the device, for On here
///     }
///
/// The server has a kids viewer "Kids" that is allowed films and series, some of them started.
final class KidsWalkthrough: LobbyUITestCase {
    private struct Plan: Decodable {
        var server: TestServers.Paired
        var screenshots: String
        var onHere: [String]
    }

    private func plan(file: StaticString = #filePath) throws -> Plan {
        let json = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "build/kids-walkthrough.json")
        guard let data = try? Data(contentsOf: json) else {
            throw XCTSkip("No build/kids-walkthrough.json: the walkthrough was not asked for.")
        }
        return try JSONDecoder().decode(Plan.self, from: data)
    }

    private var prefix: String {
        app.windows.firstMatch.frame.width > 700 ? "ipad" : "iphone"
    }

    private func save(_ name: String, _ plan: Plan) throws {
        // Pictures arrive after the page.
        _ = app.staticTexts["never"].waitForExistence(timeout: 2)
        try XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: plan.screenshots).appending(path: "\(prefix)-\(name).png"))
    }

    func testEveryScreen() async throws {
        let plan = try plan()
        let manager = ManagerAPI(server: plan.server)
        try await manager.removeOtherDevices()
        app.launchArguments = ["-lobby-mute", "YES", "-lobby-namespace", "kids-walkthrough", "-lobby-reset", "YES"]
        app.launch()
        typeAddress(plan.server.url)
        waitFor(app.buttons["connect.pair"], "Pair").tap()
        let code = waitFor(element("connect.code"), "The pairing code")
        try await manager.approve(code: (code.value as? String ?? "").filter(\.isNumber))
        waitFor(app.buttons["profile.Kids"], "The viewer picker").tap()
        waitFor(app.buttons["kids.tab.home"], "The kids screens")
        try await manager.send(plan.onHere)

        try save("home", plan)
        for tab in ["movies", "series"] {
            app.buttons["kids.tab.\(tab)"].tap()
            try save(tab, plan)
        }
        app.buttons["kids.tab.movies"].tap()
        let film = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'kids.poster.'")).firstMatch
        waitFor(film, "A film").tap()
        try save("film", plan)
        app.buttons["kids.back"].tap()
        app.buttons["kids.tab.series"].tap()
        waitFor(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'kids.poster.'")).firstMatch, "A series").tap()
        try save("series-page", plan)
        app.swipeUp()
        try save("series-episodes", plan)
        app.buttons["kids.back"].tap()
        app.buttons["kids.tab.onHere"].tap()
        if let last = plan.onHere.last {
            // The device looks at its list when it comes to the front.
            XCUIDevice.shared.press(.home)
            app.activate()
            waitFor(app.buttons["kids.poster.\(last)"], "The downloads", timeout: 120)
        }
        try save("on-here", plan)

        XCUIDevice.shared.appearance = .dark
        try save("dark-on-here", plan)
        for tab in ["home", "movies", "series"] {
            app.buttons["kids.tab.\(tab)"].tap()
            try save("dark-\(tab)", plan)
        }
        XCUIDevice.shared.appearance = .light

        app.buttons["kids.avatar"].tap()
        try save("avatar", plan)
        let out = app.buttons["kids.grownUps"]
        for _ in 0..<8 where !out.isHittable { app.swipeUp() }
        out.tap()
        try save("grown-ups", plan)
    }
}
