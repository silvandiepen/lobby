// SPDX-License-Identifier: MPL-2.0

#if os(iOS) || os(macOS)
import Foundation
import LobbyKit
import LobbyPush
import Testing

@testable import Lobby

/// Registering for pushes the way the server sends them (docs/decisions.md, "Push through a
/// relay"): through the relay, directly, or not at all, against a stand-in server and relay.
struct PushRegistrarTests {
    private let token = Data([0x0a, 0xff, 0x01])
    private let handle = "HHHHHHHHHHHHHHHHHHHHHH"
    private let ticket = "\(String(repeating: "B", count: 42))w.1900000000000.\(String(repeating: "A", count: 86))"

    @Test func registersWithTheRelayAndTellsTheServerOnlyTheHandleAndAKey() async throws {
        let relay = StubServer { request in
            request.path == "/v1/tokens/forget"
                ? StubResponse(status: 204) : .json(200, #"{ "handle": "HHHHHHHHHHHHHHHHHHHHHH", "until": 1 }"#)
        }
        let server = StubServer { request in
            request.method == "GET"
                ? .json(200, #"{ "mode": "relay", "relay": { "url": "\#(relay.baseURL.absoluteString)", "ticket": "\#(ticket)" } }"#)
                : StubResponse(status: 204)
        }
        let keys = InMemoryPushKeyStore()
        let registrar = PushRegistrar(keys: keys, session: relay.session)
        let outcome = try await registrar.register(
            token: token, environment: .production, serverID: "s1", client: try server.client())
        #expect(outcome == .relay(handle: handle))
        #expect(relay.recorded.map(\.path) == ["/v1/tokens"])
        #expect(relay.recorded.first?.json()["token"] as? String == "0aff01")
        #expect(relay.recorded.first?.json()["ticket"] as? String == ticket)
        let told = try #require(server.recorded.last)
        #expect(told.method == "PUT" && told.path == "/v1/me/push")
        #expect(told.json().keys.sorted() == ["environment", "handle", "key"])
        // The key the server seals with is the one the extension will open with.
        let saved = try #require(await keys.registration(forServer: "s1"))
        #expect(saved.handle == handle)
        #expect(saved.box == PushRelayClient.box(ofTicket: ticket))
        #expect(told.json()["key"] as? String == saved.key.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: ""))
        #expect(await keys.allKeys() == [saved.key])

        // Registered again later: the same key, so what was sealed before still opens.
        _ = try await registrar.register(token: token, environment: .production, serverID: "s1", client: try server.client())
        #expect(await keys.registration(forServer: "s1")?.key == saved.key)

        // Signing out forgets it at the relay and here.
        await registrar.forget(serverID: "s1")
        #expect(relay.recorded.last?.path == "/v1/tokens/forget")
        #expect(relay.recorded.last?.json()["handle"] as? String == handle)
        #expect(await keys.allKeys().isEmpty)
    }

    @Test func givesTheTokenToAServerThatSendsDirectlyOrIsFromBefore() async throws {
        for answer in [StubResponse.json(200, #"{ "mode": "direct" }"#), .error(404, "not_found", "No.")] {
            let server = StubServer { request in request.method == "GET" ? answer : StubResponse(status: 204) }
            let outcome = try await PushRegistrar(keys: InMemoryPushKeyStore()).register(
                token: token, environment: .development, serverID: "s1", client: try server.client())
            #expect(outcome == .direct)
            #expect(server.recorded.last?.json()["token"] as? String == "0aff01")
            #expect(server.recorded.last?.json()["environment"] as? String == "development")
        }
    }

    @Test func tellsNothingToAServerThatPushesNothing() async throws {
        let server = StubServer { _ in .json(200, #"{ "mode": "off" }"#) }
        let outcome = try await PushRegistrar(keys: InMemoryPushKeyStore()).register(
            token: token, environment: .production, serverID: "s1", client: try server.client())
        #expect(outcome == .off)
        #expect(server.recorded.map(\.method) == ["GET"])
    }
}
#endif
