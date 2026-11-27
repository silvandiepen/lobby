// SPDX-License-Identifier: MPL-2.0

import Foundation
import Security

/// What this device keeps per server for pushes through the relay: the key that server seals
/// with, and what the relay was told.
public struct PushRegistration: Codable, Hashable, Sendable {
    /// 32 random bytes, made on this device for this server.
    public var key: Data
    /// The relay's handle for this device and the server's box.
    public var handle: String?
    /// The server's box id, as the relay knows it.
    public var box: String?
    /// The relay's address.
    public var relay: URL?
    /// The device token the handle stands for, in hex, so a new one is registered again.
    public var token: String?

    public init(key: Data, handle: String? = nil, box: String? = nil, relay: URL? = nil, token: String? = nil) {
        self.key = key
        self.handle = handle
        self.box = box
        self.relay = relay
        self.token = token
    }
}

/// Where the push keys live. The app writes; the notification service extension only reads them
/// all, since a notification does not say which server it is from.
public protocol PushKeyStore: Sendable {
    func registration(forServer serverID: String) async throws -> PushRegistration?
    func setRegistration(_ registration: PushRegistration, forServer serverID: String) async throws
    func removeRegistration(forServer serverID: String) async throws
    /// Every server's key.
    func allKeys() async throws -> [Data]
}

public struct PushKeychainError: Error, Hashable, Sendable {
    public var status: OSStatus
}

/// The push keys in a Keychain group the app shares with its notification service extension.
/// Readable after the first unlock, since a notification comes while the device is locked, and
/// bound to this device: never in a backup or iCloud Keychain.
public struct KeychainPushKeyStore: PushKeyStore {
    public let service: String
    public let accessGroup: String?

    /// - Parameters:
    ///   - service: The Keychain service, the same in the app and the extension.
    ///   - accessGroup: The shared group, with the team's prefix (`LobbyPushKeychainGroup` in the
    ///     Info.plist). Nil only where nothing is shared.
    public init(service: String, accessGroup: String?) {
        self.service = service
        self.accessGroup = accessGroup
    }

    /// As the app and the extension are built: the group named in the Info.plist.
    public static func shared(service: String = "lobby.push", bundle: Bundle = .main) -> KeychainPushKeyStore {
        let group = bundle.object(forInfoDictionaryKey: "LobbyPushKeychainGroup") as? String
        return KeychainPushKeyStore(service: service, accessGroup: group?.isEmpty == false ? group : nil)
    }

    public func registration(forServer serverID: String) async throws -> PushRegistration? {
        var query = base()
        query[kSecAttrAccount as String] = serverID
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw PushKeychainError(status: status) }
        return try? JSONDecoder().decode(PushRegistration.self, from: data)
    }

    public func setRegistration(_ registration: PushRegistration, forServer serverID: String) async throws {
        let data = try JSONEncoder().encode(registration)
        var query = base()
        query[kSecAttrAccount as String] = serverID
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw PushKeychainError(status: update) }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw PushKeychainError(status: status) }
    }

    public func removeRegistration(forServer serverID: String) async throws {
        var query = base()
        query[kSecAttrAccount as String] = serverID
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PushKeychainError(status: status) }
    }

    public func allKeys() async throws -> [Data] {
        try keysNow()
    }

    /// Every server's key, at once: for the notification service, which has no time to wait.
    public func keysNow() throws -> [Data] {
        var query = base()
        // The group holds only push keys: every account's, whatever its service.
        if accessGroup != nil { query[kSecAttrService as String] = nil }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [Data] else { throw PushKeychainError(status: status) }
        return items.compactMap { try? JSONDecoder().decode(PushRegistration.self, from: $0).key }
    }

    private func base() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
}

/// Push keys that are gone when the process ends. For tests and previews.
public actor InMemoryPushKeyStore: PushKeyStore {
    private var registrations: [String: PushRegistration] = [:]

    public init() {}

    public func registration(forServer serverID: String) -> PushRegistration? { registrations[serverID] }
    public func setRegistration(_ registration: PushRegistration, forServer serverID: String) {
        registrations[serverID] = registration
    }
    public func removeRegistration(forServer serverID: String) { registrations[serverID] = nil }
    public func allKeys() -> [Data] { registrations.values.map(\.key) }
}
