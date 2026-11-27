// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyDirect
import Network

/// How the server is reached now.
public enum Road: String, Codable, Hashable, Sendable {
    /// The home network.
    case home
    case tailscale
    /// Straight from device to server, introduced by a service that learns nothing.
    case direct
    /// The same, over the household's own relay.
    case relay

    /// Only there does the server let a manager manage.
    public var allowsManaging: Bool { self == .home || self == .tailscale }
}

/// Chooses how the server is reached: its address at home, then in the tailnet, then the direct
/// connection, which itself goes over the household's relay when the networks let nothing else
/// through. Every request goes where this says.
///
/// Addresses are used only after the server proved to be there (`ServerLocator`), and only those that
/// may carry the credential (`AddressPolicy`). Over the direct road the server's certificate, known
/// from pairing, takes the place of that check, inside `DirectSession`.
public actor ServerRoad {
    public struct Found: Sendable {
        public var road: Road
        /// With this device's credential. Over the direct road its address is the app's own local
        /// server, which puts the credential on.
        public var client: LobbyClient

        public init(road: Road, client: LobbyClient) {
            self.road = road
            self.client = client
        }
    }

    /// What the app shows of it.
    public enum Condition: Hashable, Sendable {
        case steady
        /// The direct connection is being made again: what plays waits a moment.
        case reconnecting
        case lost(DirectError)
    }

    private let credentials: any CredentialStore
    private let session: URLSession
    private let link: DirectLink
    private let memory: RoadMemory
    private var server: LoopbackServer?
    private var starting: Task<LoopbackServer, any Error>?
    /// Counts `close()`, for a local server that was starting meanwhile.
    private var closes = 0
    private var identity: DirectIdentity?
    private var identityServer: String?
    private var path: NetworkSignature?
    /// Asked the server at home whether it offers the direct road: once a launch is enough.
    private var asked: Set<String> = []
    private var usesDirect: Bool
    private let headStart: Duration
    private let grace: Duration

    /// - Parameters:
    ///   - memory: Which road was right on which network.
    ///   - headStart: How long the addresses at home and in the tailnet go before the direct road.
    ///   - grace: How long they get once the direct road is there.
    public init(
        credentials: any CredentialStore, session: URLSession = .shared, link: DirectLink = DirectLink(),
        memory: RoadMemory = RoadMemory(), usesDirect: Bool = true, headStart: Duration = .milliseconds(1500),
        grace: Duration = .seconds(1)
    ) {
        self.credentials = credentials
        self.session = session
        self.link = link
        self.memory = memory
        self.usesDirect = usesDirect
        self.headStart = headStart
        self.grace = grace
    }

    // MARK: Finding

    /// Where the server answers from here. nil when it answers nowhere.
    ///
    /// - Parameter locate: Asks the addresses at home and in the tailnet.
    public func find(
        _ connection: SavedConnection, token: String, locate: @escaping @Sendable () async -> URL?
    ) async -> Found? {
        guard usesDirect, let identity = await identity(forServer: connection.serverID) else {
            guard let url = await locate() else { return nil }
            return await at(url, connection: connection, token: token)
        }

        enum Event: Sendable {
            case local(URL?)
            case direct(DirectSession.Path?)
            case graceOver
        }
        let network = path?.id
        let goesFirst = memory.road(on: network, server: connection.serverID)
        let wait: Duration = goesFirst == .direct || goesFirst == .relay ? .zero : headStart
        let grace = grace
        return await withTaskGroup(of: Event.self) { group in
            group.addTask { .local(await locate()) }
            group.addTask { [self] in
                do {
                    try await Task.sleep(for: wait)
                    return .direct(try await self.connect(identity, token: token))
                } catch {
                    return .direct(nil)
                }
            }
            var local: URL??
            var direct: DirectSession.Path??
            var graceIsOver = false
            for await event in group {
                switch event {
                case .local(let url):
                    local = .some(url)
                    if let url {
                        group.cancelAll()
                        memory.remember(Self.road(of: url, in: connection), on: network, server: connection.serverID)
                        return await at(url, connection: connection, token: token)
                    }
                case .direct(let path):
                    direct = .some(path)
                    if path != nil, local == nil {
                        group.addTask {
                            try? await Task.sleep(for: grace)
                            return .graceOver
                        }
                    }
                case .graceOver:
                    graceIsOver = true
                }
                if let direct, let path = direct, local != nil || graceIsOver {
                    group.cancelAll()
                    let road: Road = path == .relay ? .relay : .direct
                    memory.remember(road, on: network, server: connection.serverID)
                    return await overDirect(road, token: token)
                }
                if local != nil, direct != nil { break }
            }
            group.cancelAll()
            return nil
        }
    }

    /// A device that was just paired from outside: the direct road, whatever else there may be.
    public func enter(_ identity: DirectIdentity, token: String) async throws -> Found {
        await link.askAgain()
        var path = try? await connect(identity, token: token)
        for _ in 0..<4 where path == nil {
            // The box tells the introducer about a new device a moment after it was approved.
            guard case .down(.notAllowed) = await link.state else { break }
            try await Task.sleep(for: .seconds(2))
            await link.askAgain()
            path = try? await connect(identity, token: token)
        }
        if path == nil { path = try await connect(identity, token: token) }
        guard let found = await overDirect(path == .relay ? .relay : .direct, token: token) else { throw DirectError.closed }
        return found
    }

    /// The direct connection as it is now, without a word to anybody.
    public var isUsingDirect: Bool { usesDirect }

    private func connect(_ identity: DirectIdentity, token: String) async throws -> DirectSession.Path {
        await link.use(identity, token: token)
        return try await link.connect()
    }

    private func at(_ url: URL, connection: SavedConnection, token: String) async -> Found? {
        // What plays over the local server goes on from there.
        if server != nil, let origin = Origin(url) {
            await link.use(origin, token: token)
        } else {
            await link.stop()
        }
        await link.askAgain()
        guard let client = try? LobbyClient(baseURL: url, token: token, session: session) else { return nil }
        return Found(road: Self.road(of: url, in: connection), client: client)
    }

    private func overDirect(_ road: Road, token: String) async -> Found? {
        guard let server = try? await localServer(),
            let client = try? LobbyClient(baseURL: server.base, token: token, session: session, isCarriedByRoad: true)
        else { return nil }
        return Found(road: road, client: client)
    }

    private func localServer() async throws -> LoopbackServer {
        if let server { return server }
        if let starting { return try await starting.value }
        let task = Task { [link] in try await LoopbackServer.start(link: link) }
        starting = task
        defer { starting = nil }
        let generation = closes
        let made = try await task.value
        // Closed while it started: it is not this road's any more.
        guard generation == closes else {
            made.stop()
            throw CancellationError()
        }
        server = made
        return made
    }

    public static func road(of url: URL, in connection: SavedConnection) -> Road {
        if connection.addresses?.home.contains(url) == true { return .home }
        if connection.addresses?.remote.contains(url) == true { return .tailscale }
        let host = url.host?.lowercased() ?? ""
        let isTailnet = host.hasSuffix(".ts.net") || host.hasPrefix("fd7a:115c:a1e0:")
            || (host.hasPrefix("100.") && (64...127).contains(Int(host.split(separator: ".").dropFirst().first ?? "") ?? 0))
        return isTailnet ? .tailscale : .home
    }

    // MARK: Events

    /// The device is on another network, or has the same one again after it was gone.
    public func networkChanged(_ new: NetworkSignature) async {
        let before = path
        path = new
        guard before != nil, before != new, new.isUsable else { return }
        await link.networkChanged()
    }

    /// Whether what is sent costs mobile data.
    public var isOnMobileData: Bool { path?.isExpensive ?? false }

    /// The app came to the front. The system may have taken the local server's port away.
    ///
    /// - Returns: The new address of the local server, when it could not get the old one again.
    public func becameActive() async -> URL? {
        await link.becameActive()
        guard let old = server, await !old.isAlive() else { return nil }
        guard let fresh = try? await LoopbackServer.start(link: link, replacing: old) else {
            server = nil
            return nil
        }
        server = fresh
        return fresh.base == old.base ? nil : fresh.base
    }

    public func enteredBackground() async {
        await link.enteredBackground()
    }

    /// A person asks to try again now.
    public func tryAgain() async {
        await link.askAgain()
    }

    public func conditions() async -> AsyncStream<Condition> {
        let states = await link.states()
        return AsyncStream { sink in
            let task = Task {
                for await state in states {
                    switch state {
                    case .reconnecting: sink.yield(.reconnecting)
                    case .down(let problem): sink.yield(.lost(problem))
                    case .idle, .up, .origin: sink.yield(.steady)
                    // Says nothing yet.
                    case .connecting: break
                    }
                }
                sink.finish()
            }
            sink.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Getting ready

    private static func key(_ serverID: String) -> String { "direct:\(serverID)" }

    public func identity(forServer serverID: String) async -> DirectIdentity? {
        if identityServer == serverID { return identity }
        let stored = try? await credentials.token(forServer: Self.key(serverID))
        identity = stored.flatMap(DirectIdentity.init(encoded:))
        identityServer = serverID
        await link.onLearned { [weak self] learned in try? await self?.keep(learned, forServer: serverID) }
        return identity
    }

    public func keep(_ identity: DirectIdentity, forServer serverID: String) async throws {
        guard identity != self.identity || identityServer != serverID else { return }
        try await credentials.setToken(try identity.encoded(), forServer: Self.key(serverID))
        self.identity = identity
        identityServer = serverID
    }

    /// At home or in the tailnet: gets ready for the direct road when the server offers it, learns
    /// what changed, and forgets it when the server does not offer it any more. Once a launch.
    public func keepReady(_ client: LobbyClient, serverID: String) async {
        guard !client.isCarriedByRoad, asked.insert(serverID).inserted else { return }
        let known = await identity(forServer: serverID)
        do {
            if let fresh = try await client.directIdentity(keeping: known) {
                try await keep(fresh, forServer: serverID)
            } else if known != nil {
                await forgetIdentity(ofServer: serverID)
            }
        } catch {
            // The server did not answer this time: the next time at home.
            asked.remove(serverID)
        }
    }

    /// Paired anew: the server is asked again whether it offers the direct road.
    public func askAgainAfterPairing(serverID: String) async {
        asked.remove(serverID)
        await link.askAgain()
    }

    /// Signed out, or removed by a manager: nothing of it stays.
    public func forget(serverID: String) async {
        await link.stop()
        server?.stop()
        server = nil
        asked.remove(serverID)
        memory.forget(server: serverID)
        await forgetIdentity(ofServer: serverID)
    }

    /// Another server is in use now: every connection of this one ends, its local server stops,
    /// and what it knows stays for when it is used again.
    public func close() async {
        closes += 1
        starting?.cancel()
        starting = nil
        await link.stop()
        server?.stop()
        server = nil
    }

    private func forgetIdentity(ofServer serverID: String) async {
        try? await credentials.removeToken(forServer: Self.key(serverID))
        identity = nil
        identityServer = serverID
    }

    /// The person's switch. Off: no direct connection, and nothing is asked of the introducer.
    public func setUsesDirect(_ uses: Bool) async {
        usesDirect = uses
        if !uses { await link.stop() }
    }
}

/// What tells one network from another, as far as the system says. Not the network's name.
public struct NetworkSignature: Hashable, Sendable {
    public var id: String
    public var isUsable: Bool
    /// Mobile data, or a hotspot of it.
    public var isExpensive: Bool

    public init(id: String, isUsable: Bool, isExpensive: Bool) {
        self.id = id
        self.isUsable = isUsable
        self.isExpensive = isExpensive
    }

    public init(_ path: NWPath) {
        let interfaces = path.availableInterfaces.map { "\($0.type)\($0.name)" }.joined(separator: ",")
        let gateways = path.gateways.map { "\($0)" }.sorted().joined(separator: ",")
        self.init(
            id: "\(interfaces)|\(gateways)", isUsable: path.status == .satisfied,
            isExpensive: path.isExpensive || path.usesInterfaceType(.cellular))
    }
}

/// Which road worked on which network, so that the right one goes first the next time. A guess:
/// it only decides what is tried first.
public struct RoadMemory: Sendable {
    private static let key = "lobby.roads"
    private static let most = 24
    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    private func name(_ network: String, _ server: String) -> String { "\(server)|\(network)" }

    func road(on network: String?, server: String) -> Road? {
        guard let network else { return nil }
        let known = defaults.stringArray(forKey: Self.key) ?? []
        let prefix = name(network, server) + "="
        return known.last { $0.hasPrefix(prefix) }.flatMap { Road(rawValue: String($0.dropFirst(prefix.count))) }
    }

    func remember(_ road: Road, on network: String?, server: String) {
        guard let network, self.road(on: network, server: server) != road else { return }
        let prefix = name(network, server) + "="
        let known = (defaults.stringArray(forKey: Self.key) ?? []).filter { !$0.hasPrefix(prefix) }
        defaults.set(Array((known + [prefix + road.rawValue]).suffix(Self.most)), forKey: Self.key)
    }

    func forget(server: String) {
        let known = (defaults.stringArray(forKey: Self.key) ?? []).filter { !$0.hasPrefix(server + "|") }
        defaults.set(known, forKey: Self.key)
    }
}
