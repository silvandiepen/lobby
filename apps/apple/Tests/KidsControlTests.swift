// SPDX-License-Identifier: MPL-2.0
import CoreLocation
import Foundation
import LobbyKit
import Testing

@testable import Lobby

/// What the kids screens show for each mode of the plan (docs/kids-control.md, §3).
@MainActor
@Suite struct KidsControlTests {
    private static func now(
        _ mode: KidsMode, browse: Bool, video: KidsVideo, listening: Bool, waiting: Bool = false,
        reason: KidsReason = .schedule, detail: String? = nil, until: Int64? = nil, next: KidsModeAt? = nil
    ) -> KidsNow {
        KidsNow(
            at: KidsModeAt(
                mode: mode, reason: reason, detail: detail, browse: browse, video: video, listening: listening, waiting: waiting),
            until: until, next: next)
    }

    private static let everything = now(.everything, browse: true, video: .all, listening: true)
    private static let listening = now(.listening, browse: false, video: .none, listening: true)
    private static let nothing = now(.nothing, browse: false, video: .none, listening: false, until: 1_795_532_400_000)
    private static let askToOpen = now(.ask, browse: false, video: .none, listening: false, waiting: true, reason: .away)
    private static let askPerTitle = now(.ask, browse: true, video: .none, listening: true)

    private static func request(_ state: KidsRequestState) -> KidsRequest {
        KidsRequest(
            id: "q", profileId: "yeva", deviceId: "tablet", kind: .open, itemId: nil, state: state, createdAt: 0,
            expiresAt: 600_000)
    }

    @Test func showsTheLibraryAsBeforeWithoutAPlan() {
        #expect(KidsControlModel.screen(for: nil, request: nil, isOffline: false) == .open)
        #expect(KidsControlModel.screen(for: Self.everything, request: nil, isOffline: false) == .open)
    }

    @Test func showsOnlyListeningAndRestingWithoutFilms() {
        let listening = KidsControlModel.screen(for: Self.listening, request: nil, isOffline: false)
        #expect(listening == .listening)
        #expect(!listening.showsFilms)
        let resting = KidsControlModel.screen(for: Self.nothing, request: nil, isOffline: false)
        guard case .resting(let info) = resting else {
            Issue.record("not resting: \(resting)")
            return
        }
        #expect(info.until == Date(millisecondsSince1970: 1_795_532_400_000))
        #expect(!resting.showsFilms)
        #expect(resting.title == "Lobby is resting")
    }

    @Test func saysWhereItRests() {
        let school = Self.now(.nothing, browse: false, video: .none, listening: false, reason: .place, detail: "School")
        let screen = KidsControlModel.screen(for: school, request: nil, isOffline: false)
        #expect(screen.title == "At School")
        let screenTime = Self.now(.listening, browse: false, video: .none, listening: false, reason: .screenTime)
        #expect(KidsControlModel.screen(for: screenTime, request: nil, isOffline: false).title == "That was all the watching for today")
    }

    @Test func asksToOpenAndFollowsTheQuestion() {
        let screen = { (request: KidsRequest?, offline: Bool) in
            KidsControlModel.screen(for: Self.askToOpen, request: request, isOffline: offline)
        }
        #expect(screen(nil, false) == .asking(.sending))
        #expect(screen(Self.request(.waiting), false) == .asking(.waiting(Self.request(.waiting))))
        #expect(screen(Self.request(.declined), false) == .asking(.declined))
        #expect(screen(Self.request(.expired), false) == .asking(.noAnswer(retryAt: nil)))
        // An answer that ran out asks again.
        #expect(screen(Self.request(.allowed), false) == .asking(.sending))
        #expect(screen(nil, true) == .asking(.offline))
        #expect(!screen(nil, false).showsFilms)
        let later = Date().addingTimeInterval(600)
        #expect(
            KidsControlModel.screen(for: Self.askToOpen, request: nil, isOffline: false, retryAt: later)
                == .asking(.noAnswer(retryAt: later)))
    }

    @Test func browsesAndListensWhenAskingPerTitle() {
        let screen = KidsControlModel.screen(for: Self.askPerTitle, request: nil, isOffline: false)
        #expect(screen == .askPerTitle)
        #expect(screen.showsFilms)
    }

    @Test func letsAFilmPlayOnlyWhereVideoIsAllowed() {
        let model = KidsControlModel()
        #expect(model.allowsVideo(of: ["balloon"]))
        model.heard(Self.listening)
        #expect(!model.allowsVideo(of: ["balloon"]))
        var granted = Self.askPerTitle
        granted.at.video = .titles
        granted.at.titles = ["show"]
        model.heard(granted)
        #expect(model.allowsVideo(of: ["episode", "show"]))
        #expect(!model.allowsVideo(of: ["balloon"]))
    }

    @Test func countsDownOnlyInTheLastMinutesBeforeAStricterMode() {
        let model = KidsControlModel()
        let at = Date(timeIntervalSince1970: 1_795_530_000)
        let until = Int64((at.timeIntervalSince1970 + 4 * 60) * 1000)
        model.heard(Self.now(.everything, browse: true, video: .all, listening: true, until: until, next: Self.listening.at))
        let left = model.countdown(at: at)
        #expect(left == 240)
        #expect(KidsCountdownText.text(left: 240, next: Self.listening.at) == "Listening time in 4 minutes")
        #expect(model.countdown(at: at.addingTimeInterval(-120)) == nil)
        // Towards more, nothing counts down.
        model.heard(Self.now(.listening, browse: false, video: .none, listening: true, until: until, next: Self.everything.at))
        #expect(model.countdown(at: at) == nil)
    }

    @Test func goesOfflineToNothingWithoutASignedCopy() {
        let model = KidsControlModel()
        model.wentOffline()
        #expect(model.isOffline)
        guard case .resting(let info) = model.screen else {
            Issue.record("not resting: \(model.screen)")
            return
        }
        #expect(info.reason == .offline)
    }

    @Test func keepsTheQuestionsOfAGrownUp() {
        let model = KidsControlModel()
        var asked = Self.request(.waiting)
        asked.viewer = KidsRequest.Viewer(name: "Robin", avatar: nil, color: "teal")
        model.heard(asked, closed: false)
        #expect(model.questions.map(\.id) == ["q"])
        var answered = asked
        answered.state = .allowed
        model.heard(answered, closed: true)
        #expect(model.questions.isEmpty)
    }
}

