// SPDX-License-Identifier: MPL-2.0
import AVFoundation
import Foundation
import LobbyKit
import Testing

@testable import Lobby

@Suite struct BufferWatchTests {
    /// One reading a second, `loaded` seconds of film arrived at each.
    private func watch(_ loaded: [Double], isForServer: Bool = false) -> BufferWatch {
        var watch = BufferWatch()
        for (second, loaded) in loaded.enumerated() {
            watch.add(.init(at: Double(second), isWaiting: true, loadedSeconds: loaded, isForServer: isForServer))
        }
        return watch
    }

    @Test func aShortWaitIsNotMentioned() {
        #expect(watch([0, 1]).notice == nil)
    }

    @Test func aLongerOneIsCalledBuffering() {
        #expect(watch([0, 0.5, 1, 1.5]).notice == .buffering)
    }

    @Test func aFastLinkIsNeverCalledSlow() {
        #expect(watch((0...15).map { Double($0) * 1.2 }).notice == .buffering)
    }

    @Test func aLinkThatCarriesLessThanTheFilmNeedsIsSaid() throws {
        guard case .slow(let rate) = watch((0...15).map { Double($0) * 0.4 }).notice else {
            Issue.record("Not slow")
            return
        }
        #expect(abs(rate - 0.4) < 0.01)
        #expect(BufferNotice.slow(rate: 0.4).explanation(filmBitrate: 5_600_000)?
            .hasPrefix("It carries about 40 % of what this film needs (5.6 Mbit/s)") == true)
    }

    @Test func whenNothingArrivesTheViewerCanTryAgain() {
        #expect(watch(Array(repeating: 3, count: 20)).notice != .stalled)
        #expect(watch(Array(repeating: 3, count: 21)).notice == .stalled)
        // Something trickles in: slow, not gone.
        #expect(watch((0...40).map { Double($0) * 0.1 }).notice != .stalled)
    }

    @Test func waitingForTheServerToPrepareTheFilmIsNotTheConnection() {
        #expect(watch(Array(repeating: 0, count: 40), isForServer: true).notice == .buffering)
        #expect(watch(Array(repeating: 0, count: 91), isForServer: true).notice == .stalled)
    }

    @Test func playingClearsItAndASeekDoesNotCountAsNothing() {
        var watch = watch(Array(repeating: 3, count: 25))
        watch.add(.init(at: 25, isWaiting: false, loadedSeconds: 30))
        #expect(watch.notice == nil)
        // The player threw away what it had: the silence is counted from there.
        watch.add(.init(at: 26, isWaiting: true, loadedSeconds: 30))
        watch.add(.init(at: 40, isWaiting: true, loadedSeconds: 0))
        watch.add(.init(at: 50, isWaiting: true, loadedSeconds: 0))
        #expect(watch.notice != .stalled)
        watch.add(.init(at: 60, isWaiting: true, loadedSeconds: 0))
        #expect(watch.notice == .stalled)
    }

    @Test func onlyWhatLiesAheadCounts() {
        let held = [0..<30_000, 600_000..<612_000]
        #expect(BufferWatch.secondsAhead(of: 20, in: held) == 10)
        // Just after a jump the range starts a hair after the player.
        #expect(BufferWatch.secondsAhead(of: 599.8, in: held) == 12)
        // Behind, or somewhere else: nothing to play from here.
        #expect(BufferWatch.secondsAhead(of: 300, in: held) == 0)
        #expect(BufferWatch.secondsAhead(of: .nan, in: held) == 0)
    }

    @Test func aWaitWithPlentyAheadIsNotTheConnection() {
        // The player holds half a minute and waits anyway: a slow arrival says nothing then.
        #expect(watch((0...15).map { 30 + Double($0) * 0.2 }).notice == .buffering)
        #expect(watch(Array(repeating: 30, count: 30)).notice == .buffering)
        // With little ahead the same arrival is slow.
        guard case .slow = watch((0...15).map { Double($0) * 0.2 }).notice else {
            Issue.record("Not slow")
            return
        }
    }

    @Test func theBitrateComesFromSizeAndLength() {
        #expect(BufferWatch.bitrate(sizeBytes: 2_100_000_000, durationMs: 6_000_000) == 2_800_000)
        #expect(BufferWatch.bitrate(sizeBytes: 1, durationMs: nil) == nil)
    }

    @Test func aSlowAnswerIsSaidInWords() {
        #expect(Patience.fetchingLibrary(waited: 1, titles: 0) == "Fetching the library…")
        #expect(Patience.fetchingLibrary(waited: 20, titles: 240)
            == "Fetching the library… 240 titles so far. The connection to Lobby Server is slow.")
        #expect(Patience.askingToPlay(waited: 1) != Patience.askingToPlay(waited: 9))
        #expect(!Patience.discoveryFoundNothing(waited: 9))
        #expect(Patience.discoveryFoundNothing(waited: 10))
    }
}

