// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum DevicePlatform: OpenStringEnum {
    case ios, ipados, macos, tvos, cli
    case unknown(String)

    public static let knownCases: [DevicePlatform] = [.ios, .ipados, .macos, .tvos, .cli]

    public var rawValue: String {
        switch self {
        case .ios: "ios"
        case .ipados: "ipados"
        case .macos: "macos"
        case .tvos: "tvos"
        case .cli: "cli"
        case .unknown(let raw): raw
        }
    }
}

public enum DeviceRole: OpenStringEnum {
    case manager, viewer
    case unknown(String)

    public static let knownCases: [DeviceRole] = [.manager, .viewer]

    public var rawValue: String {
        switch self {
        case .manager: "manager"
        case .viewer: "viewer"
        case .unknown(let raw): raw
        }
    }
}

/// What a device may do (docs/api.md, Households): a server admin everything, a household admin
/// their own household, a viewer watch.
public enum DeviceAccess: OpenStringEnum {
    case admin, householdAdmin, viewer
    case unknown(String)

    public static let knownCases: [DeviceAccess] = [.admin, .householdAdmin, .viewer]

    public var rawValue: String {
        switch self {
        case .admin: "admin"
        case .householdAdmin: "householdAdmin"
        case .viewer: "viewer"
        case .unknown(let raw): raw
        }
    }
}

public struct Device: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var platform: DevicePlatform
    public var role: DeviceRole
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var revokedAt: Date?
    /// The kids viewer a manager bound this device to: it shows that viewer and nothing else.
    public var kidsProfileId: String?
    /// Whether a manager lets it in from outside. nil from a server that does not say.
    public var allowOutside: Bool?
    /// Others see it and can play on it (Playing on another device). nil from a server that does
    /// not say.
    public var isTarget: Bool?
    /// A manager's switch: off, it neither sees nor controls others, and they do not see it.
    public var allowRemote: Bool?
    /// Seen and controlled also while it is outside.
    public var remoteOutside: Bool?
    /// The household it is in ("owner" for the server owner's). nil from a server from before households.
    public var householdId: String?
    /// What it may do. nil from a server from before household admins: then `role` says it.
    public var access: DeviceAccess?

    /// What it may do, also on a server from before: its manager was a server admin. Anything
    /// unknown is a viewer.
    public var level: DeviceAccess {
        switch access {
        case .admin?: .admin
        case .householdAdmin?: .householdAdmin
        case .viewer?, .unknown?: .viewer
        case nil: role == .manager ? .admin : .viewer
        }
    }
    /// Whether the server said anything about the kids viewer. An older one leaves the field out, which
    /// must not be read as "not bound any more".
    public private(set) var saysKidsProfile: Bool

    public init(
        id: String, name: String, platform: DevicePlatform, role: DeviceRole,
        createdAt: Date, lastUsedAt: Date? = nil, revokedAt: Date? = nil,
        kidsProfileId: String? = nil, saysKidsProfile: Bool? = nil, allowOutside: Bool? = nil
    ) {
        self.allowOutside = allowOutside
        self.id = id
        self.name = name
        self.platform = platform
        self.role = role
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.revokedAt = revokedAt
        self.kidsProfileId = kidsProfileId
        self.saysKidsProfile = saysKidsProfile ?? (kidsProfileId != nil)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, platform, role, createdAt, lastUsedAt, revokedAt, kidsProfileId, allowOutside
        case isTarget, allowRemote, remoteOutside, householdId, access
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        platform = try container.decode(DevicePlatform.self, forKey: .platform)
        role = try container.decode(DeviceRole.self, forKey: .role)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        revokedAt = try container.decodeIfPresent(Date.self, forKey: .revokedAt)
        allowOutside = try container.decodeIfPresent(Bool.self, forKey: .allowOutside)
        isTarget = try container.decodeIfPresent(Bool.self, forKey: .isTarget)
        allowRemote = try container.decodeIfPresent(Bool.self, forKey: .allowRemote)
        remoteOutside = try container.decodeIfPresent(Bool.self, forKey: .remoteOutside)
        householdId = try container.decodeIfPresent(String.self, forKey: .householdId)
        access = try container.decodeIfPresent(DeviceAccess.self, forKey: .access)
        saysKidsProfile = container.contains(.kidsProfileId)
        kidsProfileId = try container.decodeIfPresent(String.self, forKey: .kidsProfileId)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(platform, forKey: .platform)
        try container.encode(role, forKey: .role)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try container.encodeIfPresent(revokedAt, forKey: .revokedAt)
        try container.encodeIfPresent(allowOutside, forKey: .allowOutside)
        try container.encodeIfPresent(isTarget, forKey: .isTarget)
        try container.encodeIfPresent(allowRemote, forKey: .allowRemote)
        try container.encodeIfPresent(remoteOutside, forKey: .remoteOutside)
        try container.encodeIfPresent(householdId, forKey: .householdId)
        try container.encodeIfPresent(access, forKey: .access)
        if saysKidsProfile { try container.encode(kidsProfileId, forKey: .kidsProfileId) }
    }

    /// The same device with the binding known before, when this answer left it out.
    public func keepingKidsProfile(of known: Device?) -> Device {
        guard !saysKidsProfile, let known, known.id == id, known.saysKidsProfile else { return self }
        var device = self
        device.kidsProfileId = known.kidsProfileId
        device.saysKidsProfile = true
        return device
    }
}

/// `GET /v1/devices`.
public struct DeviceList: Codable, Hashable, Sendable {
    public var devices: [Device]
    public var currentDeviceId: String
}
