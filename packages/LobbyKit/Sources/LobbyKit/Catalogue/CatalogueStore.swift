// SPDX-License-Identifier: MPL-2.0
import Foundation

/// The device's own copy of the catalogue: in memory for reading, in one file for the next launch.
///
/// Shelves and details are built from `catalogue()`, which needs no server. `sync(using:)` brings
/// it up to date through `GET /v1/library` and its `cursor`, `more`, `removed` and `reset` rules.
public actor CatalogueStore {
    /// Raise together with a case in `migrate(version:data:)`.
    static let formatVersion = 2

    struct Stored: Codable {
        var version = CatalogueStore.formatVersion
        /// The cursor for the next sync, or nil when the next sync is a full fetch.
        var cursor: String?
        var lastSyncedAt: Date?
        var items: [Item]
    }

    private let fileURL: URL
    private let now: @Sendable () -> Date

    private var loaded = false
    private var current = Catalogue()
    private var cursor: String?
    private var syncedAt: Date?
    private var runningSync: Task<Catalogue, any Error>?

    /// - Parameters:
    ///   - fileURL: Where the catalogue is kept, e.g. `LobbyStorage.catalogueFile(in:)`.
    ///   - now: The clock, for tests.
    public init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
    }

    /// The catalogue as of the last sync. Works with the server unreachable.
    public func catalogue() -> Catalogue {
        loadIfNeeded()
        return current
    }

    /// When the last complete sync finished, or nil if there never was one.
    public func lastSyncedAt() -> Date? {
        loadIfNeeded()
        return syncedAt
    }

    /// Fetches what changed since the last sync (or everything, the first time) and saves it.
    ///
    /// Calls made while a sync is running wait for that sync and return its result. When the
    /// server cannot be reached this throws `LobbyError.unreachable` and the catalogue stays as
    /// it was, plus whatever complete pages already arrived.
    ///
    /// - Parameters:
    ///   - pageSize: 1…1000, or nil for the server's default of 500.
    ///   - onPage: Called with the catalogue as it stands after each page that was added to
    ///     it, so that a first fetch can be shown while it is still arriving. Not called for
    ///     the pages of a reset, which replace the catalogue only when they are all there.
    @discardableResult
    public func sync(
        using client: LobbyClient, pageSize: Int? = nil,
        onPage: (@Sendable (Catalogue) async -> Void)? = nil
    ) async throws -> Catalogue {
        if let runningSync {
            return try await runningSync.value
        }
        let task = Task { try await self.runSync(client: client, pageSize: pageSize, onPage: onPage) }
        runningSync = task
        defer { runningSync = nil }
        return try await task.value
    }

    /// Forgets the catalogue, for signing out of a server or pairing with another one.
    public func clear() throws {
        current = Catalogue()
        cursor = nil
        syncedAt = nil
        loaded = true
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch CocoaError.fileNoSuchFile {
            // Nothing was saved yet.
        }
    }

    private func runSync(
        client: LobbyClient, pageSize: Int?, onPage: (@Sendable (Catalogue) async -> Void)?
    ) async throws -> Catalogue {
        loadIfNeeded()

        // After `reset`, the pages are a full fetch that replaces the local copy only once it is
        // complete. Until then they collect here and the old catalogue stays in use.
        // So are those of a fetch from the start beside a copy from before (`migrate`): what is
        // gone from the server meanwhile is in none of them.
        var replacement: Catalogue? = cursor == nil && !current.isEmpty ? Catalogue() : nil
        var nextCursor = cursor
        var more = true

        while more {
            let page = try await client.library(cursor: nextCursor, limit: pageSize)
            if page.reset, replacement == nil {
                replacement = Catalogue()
            }
            if replacement != nil {
                replacement?.apply(page)
            } else {
                // An incremental page and its cursor belong together: if a later page fails, the
                // next sync continues from here.
                current.apply(page)
                cursor = page.cursor
                if page.more {
                    // The last page is what `sync` returns.
                    await onPage?(current)
                }
            }
            nextCursor = page.cursor
            more = page.more
        }

        if let replacement {
            current = replacement
            cursor = nextCursor
        }
        syncedAt = now()
        try persist()
        return current
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let contents = VersionedFile.read(
            Stored.self, from: fileURL, currentVersion: Self.formatVersion, migrate: Self.migrate)
        // A missing, damaged or newer file costs one full fetch: this is a cache of the server.
        if case .value(let stored) = contents {
            current = Catalogue(items: stored.items)
            cursor = stored.cursor
            syncedAt = stored.lastSyncedAt
        }
    }

    private func persist() throws {
        let items = current.items.sorted { $0.id < $1.id }
        try VersionedFile.write(Stored(cursor: cursor, lastSyncedAt: syncedAt, items: items), to: fileURL)
        // The file can be fetched again, so it stays out of device backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = fileURL
        try url.setResourceValues(values)
    }

    /// Version 1 has the same shape, written by an app that dropped what a home page needs of a
    /// title (its logo, renown and dates). What it holds is shown, and the next sync fetches
    /// everything once, also what did not change since.
    private static func migrate(version: Int, data: Data) throws -> Stored? {
        guard version == 1 else { return nil }
        var stored = try LobbyJSON.decoder().decode(Stored.self, from: data)
        stored.version = formatVersion
        stored.cursor = nil
        return stored
    }
}
