// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

/// Play on a HomePod or speaker (docs/decisions.md, "Play on a speaker"): which speakers the
/// screens offer, to grown-ups and to a child, what each says, what goes there when music that
/// plays here moves, the words for what went wrong, and a manager's page.
@MainActor
@Suite struct SpeakerTests {
    private func speaker(
        _ id: String, _ name: String, canPlay: Bool = true, access: SpeakerAccess = .open, controllable: Bool = false,
        play: SpeakerPlay? = nil
    ) -> ShownSpeaker {
        ShownSpeaker(id: id, name: name, canPlay: canPlay, access: access, controllable: controllable, play: play)
    }

    private func state(_ status: RemotePlayerStatus, kind: SpeakerPlayState.Kind = .music, profile: String = "alex") -> SpeakerPlayState {
        SpeakerPlayState(
            profileId: profile, kind: kind, bookId: kind == .story ? "b1" : nil, trackIds: ["t1", "t2"], index: 0,
            trackId: "t1", status: status, positionMs: 0, at: 0, durationMs: 60_000, startedBy: "dev-1")
    }

    @Test func grownUpsSeeTheSpeakersThatCanPlayFirstByName() {
        let all = [
            speaker("c", "Kitchen", canPlay: false, play: .redacted(status: .playing)),
            speaker("b", "Living Room"),
            speaker("a", "Bedroom", access: .homeOnly),
            speaker("d", "Gone", canPlay: false),
        ]
        // One that is not on the network is left out, unless something still plays there.
        #expect(SpeakerTargets.ordered(all).map(\.name) == ["Bedroom", "Living Room", "Kitchen"])
    }

    @Test func aChildSeesOnlySpeakersThatWillPlayForIt() {
        let all = [
            speaker("a", "Bedroom", access: .homeOnly),
            speaker("b", "Garden", access: .password),
            speaker("c", "Kitchen", play: .redacted(status: .playing)),
            speaker("d", "Living Room"),
            speaker("e", "Playroom", controllable: true, play: .visible(state(.paused, profile: "robin"))),
        ]
        // Not one that will refuse, not one where someone else listens.
        #expect(SpeakerTargets.forKids(all).map(\.name) == ["Living Room", "Playroom"])
    }

    @Test func theBarShowsWhatPlaysForThisDevicePlayingFirst() {
        let paused = speaker("a", "Bedroom", controllable: true, play: .visible(state(.paused)))
        let playing = speaker("b", "Kitchen", controllable: true, play: .visible(state(.playing)))
        let ended = speaker("c", "Garden", controllable: true, play: .visible(state(.ended)))
        let others = speaker("d", "Den", play: .redacted(status: .playing))
        #expect(SpeakerTargets.playing([paused, playing, ended, others])?.name == "Kitchen")
        #expect(SpeakerTargets.playing([ended, others]) == nil)
    }

    @Test func eachSpeakerSaysWhatItDoesAndWhyItMightRefuse() {
        let title: (SpeakerPlayState) -> String? = { _ in "Paper Boats" }
        #expect(SpeakerTargets.state(of: speaker("a", "Kitchen"), title: title) == "Ready")
        #expect(SpeakerTargets.state(of: speaker("a", "Kitchen", play: .visible(state(.playing))), title: title) == "Playing Paper Boats")
        #expect(SpeakerTargets.state(of: speaker("a", "Kitchen", play: .visible(state(.paused))), title: title) == "Paused: Paper Boats")
        #expect(SpeakerTargets.state(of: speaker("a", "Kitchen", play: .redacted(status: .playing)), title: title) == "Playing")
        #expect(SpeakerTargets.state(of: speaker("a", "Bedroom", access: .homeOnly), title: title) == "Only for people in its Home")
        #expect(SpeakerTargets.accessHint(speaker("a", "Bedroom", access: .homeOnly))?.contains("Everyone on the Same Network") == true)
        #expect(SpeakerTargets.accessHint(speaker("a", "Garden", access: .password))?.contains("Speakers") == true)
        #expect(SpeakerTargets.accessHint(speaker("a", "Kitchen")) == nil)
    }

