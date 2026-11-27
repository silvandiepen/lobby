// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

/// Categories that stay tidy: where a drop lands and what it asks the server for, a sidebar
/// that folds long groups, and studio suggestions that go where the manager says. Every name
/// here is made up.
@Suite struct CategoryDropTests {
    /// Main: Films. Small: Lantern (Early, Sequels), Harbour, Meadow. Big: Tower.
    static let setup = CategoryGroups(groups: [
        CategoryGroup(id: "g0", name: nil, entries: [LibraryCategory(id: "films", name: "Films")]),
        CategoryGroup(id: "g-small", name: "Small", entries: [
            LibraryCategory(id: "lantern", name: "Lantern"),
            LibraryCategory(id: "early", parentId: "lantern", name: "Early"),
            LibraryCategory(id: "sequels", parentId: "lantern", name: "Sequels"),
            LibraryCategory(id: "harbour", name: "Harbour"),
            LibraryCategory(id: "meadow", name: "Meadow"),
        ]),
        CategoryGroup(id: "g-big", name: "Big", entries: [LibraryCategory(id: "tower", name: "Tower")]),
    ], revision: 2)

    let drop = CategoryDrop(setup: setup)

    private func arrangement(_ ids: [String], _ target: CategoryDropTarget) throws -> CategoryArrangement? {
        try drop.arrangement(moving: ids, to: target).get()
    }

    @Test func aDropBeforeOrAfterReordersAmongTheSameLevel() throws {
        let moved = try #require(try arrangement(["meadow"], .before("lantern")))
        #expect(moved.categories.isEmpty)
        #expect(moved.order == [.init(groupID: "g-small", parentID: nil, ids: ["meadow", "lantern", "harbour"])])
        let inside = try #require(try arrangement(["early"], .after("sequels")))
        #expect(inside.order == [.init(groupID: "g-small", parentID: "lantern", ids: ["sequels", "early"])])
        // Where it is already: nothing to send.
        #expect(try arrangement(["harbour"], .after("lantern")) == nil)
        #expect(try arrangement(["harbour"], .before("harbour")) == nil)
    }

    @Test func aDropOntoACategoryPutsItInsideLast() throws {
        let nested = try #require(try arrangement(["harbour"], .onto("lantern")))
        #expect(nested.categories == [.init(id: "harbour", parentID: .some("lantern"))])
        #expect(nested.order == [.init(groupID: "g-small", parentID: "lantern", ids: ["early", "sequels", "harbour"])])
    }

    @Test func aDropAmongTheTopLevelTakesItOut() throws {
        let out = try #require(try arrangement(["early"], .after("harbour")))
        #expect(out.categories == [.init(id: "early", parentID: .some(nil))])
        #expect(out.order == [.init(groupID: "g-small", parentID: nil, ids: ["lantern", "harbour", "early", "meadow"])])
    }

    @Test func betweenGroupsTheGroupIsSaidAtTheTopAndFollowsTheParentInside() throws {
        let across = try #require(try arrangement(["harbour"], .before("tower")))
        #expect(across.categories == [.init(id: "harbour", groupID: "g-big", parentID: .some(nil))])
        #expect(across.order == [.init(groupID: "g-big", parentID: nil, ids: ["harbour", "tower"])])
        let intoOther = try #require(try arrangement(["films"], .onto("tower")))
        #expect(intoOther.categories == [.init(id: "films", parentID: .some("tower"))])
        let atEnd = try #require(try arrangement(["tower"], .endOf(group: "g0")))
        #expect(atEnd.categories == [.init(id: "tower", groupID: "g0", parentID: .some(nil))])
        #expect(atEnd.order == [.init(groupID: "g0", parentID: nil, ids: ["films", "tower"])])
    }

