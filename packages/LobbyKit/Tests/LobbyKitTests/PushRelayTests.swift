// SPDX-License-Identifier: MPL-2.0

import CryptoKit
import Foundation
import Testing

@testable import LobbyKit

/// How the app registers for pushes through the relay (docs/api.md, Push notifications).
struct PushRelayTests {
    private let boxKey = Data(repeating: 7, count: 32)
    private var ticket: String { "\(boxKey.base64URLString).1900000000000.\(String(repeating: "A", count: 86))" }

    @Test func readsHowTheServerPushes() async throws {
        let server = StubServer { request in
            #expect(request.method == "GET")
            #expect(request.path == "/v1/me/push")
            return .json(200, #"{ "mode": "relay", "relay": { "url": "https://push.example.com", "ticket": "t.1.s" } }"#)
        }
        let route = try await server.client().pushRoute()
        #expect(route == .relay(url: URL(string: "https://push.example.com")!, ticket: "t.1.s"))
        server.setHandler { _ in .json(200, #"{ "mode": "direct" }"#) }
        #expect(try await server.client().pushRoute() == .direct)
        server.setHandler { _ in .json(200, #"{ "mode": "off" }"#) }
        #expect(try await server.client().pushRoute() == .off)
    }

    @Test func registersTheTokenWithTheRelayAndGivesTheServerOnlyTheHandle() async throws {
        let relay = StubServer { request in
            #expect(request.method == "POST")
            #expect(request.path == "/v1/tokens")
            #expect(request.headers["Authorization"] == nil)
            return .json(200, #"{ "handle": "HHHHHHHHHHHHHHHHHHHHHH", "until": 1 }"#)
        }
        let client = PushRelayClient(url: relay.baseURL, session: relay.session)
        let handle = try await client.register(ticket: ticket, token: Data([0x0a, 0xff]), environment: .production)
        #expect(handle == "HHHHHHHHHHHHHHHHHHHHHH")
        let sent = try #require(relay.recorded.first).json()
        #expect(sent["ticket"] as? String == ticket)
        #expect(sent["token"] as? String == "0aff")
        #expect(sent["environment"] as? String == "production")

        let server = StubServer { _ in StubResponse(status: 204) }
        let key = Data(repeating: 1, count: 32)
        try await server.client().registerPush(handle: handle, key: key, environment: .production)
        let told = try #require(server.recorded.first).json()
        #expect(told.keys.sorted() == ["environment", "handle", "key"])
        #expect(told["key"] as? String == key.base64URLString)
    }

    @Test func forgetsAtTheRelayWithTheBoxAndHandle() async throws {
        let relay = StubServer { _ in StubResponse(status: 204) }
        try await PushRelayClient(url: relay.baseURL, session: relay.session).forget(box: "b", handle: "h")
        let sent = try #require(relay.recorded.first)
        #expect(sent.path == "/v1/tokens/forget")
        #expect(try sent.json() as? [String: String] == ["box": "b", "handle": "h"])
    }

    @Test func saysWhenTheRelayRefuses() async throws {
        let relay = StubServer { _ in .json(403, #"{ "error": "ticket" }"#) }
        await #expect(throws: LobbyError.self) {
            _ = try await PushRelayClient(url: relay.baseURL, session: relay.session)
                .register(ticket: ticket, token: Data([1]), environment: .development)
        }
    }

    @Test func namesTheBoxOfATicketAsTheRelayDoes() {
        #expect(PushRelayClient.box(ofTicket: ticket) == Data(SHA256.hash(data: boxKey)).base64URLString)
        #expect(PushRelayClient.box(ofTicket: "nonsense") == nil)
        #expect(PushRelayClient.box(ofTicket: "a.b") == nil)
    }
}
