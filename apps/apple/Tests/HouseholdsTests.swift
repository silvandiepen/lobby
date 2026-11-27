// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyDirect
import LobbyKit
import Testing

@testable import Lobby

/// Households that share one server: the owner's managers invite and limit them; a guest's
/// manager manages their own household only, and is told whose server it is.
@MainActor
@Suite struct HouseholdsTests {
    private static let list = #"{"households":[{"id":"owner","name":"Home","owner":true,"scope":null,"maxMbps":null,"allowOutside":true,"maxDevices":null,"paused":false,"pausedAt":null,"createdAt":1795530000000,"devices":3,"managers":1,"viewers":2},{"id":"h-2","name":"The neighbours","owner":false,"scope":{"allowedGroupIds":["g-small"],"allowedCategoryIds":[],"allowedItemIds":[],"blockedItemIds":[],"blockedCategoryIds":[]},"maxMbps":20,"allowOutside":true,"maxDevices":4,"paused":false,"pausedAt":null,"createdAt":1795530000000,"devices":2,"managers":1,"viewers":3}]}"#

    private func owner() throws -> TestApp {
        let test = try TestApp(Household(.init(
            device: Device(id: "dev-1", name: "Mac", platform: .macos, role: .manager, createdAt: Make.epoch))))
        test.household.change {
            $0.households = Self.list
            $0.household = HouseholdSummary(id: "owner", name: "Home", owner: true)
        }
        return test
    }

    private func guest(role: DeviceRole = .manager) throws -> TestApp {
        var device = Device(id: "g-1", name: "Their phone", platform: .ios, role: role, createdAt: Make.epoch)
        device.householdId = "h-2"
        // As the server says it: a household admin is "viewer" to older apps, "householdAdmin" in access.
        device.access = role == .manager ? .householdAdmin : .viewer
        let test = try TestApp(Household(.init(device: device)))
        test.household.change {
            $0.households = Self.list
            $0.household = HouseholdSummary(id: "h-2", name: "The neighbours", owner: false)
            $0.outsideRequests = #"[{"id":"ask-2","outside":true,"deviceName":"Their TV","platform":"tvos","address":null,"comparison":"482913","createdAt":1795530000000,"expiresAt":4102444800000,"householdId":"h-2","invited":false}]"#
        }
        return test
    }

    @Test func theOwnerSeesTheGuestsAndInvitesOne() async throws {
        let test = try owner()
        let app = try await test.launchPaired(as: "alex")
        #expect(app.isOwnerManager)
        #expect(!app.isGuest)
        let model = HouseholdsModel(app: app)
        await model.refresh()
        #expect(model.guests.map(\.name) == ["The neighbours"])
        let neighbours = try #require(model.guests.first)
        #expect(HouseholdsModel.caption(neighbours) == "2 devices · 3 viewers · Part of the library")
        #expect(HouseholdsModel.cap(neighbours.maxMbps) == "Up to 20 Mbit/s")

        var draft = HouseholdsModel.Draft()
        draft.name = "  The neighbours "
        draft.wholeLibrary = false
        draft.groupIDs = ["g-small"]
        draft.maxMbps = 20
        draft.inviteHours = 168
        #expect(await model.invite(draft))
        let sent = try #require(test.household.current.householdChanges.first)
        let body = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(body["name"] as? String == "The neighbours")
        #expect(body["maxMbps"] as? Double == 20)
        #expect(body["inviteHours"] as? Int == 168)
        #expect(body["maxDevices"] is NSNull)
        let scope = try #require(body["scope"] as? [String: Any])
        #expect(scope["allowedGroupIds"] as? [String] == ["g-small"])

        let invitation = try #require(model.invitation)
        #expect(invitation.code == "0123-4567-89AB-CDEF")
        #expect(invitation.householdName == "The neighbours")
        // What a guest's app reads from the link: the code, and whose household and server.
        let link = try #require(invitation.link)
        let read = try #require(PairingInvitation(link: link))
        #expect(read.code == "0123456789ABCDEF")
        #expect(read.household == "The neighbours")
        #expect(read.server == "Family Pi")
    }

    @Test func aWholeLibraryLiftsTheScope() throws {
        var draft = HouseholdsModel.Draft(
            LobbyKit.Household(id: "h-2", name: "The neighbours", scope: KidsSettings(allowedGroupIds: ["g-small"])))
        #expect(!draft.wholeLibrary)
        #expect(draft.scope?.allowedGroupIds == ["g-small"])
        draft.wholeLibrary = true
        #expect(draft.scope == nil)
        let encoded = try JSONEncoder().encode(draft.change)
        let body = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(body["scope"] is NSNull)
        #expect(body["maxMbps"] is NSNull)
        #expect(body["paused"] == nil)
    }

    @Test func aGuestsManagerManagesTheirOwnHouseholdOnly() async throws {
        let test = try guest()
        let app = try await test.launchPaired(as: "alex")
        #expect(app.isGuest)
        #expect(app.isManager)
        #expect(!app.isOwnerManager)
        #expect(app.household?.name == "The neighbours")

        // Their devices come in from outside, through their own window: no server status.
        let manager = ManagerModel(app: app)
        await manager.refresh()
        #expect(manager.offersOutside)
        #expect(manager.status == nil)
        #expect(manager.problem == nil)
        #expect(test.household.stub.requests("GET", "/v1/status").isEmpty)

        let outside = OutsideModel(app: app)
        await outside.refresh()
        #expect(outside.isGuest)
        #expect(!outside.isUnavailable)
        #expect(test.household.stub.requests("GET", "/v1/outside").isEmpty)
        #expect(outside.requests.map(\.deviceName) == ["Their TV"])
        await outside.openWindow()
        #expect(outside.invitation?.code == "0123456789ABCDEF")
        let request = try #require(outside.requests.first)
        await outside.approve(request)
        #expect(outside.problem == nil)
        #expect(outside.lastApproval == "“Their TV” was let in as a viewer.")

        // The households are the owner's.
        let households = HouseholdsModel(app: app)
        await households.refresh()
        #expect(households.households.isEmpty)
        #expect(test.household.stub.requests("GET", "/v1/households").isEmpty)
    }

