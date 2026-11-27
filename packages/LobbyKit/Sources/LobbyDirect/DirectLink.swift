// SPDX-License-Identifier: MPL-2.0
import Foundation
import Network

/// The road under the app's local server: the direct connection, kept alive and made again when
/// the network changes, or the server's own address once that answers again.
///
/// A new connection is made beside the old one. What was being sent goes on there from the byte
/// that is missing (`LoopbackServer`), so that a player notices only a pause.
public actor DirectLink {
    public enum State: Hashable, Sendable {
        case idle
        case connecting
        case up(DirectSession.Path)
        /// It was up, and a new connection is on its way.
        case reconnecting
        case down(DirectError)
        /// Requests go to the server's own address.
        case origin
    }

    enum Target: Sendable {
        case none
        case direct(DirectIdentity)
        case origin(Origin)
    }

    public private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            observers.values.forEach { $0.yield(state) }
        }
    }

    private var target: Target = .none
    private var session: DirectSession?
    private var generation = 0
    private var dialing: Task<Void, Never>?
    private var dialingID = 0
    private var tries = 0
    private var nextTry: ContinuousClock.Instant?
    /// No more ringing until somebody asks: the box does not let this device in.
    private var isRefused = false
    private var isInBackground = false
    private var lastHeard = ContinuousClock.now
    private var watching: Task<Void, Never>?
    private var isProbing = false
    private var live: [ObjectIdentifier: Upstream] = [:]
    private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var observers: [UUID: AsyncStream<State>.Continuation] = [:]
    private var learned: (@Sendable (DirectIdentity) async -> Void)?
    private let detours: DirectSession.Detours
    private let patience: Duration
    private let silence: Duration
    private let quietLimit: Duration

    /// What carries the credential. Set with the target.
    private(set) var token: String?

    public init() {
        self.init(detours: .init())
    }

    /// - Parameters:
    ///   - patience: How long a request waits for a road.
    ///   - silence: After which nothing heard on a stream, with something asked, makes the link look.
    ///   - quietLimit: After which nothing heard from the box at all, while something is carried,
    ///     means that the path is gone: the box answers every second then.
    init(
        detours: DirectSession.Detours, patience: Duration = .seconds(30), silence: Duration = .seconds(10),
        quietLimit: Duration = .seconds(3)
    ) {
        self.detours = detours
        self.patience = patience
        self.silence = silence
        self.quietLimit = quietLimit
    }

    public func states() -> AsyncStream<State> {
        let id = UUID()
        let (stream, sink) = AsyncStream.makeStream(of: State.self)
        observers[id] = sink
        sink.onTermination = { [weak self] _ in Task { await self?.forget(id) } }
        sink.yield(state)
        return stream
    }

    private func forget(_ id: UUID) { observers[id] = nil }

    /// Told when the box names new certificates.
    public func onLearned(_ learned: @escaping @Sendable (DirectIdentity) async -> Void) {
        self.learned = learned
    }

    // MARK: What it is for

    /// Uses the direct connection. Dials when the first request comes, or with `connect`.
    public func use(_ identity: DirectIdentity, token: String) {
        self.token = token
        if case .direct(let before) = target, before.boxId == identity.boxId, before.ringKey == identity.ringKey {
            target = .direct(identity)
            return
        }
        reset()
        isRefused = false
        target = .direct(identity)
    }

    /// Sends everything to the server's own address, which was found to be the server. What is
    /// under way goes on there.
    public func use(_ origin: Origin, token: String) {
        self.token = token
        if case .origin(let before) = target, before == origin { return }
        stopDialing()
        target = .origin(origin)
        generation += 1
        state = .origin
        moveOn(closing: session)
        session = nil
        wake()
    }

    /// Off: every connection ends at once.
    public func stop() {
        reset()
        target = .none
        token = nil
        isRefused = false
        state = .idle
        wake()
    }

    private func reset() {
        stopDialing()
        generation += 1
        tries = 0
        nextTry = nil
        session?.close()
        session = nil
        live.values.forEach { $0.interrupt(.superseded) }
    }

    /// Dials now if there is no connection. For the racing between roads, and for a person who
    /// asks again.
    public func connect(askedByPerson: Bool = false) async throws -> DirectSession.Path {
        if askedByPerson { askAgain() }
        guard case .direct = target else { throw DirectError.closed }
        if let session, !session.isOver { return session.path }
        startDialing(now: askedByPerson)
        let began = ContinuousClock.now
        while ContinuousClock.now - began < patience {
            if let session, !session.isOver { return session.path }
            if case .down(let problem) = state { throw problem }
            guard case .direct = target else { throw DirectError.closed }
            try Task.checkCancellation()
            await pause(atMost: .milliseconds(500))
        }
        throw DirectError.noAnswer
    }

    /// The app was at home, or a person asks: a refusal is not for ever.
    public func askAgain() {
        isRefused = false
        tries = 0
        nextTry = nil
    }

    /// Another network, or back from sleep: a new connection beside the old one, if there was one
    /// or somebody waits.
    public func networkChanged() {
        guard case .direct = target else { return }
        tries = 0
        nextTry = nil
        guard session != nil || dialing != nil || !waiting.isEmpty || !live.isEmpty else { return }
        // Nothing rings in the background for nobody.
        if isInBackground, live.isEmpty, waiting.isEmpty { return suspend() }
        stopDialing()
        startDialing(now: true)
    }

    /// Nothing rings in the background, unless a film goes on playing there.
    public func enteredBackground() {
        isInBackground = true
        if live.isEmpty { suspend() }
    }

    private func suspend() {
        stopDialing()
        session?.close()
        session = nil
        if case .direct = target { state = .idle }
    }

    public func becameActive() {
        let was = isInBackground
        isInBackground = false
        if was { networkChanged() }
    }

    public var isInUse: Bool { !live.isEmpty }

    // MARK: Dialing

    private func stopDialing() {
        dialingID += 1
        dialing?.cancel()
        dialing = nil
    }

    private func startDialing(now: Bool = false) {
        guard case .direct = target, dialing == nil else { return }
        if isRefused {
            state = .down(.notAllowed)
            return wake()
        }
        if now { nextTry = nil }
        state = session == nil && state != .reconnecting && live.isEmpty ? .connecting : .reconnecting
        dialingID += 1
        let id = dialingID
        let until = nextTry
        dialing = Task { [weak self] in
            if let until, until > .now { try? await Task.sleep(until: until, clock: .continuous) }
            guard !Task.isCancelled else { return }
            await self?.dial(id)
        }
    }

    private func dial(_ id: Int) async {
        guard id == dialingID, case .direct(let identity) = target else { return }
        let outcome: Result<DirectSession, any Error>
        do {
            outcome = .success(try await DirectSession.connect(identity, stunTurn: tries, detours: detours))
        } catch {
            outcome = .failure(error)
        }
        guard id == dialingID else {
            if case .success(let late) = outcome { late.close() }
            return
        }
        dialing = nil
        switch outcome {
        case .success(let fresh):
            await take(fresh, for: identity)
        case .failure(let error):
            failed(error as? DirectError ?? .noAnswer)
        }
    }

    private func take(_ fresh: DirectSession, for identity: DirectIdentity) async {
        let old = session
        session = fresh
        generation += 1
        tries = 0
        nextTry = nil
        lastHeard = .now
        state = .up(fresh.path)
        if !live.isEmpty { fresh.keepsAsking(true) }
        moveOn(closing: old)
        wake()
        let number = generation
        Task { [weak self] in
            await fresh.waitForEnd()
            await self?.ended(number)
        }
        // Only the box can have said these: they were sealed for this device.
        if fresh.fingerprints != identity.fingerprints, case .direct(var known) = target, known.boxId == identity.boxId {
            known.fingerprints = fresh.fingerprints
            target = .direct(known)
            await learned?(known)
        }
    }

    /// What goes over the old connection goes on over the new one, and then the old one ends.
    private func moveOn(closing old: DirectSession?) {
        for one in live.values where one.generation != generation { one.interrupt(.superseded) }
        guard let old else { return }
        Task {
            // Time for a short answer that is almost here.
            try? await Task.sleep(for: .seconds(2))
            old.close()
        }
    }

    private func failed(_ error: DirectError) {
        tries += 1
        if error == .notAllowed { isRefused = true }
        let wait = min(60, 2 * pow(2, Double(min(tries, 6) - 1))) * Double.random(in: 0.8...1.2)
        nextTry = .now + .seconds(wait)
        if let session, !session.isOver, !isRefused {
            // The old one still works: nothing is lost yet.
            state = .up(session.path)
            return
        }
        // A device the box refuses is one that was removed: the box has ended its connection
        // too, even when that has not been heard here, and what waits on it would wait for ever.
        session?.close()
        session = nil
        live.values.forEach { $0.interrupt(.superseded) }
        state = .down(error)
        wake()
        // Somebody waits, and it is worth another try.
        if !isRefused, !waiting.isEmpty || !live.isEmpty { startDialing() }
    }

    private func ended(_ number: Int) {
        // Its streams end with it. One opened just before the end may never hear that by itself,
        // and would wait for ever.
        for one in live.values where one.generation == number { one.interrupt(.superseded) }
        guard number == generation, case .direct = target else { return }
        session = nil
        if live.isEmpty && waiting.isEmpty || isInBackground && live.isEmpty {
            state = .idle
        } else {
            startDialing(now: true)
        }
    }

    // MARK: Streams

    /// A connection for one request, once there is a road. Waits for one as long as is reasonable.
    func open(since began: ContinuousClock.Instant = .now) async throws -> Upstream {
        let id = UUID()
        while ContinuousClock.now - began < patience {
            try Task.checkCancellation()
            switch target {
            case .none:
                throw DirectError.closed
            case .origin(let origin):
                return keep(Upstream(
                    origin.connection(), session: nil, generation: generation, host: origin.hostHeader,
                    pathPrefix: origin.pathPrefix, heard: {}))
            case .direct(let identity):
                if let session, !session.isOver, let stream = session.stream() {
                    if live.isEmpty { lastHeard = .now }
                    return keep(Upstream(
                        stream, session: session, generation: generation, host: identity.name, pathPrefix: "",
                        heard: { [weak self] in Task { await self?.heard() } }))
                }
                if isRefused {
                    state = .down(.notAllowed)
                    throw DirectError.notAllowed
                }
                if dialing == nil { startDialing() }
            }
            await pause(id, atMost: .seconds(1))
        }
        if case .down(let problem) = state { throw problem }
        throw DirectError.noAnswer
    }

    private func keep(_ one: Upstream) -> Upstream {
        live[ObjectIdentifier(one)] = one
        if live.count == 1 { session?.keepsAsking(true) }
        watch()
        return one
    }

    func closed(_ one: Upstream) {
        live[ObjectIdentifier(one)] = nil
        if live.isEmpty {
            watching?.cancel()
            watching = nil
            session?.keepsAsking(false)
            if isInBackground, waiting.isEmpty { suspend() }
        }
    }

    private func heard() { lastHeard = .now }

    private func pause(_ id: UUID = UUID(), atMost limit: Duration) async {
        let timer = Task { [weak self] in
            if (try? await Task.sleep(for: limit)) != nil { await self?.resume(id) }
        }
        defer { timer.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { return continuation.resume() }
                waiting[id] = continuation
            }
        } onCancel: {
            Task { await self.resume(id) }
        }
    }

    private func resume(_ id: UUID) {
        waiting.removeValue(forKey: id)?.resume()
    }

    private func wake() {
        let all = waiting
        waiting = [:]
        all.values.forEach { $0.resume() }
    }

    // MARK: Silence

    /// While something is carried: a path from which nothing came for a few seconds, though the
    /// box answers every second, is gone (the phone's network gave it another port, or let
    /// nothing through any more), and a new connection is made at once, before the player runs
    /// dry. A connection that is there but on which a request hears nothing is tried with a
    /// question that is always answered, and made again when that is not.
    private func watch() {
        guard watching == nil else { return }
        watching = Task { [weak self, silence, quietLimit] in
            while !Task.isCancelled {
                try? await Task.sleep(for: min(.seconds(2), silence / 2, quietLimit / 4))
                await self?.look()
            }
        }
    }

    private func look() async {
        guard let session, !session.isOver, dialing == nil, case .direct = target, !live.isEmpty else { return }
        // For a connection that came while something was already carried.
        session.keepsAsking(true)
        if let quiet = session.quiet, quiet > quietLimit {
            // Gone, not slow: what it carried goes on over the next one. Over, rather than kept
            // beside the next: a network that lets nothing through gets the usual waits between
            // tries, not a ring every second.
            session.close()
            return ended(generation)
        }
        await probe()
    }

    private func probe() async {
        guard !isProbing, let session, !session.isOver, dialing == nil, case .direct(let identity) = target,
            live.values.contains(where: \.isWaiting), ContinuousClock.now - lastHeard > silence
        else { return }
        isProbing = true
        defer { isProbing = false }
        let number = generation
        let token = token ?? ""
        let answered: Bool
        if let stream = session.stream() {
            stream.start(queue: DispatchQueue(label: "lobby.probe"))
            answered = (try? await Deadline.run(.seconds(4)) {
                try await withTaskCancellationHandler {
                    try await stream.sendKeepingOpen(Data(
                        "GET /v1/me HTTP/1.1\r\nHost: \(identity.name)\r\nAuthorization: Bearer \(token)\r\nConnection: close\r\n\r\n".utf8))
                    return try await !stream.receiveSome().data.isEmpty
                } onCancel: {
                    stream.cancel()
                }
            }) ?? false
            stream.endAndDrain()
        } else {
            answered = false
        }
        guard number == generation else { return }
        if answered {
            lastHeard = .now
        } else {
            networkChanged()
        }
    }
}
