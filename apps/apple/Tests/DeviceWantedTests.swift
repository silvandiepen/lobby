// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

@MainActor
@Suite struct DeviceWantedTests {
    let test: TestApp

    init() throws {
        var state = Household.State(
            device: Device(id: "dev-1", name: "Alex's iPhone", platform: .ios, role: .manager, createdAt: Make.epoch),
            otherDevices: [Device(id: "dev-2", name: "Kitchen iPad", platform: .ipados, role: .viewer, createdAt: Make.epoch)])
        state.items = Make.show("show", title: "Long Show", episodesPerSeason: [2, 2]) + [Make.movie("film", title: "A Film")]
        test = try TestApp(Household(state))
    }

    private func asset(_ item: String, state: String = "ready", message: String = "null", progress: Double = 1, device: String = "null", why: String = "w1") -> String {
        #"{"assetId":"a-\#(item)","itemId":"\#(item)","revision":"r2","order":1,"bytes":1000,"bytesExact":true,"state":"\#(state)","mode":null,"downloadUrl":null,"message":\#(message),"why":[{"wantedId":"\#(why)","kind":"item"}],"prepareProgress":\#(progress),"device":\#(device)}"#
    }

    private func reported(_ state: String, revision: String = "r2", done: Int = 1000, error: String = "null") -> String {
        #"{"revision":"\#(revision)","state":"\#(state)","bytesDone":\#(done),"bytesTotal":1000,"error":\#(error),"reportedAt":1795530000000}"#
    }

