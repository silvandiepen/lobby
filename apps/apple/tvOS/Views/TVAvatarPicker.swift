// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// A viewer's picture, for the remote: the one in focus is large on the left, a press chooses
/// it. Menu goes back.
struct TVAvatarPicker: View {
    @State private var model: AvatarModel
    @FocusState private var focused: String?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.motion) private var motion

    private static let none = "none"
    private static let side: CGFloat = 170
    private static let columns = Array(repeating: GridItem(.fixed(side), spacing: 36), count: 5)

    init(app: AppModel, profileID: String) {
        _model = State(initialValue: AvatarModel(app: app, profileID: profileID))
    }

    var body: some View {
        HStack(alignment: .top, spacing: TVMetrics.gap * 2) {
            preview
            ScrollView {
                VStack(alignment: .leading, spacing: TVMetrics.gap) {
                    Button { choose(nil) } label: {
                        Label("No Picture", systemImage: model.choice == nil ? "checkmark" : "circle.slash")
                    }
                    .focused($focused, equals: Self.none)
                    .accessibilityAddTraits(model.choice == nil ? .isSelected : [])
                    .accessibilityIdentifier("avatar.none")
                    ForEach(Avatar.Group.allCases) { group in
                        Text(group.name)
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns: Self.columns, spacing: 36) {
                            ForEach(group.avatars) { cell($0) }
                        }
                        .focusSection()
                    }
                }
                .padding(TVMetrics.gap)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollClipDisabled()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.lobbyBackground(scheme).ignoresSafeArea())
        .defaultFocus($focused, model.choice ?? Self.none, priority: .userInitiated)
    }

    private func choose(_ id: String?) {
        Task { await model.choose(id) }
    }

    /// What is in focus, as it would look.
    private var shown: String? {
        guard let focused else { return model.choice }
        return focused == Self.none ? nil : focused
    }

    private var preview: some View {
        VStack(spacing: AppTheme.Space.l) {
            if let profile = model.profile {
                ProfileAvatar(name: profile.name, color: profile.color, avatar: shown, size: 320)
                    .id(shown)
                    .transition(.opacity)
                    .animation(motion.animation(.change), value: shown)
                Text(profile.name).font(.title2.weight(.semibold))
            }
            Text(Avatar(id: shown)?.name ?? String(localized: "No Picture"))
                .font(.headline.weight(.regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if let problem = model.problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(Color.lobbyWarning)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("avatar.problem")
                    .onAppear { AccessibilityNotification.Announcement(problem).post() }
            }
        }
        .frame(width: 420)
        .padding(.top, TVMetrics.gap)
    }

    private func cell(_ avatar: Avatar) -> some View {
        let isSelected = avatar.id == model.choice
        return Button { choose(avatar.id) } label: {
            AvatarPicture(avatar: avatar, size: Self.side)
                .hoverEffect(.highlight)
        }
        .buttonStyle(.borderless)
        .buttonBorderShape(.circle)
        .overlay(alignment: .bottomTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.lobbyProminentLabel(scheme), Color.lobbyProminentFill(scheme))
                    .accessibilityHidden(true)
            }
        }
        .focused($focused, equals: avatar.id)
        .accessibilityLabel(avatar.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("avatar.\(avatar.id)")
    }
}
