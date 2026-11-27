// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Albums, playlists and books kept on this device, file by file.
///
/// How one file comes: `POST /v1/music/tracks/{id}/playback` with `purpose: download`, asked
/// again while the server makes a copy (`202`); then the answer's `url`, checked for its status
/// and its length, and moved into place as `<track>-<revision>.<ext>`. A format Apple does not
/// play arrives as the server's AAC copy at 256 kbit/s; everything else as the file itself.
///
/// One file at a time: the Pi serves the family meanwhile. A transfer runs while the app does
/// (the files are small); what did not finish starts again at the next launch. Nothing waits
/// on mobile data unless the viewer allowed downloads there.
public actor MusicDownloads {
    static let formatVersion = 1

    public struct Record: Codable, Hashable, Sendable {
        public enum State: String, Codable, Sendable {
            case queued, preparing, downloading, done, failed
        }

        public var trackID: String
        /// The revision of the file on the device. nil until one is there.
        public var revision: String?
        /// The revision the server has, as of the last look.
        public var wantedRevision: String
        public var fileName: String?
        public var bytes: Int64?
        public var state: State
        public var message: String?

        /// A copy that plays, also while a newer one is on its way.
        public var isPlayable: Bool { fileName != nil && revision != nil }
        public var isOutOfDate: Bool { revision != nil && revision != wantedRevision }
    }

    public struct Collection: Codable, Hashable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable {
            case album, playlist, book
        }

        public var id: String
        public var kind: Kind
        public var title: String
        public var trackIDs: [String]
        public var addedAt: Date

        public init(id: String, kind: Kind, title: String, trackIDs: [String], addedAt: Date = Date()) {
            self.id = id
            self.kind = kind
            self.title = title
            self.trackIDs = trackIDs
            self.addedAt = addedAt
        }
    }

    /// What the screens show.
    public struct Snapshot: Hashable, Sendable {
        public var records: [String: Record] = [:]
        public var collections: [Collection] = []
        /// On mobile data, which the viewer did not allow: nothing moves.
        public var isWaitingForWiFi = false

        public init(records: [String: Record] = [:], collections: [Collection] = [], isWaitingForWiFi: Bool = false) {
            self.records = records
            self.collections = collections
            self.isWaitingForWiFi = isWaitingForWiFi
        }

        public var playableTrackIDs: Set<String> { Set(records.values.filter(\.isPlayable).map(\.trackID)) }

        /// How far a collection is: files here, files in all.
        public func progress(of collectionID: String) -> (done: Int, total: Int) {
            guard let collection = collections.first(where: { $0.id == collectionID }) else { return (0, 0) }
            let ids = Set(collection.trackIDs)
            return (ids.filter { records[$0]?.state == .done }.count, ids.count)
        }

        public func contains(_ collectionID: String) -> Bool { collections.contains { $0.id == collectionID } }

        public var totalBytes: Int64 { records.values.filter(\.isPlayable).compactMap(\.bytes).reduce(0, +) }
    }

    struct Stored: Codable {
        var version = MusicDownloads.formatVersion
        var records: [String: Record]
        var collections: [Collection]
    }

    private let directory: URL
    private let filesDirectory: URL
    private let session: URLSession
    private let sleep: @Sendable (Duration) async throws -> Void
    private var client: LobbyClient?
    private var allowsCellular = false
    private var onMobileData = false
    private var loaded = false
    private var records: [String: Record] = [:]
    private var collections: [Collection] = []
    private var running: (trackID: String, task: Task<Void, Never>)?
    private var listeners: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    /// What a track is, for the transfers: its revision and whether Apple plays the file.
    private var known: [String: MusicTrack] = [:]
    public private(set) var storageError: String?

    /// - Parameters:
    ///   - directory: Where the records and the files go.
    ///   - configuration: The transfers' session. A test passes its own.
    ///   - sleep: The wait between two questions while the server makes a copy.
    public init(
        directory: URL, configuration: URLSessionConfiguration = .default,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.directory = directory
        filesDirectory = directory.appending(path: "Files", directoryHint: .isDirectory)
        session = URLSession(configuration: configuration)
        self.sleep = sleep
    }

    // MARK: Reading

    public func snapshot() -> Snapshot {
        loadIfNeeded()
        return Snapshot(records: records, collections: collections, isWaitingForWiFi: waitsForWiFi && hasWork)
    }

    /// The snapshot now, and again after every change.
    public func updates() -> AsyncStream<Snapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: Snapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        listeners[id] = continuation
        continuation.yield(snapshot())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopListening(id) }
        }
        return stream
    }

    private func stopListening(_ id: UUID) { listeners[id] = nil }

    /// The copy of a track on this device, or nil.
    public func localFile(trackID: String) -> URL? {
        loadIfNeeded()
        guard let record = records[trackID], record.isPlayable, let name = record.fileName else { return nil }
        let url = filesDirectory.appending(path: name, directoryHint: .notDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Settings

    /// The server to fetch from; nil while it is out of reach or the device is not paired.
    public func setClient(_ client: LobbyClient?) {
        loadIfNeeded()
        self.client = client
        pump()
    }

    public func setAllowsCellular(_ allowed: Bool) {
        allowsCellular = allowed
        if !allowed, onMobileData { stopRunning() }
        pump()
        announce()
    }

    public func setOnMobileData(_ on: Bool) {
        onMobileData = on
        if waitsForWiFi { stopRunning() }
        pump()
        announce()
    }

    private var waitsForWiFi: Bool { onMobileData && !allowsCellular }
    private var hasWork: Bool { records.values.contains { $0.state != .done && $0.state != .failed } }

    // MARK: Asking

    /// Keeps an album, playlist or book on this device. Asking again for one that is here
    /// changes its list of tracks (a playlist that changed) and fetches what is missing.
    public func keep(_ collection: Collection, tracks: [MusicTrack]) {
        loadIfNeeded()
        for track in tracks { known[track.id] = track }
        if let index = collections.firstIndex(where: { $0.id == collection.id }) {
            let old = collections[index]
            collections[index] = Collection(
                id: collection.id, kind: collection.kind, title: collection.title, trackIDs: collection.trackIDs,
                addedAt: old.addedAt)
        } else {
            collections.append(collection)
        }
        for track in tracks where collection.trackIDs.contains(track.id) {
            if var record = records[track.id] {
                record.wantedRevision = track.file.revision
                if record.isOutOfDate || record.state == .failed { record.state = .queued; record.message = nil }
                records[track.id] = record
            } else {
                records[track.id] = Record(trackID: track.id, wantedRevision: track.file.revision, state: .queued)
            }
        }
        removeUnwanted()
        persist()
        pump()
        announce()
    }

    /// Takes a collection off the device, with the files no other one needs.
    public func remove(collectionID: String) {
        loadIfNeeded()
        collections.removeAll { $0.id == collectionID }
        removeUnwanted()
        persist()
        pump()
        announce()
    }

    /// Everything, for signing out.
    public func removeAll() {
        loadIfNeeded()
        stopRunning()
        collections = []
        records = [:]
        try? FileManager.default.removeItem(at: directory)
        announce()
    }

    /// Tries the failed ones again.
    public func retryFailed() {
        loadIfNeeded()
        for (id, record) in records where record.state == .failed {
            records[id]?.state = .queued
            records[id]?.message = nil
        }
        persist()
        pump()
        announce()
    }

    /// Compares the copies with the library right after a sync: a file that changed on the
    /// server is fetched again (the old copy plays meanwhile); a track that is gone leaves its
    /// collections.
    public func reconcile(with catalogue: MusicCatalogue) {
        loadIfNeeded()
        for track in catalogue.tracks.values { known[track.id] = track }
        for index in collections.indices {
            collections[index].trackIDs.removeAll { catalogue.tracks[$0] == nil }
        }
        for (id, record) in records {
            guard let track = catalogue.tracks[id] else { continue }
            if record.wantedRevision != track.file.revision {
                records[id]?.wantedRevision = track.file.revision
                records[id]?.state = .queued
            }
        }
        removeUnwanted()
        persist()
        pump()
        announce()
    }

    // MARK: Transfers

    private func removeUnwanted() {
        let wanted = Set(collections.flatMap(\.trackIDs))
        for (id, record) in records where !wanted.contains(id) {
            if running?.trackID == id { stopRunning() }
            if let name = record.fileName {
                try? FileManager.default.removeItem(at: filesDirectory.appending(path: name, directoryHint: .notDirectory))
            }
            records[id] = nil
        }
    }

    private func stopRunning() {
        guard let running else { return }
        running.task.cancel()
        if records[running.trackID]?.state != .done { records[running.trackID]?.state = .queued }
        self.running = nil
    }

    /// Starts the next file when nothing is on its way.
    private func pump() {
        guard running == nil, let client, !waitsForWiFi else { return }
        // In the order the collections were asked for, each in its own order.
        let order = collections.sorted { $0.addedAt < $1.addedAt }.flatMap(\.trackIDs)
        guard let next = order.first(where: { id in
            guard let record = records[id] else { return false }
            return record.state == .queued || ((record.state == .preparing || record.state == .downloading))
        }) else { return }
        let task = Task { await self.transfer(trackID: next, client: client) }
        running = (next, task)
    }

    private func finished(_ trackID: String) {
        if running?.trackID == trackID { running = nil }
        persist()
        announce()
        pump()
    }

    private func transfer(trackID: String, client: LobbyClient) async {
        defer { finished(trackID) }
        guard var record = records[trackID] else { return }
        let convert = known[trackID]?.file.playability == .convert
        let quality: MusicQuality = convert ? .compact(256) : .original
        do {
            record.state = .preparing
            records[trackID] = record
            announce()
            var answer = try await client.musicPlayback(trackID: trackID, quality: quality, purpose: .download)
            var asked = 1
            while answer.state == .queued || answer.state == .preparing {
                guard asked < 900 else { throw LobbyError.unavailable(message: "The server took too long to make a copy.") }
                try await sleep(.seconds(1))
                try Task.checkCancellation()
                answer = try await client.musicPlayback(trackID: trackID, quality: quality, purpose: .download)
                asked += 1
            }
            guard answer.state == .ready, let path = answer.url, let url = client.musicURL(serverPath: path) else {
                throw LobbyError.unavailable(message: answer.message ?? "This file cannot be downloaded right now.")
            }
            guard records[trackID] != nil else { return }
            records[trackID]?.state = .downloading
            announce()

            var request = client.authorizedRequest(for: url)
            request.allowsCellularAccess = allowsCellular
            let (temporary, response) = try await session.download(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                try? FileManager.default.removeItem(at: temporary)
                throw LobbyError.unavailable(message: "The server did not send the file.")
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? Int64) ?? nil
            if let expected = answer.bytes, let size, expected != size {
                try? FileManager.default.removeItem(at: temporary)
                throw LobbyError.invalidResponse("The file arrived incomplete.")
            }
            let fileExtension = answer.isCopy ? "m4a" : (known[trackID]?.file.fileExtension ?? "m4a")
            let name = "\(Self.safeName(trackID))-\(Self.safeName(answer.revision)).\(fileExtension)"
            try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
            let destination = filesDirectory.appending(path: name, directoryHint: .notDirectory)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            excludeFromBackup(destination)

            // Still wanted? It may have been removed while it came.
            guard var done = records[trackID] else {
                try? FileManager.default.removeItem(at: destination)
                return
            }
            if let old = done.fileName, old != name {
                try? FileManager.default.removeItem(at: filesDirectory.appending(path: old, directoryHint: .notDirectory))
            }
            done.fileName = name
            done.revision = answer.revision
            done.bytes = size ?? answer.bytes
            done.state = done.revision == done.wantedRevision ? .done : .queued
            // The server has another revision than we thought: that one is what we have now.
            if done.revision != done.wantedRevision, known[trackID]?.file.revision == answer.revision {
                done.wantedRevision = answer.revision
                done.state = .done
            }
            done.message = nil
            records[trackID] = done
        } catch is CancellationError {
            if records[trackID] != nil, records[trackID]?.state != .done { records[trackID]?.state = .queued }
        } catch let error as LobbyError where error.isUnreachable {
            // Waits for the server; `setClient` starts it again.
            records[trackID]?.state = .queued
            self.client = nil
        } catch {
            if (error as? URLError)?.code == .cancelled {
                if records[trackID] != nil { records[trackID]?.state = .queued }
                return
            }
            records[trackID]?.state = .failed
            records[trackID]?.message = (error as? LobbyError)?.localizedDescription ?? error.localizedDescription
        }
    }

    /// An id is opaque: only letters, digits and dashes of it go into a file name, and one that
    /// had anything else is told apart by a hash (FNV-1a).
    static func safeName(_ id: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let kept = String(id.filter { allowed.contains($0) }.prefix(80))
        guard kept.count != id.count || kept.isEmpty else { return kept }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return kept + "-" + String(hash, radix: 16)
    }

    // MARK: Storage

    private func announce() {
        let now = Snapshot(records: records, collections: collections, isWaitingForWiFi: waitsForWiFi && hasWork)
        for listener in listeners.values { listener.yield(now) }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if case .value(let stored) = VersionedFile.read(
            Stored.self, from: directory.appending(path: "music-downloads.json"), currentVersion: Self.formatVersion,
            migrate: { _, _ in nil }) {
            records = stored.records
            collections = stored.collections
            // What was on its way when the app stopped starts again.
            for (id, record) in records where record.state == .preparing || record.state == .downloading {
                records[id]?.state = .queued
            }
        }
    }

    private func persist() {
        do {
            try VersionedFile.write(
                Stored(records: records, collections: collections), to: directory.appending(path: "music-downloads.json"))
            excludeFromBackup(directory)
            storageError = nil
        } catch {
            storageError = error.localizedDescription
        }
    }

    /// Downloads can be fetched again, and are large: they stay out of device backups.
    private func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = url
        try? url.setResourceValues(values)
    }
}
