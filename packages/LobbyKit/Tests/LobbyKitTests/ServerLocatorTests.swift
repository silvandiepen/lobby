// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing

@testable import LobbyKit

@Suite struct ServerLocatorTests {
    static func server(id: String) -> StubServer {
        StubServer { request in
            guard request.path == "/v1/server" else { return .error(404, "not_found") }
            return .json(200, #"{ "id": "\#(id)", "name": "Lobby", "version": "0.1.0", "apiVersion": 1, "claimed": true }"#)
        }
    }

    static func unreachable() -> StubServer {
        StubServer { _ in throw URLError(.cannotFindHost) }
    }

    // MARK: Which address

    @Test func homeIsUsedWhenItAnswers() async {
        let home = Self.server(id: "s1"), remote = Self.server(id: "s1")
        let found = await ServerLocator.locate(
            serverID: "s1", among: [home.baseURL, remote.baseURL], session: home.session, grace: {})
        #expect(found == home.baseURL)
    }

    @Test func awayFromHomeTheRemoteAddressIsUsed() async {
        let home = Self.unreachable(), remote = Self.server(id: "s1")
        let found = await ServerLocator.locate(
            serverID: "s1", among: [home.baseURL, remote.baseURL], session: home.session, grace: {})
        #expect(found == remote.baseURL)
    }

    @Test func homeWinsAlthoughTheRemoteAddressAnswersFirst() async throws {
        let home = try #require(URL(string: "http://lobby-s1.local:8674"))
        let remote = try #require(URL(string: "http://lobby.example.ts.net:8674"))
        // Home answers only once the wait for it has begun: the remote one was there first.
        let waitBegan = AsyncStream<Void>.makeStream()
        let never = AsyncStream<Void>.makeStream()
        let found = await ServerLocator.firstInOrder(
            of: [home, remote],
            grace: {
                waitBegan.continuation.finish()
                // Longer than this test: home has to win before the wait is over.
                for await _ in never.stream {}
            },
            isTheServer: { address in
                if address == home { for await _ in waitBegan.stream {} }
                return true
            })
        never.continuation.finish()
        #expect(found == home)
    }

    @Test func aHomeAddressThatNeverAnswersDoesNotHoldUpTheRemoteOne() async throws {
        let home = try #require(URL(string: "http://lobby-s1.local:8674"))
        let remote = try #require(URL(string: "http://lobby.example.ts.net:8674"))
        let never = AsyncStream<Void>.makeStream()
        let found = await ServerLocator.firstInOrder(
            of: [home, remote], grace: {},
            isTheServer: { address in
                // Away from home the name does not resolve, and that takes its time.
                if address == home { for await _ in never.stream {} }
                return address == remote
            })
        never.continuation.finish()
        #expect(found == remote)
    }

    @Test func nothingIsFoundWhenNoAddressAnswers() async {
        let home = Self.unreachable(), remote = Self.unreachable()
        let found = await ServerLocator.locate(
            serverID: "s1", among: [home.baseURL, remote.baseURL], session: home.session, grace: {})
        #expect(found == nil)
    }

    // MARK: Who gets the credential

    @Test func anotherServerAtAKnownAddressIsNeverChosenAndSeesNoCredential() async {
        // The home address answers, but as somebody else's server (a hotel's network with the
        // same numbers, say).
        let stranger = Self.server(id: "someone-else"), remote = Self.server(id: "s1")
        let found = await ServerLocator.locate(
            serverID: "s1", among: [stranger.baseURL, remote.baseURL], session: stranger.session, grace: {})
        #expect(found == remote.baseURL)
        #expect(stranger.recorded.map(\.path) == ["/v1/server"])
        #expect(stranger.recorded.allSatisfy { $0.headers["Authorization"] == nil && $0.headers["Cookie"] == nil })

        let alone = await ServerLocator.locate(
            serverID: "s1", among: [stranger.baseURL], session: stranger.session, grace: {})
        #expect(alone == nil)
    }

    @Test func plainHTTPToThePublicInternetIsNotEvenAsked() async throws {
        let home = Self.server(id: "s1")
        let publicAddress = try #require(URL(string: "http://lobby.example.com:8674"))
        let found = await ServerLocator.locate(
            serverID: "s1", among: [publicAddress, home.baseURL], session: home.session, grace: {})
        #expect(found == home.baseURL)
    }

    @Test func theCredentialTravelsOverHTTPSOrInsideTheHomeAndTheTailnetOnly() throws {
        func allowed(_ text: String) throws -> Bool {
            AddressPolicy.mayCarryCredential(try #require(URL(string: text)))
        }
        for address in [
            "https://lobby.example.com", "http://lobby-7c3f9a12.local:8674", "http://lobby.example.ts.net:8674",
            "http://192.168.88.20:8674", "http://10.0.0.4", "http://172.20.1.1", "http://100.64.0.10:8674",
            "http://127.0.0.1:18674", "http://localhost:8674", "http://raspberrypi:8674", "http://[fd7a:115c:a1e0::1]:8674",
        ] {
            #expect(try allowed(address), "\(address) should be allowed")
        }
        for address in [
            "http://lobby.example.com:8674", "http://8.8.8.8", "http://172.32.0.1", "http://100.128.0.1",
            "http://evil.ts.net.example.com", "ftp://192.168.1.2",
        ] {
            #expect(try !allowed(address), "\(address) should be refused")
        }
    }

    // MARK: What the server says, and what is kept

    @Test func meCarriesTheServersAddresses() throws {
        let json = #"""
            { "device": \#(Fixtures.device), "server": { "id": "s1", "name": "Lobby", "version": "0.1.0", "apiVersion": 1, "claimed": true,
              "addresses": { "home": ["http://lobby-s1.local:8674"], "remote": ["http://lobby.example.ts.net:8674", "not an address"] } } }
            """#
        let me = try LobbyJSON.decoder().decode(Me.self, from: Data(json.utf8))
        let addresses = try #require(me.server.addresses)
        #expect(addresses.home.map(\.absoluteString) == ["http://lobby-s1.local:8674"])
        // What is not an address is left out; the rest still works.
        #expect(addresses.remote.map(\.absoluteString) == ["http://lobby.example.ts.net:8674"])
        #expect(addresses.inOrder.count == 2)

        // A server that does not say: as before.
        let old = #"{ "device": \#(Fixtures.device), "server": { "id": "s1", "name": "Lobby", "version": "0.1.0", "apiVersion": 1, "claimed": true } }"#
        #expect(try LobbyJSON.decoder().decode(Me.self, from: Data(old.utf8)).server.addresses == nil)
    }

    @Test func aSavedConnectionTriesHomeThenRemoteThenWhatItWasPairedThrough() throws {
        let home = try #require(URL(string: "http://lobby-s1.local:8674"))
        let remote = try #require(URL(string: "http://lobby.example.ts.net:8674"))
        var saved = SavedConnection(serverAddress: remote, serverID: "s1", serverName: "Lobby", deviceID: "d1", pairedAddress: remote)
        #expect(saved.candidates == [remote])
        saved.addresses = ServerAddresses(home: [home], remote: [remote])
        #expect(saved.candidates == [home, remote])

        // A connection saved by an older build opens, without addresses.
        let old = #"{ "serverAddress": "http://lobby-s1.local:8674", "serverID": "s1", "serverName": "Lobby", "deviceID": "d1" }"#
        let decoded = try JSONDecoder().decode(SavedConnection.self, from: Data(old.utf8))
        #expect(decoded.addresses == nil)
        #expect(decoded.candidates == [home])
    }
}
