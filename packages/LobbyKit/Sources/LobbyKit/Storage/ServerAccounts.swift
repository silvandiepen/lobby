// SPDX-License-Identifier: MPL-2.0
import Foundation

/// One Lobby Server this app holds: one's own household's, or another family's one was invited to.
///
/// Everything the app keeps for a server lives apart from the others: its files in a folder of
/// its own, its preferences in a defaults suite of its own, its credential and its direct
/// identity under a Keychain service of its own, and its downloads in a background session of
/// its own. `ServerAccountsStore` says where each is.
public struct ServerAccount: Codable, Hashable, Sendable, Identifiable {
    /// `ServerAccountsStore.firstID` for the server of a device from before there were several,
    /// a lower-case UUID for every one added since. Says where the account's things are.
    public var id: String
    /// The name a person gave it on this device. nil: the server's own name.
    public var localName: String?
    /// What the server calls itself, as of the last time it said. nil until it is paired.
    public var serverName: String?
    /// `ServerInfo.id`, once paired. Two accounts never have the same one.
    public var serverID: String?
    /// An SF Symbol, beside the name in the switcher.
    public var symbol: String
    /// One of the viewers' colour names ("blue", "green"…), for the symbol.
    public var color: String
    public var addedAt: Date
    /// When it was last the server in use: the start's "Which library?" puts the latest first.
    public var lastUsedAt: Date?
    public var storage: Storage

    /// Where the account's things are. Written down rather than worked out each time, so that a
    /// later build that lays new accounts out otherwise still finds the old ones.
    public struct Storage: Codable, Hashable, Sendable {
        /// Relative to Lobby's folder.
        public var folder: String
        /// nil: the app's standard defaults.
        public var defaultsSuite: String?
        public var keychainService: String
        /// The background `URLSession` of the downloads.
        public var downloadsSession: String
        /// The files of the one-server layout are still to be moved into `folder`.
        public var movesLegacyFiles: Bool

        public init(folder: String, defaultsSuite: String?, keychainService: String, downloadsSession: String, movesLegacyFiles: Bool = false) {
            self.folder = folder
            self.defaultsSuite = defaultsSuite
            self.keychainService = keychainService
            self.downloadsSession = downloadsSession
            self.movesLegacyFiles = movesLegacyFiles
        }
    }

    public init(
        id: String, localName: String? = nil, serverName: String? = nil, serverID: String? = nil, symbol: String = ServerAccount.symbols[0],
        color: String = ServerAccount.colors[0], addedAt: Date, storage: Storage
    ) {
        self.id = id
        self.localName = localName
        self.serverName = serverName
        self.serverID = serverID
        self.symbol = symbol
        self.color = color
        self.addedAt = addedAt
        self.storage = storage
    }

    /// What the switcher says.
    public var displayName: String {
        if let localName, !localName.trimmingCharacters(in: .whitespaces).isEmpty { return localName }
        return serverName ?? "New Server"
    }

    public var isPaired: Bool { serverID != nil }

    /// What a person chooses from.
    public static let symbols = ["house.fill", "building.2.fill", "tent.fill", "sailboat.fill", "tree.fill", "star.fill", "heart.fill", "film.fill"]
    public static let colors = ["blue", "green", "orange", "purple", "pink", "red", "yellow", "teal"]
}

/// The servers of this app, in the person's order, and which one is in use.
public struct ServerAccounts: Codable, Hashable, Sendable {
    static let currentVersion = 1

    public var version = ServerAccounts.currentVersion
    public var accounts: [ServerAccount]
    public var activeID: String
    /// This device remembers the choice of library: the start opens the last one used without
    /// asking. nil: it asks, with more than one server.
    public var remembersLibrary: Bool?

    public init(accounts: [ServerAccount], activeID: String, remembersLibrary: Bool? = nil) {
        self.accounts = accounts
        self.activeID = activeID
        self.remembersLibrary = remembersLibrary
    }

