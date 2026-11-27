// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

@Suite struct DownloadStatusTests {
    private func record(
        _ state: DownloadState, received: Int64? = nil, local: Bool = false, staleness: DownloadStaleness? = nil,
        waiting: Bool = false, cellular: Bool = false
    ) -> DownloadRecord {
        DownloadRecord(
            itemID: "up", assetID: "a1", item: Make.movie("up", title: "Up"), showID: nil, showTitle: nil, state: state,
            transfer: received.map { DownloadTransfer(revision: "r1", expectedBytes: 2_000_000_000, receivedBytes: $0, resumedAtByte: nil) },
            local: local ? LocalCopy(revision: "r1", fileName: "r1.mp4", sizeBytes: 2_000_000_000, completedAt: Make.epoch, subtitles: []) : nil,
            staleness: staleness, requestedAt: Make.epoch, allowsCellular: cellular, retried: false,
            isWaitingForNetwork: waiting)
    }

    @Test func everyStateHasItsOwnWordsAndSymbol() {
        let states: [DownloadStatus] = [
            DownloadStatus(record: nil),
            DownloadStatus(record: record(.queued)),
            DownloadStatus(record: record(.preparing(progress: 0.3))),
            DownloadStatus(record: record(.downloading, received: 500_000_000)),
            DownloadStatus(record: record(.paused, received: 500_000_000)),
            DownloadStatus(record: record(.failed(.sizeMismatch(expectedBytes: 2, receivedBytes: 1)))),
            DownloadStatus(record: record(.verified, local: true)),
            DownloadStatus(record: record(.verified, local: true, staleness: .changedOnServer)),
        ]
        #expect(states.map(\.label) == [
            "Download", "Waiting to download", "Lobby Server is preparing the file", "Downloading", "Paused",
            "Download failed", "Downloaded", "Out of date",
        ])
        // Queued, downloading, paused, failed and verified never share a symbol: colour is not the signal.
        #expect(Set(states.map(\.symbol)).count == states.count)
    }

    @Test func aRunningDownloadCanBePausedAndAPausedOneContinued() {
        let running = DownloadStatus(record: record(.downloading, received: 500_000_000))
        #expect(running.actions == [.pause, .remove])
        #expect(running.fraction == 0.25)
        #expect(running.percentText == "25 %")
        #expect(DownloadStatus(record: record(.paused, received: 500_000_000)).actions == [.resume, .remove])
        #expect(DownloadStatus(record: record(.verified, local: true)).actions == [.remove])
        #expect(DownloadStatus(record: nil).actions == [.download])
    }

    @Test func voiceOverHearsTensNotEveryPercent() {
        #expect(DownloadStatus(record: record(.downloading, received: 840_000_000)).accessibilityText == "Downloading, 40 percent")
        #expect(DownloadStatus(record: record(.downloading, received: 860_000_000)).accessibilityText == "Downloading, 40 percent")
        #expect(DownloadStatus(record: record(.verified, local: true)).accessibilityText == "Downloaded")
    }

    @Test func aCopyOfAReplacedFileIsNeverCalledDownloaded() {
        let replaced = DownloadStatus(record: record(.verified, local: true, staleness: .changedOnServer))
        #expect(replaced.kind == .outOfDate)
        #expect(replaced.actions == [.update, .remove])
        #expect(replaced.detail?.contains("replaced") == true)

        let gone = DownloadStatus(record: record(.verified, local: true, staleness: .removedFromServer))
        #expect(gone.label == "No longer on Lobby Server")
        #expect(gone.actions == [.remove])
    }

    @Test func aDownloadHeldBackForWiFiSaysSo() {
        let held = DownloadStatus(record: record(.downloading, received: 1, waiting: true))
        #expect(held.label == "Waiting for Wi-Fi")
        #expect(held.detail?.contains("mobile data") == true)
        #expect(DownloadStatus(record: record(.downloading, received: 1, waiting: true, cellular: true)).label == "Waiting for a connection")
        #expect(DownloadStatus(record: record(.queued, waiting: true)).label == "Waiting for Lobby Server")
    }

    @Test func aFullDeviceIsSaidInBytes() {
        let status = DownloadStatus(record: record(.failed(.notEnoughSpace(neededBytes: 1_800_000_000, availableBytes: 300_000_000))))
        #expect(status.detail == "There is not enough room on this device: it needs \(MediaFormat.size(bytes: 1_800_000_000)) and \(MediaFormat.size(bytes: 300_000_000)) is free for downloads.")
        #expect(status.actions.first == .resume)
    }

    @Test func aCopyThatIsBeingReplacedStillPlays() {
        let status = DownloadStatus(record: record(.downloading, received: 500_000_000, local: true, staleness: .changedOnServer))
        #expect(status.kind == .downloading)
        #expect(status.detail == "The copy on this device plays meanwhile.")
    }
}

