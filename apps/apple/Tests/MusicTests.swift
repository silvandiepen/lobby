// SPDX-License-Identifier: MPL-2.0
import AVFoundation
import Foundation
import LobbyKit
import MediaPlayer
import Testing

@testable import Lobby

/// What the lock screen is told, how loud a song plays, and how lengths are written.
@Suite struct MusicPresentationTests {
    @Test func theLockScreenHasTheSongTheTimeAndThePlace() {
        var description = NowPlayingDescription(
            title: "Glass Buoys", artist: "The Paper Lanterns", collection: "Harbour Lights", durationSeconds: 32,
            elapsedSeconds: 12.5, rate: 1, queueIndex: 1, queueCount: 4)
        var info = description.info
        #expect(info[MPMediaItemPropertyTitle] as? String == "Glass Buoys")
        #expect(info[MPMediaItemPropertyArtist] as? String == "The Paper Lanterns")
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "Harbour Lights")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 32)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 12.5)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        #expect(info[MPNowPlayingInfoPropertyPlaybackQueueIndex] as? Int == 1)
        #expect(info[MPNowPlayingInfoPropertyPlaybackQueueCount] as? Int == 4)
        #expect(info[MPNowPlayingInfoPropertyChapterNumber] == nil)

        // Paused, in a book read faster, in its third chapter, without a known length.
        description.rate = 0
        description.defaultRate = 1.5
        description.durationSeconds = nil
        description.isBook = true
        description.chapter = (2, 5)
        info = description.info
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double == 1.5)
        #expect(info[MPMediaItemPropertyPlaybackDuration] == nil)
        #expect(info[MPNowPlayingInfoPropertyChapterNumber] as? Int == 2)
        #expect(info[MPNowPlayingInfoPropertyChapterCount] as? Int == 5)
    }

    @Test func loudSongsPlayQuieterAndNothingClips() {
        #expect(VolumeMatching.volume(for: nil, preferAlbum: false) == 1)
        // -6 dB is about half.
        let half = VolumeMatching.volume(for: ReplayGain(trackGainDb: -6.02), preferAlbum: false)
        #expect(abs(half - 0.5) < 0.01)
        // A quiet song is not made louder than its file.
        #expect(VolumeMatching.volume(for: ReplayGain(trackGainDb: 4), preferAlbum: false) == 1)
        // In album order the album's gain counts.
        let gain = ReplayGain(trackGainDb: -9, albumGainDb: -3)
        #expect(VolumeMatching.volume(for: gain, preferAlbum: true) > VolumeMatching.volume(for: gain, preferAlbum: false))
        // A peak above full scale lowers it further.
        #expect(VolumeMatching.volume(for: ReplayGain(trackGainDb: 0, trackPeak: 1.25), preferAlbum: false) == 0.8)
    }

    @Test func lengthsAsAPlayerWritesThem() {
        #expect(MusicTime.short(187_000) == "3:07")
        #expect(MusicTime.clock(3_765) == "1:02:45")
        #expect(MusicTime.clock(.nan) == "0:00")
        #expect(MusicTime.long(180_000) == "3 min")
        #expect(MusicTime.long(11_100_000) == "3 h 5 min")
    }
}

/// The Lobby Server that `Scripts/ui-test-server.sh` started, with its invented music library
/// (`tools/music-sample`).
struct MusicTestServer: Decodable {
    var url: URL
    var managerToken: String

    static let paired: MusicTestServer? = {
        struct File: Decodable { var paired: MusicTestServer }
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/ui-test-server/server.json")
        return (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(File.self, from: $0).paired }
    }()
}

/// The music against a real Lobby Server on this Mac, with the real player: browsing, the
/// queue in sound, what the lock screen shows, listens and books that reach the server,
/// favourites and playlists, and an album downloaded and played without the server.
@MainActor
@Suite(.serialized, .enabled(if: MusicTestServer.paired != nil, "Run Scripts/ui-test-server.sh start first."))
struct MusicRealServerTests {
    let server = MusicTestServer.paired!