    @Test func aDevicesPageSaysWhatIsOnItHowFarTheRestIsAndWhyNot() async throws {
        let assets = [
            asset("show-s1e1", device: reported("downloaded")),
            asset("show-s1e2", device: reported("downloading", done: 250)),
            asset("show-s2e1", state: "preparing", progress: 0.5),
            asset("show-s2e2", device: reported("failed", done: 0, error: #""no_space""#)),
            asset("film", state: "does_not_fit", message: #""The copy is larger than the cache.""#, why: "w2"),
        ]
        test.household.change {
            $0.deviceLists["dev-2"] = [
                .init(id: "w1", kind: "next_unwatched", itemId: "show", itemKind: "show", profileId: "alex", count: 10),
                .init(id: "w2", kind: "item", itemId: "film", itemKind: "movie"),
            ]
            $0.deviceAssets["dev-2"] = "[\(assets.joined(separator: ","))]"
            $0.deviceOther["dev-2"] = #"[{"assetId":"o1","revision":"r","state":"downloaded","bytesDone":2000000,"bytesTotal":2000000,"error":null,"own":true,"reportedAt":1,"itemId":"film"},{"assetId":"o2","revision":"r","state":"downloaded","bytesDone":1,"bytesTotal":1,"error":null,"own":false,"reportedAt":1,"itemId":null}]"#
        }
        let app = try await test.launchPaired(as: "alex")
        let model = DevicePageModel(app: app, deviceID: "dev-2")
        await model.refresh()

        #expect(model.detail?.device.name == "Kitchen iPad")
        #expect(model.rows.map(\.title) == ["Long Show", "A Film"])
        #expect(model.rows.map(\.what) == ["The next 10 episodes Alex has not watched", "Film"])
        #expect(model.rows.map(\.summary) == ["1 of 4 on the device", "0 of 1 on the device"])
        let files = model.rows[0].files
        #expect(files.map(\.title) == ["S1 E1 · Chapter 1", "S1 E2 · Chapter 2", "S2 E1 · Chapter 1", "S2 E2 · Chapter 2"])
        #expect(files.map(\.kind) == [.onDevice, .moving, .moving, .problem])
        #expect(files.map(\.state) == ["On the device", "Downloading", "Lobby Server is preparing it", "Not downloaded"])
        #expect(files.map(\.fraction) == [nil, 0.25, 0.5, nil])
        #expect(files[3].reason == "There is not enough room on the device.")
        #expect(model.rows[0].problems == 1)
        #expect(model.rows[0].fraction == (1 + 0.25 + 0.5) / 4)
        #expect(model.rows[1].files.first?.reason == "The copy is larger than the cache.")
        // Only the person's own downloads, not what is about to be removed.
        #expect(model.own.map(\.title) == ["A Film"])
    }

    @Test func anOlderCopyOnTheDeviceIsNotTheFileThatIsWanted() async throws {
        test.household.change {
            $0.deviceLists["dev-2"] = [.init(id: "w1", kind: "item", itemId: "film", itemKind: "movie")]
            $0.deviceAssets["dev-2"] = "[\(asset("film", device: reported("downloaded", revision: "r1")))]"
        }
        let app = try await test.launchPaired(as: "alex")
        let model = DevicePageModel(app: app, deviceID: "dev-2")
        await model.refresh()
        #expect(model.rows.first?.isComplete == false)
        #expect(model.rows.first?.files.first?.state == "Ready on Lobby Server")
    }

    @Test func aManagerTakesSomethingOffADevice() async throws {
        test.household.change {
            $0.deviceLists["dev-2"] = [.init(id: "w1", kind: "item", itemId: "film", itemKind: "movie")]
        }
        let app = try await test.launchPaired(as: "alex")
        let model = DevicePageModel(app: app, deviceID: "dev-2")
        await model.refresh()
        await model.remove(try #require(model.rows.first))
        #expect(model.rows.isEmpty)
        #expect(test.household.current.deviceLists["dev-2"]?.isEmpty == true)
        #expect(model.problem == nil)
    }

    @Test func aDeviceThatWasRemovedSaysSo() async throws {
        let app = try await test.launchPaired(as: "alex")
        let model = DevicePageModel(app: app, deviceID: "dev-9")
        await model.refresh()
        #expect(model.isGone)
    }

    @Test func aSeriesIsSentAsItsNextEpisodesForAViewer() async throws {
        let app = try await test.launchPaired(as: "alex")
        let show = try #require(app.item("show"))
        let model = SendToDeviceModel(app: app, item: show)
        #expect(model.choices.map(\.title) == ["The next episodes", "The whole series", "Season 1", "Season 2"])
        #expect(model.what == .nextEpisodes)
        #expect(model.profileID == "alex")
        #expect(model.count == 10)

        await model.load()
        #expect(model.targets.map(\.device.name) == ["Alex's iPhone", "Kitchen iPad"])
        await model.send(to: try #require(model.targets.first))
        let sent = try #require(test.household.stub.requests("POST", "/v1/devices/dev-1/wanted").first).json()
        #expect(sent["kind"] as? String == "next_unwatched")
        #expect(sent["showId"] as? String == "show")
        #expect(sent["profileId"] as? String == "alex")
        #expect(sent["count"] as? Int == 10)
        #expect(model.targets.map { $0.entry?.count } == [10, nil])

        // Another count replaces it, another viewer is another rule.
        model.count = 4
        #expect(model.changesCount(try #require(model.targets.first)))
        await model.send(to: try #require(model.targets.first))
        #expect(test.household.current.deviceLists["dev-1"]?.map(\.count) == [4])
        model.profileID = "kids"
        #expect(model.targets.first?.entry == nil)

        model.profileID = "alex"
        await model.takeOff(try #require(model.targets.first))
        #expect(test.household.current.deviceLists["dev-1"]?.isEmpty == true)
        #expect(model.targets.first?.entry == nil)
    }

    @Test func aFilmIsSentToTheDeviceWhosePageAskedForIt() async throws {
        let app = try await test.launchPaired(as: "alex")
        let model = SendToDeviceModel(app: app, item: try #require(app.item("film")), deviceID: "dev-2")
        await model.load()
        #expect(model.targets.map(\.device.name) == ["Kitchen iPad"])
        await model.send(to: try #require(model.targets.first))
        #expect(test.household.current.deviceLists["dev-2"]?.map(\.itemId) == ["film"])
    }

    @Test func theServersReasonIsShownWhenSendingIsRefused() async throws {
        let app = try await test.launchPaired(as: "alex")
        let model = SendToDeviceModel(app: app, item: Make.movie("gone"))
        await model.load()
        await model.send(to: try #require(model.targets.first))
        #expect(model.problem == "That title is not in the library.")
    }

    @Test func aManagerAwayFromHomeReachesTheServerAtItsOtherAddress() async throws {
        test.household.announceAddresses()
        let app = try await test.launchPaired(as: "alex")
        let model = SendToDeviceModel(app: app, item: try #require(app.item("film")))
        // The manager leaves home: the address that worked is somebody else's now.
        test.household.change {
            $0.awayFromHome = true
        }
        await model.load()
        #expect(model.problem == nil)
        #expect(!model.targets.isEmpty)
        #expect(test.household.remote.recorded.contains { $0.path == "/v1/devices/wanted" })
    }

    @Test func aViewerDeviceAsksForNoLists() async throws {
        test.household.change { $0.device.role = .viewer }
        let app = try await test.launchPaired(as: "alex")
        let model = SendToDeviceModel(app: app, item: try #require(app.item("film")))
        await model.load()
        #expect(model.targets.isEmpty)
        #expect(model.problem == "Only a manager can do this.")
        #expect(test.household.stub.requests("GET", "/v1/devices/wanted").isEmpty)
    }

    @Test func aDevicesStateIsSaidInWords() throws {
        func summary(entries: Int = 1, files: Int = 10, downloaded: Int = 0, failed: Int = 0) throws -> DeviceWantedSummary {
            try LobbyJSON.decoder().decode(DeviceWantedSummary.self, from: Data(
                #"{"id":"d","name":"n","platform":"ios","role":"viewer","lastSeenAt":null,"entries":\#(entries),"files":\#(files),"downloaded":\#(downloaded),"failed":\#(failed),"bytesToFetch":3000000000,"ownDownloads":0,"storage":null}"#.utf8))
        }
        #expect(DeviceProgress(try summary(entries: 0, files: 0)).text == "Nothing sent to it")
        #expect(DeviceProgress(try summary(downloaded: 10)).text == "All 10 on it")
        #expect(DeviceProgress(try summary(downloaded: 3)).text == "3 of 10 on it, 3 GB to go")
        #expect(DeviceProgress(try summary(downloaded: 3, failed: 2)).text == "3 of 10 on it, 2 cannot be done")
        #expect(DeviceProgress.seen(nil, now: Make.epoch) == "Not seen yet")
        #expect(DeviceProgress.seen(Make.epoch, now: Make.epoch.addingTimeInterval(60)) == "Seen just now")
        #expect(DeviceProgress.space(nil) == nil)
    }
}
