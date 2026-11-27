// SPDX-License-Identifier: MPL-2.0
import Foundation
import Network
import Synchronization
import dnssd

/// A Lobby Server found on the local network.
public struct DiscoveredServer: Hashable, Sendable, Identifiable {
    /// The name the server announces: the one `GET /v1/server` gives.
    public var name: String
    /// `ServerInfo.id`, from the announcement. nil when an announcement comes without one.
    public var serverID: String?
    /// The server's version, from the announcement.
    public var version: String?
    /// Where Bonjour found it, e.g. "local.".
    public var domain: String

    public var id: String { serverID ?? "\(name).\(domain)" }

    public init(name: String, serverID: String?, version: String?, domain: String = "local.") {
        self.name = name
        self.serverID = serverID
        self.version = version
        self.domain = domain
    }
}

/// What a look around the local network gives.
public struct DiscoveryUpdate: Hashable, Sendable {
    /// The servers in sight right now, by name.
    public var servers: [DiscoveredServer]
    /// The person did not allow this app to look at the local network. Typing the server's
    /// address still works.
    public var isDenied: Bool

    public init(servers: [DiscoveredServer] = [], isDenied: Bool = false) {
        self.servers = servers
        self.isDenied = isDenied
    }
}

public enum DiscoveryError: Error, Hashable, Sendable {
    /// The server stopped announcing itself before its address was found.
    case notFound
    case failed(Int32)
}

/// Finds Lobby Servers on the local network: they announce themselves with Bonjour as
/// `_lobby._tcp`, with their server id and version (`id`, `v`) in the TXT record.
///
/// This does not work over Tailscale, where nothing is announced: there the address is typed.
///
/// An app that uses it needs `NSBonjourServices` with `_lobby._tcp` and
/// `NSLocalNetworkUsageDescription` in its Info.plist. The first look makes iOS ask the person
/// for access to the local network.
public enum ServerBrowser {
    public static let serviceType = "_lobby._tcp"

    /// The servers in sight, and again whenever one comes or goes. Looking stops when the
    /// stream is no longer read.
    public static func updates() -> AsyncStream<DiscoveryUpdate> {
        AsyncStream { continuation in
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: parameters)

            browser.browseResultsChangedHandler = { results, _ in
                continuation.yield(DiscoveryUpdate(servers: servers(in: results)))
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .waiting(let error), .failed(let error):
                    // No access to the local network shows as a DNS policy error.
                    if case .dns(let code) = error, code == kDNSServiceErr_PolicyDenied {
                        continuation.yield(DiscoveryUpdate(isDenied: true))
                    }
                case .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: .global(qos: .userInitiated))
        }
    }

    static func servers(in results: Set<NWBrowser.Result>) -> [DiscoveredServer] {
        var found: [String: DiscoveredServer] = [:]
        for result in results {
            guard case .service(let name, _, let domain, _) = result.endpoint else { continue }
            var serverID: String?
            var version: String?
            if case .bonjour(let record) = result.metadata {
                serverID = record["id"]
                version = record["v"]
            }
            // One server is seen once per network interface: it is one server.
            let server = DiscoveredServer(name: name, serverID: serverID, version: version, domain: domain)
            found[server.id] = server
        }
        return found.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending || ($0.name == $1.name && $0.id < $1.id)
        }
    }

    /// The address of a found server, as `LobbyClient` wants it: `http://lobby-7c3f9a12.local:8674`.
    ///
    /// The host is the name the server's machine has on the network, not a number, so the
    /// address stays right when the router hands the machine another one.
    public static func address(of server: DiscoveredServer) async throws -> URL {
        let resolution = Resolution()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                resolution.start(name: server.name, domain: server.domain, continuation: continuation)
            }
        } onCancel: {
            resolution.cancel()
        }
    }

    /// One `DNSServiceResolve`, on a queue of its own.
    private final class Resolution: Sendable {
        private struct State {
            /// The `DNSServiceRef`, as the address it is: a handle to hold and to hand back.
            var service: Int?
            var continuation: CheckedContinuation<URL, any Error>?
        }

        private let queue = DispatchQueue(label: "mt.sil.lobby.discovery")
        private let state = Mutex(State())

        func start(name: String, domain: String, continuation: CheckedContinuation<URL, any Error>) {
            state.withLock { $0.continuation = continuation }
            var service: DNSServiceRef?
            let context = Unmanaged.passUnretained(self).toOpaque()
            let error = DNSServiceResolve(
                &service, 0, 0, name, ServerBrowser.serviceType, domain,
                { _, _, _, error, _, host, port, _, _, context in
                    guard let context else { return }
                    let resolution = Unmanaged<Resolution>.fromOpaque(context).takeUnretainedValue()
                    let target = host.map { String(cString: $0) }
                    resolution.finished(error: error, host: target, port: UInt16(bigEndian: port))
                }, context)
            guard error == kDNSServiceErr_NoError, let service else {
                return finish(.failure(DiscoveryError.failed(error)))
            }
            let handle = Int(bitPattern: service)
            state.withLock { $0.service = handle }
            DNSServiceSetDispatchQueue(service, queue)
        }

        private func finished(error: DNSServiceErrorType, host: String?, port: UInt16) {
            guard error == kDNSServiceErr_NoError, var host, !host.isEmpty else {
                return finish(.failure(error == kDNSServiceErr_NoError ? DiscoveryError.notFound : DiscoveryError.failed(error)))
            }
            // "lobby-7c3f9a12.local." is the same host as "lobby-7c3f9a12.local", and reads as an address.
            if host.hasSuffix(".") { host.removeLast() }
            var components = URLComponents()
            components.scheme = "http"
            components.host = host
            components.port = Int(port)
            finish(components.url.map { .success($0) } ?? .failure(DiscoveryError.notFound))
        }

        /// Ends the resolve and answers, once: a second call finds nothing left to answer.
        private func finish(_ result: Result<URL, any Error>) {
            let continuation = state.withLock { state -> CheckedContinuation<URL, any Error>? in
                if let handle = state.service, let service = DNSServiceRef(bitPattern: handle) {
                    DNSServiceRefDeallocate(service)
                    state.service = nil
                }
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume(with: result)
        }

        func cancel() {
            finish(.failure(CancellationError()))
        }
    }
}
