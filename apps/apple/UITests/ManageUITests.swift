// SPDX-License-Identifier: MPL-2.0
import XCTest

/// What a manager does from the iPhone, against the real local server.
final class ManageUITests: LobbyUITestCase {
    func pairAsManager() async throws -> TestServers {
        let servers = try TestServers.load()
        // Every test paired this simulator, under the same name: only the one of now counts.
        try await ManagerAPI(server: servers.paired).removeOtherDevices()
        launch()
        try await pair(with: servers, role: "manager")
        waitFor(app.buttons["profile.Kids"], "The viewer picker").tap()
        waitFor(shelf("series"), "The library")
        return servers
    }

    func openSettings() {
        app.buttons["profile.menu"].firstMatch.tap()
        waitFor(app.buttons["Settings…"], "Settings in the viewer menu").tap()
    }

    /// The next episodes of a series are sent to a device from the series' page; the device
    /// fetches them by itself, its page says so, and taking them off removes them.
    func testTheNextEpisodesAreSentToADeviceArriveAndAreTakenOff() async throws {
        _ = try await pairAsManager()

        waitFor(shelf("series").buttons["Test Show"], "The show on its shelf").tap()
        waitFor(app.buttons["detail.sendToDevice"], "Send to Device").tap()
        let send = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'send.send.iP'")).firstMatch
        waitFor(send, "Send, on this device")
        XCTAssertTrue(element("send.count").exists, "The number of episodes can be chosen.")
        attachScreenshot("send-to-device")
        send.tap()
        waitFor(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'send.takeOff.iP'")).firstMatch, "The rule on the device's list")
        app.buttons["sheet.done"].tap()

        // It arrives by itself.
        app.tabBars.buttons["Downloads"].tap()
        let done = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'downloads.show.Test Show' AND label CONTAINS ', 3 episodes downloaded'")).firstMatch
        waitFor(done, "All three episodes to be downloaded", timeout: 90)

        // The manager sees it on the device's page.
        app.tabBars.buttons["Home"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        openSettings()
        scrolledTo(app.buttons["settings.manage"], "Devices and Viewers").tap()
        let device = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'manage.device.iP'")).firstMatch
        for _ in 0..<4 where !(device.exists && device.isHittable) { app.swipeUp() }
        attachScreenshot("manage-devices")
        device.tap()
        attachScreenshot("device-page-opening")
        waitFor(app.staticTexts["3 of 3 on the device"], "The device's own report", timeout: 60)
        attachScreenshot("device-page")

        app.buttons["device.takeOff.Test Show"].firstMatch.tap()
        waitFor(app.buttons["device.confirmTakeOff"].firstMatch, "The confirmation").tap()
        XCTAssertTrue(app.staticTexts["3 of 3 on the device"].waitForNonExistence(timeout: 15))
    }

    /// A category is made with an icon and a colour, renamed, and deleted again, and the
    /// library follows. The names are the test household's own.
    func testACategoryIsMadeRenamedAndDeleted() async throws {
        _ = try await pairAsManager()
        openSettings()
        scrolledTo(app.buttons["settings.categories"], "Categories").tap()
        waitFor(element("categories.row.Zebra Tales"), "The household's categories")
        attachScreenshot("categories")

        let add = element("categories.add.Kids")
        for _ in 0..<4 where !(add.exists && add.isHittable) { app.swipeUp() }
        add.tap()
        let name = waitFor(app.textFields["category.name"], "The name field")
        name.tap()
        name.typeText("Garden Films")
        // Icons that fit the name are suggested while it is typed; nothing is set by itself.
        waitFor(app.buttons["category.suggestion.camera.macro"], "A suggestion for the name")
        app.buttons["category.chooseIcon"].tap()
        let search = waitFor(app.textFields["icon.search"], "The icon search")
        search.tap()
        search.typeText("qwxzq")
        waitFor(element("icon.empty"), "That nothing was found")
        app.buttons["icon.clear"].tap()
        search.tap()
        search.typeText("ster")
        attachScreenshot("icon-search")
        waitFor(app.buttons["icon.result.star.fill"], "The star, by its Dutch name").tap()
        attachScreenshot("category-editor")
        app.buttons["sheet.confirm"].tap()
        let row = element("categories.row.Garden Films")
        waitFor(row, "The new category in its group")

        row.tap()
        let again = waitFor(app.textFields["category.name"], "The name field")
        again.tap()
        again.typeText(" 2")
        app.buttons["sheet.confirm"].tap()
        let renamed = element("categories.row.Garden Films 2")
        waitFor(renamed, "The renamed category")
        attachScreenshot("categories-after")

        renamed.press(forDuration: 1.2)
        waitFor(app.buttons["Delete…"], "Delete in its menu").tap()
        waitFor(app.buttons["categories.confirmDelete"].firstMatch, "The confirmation").tap()
        XCTAssertTrue(renamed.waitForNonExistence(timeout: 15))
        // Nothing else changed.
        XCTAssertTrue(element("categories.row.Zebra Tales").exists)
    }

    /// A manager changes a film's title, the library shows it, and it is put back.
    func testAFilmsTitleIsEditedAndPutBack() async throws {
        _ = try await pairAsManager()
        waitFor(shelf("movies").buttons["Short Notice, 2021"], "The film on its shelf").tap()
        waitFor(app.buttons["detail.more"], "More").tap()
        waitFor(app.buttons["Edit…"], "Edit in the menu").tap()
        let title = waitFor(app.textFields["edit.title"], "The title field")
        title.tap()
        title.typeText(" Edited")
        attachScreenshot("edit-film")
        app.buttons["sheet.confirm"].tap()
        XCTAssertTrue(app.staticTexts["Short Notice Edited"].waitForExistence(timeout: 20), "The page shows the new title.")

        waitFor(app.buttons["detail.more"], "More").tap()
        waitFor(app.buttons["Edit…"], "Edit in the menu").tap()
        waitFor(app.buttons["edit.putBack.title"], "Put Back, beside a changed title").tap()
        let backdrop = element("edit.artwork.backdrop")
        for _ in 0..<4 where !(backdrop.exists && backdrop.isHittable) { app.swipeUp() }
        attachScreenshot("edit-film-pictures")
        backdrop.tap()
        let frame = app.buttons["artwork.frame"]
        for _ in 0..<4 where !(frame.exists && frame.isHittable) { app.swipeUp() }
        waitFor(app.buttons["artwork.frame"], "A frame from the film")
        app.buttons["artwork.frame"].tap()
        waitFor(app.buttons["artwork.putBack"], "The frame, chosen", timeout: 30)
        attachScreenshot("edit-artwork")
        app.buttons["artwork.putBack"].tap()
        XCTAssertTrue(app.buttons["artwork.putBack"].waitForNonExistence(timeout: 20))
        app.buttons["sheet.done"].firstMatch.tap()
        app.buttons["sheet.confirm"].tap()
        XCTAssertTrue(app.staticTexts["Short Notice"].waitForExistence(timeout: 20), "The page shows the file's title again.")
    }

    /// A series is marked watched as a whole, from its page, by whoever watches.
    func testASeriesIsMarkedWatchedAndUnwatched() async throws {
        let servers = try TestServers.load()
        launch()
        try await pair(with: servers)
        waitFor(app.buttons["profile.Kids"], "The viewer picker").tap()
        waitFor(shelf("series").buttons["Test Show"], "The show on its shelf").tap()
        waitFor(app.buttons["detail.more"], "More").tap()
        XCTAssertFalse(app.buttons["Edit Series…"].exists, "A viewer edits nothing.")
        waitFor(app.buttons["Mark All as Watched"].firstMatch, "Mark All as Watched").tap()
        // The episodes are under the Related row.
        scrolledTo(element("episode.1"), "The first episode")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'episode.1' AND label CONTAINS 'Watched'")).firstMatch.waitForExistence(timeout: 15))
        app.buttons["detail.more"].tap()
        waitFor(app.buttons["Start from Beginning"], "Start from Beginning")
        waitFor(app.buttons["Mark All as Unwatched"].firstMatch, "Mark All as Unwatched").tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'episode.1' AND label CONTAINS 'Watched'")).firstMatch.waitForNonExistence(timeout: 15))
    }
}
