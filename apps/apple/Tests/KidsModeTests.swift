// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

/// Kids mode in the app model: who is in it, what there is to watch, and that nothing but a
/// grown-up leads out of it.
@MainActor
@Suite struct KidsModeTests {
    private static let groups = CategoryGroups(groups: [
        CategoryGroup(id: "main", name: nil, entries: [LibraryCategory(id: "c1", name: "One")]),
        CategoryGroup(id: "g2", name: "Two", entries: [LibraryCategory(id: "c2", name: "Second")]),
    ])

    private static func film(_ id: String, _ category: String, files: [MediaFile]? = nil) -> Item {
        Item(
            id: id, kind: .movie, title: id.capitalized, categoryIds: [category], addedAt: Make.epoch,
            files: files ?? [Make.file(assetID: "file-\(id)")])
    }

    private func household(
        kids: KidsSettings? = KidsSettings(allowedGroupIds: ["g2"]), bound: String? = nil, role: DeviceRole = .viewer
    ) -> Household {
        var convertible = Make.file(.transcode, container: "avi", codec: "mpeg4")
        convertible.convertible = true
        var show = Make.show("show", title: "Show", episodesPerSeason: [3], file: Make.file(durationMs: 1_200_000, assetID: "file-show"))
        for index in show.indices { show[index].categoryIds = ["c2"] }
        return Household(.init(
            device: Device(
                id: "dev-1", name: "Phone", platform: .ios, role: role, createdAt: Make.epoch, kidsProfileId: bound, saysKidsProfile: true),
            profiles: [
                Profile(id: "adult", name: "Adult", color: "blue", saysKids: true),
                Profile(id: "kid", name: "Kid", color: "green", kids: kids, saysKids: true),
            ],
            knowsKids: true,
            items: [
                Self.film("grown", "c1"), Self.film("bee", "c2"), Self.film("ant", "c2"),
                Self.film("old", "c2", files: [convertible]),
                Self.film("broken", "c2", files: [Make.file(.unsupported)]),
            ] + show,
            categoryGroups: Self.groups))
    }

    private func testApp(_ household: Household, check: GrownUpCheck = .refused) throws -> TestApp {
        let test = try TestApp(household)
        test.environment.hasKidsScreens = true
        test.environment.confirmGrownUp = { check }
        return test
    }

    private func wait(_ app: AppModel) async throws {
        // Whatever a change set off has settled when a refresh has.
        await app.refresh()
    }

    // MARK: What there is

    @Test func aKidsViewerSeesOnlyWhatIsAllowedAndPlays() async throws {
        let app = try await testApp(household()).launchPaired(as: "kid")
        #expect(app.phase == .library)
        #expect(app.showsKidsScreens)
        #expect(app.kidsLibrary.movies.map(\.id) == ["ant", "bee"])
        #expect(app.kidsLibrary.series.map(\.id) == ["show"])
        #expect(app.kidsLibrary.onHere.isEmpty)
        #expect(app.item("grown") == nil)
        #expect(app.search("grown").isEmpty)
        // Allowed, but it would have to be converted first, or cannot be played at all.
        #expect(app.item("old") != nil)
        #expect(app.kidsLibrary.catalogue.item("old") == nil)
        #expect(app.kidsLibrary.catalogue.item("broken") == nil)
    }

    @Test func nothingAllowedIsNothing() async throws {
        let app = try await testApp(household(kids: KidsSettings())).launchPaired(as: "kid")
        #expect(app.showsKidsScreens)
        #expect(app.catalogue.isEmpty)
        #expect(app.kidsLibrary == .empty)
    }

