// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

@MainActor
@Suite struct AppModelTests {
    let test: TestApp

    init() throws {
        test = try TestApp(Household(.init(
            items: [Make.movie("up", title: "Up"), Make.movie("coco", title: "Coco", categories: ["Pixar", "Kids Movies"])]
                + Make.show("wild", title: "Wild Isles", episodesPerSeason: [2]))))
    }

    @Test func aPairedDeviceWithoutAViewerAsksWhoIsWatching() async throws {
        let app = try await test.launchPaired()
        #expect(app.phase == .chooseProfile)
        #expect(app.profiles.map(\.name) == ["Alex", "Kids"])
        #expect(app.connectivity == .online)
        #expect(app.device?.role == .viewer)
    }

    @Test func theLibraryIsBuiltFromTheCatalogue() async throws {
        let app = try await test.launchPaired(as: "alex")
        #expect(app.phase == .library)
        #expect(app.activeProfile?.name == "Alex")
        #expect(app.shelves.movies.map(\.title) == ["Coco", "Up"])
        #expect(app.shelves.series.map(\.title) == ["Wild Isles"])
        #expect(app.shelves.categories.map(\.name) == ["Kids Movies", "Pixar", "Series"])
        #expect(app.shelves.continueWatching.isEmpty)
        #expect(app.hasLibraryCopy)
        #expect(app.search("wild").map(\.id) == ["wild"])
    }