@Suite struct FocusMemoryTests {
    private let rows: [FocusMemory.Row] = [
        .init(shelf: "continue", items: ["a", "b", "c"]), .init(shelf: "movies", items: ["x", "y"]),
    ]

    private func memory(_ shelf: String, _ item: String) -> FocusMemory {
        var memory = FocusMemory()
        memory.remember(.init(shelf: shelf, item: item), in: rows)
        return memory
    }

    @Test func theSameTitleGetsTheRemoteBackAlsoWhenItMoved() {
        let after: [FocusMemory.Row] = [.init(shelf: "continue", items: ["c", "a", "b"])]
        #expect(memory("continue", "c").target(in: after) == .init(shelf: "continue", item: "c"))
    }

    @Test func aFinishedTitleHandsItToWhatTookItsPlace() {
        let after: [FocusMemory.Row] = [.init(shelf: "continue", items: ["a", "c"])]
        #expect(memory("continue", "b").target(in: after)?.item == "c")
        #expect(memory("continue", "c").target(in: after)?.item == "c")
        #expect(memory("continue", "c").target(in: [.init(shelf: "continue", items: ["a", "b"])])?.item == "b")
    }

    @Test func aShelfThatEmptiedHandsItToTheFirstOne() {
        #expect(memory("continue", "a").target(in: [.init(shelf: "movies", items: ["x"])]) == .init(shelf: "movies", item: "x"))
        #expect(memory("continue", "a").target(in: []) == nil)
        #expect(FocusMemory().target(in: rows) == nil)
    }
}

@Suite struct TVLibraryTests {
    @Test func thePlacesFollowTheHousehold() {
        var shelves = LibraryShelves()
        #expect(TVTab.all(for: shelves) == [.viewer, .search, .home, .movies, .series])
        shelves = LibraryShelves(
            catalogue: Catalogue(items: [Make.movie("up", categories: ["One"]), Make.movie("coco", categories: ["Two"])]),
            groups: CategoryGroups(groups: [
                CategoryGroup(id: "main", name: nil, entries: [LibraryCategory(id: "c1", name: "One"), LibraryCategory(id: "c3", name: "Three")]),
                CategoryGroup(id: "g1", name: "Anything", entries: [LibraryCategory(id: "c2", name: "Two")]),
            ]), progress: [:], context: Make.context)
        #expect(TVTab.all(for: shelves) == [.viewer, .search, .home, .movies, .group("g1")])
        #expect(TVTab.group("g1").resolved(for: shelves) == .group("g1"))
        #expect(TVTab.group("gone").resolved(for: shelves) == .home)
        #expect(TVHome.rows(of: BrowsePage(rows: [
            BrowseRow(id: "empty", title: "", content: .items([])),
            BrowseRow(id: "movies", title: "Movies", content: .items(shelves.movies)),
            BrowseRow(id: "categories", title: "", content: .categories(shelves.groups[0].categories)),
        ])) == [.init(shelf: "movies", items: ["up"]), .init(shelf: "categories", items: ["folder:c2"])])
    }

    @Test func aGrowingStreamIsNeverInTheSystemsPlayer() {
        #expect(TVPlayerSurface(stage: .playing, isBeingPrepared: false) == .system)
        #expect(TVPlayerSurface(stage: .playing, isBeingPrepared: true) == .own)
        #expect(TVPlayerSurface(stage: .failed("x"), isBeingPrepared: false) == .own)
        #expect(TVPlayerSurface(stage: .ended, isBeingPrepared: false) == .own)
    }

    @Test func theCodeIsReadInTwoHalves() {
        #expect(PairingCodeText.grouped("482913") == "482 913")
        #expect(PairingCodeText.grouped("48291") == "48291")
        #expect(PairingCodeText.grouped("") == "")
    }

    @Test func theServerIsLookedForSoonWhenItIsGone() {
        #expect(AppModel.secondsUntilNextLook(outOfReach: true, hasLibrary: true) == 15)
        #expect(AppModel.secondsUntilNextLook(outOfReach: false, hasLibrary: false) == 15)
        #expect(AppModel.secondsUntilNextLook(outOfReach: false, hasLibrary: true) == 300)
    }
}

/// The app model as the Apple TV runs it: nothing is downloaded.
@MainActor
@Suite struct TVAppTests {
    let household: Household
    let environment: AppEnvironment
    let test: TestApp

    init() throws {
        household = Household(.init(items: [
            Make.movie("up", title: "Up"),
            // An old AVI film the server converts.
            Make.movie("old", title: "Old", files: [convertible()]),
        ]))
        test = try TestApp(household)
        var environment = test.environment
        environment.keepsDownloads = false
        environment.device = DeviceIdentity(name: "Apple TV", platform: .tvos)
        self.environment = environment
    }