    @Test func severalGoTogetherInTheHouseholdsOrderAndOneInsideGoesWithItsParent() throws {
        let both = try #require(try arrangement(["meadow", "harbour"], .before("lantern")))
        #expect(both.order.first?.ids == ["harbour", "meadow", "lantern"])
        // Early is carried by Lantern, not moved by itself.
        let carried = try #require(try arrangement(["early", "lantern"], .after("meadow")))
        #expect(carried.categories.isEmpty)
        #expect(carried.order.first?.ids == ["harbour", "meadow", "lantern"])
        let across = try #require(try arrangement(["harbour", "meadow"], .onto("tower")))
        #expect(across.categories.map(\.id) == ["harbour", "meadow"])
        #expect(across.order.first?.ids == ["harbour", "meadow"])
    }

    @Test func whatTheServerWouldRefuseIsRefusedWhileDragging() {
        // Two levels: inside one that is inside another.
        #expect(drop.refusal(moving: ["harbour"], to: .onto("early")) == .twoLevels)
        // A category with others inside it stays at the top.
        #expect(drop.refusal(moving: ["lantern"], to: .onto("harbour")) == .holdsOthers)
        #expect(drop.refusal(moving: ["lantern"], to: .before("early")) == .intoOwnChild)
        #expect(drop.refusal(moving: ["lantern", "harbour"], to: .after("early")) == .intoOwnChild)
        let withChild = CategoryDrop(setup: CategoryGroups(groups: [CategoryGroup(id: "g", name: nil, entries: [
            LibraryCategory(id: "p", name: "P"), LibraryCategory(id: "q", parentId: "p", name: "Q"),
            LibraryCategory(id: "r", name: "R"), LibraryCategory(id: "s", parentId: "r", name: "S"),
        ])]))
        #expect(withChild.refusal(moving: ["p"], to: .before("s")) == .holdsOthers)
        #expect(drop.refusal(moving: ["harbour"], to: .onto("harbour")) == .ontoItself)
        #expect(drop.refusal(moving: ["harbour", "meadow"], to: .onto("meadow")) == .ontoItself)
        // What may be done has no refusal.
        #expect(drop.refusal(moving: ["harbour"], to: .onto("lantern")) == nil)
        #expect(drop.refusal(moving: ["lantern"], to: .before("tower")) == nil)
        #expect(CategoryDropRefusal.twoLevels.message.contains("one level"))
    }

    @Test func theMiddleOfARowIsInsideAndItsEdgesAreBeforeAndAfter() {
        #expect(DropZone.target(for: "a", y: 2, height: 40, canHold: true) == .before("a"))
        #expect(DropZone.target(for: "a", y: 20, height: 40, canHold: true) == .onto("a"))
        #expect(DropZone.target(for: "a", y: 38, height: 40, canHold: true) == .after("a"))
        // One inside another holds none: halves.
        #expect(DropZone.target(for: "a", y: 19, height: 40, canHold: false) == .before("a"))
        #expect(DropZone.target(for: "a", y: 21, height: 40, canHold: false) == .after("a"))
    }
}

@Suite struct SidebarFoldTests {
    @Test func aLongGroupShowsItsFirstAndMoreAndAFoldedOneNothing() {
        var fold = SidebarFold()
        let eleven = Array(1...11)
        #expect(fold.visible(eleven, ofGroup: "kids").rows == [1, 2, 3, 4, 5, 6])
        #expect(fold.visible(eleven, ofGroup: "kids").hidden == 5)
        // One more than shown is shown, not hidden behind "More… (1)".
        #expect(fold.visible(Array(1...7), ofGroup: "kids").hidden == 0)
        fold.toggleAll("kids")
        #expect(fold.visible(eleven, ofGroup: "kids").rows == eleven)
        #expect(fold.canShowLess(11, ofGroup: "kids"))
        fold.toggleFolded("kids")
        #expect(fold.visible(eleven, ofGroup: "kids").rows.isEmpty)
        #expect(!fold.canShowLess(11, ofGroup: "kids"))
        fold.toggleFolded("kids")
        #expect(fold.visible(eleven, ofGroup: "kids").rows == eleven)
        #expect(fold.visible(eleven, ofGroup: "other").hidden == 5)
    }