    /// The paired servers, the one used last first.
    public var byLastUse: [ServerAccount] {
        accounts.filter(\.isPaired).enumerated()
            .sorted { ($0.element.lastUsedAt ?? .distantPast, -$0.offset) > ($1.element.lastUsedAt ?? .distantPast, -$1.offset) }
            .map(\.element)
    }

    public var active: ServerAccount? { accounts.first { $0.id == activeID } }

    public func account(_ id: String) -> ServerAccount? { accounts.first { $0.id == id } }

    /// The account paired with this server, if any.
    public func account(serverID: String) -> ServerAccount? { accounts.first { $0.serverID == serverID } }
}

/// Where the servers are written down (`servers.json` in Lobby's folder), and where each one's
/// things go.
///
/// A device from before there were several servers kept one server's things straight in Lobby's
/// folder. The first `load()` makes them the account `firstID`: the files move into its folder,
/// and its preferences, Keychain items and background session stay where they were, so nothing is
/// copied and a transfer the system is running for it is found again.
public struct ServerAccountsStore: Sendable {
    /// The account of the server a device had before there were several. Its preferences, Keychain
    /// service and background session are the ones of that time.
    public static let firstID = "first"

    /// What a one-server device kept in Lobby's folder, all of which belongs to that server.
    public static let legacyFiles = [
        "catalogue.json", "categories.json", "popular.json", "progress.json", "Downloads", "DownloadArtwork", "Music",
    ]
    /// What it kept in Caches.
    public static let legacyCaches = ["Artwork"]

    /// Lobby's folder (`LobbyStorage.defaultDirectory()`, or a namespace inside it).
    public let root: URL
    /// The Caches folder the artwork cache went in. nil: none.
    public let caches: URL?
    /// The bundle id with the namespace: `mt.sil.lobby`, `mt.sil.lobby.ui-tests`.
    public let base: String
    /// The defaults suite of the one-server time: nil for a person's copy, the namespace's own suite for a test run.
    public let legacySuite: String?
    private let now: @Sendable () -> Date

    public init(root: URL, caches: URL?, base: String, legacySuite: String?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root
        self.caches = caches
        self.base = base
        self.legacySuite = legacySuite
        self.now = now
    }

    public var fileURL: URL { root.appending(path: "servers.json", directoryHint: .notDirectory) }

    // MARK: Reading and writing

    /// The servers as they were left. The first time, the one-server layout becomes the first
    /// account. A file that cannot be read is rebuilt from the folders, so no server is lost.
    public func load(legacyServerName: String? = nil, legacyServerID: String? = nil) throws -> ServerAccounts {
        var accounts: ServerAccounts
        switch VersionedFile.read(ServerAccounts.self, from: fileURL, currentVersion: ServerAccounts.currentVersion, migrate: { _, _ in nil }) {
        case .value(let stored):
            accounts = stored
        case .missing:
            var first = account(id: Self.firstID)
            first.storage.movesLegacyFiles = true
            first.serverName = legacyServerName
            first.serverID = legacyServerID
            accounts = ServerAccounts(accounts: [first], activeID: first.id)
            // Written before anything moves: a launch that stops halfway goes on where it was.
            try save(accounts)
        case .unreadable:
            accounts = rebuilt()
            try save(accounts)
        }
        if accounts.accounts.isEmpty {
            let fresh = account(id: Self.firstID)
            accounts = ServerAccounts(accounts: [fresh], activeID: fresh.id)
            try save(accounts)
        }
        if accounts.active == nil { accounts.activeID = accounts.accounts[0].id }

        for index in accounts.accounts.indices where accounts.accounts[index].storage.movesLegacyFiles {
            try moveLegacyFiles(into: accounts.accounts[index])
            accounts.accounts[index].storage.movesLegacyFiles = false
            try save(accounts)
        }
        return accounts
    }

