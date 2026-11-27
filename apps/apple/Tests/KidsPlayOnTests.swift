// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

/// Play on TV from the kids screens (docs/decisions.md, "Kids mode plays on the TV"), apart from the network: which TVs the button
/// offers, which one plays the child's film, and what a child is told when it does not work.
struct KidsPlayOnTests {
    private func device(
        _ id: String, _ name: String, platform: DevicePlatform = .tvos, online: Bool = true, canPlay: Bool = true,
        controllable: Bool = false, player: ShownPlayer? = nil, wakeable: Bool = false, isSelf: Bool = false
    ) -> ShownDevice {
        ShownDevice(
            id: id, name: name, platform: platform, isSelf: isSelf, online: online, foreground: online, canPlay: canPlay,
            controllable: controllable, player: player, wakeable: wakeable)
    }

    private func playing(_ status: RemotePlayerStatus = .playing) -> ShownPlayer {
        .visible(RemotePlayerState(itemId: "film", status: status, positionMs: 0, at: 0, durationMs: 60_000, rate: 1))
    }

    @Test func onlyAppleTVsThatCanPlayNowAreOffered() {
        let all = [
            device("me", "Phone", platform: .ios, isSelf: true),
            device("b", "Bedroom"),
            device("a", "Attic", canPlay: false),
            device("l", "Living Room"),
            device("m", "Desk", platform: .macos),
            device("o", "Off", online: false, canPlay: false),
        ]
        #expect(RemoteTargets.forKids(all, atHome: true).map(\.name) == ["Bedroom", "Living Room"])
    }

    @Test func aTVTheServerWillWakeIsOfferedAtHomeOnly() {
        // The server says wakeable only when the household lets kids turn on the TV.
        let asleep = device("s", "Living Room", online: false, canPlay: false, wakeable: true)
        #expect(RemoteTargets.forKids([asleep], atHome: true).map(\.id) == ["s"])
        #expect(RemoteTargets.forKids([asleep], atHome: false).isEmpty)
        #expect(RemoteTargets.forKids([device("s", "Living Room", online: false, canPlay: false)], atHome: true).isEmpty)
    }

    @Test func theTVThatPlaysTheChildsFilmIsTheOneToControl() {
        let others = device("g", "Grown-ups", controllable: false, player: .redacted(status: .playing))
        let own = device("l", "Living Room", controllable: true, player: playing())
        #expect(RemoteTargets.kidsPlaying([others, own])?.id == "l")
        // What somebody else watches is never the child's, whatever the screen thinks.
        #expect(RemoteTargets.kidsPlaying([others]) == nil)
        #expect(RemoteTargets.kidsPlaying([device("l", "Living Room", controllable: true, player: playing(.ended))]) == nil)
        #expect(RemoteTargets.kidsPlaying([device("me", "Phone", platform: .ios, controllable: true, player: playing(), isSelf: true)]) == nil)
    }

    @Test func aChildIsToldPlainlyWithoutAirPlayOrSettings() {
        let words = { (outcome: RemoteOutcome) in outcome.kidsWords(device: "Living Room") }
        #expect(words(.done) == nil)
        #expect(words(.superseded) == nil)
        #expect(words(.failed(code: "title_not_allowed")) == "Living Room cannot play this one.")
        for outcome in [RemoteOutcome.offline, .expired, .notWoken(reason: "wake_not_found"), .failed(code: "busy"), .unreachable] {
            let said = words(outcome) ?? ""
            #expect(!said.isEmpty)
            #expect(!said.contains("AirPlay"))
            #expect(!said.contains("Settings"))
        }
    }

    @Test func whetherKidsCanTurnOnTheTVDecodesAndAnOlderServerMeansNo() throws {
        let decoder = LobbyJSON.decoder()
        let new = try decoder.decode(
            WakeStatus.self, from: Data(#"{"configured":true,"enabled":true,"kids":true,"running":true,"televisions":[]}"#.utf8))
        #expect(new.kids)
        let old = try decoder.decode(
            WakeStatus.self, from: Data(#"{"configured":true,"enabled":true,"running":true,"televisions":[]}"#.utf8))
        #expect(!old.kids)
    }
}