    @Test func aGuestsViewerIsAViewer() async throws {
        let test = try guest(role: .viewer)
        let app = try await test.launchPaired(as: "alex")
        #expect(app.isGuest)
        #expect(!app.isManager)
        #expect(!app.isOwnerManager)
    }

    @Test func aHouseholdAdminAtHomeSetsUpTheirHouseholdAndNotTheServer() async throws {
        var device = Device(id: "dev-1", name: "Parent's iPad", platform: .ipados, role: .viewer, createdAt: Make.epoch)
        device.householdId = "owner"
        device.access = .householdAdmin
        let test = try TestApp(Household(.init(device: device)))
        test.household.change {
            $0.households = Self.list
            $0.household = HouseholdSummary(id: "owner", name: "Home", owner: true)
        }
        let app = try await test.launchPaired(as: "alex")
        #expect(app.isManager)
        #expect(!app.isOwnerManager)
        #expect(!app.isGuest)
        let manager = ManagerModel(app: app)
        #expect(manager.grantable == [.viewer, .householdAdmin])
        await manager.refresh()
        #expect(test.household.stub.requests("GET", "/v1/status").isEmpty)
        #expect(manager.offersOutside)

        // Invites into this household, as a viewer.
        let invites = HouseholdsModel(app: app)
        #expect(await invites.inviteHere(access: .viewer, hours: 24))
        let sent = try #require(test.household.current.householdChanges.last)
        let body = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(body["access"] as? String == "viewer")
        #expect(body["inviteHours"] as? Int == 24)
        #expect(invites.invitation?.code == "0123-4567-89AB-CDEF")
        // The households are a server admin's.
        await invites.refresh()
        #expect(test.household.stub.requests("GET", "/v1/households").isEmpty)
    }

    @Test func anApprovalThatWaitsForTheServerOwnerSaysSo() throws {
        let json = #"{"deviceName":"Their TV","platform":"tvos","role":"viewer","access":"viewer","awaitsAdmin":true}"#
        let approval = try LobbyJSON.decoder().decode(PairingApproval.self, from: Data(json.utf8))
        #expect(ManagerModel.approved(approval) == "“Their TV” waits for the server owner to approve it too.")
        let done = #"{"deviceName":"Their TV","platform":"tvos","role":"viewer","access":"householdAdmin","awaitsAdmin":false}"#
        let final = try LobbyJSON.decoder().decode(PairingApproval.self, from: Data(done.utf8))
        #expect(ManagerModel.approved(final) == "Approved “Their TV” as a household admin.")
        var draft = HouseholdsModel.Draft()
        #expect(draft.requiresAdminApproval)
        draft.requiresAdminApproval = false
        let encoded = try JSONEncoder().encode(draft.change)
        let sent = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(sent["requiresAdminApproval"] as? Bool == false)
    }

    @Test func whatADeviceMayDoReadsAlsoFromAnOlderServer() throws {
        func level(_ json: String) throws -> DeviceAccess {
            try LobbyJSON.decoder().decode(Device.self, from: Data(json.utf8)).level
        }
        let base = #""id":"d","name":"TV","platform":"tvos","createdAt":1795530000000,"lastUsedAt":null,"revokedAt":null"#
        #expect(try level("{\(base),\"role\":\"manager\"}") == .admin)
        #expect(try level("{\(base),\"role\":\"viewer\"}") == .viewer)
        #expect(try level("{\(base),\"role\":\"viewer\",\"access\":\"householdAdmin\"}") == .householdAdmin)
        // Something this app does not know is nothing more than watching.
        #expect(try level("{\(base),\"role\":\"manager\",\"access\":\"superuser\"}") == .viewer)
    }

    @Test func aDeviceFromBeforeHouseholdsIsTheOwners() throws {
        let json = #"{"id":"d","name":"TV","platform":"tvos","role":"manager","createdAt":1795530000000,"lastUsedAt":null,"revokedAt":null}"#
        let device = try LobbyJSON.decoder().decode(Device.self, from: Data(json.utf8))
        #expect(device.householdId == nil)
        let guest = #"{"id":"d","name":"TV","platform":"tvos","role":"viewer","createdAt":1795530000000,"lastUsedAt":null,"revokedAt":null,"householdId":"h-2"}"#
        #expect(try LobbyJSON.decoder().decode(Device.self, from: Data(guest.utf8)).householdId == "h-2")
    }

    @Test func anInvitationSaysWhoseHouseholdItJoins() throws {
        let test = try owner()
        let connect = ConnectModel(app: test.launch())
        connect.useInvitation("lobby://pair?i=wss%3A%2F%2Fintroducer.example.com&c=0123-4567-89AB-CDEF&h=The%20neighbours&s=Family%20Pi")
        #expect(connect.joiningText == "You are joining **The neighbours**, on Family Pi.")
        connect.useInvitation("lobby://pair?i=wss://introducer.example.com&c=0123456789ABCDEF")
        #expect(connect.joiningText == nil)
    }
}