    @Test func eachViewerHasTheirOwnContinueWatching() async throws {
        test.household.change {
            $0.progress["alex"] = ["up": Make.progress("up", positionMs: 1_500_000)]
            $0.progress["kids"] = ["coco": Make.progress("coco", positionMs: 600_000)]
            $0.revision = 2
        }
        let app = try await test.launchPaired(as: "alex")
        #expect(app.shelves.continueWatching.map(\.title) == ["Up"])
        #expect(app.movieDetail(for: try #require(app.item("up"))).watch == .inProgress(fraction: 0.25))

        await app.selectProfile(try #require(app.profiles.first { $0.id == "kids" }))
        #expect(app.shelves.continueWatching.map(\.title) == ["Coco"])
        #expect(app.movieDetail(for: try #require(app.item("up"))).watch == .unwatched)
        #expect(test.environment.preferences.activeProfileID == "kids")

        await app.selectProfile(try #require(app.profiles.first { $0.id == "alex" }))
        #expect(app.shelves.continueWatching.map(\.title) == ["Up"])
    }

    @Test func withThePiOffTheLibraryOpensFromTheDevicesCopy() async throws {
        test.household.change { $0.progress["alex"] = ["up": Make.progress("up", positionMs: 1_500_000)] }
        _ = try await test.launchPaired(as: "alex")

        test.household.change { $0.offline = true }
        let app = test.launch()
        await app.start()

        #expect(app.phase == .library)
        #expect(app.connectivity == .offline)
        #expect(app.connectNotice == nil)
        #expect(app.activeProfile?.name == "Alex")
        // Nothing is on this device, so there is nothing to offer: the Library says so.
        #expect(app.serverIsOutOfReach)
        #expect(app.showsDownloadedOnly)
        #expect(app.hasLibraryCopy)
        #expect(app.catalogue.isEmpty)
        #expect(app.shelves.movies.isEmpty && app.shelves.continueWatching.isEmpty)
        #expect(app.device?.role == .viewer)

        // Back in reach, everything returns without a restart, with where Alex stopped.
        test.household.change { $0.offline = false }
        await app.refresh()
        #expect(!app.showsDownloadedOnly)
        #expect(app.shelves.movies.map(\.title) == ["Coco", "Up"])
        #expect(app.shelves.continueWatching.map(\.title) == ["Up"])
        #expect(await test.credentials.token(forServer: "server-1") == "device-token")
    }

    @Test func aRemovedDeviceGoesBackToConnectAndIsToldWhy() async throws {
        _ = try await test.launchPaired(as: "alex")
        test.household.change { $0.revoked = true }
        let app = test.launch()
        await app.start()

        #expect(app.phase == .connect)
        #expect(app.connectNotice == .deviceRemoved)
        #expect(app.connectivity != .offline)
        // The credential is gone, the address is still there for pairing again.
        #expect(await test.credentials.token(forServer: "server-1") == nil)
        #expect(app.rememberedAddress == test.household.stub.host)
    }

    @Test func aCredentialTheServerDoesNotKnowIsNotCalledRemoved() async throws {
        let state = test.household.current
        await test.credentials.setToken("from-another-life", forServer: state.server.id)
        test.environment.preferences.connection = SavedConnection(
            serverAddress: test.household.stub.baseURL, serverID: state.server.id, serverName: state.server.name, deviceID: "dev-1")
        let app = test.launch()
        await app.start()
        #expect(app.phase == .connect)
        #expect(app.connectNotice == .credentialNotRecognised)
    }

    @Test func aFailedFirstFetchOfTheViewersRecovers() async throws {
        test.household.change { $0.offline = true }
        let app = try await test.launchPaired()
        #expect(app.phase == .chooseProfile)
        #expect(!app.hasFetchedProfiles)
        #expect(app.profiles.isEmpty)

        test.household.change { $0.offline = false }
        await app.fetchProfiles()
        #expect(app.hasFetchedProfiles)
        #expect(app.profiles == test.household.current.profiles)
    }

    @Test func viewersAddedOnAnotherDeviceArriveWithTheNextLook() async throws {
        let app = try await test.launchPaired()
        let before = app.profiles.count
        test.household.change { $0.profiles.append(Profile(id: "elsewhere", name: "Robin", color: "teal")) }
        await app.fetchProfiles()
        #expect(app.profiles.count == before + 1)
        #expect(app.profiles.last?.name == "Robin")
    }

    @Test func pairingAgainWithTheSameServerKeepsTheViewerAndTheLibrary() async throws {
        _ = try await test.launchPaired(as: "alex")
        test.household.change { $0.revoked = true }
        let app = test.launch()
        await app.start()
        #expect(app.phase == .connect)

        let model = ConnectModel(app: app)
        model.addressText = test.household.stub.baseURL.absoluteString
        await model.findServer()
        await model.requestCode()
        test.household.change { $0.approved = true }
        await model.waitUntilPaired()

        // Straight back to where they were: the same viewer, the same library.
        #expect(app.phase == .library)
        #expect(app.activeProfile?.name == "Alex")
        #expect(app.connectNotice == nil)
        #expect(app.shelves.movies.count == 2)
    }

    @Test func aViewerDeletedOnTheServerIsAskedForAgain() async throws {
        _ = try await test.launchPaired(as: "kids")
        test.household.change { $0.profiles.removeAll { $0.id == "kids" } }
        let app = test.launch()
        await app.start()
        #expect(app.phase == .chooseProfile)
        #expect(app.activeProfile == nil)
        #expect(test.environment.preferences.activeProfileID == nil)
    }

    @Test func markingWatchedReachesTheServerAndTheShelf() async throws {
        test.household.change { $0.progress["alex"] = ["up": Make.progress("up", positionMs: 1_500_000)] }
        let app = try await test.launchPaired(as: "alex")
        #expect(app.shelves.continueWatching.count == 1)

        await app.markWatched(itemID: "up")
        #expect(app.shelves.continueWatching.isEmpty)
        #expect(test.household.current.progress["alex"]?["up"]?.completed == true)

        await app.markUnwatched(itemID: "up")
        #expect(app.movieDetail(for: try #require(app.item("up"))).watch == .unwatched)
        #expect(test.household.current.progress["alex"]?["up"]?.positionMs == 0)
    }

    @Test func signingOutForgetsTheCredentialAndTheLibrary() async throws {
        let app = try await test.launchPaired(as: "alex")
        await app.signOut()

        #expect(app.phase == .connect)
        #expect(app.connectNotice == nil)
        #if os(iOS) || os(macOS)
        // The server stops pushing to this device, told while the credential was still there.
        let forgets = test.household.stub.requests("DELETE", "/v1/me/push")
        #expect(forgets.count == 1)
        #expect(forgets.first?.headers["Authorization"] == "Bearer device-token")
        #endif
        #expect(app.catalogue.isEmpty)
        #expect(await test.credentials.token(forServer: "server-1") == nil)
        #expect(test.environment.preferences.connection == nil)
        #expect(await test.environment.catalogueStore.catalogue().isEmpty)

        let relaunched = test.launch()
        await relaunched.start()
        #expect(relaunched.phase == .connect)
    }

    @Test func anEmptyLibraryIsKnownToBeEmptyNotMissing() async throws {
        test.household.change { $0.items = [] }
        let app = try await test.launchPaired(as: "alex")
        #expect(app.catalogue.isEmpty)
        #expect(app.hasLibraryCopy)
    }

    @Test func aFirstFetchShowsWhatHasArrivedWhenTheRestDoesNotCome() async throws {
        // Pages of two, and the connection breaks on the third page.
        let all = test.household.current.items.count
        #expect(all > 4)
        test.household.change {
            $0.pageSize = 2
            $0.failLibraryAtPage = 3
        }
        let app = try await test.launchPaired(as: "alex")

        // The first two pages are on screen, although the fetch did not finish.
        #expect(app.catalogue.count == 4)
        #expect(app.shelves.movies.count + app.shelves.series.count >= 1)
        #expect(app.connectivity == .offline)
        #expect(!app.hasLibraryCopy)

        // The next refresh goes on where it stopped, not from the start.
        let served = test.household.current.pagesServed
        await app.refresh()
        #expect(app.catalogue.count == all)
        #expect(app.hasLibraryCopy)
        // Only the pages that were still missing are asked for.
        #expect(test.household.current.pagesServed == served + (all - 4 + 1) / 2)
    }

    @Test func aRequestThatFailsOnceDoesNotEmptyTheLibrary() async throws {
        // The server answers, but the library's second page breaks: a hiccup, not "offline".
        test.household.change {
            $0.pageSize = 2
            $0.failLibraryAtPage = 2
        }
        let app = try await test.launchPaired(as: "alex")
        #expect(app.connectivity == .offline)
        #expect(!app.serverIsOutOfReach)
        #expect(!app.showsDownloadedOnly)
        #expect(app.catalogue.count == 2)
    }

    // MARK: The household's parts of the library

    private static let kids = CategoryGroups(groups: [
        CategoryGroup(name: nil, categories: ["Movies", "Series"]),
        CategoryGroup(name: "Kids", categories: ["Pixar", "Disney", "Kids Movies"]),
    ])

    @Test func kidsTitlesAreApartFromTheMainMoviesAndSeries() async throws {
        test.household.change { $0.categoryGroups = Self.kids }
        let app = try await test.launchPaired(as: "alex")

        // Coco and Up are Pixar or Kids Movies: none of them is on the main Movies page.
        #expect(app.shelves.movies.isEmpty)
        #expect(app.shelves.series.map(\.title) == ["Wild Isles"])
        let kids = try #require(app.shelves.group(id: "Kids"))
        #expect(kids.items.map(\.title) == ["Coco", "Up"])
        // The household's order, and "Disney", which holds nothing, is left out.
        #expect(kids.categories.map(\.name) == ["Pixar", "Kids Movies"])
        // "Series" only repeats the Series page.
        #expect(app.shelves.categories.isEmpty)
        // A category of a group is found by its id, for its page.
        #expect(app.shelves.category(id: "folder:Pixar")?.name == "Pixar")
        // Search and Recently Added stay across everything.
        #expect(app.search("coco").map(\.title) == ["Coco"])
        #expect(app.shelves.recentlyAdded.contains { $0.title == "Coco" })
    }

    @Test func thePartsOfTheLibraryAreKeptForOffline() async throws {
        test.household.change { $0.categoryGroups = Self.kids }
        _ = try await test.launchPaired(as: "alex")
        test.household.change { $0.offline = true }
        let app = test.launch()
        await app.start()
        // Out of reach and nothing downloaded: no groups to show, but they are not forgotten.
        #expect(app.shelves.groups.isEmpty)
        #expect(app.categoryGroups == Self.kids)
    }

    @Test func signingOutForgetsThePartsOfTheLibrary() async throws {
        test.household.change { $0.categoryGroups = Self.kids }
        let app = try await test.launchPaired(as: "alex")
        await app.signOut()
        #expect(app.shelves.groups.isEmpty)
        #expect(await test.environment.categoryGroupsStore.groups() == .none)
    }

    // MARK: At home and away

    @Test func aDevicePairedAtHomeFindsTheServerFromElsewhereWithoutPairingAgain() async throws {
        test.household.announceAddresses()
        let app = try await test.launchPaired(as: "alex")
        #expect(app.connection?.addresses?.remote == [test.household.remote.baseURL])
        #expect(app.connection?.serverAddress == test.household.stub.baseURL)
        #expect(test.household.remote.recorded.allSatisfy { $0.path == "/v1/server" })

        // Out of the house: the home address is gone, the other one answers.
        test.household.change { $0.awayFromHome = true }
        await app.refresh()
        #expect(app.connectivity == .online)
        #expect(app.connection?.serverAddress == test.household.remote.baseURL)
        #expect(test.environment.preferences.connection?.serverAddress == test.household.remote.baseURL)
        #expect(app.phase == .library)
        #expect(!test.household.remote.requests("GET", "/v1/me").isEmpty)

        // The next launch starts where the server last was, and goes home again once it can.
        let again = test.launch()
        await again.start()
        #expect(again.connectivity == .online)
        test.household.change { $0.awayFromHome = false }
        let relaunched = test.launch()
        await relaunched.start()
        #expect(relaunched.connection?.serverAddress == test.household.stub.baseURL)
    }

    @Test func somethingElseAtTheHomeAddressNeverSeesTheCredential() async throws {
        test.household.announceAddresses()
        let app = try await test.launchPaired(as: "alex")
        let before = test.household.stub.recorded.count

        // A hotel's network where the same address belongs to another Lobby Server.
        test.household.change {
            $0.awayFromHome = true
            $0.strangerAtHomeAddress = "someone-elses-server"
        }
        let away = test.launch()
        await away.start()
        #expect(away.connectivity == .online)
        #expect(away.connection?.serverAddress == test.household.remote.baseURL)

        let seenByStranger = test.household.stub.recorded.dropFirst(before)
        #expect(!seenByStranger.isEmpty)
        #expect(seenByStranger.allSatisfy { $0.path == "/v1/server" })
        #expect(seenByStranger.allSatisfy { $0.headers["Authorization"] == nil && $0.headers["Cookie"] == nil })
        _ = app
    }

    @Test func withNoAddressThatAnswersAsTheServerTheAppIsOfflineAndSendsNothing() async throws {
        // An older server: it names no addresses, so there is only the one from pairing.
        _ = try await test.launchPaired(as: "alex")
        let before = test.household.stub.recorded.count
        test.household.change {
            $0.awayFromHome = true
            $0.strangerAtHomeAddress = "someone-elses-server"
        }
        let away = test.launch()
        await away.start()
        #expect(away.connectivity == .offline)
        #expect(away.serverIsOutOfReach)
        #expect(away.phase == .library)
        #expect(away.item("coco") != nil)
        #expect(test.household.stub.recorded.dropFirst(before).allSatisfy { $0.path == "/v1/server" && $0.headers["Authorization"] == nil })
    }
}
