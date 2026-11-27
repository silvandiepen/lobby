// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A progress change made on this device that the server has not answered yet.
public struct PendingProgressOperation: Codable, Hashable, Sendable, Identifiable {
    /// Fresh per change, and the same on every retry of that change.
    public var opId: String
    public var profileID: String
    public var itemID: String
    /// The revision this device had seen for the item when the viewer made the change.
    public var baseRevision: Int?
    public var positionMs: Int
    public var durationMs: Int?
    public var completed: Bool
    public var updatedAt: Date
    /// True once the change was sent at least once. The server may have it, so it is never
    /// replaced by a later change, only followed by one.
    public var attempted: Bool

    public var id: String { opId }

    var update: ProgressUpdate {
        ProgressUpdate(
            opId: opId, baseRevision: baseRevision, positionMs: positionMs, durationMs: durationMs,
            completed: completed, updatedAt: updatedAt)
    }

    func progress(revision: Int) -> PlaybackProgress {
        PlaybackProgress(
            itemId: itemID, positionMs: positionMs, durationMs: durationMs, completed: completed,
            revision: revision, updatedAt: updatedAt)
    }
}

/// What one `flush` did.
public struct ProgressFlushResult: Hashable, Sendable {
    /// Changes the server accepted.
    public var accepted = 0
    /// Changes that lost to a later one on the server. Its progress replaced the local one.
    public var conflicts = 0
    /// Changes the server will never take (the item or profile is gone, for example). Dropped.
    public var rejected: [Rejection] = []
    /// Changes still waiting.
    public var remaining = 0
    /// Why the flush stopped before the queue was empty: the server was unreachable, or the
    /// device has to pair again. nil when everything was sent.
    public var stoppedBy: LobbyError?

    public struct Rejection: Hashable, Sendable {
        public var operation: PendingProgressOperation
        public var error: LobbyError
    }
}

