// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing

@testable import LobbyKit

@Suite struct CategoryEditingClientTests {
    static func view(_ revision: Int) -> String {
        #""revision": \#(revision), "groups": [ { "id": "g0", "name": null, "icon": null, "color": null, "logo": null, "categories": ["A"], "entries": [ { "id": "c1", "name": "A", "icon": null, "color": null, "logo": null } ] } ], "logos": {}, "folders": [ { "id": "f1", "name": "Films", "hint": "movies", "available": true, "categoryId": "c1" }, { "id": "f2", "name": "Loose", "hint": "mixed", "available": false, "categoryId": null } ], "colors": ["red", "teal"]"#
    }

    @Test func readsTheSetupWithItsFoldersAndColours() async throws {
        let stub = StubServer { _ in .json(200, "{ \(Self.view(7)) }") }
        let edit = try await stub.client().categoriesEdit()
        #expect(edit.revision == 7)
        #expect(edit.setup.category(id: "c1")?.name == "A")
        #expect(edit.folders.map(\.categoryId) == ["c1", nil])
        #expect(edit.colors == ["red", "teal"])
        #expect(stub.recorded[0].path == "/v1/categories/edit")
    }

    @Test func everyChangeNamesItsRevisionAndGoesToItsOwnRoute() async throws {
        let stub = StubServer { _ in .json(200, "{ \(Self.view(8)) }") }
        let client = try stub.client()
        _ = try await client.createGroup(name: "G", icon: nil, color: "red", revision: 7)
        _ = try await client.createCategory(groupID: "g0", name: "B", icon: "star.fill", color: nil, revision: 7)
        _ = try await client.updateLook(of: .category("c1"), name: "C", icon: nil, color: nil, revision: 7)
        _ = try await client.updateLook(of: .group("g0"), name: nil, icon: "tv", color: "teal", revision: 7)
        _ = try await client.moveCategory(id: "c1", toGroup: "g1", revision: 7)
        _ = try await client.orderGroups(["g1"], revision: 7)
        _ = try await client.orderCategories(groupID: "g0", ids: ["c1"], revision: 7)
        _ = try await client.deleteGroup(id: "g1", movingCategoriesTo: "g0", revision: 7)
        _ = try await client.deleteCategory(id: "c1", foldersTo: FoldersTarget.none, revision: 7)
        _ = try await client.deleteCategory(id: "c1", foldersTo: .category("c2"), revision: 7)
        _ = try await client.assignFolder(id: "f1", to: nil, revision: 7)
        _ = try await client.setLogo(of: .group("g1"), path: "/x.png", revision: 7)
        _ = try await client.uploadLogo(of: .category("c1"), picture: Data([1, 2]), contentType: "image/png", revision: 7)
        _ = try await client.removeLogo(of: .category("c1"), revision: 7)

        let sent = stub.recorded
        #expect(sent.map { "\($0.method) \($0.path)" } == [
            "POST /v1/categories/groups", "POST /v1/categories", "PATCH /v1/categories/c1", "PATCH /v1/categories/groups/g0",
            "PATCH /v1/categories/c1", "PUT /v1/categories/groups/order", "PUT /v1/categories/order",
            "DELETE /v1/categories/groups/g1", "DELETE /v1/categories/c1", "DELETE /v1/categories/c1",
            "PUT /v1/categories/folders/f1", "PUT /v1/categories/groups/g1/logo", "POST /v1/categories/c1/logo/upload",
            "DELETE /v1/categories/c1/logo",
        ])
        for request in sent {
            if let inQuery = request.query["revision"] {
                #expect(inQuery == "7")
            } else {
                #expect(try request.json()["revision"] as? Int == 7)
            }
        }
        // Taking an icon away is an explicit null, and the main part's name is left out.
        #expect(try sent[2].json()["icon"] is NSNull)
        #expect(try sent[2].json()["name"] as? String == "C")
        #expect(try sent[3].json()["name"] == nil)
        #expect(sent[7].query["moveTo"] == "g0")
        #expect(sent[8].query["foldersTo"] == "none")
        #expect(sent[9].query["foldersTo"] == "c2")
        #expect(try sent[10].json()["categoryId"] is NSNull)
        #expect(sent[12].body == Data([1, 2]))
        #expect(sent[12].headers["Content-Type"] == "image/png")
    }

    @Test func aChangeSomeoneWasFirstWithCarriesWhatThereIsNow() async throws {
        let stub = StubServer { _ in
            .json(409, #"{ "error": { "code": "conflict", "message": "Someone was first." }, \#(Self.view(9)) }"#)
        }
        do {
            _ = try await stub.client().orderGroups(["g1"], revision: 7)
            Issue.record("It should be refused.")
        } catch let conflict as EditConflict<CategoriesEdit> {
            #expect(conflict.message == "Someone was first.")
            #expect(conflict.current.revision == 9)
        }
    }

    @Test func aRefusalKeepsTheServersSentence() async throws {
        let stub = StubServer { _ in .error(400, "invalid_request") }
        await #expect(throws: LobbyError.self) { try await stub.client().createGroup(name: "", icon: nil, color: nil, revision: 1) }
    }

    @Test func aPreviewIsOnlyFetchedFromTheServerItself() async throws {
        let stub = StubServer { _ in .json(200, "{}") }
        let client = try stub.client()
        _ = try await client.picture(atServerPath: "/v1/categories/logo-search/preview?path=%2Fx.png")
        #expect(stub.recorded[0].path == "/v1/categories/logo-search/preview")
        #expect(stub.recorded[0].query["path"] == "/x.png")
        // The credential does not go to another host.
        await #expect(throws: LobbyError.self) { try await client.picture(atServerPath: "http://other.example/x.png") }
        #expect(stub.recorded.count == 1)
    }
}

