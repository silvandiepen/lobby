// SPDX-License-Identifier: MPL-2.0
import Foundation

// The households that share one server (`/v1/household…`), as `docs/api.md` ("Households")
// describes them. The owner's managers see and change all of them; every device reads its own.

/// The household a device is in, as `GET /v1/me` says it.
public struct HouseholdSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// The server owner's own household.
    public var owner: Bool

    public init(id: String, name: String, owner: Bool) {
        self.id = id
        self.name = name
        self.owner = owner
    }

    /// The id of the server owner's household.
    public static let ownerID = "owner"
}

/// A household as the owner's managers see it.
public struct Household: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var owner: Bool
    /// What of the library it sees, said as kids limits are; nil: all of it.
    public var scope: KidsSettings?
    /// What all its devices are sent together; nil: no cap.
    public var maxMbps: Double?
    /// Its devices come in from outside.
    public var allowOutside: Bool
    public var maxDevices: Int?
    /// A new device needs a server admin's yes too. nil from a server from before.
    public var requiresAdminApproval: Bool?
    public var paused: Bool
    public var createdAt: Date
    public var devices: Int
    public var managers: Int
    public var viewers: Int

    public init(
        id: String, name: String, owner: Bool = false, scope: KidsSettings? = nil, maxMbps: Double? = nil,
        allowOutside: Bool = true, maxDevices: Int? = nil, paused: Bool = false, createdAt: Date = Date(),
        devices: Int = 0, managers: Int = 0, viewers: Int = 0
    ) {
        self.id = id
        self.name = name
        self.owner = owner
        self.scope = scope
        self.maxMbps = maxMbps
        self.allowOutside = allowOutside
        self.maxDevices = maxDevices
        self.paused = paused
        self.createdAt = createdAt
        self.devices = devices
        self.managers = managers
        self.viewers = viewers
    }

    public var summary: HouseholdSummary { HouseholdSummary(id: id, name: name, owner: owner) }
}

/// An invitation for one device of a household. `code` and `link` only in the answer that made it.
public struct HouseholdInvite: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var householdId: String
    /// What its device becomes.
    public var access: DeviceAccess?
    public var createdAt: Date
    public var expiresAt: Date
    public var usedAt: Date?
    public var revokedAt: Date?
    /// `XXXX-XXXX-XXXX-XXXX`, shown once.
    public var code: String?
    public var introducer: String?
    /// `lobby://pair?…`, for a QR code and to send along.
    public var link: String?

    public init(
        id: String, householdId: String, createdAt: Date = Date(), expiresAt: Date, usedAt: Date? = nil,
        revokedAt: Date? = nil, code: String? = nil, introducer: String? = nil, link: String? = nil
    ) {
        self.id = id
        self.householdId = householdId
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.usedAt = usedAt
        self.revokedAt = revokedAt
        self.code = code
        self.introducer = introducer
        self.link = link
    }

    /// It can still bring a device in.
    public func isOpen(at now: Date = Date()) -> Bool { usedAt == nil && revokedAt == nil && expiresAt > now }
}

/// `GET /v1/households/{id}`.
public struct HouseholdDetail: Codable, Hashable, Sendable {
    public struct Member: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var platform: DevicePlatform
        public var role: DeviceRole
        public var access: DeviceAccess?
        public var createdAt: Date
        public var lastUsedAt: Date?
        public var lastOutsideAt: Date?
    }

    public var household: Household
    public var devices: [Member]
    public var invites: [HouseholdInvite]
}

/// What the owner sets of a guest household. What is nil stays as it is; a `.clear` lifts a limit.
public struct HouseholdChange: Encodable, Hashable, Sendable {
    public enum Limit<Value: Encodable & Hashable & Sendable>: Hashable, Sendable {
        case keep
        case clear
        case set(Value)
    }

    public var name: String?
    public var scope: Limit<KidsSettings> = .keep
    public var maxMbps: Limit<Double> = .keep
    public var allowOutside: Bool?
    public var maxDevices: Limit<Int> = .keep
    public var paused: Bool?
    public var requiresAdminApproval: Bool?
    /// Only when a household is invited: how long the invitation lasts.
    public var inviteHours: Int?

    public init(
        name: String? = nil, scope: Limit<KidsSettings> = .keep, maxMbps: Limit<Double> = .keep,
        allowOutside: Bool? = nil, maxDevices: Limit<Int> = .keep, paused: Bool? = nil,
        requiresAdminApproval: Bool? = nil, inviteHours: Int? = nil
    ) {
        self.requiresAdminApproval = requiresAdminApproval
        self.name = name
        self.scope = scope
        self.maxMbps = maxMbps
        self.allowOutside = allowOutside
        self.maxDevices = maxDevices
        self.paused = paused
        self.inviteHours = inviteHours
    }

