// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing

@testable import LobbyKit

@Suite struct CategoryGroupsTests {
    static let json = #"{ "groups": [ { "name": null, "categories": ["Movies", "Series"] }, { "name": "Kids", "categories": ["Disney", "Pixar"] } ] }"#
    static let groups = CategoryGroups(groups: [
        CategoryGroup(name: nil, categories: ["Movies", "Series"]),
        CategoryGroup(name: "Kids", categories: ["Pixar", "Disney", "Disney II", "Kids Series"]),
    ])

    /// Adult films and a series in the main part; Pixar, Disney and a kids' series in Kids.
    static let catalogue = Catalogue(items: [
        Make.movie("heat", genres: ["Crime"], categories: ["Movies"]),
        Make.movie("alien", categories: ["Movies"]),
        Make.show("andor", categories: ["Series"]),
        Make.movie("up", genres: ["Animation"], categories: ["Pixar"]),
        Make.movie("coco", categories: ["Pixar"]),
        Make.movie("jungle", categories: ["Disney"]),
        Make.show("bluey", categories: ["Kids Series"]),
        // A show in a category that also holds films.
        Make.show("mickey", categories: ["Disney"]),
        // No category at all: the main part.
        Make.movie("loose"),
    ])

    // MARK: The call and the stored copy

    @Test func fetchesTheGroupsInTheServersOrder() async throws {
        let stub = StubServer { _ in .json(200, Self.json) }
        let groups = try await stub.client().categories()
        #expect(groups.groups.map(\.name) == [nil, "Kids"])
        #expect(groups.groups[1].categories == ["Disney", "Pixar"])
        #expect(stub.recorded.first?.path == "/v1/categories")
    }

    @Test func logosComeWithTheGroupsAndAreKeptForOffline() async throws {
        let json = #"{ "groups": [ { "name": "Kids", "categories": ["A", "B"] } ], "logos": { "A": { "id": "logo1", "width": 500, "height": 105 } } }"#
        let stub = StubServer { _ in .json(200, json) }
        let directory = try TemporaryDirectory()
        let store = CategoryGroupsStore(fileURL: directory.file("categories.json"))
        let groups = try await store.sync(using: stub.client())
        #expect(groups.category(id: "A")?.logo == CategoryLogo(id: "logo1", width: 500, height: 105))
        #expect(groups.category(id: "B")?.logo == nil)
        #expect(try stub.client().logoURL(groups.category(id: "A")!.logo!).path == "/v1/logos/logo1")

        let later = CategoryGroupsStore(fileURL: directory.file("categories.json"))
        #expect(await later.groups().category(id: "A")?.logo?.id == "logo1")
        // A server that sends none: no logos, no error.
        #expect(try JSONDecoder().decode(CategoryGroups.self, from: Data(Self.json.utf8)).categories.allSatisfy { $0.logo == nil })
    }

    @Test func theStoredCopyIsThereWithTheServerUnreachable() async throws {
        let directory = try TemporaryDirectory()
        let stub = StubServer { _ in .json(200, Self.json) }
        let store = CategoryGroupsStore(fileURL: directory.file("categories.json"))
        #expect(await store.groups() == .none)
        try await store.sync(using: stub.client())

        // The next launch, and the server does not answer.
        let later = CategoryGroupsStore(fileURL: directory.file("categories.json"))
        #expect(await later.groups().groups.map(\.name) == [nil, "Kids"])
        stub.setHandler { _ in throw URLError(.cannotConnectToHost) }
        await #expect(throws: LobbyError.self) { try await later.sync(using: stub.client()) }
        #expect(await later.groups().groups.count == 2)
    }

    @Test func aServerWithoutTheRouteHasNoGroups() async throws {
        let directory = try TemporaryDirectory()
        let stub = StubServer { _ in .json(200, Self.json) }
        let store = CategoryGroupsStore(fileURL: directory.file("categories.json"))
        try await store.sync(using: stub.client())

        stub.setHandler { _ in .error(404, "not_found") }
        #expect(try await store.sync(using: stub.client()) == .none)
        #expect(await CategoryGroupsStore(fileURL: directory.file("categories.json")).groups() == .none)
    }

    @Test func clearingForgetsTheGroups() async throws {
        let directory = try TemporaryDirectory()
        let stub = StubServer { _ in .json(200, Self.json) }
        let store = CategoryGroupsStore(fileURL: directory.file("categories.json"))
        try await store.sync(using: stub.client())
        try await store.clear()
        #expect(await store.groups() == .none)
        #expect(await CategoryGroupsStore(fileURL: directory.file("categories.json")).groups() == .none)
    }

    // MARK: Identity