@Suite struct ItemEditingClientTests {
    static func view(_ revision: Int) -> String {
        #""item": { "id": "i1", "kind": "movie", "parentId": null, "title": "Up", "sortTitle": "up", "year": 2009, "genres": [], "categories": ["A"], "categoryIds": ["c1"], "matchStatus": "locked", "artwork": { "poster": null, "backdrop": null, "still": null }, "addedAt": 1, "available": true, "files": [] }, "revision": \#(revision), "fields": { "title": { "automatic": "Up", "overridden": false, "override": null, "effective": "Up" }, "year": { "automatic": 2009, "overridden": true, "override": null, "effective": null }, "genres": { "automatic": ["Animation"], "overridden": false, "override": null, "effective": ["Animation"] }, "categories": { "automatic": ["A"], "overridden": false, "override": null, "effective": ["A"] } }, "categories": [ { "id": "c1", "name": "A" } ], "categoryIds": { "automatic": ["c1"], "overridden": false, "effective": ["c1"] }, "categoryNames": ["A"], "artwork": { "poster": [ { "source": "tmdb", "artworkId": "p1", "path": "/p.jpg", "previewUrl": "/v1/artwork/p1?w=200", "width": 500, "height": 750, "language": "en", "selected": true, "chosen": false } ], "backdrop": [] }, "match": { "status": "locked", "chosen": true, "tmdb": { "type": "movie", "id": 14160 }, "canChange": true, "available": true, "reason": null, "candidates": [], "evidence": ["title Up"] }"#
    }

    @Test func readsATitleAsItIsEdited() async throws {
        let stub = StubServer { _ in .json(200, "{ \(Self.view(3)) }") }
        let edit = try await stub.client().itemEdit(id: "i1")
        #expect(stub.recorded[0].path == "/v1/items/i1/edit")
        #expect(edit.revision == 3)
        #expect(edit.fields.title?.effective == "Up")
        // Changed to nothing, which is not the same as not changed.
        #expect(edit.fields.year?.overridden == true)
        #expect(edit.fields.year?.effective == nil)
        #expect(edit.fields.overview == nil)
        #expect(edit.artworkKinds == [.poster, .backdrop])
        #expect(edit.options(for: .poster).first?.selected == true)
        #expect(edit.match.tmdb?.id == 14160)
    }

    @Test func onlyWhatChangedIsSent() async throws {
        let stub = StubServer { _ in .json(200, "{ \(Self.view(4)) }") }
        let client = try stub.client()
        _ = try await client.updateItem(id: "i1", changes: ItemChanges(title: "Up!", year: .some(nil), reset: [.overview, .genres]), revision: 3)
        let body = try stub.recorded[0].json()
        #expect(stub.recorded[0].method == "PATCH")
        #expect(body["revision"] as? Int == 3)
        let set = try #require(body["set"] as? [String: Any])
        #expect(set.keys.sorted() == ["title", "year"])
        #expect(set["year"] is NSNull)
        #expect(body["reset"] as? [String] == ["genres", "overview"])
        #expect(ItemChanges().isEmpty)
    }

