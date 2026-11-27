// SPDX-License-Identifier: MPL-2.0
import AVFoundation
import Foundation
import LobbyKit
import Testing

@testable import Lobby

@Suite struct PreparingTimelineTests {
    let timeline = PreparingTimeline(
        durationMs: 5_940_000, preparedMs: 2_155_000, positionMs: 754_000, progress: 0.363, speed: 4, videoConverted: false)

    @Test func theBarIsTheFilmsOwnLengthNotTheTimeOfDay() {
        #expect(timeline.elapsedText == "12:34")
        #expect(timeline.remainingText == "−1:26:26")
        #expect(abs(timeline.positionFraction - 0.1269) < 0.001)
        #expect(abs(timeline.preparedFraction - 0.3628) < 0.001)
        #expect(timeline.accessibilityValue == "12:34 of 1:39:00, prepared up to 35:55")
    }

    @Test func aSeekStopsWhereTheCopyStops() {
        // Inside what is written: there.
        #expect(timeline.seekTarget(fraction: 0.2) == 1_188_000)
        // Beyond it: as far as the copy reaches, less a margin to have something to play.
        #expect(timeline.seekTarget(fraction: 0.8) == 2_125_000)
        #expect(timeline.seekTarget(fraction: -1) == 0)
        #expect(timeline.skipTarget(bySeconds: 10) == 764_000)
        #expect(timeline.skipTarget(bySeconds: -10) == 744_000)
        var early = timeline
        early.positionMs = 4_000
        #expect(early.skipTarget(bySeconds: -10) == 0)
        var atTheEdge = timeline
        atTheEdge.positionMs = 2_120_000
        #expect(atTheEdge.skipTarget(bySeconds: 10) == 2_125_000)
    }

    @Test func theBarShowsWhatThisDeviceHolds() {
        var held = timeline
        // As the player reports them: out of order, one inside another, one empty.
        held.bufferedMs = [1_188_000..<1_485_000, 594_000..<891_000, 700_000..<950_000, 5_000..<5_000]
        let parts = held.bufferedFractions
        #expect(parts.count == 2)
        #expect(abs(parts[0].lowerBound - 0.1) < 0.0001)
        #expect(abs(parts[0].upperBound - 0.16) < 0.0001)
        #expect(abs(parts[1].lowerBound - 0.2) < 0.0001)
        #expect(abs(parts[1].upperBound - 0.25) < 0.0001)
        #expect(timeline.bufferedFractions.isEmpty)
    }

    @Test func thePlayersRangesBecomeMilliseconds() {
        let ranges = [
            CMTimeRange(start: CMTime(seconds: 10, preferredTimescale: 600), duration: CMTime(seconds: 4.5, preferredTimescale: 600)),
            CMTimeRange(start: .zero, duration: .zero),
            CMTimeRange(start: .invalid, duration: .invalid),
        ].map(NSValue.init(timeRange:))
        #expect(PlayerModel.bufferedMs(of: ranges) == [10_000..<14_500])
    }

    @Test func thePlayerFetchesAMinuteAhead() {
        #expect(PlayerModel.forwardBuffer(atHome: true) == 60)
        // A phone, tablet or Mac away: a minute too (an Apple TV away: three).
        #if !os(tvOS)
        #expect(PlayerModel.forwardBuffer(atHome: false) == 60)
        #endif
        // Long enough for the item to see the end of the playlist after a long segment.
        #expect(PlayerModel.secondsToLearnTheEnd >= 20)
    }

    @Test func theStatusSaysHowFarAndHowLong() {
        // 63 minutes of film to go at four times playback speed.
        #expect(timeline.statusText == "Lobby Server is still preparing this film: 36 %. About 16 min to go.")
        var unknown = timeline
        unknown.speed = nil
        #expect(unknown.statusText == "Lobby Server is still preparing this film: 36 %.")
    }