    static let withIDs = #"{ "revision": 4, "groups": [ { "id": "g0", "name": null, "icon": null, "color": null, "logo": null, "categories": [], "entries": [] }, { "id": "g1", "name": "Small People", "icon": "star.fill", "color": "teal", "logo": { "id": "l0", "width": 10, "height": 5, "transparent": false }, "categories": ["Renamed"], "entries": [ { "id": "c1", "name": "Renamed", "icon": "leaf", "color": null, "logo": { "id": "l1", "width": 10, "height": 5, "transparent": true } } ] } ], "logos": {} }"#

    @Test func groupsAndCategoriesAreKnownByIdAndKeepTheirLook() async throws {
        let stub = StubServer { _ in .json(200, Self.withIDs) }
        let directory = try TemporaryDirectory()
        let fetched = try await CategoryGroupsStore(fileURL: directory.file("c.json")).sync(using: stub.client())
        #expect(fetched.revision == 4)
        #expect(fetched.group(id: "g1")?.icon == "star.fill")
        #expect(fetched.group(id: "g1")?.logo?.transparent == false)
        #expect(fetched.category(id: "c1") == LibraryCategory(id: "c1", name: "Renamed", icon: "leaf", logo: CategoryLogo(id: "l1", width: 10, height: 5)))
        // The same from the device's own copy.
        #expect(await CategoryGroupsStore(fileURL: directory.file("c.json")).groups() == fetched)
    }

    @Test func aTitleStaysInItsCategoryWhenTheCategoryIsRenamed() throws {
        let groups = try JSONDecoder().decode(CategoryGroups.self, from: Data(Self.withIDs.utf8))
        var byID = Make.movie("up", categories: ["Old Name"])
        byID.categoryIds = ["c1"]
        // Fetched before categories had ids: found by its name.
        let byName = Make.movie("coco", categories: ["Renamed"])
        let library = Shelves.library(in: Catalogue(items: [byID, byName, Make.movie("heat")]), groups: groups)
        #expect(library.groups.map(\.id) == ["g1"])
        #expect(library.groups[0].categories.map(\.id) == ["folder:c1"])
        #expect(library.groups[0].categories[0].name == "Renamed")
        #expect(library.groups[0].categories[0].items.map(\.id) == ["coco", "up"])
        #expect(library.movies.map(\.id) == ["heat"])
    }

    // MARK: The library by group

    @Test func noTitleIsInTheMainPartAndInAGroup() {
        let library = Shelves.library(in: Self.catalogue, groups: Self.groups)
        #expect(library.movies.map(\.id) == ["alien", "heat", "loose"])
        #expect(library.series.map(\.id) == ["andor"])

        let kids = library.groups[0]
        #expect(library.groups.map(\.name) == ["Kids"])
        #expect(kids.items.map(\.id) == ["bluey", "coco", "jungle", "mickey", "up"])
        let main = Set(library.movies.map(\.id) + library.series.map(\.id))
        #expect(main.isDisjoint(with: kids.items.map(\.id)))
    }

    @Test func aGroupsCategoriesComeInTheHouseholdsOrderWithoutEmptyOnes() {
        let kids = Shelves.library(in: Self.catalogue, groups: Self.groups).groups[0]
        // "Disney II" holds nothing and is left out; Pixar is before Disney, as configured.
        #expect(kids.categories.map(\.name) == ["Pixar", "Disney", "Kids Series"])
        #expect(kids.categories[0].items.map(\.id) == ["coco", "up"])
        // Films and a show in one category.
        #expect(kids.categories[1].items.map(\.id) == ["jungle", "mickey"])
    }

    @Test func theMainPartDoesNotRepeatMoviesAndSeriesAsCategories() {
        // "Series" is exactly the main part's shows. "Movies" is not exactly its films
        // ("loose" has no category), so it stays, as does the genre.
        let library = Shelves.library(in: Self.catalogue, groups: Self.groups)
        #expect(library.categories.map(\.id) == ["folder:Movies", "genre:Crime"])

        let tidy = Catalogue(items: Self.catalogue.itemsByID.values.filter { $0.id != "loose" })
        #expect(Shelves.library(in: tidy, groups: Self.groups).categories.map(\.id) == ["genre:Crime"])
    }

    @Test func aGroupThatHoldsNothingIsLeftOut() {
        let groups = CategoryGroups(groups: Self.groups.groups + [CategoryGroup(name: "Concerts", categories: ["Live"])])
        #expect(Shelves.library(in: Self.catalogue, groups: groups).groups.map(\.name) == ["Kids"])
    }

    @Test func withoutGroupsTheLibraryIsOneWholeAsBefore() {
        let library = Shelves.library(in: Self.catalogue, groups: .none)
        #expect(library.groups.isEmpty)
        #expect(library.movies == Shelves.movies(in: Self.catalogue))
        #expect(library.series == Shelves.series(in: Self.catalogue))
        #expect(library.categories == Shelves.categories(in: Self.catalogue))
    }
}
