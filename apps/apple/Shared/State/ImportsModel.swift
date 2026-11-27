// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Observation

/// The Inbox: files of import folders and uploads that wait for a manager, what is still being
/// written, what the rules left out, and what arrived (docs/imports.md).
@MainActor
@Observable
final class ImportsModel {
    enum View: String, CaseIterable, Identifiable, Sendable {
        case inbox, waiting, ignored, done
        var id: String { rawValue }

        var title: String {
            switch self {
            case .inbox: "Inbox"
            case .waiting: "Waiting"
            case .ignored: "Left Out"
            case .done: "Done"
            }
        }

        var empty: String {
            switch self {
            case .inbox: "Nothing waits for you."
            case .waiting: "Nothing is being written or waiting to hold still."
            case .ignored: "Nothing was left out."
            case .done: "Nothing was imported yet."
            }
        }
    }

    var view: View = .inbox
    private(set) var items: [ImportItem] = []
    private(set) var status: ImportsStatus?
    private(set) var activity: [ImportActivity] = []
    private(set) var isLoading = false
    private(set) var isWorking = false
    var problem: String?

    private let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let view = self.view
            status = try await app.asManager { try await $0.imports() }
            items = try await app.asManager { try await $0.importItems(view: view.rawValue) }
        } catch {
            problem = await app.managerProblem(error)
        }
    }

    func loadActivity() async {
        do {
            activity = try await app.asManager { try await $0.importActivity() }
        } catch {
            problem = await app.managerProblem(error)
        }
    }

    func scan() async {
        await work { try await $0.scanImports() }
    }

    func confirm(_ item: ImportItem, _ decision: ImportDecision) async -> Bool {
        await work { _ = try await $0.confirmImport(item.id, decision) }
    }

    func dismiss(_ item: ImportItem) async -> Bool {
        await work { _ = try await $0.dismissImport(item.id) }
    }

    func cleanUp(_ item: ImportItem) async -> Bool {
        await work { _ = try await $0.cleanUpImport(item.id) }
    }

    func convert(_ item: ImportItem) async -> Bool {
        await work { try await $0.convertImport(item.id) }
    }

    @discardableResult
    private func work(_ call: @escaping @Sendable (LobbyClient) async throws -> Void) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        do {
            try await app.asManager(call)
            await load()
            return true
        } catch {
            problem = await app.managerProblem(error)
            return false
        }
    }

    // MARK: Showing

    static func stateName(_ state: String) -> String {
        switch state {
        case "waiting": "Waiting"
        case "inbox": "Needs you"
        case "moving": "Moving"
        case "imported": "In the library"
        case "listed": "Listed where it is"
        case "ignored": "Left out"
        case "failed": "Did not work"
        case "dismissed": "Left alone"
        default: state
        }
    }

    static func title(of item: ImportItem) -> String {
        guard let title = item.title else { return item.name }
        if item.kind == "episode", let season = item.season, let episode = item.episode {
            return String(format: "%@ · S%02dE%02d", title, season, episode)
        }
        if let year = item.year { return "\(title) (\(year))" }
        return title
    }

    static func modeName(_ mode: String) -> String {
        mode == "index" ? "Listed where they are" : "Moved into the library"
    }
}

/// One import folder of the setting `import.folders`.
struct ImportFolderSetting: Hashable, Sendable, Identifiable {
    var path: String
    /// `move` or `index`.
    var mode: String
    var name: String?
    var id: String { path }

    init(path: String, mode: String, name: String? = nil) {
        self.path = path
        self.mode = mode
        self.name = name
    }

    init?(_ value: SettingValue) {
        guard case .object(let fields) = value, let path = fields["path"]?.string else { return nil }
        self.init(path: path, mode: fields["mode"]?.string ?? "move", name: fields["name"]?.string)
    }

    var value: SettingValue {
        var fields: [String: SettingValue] = ["path": .string(path), "mode": .string(mode)]
        if let name, !name.isEmpty { fields["name"] = .string(name) }
        return .object(fields)
    }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return (path as NSString).lastPathComponent
    }

    static func list(_ value: SettingValue) -> [ImportFolderSetting] {
        value.array?.compactMap(ImportFolderSetting.init) ?? []
    }

    /// Folders named like these may hold files a download program still needs where they are, so
    /// they start as listed where they are. The server decides the same for a folder it is given.
    static func looksLikeDownloads(_ path: String) -> Bool {
        let names: Set<String> = ["download", "downloads", "incomplete", "incoming"]
        return path.split(separator: "/").contains { names.contains($0.lowercased()) }
    }
}

extension ServerSettingsModel {
    var importFolders: [ImportFolderSetting] { ImportFolderSetting.list(value("import.folders")) }

    func setImportFolders(_ folders: [ImportFolderSetting]) {
        set("import.folders", .array(folders.map(\.value)))
    }

    func addImportFolder(path: String, mode: String) {
        var list = importFolders.filter { $0.path != path }
        list.append(ImportFolderSetting(path: path, mode: mode))
        setImportFolders(list)
    }

    func removeImportFolder(_ folder: ImportFolderSetting) {
        setImportFolders(importFolders.filter { $0.path != folder.path })
    }

    func setImportMode(_ folder: ImportFolderSetting, _ mode: String) {
        setImportFolders(importFolders.map { $0.path == folder.path ? ImportFolderSetting(path: $0.path, mode: mode, name: $0.name) : $0 })
    }
}
