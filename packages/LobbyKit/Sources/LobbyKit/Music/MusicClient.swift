// SPDX-License-Identifier: MPL-2.0
import Foundation

// `/v1/music`, as `docs/api.md` ("Music and audiobooks") describes it.

extension LobbyClient {
    // MARK: The library

    /// `GET /v1/music/library`: one page. `MusicLibraryStore.sync(using:)` drives the paging.
    ///
    /// Throws `.notFound` on a server without music, and for a kids device: there are no
    /// limits for music yet, so it has none.
    public func musicLibrary(cursor: String?, limit: Int? = nil) async throws -> MusicLibraryPage {
        var query: [URLQueryItem] = []
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await get(["music", "library"], query: query)
    }

    /// `GET /v1/music/albums/{id}`.
    public func musicAlbum(id: String) async throws -> (album: MusicAlbum, tracks: [MusicTrack]) {
        struct Answer: Decodable {
            var album: MusicAlbum
            var tracks: [MusicTrack]
        }
        let answer: Answer = try await get(["music", "albums", id])
        return (answer.album, answer.tracks)
    }

    /// `GET /v1/music/books/{id}`.
    public func musicBook(id: String) async throws -> (book: MusicBook, tracks: [MusicTrack]) {
        struct Answer: Decodable {
            var book: MusicBook
            var tracks: [MusicTrack]
        }
        let answer: Answer = try await get(["music", "books", id])
        return (answer.book, answer.tracks)
    }

    /// `GET /v1/music/covers/{coverId}?w=`: a JPEG at most `width` wide. Cache it forever.
    public func musicCoverURL(_ coverID: String, width: Int) -> URL {
        let sizes = [200, 400, 800, 1600]
        let size = sizes.first { $0 >= width } ?? 1600
        return url(["music", "covers", coverID], query: [URLQueryItem(name: "w", value: String(size))])
    }

    // MARK: Sound

    /// `/v1/music/tracks/{id}/content`: the file exactly as on the drive, with `Range`. For
    /// AVPlayer pass `deviceCookie()`.
    public func musicContentURL(trackID: String) -> URL {
        url(["music", "tracks", trackID, "content"])
    }

