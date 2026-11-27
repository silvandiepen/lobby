// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

/// Categories inside a category: a studio's page with its sections, the manager's
/// arranging, kids limits that cover what is inside, and categories that follow studios.
/// Every name here is made up.
@Suite struct SubcategoriesTests {
    /// "Lantern" holds "Early" and "Sequels"; "Harbour" stands by itself; all in Small.
    static let groups = CategoryGroups(groups: [
        CategoryGroup(id: "g0", name: nil, entries: [LibraryCategory(id: "films", name: "Films")]),
        CategoryGroup(id: "g-small", name: "Small", entries: [
            LibraryCategory(id: "lantern", name: "Lantern"),
            LibraryCategory(id: "early", parentId: "lantern", name: "Early"),
            LibraryCategory(id: "sequels", parentId: "lantern", name: "Sequels"),
            LibraryCategory(id: "harbour", name: "Harbour"),
            LibraryCategory(id: "kite", name: "Kite Works", rule: CategoryRule(studioIds: ["company:7"])),
        ]),
    ], revision: 4)

    static func film(_ id: String, _ categories: [String], ruled: [String]? = nil) -> Item {
        var item = Make.movie(id, title: "Title \(id)", categories: categories)
        item.categoryIds = categories
        item.ruleCategoryIds = ruled
        return item
    }

    static let catalogue = Catalogue(items: [
        film("own", ["lantern"]),
        film("first", ["early"]),
        film("second", ["early"]),
        film("again", ["sequels"]),
        film("boat", ["harbour"], ruled: ["kite"]),
        film("plain", ["films"], ruled: ["kite"]),
    ])

    static func shelves(_ groups: CategoryGroups = groups) -> LibraryShelves {
        LibraryShelves(catalogue: catalogue, groups: groups, progress: [:], context: Make.context)
    }

    // MARK: The library

    @Test func onlyTheParentIsAmongTheGroupsCategoriesAndItHoldsWhatIsInside() throws {
        let shelves = Self.shelves()
        let small = try #require(shelves.group(id: "g-small"))
        #expect(small.categories.map(\.name) == ["Lantern", "Harbour", "Kite Works"])
        let lantern = try #require(small.categories.first)
        #expect(Set(lantern.items.map(\.id)) == ["own", "first", "second", "again"])
        #expect(lantern.subcategories.map(\.name) == ["Early", "Sequels"])
        #expect(lantern.subcategories.map(\.parentID) == ["lantern", "lantern"])
        // A section is reached by its own id too, and from search.
        #expect(shelves.category(id: "folder:early")?.items.map(\.id) == ["first", "second"])
        #expect(shelves.categories(matching: "seq").map(\.name) == ["Sequels"])
    }

    @Test func aStudioRuleBringsTitlesToItsPageButNotIntoItsGroup() throws {
        let shelves = Self.shelves()
        let kite = try #require(shelves.category(id: "folder:kite"))
        #expect(Set(kite.items.map(\.id)) == ["boat", "plain"])
        // The film of the main part stays there: its own category decides.
        #expect(shelves.movies.map(\.id) == ["plain"])
        #expect(!(shelves.group(id: "g-small")?.items.map(\.id).contains("plain") ?? true))
    }

    @Test func anOlderServerWithoutParentsStaysFlat() throws {
        let flat = CategoryGroups(groups: Self.groups.groups.map { group in
            CategoryGroup(id: group.id, name: group.name, entries: group.entries.map {
                LibraryCategory(id: $0.id, name: $0.name)
            })
        })
        let shelves = Self.shelves(flat)
        let small = try #require(shelves.group(id: "g-small"))
        let names = small.categories.map(\.name)
        #expect(names == ["Lantern", "Early", "Sequels", "Harbour", "Kite Works"])
        #expect(small.categories.allSatisfy { $0.subcategories.isEmpty })
        #expect(small.categories.first?.items.map(\.id) == ["own"])
    }

