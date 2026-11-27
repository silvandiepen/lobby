// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Observation

/// Looking through the server's own folders, to pick one. Read only, and only where the server
/// allows: its drives and its home folder.
@MainActor
@Observable
final class FolderBrowserModel {
    private(set) var listing: FolderListing?
    private(set) var isLoading = false
    var problem: String?
    private let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    /// nil: the places to start from.
    func open(_ path: String?) async {
        isLoading = true
        defer { isLoading = false }
        do {
            listing = try await app.asManager { try await $0.browseFolders(at: path) }
            problem = nil
        } catch {
            problem = await app.managerProblem(error)
        }
    }

    func up() async {
        await open(listing?.parent)
    }

    /// "412 videos", "No videos", "More than 4000 files".
    static func caption(_ entry: FolderEntry) -> String {
        let more = entry.more ? "+" : ""
        if entry.videoFiles == 0, entry.audioFiles == 0 { return entry.more ? "Many files, no videos so far" : "No videos" }
        var parts: [String] = []
        if entry.videoFiles > 0 { parts.append(entry.videoFiles == 1 && !entry.more ? "1 video" : "\(entry.videoFiles)\(more) videos") }
        if entry.audioFiles > 0 { parts.append("\(entry.audioFiles)\(more) audio files") }
        return parts.joined(separator: ", ")
    }
}

/// The first setup of a fresh server, after its first manager claimed it: a name, the library
/// folders, a TMDB key or none, and the first look through the folders.
@MainActor
@Observable
final class ServerSetupModel {
    enum Step: Int, CaseIterable, Hashable, Sendable {
        case name, folders, tmdb, scan
    }

    private(set) var step: Step = .name
    private(set) var isWorking = false
    var name = ""
    var key = ""
    var problem: String?
    /// While the first look goes on: what the server found so far.
    private(set) var status: ServerStatus?
    private(set) var isFinished = false
    let settings: ServerSettingsModel
    private let app: AppModel

    init(app: AppModel) {
        self.app = app
        settings = app.serverSettings()
    }

    func start() async {
        await settings.load()
        name = settings.descriptor("serverName")?.value.string ?? app.connection?.serverName ?? "Lobby"
        guard let setup = settings.settings?.setup else { return }
        // Where an earlier start of the setup stopped.
        if setup.isDone("name") { step = setup.isDone("folders") ? (setup.isDone("tmdb") ? .scan : .tmdb) : .folders }
    }

    var canGoOn: Bool {
        switch step {
        case .name: !name.trimmingCharacters(in: .whitespaces).isEmpty
        case .folders: !settings.folders.isEmpty
        case .tmdb, .scan: true
        }
    }

    func back() {
        guard let earlier = Step(rawValue: step.rawValue - 1), step != .scan else { return }
        problem = nil
        step = earlier
    }

    /// Keeps what this step chose on the server and goes to the next.
    func next() async {
        guard !isWorking else { return }
        problem = nil
        isWorking = true
        defer { isWorking = false }
        do {
            switch step {
            case .name:
                let name = self.name.trimmingCharacters(in: .whitespaces)
                if name == settings.descriptor("serverName")?.value.string {
                    _ = try await app.asManager { try await $0.markSetupStep("name", skipped: false) }
                } else {
                    settings.set("serverName", .string(name))
                    guard await applyDrafts() else { return }
                }
                step = .folders
            case .folders:
                if settings.hasChanges { guard await applyDrafts() else { return } }
                step = .tmdb
            case .tmdb:
                if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    _ = try await app.asManager { try await $0.markSetupStep("tmdb", skipped: true) }
                } else if let wrong = await settings.setTMDBKey(key) {
                    problem = wrong
                    return
                }
                key = ""
                step = .scan
                try await finish()
            case .scan:
                try await finish()
            }
        } catch {
            problem = await app.managerProblem(error)
        }
    }

    /// No key: titles come from the file names.
    func skipKey() async {
        key = ""
        await next()
    }

    private func applyDrafts() async -> Bool {
        let done = await settings.apply()
        if !done {
            problem = settings.problem
            settings.problem = nil
        }
        return done
    }

    private func finish() async throws {
        let setup = try await app.asManager { try await $0.finishSetup() }
        app.serverSetup = setup
        await watchScan()
    }

    /// Follows the first look through the folders until it has gone quiet.
    private func watchScan() async {
        var quiet = 0
        while !Task.isCancelled, quiet < 3 {
            if let fresh = try? await app.asManager({ try await $0.status() }) {
                status = fresh
                quiet = fresh.scanning || fresh.files.waiting > 0 ? 0 : quiet + 1
            }
            do { try await app.environment.sleep(.seconds(1)) } catch { return }
        }
        isFinished = true
        await app.refresh()
    }

    /// "Found 120 films and 8 series, 12 files still to read."
    var progressText: String {
        guard let status else { return "Lobby Server starts looking…" }
        let items = status.items
        var found: [String] = []
        if items.movies > 0 { found.append(items.movies == 1 ? "1 film" : "\(items.movies) films") }
        if items.shows > 0 { found.append(items.shows == 1 ? "1 series" : "\(items.shows) series") }
        if items.personal > 0 { found.append("\(items.personal) home videos") }
        let what = found.isEmpty ? "Nothing found yet" : "Found \(found.joined(separator: " and "))"
        let waiting = status.files.waiting
        return waiting > 0 ? "\(what), \(waiting) files still to read." : "\(what)."
    }
}
