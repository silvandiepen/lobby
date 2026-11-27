// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

/// Waking an Apple TV for Play On (docs/api.md, "Waking an Apple TV"), apart from the
/// network: what the screens say, and what the server's answers decode to.
struct WakeTests {
    private func tv(online: Bool = false, canPlay: Bool = false, wakeable: Bool = true, platform: DevicePlatform = .tvos) -> ShownDevice {
        ShownDevice(id: "tv", name: "Living Room", platform: platform, online: online, foreground: online, canPlay: canPlay, wakeable: wakeable)
    }

    @Test func anAsleepTVTheServerCanWakeWillWake() {
        #expect(RemoteTargets.willWake(tv()))
        #expect(RemoteTargets.state(of: tv()) { _ in nil } == "Will wake")
        // Lobby is there but not in front: it is brought to the front.
        #expect(RemoteTargets.willWake(tv(online: true, canPlay: false)))
        // Open and ready: played on as always.
        #expect(!RemoteTargets.willWake(tv(online: true, canPlay: true)))
        #expect(RemoteTargets.state(of: tv(online: true, canPlay: true)) { _ in nil } == "Idle")
        // Not connected, or not a TV.
        #expect(!RemoteTargets.willWake(tv(wakeable: false)))
        #expect(RemoteTargets.state(of: tv(wakeable: false)) { _ in nil } == "Lobby is not open")
        #expect(!RemoteTargets.willWake(tv(platform: .macos)))
    }

    @Test func whyATVWasNotWokenIsSaidWithTheWayOut() throws {
        let words = { (reason: String?) in RemoteOutcome.notWoken(reason: reason).words(device: "Living Room") ?? "" }
        #expect(words("did_not_open").contains("Lobby did not open"))
        #expect(words("wake_not_found").contains("not found on the network"))
        #expect(words("wake_not_paired").contains("Apple TVs"))
        #expect(words("wake_off").contains("turned off"))
        #expect(words(nil).contains("AirPlay"))
        #expect(!RemoteOutcome.notWoken(reason: nil).succeeded)
    }

