// SPDX-License-Identifier: MPL-2.0
import XCTest

/// Kids mode against the real local server: the four places, a film, a series, and that
/// nothing leads out. Needs a server that knows kids viewers.
final class KidsUITests: LobbyUITestCase {
    /// A viewer for one test: the household's own keep what the other tests expect of them.
    private static let child = "Child"

    /// Adds a kids viewer and opens the app as them. The viewer goes again after the test.
    private func openAsKid(_ kids: [String: [String]]) async throws -> TestServers {
        let servers = try TestServers.load()
        let manager = ManagerAPI(server: servers.paired)
        try await manager.removeOtherDevices()
        try await manager.addViewer(Self.child)
        addTeardownBlock {
            // A viewer a device belongs to is not removed.
            try await manager.removeOtherDevices()
            try await manager.removeViewer(Self.child)
        }
        guard try await manager.setKids(kids, ofViewer: Self.child) else {
            throw XCTSkip("This Lobby Server does not know kids viewers yet.")
        }
        launch()
        try await pair(with: servers)
        waitFor(app.buttons["profile.\(Self.child)"], "The viewer picker").tap()
        waitFor(app.buttons["kids.tab.home"], "The kids screens")
        return servers
    }

    private func everything() async throws -> [String: [String]] {
        let servers = try TestServers.load()
        return ["allowedGroupIds": try await ManagerAPI(server: servers.paired).groupIDs()]
    }

    /// The page's name. The last page may still be fading away.
    private func expectHeading(_ name: String, line: UInt = #line) {
        waitFor(
            app.staticTexts.matching(NSPredicate(format: "identifier == 'kids.heading' AND label == %@", name)).firstMatch,
            "The page \(name)", line: line)
    }

    func testTheFourPlacesAndAFilmThatPlays() async throws {
        _ = try await openAsKid(try await everything())
        expectHeading(Self.child)
        XCTAssertFalse(app.searchFields.firstMatch.exists)
        XCTAssertFalse(app.buttons["profile.menu"].exists)
        waitFor(app.buttons["kids.poster.Short Notice"], "A film that plays")
        // The server would have to convert this one first.
        XCTAssertFalse(app.buttons["kids.poster.Old Format"].exists)
        attachScreenshot("kids-home")

        app.buttons["kids.tab.movies"].tap()
        expectHeading("Movies")
        waitFor(app.buttons["kids.poster.The Long Test"], "A film on Movies").tap()
        waitFor(app.buttons["kids.sayIt"], "The speaker").tap()
        attachScreenshot("kids-film")
        app.buttons["kids.play"].tap()
        try closePlayer(afterPlayingPast: 8)
        XCTAssertEqual(waitFor(app.buttons["kids.play"], "The film's page").label, "Resume")
        app.buttons["kids.back"].tap()

        app.buttons["kids.tab.home"].tap()
        waitFor(app.buttons["kids.continue.The Long Test"], "The card to go on with")
        attachScreenshot("kids-home-continue")

        app.buttons["kids.tab.series"].tap()
        waitFor(app.buttons["kids.poster.Test Show"], "The series").tap()
        waitFor(app.buttons["kids.play"], "One Play")
        attachScreenshot("kids-series-page")
        let second = app.buttons["kids.season.Season 2"]
        for _ in 0..<3 where !(second.exists && second.isHittable) { app.swipeUp() }
        second.tap()
        waitFor(app.buttons["kids.episode.1"], "Its first episode")
        app.buttons["kids.back"].tap()

        app.buttons["kids.tab.onHere"].tap()
        expectHeading("On here")
        waitFor(element("kids.nothing"), "Nothing on here yet")
    }

    func testOnlyWhatIsAllowedIsThereAlsoAfterARelaunch() async throws {
        let servers = try TestServers.load()
        let film = try await ManagerAPI(server: servers.paired).itemID(titled: "Short Notice")
        _ = try await openAsKid(["allowedItemIds": [film]])
        app.buttons["kids.tab.movies"].tap()
        waitFor(app.buttons["kids.poster.Short Notice"], "The one allowed film")
        XCTAssertFalse(app.buttons["kids.poster.The Long Test"].exists)
        app.buttons["kids.tab.series"].tap()
        waitFor(element("kids.nothing"), "No series")

        app.terminate()
        launch(clean: false)
        waitFor(app.buttons["kids.tab.movies"], "The kids screens, at once").tap()
        waitFor(app.buttons["kids.poster.Short Notice"], "The one allowed film")
        // A long press opens nothing.
        app.buttons["kids.poster.Short Notice"].press(forDuration: 1.2)
        XCTAssertEqual(app.menuItems.count, 0)
        XCTAssertFalse(app.buttons["detail.more"].exists)
    }

