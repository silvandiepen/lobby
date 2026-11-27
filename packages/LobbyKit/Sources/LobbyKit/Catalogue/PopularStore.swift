// SPDX-License-Identifier: MPL-2.0
import Foundation

/// The device's own copy of what the household watches, so that the home page is the same with
/// the server unreachable. Kept apart for all viewers and for kids viewers: what adults watch
/// never shapes a kids page.
public actor PopularStore {
    static let formatVersion = 1

    struct Stored: Codable, Equatable {
        var version = PopularStore.formatVersion
        var all: Popular?
        var kids: Popular?
        var allTag: String?
        var kidsTag: String?
    }

    private let fileURL: URL
    private var loaded = false
    private var current = Stored()

    /// - Parameter fileURL: Where the copy is kept, e.g. `LobbyStorage.popularFile(in:)`.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// What was watched as of the last sync. Works with the server unreachable.
    public func popular(kidsOnly: Bool) -> Popular {
        loadIfNeeded()
        return (kidsOnly ? current.kids : current.all) ?? .none
    }

    /// Fetches and saves it. A server without the route knows nothing, which is stored too.
    @discardableResult
    public func sync(kidsOnly: Bool, using client: LobbyClient) async throws -> Popular {
        loadIfNeeded()
        let before = current
        do {
            if let (fetched, tag) = try await client.popular(kidsOnly: kidsOnly, knownTag: kidsOnly ? current.kidsTag : current.allTag) {
                keep(fetched, tag: tag, kidsOnly: kidsOnly)
            }
        } catch LobbyError.notFound {
            keep(.none, tag: nil, kidsOnly: kidsOnly)
        }
        if current != before { try VersionedFile.write(current, to: fileURL) }
        return popular(kidsOnly: kidsOnly)
    }

    private func keep(_ popular: Popular, tag: String?, kidsOnly: Bool) {
        if kidsOnly {
            (current.kids, current.kidsTag) = (popular, tag)
        } else {
            (current.all, current.allTag) = (popular, tag)
        }
    }

    /// Forgets it, for signing out of a server or pairing with another one.
    public func clear() throws {
        current = Stored()
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
        // A damaged or newer file costs one fetch.
        if case .value(let stored) = VersionedFile.read(
            Stored.self, from: fileURL, currentVersion: Self.formatVersion, migrate: { _, _ in nil })
        {
            current = stored
        }
    }
}
