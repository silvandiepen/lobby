// SPDX-License-Identifier: MPL-2.0
import FamilyControls
import ManagedSettings

/// Lock to Lobby with Apple's Screen Time: FamilyControls for the permission, ManagedSettings
/// for the shield (docs/decisions.md, "Lock to Lobby"). Only iPhone and iPad have it; the Mac
/// and the Apple TV build without this file.
///
/// The permission is `.individual`: the device's owner allows it once on this device with Face
/// ID or the passcode. No Family Sharing and no parent's Apple account are needed.
@MainActor
final class ScreenTimeLock: KidsLockSurface {
    /// A store of Lobby's own, so that taking the shield away never touches anything else.
    private let store = ManagedSettingsStore(named: ManagedSettingsStore.Name("mt.sil.lobby.kidsLock"))

    var isAllowed: Bool { AuthorizationCenter.shared.authorizationStatus == .approved }

    func allow() async throws {
        try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
    }

    var isShielding: Bool { store.shield.applicationCategories != nil }

    func shield() {
        // Lobby itself is never shielded by `.all()`: an app is exempt from its own shield.
        store.shield.applicationCategories = .all()
        store.shield.webDomainCategories = .all()
        // So that Lobby cannot be deleted to get out of it.
        store.application.denyAppRemoval = true
    }

    func unshield() {
        store.clearAllSettings()
    }
}
