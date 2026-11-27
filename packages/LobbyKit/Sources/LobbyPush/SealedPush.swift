// SPDX-License-Identifier: MPL-2.0

import CryptoKit
import Foundation

#if os(iOS) || os(macOS)
import UserNotifications
#endif

/// What a server says to the app through the push relay (docs/decisions.md, "Push through a
/// relay"), sealed so that the relay and Apple pass on what they cannot read: ChaCha20-Poly1305
/// with the 32-byte key this app made for that server, the nonce first and the tag last, base64url.
/// `docs/push-vectors.json` has the exact bytes; the server tests against it too.
///
/// Small on purpose, and nothing else of Lobby's: the notification service extension links only
/// this, and the system gives it little memory.
public enum SealedPush {
    public static let protocolName = "lobby-push/1"
    /// What every sealed notification is bound to.
    public static let aad = Data("\(protocolName)|alert".utf8)

    /// What the lock screen shows, and what the app reads when it is tapped or answered.
    public struct Content: Codable, Equatable, Sendable {
        public var title: String
        public var body: String
        /// A notification category of the apps, for its actions.
        public var category: String?
        public var thread: String?
        /// `lobby` in the notification's user info: kind, requestId, serverId.
        public var data: [String: String]

        public init(
            title: String, body: String, category: String? = nil, thread: String? = nil, data: [String: String] = [:]
        ) {
            self.title = title
            self.body = body
            self.category = category
            self.thread = thread
            self.data = data
        }
    }

    /// The content, when one of these keys sealed it. Nil when none did.
    public static func open(_ sealed: String, keys: [Data]) -> Content? {
        guard sealed.utf8.count <= 4_096, let raw = Data(base64URLEncoded: sealed), raw.count > 28 else { return nil }
        for key in keys where key.count == 32 {
            guard
                let box = try? ChaChaPoly.SealedBox(combined: raw),
                let plain = try? ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad),
                let content = try? JSONDecoder().decode(Content.self, from: plain)
            else { continue }
            return content
        }
        return nil
    }

    /// The other half, as the server does it. For tests and the vectors.
    public static func seal(_ content: Content, key: Data, nonce: Data? = nil) throws -> String {
        let plain = try JSONEncoder().encode(content)
        let sealed = try ChaChaPoly.seal(
            plain, using: SymmetricKey(data: key), nonce: try nonce.map { try ChaChaPoly.Nonce(data: $0) } ?? ChaChaPoly.Nonce(),
            authenticating: aad)
        return sealed.combined.base64URLEncodedString()
    }

    /// A new key for one server: 32 random bytes.
    public static func newKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    #if os(iOS) || os(macOS)
    /// What the notification service shows: the sealed text opened, with its category (Watch,
    /// Listen, No), thread and what the app reads. Unchanged, so the generic alert, when no key
    /// opens it: a notification is never dropped.
    ///
    /// - Returns: Whether it was opened.
    @discardableResult
    public static func reveal(_ content: UNMutableNotificationContent, keys: [Data]) -> Bool {
        guard
            let lobby = content.userInfo["lobby"] as? [String: Any],
            let sealed = lobby["s"] as? String,
            let opened = open(sealed, keys: keys)
        else { return false }
        content.title = opened.title
        content.body = opened.body
        if let category = opened.category { content.categoryIdentifier = category }
        if let thread = opened.thread { content.threadIdentifier = thread }
        var info = content.userInfo
        info["lobby"] = opened.data
        content.userInfo = info
        return true
    }
    #endif
}

extension Data {
    /// Bytes from base64url without padding, in its one way of writing it. Nil otherwise.
    init?(base64URLEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), data.base64URLEncodedString() == text else { return nil }
        self = data
    }

    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