    /// `POST /v1/music/tracks/{id}/playback`: says what to fetch. `202` (queued, preparing) is
    /// an answer like any other here: ask again about once a second.
    public func musicPlayback(trackID: String, quality: MusicQuality = .original, purpose: MusicPurpose = .play) async throws -> MusicPlayback {
        var request = request("POST", ["music", "tracks", trackID, "playback"])
        request.httpBody = Data(#"{"quality":\#(quality.json),"purpose":"\#(purpose.rawValue)"}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await perform(request)
        return try decode(data)
    }

    /// A path from `MusicPlayback.url`, on this server.
    public func musicURL(serverPath: String) -> URL? {
        resolve(serverPath: serverPath)
    }

    // MARK: What viewers keep

    private func musicViewer(_ profileID: String, _ rest: String...) -> [String] {
        ["music", "profiles", profileID] + rest
    }

    /// `GET …/favourites?since=`.
    public func musicFavourites(profileID: String, since: Int? = nil) async throws -> (favourites: [MusicFavourite], revision: Int) {
        struct Answer: Decodable {
            var favourites: [MusicFavourite]
            var revision: Int
        }
        let query = since.map { [URLQueryItem(name: "since", value: String($0))] } ?? []
        let answer: Answer = try await get(musicViewer(profileID, "favourites"), query: query)
        return (answer.favourites, answer.revision)
    }

    /// `PUT …/favourites/{itemId}`. A later change on another device wins: `.conflict`.
    public func setMusicFavourite(profileID: String, itemID: String, favourite: Bool, updatedAt: Date) async throws -> Bool {
        struct Body: Encodable {
            var favourite: Bool
            var updatedAt: Date
        }
        struct Answer: Decodable { var favourite: Bool }
        let answer: Answer = try await send(
            "PUT", musicViewer(profileID, "favourites", itemID), body: Body(favourite: favourite, updatedAt: updatedAt))
        return answer.favourite
    }

    /// `GET …/playlists?since=`.
    public func musicPlaylists(profileID: String, since: Int? = nil) async throws -> (playlists: [MusicPlaylist], removed: [String], revision: Int) {
        struct Answer: Decodable {
            var playlists: [MusicPlaylist]
            var removed: [String]
            var revision: Int
        }
        let query = since.map { [URLQueryItem(name: "since", value: String($0))] } ?? []
        let answer: Answer = try await get(musicViewer(profileID, "playlists"), query: query)
        return (answer.playlists, answer.removed, answer.revision)
    }

    private struct PlaylistAnswer: Decodable { var playlist: MusicPlaylist }

    /// `POST …/playlists`. The device makes the id, so a retry is the same playlist.
    public func createMusicPlaylist(profileID: String, id: String, name: String, trackIDs: [String]) async throws -> MusicPlaylist {
        struct Body: Encodable {
            var id: String
            var name: String
            var trackIds: [String]
        }
        let answer: PlaylistAnswer = try await send(
            "POST", musicViewer(profileID, "playlists"), body: Body(id: id, name: name, trackIds: trackIDs))
        return answer.playlist
    }

    /// `PATCH …/playlists/{id}`: a new name, or the whole new order. `.conflict` when another
    /// device was first.
    public func updateMusicPlaylist(
        profileID: String, id: String, revision: Int, name: String? = nil, trackIDs: [String]? = nil
    ) async throws -> MusicPlaylist {
        struct Body: Encodable {
            var revision: Int
            var name: String?
            var trackIds: [String]?
        }
        let answer: PlaylistAnswer = try await send(
            "PATCH", musicViewer(profileID, "playlists", id), body: Body(revision: revision, name: name, trackIds: trackIDs))
        return answer.playlist
    }

    /// `POST …/playlists/{id}/tracks`: adds to the end, never a conflict.
    public func appendToMusicPlaylist(profileID: String, id: String, opID: String, trackIDs: [String]) async throws -> MusicPlaylist {
        struct Body: Encodable {
            var opId: String
            var trackIds: [String]
        }
        let answer: PlaylistAnswer = try await send(
            "POST", musicViewer(profileID, "playlists", id, "tracks"), body: Body(opId: opID, trackIds: trackIDs))
        return answer.playlist
    }

    /// `DELETE …/playlists/{id}?revision=`.
    public func deleteMusicPlaylist(profileID: String, id: String, revision: Int) async throws {
        let request = request(
            "DELETE", musicViewer(profileID, "playlists", id),
            query: [URLQueryItem(name: "revision", value: String(revision))])
        _ = try await perform(request)
    }

    /// `POST …/plays`, at most 500 at once. The same `opId` counts once.
    @discardableResult
    public func addMusicPlays(profileID: String, _ plays: [MusicPlay]) async throws -> (accepted: Int, unknown: Int) {
        struct Body: Encodable { var plays: [MusicPlay] }
        struct Answer: Decodable {
            var accepted: Int
            var unknown: Int
        }
        let answer: Answer = try await send("POST", musicViewer(profileID, "plays"), body: Body(plays: plays))
        return (answer.accepted, answer.unknown)
    }

    /// `GET …/plays?limit=`: the newest first.
    public func musicPlays(profileID: String, limit: Int = 100) async throws -> [MusicPlay] {
        struct Answer: Decodable { var plays: [MusicPlay] }
        let answer: Answer = try await get(
            musicViewer(profileID, "plays"), query: [URLQueryItem(name: "limit", value: String(limit))])
        return answer.plays
    }

    /// `GET …/progress?since=`: where a viewer is in books and long tracks.
    public func musicProgress(profileID: String, since: Int? = nil) async throws -> ProgressList {
        let query = since.map { [URLQueryItem(name: "since", value: String($0))] } ?? []
        return try await get(musicViewer(profileID, "progress"), query: query)
    }

    /// `PUT …/progress/{itemId}`, by the same rules as a film's.
    public func putMusicProgress(profileID: String, itemID: String, update: ProgressUpdate) async throws -> PlaybackProgress {
        struct Answer: Decodable { var progress: PlaybackProgress }
        let answer: Answer = try await send("PUT", musicViewer(profileID, "progress", itemID), body: update)
        return answer.progress
    }
}

extension Artwork {
    private static let musicCoverPrefix = "music-cover:"

    /// A music cover, as an artwork: it loads, is kept and gives its colours like a poster.
    public static func musicCover(_ coverID: String) -> Artwork {
        Artwork(id: musicCoverPrefix + coverID, width: 1, height: 1)
    }

    /// The cover's id on the server, for a music cover.
    public var musicCoverID: String? {
        id.hasPrefix(Self.musicCoverPrefix) ? String(id.dropFirst(Self.musicCoverPrefix.count)) : nil
    }
}