    public func save(_ accounts: ServerAccounts) throws {
        try VersionedFile.write(accounts, to: fileURL)
    }

    /// From what is in `Servers/`: names and colours are lost, the things are not.
    private func rebuilt() -> ServerAccounts {
        let folder = root.appending(path: "Servers", directoryHint: .isDirectory)
        let ids = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0 == Self.firstID || UUID(uuidString: $0) != nil }
            .sorted { ($0 == Self.firstID ? 0 : 1, $0) < ($1 == Self.firstID ? 0 : 1, $1) }
        let accounts = (ids.isEmpty ? [Self.firstID] : ids).enumerated().map { index, id in
            var made = account(id: id)
            made.symbol = ServerAccount.symbols[index % ServerAccount.symbols.count]
            made.color = ServerAccount.colors[index % ServerAccount.colors.count]
            return made
        }
        return ServerAccounts(accounts: accounts, activeID: accounts[0].id)
    }

    // MARK: Accounts

    /// A new account, not written down yet. Its symbol and colour differ from those in use where they can.
    public func newAccount(besides existing: [ServerAccount] = []) -> ServerAccount {
        var made = account(id: UUID().uuidString.lowercased())
        let usedColors = Set(existing.map(\.color)), usedSymbols = Set(existing.map(\.symbol))
        made.color = ServerAccount.colors.first { !usedColors.contains($0) } ?? ServerAccount.colors[existing.count % ServerAccount.colors.count]
        made.symbol = ServerAccount.symbols.first { !usedSymbols.contains($0) } ?? ServerAccount.symbols[existing.count % ServerAccount.symbols.count]
        return made
    }

    private func account(id: String) -> ServerAccount {
        let isFirst = id == Self.firstID
        let own = "\(base).server.\(id)"
        return ServerAccount(
            id: id, addedAt: now(),
            storage: .init(
                folder: "Servers/\(id)",
                defaultsSuite: isFirst ? legacySuite : own,
                keychainService: isFirst ? base : own,
                downloadsSession: isFirst ? "\(base).downloads" : "\(own).downloads"))
    }

    /// The account's own folder, made when missing.
    public func directory(of account: ServerAccount) throws -> URL {
        let url = root.appending(path: account.storage.folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The account's own part of Caches. nil: no Caches folder.
    public func cachesDirectory(of account: ServerAccount) -> URL? {
        caches?.appending(path: account.storage.folder, directoryHint: .isDirectory)
    }

    /// Moves what a one-server device kept into the account's folder. A thing already in the
    /// folder stays: it is the one that was moved before.
    func moveLegacyFiles(into account: ServerAccount) throws {
        let fileManager = FileManager.default
        let target = try directory(of: account)
        for name in Self.legacyFiles {
            try move(root.appending(path: name), to: target.appending(path: name), fileManager)
        }
        if let caches, let cacheTarget = cachesDirectory(of: account) {
            for name in Self.legacyCaches {
                try move(caches.appending(path: name), to: cacheTarget.appending(path: name), fileManager)
            }
        }
    }

    private func move(_ source: URL, to destination: URL, _ fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: destination.path) else { return }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: destination)
    }

    /// Deletes the account's folder and its part of Caches. Nothing of another account is there.
    public func removeFiles(of account: ServerAccount) throws {
        let fileManager = FileManager.default
        let folder = root.appending(path: account.storage.folder, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: folder.path) { try fileManager.removeItem(at: folder) }
        if let cache = cachesDirectory(of: account), fileManager.fileExists(atPath: cache.path) {
            try fileManager.removeItem(at: cache)
        }
    }

    /// Forgets the account's preferences. The standard suite of the first account is shared with
    /// the app's own few: there only the account's keys go, which its stores remove themselves.
    public func removeDefaults(of account: ServerAccount) {
        guard let suite = account.storage.defaultsSuite, suite != legacySuite else { return }
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}
