// SPDX-License-Identifier: MPL-2.0
import Foundation

/// The device's copy of the music library, with the orders the screens show it in.
public struct MusicCatalogue: Hashable, Sendable {
    public private(set) var artists: [String: MusicArtist] = [:]
    public private(set) var albums: [String: MusicAlbum] = [:]
    public private(set) var tracks: [String: MusicTrack] = [:]
    public private(set) var books: [String: MusicBook] = [:]

    public init(artists: [MusicArtist] = [], albums: [MusicAlbum] = [], tracks: [MusicTrack] = [], books: [MusicBook] = []) {
        self.artists = Dictionary(artists.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        self.albums = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        self.tracks = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        self.books = Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
    }

    public var isEmpty: Bool { tracks.isEmpty }

    /// Takes in one page of `GET /v1/music/library`. An id may be of any kind in `removed`.
    public mutating func apply(_ page: MusicLibraryPage) {
        for id in page.removed {
            artists[id] = nil
            albums[id] = nil
            tracks[id] = nil
            books[id] = nil
        }
        for artist in page.artists { artists[artist.id] = artist }
        for album in page.albums { albums[album.id] = album }
        for track in page.tracks { tracks[track.id] = track }
        for book in page.books { books[book.id] = book }
    }

    // MARK: In order

    /// By sort name, as a shelf of artists lists them.
    public var sortedArtists: [MusicArtist] {
        artists.values.sorted { ($0.sortName, $0.id) < ($1.sortName, $1.id) }
    }

    /// By title.
    public var sortedAlbums: [MusicAlbum] {
        albums.values.sorted { ($0.sortTitle, $0.id) < ($1.sortTitle, $1.id) }
    }

    /// The songs, by title: a book's parts are not songs.
    public var sortedSongs: [MusicTrack] {
        tracks.values.filter { $0.bookId == nil }.sorted { ($0.sortTitle, $0.id) < ($1.sortTitle, $1.id) }
    }

    public var sortedBooks: [MusicBook] {
        books.values.sorted { ($0.sortTitle, $0.id) < ($1.sortTitle, $1.id) }
    }

    /// What came last first.
    public var recentlyAddedAlbums: [MusicAlbum] {
        albums.values.sorted { ($0.addedAt, $0.id) > ($1.addedAt, $1.id) }
    }

    /// An album's tracks, as the sleeve has them.
    public func tracks(ofAlbum albumID: String) -> [MusicTrack] {
        tracks.values.filter { $0.albumId == albumID }.sorted(by: MusicTrack.albumOrder)
    }

    /// A book's files, in the book's order.
    public func tracks(ofBook bookID: String) -> [MusicTrack] {
        guard let book = books[bookID] else { return [] }
        return book.parts.compactMap { tracks[$0.trackId] }
    }

    /// The albums under an artist's name or with them on a track, newest first.
    public func albums(ofArtist artistID: String) -> [MusicAlbum] {
        let onTracks = Set(tracks.values.filter { $0.artistIds.contains(artistID) }.compactMap(\.albumId))
        return albums.values
            .filter { $0.artistIds.contains(artistID) || onTracks.contains($0.id) }
            .sorted { ($0.year ?? 0, $0.sortTitle) > ($1.year ?? 0, $1.sortTitle) }
    }

    /// An artist's songs on other albums than their own: where they are a guest.
    public func appearances(ofArtist artistID: String) -> [MusicAlbum] {
        albums(ofArtist: artistID).filter { !$0.artistIds.contains(artistID) }
    }

    /// The cover that stands for a track: its own, its album's, or its book's.
    public func coverID(of track: MusicTrack) -> String? {
        track.coverId ?? track.albumId.flatMap { albums[$0]?.coverId } ?? track.bookId.flatMap { books[$0]?.coverId }
    }

    /// The name above a track in a player: its album, or its book.
    public func collectionTitle(of track: MusicTrack) -> String? {
        track.albumId.flatMap { albums[$0]?.title } ?? track.bookId.flatMap { books[$0]?.title }
    }

    // MARK: Search

    public struct SearchResult: Hashable, Sendable {
        public var artists: [MusicArtist] = []
        public var albums: [MusicAlbum] = []
        public var songs: [MusicTrack] = []
        public var books: [MusicBook] = []

        public var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty && books.isEmpty }

        public init() {}
    }

