// SPDX-License-Identifier: MPL-2.0
import XCTest

/// Pictures of the screens on iPhone and iPad, dark and light, against a local server that was
/// already set up, for looking at the app by eye. Skips unless `build/look.json` exists:
///
///     { "server": "http://127.0.0.1:18774", "managerToken": "…", "screenshots": "/absolute/folder" }
final class LookWalkthrough: LobbyUITestCase {
    private struct Plan: Decodable {
        var server: URL
        var managerToken: String
        var screenshots: String
    }

    private func plan(file: StaticString = #filePath) throws -> Plan {
        let json = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/look.json")
        guard let data = try? Data(contentsOf: json) else {
            throw XCTSkip("No build/look.json: pictures of the screens were not asked for.")
        }
        return try JSONDecoder().decode(Plan.self, from: data)
    }

    func testScreens() async throws {
        let plan = try plan()
        let folder = URL(filePath: plan.screenshots)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        var look = "dark"
        func shoot(_ name: String) async throws {
            try await Task.sleep(for: .seconds(1.5))
            try XCUIScreen.main.screenshot().pngRepresentation
                .write(to: folder.appending(path: "\(isPad ? "ipad" : "iphone")-\(look)-\(name).png"))
        }

        XCUIDevice.shared.appearance = .dark
        launch()
        typeAddress(plan.server)
        waitFor(element("connect.server"), "The server's name")
        app.buttons["connect.pair"].tap()
        try skipWithoutAKeychain(unless: "connect.code")
        let code = (waitFor(element("connect.code"), "The pairing code").value as? String ?? "").filter(\.isNumber)
        try await ManagerAPI(server: .init(url: plan.server, managerToken: plan.managerToken)).approve(code: code, role: "manager")
        let viewer = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'profile.'")).firstMatch
        waitFor(viewer, "A viewer").tap()
        waitFor(shelf("movies"), "The library")

        for (name, appearance) in [("dark", XCUIDevice.Appearance.dark), ("light", .light)] {
            look = name
            XCUIDevice.shared.appearance = appearance
            try await shoot("library")
            if isPad {
                app.staticTexts["sidebar.Movies"].firstMatch.tap()
                try await shoot("movies")
                waitFor(element("sidebar.genres"), "The genres' heading").tap()
                try await shoot("genres")
                element("sidebar.genres").tap()
                app.staticTexts["sidebar.Categories"].firstMatch.tap()
                try await shoot("categories")
                editIcon()
                try await shoot("icons")
                closeSheets()
                app.staticTexts["sidebar.Devices and Viewers"].firstMatch.tap()
                try await shoot("devices")
                app.staticTexts["sidebar.Home"].firstMatch.tap()
            } else {
                app.buttons["profile.menu"].firstMatch.tap()
                waitFor(app.buttons["Settings…"], "Settings in the viewer menu").tap()
                try await shoot("settings")
                scrolledTo(app.buttons["settings.categories"], "Categories").tap()
                waitFor(app.buttons["categories.addGroup"], "The categories")
                try await shoot("categories")
                editIcon()
                try await shoot("icons")
                closeSheets()
                app.navigationBars.buttons.firstMatch.tap()
                scrolledTo(app.buttons["settings.manage"], "Devices and Viewers").tap()
                try await shoot("devices")
                app.navigationBars.buttons.firstMatch.tap()
                waitFor(app.buttons["Done"], "Done").tap()
            }
        }
    }

