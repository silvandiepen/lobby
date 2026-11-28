// SPDX-License-Identifier: MPL-2.0
import XCTest

/// A manager uploads a film from the iPhone to the real local server, and puts it in the library
/// from the Inbox.
final class UploadUITests: LobbyUITestCase {
    func testAManagerUploadsAFilmAndConfirmsItInTheInbox() async throws {
        let servers = try TestServers.load()
        let file = try XCTUnwrap(servers.uploadFile, "The test server's script made no file to upload.")
        let name = (file as NSString).lastPathComponent
        try await ManagerAPI(server: servers.paired).removeOtherDevices()
        // The file is handed over as if it was picked in Files: the picker is the system's.
        launch(more: ["-lobby-ui-upload-file", file])
        try await pair(with: servers, role: "manager")
        waitFor(app.buttons["profile.Kids"], "The viewer picker").tap()
        waitFor(shelf("series"), "The library")

        app.buttons["profile.menu"].firstMatch.tap()
        waitFor(app.buttons["Settings…"], "Settings in the viewer menu").tap()
        scrolledTo(app.buttons["settings.imports"], "Imports and Uploads").tap()
        let uploads = element("manage.uploads")
        for _ in 0..<4 where !(uploads.exists && uploads.isHittable) { app.swipeUp() }
        waitFor(uploads, "Upload, for a manager").tap()

        // Where it goes, then it is sent in pieces and checked.
        waitFor(element("uploads.destination"), "Where it goes")
        attachScreenshot("upload-destination")
        app.buttons["sheet.confirm"].tap()
        let arrived = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier IN %@ AND label CONTAINS 'Arrived.'", ["upload.state.\(name)", "upload.row.\(name)"])).firstMatch
        waitFor(arrived, "The upload to arrive", timeout: 60)
        attachScreenshot("upload-arrived")

        // A film of a few seconds is far too small for one: it is left out, and imported by hand.
        waitFor(element("uploads.inbox"), "The Inbox").tap()
        waitFor(app.segmentedControls.buttons["Left Out"], "The view of what was left out").tap()
        waitFor(element("inbox.item.\(name)"), "The uploaded film, left out").tap()
        let title = waitFor(app.textFields["importItem.title"], "Its title")
        XCTAssertEqual(title.value as? String, "Sent From Phone")
        attachScreenshot("import-item")
        app.buttons["sheet.confirm"].tap()
        waitFor(app.segmentedControls.buttons["Done"], "The view of what was done").tap()
        waitFor(element("inbox.item.\(name)"), "The film, now in the library", timeout: 20)
    }
}
