// SPDX-License-Identifier: MPL-2.0
import LobbyKit

/// Which statistics this device offers (docs/decisions.md, "Who sees which statistics"). A
/// server admin: every viewer of every household and the server's page. A household admin:
/// their household's viewers and its overview. Anyone else: only the viewer in front. Kids
/// mode: none. The server refuses the rest too; this keeps the app from offering it.
struct StatsAccess: Equatable, Sendable {
    var level: DeviceAccess
    /// A kids device, or a kids viewer in front on a grown-up's.
    var isKidsMode: Bool
    /// The viewer in front on this device.
    var viewerID: String?
    /// The household this device is in.
    var householdID: String

    /// "Your Month in Lobby" in the viewer menu and in Settings.
    var showsOwn: Bool { !isKidsMode && viewerID != nil }

    /// The household's overview, for its admins. A server admin has the server's page, which
    /// opens any household.
    var showsHouseholdOverview: Bool { !isKidsMode && level == .householdAdmin }

    var showsServerPage: Bool { !isKidsMode && level == .admin }

    /// Whether a viewer's page may be opened. `kids`: the viewer is a child.
    func mayOpen(viewerID id: String, kids: Bool, householdID household: String? = nil) -> Bool {
        guard !isKidsMode else { return false }
        switch level {
        case .admin:
            return true
        case .householdAdmin:
            return (household ?? householdID) == householdID
        case .viewer, .unknown:
            return !kids && id == viewerID && (household ?? householdID) == householdID
        }
    }

    /// Taking a sitting out of a history goes as seeing it.
    func mayRemove(viewerID id: String, kids: Bool, householdID household: String? = nil) -> Bool {
        mayOpen(viewerID: id, kids: kids, householdID: household)
    }

    /// Forgetting a viewer's whole history: the household's admins and the server admins.
    var mayForget: Bool { !isKidsMode && (level == .admin || level == .householdAdmin) }
}
