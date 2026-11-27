// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyDirect

// Getting ready for the direct road (`/v1/me/direct`), and a manager's tools for access from outside
// (`/v1/outside…`), as `docs/api.md` describes them. All of it only at home or in the tailnet.

extension LobbyClient {
    /// `GET /v1/me/direct`. Throws `.notFound` where the direct road is not set up.
    public func directOffer() async throws -> DirectOffer {
        var request = request("GET", ["me", "direct"])
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return try decode(try await perform(request).0)
    }

    /// `PUT /v1/me/direct`: makes keys, and gets this device ready for the direct road.
    public func enrolDirect() async throws -> DirectIdentity {
        struct Body: Encodable {
            var ringKey: String
            var agreementKey: String
        }
        let enrolment = DirectEnrolment()
        let offer: DirectOffer = try await send(
            "PUT", ["me", "direct"], body: Body(ringKey: enrolment.ringKey, agreementKey: enrolment.agreementKey))
        return try enrolment.finish(offer)
    }

    /// What this device should keep for the direct road: the identity it has with what changed, or
    /// a new one. nil when the server does not offer the road.
    public func directIdentity(keeping known: DirectIdentity?) async throws -> DirectIdentity? {
        let offer: DirectOffer
        do {
            offer = try await directOffer()
        } catch LobbyError.notFound {
            return nil
        }
        if let updated = known?.updated(with: offer) { return updated }
        return try await enrolDirect()
    }

    /// `GET /v1/outside`. Manager.
    public func outsideStatus() async throws -> OutsideStatus {
        try await get(["outside"])
    }

    /// `PATCH /v1/outside`. Manager.
    public func setOutside(enabled: Bool) async throws -> OutsideStatus {
        struct Body: Encodable { var enabled: Bool }
        return try await send("PATCH", ["outside"], body: Body(enabled: enabled))
    }

    /// `POST /v1/outside/window`. Manager. The code is shown once.
    public func openOutsideWindow(minutes: Int = 10) async throws -> OutsideWindow {
        struct Body: Encodable { var minutes: Int }
        return try await send("POST", ["outside", "window"], body: Body(minutes: minutes))
    }

    /// `DELETE /v1/outside/window`. Manager.
    public func closeOutsideWindow() async throws {
        try await sendDiscardingAnswer("DELETE", ["outside", "window"])
    }

    /// `POST /v1/outside/pairing/{id}/approve`. Manager. Without `comparison`: a server admin's yes
    /// to one its household admin let in.
    public func approveOutside(id: String, comparison: String?) async throws -> PairingApproval {
        struct Body: Encodable { var comparison: String? }
        return try await send("POST", ["outside", "pairing", id, "approve"], body: Body(comparison: comparison))
    }

    /// `DELETE /v1/outside/pairing/{id}`. Manager.
    public func refuseOutside(id: String) async throws {
        try await sendDiscardingAnswer("DELETE", ["outside", "pairing", id])
    }

    /// `GET /v1/outside/access`. Manager.
    public func outsideAccess(limit: Int = 50) async throws -> [OutsideAccess] {
        struct Answer: Decodable { var entries: [OutsideAccess] }
        let answer: Answer = try await get(["outside", "access"], query: [URLQueryItem(name: "limit", value: String(limit))])
        return answer.entries
    }

    /// `PATCH /v1/devices/{id}` with only `allowOutside`. Manager.
    public func setAllowOutside(_ allowed: Bool, deviceID: String) async throws -> Device {
        struct Body: Encodable { var allowOutside: Bool }
        return try await send("PATCH", ["devices", deviceID], body: Body(allowOutside: allowed))
    }
}

/// `GET /v1/outside`.
public struct OutsideStatus: Codable, Hashable, Sendable {
    public struct Transport: Codable, Hashable, Sendable {
        public var name: String
        public var open: Bool
        public var problem: String?
    }

    public struct Direct: Codable, Hashable, Sendable {
        public var running: Bool
        public var introducer: Bool
        public var connections: Int
        public var relayed: Int
        public var devices: Int
    }

    public struct Window: Codable, Hashable, Sendable {
        public var openedBy: String
        public var openedAt: Date
        public var expiresAt: Date
    }

    /// A device that waits to be let in. The manager compares `comparison` with its screen.
    public struct Request: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var deviceName: String
        public var platform: DevicePlatform
        public var address: String?
        public var comparison: String
        public var createdAt: Date
        public var expiresAt: Date
        /// The household it will be in. nil from a server from before households.
        public var householdId: String?
        /// It came with a household's invitation.
        public var invited: Bool?
        /// What it will be in its household.
        public var access: DeviceAccess?
        /// "waiting" for its household admin, "awaitingAdmin" for a server admin, "refused" by one.
        public var state: String?
        /// The household's name, in `GET /v1/pairing/requests`.
        public var householdName: String?

        /// Its household admin said yes; a server admin is still to, without digits.
        public var awaitsAdmin: Bool { state == "awaitingAdmin" }
        public var isRefused: Bool { state == "refused" }
    }

    public var configured: Bool
    public var enabled: Bool
    public var transports: [Transport]
    public var connections: Int
    /// nil where the direct road is not set up.
    public var direct: Direct?
    public var window: Window?
    public var requests: [Request]
}

/// `POST /v1/outside/window`.
public struct OutsideWindow: Codable, Hashable, Sendable {
    public struct Direct: Codable, Hashable, Sendable {
        public var introducer: String
    }

    /// `XXXX-XXXX-XXXX-XXXX`.
    public var code: String
    public var expiresAt: Date
    public var direct: Direct?

    /// What a new device reads or is given.
    public var invitation: PairingInvitation? {
        direct.flatMap { PairingInvitation(introducer: $0.introducer, code: code) }
    }
}

/// One line of `GET /v1/outside/access`.
public struct OutsideAccess: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var at: Date
    public var until: Date
    public var count: Int
    public var deviceId: String?
    public var transport: String
    public var address: String?
    public var routeClass: String
    public var outcome: String
}

/// The answer to a new device that was approved over the direct road.
public struct DirectGrant: Sendable {
    public var grant: DeviceGrant
    public var identity: DirectIdentity

    public init(_ approved: DirectPairing.Approved) throws {
        struct Answer: Decodable {
            var device: Device
            var token: String
        }
        let answer = try LobbyJSON.decoder().decode(Answer.self, from: approved.answer)
        grant = DeviceGrant(device: answer.device, token: answer.token)
        identity = approved.identity
    }
}
