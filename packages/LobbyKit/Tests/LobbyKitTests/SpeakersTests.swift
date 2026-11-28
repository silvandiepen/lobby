// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing

@testable import LobbyKit

/// HomePods and speakers as the live channel shows them, and what the app sends to play on one.
@Suite struct SpeakersTests {
    private let event = #"""
    {"speakers":[{"id":"s1","name":"Kitchen","kind":"homepod","canPlay":true,"access":"open","volume":0.4,"controllable":true,
      "play":{"redacted":false,"profileId":"p1","kind":"story","bookId":"b1","albumId":null,"trackIds":["t1","t2"],"index":1,
        "trackId":"t2","status":"playing","positionMs":500,"at":1795640000000,"durationMs":8000,"problem":null,"startedBy":"d1"}},
     {"id":"s2","name":"Bedroom","kind":"homepod","canPlay":true,"access":"home_only","volume":null,"controllable":false,
      "play":{"redacted":true,"status":"paused"}},
     {"id":"s3","name":"Garden","kind":"turntable","canPlay":false,"access":"something_new","controllable":false,"play":null}],
     "serverTime":1795640000000}
    """#

    @Test func theChannelSaysWhichSpeakersThereAreAndWhatTheyPlay() throws {
        let decoded = LiveEventParser.decode(.init(id: "e.1", event: "speakers", data: event))
        guard case .speakers(let speakers, let time) = decoded else {
            Issue.record("not read as speakers: \(String(describing: decoded))")
            return
        }
        #expect(time == 1_795_640_000_000)
        #expect(speakers.map(\.name) == ["Kitchen", "Bedroom", "Garden"])
        let kitchen = try #require(speakers.first)
        #expect(kitchen.kind == .homepod)
        #expect(kitchen.volume == 0.4)
        let state = try #require(kitchen.play?.state)
        #expect(state.kind == .story)
        #expect(state.bookId == "b1")
        #expect(state.trackId == "t2")
        #expect(state.hasNext == false)
        // It moves on by the server's clock while it plays, never past the end of the track.
        #expect(state.positionMs(at: 1_795_640_001_000) == 1_500)
        #expect(state.positionMs(at: 1_795_640_100_000) == 8_000)

        // A child sees only that something plays on another's speaker.
        #expect(speakers[1].access == .homeOnly)
        #expect(speakers[1].play == .redacted(status: .paused))
        #expect(speakers[1].play?.state == nil)

        // What a newer server says is kept, not refused.
        #expect(speakers[2].kind == .unknown("turntable"))
        #expect(speakers[2].access == .unknown("something_new"))
    }

    @Test func aPausedSpeakerStaysWhereItIs() {
        let state = SpeakerPlayState(
            profileId: "p", kind: .music, trackIds: ["a", "b"], index: 0, trackId: "a", status: .paused,
            positionMs: 1_200, at: 1_000, durationMs: 3_000, startedBy: "d")
        #expect(state.positionMs(at: 99_000) == 1_200)
        #expect(state.hasNext)
    }

    @Test func playingAndControllingAreSentAsTheContractHasThem() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func json(_ value: some Encodable) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }

        #expect(try json(SpeakerPlayRequest.story(profileID: "p", bookID: "b")) == #"{"bookId":"b","index":0,"profileId":"p"}"#)
        #expect(
            try json(SpeakerPlayRequest.music(profileID: "p", trackIDs: ["t1", "t2"], index: 1, startMs: 4_000, albumID: "a"))
                == #"{"albumId":"a","index":1,"profileId":"p","startMs":4000,"trackIds":["t1","t2"]}"#)
        #expect(try json(SpeakerAction.pause) == #"{"type":"pause"}"#)
        #expect(try json(SpeakerAction.skip(deltaMs: -15_000)) == #"{"deltaMs":-15000,"type":"skip"}"#)
        #expect(try json(SpeakerAction.seek(positionMs: 2_000)) == #"{"positionMs":2000,"type":"seek"}"#)
        #expect(try json(SpeakerAction.volume(0.25)) == #"{"type":"volume","volume":0.25}"#)
    }

    @Test func aManagerSeesTheSpeakersAndWhatTheyAllow() throws {
        let json = #"""
        {"configured":true,"enabled":true,"running":true,"problem":null,"scannedAt":1795640000000,
         "speakers":[{"id":"s1","name":"Kitchen Speaker","foundName":"Kitchen","customName":"Kitchen Speaker","model":"HomePod",
           "kind":"homepod","hidden":false,"found":true,"access":"password","hasPassword":false,"playing":false}]}
        """#
        let status = try JSONDecoder().decode(SpeakersStatus.self, from: Data(json.utf8))
        #expect(status.speakers.first?.customName == "Kitchen Speaker")
        #expect(status.speakers.first?.access == .password)
    }
}
