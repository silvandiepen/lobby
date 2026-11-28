// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Foundation
import LobbyDirect
import Testing

@testable import LobbyKit

/// The device's half of kids control: the same rule as the server's, and the signed copy that
/// holds offline without a clock anyone can turn.
@Suite struct KidsControlTests {
    static let zone = TimeZone(identifier: "Europe/Amsterdam")!
    /// Tuesday 2026-11-24, 16:00 in Amsterdam.
    static let tuesday4pm: Int64 = 1_795_532_400_000
    static let minute: Int64 = 60_000

    static let plan = KidsPlan(
        blocks: [
            KidsPlanBlock(days: [1, 2, 3, 4, 5], start: "08:00", end: "15:00", mode: .nothing, label: "School"),
            KidsPlanBlock(days: [1, 2, 3, 4, 5, 6, 7], start: "19:30", end: "07:00", mode: .listening, label: "Bedtime"),
        ],
        music: true)

    static func context(_ more: (inout KidsPlanContext) -> Void = { _ in }) -> KidsPlanContext {
        var context = KidsPlanContext(timeZone: zone, away: false, place: .outside)
        more(&context)
        return context
    }

    // MARK: The rule

    @Test func followsTheWeek() {
        let at = { (hours: Int64) in KidsPlanResolver.modeAt(Self.plan, Self.context(), at: Self.tuesday4pm + hours * 3_600_000) }
        #expect(at(0).mode == .everything)
        #expect(at(-6).mode == .nothing)  // 10:00, school
        #expect(at(5).mode == .listening)  // 21:00
        #expect(at(14).mode == .listening)  // Wednesday 06:00
        #expect(at(15).mode == .everything)  // Wednesday 07:00
        #expect(at(16).mode == .nothing)  // Wednesday 08:00, school again
    }

    @Test func knowsUntilWhenAndWhatComes() {
        let now = KidsPlanResolver.resolve(Self.plan, Self.context(), at: Self.tuesday4pm)
        #expect(now.until == Self.tuesday4pm + 210 * Self.minute)
        #expect(now.next?.mode == .listening)
        #expect(now.next?.listening == true)
        #expect(now.next?.browse == false)
    }

    @Test func letsAnOverrideWinAndAnAnswerNeverGoPastBedtime() {
        let rest = KidsOverride(mode: .nothing, until: Self.tuesday4pm + 60 * Self.minute)
        #expect(KidsPlanResolver.modeAt(Self.plan, Self.context { $0.override = rest }, at: Self.tuesday4pm).reason == .override)
        var asking = Self.plan
        asking.defaultMode = .ask
        let seven = Self.tuesday4pm + 3 * 60 * Self.minute
        let watch = KidsGrant(id: "g", mode: .everything, until: seven + 120 * Self.minute)
        let now = KidsPlanResolver.resolve(asking, Self.context { $0.grants = [watch] }, at: seven)
        #expect(now.at.video == .all)
        #expect(now.until == seven + 30 * Self.minute)
        #expect(now.next?.mode == .listening)
        // Without an answer, Ask to open only asks.
        #expect(KidsPlanResolver.modeAt(asking, Self.context(), at: seven).waiting)
    }

    @Test func followsTheScheduleWhereItCannotTellUnlessAsked() {
        var plan = KidsPlan(music: true)
        plan.places = [
            KidsPlace(id: "school", name: "School", latitude: 1, longitude: 1, radiusMeters: 300, mode: .nothing),
            KidsPlace(id: "home", name: "Home", latitude: 2, longitude: 2, radiusMeters: 300, mode: .asSchedule),
        ]
        let unknown = Self.context { $0.place = .unknown }
        // Nothing chosen: the places do not apply.
        #expect(KidsPlanResolver.modeAt(plan, unknown, at: Self.tuesday4pm).mode == .everything)
        #expect(KidsPlanResolver.modeAt(plan, unknown, at: Self.tuesday4pm).reason == .default)
        #expect(KidsPlanResolver.modeAt(plan, Self.context { $0.place = .inside(placeID: "school") }, at: Self.tuesday4pm).detail == "School")
        // A place as schedule changes nothing.
        #expect(KidsPlanResolver.modeAt(plan, Self.context { $0.place = .inside(placeID: "home") }, at: Self.tuesday4pm).reason == .default)
        #expect(KidsPlanResolver.modeAt(plan, Self.context(), at: Self.tuesday4pm).mode == .everything)
        // Asked for the strictest place, which passes a place as schedule by.
        plan.whenPlaceUnknown = .strictestPlace
        #expect(KidsPlanResolver.modeAt(plan, unknown, at: Self.tuesday4pm).mode == .nothing)
        #expect(KidsPlanResolver.modeAt(plan, unknown, at: Self.tuesday4pm).reason == .placeUnknown)
        plan.whenPlaceUnknown = .listening
        #expect(KidsPlanResolver.modeAt(plan, unknown, at: Self.tuesday4pm).mode == .listening)
        #expect(plan.strictest == .nothing)
        plan.places.removeFirst()
        plan.whenPlaceUnknown = .strictestPlace
        #expect(plan.strictestPlace == nil)
        #expect(KidsPlanResolver.modeAt(plan, unknown, at: Self.tuesday4pm).reason == .default)
    }

