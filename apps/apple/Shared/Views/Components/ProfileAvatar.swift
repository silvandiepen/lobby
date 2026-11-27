// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// A viewer: their picture, or their colour and their initial.
struct ProfileAvatar: View {
    let name: String
    let color: String
    let avatar: String?
    var size: CGFloat = 32

    init(profile: Profile, size: CGFloat = 32) {
        self.init(name: profile.name, color: profile.color, avatar: profile.avatar, size: size)
    }

    /// A viewer who does not exist yet: the preview while one is being added.
    init(name: String, color: String, avatar: String? = nil, size: CGFloat = 32) {
        self.name = name
        self.color = color
        self.avatar = avatar
        self.size = size
    }

    var body: some View {
        Group {
            if let picture = Avatar(id: avatar) {
                AvatarPicture(avatar: picture, size: size)
            } else {
                Circle()
                    .fill(Color.lobbyProfile(color))
                    .frame(width: size, height: size)
                    .overlay {
                        Text(name.trimmingCharacters(in: .whitespaces).prefix(1).uppercased())
                            .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.lobbyOnArtwork)
                            .shadow(color: Color.lobbyArtworkScrim.opacity(0.35), radius: 1, y: 0.5)
                    }
            }
        }
        .accessibilityHidden(true)
    }
}

/// One of the pictures, round.
struct AvatarPicture: View {
    let avatar: Avatar
    let size: CGFloat

    var body: some View {
        Image(avatar.assetName)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}

extension ProfileAvatar {
    @MainActor private static var small: [Profile: Image] = [:]

    /// For a menu, which takes a ready picture and no view of its own.
    @MainActor static func menuImage(_ profile: Profile) -> Image? {
        if let known = small[profile] { return known }
        let renderer = ImageRenderer(content: ProfileAvatar(profile: profile, size: 24))
        renderer.scale = 3
        guard let picture = renderer.cgImage else { return nil }
        let image = Image(decorative: picture, scale: 3)
        small[profile] = image
        return image
    }
}