    @Test func whatWasFoldedIsRememberedOnTheDevice() {
        let settings = LocalSettings(suiteName: "lobby.tests.fold.\(UUID().uuidString)")
        defer { settings.removeAll() }
        #expect(settings.sidebarFoldedGroups.isEmpty)
        settings.sidebarFoldedGroups = ["kids"]
        settings.sidebarShowsAllOfGroups = ["main", "big"]
        #expect(settings.sidebarFoldedGroups == ["kids"])
        #expect(settings.sidebarShowsAllOfGroups == ["big", "main"])
    }
}

@Suite struct SuggestionChoiceTests {
    static func suggestion(_ id: String, _ name: String, same: String? = nil) throws -> CategorySuggestions.Suggestion {
        let json = #"{"id":"\#(id)","name":"\#(name)","studios":[],"count":9,"titles":[],"logoPath":null,"categoryId":\#(same.map { "\"\($0)\"" } ?? "null")}"#
        return try JSONDecoder().decode(CategorySuggestions.Suggestion.self, from: Data(json.utf8))
    }

    @Test func nothingIsChosenForTheManagerUnlessACategoryHasItsName() throws {
        let one = SuggestionChoice([try Self.suggestion("s1", "Kite")])
        #expect(one.destination == nil)
        #expect(one.placement == nil)
        let same = SuggestionChoice([try Self.suggestion("s1", "Kite", same: "kite")])
        #expect(same.placement == .join(categoryID: "kite"))
    }

    @Test func severalGoInsideOneEachOrTogetherWithAName() throws {
        var choice = SuggestionChoice([try Self.suggestion("s1", "Kite"), try Self.suggestion("s2", "Pebble")])
        choice.destination = .inside(categoryID: "lantern")
        #expect(!choice.makesOne)
        choice.name = "Ignored"
        #expect(choice.placement == .inside(parentID: "lantern", together: false, name: nil))
        choice.together = true
        #expect(choice.makesOne)
        choice.name = "  Studios "
        #expect(choice.placement == .inside(parentID: "lantern", together: true, name: "Studios"))
        choice.destination = .newCategory(groupID: "g-small")
        #expect(choice.placement == .newCategory(groupID: "g-small", together: true, name: "Studios"))
        choice.destination = .join(categoryID: "harbour")
        #expect(choice.placement == .join(categoryID: "harbour"))
        choice.destination = .newCategory(groupID: "g-small")
        choice.name = String(repeating: "x", count: 61)
        #expect(choice.placement == nil)
    }

    @Test func itSaysWhatWillHappen() throws {
        var choice = SuggestionChoice([try Self.suggestion("s1", "Kite"), try Self.suggestion("s2", "Pebble")])
        choice.destination = .inside(categoryID: "lantern")
        #expect(choice.summary(in: CategoryDropTests.setup) == "A category for each, inside Lantern.")
        choice.destination = .join(categoryID: "harbour")
        #expect(choice.summary(in: CategoryDropTests.setup)?.hasPrefix("Harbour shows their titles") == true)
        #expect(SuggestionChoice.parents(in: CategoryDropTests.setup).map(\.categories.count) == [1, 3, 1])
    }
}

/// Dragging and merging against the stub household: a dry run first, the question about kids
/// viewers when they would see more, and nothing sent without Allow.
@MainActor
@Suite struct ArrangingByDraggingTests {
    let test: TestApp