    @Test func theParentsPageHasItsBannerSectionsARowEachAndTheGrid() throws {
        let catalogue = Self.catalogue
        let builder = BrowseBuilder(
            catalogue: catalogue, shelves: Self.shelves(), progress: [:], context: Make.context)
        let page = builder.page(.category("folder:lantern"))
        #expect(page.sections.map(\.name) == ["Early", "Sequels"])
        #expect(page.rows.map(\.id) == ["section.early", "section.sequels"])
        #expect(page.rows.first?.seeAll == .category("folder:early"))
        #expect(Set(page.all.map(\.id)) == ["own", "first", "second", "again"])

        let section = builder.page(.category("folder:lantern"), section: "folder:early")
        #expect(section.sections == page.sections)
        #expect(section.all.map(\.id) == ["first", "second"])
        #expect(section.banner == page.banner)
        // A category without sections is as before.
        #expect(builder.page(.category("folder:harbour")).sections.isEmpty)
    }

    // MARK: Kids limits

    @Test func allowingTheParentAllowsWhatIsInsideAndABlockWins() {
        let catalogue = Self.catalogue
        func allowed(_ kids: KidsSettings) -> Set<String> {
            Set(catalogue.limited(to: kids, groups: Self.groups).items.map(\.id))
        }
        #expect(allowed(KidsSettings(allowedCategoryIds: ["lantern"])) == ["own", "first", "second", "again"])
        #expect(allowed(KidsSettings(allowedCategoryIds: ["early"])) == ["first", "second"])
        #expect(allowed(KidsSettings(allowedCategoryIds: ["lantern"], blockedCategoryIds: ["sequels"])) == ["own", "first", "second"])
        // Blocked wins also over a single allowed title.
        #expect(allowed(KidsSettings(allowedItemIds: ["again"], blockedCategoryIds: ["lantern"])).isEmpty)
    }

    @Test func aStudioRuleAllowsOnlyByItsCategoryNeverByTheGroup() {
        let catalogue = Self.catalogue
        func allowed(_ kids: KidsSettings) -> Set<String> {
            Set(catalogue.limited(to: kids, groups: Self.groups).items.map(\.id))
        }
        // The group allows what was put in it by hand: not the main part's film its studio made.
        #expect(!allowed(KidsSettings(allowedGroupIds: ["g-small"])).contains("plain"))
        #expect(allowed(KidsSettings(allowedCategoryIds: ["kite"])) == ["boat", "plain"])
        #expect(allowed(KidsSettings(allowedGroupIds: ["g0"], blockedCategoryIds: ["kite"])).isEmpty)
    }

