// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

/// Screen Time as the tests play it: the simulator has none, so the real shield is checked on a
/// device (docs/apple-apps.md, "Lock to Lobby").
@MainActor
final class FakeLockSurface: KidsLockSurface {
    var isAllowed: Bool
    /// What the grown-up does when the system asks: allow, or cancel.
    var grownUpAllows = true
    private(set) var isShielding: Bool
    private(set) var shields = 0
    private(set) var unshields = 0

    init(allowed: Bool = true, shielding: Bool = false) {
        isAllowed = allowed
        isShielding = shielding
    }

    struct Cancelled: LocalizedError {
        var errorDescription: String? { "The grown-up cancelled." }
    }

    func allow() async throws {
        guard grownUpAllows else { throw Cancelled() }
        isAllowed = true
    }

    func shield() {
        isShielding = true
        shields += 1
    }

    func unshield() {
        isShielding = false
        unshields += 1
    }
}

/// Lock to Lobby (docs/decisions.md, "Lock to Lobby"): on only while a child is in front in kids
/// mode, it is wanted, and Screen Time was allowed here.
@MainActor
@Suite struct KidsLockTests {
    private typealias State = KidsLock.State

    @Test func locksOnlyAChildInKidsModeWithTheLockWantedAndAllowed() {
        for (inKidsMode, wanted, allowed, locks) in [
            (true, true, true, true),
            (false, true, true, false),
            (true, false, true, false),
            (true, true, false, false),
        ] {
            let surface = FakeLockSurface(allowed: allowed)
            let lock = KidsLock(surface: surface)
            lock.update(State(inKidsMode: inKidsMode, wanted: wanted))
            #expect(surface.isShielding == locks, "kids mode \(inKidsMode), wanted \(wanted), allowed \(allowed)")
            #expect(lock.isLocked == locks)
        }
    }

    @Test func leavingKidsModeLiftsItAndComingBackPutsItOnAgain() {
        let surface = FakeLockSurface()
        let lock = KidsLock(surface: surface)
        lock.update(State(inKidsMode: true, wanted: true))
        #expect(lock.isLocked)
        // For Grown-ups passed: a grown-up is in front.
        lock.update(State(inKidsMode: false, wanted: true))
        #expect(!lock.isLocked)
        #expect(surface.unshields == 1)
        // Who is watching closed without a choice: kids mode again.
        lock.update(State(inKidsMode: true, wanted: true))
        #expect(lock.isLocked)
        #expect(surface.shields == 2)
        // The same again asks the system for nothing.
        lock.update(State(inKidsMode: true, wanted: true))
        #expect(surface.shields == 2)
    }

    @Test func followsASwitchFromTheParentsPhone() {
        let surface = FakeLockSurface()
        let lock = KidsLock(surface: surface)
        lock.update(State(inKidsMode: true, wanted: false))
        #expect(!lock.isLocked)
        lock.update(State(inKidsMode: true, wanted: true))
        #expect(lock.isLocked)
        lock.update(State(inKidsMode: true, wanted: false))
        #expect(!lock.isLocked)
    }

    @Test func aLaunchIsNoGapInTheShield() {
        // The system kept the shield from before; the app does not know yet who is in front.
        let surface = FakeLockSurface(shielding: true)
        let lock = KidsLock(surface: surface)
        #expect(lock.isLocked)
        lock.update(State(inKidsMode: nil, wanted: false))
        #expect(surface.isShielding)
        #expect(surface.unshields == 0)
        // Once it knows a grown-up is in front, it goes.
        lock.update(State(inKidsMode: false, wanted: false))
        #expect(!surface.isShielding)
    }

    @Test func notSetUpNeverShieldsAndSaysSoUntilAGrownUpAllowsIt() async {
        let surface = FakeLockSurface(allowed: false)
        let lock = KidsLock(surface: surface)
        lock.update(State(inKidsMode: true, wanted: true))
        #expect(!lock.isLocked)
        #expect(lock.status == .notSetUp)
        #expect(lock.needsSetUp)
        // Cancelled: still nothing, and the grown-up reads why.
        surface.grownUpAllows = false
        #expect(await lock.setUp() == false)
        #expect(!lock.isLocked)
        #expect(lock.problem != nil)
        // Allowed: locked at once, in kids mode.
        surface.grownUpAllows = true
        #expect(await lock.setUp())
        #expect(lock.isLocked)
        #expect(lock.status == .ready)
        #expect(lock.problem == nil)
        #expect(!lock.needsSetUp)
    }

