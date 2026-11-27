// SPDX-License-Identifier: MPL-2.0
import Foundation
import Synchronization
import Testing

@testable import LobbyKit

@Suite struct CatalogueStoreTests {
    /// A library server that answers from a script: cursor sent → page.
    static func scripted(_ pages: [String: String]) -> StubServer {
        StubServer { request in
            guard request.path == "/v1/library" else { return .error(404, "not_found") }
            guard let page = pages[request.query["cursor"] ?? "<none>"] else {
                return .error(400, "invalid_request", "Unexpected cursor.")
            }
            return .json(200, page)
        }
    }

    @Test func theFirstSyncFetchesEveryPageAndSavesTheLastCursor() async throws {
        let directory = try TemporaryDirectory()
        let clock = TestClock()
        let stub = Self.scripted([
            "<none>": Fixtures.libraryPage(items: [Fixtures.item(id: "a"), Fixtures.item(id: "b")], cursor: "c1", more: true),
            "c1": Fixtures.libraryPage(items: [Fixtures.item(id: "c")], cursor: "c2", more: true),
            "c2": Fixtures.libraryPage(items: [Fixtures.movie], cursor: "c3"),
        ])
        let store = CatalogueStore(fileURL: directory.file("catalogue.json"), now: { clock.now })
        #expect(await store.catalogue().isEmpty)
        #expect(await store.lastSyncedAt() == nil)

        let catalogue = try await store.sync(using: stub.client(), pageSize: 2)

        #expect(Set(catalogue.itemsByID.keys) == ["a", "b", "c", "movie-1"])
        #expect(stub.recorded.map { $0.query["cursor"] } == [nil, "c1", "c2"])
        #expect(stub.recorded.allSatisfy { $0.query["limit"] == "2" })
        #expect(await store.lastSyncedAt() == clock.now)

        // The next sync asks only for what changed since.
        stub.setHandler { _ in .json(200, Fixtures.libraryPage(items: [], cursor: "c3")) }
        try await store.sync(using: stub.client())
        #expect(stub.recorded.last?.query == ["cursor": "c3"])
    }

    @Test func aFirstFetchCanBeShownWhileItArrives() async throws {
        let directory = try TemporaryDirectory()
        let stub = Self.scripted([
            "<none>": Fixtures.libraryPage(items: [Fixtures.item(id: "a"), Fixtures.item(id: "b")], cursor: "c1", more: true),
            "c1": Fixtures.libraryPage(items: [Fixtures.item(id: "c")], cursor: "c2", more: true),
            "c2": Fixtures.libraryPage(items: [Fixtures.movie], cursor: "c3"),
        ])
        let store = CatalogueStore(fileURL: directory.file("catalogue.json"))
        let seen = Mutex<[Int]>([])

        let catalogue = try await store.sync(using: stub.client(), pageSize: 2) { partial in
            seen.withLock { $0.append(partial.count) }
        }
        // After the first page and after the second. The third is the result.
        #expect(seen.withLock { $0 } == [2, 3])
        #expect(catalogue.count == 4)
    }

    @Test func thePagesOfAResetAreNotShownBeforeTheyAreAllThere() async throws {
        let directory = try TemporaryDirectory()
        let stub = Self.scripted([
            "<none>": Fixtures.libraryPage(items: [Fixtures.item(id: "old")], cursor: "c1"),
            "c1": Fixtures.libraryPage(items: [Fixtures.item(id: "new-1")], cursor: "n1", more: true, reset: true),
            "n1": Fixtures.libraryPage(items: [Fixtures.item(id: "new-2")], cursor: "n2"),
        ])
        let store = CatalogueStore(fileURL: directory.file("catalogue.json"))
        try await store.sync(using: stub.client())
        let calls = Mutex(0)
        let catalogue = try await store.sync(using: stub.client()) { _ in calls.withLock { $0 += 1 } }
        #expect(calls.withLock { $0 } == 0)
        #expect(Set(catalogue.itemsByID.keys) == ["new-1", "new-2"])
    }

    @Test func theCatalogueOpensFromTheFileWithTheServerUnreachable() async throws {
        let directory = try TemporaryDirectory()
        let stub = Self.scripted(["<none>": Fixtures.libraryPage(items: [Fixtures.movie, Fixtures.item(id: "b")], cursor: "c1")])
        try await CatalogueStore(fileURL: directory.file("catalogue.json")).sync(using: stub.client())
        stub.goOffline()

        // A new launch: a new store over the same file.
        let relaunched = CatalogueStore(fileURL: directory.file("catalogue.json"))
        let catalogue = await relaunched.catalogue()
        #expect(catalogue.count == 2)
        #expect(catalogue.item("movie-1")?.files.first?.audio.count == 2)
        #expect(catalogue.item("movie-1")?.addedAt.millisecondsSince1970 == 1_795_530_000_000)
        #expect(await relaunched.lastSyncedAt() != nil)

        await #expect(throws: LobbyError.unreachable(.cannotConnectToHost)) {
            try await relaunched.sync(using: stub.client())
        }
        #expect(await relaunched.catalogue() == catalogue)

