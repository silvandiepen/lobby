// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Synchronization
import Testing

@testable import Lobby

/// "There is an update": comparing versions, Apple's lookup, when to ask and when to say so,
/// and an app and a server that do not work together.
@MainActor
@Suite struct UpdateTests {
    /// The lookup's answer in the shape Apple documents for the iTunes Search API
    /// (`/lookup?bundleId=`), with the fields Lobby does not read left in. Written, not fetched:
    /// the tests never ask Apple.
    nonisolated static let lookup = #"""
    {
     "resultCount":1,
     "results": [{
      "isGameCenterEnabled":false, "features":["iosUniversal"], "advisories":[],
      "supportedDevices":["iPhone15-iPhone15", "AppleTV11-AppleTV11"],
      "kind":"software", "artworkUrl512":"https://is1-ssl.mzstatic.com/image/thumb/Purple/v4/x/512x512bb.jpg",
      "trackId":6747012345, "trackName":"Lobby", "bundleId":"mt.sil.lobby",
      "sellerName":"Example Developer", "primaryGenreName":"Entertainment",
      "version":"1.2.0", "minimumOsVersion":"18.0", "fileSizeBytes":"31457280",
      "releaseNotes":"- Films start sooner on the Apple TV.\n\n\n- Music keeps its place.",
      "releaseDate":"2026-06-01T07:00:00Z", "currentVersionReleaseDate":"2026-11-20T08:00:00Z",
      "trackViewUrl":"https://apps.apple.com/nl/app/lobby/id6747012345?uo=4",
      "price":0.00, "currency":"EUR", "averageUserRating":0, "userRatingCount":0
     }]
    }
    """#

    static let release = StoreRelease(trackId: 6_747_012_345, version: "1.2.0", minimumOsVersion: "18.0")
    static let system18 = AppVersion("18.2")!
    nonisolated static let start = Date(timeIntervalSince1970: 1_795_000_000)

    // MARK: Versions

    @Test func versionsCompareByTheirNumbers() throws {
        func v(_ text: String) throws -> AppVersion { try #require(AppVersion(text)) }
        #expect(try v("1.10") > v("1.9"))
        #expect(try v("1.2") == v("1.2.0"))
        #expect(try v("1.2.1") > v("1.2"))
        #expect(try v("2") > v("1.99.99"))
        #expect(try v("0.1.0") < v("0.2"))
        #expect(try v("1.2-beta") == v("1.2"))
        #expect(try v(" 3.0 (12)") == v("3"))
        #expect(try v("1.2.0").description == "1.2")
        #expect(AppVersion("") == nil)
        #expect(AppVersion("one.two") == nil)
        #expect(AppVersion("1..2") == nil)
        #expect(AppVersion.of(OperatingSystemVersion(majorVersion: 18, minorVersion: 1, patchVersion: 0)) == (try v("18.1")))
    }

    // MARK: Apple's lookup

    @Test func readsTheLookup() throws {
        let lookup = try StoreRelease.decode(lookup: Data(Self.lookup.utf8))
        #expect(lookup.resultCount == 1)
        let release = try #require(lookup.results.first)
        #expect(release.trackId == 6_747_012_345)
        #expect(release.version == "1.2.0")
        #expect(release.minimumOsVersion == "18.0")
        #expect(release.currentVersionReleaseDate == Date(timeIntervalSince1970: 1_795_161_600))
        // Blank lines in a row are one.
        #expect(release.shortNotes == "- Films start sooner on the Apple TV.\n\n- Music keeps its place.")
    }

    @Test func anAppNotInTheStoreHasNoResults() throws {
        let lookup = try StoreRelease.decode(lookup: Data(#"{ "resultCount": 0, "results": [] }"#.utf8))
        #expect(lookup.results.isEmpty)
    }

    @Test func longNotesAreCutAtAWord() {
        let notes = String(repeating: "Lobby plays films. ", count: 60)
        let short = StoreRelease.trim(notes, limit: 100)
        #expect(short.count <= 101)
        #expect(short.hasSuffix("…"))
        #expect(!short.contains("pla…"))
        #expect(StoreRelease(trackId: 1, version: "1", releaseNotes: "  \n ").shortNotes == nil)
    }

    @Test func asksTheLookupForThisAppInThisStorefront() throws {
        let iOS = StoreLink.lookup(bundleID: "mt.sil.lobby", country: "NL", on: .iOS)
        #expect(iOS.absoluteString == "https://itunes.apple.com/lookup?bundleId=mt.sil.lobby&country=nl")
        let mac = StoreLink.lookup(bundleID: "mt.sil.lobby", country: nil, on: .macOS)
        #expect(mac.absoluteString == "https://itunes.apple.com/lookup?bundleId=mt.sil.lobby&entity=macSoftware")
        #expect(StoreLink.country(fromStorefront: "NLD") == "nl")
        #expect(StoreLink.country(fromStorefront: "USA") == "us")
        #expect(StoreLink.country(fromStorefront: "gb") == "gb")
        #expect(StoreLink.country(fromStorefront: "") == nil)
    }

    @Test func opensTheAppStoreOfEachPlatform() {
        #expect(StoreLink.page(of: Self.release, on: .iOS)?.absoluteString == "itms-apps://apps.apple.com/app/id6747012345")
        #expect(StoreLink.page(of: Self.release, on: .macOS)?.absoluteString == "macappstore://apps.apple.com/app/id6747012345")
        #expect(StoreLink.page(of: Self.release, on: .tvOS)?.absoluteString == "com.apple.TVAppStore://itunes.apple.com/app/id6747012345")
    }

    // MARK: When

    @Test func asksAtMostOnceADay() {
        #expect(UpdateRules.isCheckDue(lastCheckedAt: nil, now: Self.start))
        #expect(!UpdateRules.isCheckDue(lastCheckedAt: Self.start, now: Self.start.addingTimeInterval(23 * 3600)))
        #expect(UpdateRules.isCheckDue(lastCheckedAt: Self.start, now: Self.start.addingTimeInterval(24 * 3600)))
        // A clock set back does not stop the checks for ever.
        #expect(UpdateRules.isCheckDue(lastCheckedAt: Self.start, now: Self.start.addingTimeInterval(-3600)))
    }

    @Test func offersOnlyANewerVersionThisSystemCanInstall() throws {
        let running = try #require(AppVersion("1.1.4"))
        let memory = UpdateMemory()
        #expect(UpdateRules.isOffered(Self.release, running: running, system: Self.system18, memory: memory, now: Self.start))
        #expect(!UpdateRules.isOffered(Self.release, running: try #require(AppVersion("1.2")), system: Self.system18, memory: memory, now: Self.start))
        #expect(!UpdateRules.isOffered(Self.release, running: try #require(AppVersion("1.3")), system: Self.system18, memory: memory, now: Self.start))
        let needs26 = StoreRelease(trackId: 1, version: "2.0", minimumOsVersion: "26.0")
        #expect(!UpdateRules.isOffered(needs26, running: running, system: Self.system18, memory: memory, now: Self.start))
        #expect(UpdateRules.isOffered(needs26, running: running, system: try #require(AppVersion("26.1")), memory: memory, now: Self.start))
    }

    @Test func laterAsksAgainAfterThreeDaysAndAnythingElseNever() throws {
        let running = try #require(AppVersion("1.0"))
        let later = UpdateMemory(answeredVersion: "1.2", answer: .later(until: Self.start.addingTimeInterval(UpdateRules.laterInterval)))
        #expect(!UpdateRules.isOffered(Self.release, running: running, system: Self.system18, memory: later, now: Self.start.addingTimeInterval(2 * 86_400)))
        #expect(UpdateRules.isOffered(Self.release, running: running, system: Self.system18, memory: later, now: Self.start.addingTimeInterval(3 * 86_400)))

        let done = UpdateMemory(answeredVersion: "1.2.0", answer: .done)
        #expect(!UpdateRules.isOffered(Self.release, running: running, system: Self.system18, memory: done, now: Self.start.addingTimeInterval(300 * 86_400)))
        // A newer version is offered again, whatever was said to the one before.
        let next = StoreRelease(trackId: 1, version: "1.3", minimumOsVersion: "18.0")
        #expect(UpdateRules.isOffered(next, running: running, system: Self.system18, memory: done, now: Self.start))
    }

    @Test func noticesWaitForAGrownUpInTheLibraryWithNothingPlaying() {
        #expect(NoticeMoment(isInLibrary: true, isKidsMode: false, isPlaying: false).allowsNotice)
        #expect(!NoticeMoment(isInLibrary: true, isKidsMode: true, isPlaying: false).allowsNotice)
        #expect(!NoticeMoment(isInLibrary: true, isKidsMode: false, isPlaying: true).allowsNotice)
        #expect(!NoticeMoment(isInLibrary: false, isKidsMode: false, isPlaying: false).allowsNotice)
    }

    // MARK: The model

    @Test func checksOnlyInACopyFromTheAppStoreAndOnceADay() async throws {
        let fake = FakeStore(channel: .testFlight)
        let model = UpdateModel(source: fake.source(), now: fake.now)
        await model.checkIfDue()
        #expect(fake.asked.isEmpty)

        fake.setChannel(.appStore)
        await model.checkIfDue()
        #expect(fake.asked.map(\.absoluteString) == ["https://itunes.apple.com/lookup?bundleId=mt.sil.lobby&country=nl"])
        #expect(model.state == .available(try #require(model.newer)))

        fake.advance(by: 12 * 3600)
        await model.checkIfDue()
        #expect(fake.asked.count == 1)
        // From Settings: at once.
        await model.checkNow()
        #expect(fake.asked.count == 2)
        fake.advance(by: 24 * 3600)
        await model.checkIfDue()
        #expect(fake.asked.count == 3)

        // The day counts across launches.
        let again = UpdateModel(source: fake.source(), now: fake.now)
        await again.checkIfDue()
        #expect(fake.asked.count == 3)
    }

    @Test func aTestBuildAsksWhenTold() async throws {
        let fake = FakeStore(channel: .development)
        var source = fake.source()
        source.alwaysChecks = true
        let model = UpdateModel(source: source, now: fake.now)
        await model.checkIfDue()
        #expect(fake.asked.count == 1)
    }

    @Test func saysWhatTheCheckFound() async throws {
        let fake = FakeStore(channel: .appStore, version: "1.2.0")
        let model = UpdateModel(source: fake.source(), now: fake.now)
        #expect(model.versionText == "Version 1.2.0 (7)")
        await model.checkNow()
        #expect(model.state == .upToDate)
        #expect(model.newer == nil)

        fake.setAnswer(.failure)
        await model.checkNow()
        #expect(model.state == .failed)

        fake.setAnswer(.body(#"{ "resultCount": 0, "results": [] }"#))
        await model.checkNow()
        #expect(model.state == .notInStore)
    }

    @Test func aFailedCheckIsTriedAgainAtTheNextLaunch() async throws {
        let fake = FakeStore(channel: .appStore)
        fake.setAnswer(.failure)
        let model = UpdateModel(source: fake.source(), now: fake.now)
        await model.checkIfDue()
        await model.checkIfDue()
        #expect(fake.asked.count == 2)
    }

    @Test func theNoticeComesOncePerVersionUnlessLater() async throws {
        let fake = FakeStore(channel: .appStore)
        let model = UpdateModel(source: fake.source(), now: fake.now)
        await model.checkIfDue()
        let grownUp = NoticeMoment(isInLibrary: true, isKidsMode: false, isPlaying: false)
        let release = try #require(model.notice(in: grownUp))
        #expect(release.version == "1.2.0")
        #expect(model.notice(in: NoticeMoment(isInLibrary: true, isKidsMode: true, isPlaying: false)) == nil)
        #expect(model.notice(in: NoticeMoment(isInLibrary: true, isKidsMode: false, isPlaying: true)) == nil)

        model.later(release)
        #expect(model.notice(in: grownUp) == nil)
        fake.advance(by: 3 * 86_400)
        #expect(model.notice(in: grownUp) == release)

        let page = model.done(release)
        #expect(page == StoreLink.page(of: release, on: .iOS))
        #expect(model.notice(in: grownUp) == nil)
        // Remembered across launches.
        let again = UpdateModel(source: fake.source(), now: fake.now)
        await again.checkNow()
        #expect(again.newer == release)
        #expect(again.notice(in: grownUp) == nil)
    }

    @Test func aSkippedVersionIsNeverOfferedAgainButANewerOneIs() async throws {
        let fake = FakeStore(channel: .appStore)
        let model = UpdateModel(source: fake.source(), now: fake.now)
        await model.checkIfDue()
        let grownUp = NoticeMoment(isInLibrary: true, isKidsMode: false, isPlaying: false)
        let release = try #require(model.notice(in: grownUp))
        model.skip(release)
        #expect(model.notice(in: grownUp) == nil)
        fake.advance(by: 30 * 86_400)
        #expect(model.notice(in: grownUp) == nil)

        // The daily check of another launch keeps quiet about it, also in Settings.
        let again = UpdateModel(source: fake.source(), now: fake.now)
        await again.checkIfDue()
        #expect(fake.asked.count == 2)
        #expect(again.newer == nil)
        #expect(again.state == .idle)
        #expect(again.storePage == nil)
        // Asked by hand, Settings shows it, and it still does not come up by itself.
        await again.checkNow()
        #expect(again.state == .available(release))
        #expect(again.storePage != nil)
        #expect(again.notice(in: grownUp) == nil)

        // A newer version is offered as usual.
        fake.setAnswer(.body(Self.lookup.replacingOccurrences(of: #""version":"1.2.0""#, with: #""version":"1.3.0""#)))
        fake.advance(by: 86_400)
        await again.checkIfDue()
        #expect(again.notice(in: grownUp)?.version == "1.3.0")
    }

    @Test func withSuggestionsOffNothingIsAskedOrShownButAskingByHandWorks() async throws {
        let fake = FakeStore(channel: .appStore)
        let model = UpdateModel(source: fake.source(), now: fake.now)
        #expect(model.suggestsUpdates)
        model.suggestsUpdates = false
        await model.checkIfDue()
        #expect(fake.asked.isEmpty)

        await model.checkNow()
        #expect(fake.asked.count == 1)
        #expect(model.state == .available(try #require(model.newer)))
        let grownUp = NoticeMoment(isInLibrary: true, isKidsMode: false, isPlaying: false)
        #expect(model.notice(in: grownUp) == nil)

        // Per device, across launches; and on again, the notice comes.
        let again = UpdateModel(source: fake.source(), now: fake.now)
        #expect(!again.suggestsUpdates)
        again.suggestsUpdates = true
        fake.advance(by: 86_400)
        await again.checkIfDue()
        #expect(again.notice(in: grownUp)?.version == "1.2.0")
    }

    // MARK: App and server

    @Test func appAndServerSayWhatTheyNeed() throws {
        let app = try #require(AppVersion("0.3.0"))
        #expect(ServerCompatibility(serverVersion: "0.3.0", serverNeedsApp: "0.1.0", app: app, minimumServer: "0.2.0") == .compatible)
        // A server from before the field works with every app.
        #expect(ServerCompatibility(serverVersion: "0.3.0", serverNeedsApp: nil, app: app, minimumServer: "0.2.0") == .compatible)
        #expect(
            ServerCompatibility(serverVersion: "0.1.5", serverNeedsApp: nil, app: app, minimumServer: "0.2.0")
                == .serverBehind(server: "0.1.5", needs: "0.2"))
        let behind = ServerCompatibility(serverVersion: "0.4.0", serverNeedsApp: "0.4.0", app: app, minimumServer: "0.2.0")
        #expect(behind == .appBehind(app: "0.3", needs: "0.4"))
        #expect(behind.advice.contains("App Store"))
        #expect(ServerCompatibility.serverBehind(server: "0.1.5", needs: "0.2").advice.contains("lobby update"))
    }

    @Test func aManagerIsToldOnceWhenTheAppIsBehindAndAViewerOrAChildNot() async throws {
        let household = Household()
        household.change {
            $0.server.minAppVersion = "9.0"
            $0.device.role = .manager
        }
        let test = try TestApp(household)
        let fake = FakeStore(channel: .other)
        test.environment.updates = fake.source()
        let app = try await test.launchPaired(as: "alex")
        #expect(app.phase == .library)
        #expect(app.serverCompatibility == .appBehind(app: "1.1.4", needs: "9"))
        let notice = try #require(app.updateNotice)
        #expect(notice == .mismatch(.appBehind(app: "1.1.4", needs: "9")))
        app.updates.told(app.serverCompatibility)
        #expect(app.updateNotice == nil)

        household.change { $0.device.role = .viewer }
        let viewer = try await TestApp(household).launchPaired(as: "alex")
        #expect(viewer.updateNotice == nil)
    }

    @Test func aKidsViewerIsNeverShownTheNotice() async throws {
        let household = Household()
        household.change {
            $0.knowsKids = true
            $0.profiles = [
                Profile(id: "alex", name: "Alex", color: "blue", saysKids: true),
                Profile(id: "kid", name: "Kid", color: "green", kids: KidsSettings(allowedGroupIds: []), saysKids: true),
            ]
        }
        let test = try TestApp(household)
        test.environment.hasKidsScreens = true
        let fake = FakeStore(channel: .appStore)
        test.environment.updates = fake.source()

        let kid = try await test.launchPaired(as: "kid")
        await kid.updates.checkNow()
        #expect(kid.isKidsMode)
        #expect(kid.updates.newer != nil)
        #expect(kid.updateNotice == nil)

        // Another device, with a grown-up: kids mode stays with the device it began on.
        let other = try TestApp(household)
        other.environment.hasKidsScreens = true
        other.environment.updates = FakeStore(channel: .appStore).source()
        let grownUp = try await other.launchPaired(as: "alex")
        await grownUp.updates.checkNow()
        #expect(!grownUp.isKidsMode)
        #expect(grownUp.updateNotice == .release(try #require(grownUp.updates.newer)))
    }
}

/// The App Store as the update check sees it: a channel, a storefront, an answer and a clock.
final class FakeStore: Sendable {
    enum Answer: Sendable {
        case body(String)
        case failure
    }

    private struct State: Sendable {
        var channel: DistributionChannel
        var answer: Answer = .body(UpdateTests.lookup)
        var asked: [URL] = []
        var now = UpdateTests.start
    }

    private let state: Mutex<State>
    private let version: String
    private let suite = "mt.sil.lobby.tests.updates.\(UUID().uuidString)"

    init(channel: DistributionChannel, version: String = "1.1.4") {
        state = Mutex(State(channel: channel))
        self.version = version
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    var asked: [URL] { state.withLock { $0.asked } }
    func setChannel(_ channel: DistributionChannel) { state.withLock { $0.channel = channel } }
    func setAnswer(_ answer: Answer) { state.withLock { $0.answer = answer } }
    func advance(by seconds: TimeInterval) { state.withLock { $0.now.addTimeInterval(seconds) } }

    var now: @Sendable () -> Date { { [self] in self.state.withLock { $0.now } } }

    func source() -> UpdateSource {
        UpdateSource(
            bundleID: "mt.sil.lobby", version: version, build: "7",
            system: OperatingSystemVersion(majorVersion: 18, minorVersion: 2, patchVersion: 0), platform: .iOS,
            channel: { [self] in self.state.withLock { $0.channel } },
            country: { "nl" },
            fetch: { [self] url in
                let answer = self.state.withLock { state in
                    state.asked.append(url)
                    return state.answer
                }
                switch answer {
                case .body(let text): return Data(text.utf8)
                case .failure: throw URLError(.timedOut)
                }
            },
            memory: UpdateMemoryStore(suiteName: suite))
    }
}
