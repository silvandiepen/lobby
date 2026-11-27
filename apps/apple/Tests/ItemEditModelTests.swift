// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

@MainActor
@Suite struct ItemEditModelTests {
    let test: TestApp

    init() throws {
        var state = Household.State(device: Device(id: "dev-1", name: "Mac", platform: .macos, role: .manager, createdAt: Make.epoch))
        var film = Make.movie("film", title: "Found Title", year: 2001, categories: ["One"])
        film.categoryIds = ["c1"]
        film.genres = ["Drama", "Family"]
        state.items = [film] + Make.show("show", title: "Show", episodesPerSeason: [2, 1])
        state.itemEdits = ["film": Household.EditedItem(item: film)]
        test = try TestApp(Household(state))
    }

    private func open() async throws -> ItemEditModel {
        let app = try await test.launchPaired(as: "alex")
        let model = ItemEditModel(app: app, itemID: "film")
        await model.load()
        return model
    }

    private var patches: [[String: Any]] {
        test.household.stub.requests("PATCH", "/v1/items/film").map { $0.json() }
    }

    @Test func itOpensWithWhatThereIsAndSavesNothingThatDidNotChange() async throws {
        let model = try await open()
        #expect(model.title == "Found Title")
        #expect(model.year == "2001")
        #expect(model.genres == "Drama, Family")
        #expect(model.categoryIDs == ["c1"])
        #expect(model.matchText == "Two films have that name.")
        #expect(model.changes.isEmpty)
        #expect(await model.save())
        #expect(patches.isEmpty)
    }

    @Test func onlyWhatChangedIsSavedAndAYearCanBeTakenAway() async throws {
        let model = try await open()
        model.title = " Better Title "
        model.year = ""
        model.categoryIDs = ["c2"]
        #expect(await model.save())
        let set = try #require(patches.first?["set"] as? [String: Any])
        #expect(set.keys.sorted() == ["categoryIds", "title", "year"])
        #expect(set["title"] as? String == "Better Title")
        #expect(set["year"] is NSNull)
        #expect(set["categoryIds"] as? [String] == ["c2"])
    }

    @Test func aFieldIsPutBackToWhatLobbyFinds() async throws {
        test.household.change { $0.itemEdits["film"]?.overriddenTitle = "Mine" }
        let model = try await open()
        #expect(model.title == "Mine")
        #expect(model.canPutBack(.title))
        #expect(!model.canPutBack(.year))
        model.putBack(.title)
        #expect(model.title == "Found Title")
        #expect(!model.canPutBack(.title))
        #expect(await model.save())
        #expect(patches.first?["reset"] as? [String] == ["title"])
        #expect(patches.first?["set"] == nil)

        // Put back, and then typed over after all: what was typed counts.
        let again = try await open()
        again.putBack(.year)
        again.year = "1999"
        #expect(again.changes.year == .some(1999))
    }

    @Test func whatIsNotAllowedCannotBeSaved() async throws {
        let model = try await open()
        model.year = "12"
        #expect(!model.canSave)
        model.year = "1999"
        #expect(model.canSave)
        model.title = "  "
        #expect(!model.canSave)
        model.title = "T"
        model.categoryIDs = []
        #expect(!model.canSave)
    }

    @Test func whenSomeoneWasFirstTheirsIsShownWhereThisOneTouchedNothing() async throws {
        let model = try await open()
        model.title = "Mine"
        test.household.change {
            $0.itemEdits["film"]?.revision = 1
            $0.itemEdits["film"]?.overriddenTitle = "Theirs"
            $0.itemEdits["film"]?.overriddenYear = .some(1950)
        }
        #expect(!(await model.save()))
        #expect(model.problem?.hasPrefix("Someone else changed this") == true)
        #expect(test.household.current.itemEdits["film"]?.overriddenTitle == "Theirs")
        #expect(model.title == "Mine")
        #expect(model.year == "1950")
        // Saving again, after reading that, sends only this one's change.
        #expect(await model.save())
        #expect(test.household.current.itemEdits["film"]?.overriddenTitle == "Mine")
        #expect(test.household.current.itemEdits["film"]?.overriddenYear == .some(1950))
    }

    @Test func aPictureFromTheDeviceIsSentAsAJPEG() async throws {
        let model = try await open()
        #expect(await model.upload(try Make.jpeg(width: 400, height: 600), for: .poster))
        #expect(test.household.current.uploads.first?.starts(with: [0xFF, 0xD8]) == true)
        #expect(!(await model.upload(Data("nothing".utf8), for: .poster)))
        #expect(model.problem == "That picture could not be read.")
        #expect(test.household.current.uploads.count == 1)
    }

    @Test func aTitleThatLeftTheLibrarySaysSo() async throws {
        let app = try await test.launchPaired(as: "alex")
        let model = ItemEditModel(app: app, itemID: "gone")
        await model.load()
        #expect(model.isGone)
        #expect(!model.canSave)
    }

    @Test func aWholeSeriesIsMarkedWatchedAndUnwatched() async throws {
        let app = try await test.launchPaired(as: "alex")
        let show = try #require(app.item("show"))
        #expect(app.showDetail(for: show).watch == .unwatched)
        #expect(app.showDetail(for: show).fromBeginning == nil)

        await app.markEpisodes(of: "show-s1", watched: true)
        #expect(app.showDetail(for: show).watch == .inProgress(fraction: nil))
        // Further than the first episode: it can be started over.
        #expect(app.showDetail(for: show).fromBeginning?.item.id == "show-s1e1")
        #expect(app.showDetail(for: show).fromBeginning?.startPositionMs == 0)
        await app.markEpisodes(of: "show", watched: true)
        #expect(app.showDetail(for: show).watch == .watched)
        #expect(test.household.current.progress["alex"]?.count == 3)

        await app.markEpisodes(of: "show", watched: false)
        #expect(app.showDetail(for: show).watch == .unwatched)
        #expect(test.household.current.progress["alex"]?.values.contains { $0.completed } == false)
    }
}
