// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyDirect
import LobbyKit
import Testing

@testable import Lobby

/// Access from outside: what a manager does with it, and what a device without it never notices.
@MainActor
@Suite struct OutsideTests {
    private static let status = #"{"configured":true,"enabled":false,"transports":[{"name":"direct","open":true,"problem":null}],"connections":2,"direct":{"running":true,"introducer":true,"connections":2,"relayed":1,"devices":3},"window":{"openedBy":"dev-1","openedAt":1795530000000,"expiresAt":4102444800000},"requests":[{"id":"ask-1","outside":true,"deviceName":"Apple TV","platform":"tvos","address":"203.0.113.7","comparison":"482913","createdAt":1795530000000,"expiresAt":4102444800000}]}"#

    private func test(outside: String? = nil) throws -> TestApp {
        let test = try TestApp(Household(.init(
            device: Device(id: "dev-1", name: "Mac", platform: .macos, role: .manager, createdAt: Make.epoch),
            otherDevices: [Device(id: "dev-2", name: "Kitchen iPad", platform: .ipados, role: .viewer, createdAt: Make.epoch)])))
        test.household.change { $0.outside = outside }
        return test
    }

    @Test func aServerWithoutItIsAskedOnceAndNothingShows() async throws {
        let test = try test()
        test.environment.road = ServerRoad(credentials: test.credentials, session: test.household.stub.session)
        let app = try await test.launchPaired(as: "alex")
        #expect(app.roadText == "Home network")
        await app.refresh()
        await app.refresh()
        #expect(test.household.stub.requests("GET", "/v1/me/direct").count == 1)
        #expect(test.household.stub.requests("PUT", "/v1/me/direct").isEmpty)
        #expect(!app.hasDirect)
        #expect(app.roadProblem == nil)
        let model = ManagerModel(app: app)
        await model.refresh()
        #expect(!model.offersOutside)
        let outside = OutsideModel(app: app)
        await outside.refresh()
        #expect(outside.isUnavailable)
        #expect(outside.problem == nil)
    }

    @Test func offlineSaysSoInSettings() async throws {
        let test = try test()
        test.environment.road = ServerRoad(credentials: test.credentials, session: test.household.stub.session)
        _ = try await test.launchPaired(as: "alex")
        test.household.change { $0.offline = true }
        let app = test.launch()
        await app.start()
        #expect(app.roadText == "Offline")
    }

    @Test func aManagerTurnsItOnAndLetsADeviceIn() async throws {
        let test = try test(outside: Self.status)
        let app = try await test.launchPaired(as: "alex")
        let model = OutsideModel(app: app)
        await model.refresh()
        #expect(!model.isOn)
        #expect(model.summary == "Off. Nothing can reach Lobby Server from outside.")
        await model.setOn(true)
        #expect(model.isOn)
        #expect(model.summary == "Ready. 2 devices connected, 1 over the relay.")
        #expect(model.access.map(\.title) == ["Kitchen iPad", "Nobody known"])
        #expect(model.access.first?.caption.hasPrefix("Watched · ") == true)
        #expect(model.access.last?.isRefusal == true)

        await model.openWindow()
        let invitation = try #require(model.invitation)
        #expect(invitation.link == "lobby://pair?i=wss://introducer.example.com&c=0123456789ABCDEF")
        #expect(QRCodeView.image(invitation.link) != nil)
        // A code that is no Apple TV's is not sent anything.
        await model.send(to: "lobby://pair?i=a.example.com&c=0123456789ABCDEF")
        guard case .failed = model.handOver else { return #expect(Bool(false), "\(model.handOver)") }

        let request = try #require(model.status?.requests.first)
        await model.approve(request)
        let sent = try #require(test.household.stub.requests("POST", "/v1/outside/pairing/ask-1/approve").first)
        #expect(sent.json()["comparison"] as? String == "482913")
        #expect(model.lastApproval == "“Apple TV” was let in as a viewer.")
        #expect(model.invitation == nil)
    }

    @Test func anOpenedLinkOnlyFillsIn() async throws {
        let test = try test()
        test.environment.road = ServerRoad(credentials: test.credentials, session: test.household.stub.session)
        let app = test.launch()
        await app.start()
        #expect(app.phase == .connect)
        app.open(try #require(URL(string: "lobby://tv?a=10.0.0.2&p=1&k=x")))
        #expect(app.invitation == nil)
        app.open(try #require(URL(string: "lobby://pair?i=introducer.example.com&c=0123-4567-89ab-cdef")))
        let model = ConnectModel(app: app)
        await model.resumeOutside()
        #expect(model.step == .outside)
        #expect(model.introducerText == "introducer.example.com")
        #expect(model.outsideCode == "0123456789ABCDEF")
        #expect(model.canPairOutside)
        #expect(app.invitation == nil)
        model.back()
        #expect(model.step == .discover)
        model.useInvitation("https://example.com")
        #expect(model.problem == .outside("That is not a code to pair Lobby with."))
    }

    @Test func aPairedDeviceIgnoresLinks() async throws {
        let app = try await test().launchPaired(as: "alex")
        app.open(try #require(URL(string: "lobby://pair?i=introducer.example.com&c=0123456789ABCDEF")))
        #expect(app.invitation == nil)
    }

    @Test func whatIsTypedIsReadAsTheCodeIsMeant() async throws {
        let test = try test()
        let model = ConnectModel(app: test.launch())
        model.outsideCode = "o1il-abcd"
        #expect(model.outsideCode == "0111ABCD")
        #expect(!model.canPairOutside)
        model.outsideCode = "0123456789ABCDEFGHJK"
        #expect(model.outsideCode == "0123456789ABCDEF")
        model.introducerText = "not an address"
        #expect(!model.canPairOutside)
    }

    @Test func signingOutForgetsTheKeys() async throws {
        let test = try test()
        let road = ServerRoad(credentials: test.credentials, session: test.household.stub.session)
        test.environment.road = road
        let app = try await test.launchPaired(as: "alex")
        let key = "direct:\(test.household.current.server.id)"
        await test.credentials.setToken("kept", forServer: key)
        await test.credentials.setToken("kept", forServer: AppModel.pendingPairingKey)
        await app.signOut()
        #expect(await test.credentials.token(forServer: key) == nil)
        #expect(await test.credentials.token(forServer: AppModel.pendingPairingKey) == nil)
    }
}