    @Test func decodesWhatHoldsWhereItCannotTell() throws {
        func decode(_ json: String) throws -> KidsPlan {
            try LobbyJSON.decoder().decode(KidsPlan.self, from: Data(json.utf8))
        }
        #expect(try decode(#"{}"#).whenPlaceUnknown == nil)
        #expect(try decode(#"{"whenPlaceUnknown":null}"#).whenPlaceUnknown == nil)
        #expect(try decode(#"{"whenPlaceUnknown":"strictest"}"#).whenPlaceUnknown == .strictestPlace)
        #expect(try decode(#"{"whenPlaceUnknown":"listening"}"#).whenPlaceUnknown == .listening)
        // A newer value: kept, and as strict as Nothing.
        let newer = try decode(#"{"whenPlaceUnknown":"sometimes"}"#)
        #expect(newer.whenPlaceUnknown == .unknown("sometimes"))
        #expect(newer.whenPlaceUnknown?.mode?.strictness == KidsMode.nothing.strictness)
        let place = #"{"id":"home","name":"Home","latitude":1,"longitude":1,"radiusMeters":300,"mode":"schedule"}"#
        let plan = try decode(#"{"places":[\#(place)]}"#)
        #expect(plan.places.first?.mode == .asSchedule)
        #expect(plan.places.first?.mode.mode == nil)
        // It goes back to the server as it came.
        let again = try decode(String(decoding: try LobbyJSON.encoder().encode(plan), as: UTF8.self))
        #expect(again.places.first?.mode == .asSchedule)
    }

    @Test func endsVideoWhenScreenTimeIsUsed() {
        var plan = KidsPlan(music: true)
        plan.screenTime = KidsScreenTime(weekdayMinutes: 60, weekendMinutes: nil)
        let used = KidsPlanResolver.resolve(plan, Self.context { $0.videoSeconds = { _ in 3600 } }, at: Self.tuesday4pm)
        #expect(used.at.mode == .listening)
        #expect(used.at.reason == .screenTime)
        // Again at midnight.
        #expect(used.until == Self.tuesday4pm + 8 * 60 * Self.minute)
    }

    @Test func goesBySummerTime() {
        let plan = KidsPlan(blocks: [KidsPlanBlock(days: [7], start: "02:30", end: "04:00", mode: .nothing)])
        // 2026-03-29 00:30 UTC is 01:30 winter time; at 01:00 UTC the clock jumps to 03:00.
        let now = KidsPlanResolver.resolve(plan, Self.context(), at: 1_774_744_200_000)
        #expect(now.until == 1_774_746_000_000)
    }

    @Test func treatsAModeItDoesNotKnowAsNothing() throws {
        let json = #"{"defaultMode":"sometimes","blocks":[]}"#
        let plan = try LobbyJSON.decoder().decode(KidsPlan.self, from: Data(json.utf8))
        #expect(KidsPlanResolver.modeAt(plan, Self.context(), at: Self.tuesday4pm).isResting)
    }

    // MARK: The signed copy

    struct Clock: KidsClock {
        var wallMs: Int64
        var monotonicMs: Double
        var bootSession: String
    }

    static let key = Curve25519.Signing.PrivateKey()

    static func me(plan: KidsPlan = Self.plan, issuedAt: Int64 = tuesday4pm, deviceID: String = "tablet", key: Curve25519.Signing.PrivateKey = key)
        throws -> KidsMe
    {
        let copy = KidsPlanCopy(
            v: 1, profileId: "yeva", deviceId: deviceID, issuedAt: issuedAt, validUntil: issuedAt + 7 * 24 * 60 * minute,
            timeZone: "Europe/Amsterdam", plan: plan, override: nil, grants: [],
            screenTime: .init(day: "2026-11-24", seconds: 0))
        let payload = try LobbyJSON.encoder().encode(copy)
        let signature = try key.signature(for: payload)
        let now = KidsPlanResolver.resolve(plan, context(), at: issuedAt)
        return KidsMe(
            profileId: "yeva", now: now, plan: plan, timeZone: "Europe/Amsterdam", request: nil,
            signed: SignedKidsPlan(payload: payload.base64URL, signature: signature.base64URL),
            publicKey: key.publicKey.rawRepresentation.base64URL, serverTime: issuedAt)
    }

    static func synced(at clock: Clock) throws -> KidsPlanCache {
        var cache = KidsPlanCache()
        try cache.accept(try me(), deviceID: "tablet", clock: clock)
        return cache
    }

    @Test func holdsThePlanOfflineByTheServersClock() throws {
        let start = Clock(wallMs: Self.tuesday4pm, monotonicMs: 1_000, bootSession: "a")
        let cache = try Self.synced(at: start)
        // Two hours later: bedtime by the monotonic clock.
        var later = start
        later.monotonicMs += 4 * 3_600_000
        later.wallMs += 4 * 3_600_000
        #expect(cache.now(place: .outside, clock: later).at.mode == .listening)
    }

    @Test func doesNotOpenWhenTheClockIsTurned() throws {
        // At school, 10:00 on Tuesday.
        let school = Clock(wallMs: Self.tuesday4pm - 6 * 3_600_000, monotonicMs: 0, bootSession: "a")
        var cache = KidsPlanCache()
        try cache.accept(try Self.me(issuedAt: school.wallMs), deviceID: "tablet", clock: school)
        // The child sets the clock to Saturday: the monotonic clock says it is still Tuesday.
        var turned = school
        turned.wallMs += 4 * 24 * 3_600_000
        turned.monotonicMs += 60_000
        #expect(cache.now(place: .outside, clock: turned).at.mode == .nothing)
        // And back to last night: the stricter of both moments holds.
        turned.wallMs = school.wallMs - 12 * 3_600_000
        #expect(cache.now(place: .outside, clock: turned).at.mode == .nothing)
    }

    @Test func neverGoesBeforeWhatItTrustedAfterARestart() throws {
        let school = Clock(wallMs: Self.tuesday4pm - 6 * 3_600_000, monotonicMs: 5_000, bootSession: "a")
        var cache = KidsPlanCache()
        try cache.accept(try Self.me(issuedAt: school.wallMs), deviceID: "tablet", clock: school)
        // Restarted with the clock turned back to 07:30, before school began: the latest
        // trusted moment (10:00) holds as well, and the stricter wins.
        let restarted = Clock(wallMs: school.wallMs - 150 * Self.minute, monotonicMs: 10, bootSession: "b")
        #expect(cache.now(place: .outside, clock: restarted).at.mode == .nothing)
    }

    @Test func fallsBackToTheStrictestWhenTheCopyRunsOut() throws {
        let start = Clock(wallMs: Self.tuesday4pm, monotonicMs: 0, bootSession: "a")
        let cache = try Self.synced(at: start)
        var week = start
        week.monotonicMs += 8 * 24 * 3_600_000
        week.wallMs += 8 * 24 * 3_600_000
        let now = cache.now(place: .outside, clock: week)
        #expect(now.at.mode == .nothing)
        #expect(now.at.reason == .offline)
        // Without any copy: Nothing.
        #expect(KidsPlanCache().now(place: .outside, clock: start).at.isResting)
    }

    @Test func takesThePlanAsItIsOfflineNotAsAway() throws {
        var plan = Self.plan
        plan.away = .listening
        let start = Clock(wallMs: Self.tuesday4pm, monotonicMs: 0, bootSession: "a")
        var cache = KidsPlanCache()
        try cache.accept(try Self.me(plan: plan), deviceID: "tablet", clock: start)
        #expect(cache.now(place: .outside, clock: start).at.mode == .everything)
    }

    @Test func readsWhoIsAskedAndWhatAnAnswerGave() throws {
        let plan = try LobbyJSON.decoder().decode(
            KidsPlan.self,
            from: Data(#"{"askers":[{"profileId":"dad","deviceIds":["phone"]}],"musicSourceIds":["m1"]}"#.utf8))
        #expect(plan.askers == [KidsAsker(profileId: "dad", deviceIds: ["phone"])])
        #expect(plan.musicSourceIds == ["m1"])
        // Music is on unless turned off.
        #expect(plan.music)
        #expect(KidsPlan.none.music)
        let request = try LobbyJSON.decoder().decode(
            KidsRequest.self,
            from: Data(
                #"""
                {"id":"q","profileId":"yeva","deviceId":"tablet","kind":"open","itemId":null,"state":"allowed",
                 "createdAt":0,"expiresAt":1,"answer":"watch","answeredBy":"phone","answeredAt":1,"grantId":"g",
                 "answeredByName":"Dad","grant":{"mode":"everything","until":3600000,"itemId":null}}
                """#.utf8))
        #expect(request.answeredByName == "Dad")
        #expect(request.grant == KidsRequest.Grant(mode: .everything, until: 3_600_000))
    }

    @Test func countsVideoWatchedOffline() throws {
        var plan = KidsPlan(music: true)
        plan.screenTime = KidsScreenTime(weekdayMinutes: 30, weekendMinutes: nil, whenOut: .nothing)
        let start = Clock(wallMs: Self.tuesday4pm, monotonicMs: 0, bootSession: "a")
        var cache = KidsPlanCache()
        try cache.accept(try Self.me(plan: plan), deviceID: "tablet", clock: start)
        cache.addVideo(seconds: 29 * 60, clock: start)
        #expect(cache.now(place: .outside, clock: start).at.mode == .everything)
        cache.addVideo(seconds: 60, clock: start)
        #expect(cache.now(place: .outside, clock: start).at.mode == .nothing)
    }

    @Test func refusesWhatIsNotTheServers() throws {
        let clock = Clock(wallMs: Self.tuesday4pm, monotonicMs: 0, bootSession: "a")
        var cache = try Self.synced(at: clock)
        // Another key: not the pinned one.
        #expect(throws: KidsPlanCacheError.keyChanged) {
            try cache.accept(try Self.me(key: Curve25519.Signing.PrivateKey()), deviceID: "tablet", clock: clock)
        }
        // A payload changed after it was signed.
        var forged = try Self.me()
        var copy = try LobbyJSON.decoder().decode(KidsPlanCopy.self, from: Data(base64URL: forged.signed.payload)!)
        copy.plan = KidsPlan(music: true)
        forged.signed.payload = try LobbyJSON.encoder().encode(copy).base64URL
        #expect(throws: KidsPlanCacheError.badSignature) { try cache.accept(forged, deviceID: "tablet", clock: clock) }
        // A copy for another device.
        #expect(throws: KidsPlanCacheError.notForThis) {
            try cache.accept(try Self.me(deviceID: "phone"), deviceID: "tablet", clock: clock)
        }
        // What it held is still the server's.
        #expect(cache.copy?.plan == Self.plan)
    }

    // MARK: The wire

    @Test func readsWhatTheServerSends() throws {
        let json = #"""
            {"mode":"ask","reason":"away","detail":null,"browse":false,"video":"none","titles":[],"listening":false,
             "waiting":true,"grantId":null,"until":1795532400000,
             "next":{"mode":"listening","reason":"schedule","detail":"Bedtime","browse":false,"video":"none","titles":[],
                     "listening":true,"waiting":false,"grantId":null},
             "screenTime":null}
            """#
        let now = try LobbyJSON.decoder().decode(KidsNow.self, from: Data(json.utf8))
        #expect(now.at.waiting)
        #expect(now.next?.detail == "Bedtime")
        let event = LiveEventParser.decode(.init(id: nil, event: "kidsMode", data: #"{"profileId":"yeva","now":\#(json)}"#))
        guard case .kidsMode(let profile, let decoded, let lock)? = event else {
            Issue.record("not a kids mode event")
            return
        }
        #expect(profile == "yeva")
        #expect(decoded == now)
        // A server from before the lock says nothing of it.
        #expect(lock == nil)
        let locking = LiveEventParser.decode(.init(id: nil, event: "kidsMode", data: #"{"profileId":"yeva","now":\#(json),"lock":true}"#))
        guard case .kidsMode(_, _, let lock)? = locking else {
            Issue.record("not a kids mode event")
            return
        }
        #expect(lock == true)
    }

    @Test func reportsTheLockAndSwitchesItForOneDevice() async throws {
        let view = #"{"profileId":"yeva","plan":{"lockToLobby":true},"planned":true,"timeZone":"Europe/Amsterdam","now":{"mode":"everything","reason":"default","detail":null,"browse":true,"video":"all","titles":[],"listening":true,"waiting":false,"grantId":null,"until":null,"next":null,"screenTime":null},"lockDevices":[{"deviceId":"tablet","name":"Tablet","platform":"ipados","wanted":false,"source":"device","choice":false,"status":"notSetUp","locked":false,"reportedAt":5}]}"#
        let server = StubServer { request in
            request.path == "/v1/me/kids/lock"
                ? .json(200, #"{"lock":{"wanted":true,"source":"viewer"}}"#) : .json(200, view)
        }
        let client = try server.client()
        let wish = try await client.reportKidsLock(.notSetUp, locked: false, profileID: "yeva")
        #expect(wish == KidsLockWish(wanted: true, source: .viewer))
        let answer = try await client.setKidsLock(nil, deviceID: "tablet", profileID: "yeva")
        #expect(answer.plan.lockToLobby)
        #expect(answer.lockDevices == [
            KidsLockDevice(deviceId: "tablet", name: "Tablet", wanted: false, source: .device, choice: false, status: .notSetUp, reportedAt: 5)
        ])
        _ = try await client.setKidsLock(true, deviceID: "tablet", profileID: "yeva")
        let bodies = try server.recorded.map { try $0.json() }
        #expect(bodies[0]["status"] as? String == "notSetUp")
        #expect(bodies[0]["locked"] as? Bool == false)
        #expect(bodies[0]["profileId"] as? String == "yeva")
        // "As the plan says" is sent as null, not left out.
        #expect(bodies[1].keys.sorted() == ["lock"])
        #expect(bodies[1]["lock"] is NSNull)
        #expect(bodies[2]["lock"] as? Bool == true)
        #expect(server.recorded.map(\.path) == ["/v1/me/kids/lock", "/v1/profiles/yeva/kids/lock/tablet", "/v1/profiles/yeva/kids/lock/tablet"])
        #expect(server.recorded.allSatisfy { $0.method == "PUT" })
    }

    @Test func tellsThePlaceAndNeverWhereTheDeviceIs() async throws {
        let now = #"{"mode":"nothing","reason":"place","detail":"School","browse":false,"video":"none","titles":[],"listening":false,"waiting":false,"grantId":null,"until":null,"next":null,"screenTime":null}"#
        let server = StubServer { _ in .json(200, #"{"now":\#(now)}"#) }
        let client = try server.client()
        let said = try await client.reportKidsPlace(.inside(placeID: "school"))
        #expect(said.at.detail == "School")
        try await client.reportKidsPlace(.unknown, profileID: "yeva")
        let bodies = try server.recorded.map { try $0.json() }
        #expect(bodies[0].keys.sorted() == ["placeId", "state"])
        #expect(bodies[0]["placeId"] as? String == "school")
        #expect(bodies[1].keys.sorted() == ["profileId", "state"])
        #expect(bodies[1]["state"] as? String == "unknown")
        #expect(server.recorded.allSatisfy { $0.method == "PUT" && $0.path == "/v1/me/kids/place" })
    }

    @Test func registersThePushToken() async throws {
        let server = StubServer { _ in StubResponse(status: 204) }
        let client = try server.client()
        try await client.registerPush(token: Data([0x0a, 0xff, 0x01]), environment: .production)
        try await client.unregisterPush()
        let sent = try #require(server.recorded.first)
        #expect(sent.method == "PUT")
        #expect(sent.path == "/v1/me/push")
        #expect(try sent.json()["token"] as? String == "0aff01")
        #expect(try sent.json()["environment"] as? String == "production")
        #expect(server.recorded.last?.method == "DELETE")
    }

    @Test func knowsAKidsModeRefusal() {
        #expect(LobbyError.server(status: 403, code: "kids_mode", message: "").isKidsMode)
        #expect(!LobbyError.forbidden(message: "").isKidsMode)
    }
}
