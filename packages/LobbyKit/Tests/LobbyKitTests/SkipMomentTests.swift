// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing

@testable import LobbyKit

@Suite struct SkipMomentTests {
    private let markers = PlaybackMarkers(
        intro: .init(startMs: 60_000, endMs: 120_000, source: "detected"),
        credits: .init(startMs: 1_300_000, source: "chapters"))

    @Test func skipIntroShowsDuringTheIntroOnly() {
        let show = SkipPreferences.defaults
        #expect(SkipMoment.at(fileMs: 59_999, markers: markers, preferences: show) == .none)
        #expect(SkipMoment.at(fileMs: 60_000, markers: markers, preferences: show) == .intro(endMs: 120_000, automatic: false))
        #expect(SkipMoment.at(fileMs: 117_999, markers: markers, preferences: show) == .intro(endMs: 120_000, automatic: false))
        // Its last seconds are not worth a button.
        #expect(SkipMoment.at(fileMs: 118_000, markers: markers, preferences: show) == .none)
        #expect(SkipMoment.at(fileMs: 1_300_000, markers: markers, preferences: show) == .credits(startMs: 1_300_000))
        #expect(SkipMoment.at(fileMs: 100_000, markers: nil, preferences: show) == .none)
    }

    @Test func theViewersChoiceDecides() {
        let auto = SkipPreferences(intro: .skip, credits: .off)
        #expect(SkipMoment.at(fileMs: 70_000, markers: markers, preferences: auto) == .intro(endMs: 120_000, automatic: true))
        #expect(SkipMoment.at(fileMs: 1_400_000, markers: markers, preferences: auto) == .none)
        #expect(SkipMoment.creditsStartMs(markers: markers, preferences: auto) == nil)
        #expect(SkipMoment.creditsStartMs(markers: markers, preferences: .defaults) == 1_300_000)
        let off = SkipPreferences(intro: .off, credits: .show)
        #expect(SkipMoment.at(fileMs: 70_000, markers: markers, preferences: off) == .none)
    }

    @Test func anIntroIsSkippedByItselfOnceAndThenOffersTheButton() {
        var skip = IntroAutoSkip()
        let automatic = SkipMoment.intro(endMs: 120_000, automatic: true)
        #expect(!skip.showsButton(for: automatic))
        #expect(skip.target(for: automatic) == 120_000)
        // The viewer went back into it: they want to see it.
        #expect(skip.target(for: automatic) == nil)
        #expect(skip.showsButton(for: automatic))
        var shown = IntroAutoSkip()
        #expect(shown.target(for: .intro(endMs: 120_000, automatic: false)) == nil)
        #expect(shown.showsButton(for: .intro(endMs: 120_000, automatic: false)))
        #expect(!shown.showsButton(for: .credits(startMs: 1)))
    }

    @Test func aControllingDeviceLeavesTheSkippingToThePlayer() {
        #expect(SkipMoment.remoteIntroEnd(fileMs: 70_000, markers: markers, preferences: .defaults) == 120_000)
        let auto = SkipPreferences(intro: .skip, credits: .show)
        #expect(SkipMoment.remoteIntroEnd(fileMs: 61_000, markers: markers, preferences: auto) == nil)
        #expect(SkipMoment.remoteIntroEnd(fileMs: 64_000, markers: markers, preferences: auto) == 120_000)
        #expect(SkipMoment.remoteIntroEnd(fileMs: 130_000, markers: markers, preferences: .defaults) == nil)
    }

    @Test func markersAndChoicesAreReadLeniently() throws {
        let decoder = LobbyJSON.decoder()
        let file = try decoder.decode(PlaybackMarkers.self, from: Data(#"{"intro":{"startMs":1000,"endMs":30000,"source":"manual"},"credits":null}"#.utf8))
        #expect(file == PlaybackMarkers(intro: .init(startMs: 1000, endMs: 30000, source: "manual")))
        // Something a newer server says otherwise is no broken film.
        let odd = try decoder.decode(PlaybackMarkers.self, from: Data(#"{"intro":{"from":1},"credits":{"startMs":5}}"#.utf8))
        #expect(odd.intro == nil)
        #expect(odd.credits?.startMs == 5)

        let old = try decoder.decode(Profile.self, from: Data(#"{"id":"p","name":"A","color":"red"}"#.utf8))
        #expect(old.skipping == nil)
        #expect(old.skipPreferences == .defaults)
        let chosen = try decoder.decode(
            Profile.self, from: Data(#"{"id":"p","name":"A","color":"red","skipping":{"intro":"skip","credits":"off"}}"#.utf8))
        #expect(chosen.skipPreferences == SkipPreferences(intro: .skip, credits: .off))
        let newer = try decoder.decode(
            Profile.self, from: Data(#"{"id":"p","name":"A","color":"red","skipping":{"intro":"fast","credits":"off"}}"#.utf8))
        #expect(newer.skipPreferences == SkipPreferences(intro: .show, credits: .off))
        #expect(old.keepingUnsaid(of: chosen).skipping == chosen.skipping)
        #expect(try decoder.decode(Profile.self, from: LobbyJSON.encoder().encode(chosen)) == chosen)
    }

    @Test func theCallsSayWhatTheContractSays() async throws {
        let stub = StubServer { request in
            if request.path.hasPrefix("/v1/markers") { return .json(202, #"{"files":12,"status":{}}"#) }
            return .json(200, #"{"id":"p1","name":"A","color":"red","skipping":{"intro":"off","credits":"show"}}"#)
        }
        let client = try stub.client()
        let wanted = SkipPreferences(intro: .off, credits: .show)
        #expect(try await client.setSkipPreferences(wanted, profileID: "p1").skipping == wanted)
        let put = try #require(stub.recorded.last)
        #expect(put.method == "PUT")
        #expect(put.path == "/v1/profiles/p1/skipping")
        #expect(try put.json() as? [String: String] == ["intro": "off", "credits": "show"])

        #expect(try await client.findMarkers(itemID: "season-1") == 12)
        #expect(stub.recorded.last?.method == "POST")
        #expect(stub.recorded.last?.path == "/v1/markers/items/season-1/detect")
    }
}
