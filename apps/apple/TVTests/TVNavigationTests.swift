// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

@MainActor
@Suite struct FocusKeeperTests {
    private let rows: [FocusMemory.Row] = [.init(shelf: "continue", items: ["a", "b"]), .init(shelf: "movies", items: ["x", "y"])]

    @Test func whatHadTheRemoteGetsItBackOnlyWhenNothingHasIt() {
        let keeper = FocusKeeper()
        keeper.rows = rows
        keeper.took(TVFocusID(shelf: "movies", item: "y"))
        // Something has it: nothing is taken from it.
        #expect(keeper.restore() == nil)
        keeper.left(TVFocusID(shelf: "movies", item: "y"))
        #expect(keeper.restore() == TVFocusID(shelf: "movies", item: "y"))
        #expect(keeper.wanted == TVFocusID(shelf: "movies", item: "y"))
        // Taken: the wish is over.
        keeper.took(TVFocusID(shelf: "movies", item: "y"))
        #expect(keeper.wanted == nil)
    }

    @Test func leavingAnotherTileKeepsTheCurrentOne() {
        let keeper = FocusKeeper()
        keeper.took(TVFocusID(shelf: "movies", item: "x"))
        keeper.took(TVFocusID(shelf: "movies", item: "y"))
        keeper.left(TVFocusID(shelf: "movies", item: "x"))
        #expect(keeper.current == TVFocusID(shelf: "movies", item: "y"))
    }

    @Test func aFilmFromTheBannerSendsNoTileAnywhere() {
        let keeper = FocusKeeper()
        keeper.rows = rows
        keeper.took(TVFocusID(shelf: "continue", item: "b"))
        keeper.left(TVFocusID(shelf: "continue", item: "b"))
        keeper.forget()
        #expect(keeper.restore() == nil)
    }

    @Test func aTitleThatMovedIsFoundWhereItIsNow() {
        let keeper = FocusKeeper()
        keeper.rows = rows
        keeper.took(TVFocusID(shelf: "continue", item: "b"))
        keeper.left(TVFocusID(shelf: "continue", item: "b"))
        keeper.rows = [.init(shelf: "continue", items: ["b", "a"])]
        #expect(keeper.restore() == TVFocusID(shelf: "continue", item: "b"))
    }
}

@Suite struct TVPlacesTests {
    @Test func theViewerComesFirstAndAChildHasNoSearch() {
        #expect(TVTab.all(for: LibraryShelves()).first == .viewer)
        #expect(TVTab.kids(for: .empty) == [.viewer, .home])
        #expect(!TVTab.kids(for: .empty).contains(.search))
    }

    @Test func theCodeIsFourDigits() {
        var entry = CodeEntry()
        for digit in [1, 2, 12, -1, 3] { entry.add(digit) }
        #expect(entry.digits == "123")
        entry.add(4)
        entry.add(5)
        #expect(entry.digits == "1234")
        #expect(entry.isComplete)
        entry.delete()
        #expect(entry.digits == "123")
        entry.clear()
        entry.delete()
        #expect(entry.digits.isEmpty)
    }

    @Test func eachAnswerSaysWhatToDo() {
        #expect(KidsCodeCheck.confirmed.explanation == nil)
        #expect(KidsCodeCheck.locked(seconds: 61).explanation?.contains("2 min") == true)
        #expect(KidsCodeCheck.noCode.explanation?.contains("manager") == true)
        #expect(KidsCodeCheck.bound.explanation?.contains("manager") == true)
    }
}

@Suite struct ViewerQuestionTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func eachTimeIsEveryStartAndEveryReturnAfterAWhile() {
        #expect(ViewerQuestion.eachTime.asks(isLaunch: true, lastUsed: now, now: now))
        #expect(!ViewerQuestion.eachTime.asks(isLaunch: false, lastUsed: now.addingTimeInterval(-60), now: now))
        #expect(ViewerQuestion.eachTime.asks(isLaunch: false, lastUsed: now.addingTimeInterval(-ViewerQuestion.glance), now: now))
    }

    @Test func afterHoursCountsTheTimeAway() {
        #expect(!ViewerQuestion.afterFourHours.asks(isLaunch: true, lastUsed: now.addingTimeInterval(-3 * 3_600), now: now))
        #expect(ViewerQuestion.afterFourHours.asks(isLaunch: true, lastUsed: now.addingTimeInterval(-4 * 3_600), now: now))
        #expect(ViewerQuestion.afterOneHour.asks(isLaunch: true, lastUsed: nil, now: now))
        #expect(!ViewerQuestion.never.asks(isLaunch: true, lastUsed: nil, now: now))
    }
}

