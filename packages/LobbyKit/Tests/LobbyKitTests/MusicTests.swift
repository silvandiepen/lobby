// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing

@testable import LobbyKit

/// The music's models, catalogue and queue. The `music-*.json` files in `Captured/` came from
/// `apps/server` over the invented library of `tools/music-sample/make-library.sh`, unedited.
@Suite struct MusicDecodingTests {
    func captured(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Captured"))
        return try Data(contentsOf: url)
    }

    @Test func theLibraryAsTheServerSendsIt() throws {
        let page = try LobbyJSON.decoder().decode(MusicLibraryPage.self, from: captured("music-library"))
        #expect(page.albums.count == 4)
        #expect(page.tracks.count == 15)
        #expect(page.books.count == 1)
        #expect(!page.more)

        var catalogue = MusicCatalogue()
        catalogue.apply(page)
        let harbour = try #require(catalogue.sortedAlbums.first { $0.title == "Harbour Lights" })
        #expect(catalogue.tracks(ofAlbum: harbour.id).map(\.title) == ["Low Tide Signal", "Glass Buoys", "Copper Gulls", "Night Ferry"])
        #expect(catalogue.tracks(ofAlbum: harbour.id).first?.replayGain?.trackGainDb == -3.4)
        let lines = try #require(catalogue.albums.values.first { $0.title == "Northern Lines" })
        #expect(lines.compilation)
        #expect(catalogue.tracks(ofAlbum: lines.id).allSatisfy { $0.file.playability == .convert })
        let opus = try #require(catalogue.tracks(ofAlbum: lines.id).first)
        #expect(opus.file.compact == [256, 128])

        let book = try #require(catalogue.sortedBooks.first)
        #expect(book.authors == ["Ada Penhallow"])
        #expect(book.narrators == ["Tom Wren"])
        #expect(book.chapters.map(\.title) == ["Opening Credits", "The Lamp Room", "A Storm from the West", "Seven Fishing Boats", "Morning, at Last"])
        #expect(book.chapterIndex(atBookMs: 80_000) == 2)
        #expect(book.place(atBookMs: 100_000)?.trackMs == 100_000)
        // A book's file is no song.
        #expect(!catalogue.sortedSongs.contains { $0.bookId != nil })
        #expect(catalogue.sortedSongs.count == 14)

        // A guest on one track has that album among theirs.
        let guest = try #require(catalogue.artists.values.first { $0.name == "Oskar Lunde" })
        #expect(catalogue.albums(ofArtist: guest.id).map(\.title) == ["Static Orchard"])
        #expect(catalogue.appearances(ofArtist: guest.id).map(\.title) == ["Static Orchard"])

        // The covers of tracks are their album's.
        #expect(catalogue.coverID(of: opus) == lines.coverId)
        #expect(catalogue.search("orchard noon").songs.map(\.title) == ["Orchard at Noon"])
        #expect(catalogue.search("penhallow").books.count == 1)
        #expect(catalogue.search("KETTLE").albums.map(\.title) == ["Morning Tram"])
    }

    @Test func playbackPlaylistsFavouritesAndPlays() throws {
        let decoder = LobbyJSON.decoder()
        let direct = try decoder.decode(MusicPlayback.self, from: captured("music-playback-direct"))
        #expect(direct.state == .ready)
        #expect(!direct.isCopy)
        #expect(direct.url?.hasSuffix("/content") == true)
        let copy = try decoder.decode(MusicPlayback.self, from: captured("music-playback-copy"))
        #expect(copy.isCopy)
        #expect(copy.kbps == 256)

        struct Playlists: Decodable { var playlists: [MusicPlaylist] }
        let playlist = try #require(try decoder.decode(Playlists.self, from: captured("music-playlists")).playlists.first)
        #expect(playlist.name == "Rainy Sunday")
        #expect(playlist.trackIds.count == 3)
        #expect(playlist.trackIds[0] == playlist.trackIds[2])

        struct Favourites: Decodable { var favourites: [MusicFavourite] }
        #expect(try decoder.decode(Favourites.self, from: captured("music-favourites")).favourites.first?.kind == .track)
        struct Plays: Decodable { var plays: [MusicPlay] }
        #expect(try decoder.decode(Plays.self, from: captured("music-plays")).plays.first?.completed == true)
    }

