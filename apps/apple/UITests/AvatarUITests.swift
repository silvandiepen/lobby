// SPDX-License-Identifier: MPL-2.0
import XCTest

/// Choosing a viewer's picture on an ordinary device, against the real local server.
final class AvatarUITests: LobbyUITestCase {
    /// A viewer for one test: the household's own keep what the other tests expect of them.
    private static let viewer = "Tester"

    private func openPicker(role: String = "viewer") async throws -> ManagerAPI {
        let servers = try TestServers.load()
        let manager = ManagerAPI(server: servers.paired)
        try await manager.removeOtherDevices()
        try await manager.addViewer(Self.viewer)
        addTeardownBlock { try await manager.removeViewer(Self.viewer) }
        launch()
        try await pair(with: servers, role: role)
        waitFor(app.buttons["profile.\(Self.viewer)"], "The viewer picker")
        return manager
    }

    /// From the viewer picker and from the viewer's menu, on a device that is not a manager's.
    func testAViewerChoosesAPictureAndTakesItAwayAgain() async throws {
        let manager = try await openPicker()
        app.buttons["profile.pictures"].tap()
        app.buttons["profile.\(Self.viewer)"].tap()
        let none = waitFor(app.buttons["avatar.none"], "No picture")
        XCTAssertTrue(none.isSelected)
        attachScreenshot("avatar-none")
        app.buttons["avatar.viking-woman"].tap()
        XCTAssertTrue(app.buttons["avatar.viking-woman"].wait(for: \.isSelected, toEqual: true, timeout: 10))
        XCTAssertEqual(element("avatar.preview").label, "\(Self.viewer): Viking woman")
        XCTAssertFalse(none.isSelected)
        attachScreenshot("avatar-picker")
        app.buttons["sheet.done"].tap()
        waitFor(app.buttons["profile.pictures"], "Done")
        attachScreenshot("avatar-viewers")
        var saved = try await manager.avatar(ofViewer: Self.viewer)
        XCTAssertEqual(saved, "viking-woman")
        app.buttons["profile.pictures"].tap()
        app.buttons["profile.\(Self.viewer)"].tap()
        waitFor(shelf("series"), "The library")
        attachScreenshot("avatar-library")

        app.buttons["profile.menu"].firstMatch.tap()
        let choose = waitFor(app.buttons["Choose a Picture…"], "Choose a Picture in the viewer menu")
        attachScreenshot("avatar-menu")
        choose.tap()
        XCTAssertTrue(waitFor(app.buttons["avatar.viking-woman"], "The picture").isSelected)
        for _ in 0..<4 where !app.buttons["avatar.none"].isHittable { app.swipeDown() }
        app.buttons["avatar.none"].tap()
        XCTAssertTrue(app.buttons["avatar.none"].wait(for: \.isSelected, toEqual: true, timeout: 10))
        app.buttons["sheet.done"].tap()
        saved = try await manager.avatar(ofViewer: Self.viewer)
        XCTAssertNil(saved)
    }

    func testANewViewerGetsAPicture() async throws {
        let manager = try await openPicker(role: "manager")
        addTeardownBlock { try await manager.removeViewer("Newcomer") }
        app.buttons["profile.add"].tap()
        let name = waitFor(app.textFields["profile.name"], "The name field")
        name.tap()
        name.typeText("Newcomer")
        app.buttons["profile.newPicture"].tap()
        waitFor(app.buttons["avatar.princess"], "The pictures").tap()
        app.buttons["sheet.done"].tap()
        waitFor(app.buttons["profile.save"], "Add")
        attachScreenshot("avatar-new-viewer")
        app.buttons["profile.save"].tap()
        waitFor(app.buttons["profile.Newcomer"], "The new viewer")
        let saved = try await manager.avatar(ofViewer: "Newcomer")
        XCTAssertEqual(saved, "princess")
    }

    func testThePickerWithLargeTextInTheDark() async throws {
        _ = try await openPicker()
        app.terminate()
        app.launchArguments = ["-lobby-mute", "YES", "-lobby-namespace", "ui-tests", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        XCUIDevice.shared.appearance = .dark
        addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = .light }
        app.launch()
        let pictures = waitFor(app.buttons["profile.pictures"], "Choose Pictures")
        for _ in 0..<5 where !pictures.isHittable { app.swipeUp() }
        pictures.tap()
        let viewer = app.buttons["profile.\(Self.viewer)"]
        for _ in 0..<5 where !viewer.isHittable { app.swipeDown() }
        viewer.tap()
        let panda = waitFor(app.buttons["avatar.panda"], "The panda")
        for _ in 0..<5 where !panda.isHittable { app.swipeUp() }
        XCTAssertTrue(panda.isHittable)
        XCTAssertGreaterThanOrEqual(panda.frame.height, 44)
        attachScreenshot("avatar-dark-large")
    }
}
