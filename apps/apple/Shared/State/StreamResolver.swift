// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// What the player is given to play.
struct ResolvedStream: Hashable, Sendable {
    var url: URL
    var mode: PlaybackMode
    /// True while the server is still writing the copy: the stream grows, and a seek has to stay
    /// inside what the player reports as seekable.
    var isStillBeingWritten: Bool
    /// The server's answer the stream came with: how far the copy reaches and how fast it grows.
    var playback: Playback
}

/// Why a file cannot be played right now, in the viewer's terms.
struct StreamFailure: Error, Hashable, Sendable {
    var message: String
    /// Set when the server refused this device's credential.
    var requiresPairing: LobbyError?
}

/// Asks Lobby Server how to play a file, and waits while it prepares one that needs it.
///
/// The rules are in `docs/playback.md` ("What the Apple apps must do"): always ask first, play
/// the URL that comes back, ask again about once a second while there is none, and to resume
/// part-way wait until the copy reaches that position.
struct StreamResolver: Sendable {
    /// What to tell the viewer while waiting.
    enum Waiting: Hashable, Sendable {
        /// Another file is being prepared first.
        case queued
        /// 0…1 of the copy is written.
        case preparing(progress: Double)
    }

    var client: LobbyClient
    var sleep: @Sendable (Duration) async throws -> Void
    static let pollEvery = Duration.seconds(1)

    /// - Parameters:
    ///   - startMs: Where in the file playback will start.
    ///   - waiting: Called with every answer that is not playable yet.
    func resolve(
        assetID: String, startMs: Int, waiting: @MainActor (Waiting) -> Void
    ) async throws(StreamFailure) -> ResolvedStream {
        while true {
            let playback: Playback
            do {
                playback = try await client.playback(assetID: assetID)
            } catch {
                // The server is busy with others: this waits its turn, as in a queue.
                if let pause = (error as? LobbyError)?.pauseWhenBusy {
                    await waiting(.queued)
                    do {
                        try await sleep(pause)
                    } catch {
                        throw StreamFailure(message: "Cancelled.")
                    }
                    continue
                }
                throw Self.failure(for: error)
            }

            switch playback.state {
            case .unsupported:
                throw StreamFailure(message: playback.message ?? "This file cannot be played on Apple devices.")
            case .failed:
                throw StreamFailure(message: playback.message ?? "Lobby Server could not get this file ready.")
            case .unknown(let state):
                throw StreamFailure(message: "Lobby Server answered \"\(state)\", which this version of the app does not know. Update Lobby.")
            case .ready, .preparing, .queued:
                break
            }

            if let url = playback.streamURL, playback.canStart(atMs: startMs) {
                return ResolvedStream(
                    url: url, mode: playback.mode ?? .direct, isStillBeingWritten: playback.state != .ready,
                    playback: playback)
            }

            await waiting(playback.state == .queued ? .queued : .preparing(progress: playback.progress))
            do {
                try await sleep(Self.pollEvery)
            } catch {
                throw StreamFailure(message: "Cancelled.")
            }
        }
    }

    private static func failure(for error: any Error) -> StreamFailure {
        guard let error = error as? LobbyError else {
            return StreamFailure(message: error.localizedDescription)
        }
        if error.isUnreachable {
            return StreamFailure(message: "Lobby Server cannot be reached. Check that this device is on the home network or connected to Tailscale.")
        }
        if error.requiresPairing {
            return StreamFailure(message: error.localizedDescription, requiresPairing: error)
        }
        if case .notFound = error {
            return StreamFailure(message: "This is no longer on Lobby Server.")
        }
        return StreamFailure(message: error.localizedDescription)
    }
}
