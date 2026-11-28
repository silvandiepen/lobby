// SPDX-License-Identifier: MPL-2.0

#if os(iOS) || os(macOS)
import Foundation
import LobbyKit
import Testing

@testable import Lobby

/// Which Apple push service a build's tokens belong to, and telling the server about the token
/// as soon as there is both a token and a server.
@MainActor
@Suite(.serialized) struct PushEnvironmentTests {
    /// A provisioning profile as the signing tool leaves it: a property list inside a signed blob.
    private func profile(_ entitlements: [String: String]) throws -> Data {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["Name": "Lobby development", "Entitlements": entitlements], format: .xml, options: 0)
        return Data([0x30, 0x82, 0x0a, 0x01, 0x06, 0x09]) + plist + Data([0x00, 0xff, 0x30, 0x82])
    }

    @Test func aDevelopmentSignedBuildGetsSandboxTokensWhateverItsConfiguration() throws {
        let data = try profile(["aps-environment": "development", "application-identifier": "T.mt.sil.lobby"])
        #expect(PushEnvironmentDetector.apsEnvironment(inProfile: data) == "development")
        #expect(PushEnvironmentDetector.environment(profile: data) == .development)
    }

    @Test func aProfileForProductionIsProduction() throws {
        let data = try profile(["aps-environment": "production"])
        #expect(PushEnvironmentDetector.environment(profile: data) == .production)
    }

    @Test func theMacsEntitlementNameIsRead() throws {
        let data = try profile(["com.apple.developer.aps-environment": "development"])
        #expect(PushEnvironmentDetector.environment(profile: data) == .development)
    }

    @Test func aProfileWithoutPushIsNotDevelopment() throws {
        let data = try profile(["application-identifier": "T.mt.sil.lobby"])
        #expect(PushEnvironmentDetector.apsEnvironment(inProfile: data) == nil)
        #expect(PushEnvironmentDetector.environment(profile: data) == .production)
    }

    @Test func somethingThatIsNoProfileSaysNothing() {
        #expect(PushEnvironmentDetector.apsEnvironment(inProfile: Data("garbage".utf8)) == nil)
        #expect(PushEnvironmentDetector.apsEnvironment(inProfile: Data("<?xml no end".utf8)) == nil)
    }

    // MARK: Telling the server

    private func household() -> Household {
        Household(.init(
            device: Device(id: "dev-1", name: "Phone", platform: .ios, role: .viewer, createdAt: Make.epoch),
            profiles: [Profile(id: "adult", name: "Adult", color: "blue")]))
    }

    private func puts(_ home: Household) -> Int {
        home.stub.recorded.filter { $0.method == "PUT" && $0.path == "/v1/me/push" }.count
    }

    @Test func aTokenThatCameBeforeTheServerWasReachedIsToldOnceItIs() async throws {
        let saved = PushCenter.shared.token
        defer { PushCenter.shared.token = saved }
        PushCenter.shared.token = Data([0x0a, 0xff, 0x01])
        let home = household()
        let test = try TestApp(home)

        // Not started, not connected: nothing to tell it to, and nothing is lost.
        let waiting = test.launch()
        await waiting.registerPushIfNeeded()
        #expect(puts(home) == 0)

        // The server comes up (the refresh, or the live channel opening): the token is told.
        let app = try await test.launchPaired()
        await app.registerPushIfNeeded()
        #expect(puts(home) >= 1)
        // And only once for the same token.
        let told = puts(home)
        await app.registerPushIfNeeded()
        #expect(puts(home) == told)
    }
}
#endif