    init() throws {
        var state = Household.State(device: Device(id: "dev-1", name: "Mac", platform: .macos, role: .manager, createdAt: Make.epoch))
        state.categoryGroups = CategoryGroups(groups: [
            CategoryGroup(id: "g0", name: nil, entries: [LibraryCategory(id: "films", name: "Films")]),
            CategoryGroup(id: "g1", name: "Small", entries: [
                LibraryCategory(id: "a", name: "Lantern"),
                LibraryCategory(id: "b", name: "Harbour", rule: CategoryRule(studioIds: ["company:2"])),
                LibraryCategory(id: "c", name: "Meadow", rule: CategoryRule(studioIds: ["company:3"])),
            ]),
        ], revision: 3)
        state.folders = ["Meadow": "c"]
        test = try TestApp(Household(state))
    }

    private func open() async throws -> CategoriesModel {
        let app = try await test.launchPaired(as: "alex")
        let model = CategoriesModel(app: app)
        await model.load()
        return model
    }

    private var groups: [CategoryGroup] { test.household.current.categoryGroups!.groups }
    private func sent(_ path: String) -> [[String: Any]] {
        test.household.stub.recorded.filter { $0.method == "POST" && $0.path == path }.map { $0.json() }
    }

    private func askKids() {
        test.household.change {
            $0.kidsQuestion = [KidsChange(
                profileId: "kids", name: "Kids", appearing: .init(count: 1, titles: [.init(id: "t1", title: "Tide")]),
                disappearing: .init(count: 0, titles: []))]
        }
    }

    @Test func aDropIsTriedFirstAndThenSentWithTheDryRunsToken() async throws {
        let model = try await open()
        model.dragging = ["c"]
        #expect(model.refusal(dropping: ["c"], on: .onto("a")) == nil)
        #expect(await model.drop(["c"], on: .onto("a")))
        #expect(model.dragging == nil)
        #expect(groups[1].entries.map(\.id) == ["a", "c", "b"])
        #expect(groups[1].entries.first { $0.id == "c" }?.parentId == "a")
        let bodies = sent("/v1/categories/arrange")
        #expect(bodies.count == 2)
        #expect(bodies[0]["dryRun"] as? Bool == true)
        #expect(bodies[0]["kidsToken"] == nil)
        #expect(bodies[1]["dryRun"] == nil)
        #expect(bodies[1]["kidsToken"] as? String == "nothing-token")
        #expect(bodies[1]["revision"] as? Int == 3)
        let change = try #require((bodies[1]["categories"] as? [[String: Any]])?.first)
        #expect(change["id"] as? String == "c")
        #expect(change["parentId"] as? String == "a")
        #expect((bodies[1]["order"] as? [[String: Any]])?.first?["ids"] as? [String] == ["c"])
        // Undo takes it back.
        #expect(model.canUndo)
        await model.undo()
        #expect(groups[1].entries.allSatisfy { $0.parentId == nil })
    }

    @Test func whenKidsWouldSeeMoreNothingIsSentUntilAllow() async throws {
        let model = try await open()
        askKids()
        #expect(!(await model.drop(["b"], on: .before("a"))))
        let question = try #require(model.question)
        #expect(question.token == "kids-token")
        #expect(question.appearing.map(\.name) == ["Kids"])
        // Only the dry run went out.
        #expect(sent("/v1/categories/arrange").count == 1)
        #expect(groups[1].entries.map(\.id) == ["a", "b", "c"])

        await model.allow(question)
        #expect(groups[1].entries.map(\.id) == ["b", "a", "c"])
        #expect(sent("/v1/categories/arrange").last?["kidsToken"] as? String == "kids-token")
    }

    @Test func aDropThatCannotBeIsNeverSent() async throws {
        let model = try await open()
        _ = await model.drop(["c"], on: .onto("a"))
        let before = test.household.stub.recorded.count
        #expect(model.refusal(dropping: ["a"], on: .onto("b")) == .holdsOthers)
        #expect(model.refusal(dropping: ["b"], on: .onto("c")) == .twoLevels)
        #expect(!(await model.drop(["a"], on: .onto("b"))))
        #expect(test.household.stub.recorded.count == before)
    }