    /// What has every word of `query` in its name, title or credit, whatever the case and accents.
    public func search(_ query: String, limit: Int = 30) -> SearchResult {
        let words = Self.fold(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return SearchResult() }
        func matches(_ fields: [String]) -> Bool {
            let text = Self.fold(fields.joined(separator: " "))
            return words.allSatisfy { text.contains($0) }
        }
        var result = SearchResult()
        result.artists = Array(sortedArtists.filter { matches([$0.name]) }.prefix(limit))
        result.albums = Array(sortedAlbums.filter { matches([$0.title, $0.artistCredit]) }.prefix(limit))
        result.songs = Array(sortedSongs.filter { matches([$0.title, $0.artistCredit]) }.prefix(limit))
        result.books = Array(sortedBooks.filter { matches([$0.title] + $0.authors + $0.narrators) }.prefix(limit))
        return result
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    // MARK: What is on this device

    /// Only what can play from these tracks: albums and books keep the ones that are here,
    /// artists the ones with such an album. The same screens, without the server.
    public func limited(to trackIDs: Set<String>) -> MusicCatalogue {
        var limited = MusicCatalogue()
        limited.tracks = tracks.filter { trackIDs.contains($0.key) }
        let albumIDs = Set(limited.tracks.values.compactMap(\.albumId))
        limited.albums = albums.filter { albumIDs.contains($0.key) }
        let bookIDs = Set(limited.tracks.values.compactMap(\.bookId))
        limited.books = books.filter { bookIDs.contains($0.key) }
        let artistIDs = Set(limited.albums.values.flatMap(\.artistIds) + limited.tracks.values.flatMap(\.artistIds))
        limited.artists = artists.filter { artistIDs.contains($0.key) }
        return limited
    }
}

/// The device's own copy of the music library: in memory for reading, in one file for the next
/// launch, brought up to date through `GET /v1/music/library` like the films' catalogue.
public actor MusicLibraryStore {
    static let formatVersion = 1

    struct Stored: Codable {
        var version = MusicLibraryStore.formatVersion
        var cursor: String?
        var lastSyncedAt: Date?
        /// False: the server said there is no music for this device.
        var hasMusic: Bool
        var artists: [MusicArtist]
        var albums: [MusicAlbum]
        var tracks: [MusicTrack]
        var books: [MusicBook]
    }

    private let fileURL: URL
    private let now: @Sendable () -> Date
    private var loaded = false
    private var current = MusicCatalogue()
    private var cursor: String?
    private var syncedAt: Date?
    private var hasMusic = true
    private var runningSync: Task<MusicCatalogue, any Error>?

    public init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
    }

    public func catalogue() -> MusicCatalogue {
        loadIfNeeded()
        return current
    }

    /// False when the server answered that there is no music: a server from before music, or
    /// a device that belongs to a kids viewer.
    public func serverHasMusic() -> Bool {
        loadIfNeeded()
        return hasMusic
    }

    public func lastSyncedAt() -> Date? {
        loadIfNeeded()
        return syncedAt
    }

    /// Fetches what changed since the last sync, or everything the first time. A server without
    /// music (`404`) empties the copy: what was there is no longer this device's.
    @discardableResult
    public func sync(using client: LobbyClient, pageSize: Int? = nil) async throws -> MusicCatalogue {
        if let runningSync { return try await runningSync.value }
        let task = Task { try await self.runSync(client: client, pageSize: pageSize) }
        runningSync = task
        defer { runningSync = nil }
        return try await task.value
    }

    public func clear() throws {
        current = MusicCatalogue()
        cursor = nil
        syncedAt = nil
        hasMusic = true
        loaded = true
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch CocoaError.fileNoSuchFile {}
    }

    private func runSync(client: LobbyClient, pageSize: Int?) async throws -> MusicCatalogue {
        loadIfNeeded()
        var replacement: MusicCatalogue? = cursor == nil && !current.isEmpty ? MusicCatalogue() : nil
        var nextCursor = cursor
        var more = true
        do {
            while more {
                let page = try await client.musicLibrary(cursor: nextCursor, limit: pageSize)
                if page.reset, replacement == nil { replacement = MusicCatalogue() }
                if replacement != nil {
                    replacement?.apply(page)
                } else {
                    current.apply(page)
                    cursor = page.cursor
                }
                nextCursor = page.cursor
                more = page.more
            }
        } catch LobbyError.notFound {
            current = MusicCatalogue()
            cursor = nil
            hasMusic = false
            syncedAt = now()
            try persist()
            return current
        }
        if let replacement {
            current = replacement
            cursor = nextCursor
        }
        hasMusic = true
        syncedAt = now()
        try persist()
        return current
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let contents = VersionedFile.read(Stored.self, from: fileURL, currentVersion: Self.formatVersion) { _, _ in nil }
        if case .value(let stored) = contents {
            current = MusicCatalogue(artists: stored.artists, albums: stored.albums, tracks: stored.tracks, books: stored.books)
            cursor = stored.cursor
            syncedAt = stored.lastSyncedAt
            hasMusic = stored.hasMusic
        }
    }

    private func persist() throws {
        try VersionedFile.write(
            Stored(
                cursor: cursor, lastSyncedAt: syncedAt, hasMusic: hasMusic,
                artists: current.artists.values.sorted { $0.id < $1.id },
                albums: current.albums.values.sorted { $0.id < $1.id },
                tracks: current.tracks.values.sorted { $0.id < $1.id },
                books: current.books.values.sorted { $0.id < $1.id }),
            to: fileURL)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = fileURL
        try url.setResourceValues(values)
    }
}
