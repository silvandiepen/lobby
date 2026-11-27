// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyDirect
import LobbyKit
import Observation

/// The servers this app holds and the one in use: one's own household's, and another
/// family's one was invited to.
///
/// Each server is an account with its own things (`ServerAccountsStore`), and the one in use has
/// an `AppModel` of its own, made from them. Switching takes the old model down
/// (`AppModel.suspend()`) and makes a new one from the other server's stored state, so nothing of
/// one server is ever on screen or sent with another. The downloads of every server keep running,
/// each in its own background session and to its own folder.
@MainActor
@Observable
final class ServersModel {
    /// How accounts become environments. The real app's are `live`; tests put stub servers in.
    struct Making {
        var store: ServerAccountsStore
        var downloads: @MainActor (ServerAccount) throws -> DownloadManager
        var environment: @MainActor (ServerAccount, DownloadManager) throws -> AppEnvironment
        /// Removes every Keychain item of an account.
        var removeCredentials: @Sendable (ServerAccount) async throws -> Void
        /// Whether a server answers at one of its addresses now, asked without its credential.
        var isReachable: @Sendable (ServerAccount) async -> Bool

        static func live(store: ServerAccountsStore, device: DeviceIdentity) -> Making {
            Making(
                store: store,
                downloads: { try AppEnvironment.liveDownloads(of: $0, in: store) },
                environment: { account, downloads in
                    try AppEnvironment.live(account: account, in: store, downloads: downloads, device: device)
                },
                removeCredentials: { account in
                    try KeychainCredentialStore(service: account.storage.keychainService).removeAll()
                },
                isReachable: { account in
                    // The addresses only: a server reached over the direct road alone counts as
                    // offline here, and is found once it is chosen.
                    guard let saved = ConnectionPreferences(suiteName: account.storage.defaultsSuite).connection else { return false }
                    return await ServerLocator.locate(serverID: saved.serverID, among: saved.candidates) != nil
                })
        }
    }

    /// Why a switch or a change of the list did not happen.
    enum Refusal: Hashable, Sendable {
        /// A manager bound this device to a kids viewer of the server in use.
        case boundToKids(String)
        /// Kids mode is on, and there is no way to ask for a grown-up here (the Apple TV).
        case kidsMode
        /// The grown-up's question was not answered.
        case refused
        case noPasscode

        var message: String {
            switch self {
            case .boundToKids(let server):
                "This device belongs to a kids viewer on “\(server)”, and stays on that server. A manager can change that from their own device."
            case .kidsMode:
                "A grown-up chooses another server. Leave the kids screens first."
            case .refused:
                ""
            case .noPasscode:
                "This device has no passcode, so there is no way to check for a grown-up. Set a passcode in Settings first."
            }
        }
    }

    private(set) var accounts: [ServerAccount]
    private(set) var activeID: String
    /// The model of the server in use.
    private(set) var active: AppModel
    /// The account that was in use when another was added, while that one is not paired yet:
    /// where Cancel goes back to.
    private(set) var addingFrom: String?
    /// The downloads of the servers not in use, by account id.
    private(set) var otherDownloads: [String: [DownloadRecord]] = [:]
    private(set) var isSwitching = false
    /// "Which library?" is up: the first of the two steps of the start, with more than one server.
    private(set) var choosingLibrary = false
    /// Whether each server answered when the libraries were last shown, by account id.
    private(set) var reachability: [String: Reach] = [:]
    /// The grown-up's question was answered for this showing of "Which library?".
    private var mayLeaveNow = false
    /// This device opens the last library without asking.
    private(set) var remembersLibrary = false

    enum Reach: Hashable, Sendable {
        case checking
        case reachable
        /// Only what is on this device plays.
        case offline
    }
    /// What the person should read: a switch that was refused, a removal that did not finish.
    var problem: String?

    private let making: Making
    private var managers: [String: DownloadManager] = [:]
    /// The managers that were started in this run: by a model of their server, or here.
    /// Started again, a manager would forget the server its transfers go on with.
    private var startedManagers: Set<String> = []
    private var followers: [String: Task<Void, Never>] = [:]
    private let startsClean: Bool