/// Progress per viewer: what the server last said, what the viewer did since, and the queue of
/// changes that still have to reach the server.
///
/// Every change is written to the file before anything is sent, so progress made on a flight
/// survives quitting the app. `flush(using:)` sends the queue in order when the server can be
/// reached. Nothing here waits or retries on a timer: the app calls `flush` when it comes to
/// the foreground, when the server becomes reachable and when playback pauses or ends.
public actor ProgressStore {
    /// Which progress of the server a store keeps: the films' (`/v1/profiles/…/progress`) or
    /// music's (`/v1/music/profiles/…/progress`, books and long tracks). The rules are the same.
    public enum Routes: Sendable {
        case films, music
    }

    /// Raise together with a case in `migrate(version:data:)`.
    static let formatVersion = 1

    struct ProfileState: Codable {
        /// The `revision` of the last `GET …/progress`, passed as `since` next time.
        var sinceRevision: Int?
        /// The server's progress per item id, as last heard.
        var known: [String: PlaybackProgress] = [:]
    }

    struct Stored: Codable {
        var version = ProgressStore.formatVersion
        var profiles: [String: ProfileState] = [:]
        var queue: [PendingProgressOperation] = []
    }

    private let fileURL: URL
    private let routes: Routes
    private let now: @Sendable () -> Date
    private let makeOperationID: @Sendable () -> String

    private var loaded = false
    private var state = Stored()
    private var isFlushing = false
    /// Set when an unreadable file is in the way and could not be moved. Every write then fails
    /// with this error, until `clear()`.
    private var unwritable: (any Error)?

    /// - Parameters:
    ///   - fileURL: Where progress is kept, e.g. `LobbyStorage.progressFile(in:)`.
    ///   - now: The clock that stamps a change, for tests.
    ///   - makeOperationID: The source of operation ids, for tests.
    ///   - routes: Films, or music.
    public init(
        fileURL: URL,
        routes: Routes = .films,
        now: @escaping @Sendable () -> Date = { Date() },
        makeOperationID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.fileURL = fileURL
        self.routes = routes
        self.now = now
        self.makeOperationID = makeOperationID
    }

    // MARK: Reading

    /// A viewer's progress by item id: the server's, with this device's unsent changes on top.
    public func progress(profileID: String) -> [String: PlaybackProgress] {
        loadIfNeeded()
        var result = state.profiles[profileID]?.known ?? [:]
        for operation in state.queue where operation.profileID == profileID {
            let known = result[operation.itemID]
            // The same rule the server applies: the later change wins.
            if known.map({ operation.updatedAt >= $0.updatedAt }) ?? true {
                result[operation.itemID] = operation.progress(revision: known?.revision ?? 0)
            }
        }
        return result
    }

    public func progress(profileID: String, itemID: String) -> PlaybackProgress? {
        progress(profileID: profileID)[itemID]
    }

    /// The changes that have not reached the server, oldest first.
    public func pendingOperations() -> [PendingProgressOperation] {
        loadIfNeeded()
        return state.queue
    }

    // MARK: Writing

    /// Records what the viewer did and queues it for the server.
    ///
    /// A change that was never sent is replaced by a newer one for the same viewer and item, so
    /// an hour of playback offline leaves one queued change per item, not one per position tick.
    @discardableResult
    public func record(
        profileID: String, itemID: String, positionMs: Int, durationMs: Int?, completed: Bool
    ) throws -> PlaybackProgress {
        loadIfNeeded()
        let known = state.profiles[profileID]?.known[itemID]
        let operation = PendingProgressOperation(
            opId: makeOperationID(), profileID: profileID, itemID: itemID,
            baseRevision: known?.revision, positionMs: max(0, positionMs), durationMs: durationMs,
            completed: completed, updatedAt: now(), attempted: false)

        let replaceable = state.queue.lastIndex {
            $0.profileID == profileID && $0.itemID == itemID
        }
        if let replaceable, !state.queue[replaceable].attempted {
            state.queue[replaceable] = operation
        } else {
            state.queue.append(operation)
        }
        try persist()
        return operation.progress(revision: known?.revision ?? 0)
    }

    /// Marks an item watched: `completed: true`, keeping the position.
    @discardableResult
    public func markWatched(profileID: String, itemID: String, durationMs: Int? = nil) throws -> PlaybackProgress {
        let existing = progress(profileID: profileID, itemID: itemID)
        return try record(
            profileID: profileID, itemID: itemID, positionMs: existing?.positionMs ?? 0,
            durationMs: durationMs ?? existing?.durationMs, completed: true)
    }

    /// Marks an item unwatched: `positionMs: 0, completed: false`. Also what Restart does.
    @discardableResult
    public func markUnwatched(profileID: String, itemID: String) throws -> PlaybackProgress {
        let existing = progress(profileID: profileID, itemID: itemID)
        return try record(
            profileID: profileID, itemID: itemID, positionMs: 0, durationMs: existing?.durationMs,
            completed: false)
    }

    // MARK: Server

    /// Sends the queue, oldest change first.
    ///
    /// - An accepted change takes the server's answer as the known progress.
    /// - A `409 conflict` takes the server's progress and drops the local change.
    /// - An unreachable server, or one that says to come back later, stops the flush. The queue
    ///   stays as it is and the same operation ids are sent next time.
    /// - A revoked or unknown credential stops the flush too, and keeps the queue for after
    ///   pairing again: profiles outlive a device grant.
    /// - Any other refusal can never succeed, so the change is dropped and reported.
    ///
    /// A call made while another flush is running returns at once with what is waiting.
    @discardableResult
    public func flush(using client: LobbyClient) async throws -> ProgressFlushResult {
        loadIfNeeded()
        var result = ProgressFlushResult()
        guard !isFlushing else {
            result.remaining = state.queue.count
            return result
        }
        isFlushing = true
        defer { isFlushing = false }

        while var operation = state.queue.first {
            if !operation.attempted {
                // Written down before it leaves, so a crash mid-request retries this exact change.
                operation.attempted = true
                state.queue[0] = operation
                try persist()
            }

            do {
                let accepted = switch routes {
                case .films:
                    try await client.putProgress(
                        profileID: operation.profileID, itemID: operation.itemID, update: operation.update)
                case .music:
                    try await client.putMusicProgress(
                        profileID: operation.profileID, itemID: operation.itemID, update: operation.update)
                }
                setKnown(accepted, profileID: operation.profileID)
                result.accepted += 1
            } catch let error as LobbyError {
                if case .conflict(_, let serverProgress) = error {
                    if let serverProgress {
                        setKnown(serverProgress, profileID: operation.profileID)
                    }
                    result.conflicts += 1
                } else if error.isTransient || error.requiresPairing {
                    result.stoppedBy = error
                    break
                } else {
                    result.rejected.append(.init(operation: operation, error: error))
                }
            }

            // The queue may have changed while the request was out.
            state.queue.removeAll { $0.opId == operation.opId }
            try persist()
        }

        result.remaining = state.queue.count
        return result
    }

    /// Fetches what changed for a viewer since the last refresh, from any device.
    public func refresh(profileID: String, using client: LobbyClient) async throws {
        loadIfNeeded()
        let since = state.profiles[profileID]?.sinceRevision
        let list = switch routes {
        case .films: try await client.progress(profileID: profileID, since: since)
        case .music: try await client.musicProgress(profileID: profileID, since: since)
        }
        var profile = state.profiles[profileID] ?? ProfileState()
        for progress in list.progress {
            // A flush may have stored a newer answer for the item while this request was out.
            if let known = profile.known[progress.itemId], known.revision > progress.revision { continue }
            profile.known[progress.itemId] = progress
        }
        profile.sinceRevision = list.revision
        state.profiles[profileID] = profile
        try persist()
    }

    /// Sends this device's changes, then fetches everyone else's. What the app calls when the
    /// server becomes reachable.
    @discardableResult
    public func synchronise(profileID: String, using client: LobbyClient) async throws -> ProgressFlushResult {
        let result = try await flush(using: client)
        if let stoppedBy = result.stoppedBy {
            throw stoppedBy
        }
        try await refresh(profileID: profileID, using: client)
        return result
    }

    /// Forgets a viewer who was deleted on the server, with their queued changes.
    public func removeProfile(_ profileID: String) throws {
        loadIfNeeded()
        state.profiles[profileID] = nil
        state.queue.removeAll { $0.profileID == profileID }
        try persist()
    }

    /// Forgets everything, for pairing with another server.
    public func clear() throws {
        loaded = true
        unwritable = nil
        state = Stored()
        try persist()
    }

    // MARK: File

    private func setKnown(_ progress: PlaybackProgress, profileID: String) {
        state.profiles[profileID, default: ProfileState()].known[progress.itemId] = progress
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        switch VersionedFile.read(
            Stored.self, from: fileURL, currentVersion: Self.formatVersion, migrate: Self.migrate)
        {
        case .value(let stored):
            state = stored
        case .missing:
            break
        case .unreadable:
            // Kept beside the new file instead of overwritten: it may hold unsent progress that
            // a later build can still read.
            do {
                let aside = fileURL.appendingPathExtension("unreadable")
                if FileManager.default.fileExists(atPath: aside.path) {
                    try FileManager.default.removeItem(at: aside)
                }
                try FileManager.default.moveItem(at: fileURL, to: aside)
            } catch {
                // It could not be set aside, so nothing may be written over it.
                unwritable = error
            }
        }
    }

    private func persist() throws {
        if let unwritable { throw unwritable }
        try VersionedFile.write(state, to: fileURL)
    }

    /// Version 1 is the first format, so there is nothing older to read yet. When the format
    /// changes: raise `formatVersion` and decode the previous shape here into `Stored`.
    private static func migrate(version: Int, data: Data) throws -> Stored? {
        nil
    }
}
