// SPDX-License-Identifier: MPL-2.0
import CoreGraphics
import Foundation
import LobbyKit
import Observation

/// AudioToolbox has a `MusicTrack` of its own (a MIDI sequence's): in this app the name is
/// always the library's.
typealias MusicTrack = LobbyKit.MusicTrack

/// Where music keeps its things on this device: its copy of the library, what each viewer
/// keeps, where they are in books, and the downloads.
struct MusicStorage: Sendable {
    var library: MusicLibraryStore
    var personal: MusicPersonalStore
    var progress: ProgressStore
    var downloads: MusicDownloads

    init(directory: URL, downloadSession: URLSessionConfiguration = .default,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        library = MusicLibraryStore(fileURL: directory.appending(path: "music-library.json"))
        personal = MusicPersonalStore(fileURL: directory.appending(path: "music-viewers.json"))
        progress = ProgressStore(fileURL: directory.appending(path: "music-progress.json"), routes: .music)
        downloads = MusicDownloads(directory: directory.appending(path: "MusicDownloads", directoryHint: .isDirectory),
                                   configuration: downloadSession, sleep: sleep)
    }

    func clear() async throws {
        try await library.clear()
        try await personal.clear()
        try await progress.clear()
        await downloads.removeAll()
    }
}

/// The household's music on this device: the library, the viewer's favourites, playlists,
/// listens and books, the downloads, and the player. Kept apart from the films, as on the
/// server (docs/decisions.md, "Music"), and owned by the app model, which tells it the connection and the viewer.
@MainActor
@Observable
final class MusicModel {
    /// Everything the server has, as of the last sync.
    private(set) var wholeCatalogue = MusicCatalogue()
    /// What the screens show: all of it, or what is on this device.
    private(set) var catalogue = MusicCatalogue()
    /// False: the server said there is no music for this device.
    private(set) var serverHasMusic = true
    private(set) var favourites: Set<String> = []
    private(set) var playlists: [MusicPlaylist] = []
    private(set) var recentPlays: [MusicPlay] = []
    private(set) var bookProgress: [String: PlaybackProgress] = [:]
    private(set) var downloads = MusicDownloads.Snapshot()
    /// Something the listener should know: a change the server refused.
    var problem: String?

