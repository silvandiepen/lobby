// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Observation

/// Uploads from this device to the server, for a manager: files and folders picked in Files or
/// dropped on the Mac's window, where they go, and how far each is (docs/imports.md).
@MainActor
@Observable
final class UploadsModel {
    private(set) var jobs: [UploadJob] = []
    private(set) var status: ImportsStatus?
    /// Files picked and not yet given a place: the app asks where they go.
    var picked: [UploadFile] = []
    var problem: String?

    private let app: AppModel
    @ObservationIgnored private var watching: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
    }

    private var queue: UploadQueue? { app.environment.uploads }

    /// Whether this device can upload: a server admin's iPhone, iPad or Mac. Imports are the
    /// server's library, so not a household admin's.
    var isAvailable: Bool { queue != nil && app.isOwnerManager }

    var active: [UploadJob] { jobs.filter { !$0.isFinished } }

    /// Gives the queue the server, and follows what it does. Called when the app starts and when
    /// the uploads are shown.
    func connect() async {
        guard let queue else { return }
        await queue.setClient(app.isOwnerManager ? app.managerClient : nil)
        guard watching == nil else { return }
        watching = Task { [weak self] in
            for await jobs in await queue.updates() {
                self?.jobs = jobs.sorted { $0.addedAt > $1.addedAt }
            }
        }
    }

    func loadDestinations() async {
        do {
            status = try await app.asManager { try await $0.imports() }
        } catch {
            problem = await app.managerProblem(error)
        }
    }

    /// The places a file can go: Films, Series, and each library folder of those kinds.
    var destinations: [(title: String, destination: UploadDestination)] {
        var list: [(String, UploadDestination)] = [("Movies", .movies), ("Series", .series)]
        for folder in status?.destinations ?? [] {
            list.append(("\(folder.name) (\(ServerSettingsModel.kindName(folder.hint)))", .folder(path: folder.path)))
        }
        return list
    }

    // MARK: Picking

    /// Files and folders that were picked or dropped. A folder brings what is in it, with its
    /// own folders kept in the names: "Show/Season 1/Show S01E01.mkv".
    func pick(_ urls: [URL]) {
        var files: [UploadFile] = []
        for url in urls {
            files.append(contentsOf: Self.files(at: url))
        }
        guard !files.isEmpty else {
            problem = "There are no videos or subtitles in what was picked."
            return
        }
        picked = files
    }

    func send(to destination: UploadDestination) async {
        let files = picked
        picked = []
        guard let queue else { return }
        await connect()
        await queue.add(files, destination: destination)
    }

    nonisolated static func files(at url: URL) -> [UploadFile] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            // The Mac keeps reading by path while the app is open: what was picked stays open.
            #if !os(macOS)
            if accessing { url.stopAccessingSecurityScopedResource() }
            #endif
        }
        _ = accessing
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return [] }
        if !isFolder.boolValue {
            guard UploadQueue.isUploadable(url.lastPathComponent), let size = size(of: url) else { return [] }
            return [UploadFile(source: source(for: url, subpath: nil), name: url.lastPathComponent, relPath: url.lastPathComponent, size: size)]
        }
        let base = url.lastPathComponent
        let folderSource = source(for: url, subpath: nil)
        guard
            let walker = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])
        else { return [] }
        var files: [UploadFile] = []
        for case let file as URL in walker {
            guard UploadQueue.isUploadable(file.lastPathComponent), let size = size(of: file) else { continue }
            let inside = file.standardizedFileURL.path.dropFirst(url.standardizedFileURL.path.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            // The server takes eight parts at most.
            let rel = ([base] + inside.split(separator: "/").map(String.init)).suffix(8).joined(separator: "/")
            var source = folderSource
            if source.bookmark != nil { source.subpath = inside } else { source.path = file.path }
            files.append(UploadFile(source: source, name: file.lastPathComponent, relPath: rel, size: size))
        }
        return files.sorted { $0.relPath < $1.relPath }
    }

    private nonisolated static func size(of url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true, let size = values.fileSize, size > 0
        else { return nil }
        return Int64(size)
    }

    /// The Mac reads by path while it is open; iPhone and iPad keep a bookmark, which lets the
    /// file be read again after the app was started anew, in the background too.
    private nonisolated static func source(for url: URL, subpath: String?) -> UploadSource {
        #if os(macOS)
        return UploadSource(path: url.path, subpath: subpath)
        #else
        if let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            return UploadSource(bookmark: bookmark, subpath: subpath)
        }
        return UploadSource(path: url.path, subpath: subpath)
        #endif
    }

    // MARK: Changing

    func pause(_ job: UploadJob) async { await queue?.pause(job.id) }
    func resume(_ job: UploadJob) async {
        await connect()
        await queue?.resume(job.id)
    }
    func cancel(_ job: UploadJob) async { await queue?.cancel(job.id) }
    func clearFinished() async { await queue?.clearFinished() }

    // MARK: Showing

    static func describe(_ job: UploadJob) -> String {
        let total = ByteCountFormatter.string(fromByteCount: job.size, countStyle: .file)
        switch job.state {
        case .queued: return job.problem ?? "Waiting to be sent · \(total)"
        case .sending:
            let sent = ByteCountFormatter.string(fromByteCount: job.sentBytes, countStyle: .file)
            return "\(sent) of \(total)"
        case .paused: return "Paused · \(Int((job.fraction * 100).rounded()))%"
        case .verifying: return "Arrived; the server checks it"
        case .done: return "Arrived. It is in the Inbox or the library."
        case .failed: return job.problem ?? "It did not work."
        case .cancelled: return "Cancelled"
        }
    }

    static func describe(_ destination: UploadDestination, status: ImportsStatus?) -> String {
        switch destination {
        case .movies: "Movies"
        case .series: "Series"
        case .folder(let path): status?.destinations.first { $0.path == path }?.name ?? (path as NSString).lastPathComponent
        }
    }
}