@Suite struct DownloadsOverviewTests {
    @Test func filmsAndShowsAreListedWithCountsAndSizes() throws {
        let show = Make.show("wild", title: "Wild Isles", episodesPerSeason: [3])
        func record(_ item: Item, _ state: DownloadState, bytes: Int64, showTitle: String? = nil) -> DownloadRecord {
            DownloadRecord(
                itemID: item.id, assetID: "a", item: item, showID: showTitle == nil ? nil : "wild", showTitle: showTitle,
                state: state,
                transfer: state == .verified ? nil : DownloadTransfer(revision: "r1", expectedBytes: 400_000_000, receivedBytes: bytes, resumedAtByte: nil),
                local: state == .verified ? LocalCopy(revision: "r1", fileName: "r1.mp4", sizeBytes: bytes, completedAt: Make.epoch, subtitles: []) : nil,
                staleness: nil, requestedAt: Make.epoch, allowsCellular: false, retried: false, isWaitingForNetwork: false)
        }
        let overview = DownloadsOverview(records: [
            record(show[3], .downloading, bytes: 100_000_000, showTitle: "Wild Isles"),
            record(show[2], .verified, bytes: 400_000_000, showTitle: "Wild Isles"),
            record(Make.movie("up", title: "Up", year: 2009), .verified, bytes: 2_000_000_000),
        ])

        #expect(overview.films.map(\.title) == ["Up"])
        #expect(overview.films[0].caption == "2009")
        #expect(overview.films[0].sizeText == MediaFormat.size(bytes: 2_000_000_000))
        #expect(overview.films[0].isPlayable)

        let group = try #require(overview.shows.first)
        #expect(group.title == "Wild Isles")
        // Episodes in order, whatever order they were asked for in.
        #expect(group.rows.map(\.title) == ["1. Chapter 1", "2. Chapter 2"])
        #expect(group.rows.map(\.caption) == ["S1 E1", "S1 E2"])
        #expect(group.summary == "1 of 2 episodes downloaded · \(MediaFormat.size(bytes: 500_000_000))")
        #expect(group.rows[1].sizeText == "\(MediaFormat.size(bytes: 100_000_000)) of \(MediaFormat.size(bytes: 400_000_000))")
        #expect(!group.rows[1].isPlayable)
        #expect(overview.total == "3 items · \(MediaFormat.size(bytes: 2_500_000_000)) on this device")
        #expect(group.rows[0].accessibilityLabel.contains("Downloaded"))
    }

