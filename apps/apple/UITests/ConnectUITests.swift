// SPDX-License-Identifier: MPL-2.0
import XCTest

final class ConnectUITests: LobbyUITestCase {
    /// No server needed: nothing listens on the discard port.
    func testAnUnreachableServerIsExplainedAsUnreachable() {
        launch()
        typeAddress(URL(string: "http://127.0.0.1:9")!)

        let problem = waitFor(element("connect.problem"), "The explanation")
        XCTAssertTrue(problem.label.contains("cannot be reached"), problem.label)
        XCTAssertTrue(problem.label.contains("Tailscale"), "It should say what to check: \(problem.label)")
        XCTAssertFalse(element("connect.notice").exists, "Nothing was removed: this is about the network.")
    }

    func testANewServerIsSetUpWithOneTapAndGetsItsFirstViewer() async throws {
        let servers = try TestServers.load()
        launch()
        typeAddress(servers.fresh.url)

        // A new server asks for nothing: one tap, and this device manages it.
        waitFor(app.buttons["connect.setUp"], "Set Up This Server, on a new server").tap()
        try skipWithoutAKeychain(unless: "profile.none")

        // The device is now the manager of a server without viewers, and may add the first.
        waitFor(element("profile.none"), "The note that there are no viewers")
        app.buttons["profile.add"].tap()
        let name = waitFor(app.textFields["profile.name"], "The name field")
        name.tap()
        name.typeText("Tester")
        app.buttons["profile.save"].tap()
        waitFor(app.buttons["profile.Tester"], "The new viewer").tap()

        waitFor(shelf("movies"), "The library")

        // Settings names this device's role and the server, and Sign Out forgets the credential.
        app.buttons["profile.menu"].tap()
        waitFor(app.buttons["Settings…"], "The Settings entry").tap()
        waitFor(app.buttons["settings.device"], "This Device in Settings").tap()
        waitFor(app.staticTexts["Role, Manager"], "The device's role")
        app.navigationBars.buttons.firstMatch.tap()
        waitFor(app.buttons["settings.connection"], "Connection in Settings").tap()
        waitFor(app.staticTexts["Name, Lobby UI Test"], "The server's name")
        let signOut = app.buttons["settings.signOut"]
        for _ in 0..<4 where !(signOut.exists && signOut.isHittable) { app.swipeUp() }
        signOut.tap()
        waitFor(app.buttons["settings.confirmSignOut"].firstMatch, "The confirmation").tap()
        waitFor(app.buttons["connect.enterAddress"], "The Connect screen after signing out")

        // A new launch does not find a credential either.
        app.terminate()
        launch(clean: false)
        waitFor(app.buttons["connect.enterAddress"], "The Connect screen after relaunching")
    }

    func testADeviceAManagerRemovedIsToldSo() async throws {
        let servers = try TestServers.load()
        launch()
        try await pair(with: servers)
        waitFor(app.buttons["profile.Alex"], "The viewer picker").tap()
        waitFor(shelf("movies"), "The library")

        try await ManagerAPI(server: servers.paired).removeOtherDevices()
        app.terminate()
        launch(clean: false)

        let notice = waitFor(element("connect.notice"), "The notice that the device was removed")
        XCTAssertTrue(notice.label.contains("This device was removed"), notice.label)
        XCTAssertFalse(element("connect.problem").exists, "The server answered: this is not about the network.")
        attachScreenshot("connect-device-removed")
    }
}