    @Test func aDownloadedCopyKeepsAnExtensionThatPlays() {
        func file(_ container: String) -> MusicFile { MusicFile(revision: "r", sizeBytes: 1, container: container, codec: "x") }
        #expect(file("flac").fileExtension == "flac")
        #expect(file("mp3").fileExtension == "mp3")
        #expect(file("mp4").fileExtension == "m4a")
        #expect(MusicDownloads.safeName("abc-123") == "abc-123")
        #expect(MusicDownloads.safeName("../x") != "../x")
        #expect(!MusicDownloads.safeName("../x").contains("/"))
    }

    @Test func whatCountsAsAListen() {
        #expect(MusicPlay.judge(listenedMs: 5_000, durationMs: 200_000, reachedEnd: false) == nil)
        #expect(MusicPlay.judge(listenedMs: 40_000, durationMs: 200_000, reachedEnd: false) == false)
        #expect(MusicPlay.judge(listenedMs: 100_000, durationMs: 200_000, reachedEnd: false) == true)
        #expect(MusicPlay.judge(listenedMs: 240_000, durationMs: 3_600_000, reachedEnd: false) == true)
        #expect(MusicPlay.judge(listenedMs: 12_000, durationMs: 20_000, reachedEnd: false) == true)
        #expect(MusicPlay.judge(listenedMs: 1_000, durationMs: 20_000, reachedEnd: true) == true)
    }
}

@Suite struct MusicQueueTests {
    let ids = ["a", "b", "c", "d", "e"]

    @Test func playsInOrderAndStopsAtTheEnd() {
        var queue = MusicQueue(trackIDs: ids, startAt: 1)
        #expect(queue.current?.trackID == "b")
        #expect(queue.upNext.map(\.trackID) == ["c", "d", "e"])
        #expect(queue.history.map(\.trackID) == ["a"])
        #expect(queue.following()?.trackID == "c")
        queue.advance()
        queue.advance()
        queue.advance()
        #expect(queue.current?.trackID == "e")
        #expect(queue.following() == nil)
        #expect(queue.advance() == nil)
        #expect(queue.current == nil)
        // Back after the end: the last one.
        #expect(queue.skipBack()?.trackID == "e")
    }

    @Test func repeatOneAndAll() {
        var queue = MusicQueue(trackIDs: ids, startAt: 4)
        queue.repeatMode = .one
        #expect(queue.following()?.trackID == "e")
        #expect(queue.advance()?.trackID == "e")
        // The listener's next goes on, also with repeat one; at the end of the queue that is nothing.
        #expect(queue.skipForward() == nil)

        queue = MusicQueue(trackIDs: ids, startAt: 4)
        queue.repeatMode = .all
        #expect(queue.following()?.trackID == "a")
        #expect(queue.advance()?.trackID == "a")
        #expect(queue.skipBack()?.trackID == "e")
        #expect(MusicQueue.Repeat.off.next == .all)
        #expect(MusicQueue.Repeat.all.next == .one)
        #expect(MusicQueue.Repeat.one.next == .off)
    }

    @Test func shuffleKeepsWhatPlaysAndComesBackToTheOrder() {
        var queue = MusicQueue(trackIDs: ids, startAt: 2, seed: 42)
        queue.setShuffled(true)
        #expect(queue.isShuffled)
        #expect(queue.current?.trackID == "c")
        #expect(queue.index == 0)
        #expect(Set(queue.upNext.map(\.trackID)) == ["a", "b", "d", "e"])
        // The same seed, the same order.
        var again = MusicQueue(trackIDs: ids, startAt: 2, seed: 42)
        again.setShuffled(true)
        #expect(again.entries.map(\.trackID) == queue.entries.map(\.trackID))

        queue.advance()
        let playing = queue.current
        queue.setShuffled(false)
        #expect(queue.entries.map(\.trackID) == ids)
        #expect(queue.current == playing)
    }

    @Test func shuffleAndRepeatAllNeverRepeatsTheLastOneFirst() {
        for seed in UInt64(1)...40 {
            var queue = MusicQueue(trackIDs: ids, shuffled: true, seed: seed)
            queue.repeatMode = .all
            for _ in 0..<4 { queue.advance() }
            let last = queue.current
            let first = queue.advance()
            #expect(first != last)
            #expect(queue.entries.count == ids.count)
            #expect(queue.index == 0)
        }
    }

