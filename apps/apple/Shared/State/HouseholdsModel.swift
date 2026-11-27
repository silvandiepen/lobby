// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyDirect
import LobbyKit
import Observation

/// The households that share the server, for a manager of the owner's household: who there is,
/// inviting one, what each may see and use, pausing and removing (docs/api.md, Households).
@MainActor
@Observable
final class HouseholdsModel {
    private(set) var households: [Household] = []
    /// The one whose page is open, with its devices and invitations.
    private(set) var detail: HouseholdDetail?
    /// An invitation just made: its code and link are shown this once.
    private(set) var invitation: Invitation?
    private(set) var isLoading = false
    private(set) var isWorking = false
    /// The server is from before households.
    private(set) var isUnavailable = false
    var problem: String?

    /// What a guest needs, and for which household.
    struct Invitation: Hashable, Identifiable {
        var householdName: String
        var invite: HouseholdInvite
        var id: String { invite.id }

        /// The code as it is typed.
        var code: String { invite.code.map { PairingCode.grouped(PairingCode.clean($0)) } ?? "" }

        /// What a camera reads, or what is sent along: the link, when the server has a direct road.
        var link: String? { invite.link }

        var expires: Date { invite.expiresAt }
    }

    /// What the owner fills in for a new household, or changes of one.
    struct Draft: Hashable {
        var name = ""
        /// The whole library; else only the groups and categories below.
        var wholeLibrary = true
        var groupIDs: Set<String> = []
        var categoryIDs: Set<String> = []
        /// Megabits a second; nil: no cap.
        var maxMbps: Double?
        var allowOutside = true
        var maxDevices: Int?
        /// Its new devices need a server admin's yes too. On unless said otherwise.
        var requiresAdminApproval = true
        var inviteHours = 72

        init() {}

        init(_ household: Household) {
            name = household.name
            wholeLibrary = household.scope == nil
            groupIDs = Set(household.scope?.allowedGroupIds ?? [])
            categoryIDs = Set(household.scope?.allowedCategoryIds ?? [])
            maxMbps = household.maxMbps
            allowOutside = household.allowOutside
            maxDevices = household.maxDevices
            requiresAdminApproval = household.requiresAdminApproval ?? true
        }

        var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

        /// The part of the library, said as kids limits are.
        var scope: KidsSettings? {
            wholeLibrary
                ? nil
                : KidsSettings(
                    allowedGroupIds: groupIDs.sorted(), allowedCategoryIds: categoryIDs.sorted(),
                    knowsBlockedCategories: true)
        }

        var change: HouseholdChange {
            HouseholdChange(
                name: name.trimmingCharacters(in: .whitespaces), scope: scope.map { .set($0) } ?? .clear,
                maxMbps: maxMbps.map { .set($0) } ?? .clear, allowOutside: allowOutside,
                maxDevices: maxDevices.map { .set($0) } ?? .clear, requiresAdminApproval: requiresAdminApproval)
        }
    }

    private let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    /// The guests, without the owner's own household.
    var guests: [Household] { households.filter { !$0.owner } }

    /// "3 devices · 2 viewers · Paused"
    static func caption(_ household: Household) -> String {
        var parts = [
            household.devices == 1 ? "1 device" : "\(household.devices) devices",
            household.viewers == 1 ? "1 viewer" : "\(household.viewers) viewers",
        ]
        if household.devices == 0 { parts = ["Invited, not here yet"] }
        if household.scope != nil { parts.append("Part of the library") }
        if household.paused { parts.append("Paused") }
        return parts.joined(separator: " · ")
    }

    /// "Up to 20 Mbit/s", "No limit"
    static func cap(_ mbps: Double?) -> String {
        guard let mbps else { return "No limit" }
        return "Up to \(mbps.formatted(.number.precision(.fractionLength(0...1)))) Mbit/s"
    }

    func refresh() async {
        guard app.isOwnerManager else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            households = try await app.asManager { try await $0.households() }
            isUnavailable = false
        } catch LobbyError.notFound {
            isUnavailable = true
        } catch {
            problem = await app.managerProblem(error)
        }
    }

    func open(_ id: String) async {
        await perform {
            self.detail = try await self.app.asManager { try await $0.household(id: id) }
        }
    }

    /// Makes the household and its first invitation, which is then shown.
    func invite(_ draft: Draft) async -> Bool {
        var change = draft.change
        change.inviteHours = draft.inviteHours
        var made: InvitedHousehold?
        await perform {
            made = try await self.app.asManager { try await $0.inviteHousehold(change) }
        }
        guard let made else { return false }
        invitation = Invitation(householdName: made.household.name, invite: made.invite)
        await refresh()
        return true
    }

    func save(_ draft: Draft, for id: String) async {
        await perform {
            _ = try await self.app.asManager { try await $0.changeHousehold(id: id, draft.change) }
            self.detail = try await self.app.asManager { try await $0.household(id: id) }
        }
        await refresh()
    }

    func setPaused(_ paused: Bool, id: String) async {
        await perform {
            _ = try await self.app.asManager { try await $0.changeHousehold(id: id, HouseholdChange(paused: paused)) }
            self.detail = try await self.app.asManager { try await $0.household(id: id) }
        }
        await refresh()
    }

    /// Its devices are cut off at once, its viewers removed. The library stays as it is.
    func remove(_ id: String) async -> Bool {
        var done = false
        await perform {
            try await self.app.asManager { try await $0.removeHousehold(id: id) }
            self.detail = nil
            done = true
        }
        await refresh()
        return done
    }

    /// Another device that becomes its manager: for a household that lost theirs.
    func newInvitation(for household: Household, hours: Int = 72) async {
        await perform {
            let invite = try await self.app.asManager { try await $0.newInvite(householdID: household.id, hours: hours) }
            self.invitation = Invitation(householdName: household.name, invite: invite)
            self.detail = try await self.app.asManager { try await $0.household(id: household.id) }
        }
    }

    /// An invitation into this manager's own household.
    func inviteHere(access: DeviceAccess, hours: Int) async -> Bool {
        var made: HouseholdInvite?
        await perform {
            made = try await self.app.asManager { try await $0.inviteToHousehold(access: access, hours: hours) }
        }
        guard let made else { return false }
        invitation = Invitation(householdName: app.household?.name ?? "your household", invite: made)
        return true
    }

    func revoke(_ invite: HouseholdInvite) async {
        await perform {
            try await self.app.asManager { try await $0.revokeInvite(householdID: invite.householdId, inviteID: invite.id) }
            self.detail = try await self.app.asManager { try await $0.household(id: invite.householdId) }
        }
    }

    func dismissInvitation() {
        invitation = nil
    }

    private func perform(_ work: @MainActor () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        problem = nil
        defer { isWorking = false }
        do {
            try await work()
        } catch {
            problem = await app.managerProblem(error)
        }
    }
}
