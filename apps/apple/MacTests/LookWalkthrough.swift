// SPDX-License-Identifier: MPL-2.0
import AppKit
import LobbyKit
import SwiftUI
import XCTest

@testable import Lobby

/// Pictures of the Mac app's screens, dark and light, against a local server that was already
/// set up, for looking at the app by eye. Like `MacWalkthrough` it is inside the running app
/// and skips unless it was asked for:
///
///     LOBBY_LOOK_SERVER=http://127.0.0.1:18774   a local server
///     LOBBY_LOOK_TOKEN=…                         a manager's token on it, to approve this Mac
///     LOBBY_LOOK_TITLES=One,Another              titles with artwork to show the page of, at will
///
/// AppKit cannot draw the system's glass (sidebar, toolbar) into a bitmap, so the pictures are
/// taken from outside: for each screen the test writes `<window number> <name>` to
/// `<temporary directory>/lobby-look/request` inside the app's container and waits until a
/// script that runs `screencapture -l <window number>` has removed that file.
@MainActor
final class LookWalkthrough: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    private var request: URL {
        FileManager.default.temporaryDirectory.appending(path: "lobby-look/request")
    }

    /// Gives the app's run loop the time to fetch and draw what a page shows.
    private func settle(_ seconds: Double = 1.5) async throws {
        try await Task.sleep(for: .seconds(seconds))
        CATransaction.flush()
    }

    private func photograph(_ window: NSWindow, _ name: String) async throws {
        try await settle()
        try FileManager.default.createDirectory(at: request.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "\(window.windowNumber) \(name)".write(to: request, atomically: true, encoding: .utf8)
        for _ in 0..<150 where FileManager.default.fileExists(atPath: request.path) {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.path), "Nobody took the picture “\(name)”.")
    }

    private func capture(_ name: String) async throws {
        try await photograph(try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.canBecomeMain }), name)
    }

    /// A sheet, drawn in a window of its own.
    private func capture(_ name: String, of sheet: some View, app: AppModel) async throws {
        let host = NSHostingView(rootView: sheet.environment(app).tint(Color("AccentColor")))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        try await photograph(window, name)
        window.close()
    }

    private func pair(_ app: AppModel, at address: String, token: String) async throws {
        try await app.environment.forgetEverything()
        await app.signOut()
        let connect = ConnectModel(app: app)
        connect.addressText = address
        await connect.findServer()
        await connect.requestCode()
        guard case .code(let request, _) = connect.step else {
            return XCTFail("No pairing code: \(String(describing: connect.problem))")
        }
        var approval = URLRequest(url: try XCTUnwrap(URL(string: address)).appending(path: "v1/pairing/approve"))
        approval.httpMethod = "POST"
        approval.setValue("application/json", forHTTPHeaderField: "Content-Type")
        approval.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        approval.httpBody = try JSONSerialization.data(withJSONObject: ["code": request.code, "role": "manager"])
        _ = try await URLSession.shared.data(for: approval)
        await connect.waitUntilPaired()
        await app.selectProfile(try XCTUnwrap(app.profiles.first))
    }

    func testScreens() async throws {
        guard let address = environment["LOBBY_LOOK_SERVER"], let token = environment["LOBBY_LOOK_TOKEN"] else {
            throw XCTSkip("No LOBBY_LOOK_SERVER and LOBBY_LOOK_TOKEN: pictures of the screens were not asked for.")
        }
        let app = try AppLaunch.shared.result.get().active
        try await pair(app, at: address, token: token)
        XCTAssertEqual(app.phase, .library)
        try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.canBecomeMain }).setContentSize(CGSize(width: 1280, height: 800))

        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            try await screens(app, name)
        }
        NSApp.appearance = nil
        // Once as the window in front: an inactive window dims its title and its buttons.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        app.sidebarSelection = .movies
        try await capture("active-movies")
        NSApp.deactivate()
        if let kids = app.profiles.first(where: { $0.kids != nil }) {
            await app.selectProfile(kids)
            for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                try await coloured(app, "\(name)-kids") { app.kidsPath = [KidsRoute(itemID: $0.id)] }
                app.kidsPath = []
            }
            NSApp.appearance = nil
        }
        await app.signOut()
        try await app.environment.forgetEverything()
    }

    /// Home, a category, lists and titles, and the kids' pages: what starts with a picture.
    func testHomePages() async throws {
        guard let address = environment["LOBBY_LOOK_SERVER"], let token = environment["LOBBY_LOOK_TOKEN"] else {
            throw XCTSkip("No LOBBY_LOOK_SERVER and LOBBY_LOOK_TOKEN: pictures of the screens were not asked for.")
        }
        let app = try AppLaunch.shared.result.get().active
        try await pair(app, at: address, token: token)
        let window = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.canBecomeMain })
        window.setContentSize(CGSize(width: 1280, height: 860))
        NSApp.activate(ignoringOtherApps: true)
        for (look, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            app.sidebarSelection = .library
            try await settle(3)
            try await capture("mac-\(look)-home")
            if let page = scrollView(in: window) {
                scroll(page, to: 560)
                try await capture("mac-\(look)-home-rows")
                scroll(page, to: 0)
            }
            app.sidebarSelection = .movies
            try await settle(2)
            try await capture("mac-\(look)-movies")
            for (place, category) in app.shelves.groups.flatMap(\.categories).prefix(2).enumerated() {
                app.sidebarSelection = .category(category.id)
                try await settle(2)
                try await capture("mac-\(look)-category-\(place + 1)")
            }
            if let group = app.shelves.groups.first {
                app.libraryPath = [.group(group.id)]
                try await settle(2)
                try await capture("mac-\(look)-group")
            }
            app.sidebarSelection = .library
            try await settle()
            for (name, kind) in [("film", ItemKind.movie), ("series", .show)] {
                guard let item = app.homePage.banner.map(\.item).first(where: { $0.kind == kind })
                    ?? app.catalogue.items(ofKind: kind).first(where: { $0.artwork.backdrop != nil }) else { continue }
                app.libraryPath = [.item(item.id)]
                try await settle(3)
                try await capture("mac-\(look)-\(name)")
                if let page = scrollView(in: window) {
                    scroll(page, to: 420)
                    try await capture("mac-\(look)-\(name)-below")
                }
                app.libraryPath = []
                try await settle()
            }
        }
        if let kids = app.profiles.first(where: { $0.kids != nil }) {
            await app.selectProfile(kids)
            for (look, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                for section in KidsSection.allCases {
                    app.kidsPath = []
                    app.kidsSection = section
                    try await settle(2)
                    try await capture("mac-\(look)-kids-\(section.rawValue)")
                }
                if let category = app.kidsLibrary.categories.first {
                    app.kidsPath = [KidsRoute(categoryID: category.id)]
                    try await settle(2)
                    try await capture("mac-\(look)-kids-category")
                }
                for (name, item) in [("film", app.kidsLibrary.movies.first { $0.artwork.backdrop != nil }), ("show", app.kidsLibrary.series.first)] {
                    guard let item else { continue }
                    app.kidsPath = [KidsRoute(itemID: item.id)]
                    try await settle(2)
                    try await capture("mac-\(look)-kids-\(name)")
                }
                app.kidsPath = []
                app.kidsSection = .home
                try await settle(2)
                if let page = scrollView(in: window) {
                    scroll(page, to: 520)
                    try await capture("mac-\(look)-kids-home-rows")
                }
            }
        }
        NSApp.appearance = nil
        await app.signOut()
        try await app.environment.forgetEverything()
    }

    /// The page's own scroll view: the largest that scrolls downwards.
    private func scrollView(in window: NSWindow) -> NSScrollView? {
        func all(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(all) }
        return window.contentView.map(all)?.filter { $0.frame.width > 500 && ($0.documentView?.frame.height ?? 0) > $0.frame.height }
            .max { $0.frame.height < $1.frame.height }
    }

    private func scroll(_ view: NSScrollView, to y: CGFloat) {
        view.contentView.scroll(to: CGPoint(x: 0, y: y - view.contentInsets.top))
        view.reflectScrolledClipView(view.contentView)
    }

    /// Choosing a viewer's picture, and where it shows.
    func testPictures() async throws {
        guard let address = environment["LOBBY_LOOK_SERVER"], let token = environment["LOBBY_LOOK_TOKEN"] else {
            throw XCTSkip("No LOBBY_LOOK_SERVER and LOBBY_LOOK_TOKEN: pictures of the screens were not asked for.")
        }
        let app = try AppLaunch.shared.result.get().active
        try await pair(app, at: address, token: token)
        let viewer = try XCTUnwrap(app.activeProfile)
        try await app.setAvatar("panda", profileID: viewer.id)
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            try await capture("\(name)-pictures", of: AvatarPickerSheet(app: app, profileID: viewer.id), app: app)
            try await capture("\(name)-pictures-kids", of: KidsAvatarPicker(app: app, profileID: viewer.id) {}, app: app)
            app.sidebarSelection = .library
            app.libraryPath = [.viewer(viewer.id)]
            try await capture("\(name)-viewer")
            app.libraryPath = []
            app.chooseAnotherProfile()
            try await capture("\(name)-viewers")
            await app.selectProfile(viewer)
        }
        NSApp.appearance = nil
        try await app.setAvatar(nil, profileID: viewer.id)
        await app.signOut()
        try await app.environment.forgetEverything()
    }

    /// The pages of a few titles with a backdrop, which colour their page.
    private func coloured(_ app: AppModel, _ look: String, open: (Item) -> Void) async throws {
        let items = app.wholeCatalogue.items.filter { $0.artwork.backdrop != nil && [.movie, .show].contains($0.kind) }
        let titles = environment["LOBBY_LOOK_TITLES"].map { Set($0.split(separator: ",").map(String.init)) }
        for item in items.filter({ titles?.contains($0.title) ?? true }).prefix(4) {
            open(item)
            try await settle()
            try await capture("\(look)-\(item.title.lowercased().replacing(" ", with: "-"))")
        }
    }

    private func screens(_ app: AppModel, _ look: String) async throws {
        app.sidebarSelection = .library
        try await capture("\(look)-library")
        app.sidebarSelection = .movies
        try await capture("\(look)-movies")
        if let film = app.shelves.movies.first {
            app.libraryPath = [.item(film.id)]
            try await capture("\(look)-film")
        }
        try await coloured(app, "\(look)-page") { app.libraryPath = [.item($0.id)] }
        if let category = app.shelves.groups.first?.categories.first {
            app.sidebarSelection = .category(category.id)
            try await capture("\(look)-category")
        }
        app.sidebarSelection = .downloads
        try await capture("\(look)-downloads")
        app.sidebarSelection = .manage
        try await capture("\(look)-devices")
        app.sidebarSelection = .categories
        try await capture("\(look)-categories")
        app.sidebarSelection = .library
        try await settle()
        app.isSearching = true
        app.searchText = "the"
        try await capture("\(look)-search")
        app.searchText = ""
        app.isSearching = false

        let categories = CategoriesModel(app: app)
        await categories.load()
        let group = try XCTUnwrap(categories.groups.last)
        let category = try XCTUnwrap(group.entries.first)
        try await capture("\(look)-category-editor", of: CategoryEditor(model: categories, draft: CategoryDraft(category, in: group)), app: app)
        let suggestions = SymbolSearch.suggestions(forName: category.name, genres: app.genres(ofCategory: category.id, in: categories.edit?.setup ?? .none))
        try await capture("\(look)-icons", of: IconPicker(selection: .constant(suggestions.first), suggestions: suggestions), app: app)
        try await capture("\(look)-icons-search", of: IconPicker(selection: .constant(nil), suggestions: [], query: "kerst"), app: app)
        try await capture("\(look)-icons-none", of: IconPicker(selection: .constant(nil), suggestions: [], query: "zzz"), app: app)
        if let film = app.shelves.movies.first {
            try await capture("\(look)-title-editor", of: ItemEditView(app: app, itemID: film.id), app: app)
        }
        try await capture("\(look)-settings", of: SettingsView().frame(width: 480), app: app)
    }
}