    /// A device paired with the server as a viewer, watching as "Alex", with music synced.
    private func pairedApp(_ test: TestApp, musicDirectory: URL) async throws -> AppModel {
        var environment = test.environment
        environment.session = .shared
        environment.locateGrace = {}
        environment.sleep = { try await Task.sleep(for: $0) }
        environment.music = MusicStorage(directory: musicDirectory)
        test.environment = environment
        let app = AppModel(environment: environment)
        await app.start()
        let connect = ConnectModel(app: app)
        connect.enterAddress()
        connect.addressText = server.url.absoluteString
        await connect.findServer()
        await connect.requestCode()
        guard case .code(let request, _) = connect.step else {
            Issue.record("No code: \(String(describing: connect.problem))")
            throw CancellationError()
        }
        _ = try await LobbyClient(baseURL: server.url, token: server.managerToken).approvePairing(code: request.code, role: .viewer)
        await connect.waitUntilPaired()
        await app.selectProfile(try #require(app.profiles.first { $0.name == "Alex" }))
        await app.refresh()
        return app
    }

    private func until(_ what: String, timeout: Double = 20, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end {
                Issue.record("Waited \(Int(timeout)) s for: \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func browsePlayAndMoveThroughTheQueue() async throws {
        let test = try TestApp()
        let folder = FileManager.default.temporaryDirectory.appending(path: "music-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = try await pairedApp(test, musicDirectory: folder)
        let music = app.music
        let player = music.player
        defer { player.stop() }

        #expect(music.isAvailable)
        #expect(music.catalogue.sortedAlbums.map(\.title) == ["Harbour Lights", "Morning Tram", "Northern Lines", "Static Orchard"])
        let harbour = try #require(music.catalogue.sortedAlbums.first { $0.title == "Harbour Lights" })
        #expect(music.tracks(ofAlbum: harbour.id).map(\.title) == ["Low Tide Signal", "Glass Buoys", "Copper Gulls", "Night Ferry"])
        #expect(music.catalogue.search("calloway").albums.map(\.title) == ["Static Orchard"])

        // An album from its second song: it sounds, and the lock screen knows it.
        music.play(album: harbour, startAt: 1)
        try await until("the second song plays") { player.isPlaying && !player.isLoading && player.elapsed > 1 }
        #expect(player.currentTrack?.title == "Glass Buoys")
        #expect(!player.isPlayingFromDevice)
        let now = try #require(player.nowPlaying)
        #expect(now.title == "Glass Buoys")
        #expect(now.artist == "The Paper Lanterns")
        #expect(now.collection == "Harbour Lights")
        #expect(now.queueIndex == 1)
        #expect(now.queueCount == 4)
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Glass Buoys")

        // Next, back to the start of the song, and back to the one before.
        player.next()
        // Past three seconds, back is the start of the song itself.
        try await until("the third song plays") { player.currentTrack?.title == "Copper Gulls" && player.isPlaying && player.elapsed > 3.3 }
        player.previous()
        try await until("back at its start") { player.elapsed < 1 }
        #expect(player.currentTrack?.title == "Copper Gulls")
        player.previous()
        try await until("the second again") { player.currentTrack?.title == "Glass Buoys" }

        // Shuffle keeps what plays; repeat one; pause.
        player.setShuffled(true)
        #expect(player.currentTrack?.title == "Glass Buoys")
        #expect(player.queue.index == 0)
        player.setShuffled(false)
        #expect(player.queue.entries.map { music.track($0.trackID)?.title } == ["Low Tide Signal", "Glass Buoys", "Copper Gulls", "Night Ferry"])
        player.setRepeat(.one)
        #expect(player.queue.following()?.trackID == player.currentTrack?.id)
        player.setRepeat(.off)
        player.pause()
        #expect(!player.isPlaying)
        #expect(player.nowPlaying?.rate == 0)

        // A song Apple does not play (Opus): the server's copy plays.
        let lines = try #require(music.catalogue.sortedAlbums.first { $0.title == "Northern Lines" })
        music.play(album: lines)
        try await until("the converted song plays", timeout: 60) { player.isPlaying && !player.isLoading && player.elapsed > 1 }
        #expect(player.currentTrack?.file.playability == .convert)
    }

    @Test func aSongPlayedToItsEndIsCountedAndTheNextFollowsWithoutAGap() async throws {
        let test = try TestApp()
        let folder = FileManager.default.temporaryDirectory.appending(path: "music-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = try await pairedApp(test, musicDirectory: folder)
        let music = app.music
        let player = music.player
        defer { player.stop() }
        let tram = try #require(music.catalogue.sortedAlbums.first { $0.title == "Morning Tram" })
        let tracks = music.tracks(ofAlbum: tram.id)

        // Near the end of the first song: the second is ready behind it and takes over.
        music.play(album: tram)
        try await until("the first song plays") { player.isPlaying && !player.isLoading && player.elapsed > 0.5 }
        player.seek(to: Double(tracks[0].durationMs ?? 25_000) / 1000 - 2)
        try await until("the second song", timeout: 15) { player.currentTrack?.id == tracks[1].id && player.elapsed > 0.2 }
        #expect(player.isPlaying)

        // The listen counts, here and at the server.
        try await until("the listen is kept") { music.recentPlays.contains { $0.trackId == tracks[0].id && $0.completed } }
        player.pause()
        await app.refresh()
        let client = try LobbyClient(baseURL: server.url, token: server.managerToken)
        let alex = try #require(app.activeProfile)
        let plays = try await client.musicPlays(profileID: alex.id, limit: 20)
        #expect(plays.contains { $0.trackId == tracks[0].id && $0.completed })
        #expect(music.recentlyPlayed.first?.id == tram.id)
    }

    @Test func aBookResumesWhereItWasWithChaptersAndSpeed() async throws {
        let test = try TestApp()
        let folder = FileManager.default.temporaryDirectory.appending(path: "music-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = try await pairedApp(test, musicDirectory: folder)
        let music = app.music
        let player = music.player
        defer { player.stop() }
        let book = try #require(music.catalogue.sortedBooks.first)
        #expect(book.chapters.count == 5)

        // The third chapter, read faster.
        player.play(book: book, chapter: 2)
        try await until("the third chapter plays") { player.isPlaying && !player.isLoading && (player.bookPositionMs ?? 0) > 72_500 }
        #expect(player.currentChapterIndex == 2)
        #expect(player.nowPlaying?.chapter?.index == 2)
        #expect(player.nowPlaying?.title.hasPrefix("A Storm from the West") == true)
        player.setRate(1.5)
        #expect(player.nowPlaying?.defaultRate == 1.5)
        player.next()
        try await until("the fourth chapter") { player.currentChapterIndex == 3 }
        player.skip(by: 30)
        try await until("thirty seconds on") { (player.bookPositionMs ?? 0) >= 138_000 }
        player.pause()
        let kept = try #require(player.bookPositionMs)
        music.setRate(back: 1)

        // The place reaches the server: another device, or this one later, resumes there.
        try await until("the place is kept") { (music.bookProgress[book.id]?.positionMs ?? 0) >= kept - 1_000 }
        await app.refresh()
        let client = try LobbyClient(baseURL: server.url, token: server.managerToken)
        let atServer = try await client.musicProgress(profileID: try #require(app.activeProfile).id)
        let resumed = try #require(atServer.progress.first { $0.itemId == book.id })
        #expect(abs(resumed.positionMs - kept) < 2_000)
        player.play(book: book)
        try await until("it resumes") { !player.isLoading && player.bookPositionMs != nil }
        #expect(abs((player.bookPositionMs ?? 0) - kept) < 2_000)
    }

    @Test func favouritesAndPlaylistsAreTheViewersOnEveryDevice() async throws {
        let test = try TestApp()
        let folder = FileManager.default.temporaryDirectory.appending(path: "music-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = try await pairedApp(test, musicDirectory: folder)
        let music = app.music
        let songs = music.catalogue.sortedSongs
        let orchard = try #require(music.catalogue.sortedAlbums.first { $0.title == "Static Orchard" })

        let wasFavourite = music.isFavourite(orchard.id)
        music.toggleFavourite(orchard.id, kind: .album)
        #expect(music.isFavourite(orchard.id) != wasFavourite)
        try await Task.sleep(for: .seconds(3))
        await app.refresh()
        #expect(music.isFavourite(orchard.id) != wasFavourite)

        let name = "Test \(UUID().uuidString.prefix(6))"
        let made = try #require(await music.createPlaylist(name: name, trackIDs: [songs[0].id, songs[1].id]))
        await music.add([songs[2].id], to: made)
        var playlist = try #require(music.playlists.first { $0.id == made.id })
        #expect(playlist.trackIds == [songs[0].id, songs[1].id, songs[2].id])
        await music.setTracks([songs[2].id, songs[0].id], of: playlist)
        playlist = try #require(music.playlists.first { $0.id == made.id })
        #expect(playlist.trackIds == [songs[2].id, songs[0].id])
        await music.rename(playlist, to: name + " renamed")
        playlist = try #require(music.playlists.first { $0.id == made.id })
        #expect(playlist.name == name + " renamed")

        // A stale revision is the server's conflict: the playlist is shown as it is now.
        await music.setTracks([songs[1].id], of: made)
        #expect(music.problem?.contains("another device") == true)
        music.problem = nil
        #expect(music.playlists.first { $0.id == made.id }?.trackIds == [songs[2].id, songs[0].id])

        await music.delete(try #require(music.playlists.first { $0.id == made.id }))
        #expect(!music.playlists.contains { $0.id == made.id })
    }

    @Test func aDownloadedAlbumPlaysWithoutTheServer() async throws {
        let test = try TestApp()
        let folder = FileManager.default.temporaryDirectory.appending(path: "music-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = try await pairedApp(test, musicDirectory: folder)
        let music = app.music
        let player = music.player
        defer { player.stop() }
        let lines = try #require(music.catalogue.sortedAlbums.first { $0.title == "Northern Lines" })
        let harbour = try #require(music.catalogue.sortedAlbums.first { $0.title == "Harbour Lights" })

        // Opus arrives as the server's AAC copy; the rest as it is.
        music.download(lines)
        music.download(harbour)
        try await until("both are on the device", timeout: 120) {
            music.downloadState(of: lines.id) == .done && music.downloadState(of: harbour.id) == .done
        }
        #expect(music.downloads.collections.count == 2)
        let copy = try #require(await music.localFile(trackID: music.tracks(ofAlbum: lines.id)[0].id))
        #expect(copy.pathExtension == "m4a")
        let flac = try #require(await music.localFile(trackID: music.tracks(ofAlbum: harbour.id)[0].id))
        #expect(flac.pathExtension == "flac")

        // Only what is here, in the same screens.
        await app.setDownloadedOnly(true)
        #expect(Set(music.catalogue.albums.keys) == [lines.id, harbour.id])
        #expect(music.catalogue.books.isEmpty)

        // With the server gone, it plays from the device.
        music.setConnection(nil, outOfReach: true)
        music.play(album: lines)
        try await until("the copy plays") { player.isPlaying && !player.isLoading && player.elapsed > 0.5 }
        #expect(player.isPlayingFromDevice)

        // Removing one keeps the other.
        player.stop()
        music.removeDownload(lines.id)
        try await until("it is gone") { !music.downloads.contains(lines.id) }
        #expect(await music.localFile(trackID: music.tracks(ofAlbum: harbour.id)[0].id) != nil)
        await app.setDownloadedOnly(false)
    }
}

private extension MusicModel {
    /// Books read at the usual speed again, for the tests after.
    func setRate(back rate: Float) { bookRate = rate }
}