    @Test func continueWatchingLeavesOutWhatIsNotAllowedAnyMore() async throws {
        let household = household()
        household.change {
            $0.progress["kid"] = [
                "grown": Make.progress("grown", positionMs: 900_000), "bee": Make.progress("bee", positionMs: 900_000, minutesAgo: 5),
                "show-s1e1": Make.progress("show-s1e1", positionMs: 1_200_000, durationMs: 1_200_000, completed: true, minutesAgo: 9),
            ]
            $0.revision = 3
        }
        let app = try await testApp(household).launchPaired(as: "kid")
        #expect(app.kidsLibrary.continueWatching.map(\.title) == ["Bee", "Show"])
        #expect(app.kidsLibrary.seriesToContinue.map(\.title) == ["Show"])
        // What stands above as a card is not a poster under it.
        #expect(app.kidsLibrary.home.map(\.id) == ["ant"])

        household.change { $0.profiles[1].kids?.blockedItemIds = ["show"] }
        try await wait(app)
        #expect(app.kidsLibrary.continueWatching.map(\.title) == ["Bee"])
        #expect(app.kidsLibrary.series.isEmpty)
    }

    @Test func anAdultOnTheSameDeviceStillSeesEverything() async throws {
        let app = try await testApp(household()).launchPaired(as: "adult")
        #expect(!app.showsKidsScreens)
        #expect(app.item("grown") != nil)
        #expect(app.kidsLibrary == .empty)
        await app.selectProfile(try #require(app.profiles.last))
        #expect(app.showsKidsScreens)
        #expect(app.item("grown") == nil)
    }

    @Test func playOnTVIsForTheKidsScreensAndTheGrownUpsRemoteIsNot() async throws {
        let app = try await testApp(household()).launchPaired(as: "kid")
        #if os(tvOS)
        #expect(!app.remote.showsKidsRemote)
        #else
        #expect(app.remote.showsKidsRemote)
        #endif
        #expect(!app.remote.showsRemote)
        #expect(app.remote.targets.isEmpty)
        // Without a channel there is no TV to play on, so the button is not there.
        #expect(app.remote.kidsTargets.isEmpty)
        #expect(app.remote.kidsPlaying == nil)

        let grownUp = try await testApp(household()).launchPaired(as: "adult")
        #expect(!grownUp.remote.showsKidsRemote)
    }

    @Test func aBoundDeviceHasPlayOnTVAsKidsModeHas() async throws {
        let app = try await testApp(household(bound: "kid")).launchPaired(as: "kid")
        #expect(app.isBoundToKids)
        #if os(tvOS)
        #expect(!app.remote.showsKidsRemote)
        #else
        #expect(app.remote.showsKidsRemote)
        #endif
        #expect(!app.remote.showsRemote)
    }

    @Test func aFilmThatIsNotAllowedDoesNotPlay() async throws {
        let app = try await testApp(household()).launchPaired(as: "kid")
        let grown = try #require(app.wholeCatalogue.item("grown"))
        let request = try #require(PlayActionBuilder.action(for: grown, progress: nil, context: Make.context).request)
        app.play(request)
        #expect(app.player == nil)
    }

    @Test func offlineThereIsOnlyWhatIsOnTheDevice() async throws {
        let household = household()
        let file = Make.file(assetID: "bee-file", sizeBytes: 4)
        household.change {
            $0.items = [Self.film("bee", "c2", files: [file]), Self.film("ant", "c2"), Self.film("grown", "c1")]
            $0.files["bee-file"] = Data([1, 2, 3, 4])
        }
        let test = try testApp(household)
        let app = try await test.launchPaired(as: "kid")
        let watching = Task { await app.watchDownloads() }
        defer { watching.cancel() }
        await app.download(try #require(app.item("bee")))
        for _ in 0..<2000 where app.downloads["bee"]?.state != .verified {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await wait(app)
        #expect(app.kidsLibrary.onHere.map(\.id) == ["bee"])
        #expect(app.kidsLibrary.movies.map(\.id) == ["ant", "bee"])

        household.change { $0.offline = true }
        let again = test.launch()
        await again.start()
        #expect(again.showsKidsScreens)
        #expect(again.kidsLibrary.movies.map(\.id) == ["bee"])
        #expect(again.kidsLibrary.onHere.map(\.id) == ["bee"])
    }

    // MARK: No way out

    @Test func theAvatarLeadsOutOnlyPastAGrownUp() async throws {
        for (check, phase) in [(GrownUpCheck.refused, AppModel.Phase.library), (.unavailable, .library), (.confirmed, .chooseProfile)] {
            let app = try await testApp(household(), check: check).launchPaired(as: "kid")
            app.chooseAnotherProfile()
            await app.selectProfile(try #require(app.profiles.first))
            #expect(app.activeProfile?.id == "kid")
            #expect(app.phase == .library)
            await app.askToLeaveKidsMode()
            #expect(app.phase == phase)
            #expect(app.grownUpNotice == (check == .unavailable ? .noPasscode : nil))
        }
    }

    @Test func thePickerLeftOpenIsKidsModeAgain() async throws {
        let test = try testApp(household(), check: .confirmed)
        let app = try await test.launchPaired(as: "kid")
        await app.askToLeaveKidsMode()
        #expect(app.phase == .chooseProfile)
        await app.enteredBackground()
        #expect(app.phase == .library)
        #expect(app.showsKidsScreens)

        // And a grown-up who does choose is out.
        await app.askToLeaveKidsMode()
        await app.selectProfile(try #require(app.profiles.first))
        #expect(!app.showsKidsScreens)
        #expect(test.environment.settings.kidsModeProfileID == nil)
        #expect(app.item("grown") != nil)
    }

    /// The way out as a phone takes it: the grown-up's question, Who is watching,
    /// and the grown-up chosen there. Nothing that follows takes the device back to the kids
    /// screens: not the app coming to the front again after Face ID, not a relaunch.
    @Test func aGrownUpWhoLeftStaysOut() async throws {
        let test = try testApp(household(), check: .confirmed)
        let app = try await test.launchPaired(as: "kid")
        await app.askToLeaveKidsMode()
        #expect(app.phase == .chooseProfile)
        // Face ID takes the app out of the front for a moment.
        await app.becameActive()
        #expect(app.phase == .chooseProfile)
        await app.selectProfile(try #require(app.profiles.first { $0.id == "adult" }))
        await app.becameActive()
        #expect(app.phase == .library)
        #expect(!app.showsKidsScreens)
        #expect(app.activeProfile?.id == "adult")

        let again = test.launch()
        await again.start()
        #expect(again.phase == .library)
        #expect(!again.showsKidsScreens)
        #expect(again.activeProfile?.id == "adult")
    }

    @Test func aBoundDeviceHasNoWayOutAtAll() async throws {
        let test = try testApp(household(bound: "kid"), check: .confirmed)
        let app = try await test.launchPaired()
        #expect(app.phase == .library)
        #expect(app.activeProfile?.id == "kid")
        await app.askToLeaveKidsMode()
        #expect(app.phase == .library)
        #expect(app.grownUpNotice == .bound)
        app.chooseAnotherProfile()
        await app.selectProfile(try #require(app.profiles.first))
        #expect(app.phase == .library)
        #expect(app.activeProfile?.id == "kid")
    }

    @Test func bindingADeviceTakesItOverAndFreeingItLeavesTheKidsViewer() async throws {
        let household = household()
        let app = try await testApp(household).launchPaired(as: "adult")
        app.libraryPath = [.item("grown")]
        household.change { $0.device.kidsProfileId = "kid" }
        try await wait(app)
        #expect(app.showsKidsScreens)
        #expect(app.activeProfile?.id == "kid")
        #expect(app.libraryPath.isEmpty)
        #expect(app.item("grown") == nil)

        household.change { $0.device.kidsProfileId = nil }
        try await wait(app)
        #expect(!app.isBoundToKids)
        #expect(app.showsKidsScreens)
    }

    @Test func aBindingToAViewerNobodyKnowsShowsNothing() async throws {
        let app = try await testApp(household(bound: "gone")).launchPaired(as: "adult")
        #expect(app.showsKidsScreens)
        #expect(app.catalogue.isEmpty)
    }

    @Test func aBoundDeviceDropsWhatIsTakenAwayAndASharedOneKeepsIt() async throws {
        for bound in ["kid", nil] {
            let household = household(bound: bound)
            household.change {
                $0.items = [Self.film("bee", "c2", files: [Make.file(assetID: "bee-file", sizeBytes: 4)]), Self.film("ant", "c2")]
                $0.files["bee-file"] = Data([1, 2, 3, 4])
            }
            let app = try await testApp(household).launchPaired(as: "kid")
            let watching = Task { await app.watchDownloads() }
            defer { watching.cancel() }
            await app.download(try #require(app.item("bee")))
            for _ in 0..<2000 where app.downloads["bee"]?.state != .verified {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(app.downloads["bee"]?.state == .verified)

            household.change {
                $0.removed = ["bee"]
                $0.profiles[1].kids?.blockedItemIds = ["bee"]
            }
            try await wait(app)
            #expect(app.kidsLibrary.movies.map(\.id) == ["ant"])
            #expect(app.kidsLibrary.onHere.isEmpty)
            let kept = await app.environment.downloads.all().map(\.itemID)
            #expect(kept == (bound == nil ? ["bee"] : []))
        }
    }

    // MARK: Fail closed

    @Test func withoutTheServerTheDeviceStaysInKidsMode() async throws {
        let household = household(bound: "kid")
        let test = try testApp(household, check: .confirmed)
        _ = try await test.launchPaired()
        household.change { $0.offline = true }
        let app = test.launch()
        await app.start()
        #expect(app.phase == .library)
        #expect(app.showsKidsScreens)
        #expect(app.isBoundToKids)
        #expect(app.activeProfile?.id == "kid")
    }

    @Test func anOlderServerDoesNotEndKidsMode() async throws {
        let household = household(bound: "kid")
        let test = try testApp(household)
        _ = try await test.launchPaired()
        // Rolled back: it says nothing about kids any more.
        household.change {
            $0.device = Device(id: "dev-1", name: "Phone", platform: .ios, role: .viewer, createdAt: Make.epoch)
            $0.profiles = [Profile(id: "adult", name: "Adult", color: "blue"), Profile(id: "kid", name: "Kid", color: "green")]
        }
        let app = test.launch()
        await app.start()
        #expect(app.connectivity == .online)
        #expect(app.isBoundToKids)
        #expect(app.kidsLibrary.movies.map(\.id) == ["ant", "bee"])
        #expect(app.item("grown") == nil)
    }

    @Test func aListOfViewersThatCannotBeReadDoesNotEndKidsMode() async throws {
        let household = household()
        let test = try testApp(household)
        _ = try await test.launchPaired(as: "kid")
        test.environment.settings.profiles = []
        household.change { $0.offline = true }
        let app = test.launch()
        await app.start()
        #expect(app.phase == .library)
        #expect(app.showsKidsScreens)
        #expect(app.catalogue.isEmpty)
    }

    @Test func aDeletedKidsViewerDoesNotOpenThePicker() async throws {
        let household = household()
        let app = try await testApp(household).launchPaired(as: "kid")
        household.change { $0.profiles.removeLast() }
        try await wait(app)
        #expect(app.phase == .library)
        #expect(app.showsKidsScreens)
        #expect(app.catalogue.isEmpty)
    }

    @Test func pairingAgainIsKidsModeAgain() async throws {
        let household = household()
        let test = try testApp(household)
        _ = try await test.launchPaired(as: "kid")
        household.change { $0.revoked = true }
        let app = test.launch()
        await app.start()
        #expect(app.phase == .connect)
        household.change { $0.revoked = false }
        let restarted = test.launch()
        await restarted.start()
        #expect(restarted.phase == .connect)
        household.change { $0.approved = true }
        let client = try LobbyClient(baseURL: household.stub.baseURL, session: household.stub.session)
        let request = try await client.requestPairing(deviceName: "Phone", platform: .ios)
        guard case .approved(let grant) = try await client.collectPairing(request) else {
            Issue.record("The pairing was not approved.")
            return
        }
        try await restarted.completePairing(address: household.stub.baseURL, server: household.current.server, grant: grant)
        #expect(restarted.phase == .library)
        #expect(restarted.showsKidsScreens)
        #expect(restarted.item("grown") == nil)
    }

    // MARK: The manager

    @Test func aManagerMakesAKidsViewerAndChoosesWhatItMayWatch() async throws {
        let household = household(kids: nil, role: .manager)
        let app = try await testApp(household).launchPaired(as: "adult")
        let model = ViewerPageModel(app: app, profileID: "kid")
        #expect(model.kids == nil)
        await model.setIsKids(true)
        #expect(model.summary.hasPrefix("Nothing is allowed yet"))
        await model.setAllows(true, group: "g2")
        #expect(model.summary == "4 films and 1 series to watch.")
        await model.set(.blocked, for: "bee")
        await model.set(.allowed, for: "grown")
        #expect(model.summary == "4 films and 1 series to watch.")
        #expect(household.current.profiles[1].kids
            == KidsSettings(allowedGroupIds: ["g2"], allowedItemIds: ["grown"], blockedItemIds: ["bee"]))
        #expect(model.titles("").map(\.caption) == ["Blocked", "Always allowed"])
        await model.set(.byCategory, for: "bee")
        #expect(model.titles("bee").map(\.caption) == ["Allowed by its category"])
        await model.setIsKids(false)
        #expect(household.current.profiles[1].kids == nil)
        #expect(model.problem == nil)
    }

    @Test func idsOfTitlesThatAreAwayStayInTheLists() async throws {
        let known = KidsSettings(
            allowedGroupIds: ["g-away"], allowedCategoryIds: ["c-away"], allowedItemIds: ["film-away"], blockedItemIds: ["blocked-away"])
        let household = household(kids: known, role: .manager)
        let app = try await testApp(household).launchPaired(as: "adult")
        let model = ViewerPageModel(app: app, profileID: "kid")
        await model.setAllows(true, group: "g2")
        await model.setAllows(true, category: "c1")
        await model.set(.blocked, for: "bee")
        await model.set(.allowed, for: "grown")
        await model.set(.byCategory, for: "bee")
        #expect(household.current.profiles[1].kids == KidsSettings(
            allowedGroupIds: ["g-away", "g2"], allowedCategoryIds: ["c-away", "c1"], allowedItemIds: ["film-away", "grown"],
            blockedItemIds: ["blocked-away"]))
    }

    @Test func theViewerWhoIsWatchingHereIsNotMadeAKidsViewer() async throws {
        let household = household(kids: nil, role: .manager)
        let app = try await testApp(household).launchPaired(as: "kid")
        let model = ViewerPageModel(app: app, profileID: "kid")
        #expect(model.isWatchingHere)
        await model.setIsKids(true)
        #expect(household.stub.requests("PATCH", "/v1/profiles/kid").isEmpty)
    }

    @Test func anOlderServerIsNamedAsTheReason() async throws {
        let household = household(kids: nil, role: .manager)
        household.change { $0.knowsKids = false }
        let app = try await testApp(household).launchPaired(as: "adult")
        let model = ViewerPageModel(app: app, profileID: "kid")
        await model.setIsKids(true)
        #expect(model.kids == nil)
        #expect(model.problem == KidsUnsupported().localizedDescription)
    }

    @Test func aManagerBindsADeviceAndFreesIt() async throws {
        let household = household(role: .manager)
        household.change {
            $0.otherDevices = [Device(
                id: "dev-2", name: "Tablet", platform: .ipados, role: .viewer, createdAt: Make.epoch, saysKidsProfile: true)]
        }
        let app = try await testApp(household).launchPaired(as: "adult")
        let model = DevicePageModel(app: app, deviceID: "dev-2")
        await model.refresh()
        #expect(model.canBeBound)
        #expect(model.kidsViewers.map(\.id) == ["kid"])
        await model.bind(to: "kid")
        #expect(household.current.otherDevices[0].kidsProfileId == "kid")
        await model.bind(to: nil)
        #expect(household.current.otherDevices[0].kidsProfileId == nil)
        #expect(model.problem == nil)

        let own = DevicePageModel(app: app, deviceID: "dev-1")
        await own.refresh()
        #expect(!own.canBeBound)
    }

    // MARK: Places

    private static let school = KidsPlace(id: "school", name: "School", latitude: 52, longitude: 4, radiusMeters: 300, mode: .nothing)

    private static func kidsMe(places: [KidsPlace]) -> KidsMe {
        KidsMe(
            profileId: "kid",
            now: KidsNow(at: KidsModeAt(mode: .everything, reason: .schedule, browse: true, video: .all, listening: true)),
            plan: KidsPlan(places: places), timeZone: "Europe/Amsterdam", request: nil,
            signed: SignedKidsPlan(payload: "", signature: ""), publicKey: "", serverTime: 0)
    }

    /// A kids app whose places are followed until the watcher stops, never by Location.
    private func placesApp(_ household: Household, check: GrownUpCheck = .refused) throws -> TestApp {
        household.change { $0.kidsMe = Self.kidsMe(places: [Self.school]) }
        let test = try testApp(household, check: check)
        test.environment.followPlaces = { _, _ in
            // Until the watcher cancels it.
            try? await Task.sleep(for: .seconds(3600))
        }
        return test
    }

    @Test func thePlacesAreWatchedOnlyWhileThePlanHasSome() async throws {
        let household = household()
        let app = try await placesApp(household).launchPaired(as: "kid")
        #expect(app.places.isWatching)
        #expect(app.places.watching == [Self.school])

        household.change { $0.kidsMe = Self.kidsMe(places: []) }
        try await wait(app)
        #expect(!app.places.isWatching)
    }

    @Test func leavingKidsModeStopsWatchingThePlaces() async throws {
        let app = try await placesApp(household(), check: .confirmed).launchPaired(as: "kid")
        #expect(app.places.isWatching)
        await app.askToLeaveKidsMode()
        await app.selectProfile(try #require(app.profiles.first { $0.id == "adult" }))
        #expect(!app.isKidsMode)
        #expect(!app.places.isWatching)
    }

    @Test func signingOutStopsWatchingThePlaces() async throws {
        let app = try await placesApp(household()).launchPaired(as: "kid")
        #expect(app.places.isWatching)
        await app.signOut()
        #expect(!app.places.isWatching)
    }

    @Test func aRemovedDeviceStopsWatchingThePlaces() async throws {
        let household = household(bound: "kid")
        let app = try await placesApp(household).launchPaired()
        #expect(app.places.isWatching)
        household.change { $0.revoked = true }
        await app.refresh()
        #expect(app.phase == .connect)
        #expect(!app.places.isWatching)
    }

    /// Another server in use takes this one down: its places are not watched for it any more.
    @Test func anotherServerStopsWatchingThePlaces() async throws {
        let app = try await placesApp(household()).launchPaired(as: "kid")
        #expect(app.places.isWatching)
        await app.suspend()
        #expect(!app.places.isWatching)
    }
}

#if !os(tvOS)
import LocalAuthentication

@MainActor
@Suite struct KidsOnTheDeviceTests {
    @Test func onlyAMissingPasscodeIsExplainedAndNothingButAPassPasses() {
        #expect(GrownUpGate.check(for: LAError(.passcodeNotSet) as NSError) == .unavailable)
        for code in [LAError.userCancel, .authenticationFailed, .biometryLockout, .systemCancel, .notInteractive] {
            #expect(GrownUpGate.check(for: LAError(code) as NSError) == .refused)
        }
        #expect(GrownUpGate.check(for: nil) == .refused)
    }

    /// Watch and Listen let a child in, so a locked phone does not answer them: the grown-up
    /// unlocks first. No only keeps things as they are and answers from the lock screen.
    @Test func onlyNoAnswersAChildWithoutUnlocking() throws {
        let actions = Dictionary(uniqueKeysWithValues: PushCenter.kidsQuestionCategory().actions.map { ($0.identifier, $0.options) })
        #expect(actions.count == 3)
        #expect(try #require(actions[PushCenter.watch]).contains(.authenticationRequired))
        #expect(try #require(actions[PushCenter.listen]).contains(.authenticationRequired))
        let no = try #require(actions[PushCenter.no])
        #expect(!no.contains(.authenticationRequired))
        #expect(no.contains(.destructive))
    }

    @Test func aTitleIsSaidInItsOwnLanguageWhenThatIsClear() {
        let dutch = ["nl-NL", "en-NL"]
        #expect(TitleSpeaker.language(of: "Het grote avontuur van de kleine beer", preferred: dutch) == "nl-NL")
        #expect(TitleSpeaker.language(of: "The great adventure of the little bear", preferred: dutch) == "en-NL")
        // A name says nothing.
        #expect(TitleSpeaker.language(of: "Bee", preferred: dutch) == "nl-NL")
    }
}
#endif
