// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

/// The now-playing panel's rules, apart from the screen: how far, which buttons work, and where a
/// drag or a skip lands.
struct RemotePanelTests {
    private let everything = ["pause", "resume", "seek", "skip", "next", "stop", "setAudio", "setSubtitle"]

    private func tv(
        _ status: RemotePlayerStatus = .playing, duration: Int? = 3_600_000, next: String? = nil, volume: Double? = nil,
        capabilities: [String]? = nil, controllable: Bool = true
    ) -> ShownDevice {
        let state = RemotePlayerState(
            itemId: "film", status: status, positionMs: 0, at: 0, durationMs: duration, volume: volume, nextItemId: next)
        return ShownDevice(
            id: "tv", name: "Living Room", platform: .tvos, online: true, canPlay: true, controllable: controllable,
            capabilities: capabilities ?? everything, player: .visible(state))
    }

    private func model(_ device: ShownDevice, at position: Int = 600_000) -> RemotePanelModel {
        RemotePanelModel(device: device, positionMs: position)
    }

    @Test func howFarItIsIsTextAndAFraction() {
        let panel = model(tv(), at: 900_000)
        #expect(panel.fraction == 0.25)
        #expect(panel.elapsedText == "15:00")
        #expect(panel.remainingText == "-45:00")
        let long = model(tv(duration: 7_500_000), at: 3_723_000)
        #expect(long.elapsedText == "1:02:03")
        #expect(long.remainingText == "-1:01:57")
    }

    @Test func thePlaceStaysInsideTheFilm() {
        #expect(model(tv(), at: 9_999_999).positionMs == 3_600_000)
        #expect(model(tv(), at: -5).positionMs == 0)
        #expect(model(tv(duration: nil), at: 5_000).fraction == 0)
        #expect(model(tv(duration: nil), at: 5_000).remainingText == "")
    }

    @Test func aDragLandsWhereTheFingerIs() {
        let panel = model(tv())
        #expect(panel.seekTarget(fraction: 0.5) == 1_800_000)
        #expect(panel.seekTarget(fraction: -1) == 0)
        #expect(panel.seekTarget(fraction: 4) == 3_600_000)
        #expect(model(tv(duration: nil)).seekTarget(fraction: 0.5) == nil)
    }

    @Test func aSkipIsTenBackAndThirtyForwardAndNeverLeavesTheFilm() {
        #expect(RemotePanelModel.backSeconds == 10)
        #expect(RemotePanelModel.forwardSeconds == 30)
        #expect(model(tv(), at: 600_000).skipTarget(seconds: -10) == 590_000)
        #expect(model(tv(), at: 600_000).skipTarget(seconds: 30) == 630_000)
        #expect(model(tv(), at: 4_000).skipTarget(seconds: -10) == 0)
        #expect(model(tv(), at: 3_590_000).skipTarget(seconds: 30) == 3_600_000)
    }

    @Test func playingOffersPauseAndPausedOffersResume() {
        #expect(model(tv(.playing)).isPlaying)
        #expect(model(tv(.buffering)).isPlaying)
        #expect(!model(tv(.paused)).isPlaying)
        #expect(model(tv(.paused)).statusWords == "Paused")
        #expect(model(tv(.playing, capabilities: ["resume"])).canPlayPause == false)
        #expect(model(tv(.paused, capabilities: ["resume"])).canPlayPause)
    }

    @Test func buttonsFollowWhatTheDeviceCan() {
        let all = model(tv(next: "episode-2"))
        #expect(all.canSeek && all.canSkip && all.canNext && all.canStop)
        // No next episode: no next button.
        #expect(!model(tv()).canNext)
        // A device that cannot seek: the bar is for looking at.
        #expect(!model(tv(capabilities: ["pause", "skip"])).canSeek)
        // Without a length there is nothing to drag.
        #expect(!model(tv(duration: nil)).canSeek)
        // What a child may not control is not offered at all.
        let locked = model(tv(next: "episode-2", controllable: false))
        #expect(!locked.canPlayPause && !locked.canSeek && !locked.canSkip && !locked.canNext && !locked.canStop)
    }

    @Test func volumeOnlyShowsWhenTheDeviceTakesIt() {
        #expect(model(tv(volume: 0.4)).volume == nil)
        #expect(model(tv(volume: 0.4, capabilities: everything + ["setVolume"])).volume == 0.4)
        #expect(model(tv(volume: nil, capabilities: everything + ["setVolume"])).volume == nil)
    }
}