    @Test func blockedCategoriesAreSentOnlyToAServerThatKnowsThem() throws {
        func sent(_ kids: KidsSettings) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(kids)) as? [String: Any])
        }
        #expect(try sent(KidsSettings()).keys.contains("blockedCategoryIds") == false)
        #expect(try sent(KidsSettings(blockedCategoryIds: ["x"]))["blockedCategoryIds"] as? [String] == ["x"])
        let read = try JSONDecoder().decode(KidsSettings.self, from: Data(#"{"allowedGroupIds":[],"blockedCategoryIds":[]}"#.utf8))
        // Known, so an empty list goes back: that unblocks.
        #expect(try sent(read)["blockedCategoryIds"] as? [String] == [])
    }

    // MARK: Arranging

    @Test func theTreeListsEachParentFollowedByWhatIsInside() throws {
        let tree = CategoryTree(try #require(Self.groups.group(id: "g-small")))
        #expect(tree.rows.map(\.id) == ["lantern", "early", "sequels", "harbour", "kite"])
        #expect(tree.rows.map(\.isInside) == [false, true, true, false, false])
        #expect(tree.parents(for: "harbour").map(\.id) == ["lantern", "kite"])
        #expect(tree.parents(for: "lantern").isEmpty)
    }

    @Test func draggingPutsInsideTakesOutAndReorders() throws {
        let tree = CategoryTree(try #require(Self.groups.group(id: "g-small")))
        // Harbour between Early and Sequels: inside Lantern.
        let inside = try #require(tree.moving(from: [3], to: 2))
        #expect(inside.categories == [.init(id: "harbour", parentID: .some("lantern"))])
        #expect(inside.order == [.init(groupID: "g-small", parentID: "lantern", ids: ["early", "harbour", "sequels"])])
        // Sequels to the top: out of Lantern, first.
        let out = try #require(tree.moving(from: [2], to: 0))
        #expect(out.categories == [.init(id: "sequels", parentID: .some(nil))])
        #expect(out.order.first?.ids == ["sequels", "lantern", "harbour", "kite"])
        // Sequels before Early: the same parent, another order.
        let order = try #require(tree.moving(from: [2], to: 1))
        #expect(order.categories.isEmpty)
        #expect(order.order.first?.ids == ["sequels", "early"])
        // Put back where it was: nothing to send.
        #expect(tree.moving(from: [1], to: 1) == nil)
        // A parent stays top-level wherever it lands.
        let parent = try #require(tree.moving(from: [0], to: 4))
        #expect(parent.categories.isEmpty)
        #expect(parent.order.first?.ids == ["harbour", "lantern", "kite"])
    }

    @Test func takingOutPutsItRightAfterItsParent() throws {
        let tree = CategoryTree(try #require(Self.groups.group(id: "g-small")))
        let out = try #require(tree.takingOut("early"))
        #expect(out.categories == [.init(id: "early", parentID: .some(nil))])
        #expect(out.order.first?.ids == ["lantern", "early", "harbour", "kite"])
        #expect(tree.takingOut("harbour") == nil)
    }

    @Test func aNewParentTakesTheOldNameAndTheLogoOfOneInside() throws {
        let group = CategoryGroup(id: "g-small", name: "Small", entries: [
            LibraryCategory(id: "c-lantern", name: "Lantern", color: "blue", logo: CategoryLogo(id: "logo-1", width: 10, height: 5)),
            LibraryCategory(id: "c-lantern-2", name: "Lantern II"),
            LibraryCategory(id: "c-meadow", name: "Meadow"),
            LibraryCategory(id: "c-lantern-live", name: "Lantern Live"),
        ])
        let made = try #require(CategoryTree(group).makingParent(
            named: "Lantern", of: ["c-lantern", "c-lantern-2", "c-lantern-live"],
            renaming: ["c-lantern": "Classics", "c-lantern-2": " Sequels ", "c-lantern-live": ""], logoFrom: "c-lantern"))
        #expect(made.create == [.init(key: "parent", groupID: "g-small", name: "Lantern", icon: .some(nil), color: .some("blue"), logoFrom: "c-lantern")])
        #expect(made.categories == [
            .init(id: "c-lantern", name: "Classics", parentID: .some("new:parent")),
            .init(id: "c-lantern-2", name: "Sequels", parentID: .some("new:parent")),
            .init(id: "c-lantern-live", parentID: .some("new:parent")),
        ])
        #expect(made.order == [
            .init(groupID: "g-small", parentID: nil, ids: ["new:parent", "c-meadow"]),
            .init(groupID: "g-small", parentID: "new:parent", ids: ["c-lantern", "c-lantern-2", "c-lantern-live"]),
        ])
    }
}

/// The manager's Categories screen against the stub household: arranging, its undo, the
/// question about kids viewers, and studio suggestions.
@MainActor
@Suite struct ArrangingCategoriesTests {
    let test: TestApp

    init() throws {
        var state = Household.State(device: Device(id: "dev-1", name: "Mac", platform: .macos, role: .manager, createdAt: Make.epoch))
        state.categoryGroups = CategoryGroups(groups: [
            CategoryGroup(id: "g0", name: nil, entries: []),
            CategoryGroup(id: "g1", name: "Small", entries: [
                LibraryCategory(id: "a", name: "Lantern", logo: CategoryLogo(id: "logo-a", width: 10, height: 5)),
                LibraryCategory(id: "b", name: "Lantern II"),
                LibraryCategory(id: "c", name: "Meadow"),
            ]),
        ], revision: 3)
        test = try TestApp(Household(state))
    }

    private func open() async throws -> (AppModel, CategoriesModel) {
        let app = try await test.launchPaired(as: "alex")
        let model = CategoriesModel(app: app)
        await model.load()
        return (app, model)
    }

