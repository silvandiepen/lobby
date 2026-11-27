// SPDX-License-Identifier: MPL-2.0
import Foundation

/// The answer to a claim or an approved collect. The token is shown once: store it in the
/// Keychain (`CredentialStore`) and nowhere else.
public struct DeviceGrant: Codable, Hashable, Sendable {
    public var device: Device
    public var token: String

    public init(device: Device, token: String) {
        self.device = device
        self.token = token
    }
}

/// `POST /v1/pairing/requests`: the new device shows `code` and polls with `pollSecret`.
public struct PairingRequest: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var code: String
    public var pollSecret: String
    public var expiresAt: Date
}

/// `POST /v1/pairing/requests/{id}/collect`.
public enum PairingCollectResult: Hashable, Sendable {
    case pending(expiresAt: Date)
    /// Returned exactly once.
    case approved(DeviceGrant)
}

/// A device waiting for a manager, from `GET /v1/pairing/requests`. The code is never listed.
public struct PendingPairingRequest: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var deviceName: String
    public var platform: DevicePlatform
    /// The code on the device's screen, to compare. Nil after a server restart.
    public var code: String?
    public var createdAt: Date
    public var expiresAt: Date
}

/// `POST /v1/pairing/approve`.
public struct PairingApproval: Codable, Hashable, Sendable {
    public var deviceName: String
    public var platform: DevicePlatform
    public var role: DeviceRole
    /// The household it is in now. nil from a server from before households.
    public var householdId: String?
    public var access: DeviceAccess?
    /// Its household needs a server admin's yes too: it waits for that now.
    public var awaitsAdmin: Bool?
}