    private enum CodingKeys: String, CodingKey {
        case name, scope, maxMbps, allowOutside, maxDevices, paused, requiresAdminApproval, inviteHours
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        func put<Value>(_ limit: Limit<Value>, _ key: CodingKeys) throws {
            switch limit {
            case .keep: break
            case .clear: try container.encodeNil(forKey: key)
            case .set(let value): try container.encode(value, forKey: key)
            }
        }
        try container.encodeIfPresent(name, forKey: .name)
        try put(scope, .scope)
        try put(maxMbps, .maxMbps)
        try container.encodeIfPresent(allowOutside, forKey: .allowOutside)
        try put(maxDevices, .maxDevices)
        try container.encodeIfPresent(paused, forKey: .paused)
        try container.encodeIfPresent(requiresAdminApproval, forKey: .requiresAdminApproval)
        try container.encodeIfPresent(inviteHours, forKey: .inviteHours)
    }
}

/// `POST /v1/households`.
public struct InvitedHousehold: Codable, Hashable, Sendable {
    public var household: Household
    public var invite: HouseholdInvite
}

extension LobbyClient {
    /// `GET /v1/household`: the device's own.
    public func myHousehold() async throws -> Household {
        struct Answer: Decodable { var household: Household }
        let answer: Answer = try await get(["household"])
        return answer.household
    }

    /// `GET /v1/households`. The owner's managers.
    public func households() async throws -> [Household] {
        struct Answer: Decodable { var households: [Household] }
        var request = request("GET", ["households"])
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await perform(request)
        let answer: Answer = try decode(data)
        return answer.households
    }

    /// `GET /v1/households/{id}`. The owner's managers.
    public func household(id: String) async throws -> HouseholdDetail {
        var request = request("GET", ["households", id])
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await perform(request)
        return try decode(data)
    }

    /// `POST /v1/households`. Makes the household and an invitation for its first device.
    public func inviteHousehold(_ change: HouseholdChange) async throws -> InvitedHousehold {
        try await send("POST", ["households"], body: change)
    }

    /// `PATCH /v1/households/{id}`.
    public func changeHousehold(id: String, _ change: HouseholdChange) async throws -> Household {
        try await send("PATCH", ["households", id], body: change)
    }

    /// `DELETE /v1/households/{id}`: its devices are removed at once, with its viewers.
    public func removeHousehold(id: String) async throws {
        try await sendDiscardingAnswer("DELETE", ["households", id])
    }

    /// `POST /v1/households/{id}/invites`: one more device of that household. Server admins.
    public func newInvite(householdID: String, access: DeviceAccess = .householdAdmin, hours: Int? = nil) async throws -> HouseholdInvite {
        struct Body: Encodable {
            var access: DeviceAccess
            var inviteHours: Int?
        }
        return try await send("POST", ["households", householdID, "invites"], body: Body(access: access, inviteHours: hours))
    }

    /// `POST /v1/household/invites`: one more device of this manager's own household.
    public func inviteToHousehold(access: DeviceAccess, hours: Int? = nil) async throws -> HouseholdInvite {
        struct Body: Encodable {
            var access: DeviceAccess
            var inviteHours: Int?
        }
        return try await send("POST", ["household", "invites"], body: Body(access: access, inviteHours: hours))
    }

    /// `PATCH /v1/devices/{id}` with only `access`. Up to the manager's own.
    public func setAccess(_ access: DeviceAccess, deviceID: String) async throws -> Device {
        struct Body: Encodable { var access: DeviceAccess }
        return try await send("PATCH", ["devices", deviceID], body: Body(access: access))
    }

    /// `POST /v1/pairing/approve` with what the device becomes; a server admin's yes to one that
    /// waits for them takes only its id.
    public func approvePairing(requestID: String, access: DeviceAccess?) async throws -> PairingApproval {
        struct Body: Encodable {
            var requestId: String
            var access: DeviceAccess?
        }
        return try await send("POST", ["pairing", "approve"], body: Body(requestId: requestID, access: access))
    }

    /// `POST /v1/pairing/approve` for a typed code, with what the device becomes.
    public func approvePairing(code: String, access: DeviceAccess) async throws -> PairingApproval {
        struct Body: Encodable {
            var code: String
            var access: DeviceAccess
        }
        return try await send("POST", ["pairing", "approve"], body: Body(code: code, access: access))
    }

    /// `DELETE /v1/pairing/requests/{id}`: a server admin turns away one a household admin let in.
    public func refusePairing(id: String) async throws {
        try await sendDiscardingAnswer("DELETE", ["pairing", "requests", id])
    }

    /// `GET /v1/pairing/requests`: those let in at home that wait for a server admin.
    public func awaitingAdmin() async throws -> [PendingPairingRequest] {
        struct Answer: Decodable { var awaitingAdmin: [PendingPairingRequest]? }
        let answer: Answer = try await get(["pairing", "requests"])
        return answer.awaitingAdmin ?? []
    }

    /// `DELETE /v1/households/{id}/invites/{inviteId}`.
    public func revokeInvite(householdID: String, inviteID: String) async throws {
        try await sendDiscardingAnswer("DELETE", ["households", householdID, "invites", inviteID])
    }

    /// `GET /v1/pairing/requests`, the devices that wait at this manager's household's window
    /// from outside (and, for the owner's, those that came with an invitation).
    public func pendingOutsideRequests() async throws -> [OutsideStatus.Request] {
        struct Answer: Decodable { var outsideRequests: [OutsideStatus.Request]? }
        let answer: Answer = try await get(["pairing", "requests"])
        return answer.outsideRequests ?? []
    }
}