    /// Home, a category, titles and the kids' pages: what starts with a picture. The server has
    /// a viewer called Robin, and a kids viewer called Juno.
    func testHomePages() async throws {
        let plan = try plan()
        let folder = URL(filePath: plan.screenshots)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        if isPad { XCUIDevice.shared.orientation = .landscapeLeft }
        func shoot(_ name: String, after seconds: Double = 2) async throws {
            try await Task.sleep(for: .seconds(seconds))
            try XCUIScreen.main.screenshot().pngRepresentation
                .write(to: folder.appending(path: "\(isPad ? "ipad" : "iphone")-\(name).png"))
        }

        XCUIDevice.shared.appearance = .dark
        launch()
        typeAddress(plan.server)
        waitFor(element("connect.server"), "The server's name")
        app.buttons["connect.pair"].tap()
        try skipWithoutAKeychain(unless: "connect.code")
        let code = (waitFor(element("connect.code"), "The pairing code").value as? String ?? "").filter(\.isNumber)
        try await ManagerAPI(server: .init(url: plan.server, managerToken: plan.managerToken)).approve(code: code, role: "viewer")
        waitFor(app.buttons["profile.Robin"], "The viewer").tap()
        waitFor(app.buttons["banner.play"], "The banner", timeout: 40)

        for (look, appearance) in [("dark", XCUIDevice.Appearance.dark), ("light", .light)] {
            XCUIDevice.shared.appearance = appearance
            try await shoot("\(look)-home", after: 3)
            app.swipeLeft()
            try await shoot("\(look)-home-next")
            app.buttons["banner.info"].firstMatch.tap()
            waitFor(app.buttons["detail.play"].firstMatch, "The title's page")
            try await shoot("\(look)-title")
            app.swipeUp()
            try await shoot("\(look)-title-below")
            app.navigationBars.buttons.firstMatch.tap()
            waitFor(app.buttons["banner.play"].firstMatch, "Home")
            app.swipeUp()
            try await shoot("\(look)-home-rows")
            let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tile.category.'")).firstMatch
            if tile.exists {
                tile.tap()
                try await shoot("\(look)-category")
                app.navigationBars.buttons.firstMatch.tap()
            }
            for _ in 0..<3 { app.swipeDown() }
            if isPad {
                app.staticTexts["sidebar.Series"].firstMatch.tap()
                try await shoot("\(look)-series")
                app.staticTexts["sidebar.Home"].firstMatch.tap()
            } else {
                app.buttons["filter.Series"].tap()
                try await shoot("\(look)-series")
                app.buttons["filter.Home"].tap()
            }
        }
        app.buttons["profile.menu"].firstMatch.tap()
        waitFor(viewerInMenu("Juno"), "The kids viewer").tap()
        waitFor(app.buttons["kids.tab.home"], "The kids screens")
        for (look, appearance) in [("dark", XCUIDevice.Appearance.dark), ("light", .light)] {
            XCUIDevice.shared.appearance = appearance
            for tab in ["movies", "series", "home"] {
                app.buttons["kids.tab.\(tab)"].tap()
                try await shoot("\(look)-kids-\(tab)")
            }
            app.buttons["kids.banner.open"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.35)).tap()
            waitFor(app.buttons["kids.play"], "The title's page")
            try await shoot("\(look)-kids-title")
            app.buttons["kids.back"].firstMatch.tap()
            app.swipeUp()
            try await shoot("\(look)-kids-home-rows")
            app.swipeDown()
            let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'kids.category.'")).firstMatch
            if tile.exists, !tile.isHittable { app.swipeUp() }
            if tile.exists {
                tile.tap()
                try await shoot("\(look)-kids-category")
                app.buttons["kids.back"].firstMatch.tap()
            }
        }
        XCUIDevice.shared.appearance = .dark
    }

    private func editIcon() {
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'categories.row.'")).element(boundBy: 2)
        waitFor(row, "A category").tap()
        waitFor(app.buttons["category.chooseIcon"], "Choose an Icon").tap()
        waitFor(app.textFields["icon.search"], "The icon selector")
    }

    private func closeSheets() {
        app.buttons["sheet.done"].firstMatch.tap()
        waitFor(app.buttons["Cancel"].firstMatch, "The editor").tap()
        waitForGone()
    }

    private func waitForGone() {
        XCTAssertTrue(app.buttons["category.chooseIcon"].waitForNonExistence(timeout: 10))
    }
}
