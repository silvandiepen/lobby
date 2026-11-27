// SPDX-License-Identifier: MPL-2.0
import CoreGraphics
import Foundation
import ImageIO
import LobbyKit
import Testing

@testable import Lobby

@MainActor
@Suite struct CategoriesModelTests {
    let test: TestApp

    init() throws {
        var state = Household.State(device: Device(id: "dev-1", name: "Mac", platform: .macos, role: .manager, createdAt: Make.epoch))
        state.categoryGroups = CategoryGroups(groups: [
            CategoryGroup(id: "g0", name: nil, entries: [LibraryCategory(id: "a", name: "Aardvark")]),
            CategoryGroup(id: "g1", name: "Upstairs", entries: [
                LibraryCategory(id: "b", name: "Badger"), LibraryCategory(id: "c", name: "Crow"), LibraryCategory(id: "d", name: "Dormouse"),
            ]),
        ], revision: 3)
        state.folders = ["Films": "b", "Loose": nil]
        var film = Make.movie("film", categories: ["Badger"])
        film.categoryIds = ["b"]
        state.items = [film]
        test = try TestApp(Household(state))
    }

    private func open() async throws -> (AppModel, CategoriesModel) {
        let app = try await test.launchPaired(as: "alex")
        let model = CategoriesModel(app: app)
        await model.load()
        return (app, model)
    }

    private var names: [[String]] { test.household.current.categoryGroups!.groups.map(\.categories) }

    @Test func aCategoryIsMadeWithItsLookAndItsLogo() async throws {
        let (app, model) = try await open()
        var draft = CategoryDraft(newCategoryIn: model.groups[1])
        #expect(!draft.canSave)
        draft.name = "  Eagle "
        draft.icon = "bird.fill"
        draft.color = "teal"
        draft.logo = .found(try JSONDecoder().decode(LogoSearchResult.self, from: Data(#"{"path":"/e.png","name":"E","country":null,"previewUrl":"/v1/x"}"#.utf8)))
        #expect(await model.save(draft))
        let made = try #require(model.groups[1].entries.last)
        #expect(made.name == "Eagle")
        #expect(made.icon == "bird.fill")
        #expect(made.color == "teal")
        #expect(made.logo?.id == "/e.png")
        // The library follows at once.
        #expect(app.look(ofCategory: made.id).symbol == "bird.fill")
    }

    @Test func aRenamedAndMovedCategoryKeepsItsTitles() async throws {
        let (app, model) = try await open()
        #expect(app.shelves.groups.map(\.name) == ["Upstairs"])
        var draft = CategoryDraft(model.groups[1].entries[0], in: model.groups[1])
        draft.name = "Otter"
        draft.groupID = "g0"
        #expect(await model.save(draft))
        #expect(names == [["Aardvark", "Otter"], ["Crow", "Dormouse"]])
        // The film's own copy still says the old name: it is found by the id.
        #expect(app.shelves.movies.map(\.id) == ["film"])
        #expect(app.shelves.groups.isEmpty)
    }

    @Test func categoriesAreReorderedByDraggingAndOneStepAtATime() async throws {
        let (_, model) = try await open()
        await model.moveCategories(in: model.groups[1], from: IndexSet(integer: 0), to: 3)
        #expect(names[1] == ["Crow", "Dormouse", "Badger"])
        await model.moveCategory("b", by: -1)
        #expect(names[1] == ["Crow", "Badger", "Dormouse"])
        #expect(!model.canMoveCategory("c", by: -1))
        #expect(!model.canMoveCategory("d", by: 1))
        #expect(CategoriesModel.moved(["1", "2", "3", "4"], from: IndexSet([0, 3]), to: 2) == ["2", "1", "4", "3"])
        #expect(CategoriesModel.moved(["1", "2", "3"], from: IndexSet(integer: 2), to: 0) == ["3", "1", "2"])
    }

    @Test func deletingACategoryThatFoldersFeedSaysWhereTheyGo() async throws {
        let (_, model) = try await open()
        #expect(model.folders(of: "b").map(\.name) == ["Films"])
        #expect(await model.deleteCategory("b", foldersTo: .category("c")))
        #expect(test.household.current.folders["Films"] == .some("c"))
        #expect(names[1] == ["Crow", "Dormouse"])
        #expect(await model.deleteCategory("c", foldersTo: FoldersTarget.none))
        #expect(test.household.current.folders["Films"] == .some(nil))
        #expect(await model.deleteCategory("d", foldersTo: nil))
        #expect(names[1].isEmpty)
    }

    @Test func aFolderFeedsTheCategoryThatIsChosen() async throws {
        let (_, model) = try await open()
        await model.assign(folder: "Loose", to: "d")
        #expect(model.folders(of: "d").map(\.name) == ["Loose"])
        await model.assign(folder: "Loose", to: nil)
        #expect(model.folders.first { $0.name == "Loose" }?.categoryId == nil)
    }

    @Test func whenAnotherManagerWasFirstTheirsStaysAndIsShown() async throws {
        let (_, model) = try await open()
        // On another device, meanwhile.
        test.household.change {
            $0.categoryGroups?.revision = 4
            $0.categoryGroups?.groups[1].entries[0].name = "Theirs"
        }
        var draft = CategoryDraft(model.groups[1].entries[0], in: model.groups[1])
        draft.name = "Mine"
        #expect(!(await model.save(draft)))
        #expect(names[1].first == "Theirs")
        #expect(model.groups[1].entries[0].name == "Theirs")
        #expect(model.problem?.hasPrefix("Someone else changed") == true)
        // Saving again, after reading that, goes through.
        #expect(await model.save(draft))
        #expect(names[1].first == "Mine")
    }

    @Test func aRefusalIsShownInTheServersWords() async throws {
        let (_, model) = try await open()
        var draft = CategoryDraft(newCategoryIn: model.groups[0])
        draft.name = "crow"
        #expect(!(await model.save(draft)))
        #expect(model.problem == "There is a category with that name.")
    }

    @Test func aViewerDeviceChangesNothing() async throws {
        test.household.change { $0.device.role = .viewer }
        let (_, model) = try await open()
        #expect(model.edit == nil)
        #expect(!(await model.deleteCategory("d", foldersTo: nil)))
        #expect(!test.household.stub.recorded.contains { $0.path.hasPrefix("/v1/categories/") })
    }

    @Test func theMainPartHasNoNameToChange() {
        let draft = CategoryDraft(CategoryGroup(id: "g0", name: nil, entries: []))
        #expect(!draft.hasName)
        #expect(draft.canSave)
    }

    @Test func aChosenPictureIsSentSmallUprightAndInTheRightKind() throws {
        let photo = try Make.jpeg(width: 3000, height: 1500)
        let jpeg = try #require(PictureEncoder.jpeg(from: photo))
        #expect(jpeg.starts(with: [0xFF, 0xD8]))
        #expect(PictureEncoder.image(from: jpeg, maxPixels: 5000)?.width == 2400)
        let png = try #require(PictureEncoder.png(from: photo))
        #expect(png.starts(with: [0x89, 0x50]))
        // A small one is not made larger.
        let small = try #require(PictureEncoder.jpeg(from: try Make.jpeg(width: 200, height: 100)))
        #expect(PictureEncoder.image(from: small, maxPixels: 5000)?.width == 200)
        #expect(PictureEncoder.jpeg(from: Data("not a picture".utf8)) == nil)
    }
}
