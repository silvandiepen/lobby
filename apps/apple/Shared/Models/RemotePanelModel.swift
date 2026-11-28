// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// What the now-playing panel shows and offers for one other device: where it is, which buttons
/// work, and where a drag or a skip lands. Pure, so that it is tested without the channel; the
/// panel (`RemotePanelBody`) only draws it.
struct RemotePanelModel: Equatable {
    /// How far the skip buttons go: back a little, forward a little more, as a remote does.
    static let backSeconds = 10
    static let forwardSeconds = 30

    let status: RemotePlayerStatus
    /// Where it is now, never past the end.
    let positionMs: Int
    /// nil: it cannot tell (a live stream, or a device from before).
    let durationMs: Int?
    let canPlayPause: Bool
    let canSeek: Bool
    let canSkip: Bool
    let canNext: Bool
    let canStop: Bool
    /// The device's own volume, 0 to 1, only when the device both says it and takes `setVolume`.
    let volume: Double?

    init(device: ShownDevice, positionMs: Int) {
        let state = device.player?.state
        let duration = state?.durationMs.flatMap { $0 > 0 ? $0 : nil }
        status = device.player?.status ?? .playing
        durationMs = duration
        self.positionMs = duration.map { min(max(0, positionMs), $0) } ?? max(0, positionMs)
        let control = device.controllable && state != nil
        canPlayPause = control && device.can(Self.plays(status) ? "pause" : "resume")
        canSeek = control && duration != nil && device.can("seek")
        canSkip = control && device.can("skip")
        canNext = control && state?.nextItemId != nil && device.can("next")
        canStop = control && device.can("stop")
        volume = control && device.can("setVolume") ? state?.volume : nil
    }

    static func plays(_ status: RemotePlayerStatus) -> Bool { status == .playing || status == .buffering }

    var isPlaying: Bool { Self.plays(status) }

    /// 0 to 1.
    var fraction: Double {
        guard let durationMs, durationMs > 0 else { return 0 }
        return Double(positionMs) / Double(durationMs)
    }

    var elapsedText: String { MediaFormat.clock(ms: positionMs) }

    /// "-41:07"; empty without a length.
    var remainingText: String {
        guard let durationMs else { return "" }
        return "-" + MediaFormat.clock(ms: max(0, durationMs - positionMs))
    }

    /// Where a drag to `fraction` of the bar lands.
    func seekTarget(fraction: Double) -> Int? {
        guard let durationMs else { return nil }
        return Int((min(max(0, fraction), 1) * Double(durationMs)).rounded())
    }

    /// Where a skip of `seconds` (negative: back) lands, kept inside the film.
    func skipTarget(seconds: Int) -> Int {
        let target = positionMs + seconds * 1000
        return min(max(0, target), durationMs ?? .max)
    }

    /// The device's state in one word, for under the title.
    var statusWords: String {
        switch status {
        case .paused: "Paused"
        case .loading, .buffering: "Starting"
        case .ended: "Finished"
        case .error: "Stopped"
        default: "Playing"
        }
    }
}
