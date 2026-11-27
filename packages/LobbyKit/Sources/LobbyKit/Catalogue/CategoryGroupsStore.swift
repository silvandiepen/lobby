// SPDX-License-Identifier: MPL-2.0
import Foundation

/// The device's own copy of the household's category groups, so that the library is laid out
/// the same with the server unreachable.
public actor CategoryGroupsStore {
    static let formatVersion = 1

    struct Stored: Codable {
        var version = CategoryGroupsStore.formatVersion
        var groups: [CategoryGroup]
        /// By category name: only in a file written before categories had ids.
        var logos: [String: CategoryLogo]?
        /// nil in a file written before the setup was counted.
        var revision: Int?
    }

    private let fileURL: URL
    private var loaded = false
    private var current = CategoryGroups.none

    /// - Parameter fileURL: Where the copy is kept, e.g. `LobbyStorage.categoriesFile(in:)`.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The groups as of the last sync. Works with the server unreachable.
    public func groups() -> CategoryGroups {
        loadIfNeeded()
        return current
    }

    /// Fetches the groups and saves them.
    ///
    /// A server that does not have the route yet has no groups: that is stored too, and the
    /// library is one whole, as it was before groups existed. Any other failure throws and
    /// leaves the copy as it was.
    @discardableResult
    public func sync(using client: LobbyClient) async throws -> CategoryGroups {
        loadIfNeeded()
        let fetched: CategoryGroups
        do {
            fetched = try await client.categories()
        } catch LobbyError.notFound {
            fetched = .none
        }
        if fetched != current || !FileManager.default.fileExists(atPath: fileURL.path) {
            current = fetched
            try VersionedFile.write(Stored(groups: fetched.groups, revision: fetched.revision), to: fileURL)
        }
        return current
    }

    /// Forgets the groups, for signing out of a server or pairing with another one.
    public func clear() throws {
        current = .none
        loaded = true
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch CocoaError.fileNoSuchFile {
            // Nothing was stored.
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        // A damaged or newer file costs one fetch: until then the library is one whole.
        if case .value(let stored) = VersionedFile.read(
            Stored.self, from: fileURL, currentVersion: Self.formatVersion, migrate: { _, _ in nil })
        {
            current = CategoryGroups(groups: stored.groups, revision: stored.revision ?? 0, logos: stored.logos ?? [:])
        }
    }
}
