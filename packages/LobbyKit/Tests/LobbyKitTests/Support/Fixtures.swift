// SPDX-License-Identifier: MPL-2.0
import Foundation

@testable import LobbyKit

/// JSON written by hand from the examples and interfaces in `docs/api.md`.
enum Fixtures {
    static let device = #"""
        { "id": "dev-1", "name": "Alex's MacBook Pro", "platform": "macos", "role": "manager",
          "createdAt": 1795530000000, "lastUsedAt": 1795530060000, "revokedAt": null }
        """#

    static let mediaFile = #"""
        {
          "assetId": "asset-1", "role": "main", "edition": null, "part": null,
          "startMs": null, "endMs": null, "sharedBy": 1, "available": true,
          "sizeBytes": 4812345678, "durationMs": 5820000, "container": "mkv",
          "revision": "r-8f2a", "playability": "remux",
          "playabilityReason": "The file is MKV, which has to be repackaged as MP4.",
          "video": { "codec": "hevc", "width": 3840, "height": 2160, "bitDepth": 10 },
          "audio": [
            { "index": 1, "codec": "eac3", "language": "eng", "title": "Surround", "channels": 6, "isDefault": true },
            { "index": 2, "codec": "aac", "language": null, "title": null, "channels": null, "isDefault": false }
          ],
          "subtitles": [
            { "id": "s3", "source": "embedded", "codec": "subrip", "language": "nld", "title": null, "isForced": false, "isText": true },
            { "id": "side-en", "source": "sidecar", "codec": "hdmv_pgs_subtitle", "language": "eng", "title": "SDH", "isForced": true, "isText": false }
          ]
        }
        """#

    static let movie = #"""
        {
          "id": "movie-1", "kind": "movie", "parentId": null,
          "title": "The Jungle Book", "sortTitle": "Jungle Book", "year": 1967,
          "seasonNumber": null, "episodeNumber": null,
          "overview": "A boy raised by wolves.", "airDate": "1967-10-18", "runtimeMs": 4680000,
          "genres": ["Animation", "Family"], "categories": ["Disney"],
          "matchStatus": "needs_review", "imdbId": "tt0061852", "tmdb": { "type": "movie", "id": 9325 },
          "extraKind": null, "trailer": { "provider": "youtube", "key": "abc123" },
          "artwork": { "poster": { "id": "art-1", "width": 2000, "height": 3000 }, "backdrop": { "id": "art-2", "width": null, "height": null }, "still": null },
          "addedAt": 1795530000000, "available": true,
          "files": [\#(mediaFile)]
        }
        """#

    static func libraryPage(items: [String], removed: [String] = [], cursor: String, more: Bool = false, reset: Bool = false) -> String {
        let removedJSON = removed.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{ "items": [\#(items.joined(separator: ","))], "removed": [\#(removedJSON)], "cursor": "\#(cursor)", "more": \#(more), "reset": \#(reset) }"#
    }

    static func progress(itemId: String, positionMs: Int, completed: Bool = false, revision: Int, updatedAt: Int64) -> String {
        #"{ "itemId": "\#(itemId)", "positionMs": \#(positionMs), "durationMs": 3480000, "completed": \#(completed), "revision": \#(revision), "updatedAt": \#(updatedAt) }"#
    }

    /// A minimal item as the server writes it, with every field present.
    static func item(id: String, kind: String = "movie", parentId: String? = nil, title: String? = nil, addedAt: Int64 = 1_795_530_000_000) -> String {
        let parent = parentId.map { "\"\($0)\"" } ?? "null"
        return #"""
            {
              "id": "\#(id)", "kind": "\#(kind)", "parentId": \#(parent),
              "title": "\#(title ?? id)", "sortTitle": "\#(title ?? id)", "year": null,
              "seasonNumber": null, "episodeNumber": null, "overview": null, "airDate": null, "runtimeMs": null,
              "genres": [], "categories": [], "matchStatus": "matched", "imdbId": null, "tmdb": null,
              "extraKind": null, "trailer": null,
              "artwork": { "poster": null, "backdrop": null, "still": null },
              "addedAt": \#(addedAt), "available": true, "files": []
            }
            """#
    }
}

/// Builders for catalogues in shelf tests.
enum Make {
    static let epoch = Date(millisecondsSince1970: 1_795_530_000_000)

    static func date(_ minutes: Int) -> Date {
        epoch.addingTimeInterval(TimeInterval(minutes * 60))
    }

    static func movie(_ id: String, title: String? = nil, sortTitle: String? = nil, added: Int = 0, genres: [String] = [], categories: [String] = []) -> Item {
        Item(id: id, kind: .movie, title: title ?? id, sortTitle: sortTitle, genres: genres, categories: categories, addedAt: date(added))
    }

    static func show(_ id: String, title: String? = nil, added: Int = 0, genres: [String] = [], categories: [String] = []) -> Item {
        Item(id: id, kind: .show, title: title ?? id, genres: genres, categories: categories, addedAt: date(added))
    }

    static func season(_ id: String, show: String, number: Int?, added: Int = 0) -> Item {
        Item(id: id, kind: .season, parentId: show, title: number.map { "Season \($0)" } ?? "Unknown season", seasonNumber: number, addedAt: date(added))
    }

    static func episode(_ id: String, season: String?, s: Int?, e: Int?, title: String? = nil, added: Int = 0) -> Item {
        Item(id: id, kind: .episode, parentId: season, title: title ?? id, seasonNumber: s, episodeNumber: e, addedAt: date(added))
    }

    static func progress(_ itemId: String, position: Int = 60_000, completed: Bool = false, at minutes: Int, revision: Int = 1) -> PlaybackProgress {
        PlaybackProgress(itemId: itemId, positionMs: position, durationMs: 1_200_000, completed: completed, revision: revision, updatedAt: date(minutes))
    }

    static func progressMap(_ entries: PlaybackProgress...) -> [String: PlaybackProgress] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.itemId, $0) })
    }

    static func file(
        playability: Playability, container: String = "mp4", video: String? = "h264", audio: [String] = ["aac"],
        available: Bool = true, reason: String? = nil
    ) -> MediaFile {
        MediaFile(
            assetId: "asset", available: available, sizeBytes: 1_000, durationMs: 1_000, container: container,
            revision: "r1", playability: playability, playabilityReason: reason,
            video: video.map { VideoTrack(codec: $0, width: 1920, height: 1080, bitDepth: 8) },
            audio: audio.enumerated().map {
                AudioTrack(index: $0.offset, codec: $0.element, language: nil, title: nil, channels: 2, isDefault: $0.offset == 0)
            })
    }
}