    @Test func aSlowConversionWarnsThatTheFilmWillPause() {
        var avi = timeline
        avi.videoConverted = true
        avi.speed = 0.8
        #expect(avi.statusText.hasPrefix("Lobby Server is still converting this film: 36 %."))
        #expect(avi.statusText.hasSuffix("so it will pause now and then."))
        #expect(!avi.hasCaughtUp)
        avi.positionMs = 2_154_500
        #expect(avi.hasCaughtUp)
    }
}

@Suite struct SubtitleCuesTests {
    static let vtt = """
        WEBVTT - made by Lobby Server

        NOTE this is not a cue

        STYLE
        ::cue { color: yellow }

        1
        00:00:01.000 --> 00:00:03.500 line:90% align:center
        <i>Hallo</i> daar,
        <v Roger>hoe gaat het?

        00:04.000 --> 00:06.000
        Tom &amp; Jerry

        00:00:05.000 --> 00:00:07.000
        [deur slaat]

        not a timestamp --> 00:00:09.000
        skipped

        01:02:03.250 --> 01:02:04.000
        Einde
        """

    @Test func cuesAreReadWithoutHeaderNotesStylesOrMarkup() {
        let cues = SubtitleCues(webVTT: Self.vtt)
        #expect(cues.count == 4)
        #expect(cues.cues[0] == .init(startMs: 1_000, endMs: 3_500, text: "Hallo daar,\nhoe gaat het?"))
        #expect(cues.cues[1].text == "Tom & Jerry")
        #expect(cues.cues[3].startMs == 3_723_250)
    }

    @Test func theRightCueIsOnScreenAtEachMoment() {
        let cues = SubtitleCues(webVTT: Self.vtt)
        #expect(cues.text(atMs: 0) == nil)
        #expect(cues.text(atMs: 1_000) == "Hallo daar,\nhoe gaat het?")
        #expect(cues.text(atMs: 3_499) == "Hallo daar,\nhoe gaat het?")
        #expect(cues.text(atMs: 3_500) == nil)
        #expect(cues.text(atMs: 4_500) == "Tom & Jerry")
        // Two at once: one under the other, in order.
        #expect(cues.text(atMs: 5_500) == "Tom & Jerry\n[deur slaat]")
        #expect(cues.text(atMs: 6_500) == "[deur slaat]")
        #expect(cues.text(atMs: 3_723_300) == "Einde")
        #expect(cues.text(atMs: 9_999_999) == nil)
    }

    @Test func windowsLineEndingsAndCommasAreRead() {
        let cues = SubtitleCues(webVTT: "WEBVTT\r\n\r\n00:00:01,000 --> 00:00:02,000\r\nHoi\r\n")
        #expect(cues.cues == [.init(startMs: 1_000, endMs: 2_000, text: "Hoi")])
    }

    @Test func somethingThatIsNotWebVTTHasNoCues() {
        #expect(SubtitleCues(webVTT: "<html>404</html>").isEmpty)
        #expect(SubtitleCues(webVTT: "").isEmpty)
    }
}

@Suite struct SubtitleChoicesTests {
    static let sidecar = SubtitleTrack(id: "side-nl", source: .sidecar, codec: "subrip", language: "nl", title: nil, isForced: false, isText: true)
    static let embedded = SubtitleTrack(id: "t2", source: .embedded, codec: "subrip", language: "en", title: nil, isForced: true, isText: true)
    static let picture = SubtitleTrack(id: "pgs", source: .embedded, codec: "hdmv_pgs_subtitle", language: "en", title: nil, isForced: false, isText: false)

    private func file(_ playability: Playability) -> MediaFile {
        MediaFile(
            assetId: "a1", sizeBytes: 1, durationMs: 1, container: playability == .direct ? "mp4" : "mkv", revision: "r1",
            playability: playability, video: nil, subtitles: [Self.sidecar, Self.embedded, Self.picture])
    }

    private func stored(_ track: SubtitleTrack) -> LocalSubtitle {
        LocalSubtitle(id: track.id, language: track.language, title: track.title, isForced: track.isForced, fileName: "\(track.id).vtt")
    }

