// SPDX-License-Identifier: MPL-2.0
import XCTest

final class ManagerMacUITests: MacUITestCase {
    /// The Mac sets up a new server, becomes its manager, lets a waiting iPhone in with one click,
    /// removes it again, and keeps the list of viewers.
    func testAManagerClaimsApprovesADeviceAndKeepsTheViewers() async throws {
        let servers = try TestServers.load()
        launch()

        waitFor(app.buttons["connect.enterAddress"], "Enter Address").click()
        type(servers.fresh.url.absoluteString, into: waitFor(app.textFields["connect.address"], "The address field"))
        app.buttons["connect.continue"].click()
        waitFor(app.buttons["connect.setUp"], "Set Up This Server, on a new server").click()
        try skipWithoutAKeychain(unless: "profile.none")

        // The first viewer.
        app.buttons["profile.add"].click()
        type("Tester", into: waitFor(app.textFields["profile.name"], "The name field"))
        app.buttons["profile.save"].click()
        waitFor(app.buttons["profile.Tester"], "The new viewer").click()

        // The manager's page is in the sidebar, and has a key.
        waitFor(element("sidebar.Devices and Viewers"), "The manager's page in the sidebar")
        app.typeKey("5", modifierFlags: .command)
        waitFor(app.textFields["manage.code"], "The code field")
        waitFor(element("manage.server"), "The server's status")

        // An iPhone asks to join and shows a code.
        let asked = try await requestPairing(at: servers.fresh.url, deviceName: "Test iPhone")
        app.typeKey("r", modifierFlags: .command)
        waitFor(element("manage.waiting.Test iPhone"), "The device that is waiting")
        // One click on the waiting device approves it: no code to type.
        waitFor(app.buttons["manage.approveWaiting.Test iPhone"], "Approve, on the waiting device").click()
        waitForGone(element("manage.waiting.Test iPhone"), "The device that was waiting")
        // The iPhone collects its credential, and is a device from then on.
        try await asked.collect()
        app.typeKey("r", modifierFlags: .command)
        waitFor(element("manage.device.Test iPhone"), "The approved device in the list")
        try save("mac-manage-device-approved")

        // Remove it again.
        element("manage.device.Test iPhone").click()
        waitFor(app.buttons["device.remove"].firstMatch, "Remove Device, on its page").click()
        waitFor(app.buttons["manage.confirmRemoveDevice"].firstMatch, "The confirmation").click()
        waitForGone(element("manage.device.Test iPhone"), "The removed device")

        // A second viewer, added and removed.
        app.buttons["manage.addViewer"].click()
        type("Kid", into: waitFor(app.textFields["profile.name"], "The name field"))
        app.buttons["profile.save"].click()
        waitFor(element("manage.viewer.Kid"), "The new viewer in the list")
        app.buttons["manage.removeViewer.Kid"].click()
        waitFor(app.buttons["manage.confirmRemoveViewer"].firstMatch, "The confirmation").click()
        waitForGone(element("manage.viewer.Kid"), "The removed viewer")
    }

    /// A Mac paired as a viewer browses and plays, and has none of the manager's tools.
    func testAViewerMacBrowsesPlaysAndHasNoManagerTools() async throws {
        let servers = try TestServers.load()
        launch()

        waitFor(app.buttons["connect.enterAddress"], "Enter Address").click()
        type(servers.paired.url.absoluteString, into: waitFor(app.textFields["connect.address"], "The address field"))
        app.buttons["connect.continue"].click()
        waitFor(app.buttons["connect.pair"], "Pair This Device").click()
        try skipWithoutAKeychain(unless: "connect.code")
        let shown = waitFor(element("connect.code"), "The pairing code")
        let digits = ((shown.value as? String ?? "") + shown.label).filter(\.isNumber).prefix(6)
        try await ManagerAPI(server: servers.paired).approve(code: String(digits), role: "viewer")
        waitFor(app.buttons["profile.Guest"], "The viewer picker").click()

        waitFor(element("sidebar.Movies"), "The sidebar")
        XCTAssertFalse(element("sidebar.Devices and Viewers").exists, "A viewer device has no manager page.")
        XCTAssertFalse(app.menuItems["Devices and Viewers"].exists, "Nor a menu item for it.")
        try save("mac-library-viewer")

        // Keys reach every section.
        app.typeKey("2", modifierFlags: .command)
        waitFor(app.buttons["Short Notice, 2021"].firstMatch, "The Movies grid").click()
        waitFor(app.buttons["detail.play"], "Play").click()
        waitFor(element("player.title"), "The player")
        // Twelve seconds of film: it plays to its end and the player closes itself.
        waitForGone(element("player.title"), "The player after the film ended", timeout: 60)
        waitFor(app.buttons["detail.play"], "The film's page")
    }
}