    @Test func picturesAndMatchesGoToTheirOwnRoutes() async throws {
        let stub = StubServer { request in
            request.path.hasSuffix("/match") && request.method == "GET"
                ? .json(200, #"{ "results": [ { "tmdb": { "type": "movie", "id": 7 }, "title": "Up", "originalTitle": null, "year": 2009, "overview": null, "previewUrl": null } ] }"#)
                : request.path.hasSuffix("/artwork-options")
                ? .json(200, #"{ "kind": "poster", "revision": 3, "tmdbAvailable": true, "options": [ { "source": "tmdb", "artworkId": null, "path": "/x.jpg", "previewUrl": "/v1/p", "width": null, "height": null, "language": null, "selected": false, "chosen": false } ] }"#)
                : .json(200, "{ \(Self.view(4)) }")
        }
        let client = try stub.client()
        let options = try await client.artworkOptions(itemID: "i1", kind: .poster)
        _ = try await client.chooseArtwork(itemID: "i1", kind: .poster, option: options.options[0], revision: 3)
        _ = try await client.chooseFrame(itemID: "i1", kind: .backdrop, positionMs: 754_000, revision: 3)
        _ = try await client.uploadArtwork(itemID: "i1", kind: .poster, picture: Data([0xFF, 0xD8]), revision: 3)
        _ = try await client.resetArtwork(itemID: "i1", kind: .poster, revision: 3)
        let found = try await client.searchMatch(itemID: "i1", query: "up", year: 2009)
        _ = try await client.setMatch(itemID: "i1", to: found[0].tmdb, revision: 3)
        _ = try await client.removeMatch(itemID: "i1", revision: 3)
        _ = try await client.automaticMatch(itemID: "i1", revision: 3)

        let sent = stub.recorded
        #expect(sent.map { "\($0.method) \($0.path)" } == [
            "GET /v1/items/i1/artwork-options", "POST /v1/items/i1/artwork", "POST /v1/items/i1/artwork",
            "POST /v1/items/i1/artwork/upload", "DELETE /v1/items/i1/artwork", "GET /v1/items/i1/match",
            "PUT /v1/items/i1/match", "DELETE /v1/items/i1/match", "POST /v1/items/i1/match/automatic",
        ])
        #expect(try sent[1].json()["source"] as? String == "tmdb")
        #expect(try sent[1].json()["path"] as? String == "/x.jpg")
        #expect(try sent[2].json()["positionMs"] as? Int == 754_000)
        #expect(sent[3].query["kind"] == "poster")
        #expect(sent[3].query["revision"] == "3")
        #expect(sent[3].headers["Content-Type"] == "image/jpeg")
        #expect(try sent[6].json()["tmdbId"] as? Int == 7)
    }

    @Test func anEditSomeoneWasFirstWithCarriesTheTitleAsItIsNow() async throws {
        let stub = StubServer { _ in .json(409, #"{ "error": { "code": "conflict", "message": "Changed." }, \#(Self.view(9)) }"#) }
        await #expect(throws: EditConflict<ItemEdit>.self) {
            try await stub.client().updateItem(id: "i1", changes: ItemChanges(title: "x"), revision: 1)
        }
    }
}

/// Categories inside a category: one request for an arrangement, its undo, the
/// question about kids viewers, and studio suggestions.
@Suite struct ArrangingClientTests {
    static let view = CategoryEditingClientTests.view(9)

