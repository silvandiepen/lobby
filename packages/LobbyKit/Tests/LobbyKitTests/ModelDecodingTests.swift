// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing

@testable import LobbyKit

@Suite struct ModelDecodingTests {
    let decoder = LobbyJSON.decoder()

    @Test func decodesAnItemWithItsFile() throws {
        let item = try decoder.decode(Item.self, from: Data(Fixtures.movie.utf8))

        #expect(item.id == "movie-1")
        #expect(item.kind == .movie)
        #expect(item.parentId == nil)
        #expect(item.sortTitle == "Jungle Book")
        #expect(item.year == 1967)
        #expect(item.airDate == "1967-10-18")
        #expect(item.genres == ["Animation", "Family"])
        #expect(item.categories == ["Disney"])
        #expect(item.matchStatus == .needsReview)
        #expect(item.tmdb == TMDBReference(type: .movie, id: 9325))
        #expect(item.trailer == OnlineTrailer(provider: .youtube, key: "abc123"))
        #expect(item.artwork.poster == Artwork(id: "art-1", width: 2000, height: 3000))
        #expect(item.artwork.backdrop == Artwork(id: "art-2"))
        #expect(item.artwork.still == nil)
        #expect(item.addedAt == Date(timeIntervalSince1970: 1_795_530_000))
        #expect(item.available)

        let file = try #require(item.files.first)
        #expect(file.assetId == "asset-1")
        #expect(file.role == .main)
        #expect(file.sizeBytes == 4_812_345_678)
        #expect(file.durationMs == 5_820_000)
        #expect(file.playability == .remux)
        #expect(file.playabilityReason == "The file is MKV, which has to be repackaged as MP4.")
        #expect(file.video == VideoTrack(codec: "hevc", width: 3840, height: 2160, bitDepth: 10))
        #expect(file.audio.count == 2)
        #expect(file.audio[0].channels == 6)
        #expect(file.audio[0].isDefault)
        #expect(file.audio[1].language == nil)
        #expect(file.subtitles[0] == SubtitleTrack(id: "s3", source: .embedded, codec: "subrip", language: "nld", title: nil, isForced: false, isText: true))
        #expect(file.subtitles[1].source == .sidecar)
        #expect(!file.subtitles[1].isText)
    }

    @Test func decodesADeviceWithInstantsAsDates() throws {
        let device = try decoder.decode(Device.self, from: Data(Fixtures.device.utf8))

        #expect(device.platform == .macos)
        #expect(device.role == .manager)
        #expect(device.createdAt.millisecondsSince1970 == 1_795_530_000_000)
        #expect(device.lastUsedAt?.millisecondsSince1970 == 1_795_530_060_000)
        #expect(device.revokedAt == nil)
    }

    @Test func instantsRoundTripAsIntegerMilliseconds() throws {
        let progress = PlaybackProgress(
            itemId: "i", positionMs: 1_264_000, durationMs: nil, completed: false, revision: 7,
            updatedAt: Date(millisecondsSince1970: 1_795_531_000_123))
        let data = try LobbyJSON.encoder().encode(progress)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains(#""updatedAt":1795531000123"#))
        #expect(try decoder.decode(PlaybackProgress.self, from: data) == progress)
    }

    @Test func aProgressUpdateWritesNullInsteadOfOmittingAField() throws {
        let update = ProgressUpdate(
            opId: "op", baseRevision: nil, positionMs: 0, durationMs: nil, completed: false,
            updatedAt: Date(millisecondsSince1970: 1_795_531_000_000))
        let json = try #require(String(data: try LobbyJSON.encoder().encode(update), encoding: .utf8))

        #expect(json.contains(#""baseRevision":null"#))
        #expect(json.contains(#""durationMs":null"#))
        #expect(json.contains(#""updatedAt":1795531000000"#))
    }

    @Test func valuesFromANewerServerDoNotBreakDecoding() throws {
        let json = Fixtures.movie
            .replacingOccurrences(of: #""kind": "movie""#, with: #""kind": "audiobook""#)
            .replacingOccurrences(of: #""matchStatus": "needs_review""#, with: #""matchStatus": "pending_vote""#)
            .replacingOccurrences(of: #""playability": "remux""#, with: #""playability": "cloud""#)
            .replacingOccurrences(of: #""provider": "youtube""#, with: #""provider": "vimeo""#)
            .replacingOccurrences(of: #""role": "main""#, with: #""role": "commentary", "somethingNew": { "a": [1, 2] }"#)
        let item = try decoder.decode(Item.self, from: Data(json.utf8))

        #expect(item.kind == .unknown("audiobook"))
        #expect(!item.kind.isKnown)
        #expect(item.matchStatus == .unknown("pending_vote"))
        #expect(item.trailer?.provider == .unknown("vimeo"))
        #expect(item.files[0].playability == .unknown("cloud"))
        #expect(item.files[0].role == .unknown("commentary"))

        // What this build does not know survives the trip through the cache.
        let again = try decoder.decode(Item.self, from: try LobbyJSON.encoder().encode(item))
        #expect(again == item)
        #expect(again.kind.rawValue == "audiobook")
    }

    @Test func decodesALibraryPage() throws {
        let json = Fixtures.libraryPage(items: [Fixtures.movie], removed: ["gone-1", "gone-2"], cursor: "c-41", more: true)
        let page = try decoder.decode(LibraryPage.self, from: Data(json.utf8))

        #expect(page.items.map(\.id) == ["movie-1"])
        #expect(page.removed == ["gone-1", "gone-2"])
        #expect(page.cursor == "c-41")
        #expect(page.more)
        #expect(!page.reset)
    }

    @Test func decodesTheServerStatus() throws {
        let json = #"""
            {
              "scanning": true,
              "sources": [
                { "id": "src-1", "name": "Pixar", "hint": "movies", "available": true, "lastScanStartedAt": 1795530000000, "lastScanFinishedAt": null, "files": 34 }
              ],
              "files": { "total": 3070, "waiting": 12, "failed": 3, "missing": 0 },
              "playability": { "direct": 920, "remux": 1380, "transcode": 620, "unsupported": 4 },
              "items": { "movies": 380, "shows": 50, "episodes": 2500, "extras": 40, "personal": 0, "needsReview": 62, "unmatched": 310 }
            }
            """#
        let status = try decoder.decode(ServerStatus.self, from: Data(json.utf8))

        #expect(status.scanning)
        #expect(status.sources[0].hint == .movies)
        #expect(status.sources[0].lastScanFinishedAt == nil)
        #expect(status.files.total == 3070)
        #expect(status.playability.remux == 1380)
        #expect(status.items.needsReview == 62)
    }
}
