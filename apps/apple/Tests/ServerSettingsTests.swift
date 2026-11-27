// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

/// Settings → Server and the first setup: what a manager sees, what is sent, and the restart.
@MainActor
@Suite struct ServerSettingsTests {
    static let settings = #"""
    {"version":3,"updatedAt":1795530000000,"updatedBy":null,"bootId":"boot-1","restarting":false,
     "sections":[{"id":"general","title":"General"},{"id":"library","title":"Library folders"}],
     "settings":[
      {"key":"serverName","section":"general","title":"Name","help":"Shown.","type":"text","apply":"live","default":"Lobby","nullable":false,"value":"Den","available":true},
      {"key":"language","section":"general","title":"Language of titles","help":"From TMDB.","type":"language","apply":"restart","default":"en-US","nullable":false,"value":"en-US","available":true},
      {"key":"roots","section":"library","title":"Folders","help":"Read only.","type":"folders","apply":"live","default":[],"nullable":false,
       "value":[{"path":"/media/drive/Films","hint":"movies"}],"available":true},
      {"key":"rescanMinutes","section":"library","title":"Every","help":"Minutes.","type":"integer","apply":"live","default":30,"nullable":false,"min":1,"max":1440,"value":30,"available":true}
     ],
     "secrets":{"tmdbKey":{"set":false,"source":null}},
     "fixed":{"configFile":"/home/pi/lobby/lobby.config.json","dataDir":"/home/pi/lobby/data","host":"0.0.0.0","port":8674,"claim":"open","outside":null},
     "setup":{"needed":false,"steps":[]}}
    """#

    private func test(settings: String? = Self.settings, setup: ServerSetup? = nil) throws -> TestApp {
        let test = try TestApp(Household(.init(
            device: Device(id: "dev-1", name: "Mac", platform: .macos, role: .manager, createdAt: Make.epoch))))
        test.household.change {
            $0.settings = settings
            $0.server.setup = setup
        }
        return test
    }

    @Test func showsWhatTheServerHasAndSendsOnlyWhatChanged() async throws {
        let test = try test()
        let app = try await test.launchPaired(as: "alex")
        let model = ServerSettingsModel(app: app)
        await model.load()
        #expect(model.value("serverName") == .string("Den"))
        #expect(model.folders.map(\.displayName) == ["Films"])
        #expect(!model.hasChanges)

        model.set("serverName", .string("Attic"))
        model.addFolder(path: "/media/drive/Cartoons", hint: "movies", forKids: true)
        #expect(model.hasChanges)
        #expect(!model.changesRestart)
        // Back to what the server has: no change.
        model.set("serverName", .string("Den"))
        #expect(!model.isChanged("serverName"))

        await model.prepareReview()
        #expect(model.review != nil)
        let dry = try #require(test.household.stub.requests("PATCH", "/v1/settings").last)
        #expect(dry.json()["dryRun"] as? Bool == true)
        #expect(dry.json()["baseVersion"] as? Int == 3)
        let changes = try #require(dry.json()["changes"] as? [String: Any])
        #expect(Array(changes.keys) == ["roots"])
        let roots = try #require(changes["roots"] as? [[String: Any]])
        #expect(roots.last?["group"] as? String == "Kids")

        #expect(await model.apply())
        let sent = try #require(test.household.stub.requests("PATCH", "/v1/settings").last)
        #expect(sent.json()["dryRun"] as? Bool == false)
        #expect(!model.hasChanges)
        #expect(model.saved != nil)
    }

    @Test func waitsForTheServerToComeBackAfterARestart() async throws {
        let test = try test()
        test.household.change {
            $0.settingsChange = #"{"dryRun":true,"version":4,"changed":["language"],"effects":[{"key":"language","title":"Language of titles","apply":"restart","message":"en-US → nl-NL."}],"restart":true,"restarting":true,"rescanFolders":0,"bootId":"boot-1"}"#
        }
        let app = try await test.launchPaired(as: "alex")
        let model = ServerSettingsModel(app: app)
        await model.load()
        model.set("language", .string("nl-NL"))
        #expect(model.changesRestart)
        await model.prepareReview()
        #expect(model.review?.restart == true)
        #expect(await model.apply())
        #expect(model.restart == .back)
        #expect(model.settings?.bootId == "boot-2")
    }

    @Test func aWrongTMDBKeySaysWhy() async throws {
        let test = try test()
        let app = try await test.launchPaired(as: "alex")
        let model = ServerSettingsModel(app: app)
        await model.load()
        #expect(await model.setTMDBKey("nope") == "TMDB does not accept this key.")
        #expect(!model.tmdbKey.set)
        #expect(await model.setTMDBKey(" 0123456789abcdef0123456789abcdef ") == nil)
        #expect(model.tmdbKey.set)
    }

    @Test func aFreshServerOffersItsSetupToTheManagerOnly() async throws {
        let needed = ServerSetup(needed: true, steps: [.init(id: "name", done: false, skipped: false)])
        let test = try test(setup: needed)
        let app = try await test.launchPaired(as: "alex")
        #expect(app.serverSetup?.needed == true)
        #expect(app.showsServerSetup)
        app.postponesSetup = true
        #expect(!app.showsServerSetup)
    }

    @Test func wordsForHoursAndFolders() {
        let hours = ServerSettingsModel.hours(.string("01:30-07:00"))
        #expect(hours?.from == 90)
        #expect(hours?.to == 420)
        #expect(ServerSettingsModel.hours(.null) == nil)
        #expect(ServerSettingsModel.hoursValue(from: 23 * 60, to: 6 * 60) == .string("23:00-06:00"))
        #expect(ServerSettingsModel.describe(.number(30)) == "30")
        #expect(ServerSettingsModel.kindName("personal") == "Home videos")
        let folder = FolderEntry(name: "Films", path: "/m/Films", videoFiles: 412, audioFiles: 0, more: false)
        #expect(FolderBrowserModel.caption(folder) == "412 videos")
        let many = FolderEntry(name: "All", path: "/m", videoFiles: 4000, audioFiles: 3, more: true)
        #expect(FolderBrowserModel.caption(many) == "4000+ videos, 3+ audio files")
    }
}