    @Test func playNextAddMoveAndRemove() {
        var queue = MusicQueue(trackIDs: ["a", "b", "c"])
        queue.playNext(["x"])
        #expect(queue.upNext.map(\.trackID) == ["x", "b", "c"])
        queue.add(["y"])
        #expect(queue.upNext.map(\.trackID) == ["x", "b", "c", "y"])
        // The last of Up Next to the top, as a list's drag gives it.
        queue.moveUpNext(fromOffsets: [3], toOffset: 0)
        #expect(queue.upNext.map(\.trackID) == ["y", "x", "b", "c"])
        queue.moveUpNext(fromOffsets: [0], toOffset: 4)
        #expect(queue.upNext.map(\.trackID) == ["x", "b", "c", "y"])

        // The same track twice: each entry is its own.
        queue.add(["b"])
        let second = queue.entries.last!
        queue.remove(entryID: second.id)
        #expect(queue.upNext.map(\.trackID) == ["x", "b", "c", "y"])

        // Removing what plays makes the next one current.
        queue.remove(entryID: queue.current!.id)
        #expect(queue.current?.trackID == "x")
        queue.clearUpNext()
        #expect(queue.entries.map(\.trackID) == ["x"])

        var empty = MusicQueue()
        #expect(empty.current == nil)
        empty.playNext(["z"])
        #expect(empty.current?.trackID == "z")
    }

    @Test func jumpAndAddWhileShuffled() {
        var queue = MusicQueue(trackIDs: ids, seed: 7)
        queue.setShuffled(true)
        queue.add(["f"])
        let target = queue.entries[3]
        queue.jump(to: target.id)
        #expect(queue.current == target)
        queue.setShuffled(false)
        #expect(queue.entries.map(\.trackID) == ids + ["f"])
        #expect(queue.current == target)
    }

    @Test func aQueueIsKeptAsItWas() throws {
        var queue = MusicQueue(trackIDs: ids, startAt: 3, seed: 3)
        queue.repeatMode = .all
        queue.setShuffled(true)
        let data = try JSONEncoder().encode(queue)
        #expect(try JSONDecoder().decode(MusicQueue.self, from: data) == queue)
    }
}

@Suite struct MusicCatalogueTests {
    @Test func onlyWhatIsOnTheDevice() {
        let epoch = Date(millisecondsSince1970: 1_795_530_000_000)
        func file(_ revision: String) -> MusicFile { MusicFile(revision: revision, sizeBytes: 10, container: "flac", codec: "flac") }
        var catalogue = MusicCatalogue(
            artists: [MusicArtist(id: "ar1", name: "One", addedAt: epoch), MusicArtist(id: "ar2", name: "Two", addedAt: epoch)],
            albums: [
                MusicAlbum(id: "al1", title: "First", artistCredit: "One", artistIds: ["ar1"], trackCount: 2, durationMs: 2, addedAt: epoch),
                MusicAlbum(id: "al2", title: "Second", artistCredit: "Two", artistIds: ["ar2"], trackCount: 1, durationMs: 1, addedAt: epoch.addingTimeInterval(60)),
            ],
            tracks: [
                MusicTrack(id: "t1", title: "B side", artistCredit: "One", artistIds: ["ar1"], albumId: "al1", track: 2, durationMs: 1, addedAt: epoch, file: file("r1")),
                MusicTrack(id: "t2", title: "A side", artistCredit: "One", artistIds: ["ar1"], albumId: "al1", track: 1, durationMs: 1, addedAt: epoch, file: file("r2")),
                MusicTrack(id: "t3", title: "Other", artistCredit: "Two", artistIds: ["ar2"], albumId: "al2", durationMs: 1, addedAt: epoch, file: file("r3")),
            ])
        #expect(catalogue.tracks(ofAlbum: "al1").map(\.id) == ["t2", "t1"])
        #expect(catalogue.recentlyAddedAlbums.map(\.id) == ["al2", "al1"])

        let here = catalogue.limited(to: ["t1"])
        #expect(here.albums.keys.sorted() == ["al1"])
        #expect(here.artists.keys.sorted() == ["ar1"])
        #expect(here.tracks(ofAlbum: "al1").map(\.id) == ["t1"])

        catalogue.apply(MusicLibraryPage(removed: ["t3", "al2"], cursor: "c"))
        #expect(catalogue.albums["al2"] == nil)
        #expect(catalogue.tracks["t3"] == nil)
    }
}
