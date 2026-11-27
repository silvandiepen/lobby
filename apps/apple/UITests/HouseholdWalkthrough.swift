// SPDX-License-Identifier: MPL-2.0
import XCTest

/// A walk through the app against a real household server (the Pi), one step per test, with a
/// screenshot of every screen. For checking a build by eye before it goes to the family.
///
/// Not part of the automated suite: every step skips unless `build/walkthrough.json` exists.
///
///     {
///       "server": "http://media.example.ts.net:8674",
///       "codeFile": "/absolute/path/code.txt",        the pairing code is written here
///       "screenshots": "/absolute/path/screenshots",  PNGs are written here
///       "viewer": "Alex", "otherViewer": "Kids",
///       "film": "Finding Nemo, 2003",                 a film that plays directly, as VoiceOver reads its tile
///       "search": "nemo",                             what to type to find it
///       "show": "Bluey",
///       "seekTo": 0.8,
///       "contentSize": "UICTContentSizeCategoryAccessibilityL"   optional: a text size to check
///       "downloadFilm": "Cinderella, 2015", "downloadFilmSearch": "Cinderella",   for steps 7 to 10
///       "downloadSeason": "Season 2", "downloadEpisode": 9, "interruptEpisode": 35
///     }
///
/// Steps 8 and 9 need somebody to cut the connection to the server and restore it. They say
/// when through marker files beside `codeFile` (`.downloading`, `.cut`, `.waiting`,
/// `.restored`): put a TCP relay between the simulator and the server and stop and start that.
///
/// Run the steps in order, each with `-only-testing:LobbyUITests/HouseholdWalkthrough/<step>`.
/// `test1Pair` shows a code and writes it to `codeFile`; approve it on the server while the
/// step waits (`lobby approve <code> viewer`). The app's state is kept between steps in a
/// namespace of its own, so step 4 finds what step 3 left.
final class HouseholdWalkthrough: LobbyUITestCase {
    struct Plan: Decodable {
        var server: URL
        var codeFile: String
        var screenshots: String
        var viewer: String
        var otherViewer: String
        var film: String
        var search: String
        var show: String
        var seekTo: Double
        /// A text size to check the screens at, e.g. "UICTContentSizeCategoryAccessibilityL".
        var contentSize: String?
        /// For the download steps: a small film (as VoiceOver reads its tile) and what to type
        /// to find it, and two episodes of one season of `show`.
        var downloadFilm: String?
        var downloadFilmSearch: String?
        var downloadSeason: String?
        var downloadEpisode: Int?
        var interruptEpisode: Int?
        /// For step 10: an MKV the server has not prepared yet, and what to type to find it.
        var preparingFilm: String?
        var preparingFilmSearch: String?
    }

