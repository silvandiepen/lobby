// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing

@testable import LobbyKit

@Suite struct KidsTests {
    private func profile(_ json: String) throws -> Profile {
        try LobbyJSON.decoder().decode(Profile.self, from: Data(json.utf8))
    }

    // MARK: Decoding

    @Test func anOlderServerSaysNothingAboutKids() throws {
        let old = try profile(#"{"id":"p1","name":"A","color":"red"}"#)
        #expect(old.kids == nil)
        #expect(!old.saysKids)
        let off = try profile(#"{"id":"p1","name":"A","color":"red","kids":null}"#)
        #expect(off.kids == nil)
        #expect(off.saysKids)
        let on = try profile(#"{"id":"p1","name":"A","color":"red","kids":{"allowedGroupIds":["g"]}}"#)
        #expect(on.kids == KidsSettings(allowedGroupIds: ["g"]))
    }

    @Test func silenceKeepsWhatWasKnownAndAnAnswerReplacesIt() throws {
        let known = Profile(id: "p1", name: "A", color: "red", kids: KidsSettings(allowedItemIds: ["x"]))
        #expect(Profile(id: "p1", name: "B", color: "red").keepingUnsaid(of: known).kids == known.kids)
        #expect(Profile(id: "p1", name: "B", color: "red", kids: nil, saysKids: true).keepingUnsaid(of: known).kids == nil)
        #expect(Profile(id: "p2", name: "B", color: "red").keepingUnsaid(of: known).kids == nil)
    }

    @Test func whatIsKeptOnTheDeviceSaysTheSameWhenItIsReadBack() throws {
        for kids in [nil, KidsSettings(), KidsSettings(allowedCategoryIds: ["c"], blockedItemIds: ["b"])] {
            let one = Profile(id: "p", name: "N", color: "blue", kids: kids, saysKids: true)
            #expect(try LobbyJSON.decoder().decode(Profile.self, from: LobbyJSON.encoder().encode(one)) == one)
        }
        let device = Device(id: "d", name: "N", platform: .ios, role: .viewer, createdAt: Make.epoch, kidsProfileId: "p")
        let back = try LobbyJSON.decoder().decode(Device.self, from: LobbyJSON.encoder().encode(device))
        #expect(back == device)
        #expect(Device(id: "d", name: "N", platform: .ios, role: .viewer, createdAt: Make.epoch).keepingKidsProfile(of: back).kidsProfileId == "p")
        let freed = Device(id: "d", name: "N", platform: .ios, role: .viewer, createdAt: Make.epoch, saysKidsProfile: true)
        #expect(freed.keepingKidsProfile(of: back).kidsProfileId == nil)
    }

    // MARK: Requests

    @Test func kidsAndBindingsAreSentWithExplicitNulls() async throws {
        let stub = StubServer { request in
            request.path.contains("devices")
                ? .json(200, #"{"id":"d","name":"N","platform":"ios","role":"viewer","createdAt":1,"lastUsedAt":null,"revokedAt":null,"kidsProfileId":"p"}"#)
                : .json(200, #"{"id":"p","name":"N","color":"red","kids":null}"#)
        }
        let client = try LobbyClient(baseURL: stub.baseURL, token: "t", session: stub.session)
        _ = try await client.setKids(nil, profileID: "p")
        _ = try await client.setKids(KidsSettings(allowedGroupIds: ["g"]), profileID: "p")
        #expect(try await client.bindDevice(id: "d", toKidsProfile: "p").kidsProfileId == "p")
        _ = try await client.bindDevice(id: "d", toKidsProfile: nil)
        let bodies = try stub.recorded.map { try $0.json() }
        #expect(stub.recorded.map(\.method) == ["PATCH", "PATCH", "PATCH", "PATCH"])
        #expect(bodies[0]["kids"] is NSNull)
        #expect((bodies[1]["kids"] as? [String: Any])?["allowedGroupIds"] as? [String] == ["g"])
        #expect(bodies[2]["kidsProfileId"] as? String == "p")
        #expect(bodies[3]["kidsProfileId"] is NSNull)
    }

    // MARK: The rule

    private let groups = CategoryGroups(groups: [
        CategoryGroup(id: "main", name: nil, entries: [LibraryCategory(id: "c1", name: "One")]),
        CategoryGroup(id: "g2", name: "Two", entries: [LibraryCategory(id: "c2", name: "A"), LibraryCategory(id: "c3", name: "B")]),
    ])

    private func catalogue() -> Catalogue {
        func film(_ id: String, _ categories: [String]) -> Item {
            Item(id: id, kind: .movie, title: id, categoryIds: categories, addedAt: Make.epoch)
        }
        return Catalogue(items: [
            film("one", ["c1"]), film("two", ["c2"]), film("three", ["c3"]), film("loose", []),
            Item(id: "show", kind: .show, title: "Show", categoryIds: ["c2"], addedAt: Make.epoch),
            Item(id: "s1", kind: .season, parentId: "show", title: "S1", addedAt: Make.epoch),
            Item(id: "e1", kind: .episode, parentId: "s1", title: "E1", categoryIds: ["c2"], addedAt: Make.epoch),
            Item(id: "e2", kind: .episode, parentId: "s1", title: "E2", categoryIds: ["c2"], addedAt: Make.epoch),
        ])
    }

    private func left(_ kids: KidsSettings) -> Set<String> {
        Set(catalogue().limited(to: kids, groups: groups).itemsByID.keys)
    }

    @Test func nothingAllowedIsNothing() {
        #expect(left(KidsSettings()) == [])
    }

    @Test func aCategoryAndAGroupAllowTheirTitles() {
        #expect(left(KidsSettings(allowedCategoryIds: ["c3"])) == ["three"])
        #expect(left(KidsSettings(allowedGroupIds: ["g2"])) == ["two", "three", "show", "s1", "e1", "e2"])
    }

    @Test func aTitleInNoCategoryBelongsToTheMainPart() {
        #expect(left(KidsSettings(allowedGroupIds: ["main"])) == ["one", "loose"])
        #expect(left(KidsSettings(allowedCategoryIds: ["c1"])) == ["one"])
    }

    @Test func blockedWinsAndAShowCoversItsEpisodes() {
        #expect(left(KidsSettings(allowedGroupIds: ["g2"], allowedItemIds: ["show"], blockedItemIds: ["show", "two"])) == ["three"])
        #expect(left(KidsSettings(allowedItemIds: ["show"])) == ["show", "s1", "e1", "e2"])
        #expect(left(KidsSettings(allowedItemIds: ["show"], blockedItemIds: ["e2"])) == ["show", "s1", "e1"])
        // A series with nothing left to watch is not shown.
        #expect(left(KidsSettings(allowedItemIds: ["show"], blockedItemIds: ["s1"])) == [])
    }

    @Test func anEpisodeCountsByItsOwnCategory() {
        var items = catalogue().items
        for index in items.indices where items[index].id == "e2" { items[index].categoryIds = ["c1"] }
        for index in items.indices where items[index].id == "show" { items[index].categoryIds = ["c1", "c2"] }
        let left = Catalogue(items: items).limited(to: KidsSettings(allowedCategoryIds: ["c2"]), groups: groups)
        #expect(left.item("e1") != nil)
        #expect(left.item("e2") == nil)
    }

    @Test func anExtraDoesNotBringItsFilmAlong() {
        let extra = Item(id: "extra", kind: .extra, parentId: "one", title: "Extra", categoryIds: ["c2"], addedAt: Make.epoch)
        let whole = Catalogue(items: catalogue().items + [extra])
        let left = whole.limited(to: KidsSettings(allowedCategoryIds: ["c2"], allowedItemIds: ["extra"]), groups: groups)
        #expect(left.item("one") == nil)
        #expect(left.item("extra") == nil)
    }

    @Test func aFileThatAlsoHoldsSomethingBlockedIsLeftOut() {
        let file = MediaFile(
            assetId: "both", available: true, sizeBytes: 1, durationMs: nil, container: "mp4", revision: "r", playability: .direct, video: nil)
        var items = catalogue().items
        for index in items.indices where ["e1", "e2"].contains(items[index].id) { items[index].files = [file] }
        let left = Catalogue(items: items).limited(to: KidsSettings(allowedItemIds: ["show"], blockedItemIds: ["e2"]), groups: groups)
        #expect(left.item("e1")?.files.isEmpty == true)
    }

    @Test func anIdNobodyKnowsAllowsNothing() {
        #expect(left(KidsSettings(allowedGroupIds: ["gone"], allowedCategoryIds: ["gone"], allowedItemIds: ["gone"])) == [])
    }
}

@Suite struct BusyServerTests {
    @Test func aCallWaitsItsTurnAndGivesUpInTheEnd() async throws {
        let busy = LobbyError.rateLimited(message: "Busy.", retryAfter: 600)
        #expect(busy.pauseWhenBusy == .seconds(30))
        #expect(LobbyError.rateLimited(message: "", retryAfter: nil).pauseWhenBusy == .seconds(2))
        #expect(LobbyError.notFound(message: "").pauseWhenBusy == nil)

        var tries = 0
        let answer = try await LobbyError.waitingItsTurn(sleep: { _ in }) {
            tries += 1
            if tries < 4 { throw busy }
            return "here"
        }
        #expect(answer == "here")

        tries = 0
        await #expect(throws: busy) {
            try await LobbyError.waitingItsTurn(tries: 3, sleep: { _ in }) {
                tries += 1
                throw busy
            }
        }
        #expect(tries == 3)
    }
}
