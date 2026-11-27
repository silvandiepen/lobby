// SPDX-License-Identifier: MPL-2.0
import Foundation

// A manager's Apple TVs that Lobby Server can wake (`/v1/wake…`), as `docs/api.md` ("Waking an
// Apple TV") describes them. At home or in the tailnet only.

/// `GET /v1/wake`.
public struct WakeStatus: Decodable, Hashable, Sendable {
    public struct Pairing: Decodable, Hashable, Sendable {
        public var id: String
        public var televisionId: String
        public var expiresAt: Date
    }

    /// `remote.wake` is in the server's config file.
    public var configured: Bool
    public var enabled: Bool
    /// "Kids can turn on the TV" (`remote.wake.kids`): kids mode may wake a TV too. False from a
    /// server from before it.
    public var kids: Bool
    /// The helper that speaks to the TVs runs.
    public var running: Bool
    public var problem: String?
    public var pyatv: String?
    public var scannedAt: Date?
    public var televisions: [Television]
    public var pairing: Pairing?

    public init(
        configured: Bool, enabled: Bool, kids: Bool = false, running: Bool, problem: String? = nil,
        pyatv: String? = nil, scannedAt: Date? = nil, televisions: [Television] = [], pairing: Pairing? = nil
    ) {
        self.configured = configured
        self.enabled = enabled
        self.kids = kids
        self.running = running
        self.problem = problem
        self.pyatv = pyatv
        self.scannedAt = scannedAt
        self.televisions = televisions
        self.pairing = pairing
    }

    private enum CodingKeys: String, CodingKey {
        case configured, enabled, kids, running, problem, pyatv, scannedAt, televisions, pairing
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configured = try container.decode(Bool.self, forKey: .configured)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        kids = try container.decodeIfPresent(Bool.self, forKey: .kids) ?? false
        running = try container.decode(Bool.self, forKey: .running)
        problem = try container.decodeIfPresent(String.self, forKey: .problem)
        pyatv = try container.decodeIfPresent(String.self, forKey: .pyatv)
        scannedAt = try container.decodeIfPresent(Date.self, forKey: .scannedAt)
        televisions = try container.decode([Television].self, forKey: .televisions)
        pairing = try container.decodeIfPresent(Pairing.self, forKey: .pairing)
    }
}

/// An Apple TV as Lobby Server knows it.
public struct Television: Decodable, Hashable, Sendable, Identifiable {
    /// pyatv's identifier for it.
    public var id: String
    public var name: String
    public var model: String
    /// Lobby Server holds credentials for it.
    public var paired: Bool
    /// It answered the last look on the network.
    public var found: Bool
    /// The Lobby device it is, as a manager confirmed.
    public var deviceId: String?
    /// The Lobby device it probably is, by name, until a manager confirms one.
    public var suggestedDeviceId: String?

    public init(
        id: String, name: String, model: String = "", paired: Bool, found: Bool = true, deviceId: String? = nil,
        suggestedDeviceId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.paired = paired
        self.found = found
        self.deviceId = deviceId
        self.suggestedDeviceId = suggestedDeviceId
    }
}

/// `POST /v1/wake/pairings`: the TV shows a code until `expiresAt`.
public struct TelevisionPairing: Decodable, Hashable, Sendable {
    public var id: String
    public var televisionId: String
    public var expiresAt: Date
}

extension LobbyClient {
    /// `GET /v1/wake`. Manager.
    public func wakeStatus() async throws -> WakeStatus {
        var request = request("GET", ["wake"])
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return try decode(try await perform(request).0)
    }

    /// `PATCH /v1/wake`. Manager.
    public func setWake(enabled: Bool) async throws -> WakeStatus {
        struct Body: Encodable { var enabled: Bool }
        return try await send("PATCH", ["wake"], body: Body(enabled: enabled))
    }

    /// `PATCH /v1/wake` `{ kids }`: "Kids can turn on the TV". Manager.
    public func setKidsWake(_ kids: Bool) async throws -> WakeStatus {
        struct Body: Encodable { var kids: Bool }
        return try await send("PATCH", ["wake"], body: Body(kids: kids))
    }

    /// `POST /v1/wake/scan`: looks on the network for a few seconds. Manager.
    public func scanForTelevisions() async throws -> WakeStatus {
        try await send("POST", ["wake", "scan"])
    }

    /// `POST /v1/wake/pairings`: the TV shows a code now. Manager.
    public func beginTelevisionPairing(televisionID: String) async throws -> TelevisionPairing {
        struct Body: Encodable { var televisionId: String }
        return try await send("POST", ["wake", "pairings"], body: Body(televisionId: televisionID))
    }

    /// `POST /v1/wake/pairings/{id}` with the code the TV shows. Manager.
    public func finishTelevisionPairing(id: String, pin: String) async throws -> Television {
        struct Body: Encodable { var pin: String }
        return try await send("POST", ["wake", "pairings", id], body: Body(pin: pin))
    }

    /// `DELETE /v1/wake/pairings/{id}`. Manager.
    public func cancelTelevisionPairing(id: String) async throws {
        try await sendDiscardingAnswer("DELETE", ["wake", "pairings", id])
    }

    /// `PUT /v1/wake/televisions/{id}`: which Lobby device the TV is; nil for none. Manager.
    public func linkTelevision(id: String, deviceID: String?) async throws -> Television {
        struct Body: Encodable {
            var deviceId: String?
            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: Key.self)
                try container.encode(deviceId, forKey: .deviceId)
            }
            enum Key: String, CodingKey { case deviceId }
        }
        return try await send("PUT", ["wake", "televisions", id], body: Body(deviceId: deviceID))
    }

    /// `DELETE /v1/wake/televisions/{id}`: Lobby Server forgets the TV's credentials. Manager.
    public func disconnectTelevision(id: String) async throws {
        try await sendDiscardingAnswer("DELETE", ["wake", "televisions", id])
    }
}
