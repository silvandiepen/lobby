// SPDX-License-Identifier: MPL-2.0
import Foundation

/// What each viewer keeps of the music, on this device: favourites, playlists and what they
/// listened to. Read without the server; favourites and listens made offline wait in a queue
/// that `synchronise` sends. (Where a viewer is in a book is a `ProgressStore` of its own.)
public actor MusicPersonalStore {
    static let formatVersion = 1
    /// How many listens a viewer's Recently Played is made from.
    public static let recentLimit = 200

    struct Viewer: Codable {
        var favourites: [String: MusicFavourite] = [:]
        var favouritesRevision: Int?
        var playlists: [String: MusicPlaylist] = [:]
        var playlistsRevision: Int?
        /// The newest first: the server's and this device's.
        var recentPlays: [MusicPlay] = []
    }

    struct PendingFavourite: Codable, Hashable {
        var profileID: String
        var favourite: MusicFavourite
    }

    struct PendingPlay: Codable, Hashable {
        var profileID: String
        var play: MusicPlay
    }

    struct Stored: Codable {
        var version = MusicPersonalStore.formatVersion
        var viewers: [String: Viewer] = [:]
        var favourites: [PendingFavourite] = []
        var plays: [PendingPlay] = []
    }

    private let fileURL: URL
    private let now: @Sendable () -> Date
    private var loaded = false
    private var state = Stored()
    private var isSynchronising = false

    public init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
    }

    // MARK: Reading

    /// The viewer's favourites, with this device's unsent changes on top. Only what is one.
    public func favourites(profileID: String) -> Set<String> {
        loadIfNeeded()
        var all = state.viewers[profileID]?.favourites ?? [:]
        for pending in state.favourites where pending.profileID == profileID {
            all[pending.favourite.itemId] = pending.favourite
        }
        return Set(all.values.filter(\.favourite).map(\.itemId))
    }

    /// The viewer's playlists, the newest change first.
    public func playlists(profileID: String) -> [MusicPlaylist] {
        loadIfNeeded()
        return (state.viewers[profileID]?.playlists.values).map { Array($0) }?
            .sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) } ?? []
    }

    /// What the viewer listened to, the newest first, with what was not sent yet.
    public func recentPlays(profileID: String) -> [MusicPlay] {
        loadIfNeeded()
        return state.viewers[profileID]?.recentPlays ?? []
    }

    /// Listens that have not reached the server, for all viewers.
    public func pendingPlayCount() -> Int {
        loadIfNeeded()
        return state.plays.count
    }

    // MARK: Writing

    /// Marks something a favourite, or not any more. Sent at the next `synchronise`.
    public func setFavourite(_ favourite: Bool, itemID: String, kind: MusicKind, profileID: String) throws {
        loadIfNeeded()
        let change = MusicFavourite(itemId: itemID, kind: kind, favourite: favourite, updatedAt: now())
        state.favourites.removeAll { $0.profileID == profileID && $0.favourite.itemId == itemID }
        state.favourites.append(PendingFavourite(profileID: profileID, favourite: change))
        try persist()
    }

    /// Records a listen; sent at the next `synchronise`.
    public func record(_ play: MusicPlay, profileID: String) throws {
        loadIfNeeded()
        state.plays.append(PendingPlay(profileID: profileID, play: play))
        var viewer = state.viewers[profileID] ?? Viewer()
        viewer.recentPlays.insert(play, at: 0)
        viewer.recentPlays = Array(viewer.recentPlays.prefix(Self.recentLimit))
        state.viewers[profileID] = viewer
        try persist()
    }

    /// A playlist as the server answered it after a change.
    public func keep(_ playlist: MusicPlaylist, profileID: String) throws {
        loadIfNeeded()
        state.viewers[profileID, default: Viewer()].playlists[playlist.id] = playlist
        try persist()
    }

    public func forgetPlaylist(id: String, profileID: String) throws {
        loadIfNeeded()
        state.viewers[profileID]?.playlists[id] = nil
        try persist()
    }

    // MARK: Server

    /// Sends what waits (favourites, listens), then fetches the viewer's favourites, playlists
    /// and recent listens. An unreachable server stops it and keeps the queue.
    public func synchronise(profileID: String, using client: LobbyClient) async throws {
        loadIfNeeded()
        guard !isSynchronising else { return }
        isSynchronising = true
        defer { isSynchronising = false }

        while let pending = state.favourites.first {
            do {
                _ = try await client.setMusicFavourite(
                    profileID: pending.profileID, itemID: pending.favourite.itemId,
                    favourite: pending.favourite.favourite, updatedAt: pending.favourite.updatedAt)
                state.viewers[pending.profileID, default: Viewer()].favourites[pending.favourite.itemId] = pending.favourite
            } catch let error as LobbyError where error.isTransient || error.requiresPairing {
                throw error
            } catch LobbyError.conflict {
                // Changed later on another device: that one counts, and is fetched in full.
                state.viewers[pending.profileID]?.favouritesRevision = nil
            } catch {
                // Gone from the library, or a viewer that is gone: it can never be sent.
            }
            state.favourites.removeAll { $0 == pending }
            try persist()
        }

        for profile in Set(state.plays.map(\.profileID)) {
            let plays = state.plays.filter { $0.profileID == profile }
            for batch in stride(from: 0, to: plays.count, by: 500) {
                let part = plays[batch..<min(plays.count, batch + 500)]
                do {
                    try await client.addMusicPlays(profileID: profile, part.map(\.play))
                } catch let error as LobbyError where error.isTransient || error.requiresPairing {
                    throw error
                } catch {
                    // A viewer that is gone: its listens go with it.
                }
                let sent = Set(part.map(\.play.opId))
                state.plays.removeAll { sent.contains($0.play.opId) }
                try persist()
            }
        }

        var viewer = state.viewers[profileID] ?? Viewer()
        let favourites = try await client.musicFavourites(profileID: profileID, since: viewer.favouritesRevision)
        if viewer.favouritesRevision == nil { viewer.favourites = [:] }
        for favourite in favourites.favourites { viewer.favourites[favourite.itemId] = favourite }
        viewer.favouritesRevision = favourites.revision

        let playlists = try await client.musicPlaylists(profileID: profileID, since: viewer.playlistsRevision)
        if viewer.playlistsRevision == nil { viewer.playlists = [:] }
        for id in playlists.removed { viewer.playlists[id] = nil }
        for playlist in playlists.playlists { viewer.playlists[playlist.id] = playlist }
        viewer.playlistsRevision = playlists.revision

        let server = try await client.musicPlays(profileID: profileID, limit: Self.recentLimit)
        let unsent = state.plays.filter { $0.profileID == profileID }.map(\.play)
        viewer.recentPlays = Array((unsent + server).sorted { $0.playedAt > $1.playedAt }.prefix(Self.recentLimit))
        state.viewers[profileID] = viewer
        try persist()
    }

    public func removeProfile(_ profileID: String) throws {
        loadIfNeeded()
        state.viewers[profileID] = nil
        state.favourites.removeAll { $0.profileID == profileID }
        state.plays.removeAll { $0.profileID == profileID }
        try persist()
    }

    public func clear() throws {
        state = Stored()
        loaded = true
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch CocoaError.fileNoSuchFile {}
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if case .value(let stored) = VersionedFile.read(
            Stored.self, from: fileURL, currentVersion: Self.formatVersion, migrate: { _, _ in nil }) {
            state = stored
        }
    }

    private func persist() throws {
        try VersionedFile.write(state, to: fileURL)
    }
}