    /// The connection, while the server is found.
    private(set) var client: LobbyClient?
    private(set) var serverIsOutOfReach = false
    /// Only what is on this device: the server is out of reach, or the viewer asked for it.
    var showsDownloadedOnly = false {
        didSet { if showsDownloadedOnly != oldValue { applyLimit() } }
    }
    /// A kids viewer, or a device that belongs to one: music only where the plan lets it listen
    /// (docs/kids-control.md); the server keeps to the libraries chosen for the child.
    var isForKids = false
    /// The kids viewer's plan allows listening now.
    var kidsMayListen = false
    private var isClosedForKids: Bool { isForKids && !kidsMayListen }
    /// The network costs: a format that needs converting is fetched compact.
    var isOnExpensiveNetwork = false
    /// Loud and quiet songs alike, from their ReplayGain.
    var matchesVolume = true
    /// How fast books are read, for the next one too.
    var bookRate: Float {
        get { Float(UserDefaults.standard.object(forKey: "lobby.music.bookRate") as? Double ?? 1) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "lobby.music.bookRate") }
    }

    @ObservationIgnored let storage: MusicStorage?
    @ObservationIgnored private var profileID: String?
    @ObservationIgnored private let coverLoader: @MainActor (Artwork, Int) async -> CGImage?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var keptCoversChanged: @MainActor () -> Void = {}
    @ObservationIgnored private(set) lazy var player = MusicPlayer(music: self)

    /// - Parameters:
    ///   - storage: nil keeps nothing between launches.
    ///   - coverLoader: Fetches a cover as the app fetches posters.
    init(
        storage: MusicStorage?, coverLoader: @escaping @MainActor (Artwork, Int) async -> CGImage? = { _, _ in nil },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.storage = storage
        self.coverLoader = coverLoader
        self.sleep = sleep
    }

    /// Music is shown: the server has some, and the viewer is not a child.
    var isAvailable: Bool { !isClosedForKids && serverHasMusic && !wholeCatalogue.isEmpty }

    // MARK: Launch and refresh

    /// Where the server is reached now, as the app model found it. Downloads move with it.
    func setConnection(_ client: LobbyClient?, outOfReach: Bool) {
        self.client = client
        serverIsOutOfReach = outOfReach
        let usable = outOfReach ? nil : client
        Task { [downloads = storage?.downloads] in await downloads?.setClient(usable) }
    }

    /// Reads what was kept, so the screens open at once and without the server.
    func start(profileID: String?, keptCoversChanged: @escaping @MainActor () -> Void) async {
        self.keptCoversChanged = keptCoversChanged
        guard !started, let storage else { return }
        started = true
        wholeCatalogue = await storage.library.catalogue()
        serverHasMusic = await storage.library.serverHasMusic()
        downloads = await storage.downloads.snapshot()
        applyLimit()
        await viewerChanged(profileID)
        Task { [weak self] in
            for await snapshot in await storage.downloads.updates() {
                guard let self else { return }
                let before = self.downloads.playableTrackIDs
                self.downloads = snapshot
                if snapshot.playableTrackIDs != before {
                    self.applyLimit()
                    self.keptCoversChanged()
                }
            }
        }
    }

    /// Another viewer: their favourites, playlists, listens and books.
    func viewerChanged(_ profileID: String?) async {
        if self.profileID != nil, profileID != self.profileID { player.stop() }
        self.profileID = profileID
        await reloadPersonal()
    }

    /// Fetches what changed: the library, then the viewer's own. Quiet when there is no music.
    func refresh(using client: LobbyClient) async {
        guard let storage, !isClosedForKids else { return }
        do {
            wholeCatalogue = try await storage.library.sync(using: client)
            serverHasMusic = await storage.library.serverHasMusic()
            applyLimit()
            await storage.downloads.reconcile(with: wholeCatalogue)
            guard serverHasMusic, let profileID else { return }
            try await storage.personal.synchronise(profileID: profileID, using: client)
            try await storage.progress.synchronise(profileID: profileID, using: client)
            await reloadPersonal()
        } catch {
            // The films' refresh says what is wrong with the connection; music waits for the next.
        }
    }

    private func reloadPersonal() async {
        guard let storage, let profileID else {
            favourites = []
            playlists = []
            recentPlays = []
            bookProgress = [:]
            return
        }
        favourites = await storage.personal.favourites(profileID: profileID)
        playlists = await storage.personal.playlists(profileID: profileID)
        recentPlays = await storage.personal.recentPlays(profileID: profileID)
        bookProgress = await storage.progress.progress(profileID: profileID)
    }

    /// Sends listens and a book's place soon, without holding up what plays.
    func flushSoon() {
        guard let client, !serverIsOutOfReach, let storage, let profileID else { return }
        flushTask?.cancel()
        flushTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            try? await storage.progress.flush(using: client)
            try? await storage.personal.synchronise(profileID: profileID, using: client)
            await reloadPersonal()
        }
    }

    func signOut() async {
        player.stop()
        try? await storage?.clear()
        wholeCatalogue = MusicCatalogue()
        catalogue = MusicCatalogue()
        downloads = MusicDownloads.Snapshot()
        await reloadPersonal()
    }

    private func applyLimit() {
        catalogue = showsDownloadedOnly ? wholeCatalogue.limited(to: downloads.playableTrackIDs) : wholeCatalogue
    }

    // MARK: Reading

    func track(_ id: String) -> MusicTrack? { wholeCatalogue.tracks[id] }
    func album(_ id: String) -> MusicAlbum? { wholeCatalogue.albums[id] }
    func book(_ id: String) -> MusicBook? { wholeCatalogue.books[id] }
    func artist(_ id: String) -> MusicArtist? { wholeCatalogue.artists[id] }

    /// The tracks of an album that can play now.
    func tracks(ofAlbum id: String) -> [MusicTrack] { catalogue.tracks(ofAlbum: id) }

    /// A playlist's tracks that are in the library (and on the device, offline), in its order.
    func tracks(of playlist: MusicPlaylist) -> [MusicTrack] { playlist.trackIds.compactMap { catalogue.tracks[$0] } }

    /// Albums and books the viewer listened to, the latest first.
    var recentlyPlayed: [RecentlyPlayed] {
        var seen = Set<String>()
        var result: [RecentlyPlayed] = []
        for play in recentPlays {
            guard let track = catalogue.tracks[play.trackId] else { continue }
            if let id = track.albumId, let album = catalogue.albums[id], seen.insert(id).inserted {
                result.append(.album(album))
            } else if let id = track.bookId, let book = catalogue.books[id], seen.insert(id).inserted {
                result.append(.book(book))
            }
            if result.count == 20 { break }
        }
        return result
    }

    enum RecentlyPlayed: Hashable, Identifiable {
        case album(MusicAlbum)
        case book(MusicBook)

        var id: String {
            switch self {
            case .album(let album): album.id
            case .book(let book): book.id
            }
        }
    }

    var favouriteSongs: [MusicTrack] { catalogue.sortedSongs.filter { favourites.contains($0.id) } }
    var favouriteAlbums: [MusicAlbum] { catalogue.sortedAlbums.filter { favourites.contains($0.id) } }
    var favouriteArtists: [MusicArtist] { catalogue.sortedArtists.filter { favourites.contains($0.id) } }
    var favouriteBooks: [MusicBook] { catalogue.sortedBooks.filter { favourites.contains($0.id) } }

    /// 0…1 of a book, for this viewer. nil: not begun.
    func fractionHeard(of book: MusicBook) -> Double? {
        guard let progress = bookProgress[book.id], book.durationMs > 0 else { return nil }
        return progress.completed ? 1 : Double(progress.positionMs) / Double(book.durationMs)
    }

    func coverImage(_ coverID: String, pixelWidth: Int) async -> CGImage? {
        await coverLoader(.musicCover(coverID), pixelWidth)
    }

    /// The covers of what is downloaded, which stay on the device with it.
    var keptCovers: [Artwork] {
        let here = downloads.playableTrackIDs
        let ids = Set(here.compactMap { id in wholeCatalogue.tracks[id].flatMap { wholeCatalogue.coverID(of: $0) } })
        return ids.sorted().map(Artwork.musicCover)
    }

    // MARK: Playing

    func play(album: MusicAlbum, startAt index: Int = 0, shuffled: Bool = false) {
        player.play(trackIDs: tracks(ofAlbum: album.id).map(\.id), startAt: index, shuffled: shuffled)
    }

    func play(_ tracks: [MusicTrack], startAt index: Int = 0, shuffled: Bool = false) {
        player.play(trackIDs: tracks.map(\.id), startAt: index, shuffled: shuffled)
    }

    func localFile(trackID: String) async -> URL? {
        await storage?.downloads.localFile(trackID: trackID)
    }

    /// Where the sound of a track is fetched: the file itself where Apple plays it, else the
    /// server's copy, which it may have to make first (asked again until it is there).
    func streamURL(for track: MusicTrack, using client: LobbyClient) async throws -> URL {
        let compact = track.file.playability != .direct || (isOnExpensiveNetwork && track.file.compact.contains(256))
        if !compact { return client.musicContentURL(trackID: track.id) }
        var answer = try await client.musicPlayback(trackID: track.id, quality: .compact(256), purpose: .play)
        var asked = 1
        while answer.state == .queued || answer.state == .preparing {
            guard asked < 120 else { break }
            try await sleep(.milliseconds(500))
            answer = try await client.musicPlayback(trackID: track.id, quality: .compact(256), purpose: .play)
            asked += 1
        }
        guard answer.state == .ready, let path = answer.url, let url = client.musicURL(serverPath: path) else {
            throw LobbyError.unavailable(message: answer.message ?? "Lobby Server could not get this ready in time.")
        }
        return url
    }

    func recordPlay(_ play: MusicPlay) {
        guard let storage, let profileID else { return }
        recentPlays.insert(play, at: 0)
        Task { try? await storage.personal.record(play, profileID: profileID) }
    }

    func recordBookProgress(bookID: String, positionMs: Int, durationMs: Int?, completed: Bool) {
        guard let storage, let profileID else { return }
        Task {
            if let progress = try? await storage.progress.record(
                profileID: profileID, itemID: bookID, positionMs: positionMs, durationMs: durationMs, completed: completed) {
                bookProgress[bookID] = progress
            }
        }
    }

    // MARK: Favourites

    func isFavourite(_ id: String) -> Bool { favourites.contains(id) }

    func toggleFavourite(_ id: String, kind: MusicKind) {
        guard let storage, let profileID else { return }
        let now = !favourites.contains(id)
        if now { favourites.insert(id) } else { favourites.remove(id) }
        Task {
            try? await storage.personal.setFavourite(now, itemID: id, kind: kind, profileID: profileID)
            flushSoon()
        }
    }

    // MARK: Playlists

    /// Playlists change at the server, which keeps them for every device: not while it is out
    /// of reach.
    var canEditPlaylists: Bool { client != nil && !serverIsOutOfReach && profileID != nil }

    @discardableResult
    func createPlaylist(name: String, trackIDs: [String] = []) async -> MusicPlaylist? {
        await changePlaylist { client, profile in
            try await client.createMusicPlaylist(
                profileID: profile, id: UUID().uuidString.lowercased(), name: name, trackIDs: trackIDs)
        }
    }

    func rename(_ playlist: MusicPlaylist, to name: String) async {
        await changePlaylist { client, profile in
            try await client.updateMusicPlaylist(profileID: profile, id: playlist.id, revision: playlist.revision, name: name)
        }
    }

    /// The whole new order.
    func setTracks(_ trackIDs: [String], of playlist: MusicPlaylist) async {
        // Shown at once; the server's answer follows.
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) { playlists[index].trackIds = trackIDs }
        await changePlaylist { client, profile in
            try await client.updateMusicPlaylist(profileID: profile, id: playlist.id, revision: playlist.revision, trackIDs: trackIDs)
        }
    }

    func add(_ trackIDs: [String], to playlist: MusicPlaylist) async {
        await changePlaylist { client, profile in
            try await client.appendToMusicPlaylist(
                profileID: profile, id: playlist.id, opID: UUID().uuidString.lowercased(), trackIDs: trackIDs)
        }
    }

    func delete(_ playlist: MusicPlaylist) async {
        guard let client, let profileID, let storage else { return }
        do {
            try await client.deleteMusicPlaylist(profileID: profileID, id: playlist.id, revision: playlist.revision)
            try await storage.personal.forgetPlaylist(id: playlist.id, profileID: profileID)
            await storage.downloads.remove(collectionID: playlist.id)
        } catch {
            problem = Self.describe(error, about: "The playlist")
        }
        await reloadPersonal()
    }

    @discardableResult
    private func changePlaylist(_ change: (LobbyClient, String) async throws -> MusicPlaylist) async -> MusicPlaylist? {
        guard let client, let profileID, let storage, canEditPlaylists else {
            problem = "Playlists change while Lobby Server is in reach."
            return nil
        }
        do {
            let playlist = try await change(client, profileID)
            try await storage.personal.keep(playlist, profileID: profileID)
            await reloadPersonal()
            // A downloaded playlist follows its new tracks.
            if downloads.contains(playlist.id) { downloadPlaylist(playlist) }
            return playlist
        } catch LobbyError.conflict {
            problem = "This playlist was changed on another device. Here it is as it is now."
            try? await storage.personal.synchronise(profileID: profileID, using: client)
            await reloadPersonal()
        } catch {
            problem = Self.describe(error, about: "The playlist")
        }
        return nil
    }

    private static func describe(_ error: any Error, about thing: String) -> String {
        "\(thing) could not be changed. \((error as? LobbyError)?.localizedDescription ?? error.localizedDescription)"
    }

    // MARK: Downloads

    func download(_ album: MusicAlbum) {
        let tracks = wholeCatalogue.tracks(ofAlbum: album.id)
        keep(.init(id: album.id, kind: .album, title: album.title, trackIDs: tracks.map(\.id)), tracks)
    }

    func downloadPlaylist(_ playlist: MusicPlaylist) {
        let tracks = playlist.trackIds.compactMap { wholeCatalogue.tracks[$0] }
        keep(.init(id: playlist.id, kind: .playlist, title: playlist.name, trackIDs: tracks.map(\.id)), tracks)
    }

    func download(_ book: MusicBook) {
        let tracks = wholeCatalogue.tracks(ofBook: book.id)
        keep(.init(id: book.id, kind: .book, title: book.title, trackIDs: tracks.map(\.id)), tracks)
    }

    private func keep(_ collection: MusicDownloads.Collection, _ tracks: [MusicTrack]) {
        guard let downloads = storage?.downloads else { return }
        Task { await downloads.keep(collection, tracks: tracks) }
    }

    func removeDownload(_ collectionID: String) {
        guard let downloads = storage?.downloads else { return }
        Task { await downloads.remove(collectionID: collectionID) }
    }

    func retryDownloads() {
        guard let downloads = storage?.downloads else { return }
        Task { await downloads.retryFailed() }
    }

    func setDownloadsUseMobileData(_ allowed: Bool) {
        guard let downloads = storage?.downloads else { return }
        Task { await downloads.setAllowsCellular(allowed) }
    }

    func setOnMobileData(_ on: Bool) {
        isOnExpensiveNetwork = on
        guard let downloads = storage?.downloads else { return }
        Task { await downloads.setOnMobileData(on) }
    }

    /// How a collection's download is doing, for its button.
    func downloadState(of collectionID: String) -> DownloadState {
        guard downloads.contains(collectionID) else { return .none }
        let (done, total) = downloads.progress(of: collectionID)
        if total > 0, done == total { return .done }
        if downloads.isWaitingForWiFi { return .waitingForWiFi(done: done, total: total) }
        let ids = downloads.collections.first { $0.id == collectionID }?.trackIDs ?? []
        if ids.contains(where: { downloads.records[$0]?.state == .failed }) { return .failed(done: done, total: total) }
        return .downloading(done: done, total: total)
    }

    enum DownloadState: Hashable {
        case none
        case downloading(done: Int, total: Int)
        case waitingForWiFi(done: Int, total: Int)
        case failed(done: Int, total: Int)
        case done
    }
}