/// Who is watching, and the way out of kids mode, as the Apple TV runs them.
@MainActor
@Suite struct TVViewerTests {
    private func household(code: String? = "2468", bound: String? = nil) -> Household {
        Household(.init(
            device: Device(
                id: "dev-1", name: "Apple TV", platform: .tvos, role: .viewer, createdAt: Make.epoch, kidsProfileId: bound,
                saysKidsProfile: true),
            profiles: [
                Profile(id: "adult", name: "Adult", color: "blue", saysKids: true),
                Profile(id: "other", name: "Other", color: "red", saysKids: true),
                Profile(id: "kid", name: "Kid", color: "green", kids: KidsSettings(allowedItemIds: ["up"]), saysKids: true),
            ],
            knowsKids: true,
            items: [Make.movie("up", title: "Up"), Make.movie("grown", title: "Grown")],
            kidsCode: code))
    }

    private func test(_ household: Household, question: ViewerQuestion = .eachTime) throws -> TestApp {
        let test = try TestApp(household)
        test.environment.keepsDownloads = false
        test.environment.hasKidsScreens = true
        test.environment.asksWhoIsWatching = true
        test.environment.device = DeviceIdentity(name: "Apple TV", platform: .tvos)
        test.environment.settings.viewerQuestion = question
        return test
    }

    @Test func theTVAsksWhoIsWatchingAtStartAndBackGoesToTheLastViewer() async throws {
        let app = try await test(household()).launchPaired(as: "adult")
        #expect(app.phase == .chooseProfile)
        #expect(app.activeProfile?.id == "adult")
        app.returnToLibrary()
        #expect(app.phase == .library)
        #expect(app.activeProfile?.id == "adult")
    }

    @Test func neverAsksOnlyWhenNobodyWatches() async throws {
        let test = try test(household(), question: .never)
        #expect(test.environment.settings.viewerQuestion == .never)
        let app = try await test.launchPaired(as: "adult")
        #expect(app.activeProfile?.id == "adult")
        #expect(app.phase == .library)
        app.cameBack()
        #expect(app.phase == .library)
    }

    @Test func aChildIsNeverAskedAndCannotSkipThePicker() async throws {
        let app = try await test(household()).launchPaired(as: "kid")
        #expect(app.phase == .library)
        #expect(app.showsKidsScreens)
        #expect(app.item("grown") == nil)
        app.chooseAnotherProfile()
        #expect(app.phase == .library)
    }

    @Test func theRightCodeLeadsToThePickerAndAWrongOneNowhere() async throws {
        let household = household()
        let app = try await test(household).launchPaired(as: "kid")
        #expect(try await app.hasKidsCode())
        #expect(await app.leaveKidsMode(code: "1111") == .wrong)
        #expect(app.phase == .library)
        #expect(await app.leaveKidsMode(code: "2468") == .confirmed)
        #expect(app.phase == .chooseProfile)
        // Not chosen yet: still the child's, and Back is back to the kids pages.
        #expect(app.showsKidsScreens)
        app.returnToLibrary()
        #expect(app.phase == .library)
        #expect(app.showsKidsScreens)
    }

    @Test func tooManyWrongCodesLockTheDoor() async throws {
        let household = household()
        household.change { $0.wrongKidsCodes = 5 }
        let app = try await test(household).launchPaired(as: "kid")
        guard case .locked = await app.leaveKidsMode(code: "2468") else {
            Issue.record("Not locked")
            return
        }
        #expect(app.phase == .library)
    }

    @Test func withoutACodeOrTheServerNobodyLeaves() async throws {
        let none = household(code: nil)
        var app = try await test(none).launchPaired(as: "kid")
        #expect(try await app.hasKidsCode() == false)
        #expect(await app.leaveKidsMode(code: "2468") == .noCode)
        #expect(app.phase == .library)

        let offline = household()
        app = try await test(offline).launchPaired(as: "kid")
        offline.change { $0.offline = true }
        #expect(await app.leaveKidsMode(code: "2468") == .unreachable)
        #expect(app.phase == .library)
        #expect(app.showsKidsScreens)
    }

    @Test func aBoundTVCannotBeLeft() async throws {
        let app = try await test(household(bound: "kid")).launchPaired()
        #expect(app.showsKidsScreens)
        #expect(await app.leaveKidsMode(code: "2468") == .bound)
        #expect(app.phase == .library)
    }
}
