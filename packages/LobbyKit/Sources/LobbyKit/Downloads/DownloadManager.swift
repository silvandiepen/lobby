// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Films and episodes kept on this device: the queue, the transfers and the verified copies.
///
/// How a download goes, following `docs/playback.md` ("What the Apple apps must do", point 8):
///
/// 1. Ask `POST /v1/assets/{id}/playback` until `state` is `ready`. A file that needs
///    repackaging is `preparing` meanwhile, which the record shows.
/// 2. Check that the device has room for `downloadBytes`.
/// 3. Fetch `downloadUrl` with a `URLSession` download task. In the apps that is a background
///    session, so the transfer goes on while the app is not running.
/// 4. Check what arrived: the HTTP status, the length against `downloadBytes`, and the `ETag`
///    against the revision. Only then move it into place, in one step, as `<revision>.mp4`.
/// 5. Fetch the text subtitles as WebVTT and store them beside it.
///
/// A transfer that stops (paused, or the connection broke) keeps what arrived and continues
/// from there with `Range` and `If-Range`. If the file changed on the server meanwhile, the
/// revision differs and it starts over. A finished copy of an older revision stays, and stays
/// playable, until its replacement is verified.
///
/// Nothing here deletes anything on the server.
public actor DownloadManager {
    /// Raise together with a case in `migrate(version:data:)`.
    static let formatVersion = 1

    struct Stored: Codable {
        var version = DownloadManager.formatVersion
        var records: [DownloadRecord]
    }

    /// How many transfers run at once. One: the Pi serves the family at the same time.
    public static let concurrentTransfers = 1

    private let directory: URL
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let availableSpace: @Sendable (URL) -> Int64?
    private let totalSpace: @Sendable (URL) -> Int64?
    private let spaceReserveBytes: Int64
    private let pollEvery: Duration

    private var events: AsyncStream<DownloadSessionEvent>?
    private var eventLoop: Task<Void, Never>?
    private var client: LobbyClient?
    private var loaded = false
    private var records: [String: DownloadRecord] = [:]
    private var tasks: [String: URLSessionDownloadTask] = [:]
    /// Transfers over the direct road, which the app carries itself. See `CarriedTransfer`.
    private var carried: [String: Task<Void, Never>] = [:]
    private let carriedSession: URLSession
    /// What is sent costs mobile data. The system holds back its own transfers; these are ours.
    private var isOnMobileData = false
    /// Items that are being asked about (`POST …/playback`), with the task that asks.
    private var asking: [String: Task<Void, Never>] = [:]
    /// Transfers the viewer paused: their stop is not a failure.
    private var pausing: Set<String> = []
    private var subtitleFetches: [String: Task<Void, Never>] = [:]
    private var observers: [UUID: AsyncStream<[DownloadRecord]>.Continuation] = [:]
    private var backgroundCompletion: (@Sendable () -> Void)?
    /// The last failure to write the records file. Reported, never ignored.
    public private(set) var storageError: String?

    /// - Parameters:
    ///   - directory: Where records and files go, e.g. `LobbyStorage.downloadsDirectory(in:)`.
    ///   - sessionConfiguration: `.background(withIdentifier:)` in an app. Tests pass another.
    ///   - availableSpace: The room on the volume of a URL, for tests.
    ///   - spaceReserveBytes: Room that is left free after a download.
    ///   - pollEvery: How often the server is asked while it prepares a copy.
    ///   - carriedSession: For transfers over the direct road, which only run while the app does.
    public init(
        directory: URL,
        sessionConfiguration: URLSessionConfiguration,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        availableSpace: @escaping @Sendable (URL) -> Int64? = DownloadManager.volumeSpace,
        totalSpace: @escaping @Sendable (URL) -> Int64? = DownloadManager.volumeCapacity,
        spaceReserveBytes: Int64 = 200_000_000,
        pollEvery: Duration = .seconds(1),
        carriedSession: URLSession = .shared
    ) {
        self.carriedSession = carriedSession
        self.directory = directory
        self.now = now
        self.sleep = sleep
        self.availableSpace = availableSpace
        self.totalSpace = totalSpace
        self.spaceReserveBytes = spaceReserveBytes
        self.pollEvery = pollEvery

        let (stream, continuation) = AsyncStream<DownloadSessionEvent>.makeStream()
        events = stream
        let delegate = DownloadSessionDelegate(
            stagingDirectory: DownloadPaths.staging(in: directory), events: continuation)
        session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
    }

    /// How large the volume `url` is on is.
    public static let volumeCapacity: @Sendable (URL) -> Int64? = { url in
        (try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity.map(Int64.init)
    }

    /// What the system says can be written to the volume `url` is on.
    public static let volumeSpace: @Sendable (URL) -> Int64? = { url in
        #if os(tvOS) || os(watchOS)
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
        #else
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        #endif
    }

    // MARK: Start

    /// Reads the records, picks up transfers the system kept running while the app was away,
    /// and starts what is queued. Call once at launch, before anything else.
    ///
    /// - Parameter client: The paired server, or nil when the device is not paired right now.
    ///   Copies on the device play without one.
    public func start(using client: LobbyClient?) async {
        self.client = client
        loadIfNeeded()

        if let events {
            self.events = nil
            eventLoop = Task { [weak self] in
                for await event in events {
                    await self?.handle(event)
                }
            }
        }

        // Transfers of a background session outlive the app. Find them again by the item id
        // each task carries.
        let running = await session.allTasks.compactMap { $0 as? URLSessionDownloadTask }
        for task in running {
            guard let itemID = task.taskDescription, records[itemID] != nil, task.state != .completed else {
                task.cancel()
                continue
            }
            tasks[itemID] = task
        }
        for (itemID, record) in records {
            switch record.state {
            case .downloading where tasks[itemID] == nil, .preparing:
                // The transfer is gone (the app was force-quit), or the asking stopped with the app.
                records[itemID]?.state = .queued
            default:
                break
            }
        }
        save()
        publish()
        pump()
    }

    /// The server to use from now on. nil: the device was removed or signed out. Nothing new
    /// starts then, and what is on the device stays.
    ///
    /// The same server at another address (home, or from elsewhere): transfers that run
    /// against the old address are stopped and start again at the new one. The file in flight
    /// starts over, because the system can only continue a transfer at the address it began at.
    public func setClient(_ client: LobbyClient?) {
        let moved = client != nil && self.client != nil && client?.baseURL != self.client?.baseURL
        self.client = client
        if moved {
            for itemID in Array(asking.keys) {
                asking.removeValue(forKey: itemID)?.cancel()
                if case .preparing = records[itemID]?.state {
                    records[itemID]?.state = .queued
                }
            }
            // Each reports its stop, is queued again, and starts from the new address.
            for task in tasks.values {
                task.cancel()
            }
            for itemID in Array(carried.keys) { stopCarrying(itemID, then: .queued) }
            changed()
        }
        if client == nil, !carried.isEmpty {
            // The road is inside the app: without a connection there is none.
            for itemID in Array(carried.keys) { stopCarrying(itemID, then: .queued) }
            changed()
        }
        if client != nil { pump() }
    }

    /// The device is on mobile data now, or not any more. Only matters for what the app carries.
    public func setOnMobileData(_ on: Bool) {
        guard on != isOnMobileData else { return }
        isOnMobileData = on
        if on {
            for itemID in Array(carried.keys) where records[itemID]?.allowsCellular != true {
                stopCarrying(itemID, then: .queued)
            }
            changed()
        } else {
            retryWaiting()
        }
    }

    /// The server may be reachable again (the network came back, the app came to the front):
    /// try what was waiting.
    public func retryWaiting() {
        for itemID in records.keys where records[itemID]?.state == .queued {
            records[itemID]?.isWaitingForNetwork = false
        }
        pump()
    }

    /// The system relaunched the app to deliver the events of a background session. `completion`
    /// is called once they were all handled, as the system asks.
    public func handleBackgroundEvents(completion: @escaping @Sendable () -> Void) {
        backgroundCompletion = completion
    }

    // MARK: Reading

    /// Every record, oldest request first.
    public func all() -> [DownloadRecord] {
        loadIfNeeded()
        return records.values.sorted {
            $0.requestedAt != $1.requestedAt ? $0.requestedAt < $1.requestedAt : $0.itemID < $1.itemID
        }
    }

    public func record(itemID: String) -> DownloadRecord? {
        loadIfNeeded()
        return records[itemID]
    }

    /// The records now, and again after every change.
    public func updates() -> AsyncStream<[DownloadRecord]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[DownloadRecord]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        continuation.yield(all())
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    /// The copy of an item that can be played from this device, or nil. It may be an older
    /// revision than the server has now: `DownloadRecord.staleness` says so.
    public func localFile(itemID: String) -> URL? {
        loadIfNeeded()
        guard let local = records[itemID]?.local else { return nil }
        let url = DownloadPaths.itemFolder(itemID, in: directory)
            .appending(path: local.fileName, directoryHint: .notDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A subtitle stored with a downloaded item.
    public func localSubtitleFile(itemID: String, subtitleID: String) -> URL? {
        loadIfNeeded()
        guard let subtitle = records[itemID]?.local?.subtitles.first(where: { $0.id == subtitleID }) else { return nil }
        return DownloadPaths.itemFolder(itemID, in: directory)
            .appending(path: subtitle.fileName, directoryHint: .notDirectory)
    }

    /// The room for downloads on this device now, after the reserve. nil when the system does
    /// not say.
    public func spaceForDownloads() -> Int64? {
        availableSpace(directory).map { max(0, $0 - spaceReserveBytes) }
    }

    // MARK: The viewer's actions

    /// Asks for a film or episode to be kept on this device.
    ///
    /// Asking again for something that is queued, on its way or verified changes nothing. For a
    /// copy that is out of date it fetches the current file, and keeps the old copy playable
    /// until the new one is verified.
    ///
    /// - Parameters:
    ///   - file: The file to fetch, normally the one the app would play.
    ///   - show: The episode's show, for grouping on the Downloads screen.
    public func enqueue(_ item: Item, file: MediaFile, show: Item? = nil, allowsCellular: Bool) {
        loadIfNeeded()
        if var existing = records[item.id] {
            if existing.state.isActive || existing.isVerifiedAndCurrent {
                // Already here or on its way because a manager wanted it: now it is also
                // the person's own, and stays when the manager takes it off the list.
                if !existing.isOwn {
                    records[item.id]?.own = true
                    changed()
                    pump()
                }
                return
            }
            if existing.assetID != file.assetId {
                // Another file now: nothing of a half-fetched one applies.
                discardPartial(item.id)
                existing.transfer = nil
            }
            existing.own = true
            existing.assetID = file.assetId
            existing.item = item
            existing.showID = show?.id
            existing.showTitle = show?.title
            existing.state = .queued
            existing.retried = false
            existing.isWaitingForNetwork = false
            existing.allowsCellular = allowsCellular
            records[item.id] = existing
        } else {
            records[item.id] = DownloadRecord(
                itemID: item.id, assetID: file.assetId, item: item, showID: show?.id, showTitle: show?.title,
                state: .queued, transfer: nil, local: nil, staleness: nil, requestedAt: now(),
                allowsCellular: allowsCellular, retried: false, isWaitingForNetwork: false)
        }
        changed()
        pump()
    }

    /// Stops a transfer and keeps what arrived.
    public func pause(itemID: String) {
        guard let record = records[itemID], record.state.isActive else { return }
        asking.removeValue(forKey: itemID)?.cancel()
        if carried[itemID] != nil {
            // What arrived stays, and it goes on from there.
            stopCarrying(itemID, then: .paused)
            changed()
            pump()
        } else if let task = tasks[itemID] {
            // The state changes when the system reports the stop, with what lets it continue.
            pausing.insert(itemID)
            task.cancel(byProducingResumeData: { _ in })
        } else {
            records[itemID]?.state = .paused
            changed()
            pump()
        }
    }

    /// Continues a paused transfer, or tries a failed one again, from where it stopped.
    public func resume(itemID: String) {
        guard let record = records[itemID] else { return }
        switch record.state {
        case .paused, .failed:
            records[itemID]?.state = .queued
            records[itemID]?.retried = false
            records[itemID]?.isWaitingForNetwork = false
            changed()
            pump()
        case .queued, .preparing, .downloading, .verified:
            break
        }
    }

    /// Whether transfers that are queued or running may use mobile data from now on. A running
    /// transfer keeps the setting it started with until it is paused and continued.
    public func setAllowsCellular(_ allowed: Bool) {
        for itemID in records.keys where records[itemID]?.state != .verified {
            records[itemID]?.allowsCellular = allowed
        }
        changed()
    }

    /// Removes an item from this device: the transfer, what arrived and the finished copy.
    /// The server's file is not touched.
    ///
    /// A file a manager wants on this device stays: it only stops being the person's own.
    public func remove(itemID: String) {
        guard let record = records[itemID] else { return }
        if record.wanted != nil, record.isOwn {
            records[itemID]?.own = false
            changed()
            return
        }
        discard(itemID)
    }

    private func discard(_ itemID: String) {
        guard records[itemID] != nil else { return }
        asking.removeValue(forKey: itemID)?.cancel()
        subtitleFetches.removeValue(forKey: itemID)?.cancel()
        pausing.remove(itemID)
        tasks.removeValue(forKey: itemID)?.cancel()
        carried.removeValue(forKey: itemID)?.cancel()
        records[itemID] = nil
        discardPartial(itemID)
        removeIfPresent(DownloadPaths.itemFolder(itemID, in: directory))
        changed()
        pump()
    }

    /// Removes everything, for signing out of the server.
    public func removeAll() {
        for itemID in Array(records.keys) {
            discard(itemID)
        }
    }

    /// The server of these downloads was removed from the app: every transfer stops, the files
    /// and records go, and the background session ends. Nothing works on this manager after it.
    public func close() async {
        loadIfNeeded()
        client = nil
        removeAll()
        for task in await session.allTasks { task.cancel() }
        session.invalidateAndCancel()
        eventLoop?.cancel()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: What a manager wants on this device

    /// Makes this device's downloads follow the list a manager keeps for it.
    ///
    /// A file on the list that is not here is fetched once the server has it ready, without
    /// asking the server to hurry. A file that left the list is removed, unless the person
    /// downloaded it themselves or it is playing.
    ///
    /// - Parameters:
    ///   - catalogue: To know the films and episodes the files belong to. A file of a title
    ///     the catalogue does not have yet is taken up at the next call.
    ///   - playing: The items being played now: their files are not removed.
    public func applyWanted(_ assets: [WantedAsset], catalogue: Catalogue, playing: Set<String> = [], allowsCellular: Bool) {
        loadIfNeeded()
        var wantedItems: Set<String> = []
        for asset in assets.sorted(by: { $0.order < $1.order }) {
            // A film in several files is one download here: its first file.
            guard let item = catalogue.item(asset.itemId), item.files.contains(where: { $0.assetId == asset.assetId }),
                wantedItems.insert(item.id).inserted
            else { continue }
            let file = WantedFile(
                revision: asset.revision, bytes: asset.bytes, state: asset.state,
                downloadPath: asset.state == .ready ? asset.downloadUrl : nil, message: asset.message, order: asset.order)

            if var record = records[item.id] {
                if record.assetID != asset.assetId, !record.isOwn {
                    discardPartial(item.id)
                    record.transfer = nil
                    record.assetID = asset.assetId
                    record.state = .queued
                }
                // Another revision on the server: fetch it again, and keep the old copy
                // playable until the new one is here.
                if !record.isOwn, record.state == .verified, record.local?.revision != asset.revision {
                    record.state = .queued
                    record.retried = false
                }
                // What could not be done as things were gets another try when the server
                // says something new about the file.
                if !record.isOwn, case .failed = record.state, record.wanted != file {
                    record.state = .queued
                    record.retried = false
                }
                record.wanted = file
                records[item.id] = record
            } else {
                let show = item.kind == .episode ? catalogue.show(of: item) : nil
                var record = DownloadRecord(
                    itemID: item.id, assetID: asset.assetId, item: item, showID: show?.id, showTitle: show?.title,
                    state: .queued, transfer: nil, local: nil, staleness: nil, requestedAt: now(),
                    allowsCellular: allowsCellular, retried: false, isWaitingForNetwork: false)
                record.own = false
                record.wanted = file
                records[item.id] = record
            }
        }

        for (itemID, record) in records where record.wanted != nil && !wantedItems.contains(itemID) {
            if record.isOwn || playing.contains(itemID) {
                // Kept: the person's own, or on screen right now. A file that is playing is
                // looked at again the next time the list is read.
                if record.isOwn { records[itemID]?.wanted = nil }
            } else {
                discard(itemID)
            }
        }
        changed()
        pump()
    }

    /// What this device has, for `POST /v1/me/downloads`.
    public func report() -> DownloadsReport {
        loadIfNeeded()
        let entries = all().map { record -> DownloadsReport.Entry in
            let state: DownloadsReport.Entry.State
            var failure: DownloadsReport.Entry.Failure?
            switch record.state {
            case .queued, .preparing: state = .waiting
            case .downloading: state = .downloading
            case .paused: state = .paused
            case .verified: state = .downloaded
            case .failed(let reason):
                state = .failed
                failure = switch reason {
                case .notEnoughSpace: .noSpace
                case .sizeMismatch, .changedOnServer: .verificationFailed
                case .removedFromServer: .notFound
                case .interrupted: .network
                case .server: .other
                }
            }
            let isDone = record.state == .verified
            let revision = (isDone ? record.local?.revision : record.transfer?.revision)
                ?? record.wanted?.revision ?? record.local?.revision
                ?? record.item.files.first { $0.assetId == record.assetID }?.revision ?? ""
            let total = isDone ? record.local?.sizeBytes : (record.transfer?.expectedBytes ?? record.wanted?.bytes)
            let done = isDone ? (record.local?.sizeBytes ?? 0) : (record.transfer?.receivedBytes ?? 0)
            return DownloadsReport.Entry(
                assetId: record.assetID, revision: revision, state: state, bytesDone: min(done, total ?? done),
                bytesTotal: total, error: failure, own: record.isOwn)
        }
        return DownloadsReport(
            freeBytes: spaceForDownloads(), totalBytes: totalSpace(directory), downloads: entries)
    }

    /// Compares every copy on this device with the catalogue and marks the ones that no longer
    /// match: the file was replaced on the server, or the item is gone from it.
    ///
    /// - Parameter catalogue: The catalogue right after a successful sync. A catalogue read from
    ///   the device's cache says nothing about what the server has now.
    public func reconcile(with catalogue: Catalogue) {
        loadIfNeeded()
        var didChange = false
        for (itemID, record) in records {
            var updated = record
            updated.staleness = record.staleness(in: catalogue)
            if let current = catalogue.item(itemID) {
                updated.item = current
                if let showID = record.showID, let show = catalogue.item(showID) {
                    updated.showTitle = show.title
                }
            }
            if updated != record {
                records[itemID] = updated
                didChange = true
            }
        }
        if didChange { changed() }
    }

    // MARK: The queue

    /// Starts queued items while there is room for another transfer.
    private func pump() {
        guard client != nil else { return }
        var busy = records.values.filter { record in
            switch record.state {
            case .preparing, .downloading: true
            default: asking[record.itemID] != nil
            }
        }.count
        for record in all() where busy < Self.concurrentTransfers {
            guard record.state == .queued, !record.isWaitingForNetwork, asking[record.itemID] == nil,
                tasks[record.itemID] == nil, carried[record.itemID] == nil
            else { continue }
            // To the system every transfer over the direct road stays on this device.
            if client?.isCarriedByRoad == true, isOnMobileData, !record.allowsCellular {
                records[record.itemID]?.isWaitingForNetwork = true
                changed()
                continue
            }
            // A file only a manager wants waits until the server has it ready. Asking for
            // playback would tell the server someone wants to watch it now.
            if !record.isOwn, record.wanted?.downloadPath == nil { continue }
            busy += 1
            let itemID = record.itemID
            asking[itemID] = Task { [weak self] in
                await self?.ask(itemID)
            }
        }
    }

    /// Asks the server how to fetch the file, and waits while it prepares one.
    private func ask(_ itemID: String) async {
        defer {
            // Whoever cancelled this (pause, remove) already took it off the list, and may
            // have started another one for the same item since.
            if !Task.isCancelled { asking[itemID] = nil }
            pump()
        }
        while !Task.isCancelled {
            guard let record = records[itemID], let client else { return }
            // The server already said where a wanted file is: fetch it, and ask nothing.
            if let wanted = record.wanted, let path = wanted.downloadPath, let url = client.resolve(serverPath: path) {
                startTransfer(itemID, from: url, revision: wanted.revision, expectedBytes: wanted.bytes, client: client)
                return
            }
            let playback: Playback
            do {
                playback = try await client.playback(assetID: record.assetID)
            } catch is CancellationError {
                return
            } catch let error as LobbyError where error.isTransient || error.requiresPairing {
                // Out of reach, or this device has to pair again. It waits; nothing is lost.
                finishAsking(itemID) {
                    $0.state = .queued
                    $0.isWaitingForNetwork = true
                }
                return
            } catch LobbyError.notFound {
                finishAsking(itemID) { $0.state = .failed(.removedFromServer) }
                return
            } catch {
                finishAsking(itemID) { $0.state = .failed(.server(error.localizedDescription)) }
                return
            }
            guard !Task.isCancelled, records[itemID] != nil else { return }

            switch playback.state {
            case .unsupported, .failed:
                let message = playback.message ?? "Lobby Server cannot hand this file over."
                finishAsking(itemID) { $0.state = .failed(.server(message)) }
                return
            case .unknown(let state):
                finishAsking(itemID) {
                    $0.state = .failed(.server("Lobby Server answered \"\(state)\", which this version of the app does not know."))
                }
                return
            case .ready:
                guard let url = playback.downloadURL, let bytes = playback.downloadBytes else {
                    finishAsking(itemID) { $0.state = .failed(.server("Lobby Server gave no file to download.")) }
                    return
                }
                startTransfer(itemID, from: url, revision: playback.revision, expectedBytes: bytes, client: client)
                return
            case .preparing, .queued:
                if records[itemID]?.state != .preparing(progress: playback.progress) {
                    records[itemID]?.state = .preparing(progress: playback.progress)
                    changed()
                }
                do {
                    try await sleep(pollEvery)
                } catch {
                    return
                }
            }
        }
    }

    private func finishAsking(_ itemID: String, _ change: (inout DownloadRecord) -> Void) {
        guard var record = records[itemID] else { return }
        change(&record)
        records[itemID] = record
        changed()
    }

    private func startTransfer(
        _ itemID: String, from url: URL, revision: String, expectedBytes: Int64, client: LobbyClient
    ) {
        guard var record = records[itemID] else { return }

        if client.isCarriedByRoad {
            return carry(itemID, from: url, revision: revision, expectedBytes: expectedBytes, client: client)
        }

        // What arrived of another revision is of another file.
        var resumeData = try? Data(contentsOf: DownloadPaths.resumeData(itemID, in: directory))
        let fromElsewhere = record.transfer?.server.map { $0 != client.baseURL } ?? false
        if record.transfer?.revision != revision || fromElsewhere {
            discardPartial(itemID)
            resumeData = nil
            record.transfer = nil
        }
        let alreadyHere = resumeData == nil ? 0 : (record.transfer?.receivedBytes ?? 0)

        if let available = availableSpace(directory) {
            let needed = expectedBytes - alreadyHere
            if available - spaceReserveBytes < needed {
                record.state = .failed(.notEnoughSpace(neededBytes: needed, availableBytes: max(0, available - spaceReserveBytes)))
                records[itemID] = record
                changed()
                return
            }
        }

        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var request = client.authorizedRequest(for: url)
            request.allowsCellularAccess = record.allowsCellular
            request.allowsExpensiveNetworkAccess = record.allowsCellular
            task = session.downloadTask(with: request)
        }
        task.taskDescription = itemID
        task.countOfBytesClientExpectsToReceive = expectedBytes - alreadyHere
        tasks[itemID] = task

        record.transfer = DownloadTransfer(
            revision: revision, expectedBytes: expectedBytes, receivedBytes: alreadyHere, resumedAtByte: nil,
            server: client.baseURL)
        record.state = .downloading
        record.isWaitingForNetwork = false
        records[itemID] = record
        changed()
        task.resume()
    }

    // MARK: Over the direct road

    /// Where a transfer that the app carries came from. The local server's own address is another
    /// one each time the app starts.
    private static let carriedFrom = URL(string: "lobby-direct:")

    private func carry(_ itemID: String, from url: URL, revision: String, expectedBytes: Int64, client: LobbyClient) {
        guard var record = records[itemID] else { return }
        if record.transfer?.revision != revision || record.transfer?.server != Self.carriedFrom {
            discardPartial(itemID)
            record.transfer = nil
        }
        let transfer = CarriedTransfer(
            request: client.authorizedRequest(for: url), revision: revision, expectedBytes: expectedBytes,
            partial: DownloadPaths.partial(itemID, in: directory),
            staged: DownloadSessionDelegate.stagedFile(for: itemID, in: DownloadPaths.staging(in: directory)),
            session: carriedSession)
        let alreadyHere = transfer.receivedBytes
        if let available = availableSpace(directory) {
            let needed = expectedBytes - alreadyHere
            if available - spaceReserveBytes < needed {
                record.state = .failed(.notEnoughSpace(neededBytes: needed, availableBytes: max(0, available - spaceReserveBytes)))
                records[itemID] = record
                changed()
                return
            }
        }
        record.transfer = DownloadTransfer(
            revision: revision, expectedBytes: expectedBytes, receivedBytes: alreadyHere, resumedAtByte: alreadyHere > 0 ? alreadyHere : nil,
            server: Self.carriedFrom)
        record.state = .downloading
        record.isWaitingForNetwork = false
        records[itemID] = record
        changed()
        carried[itemID] = Task { [weak self] in
            do {
                let outcome = try await transfer.run { [weak self] received in
                    await self?.handle(.progress(itemID: itemID, receivedBytes: received))
                }
                await self?.carriedToTheEnd(itemID, outcome)
            } catch {
                await self?.carryingStopped(itemID, error)
            }
        }
    }

    private func carriedToTheEnd(_ itemID: String, _ outcome: CarriedTransfer.Outcome) {
        guard !Task.isCancelled, carried.removeValue(forKey: itemID) != nil else { return }
        handle(.finished(itemID: itemID, staged: outcome.staged, status: outcome.status, etag: outcome.etag, problem: nil))
    }

    private func carryingStopped(_ itemID: String, _ error: any Error) {
        // Whoever cancelled this already said what becomes of it.
        guard !Task.isCancelled, carried.removeValue(forKey: itemID) != nil, var record = records[itemID] else { return }
        if (error as? CocoaError)?.code == .fileWriteOutOfSpace {
            record.state = .failed(.notEnoughSpace(
                neededBytes: (record.transfer?.expectedBytes ?? 0) - (record.transfer?.receivedBytes ?? 0),
                availableBytes: max(0, (availableSpace(directory) ?? 0) - spaceReserveBytes)))
        } else {
            // The road broke, or the app was away. Nothing is lost: it goes on from what arrived.
            record.state = .queued
            record.isWaitingForNetwork = true
        }
        records[itemID] = record
        changed()
        pump()
    }

    private func stopCarrying(_ itemID: String, then state: DownloadState) {
        guard let task = carried.removeValue(forKey: itemID) else { return }
        task.cancel()
        records[itemID]?.state = state
    }

    // MARK: Events

    private func handle(_ event: DownloadSessionEvent) {
        switch event {
        case .progress(let itemID, let receivedBytes):
            guard records[itemID]?.state == .downloading, records[itemID]?.transfer?.receivedBytes != receivedBytes
            else { return }
            records[itemID]?.transfer?.receivedBytes = receivedBytes
            records[itemID]?.isWaitingForNetwork = false
            // Not written to the file: the system knows how far a transfer is.
            publish()

        case .resumed(let itemID, let atByte):
            records[itemID]?.transfer?.resumedAtByte = atByte
            records[itemID]?.transfer?.receivedBytes = atByte
            changed()

        case .waitingForNetwork(let itemID):
            guard records[itemID]?.state == .downloading else { return }
            records[itemID]?.isWaitingForNetwork = true
            changed()

        case .finished(let itemID, let staged, let status, let etag, let problem):
            tasks[itemID] = nil
            pausing.remove(itemID)
            finished(itemID, staged: staged, status: status, etag: etag, problem: problem)
            pump()

        case .stopped(let itemID, let reason):
            tasks[itemID] = nil
            stopped(itemID, reason: reason)
            pump()

        case .backgroundEventsDelivered:
            backgroundCompletion?()
            backgroundCompletion = nil
        }
    }

    /// The body arrived: check it, and only then make it the copy on this device.
    private func finished(_ itemID: String, staged: URL?, status: Int, etag: String?, problem: String?) {
        guard var record = records[itemID], let transfer = record.transfer else {
            // Removed while it was arriving.
            if let staged { removeIfPresent(staged) }
            return
        }
        removeIfPresent(DownloadPaths.resumeData(itemID, in: directory))

        func fail(_ failure: DownloadFailure) {
            if let staged { removeIfPresent(staged) }
            record.transfer = nil
            record.state = .failed(failure)
            records[itemID] = record
            changed()
        }
        /// The server has another file now than the one that was asked for. Ask again, once.
        func startOver(otherwise failure: DownloadFailure) {
            if let staged { removeIfPresent(staged) }
            guard !record.retried else { return fail(failure) }
            record.retried = true
            record.transfer = nil
            record.state = .queued
            records[itemID] = record
            changed()
        }

        guard status == 200 || status == 206 else {
            // 404: the prepared copy was evicted, or the file changed. Asking again makes a new one.
            return status == 404
                ? startOver(otherwise: .removedFromServer)
                : fail(.server("Lobby Server answered \(status) for the file."))
        }
        guard let staged else {
            return fail(.interrupted(problem ?? "The file could not be stored."))
        }
        // The server's ETag is the revision, or the revision and "-prepared".
        if let etag, !etag.contains(transfer.revision) {
            return startOver(otherwise: .changedOnServer)
        }
        let size = (try? staged.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? -1
        guard size == transfer.expectedBytes else {
            return fail(.sizeMismatch(expectedBytes: transfer.expectedBytes, receivedBytes: size))
        }

        // Verified. Into place in one step, and only now does an older copy go.
        let folder = DownloadPaths.itemFolder(itemID, in: directory)
        let fileName = DownloadPaths.safeName(transfer.revision) + ".mp4"
        let destination = folder.appending(path: fileName, directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            removeIfPresent(destination)
            try FileManager.default.moveItem(at: staged, to: destination)
            try excludeFromBackup(directory)
        } catch {
            return fail(.interrupted(error.localizedDescription))
        }
        if let previous = record.local {
            if previous.fileName != fileName {
                removeIfPresent(folder.appending(path: previous.fileName, directoryHint: .notDirectory))
            }
            for subtitle in previous.subtitles {
                removeIfPresent(folder.appending(path: subtitle.fileName, directoryHint: .notDirectory))
            }
        }

        record.local = LocalCopy(
            revision: transfer.revision, fileName: fileName, sizeBytes: size, completedAt: now(), subtitles: [])
        record.transfer = nil
        record.staleness = nil
        record.state = .verified
        record.isWaitingForNetwork = false
        records[itemID] = record
        changed()
        fetchSubtitles(itemID)
    }

    private func stopped(_ itemID: String, reason: DownloadSessionEvent.StopReason) {
        let wasPaused = pausing.remove(itemID) != nil
        guard var record = records[itemID] else { return }

        if let resumeData = reason.resumeData {
            let file = DownloadPaths.resumeData(itemID, in: directory)
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try resumeData.write(to: file, options: .atomic)
            } catch {
                storageError = error.localizedDescription
            }
        } else {
            // Nothing to continue from: the next attempt starts at the beginning.
            removeIfPresent(DownloadPaths.resumeData(itemID, in: directory))
            record.transfer?.receivedBytes = 0
        }

        if wasPaused {
            record.state = .paused
        } else if reason.outOfSpace {
            let expected = record.transfer?.expectedBytes ?? 0
            record.state = .failed(.notEnoughSpace(
                neededBytes: expected - (record.transfer?.receivedBytes ?? 0),
                availableBytes: max(0, (availableSpace(directory) ?? 0) - spaceReserveBytes)))
        } else if reason.cancelled {
            // Cancelled from outside the viewer's actions (the system, or a force-quit).
            record.state = .queued
        } else if !record.retried {
            record.retried = true
            record.state = .queued
        } else {
            record.state = .failed(.interrupted(reason.message))
        }
        record.isWaitingForNetwork = false
        records[itemID] = record
        changed()
    }

    // MARK: Subtitles

    /// Stores the item's text subtitles beside its file. A subtitle that cannot be fetched does
    /// not cost the film: it is simply not there, and is tried again with the next download.
    private func fetchSubtitles(_ itemID: String) {
        guard let record = records[itemID], let client,
            let file = record.item.files.first(where: { $0.assetId == record.assetID })
        else { return }
        let tracks = file.subtitles.filter(\.isText)
        guard !tracks.isEmpty else { return }
        let assetID = record.assetID
        let revision = record.local?.revision

        subtitleFetches[itemID]?.cancel()
        let sleep = sleep
        subtitleFetches[itemID] = Task { [weak self] in
            for track in tracks {
                guard !Task.isCancelled,
                    let data = try? await LobbyError.waitingItsTurn(sleep: sleep, {
                        try await client.data(at: client.subtitleURL(assetID: assetID, subtitle: track))
                    })
                else { continue }
                await self?.storeSubtitle(track, data: data, itemID: itemID, revision: revision)
            }
        }
    }

    private func storeSubtitle(_ track: SubtitleTrack, data: Data, itemID: String, revision: String?) {
        // The copy may have been removed or replaced while the subtitle was on its way.
        guard var local = records[itemID]?.local, local.revision == revision else { return }
        let fileName = DownloadPaths.safeName(track.id) + ".vtt"
        let url = DownloadPaths.itemFolder(itemID, in: directory).appending(path: fileName, directoryHint: .notDirectory)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            storageError = error.localizedDescription
            return
        }
        local.subtitles.removeAll { $0.id == track.id }
        local.subtitles.append(LocalSubtitle(
            id: track.id, language: track.language, title: track.title, isForced: track.isForced, fileName: fileName))
        records[itemID]?.local = local
        changed()
    }

    // MARK: Files

    private func discardPartial(_ itemID: String) {
        removeIfPresent(DownloadPaths.resumeData(itemID, in: directory))
        removeIfPresent(DownloadPaths.partial(itemID, in: directory))
        removeIfPresent(DownloadSessionDelegate.stagedFile(for: itemID, in: DownloadPaths.staging(in: directory)))
    }

    private func removeIfPresent(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Already gone.
        } catch {
            storageError = error.localizedDescription
        }
    }

    /// Downloads can be fetched again, and are large: they stay out of device backups.
    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = url
        try url.setResourceValues(values)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let contents = VersionedFile.read(
            Stored.self, from: DownloadPaths.recordsFile(in: directory), currentVersion: Self.formatVersion,
            migrate: Self.migrate)
        switch contents {
        case .value(let stored):
            records = Dictionary(stored.records.map { ($0.itemID, $0) }, uniquingKeysWith: { _, newer in newer })
        case .missing:
            break
        case .unreadable:
            // The files may still be there, and nothing says what they are. Set the list aside
            // for a later build instead of writing over it.
            let file = DownloadPaths.recordsFile(in: directory)
            do {
                let aside = file.appendingPathExtension("unreadable")
                removeIfPresent(aside)
                try FileManager.default.moveItem(at: file, to: aside)
            } catch {
                storageError = error.localizedDescription
            }
        }
    }

    private func changed() {
        save()
        publish()
    }

    private func save() {
        do {
            try VersionedFile.write(Stored(records: all()), to: DownloadPaths.recordsFile(in: directory))
            storageError = nil
        } catch {
            storageError = error.localizedDescription
        }
    }

    private func publish() {
        let snapshot = all()
        for observer in observers.values {
            observer.yield(snapshot)
        }
    }

    /// Version 1 is the first format, so there is nothing older to read yet.
    private static func migrate(version: Int, data: Data) throws -> Stored? {
        nil
    }
}

extension LobbyStorage {
    /// Where `DownloadManager` keeps its records and files.
    public static func downloadsDirectory(in directory: URL) -> URL {
        directory.appending(path: "Downloads", directoryHint: .isDirectory)
    }
}