    @Test func nothingDownloadedIsEmpty() {
        #expect(DownloadsOverview(records: []).isEmpty)
        #expect(DownloadsOverview(records: []).total == nil)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppDownloadTests {
    let test: TestApp
    static let film = Data(repeating: 7, count: 300_000)

    init() throws {
        let episodeFile = { (n: Int) in Make.file(durationMs: 1_200_000, assetID: "ep\(n)", sizeBytes: 100_000) }
        var show = Make.show("wild", title: "Wild Isles", episodesPerSeason: [3])
        for index in show.indices where show[index].kind == .episode {
            show[index].files = [episodeFile(show[index].episodeNumber ?? 0)]
        }
        // The third episode is an old AVI: it cannot be played, so it cannot be downloaded.
        show[4].files = [Make.file(.transcode, container: "avi", codec: "mpeg4", assetID: "ep3")]
        test = try TestApp(Household(.init(
            items: [
                Make.movie("up", title: "Up", files: [Make.file(assetID: "up-file", sizeBytes: 300_000)]),
                // A film that is never downloaded in these tests.
                Make.movie("coco", title: "Coco", files: [Make.file(assetID: "coco-file", sizeBytes: 300_000)]),
            ] + show,
            files: [
                "up-file": Self.film, "ep1": Data(repeating: 1, count: 100_000), "ep2": Data(repeating: 2, count: 100_000),
            ])))
    }

    /// Follows the downloads the way `watchDownloads()` does, until the model shows what is
    /// expected.
    private func wait(_ app: AppModel, until reached: (AppModel) -> Bool) async {
        for await records in await app.environment.downloads.updates() {
            app.applyDownloads(records)
            if reached(app) { return }
        }
    }

    @Test func aDownloadedFilmPlaysFromTheDeviceWithTheServerOutOfReach() async throws {
        let app = try await test.launchPaired(as: "alex")
        let up = try #require(app.item("up"))
        #expect(app.downloadStatus(for: "up").kind == .notDownloaded)
        #expect(app.movieDetail(for: up).action.request?.source == .direct)

        await app.download(up)
        await wait(app) { $0.downloadStatus(for: "up").kind == .downloaded }
        #expect(app.downloadsOverview.films.map(\.title) == ["Up"])
        #expect(app.movieDetail(for: up).action.request?.source == .local)

        // The Pi is off. A new launch still has the film, and Play needs no server.
        test.household.change { $0.offline = true }
        let offline = test.launch()
        await offline.start()
        #expect(offline.connectivity == .offline)
        #expect(offline.downloadStatus(for: "up").kind == .downloaded)
        #expect(offline.downloadsOverview.total == "1 item · \(MediaFormat.size(bytes: 300_000)) on this device")
        let action = offline.movieDetail(for: try #require(offline.item("up"))).action
        #expect(action.request?.source == .local)
        let file = try #require(await offline.environment.downloads.localFile(itemID: "up"))
        #expect(try Data(contentsOf: file) == Self.film)
    }

    // MARK: What a manager wants on this device

    private static func wantedUp(_ state: WantedAsset.State) -> WantedAsset {
        WantedAsset(
            assetId: "up-file", itemId: "up", revision: "r1", order: 1, bytes: 300_000, bytesExact: true, state: state,
            downloadUrl: state == .ready ? "/v1/assets/up-file/content" : nil)
    }

    @Test func aFilmAManagerPutOnThisDeviceArrivesByItselfAndIsReported() async throws {
        test.household.change { $0.wanted = DeviceWantedList(revision: "w1", assets: [Self.wantedUp(.preparing)]) }
        let app = try await test.launchPaired(as: "alex")
        // The server is still getting it ready: the device says it waits, and why.
        app.applyDownloads(await app.environment.downloads.all())
        let status = app.downloadStatus(for: "up")
        #expect(status.label == "Waiting for Lobby Server")
        #expect(status.detail?.contains("A manager keeps this on this device.") == true)
        #expect(!status.actions.contains(.remove))
        #expect(test.household.current.reports.last?.downloads.map(\.state) == [.waiting])
        #expect(test.household.current.reports.last?.downloads.first?.own == false)

        // Ready: it is fetched without anyone on the device asking, and without POST playback.
        test.household.change { $0.wanted = DeviceWantedList(revision: "w2", assets: [Self.wantedUp(.ready)]) }
        await app.syncWanted()
        await wait(app) { $0.downloadStatus(for: "up").kind == .downloaded }
        #expect(test.household.stub.recorded.allSatisfy { !$0.path.hasSuffix("/playback") })
        await app.syncWanted()
        let report = try #require(test.household.current.reports.last)
        #expect(report.downloads.map(\.state) == [.downloaded])
        #expect(report.downloads.first?.bytesDone == 300_000)

        // Taken off the list: the device removes it.
        test.household.change { $0.wanted = DeviceWantedList(revision: "w3", assets: []) }
        await app.syncWanted()
        await wait(app) { $0.downloadStatus(for: "up").kind == .notDownloaded }
        #expect(await app.environment.downloads.localFile(itemID: "up") == nil)
    }

    @Test func aServerWithoutListsLeavesTheDownloadsAlone() async throws {
        let app = try await test.launchPaired(as: "alex")
        await app.download(try #require(app.item("up")))
        await wait(app) { $0.downloadStatus(for: "up").kind == .downloaded }
        await app.syncWanted()
        #expect(app.downloadStatus(for: "up").kind == .downloaded)
        #expect(app.problem == nil)
    }

    // MARK: Without the server: the same Library, with what is on the device

    @Test func outOfReachTheLibraryShowsOnlyWhatIsDownloaded() async throws {
        test.household.change {
            $0.categoryGroups = CategoryGroups(groups: [CategoryGroup(name: "Kids", categories: ["Pixar", "Kids Movies"])])
            $0.progress["alex"] = ["coco": Make.progress("coco", positionMs: 600_000), "up": Make.progress("up", positionMs: 900_000)]
        }
        let app = try await test.launchPaired(as: "alex")
        await app.download(try #require(app.item("up")))
        await wait(app) { $0.downloadStatus(for: "up").kind == .downloaded }
        await app.download(await app.seasonDownloadPlan(seasonID: "wild-s1"))
        await wait(app) { $0.downloadsOverview.shows.first?.summary.hasPrefix("2 episodes downloaded") == true }

        // A cold launch with the Pi off.
        test.household.change { $0.offline = true }
        let offline = test.launch()
        await offline.start()
        #expect(offline.showsDownloadedOnly)
        // Up is there; Coco, which was not downloaded, is nowhere: not on a shelf, not in
        // Continue Watching, not in search.
        let kids = try #require(offline.shelves.group(id: "Kids"))
        #expect(kids.items.map(\.title) == ["Up"])
        #expect(offline.shelves.continueWatching.map(\.title) == ["Up"])
        #expect(offline.shelves.recentlyAdded.allSatisfy { $0.title != "Coco" })
        #expect(offline.search("co").isEmpty)
        #expect(offline.search("up").map(\.title) == ["Up"])
        // The pills: no Movies pill, because no main film is on the device.
        #expect(offline.shelves.filters == [.all, .series, .group("Kids")])

        // The series shows only its downloaded episodes, and every one of them plays here.
        let show = try #require(offline.shelves.series.first)
        let detail = offline.showDetail(for: show)
        let episodes = detail.seasons.flatMap(\.episodes)
        #expect(episodes.map(\.id) == ["wild-s1e1", "wild-s1e2"])
        #expect(episodes.allSatisfy { $0.action.request?.source == .local })
        #expect(kids.items.allSatisfy { offline.movieDetail(for: $0).action.request?.source == .local })

        // Watching still counts, and is sent when the server is back.
        await offline.markWatched(itemID: "up")
        #expect(offline.shelves.continueWatching.isEmpty)
        test.household.change { $0.offline = false }
        await offline.refresh()
        #expect(!offline.showsDownloadedOnly)
        #expect(offline.shelves.group(id: "Kids")?.items.map(\.title) == ["Coco", "Up"])
        #expect(test.household.current.progress["alex"]?["up"]?.completed == true)
    }

    @Test func theViewerCanAskForDownloadsOnlyWithTheServerInReach() async throws {
        let app = try await test.launchPaired(as: "alex")
        await app.download(try #require(app.item("up")))
        await wait(app) { $0.downloadStatus(for: "up").kind == .downloaded }

        await app.setDownloadedOnly(true)
        #expect(app.shelves.movies.map(\.title) == ["Up"])
        #expect(app.shelves.series.isEmpty)
        // The switch is remembered.
        let again = test.launch()
        await again.start()
        #expect(again.downloadedOnly)
        #expect(again.shelves.movies.map(\.title) == ["Up"])
        await again.setDownloadedOnly(false)
        #expect(again.shelves.movies.map(\.title) == ["Coco", "Up"])
    }

    @Test func aPageThatIsOpenStaysWhenTheServerGoesOutOfReach() async throws {
        let app = try await test.launchPaired(as: "alex")
        test.household.change { $0.offline = true }
        await app.refresh()
        #expect(app.serverIsOutOfReach)
        // Coco is not on the device and not on a shelf any more, but its page still has it,
        // and says why it cannot play.
        let coco = try #require(app.item("coco"))
        #expect(app.shelves.movies.isEmpty)
        #expect(!app.movieDetail(for: coco).action.isPlayable)
    }

    @Test func thePicturesOfADownloadAreOnTheDeviceWithoutTheServer() async throws {
        test.household.change { state in
            let index = state.items.firstIndex { $0.id == "up" }!
            state.items[index].artwork = ArtworkSet(poster: Artwork(id: "up-poster"), backdrop: Artwork(id: "up-backdrop"), logo: Artwork(id: "up-logo"))
            let other = state.items.firstIndex { $0.id == "coco" }!
            state.items[other].artwork = ArtworkSet(poster: Artwork(id: "coco-poster"))
        }
        let picture = try Make.jpeg(width: 40, height: 60)
        test.household.change { $0.pictures = ["up-poster": picture, "up-backdrop": picture, "up-logo": picture, "coco-poster": picture] }
        let app = try await test.launchPaired(as: "alex")
        await app.download(try #require(app.item("up")))
        await wait(app) { $0.downloadStatus(for: "up").kind == .downloaded }
        await app.finishKeepingArtwork()
        // Only the downloaded film's pictures were asked for, in the kept size.
        let asked = test.household.stub.recorded.filter { $0.path.hasPrefix("/v1/artwork/") }
        #expect(Set(asked.map(\.path)) == ["/v1/artwork/up-poster", "/v1/artwork/up-backdrop", "/v1/artwork/up-logo"])
        #expect(asked.allSatisfy { $0.query["w"] == ($0.path.contains("back") ? String(ArtworkLoader.keptBannerWidth.rawValue) : "800") })

        test.household.change { $0.offline = true }
        let offline = test.launch()
        await offline.start()
        let before = test.household.stub.recorded.count
        #expect(await offline.artwork(Artwork(id: "up-poster"), pixelWidth: 390) != nil)
        // Also in a size that was never fetched.
        #expect(await offline.artwork(Artwork(id: "up-backdrop"), pixelWidth: 1300) != nil)
        #expect(await offline.artwork(Artwork(id: "coco-poster"), pixelWidth: 390) == nil)
        // And the server was not asked for any of them.
        #expect(test.household.stub.recorded.dropFirst(before).allSatisfy { !$0.path.hasPrefix("/v1/artwork/") })

        // Removing the download removes its pictures.
        test.household.change { $0.offline = false }
        await offline.refresh()
        await offline.removeDownload(itemID: "up")
        await wait(offline) { $0.downloadStatus(for: "up").kind == .notDownloaded }
        await offline.finishKeepingArtwork()
        test.household.change { $0.offline = true }
        let after = test.launch()
        await after.start()
        #expect(await after.artwork(Artwork(id: "up-poster"), pixelWidth: 390) == nil)
    }

    @Test func downloadSeasonSaysWhatItNeedsAndFetchesWhatCanPlay() async throws {
        let app = try await test.launchPaired(as: "alex")
        let plan = await app.seasonDownloadPlan(seasonID: "wild-s1")
        #expect(plan.episodes.map(\.id) == ["wild-s1e1", "wild-s1e2"])
        #expect(plan.skipped == 1)
        #expect(plan.neededBytes == 200_000)
        #expect(plan.fits)
        #expect(plan.title == "Download 2 episodes?")
        #expect(plan.message.contains("1 episode cannot be played on Apple devices and is left out."))

        await app.download(plan)
        await wait(app) { $0.downloadsOverview.shows.first?.summary.hasPrefix("2 episodes downloaded") == true }
        #expect(app.downloadsOverview.shows.first?.rows.map(\.title) == ["1. Chapter 1", "2. Chapter 2"])

        // Asking again has nothing left to fetch.
        let again = await app.seasonDownloadPlan(seasonID: "wild-s1")
        #expect(again.episodes.isEmpty)
        #expect(again.alreadyHere == 2)
        #expect(again.title == "Nothing to download")
    }

    @Test func aSeasonThatDoesNotFitIsNotStarted() async throws {
        test.household.change { $0.freeBytes = 150_000 }
        let app = try await test.launchPaired(as: "alex")
        let plan = await app.seasonDownloadPlan(seasonID: "wild-s1")
        #expect(!plan.fits)
        #expect(plan.message.contains("does not fit"))
    }

    @Test func aFileReplacedOnTheServerIsFlaggedAfterTheNextRefresh() async throws {
        let app = try await test.launchPaired(as: "alex")
        await app.download(try #require(app.item("up")))
        await wait(app) { $0.downloadStatus(for: "up").kind == .downloaded }

        test.household.change { state in
            state.items[0].files = [Make.file(assetID: "up-file", sizeBytes: 300_000, revision: "r2")]
        }
        // An incremental sync returns nothing new in this stub, so start from an empty cache.
        try await app.environment.catalogueStore.clear()
        await app.refresh()
        await wait(app) { $0.downloadStatus(for: "up").kind == .outOfDate }

        let status = app.downloadStatus(for: "up")
        #expect(status.label == "Out of date")
        #expect(status.actions.first == .update)
        // It still plays, and says which copy that is.
        let action = app.movieDetail(for: try #require(app.item("up"))).action
        guard case .play(let request, _, let note?) = action else {
            Issue.record("Expected Play with a note, got \(action)")
            return
        }
        #expect(request.source == .local)
        #expect(note.contains("older"))
    }

    @Test func aRemovedDeviceKeepsItsDownloadsAndSigningOutDeletesThem() async throws {
        let app = try await test.launchPaired(as: "alex")
        await app.download(try #require(app.item("up")))
        await wait(app) { $0.downloadStatus(for: "up").kind == .downloaded }
        let file = try #require(await app.environment.downloads.localFile(itemID: "up"))

        test.household.change { $0.revoked = true }
        await app.refresh()
        #expect(app.phase == .connect)
        #expect(FileManager.default.fileExists(atPath: file.path))

        await app.signOut()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await app.environment.downloads.all().isEmpty)
    }

    @Test func removingADownloadGivesTheServerCopyBack() async throws {
        let app = try await test.launchPaired(as: "alex")
        let up = try #require(app.item("up"))
        await app.download(up)
        await wait(app) { $0.downloadStatus(for: "up").kind == .downloaded }

        await app.removeDownload(itemID: "up")
        await wait(app) { $0.downloadStatus(for: "up").kind == .notDownloaded }
        #expect(app.downloadsOverview.isEmpty)
        #expect(app.movieDetail(for: up).action.request?.source == .direct)
        #expect(test.household.stub.recorded.allSatisfy { $0.method != "DELETE" })
    }

    @Test func theMobileDataChoiceIsRemembered() async throws {
        let app = try await test.launchPaired(as: "alex")
        #expect(!app.downloadsUseMobileData)
        await app.setDownloadsUseMobileData(true)
        let relaunched = test.launch()
        await relaunched.start()
        #expect(relaunched.downloadsUseMobileData)
    }
}