    @Test func anArrangementSendsNewOnesChangesAndOrderAsTheServerReadsThem() async throws {
        let stub = StubServer { _ in .json(200, #"{ \#(Self.view), "undo": "u-1", "created": { "top": "c9" } }"#) }
        let arrangement = CategoryArrangement(
            create: [.init(key: "top", groupID: "g0", name: "Lantern", color: .some("blue"), logoFrom: "c1")],
            categories: [.init(id: "c1", name: "Early", parentID: .some(CategoryArrangement.newID("top"))), .init(id: "c2", parentID: .some(nil))],
            order: [.init(groupID: "g0", parentID: "new:top", ids: ["c1"])])
        let edit = try await stub.client().arrange(arrangement, revision: 8, kidsToken: "k-1")
        #expect(edit.undo == "u-1")
        #expect(edit.created == ["top": "c9"])

        let body = try stub.recorded[0].json()
        #expect(stub.recorded[0].path == "/v1/categories/arrange")
        #expect(body["revision"] as? Int == 8)
        #expect(body["kidsToken"] as? String == "k-1")
        let create = try #require((body["create"] as? [[String: Any]])?.first)
        #expect(create["name"] as? String == "Lantern" && create["logoFrom"] as? String == "c1" && create["color"] as? String == "blue")
        #expect(create.keys.contains("icon") == false)
        let changes = try #require(body["categories"] as? [[String: Any]])
        #expect(changes[0]["parentId"] as? String == "new:top")
        // Out of its parent: an explicit null, not a field left out.
        #expect(changes[1].keys.contains("parentId") && changes[1]["parentId"] is NSNull)
        #expect(changes[1].keys.contains("name") == false)
        #expect((body["order"] as? [[String: Any]])?.first?["ids"] as? [String] == ["c1"])
    }

    @Test func aChangeThatShowsAChildMoreIsAQuestionWithTheSetupAsItIs() async throws {
        let stub = StubServer { _ in
            .json(409, #"""
            { "error": { "code": "kids_confirmation", "message": "This lets Pip see more than now." }, \#(Self.view),
              "kidsChanges": [ { "profileId": "p1", "name": "Pip",
                "appearing": { "count": 3, "titles": [ { "id": "t1", "title": "Tide" } ] },
                "disappearing": { "count": 0, "titles": [] } } ],
              "kidsToken": "k-2" }
            """#)
        }
        do {
            _ = try await stub.client().undoArrangement(token: "u-1", revision: 9)
            Issue.record("A question was expected")
        } catch let question as KidsConfirmationNeeded<CategoriesEdit> {
            #expect(question.token == "k-2")
            #expect(question.changes.first?.appearing.count == 3)
            #expect(question.changes.first?.appearing.titles.map(\.title) == ["Tide"])
            #expect(question.current.revision == 9)
            #expect(question.message == "This lets Pip see more than now.")
        }
        #expect(stub.recorded[0].path == "/v1/categories/arrange/undo")
        #expect(try stub.recorded[0].json()["token"] as? String == "u-1")
    }

    @Test func aDeleteAsksWithTheTokenInTheQuery() async throws {
        let stub = StubServer { _ in .json(200, "{ \(Self.view) }") }
        _ = try await stub.client().deleteCategory(id: "c1", foldersTo: nil, revision: 9, kidsToken: "k-3")
        #expect(stub.recorded[0].query["kidsToken"] == "k-3")
        #expect(stub.recorded[0].query["revision"] == "9")
    }

    @Test func suggestionsAreReadAcceptedAndDismissed() async throws {
        let list = #"{ "min": 8, "suggestions": [ { "id": "s1", "name": "Kite Works", "studios": [ { "id": "company:7", "name": "Kite Works Animation", "logoPath": "/k.png", "titles": 12 } ], "count": 12, "titles": [ { "id": "t1", "title": "Tide" } ], "logoPath": "/k.png", "categoryId": null } ] }"#
        let stub = StubServer { request in
            request.path.hasSuffix("/accept") ? .json(200, #"{ \#(Self.view), "categoryId": "c5" }"#) : .json(200, list)
        }
        let client = try stub.client()
        let found = try await client.categorySuggestions()
        #expect(found.suggestions.first?.studios.first?.titles == 12)
        #expect(found.suggestions.first?.logoPreviewPath == "/v1/categories/logo-search/preview?path=%2Fk.png")
        let accepted = try await client.acceptSuggestion(id: "s1", groupID: "g0", revision: 9)
        #expect(accepted.categoryId == "c5")
        _ = try await client.dismissSuggestion(id: "s1")
        #expect(stub.recorded.map { "\($0.method) \($0.path)" } == [
            "GET /v1/categories/suggestions", "POST /v1/categories/suggestions/s1/accept", "POST /v1/categories/suggestions/s1/dismiss",
        ])
        #expect(try stub.recorded[1].json()["groupId"] as? String == "g0")
    }

    @Test func aCategoryKnowsItsParentAndRuleAndAnOlderServerSaysNeither() throws {
        let json = #"{ "revision": 2, "groups": [ { "id": "g", "name": "Small", "entries": [ { "id": "p", "parentId": null, "name": "Lantern", "icon": null, "color": null, "logo": null, "rule": null }, { "id": "s", "parentId": "p", "name": "Early", "icon": null, "color": null, "logo": null, "rule": { "studioIds": ["company:7"] } } ] } ] }"#
        let groups = try JSONDecoder().decode(CategoryGroups.self, from: Data(json.utf8))
        #expect(groups.parent(of: "s")?.id == "p")
        #expect(groups.children(of: "p").map(\.id) == ["s"])
        #expect(groups.topLevelID(of: "s") == "p")
        #expect(groups.category(id: "s")?.rule?.studioIds == ["company:7"])
        var film = Make.movie("f", categories: ["Early"])
        film.categoryIds = ["s"]
        film.ruleCategoryIds = ["x"]
        #expect(groups.pageCategoryIDs(of: film) == ["s", "p", "x"])
        // As before: no parent, no rule.
        let older = try JSONDecoder().decode(CategoryGroups.self, from: Data(#"{ "groups": [ { "name": "Kids", "categories": ["A"] } ] }"#.utf8))
        #expect(older.category(id: "A")?.parentId == nil && older.category(id: "A")?.rule == nil)
    }
}