    @Test func aCategoryIsDraggedToAnotherGroup() async throws {
        let model = try await open()
        #expect(await model.drop(["b"], on: .after("films")))
        #expect(groups[0].entries.map(\.id) == ["films", "b"])
        #expect(groups[1].entries.map(\.id) == ["a", "c"])
        let change = try #require((sent("/v1/categories/arrange").last?["categories"] as? [[String: Any]])?.first)
        #expect(change["groupId"] as? String == "g0")
    }

    @Test func severalChosenAreDraggedAndMergedTogether() async throws {
        let model = try await open()
        model.selection = ["c", "b"]
        #expect(model.dragged(startingAt: "c") == ["b", "c"])
        #expect(model.dragged(startingAt: "a") == ["a"])
        #expect(model.mergeTargets(of: ["b", "c"]).map(\.id) == ["b", "c"])
        #expect(model.mergeTargets(of: ["b"]).isEmpty)

        #expect(await model.merge(["b", "c"], into: "b"))
        #expect(groups[1].entries.map(\.id) == ["a", "b"])
        #expect(groups[1].entries.last?.rule == CategoryRule(studioIds: ["company:2", "company:3"]))
        #expect(test.household.current.folders["Meadow"] == .some("b"))
        #expect(model.selection.isEmpty)
        let bodies = sent("/v1/categories/merge")
        #expect(bodies.map { $0["dryRun"] as? Bool } == [true, nil])
        #expect(bodies.last?["into"] as? String == "b")
        #expect(bodies.last?["ids"] as? [String] == ["c"])
    }

    @Test func aMergeThatShowsAChildMoreWaitsForTheManager() async throws {
        let model = try await open()
        askKids()
        #expect(!(await model.merge(["a", "c"], into: "a")))
        #expect(model.question != nil)
        #expect(groups[1].entries.count == 3)
        model.question = nil
        #expect(sent("/v1/categories/merge").count == 1)
    }

    @Test func suggestionsGoWhereTheManagerSays() async throws {
        test.household.change {
            $0.suggestions = #"""
            {"min":8,"suggestions":[{"id":"s7","name":"Kite","studios":[],"count":12,"titles":[],"logoPath":null,"categoryId":null},
             {"id":"s9","name":"Pebble","studios":[],"count":9,"titles":[],"logoPath":null,"categoryId":null}]}
            """#
        }
        let model = try await open()
        #expect(await model.place(["s7", "s9"], .inside(parentID: "a", together: false, name: nil)))
        #expect(groups[1].entries.map(\.id) == ["a", "studio-s7", "studio-s9", "b", "c"])
        #expect(groups[1].entries.filter { $0.parentId == "a" }.count == 2)
        // Never at the top of a group by itself.
        #expect(groups[1].entries.filter { $0.parentId == nil }.map(\.id) == ["a", "b", "c"])
        let bodies = sent("/v1/categories/suggestions/accept")
        #expect(bodies.first?["dryRun"] as? Bool == true)
        #expect(bodies.last?["ids"] as? [String] == ["s7", "s9"])
        #expect(bodies.last?["parentId"] as? String == "a")
        #expect(bodies.last?["together"] as? Bool == false)
        #expect(model.suggestions.isEmpty)
    }

    @Test func suggestionsJoinTheRuleOfACategoryThereIs() async throws {
        test.household.change {
            $0.suggestions = #"{"min":8,"suggestions":[{"id":"s7","name":"Kite","studios":[],"count":12,"titles":[],"logoPath":null,"categoryId":null}]}"#
        }
        let model = try await open()
        #expect(await model.place(["s7"], .join(categoryID: "b")))
        #expect(groups[1].entries.first { $0.id == "b" }?.rule == CategoryRule(studioIds: ["company:2", "company:7"]))
        #expect(groups[1].entries.count == 3)
    }
}
