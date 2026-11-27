// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing

@testable import LobbyKit

/// Decodes what the real server sent. The files in `Captured/` were written by `curl` against
/// `apps/server` over a small library (one film, one show with two episodes), unedited. The
/// package README has the commands to capture them again when the server changes.
@Suite struct CapturedResponseTests {
    let decoder = LobbyJSON.decoder()

    func captured(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Captured"))
        return try Data(contentsOf: url)
    }

    @Test func serverAndMe() throws {
        let server = try decoder.decode(ServerInfo.self, from: captured("server"))
        #expect(server.name == "Lobby integration test")
        #expect(server.apiVersion == 1)
        #expect(!server.claimed)

        let me = try decoder.decode(Me.self, from: captured("me"))
        #expect(me.device.name == "Capture Mac")
        #expect(me.device.platform == .macos)
        #expect(me.device.role == .manager)
        #expect(me.device.revokedAt == nil)
        #expect(me.server.claimed)
        #expect(me.server.id == server.id)
    }

    @Test func statusDevicesAndProfiles() throws {
        let status = try decoder.decode(ServerStatus.self, from: captured("status"))
        #expect(status.sources.map(\.name) == ["Movies", "Series"])
        #expect(status.sources.map(\.hint) == [.movies, .series])
        #expect(status.files.total == 3)
        #expect(status.playability.direct == 2)
        #expect(status.playability.remux == 1)
        #expect(status.items.episodes == 2)

        let devices = try decoder.decode(DeviceList.self, from: captured("devices"))
        #expect(devices.devices.map(\.id) == [devices.currentDeviceId])
        #expect(devices.devices[0].lastUsedAt != nil)

        struct Profiles: Decodable { var profiles: [Profile] }
        let profiles = try decoder.decode(Profiles.self, from: captured("profiles")).profiles
        #expect(profiles.map(\.name) == ["Robin"])
        #expect(profiles[0].color == "teal")
    }

    @Test func pairing() throws {
        struct Requests: Decodable { var requests: [PendingPairingRequest] }
        let requests = try decoder.decode(Requests.self, from: captured("pairing-requests")).requests
        #expect(requests.count == 1)
        #expect(requests[0].deviceName == "Living room Apple TV")
        #expect(requests[0].platform == .tvos)
        // The code works for ten minutes.
        #expect(requests[0].expiresAt.timeIntervalSince(requests[0].createdAt) == 600)
    }

    @Test func theLibraryAndItsShelves() throws {
        let page = try decoder.decode(LibraryPage.self, from: captured("library"))
        #expect(!page.more)
        #expect(!page.reset)
        #expect(!page.cursor.isEmpty)
        #expect(page.removed.isEmpty)
        #expect(page.items.count == 5)
        #expect(page.items.allSatisfy { $0.kind.isKnown && $0.matchStatus.isKnown })
        #expect(page.items.flatMap(\.files).allSatisfy { $0.playability.isKnown && $0.role.isKnown })

        var catalogue = Catalogue()
        catalogue.apply(page)

        let film = try #require(Shelves.movies(in: catalogue).first)
        #expect(film.title == "Test Film")
        #expect(film.year == 2020)
        #expect(film.categories == ["Movies"])
        let filmFile = try #require(film.mainFiles.first)
        #expect(filmFile.container == "mp4")
        #expect(filmFile.playability == .direct)
        #expect(filmFile.video?.codec == "h264")
        #expect(filmFile.audio.first?.codec == "aac")
        #expect(filmFile.sizeBytes > 0)
        #expect(PlaybackPlanner.decide(for: filmFile, capabilities: DeviceCapabilities(hardwareAV1Decode: false)) == .direct)

        let show = try #require(Shelves.series(in: catalogue).first)
        #expect(show.title == "Bluey")
        #expect(show.files.isEmpty)
        let episodes = EpisodeOrder.episodes(ofShow: show.id, in: catalogue)
        #expect(episodes.map(\.episodeNumber) == [1, 2])
        #expect(episodes.map(\.seasonNumber) == [1, 1])
        let mkv = try #require(episodes[1].mainFiles.first)
        #expect(mkv.container == "mkv")
        #expect(mkv.playability == .remux)
        #expect(mkv.playabilityReason != nil)
        #expect(PlaybackPlanner.decide(for: mkv, capabilities: DeviceCapabilities(hardwareAV1Decode: false)) == .needsPreparedPlayback)

        // One card for the film and one for the season, not one per episode.
        let recent = Shelves.recentlyAdded(in: catalogue)
        #expect(recent.count == 2)
        #expect(Shelves.categories(in: catalogue).map(\.id) == ["folder:Movies", "folder:Series"])
    }

    @Test func anItemWithItsChildren() throws {
        let detail = try decoder.decode(ItemDetail.self, from: captured("item-show"))
        #expect(detail.item.kind == .show)
        #expect(detail.children.map(\.kind) == [.season])
        #expect(detail.children[0].parentId == detail.item.id)
        #expect(detail.children[0].seasonNumber == 1)
    }

    @Test func progress() throws {
        struct Accepted: Decodable { var progress: PlaybackProgress }
        let accepted = try decoder.decode(Accepted.self, from: captured("progress-put")).progress
        #expect(accepted.positionMs == 61_000)
        #expect(accepted.durationMs == 2_000)
        #expect(accepted.revision == 1)
        #expect(accepted.updatedAt.millisecondsSince1970 == 1_795_530_000_000)

        let list = try decoder.decode(ProgressList.self, from: captured("progress-list"))
        #expect(list.progress == [accepted])
        #expect(list.revision == 1)
    }

    @Test func errors() throws {
        let response = HTTPURLResponse(url: URL(string: "http://lobby.test")!, statusCode: 0, httpVersion: nil, headerFields: nil)!

        let conflict = LobbyError.from(status: 409, data: try captured("progress-conflict"), headers: response)
        guard case .conflict(let message, let progress) = conflict else {
            Issue.record("Expected a conflict, got \(conflict)")
            return
        }
        #expect(message == "This was changed more recently on another device.")
        #expect(progress?.positionMs == 61_000)
        #expect(progress?.revision == 1)

        #expect(
            LobbyError.from(status: 401, data: try captured("error-unauthorized"), headers: response)
                == .unauthorized(message: "This device is not paired with the server."))
        #expect(
            LobbyError.from(status: 404, data: try captured("error-not-found"), headers: response)
                == .notFound(message: "That title is no longer in the library."))

        struct Pending: Decodable {
            var status: String
            var expiresAt: Date
        }
        #expect(try decoder.decode(Pending.self, from: captured("pairing-collect-pending")).status == "pending")
    }
}
