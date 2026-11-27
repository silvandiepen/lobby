// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing

@testable import LobbyKit

@Suite struct SubtitlePreferencesTests {
    private func profile(_ json: String) throws -> Profile {
        try LobbyJSON.decoder().decode(Profile.self, from: Data(json.utf8))
    }

    @Test func aServerFromBeforeMeansTheDefaults() throws {
        let old = try profile(#"{"id":"p","name":"A","color":"red"}"#)
        #expect(old.subtitles == nil)
        #expect(old.subtitlePreferences == .defaults)
        #expect(SubtitlePreferences.defaults.isOff)
        #expect(SubtitlePreferences.defaults.forced)

        let chosen = try profile(
            #"{"id":"p","name":"A","color":"red","subtitles":{"languages":["nl","eng"],"forced":false,"size":"large","background":false}}"#)
        #expect(chosen.subtitlePreferences == SubtitlePreferences(languages: ["nl", "eng"], forced: false, size: .large, background: false))
        // What a newer server adds or names otherwise is not a broken viewer.
        let newer = try profile(#"{"id":"p","name":"A","color":"red","subtitles":{"languages":["hy"],"size":"giant","outline":true}}"#)
        #expect(newer.subtitlePreferences == SubtitlePreferences(languages: ["hy"], forced: true, size: .medium, background: true))
        // Kept from before when an answer leaves them out, and read back as they were written.
        #expect(old.keepingUnsaid(of: chosen).subtitles == chosen.subtitles)
        #expect(try LobbyJSON.decoder().decode(Profile.self, from: LobbyJSON.encoder().encode(chosen)) == chosen)
    }

    @Test func theCallsSayWhatTheContractSays() async throws {
        let stub = StubServer { request in
            if request.path.contains("subtitle-offsets") { return .json(200, #"{"offsetMs":-1500}"#) }
            return .json(200, #"{"id":"p1","name":"A","color":"red","avatar":null,"kids":null,"subtitles":{"languages":["nl"],"forced":true,"size":"small","background":true}}"#)
        }
        let client = try stub.client()
        let wanted = SubtitlePreferences(languages: ["nl"], forced: true, size: .small, background: true)
        #expect(try await client.setSubtitlePreferences(wanted, profileID: "p1").subtitles == wanted)
        let put = try #require(stub.recorded.last)
        #expect(put.method == "PUT")
        #expect(put.path == "/v1/profiles/p1/subtitles")
        #expect(try put.json().keys.sorted() == ["background", "forced", "languages", "size"])

        #expect(try await client.subtitleOffset(profileID: "p1", itemID: "i9") == -1500)
        #expect(stub.recorded.last?.path == "/v1/profiles/p1/subtitle-offsets/i9")
        try await client.setSubtitleOffset(250, profileID: "p1", itemID: "i9")
        #expect(stub.recorded.last?.method == "PUT")
        #expect(try stub.recorded.last?.json() as? [String: Int] == ["offsetMs": 250])
    }
}

@Suite struct SubtitleChoiceTests {
    private func candidate(_ id: String, _ language: String?, forced: Bool = false, native: Bool = true) -> SubtitleCandidate {
        SubtitleCandidate(id: id, language: language, isForced: forced, isNative: native)
    }

    private func choose(
        _ candidates: [SubtitleCandidate], languages: [String] = [], forced: Bool = true, sound: String? = "en",
        device: [String] = ["en"]
    ) -> String? {
        SubtitleChooser.choose(
            from: candidates, preferences: SubtitlePreferences(languages: languages, forced: forced, size: .medium, background: true),
            soundLanguage: sound, deviceLanguages: device)?.id
    }

    @Test func languageCodesOfEveryKindMeetEachOther() {
        #expect(SubtitleLanguage.base("dut") == "nl")
        #expect(SubtitleLanguage.base("nld") == "nl")
        #expect(SubtitleLanguage.base("NL") == "nl")
        #expect(SubtitleLanguage.base("en-GB") == "en")
        #expect(SubtitleLanguage.base("pt_BR") == "pt")
        #expect(SubtitleLanguage.base("arm") == "hy")
        #expect(SubtitleLanguage.base("ger") == "de")
        #expect(SubtitleLanguage.base("und") == nil)
        #expect(SubtitleLanguage.base(nil) == nil)
        #expect(SubtitleLanguage.base("") == nil)
    }

    @Test func offMeansNothingButForcedSubtitles() {
        let film = [candidate("en", "eng"), candidate("nl", "dut"), candidate("en-forced", "eng", forced: true)]
        #expect(choose(film) == "en-forced")
        #expect(choose(film, forced: false) == nil)
        #expect(choose([candidate("en", "eng"), candidate("nl", "dut")]) == nil)
    }

    @Test func theFirstLanguageTheFilmHasWins() {
        let film = [candidate("en", "eng"), candidate("nl", "nld"), candidate("fr", "fre")]
        #expect(choose(film, languages: ["nl", "en"]) == "nl")
        #expect(choose(film, languages: ["hy", "fr", "nl"]) == "fr")
        #expect(choose(film, languages: ["en"]) == "en")
        // None of them: forced ones, else nothing.
        #expect(choose(film, languages: ["hy"]) == nil)
        #expect(choose(film + [candidate("f", "en", forced: true)], languages: ["hy"]) == "f")
    }

    @Test func fullSubtitlesAreNeverTakenForForcedOnesOrTheOtherWayRound() {
        let onlyForced = [candidate("nl-forced", "nl", forced: true)]
        #expect(choose(onlyForced, languages: ["nl"], sound: "nl") == "nl-forced")
        #expect(choose(onlyForced, languages: ["nl"], forced: false) == nil)
    }

    @Test func forcedSubtitlesFollowTheSoundThenTheViewerThenTheDevice() {
        let forced = [candidate("f-nl", "nl", forced: true), candidate("f-en", "en", forced: true), candidate("f-ru", "rus", forced: true)]
        #expect(choose(forced, sound: "eng") == "f-en")
        #expect(choose(forced, sound: "ja", device: ["ru"]) == "f-ru")
        #expect(choose(forced, languages: ["nl"], sound: "ja") == "f-nl")
        #expect(choose(forced, sound: nil, device: ["fr"]) == nil)
        #expect(choose(forced, sound: nil, device: ["fr", "nl"]) == "f-nl")
    }

    @Test func whatThePlayerShowsItselfComesBeforeWhatTheAppDraws() {
        let film = [candidate("drawn", "nl", native: false), candidate("native", "nl")]
        #expect(choose(film, languages: ["nl"]) == "native")
        #expect(choose([candidate("drawn", "nl", native: false)], languages: ["nl"]) == "drawn")
    }

    @Test func aSubtitleOfUnknownLanguageIsLeftToTheMenu() {
        #expect(choose([candidate("x", nil), candidate("y", "und", forced: true)], languages: ["en"]) == nil)
    }
}

@Suite struct PictureSubtitlesTests {
    @Test func theServersCuesAreReadWithTheirPictures() throws {
        let json = #"{"width":1920,"height":1080,"cues":[{"startMs":4000,"endMs":5000,"x":10,"y":20,"width":3,"height":4,"png":"iVBORw=="},{"startMs":1000,"endMs":2500,"x":800,"y":950,"width":300,"height":60,"png":"AAEC"}]}"#
        let pictures = try LobbyJSON.decoder().decode(PictureSubtitles.self, from: Data(json.utf8))
        #expect(pictures.width == 1920)
        // In time order, whatever order they came in.
        #expect(pictures.cues.map(\.startMs) == [1000, 4000])
        #expect(pictures.cues[0].png == Data([0, 1, 2]))
    }

    @Test func theRightCueIsOnScreenAtEachMoment() {
        let cue = { (start: Int, end: Int) in PictureSubtitles.Cue(startMs: start, endMs: end, x: 0, y: 0, width: 1, height: 1, png: Data()) }
        let pictures = PictureSubtitles(width: 10, height: 10, cues: [cue(1000, 2000), cue(3000, 4000)])
        #expect(pictures.cue(atMs: 999) == nil)
        #expect(pictures.cue(atMs: 1000)?.startMs == 1000)
        #expect(pictures.cue(atMs: 1999)?.startMs == 1000)
        #expect(pictures.cue(atMs: 2000) == nil)
        #expect(pictures.cue(atMs: 3500)?.startMs == 3000)
        #expect(pictures.cue(atMs: 9000) == nil)
    }

    @Test func onlyPictureCodecsArePictures() {
        let track = { (codec: String, isText: Bool) in
            SubtitleTrack(id: "t", source: .embedded, codec: codec, language: nil, title: nil, isForced: false, isText: isText)
        }
        #expect(track("hdmv_pgs_subtitle", false).isPicture)
        #expect(track("dvd_subtitle", false).isPicture)
        #expect(!track("subrip", true).isPicture)
        #expect(!track("eia_608", false).isPicture)
    }
}
