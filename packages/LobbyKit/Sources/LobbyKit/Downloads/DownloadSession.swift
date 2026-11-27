// SPDX-License-Identifier: MPL-2.0
import Foundation

/// What `URLSession` reported about a download, in the order it happened.
enum DownloadSessionEvent: Sendable {
    case progress(itemID: String, receivedBytes: Int64)
    /// The transfer continued from bytes that had already arrived (`Range` was honoured).
    case resumed(itemID: String, atByte: Int64)
    /// The system holds the transfer until there is a network it may use.
    case waitingForNetwork(itemID: String)
    /// The body arrived. `staged` is nil when it could not be moved out of the system's
    /// temporary place, with the reason in `problem`.
    case finished(itemID: String, staged: URL?, status: Int, etag: String?, problem: String?)
    case stopped(itemID: String, reason: StopReason)
    /// Every event of a background launch was delivered.
    case backgroundEventsDelivered

    struct StopReason: Sendable {
        var cancelled: Bool
        var outOfSpace: Bool
        var message: String
        /// What lets the transfer continue where it stopped.
        var resumeData: Data?
    }
}

/// The `URLSession` delegate of the downloads. It turns callbacks into events and moves a
/// finished file to the staging folder, which has to happen before the callback returns.
///
/// Each task carries its item id as `taskDescription`, which survives the app being relaunched
/// by the system for a background session.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let stagingDirectory: URL
    private let events: AsyncStream<DownloadSessionEvent>.Continuation

    init(stagingDirectory: URL, events: AsyncStream<DownloadSessionEvent>.Continuation) {
        self.stagingDirectory = stagingDirectory
        self.events = events
    }

    static func stagedFile(for itemID: String, in directory: URL) -> URL {
        directory.appending(path: DownloadPaths.safeName(itemID) + ".part", directoryHint: .notDirectory)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let itemID = downloadTask.taskDescription else { return }
        events.yield(.progress(itemID: itemID, receivedBytes: totalBytesWritten))
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        guard let itemID = downloadTask.taskDescription else { return }
        events.yield(.resumed(itemID: itemID, atByte: fileOffset))
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        guard let itemID = task.taskDescription else { return }
        events.yield(.waitingForNetwork(itemID: itemID))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let itemID = downloadTask.taskDescription else { return }
        let response = downloadTask.response as? HTTPURLResponse
        let staged = Self.stagedFile(for: itemID, in: stagingDirectory)
        var problem: String?
        do {
            // The system removes `location` when this method returns.
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: staged.path) {
                try FileManager.default.removeItem(at: staged)
            }
            try FileManager.default.moveItem(at: location, to: staged)
        } catch {
            problem = error.localizedDescription
        }
        events.yield(.finished(
            itemID: itemID, staged: problem == nil ? staged : nil, status: response?.statusCode ?? 0,
            etag: response?.value(forHTTPHeaderField: "ETag"), problem: problem))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        // Success was reported by `didFinishDownloadingTo`.
        guard let error, let itemID = task.taskDescription else { return }
        let nsError = error as NSError
        let posix = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap {
            $0.domain == NSPOSIXErrorDomain ? $0.code : nil
        }
        let outOfSpace = posix == Int(ENOSPC) || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC))
            || (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError)
        events.yield(.stopped(itemID: itemID, reason: .init(
            cancelled: (error as? URLError)?.code == .cancelled,
            outOfSpace: outOfSpace,
            message: error.localizedDescription,
            resumeData: nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data)))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        events.yield(.backgroundEventsDelivered)
    }
}

/// Where the downloads live, under one folder:
///
///     downloads.json            the records
///     files/<item>/<rev>.mp4    verified copies, and their subtitles as <id>.vtt
///     staging/<item>.partial    what arrived so far over the direct road
///     staging/<item>.part       a body that arrived and is not verified yet
///     resume/<item>.data        what lets a stopped transfer continue
enum DownloadPaths {
    static func recordsFile(in directory: URL) -> URL {
        directory.appending(path: "downloads.json", directoryHint: .notDirectory)
    }

    static func staging(in directory: URL) -> URL {
        directory.appending(path: "staging", directoryHint: .isDirectory)
    }

    /// What arrived so far over the direct road.
    static func partial(_ itemID: String, in directory: URL) -> URL {
        staging(in: directory).appending(path: safeName(itemID) + ".partial", directoryHint: .notDirectory)
    }

    static func itemFolder(_ itemID: String, in directory: URL) -> URL {
        directory.appending(path: "files", directoryHint: .isDirectory)
            .appending(path: safeName(itemID), directoryHint: .isDirectory)
    }

    static func resumeData(_ itemID: String, in directory: URL) -> URL {
        directory.appending(path: "resume", directoryHint: .isDirectory)
            .appending(path: safeName(itemID) + ".data", directoryHint: .notDirectory)
    }

    /// Ids and revisions are opaque strings from the server. Only what is plainly safe in a
    /// file name is kept as it is.
    static func safeName(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let scalars = text.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" + String($0.value, radix: 16) }
        return scalars.joined()
    }
}
