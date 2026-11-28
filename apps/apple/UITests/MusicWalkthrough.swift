// SPDX-License-Identifier: MPL-2.0
import XCTest

/// Pictures of the music screens on iPhone and iPad, dark and light, against the local test
/// server with its invented library, for looking at by eye. Skips unless `build/music-look.json`
/// names a folder:
///
///     { "screenshots": "/absolute/folder" }
final class MusicWalkthrough: LobbyUITestCase {
    private struct Plan: Decodable {
        var screenshots: String
    }

    func testMusicScreens() async throws {
        let json = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/music-look.json")
        guard let data = try? Data(contentsOf: json) else {
            throw XCTSkip("No build/music-look.json: pictures of the music were not asked for.")
        }
        let plan = try JSONDecoder().decode(Plan.self, from: data)
        let servers = try TestServers.load()
        let folder = URL(filePath: plan.screenshots)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        if isPad { XCUIDevice.shared.orientation = .landscapeLeft }
        var look = "dark"
        func shoot(_ name: String, after seconds: Double = 2) async throws {
            try await Task.sleep(for: .seconds(seconds))
            try XCUIScreen.main.screenshot().pngRepresentation
                .write(to: folder.appending(path: "\(isPad ? "ipad" : "iphone")-\(look)-\(name).png"))
        }
        func openMusic(_ section: String? = nil) {
            if isPad {
                app.staticTexts["sidebar.\(section ?? "Music")"].firstMatch.tap()
            } else {
                app.tabBars.buttons["Music"].tap()
                if let section {
                    waitFor(element("music.section.\(section)"), "The \(section) pill").tap()
                }
            }
        }
        func back() {
            app.navigationBars.buttons.firstMatch.tap()
        }

        XCUIDevice.shared.appearance = .dark
        launch()
        try await pair(with: servers)
        waitFor(app.buttons["profile.Guest"], "The viewer picker").tap()
        if isPad {
            waitFor(app.staticTexts["sidebar.Music"].firstMatch, "Music in the sidebar", timeout: 30)
        } else {
            waitFor(app.tabBars.buttons["Music"], "The Music tab", timeout: 30)
        }

        for (name, appearance) in [("dark", XCUIDevice.Appearance.dark), ("light", .light)] {
            look = name
            XCUIDevice.shared.appearance = appearance
            openMusic()
            waitFor(element("music.album.Harbour Lights"), "Music's home")
            try await shoot("home", after: 3)

            element("music.album.Harbour Lights").tap()
            waitFor(app.buttons["music.play"], "The album")
            try await shoot("album")
            if name == "dark" {
                app.buttons["music.play"].tap()
                waitFor(element("music.mini"), "The mini player")
                try await shoot("album-playing")
            }
            element("music.mini").tap()
            waitFor(element("music.player.title"), "The full player")
            try await shoot("player")
            app.buttons["music.player.queue"].tap()
            try await shoot("player-queue")
            app.buttons["music.player.queue"].tap()
            app.buttons["music.player.close"].tap()
            if !isPad { back() }

            openMusic(isPad ? "Stories" : "books")
            waitFor(element("music.book.The Lighthouse Keeper's Cat"), "The book").tap()
            waitFor(element("music.chapter.0"), "The chapters")
            try await shoot("book")
            if !isPad { back(); back() }

            openMusic(isPad ? "Albums" : "albums")
            waitFor(element("music.album.Static Orchard"), "The albums")
            try await shoot("albums")
            if !isPad { back() }
        }
    }
}