    /// The simulator asks for a passcode and takes any. Without an answer the child stays; with
    /// one, the grown-up gets the picker, and leaving the app there is kids mode again.
    func testOnlyAGrownUpLeadsOut() async throws {
        _ = try await openAsKid(try await everything())
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.buttons["kids.avatar"].tap()
        leaveThroughTheGrownUps()
        let passcode = waitFor(system.secureTextFields.firstMatch, "The passcode question")
        attachScreenshot("kids-gate")
        XCTAssertFalse(app.buttons["profile.Alex"].exists, "The picker is behind the gate.")
        passcode.tap()
        passcode.typeText("1234\r")
        waitFor(app.buttons["profile.Alex"], "The viewer picker")

        XCUIDevice.shared.press(.home)
        app.activate()
        waitFor(app.buttons["kids.tab.home"], "The kids screens")
        XCTAssertFalse(app.buttons["profile.Alex"].exists)
    }

    /// The whole way out, as on a phone: the picture, For grown-ups, the system's question, Who
    /// is watching, and a grown-up who is then the one watching, out of the kids screens.
    /// A simulator with Face ID enrolled answers a match sent from the Mac
    /// (`notifyutil -p com.apple.BiometricKit_Sim.pearl.match`); without, it asks for a passcode.
    func testAGrownUpLeavesAndWatchesAsThemselves() async throws {
        _ = try await openAsKid(try await everything())
        app.buttons["kids.avatar"].tap()
        // The pictures as they come up, with the way out under them.
        _ = waitFor(app.buttons["kids.avatars.done"], "The pictures").wait(for: \.isHittable, toEqual: true, timeout: 5)
        attachScreenshot("kids-way-out")
        leaveThroughTheGrownUps()
        let passcode = XCUIApplication(bundleIdentifier: "com.apple.springboard").secureTextFields.firstMatch
        let picker = app.buttons["profile.Alex"]
        for _ in 0..<30 where !picker.exists {
            if passcode.exists {
                passcode.tap()
                passcode.typeText("1234\r")
                break
            }
            _ = picker.waitForExistence(timeout: 1)
        }
        waitFor(picker, "Who is watching")
        attachScreenshot("kids-left")
        picker.tap()
        waitFor(app.buttons["profile.menu"].firstMatch, "The grown-up's library")
        XCTAssertFalse(app.buttons["kids.tab.home"].exists, "Still on the kids screens.")
        attachScreenshot("kids-left-library")

        // And it stays so after a relaunch.
        app.terminate()
        launch(clean: false)
        waitFor(app.buttons["profile.menu"].firstMatch, "The grown-up's library again")
        XCTAssertFalse(app.buttons["kids.tab.home"].exists)
    }

    func testABoundDeviceOpensOnTheKidsScreensAndHasNoPicker() async throws {
        let servers = try await openAsKid(try await everything())
        let manager = ManagerAPI(server: servers.paired)
        try await manager.bindOtherDevices(toViewer: Self.child)
        app.terminate()
        launch(clean: false)
        waitFor(app.buttons["kids.tab.home"], "The kids screens")
        waitFor(app.buttons["kids.poster.Short Notice"], "Its films")
        XCTAssertFalse(app.buttons["profile.Alex"].exists)
        // Past the question there is only a page that says who can change it.
        app.buttons["kids.avatar"].tap()
        leaveThroughTheGrownUps()
        let passcode = waitFor(XCUIApplication(bundleIdentifier: "com.apple.springboard").secureTextFields.firstMatch, "The passcode question")
        passcode.tap()
        passcode.typeText("1234\r")
        waitFor(element("kids.notice.bound"), "Who can change it")
        XCTAssertFalse(app.buttons["profile.Alex"].exists)
        attachScreenshot("kids-bound")
    }

    /// The way out is in sight as the pictures open, on a phone too: nobody scrolls for it.
    private func leaveThroughTheGrownUps(line: UInt = #line) {
        let out = waitFor(app.buttons["kids.grownUps"], "For grown-ups", line: line)
        XCTAssertTrue(out.isHittable, "For grown-ups is out of sight.", line: line)
        out.tap()
    }

