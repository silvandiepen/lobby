// SPDX-License-Identifier: MPL-2.0
import AppKit
import CoreText
import LobbyKit
import SwiftUI
import XCTest

@testable import Lobby

/// Pictures of a studio's page with its sections, and of arranging categories, for looking
/// at by eye. Made-up films with made-up art, against the stub household; it skips unless
/// it was asked for:
///
///     LOBBY_SHOTS=<folder>      where the PNGs go
///     LOBBY_SHOTS_ART=<folder>  posters and stills as JPEG, named like the films below
///
/// (`TEST_RUNNER_LOBBY_SHOTS=…` with xcodebuild.) With `LOBBY_SHOTS_CAPTURE=1` a script
/// outside takes each picture: it waits for `<folder>/.request` ("<window number> <name>"),
/// runs `screencapture -l` and removes the file. Without, the views are drawn into a bitmap,
/// which leaves their pictures out.
@MainActor
final class SubcategoriesLook: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// Poster, and a still for the banner when there is one, by category.
    private static let films: [(id: String, still: String?, category: String, ruled: Bool)] = [
        ("bread-moon", nil, "classics", false), ("cold-moon", nil, "classics", false),
        ("nine-lamps", "still-lamps", "classics", false), ("paper-comet", nil, "classics", false),
        ("mossback-express", "still-mossback", "sequels", false), ("orbit-grocery", "still-orbit", "sequels", false),
        ("low-tide-radio", "still-radio-1", "sequels", false),
        ("salt-cartographer", "still-salt", "live", false), ("tuba-island", "still-tuba", "live", false),
        ("button-submarine", nil, "live", false),
        ("kelder-moss", nil, "pebble", false), ("quiet-kettle", nil, "pebble", false),
        ("six-left-shoes", nil, "pebble", true), ("snow-ledger", nil, "pebble", false),
        ("tin-orchard", nil, "films", false), ("umbrella-thief", nil, "films", true),
    ]

    private static func title(_ id: String) -> String {
        id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private func household(art: URL) throws -> Household {
        var state = Household.State(device: Device(id: "dev-1", name: "Mac", platform: .macos, role: .manager, createdAt: Make.epoch))
        state.knowsKids = true
        state.profiles = [
            Profile(id: "me", name: "Robin", color: "blue"),
            Profile(id: "pip", name: "Pip", color: "green", kids: KidsSettings(allowedCategoryIds: ["lantern", "pebble"], knowsBlockedCategories: true)),
        ]
        state.categoryGroups = CategoryGroups(groups: [
            CategoryGroup(id: "g0", name: nil, entries: [LibraryCategory(id: "films", name: "Films")]),
            CategoryGroup(id: "g-small", name: "Small", icon: "sparkles", color: "teal", entries: [
                LibraryCategory(id: "lantern", name: "Lantern", icon: "lamp.desk.fill", color: "blue"),
                LibraryCategory(id: "classics", parentId: "lantern", name: "Classics"),
                LibraryCategory(id: "sequels", parentId: "lantern", name: "Sequels"),
                LibraryCategory(id: "live", parentId: "lantern", name: "Live Action"),
                LibraryCategory(id: "pebble", name: "Pebble", icon: "circle.fill", color: "orange"),
                LibraryCategory(id: "kite", name: "Kite Works", icon: "wind", rule: CategoryRule(studioIds: ["company:7"])),
            ]),
        ], revision: 5)
        state.folders = ["Lantern": "classics", "Lantern 2": "sequels", "Pebble": "pebble", "Films": "films"]
        for (index, film) in Self.films.enumerated() {
            var item = Make.movie(
                film.id, title: Self.title(film.id), year: 1990 + index, categories: [film.category],
                files: [Make.file(assetID: "asset-\(film.id)")])
            item.categoryIds = [film.category]
            item.ruleCategoryIds = film.ruled ? ["kite"] : []
            item.addedAt = Make.epoch.addingTimeInterval(TimeInterval(-index * 86_400))
            item.genres = index.isMultiple(of: 2) ? ["Adventure", "Family"] : ["Animation", "Comedy"]
            item.overview = "A made-up film for looking at the app."
            item.artwork = ArtworkSet(
                poster: Artwork(id: film.id, width: 400, height: 600),
                backdrop: film.still.map { Artwork(id: $0, width: 1920, height: 1080) })
            state.items.append(item)
            state.pictures[film.id] = try Data(contentsOf: art.appending(path: "\(film.id).jpg"))
            if let still = film.still { state.pictures[still] = try Data(contentsOf: art.appending(path: "\(still).jpg")) }
        }
        state.pictures["/marsh.png"] = try Self.wordMark("MARSH LANE")
        state.suggestions = #"""
        {"min":8,"suggestions":[{"id":"s3","name":"Marsh Lane","studios":[{"id":"company:3","name":"Marsh Lane Animation","logoPath":"/marsh.png","titles":12}],
         "count":12,"titles":[{"id":"t1","title":"Bread Moon"},{"id":"t2","title":"Cold Moon"},{"id":"t3","title":"Snow Ledger"}],"logoPath":"/marsh.png","categoryId":null}]}
        """#
        return Household(state)
    }

    /// A made-up studio's logo: its name in black on nothing.
    private static func wordMark(_ text: String) throws -> Data {
        let size = CGSize(width: 520, height: 120)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let font = CTFontCreateWithName("AvenirNext-Heavy" as CFString, 72, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: CGColor(gray: 0, alpha: 1),
        ]))
        context.textPosition = CGPoint(x: 12, y: 32)
        CTLineDraw(line, context)
        let image = try XCTUnwrap(context.makeImage())
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    private func settle(_ seconds: Double = 6) async throws {
        try await Task.sleep(for: .seconds(seconds))
        CATransaction.flush()
    }

    private func shoot(_ name: String, _ view: some View, app: AppModel, size: CGSize, into folder: URL) async throws {
        let host = NSHostingView(rootView: view.environment(app).tint(Color("AccentColor")))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.center()
        window.orderFrontRegardless()
        try await settle()
        if environment["LOBBY_SHOTS_CAPTURE"] != nil {
            // Taken from outside (`screencapture -l <window number>`): a bitmap of the view
            // leaves out pictures and layers. The script removes the request when it is done.
            let request = folder.appending(path: ".request")
            try "\(window.windowNumber) \(name)".write(to: request, atomically: true, encoding: .utf8)
            for _ in 0..<150 where FileManager.default.fileExists(atPath: request.path) {
                try await Task.sleep(for: .milliseconds(100))
            }
        } else {
            let bounds = host.bounds
            let picture = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: bounds))
            host.cacheDisplay(in: bounds, to: picture)
            try XCTUnwrap(picture.representation(using: .png, properties: [:])).write(to: folder.appending(path: "\(name).png"))
        }
        window.close()
    }

    func testSubcategoryScreens() async throws {
        guard let out = environment["LOBBY_SHOTS"].map(URL.init(fileURLWithPath:)),
            let art = environment["LOBBY_SHOTS_ART"].map(URL.init(fileURLWithPath:))
        else { throw XCTSkip("No LOBBY_SHOTS and LOBBY_SHOTS_ART: pictures were not asked for.") }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let test = try TestApp(try household(art: art))
        let app = try await test.launchPaired(as: "me")
        let wide = CGSize(width: 1280, height: 860), sheet = CGSize(width: 560, height: 640)

        for (look, scheme) in [("dark", ColorScheme.dark), ("light", .light)] {
            func shot(_ name: String, _ view: some View, size: CGSize = wide) async throws {
                try await shoot("\(look)-\(name)", view.environment(\.colorScheme, scheme).preferredColorScheme(scheme), app: app, size: size, into: out)
            }
            try await shot("studio-page", NavigationStack { CategoryPage(id: "folder:lantern").lobbyDestinations() })
            try await shot("studio-section", NavigationStack { CategoryPage(id: "folder:sequels").lobbyDestinations() })
            try await shot("search-sections", NavigationStack { SearchResultsView(query: .constant("seq")) })
            try await shot("categories-before", NavigationStack { CategoriesView(app: app) }, size: CGSize(width: 900, height: 1100))

            let model = CategoriesModel(app: app)
            await model.load()
            let small = try XCTUnwrap(model.groups.first { $0.id == "g-small" })
            try await shot("make-one-of-several", CategoryGroupingSheet(model: model, group: small, chosen: ["pebble"]), size: sheet)
            try await shot("kids-question", KidsQuestionSheet(model: model, question: KidsQuestion(
                message: "This lets Pip see more than now.",
                changes: [KidsChange(
                    profileId: "pip", name: "Pip",
                    appearing: .init(count: 4, titles: ["Kelder Moss", "Quiet Kettle", "Six Left Shoes", "Snow Ledger"].map {
                        .init(id: $0, title: $0)
                    }),
                    disappearing: .init(count: 0, titles: []))],
                token: "t", retry: { client, revision, token in try await client.categoriesEdit() })), size: sheet)
            try await shot("kids-limits", NavigationStack { ViewerPageView(app: app, profileID: "pip") }, size: CGSize(width: 700, height: 1000))
        }

        // After an arrangement: the undo is offered.
        let model = CategoriesModel(app: app)
        await model.load()
        let small = try XCTUnwrap(model.groups.first { $0.id == "g-small" })
        if let arrangement = CategoryTree(small).takingOut("live") { await model.arrange(arrangement) }
        try await shoot("dark-categories-undo", NavigationStack { CategoriesView(app: app) }.preferredColorScheme(.dark), app: app, size: CGSize(width: 900, height: 1100), into: out)
        await model.undo()

        // The same page for a child.
        await app.selectProfile(try XCTUnwrap(app.profiles.first { $0.id == "pip" }))
        try await settle()
        XCTAssertEqual(app.kidsLibrary.category("folder:lantern")?.subcategories.count, 3)
        for (look, scheme) in [("dark", ColorScheme.dark), ("light", .light)] {
            try await shoot(
                "\(look)-kids-studio-page", NavigationStack { KidsCategoryView(categoryID: "folder:lantern") }.preferredColorScheme(scheme),
                app: app, size: wide, into: out)
        }
    }
}
