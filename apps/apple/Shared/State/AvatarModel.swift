// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Observation

/// Choosing one viewer's picture. A choice shows and is sent at once; when it cannot be saved
/// the picture is what it was, and `problem` says why.
@MainActor
@Observable
final class AvatarModel {
    let profileID: String
    /// What is chosen on screen, which may still be on its way.
    private(set) var choice: String?
    private(set) var isSaving = false
    private(set) var problem: String?
    private let app: AppModel
    private var saved: String?

    init(app: AppModel, profileID: String) {
        self.app = app
        self.profileID = profileID
        load()
    }

    /// The viewer, with the choice on screen.
    var profile: Profile? {
        let known = app.profiles.first { $0.id == profileID } ?? app.activeProfile.flatMap { $0.id == profileID ? $0 : nil }
        guard var profile = known else { return nil }
        profile.avatar = choice
        return profile
    }

    /// Takes over what the server says, unless a choice is on its way.
    func load() {
        guard !isSaving else { return }
        choice = app.profiles.first { $0.id == profileID }?.avatar
        saved = choice
    }

    func choose(_ avatar: String?) async {
        problem = nil
        choice = avatar
        // One at a time, the newest last: the one under way sends what came meanwhile.
        guard !isSaving else { return }
        isSaving = true
        while choice != saved {
            let sending = choice
            do {
                try await app.setAvatar(sending, profileID: profileID)
                saved = sending
            } catch {
                choice = saved
                problem = await Self.words(for: error, app: app)
                break
            }
        }
        isSaving = false
    }

    private static func words(for error: any Error, app: AppModel) async -> String? {
        if (error as? LobbyError)?.isUnreachable == true {
            return String(localized: "Lobby Server cannot be reached, so the picture stays as it was. Try again later.")
        }
        return await app.managerProblem(error)
    }
}