    /// A child picks a picture without being asked for anything, and it is there after a
    /// relaunch and on the server.
    func testAChildPicksAPicture() async throws {
        let servers = try await openAsKid(try await everything())
        app.buttons["kids.avatar"].tap()
        let panda = waitFor(app.buttons["avatar.panda"], "The panda")
        attachScreenshot("kids-avatars")
        for _ in 0..<4 where !panda.isHittable { app.swipeUp() }
        panda.tap()
        XCTAssertTrue(panda.wait(for: \.isSelected, toEqual: true, timeout: 10))
        attachScreenshot("kids-avatars-panda")
        app.buttons["kids.avatars.done"].tap()
        waitFor(app.buttons["kids.tab.home"], "The kids screens")
        XCTAssertFalse(app.buttons["profile.Alex"].exists)
        attachScreenshot("kids-home-panda")
        let saved = try await ManagerAPI(server: servers.paired).avatar(ofViewer: Self.child)
        XCTAssertEqual(saved, "panda")

        app.terminate()
        launch(clean: false)
        waitFor(app.buttons["kids.avatar"], "The avatar").tap()
        XCTAssertTrue(waitFor(app.buttons["avatar.panda"], "The panda").isSelected)
    }

    func testDarkAndLargeText() async throws {
        _ = try await openAsKid(try await everything())
        app.terminate()
        app.launchArguments = ["-lobby-mute", "YES", "-lobby-namespace", "ui-tests", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        XCUIDevice.shared.appearance = .dark
        addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = .light }
        app.launch()
        for tab in ["home", "movies", "series", "onHere"] {
            let button = waitFor(app.buttons["kids.tab.\(tab)"], "The tab")
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            button.tap()
            attachScreenshot("kids-dark-large-\(tab)")
        }
        app.buttons["kids.tab.movies"].tap()
        waitFor(app.buttons["kids.poster.Short Notice"], "A film").tap()
        XCTAssertTrue(waitFor(app.buttons["kids.play"], "Play").isHittable)
        attachScreenshot("kids-dark-large-film")
    }

    /// A manager makes a kids viewer and allows a part of the library.
    func testAManagerMakesAKidsViewer() async throws {
        let servers = try TestServers.load()
        let manager = ManagerAPI(server: servers.paired)
        try await manager.removeOtherDevices()
        try await manager.addViewer(Self.child)
        addTeardownBlock { try await manager.removeViewer(Self.child) }
        guard try await manager.setKids(nil, ofViewer: Self.child) else {
            throw XCTSkip("This Lobby Server does not know kids viewers yet.")
        }
        launch()
        try await pair(with: servers, role: "manager")
        waitFor(app.buttons["profile.Guest"], "The viewer picker").tap()
        waitFor(shelf("series"), "The library")
        openManage()
        let viewer = element("manage.viewer.\(Self.child)")
        for _ in 0..<5 where !(viewer.exists && viewer.isHittable) { app.swipeUp() }
        viewer.tap()
        let toggle = waitFor(app.switches["viewer.kids"], "Kids Viewer")
        toggle.switches.firstMatch.tap()
        let group = app.switches["viewer.group.Kids"]
        waitFor(element("viewer.summary"), "What there is to watch")
        for _ in 0..<4 where !(group.exists && group.isHittable) { app.swipeUp() }
        group.switches.firstMatch.tap()
        attachScreenshot("manage-viewer")
        let summary = app.staticTexts.matching(NSPredicate(format: "label == '2 films and 0 series to watch.'")).firstMatch
        for _ in 0..<4 where !summary.exists { app.swipeDown() }
        waitFor(summary, "What there is to watch now")
        attachScreenshot("manage-viewer-allowed")
        let saved = try await manager.kidsGroups(ofViewer: Self.child)
        XCTAssertEqual(saved.count, 1)
    }

    private func openManage() {
        let row = app.descendants(matching: .any)["sidebar.Devices and Viewers"].firstMatch
        if row.exists {
            // Not the symbol of the row, which takes no taps of its own.
            row.coordinate(withNormalizedOffset: CGVector(dx: 2, dy: 0.5)).tap()
        } else {
            app.buttons["profile.menu"].firstMatch.tap()
            waitFor(app.buttons["Settings…"], "Settings in the viewer menu").tap()
            scrolledTo(app.buttons["settings.viewers"], "Viewers").tap()
        }
    }
}