    private var entries: [LibraryCategory] { test.household.current.categoryGroups!.groups[1].entries }

    @Test func aParentIsMadeOfTwoAndTheUndoTakesItBack() async throws {
        let (_, model) = try await open()
        #expect(!model.canUndo)
        let tree = model.tree(of: model.groups[1])
        let made = try #require(tree.makingParent(named: "Lantern", of: ["a", "b"], renaming: ["a": "Classics"], logoFrom: "a"))
        #expect(await model.arrange(made))
        #expect(entries.map(\.name) == ["Lantern", "Classics", "Lantern II", "Meadow"])
        #expect(entries.map(\.parentId) == [nil, "made-parent", "made-parent", nil])
        #expect(entries.first?.logo?.id == "logo-a")
        #expect(model.canUndo)

        await model.undo()
        #expect(entries.map(\.name) == ["Lantern", "Lantern II", "Meadow"])
        #expect(entries.allSatisfy { $0.parentId == nil })
        #expect(!model.canUndo)
    }

    @Test func aChangeThatShowsAChildMoreWaitsForTheManager() async throws {
        let (_, model) = try await open()
        test.household.change {
            $0.kidsQuestion = [KidsChange(
                profileId: "kids", name: "Kids",
                appearing: .init(count: 2, titles: [.init(id: "t1", title: "Tide"), .init(id: "t2", title: "Twig")]),
                disappearing: .init(count: 0, titles: []))]
        }
        await model.putCategory("c", inside: "a")
        let question = try #require(model.question)
        #expect(question.appearing.map(\.name) == ["Kids"])
        #expect(question.changes.first?.appearing.titles.map(\.title) == ["Tide", "Twig"])
        // Nothing changed yet.
        #expect(entries.allSatisfy { $0.parentId == nil })
        #expect(model.problem == nil)

        await model.allow(question)
        #expect(model.question?.id == nil)
        #expect(entries.first { $0.id == "c" }?.parentId == "a")
    }

    @Test func cancellingTheQuestionSendsNothing() async throws {
        let (_, model) = try await open()
        test.household.change {
            $0.kidsQuestion = [KidsChange(
                profileId: "kids", name: "Kids", appearing: .init(count: 1, titles: [.init(id: "t1", title: "Tide")]),
                disappearing: .init(count: 0, titles: []))]
        }
        let before = test.household.current.categoryGroups?.revision
        await model.putCategory("c", inside: "a")
        #expect(model.question?.id != nil)
        model.question = nil
        #expect(test.household.current.categoryGroups?.revision == before)
    }

    @Test func aSuggestedStudioBecomesACategoryOrIsDismissed() async throws {
        test.household.change {
            $0.suggestions = #"""
            {"min":8,"suggestions":[{"id":"s7","name":"Kite Works","studios":[{"id":"company:7","name":"Kite Works","logoPath":null,"titles":12}],
             "count":12,"titles":[{"id":"t1","title":"Tide"}],"logoPath":null,"categoryId":null},
             {"id":"s9","name":"Pebble","studios":[{"id":"company:9","name":"Pebble Pictures","logoPath":"/p.png","titles":9}],
             "count":9,"titles":[],"logoPath":"/p.png","categoryId":null}]}
            """#
        }
        let (_, model) = try await open()
        #expect(model.suggestions.map(\.name) == ["Kite Works", "Pebble"])
        #expect(model.suggestions[1].logoPreviewPath == "/v1/categories/logo-search/preview?path=%2Fp.png")

        #expect(await model.place(["s7"], .newCategory(groupID: "g1", together: false, name: nil)))
        let made = try #require(entries.last)
        #expect(made.rule == CategoryRule(studioIds: ["company:7"]))
        #expect(model.follows(made) == "Follows Kite Works")

        test.household.change { $0.suggestions = #"{"min":8,"suggestions":[{"id":"s9","name":"Pebble","studios":[],"count":9,"titles":[],"logoPath":null,"categoryId":null}]}"# }
        await model.loadSuggestions()
        await model.dismiss(model.suggestions[0])
        #expect(test.household.current.dismissed == ["s9"])
        #expect(model.suggestions.isEmpty)
    }
}
