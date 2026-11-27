// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing

@testable import LobbyKit

@Suite struct CredentialStoreTests {
    @Test func theInMemoryStoreKeepsATokenPerServer() async throws {
        let store: any CredentialStore = InMemoryCredentialStore()

        try await store.setToken("a", forServer: "srv-1")
        try await store.setToken("b", forServer: "srv-2")
        #expect(try await store.token(forServer: "srv-1") == "a")
        #expect(try await store.token(forServer: "srv-2") == "b")

        try await store.removeToken(forServer: "srv-1")
        #expect(try await store.token(forServer: "srv-1") == nil)
        #expect(try await store.token(forServer: "srv-2") == "b")
    }

    #if os(macOS)
    /// The real Keychain. A test runner is not a signed app, so this uses the login Keychain
    /// (see `KeychainCredentialStore.init`), under a service name of its own.
    @Test func theKeychainStoresReplacesAndRemovesAToken() async throws {
        let store = KeychainCredentialStore(
            service: "mt.sil.lobby.tests.\(UUID().uuidString)", usesDataProtectionKeychain: false)
        let server = "srv-keychain"

        #expect(try await store.token(forServer: server) == nil)
        try await store.setToken("first", forServer: server)
        #expect(try await store.token(forServer: server) == "first")
        try await store.setToken("second", forServer: server)
        #expect(try await store.token(forServer: server) == "second")
        try await store.removeToken(forServer: server)
        #expect(try await store.token(forServer: server) == nil)
        try await store.removeToken(forServer: server)
    }
    #endif

    @Test func remembersTheConnectionAndTheViewer() throws {
        let suite = "mt.sil.lobby.tests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let preferences = ConnectionPreferences(suiteName: suite)
        #expect(preferences.connection == nil)

        let connection = SavedConnection(
            serverAddress: URL(string: "http://lobby.local:8484")!, serverID: "srv-1", serverName: "Lobby", deviceID: "dev-1")
        preferences.connection = connection
        preferences.activeProfileID = "p1"

        let again = ConnectionPreferences(suiteName: suite)
        #expect(again.connection == connection)
        #expect(again.activeProfileID == "p1")

        again.connection = nil
        again.activeProfileID = nil
        #expect(preferences.connection == nil)
        #expect(preferences.activeProfileID == nil)
    }
}