    @Test func anMP4FromTheServerNeedsItsSubtitleFilesDrawn() {
        let options = SubtitleChoices.options(for: file(.direct), itemID: "up", playing: .direct)
        // The track inside the MP4 is in the player's own menu. The picture subtitle is drawn
        // by the app, from the server's pictures.
        #expect(options.map(\.id) == ["side-nl", "pgs"])
        #expect(options[1].source == .server(assetID: "a1", track: Self.picture))
        #expect(options[0].source == .server(assetID: "a1", track: Self.sidecar))
        #expect(options[0].label == SubtitleOption.label(language: "nl", title: nil, isForced: false, position: 1))
    }

    @Test func aStreamStartedWhileItsCopyWasWrittenLacksTheEmbeddedTracks() {
        let options = SubtitleChoices.options(for: file(.remux), itemID: "up", playing: .stream(stillBeingWritten: true))
        #expect(options.map(\.id) == ["t2", "pgs"])
        #expect(options[0].label.hasSuffix("(forced)"))
    }

    @Test func aStreamOfACompleteCopyListsEverythingItselfButPictures() {
        #expect(SubtitleChoices.options(for: file(.remux), itemID: "up", playing: .stream(stillBeingWritten: false)).map(\.id) == ["pgs"])
    }

    @Test func aDownloadedRepackagedCopyNeedsEveryStoredSubtitle() {
        let options = SubtitleChoices.options(
            for: file(.remux), itemID: "up", playing: .local(stored: [stored(Self.sidecar), stored(Self.embedded)]))
        #expect(options.map(\.id) == ["side-nl", "t2"])
        #expect(options[1].source == .stored(itemID: "up", subtitleID: "t2"))
    }

    @Test func aDownloadedMP4StillHasItsEmbeddedTracksInside() {
        let options = SubtitleChoices.options(
            for: file(.direct), itemID: "up", playing: .local(stored: [stored(Self.sidecar), stored(Self.embedded)]))
        #expect(options.map(\.id) == ["side-nl"])
    }

    @Test func aTracksOwnTitleWins() {
        #expect(SubtitleOption.label(language: "en", title: "English SDH", isForced: false, position: 1) == "English SDH")
        #expect(SubtitleOption.label(language: nil, title: nil, isForced: false, position: 2) == "Subtitles 2")
    }

    @Test func whatTheAppDrawsCarriesItsLanguageForTheViewersPreferences() {
        let streamed = SubtitleChoices.options(for: file(.remux), itemID: "up", playing: .stream(stillBeingWritten: true))
        #expect(streamed.map(\.language) == ["en", "en"])
        #expect(streamed.map(\.isForced) == [true, false])
        let stored = SubtitleChoices.options(
            for: file(.remux), itemID: "up", playing: .local(stored: [stored(Self.sidecar), stored(Self.embedded)]))
        #expect(stored.map(\.language) == ["nl", "en"])
        #expect(stored.map(\.isForced) == [false, true])

        // The preferences choose among them: Dutch, else forced English for English sound.
        let candidates = stored.map { SubtitleCandidate(id: $0.id, language: $0.language, isForced: $0.isForced, isNative: false) }
        let dutch = SubtitlePreferences(languages: ["nld"], forced: true, size: .medium, background: true)
        #expect(SubtitleChooser.choose(from: candidates, preferences: dutch, soundLanguage: "eng", deviceLanguages: [])?.id == "side-nl")
        #expect(SubtitleChooser.choose(from: candidates, preferences: .defaults, soundLanguage: "eng", deviceLanguages: [])?.id == "t2")
    }
}

@Suite struct SubtitleLookTests {
    @Test func theTimingSaysWhichWayInWords() {
        #expect(SubtitleTiming.text(0) == "In time")
        #expect(SubtitleTiming.text(500) == "0.5 s later")
        #expect(SubtitleTiming.text(-1500) == "1.5 s earlier")
        #expect(SubtitleTiming.text(2000) == "2 s later")
    }