        // Back online, it continues from the saved cursor.
        stub.setHandler { _ in .json(200, Fixtures.libraryPage(items: [Fixtures.item(id: "c")], cursor: "c2")) }
        let synced = try await relaunched.sync(using: stub.client())
        #expect(stub.recorded.last?.query == ["cursor": "c1"])
        #expect(synced.count == 3)
    }

    @Test func anIncrementalSyncUpdatesItemsAndDropsRemovedOnesWithTheirChildren() async throws {
        let directory = try TemporaryDirectory()
        let stub = Self.scripted([
            "<none>": Fixtures.libraryPage(
                items: [
                    Fixtures.item(id: "show", kind: "show"),
                    Fixtures.item(id: "season", kind: "season", parentId: "show"),
                    Fixtures.item(id: "ep1", kind: "episode", parentId: "season"),
                    Fixtures.item(id: "ep2", kind: "episode", parentId: "season"),
                    Fixtures.item(id: "film", title: "Old title"),
                    Fixtures.item(id: "other"),
                ], cursor: "c1"),
            "c1": Fixtures.libraryPage(
                items: [Fixtures.item(id: "film", title: "New title")], removed: ["show", "never-seen"], cursor: "c2"),
        ])
        let store = CatalogueStore(fileURL: directory.file("catalogue.json"))
        try await store.sync(using: stub.client())
        #expect(await store.catalogue().children(of: "season").count == 2)

        let catalogue = try await store.sync(using: stub.client())

        #expect(Set(catalogue.itemsByID.keys) == ["film", "other"])
        #expect(catalogue.item("film")?.title == "New title")
        #expect(catalogue.children(of: "season").isEmpty)
        // And it is what the next launch reads.
        #expect(await CatalogueStore(fileURL: directory.file("catalogue.json")).catalogue() == catalogue)
    }

    @Test func aResetReplacesTheLocalCopyOnlyOnceTheFullFetchIsComplete() async throws {
        let directory = try TemporaryDirectory()
        let stub = Self.scripted(["<none>": Fixtures.libraryPage(items: [Fixtures.item(id: "old-1"), Fixtures.item(id: "old-2")], cursor: "stale")])
        let store = CatalogueStore(fileURL: directory.file("catalogue.json"))
        let old = try await store.sync(using: stub.client())

        // The server no longer knows the cursor and starts a full fetch, which breaks off.
        let failSecondPage = Mutex(true)
        stub.setHandler { request in
            switch request.query["cursor"] {
            case "stale":
                return .json(200, Fixtures.libraryPage(items: [Fixtures.item(id: "new-1")], cursor: "n1", more: true, reset: true))
            case "n1":
                if failSecondPage.withLock({ $0 }) { throw URLError(.timedOut) }
                return .json(200, Fixtures.libraryPage(items: [Fixtures.item(id: "new-2")], cursor: "n2"))
            default:
                return .error(400, "invalid_request")
            }
        }
        await #expect(throws: LobbyError.unreachable(.timedOut)) { try await store.sync(using: stub.client()) }

        // Half a replacement is not shown, in memory or after a relaunch.
        #expect(await store.catalogue() == old)
        #expect(await CatalogueStore(fileURL: directory.file("catalogue.json")).catalogue() == old)

        failSecondPage.withLock { $0 = false }
        let catalogue = try await store.sync(using: stub.client())

        // The retry starts from the old cursor again, gets the reset again, and now completes.
        #expect(stub.recorded.suffix(2).map { $0.query["cursor"] } == ["stale", "n1"])
        #expect(Set(catalogue.itemsByID.keys) == ["new-1", "new-2"])

        stub.setHandler { _ in .json(200, Fixtures.libraryPage(items: [], cursor: "n2")) }
        try await store.sync(using: stub.client())
        #expect(stub.recorded.last?.query == ["cursor": "n2"])
    }

    @Test func aFailedPageKeepsTheCompletePagesBeforeItAndContinuesFromTheirCursor() async throws {
        let directory = try TemporaryDirectory()
        let stub = StubServer { request in
            switch request.query["cursor"] {
            case nil: .json(200, Fixtures.libraryPage(items: [Fixtures.item(id: "a")], cursor: "c1", more: true))
            default: throw URLError(.networkConnectionLost)
            }
        }
        let store = CatalogueStore(fileURL: directory.file("catalogue.json"))
        await #expect(throws: LobbyError.unreachable(.networkConnectionLost)) { try await store.sync(using: stub.client()) }
        #expect(await store.catalogue().count == 1)
        #expect(await store.lastSyncedAt() == nil)

        stub.setHandler { _ in .json(200, Fixtures.libraryPage(items: [Fixtures.item(id: "b")], cursor: "c2")) }
        let catalogue = try await store.sync(using: stub.client())
        #expect(stub.recorded.last?.query == ["cursor": "c1"])
        #expect(Set(catalogue.itemsByID.keys) == ["a", "b"])
    }

    @Test func aDamagedOrNewerFileCostsOneFullFetch() async throws {
        let directory = try TemporaryDirectory()
        let stub = Self.scripted(["<none>": Fixtures.libraryPage(items: [Fixtures.item(id: "a")], cursor: "c1")])

        for contents in ["not json at all", #"{ "version": 99, "cursor": "from-the-future", "things": [] }"#] {
            try Data(contents.utf8).write(to: directory.file("catalogue.json"))
            let store = CatalogueStore(fileURL: directory.file("catalogue.json"))
            #expect(await store.catalogue().isEmpty)
            #expect(try await store.sync(using: stub.client()).count == 1)
            #expect(stub.recorded.last?.query["cursor"] == nil)
        }
    }

    @Test func theFileCarriesItsFormatVersionAndIntegerInstants() async throws {
        let directory = try TemporaryDirectory()
        let stub = Self.scripted(["<none>": Fixtures.libraryPage(items: [Fixtures.movie], cursor: "c1")])
        try await CatalogueStore(fileURL: directory.file("catalogue.json")).sync(using: stub.client())

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.file("catalogue.json"))) as? [String: Any]
        #expect(object?["version"] as? Int == 2)
        #expect(object?["cursor"] as? String == "c1")
        let item = (object?["items"] as? [[String: Any]])?.first
        #expect(item?["addedAt"] as? Int == 1_795_530_000_000)
    }

    @Test func clearingForgetsTheCatalogueAndItsFile() async throws {
        let directory = try TemporaryDirectory()
        let stub = Self.scripted(["<none>": Fixtures.libraryPage(items: [Fixtures.item(id: "a")], cursor: "c1")])
        let store = CatalogueStore(fileURL: directory.file("catalogue.json"))
        try await store.sync(using: stub.client())

        try await store.clear()
        #expect(await store.catalogue().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.file("catalogue.json").path))
        try await store.clear()

        try await store.sync(using: stub.client())
        #expect(stub.recorded.last?.query["cursor"] == nil)
    }

    /// An app from before home pages dropped a title's logo and dates: they are in no change the
    /// server still has to tell.
    @Test func aCopyOfTheFormerFormatIsShownAndThenFetchedInFull() async throws {
        let directory = try TemporaryDirectory()
        let file = directory.file("catalogue.json")
        let old = #"{"version":1,"cursor":"c9","lastSyncedAt":1000,"items":[\#(Fixtures.item(id: "a")),\#(Fixtures.item(id: "gone"))]}"#
        try Data(old.utf8).write(to: file)
        let store = CatalogueStore(fileURL: file)
        #expect(Set(await store.catalogue().itemsByID.keys) == ["a", "gone"])
        #expect(await store.lastSyncedAt() != nil)

        let stub = Self.scripted(["<none>": Fixtures.libraryPage(items: [Fixtures.item(id: "a")], cursor: "c10")])
        let synced = try await store.sync(using: stub.client())
        #expect(stub.recorded.map { $0.query["cursor"] } == [nil])
        #expect(Set(synced.itemsByID.keys) == ["a"], "What went meanwhile is not kept.")
        // From there on only what changed.
        stub.setHandler { _ in .json(200, Fixtures.libraryPage(items: [], cursor: "c10")) }
        try await CatalogueStore(fileURL: file).sync(using: stub.client())
        #expect(stub.recorded.last?.query == ["cursor": "c10"])
    }

    @Test func aCatalogueOfTheRealSizeSavesAndLoads() async throws {
        let directory = try TemporaryDirectory()
        let file = try LobbyJSON.decoder().decode(MediaFile.self, from: Data(Fixtures.mediaFile.utf8))
        let items = (0..<4000).map { index in
            Item(
                id: "item-\(index)", kind: .movie, title: "Film \(index)", overview: String(repeating: "A story. ", count: 30),
                genres: ["Animation", "Family"], categories: ["Pixar"], addedAt: Make.date(index), files: [file])
        }
        let page = try LobbyJSON.encoder().encode(LibraryPage(items: items, cursor: "c1"))
        let stub = StubServer { _ in StubResponse(status: 200, body: page) }

        let synced = try await CatalogueStore(fileURL: directory.file("catalogue.json")).sync(using: stub.client())
        let loaded = await CatalogueStore(fileURL: directory.file("catalogue.json")).catalogue()

        #expect(loaded.count == 4000)
        #expect(loaded == synced)
    }
}