    @Test func aShownDeviceSaysWhetherItIsWakeableAndAnOlderServerMeansNo() throws {
        let decoder = LobbyJSON.decoder()
        let new = try decoder.decode(ShownDevice.self, from: Data(#"{"id":"a","name":"TV","platform":"tvos","online":false,"canPlay":false,"wakeable":true}"#.utf8))
        #expect(new.wakeable)
        let old = try decoder.decode(ShownDevice.self, from: Data(#"{"id":"a","name":"TV","platform":"tvos","online":false,"canPlay":false}"#.utf8))
        #expect(!old.wakeable)
    }

    // MARK: Wake and Play

    private func device(_ id: String, _ name: String, _ platform: DevicePlatform, online: Bool, canPlay: Bool = false, wakeable: Bool = false) -> ShownDevice {
        ShownDevice(id: id, name: name, platform: platform, online: online, foreground: online, canPlay: canPlay, wakeable: wakeable)
    }

    @Test func theSheetListsLobbyTVsFirstAndEverythingElseUnderThem() {
        let all = [
            device("m", "Attic Mac", .macos, online: true, canPlay: true),
            device("a", "Bedroom", .tvos, online: false),
            device("b", "Den", .tvos, online: false, wakeable: true),
            device("c", "Living Room", .tvos, online: true, canPlay: true),
            device("i", "Kitchen iPad", .ipados, online: true, canPlay: true),
        ]
        let sections = RemoteTargets.playOnSections(all)
        // Open, then the one that will wake, then the one that cannot be woken.
        #expect(sections.televisions.map(\.name) == ["Living Room", "Den", "Bedroom"])
        #expect(sections.others.map(\.name) == ["Attic Mac", "Kitchen iPad"])
        // Without a TV, there is only the other list (with AirPlay in it).
        #expect(RemoteTargets.playOnSections([all[0]]).televisions.isEmpty)
    }

    @Test func eachTVSaysWhetherLobbyIsOpenWillWakeOrCannotBeWoken() {
        let words = { (device: ShownDevice) in RemoteTargets.playOnState(of: device) { _ in nil } }
        #expect(words(tv(online: true, canPlay: true)) == "Lobby open")
        #expect(words(tv()) == "Will wake")
        #expect(words(tv(wakeable: false)) == "Asleep — can’t be woken (link it in Apple TVs)")
        // A Mac says what it always said.
        #expect(words(device("m", "Mac", .macos, online: false)) == "Lobby is not open")
    }

    @Test func wakingSaysEachStepAndHintsAtTheProfilePicker() {
        #expect(RemoteTargets.progress(.waking, device: "Living Room") == "Waking Living Room…")
        #expect(RemoteTargets.progress(.opening, device: "Living Room") == "Opening Lobby…")
        #expect(RemoteTargets.progress(.profileHint, device: "Living Room") == "Opening Lobby…")
        #expect(RemoteTargets.hint(.opening, device: "Living Room") == nil)
        #expect(RemoteTargets.hint(.profileHint, device: "Living Room") == "Choose a profile on the TV if it asks")
        #expect(RemoteTargets.hint(.notOpen, device: "Living Room")?.contains("Living Room") == true)
        // Taken back: nothing to say, and it did not play.
        #expect(RemoteOutcome.cancelled.words(device: "Living Room") == nil)
        #expect(!RemoteOutcome.cancelled.succeeded)
    }

    @Test func thePlayGoesWithTheWakeAndTheAnswersDecode() throws {
        let held = HeldPlayRequest(id: "p1", command: PlayCommand(itemId: "up", profileId: "alex", startMs: 61_000, subtitleTrackId: "off"))
        let sent = try JSONSerialization.jsonObject(with: try LobbyJSON.encoder().encode(held)) as? [String: Any]
        #expect(sent?["id"] as? String == "p1")
        let command = sent?["command"] as? [String: Any]
        #expect(command?["type"] as? String == "play")
        #expect(command?["itemId"] as? String == "up")
        #expect(command?["startMs"] as? Int == 61_000)

        let decoder = LobbyJSON.decoder()
        let reply = try decoder.decode(WakeReply.self, from: Data(#"{"deviceId":"tv","wokenAt":1,"lobbyInFront":null,"play":{"id":"p1","expiresAt":1795640180000}}"#.utf8))
        #expect(reply.play?.expiresAt == 1_795_640_180_000)
        // A server from before keeps nothing.
        #expect(try decoder.decode(WakeReply.self, from: Data(#"{"deviceId":"tv","wokenAt":1}"#.utf8)).play == nil)
        let hello = try decoder.decode(LiveHello.self, from: Data(#"{"session":"s","deviceId":"tv","resumed":false,"heartbeatMs":5000,"silentMs":12000,"serverTime":1,"pendingPlay":true}"#.utf8))
        #expect(hello.pendingPlay == true)
        guard case .wake(let progress) = LiveEventParser.decode(.init(id: nil, event: "wake", data: #"{"deviceId":"tv","commandId":"p1","step":"not_open","reason":"timeout","serverTime":1}"#)) else {
            Issue.record("wake was not read")
            return
        }
        #expect(progress.step == .notOpen)
        #expect(progress.reason == "timeout")
    }

    @MainActor @Test func aWaitingDeviceIsLetInAsWhatWasChosen() {
        #expect(ManagerModel.letInLabel(.viewer) == "Let In as Viewer")
        #expect(ManagerModel.letInLabel(.householdAdmin) == "Let In as Household Admin")
        #expect(ManagerModel.letInLabel(.admin) == "Let In as Server Admin")
    }

    @Test func theServersApplesTVsDecode() throws {
        let json = #"""
        {"configured":true,"enabled":true,"running":true,"problem":null,"pyatv":"0.18.0","scannedAt":1795640000000,
         "televisions":[{"id":"AA:BB","name":"Living Room","model":"Apple TV 4K","paired":true,"found":true,"deviceId":null,"suggestedDeviceId":"d1"}],
         "pairing":{"id":"p","televisionId":"AA:BB","expiresAt":1795640060000}}
        """#
        let status = try LobbyJSON.decoder().decode(WakeStatus.self, from: Data(json.utf8))
        #expect(status.televisions.first?.suggestedDeviceId == "d1")
        #expect(status.pairing?.expiresAt == Date(millisecondsSince1970: 1_795_640_060_000))
        #expect(status.scannedAt != nil)
    }

    // The Apple TVs page is a screen of the iPhone, iPad and Mac.
    #if !os(tvOS)
    @Test func theManagersPageSaysHowItIsDoing() {
        #expect(AppleTVsModel.summary(nil) == "")
        #expect(AppleTVsModel.summary(WakeStatus(configured: false, enabled: false, running: false)).contains("pyatv"))
        #expect(AppleTVsModel.summary(WakeStatus(configured: true, enabled: true, running: false, problem: "no Python there")).contains("no Python there"))
        let linked = Television(id: "AA", name: "Living Room", paired: true, deviceId: "d1")
        #expect(AppleTVsModel.summary(WakeStatus(configured: true, enabled: true, running: true, televisions: [linked])) == "On. Play On turns 1 Apple TV on.")
        #expect(AppleTVsModel.summary(WakeStatus(configured: true, enabled: false, running: true, televisions: [linked])).hasPrefix("Off."))
        #expect(AppleTVsModel.summary(WakeStatus(configured: true, enabled: true, running: true)) == "On. No Apple TV is connected yet.")
    }

    @Test func eachTVSaysWhetherItIsConnectedAndAsWhich() {
        let device = Device(id: "d1", name: "Living Room", platform: .tvos, role: .viewer, createdAt: Date())
        #expect(AppleTVsModel.state(of: Television(id: "A", name: "TV", paired: false), devices: [], looked: true) == "Not connected")
        #expect(AppleTVsModel.state(of: Television(id: "A", name: "TV", paired: false, found: false), devices: [], looked: true)
            == "Not connected, not found in the last look")
        #expect(AppleTVsModel.state(of: Television(id: "A", name: "TV", paired: true, found: false), devices: [], looked: false)
            == "Connected. Which Lobby device is it?")
        #expect(AppleTVsModel.state(of: Television(id: "A", name: "TV", paired: true, deviceId: "d1"), devices: [device], looked: true)
            == "Connected as Living Room")
        #expect(AppleTVsModel.state(of: Television(id: "A", name: "TV", paired: true, deviceId: "gone"), devices: [device], looked: true)
            == "Connected as a removed device")
    }
    #endif
}