    @Test func thePlayersOwnSubtitlesGetTheViewersSizeAndBackground() throws {
        func attributes(_ style: SubtitlePreferences) throws -> [String: Any] {
            try #require(PlayerModel.textStyleRules(for: style).first).textMarkupAttributes
        }
        let large = try attributes(SubtitlePreferences(languages: [], forced: true, size: .large, background: false))
        #expect(large[kCMTextMarkupAttribute_RelativeFontSize as String] as? Int == 130)
        #expect(large[kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String] as? [Double] == [0, 0, 0, 0])
        #expect(large[kCMTextMarkupAttribute_CharacterEdgeStyle as String] as? String == kCMTextMarkupCharacterEdgeStyle_DropShadow as String)
        let usual = try attributes(.defaults)
        #expect(usual[kCMTextMarkupAttribute_RelativeFontSize as String] as? Int == 100)
        #expect(usual[kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String] as? [Double] == [0.7, 0, 0, 0])
        #expect(usual[kCMTextMarkupAttribute_CharacterEdgeStyle as String] == nil)
    }

    // The subtitle settings are a screen of the iPhone, iPad and Mac; the TV has none.
    #if !os(tvOS)
    @Test func theSettingsNameTheLanguagesAndOfferTheRest() {
        #expect(SubtitleLanguages.summary(.defaults) == "Off")
        let chosen = SubtitlePreferences(languages: ["nl", "eng"], forced: true, size: .medium, background: true)
        #expect(SubtitleLanguages.summary(chosen) == "\(SubtitleLanguages.name("nl")), \(SubtitleLanguages.name("en"))")
        let rest = SubtitleLanguages.choices(excluding: chosen.languages)
        #expect(!rest.contains("nl"))
        #expect(!rest.contains("en"))
        #expect(rest.contains("hy"))
    }
    #endif
}

@MainActor
@Suite struct SubtitleLoaderTests {
    let test: TestApp
    static let vtt = StubResponse(status: 200, body: Data("WEBVTT\n\n00:01.000 --> 00:02.000\nHallo\n".utf8))
    static let track = SubtitleTrack(id: "t2", source: .embedded, codec: "subrip", language: "nl", title: nil, isForced: false, isText: true)
    static let option = SubtitleOption(id: "t2", label: "Dutch", source: .server(assetID: "a1", track: track))

    init() throws {
        test = try TestApp()
    }

    private var loader: SubtitleLoader {
        get throws {
            SubtitleLoader(
                client: try test.household.stub.client(token: "device-token"), downloads: test.environment.downloads,
                sleep: { _ in try Task.checkCancellation() })
        }
    }

    private var asked: Int { test.household.stub.requests("GET", "/v1/assets/a1/subtitles/t2.vtt").count }

    @Test func aSubtitleTheServerHasIsReadAtOnce() async throws {
        test.household.change { $0.subtitles["t2"] = [Self.vtt] }
        var waited = 0
        let outcome = try await loader.load(Self.option) { false } waiting: { waited += 1 }
        guard case .cues(let cues) = outcome else {
            Issue.record("Expected cues, got \(outcome)")
            return
        }
        #expect(cues.text(atMs: 1_500) == "Hallo")
        #expect(waited == 0)
        #expect(asked == 1)
    }

