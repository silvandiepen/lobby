// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

@MainActor
@Suite struct ConnectModelTests {
    let test: TestApp
    let app: AppModel
    let model: ConnectModel

    init() async throws {
        test = try TestApp()
        app = test.launch()
        await app.start()
        model = ConnectModel(app: app)
        model.addressText = test.household.stub.baseURL.absoluteString
    }

    @Test func aNewInstallOpensOnConnect() {
        #expect(app.phase == .connect)
        #expect(app.connectNotice == nil)
        #expect(model.step == .discover)
    }

    @Test func somethingThatIsNotAnAddressIsRefusedWithoutAsking() async {
        model.addressText = "not an address"
        await model.findServer()
        #expect(model.problem == .invalidAddress)
        #expect(test.household.stub.recorded.isEmpty)
    }

    @Test func aServerThatDoesNotAnswerIsUnreachableNotRefused() async {
        test.household.change { $0.offline = true }
        await model.findServer()
        #expect(model.problem == .unreachable)
        #expect(model.step == .discover)
        #expect(model.problem?.explanation.contains("Tailscale") == true)
    }

    @Test func theServersNameIsShownBeforePairing() async {
        await model.findServer()
        guard case .server(let server) = model.step else {
            Issue.record("Expected the server step, got \(model.step)")
            return
        }
        #expect(server.name == "Family Pi")
        #expect(model.problem == nil)
        // Nothing was asked of the server beyond its name.
        #expect(test.household.stub.recorded.map(\.path) == ["/v1/server"])
    }

    @Test func theAddressIsRememberedForNextTime() async {
        await model.findServer()
        #expect(ConnectModel(app: app).addressText == test.household.stub.baseURL.absoluteString)
    }

    @Test func aCodeIsShownAndApprovalPairsTheDevice() async throws {
        await model.findServer()
        await model.requestCode()
        guard case .code(let request, _) = model.step else {
            Issue.record("Expected the code step, got \(model.step)")
            return
        }
        #expect(request.code == "482913")
        #expect(app.phase == .connect)

        test.household.change { $0.approved = true }
        await model.waitUntilPaired()

        #expect(app.phase == .chooseProfile)
        #expect(app.profiles.map(\.name) == ["Alex", "Kids"])
        #expect(await test.credentials.token(forServer: "server-1") == "device-token")
        #expect(test.environment.preferences.connection?.serverName == "Family Pi")
        let sent = try #require(test.household.stub.requests("POST", "/v1/pairing/requests").first)
        #expect(sent.json()["deviceName"] as? String == "Test iPhone")
        #expect(sent.json()["platform"] as? String == "ios")
    }

    @Test func anExpiredCodeSaysSoAndOffersANewOne() async {
        await model.findServer()
        test.household.change { $0.codeExpired = true }
        await model.requestCode()
        await model.waitUntilPaired()
        #expect(model.problem == .codeExpired)
        guard case .server = model.step else {
            Issue.record("Expected to be back at the server step, got \(model.step)")
            return
        }
        #expect(app.phase == .connect)
    }

    @Test func goingBackStopsWaitingForApproval() async {
        await model.findServer()
        await model.requestCode()
        model.back()
        test.household.change { $0.approved = true }
        await model.waitUntilPaired()
        #expect(app.phase == .connect)
        guard case .server = model.step else {
            Issue.record("Expected the server step, got \(model.step)")
            return
        }
    }

    @Test func aClaimedServerHasNoSetupSecretStep() async {
        await model.findServer()
        model.chooseSetupSecret()
        guard case .server = model.step else {
            Issue.record("A claimed server cannot be claimed again: \(model.step)")
            return
        }
    }

    @Test func aNewServerIsClaimedWithItsSetupSecret() async throws {
        test.household.change {
            $0.server.claimed = false
            $0.profiles = []
        }
        await model.findServer()
        model.chooseSetupSecret()

        model.setupSecretText = "wrong"
        await model.claim()
        #expect(model.problem == .refused("That is not the setup secret."))
        #expect(app.phase == .connect)

        model.setupSecretText = " the-setup-secret "
        await model.claim()
        #expect(app.phase == .chooseProfile)
        #expect(app.isManager)
        #expect(model.setupSecretText.isEmpty)

        // The manager adds the first viewer.
        try await app.addProfile(name: "Robin", color: "teal")
        #expect(app.profiles.map(\.name) == ["Robin"])
    }

    @Test func aNewOpenServerIsSetUpWithOneTapAndNoSecret() async throws {
        test.household.change {
            $0.server.claimed = false
            $0.server.claim = .open
            $0.profiles = []
        }
        await model.findServer()
        // No secret step on a server that asks for none.
        model.chooseSetupSecret()
        guard case .server = model.step else {
            Issue.record("Expected the server step, got \(model.step)")
            return
        }

        await model.setUp()
        #expect(app.phase == .chooseProfile)
        #expect(app.isManager)
        let claim = try #require(test.household.stub.requests("POST", "/v1/pairing/claim").first)
        #expect(claim.json()["setupSecret"] == nil)
        #expect(test.household.current.server.claimed)
    }

    @Test func aServerThatAsksForItsSecretIsNotSetUpWithOneTap() async {
        test.household.change { $0.server.claimed = false }
        await model.findServer()
        await model.setUp()
        #expect(app.phase == .connect)
        #expect(test.household.stub.requests("POST", "/v1/pairing/claim").isEmpty)
    }