    /// - Parameter startsClean: Forget every server first. For a test run in its own namespace.
    init(making: Making, startsClean: Bool = false) throws {
        self.making = making
        self.startsClean = startsClean
        var list: ServerAccounts
        if startsClean {
            list = ServerAccounts(accounts: [], activeID: "")
            let old = (try? making.store.load()) ?? list
            // Forgotten in `start()`, where there is time to ask the Keychain; written down now
            // so that none of them is used.
            Self.pendingRemoval = old.accounts.filter { $0.id != ServerAccountsStore.firstID }
            for account in old.accounts where account.id != ServerAccountsStore.firstID {
                try? making.store.removeFiles(of: account)
                making.store.removeDefaults(of: account)
            }
            try? FileManager.default.removeItem(at: making.store.fileURL)
        }
        // A device from the one-server time: its server's name for the first account.
        let legacy = startsClean ? nil : ConnectionPreferences(suiteName: making.store.legacySuite).connection
        list = try making.store.load(legacyServerName: legacy?.serverName, legacyServerID: legacy?.serverID)
        accounts = list.accounts
        activeID = list.activeID
        remembersLibrary = list.remembersLibrary ?? false
        let account = list.active ?? list.accounts[0]
        let downloads = try making.downloads(account)
        active = AppModel(environment: try making.environment(account, downloads), startsClean: startsClean)
        managers[account.id] = downloads
        startedManagers.insert(account.id)
        connect(active, to: account.id)
        // With more than one library the start asks which, unless this device remembers it or
        // a manager bound it to a kids viewer, which keeps it on its server.
        let bound = active.environment.settings.device?.kidsProfileId != nil
        choosingLibrary = list.byLastUse.count > 1 && !remembersLibrary && !bound
        markUsed(account.id)
    }