    @Test func screenTimeTakenAwayInSettingsLiftsTheShield() {
        let surface = FakeLockSurface()
        let lock = KidsLock(surface: surface)
        lock.update(State(inKidsMode: true, wanted: true))
        #expect(lock.isLocked)
        surface.isAllowed = false
        lock.refresh()
        #expect(!lock.isLocked)
        #expect(lock.status == .notSetUp)
    }

    @Test func saysToTheGrownUpsWhatADeviceSaid() {
        func device(_ status: KidsLockStatus?, locked: Bool = false, wanted: Bool = true) -> KidsLockDevice {
            KidsLockDevice(deviceId: "tablet", name: "Tablet", wanted: wanted, status: status, locked: locked)
        }
        #expect(KidsLockText.status(device(nil)) == "Lock not set up on this device")
        #expect(KidsLockText.status(device(.notSetUp)) == "Lock not set up on this device")
        #expect(KidsLockText.status(device(.ready, locked: true)) == "Locked to Lobby")
        #expect(KidsLockText.status(device(.ready)) == "Set up. Locks when kids mode is on.")
        #expect(KidsLockText.status(device(.ready, wanted: false)) == "Set up. Not locked.")
        #expect(KidsLockText.status(device(.unsupported)) == "Only an iPhone or iPad can be locked")
    }

    // MARK: What is wanted, from the server and offline

    private static func me(lock: KidsLockWish?) -> KidsMe {
        KidsMe(
            profileId: "kid",
            now: KidsNow(at: KidsModeAt(mode: .everything, reason: .default, browse: true, video: .all, listening: true)),
            plan: KidsPlan(lockToLobby: lock?.wanted ?? false), timeZone: "Europe/Amsterdam", request: nil,
            signed: SignedKidsPlan(payload: "", signature: ""), publicKey: "", serverTime: 0, lock: lock)
    }

    @Test func wantsWhatTheServerSaidLastAndKeepsItOffline() {
        let model = KidsControlModel()
        #expect(!model.lockWanted)
        model.update(Self.me(lock: KidsLockWish(wanted: true)), deviceID: "tablet")
        #expect(model.lockWanted)
        // Switched off from a parent's phone, on the live channel.
        #expect(model.heard(lock: false))
        #expect(!model.lockWanted)
        #expect(!model.heard(lock: false))
        // A server from before the lock says nothing on the channel: nothing changes.
        #expect(!model.heard(lock: nil))
        #expect(model.heard(lock: true))
        // Offline without a signed copy: what it heard last holds.
        model.wentOffline()
        #expect(model.lockWanted)
        // A server from before the lock: there is none.
        model.update(Self.me(lock: nil), deviceID: "tablet")
        #expect(!model.lockWanted)
    }
}

/// Lock to Lobby in the app model, against the HTTP stub of the server.
@MainActor
@Suite struct KidsLockAppTests {
    private func household(lock: Bool, bound: String? = nil) -> Household {
        Household(.init(
            device: Device(
                id: "dev-1", name: "Tablet", platform: .ipados, role: .viewer, createdAt: Make.epoch, kidsProfileId: bound,
                saysKidsProfile: true),
            profiles: [
                Profile(id: "adult", name: "Adult", color: "blue", saysKids: true),
                Profile(id: "kid", name: "Kid", color: "green", kids: KidsSettings(), saysKids: true),
            ],
            knowsKids: true,
            kidsMe: KidsMe(
                profileId: "kid",
                now: KidsNow(at: KidsModeAt(mode: .everything, reason: .default, browse: true, video: .all, listening: true)),
                plan: KidsPlan(lockToLobby: lock), timeZone: "Europe/Amsterdam", request: nil,
                signed: SignedKidsPlan(payload: "", signature: ""), publicKey: "", serverTime: 0,
                lock: KidsLockWish(wanted: lock))))
    }

