// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

@MainActor
@Suite struct ManagerModelTests {
    let test: TestApp

    init() throws {
        test = try TestApp(Household(.init(
            device: Device(id: "dev-1", name: "Alex's MacBook Pro", platform: .macos, role: .manager, createdAt: Make.epoch),
            otherDevices: [Device(id: "dev-2", name: "Kitchen iPad", platform: .ipados, role: .viewer, createdAt: Make.epoch.addingTimeInterval(10))],
            waiting: ["482913": "Living room Apple TV"])))
    }

    @Test func aManagerSeesWhoIsWaitingAndEveryDevice() async throws {
        let app = try await test.launchPaired(as: "alex")
        #expect(app.isManager)
        let model = ManagerModel(app: app)
        await model.refresh()

        #expect(model.waiting.map(\.deviceName) == ["Living room Apple TV"])
        #expect(model.devices.map(\.device.name) == ["Alex's MacBook Pro", "Kitchen iPad"])
        #expect(model.devices.map(\.caption) == ["Mac · Server Admin", "iPad · Viewer"])
        #expect(model.devices.map(\.isThisDevice) == [true, false])
        #expect(model.problem == nil)
    }

    @Test func aCodeIsApprovedWithTheChosenRole() async throws {
        let app = try await test.launchPaired(as: "alex")
        let model = ManagerModel(app: app)
        await model.refresh()

        model.code = "48 29"
        #expect(!model.canApprove)
        model.code = "482 913"
        model.role = .admin
        #expect(model.canApprove)
        await model.approve()

        let sent = try #require(test.household.stub.requests("POST", "/v1/pairing/approve").first)
        #expect(sent.json()["code"] as? String == "482913")
        #expect(sent.json()["access"] as? String == "admin")
        #expect(model.lastApproval == "Approved “Living room Apple TV” as a server admin.")
        #expect(model.code.isEmpty)
        #expect(model.waiting.isEmpty)
        #expect(model.devices.map(\.caption).last == "Apple TV · Server Admin")
    }

    @Test func aWaitingDeviceIsApprovedWithoutTypingItsCode() async throws {
        let app = try await test.launchPaired(as: "alex")
        let model = ManagerModel(app: app)
        await model.refresh()

        let request = try #require(model.waiting.first)
        #expect(request.code == "482913")
        #expect(ManagerModel.spaced("482913") == "482 913")
        await model.approve(request, as: .viewer)

        let sent = try #require(test.household.stub.requests("POST", "/v1/pairing/approve").first)
        #expect(sent.json()["code"] == nil)
        #expect(sent.json()["requestId"] as? String == request.id)
        #expect(model.lastApproval == "Approved “Living room Apple TV” as a viewer.")
        #expect(model.waiting.isEmpty)
        #expect(model.devices.map(\.caption).last == "Apple TV · Viewer")

        // Someone else was quicker: the server's sentence is shown.
        await model.approve(request, as: .viewer)
        #expect(model.problem != nil)
        #expect(model.lastApproval == nil)
    }

    @Test func aWrongCodeShowsTheServersSentenceAndKeepsTheCode() async throws {
        let app = try await test.launchPaired(as: "alex")
        let model = ManagerModel(app: app)
        model.code = "000000"
        await model.approve()
        #expect(model.problem == "No device is waiting with that code.")
        #expect(model.lastApproval == nil)
        #expect(model.code == "000000")
    }

    @Test func aDeviceIsRemovedAndTheLastManagerCannotBe() async throws {
        let app = try await test.launchPaired(as: "alex")
        let model = ManagerModel(app: app)
        await model.refresh()

        await model.remove(try #require(model.devices.first { $0.device.name == "Kitchen iPad" }))
        #expect(model.devices.map(\.device.name) == ["Alex's MacBook Pro"])
        #expect(test.household.current.otherDevices.isEmpty)

        await model.remove(try #require(model.devices.first))
        #expect(model.problem == "The last manager cannot be removed.")
        #expect(model.devices.count == 1)
    }

    @Test func viewersAreAddedAndRemoved() async throws {
        test.household.change { $0.progress["kids"] = ["x": Make.progress("x", positionMs: 1)] }
        let app = try await test.launchPaired(as: "alex")
        let model = ManagerModel(app: app)

        await model.addViewer(name: "Robin", color: "teal")
        #expect(app.profiles.map(\.name) == ["Alex", "Kids", "Robin"])

        await model.removeViewer(try #require(app.profiles.first { $0.id == "kids" }))
        #expect(app.profiles.map(\.name) == ["Alex", "Robin"])
        #expect(test.household.current.profiles.map(\.id) == ["alex", "p3"])
        #expect(test.environment.settings.profiles.map(\.name) == ["Alex", "Robin"])
        #expect(app.phase == .library)
    }

    @Test func removingTheViewerWhoIsWatchingAsksWhoIsWatching() async throws {
        let app = try await test.launchPaired(as: "alex")
        let model = ManagerModel(app: app)
        await model.removeViewer(try #require(app.activeProfile))
        #expect(app.phase == .chooseProfile)
        #expect(app.activeProfile == nil)
        #expect(test.environment.preferences.activeProfileID == nil)
    }

    @Test func theServersStateIsSaidInSentences() async throws {
        let app = try await test.launchPaired(as: "alex")
        let model = ManagerModel(app: app)
        await model.refresh()
        #expect(ManagerModel.summary(try #require(model.status)) == [
            "380 films, 50 series, 2500 episodes",
            "920 files play as they are, 1380 are repackaged first, 620 are converted first",
            "4 files cannot be played",
            "Reading the library: 12 files to go",
            "3 files could not be read",
            "Not connected: Disney",
        ])
    }

    @Test func aViewerDeviceHasNoManagerToolsAndAsksTheServerNothing() async throws {
        test.household.change { $0.device.role = .viewer }
        let app = try await test.launchPaired(as: "alex")
        #expect(!app.isManager)
        #expect(app.managerClient == nil)

        let before = test.household.stub.recorded.count
        let model = ManagerModel(app: app)
        await model.refresh()
        model.code = "482913"
        await model.approve()
        #expect(test.household.stub.recorded.count == before)
        #expect(model.devices.isEmpty)
        #expect(test.household.current.waiting.count == 1)
    }

    @Test func aManagerWhoWasDemotedLosesTheToolsAtTheNextRefresh() async throws {
        let app = try await test.launchPaired(as: "alex")
        app.sidebarSelection = .manage
        test.household.change { $0.device.role = .viewer }
        await app.refresh()
        #expect(!app.isManager)
        #expect(app.managerClient == nil)
    }
}