    private func markUsed(_ id: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }), accounts[index].isPaired else { return }
        accounts[index].lastUsedAt = Date()
        try? save()
    }

    /// Accounts of a namespace that was reset, still to be removed from the Keychain.
    private static var pendingRemoval: [ServerAccount] = []

    var activeAccount: ServerAccount? { accounts.first { $0.id == activeID } }

    func account(_ id: String) -> ServerAccount? { accounts.first { $0.id == id } }

    /// The others in the switcher: paired ones only, in the person's order.
    var switchable: [ServerAccount] { accounts.filter { $0.isPaired || $0.id == activeID } }

    /// The list can be changed and another server chosen: not on a device bound to a kids viewer.
    var canChangeServers: Bool { !active.isBoundToKids }

    /// Whether there is more than one server to show a switcher for.
    var hasSeveral: Bool { switchable.count > 1 }

    // MARK: Starting

    /// Picks up the downloads of the servers that are not in use, so that what the system
    /// finished for them while the app was away lands in their folders. Once, at launch.
    func start() async {
        for account in Self.pendingRemoval { try? await making.removeCredentials(account) }
        Self.pendingRemoval = []
        for account in accounts where account.id != activeID {
            await followDownloads(of: account)
        }
    }

    private func manager(of account: ServerAccount) throws -> DownloadManager {
        if let known = managers[account.id] { return known }
        let made = try making.downloads(account)
        managers[account.id] = made
        return made
    }

    /// Starts an account's downloads without its server, and follows them for Downloads.
    private func followDownloads(of account: ServerAccount) async {
        guard followers[account.id] == nil, let manager = try? manager(of: account) else { return }
        if startedManagers.insert(account.id).inserted { await manager.start(using: nil) }
        otherDownloads[account.id] = await manager.all()
        let id = account.id
        followers[id] = Task { [weak self] in
            for await records in await manager.updates() {
                guard let self, self.activeID != id else { return }
                self.otherDownloads[id] = records
            }
        }
    }

    /// The system started the app for a background session: its account's manager takes it.
    func handleBackgroundEvents(identifier: String, completion: @escaping @Sendable () -> Void) async {
        guard let account = accounts.first(where: { $0.storage.downloadsSession == identifier }),
            let manager = try? manager(of: account)
        else { return completion() }
        await manager.handleBackgroundEvents(completion: completion)
        if account.id == activeID {
            // No window asks for it in a background launch: start the model, which picks the
            // transfers up again and takes their results.
            await active.start()
        } else {
            await followDownloads(of: account)
        }
    }

    #if os(iOS)
    /// The system started the app for an uploads' background session: its account's queue
    /// takes it. false: the session is no account's uploads. A server not in use gets its
    /// pieces' results; its queue goes on once it is in use again.
    func handleUploadEvents(identifier: String, completion: @escaping @Sendable () -> Void) async -> Bool {
        guard let account = accounts.first(where: { AppEnvironment.uploadsSession(of: $0) == identifier }),
            let directory = try? making.store.directory(of: account)
        else { return false }
        let caches = making.store.cachesDirectory(of: account) ?? directory.appending(path: "Caches", directoryHint: .isDirectory)
        let uploads = AppEnvironment.liveUploads(of: account, directory: directory, caches: caches)
        // A piece of an upload finished: the queue sends the next one.
        uploads.pieces.handleBackgroundEvents(done: completion)
        if account.id == activeID {
            await active.start()
            await active.uploads().connect()
        }
        return true
    }
    #endif

    // MARK: Switching

    /// Whether the person may leave the server in use now, asking for a grown-up where kids
    /// mode is on. nil: yes.
    private func mayLeave() async -> Refusal? {
        if active.isBoundToKids { return .boundToKids(activeAccount?.displayName ?? "this server") }
        // Before its start the model does not know its viewer yet: what it kept says kids mode.
        let isKids = active.isKidsMode || (active.phase == .launching && active.environment.settings.kidsModeProfileID != nil)
        guard isKids, !active.grownUpIsPresent else { return nil }
        guard active.hasKidsScreens else { return .kidsMode }
        switch await active.environment.confirmGrownUp() {
        case .confirmed: return nil
        case .refused: return .refused
        case .unavailable: return .noPasscode
        }
    }

    /// Uses another server: the one in use is taken down cleanly, and the other comes up as it
    /// was left. In kids mode only for a grown-up, and never on a device bound to a kids viewer.
    func switchTo(_ id: String) async {
        guard id != activeID, !isSwitching, account(id) != nil else { return }
        if let refusal = await mayLeave() { return refuse(refusal) }
        await activate(id)
    }

    private func refuse(_ refusal: Refusal) {
        if refusal != .refused { problem = refusal.message }
    }

    private func activate(_ id: String) async {
        guard let target = account(id), !isSwitching else { return }
        isSwitching = true
        defer { isSwitching = false }
        let model: AppModel
        do {
            // Made before the one in use goes down: one that cannot be made leaves it as it was.
            model = AppModel(environment: try making.environment(target, try manager(of: target)))
        } catch {
            problem = "That server could not be opened. \(error.localizedDescription)"
            return
        }
        let leaving = active
        let leftID = activeID
        await leaving.suspend()
        followers.removeValue(forKey: id)?.cancel()
        otherDownloads[id] = nil
        connect(model, to: id)
        startedManagers.insert(id)
        activeID = id
        active = model
        do {
            try save()
        } catch {
            problem = "Which server is in use could not be saved. \(error.localizedDescription)"
        }
        if addingFrom == id { addingFrom = nil }
        markUsed(id)
        if let left = account(leftID) { await followDownloads(of: left) }
    }

    /// The hooks through which the model of the server in use tells about its connection.
    private func connect(_ model: AppModel, to id: String) {
        model.account = AccountHooks(
            connectionChanged: { [weak self] connection in self?.connectionChanged(connection, of: id) },
            otherAccountName: { [weak self] serverID in
                self?.accounts.first { $0.id != id && $0.serverID == serverID }?.displayName
            })
    }

    private func connectionChanged(_ connection: SavedConnection?, of id: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        var changed = accounts[index]
        if let connection {
            changed.serverID = connection.serverID
            changed.serverName = connection.serverName
        } else {
            changed.serverID = nil
        }
        guard changed != accounts[index] else { return }
        accounts[index] = changed
        // Paired: nothing is being added any more.
        if changed.isPaired, addingFrom != nil, id == activeID { addingFrom = nil }
        if changed.isPaired, changed.lastUsedAt == nil { accounts[index].lastUsedAt = Date() }
        try? save()
    }

    private func save() throws {
        try making.store.save(ServerAccounts(
            accounts: accounts, activeID: activeID, remembersLibrary: remembersLibrary ? true : nil))
    }

    // MARK: Which library?

    /// The libraries for "Which library?": paired ones, the one used last first.
    var libraries: [ServerAccount] {
        ServerAccounts(accounts: accounts, activeID: activeID).byLastUse
    }

    /// The step is on screen: never on a device bound to a kids viewer.
    var showsLibraryChoice: Bool { choosingLibrary && !active.isBoundToKids && libraries.count > 1 }

    /// The one chosen when nothing else is: the last used.
    var preselectedLibrary: String? { libraries.first?.id }

    /// Back to "Which library?" from the viewer menu or Who is watching. In kids mode only for a
    /// grown-up, and never on a device bound to a kids viewer.
    func showLibraryChoice() async {
        guard !isSwitching, !choosingLibrary else { return }
        if let refusal = await mayLeave() { return refuse(refusal) }
        mayLeaveNow = true
        choosingLibrary = true
    }

    /// Asks each library whether it answers, for what the step shows beside it.
    func checkReachability() async {
        for account in libraries {
            if let manager = try? manager(of: account) { downloadCounts[account.id] = await manager.all().count }
        }
        let making = making
        await withTaskGroup(of: (String, Bool).self) { group in
            for account in libraries {
                reachability[account.id] = reachability[account.id] ?? .checking
                group.addTask { (account.id, await making.isReachable(account)) }
            }
            for await (id, answers) in group {
                reachability[id] = answers ? .reachable : .offline
            }
        }
    }

    /// How many films and episodes of each library are on this device, for the offline state.
    private(set) var downloadCounts: [String: Int] = [:]

    /// The second step: that library's viewers. Its own only: no viewer is of two servers.
    ///
    /// - Parameter remember: Open this library from now on without asking.
    func chooseLibrary(_ id: String, remember: Bool = false) async {
        guard choosingLibrary, account(id)?.isPaired == true else { return }
        if id != activeID {
            // At the start nobody was asked yet: a child does not leave kids mode by another server.
            if !mayLeaveNow, let refusal = await mayLeave() { return refuse(refusal) }
            await activate(id)
            guard activeID == id else { return }
        }
        if remember != remembersLibrary {
            remembersLibrary = remember
            try? save()
        }
        choosingLibrary = false
        mayLeaveNow = false
        active.askForViewer()
    }

    /// Left without choosing: the library in use stays, as it was.
    func closeLibraryChoice() {
        guard choosingLibrary else { return }
        choosingLibrary = false
        mayLeaveNow = false
    }

    /// Settings: whether the start asks which library.
    func setRemembersLibrary(_ remembers: Bool) {
        remembersLibrary = remembers
        try? save()
    }

    // MARK: Adding

    /// Adds a server: a new account comes up on the Connect screen (found at home, typed,
    /// or from outside with a code), with Cancel back to the one in use.
    ///
    /// - Parameter invitation: A `lobby://pair…` or `lobby://join…` link, filled in.
    func addServer(invitation: URL? = nil) async {
        guard !isSwitching else { return }
        // Already on a Connect screen of an account that has no server: that one takes it.
        if activeAccount?.isPaired == false {
            if let invitation { active.open(invitation) }
            return
        }
        if let refusal = await mayLeave() { return refuse(refusal) }
        let added = making.store.newAccount(besides: accounts)
        accounts.append(added)
        let from = activeID
        await activate(added.id)
        guard activeID == added.id else {
            accounts.removeAll { $0.id == added.id }
            try? save()
            return
        }
        addingFrom = from
        if let invitation { active.open(invitation) }
    }

    /// Whether the Connect screen on screen belongs to a server being added.
    var isAdding: Bool { addingFrom != nil && activeAccount?.isPaired == false }

    /// Gives up on adding: back to the server that was in use, and the empty account goes.
    func cancelAdding() async {
        guard isAdding, let from = addingFrom, let added = activeAccount else { return }
        await activate(from)
        addingFrom = nil
        await forget(added)
    }

    /// A link that was opened. A pairing link while a server is paired adds another server.
    func open(_ url: URL) {
        guard HouseholdInvitation.isPairingLink(url.absoluteString) else { return active.open(url) }
        if activeAccount?.isPaired == false, active.phase == .connect || active.phase == .launching {
            active.open(url)
        } else {
            Task { await addServer(invitation: url) }
        }
    }

    // MARK: Changing the list

    func rename(_ id: String, to name: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        accounts[index].localName = trimmed.isEmpty || trimmed == accounts[index].serverName ? nil : trimmed
        try? save()
    }

    func setLook(_ id: String, symbol: String, color: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].symbol = symbol
        accounts[index].color = color
        try? save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        try? save()
    }

    /// Moves one up or down the list, for where there is no dragging (the Apple TV, keys).
    func move(_ id: String, by offset: Int) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard accounts.indices.contains(target) else { return }
        accounts.swapAt(index, target)
        try? save()
    }

    /// Whether a server can be removed now: not on a device bound to a kids viewer.
    func canRemove(_ id: String) -> Bool { canChangeServers && account(id) != nil }

    /// Removes a server from this device: its credential, its copy of the library, its
    /// progress that was not sent, its settings and its downloads. Nothing of another server.
    /// The one in use first hands over to another one, or to a new empty one when it was the last.
    func remove(_ id: String) async {
        guard canRemove(id), let removed = account(id) else {
            if active.isBoundToKids { problem = Refusal.boundToKids(activeAccount?.displayName ?? "this server").message }
            return
        }
        if id == activeID {
            if let next = accounts.first(where: { $0.id != id && $0.isPaired }) ?? accounts.first(where: { $0.id != id }) {
                await activate(next.id)
            } else {
                let fresh = making.store.newAccount(besides: [])
                accounts.append(fresh)
                await activate(fresh.id)
            }
            guard activeID != id else { return }
        }
        if addingFrom == id { addingFrom = nil }
        await forget(removed)
    }

    private func forget(_ removed: ServerAccount) async {
        followers.removeValue(forKey: removed.id)?.cancel()
        otherDownloads[removed.id] = nil
        do {
            let downloads = try manager(of: removed)
            let environment = try making.environment(removed, downloads)
            await environment.unregisterPush()
            try await environment.forgetEverything()
            #if os(iOS) || os(macOS)
            await AppEnvironment.forgetUploads(of: removed)
            #endif
            await downloads.close()
            managers[removed.id] = nil
            try await making.removeCredentials(removed)
            try making.store.removeFiles(of: removed)
            making.store.removeDefaults(of: removed)
        } catch {
            problem = "Not everything of “\(removed.displayName)” could be removed. \(error.localizedDescription)"
        }
        accounts.removeAll { $0.id == removed.id }
        try? save()
    }

    // MARK: Downloads of other servers

    /// What the servers not in use have on this device, in the person's order. For On This Device.
    var otherServersDownloads: [(account: ServerAccount, overview: DownloadsOverview)] {
        accounts.compactMap { account in
            guard account.id != activeID, let records = otherDownloads[account.id], !records.isEmpty else { return nil }
            return (account, DownloadsOverview(records: records))
        }
    }

    /// Plays a download of another server: that server is switched to (in kids mode only for a
    /// grown-up), and the copy plays there by its rules once a viewer is chosen.
    func playDownload(itemID: String, of id: String) async {
        await switchTo(id)
        guard activeID == id else { return }
        active.playWhenReady(itemID)
    }
}
