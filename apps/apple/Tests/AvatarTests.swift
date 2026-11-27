// SPDX-License-Identifier: MPL-2.0
import CoreGraphics
import Foundation
import LobbyKit
import SwiftUI
import Testing

@testable import Lobby

/// The viewers' pictures: what there is, choosing one, and what happens when it cannot be saved.
@MainActor
@Suite struct AvatarTests {
    private func household(
        avatar: String? = nil, knowsAvatars: Bool = true, bound: String? = nil, offline: Bool = false
    ) -> Household {
        Household(.init(
            device: Device(
                id: "dev-1", name: "Phone", platform: .ios, role: .viewer, createdAt: Make.epoch, kidsProfileId: bound, saysKidsProfile: true),
            profiles: [
                Profile(id: "adult", name: "Adult", color: "blue", avatar: avatar, saysAvatar: knowsAvatars, saysKids: true),
                Profile(id: "kid", name: "Kid", color: "green", saysAvatar: knowsAvatars, kids: KidsSettings(), saysKids: true),
            ],
            knowsKids: true, knowsAvatars: knowsAvatars, offline: offline))
    }

    // MARK: The set

    @Test func thereAreSixteenOfEachAndEveryOneHasAPictureAndAName() throws {
        let all = Avatar.Group.allCases.flatMap(\.avatars)
        #expect(Avatar.characters.count == 16)
        #expect(Avatar.animals.count == 16)
        #expect(Set(all.map(\.id)).count == 32)
        #expect(Set(all.map(\.name)).count == 32)
        for avatar in all {
            let renderer = ImageRenderer(content: AvatarPicture(avatar: avatar, size: 40))
            let picture = try #require(renderer.cgImage)
            #expect(try Self.hasInk(picture), "\(avatar.id) has no picture")
            // What the server takes.
            #expect(avatar.id.wholeMatch(of: /[a-z0-9]+(-[a-z0-9]+)*/) != nil)
            #expect(avatar.id.count <= 40)
        }
    }

    /// Something opaque in the middle.
    private static func hasInk(_ image: CGImage) throws -> Bool {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel[3] > 100
    }

    @Test func aPictureOnlyANewerAppHasIsTheLetter() {
        #expect(Avatar(id: "from-a-newer-app") == nil)
        #expect(Avatar(id: nil) == nil)
        #expect(Avatar(id: "panda")?.name == "Panda")
    }

    @Test func theArrowKeysReachEveryPictureAndStopAtTheEnds() {
        for columns in [3, 4, 8] {
            var id: String? = nil
            var seen: [String?] = [nil]
            for _ in 0..<32 {
                id = AvatarKeys.step(.right, from: id, columns: columns)
                seen.append(id)
            }
            #expect(seen == [nil] + (Avatar.characters + Avatar.animals).map(\.id))
            #expect(AvatarKeys.step(.right, from: id, columns: columns) == id)
            #expect(AvatarKeys.step(.left, from: nil, columns: columns) == nil)
            #expect(AvatarKeys.step(.up, from: nil, columns: columns) == nil)
            // Down and up again is the same place, in the same column.
            #expect(AvatarKeys.step(.down, from: nil, columns: columns) == Avatar.characters[0].id)
            let second = Avatar.characters[1].id
            let below = AvatarKeys.step(.down, from: second, columns: columns)
            #expect(below == Avatar.characters[1 + columns].id)
            #expect(AvatarKeys.step(.up, from: below, columns: columns) == second)
        }
        // From the last row of a group into the next group.
        #expect(AvatarKeys.step(.down, from: Avatar.characters[13].id, columns: 4) == Avatar.animals[1].id)
        // A row that is shorter: its last one.
        #expect(AvatarKeys.step(.down, from: Avatar.characters[14].id, columns: 3) == Avatar.characters[15].id)
    }

    // MARK: Choosing

    @Test func aViewersDeviceChoosesAPictureWhichIsThereOfflineToo() async throws {
        let home = household()
        let test = try TestApp(home)
        let app = try await test.launchPaired(as: "adult")
        let model = AvatarModel(app: app, profileID: "adult")
        await model.choose("panda")
        #expect(model.problem == nil)
        #expect(home.current.profiles.map(\.avatar) == ["panda", nil])
        #expect(app.activeProfile?.avatar == "panda")
        #expect(app.profiles.first?.avatar == "panda")

        home.change { $0.offline = true }
        let again = test.launch()
        await again.start()
        #expect(again.activeProfile?.avatar == "panda")

        home.change { $0.offline = false }
        await again.refresh()
        await AvatarModel(app: again, profileID: "adult").choose(nil)
        #expect(home.current.profiles.map(\.avatar) == [nil, nil])
        #expect(again.activeProfile?.avatar == nil)
    }

    @Test func aPictureChosenElsewhereComesWithARefresh() async throws {
        let home = household(avatar: "fox")
        let app = try await TestApp(home).launchPaired(as: "adult")
        #expect(app.activeProfile?.avatar == "fox")
        home.change { $0.profiles[0].avatar = "owl" }
        await app.refresh()
        #expect(app.activeProfile?.avatar == "owl")
    }

    @Test func outOfReachItStaysAsItWasAndSaysSo() async throws {
        let home = household(avatar: "fox")
        let app = try await TestApp(home).launchPaired(as: "adult")
        home.change { $0.offline = true }
        let model = AvatarModel(app: app, profileID: "adult")
        await model.choose("panda")
        #expect(model.choice == "fox")
        #expect(model.problem?.contains("cannot be reached") == true)
        #expect(app.activeProfile?.avatar == "fox")
        // And nothing is sent by itself later.
        home.change { $0.offline = false }
        await app.refresh()
        #expect(home.current.profiles[0].avatar == "fox")
        await model.choose("panda")
        #expect(model.problem == nil)
        #expect(home.current.profiles[0].avatar == "panda")
    }

    @Test func anOlderServerIsNotAskedForPictures() async throws {
        let app = try await TestApp(household(knowsAvatars: false)).launchPaired(as: "adult")
        #expect(!app.offersAvatars)
        let model = AvatarModel(app: app, profileID: "adult")
        await model.choose("panda")
        #expect(model.choice == nil)
        #expect(model.problem == AvatarsUnsupported().errorDescription)
    }

    @Test func aChildsDeviceChangesOnlyItsOwnPictureAndStaysInKidsMode() async throws {
        let home = household(bound: "kid")
        let test = try TestApp(home)
        test.environment.hasKidsScreens = true
        let app = try await test.launchPaired(as: "kid")
        #expect(app.showsKidsScreens)
        let own = AvatarModel(app: app, profileID: "kid")
        await own.choose("unicorn")
        #expect(own.problem == nil)
        #expect(app.activeProfile?.avatar == "unicorn")
        let other = AvatarModel(app: app, profileID: "adult")
        await other.choose("unicorn")
        #expect(other.problem != nil)
        #expect(home.current.profiles.map(\.avatar) == [nil, "unicorn"])
        #expect(app.showsKidsScreens)
        #expect(app.phase == .library)
    }

    @Test func aNewViewerComesWithTheirPicture() async throws {
        let home = household()
        home.change { $0.device.role = .manager }
        let app = try await TestApp(home).launchPaired(as: "adult")
        try await app.addProfile(name: "New", color: "pink", avatar: "robot")
        #expect(app.profiles.last?.avatar == "robot")
    }
}