/// The grown-up's page and the words around asking (docs/kids-control.md, §4).
@MainActor
@Suite struct KidsPlanPageTests {
    @Test func drawsTheWeekWithTheStricterOnTop() {
        var plan = KidsPlan.none
        plan = KidsWeek.applying(KidsWeek.schoolDays, to: plan)
        plan = KidsWeek.applying(KidsWeek.bedtime, to: plan)
        let tuesday = KidsWeek.segments(of: plan, day: 2)
        #expect(tuesday.map(\.mode) == [.listening, .everything, .nothing, .everything, .listening])
        #expect(tuesday.map(\.start) == [0, 420, 480, 900, 1170])
        #expect(tuesday.last?.end == 1440)
        // No school on Saturday.
        #expect(KidsWeek.segments(of: plan, day: 6).map(\.mode) == [.listening, .everything, .listening])
        // A preset again puts it back, never twice.
        var changed = plan
        changed.blocks[0].end = "16:00"
        #expect(KidsWeek.applying(KidsWeek.schoolDays, to: changed).blocks == plan.blocks)
    }

    @Test func namesWhoIsAsked() {
        #expect(KidsAskText.asking([]) == "Asking a grown-up…")
        #expect(KidsAskText.asking(["Dad"]) == "Asking Dad…")
        #expect(KidsAskText.asking(["Mum", "Dad"]) == "Asking Mum and Dad…")
        #expect(KidsAskText.asking(["Mum", "Dad", "Gran"]) == "Asking Mum, Dad and Gran…")
    }

    @Test func saysWhoAnsweredAndWhat() {
        var request = KidsRequest(
            id: "q", profileId: "yeva", deviceId: "tablet", kind: .open, state: .allowed, createdAt: 0, expiresAt: 1,
            answer: .watch, answeredAt: 1_000_000, answeredByName: "Dad",
            grant: KidsRequest.Grant(mode: .everything, until: 1_000_000 + 3_600_000))
        #expect(KidsAskText.answered(request) == "Answered by Dad — Watch for 1 h")
        request.grant = KidsRequest.Grant(mode: .listening, until: 1_000_000 + 30 * 60_000)
        #expect(KidsAskText.answered(request) == "Answered by Dad — Listen for 30 min")
        request.state = .declined
        request.grant = nil
        #expect(KidsAskText.answered(request) == "Answered by Dad — Not now")
    }

    @Test func showsWhoAnsweredOnTheOtherGrownUpsDevices() {
        let model = KidsControlModel()
        let viewer = KidsRequest.Viewer(name: "Robin", color: "teal")
        var asked = KidsRequest(
            id: "q", profileId: "yeva", deviceId: "tablet", kind: .open, state: .waiting, createdAt: 0, expiresAt: 1, viewer: viewer)
        model.heard(asked, closed: false)
        asked.state = .allowed
        asked.answeredByName = "Mum"
        model.heard(asked, closed: true)
        #expect(model.questions.isEmpty)
        #expect(model.answered.map(\.answeredByName) == ["Mum"])
    }

    @Test func beginsANewKidsViewerWithTheKidsPart() {
        let groups = CategoryGroups(groups: [
            CategoryGroup(id: "main", name: nil, entries: []),
            CategoryGroup(id: "kids", name: "Kids", entries: []),
            CategoryGroup(id: "late", name: "Grown-ups", entries: []),
        ])
        #expect(KidsSetup.defaultLimits(for: groups).allowedGroupIds == ["kids"])
        #expect(KidsSetup.defaultLimits(for: CategoryGroups(groups: [])).allowedGroupIds.isEmpty)
    }

    @Test func toldThePlaceOnlyWhenAllowed() {
        let places = [
            KidsPlace(id: "gran", name: "Grandma's", latitude: 1, longitude: 1, radiusMeters: 500, mode: .listening),
            KidsPlace(id: "school", name: "School", latitude: 2, longitude: 2, radiusMeters: 500, mode: .nothing),
        ]
        #expect(KidsPlaceWatcher.report(isAllowed: false, inside: ["school"], places: places) == .unknown)
        #expect(KidsPlaceWatcher.report(isAllowed: true, inside: [], places: places) == .outside)
        #expect(KidsPlaceWatcher.report(isAllowed: true, inside: ["gran", "school"], places: places) == .inside(placeID: "school"))
        #expect(!KidsPlaceWatcher.isAllowed(.denied, servicesOn: true))
        #expect(!KidsPlaceWatcher.isAllowed(.notDetermined, servicesOn: true))
        #expect(!KidsPlaceWatcher.isAllowed(.restricted, servicesOn: true))
        #expect(!KidsPlaceWatcher.isAllowed(.authorizedAlways, servicesOn: false))
        #expect(KidsPlaceWatcher.isAllowed(.authorizedAlways, servicesOn: true))
    }
}
