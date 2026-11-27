// SPDX-License-Identifier: MPL-2.0
import Foundation

/// `Me.server.addresses`: where a paired device can reach its server.
public struct ServerAddresses: Codable, Hashable, Sendable {
    /// On the home network, e.g. `http://lobby-7c3f9a12.local:8674`. In the server's order.
    public var home: [URL]
    /// From elsewhere, e.g. over Tailscale. In the server's order of preference.
    public var remote: [URL]

    public init(home: [URL] = [], remote: [URL] = []) {
        self.home = home
        self.remote = remote
    }

    /// An address the server sends that is not a URL is left out, not an error: the others
    /// still work.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        home = (try container.decodeIfPresent([String].self, forKey: .home) ?? []).compactMap(Self.address)
        remote = (try container.decodeIfPresent([String].self, forKey: .remote) ?? []).compactMap(Self.address)
    }

    /// Home first: it is the short way, and it works when the internet does not.
    public var inOrder: [URL] {
        home + remote
    }

    private static func address(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", url.host?.isEmpty == false
        else { return nil }
        return url
    }
}

/// Which addresses may be sent this device's credential.
public enum AddressPolicy {
    /// HTTPS anywhere. Plain HTTP only where nobody outside the household listens: the home
    /// network (`.local` names and private addresses), this device itself, and a tailnet
    /// (`.ts.net` names and Tailscale's own address range), which is encrypted underneath.
    public static func mayCarryCredential(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), var host = url.host?.lowercased(), !host.isEmpty else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        if host.hasSuffix(".") { host.removeLast() }

        // Names that never leave the local network, by RFC 6761 and 6762.
        if host == "localhost" || [".local", ".localhost", ".test", ".home.arpa", ".ts.net"].contains(where: host.hasSuffix) {
            return true
        }
        // A name without a dot is one the home router hands out.
        if !host.contains("."), !host.contains(":") { return true }
        if let v4 = ipv4(host) {
            switch (v4[0], v4[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            // 100.64.0.0/10: carrier-grade NAT space, where Tailscale puts its devices.
            case (100, 64...127): return true
            default: return false
            }
        }
        // IPv6: this device, link-local, unique local, and Tailscale's fd7a:115c:a1e0::/48.
        let v6 = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if v6.contains(":") {
            return v6 == "::1" || v6.hasPrefix("fe80:") || v6.hasPrefix("fc") || v6.hasPrefix("fd")
        }
        return false
    }

    private static func ipv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let numbers = parts.compactMap { part in part.allSatisfy(\.isNumber) ? Int(part) : nil }
        return numbers.count == 4 && numbers.allSatisfy { (0...255).contains($0) } ? numbers : nil
    }
}

/// Finds which of a server's addresses works from where the device is now.
public enum ServerLocator {
    /// The first address in `candidates` at which the server with `serverID` answers.
    ///
    /// Every address is asked `GET /v1/server`, which needs no credential, at the same time.
    /// An earlier address wins over a later one: when a later one answers first, the earlier
    /// ones get `grace` to answer too. An address that answers as another server, or that may
    /// not carry the credential (`AddressPolicy`), is never returned: the caller sends the
    /// device's credential to what this returns, and to nothing else.
    ///
    /// - Parameters:
    ///   - timeout: How long one address gets to answer.
    ///   - grace: The wait for an earlier address once a later one has answered.
    /// - Returns: nil when the server answers at none of them.
    public static func locate(
        serverID: String, among candidates: [URL], session: URLSession = .shared, timeout: TimeInterval = 4,
        grace: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(1)) }
    ) async -> URL? {
        await firstInOrder(of: candidates, grace: grace) { address in
            let info = try? await LobbyClient(baseURL: address, session: session).serverInfo(timeout: timeout)
            return info?.id == serverID
        }
    }

    /// The choosing, apart from the asking: `isTheServer` says whether the server answers at
    /// an address.
    static func firstInOrder(
        of candidates: [URL], grace: @escaping @Sendable () async -> Void,
        isTheServer: @escaping @Sendable (URL) async -> Bool
    ) async -> URL? {
        var seen: Set<URL> = []
        let addresses = candidates.filter { AddressPolicy.mayCarryCredential($0) && seen.insert($0).inserted }
        guard !addresses.isEmpty else { return nil }

        enum Event: Sendable {
            case answered(Int, isTheServer: Bool)
            case graceOver
        }
        return await withTaskGroup(of: Event.self) { group in
            for (index, address) in addresses.enumerated() {
                group.addTask {
                    .answered(index, isTheServer: await isTheServer(address))
                }
            }
            var finished: Set<Int> = []
            var best: Int?
            for await event in group {
                switch event {
                case .answered(let index, let isTheServer):
                    finished.insert(index)
                    if isTheServer, index < best ?? .max {
                        if best == nil {
                            group.addTask {
                                await grace()
                                return .graceOver
                            }
                        }
                        best = index
                    }
                case .graceOver:
                    group.cancelAll()
                    return best.map { addresses[$0] }
                }
                if let best, (0..<best).allSatisfy(finished.contains) {
                    group.cancelAll()
                    return addresses[best]
                }
                if best == nil, finished.count == addresses.count {
                    return nil
                }
            }
            return best.map { addresses[$0] }
        }
    }
}