    @Test func picturesAreReadAsPlacedCues() async throws {
        let json = #"{"width":1920,"height":1080,"cues":[{"startMs":1000,"endMs":2000,"x":800,"y":950,"width":300,"height":60,"png":"AAEC"}]}"#
        test.household.change {
            $0.subtitles["pgs"] = [StubResponse(status: 503, body: Data()), StubResponse(status: 200, body: Data(json.utf8))]
        }
        let track = SubtitleTrack(id: "pgs", source: .embedded, codec: "hdmv_pgs_subtitle", language: "en", title: nil, isForced: false, isText: false)
        var waited = 0
        let outcome = try await loader.load(SubtitleOption(id: "pgs", label: "English", source: .server(assetID: "a1", track: track))) {
            false
        } waiting: { waited += 1 }
        guard case .pictures(let pictures) = outcome else {
            Issue.record("Expected pictures, got \(outcome)")
            return
        }
        #expect(pictures.cue(atMs: 1_500)?.x == 800)
        // Still being read the first time: asked again.
        #expect(waited == 1)
        #expect(test.household.stub.requests("GET", "/v1/assets/a1/subtitles/pgs.json").count == 2)
    }

    @Test func aBusyServerIsAskedAgain() async throws {
        test.household.change { $0.subtitles["t2"] = [StubResponse(status: 429, headers: ["Retry-After": "2"]), Self.vtt] }
        let outcome = try await loader.load(Self.option) { false } waiting: {}
        guard case .cues = outcome else {
            Issue.record("Expected cues, got \(outcome)")
            return
        }
        #expect(asked == 2)
    }

    @Test func aSubtitleInsideAFilmThatIsStillBeingPreparedIsWaitedFor() async throws {
        // The server holds the request until the copy is done, which the app's request does not
        // outlast. Twice it fails, then the copy is complete.
        test.household.change {
            $0.subtitles["t2"] = [.error(503, "unavailable", "Not yet."), .error(503, "unavailable", "Not yet."), Self.vtt]
        }
        var waited = 0
        let outcome = try await loader.load(Self.option) { true } waiting: { waited += 1 }
        guard case .cues = outcome else {
            Issue.record("Expected cues, got \(outcome)")
            return
        }
        // Told once before asking, and again after each request that came back empty-handed.
        #expect(waited == 3)
        #expect(asked == 3)
    }

    @Test func aSubtitleThatCannotBeHadFailsPlainlyWhenNothingIsBeingPrepared() async throws {
        test.household.change { $0.subtitles["t2"] = [.error(422, "unsupported_subtitle", "This subtitle track could not be read.")] }
        var waited = 0
        let outcome = try await loader.load(Self.option) { false } waiting: { waited += 1 }
        #expect(outcome == .failed)
        #expect(waited == 0)
        // Once more after the first failure, in case the copy was completed meanwhile.
        #expect(asked == 2)
    }

    @Test func somethingThatIsNotASubtitleIsNotShown() async throws {
        test.household.change { $0.subtitles["t2"] = [StubResponse(status: 200, body: Data("<html></html>".utf8))] }
        #expect(try await loader.load(Self.option) { false } waiting: {} == .failed)
    }

    @Test func aDownloadWithoutThatSubtitleFailsPlainly() async throws {
        let stored = SubtitleOption(id: "t2", label: "Dutch", source: .stored(itemID: "up", subtitleID: "t2"))
        #expect(try await loader.load(stored) { false } waiting: {} == .failed)
        #expect(asked == 0)
    }
}

/// A picture the device cannot decode (HEVC labelled hev1) plays its sound over black.
@Suite struct MissingPictureTests {
    @Test func soundWithoutAPictureSizeIsAMissingPicture() {
        #expect(PlayerModel.pictureIsMissing(presentationSize: .zero, mediaTypes: [.video, .audio]))
        #expect(PlayerModel.pictureIsMissing(presentationSize: .zero, mediaTypes: [.audio]))
    }

    @Test func aPictureOrNothingKnownIsNot() {
        #expect(!PlayerModel.pictureIsMissing(presentationSize: CGSize(width: 1920, height: 1080), mediaTypes: [.video, .audio]))
        // Tracks not listed yet: no reason to stop the film.
        #expect(!PlayerModel.pictureIsMissing(presentationSize: .zero, mediaTypes: []))
    }

    @Test func theViewerIsToldInPlainWords() {
        #expect(PlayerModel.pictureProblem == "This film can't be shown on this device yet.")
    }
}
