// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Observation

/// What locks the device to Lobby: Apple's Screen Time frameworks on iPhone and iPad
/// (`iOS/ScreenTimeLock.swift`), a fake in the tests. The simulator has no Screen Time, so
/// everything above this is tested with the fake (docs/decisions.md, "Lock to Lobby").
@MainActor
protocol KidsLockSurface: AnyObject {
    /// A grown-up allowed Lobby to use Screen Time on this device, and has not taken it back.
    var isAllowed: Bool { get }
    /// Asks the system, which asks the device's owner for Face ID or the passcode.
    func allow() async throws
    /// Every other app and website is shielded now. Kept by the system across launches.
    var isShielding: Bool { get }
    /// Shields everything but Lobby.
    func shield()
    /// Takes every shield away.
    func unshield()
}

/// Locks this device to Lobby while a child is in front in kids mode and the lock is wanted for
/// it: by the child's plan, or a grown-up's switch for this device. Leaving kids mode through
/// For Grown-ups lifts it, and coming back puts it on again. One per app, whichever server.
@MainActor
@Observable
final class KidsLock {
    struct State: Hashable, Sendable {
        /// A child is in front in kids mode. nil while the app is starting and does not know
        /// yet: the shield stays as it is, so a launch is no gap in it.
        var inKidsMode: Bool?
        /// The lock is wanted for the child in front, as the server or the signed copy said last.
        var wanted: Bool

        /// The shield is to be up.
        func locks(allowed: Bool) -> Bool { inKidsMode == true && wanted && allowed }
    }

    /// Lobby may use Screen Time here.
    private(set) var isAllowed: Bool
    /// The other apps are shielded now.
    private(set) var isLocked: Bool
    private(set) var isSettingUp = false
    /// Why setting up did not work, for the grown-up who tried.
    var problem: String?
    /// What the app said last.
    private(set) var state: State?

    @ObservationIgnored private let surface: KidsLockSurface

    init(surface: KidsLockSurface) {
        self.surface = surface
        isAllowed = surface.isAllowed
        isLocked = surface.isShielding
    }

    /// What the device tells the server of its lock.
    var status: KidsLockStatus { isAllowed ? .ready : .notSetUp }

    /// The lock is wanted for the child in front, and nobody set it up here yet.
    var needsSetUp: Bool { (state?.wanted ?? false) && !isAllowed }

    /// Follows the app: shields or unshields when what is wanted differs from what is.
    func update(_ state: State) {
        self.state = state
        apply()
    }

    /// The app came to the front: a grown-up may have taken Screen Time away in Settings.
    func refresh() {
        apply()
    }

    /// The one-time setup on the child's device. True when Lobby may lock it now.
    @discardableResult
    func setUp() async -> Bool {
        guard !isSettingUp else { return false }
        isSettingUp = true
        defer { isSettingUp = false }
        problem = nil
        do {
            try await surface.allow()
        } catch {
            problem = "Screen Time was not allowed. \(error.localizedDescription)"
        }
        apply()
        if !isAllowed, problem == nil { problem = "Screen Time was not allowed." }
        return isAllowed
    }

    private func apply() {
        isAllowed = surface.isAllowed
        guard let state, state.inKidsMode != nil else {
            isLocked = surface.isShielding
            return
        }
        let wanted = state.locks(allowed: isAllowed)
        if wanted, !surface.isShielding {
            surface.shield()
        } else if !wanted, surface.isShielding {
            surface.unshield()
        }
        isLocked = surface.isShielding
    }
}

/// What the grown-ups read about one of a child's devices.
enum KidsLockText {
    static let notSetUp = "Lock not set up on this device"

    static func status(_ device: KidsLockDevice) -> String {
        switch device.status {
        case .ready?:
            if device.locked { return "Locked to Lobby" }
            return device.wanted ? "Set up. Locks when kids mode is on." : "Set up. Not locked."
        case .unsupported?:
            return "Only an iPhone or iPad can be locked"
        case .notSetUp?, .unknown?, nil:
            return notSetUp
        }
    }
}