    private func testApp(_ household: Household, surface: FakeLockSurface, check: GrownUpCheck = .confirmed) throws -> TestApp {
        let test = try TestApp(household)
        test.environment.hasKidsScreens = true
        test.environment.confirmGrownUp = { check }
        test.environment.kidsLock = KidsLock(surface: surface)
        return test
    }

    @Test func locksInKidsModeAndForGrownUpsLiftsIt() async throws {
        let household = household(lock: true)
        let surface = FakeLockSurface()
        let app = try await testApp(household, surface: surface).launchPaired(as: "kid")
        await app.applyKidsLock()
        #expect(surface.isShielding)
        #expect(household.current.kidsLockReports.last == KidsLockReport(status: "ready", locked: true, profileID: "kid"))

        // For Grown-ups: the shield goes while Who is watching is up.
        await app.askToLeaveKidsMode()
        #expect(app.phase == .chooseProfile)
        #expect(app.kidsLockState.inKidsMode == false)
        await app.applyKidsLock()
        #expect(!surface.isShielding)
        #expect(household.current.kidsLockReports.last?.locked == false)

        // Closed without a choice: kids mode again, and the lock with it.
        await app.enteredBackground()
        #expect(app.phase == .library)
        await app.applyKidsLock()
        #expect(surface.isShielding)

        // A grown-up chosen: grown-up mode never locks.
        await app.askToLeaveKidsMode()
        await app.selectProfile(try #require(app.profiles.first { $0.id == "adult" }))
        await app.applyKidsLock()
        #expect(!app.isKidsMode)
        #expect(!surface.isShielding)
    }

    @Test func followsTheSwitchOnTheLiveChannel() async throws {
        let household = household(lock: false, bound: "kid")
        let surface = FakeLockSurface()
        let app = try await testApp(household, surface: surface).launchPaired()
        await app.applyKidsLock()
        #expect(!surface.isShielding)
        // The parent switches it on; the server says so with the plan too from now on.
        household.change { $0.kidsMe?.lock = KidsLockWish(wanted: true, source: .device) }
        let now = KidsNow(at: KidsModeAt(mode: .everything, reason: .default, browse: true, video: .all, listening: true))
        await app.kidsHeard(.kidsMode(profileID: "kid", now: now, lock: true))
        #expect(surface.isShielding)
        // And off again.
        household.change { $0.kidsMe?.lock = KidsLockWish(wanted: false, source: .device) }
        await app.kidsHeard(.kidsMode(profileID: "kid", now: now, lock: false))
        #expect(!surface.isShielding)
    }

    @Test func aSwitchMadeWhileOfflineAppliesWhenTheServerIsBack() async throws {
        let household = household(lock: false, bound: "kid")
        let surface = FakeLockSurface()
        let app = try await testApp(household, surface: surface).launchPaired()
        await app.applyKidsLock()
        #expect(!surface.isShielding)
        household.change { $0.offline = true }
        await app.refresh()
        #expect(!surface.isShielding)
        // Switched on while the tablet could not hear it.
        household.change {
            $0.kidsMe?.lock = KidsLockWish(wanted: true, source: .device)
            $0.offline = false
        }
        await app.refresh()
        #expect(surface.isShielding)
    }

    @Test func notSetUpIsWhatTheGrownUpsAreTold() async throws {
        let household = household(lock: true, bound: "kid")
        let surface = FakeLockSurface(allowed: false)
        let app = try await testApp(household, surface: surface).launchPaired()
        await app.applyKidsLock()
        #expect(!surface.isShielding)
        #expect(household.current.kidsLockReports.last == KidsLockReport(status: "notSetUp", locked: false, profileID: nil))
        // The bound device's one-time setup, past the grown-up's check.
        await app.askToLeaveKidsMode()
        #expect(app.grownUpNotice == .bound)
        #expect(await app.setUpKidsLock())
        #expect(surface.isShielding)
        #expect(household.current.kidsLockReports.last == KidsLockReport(status: "ready", locked: true, profileID: nil))
    }
}
