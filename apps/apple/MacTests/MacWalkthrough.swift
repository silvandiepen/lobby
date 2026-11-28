// SPDX-License-Identifier: MPL-2.0
import AVFoundation
import AppKit
import LobbyKit
import ScreenCaptureKit
import SwiftUI
import XCTest

@testable import Lobby

/// A walk through the running Mac app against a real server, from inside the app: these tests
/// are hosted by the signed app, so `AppLaunch.shared` is the model of the app whose window is
/// on screen. They do what a person does through that model and through the real menu items,
/// and save pictures of the real window's contents.
///
/// They exist because the Mac UI tests (`MacUITests/`, scheme `LobbyMacUI`) need a person to
/// allow UI testing on the Mac first. What these cannot do is click: buttons, the sidebar and
/// AVKit's own controls are not exercised here.
///
/// Every test skips unless its variables are set (`TEST_RUNNER_…` on the `xcodebuild` command
/// line reaches the app without the prefix):
///
///     LOBBY_MAC_SERVER=http://media.example.ts.net:8674   a household server, paired as viewer
///     LOBBY_MAC_STEP=pair | resume | download | forget    each is a launch of its own
///     LOBBY_MAC_DOWNLOAD="Cinderella|2015"                for the download step
///     LOBBY_MAC_VIEWER=Alex
///     LOBBY_MAC_FILM="Frozen|2013"  LOBBY_MAC_MKV="The Prince of Egypt|1998"
///
///     LOBBY_MAC_MANAGER_SERVER=http://127.0.0.1:18675     a local server nobody claimed yet
///     LOBBY_MAC_SETUP_SECRET=…
///
///     LOBBY_MAC_KIDS_SERVER=http://127.0.0.1:18690        a server with a kids viewer "Kids"
///     LOBBY_MAC_KIDS_TOKEN=…                              and its manager's token
///
/// The pairing code is written to `<temporary directory>/lobby-mac-code.txt` and pictures to
/// `<temporary directory>/lobby-mac-shots/`, both inside the app's sandbox container.
@MainActor
final class MacWalkthrough: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    private func model() throws -> AppModel {
        // The menu bar follows the app that is in front, as it does for a person using it.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.title == "Lobby" }?.makeKeyAndOrderFront(nil)
        return try AppLaunch.shared.result.get().active
    }

    private var shots: URL {
        FileManager.default.temporaryDirectory.appending(path: "lobby-mac-shots", directoryHint: .isDirectory)
    }

    // MARK: Helpers

    /// Lets SwiftUI draw what the model now says.
    private func settle() async {
        // SwiftUI redraws views and rebuilds menus at the end of a turn of the main run loop.
        // Wait for a few whole turns: no clock involved.
        for _ in 0..<6 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let observer = CFRunLoopObserverCreateWithHandler(
                    nil, CFRunLoopActivity.beforeWaiting.rawValue, false, Int.max
                ) { _, _ in
                    continuation.resume()
                }
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
        }
        CATransaction.flush()
        for window in NSApp.windows {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    /// Saves the contents of the app's own window, with its toolbar. Not the screen.
    private func capture(_ name: String) async throws {
        await settle()
        let window = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title == "Lobby" } ?? NSApp.windows.first { $0.isVisible })
        // The window's own content view, drawn into a bitmap by AppKit. This needs no permission
        // to record the screen and shows nothing but the app. The title bar is not part of it,
        // and video does not draw this way: the player's picture is black.
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try png.write(to: shots.appending(path: "\(name).png"))
    }

    /// The window as it is on screen, with its pictures and gradients, which AppKit does not draw
    /// into a bitmap. An app may look at its own windows without anybody's permission.
    private func captureOnScreen(_ name: String) async throws {
        for _ in 0..<240 { await settle() }
        // The one window; its title is that of the page in it.
        let window = try XCTUnwrap(NSApp.windows.filter(\.isVisible).max { $0.frame.width < $1.frame.width })
        let image = try await Self.picture(
            ofWindow: CGWindowID(window.windowNumber), width: Int(window.frame.width * window.backingScaleFactor),
            height: Int(window.frame.height * window.backingScaleFactor))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try png.write(to: shots.appending(path: "\(name).png"))
    }

    private nonisolated static func picture(ofWindow id: CGWindowID, width: Int, height: Int) async throws -> CGImage {
        let content = try await SCShareableContent.currentProcess
        let window = try XCTUnwrap(content.windows.first { $0.windowID == id })
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
    }

    /// The same once a page had the time to fetch what it shows.
    private func captureLoaded(_ name: String) async throws {
        for _ in 0..<60 { await settle() }
        try await capture(name)
    }

    /// Saves a sheet as it is drawn in a window of its own: a click is not made here.
    private func capture(_ name: String, of sheet: some View, app: AppModel) async throws {
        let host = NSHostingView(rootView: sheet.environment(app))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        for _ in 0..<60 { await settle() }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        window.close()
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: shots.appending(path: "\(name).png"))
    }

    /// The menu item with this title, as the menu bar has it right now.
    private func menuItem(_ title: String) -> NSMenuItem? {
        func find(in menu: NSMenu) -> NSMenuItem? {
            // What AppKit does when a person opens the menu: ask its owner to bring it up to date.
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            for item in menu.items {
                if item.title == title, !item.hasSubmenu { return item }
                if let submenu = item.submenu, let found = find(in: submenu) { return found }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(find(in:))
    }

    private func menuTitles() -> [String] {
        func titles(in menu: NSMenu, prefix: String) -> [String] {
            menu.items.flatMap { item -> [String] in
                let name = prefix + item.title
                return [name] + (item.submenu.map { titles(in: $0, prefix: name + " > ") } ?? [])
            }
        }
        return NSApp.mainMenu.map { titles(in: $0, prefix: "") } ?? []
    }

    /// Chooses a menu item, the way the menu bar or its key does.
    private func choose(_ title: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        await settle()
        if menuItem(title) == nil { note("menu bar: \(menuTitles().joined(separator: " | "))") }
        let item = try XCTUnwrap(menuItem(title), "There is no menu item “\(title)”.", file: file, line: line)
        XCTAssertTrue(item.isEnabled, "“\(title)” is disabled.", file: file, line: line)
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item), file: file, line: line)
    }

    private func item(_ spec: String, in app: AppModel) throws -> Item {
        let parts = spec.split(separator: "|").map(String.init)
        let year = parts.count > 1 ? Int(parts[1]) : nil
        return try XCTUnwrap(
            app.search(parts[0]).first { $0.title == parts[0] && (year == nil || $0.year == year) },
            "“\(spec)” is not in the library.")
    }

    /// Waits until the film has played past `seconds` of its own timeline.
    private func waitUntil(_ player: AVPlayer, isPast seconds: Double) async {
        let (stream, continuation) = AsyncStream<Double>.makeStream()
        let observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { time in
            continuation.yield(time.seconds)
        }
        for await time in stream where time >= seconds && player.timeControlStatus == .playing {
            break
        }
        player.removeTimeObserver(observer)
    }

    private func note(_ text: String) {
        print("WALKTHROUGH: \(text)")
    }

    /// Plays an item for a few seconds from wherever Play starts, and returns where that was.
    private func play(_ item: Item, in app: AppModel, picture: String?) async throws -> (startedAt: Double, player: PlayerModel) {
        let action = app.movieDetail(for: item).action
        let request = try XCTUnwrap(action.request, "“\(item.title)” cannot be played: \(action)")
        app.play(request)
        let player = try XCTUnwrap(app.player)
        let start = Double(request.startPositionMs) / 1000
        await waitUntil(player.player, isPast: start + 3)
        if case .failed(let message) = player.stage {
            XCTFail("“\(item.title)” did not play: \(message)")
        }
        if let picture { try await capture(picture) }
        return (start, player)
    }

    // MARK: A household server, as a viewer

    func testHouseholdServerAsViewer() async throws {
        guard let address = environment["LOBBY_MAC_SERVER"] else {
            throw XCTSkip("No LOBBY_MAC_SERVER: the walkthrough against a household server was not asked for.")
        }
        let app = try model()
        let viewerName = environment["LOBBY_MAC_VIEWER"] ?? "Alex"
        let film = environment["LOBBY_MAC_FILM"] ?? ""
        let mkv = environment["LOBBY_MAC_MKV"] ?? ""

        switch environment["LOBBY_MAC_STEP"] {
        case "resume":
            return try await resume(app, film: film, mkv: mkv)
        case "download":
            return try await download(app, spec: try XCTUnwrap(environment["LOBBY_MAC_DOWNLOAD"]))
        case "forget":
            // Leaves the Mac as nobody's: the unit tests share this app and its namespace.
            while app.phase == .launching { await Task.yield() }
            await app.signOut()
            try await app.environment.forgetEverything()
            return XCTAssertEqual(app.phase, .connect)
        default:
            break
        }

        // A Mac nobody paired yet.
        try await app.environment.forgetEverything()
        await app.signOut()
        XCTAssertEqual(app.phase, .connect)

        // Connect: the server's name, a code, and somebody approves it as a viewer.
        let connect = ConnectModel(app: app)
        connect.addressText = address
        await connect.findServer()
        guard case .server(let server) = connect.step else {
            return XCTFail("The server did not answer: \(String(describing: connect.problem))")
        }
        note("server \(server.name) \(server.version)")
        await connect.requestCode()
        guard case .code(let request, _) = connect.step else {
            return XCTFail("No pairing code: \(String(describing: connect.problem))")
        }
        try request.code.write(
            to: FileManager.default.temporaryDirectory.appending(path: "lobby-mac-code.txt"), atomically: true, encoding: .utf8)
        await connect.waitUntilPaired()
        XCTAssertEqual(app.phase, .chooseProfile, "Pairing did not finish: \(String(describing: connect.problem))")
        XCTAssertEqual(app.device?.platform, .macos)
        XCTAssertEqual(app.device?.role, .viewer)
        note("paired as \(app.device?.name ?? "?"), role \(app.device?.role.rawValue ?? "?")")
        try await capture("01-who-is-watching")

        let viewer = try XCTUnwrap(app.profiles.first { $0.name == viewerName })
        await app.selectProfile(viewer)
        XCTAssertEqual(app.phase, .library)
        XCTAssertEqual(app.connectivity, .online)
        note("library: \(app.shelves.movies.count) films, \(app.shelves.series.count) series, \(app.shelves.categories.count) categories")
        try await capture("02-library")

        // A viewer Mac has no manager tools: not in the model, not in the menu bar.
        XCTAssertFalse(app.isManager)
        XCTAssertNil(app.managerClient)
        await settle()
        XCTAssertNil(menuItem("Devices and Viewers"))

        // The menu bar reaches every section.
        try await choose("Movies")
        XCTAssertEqual(app.sidebarSelection, .movies)
        try await capture("03-movies-from-the-menu")
        try await choose("Series")
        XCTAssertEqual(app.sidebarSelection, .series)
        try await choose("Downloads")
        XCTAssertEqual(app.sidebarSelection, .downloads)
        try await capture("04-downloads")
        try await choose("Home")
        try await choose("Find in Library")
        XCTAssertTrue(app.isSearching)
        app.searchText = film.split(separator: "|").first.map(String.init) ?? ""
        try await capture("05-search")
        app.searchText = ""

        // A film that plays as it is: open it, play, move near the end, close.
        let direct = try item(film, in: app)
        app.libraryPath = [.item(direct.id)]
        try await capture("06-movie")
        var (_, player) = try await play(direct, in: app, picture: "07-player")
        await settle()
        XCTAssertNotNil(menuItem("Pause"), "Playback has its menu item while a film plays.")
        let duration = Double(try XCTUnwrap(direct.displayDurationMs)) / 1000
        await player.player.seek(to: CMTime(seconds: duration * 0.8, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        await waitUntil(player.player, isPast: duration * 0.8 + 4)
        try await choose("Close Player")
        await settle()
        while app.player != nil { await Task.yield() }
        let stoppedAt = Double(try XCTUnwrap(app.progress[direct.id]).positionMs) / 1000
        note("\(direct.title) (\(direct.mainFiles.first?.container ?? "?")) stopped at \(MediaFormat.clock(ms: Int(stoppedAt * 1000)))")
        XCTAssertGreaterThan(stoppedAt, duration * 0.8)
        try await capture("08-movie-resume")

        // An MKV, through the server's repackaged copy.
        let matroska = try item(mkv, in: app)
        XCTAssertEqual(matroska.mainFiles.first?.playability, .remux)
        app.libraryPath = [.item(matroska.id)]
        (_, player) = try await play(matroska, in: app, picture: nil)
        try await choose("Close Player")
        while app.player != nil { await Task.yield() }
        let mkvStoppedAt = try XCTUnwrap(app.progress[matroska.id]).positionMs
        note("\(matroska.title) (mkv) stopped at \(MediaFormat.clock(ms: mkvStoppedAt))")
        XCTAssertGreaterThan(mkvStoppedAt, 0)
    }

    /// A second launch of the app: what the first one left is there, and Resume starts where
    /// the viewer stopped.
    private func resume(_ app: AppModel, film: String, mkv: String) async throws {
        while app.phase == .launching { await Task.yield() }
        XCTAssertEqual(app.phase, .library, "A paired Mac with a viewer opens on the library.")
        while app.isRefreshing { await Task.yield() }
        XCTAssertFalse(app.shelves.continueWatching.isEmpty)
        note("continue watching after relaunch: \(app.shelves.continueWatching.map { "\($0.title) (\($0.status))" }.joined(separator: ", "))")
        try await capture("09-library-after-relaunch")

        for spec in [film, mkv] {
            let item = try item(spec, in: app)
            let saved = Double(try XCTUnwrap(app.progress[item.id]).positionMs) / 1000
            guard case .play(_, .resume, _) = app.movieDetail(for: item).action else {
                return XCTFail("\(item.title) should offer Resume.")
            }
            app.libraryPath = [.item(item.id)]
            let (startedAt, player) = try await play(item, in: app, picture: spec == film ? "10-player-resumed" : nil)
            let now = player.player.currentTime().seconds
            note("\(item.title) resumed at \(MediaFormat.clock(ms: Int(startedAt * 1000))), saved was \(MediaFormat.clock(ms: Int(saved * 1000))), playing at \(MediaFormat.clock(ms: Int(now * 1000)))")
            XCTAssertEqual(startedAt, saved, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(now, saved)
            XCTAssertLessThan(now, saved + 15)
            try await choose("Close Player")
            while app.player != nil { await Task.yield() }
        }
    }

    /// Keeps a film on this Mac with the same engine as the iPhone, plays the copy, removes it.
    private func download(_ app: AppModel, spec: String) async throws {
        while app.phase == .launching { await Task.yield() }
        while app.isRefreshing { await Task.yield() }
        let item = try item(spec, in: app)
        await app.download(item)
        for await records in await app.environment.downloads.updates() {
            app.applyDownloads(records)
            let status = app.downloadStatus(for: item.id)
            if status.kind == .downloaded { break }
            if status.kind == .failed { return XCTFail("The download failed: \(status.detail ?? "")") }
        }
        let local = await app.environment.downloads.localFile(itemID: item.id)
        let file = try XCTUnwrap(local)
        let size = try XCTUnwrap(file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        note("downloaded \(item.title): \(MediaFormat.size(bytes: Int64(size))), \(app.downloadsOverview.total ?? "")")
        XCTAssertEqual(app.movieDetail(for: item).action.request?.source, .local)

        _ = try await play(item, in: app, picture: nil)
        try await choose("Close Player")
        while app.player != nil { await Task.yield() }
        await app.removeDownload(itemID: item.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        note("played the copy on this Mac and removed it")
    }

    /// Looks at the real network from inside the signed, sandboxed app: the household's server
    /// has to be in the list, and its address has to answer. Set `LOBBY_MAC_FIND=<server name>`.
    ///
    /// macOS asks the person at the Mac once whether Lobby may find devices on the local
    /// network. Until that is answered nothing is found and this waits: stop it by hand.
    func testFindsTheServerOnThisNetwork() async throws {
        guard let name = environment["LOBBY_MAC_FIND"] else {
            throw XCTSkip("No LOBBY_MAC_FIND: looking at the real network was not asked for.")
        }
        var found: DiscoveredServer?
        for await update in ServerBrowser.updates() {
            XCTAssertFalse(update.isDenied, "The app may not look at the local network.")
            if update.isDenied { return }
            if let server = update.servers.first(where: { $0.name == name }) {
                found = server
                break
            }
        }
        let server = try XCTUnwrap(found)
        let address = try await ServerBrowser.address(of: server)
        note("found \(server.name), id \(server.serverID ?? "none"), at \(address.absoluteString)")
        let info = try await LobbyClient(baseURL: address).serverInfo()
        XCTAssertEqual(info.name, server.name)
        XCTAssertEqual(info.id, server.serverID)
    }

    // MARK: A new local server, as its manager

    func testNewServerAsManager() async throws {
        guard let address = environment["LOBBY_MAC_MANAGER_SERVER"], let secret = environment["LOBBY_MAC_SETUP_SECRET"],
            let url = URL(string: address)
        else {
            throw XCTSkip("No LOBBY_MAC_MANAGER_SERVER and LOBBY_MAC_SETUP_SECRET: the manager walkthrough was not asked for.")
        }
        let app = try model()
        try await app.environment.forgetEverything()
        await app.signOut()

        // Set the server up, with its setup secret when it asks for one: this Mac is its manager.
        let connect = ConnectModel(app: app)
        connect.addressText = address
        await connect.findServer()
        if case .server(let info) = connect.step, info.claim == .open {
            await connect.setUp()
        } else {
            connect.chooseSetupSecret()
            connect.setupSecretText = secret
            await connect.claim()
        }
        XCTAssertEqual(app.phase, .chooseProfile, "The claim did not work: \(String(describing: connect.problem))")
        XCTAssertTrue(app.isManager)
        try await app.addProfile(name: "Tester", color: "blue")
        await app.selectProfile(try XCTUnwrap(app.profiles.first))

        // The manager's page: in the menu bar now, and in the sidebar.
        try await choose("Devices and Viewers")
        XCTAssertEqual(app.sidebarSelection, .manage)
        let manager = app.manager()

        // An iPhone asks to join and shows a code.
        var request = URLRequest(url: url.appending(path: "v1/pairing/requests"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["deviceName": "Kitchen iPhone", "platform": "ios"])
        let (data, _) = try await URLSession.shared.data(for: request)
        let asked = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let code = try XCTUnwrap(asked["code"] as? String)

        await manager.refresh()
        XCTAssertEqual(manager.waiting.map(\.deviceName), ["Kitchen iPhone"])
        manager.code = code
        try await capture("20-manage-device-waiting")

        manager.role = .viewer
        await manager.approve()
        XCTAssertNil(manager.problem)
        XCTAssertEqual(manager.lastApproval, "Approved “Kitchen iPhone” as a viewer.")

        // The iPhone collects its credential, which is when the server has it as a device.
        var collect = URLRequest(url: url.appending(path: "v1/pairing/requests/\(try XCTUnwrap(asked["id"] as? String))/collect"))
        collect.httpMethod = "POST"
        collect.setValue("application/json", forHTTPHeaderField: "Content-Type")
        collect.httpBody = try JSONSerialization.data(withJSONObject: ["pollSecret": try XCTUnwrap(asked["pollSecret"] as? String)])
        _ = try await URLSession.shared.data(for: collect)
        try await choose("Refresh")
        while app.isRefreshing { await Task.yield() }
        await manager.refresh()
        XCTAssertEqual(manager.devices.map(\.caption), ["Mac · Manager", "iPhone · Viewer"])
        XCTAssertTrue(manager.waiting.isEmpty)
        try await capture("21-manage-device-approved")

        // What is downloaded on that iPhone: its page, after something was sent to it.
        let iPhone = try XCTUnwrap(manager.devices.last)
        let show = try XCTUnwrap(app.wholeCatalogue.items(ofKind: .show).first)
        let send = SendToDeviceModel(app: app, item: show, deviceID: iPhone.id)
        await send.load()
        await send.send(to: try XCTUnwrap(send.targets.first))
        XCTAssertNil(send.problem)
        try await capture("24-send-to-device", of: SendToDeviceView(model: SendToDeviceModel(app: app, item: show)), app: app)
        app.libraryPath = [.device(iPhone.id)]
        try await captureLoaded("25-device-page")
        app.libraryPath = []

        // The categories, and the sheets of a category and of a title.
        try await choose("Categories")
        try await captureLoaded("26-categories")
        let categories = CategoriesModel(app: app)
        await categories.load()
        let group = try XCTUnwrap(categories.groups.last)
        try await capture(
            "27-category", of: CategoryEditor(model: categories, draft: CategoryDraft(try XCTUnwrap(group.entries.first), in: group)), app: app)
        let film = try XCTUnwrap(app.shelves.movies.first)
        try await capture("28-edit", of: ItemEditView(app: app, itemID: film.id), app: app)
        app.sidebarSelection = .manage

        // Viewers: one more, and gone again.
        await manager.addViewer(name: "Kid", color: "green")
        XCTAssertEqual(app.profiles.map(\.name), ["Tester", "Kid"])
        try await capture("22-manage-viewer-added")
        await manager.removeViewer(try XCTUnwrap(app.profiles.last))
        XCTAssertEqual(app.profiles.map(\.name), ["Tester"])

        // Remove the iPhone. The last manager cannot be removed, and says so.
        await manager.remove(try XCTUnwrap(manager.devices.last))
        XCTAssertEqual(manager.devices.map(\.caption), ["Mac · Manager"])
        await manager.remove(try XCTUnwrap(manager.devices.first))
        XCTAssertNotNil(manager.problem)
        note("removing the last manager: \(manager.problem ?? "")")
        manager.problem = nil
        try await capture("23-manage-after-removing")
        note("server status: \(manager.status.map(ManagerModel.summary)?.joined(separator: " / ") ?? "none")")
    }

    // MARK: The kids screens

    func testKidsScreens() async throws {
        guard let url = environment["LOBBY_MAC_KIDS_SERVER"].flatMap(URL.init(string:)), let token = environment["LOBBY_MAC_KIDS_TOKEN"] else {
            throw XCTSkip("No LOBBY_MAC_KIDS_SERVER and LOBBY_MAC_KIDS_TOKEN: the kids walkthrough was not asked for.")
        }
        let app = try model()
        try await app.environment.forgetEverything()
        await app.signOut()

        let newDevice = try LobbyClient(baseURL: url)
        let manager = newDevice.authenticated(with: token)
        let request = try await newDevice.requestPairing(deviceName: "Kids Mac", platform: .macos)
        _ = try await manager.approvePairing(code: request.code, role: .viewer)
        guard case .approved(let grant) = try await newDevice.collectPairing(request) else {
            return XCTFail("The pairing was not approved.")
        }
        try await app.completePairing(address: url, server: try await newDevice.serverInfo(), grant: grant)
        XCTAssertEqual(app.phase, .chooseProfile)

        // An ordinary viewer first: the sidebar, and the menus that go with it.
        await app.selectProfile(try XCTUnwrap(app.profiles.first { $0.kids == nil }))
        await settle()
        XCTAssertNotNil(menuItem("All Viewers…"))
        try await captureOnScreen("kids-0-before")

        // Choosing the kids viewer changes the whole window. By day first, as it was designed.
        NSApp.appearance = NSAppearance(named: .aqua)
        defer { NSApp.appearance = nil }
        let kid = try XCTUnwrap(app.profiles.first { $0.kids != nil })
        await app.selectProfile(kid)
        XCTAssertTrue(app.showsKidsScreens)
        for (index, place) in KidsSection.allCases.enumerated() {
            try await choose(place.name)
            XCTAssertEqual(app.kidsSection, place)
            try await captureOnScreen("kids-\(index + 1)-\(place.rawValue)")
        }
        let film = try XCTUnwrap(app.kidsLibrary.movies.first)
        app.kidsPath = [KidsRoute(itemID: film.id)]
        try await captureOnScreen("kids-5-film")
        let show = try XCTUnwrap(app.kidsLibrary.series.first)
        app.kidsPath = [KidsRoute(itemID: show.id)]
        try await captureOnScreen("kids-6-series")
        app.kidsPath = []
        try await capture("kids-7-settings", of: MacSettingsView().frame(width: 480, height: 280), app: app)

        NSApp.appearance = NSAppearance(named: .darkAqua)
        try await captureOnScreen("kids-8-dark")

        // Nothing in the menu bar leads out.
        await settle()
        for title in ["All Viewers…", "Home", "Downloads", "Devices and Viewers", "Categories", "For Grown-ups…"] + app.profiles.map(\.name) {
            XCTAssertNil(menuItem(title), "“\(title)” is still in the menu bar.")
        }
        XCTAssertFalse(menuItem("Find in Library")?.isEnabled ?? false)
        XCTAssertNil(menuItem("New Window"))
        app.chooseAnotherProfile()
        await app.selectProfile(try XCTUnwrap(app.profiles.first { $0.kids == nil }))
        XCTAssertEqual(app.activeProfile?.id, kid.id)

        // Bound by a manager: still the same, and the avatar has nowhere to go.
        _ = try await manager.bindDevice(id: grant.device.id, toKidsProfile: kid.id)
        await app.refresh()
        while app.isRefreshing { await Task.yield() }
        XCTAssertTrue(app.isBoundToKids)
        XCTAssertEqual(app.activeProfile?.id, kid.id)
        XCTAssertFalse(app.kidsLibrary.movies.isEmpty, "The server's limits and the app's agree.")
        _ = try await manager.bindDevice(id: grant.device.id, toKidsProfile: nil)
        try await app.environment.forgetEverything()
        await app.signOut()
    }
}
