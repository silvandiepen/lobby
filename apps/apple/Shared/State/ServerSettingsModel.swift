// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Observation

/// The server's settings, for a manager at home or over Tailscale: what they are, what is being
/// changed, what that will do, making the change, and waiting while the server restarts.
@MainActor
@Observable
final class ServerSettingsModel {
    private(set) var settings: ServerSettings?
    private(set) var isLoading = false
    private(set) var isWorking = false
    /// Values changed here and not yet sent, by key.
    private(set) var drafts: [String: SettingValue] = [:]
    /// What the server says the changes will do, before they are made.
    private(set) var review: SettingsChange?
    /// An earlier version to go back to, when that is what is being reviewed.
    private(set) var restoring: Int?
    private(set) var restart: Restart = .none
    /// "Saved." after a change, for a moment.
    private(set) var saved: String?
    private(set) var history: [SettingsVersion] = []
    private(set) var audit: [SettingsAuditEntry] = []
    var problem: String?

    enum Restart: Hashable, Sendable {
        case none
        /// The server is restarting; it is asked again and again until it is back.
        case waiting
        case back
        /// Not back after a minute and a half.
        case late
    }

    private let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    /// For the screens that open from these settings.
    var appModel: AppModel { app }

    // MARK: Reading

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            settings = try await app.asManager { try await $0.serverSettings() }
            if let settings { app.serverSetup = settings.setup }
        } catch {
            problem = await app.managerProblem(error)
        }
    }

    func loadHistory() async {
        do {
            history = try await app.asManager { try await $0.settingsHistory() }
            audit = try await app.asManager { try await $0.settingsAudit() }
        } catch {
            problem = await app.managerProblem(error)
        }
    }

    func descriptor(_ key: String) -> SettingDescriptor? { settings?.setting(key) }

    func settings(in section: String) -> [SettingDescriptor] {
        settings?.settings.filter { $0.section == section } ?? []
    }

    /// What is shown: the change being made, or what the server has.
    func value(_ key: String) -> SettingValue {
        drafts[key] ?? descriptor(key)?.value ?? .null
    }

    func isChanged(_ key: String) -> Bool { drafts[key] != nil }

    var hasChanges: Bool { !drafts.isEmpty }

    /// Some of the changes are taken only after a restart.
    var changesRestart: Bool { drafts.keys.contains { descriptor($0)?.restarts == true } }

    // MARK: Changing

    func set(_ key: String, _ value: SettingValue) {
        if descriptor(key)?.value == value {
            drafts[key] = nil
        } else {
            drafts[key] = value
        }
        review = nil
        restoring = nil
        saved = nil
    }

    func discard() {
        drafts = [:]
        review = nil
        restoring = nil
    }

    var folders: [LibraryFolder] { LibraryFolder.list(value("roots")) }

    func setFolders(_ folders: [LibraryFolder]) {
        set("roots", .array(folders.map(\.value)))
    }

    /// A folder picked in the browser; one that is in the list already gets the new kind.
    func addFolder(path: String, hint: String, forKids: Bool) {
        var list = folders.filter { $0.path != path }
        list.append(LibraryFolder(path: path, hint: hint, group: forKids ? LibraryFolder.kidsGroup : nil))
        setFolders(list)
    }

    func removeFolder(_ folder: LibraryFolder) {
        setFolders(folders.filter { $0.path != folder.path })
    }

    /// Asks the server what the changes will do. Nothing is changed yet.
    func prepareReview() async {
        guard let settings, hasChanges, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let drafts = self.drafts
            review = try await app.asManager {
                try await $0.changeSettings(drafts, baseVersion: settings.version, dryRun: true)
            }
            restoring = nil
        } catch {
            problem = await problemText(error)
        }
    }

    /// Asks what going back to an earlier version will do.
    func prepareRestore(_ version: Int) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            review = try await app.asManager { try await $0.restoreSettings(version: version, dryRun: true) }
            restoring = version
        } catch {
            problem = await problemText(error)
        }
    }

    func cancelReview() {
        review = nil
        restoring = nil
    }

    /// Makes the reviewed change. When the server restarts for it, waits until it is back.
    @discardableResult
    func apply() async -> Bool {
        guard let settings, !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let drafts = self.drafts
            let restoring = self.restoring
            let result = try await app.asManager { client in
                if let restoring {
                    return try await client.restoreSettings(version: restoring, dryRun: false)
                }
                return try await client.changeSettings(drafts, baseVersion: settings.version, dryRun: false)
            }
            self.drafts = [:]
            review = nil
            self.restoring = nil
            if result.restarting {
                await waitForRestart(after: result.bootId)
            } else {
                await load()
            }
            saved = result.changed.isEmpty ? "Nothing changed." : "Saved."
            return true
        } catch {
            problem = await problemText(error)
            return false
        }
    }

    /// Asks every second until the server answers as a new start, for a minute and a half at most.
    func waitForRestart(after bootID: String) async {
        restart = .waiting
        let started = Date()
        while Date().timeIntervalSince(started) < 90, !Task.isCancelled {
            do { try await app.environment.sleep(.seconds(1)) } catch { return }
            if let fresh = try? await app.asManager({ try await $0.serverSettings() }), fresh.bootId != bootID, !fresh.restarting {
                settings = fresh
                app.serverSetup = fresh.setup
                restart = .back
                return
            }
        }
        restart = .late
    }

    func endRestartNotice() {
        restart = .none
    }

    // MARK: The TMDB key

    var tmdbKey: SecretStatus { settings?.secrets.tmdbKey ?? SecretStatus(set: false, source: nil) }

    /// Checks the key with TMDB through the server and keeps it. Returns what went wrong.
    func setTMDBKey(_ key: String) async -> String? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return "Paste the key first." }
        isWorking = true
        defer { isWorking = false }
        do {
            let status = try await app.asManager { try await $0.setTMDBKey(key) }
            settings?.secrets.tmdbKey = status
            return nil
        } catch {
            return await problemText(error) ?? "That did not work."
        }
    }

    func removeTMDBKey() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let status = try await app.asManager { try await $0.removeTMDBKey() }
            settings?.secrets.tmdbKey = status
        } catch {
            problem = await problemText(error)
        }
    }

    // MARK: Words

    private func problemText(_ error: any Error) async -> String? {
        if case LobbyError.conflict = error {
            // Someone else changed something meanwhile: show what is there now.
            await load()
        }
        return await app.managerProblem(error)
    }

    static func kindName(_ hint: String) -> String {
        switch hint {
        case "movies": "Films"
        case "series": "Series"
        case "personal": "Home videos"
        case "mixed": "Films and series"
        case "music": "Music"
        case "audiobooks": "Audiobooks"
        default: hint.capitalized
        }
    }

    static let kinds = ["movies", "series", "personal", "mixed", "music", "audiobooks"]

    /// "01:00-07:00" as two times, in minutes after midnight.
    static func hours(_ value: SettingValue) -> (from: Int, to: Int)? {
        guard let text = value.string else { return nil }
        let parts = text.split(separator: "-").map { $0.split(separator: ":").compactMap { Int($0) } }
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2 else { return nil }
        return (parts[0][0] * 60 + parts[0][1], parts[1][0] * 60 + parts[1][1])
    }

    static func hoursValue(from: Int, to: Int) -> SettingValue {
        func time(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60 % 24, minutes % 60) }
        return .string("\(time(from))-\(time(to))")
    }

    static func describe(_ value: SettingValue) -> String {
        switch value {
        case .null: "None"
        case .bool(let on): on ? "On" : "Off"
        case .number(let number):
            number.rounded() == number ? String(Int64(number)) : String(number)
        case .string(let text): text
        case .array(let list): list.count == 1 ? "1 entry" : "\(list.count) entries"
        case .object: "Set"
        }
    }

    static func auditLine(_ entry: SettingsAuditEntry) -> String {
        let who = entry.by?.name ?? "Lobby Server"
        let what =
            switch entry.action {
            case "change": "changed \(entry.keys.joined(separator: ", "))"
            case "restore": "went back to an earlier version"
            case "refused": "was refused: \(entry.note ?? entry.keys.joined(separator: ", "))"
            case "tmdb_set": "set the TMDB key"
            case "tmdb_removed": "removed the TMDB key"
            case "setup": "setup: \(entry.keys.joined(separator: ", "))"
            default: entry.action
            }
        return "\(who) \(what)"
    }
}
