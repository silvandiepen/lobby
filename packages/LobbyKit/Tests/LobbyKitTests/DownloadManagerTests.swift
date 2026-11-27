// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing

@testable import LobbyKit

/// The download engine against a real HTTP server on this machine (`LocalHTTPServer`): real
/// `URLSession` download tasks, real files, real pausing and continuing with `Range`.
@Suite(.timeLimit(.minutes(1)))
struct DownloadManagerTests {
    let server: LocalHTTPServer
    let directory: TemporaryDirectory
    let client: LobbyClient

    /// A megabyte that is different at every offset, so a splice of two versions would show.
    static func bytes(_ count: Int = 1_048_576, seed: Int = 7) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: ($0 &* 31 &+ $0 / 251 &+ seed) % 251) })
    }

    init() async throws {
        server = try await LocalHTTPServer()
        directory = try TemporaryDirectory()
        client = try LobbyClient(baseURL: server.baseURL, token: "device-token", session: URLSession(configuration: .ephemeral))
        serve(Self.bytes(), revision: "r1")
    }

    private func serve(_ content: Data, revision: String, statedBytes: Int? = nil, prepared: Bool = false) {
        let url = prepared ? "/v1/assets/a1/prepared/\(revision)/media.mp4" : "/v1/assets/a1/content"
        server.change {
            $0.content = content
            $0.etag = prepared ? "\(revision)-prepared" : revision
            $0.playback = [(200, Self.ready(revision: revision, bytes: statedBytes ?? content.count, url: url, prepared: prepared))]
        }
    }

    static func ready(revision: String, bytes: Int, url: String, prepared: Bool = false) -> String {
        #"{"state":"ready","mode":"\#(prepared ? "prepared" : "direct")","revision":"\#(revision)","progress":1,"preparedMs":60000,"durationMs":60000,"streamUrl":"\#(url)","downloadUrl":"\#(url)","downloadBytes":\#(bytes),"audio":[],"message":null}"#
    }

    static func preparing(_ progress: Double) -> String {
        #"{"state":"preparing","mode":"prepared","revision":"r1","progress":\#(progress),"preparedMs":0,"durationMs":60000,"streamUrl":null,"downloadUrl":null,"downloadBytes":null,"audio":[],"message":null}"#
    }

    private func manager(space: Int64? = 50_000_000_000) -> DownloadManager {
        DownloadManager(
            directory: directory.url, sessionConfiguration: .ephemeral,
            sleep: { _ in try Task.checkCancellation() },
            availableSpace: { _ in space }, spaceReserveBytes: 1_000_000)
    }

    static func item(revision: String = "r1", subtitles: [SubtitleTrack] = []) -> Item {
        Item(
            id: "film", kind: .movie, title: "Up", year: 2009, addedAt: Make.epoch,
            files: [MediaFile(
                assetId: "a1", sizeBytes: 1_048_576, durationMs: 60_000, container: "mp4", revision: revision,
                playability: .direct, video: VideoTrack(codec: "h264", width: 1920, height: 1080, bitDepth: 8),
                subtitles: subtitles)])
    }

    private func enqueue(_ manager: DownloadManager, _ item: Item = DownloadManagerTests.item()) async {
        await manager.enqueue(item, file: item.files[0], allowsCellular: false)
    }

    /// Waits for the record to get somewhere, by watching the manager's own updates.
    @discardableResult
    private func wait(
        _ manager: DownloadManager, until reached: @escaping @Sendable (DownloadRecord) -> Bool
    ) async -> DownloadRecord {
        for await records in await manager.updates() {
            if let record = records.first(where: { $0.itemID == "film" }), reached(record) { return record }
        }
        preconditionFailure("The manager stopped reporting.")
    }

    private var stagedFiles: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: DownloadPaths.staging(in: directory.url).path)) ?? []
    }

    // MARK: A download

    @Test func aFilmIsFetchedCheckedAndPutInPlace() async throws {
        let manager = manager()
        await manager.start(using: client)
        await enqueue(manager)
        let record = await wait(manager) { $0.state == .verified }

        #expect(record.isVerifiedAndCurrent)
        #expect(record.local?.revision == "r1")
        #expect(record.local?.sizeBytes == 1_048_576)
        #expect(record.local?.fileName == "r1.mp4")
        #expect(record.transfer == nil)
        let file = try #require(await manager.localFile(itemID: "film"))
        #expect(file.pathExtension == "mp4")
        #expect(try Data(contentsOf: file) == Self.bytes())
        #expect(stagedFiles.isEmpty)

        // Asked first, then fetched what the answer named, with the device's credential.
        #expect(server.requests.map(\.method) == ["POST", "GET"])
        #expect(server.requests[0].path == "/v1/assets/a1/playback")
        #expect(server.requests[1].path == "/v1/assets/a1/content")
        #expect(server.requests[1].headers["authorization"] == "Bearer device-token")
        #expect(!server.requests[1].path.contains("device-token"))
        // Downloads stay out of device backups.
        #expect(try directory.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func theCopyIsStillThereAfterTheAppIsOpenedAgain() async throws {
        let first = manager()
        await first.start(using: client)
        await enqueue(first)
        await wait(first) { $0.state == .verified }

        // A new launch, and the server is not asked anything.
        let before = server.requests.count
        let second = manager()
        await second.start(using: nil)
        #expect(await second.record(itemID: "film")?.isVerifiedAndCurrent == true)
        #expect(await second.localFile(itemID: "film") != nil)
        #expect(server.requests.count == before)
    }

    @Test func anMKVWaitsWhileTheServerWritesItsCopy() async throws {
        server.change {
            $0.etag = "r1-prepared"
            $0.playback = [
                (202, Self.preparing(0.2)), (202, Self.preparing(0.7)),
                (200, Self.ready(revision: "r1", bytes: 1_048_576, url: "/v1/assets/a1/prepared/r1/media.mp4", prepared: true)),
            ]
        }
        let manager = manager()
        await manager.start(using: client)
        await enqueue(manager)
        await wait(manager) { $0.state == .preparing(progress: 0.2) || $0.state == .preparing(progress: 0.7) }
        let record = await wait(manager) { $0.state == .verified }

        #expect(record.local?.sizeBytes == 1_048_576)
        #expect(server.requests("POST", containing: "/playback").count == 3)
        #expect(server.requests("GET", containing: "/prepared/r1/media.mp4").count == 1)
    }

    // MARK: Stopping and continuing

    @Test func aPausedTransferContinuesWhereItStopped() async throws {
        server.change { $0.holdAfterBytes = 300_000 }
        let manager = manager()
        await manager.start(using: client)
        await enqueue(manager)
        await wait(manager) { ($0.transfer?.receivedBytes ?? 0) > 0 }

        await manager.pause(itemID: "film")
        let paused = await wait(manager) { $0.state == .paused }
        #expect((paused.transfer?.receivedBytes ?? 0) > 0)
        #expect(await manager.localFile(itemID: "film") == nil)

        server.release()
        await manager.resume(itemID: "film")
        let record = await wait(manager) { $0.state == .verified }

        // The second request asked for the rest only, and only of the same revision.
        let fetches = server.requests("GET", containing: "/content")
        #expect(fetches.count == 2)
        let range = try #require(fetches[1].headers["range"])
        #expect(range.hasPrefix("bytes=") && range != "bytes=0-")
        #expect(fetches[1].headers["if-range"] == "\"r1\"")
        #expect(try Data(contentsOf: try #require(await manager.localFile(itemID: "film"))) == Self.bytes())
        #expect(record.local?.sizeBytes == 1_048_576)
    }

    @Test func aPausedTransferContinuesAfterTheAppWasClosed() async throws {
        server.change { $0.holdAfterBytes = 300_000 }
        let first = manager()
        await first.start(using: client)
        await enqueue(first)
        await wait(first) { ($0.transfer?.receivedBytes ?? 0) > 0 }
        await first.pause(itemID: "film")
        await wait(first) { $0.state == .paused }
        server.release()

        let second = manager()
        await second.start(using: client)
        #expect(await second.record(itemID: "film")?.state == .paused)
        await second.resume(itemID: "film")
        await wait(second) { $0.state == .verified }

        let fetches = server.requests("GET", containing: "/content")
        #expect(fetches.last?.headers["range"] != nil)
        #expect(try Data(contentsOf: try #require(await second.localFile(itemID: "film"))) == Self.bytes())
    }

    @Test func aBrokenConnectionIsRetriedOnceFromWhereItBroke() async throws {
        server.change { $0.dropAfterBytes = 400_000 }
        let manager = manager()
        await manager.start(using: client)
        await enqueue(manager)
        let record = await wait(manager) { $0.state == .verified }

        #expect(record.retried)
        let fetches = server.requests("GET", containing: "/content")
        #expect(fetches.count == 2)
        #expect(fetches[1].headers["range"]?.hasPrefix("bytes=") == true)
        #expect(fetches[1].headers["if-range"] == "\"r1\"")
        #expect(try Data(contentsOf: try #require(await manager.localFile(itemID: "film"))) == Self.bytes())
    }

    @Test func aFileThatChangedWhileItWasPausedStartsOver() async throws {
        server.change { $0.holdAfterBytes = 300_000 }
        let manager = manager()
        await manager.start(using: client)
        await enqueue(manager)
        await wait(manager) { ($0.transfer?.receivedBytes ?? 0) > 0 }
        await manager.pause(itemID: "film")
        await wait(manager) { $0.state == .paused }

        // Somebody replaced the file on the Pi.
        let replacement = Self.bytes(900_000, seed: 99)
        server.release()
        serve(replacement, revision: "r2")
        await manager.resume(itemID: "film")
        let record = await wait(manager) { $0.state == .verified }

        #expect(record.local?.revision == "r2")
        #expect(record.local?.fileName == "r2.mp4")
        // All of the new file, none of the old one.
        #expect(try Data(contentsOf: try #require(await manager.localFile(itemID: "film"))) == replacement)
        #expect(server.requests("GET", containing: "/content").last?.headers["range"] == nil)
    }

    // MARK: What is not accepted

    @Test func aBodyOfAnotherLengthIsNotKept() async throws {
        serve(Self.bytes(500_000), revision: "r1", statedBytes: 1_048_576)
        let manager = manager()
        await manager.start(using: client)
        await enqueue(manager)
        let record = await wait(manager) { !$0.state.isActive }

        #expect(record.state == .failed(.sizeMismatch(expectedBytes: 1_048_576, receivedBytes: 500_000)))
        #expect(record.local == nil)
        #expect(await manager.localFile(itemID: "film") == nil)
        #expect(stagedFiles.isEmpty)
    }

    @Test func aFileOfAnotherRevisionThanAskedForIsFetchedAgainAndThenRefused() async throws {
        // The playback answer says r1, the file route serves something tagged r9.
        server.change { $0.etag = "r9" }
        let manager = manager()
        await manager.start(using: client)
        await enqueue(manager)
        let record = await wait(manager) { !$0.state.isActive }

        #expect(record.state == .failed(.changedOnServer))
        #expect(record.local == nil)
        #expect(server.requests("POST", containing: "/playback").count == 2)
        #expect(stagedFiles.isEmpty)
    }

    @Test func aDeviceWithoutRoomSaysSoBeforeFetchingAnything() async throws {
        let manager = manager(space: 1_500_000)
        await manager.start(using: client)
        await enqueue(manager)
        let record = await wait(manager) { !$0.state.isActive }

        // 1.5 MB free, 1 MB of it reserved, and the film is 1 MB.
        #expect(record.state == .failed(.notEnoughSpace(neededBytes: 1_048_576, availableBytes: 500_000)))
        #expect(server.requests("GET", containing: "/content").isEmpty)
        #expect(await manager.spaceForDownloads() == 500_000)
    }

    @Test func whatTheServerCannotHandOverCarriesItsReason() async throws {
        server.change {
            $0.playback = [(200, #"{"state":"unsupported","mode":null,"revision":"r1","progress":0,"preparedMs":0,"durationMs":null,"streamUrl":null,"downloadUrl":null,"downloadBytes":null,"audio":[],"message":"The video is MPEG4, which Apple devices do not play."}"#)]
        }
        let manager = manager()
        await manager.start(using: client)
        await enqueue(manager)
        let record = await wait(manager) { !$0.state.isActive }
        #expect(record.state == .failed(.server("The video is MPEG4, which Apple devices do not play.")))
    }

    @Test func aFilmThatIsGoneFromTheServerSaysSo() async throws {
        server.change { $0.playback = [] }
        let manager = manager()
        await manager.start(using: client)
        await enqueue(manager)
        let record = await wait(manager) { !$0.state.isActive }
        #expect(record.state == .failed(.removedFromServer))
    }

    @Test func anEvictedCopyIsAskedForAgain() async throws {
        server.change { $0.contentStatus = 404 }
        let manager = manager()
        await manager.start(using: client)
        await enqueue(manager)
        await wait(manager) { $0.retried }
        server.change { $0.contentStatus = nil }
        // The retry may already have met the 404 again: then Try Again does it.
        let settled = await wait(manager) { !$0.state.isActive }
        if settled.state != .verified {
            await manager.resume(itemID: "film")
        }
        let record = await wait(manager) { $0.state == .verified }
        #expect(record.local != nil)
        #expect(server.requests("POST", containing: "/playback").count >= 2)
    }

    // MARK: The server out of reach

    @Test func withTheServerOutOfReachTheDownloadWaitsAndStartsWhenItIsBack() async throws {
        let nowhere = try LobbyClient(
            baseURL: URL(string: "http://127.0.0.1:9")!, token: "device-token", session: URLSession(configuration: .ephemeral))
        let manager = manager()
        await manager.start(using: nowhere)
        await enqueue(manager)
        let waiting = await wait(manager) { $0.isWaitingForNetwork }
        #expect(waiting.state == .queued)

        await manager.setClient(client)
        await manager.retryWaiting()
        await wait(manager) { $0.state == .verified }
    }

    @Test func aTransferFollowsTheServerToItsOtherAddress() async throws {
        // The same server under two names, as at home and from elsewhere.
        let port = try #require(server.baseURL.port)
        let elsewhere = try LobbyClient(
            baseURL: try #require(URL(string: "http://localhost:\(port)")), token: "device-token",
            session: URLSession(configuration: .ephemeral))
        server.change { $0.holdAfterBytes = 300_000 }
        let manager = manager()
        await manager.start(using: client)
        await enqueue(manager)
        await wait(manager) { ($0.transfer?.receivedBytes ?? 0) > 0 }

        // The device leaves home half-way: the server is now reached at the other address.
        server.change { $0.holdAfterBytes = nil }
        await manager.setClient(elsewhere)
        server.release()
        let record = await wait(manager) { $0.state == .verified }

        let fetches = server.requests("GET", containing: "/content")
        #expect(fetches.last?.headers["host"] == "localhost:\(port)")
        // The file is whole and of one piece, fetched from its start at the new address.
        #expect(fetches.last?.headers["range"] == nil)
        #expect(try Data(contentsOf: try #require(await manager.localFile(itemID: "film"))) == Self.bytes())
        #expect(record.local?.sizeBytes == 1_048_576)
    }

    // MARK: What a manager wants on this device

    private func wanted(_ state: WantedAsset.State, revision: String = "r1", bytes: Int = 1_048_576) -> WantedAsset {
        WantedAsset(
            assetId: "a1", itemId: "film", revision: revision, order: 1, bytes: Int64(bytes), bytesExact: state == .ready,
            state: state, downloadUrl: state == .ready ? "/v1/assets/a1/content" : nil)
    }

    @Test func aFileAManagerWantsIsFetchedWhenTheServerHasItReadyWithoutAskingForPlayback() async throws {
        let catalogue = Catalogue(items: [Self.item()])
        let manager = manager()
        await manager.start(using: client)

        // The server is still making the copy: the device waits and asks for nothing.
        await manager.applyWanted([wanted(.preparing)], catalogue: catalogue, allowsCellular: false)
        let waiting = try #require(await manager.record(itemID: "film"))
        #expect(waiting.state == .queued)
        #expect(!waiting.isOwn)
        #expect(await manager.report().downloads.map(\.state) == [.waiting])
        #expect(await manager.report().downloads.first?.own == false)

        await manager.applyWanted([wanted(.ready)], catalogue: catalogue, allowsCellular: false)
        let record = await wait(manager) { $0.state == .verified }
        #expect(record.local?.revision == "r1")
        #expect(try Data(contentsOf: try #require(await manager.localFile(itemID: "film"))) == Self.bytes())
        // The file was fetched from where the list said, and playback was never asked for.
        #expect(server.requests("POST", containing: "/playback").isEmpty)
        #expect(server.requests("GET", containing: "/content").count == 1)

        let report = await manager.report()
        #expect(report.downloads.first?.state == .downloaded)
        #expect(report.downloads.first?.bytesDone == 1_048_576)
        #expect(report.freeBytes != nil)
    }

    @Test func aFileThatLeftTheListIsRemovedUnlessThePersonWantsItOrItIsPlaying() async throws {
        let catalogue = Catalogue(items: [Self.item()])
        let manager = manager()
        await manager.start(using: client)
        await manager.applyWanted([wanted(.ready)], catalogue: catalogue, allowsCellular: false)
        await wait(manager) { $0.state == .verified }

        // Playing: it stays for now.
        await manager.applyWanted([], catalogue: catalogue, playing: ["film"], allowsCellular: false)
        #expect(await manager.localFile(itemID: "film") != nil)
        // Not playing any more: gone, with its file.
        await manager.applyWanted([], catalogue: catalogue, allowsCellular: false)
        #expect(await manager.record(itemID: "film") == nil)
        #expect(await manager.localFile(itemID: "film") == nil)

        // Wanted again, and this time the person downloads it too: it outlives the list.
        await manager.applyWanted([wanted(.ready)], catalogue: catalogue, allowsCellular: false)
        await wait(manager) { $0.state == .verified }
        await enqueue(manager)
        await manager.applyWanted([], catalogue: catalogue, allowsCellular: false)
        let kept = try #require(await manager.record(itemID: "film"))
        #expect(kept.isOwn && kept.wanted == nil)
        #expect(await manager.localFile(itemID: "film") != nil)
    }

    @Test func thePersonCannotRemoveWhatAManagerWantsOnTheDevice() async throws {
        let catalogue = Catalogue(items: [Self.item()])
        let manager = manager()
        await manager.start(using: client)
        await enqueue(manager)
        await wait(manager) { $0.state == .verified }
        await manager.applyWanted([wanted(.ready)], catalogue: catalogue, allowsCellular: false)

        // Their own download, and wanted: removing it only makes it not theirs.
        await manager.remove(itemID: "film")
        let record = try #require(await manager.record(itemID: "film"))
        #expect(!record.isOwn)
        #expect(await manager.localFile(itemID: "film") != nil)
    }

    @Test func aWantedFileInANewRevisionIsFetchedAgain() async throws {
        let catalogue = Catalogue(items: [Self.item()])
        let manager = manager()
        await manager.start(using: client)
        await manager.applyWanted([wanted(.ready)], catalogue: catalogue, allowsCellular: false)
        await wait(manager) { $0.state == .verified }

        serve(Self.bytes(seed: 9), revision: "r2")
        await manager.applyWanted([wanted(.ready, revision: "r2")], catalogue: catalogue, allowsCellular: false)
        let record = await wait(manager) { $0.local?.revision == "r2" && $0.state == .verified }
        #expect(record.local?.revision == "r2")
        #expect(try Data(contentsOf: try #require(await manager.localFile(itemID: "film"))) == Self.bytes(seed: 9))
    }

    @Test func aWantedFileThatDoesNotFitIsReportedAndNothingIsDeletedForIt() async throws {
        let catalogue = Catalogue(items: [Self.item()])
        let manager = manager(space: 1_500_000)
        await manager.start(using: client)
        await manager.applyWanted([wanted(.ready)], catalogue: catalogue, allowsCellular: false)
        let record = await wait(manager) { if case .failed = $0.state { true } else { false } }
        guard case .failed(.notEnoughSpace) = record.state else {
            Issue.record("Expected no room, got \(record.state)")
            return
        }
        let entry = try #require(await manager.report().downloads.first)
        #expect(entry.state == .failed && entry.error == .noSpace)
    }

    // MARK: A copy and the server's file

    @Test func aCopyOfAReplacedFileIsFlaggedAndStaysPlayableUntilTheNewOneIsVerified() async throws {
        let manager = manager()
        await manager.start(using: client)
        await enqueue(manager)
        await wait(manager) { $0.state == .verified }
        let old = try #require(await manager.localFile(itemID: "film"))

        // The next sync shows another revision of the file.
        let replaced = Self.item(revision: "r2")
        await manager.reconcile(with: Catalogue(items: [replaced]))
        var record = try #require(await manager.record(itemID: "film"))
        #expect(record.staleness == .changedOnServer)
        #expect(!record.isVerifiedAndCurrent)
        #expect(record.isPlayable)

        // Fetching the new one: the old copy is what plays meanwhile.
        let replacement = Self.bytes(700_000, seed: 3)
        serve(replacement, revision: "r2")
        server.change { $0.holdAfterBytes = 200_000 }
        await manager.enqueue(replaced, file: replaced.files[0], allowsCellular: false)
        await wait(manager) { ($0.transfer?.receivedBytes ?? 0) > 0 }
        #expect(await manager.localFile(itemID: "film") == old)
        #expect(FileManager.default.fileExists(atPath: old.path))

        server.release()
        record = await wait(manager) { $0.state == .verified }
        #expect(record.staleness == nil)
        #expect(record.local?.revision == "r2")
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(try Data(contentsOf: try #require(await manager.localFile(itemID: "film"))) == replacement)
    }

    @Test func aCopyOfSomethingGoneFromTheServerIsFlaggedNotDeleted() async throws {
        let manager = manager()
        await manager.start(using: client)
        await enqueue(manager)
        await wait(manager) { $0.state == .verified }

        await manager.reconcile(with: Catalogue(items: []))
        let record = try #require(await manager.record(itemID: "film"))
        #expect(record.staleness == .removedFromServer)
        #expect(!record.isVerifiedAndCurrent)
        #expect(await manager.localFile(itemID: "film") != nil)
        // The Downloads screen can still name it.
        #expect(record.item.title == "Up")

        // And it is current again if the catalogue has it back unchanged.
        await manager.reconcile(with: Catalogue(items: [Self.item()]))
        #expect(await manager.record(itemID: "film")?.isVerifiedAndCurrent == true)
    }

    @Test func removingADownloadFreesTheDeviceAndLeavesTheServerAlone() async throws {
        let manager = manager()
        await manager.start(using: client)
        await enqueue(manager)
        await wait(manager) { $0.state == .verified }
        let file = try #require(await manager.localFile(itemID: "film"))

        await manager.remove(itemID: "film")
        #expect(await manager.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        #expect(server.requests.allSatisfy { $0.method == "POST" || $0.method == "GET" })
    }

    @Test func removingAHalfFetchedDownloadLeavesNothingBehind() async throws {
        server.change { $0.holdAfterBytes = 300_000 }
        let manager = manager()
        await manager.start(using: client)
        await enqueue(manager)
        await wait(manager) { ($0.transfer?.receivedBytes ?? 0) > 0 }
        await manager.pause(itemID: "film")
        await wait(manager) { $0.state == .paused }

        await manager.remove(itemID: "film")
        #expect(await manager.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: DownloadPaths.resumeData("film", in: directory.url).path))
        #expect(stagedFiles.isEmpty)
        server.release()
    }

    // MARK: Subtitles

    @Test func textSubtitlesAreStoredBesideTheFilm() async throws {
        server.change { $0.subtitles["s3"] = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHallo\n" }
        let tracks = [
            SubtitleTrack(id: "s3", source: .embedded, codec: "subrip", language: "nld", title: nil, isForced: false, isText: true),
            SubtitleTrack(id: "pgs", source: .embedded, codec: "hdmv_pgs_subtitle", language: "eng", title: nil, isForced: false, isText: false),
        ]
        let manager = manager()
        await manager.start(using: client)
        await enqueue(manager, Self.item(subtitles: tracks))
        let record = await wait(manager) { $0.local?.subtitles.isEmpty == false }

        #expect(record.local?.subtitles.map(\.id) == ["s3"])
        #expect(record.local?.subtitles.first?.language == "nld")
        let file = try #require(await manager.localSubtitleFile(itemID: "film", subtitleID: "s3"))
        #expect(try String(contentsOf: file, encoding: .utf8).hasPrefix("WEBVTT"))
        // The image subtitle was not asked for.
        #expect(server.requests("GET", containing: ".vtt").map(\.path) == ["/v1/assets/a1/subtitles/s3.vtt"])
    }
}

@Suite struct DownloadRecordTests {
    @Test func whatIsOnTheDeviceCountsTheCopyAndWhatArrived() {
        var record = DownloadRecord(
            itemID: "film", assetID: "a1", item: DownloadManagerTests.item(), showID: nil, showTitle: nil,
            state: .downloading,
            transfer: DownloadTransfer(revision: "r2", expectedBytes: 1_000, receivedBytes: 250, resumedAtByte: nil),
            local: LocalCopy(revision: "r1", fileName: "r1.mp4", sizeBytes: 900, completedAt: Make.epoch, subtitles: []),
            staleness: .changedOnServer, requestedAt: Make.epoch, allowsCellular: false, retried: false,
            isWaitingForNetwork: false)
        #expect(record.bytesOnDevice == 1_150)
        #expect(record.transfer?.fraction == 0.25)
        #expect(record.isPlayable)
        #expect(!record.isVerifiedAndCurrent)

        record.state = .verified
        record.transfer = nil
        record.staleness = nil
        #expect(record.bytesOnDevice == 900)
        #expect(record.isVerifiedAndCurrent)
    }

    @Test func idsFromTheServerAreNeverTrustedAsFileNames() {
        #expect(DownloadPaths.safeName("5094a55d-1185") == "5094a55d-1185")
        #expect(!DownloadPaths.safeName("../../etc/passwd").contains("/"))
        #expect(!DownloadPaths.safeName("../../etc/passwd").contains("."))
        #expect(DownloadPaths.safeName("a/b") != DownloadPaths.safeName("a_b"))
    }
}
