// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// The rules of resuming and finishing. The server stores what the app tells it: the app decides
/// when something counts as watched.
enum PlaybackPolicy {
    /// Watched once this little is left: the last 5 %, and never more than eight minutes, so a
    /// long film with long credits still needs most of its last reel.
    static let completionFraction = 0.05
    static let longestCreditsMs = 8 * 60_000

    /// Nothing is written down before this, so opening a film by accident does not put it on
    /// Continue Watching.
    static let earliestRecordedMs = 5_000

    /// While playing, the position is written down this often.
    static let recordEveryMs = 10_000

    /// True once the viewer is in the credits. Never true when the duration is unknown: then
    /// only reaching the end counts.
    static func isCompleted(positionMs: Int, durationMs: Int?) -> Bool {
        guard let durationMs, durationMs > 0 else { return false }
        let credits = min(Int(Double(durationMs) * completionFraction), longestCreditsMs)
        return positionMs >= durationMs - credits
    }

    /// Where Play starts: where the viewer stopped, or the beginning when they never started,
    /// finished it, or stopped in the credits.
    static func resumePosition(for progress: PlaybackProgress?, durationMs: Int?) -> Int {
        guard let progress, !progress.completed, progress.positionMs > 0 else { return 0 }
        let duration = durationMs ?? progress.durationMs
        return isCompleted(positionMs: progress.positionMs, durationMs: duration) ? 0 : progress.positionMs
    }

    /// Whether a position is worth writing down.
    ///
    /// - Parameter hasProgress: The viewer already has progress for this item. Then even 0:00
    ///   is written, because scrubbing back to the start is a change.
    static func isWorthRecording(positionMs: Int, hasProgress: Bool) -> Bool {
        hasProgress || positionMs >= earliestRecordedMs
    }

    /// While playing: whether enough changed since the last time the position was written down.
    static func shouldRecordTick(positionMs: Int, lastRecordedMs: Int?) -> Bool {
        guard let lastRecordedMs else { return true }
        return abs(positionMs - lastRecordedMs) >= recordEveryMs
    }
}
