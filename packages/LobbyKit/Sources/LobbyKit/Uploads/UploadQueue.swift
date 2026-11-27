// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Foundation
import Synchronization

/// Sends the bytes of one piece of an upload, from a file.
public protocol PieceTransport: Sendable {
    func send(_ request: URLRequest, fromFile file: URL) async throws -> (Data, HTTPURLResponse)
}

/// Pieces through an ordinary `URLSession`: while the app runs, as on the Mac.
public struct SessionPieceTransport: PieceTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest, fromFile file: URL) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.upload(for: request, fromFile: file)
            guard let http = response as? HTTPURLResponse else { throw LobbyError.invalidResponse("The answer was not HTTP.") }
            return (data, http)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw LobbyError.unreachable(error.code)
        }
    }
}

/// Pieces through a background `URLSession`: iOS goes on sending a piece while the app is in the
/// background or suspended, and wakes it when the piece is done, so it can send the next one.
public final class BackgroundPieceTransport: NSObject, PieceTransport, URLSessionDataDelegate {
    private struct Pending {
        var continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>
        var data = Data()
    }

    private struct State {
        var pending: [Int: Pending] = [:]
        var finishedEvents: (@Sendable () -> Void)?
    }

    public let identifier: String
    private let state = Mutex(State())
    private let orphaned: @Sendable () -> Void
    private let sessionHolder = Mutex<URLSession?>(nil)

    /// - Parameter orphaned: A piece finished that nobody waits for any more (the app was
    ///   started again by the system): the queue should look where its uploads are.
    public init(identifier: String, orphaned: @escaping @Sendable () -> Void) {
        self.identifier = identifier
        self.orphaned = orphaned
        super.init()
    }

    private var session: URLSession {
        sessionHolder.withLock { held in
            if let held { return held }
            let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
            configuration.sessionSendsLaunchEvents = true
            configuration.isDiscretionary = false
            let made = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            held = made
            return made
        }
    }

    /// Connects to the session again after a background launch, and calls `done` once its events
    /// were delivered.
    public func handleBackgroundEvents(done: @escaping @Sendable () -> Void) {
        state.withLock { $0.finishedEvents = done }
        _ = session
    }

