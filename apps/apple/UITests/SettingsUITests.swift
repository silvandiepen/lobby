// SPDX-License-Identifier: MPL-2.0
import XCTest

/// Settings for each kind of person, against the real local server: the root lists only what
/// they may change, and every page it lists opens (docs/decisions.md, "Settings, one page per
/// subject"). With a folder named in `build/settings-shots` (one line, an absolute path), the
/// root and every page are also kept there as pictures.
final class SettingsUITests: LobbyUITestCase {
    /// The rows of the root, by identifier, with the title of the page each opens.
    private static let you = [("settings.you", "You"), ("settings.playback", "Playback"),
                              ("settings.subtitles", "Subtitles"), ("settings.skipping", "Intros and Credits")]
    private static let device = [("settings.connection", "Connection"), ("settings.servers", "Servers"),
                                 ("settings.device", "This Device"), ("settings.downloads", "Downloads"),
                                 ("settings.kidsMode", "Kids Mode")]
    private static let household = [("settings.manage", "Devices"), ("settings.viewers", "Viewers"), ("settings.kids", "Kids")]
    private static let server = [("settings.server", "General"), ("settings.libraryFolders", "Library Folders"),
                                 ("settings.imports", "Imports and Uploads"), ("settings.matching", "Matching"),
                                 ("settings.converting", "Converting"), ("settings.appleTVs", "Apple TVs"),
                                 ("settings.speakers", "Speakers"), ("settings.away", "Away From Home"),
                                 ("settings.households", "Households"), ("settings.statistics", "Statistics"),
                                 ("settings.backups", "Backups"), ("settings.advanced", "Advanced")]
    private static let about = [("settings.about", "About Lobby")]

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private func shotsFolder(file: StaticString = #filePath) -> URL? {
        let note = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/settings-shots")
        guard let path = try? String(contentsOf: note, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return URL(filePath: path)
    }

    private func shoot(_ role: String, _ name: String) {
        // Let a page that loads from the server draw what it got.
        _ = app.activityIndicators.firstMatch.waitForNonExistence(timeout: 5)
        attachScreenshot("\(role)-\(name)")
        guard let folder = shotsFolder() else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: folder.appending(path: "\(isPad ? "ipad" : "iphone")-\(role)-\(name).png"))
    }

    private func openSettings(as role: String, viewer: String = "Alex") async throws {
        let servers = try TestServers.load()
        try await ManagerAPI(server: servers.paired).removeOtherDevices()
        launch()
        try await pair(with: servers, role: role)
        waitFor(app.buttons["profile.\(viewer)"], "The viewer picker").tap()
        waitFor(app.buttons["profile.menu"].firstMatch, "The viewer menu").tap()
        waitFor(app.buttons["Settings…"], "Settings in the viewer menu").tap()
        waitFor(element("settings.connection"), "The Settings list")
    }

    /// Opens each row there is, sees its page, and goes back. Rows of an older server's
    /// missing preferences may be absent; `required` rows must be there.
    private func walk(_ rows: [(String, String)], role: String, required: Set<String>) {
        for (id, title) in rows {
            let row = element(id)
            if !row.waitForExistence(timeout: 2) {
                for _ in 0..<4 where !row.exists { app.swipeUp(velocity: .slow) }
            }
            guard row.exists else {
                XCTAssertFalse(required.contains(id), "\(id) is missing from Settings.")
                continue
            }
            scrolledTo(row, title).tap()
            let page = app.navigationBars.matching(NSPredicate(format: "identifier == %@", title)).firstMatch
            waitFor(page, "The page \(title)")
            shoot(role, String(id.dropFirst("settings.".count)))
            if !isPad {
                app.navigationBars[title].buttons.firstMatch.tap()
                waitFor(app.navigationBars["Settings"], "The Settings list again")
            }
        }
    }

    private func expectAbsent(_ rows: [(String, String)], _ who: String) {
        for (id, _) in rows {
            XCTAssertFalse(element(id).exists, "\(who) should not see \(id).")
        }
    }

    func testAServerAdminSeesEveryPage() async throws {
        try await openSettings(as: "manager")
        shoot("admin", "root")
        let rows = Self.you + Self.device + Self.household + (isPad ? [] : [("settings.categories", "Categories")]) + Self.server + Self.about
        let required = Set((Self.device + Self.household + Self.server + Self.about).map(\.0))
        walk(rows, role: "admin", required: required)
    }

    func testAHouseholdAdminManagesTheHouseholdOnly() async throws {
        try await openSettings(as: "householdAdmin")
        shoot("household", "root")
        expectAbsent(Self.server, "A household admin")
        walk(Self.household + [("settings.householdStatistics", "Household Statistics")], role: "household",
             required: Set(Self.household.map(\.0)))
    }

    func testAViewerSeesOnlyTheirOwnThings() async throws {
        try await openSettings(as: "viewer")
        shoot("viewer", "root")
        expectAbsent(Self.household + Self.server + [("settings.categories", "")], "A viewer")
        walk(Self.you + Self.device + Self.about, role: "viewer", required: Set((Self.device + Self.about).map(\.0)))
    }

    /// Search finds a page by a word on it, and opens it.
    func testSearchFindsAPage() async throws {
        try await openSettings(as: "viewer")
        let field = waitFor(app.searchFields.firstMatch, "The search field")
        field.tap()
        field.typeText("mobile data")
        waitFor(element("settings.downloads"), "Downloads, found").tap()
        waitFor(app.switches["settings.mobileData"], "The setting that was looked for")
    }

    /// A kids viewer has no way into Settings at all.
    func testAKidHasNoSettings() async throws {
        let servers = try TestServers.load()
        let manager = ManagerAPI(server: servers.paired)
        try await manager.removeOtherDevices()
        try await manager.addViewer("Child")
        addTeardownBlock {
            try await manager.removeOtherDevices()
            try await manager.removeViewer("Child")
        }
        guard try await manager.setKids(["allowedGroupIds": try await manager.groupIDs()], ofViewer: "Child") else {
            throw XCTSkip("This Lobby Server does not know kids viewers yet.")
        }
        launch()
        try await pair(with: servers)
        waitFor(app.buttons["profile.Child"], "The viewer picker").tap()
        waitFor(app.buttons["kids.tab.home"], "The kids screens")
        XCTAssertFalse(app.buttons["profile.menu"].exists)
        XCTAssertFalse(app.buttons["Settings…"].exists)
        shoot("kid", "home")
    }
}