    @Test func theSecondDeviceToSetUpAnOpenServerIsToldSomeoneWasFirst() async {
        test.household.change {
            $0.server.claimed = false
            $0.server.claim = .open
        }
        await model.findServer()
        // Another device claims it while this one shows the button.
        test.household.change { $0.server.claimed = true }
        await model.setUp()
        #expect(app.phase == .connect)
        #expect(model.problem == .refused("Someone else has just set up this server. Ask them to approve this device."))
        // The screen now offers pairing with a code.
        guard case .server(let server) = model.step else {
            Issue.record("Expected the server step, got \(model.step)")
            return
        }
        #expect(server.claimed)
    }

    @Test func aDeviceThatCannotKeepACredentialDoesNotPairOrClaim() async throws {
        struct BrokenKeychain: CredentialStore {
            func token(forServer serverID: String) async throws -> String? { nil }
            func setToken(_ token: String, forServer serverID: String) async throws { throw CocoaError(.fileWriteNoPermission) }
            func removeToken(forServer serverID: String) async throws {}
        }
        var environment = test.environment
        environment.credentials = BrokenKeychain()
        test.household.change { $0.server.claimed = false }
        let app = AppModel(environment: environment)
        await app.start()
        let model = ConnectModel(app: app)
        model.addressText = test.household.stub.baseURL.absoluteString
        await model.findServer()

        await model.requestCode()
        guard case .keychain = model.problem else {
            Issue.record("Expected the Keychain to be named, got \(String(describing: model.problem))")
            return
        }
        model.chooseSetupSecret()
        model.setupSecretText = "the-setup-secret"
        await model.claim()

        // The credential is handed out once: nothing was asked for that could not be kept.
        #expect(test.household.stub.recorded.map(\.path) == ["/v1/server"])
        #expect(!test.household.current.server.claimed)
        #expect(app.phase == .connect)
    }

    @Test func anUnencryptedAddressOnTheInternetIsNotPairedWith() async {
        model.addressText = "http://lobby.example.com:8674"
        await model.findServer()
        guard case .refused = model.problem else {
            Issue.record("Expected a refusal, got \(String(describing: model.problem))")
            return
        }
        #expect(model.step == .discover)
    }

    // MARK: Servers found on the network

    /// A model whose network shows the given servers, all at the household's address.
    private func modelFinding(_ servers: [DiscoveredServer], denied: Bool = false) -> ConnectModel {
        var environment = test.environment
        let address = test.household.stub.baseURL
        environment.discover = {
            AsyncStream { continuation in
                continuation.yield(DiscoveryUpdate(servers: servers, isDenied: denied))
                continuation.finish()
            }
        }
        environment.addressOfDiscovered = { _ in address }
        return ConnectModel(app: AppModel(environment: environment))
    }

    @Test func connectStartsWithTheServersOnThisNetwork() async {
        let model = modelFinding([DiscoveredServer(name: "Family Pi", serverID: "server-1", version: "0.1.0")])
        #expect(model.step == .discover)
        await model.watchNetwork()
        #expect(model.discovered.map(\.name) == ["Family Pi"])
        #expect(!model.discoveryIsDenied)
    }

    @Test func tappingAFoundServerGoesStraightToItsPairingCode() async {
        let found = DiscoveredServer(name: "Family Pi", serverID: "server-1", version: "0.1.0")
        let model = modelFinding([found])
        await model.choose(found)
        guard case .code(let request, let server) = model.step else {
            Issue.record("Expected the pairing code, got \(model.step) \(String(describing: model.problem))")
            return
        }
        #expect(request.code == "482913")
        #expect(server.name == "Family Pi")
        #expect(model.addressText == test.household.stub.host)
        // Back from the code is the server, back from there the list: not the address field.
        model.back()
        model.back()
        #expect(model.step == .discover)
    }

    @Test func aNewServerShowsHowItIsSetUpInsteadOfACode() async {
        test.household.change { $0.server.claimed = false }
        let found = DiscoveredServer(name: "Family Pi", serverID: "server-1", version: "0.1.0")
        let model = modelFinding([found])
        await model.choose(found)
        guard case .server(let server) = model.step else {
            Issue.record("Expected the server step, got \(model.step)")
            return
        }
        #expect(!server.claimed)
        #expect(test.household.stub.requests("POST", "/v1/pairing/requests").isEmpty)
    }

    @Test func somethingElseAtTheAnnouncedAddressIsNotPairedWith() async {
        let impostor = DiscoveredServer(name: "Family Pi", serverID: "another-server", version: "0.1.0")
        let model = modelFinding([impostor])
        await model.choose(impostor)
        #expect(model.step == .discover)
        guard case .refused = model.problem else {
            Issue.record("Expected a refusal, got \(String(describing: model.problem))")
            return
        }
        #expect(test.household.stub.requests("POST", "/v1/pairing/requests").isEmpty)
    }

    @Test func withoutLeaveToLookAtTheNetworkTheAddressCanStillBeTyped() async {
        let model = modelFinding([], denied: true)
        await model.watchNetwork()
        #expect(model.discoveryIsDenied)
        #expect(model.discovered.isEmpty)
        model.enterAddress()
        #expect(model.step == .address)
        model.addressText = test.household.stub.baseURL.absoluteString
        await model.findServer()
        guard case .server = model.step else {
            Issue.record("Expected the server step, got \(model.step)")
            return
        }
        // Back from a typed server is the address field, and from there the list.
        model.back()
        #expect(model.step == .address)
        model.back()
        #expect(model.step == .discover)
    }
}
