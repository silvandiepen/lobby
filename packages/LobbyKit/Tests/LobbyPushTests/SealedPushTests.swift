// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing

@testable import LobbyPush

#if os(iOS) || os(macOS)
import UserNotifications
#endif

/// docs/push-vectors.json, opened as the notification service extension opens it.
struct SealedPushTests {
    private struct Vectors: Decodable {
        struct Case: Decodable {
            var content: SealedPush.Content
            var sealed: String
        }
        var aad: String
        var key: String
        var nonce: String
        var cases: [Case]
        var wrongKey: String
    }

    private let vectors: Vectors

    init() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        vectors = try JSONDecoder().decode(
            Vectors.self, from: Data(contentsOf: root.appending(path: "docs/push-vectors.json")))
    }

    private var key: Data { Data(base64URLEncoded: vectors.key)! }

    @Test func opensWhatTheServerSealed() throws {
        #expect(String(decoding: SealedPush.aad, as: UTF8.self) == vectors.aad)
        for one in vectors.cases {
            #expect(SealedPush.open(one.sealed, keys: [key]) == one.content)
        }
    }

    @Test func sealsSoThatItOpensAgain() throws {
        let first = try #require(vectors.cases.first)
        let sealed = try SealedPush.seal(first.content, key: key, nonce: Data(base64URLEncoded: vectors.nonce))
        // The JSON may be written in another order; what matters is that the server's opens here
        // and this opens in turn.
        #expect(SealedPush.open(sealed, keys: [key]) == first.content)
    }

    @Test func triesEveryServersKeyAndOpensNothingWithTheWrongOne() throws {
        let wrong = try #require(Data(base64URLEncoded: vectors.wrongKey))
        let sealed = try #require(vectors.cases.first?.sealed)
        #expect(SealedPush.open(sealed, keys: [wrong]) == nil)
        #expect(SealedPush.open(sealed, keys: [wrong, key]) == vectors.cases.first?.content)
        // A byte changed, or something that is no envelope at all.
        var changed = Array(sealed)
        changed[20] = changed[20] == "A" ? "B" : "A"
        #expect(SealedPush.open(String(changed), keys: [key]) == nil)
        #expect(SealedPush.open("not sealed", keys: [key]) == nil)
        #expect(SealedPush.open("", keys: [key]) == nil)
    }

    @Test func makesAKeyOfThirtyTwoRandomBytes() {
        #expect(SealedPush.newKey().count == 32)
        #expect(SealedPush.newKey() != SealedPush.newKey())
    }

    #if os(iOS) || os(macOS)
    /// What the extension does with a notification as the relay delivers it.
    @Test func showsTheRealTextWithItsActionsOnTheLockScreen() throws {
        let one = try #require(vectors.cases.first)
        let content = UNMutableNotificationContent()
        content.title = "Lobby"
        content.body = "A request is waiting."
        content.userInfo = ["aps": ["mutable-content": 1], "lobby": ["v": 1, "s": one.sealed]]
        #expect(SealedPush.reveal(content, keys: [key]))
        #expect(content.title == "Robin")
        #expect(content.body == "Robin wants to watch The Film.")
        #expect(content.categoryIdentifier == "LOBBY_KIDS_QUESTION")
        #expect(content.threadIdentifier == "kids-p1")
        // What the app reads when Watch, Listen or No is chosen.
        let lobby = try #require(content.userInfo["lobby"] as? [String: String])
        #expect(lobby == ["kind": "kidsRequest", "requestId": "q1", "serverId": "s1"])
    }

    @Test func leavesTheGenericAlertWhenNoKeyOpensIt() throws {
        let one = try #require(vectors.cases.first)
        let content = UNMutableNotificationContent()
        content.title = "Lobby"
        content.body = "A request is waiting."
        content.userInfo = ["lobby": ["v": 1, "s": one.sealed]]
        #expect(!SealedPush.reveal(content, keys: [SealedPush.newKey()]))
        #expect(content.title == "Lobby")
        #expect(content.body == "A request is waiting.")
        #expect(content.categoryIdentifier.isEmpty)
    }
    #endif

    @Test func keepsARegistrationPerServerAndEveryKey() async throws {
        let store: any PushKeyStore = InMemoryPushKeyStore()
        let one = PushRegistration(key: SealedPush.newKey(), handle: "h1", box: "b1")
        try await store.setRegistration(one, forServer: "s1")
        try await store.setRegistration(PushRegistration(key: SealedPush.newKey()), forServer: "s2")
        #expect(try await store.registration(forServer: "s1") == one)
        #expect(try await store.allKeys().count == 2)
        try await store.removeRegistration(forServer: "s1")
        #expect(try await store.registration(forServer: "s1") == nil)
        #expect(try await store.allKeys().count == 1)
    }
}
