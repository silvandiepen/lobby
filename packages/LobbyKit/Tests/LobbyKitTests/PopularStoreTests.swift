// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing

@testable import LobbyKit

@Suite struct PopularStoreTests {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "popular-\(UUID().uuidString).json")
    }

    @Test func whatWasWatchedIsKeptForOfflineAndAskedForByItsTag() async throws {
        let stub = StubServer { request in
            if request.headers["If-None-Match"] == "\"t1\"" { return StubResponse(status: 304) }
            let titles = request.query["viewers"] == "kids" ? #"[{"itemId":"k","plays":2}]"# : #"[{"itemId":"a","plays":5},{"itemId":"b","plays":1}]"#
            return StubResponse(
                status: 200, headers: ["Content-Type": "application/json", "ETag": "\"t1\""],
                body: Data(#"{"days":180,"viewers":"all","titles":\#(titles)}"#.utf8))
        }
        let client = try stub.client()
        let url = file()
        let store = PopularStore(fileURL: url)
        #expect(try await store.sync(kidsOnly: false, using: client).titles.map(\.itemId) == ["a", "b"])
        #expect(try await store.sync(kidsOnly: true, using: client).titles.map(\.itemId) == ["k"])
        // Not changed: the kept answer.
        #expect(try await store.sync(kidsOnly: false, using: client).titles.map(\.plays) == [5, 1])
        let relaunched = PopularStore(fileURL: url)
        #expect(await relaunched.popular(kidsOnly: false).titles.count == 2)
        #expect(await relaunched.popular(kidsOnly: true).titles.map(\.itemId) == ["k"])
        try await relaunched.clear()
        #expect(await PopularStore(fileURL: url).popular(kidsOnly: false) == .none)
    }

    @Test func anOlderServerKnowsNothing() async throws {
        let stub = StubServer { _ in .error(404, "not_found", "No such route.") }
        #expect(try await PopularStore(fileURL: file()).sync(kidsOnly: false, using: try stub.client()) == .none)
    }

    @Test func aTitleOfAnOlderServerHasNothingMore() throws {
        let old = #"{"id":"m","kind":"movie","parentId":null,"title":"T","sortTitle":"t","year":null,"seasonNumber":null,"episodeNumber":null,"overview":null,"airDate":null,"runtimeMs":null,"genres":[],"categories":[],"matchStatus":"matched","imdbId":null,"tmdb":null,"extraKind":null,"trailer":null,"artwork":{"poster":null,"backdrop":null,"still":null},"addedAt":0,"available":true,"files":[]}"#
        let item = try LobbyJSON.decoder().decode(Item.self, from: Data(old.utf8))
        #expect(item.artwork.logo == nil && item.renown == nil && item.tagline == nil && item.newEpisodesAt == nil)
    }
}
