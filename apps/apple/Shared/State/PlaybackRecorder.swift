// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// Writes down where the viewer is in one film or episode, and sends it to the server.
///
/// Every position goes into `ProgressStore`'s file first, so it survives the app being closed
/// or the Pi being unreachable. The server hears about it when playback pauses, ends or closes,
/// and once a minute while it plays.
@MainActor
final class PlaybackRecorder {
    enum Outcome: Hashable, Sendable {
        /// Nothing was worth writing down.
        case unchanged
        case recorded
        /// Written down, and the server refused this device's credential when it was sent.
        case requiresPairing(LobbyError)
    }

    /// While playing, queued positions are sent this often.
    static let flushEveryMs = 60_000

    let profileID: String
    let itemID: String
    private(set) var durationMs: Int?
    private let store: ProgressStore
    private let client: LobbyClient

    private var hasProgress: Bool
    private var lastRecorded: (positionMs: Int, completed: Bool)?
    private var lastFlushedAtMs: Int?
    /// The last failure to write to the device's own file, for the player to show.
    private(set) var storageError: (any Error)?

    /// - Parameter hasProgress: The viewer already has progress for this item.
    init(
        profileID: String, itemID: String, durationMs: Int?, hasProgress: Bool, store: ProgressStore,
        client: LobbyClient
    ) {
        self.profileID = profileID
        self.itemID = itemID
        self.durationMs = durationMs
        self.hasProgress = hasProgress
        self.store = store
        self.client = client
    }

    /// The player learned how long the file is (when the catalogue did not know).
    func setDuration(ms: Int) {
        if durationMs == nil, ms > 0 {
            durationMs = ms
        }
    }

    /// Called about once a second while playing. Writes at most every ten seconds.
    @discardableResult
    func tick(positionMs: Int) async -> Outcome {
        guard PlaybackPolicy.shouldRecordTick(positionMs: positionMs, lastRecordedMs: lastRecorded?.positionMs) else {
            return .unchanged
        }
        let dueForFlush = lastFlushedAtMs.map { abs(positionMs - $0) >= Self.flushEveryMs } ?? false
        return await record(positionMs: positionMs, reachedEnd: false, flush: dueForFlush)
    }

    /// Playback paused, the player closed, or the app went to the background.
    ///
    /// - Parameter sends: False to only write it down on the device; `send()` follows. On a
    ///   slow link nobody waits for the server before the player goes away.
    @discardableResult
    func checkpoint(positionMs: Int, sends: Bool = true) async -> Outcome {
        await record(positionMs: positionMs, reachedEnd: false, flush: sends)
    }

    /// The film or episode played to its end, or the viewer chose Play Next in the credits.
    @discardableResult
    func finish(positionMs: Int? = nil, sends: Bool = true) async -> Outcome {
        await record(positionMs: positionMs ?? durationMs ?? lastRecorded?.positionMs ?? 0, reachedEnd: true, flush: sends)
    }

    /// Sends what was written down and not sent yet.
    @discardableResult
    func send() async -> Outcome {
        if let lastRecorded { lastFlushedAtMs = lastRecorded.positionMs }
        do {
            let result = try await store.flush(using: client)
            if let stopped = result.stoppedBy, stopped.requiresPairing {
                return .requiresPairing(stopped)
            }
        } catch {
            storageError = error
        }
        return .unchanged
    }

    private func record(positionMs: Int, reachedEnd: Bool, flush: Bool) async -> Outcome {
        let position = max(0, positionMs)
        let completed = reachedEnd || PlaybackPolicy.isCompleted(positionMs: position, durationMs: durationMs)

        var outcome = Outcome.unchanged
        let isNew = lastRecorded.map { $0.positionMs != position || $0.completed != completed } ?? true
        if isNew, completed || PlaybackPolicy.isWorthRecording(positionMs: position, hasProgress: hasProgress) {
            do {
                try await store.record(
                    profileID: profileID, itemID: itemID, positionMs: position, durationMs: durationMs,
                    completed: completed)
                hasProgress = true
                lastRecorded = (position, completed)
                if lastFlushedAtMs == nil { lastFlushedAtMs = position }
                storageError = nil
                outcome = .recorded
            } catch {
                storageError = error
                return .unchanged
            }
        }

        if flush {
            lastFlushedAtMs = position
            let sent = await send()
            if sent != .unchanged { return sent }
        }
        return outcome
    }
}
