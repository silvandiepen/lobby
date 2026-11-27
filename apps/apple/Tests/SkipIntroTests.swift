// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

/// What a viewer wants at intros and credits, chosen in the apps and kept with the viewer.
@MainActor
@Suite struct SkipIntroTests {
    private func household(bound: String? = nil) -> Household {
        Household(.init(
            device: Device(
                id: "dev-1", name: "Phone", platform: .ios, role: .viewer, createdAt: Make.epoch, kidsProfileId: bound, saysKidsProfile: true),
            profiles: [
                Profile(id: "adult", name: "Adult", color: "blue", saysKids: true, skipping: .defaults),
                Profile(id: "kid", name: "Kid", color: "green", kids: KidsSettings(), saysKids: true, skipping: .defaults),
            ],
            knowsKids: true))
    }

    @Test func aViewerChoosesAndTheChoiceIsKeptWithThem() async throws {
        let home = household()
        let app = try await TestApp(home).launchPaired(as: "adult")
        #expect(app.offersSkipPreferences)
        #expect(app.activeProfile?.skipPreferences == .defaults)
        try await app.setSkipPreferences(SkipPreferences(intro: .skip, credits: .off), profileID: "adult")
        #expect(home.current.profiles.first?.skipping == SkipPreferences(intro: .skip, credits: .off))
        #expect(app.profiles.first?.skipPreferences == SkipPreferences(intro: .skip, credits: .off))
        let put = try #require(home.stub.requests("PUT", "/v1/profiles/adult/skipping").last)
        #expect(put.json() as? [String: String] == ["intro": "skip", "credits": "off"])
        // A grown-up's device chooses for a kids viewer too.
        try await app.setSkipPreferences(SkipPreferences(intro: .off, credits: .show), profileID: "kid")
        #expect(home.current.profiles.last?.skipping?.intro == .off)
    }

    @Test func aChildsDeviceCannotChangeIt() async throws {
        let home = household(bound: "kid")
        let app = try await TestApp(home).launchPaired(as: "kid")
        await #expect(throws: (any Error).self) {
            try await app.setSkipPreferences(SkipPreferences(intro: .off, credits: .off), profileID: "kid")
        }
        #expect(home.current.profiles.last?.skipping == .defaults)
    }

    @Test func anOlderServerOffersNoChoice() async throws {
        let home = Household(.init(
            device: Device(id: "dev-1", name: "Phone", platform: .ios, role: .viewer, createdAt: Make.epoch),
            profiles: [Profile(id: "adult", name: "Adult", color: "blue")]))
        let app = try await TestApp(home).launchPaired(as: "adult")
        #expect(!app.offersSkipPreferences)
        // The player goes by the buttons then.
        #expect(app.activeProfile?.skipPreferences == .defaults)
    }

    #if !os(tvOS)
    @Test func theSettingsSayTheChoiceInWords() {
        #expect(SkipWords.summary(.defaults) == "Show Skip Intro")
        #expect(SkipWords.intro(.skip) == "Skip Automatically")
        #expect(SkipWords.credits(.show) == "Show Next Episode")
        #expect(SkipWords.credits(.off) == "Off")
    }
    #endif
}