    @Test func musicThatPlaysHereGoesOnThereFromTheSamePlace() throws {
        let music = try #require(SpeakerTargets.handover(
            trackIDs: ["t1", "t2", "t3"], index: 1, elapsedMs: 42_000, book: nil, bookPositionMs: nil, profileID: "alex"))
        #expect(music == .music(profileID: "alex", trackIDs: ["t2", "t3"], index: 0, startMs: 42_000))

        let book = MusicBook(
            id: "b1", title: "The Long Story", durationMs: 600_000, addedAt: Make.epoch,
            parts: [.init(trackId: "p1", startMs: 0, durationMs: 300_000), .init(trackId: "p2", startMs: 300_000, durationMs: 300_000)])
        let story = SpeakerTargets.handover(
            trackIDs: ["p1", "p2"], index: 1, elapsedMs: 5_000, book: book, bookPositionMs: 305_000, profileID: "robin")
        // A story goes by its own line of time: the server finds the file and the place in it.
        #expect(story == .story(profileID: "robin", bookID: "b1", startMs: 305_000))
        #expect(SpeakerTargets.handover(trackIDs: [], index: 0, elapsedMs: 0, book: nil, bookPositionMs: nil, profileID: "alex") == nil)
    }

    @Test func aRefusalIsSaidPlainlyWithTheWayOut() {
        let words = { (reason: String?) in SpeakerTargets.words(.refused(reason: reason, message: nil), speaker: "Kitchen") ?? "" }
        #expect(words("speaker_refused").contains("Everyone on the Same Network"))
        #expect(words("speaker_not_found").contains("plugged in"))
        #expect(words("speaker_busy") == "Something else plays on Kitchen.")
        #expect(words("home_only").contains("from home"))
        // The server's own words, when it has them.
        #expect(SpeakerTargets.words(.refused(reason: "speaker_refused", message: "Its own words."), speaker: "Kitchen") == "Its own words.")
        #expect(SpeakerTargets.words(.done, speaker: "Kitchen") == nil)
        // A child is told without settings.
        #expect(SpeakerTargets.kidsWords(.refused(reason: "speaker_refused", message: nil), speaker: "Kitchen") == "That did not work on Kitchen. Ask a grown-up for help.")
        #expect(SpeakerTargets.kidsWords(.refused(reason: "kids_mode", message: nil), speaker: "Kitchen") == "It is not time to listen now.")
    }

    // MARK: A manager's page

    #if !os(tvOS)

    private static let status = #"""
    {"configured":true,"enabled":true,"running":true,"problem":null,"scannedAt":1795640000000,"speakers":[
      {"id":"s1","name":"Kitchen","foundName":"Kitchen","customName":null,"model":"HomePod","kind":"homepod","hidden":false,
       "found":true,"access":"open","hasPassword":false,"playing":false},
      {"id":"s2","name":"Garden","foundName":"Garden","customName":null,"model":"Speaker","kind":"speaker","hidden":false,
       "found":true,"access":"password","hasPassword":false,"playing":false}]}
    """#

    @Test func aManagerNamesHidesAndGivesAPassword() async throws {
        var state = Household.State(
            device: Device(id: "dev-1", name: "Alex's MacBook Pro", platform: .macos, role: .manager, createdAt: Make.epoch))
        state.speakers = Self.status
        let test = try TestApp(Household(state))
        let app = try await test.launchPaired(as: "alex")
        let model = SpeakersModel(app: app)
        await model.load()
        #expect(model.speakers.map(\.name) == ["Kitchen", "Garden"])
        #expect(model.summary == "On. Play On offers 2 speakers for music and stories.")

        let kitchen = try #require(model.speaker("s1"))
        await model.rename(kitchen, to: "  Kitchen Speaker ")
        #expect(model.speaker("s1")?.name == "Kitchen Speaker")
        #expect(SpeakersModel.state(of: try #require(model.speaker("s1"))) == "Calls itself “Kitchen”")
        // Its own name again: no name of the household's.
        await model.rename(try #require(model.speaker("s1")), to: "")
        #expect(model.speaker("s1")?.customName == nil)

        await model.setHidden(try #require(model.speaker("s1")), true)
        #expect(model.speaker("s1")?.hidden == true)

        let garden = try #require(model.speaker("s2"))
        #expect(SpeakersModel.state(of: garden) == "Needs its password")
        await model.setPassword(garden, "1234")
        #expect(model.speaker("s2")?.hasPassword == true)

        #expect(test.household.current.speakerRequests == [
            #"PATCH s1 {"name":"Kitchen Speaker"}"#,
            #"PATCH s1 {"name":null}"#,
            #"PATCH s1 {"hidden":true}"#,
            #"PUT s2 {"password":"1234"}"#,
        ])
        #expect(model.problem == nil)
    }

    @Test func aServerWithoutSpeakersSaysSo() async throws {
        let test = try TestApp(Household(.init(
            device: Device(id: "dev-1", name: "Mac", platform: .macos, role: .manager, createdAt: Make.epoch))))
        let app = try await test.launchPaired(as: "alex")
        let model = SpeakersModel(app: app)
        await model.load()
        #expect(model.isUnavailable)
        #expect(SpeakersModel.summary(SpeakersStatus(configured: false, enabled: true, running: false, speakers: [])).contains("pyatv"))
        #expect(SpeakersModel.summary(SpeakersStatus(configured: true, enabled: false, running: true, speakers: [])) == "Off. Play On does not offer speakers.")
    }
    #endif
}
