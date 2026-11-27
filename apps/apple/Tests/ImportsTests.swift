// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

/// Uploading and the Inbox: what the server's answers mean, what is picked, and what is shown.
@MainActor
@Suite struct ImportsTests {
    // Captured from the real server (apps/server) after an upload of a two-second film.
    static let status = #"""
    {"folders":[{"path":"/media/drive/Downloads","name":"Downloads","mode":"index","looksLikeDownloads":true,"connected":true,
      "counts":{"waiting":0,"inbox":0,"moving":0,"imported":0,"listed":0,"ignored":0,"failed":0,"dismissed":0},"lastLookAt":null,"problem":null}],
     "moving":true,"driveConnected":true,
     "counts":{"waiting":0,"inbox":0,"moving":0,"imported":0,"listed":0,"ignored":1,"failed":0,"dismissed":0},
     "destinations":[{"path":"/media/drive/Movies","name":"Movies","hint":"movies"}],
     "settings":{"waitMinutes":10,"copyAcrossDrives":false,"maxFileGb":100,"quotaGb":500}}
    """#
    static let items = #"""
    {"items":[{"id":"78c71aa8-cb43-41aa-b873-997e75bdb549","origin":"upload","folder":null,"name":"Holiday (2018).mp4",
      "relPath":"Holiday (2018).mp4","sizeBytes":37481,"state":"ignored","reason":"At less than 1 MB it is too small for a film.",
      "kind":"movie","title":"Holiday","year":2018,"season":null,"episode":null,"episodeTitle":null,"tmdbId":null,"candidates":[],
      "destination":null,"targetPath":null,"subtitles":[],"leftovers":null,"uploadId":"2e6e8aff-da95-43f4-9537-2e773e9a5a85",
      "convertible":false,"actions":["move","dismiss"],"firstSeenAt":1795686449030,"updatedAt":1795686449038,"doneAt":null}]}
    """#
    static let upload = #"""
    {"upload":{"id":"2e6e8aff-da95-43f4-9537-2e773e9a5a85","batch":null,"relPath":"Holiday (2018).mp4","name":"Holiday (2018).mp4",
      "sizeBytes":37481,"receivedBytes":37481,"state":"done","reason":null,"destination":{"kind":"movies"},
      "itemId":"78c71aa8-cb43-41aa-b873-997e75bdb549","createdAt":1795686448357,"updatedAt":1795686449042}}
    """#

    @Test func readsTheServersAnswers() throws {
        let status = try LobbyJSON.decoder().decode(ImportsStatus.self, from: Data(Self.status.utf8))
        #expect(status.folders.first?.mode == "index")
        #expect(status.folders.first?.looksLikeDownloads == true)
        #expect(status.destinations.map(\.name) == ["Movies"])

        struct Items: Decodable { var items: [ImportItem] }
        let item = try #require(try LobbyJSON.decoder().decode(Items.self, from: Data(Self.items.utf8)).items.first)
        #expect(item.can("move"))
        #expect(!item.can("list"))
        #expect(ImportsModel.title(of: item) == "Holiday (2018)")
        #expect(ImportsModel.stateName(item.state) == "Left out")

        struct Answer: Decodable { var upload: ServerUpload }
        let upload = try LobbyJSON.decoder().decode(Answer.self, from: Data(Self.upload.utf8)).upload
        #expect(upload.destination == .movies)
        #expect(upload.itemId == item.id)
    }

    @Test func sendsWhereAnUploadGoesAsTheServerReadsIt() throws {
        let encoded = try LobbyJSON.encoder().encode([UploadDestination.movies, .folder(path: "/media/drive/Pixar")])
        #expect(String(decoding: encoded, as: UTF8.self) == #"[{"kind":"movies"},{"kind":"folder","path":"\/media\/drive\/Pixar"}]"#)
    }

    @Test func readsHowAPieceWent() throws {
        let url = URL(string: "http://lobby.local/v1/uploads/u1")!
        let taken = HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: ["Upload-Offset": "4096"])!
        #expect(try LobbyClient.uploadPieceOutcome(status: 204, headers: taken, data: Data()) == .accepted(offset: 4096))
        let elsewhere = HTTPURLResponse(url: url, statusCode: 409, httpVersion: nil, headerFields: nil)!
        let body = Data(#"{"error":{"code":"conflict","message":"The piece arrived damaged. Send it again."},"offset":1024}"#.utf8)
        #expect(
            try LobbyClient.uploadPieceOutcome(status: 409, headers: elsewhere, data: body)
                == .elsewhere(offset: 1024, message: "The piece arrived damaged. Send it again."))
        let refused = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!
        #expect(throws: LobbyError.self) {
            try LobbyClient.uploadPieceOutcome(
                status: 403, headers: refused, data: Data(#"{"error":{"code":"forbidden","message":"No."}}"#.utf8))
        }
    }

    @Test func picksVideosAndSubtitlesFromAFolderWithItsFoldersInTheirNames() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "imports-\(UUID().uuidString)/Show", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let season = root.appending(path: "Season 1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: season, withIntermediateDirectories: true)
        for name in ["Show S01E01.mkv", "Show S01E01.en.srt", "info.nfo", ".hidden.mkv", "empty.mkv"] {
            try Data(name == "empty.mkv" ? [] : Array(name.utf8)).write(to: season.appending(path: name))
        }
        let files = UploadsModel.files(at: root)
        #expect(files.map(\.relPath) == ["Show/Season 1/Show S01E01.en.srt", "Show/Season 1/Show S01E01.mkv"])
        #expect(files.allSatisfy { $0.size > 0 })
        #expect(UploadsModel.files(at: season.appending(path: "info.nfo")).isEmpty)
    }

    @Test func keepsImportFoldersAsTheSettingHasThem() {
        let value = SettingValue.array([
            .object(["path": .string("/media/drive/Downloads"), "mode": .string("index")]),
            .object(["path": .string("/media/drive/New"), "mode": .string("move"), "name": .string("New films")]),
        ])
        let folders = ImportFolderSetting.list(value)
        #expect(folders.map(\.displayName) == ["Downloads", "New films"])
        #expect(SettingValue.array(folders.map(\.value)) == value)
        #expect(ImportFolderSetting.looksLikeDownloads("/media/drive/Downloads"))
        #expect(!ImportFolderSetting.looksLikeDownloads("/media/drive/New"))
        #expect(UploadQueue.isUploadable("Film (2020).mkv"))
        #expect(UploadQueue.isUploadable("Film (2020).en.srt"))
        #expect(!UploadQueue.isUploadable("Film (2020).mkv.part"))
        #expect(!UploadQueue.isUploadable("cover.jpg"))
    }

    @Test func saysHowAnUploadIs() {
        var job = UploadJob(
            id: UUID(), source: UploadSource(path: "/tmp/x.mkv"), name: "x.mkv", relPath: "x.mkv", size: 2_000_000, batch: "b",
            destination: .movies, uploadID: nil, sentBytes: 500_000, state: .paused, problem: nil, itemID: nil, addedAt: Date())
        #expect(job.fraction == 0.25)
        #expect(UploadsModel.describe(job) == "Paused · 25%")
        job.state = .done
        #expect(job.isFinished)
        #expect(UploadsModel.describe(.folder(path: "/media/drive/Pixar"), status: nil) == "Pixar")
    }
}
