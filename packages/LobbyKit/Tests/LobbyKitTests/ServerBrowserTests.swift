// SPDX-License-Identifier: MPL-2.0
import Foundation
import Network
import Testing

@testable import LobbyKit

/// Real Bonjour on this machine: a listener announces itself the way Lobby Server does, and
/// the browser has to find it and work out its address.
@Suite(.timeLimit(.minutes(1)))
struct ServerBrowserTests {
    /// Announces `_lobby._tcp` under `name`, on a port the system picks.
    private func announce(name: String, id: String) async throws -> NWListener {
        let listener = try NWListener(using: .tcp)
        var record = NWTXTRecord()
        record["id"] = id
        record["v"] = "0.1.0"
        listener.service = NWListener.Service(name: name, type: ServerBrowser.serviceType, txtRecord: record)
        listener.newConnectionHandler = { $0.cancel() }
        let ready = AsyncStream<Bool>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.continuation.yield(true)
            case .failed, .cancelled: ready.continuation.yield(false)
            default: break
            }
        }
        listener.start(queue: .global())
        guard await ready.stream.first(where: { _ in true }) == true else { throw DiscoveryError.notFound }
        return listener
    }

    @Test func aServerThatAnnouncesItselfIsFoundWithItsNameIdAndAddress() async throws {
        let name = "Lobby test \(UUID().uuidString.prefix(8))"
        let listener = try await announce(name: name, id: "server-123")
        defer { listener.cancel() }
        let port = try #require(listener.port?.rawValue)

        var found: DiscoveredServer?
        for await update in ServerBrowser.updates() {
            if let server = update.servers.first(where: { $0.name == name }) {
                found = server
                break
            }
        }
        let server = try #require(found)
        #expect(server.serverID == "server-123")
        #expect(server.version == "0.1.0")
        #expect(server.id == "server-123")

        // Its address: this machine's own name on the network, and the listener's port.
        let address = try await ServerBrowser.address(of: server)
        #expect(address.scheme == "http")
        #expect(address.port == Int(port))
        let host = try #require(address.host)
        #expect(!host.isEmpty && !host.hasSuffix("."))
        #expect(try LobbyClient(baseURL: address).baseURL == address)
    }

    @Test func aServerThatGoesAwayLeavesTheList() async throws {
        let name = "Lobby test \(UUID().uuidString.prefix(8))"
        let listener = try await announce(name: name, id: "server-456")
        var seen = false
        for await update in ServerBrowser.updates() {
            let isThere = update.servers.contains { $0.name == name }
            if isThere, !seen {
                seen = true
                listener.cancel()
            } else if seen, !isThere {
                break
            }
        }
        #expect(seen)
    }

    @Test func oneServerSeenOnSeveralInterfacesIsListedOnce() {
        let same = DiscoveredServer(name: "Lobby", serverID: "s1", version: "0.1.0")
        #expect(Set([same, same]).count == 1)
        // Without an id in the announcement the name tells servers apart.
        #expect(DiscoveredServer(name: "Lobby", serverID: nil, version: nil).id == "Lobby.local.")
    }
}