    public func send(_ request: URLRequest, fromFile file: URL) async throws -> (Data, HTTPURLResponse) {
        let task = session.uploadTask(with: request, fromFile: file)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { $0.pending[task.taskIdentifier] = Pending(continuation: continuation) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        state.withLock { $0.pending[dataTask.taskIdentifier]?.data.append(data) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let pending = state.withLock { $0.pending.removeValue(forKey: task.taskIdentifier) }
        guard let pending else {
            orphaned()
            return
        }
        if let error = error as? URLError {
            pending.continuation.resume(throwing: error.code == .cancelled ? CancellationError() : LobbyError.unreachable(error.code))
        } else if let error {
            pending.continuation.resume(throwing: error)
        } else if let http = task.response as? HTTPURLResponse {
            pending.continuation.resume(returning: (pending.data, http))
        } else {
            pending.continuation.resume(throwing: LobbyError.invalidResponse("The answer was not HTTP."))
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let done = state.withLock { held -> (@Sendable () -> Void)? in
            let done = held.finishedEvents
            held.finishedEvents = nil
            return done
        }
        done?()
    }
}

/// Where a file to upload is, so it can be read again later: a path, or a security-scoped
/// bookmark (of the file, or of the folder it was picked in, with its path inside).
public struct UploadSource: Codable, Hashable, Sendable {
    public var bookmark: Data?
    public var path: String?
    /// Below the bookmarked folder.
    public var subpath: String?

    public init(bookmark: Data? = nil, path: String? = nil, subpath: String? = nil) {
        self.bookmark = bookmark
        self.path = path
        self.subpath = subpath
    }

    /// Reads the file within the access a bookmark grants.
    public func withAccess<T>(_ body: (URL) throws -> T) throws -> T {
        if let bookmark {
            var stale = false
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let options: URL.BookmarkResolutionOptions = []
            #endif
            let base = try URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
            let accessing = base.startAccessingSecurityScopedResource()
            defer { if accessing { base.stopAccessingSecurityScopedResource() } }
            let url = subpath.map { base.appending(path: $0, directoryHint: .notDirectory) } ?? base
            return try body(url)
        }
        guard let path else { throw UploadQueue.Problem("The file can no longer be found.") }
        return try body(URL(fileURLWithPath: path))
    }
}

/// One file the app uploads, and how far it got.
public struct UploadJob: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Hashable, Sendable {
        case queued, sending, paused, verifying, done, failed, cancelled
    }

    public var id: UUID
    public var source: UploadSource
    public var name: String
    /// The name the server gets: the file's name, or its path in a folder that was dropped.
    public var relPath: String
    public var size: Int64
    public var batch: String
    public var destination: UploadDestination
    public var uploadID: String?
    public var sentBytes: Int64
    public var state: State
    public var problem: String?
    /// The import it became on the server.
    public var itemID: String?
    public var addedAt: Date

    public init(
        id: UUID, source: UploadSource, name: String, relPath: String, size: Int64, batch: String,
        destination: UploadDestination, uploadID: String?, sentBytes: Int64, state: State, problem: String?, itemID: String?,
        addedAt: Date
    ) {
        self.id = id
        self.source = source
        self.name = name
        self.relPath = relPath
        self.size = size
        self.batch = batch
        self.destination = destination
        self.uploadID = uploadID
        self.sentBytes = sentBytes
        self.state = state
        self.problem = problem
        self.itemID = itemID
        self.addedAt = addedAt
    }

    public var fraction: Double { size == 0 ? 0 : min(1, Double(sentBytes) / Double(size)) }
    public var isFinished: Bool { state == .done || state == .cancelled }
}

/// A file picked to upload.
public struct UploadFile: Hashable, Sendable {
    public var source: UploadSource
    public var name: String
    public var relPath: String
    public var size: Int64

    public init(source: UploadSource, name: String, relPath: String, size: Int64) {
        self.source = source
        self.name = name
        self.relPath = relPath
        self.size = size
    }
}

/// The uploads of this device, one or two at a time, each in pieces the server checks, resumed
/// where the server says it is after anything stopped it (docs/api.md, Uploads).
public actor UploadQueue {
    public struct Problem: Error, LocalizedError, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "webm", "mpg", "mpeg", "ts", "m2ts", "wmv", "flv", "ogv", "divx", "3gp",
    ]
    public static let subtitleExtensions: Set<String> = ["srt", "vtt", "ass", "ssa", "sub", "idx"]

    private let storeFile: URL?
    private let pieceDirectory: URL
    private let transport: any PieceTransport
    private let pieceSize: Int64
    private let maxConcurrent: Int
    private var client: LobbyClient?
    private var jobs: [UploadJob] = []
    private var running: [UUID: Task<Void, Never>] = [:]
    private var observers: [UUID: AsyncStream<[UploadJob]>.Continuation] = [:]
    private var loaded = false

    /// - Parameter storeFile: Where the queue is kept between launches; nil keeps it in memory.
    public init(
        storeFile: URL?, pieceDirectory: URL, transport: any PieceTransport, pieceSize: Int64 = 64 * 1024 * 1024,
        maxConcurrent: Int = 2
    ) {
        self.storeFile = storeFile
        self.pieceDirectory = pieceDirectory
        self.transport = transport
        self.pieceSize = pieceSize
        self.maxConcurrent = maxConcurrent
    }

    /// Whether a file of this name is one the server takes.
    public static func isUploadable(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return !name.hasPrefix(".") && (videoExtensions.contains(ext) || subtitleExtensions.contains(ext))
    }

    // MARK: Watching

    public func updates() -> AsyncStream<[UploadJob]> {
        let (stream, continuation) = AsyncStream<[UploadJob]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.yield(jobs)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopObserving(id) }
        }
        return stream
    }

    private func stopObserving(_ id: UUID) {
        observers[id] = nil
    }

    private func changed(save: Bool = true) {
        for observer in observers.values { observer.yield(jobs) }
        if save { self.save() }
    }

    public var all: [UploadJob] { jobs }

    // MARK: Keeping

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let storeFile, let data = try? Data(contentsOf: storeFile),
            let saved = try? LobbyJSON.decoder().decode([UploadJob].self, from: data)
        else { return }
        // What was being sent when the app stopped goes on.
        jobs = saved.map { job in
            var job = job
            if job.state == .sending { job.state = .queued }
            return job
        }
    }

    private func save() {
        guard let storeFile else { return }
        do {
            try FileManager.default.createDirectory(at: storeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try LobbyJSON.encoder().encode(jobs).write(to: storeFile, options: .atomic)
        } catch {
            // The queue still runs; it is only not kept for the next launch.
        }
    }

    // MARK: Changing

    /// The server to send to; nil stops sending (the device is not a manager, or not connected).
    public func setClient(_ client: LobbyClient?) {
        load()
        self.client = client
        if client == nil {
            for task in running.values { task.cancel() }
            running = [:]
        }
        schedule()
    }

    @discardableResult
    public func add(_ files: [UploadFile], destination: UploadDestination) -> [UploadJob] {
        load()
        let batch = UUID().uuidString.lowercased()
        // Subtitles first: a subtitle that arrives before its film goes along with it.
        let ordered = files.sorted { a, b in
            let subA = Self.subtitleExtensions.contains((a.name as NSString).pathExtension.lowercased())
            let subB = Self.subtitleExtensions.contains((b.name as NSString).pathExtension.lowercased())
            return subA && !subB
        }
        let added = ordered.map { file in
            UploadJob(
                id: UUID(), source: file.source, name: file.name, relPath: file.relPath, size: file.size, batch: batch,
                destination: destination, uploadID: nil, sentBytes: 0, state: .queued, problem: nil, itemID: nil,
                addedAt: Date())
        }
        jobs.append(contentsOf: added)
        changed()
        schedule()
        return added
    }

    public func pause(_ id: UUID) {
        running[id]?.cancel()
        running[id] = nil
        update(id) { job in
            if job.state == .queued || job.state == .sending { job.state = .paused }
        }
        schedule()
    }

    public func resume(_ id: UUID) {
        update(id) { job in
            if job.state == .paused || job.state == .failed {
                job.state = .queued
                job.problem = nil
            }
        }
        schedule()
    }

    /// Stops it for good; the server removes what arrived.
    public func cancel(_ id: UUID) async {
        running[id]?.cancel()
        running[id] = nil
        guard let job = jobs.first(where: { $0.id == id }), !job.isFinished else { return }
        update(id) { $0.state = .cancelled }
        if let uploadID = job.uploadID, let client {
            _ = try? await client.cancelUpload(uploadID)
        }
        schedule()
    }

    /// Forgets uploads that arrived or were cancelled.
    public func clearFinished() {
        jobs.removeAll { $0.isFinished }
        changed()
    }

    /// Forgets every upload, also those under way: the device forgets its server.
    public func removeAll() {
        load()
        running.values.forEach { $0.cancel() }
        running = [:]
        jobs = []
        changed()
        try? FileManager.default.removeItem(at: pieceDirectory)
    }

    /// Looks again where everything is: after the app was started in the background.
    public func wake() {
        load()
        schedule()
    }

    private func update(_ id: UUID, save: Bool = true, _ change: (inout UploadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
        changed(save: save)
    }

    private func schedule() {
        guard let client else { return }
        for job in jobs where job.state == .queued || job.state == .verifying {
            guard running.count < maxConcurrent else { break }
            guard running[job.id] == nil else { continue }
            let id = job.id
            running[id] = Task { [weak self] in
                await self?.run(id, client: client)
            }
        }
    }

    private func finished(_ id: UUID) {
        running[id] = nil
        schedule()
    }

    // MARK: Sending

    private func run(_ id: UUID, client: LobbyClient) async {
        defer { finished(id) }
        do {
            try await send(id, client: client)
        } catch is CancellationError {
            // Paused, or no server: it waits where it is.
        } catch {
            let message = (error as? LobbyError).map(Self.describe) ?? error.localizedDescription
            update(id) { job in
                job.state = .failed
                job.problem = message
            }
        }
    }

    private static func describe(_ error: LobbyError) -> String {
        switch error {
        case .unreachable: "The server cannot be reached. It goes on when you resume."
        case .invalidRequest(let message), .forbidden(let message), .notFound(let message), .unavailable(let message),
            .gone(let message), .unauthorized(let message), .deviceRevoked(let message):
            message
        case .conflict(let message, _): message
        case .rateLimited(let message, _): message
        case .server(_, _, let message): message
        default: "The upload did not work."
        }
    }

    private func job(_ id: UUID) throws -> UploadJob {
        guard let job = jobs.first(where: { $0.id == id }) else { throw CancellationError() }
        return job
    }

    private func send(_ id: UUID, client: LobbyClient) async throws {
        var job = try self.job(id)
        if job.state == .verifying, let uploadID = job.uploadID {
            try await waitForProof(id, uploadID: uploadID, client: client)
            return
        }
        update(id) { $0.state = .sending }
        if job.uploadID == nil {
            let upload = try await client.createUpload(
                relPath: job.relPath, sizeBytes: job.size, destination: job.destination, batch: job.batch)
            update(id) { $0.uploadID = upload.id }
            job = try self.job(id)
        }
        guard let uploadID = job.uploadID else { return }
        let (upload, start) = try await client.uploadState(uploadID)
        if upload.state == "done" {
            update(id) { job in
                job.state = .done
                job.sentBytes = job.size
                job.itemID = upload.itemId
            }
            return
        }
        if upload.state == "cancelled" || upload.state == "failed" {
            // Given up on the server (a week without bytes): it starts again as a new upload.
            update(id) { job in
                job.uploadID = nil
                job.sentBytes = 0
                job.state = .queued
            }
            throw CancellationError()
        }

        var offset = start
        var whole = try hashPrefix(of: job.source, upTo: offset)
        update(id, save: false) { $0.sentBytes = offset }
        try FileManager.default.createDirectory(at: pieceDirectory, withIntermediateDirectories: true)
        let pieceFile = pieceDirectory.appending(path: "\(id.uuidString).piece", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: pieceFile) }

        while offset < job.size {
            try Task.checkCancellation()
            let length = min(pieceSize, job.size - offset)
            var next = whole
            let checksum = try writePiece(of: job.source, from: offset, length: length, to: pieceFile, whole: &next)
            let request = client.uploadPieceRequest(uploadID, offset: offset, length: length, checksum: checksum)
            let (data, http) = try await transport.send(request, fromFile: pieceFile)
            switch try LobbyClient.uploadPieceOutcome(status: http.statusCode, headers: http, data: data) {
            case .accepted(let now):
                if now == offset + length {
                    whole = next
                } else {
                    whole = try hashPrefix(of: job.source, upTo: now)
                }
                offset = now
            case .elsewhere(let now, _):
                whole = try hashPrefix(of: job.source, upTo: now)
                offset = now
            }
            update(id, save: true) { $0.sentBytes = offset }
        }

        let sha256 = whole.finalize().map { String(format: "%02x", $0) }.joined()
        update(id) { $0.state = .verifying }
        let done = try await client.completeUpload(uploadID, sha256: sha256)
        try await settle(id, done, uploadID: uploadID, client: client)
    }

    private func settle(_ id: UUID, _ upload: ServerUpload, uploadID: String, client: LobbyClient) async throws {
        switch upload.state {
        case "done":
            update(id) { job in
                job.state = .done
                job.sentBytes = job.size
                job.itemID = upload.itemId
                job.problem = nil
            }
        case "receiving":
            // It arrived damaged: the server starts it over.
            update(id) { job in
                job.state = .queued
                job.sentBytes = 0
                job.problem = upload.reason
            }
        case "verifying":
            try await waitForProof(id, uploadID: uploadID, client: client)
        default:
            update(id) { job in
                job.state = .failed
                job.problem = upload.reason ?? "The server did not take the file."
            }
        }
    }

    private func waitForProof(_ id: UUID, uploadID: String, client: LobbyClient) async throws {
        while true {
            try await Task.sleep(for: .seconds(2))
            let (upload, _) = try await client.uploadState(uploadID)
            if upload.state != "verifying" {
                try await settle(id, upload, uploadID: uploadID, client: client)
                return
            }
        }
    }

    // MARK: Reading the file

    private static let readSize = 1024 * 1024

    /// The SHA-256 of the file's first `count` bytes, to go on hashing after a restart.
    private func hashPrefix(of source: UploadSource, upTo count: Int64) throws -> SHA256 {
        var hash = SHA256()
        guard count > 0 else { return hash }
        try source.withAccess { url in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var left = count
            while left > 0 {
                guard let data = try handle.read(upToCount: Int(min(Int64(Self.readSize), left))), !data.isEmpty else {
                    throw Problem("The file is shorter than when it was picked.")
                }
                hash.update(data: data)
                left -= Int64(data.count)
            }
        }
        return hash
    }

    /// Copies one piece into a file of its own, for the request, and hashes it on the way.
    /// - Returns: The piece's SHA-256, base64.
    private func writePiece(
        of source: UploadSource, from offset: Int64, length: Int64, to file: URL, whole: inout SHA256
    ) throws -> String {
        var piece = SHA256()
        var hash = whole
        try source.withAccess { url in
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            try input.seek(toOffset: UInt64(offset))
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let output = try FileHandle(forWritingTo: file)
            defer { try? output.close() }
            try output.truncate(atOffset: 0)
            var left = length
            while left > 0 {
                guard let data = try input.read(upToCount: Int(min(Int64(Self.readSize), left))), !data.isEmpty else {
                    throw Problem("The file is shorter than when it was picked.")
                }
                piece.update(data: data)
                hash.update(data: data)
                try output.write(contentsOf: data)
                left -= Int64(data.count)
            }
        }
        whole = hash
        return Data(piece.finalize()).base64EncodedString()
    }
}