    private func launch() async throws -> AppModel {
        await test.credentials.setToken("device-token", forServer: "server-1")
        // Only the first time: later starts find what the one before it learned.
        if environment.preferences.connection == nil {
            environment.preferences.connection = SavedConnection(
                serverAddress: household.stub.baseURL, serverID: "server-1", serverName: "Family Pi", deviceID: "dev-1")
        }
        environment.preferences.activeProfileID = "alex"
        environment.settings.profiles = household.current.profiles
        let app = AppModel(environment: environment)
        await app.start()
        return app
    }

    @Test func theLibraryStaysWholeWhileTheServerIsOutOfReach() async throws {
        var app = try await launch()
        #expect(app.shelves.movies.map(\.id) == ["old", "up"])
        household.change { $0.offline = true }
        app = try await launch()
        #expect(app.serverIsOutOfReach)
        #expect(!app.showsDownloadedOnly)
        #expect(app.shelves.movies.map(\.id) == ["old", "up"])
        guard case .unavailable(let headline, let explanation) = app.movieDetail(for: try #require(app.item("up"))).action else {
            Issue.record("Nothing plays without the server.")
            return
        }
        #expect(headline == "Lobby Server cannot be reached")
        #expect(!explanation.contains("download"))

        household.change { $0.offline = false }
        await app.refresh()
        #expect(app.movieDetail(for: try #require(app.item("up"))).action.isPlayable)
    }

    @Test func awayFromHomeTheServerIsReachedAtItsOtherAddressWithTheSavedCredential() async throws {
        household.announceAddresses()
        _ = try await launch()
        household.change { $0.awayFromHome = true }
        // A new start, as after the TV was unplugged and taken along.
        let app = try await launch()
        #expect(app.connectivity == .online)
        #expect(app.connection?.serverAddress == household.remote.baseURL)
        #expect(app.phase == .library)
    }

    @Test func aStrangerAtTheHomeAddressNeverSeesTheCredential() async throws {
        household.announceAddresses()
        _ = try await launch()
        household.change {
            $0.awayFromHome = true
            $0.strangerAtHomeAddress = "hotel-server"
        }
        let before = household.stub.recorded.count
        let app = try await launch()
        #expect(app.connection?.serverAddress == household.remote.baseURL)
        #expect(household.stub.recorded.dropFirst(before).allSatisfy { $0.headers["Authorization"] == nil })
    }

    @Test func aListOfDownloadsForThisDeviceIsNotFollowed() async throws {
        household.change { $0.wanted = DeviceWantedList(revision: "1", assets: []) }
        let app = try await launch()
        await app.syncWanted()
        #expect(household.current.reports.isEmpty)
    }

    @Test func aConvertibleFilmPlays() async throws {
        let app = try await launch()
        #expect(app.movieDetail(for: try #require(app.item("old"))).action.request?.source == .prepared)
    }

    /// An evening seen in use: the TV woke on what was open before. A play from another
    /// device replaces it: the old player goes, the new title plays as asked, and its page is open.
    @Test func aPlayFromAnotherDeviceReplacesWhatIsShown() async throws {
        let app = try await launch()
        let up = try #require(app.item("up"))
        app.play(try #require(app.movieDetail(for: up).action.request))
        let before = try #require(app.player)
        #expect(before.request.item.id == "up")

        // The stub serves no real picture, so whether the new player gets as far as playing is
        // not what this is about: what is shown is.
        _ = await app.playFromRemote(PlayCommand(itemId: "old", profileId: "alex", startMs: 30_000))
        let now = try #require(app.player)
        #expect(now !== before)
        #expect(now.request.item.id == "old")
        #expect(now.request.startPositionMs == 30_000)
        #expect(app.remoteOpened?.itemID == "old")
        await now.close()
    }

    /// Woken for a play: who is watching waits for it, and not forever.
    @Test func aPlayThatIsOnItsWayHoldsWhoIsWatching() async throws {
        let app = try await launch()
        app.heardOfRemotePlay(waiting: true, for: .milliseconds(50))
        #expect(app.awaitsRemotePlay)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!app.awaitsRemotePlay)
        app.heardOfRemotePlay(waiting: true)
        app.heardOfRemotePlay(waiting: false)
        #expect(!app.awaitsRemotePlay)
    }

    @Test func lookingForTheServerGoesOnByItself() async throws {
        household.change { $0.offline = true }
        let app = try await launch()
        #expect(app.connectivity == .offline)
        household.change { $0.offline = false }
        let watching = Task { await app.watchServer() }
        while app.connectivity != .online { await Task.yield() }
        watching.cancel()
        #expect(!app.serverIsOutOfReach)
    }
}

private func convertible() -> MediaFile {
    var file = Make.file(.transcode, container: "avi", codec: "mpeg4")
    file.convertible = true
    return file
}