    private func plan(file: StaticString = #filePath) throws -> Plan {
        let json = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "build/walkthrough.json")
        guard let data = try? Data(contentsOf: json) else {
            throw XCTSkip("No build/walkthrough.json: the walkthrough against a real server was not asked for.")
        }
        return try JSONDecoder().decode(Plan.self, from: data)
    }

    private func open(clean: Bool = false) {
        app.launchArguments = ["-lobby-mute", "YES", "-lobby-namespace", "walkthrough"] + (clean ? ["-lobby-reset", "YES"] : [])
        if let size = (try? plan())?.contentSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
        }
        app.launch()
    }

    private func save(_ name: String, to plan: Plan) throws {
        let folder = URL(fileURLWithPath: plan.screenshots, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appending(path: "\(name).png"))
    }

    private func chooseViewerIfAsked(_ plan: Plan) {
        let viewer = app.buttons["profile.\(plan.viewer)"]
        let isShelf = NSPredicate(format: "identifier BEGINSWITH 'shelf.'")
        let library = app.scrollViews.matching(isShelf).firstMatch
        let either = app.descendants(matching: .any).matching(NSCompoundPredicate(
            orPredicateWithSubpredicates: [isShelf, NSPredicate(format: "identifier == %@", "profile.\(plan.viewer)")])).firstMatch
        waitFor(either, "The viewer picker or the library", timeout: 60)
        if viewer.exists, !library.exists {
            viewer.tap()
        }
        waitFor(library, "The library", timeout: 120)
    }

    /// Finds a film or show through search and opens it.
    private func find(_ label: String, typing query: String) {
        let searchTab = app.tabBars.buttons["Search"]
        if searchTab.exists {
            searchTab.tap()
        }
        let field = waitFor(app.searchFields.firstMatch, "The search field")
        field.tap()
        let clear = field.buttons["Clear text"]
        if clear.exists {
            clear.tap()
            field.tap()
        }
        field.typeText(query)
        waitFor(app.buttons[label].firstMatch, "\(label) in the search results").tap()
        waitFor(element("detail.title"), "The page of \(label)")
    }

    private func find(_ plan: Plan) {
        find(plan.film, typing: plan.search)
    }

    // MARK: Steps

    func test1Pair() throws {
        let plan = try plan()
        open(clean: true)
        waitFor(app.buttons["connect.enterAddress"], "Enter Address").tap()
        let field = waitFor(app.textFields["connect.address"], "The address field")
        field.tap()
        field.typeText(plan.server.absoluteString)
        try save("01-connect-address", to: plan)
        app.buttons["connect.continue"].tap()

        waitFor(element("connect.server"), "The server's name", timeout: 30)
        try save("02-connect-server", to: plan)
        app.buttons["connect.pair"].tap()

        let code = waitFor(element("connect.code"), "The pairing code", timeout: 30)
        try save("03-connect-code", to: plan)
        let digits = (code.value as? String ?? "").filter(\.isNumber)
        try digits.write(toFile: plan.codeFile, atomically: true, encoding: .utf8)

        // Somebody approves the code on the server now.
        waitFor(app.buttons["profile.\(plan.viewer)"], "The viewer picker after approval", timeout: 180)
        try save("04-who-is-watching", to: plan)
    }

    func test2Browse() throws {
        let plan = try plan()
        open()
        chooseViewerIfAsked(plan)
        try save("05-library", to: plan)

        app.swipeUp()
        try save("06-library-further", to: plan)

        app.tabBars.buttons["Downloads"].tap()
        waitFor(element("downloads.empty"), "The Downloads screen")
        try save("07-downloads", to: plan)

        find(plan)
        try save("08-movie", to: plan)

        find(plan.show, typing: plan.show)
        waitFor(app.buttons["detail.play"], "The show's page")
        try save("09-show", to: plan)
        app.swipeUp()
        try save("10-show-episodes", to: plan)
    }

    func test3PlayAndSeek() throws {
        let plan = try plan()
        open()
        chooseViewerIfAsked(plan)
        find(plan)
        waitFor(app.buttons["detail.play"], "Play").tap()

        // Wait until the film is really playing.
        let deadline = Date().addingTimeInterval(60)
        var elapsed = playerElapsedSeconds()
        while (elapsed ?? 0) < 3, Date() < deadline {
            elapsed = playerElapsedSeconds()
        }
        XCTAssertGreaterThanOrEqual(elapsed ?? 0, 3, "The film did not start playing.")
        _ = playerElapsedSeconds()
        try save("11-player", to: plan)

        // Seek near the end with the system player's own scrubber.
        _ = playerElapsedSeconds()
        showPlayerControls()
        // The volume slider carries the same label, so ask for the identifier.
        let scrubber = waitFor(
            app.sliders.matching(NSPredicate(format: "identifier == %@", "Current position")).firstMatch,
            "The player's scrubber")
        scrubber.adjust(toNormalizedSliderPosition: plan.seekTo)
        let after = Date().addingTimeInterval(30)
        var position = playerElapsedSeconds() ?? 0
        while position < 60, Date() < after {
            position = playerElapsedSeconds() ?? 0
        }
        _ = playerElapsedSeconds()
        try save("12-player-after-seek", to: plan)
        try String(position).write(toFile: plan.codeFile + ".position", atomically: true, encoding: .utf8)

        // Quit without closing the player first: the app is simply gone.
        XCUIDevice.shared.press(.home)
        app.terminate()
    }

    func test4Resume() throws {
        let plan = try plan()
        let stoppedAt = Int((try? String(contentsOfFile: plan.codeFile + ".position", encoding: .utf8)) ?? "") ?? 0
        open()
        chooseViewerIfAsked(plan)
        waitFor(element("shelf.continueWatching"), "Continue Watching after relaunching")
        try save("13-library-continue-watching", to: plan)

        find(plan)
        XCTAssertEqual(waitFor(app.buttons["detail.play"], "Resume").label, "Resume")
        try save("14-movie-resume", to: plan)
        app.buttons["detail.play"].tap()

        let deadline = Date().addingTimeInterval(60)
        var elapsed = playerElapsedSeconds() ?? 0
        while elapsed < stoppedAt - 30, Date() < deadline {
            elapsed = playerElapsedSeconds() ?? 0
        }
        _ = playerElapsedSeconds()
        try save("15-player-resumed", to: plan)
        // The position is written down every ten seconds while playing, so a quit loses at most that.
        XCTAssertGreaterThanOrEqual(elapsed, stoppedAt - 15, "Playback should resume where it stopped (\(stoppedAt) s).")
        XCTAssertLessThanOrEqual(elapsed, stoppedAt + 30)
        showPlayerControls()
        waitFor(app.buttons["Close Button"], "The player's Close button").tap()
    }

    func test5OtherViewer() throws {
        let plan = try plan()
        open()
        chooseViewerIfAsked(plan)
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(waitFor(element("shelf.continueWatching"), "Continue Watching for \(plan.viewer)").exists)

        app.buttons["profile.menu"].tap()
        waitFor(viewerInMenu(plan.otherViewer), "\(plan.otherViewer) in the viewer menu").tap()
        waitFor(shelf("movies"), "The library for \(plan.otherViewer)")
        XCTAssertFalse(element("shelf.continueWatching").exists, "\(plan.otherViewer) has not watched anything.")
        try save("16-library-other-viewer", to: plan)

        app.buttons["profile.menu"].tap()
        waitFor(viewerInMenu(plan.viewer), "\(plan.viewer) in the viewer menu").tap()
        waitFor(element("shelf.continueWatching"), "Continue Watching back for \(plan.viewer)")
    }

    /// The iPad: the split layout of the concept, in landscape. Pair it first with `test1Pair`.
    func test6PadSplitLayout() throws {
        let plan = try plan()
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("This step is for the iPad.")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        open()
        let viewer = app.buttons["profile.\(plan.viewer)"]
        // The identifier is on the row's symbol and on its text. The text is what takes a tap.
        let sidebar = app.staticTexts["sidebar.Movies"].firstMatch
        waitFor(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier IN %@", ["profile.\(plan.viewer)", "sidebar.Movies"])).firstMatch,
            "The viewer picker or the library", timeout: 60)
        if viewer.exists, !sidebar.exists {
            try save("20-ipad-who-is-watching", to: plan)
            viewer.tap()
        }
        waitFor(shelf("movies"), "The library", timeout: 120)
        try save("21-ipad-library", to: plan)

        waitFor(sidebar, "Movies in the sidebar").tap()
        waitFor(app.navigationBars["Movies"], "The Movies grid")
        try save("22-ipad-movies", to: plan)

        find(plan)
        try save("23-ipad-movie", to: plan)

        find(plan.show, typing: plan.show)
        waitFor(app.buttons["detail.play"], "The show's page")
        try save("24-ipad-show", to: plan)

        app.staticTexts["sidebar.Downloads"].firstMatch.tap()
        waitFor(element("downloads.empty"), "The Downloads screen")
        try save("25-ipad-downloads", to: plan)
    }

    // MARK: Downloads

    private func marker(_ name: String, _ plan: Plan) -> String { plan.codeFile + "." + name }

    private func waitForMarker(_ name: String, _ plan: Plan, timeout: TimeInterval = 120) {
        let exists = NSPredicate { _, _ in FileManager.default.fileExists(atPath: self.marker(name, plan)) }
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: exists, object: nil)], timeout: timeout)
        XCTAssertEqual(result, .completed, "Nobody wrote \(marker(name, plan)).")
    }

    private func openSeason(_ plan: Plan) throws {
        find(plan.show, typing: plan.show)
        waitFor(app.buttons["detail.play"], "The show's page")
        if let season = plan.downloadSeason, element("show.season").exists {
            element("show.season").tap()
            waitFor(app.buttons[season], "\(season) in the season menu").tap()
        }
    }

    /// The download button of an episode, scrolled into view.
    private func episodeDownload(_ number: Int) -> XCUIElement {
        let button = element("episode.download.\(number)")
        var swipes = 0
        while !button.exists || !button.isHittable, swipes < 30 {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
        return waitFor(button, "The download button of episode \(number)")
    }

    private func waitForLabel(_ identifier: String, containing text: String, timeout: TimeInterval) {
        let match = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", identifier, text)).firstMatch
        waitFor(match, "\(identifier) to say \(text)", timeout: timeout)
    }

    func test7Download() throws {
        let plan = try plan()
        let film = try XCTUnwrap(plan.downloadFilm)
        let episode = try XCTUnwrap(plan.downloadEpisode)
        open()
        chooseViewerIfAsked(plan)

        // A film. This one is an MKV, so the server repackages it before it can be fetched.
        find(film, typing: plan.downloadFilmSearch ?? film)
        try save("30-movie-before-download", to: plan)
        waitFor(app.buttons["detail.download"], "The Download button").tap()
        waitForLabel("detail.download", containing: "Downloaded", timeout: 600)
        try save("31-movie-downloaded", to: plan)

        // An episode, from its row.
        try openSeason(plan)
        episodeDownload(episode).tap()
        waitForLabel("episode.download.\(episode)", containing: "Downloaded", timeout: 600)
        try save("32-episode-downloaded", to: plan)

        // What a whole season would need. Not started here: the simulator's disk is the Mac's.
        app.swipeDown(velocity: .fast)
        app.swipeDown(velocity: .fast)
        scrolledTo(app.buttons["show.downloadSeason"], "Download Season").tap()
        waitFor(app.alerts.firstMatch, "What the season needs")
        try save("33-download-season-asks-first", to: plan)
        app.alerts.firstMatch.buttons["Cancel"].firstMatch.tap()

        app.tabBars.buttons["Downloads"].tap()
        waitFor(element("downloads.total"), "The Downloads screen")
        try save("34-downloads", to: plan)
    }

    /// The connection is cut while an episode is arriving, and restored.
    func test8Interrupt() throws {
        let plan = try plan()
        let episode = try XCTUnwrap(plan.interruptEpisode)
        for name in ["downloading", "cut", "waiting", "restored"] {
            try? FileManager.default.removeItem(atPath: marker(name, plan))
        }
        open()
        chooseViewerIfAsked(plan)
        try openSeason(plan)
        episodeDownload(episode).tap()
        waitForLabel("episode.download.\(episode)", containing: "Downloading, ", timeout: 120)
        try "1".write(toFile: marker("downloading", plan), atomically: true, encoding: .utf8)

        // Somebody cuts the connection now.
        waitForMarker("cut", plan)
        app.tabBars.buttons["Downloads"].tap()
        waitFor(element("downloads.total"), "The Downloads screen")
        try save("35-downloads-connection-cut", to: plan)
        try "1".write(toFile: marker("waiting", plan), atomically: true, encoding: .utf8)

        // And restores it. Coming back to the app is what a person would do.
        waitForMarker("restored", plan)
        app.terminate()
        open()
        chooseViewerIfAsked(plan)
        app.tabBars.buttons["Downloads"].tap()
        let done = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'downloads.show.' AND label CONTAINS ', 2 episodes downloaded'")).firstMatch
        waitFor(done, "The interrupted episode to finish", timeout: 600)
        try save("36-downloads-after-restoring", to: plan)
    }

    /// With the server out of reach (cut the connection before this step): a cold launch, the
    /// Downloads screen, and a downloaded film played to its end.
    func test9Offline() throws {
        let plan = try plan()
        let film = try XCTUnwrap(plan.downloadFilm)
        let title = String(film.split(separator: ",").first ?? "")
        open()
        chooseViewerIfAsked(plan)
        waitFor(element("notice.offline"), "The notice that Lobby Server cannot be reached", timeout: 90)
        try save("37-library-server-unreachable", to: plan)

        app.tabBars.buttons["Downloads"].tap()
        let row = waitFor(element("download.\(title)"), "The film on the Downloads screen")
        try save("38-downloads-server-unreachable", to: plan)
        row.tap()

        var elapsed = 0
        let deadline = Date().addingTimeInterval(60)
        while elapsed < 5, Date() < deadline {
            elapsed = playerElapsedSeconds() ?? elapsed
        }
        XCTAssertGreaterThanOrEqual(elapsed, 5, "The downloaded film did not play.")
        _ = playerElapsedSeconds()
        try save("39-player-server-unreachable", to: plan)

        // To its end: the player then closes itself and the Downloads screen is back.
        let closed = NSPredicate(format: "exists == false")
        let playerGone = XCTNSPredicateExpectation(predicate: closed, object: app.otherElements["Video"])
        XCTAssertEqual(XCTWaiter().wait(for: [playerGone], timeout: 240), .completed, "The film did not play to its end.")
        waitFor(element("download.\(title)"), "The Downloads screen after the film")
        try save("40-downloads-after-playing-offline", to: plan)
    }

    // MARK: A film the server is still preparing

    private func waitForGone(_ element: XCUIElement, _ what: String, timeout: TimeInterval) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: timeout), .completed, "\(what) did not go away.")
    }

    private func clockSeconds(_ identifier: String) -> Int? {
        let label = element(identifier)
        guard label.exists else { return nil }
        let parts = label.label.replacingOccurrences(of: "−", with: "").split(separator: ":").map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    /// Plays an MKV for the first time. While the server writes its copy the app shows the
    /// film's own bar, never a live broadcast; when the copy is complete the system's
    /// transport takes over with the film's length.
    func test10PreparingBar() throws {
        let plan = try plan()
        let film = try XCTUnwrap(plan.preparingFilm)
        open()
        chooseViewerIfAsked(plan)
        find(film, typing: plan.preparingFilmSearch ?? film)
        try save("50-movie-mkv-not-prepared", to: plan)
        waitFor(app.buttons["detail.play"], "Play").tap()

        // The app's own transport, with the film's length.
        waitFor(element("player.preparingStatus"), "The bar of a film that is being prepared", timeout: 120)
        XCTAssertFalse(app.staticTexts["LIVE"].exists, "A film is not a live broadcast.")
        let start = Date()
        var elapsed = 0
        while elapsed < 6, Date().timeIntervalSince(start) < 60 {
            elapsed = clockSeconds("player.elapsed") ?? elapsed
        }
        XCTAssertGreaterThanOrEqual(elapsed, 6, "The film did not play.")
        let remaining = try XCTUnwrap(clockSeconds("player.remaining"))
        XCTAssertGreaterThan(remaining, 20 * 60, "What is left is the film's, not the copy's.")
        try save("51-player-being-prepared", to: plan)

        // A subtitle that is inside the MKV: the stream does not list it yet, the app draws it.
        if element("player.choices").exists {
            element("player.choices").tap()
            try save("52-player-sound-and-subtitles", to: plan)
            let subtitle = app.buttons.matching(NSPredicate(format: "label != 'Off' AND label != 'Sound and subtitles'")).allElementsBoundByIndex.last
            subtitle?.tap()
        }

        // A seek far beyond what is written stops where the copy stops.
        let bar = element("player.bar")
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let landed = Date()
        var after = elapsed
        while after <= elapsed + 20, Date().timeIntervalSince(landed) < 30 {
            after = clockSeconds("player.elapsed") ?? after
        }
        XCTAssertGreaterThan(after, elapsed + 20, "The seek did not move.")
        try save("53-player-after-seeking-beyond-the-copy", to: plan)
        try String(after).write(toFile: plan.codeFile + ".position", atomically: true, encoding: .utf8)
        // The subtitle is inside the film, and the server writes it out with the copy: until
        // then the app says that it is coming.
        try save("54-player-subtitle-is-coming", to: plan)

        // The copy gets complete: the app's own bar goes, the system's transport is back with
        // the film's length on it.
        waitForGone(element("player.close"), "The app's own transport, once the copy is complete", timeout: 25 * 60)
        showPlayerControls()
        // The film is opened again on the complete copy: its clock shows dashes for a moment.
        let elapsedLabel = waitFor(
            app.staticTexts.matching(NSPredicate(format: "identifier == 'Elapsed Time' AND label MATCHES %@", "^[0-9:]+ elapsed$")).firstMatch,
            "The system's elapsed time", timeout: 60)
        try save("55-player-copy-complete", to: plan)
        XCTAssertFalse(app.staticTexts["LIVE"].exists)
        // "53:20 elapsed": a position in the film, not a time of day.
        XCTAssertNotNil(
            elapsedLabel.label.range(of: #"^([0-9]+:)?[0-9]+:[0-9]{2} elapsed$"#, options: .regularExpression), elapsedLabel.label)
        // And now the chosen subtitle is drawn.
        if element("player.subtitle").waitForExistence(timeout: 120) {
            try save("56-player-drawn-subtitle", to: plan)
        }
        showPlayerControls()
        waitFor(app.buttons["Close Button"], "The player's Close button").tap()
    }
}
