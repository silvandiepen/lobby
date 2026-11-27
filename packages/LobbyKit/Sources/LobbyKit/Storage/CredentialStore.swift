// SPDX-License-Identifier: MPL-2.0
import Foundation
import Security

/// Where the device token lives. The apps use `KeychainCredentialStore`; tests and previews use
/// `InMemoryCredentialStore`.
///
/// Tokens are keyed by the server's id (`ServerInfo.id`), so a device paired with two servers
/// keeps both.
public protocol CredentialStore: Sendable {
    func token(forServer serverID: String) async throws -> String?
    func setToken(_ token: String, forServer serverID: String) async throws
    func removeToken(forServer serverID: String) async throws
}

public struct KeychainError: Error, Hashable, Sendable {
    /// The `OSStatus` of the failed Security call.
    public var status: OSStatus

    public var message: String {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
}

/// The device token as a generic password in the Keychain.
///
/// Readable after the first unlock, so a background download can still authenticate with the
/// device locked, and bound to this device: the token is a per-device grant and must not travel
/// in a backup or through iCloud Keychain.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String
    public let accessGroup: String?
    private let usesDataProtectionKeychain: Bool

    /// - Parameters:
    ///   - service: The Keychain service name, normally the app's bundle id.
    ///   - accessGroup: A shared Keychain group, when an extension needs the token too.
    ///   - usesDataProtectionKeychain: Leave true in an app. On macOS the data protection
    ///     Keychain needs a signed app with an application identifier; pass false for an unsigned
    ///     command-line tool or test runner, which then uses the login Keychain. iOS and tvOS
    ///     have no other Keychain and ignore the flag.
    public init(service: String, accessGroup: String? = nil, usesDataProtectionKeychain: Bool = true) {
        self.service = service
        self.accessGroup = accessGroup
        self.usesDataProtectionKeychain = usesDataProtectionKeychain
    }

    public func token(forServer serverID: String) async throws -> String? {
        var query = baseQuery(serverID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    public func setToken(_ token: String, forServer serverID: String) async throws {
        let data = Data(token.utf8)
        let update = SecItemUpdate(
            baseQuery(serverID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch update {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = baseQuery(serverID)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        default:
            throw KeychainError(status: update)
        }
    }

    public func removeToken(forServer serverID: String) async throws {
        let status = SecItemDelete(baseQuery(serverID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    /// Removes every item of this service: an account that is removed keeps nothing behind.
    public func removeAll() throws {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = usesDataProtectionKeychain
        #endif
        // The Mac's file-based Keychain deletes one matching item at a time.
        for _ in 0..<1_000 {
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        }
    }

    private func baseQuery(_ serverID: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = usesDataProtectionKeychain
        #endif
        return query
    }
}

/// A credential store that forgets everything when the process ends. For tests and previews.
public actor InMemoryCredentialStore: CredentialStore {
    private var tokens: [String: String]

    public init(tokens: [String: String] = [:]) {
        self.tokens = tokens
    }

    public func token(forServer serverID: String) -> String? {
        tokens[serverID]
    }

    public func setToken(_ token: String, forServer serverID: String) {
        tokens[serverID] = token
    }

    public func removeToken(forServer serverID: String) {
        tokens[serverID] = nil
    }

    public func removeAll() {
        tokens = [:]
    }

    /// Every key that has a token, for tests.
    public var keys: [String] { tokens.keys.sorted() }
}
