// SPDX-License-Identifier: MPL-2.0
import AVFoundation
import Foundation
import LobbyKit
import Observation

/// Reads the player once a second and keeps what to say about its waiting.
@MainActor
@Observable
final class BufferMonitor {
    private(set) var notice: BufferNotice?
    /// Seconds since the player began to ask the server, while there is nothing to play yet.
    private(set) var askingFor = 0.0

    private let model: PlayerModel
    private var watch = BufferWatch()
    private let started = ContinuousClock.now
    private var askingSince: Double?

    init(model: PlayerModel) {
        self.model = model
    }

    var explanation: String? {
        let file = model.request.file
        return notice?.explanation(
            filmBitrate: BufferWatch.bitrate(sizeBytes: file.sizeBytes, durationMs: file.durationMs ?? model.request.durationMs))
    }

    /// Runs for as long as the player is on screen.
    func run() async {
        while !Task.isCancelled {
            take()
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    private func take() {
        let now = (ContinuousClock.now - started) / .seconds(1)
        if model.stage == .loading {
            if askingSince == nil { askingSince = now }
        } else {
            askingSince = nil
        }
        let asking = askingSince.map { now - $0 } ?? 0
        if askingFor != asking { askingFor = asking }

        let player = model.player
        let isWaiting = model.stage == .playing
            && (!model.hasStarted || player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
        let ahead = BufferWatch.secondsAhead(
            of: player.currentTime().seconds,
            in: PlayerModel.bufferedMs(of: player.currentItem?.loadedTimeRanges ?? []))
        watch.add(.init(
            at: now, isWaiting: isWaiting, loadedSeconds: ahead,
            isForServer: model.preparing.map { !model.hasStarted || $0.hasCaughtUp } ?? false))
        // Only a change is told: a notice that is the same need not be drawn again.
        if notice != watch.notice { notice = watch.notice }
    }
}
