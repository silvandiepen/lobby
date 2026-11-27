// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// The pictures to choose from: no picture, the characters and the animals. On the Mac the
/// arrow keys move through them and the space bar chooses.
struct AvatarGrid: View {
    /// Whose picture: their letter stands for "no picture".
    let name: String
    let color: String
    let selection: String?
    var isKids = false
    let choose: (String?) -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.motion) private var motion
    @State private var width: CGFloat = 0
    @FocusState private var focused: String?

    /// Stands for "no picture" where an id is asked for.
    private static let none = "none"
    private static let gap: CGFloat = 8

    var body: some View {
        ScrollViewReader { scroll in
            VStack(alignment: .leading, spacing: AppTheme.Space.l) {
                noPicture
                    .id(Self.none)
                ForEach(Avatar.Group.allCases) { group in
                    VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                        Text(group.name)
                            .font(isKids ? .title.weight(.heavy) : .title3.weight(.semibold))
                            .foregroundStyle(isKids ? KidsTheme.words : .primary)
                            .accessibilityAddTraits(.isHeader)
                        rows(group)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            #if os(macOS)
            .onMoveCommand { direction in
                let step: AvatarKeys.Step = switch direction {
                case .up: .up
                case .down: .down
                case .left: .left
                default: .right
                }
                focused = key(AvatarKeys.step(step, from: focused == Self.none ? nil : focused ?? selection, columns: columns))
            }
            .defaultFocus($focused, key(selection))
            #endif
            .onChange(of: focused) { _, id in
                guard let id else { return }
                withAnimation(motion.animation(.list)) { scroll.scrollTo(id) }
            }
            // The one a viewer has is in sight.
            .task(id: width > 0) {
                if width > 0, let selection { scroll.scrollTo(selection, anchor: .center) }
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func key(_ id: String?) -> String { id ?? Self.none }

    // MARK: Sizes

    private var columns: Int {
        if isKids { return width >= 480 ? 4 : 3 }
        return width >= 620 ? 8 : 4
    }

    private var side: CGFloat {
        max(44, ((width - CGFloat(columns - 1) * Self.gap) / CGFloat(columns)).rounded(.down))
    }

    // MARK: Cells

    private func rows(_ group: Avatar.Group) -> some View {
        let avatars = group.avatars
        return VStack(alignment: .leading, spacing: Self.gap) {
            ForEach(Array(stride(from: 0, to: avatars.count, by: columns)), id: \.self) { start in
                HStack(spacing: Self.gap) {
                    ForEach(avatars[start..<min(start + columns, avatars.count)]) { cell($0) }
                }
            }
        }
    }

    private func cell(_ avatar: Avatar) -> some View {
        let isSelected = avatar.id == selection
        return Button {
            choose(avatar.id)
        } label: {
            AvatarPicture(avatar: avatar, size: max(36, side - 12))
                .frame(width: side, height: side)
                .background(fill(isSelected), in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
                .overlay(alignment: .bottomTrailing) { if isSelected { mark } }
                .animation(motion.animation(.change), value: isSelected)
                .contentShape(Rectangle())
        }
        .buttonStyle(TileButtonStyle(lifts: false))
        .modifier(KeyChoice(focused: $focused, id: avatar.id) { choose(avatar.id) })
        .id(avatar.id)
        .accessibilityLabel(avatar.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("avatar.\(avatar.id)")
    }

    private var noPicture: some View {
        let isSelected = selection == nil
        return Button {
            choose(nil)
        } label: {
            HStack(spacing: AppTheme.Space.m) {
                ProfileAvatar(name: name, color: color, size: isKids ? 52 : 40)
                Text("No Picture")
                    .font(isKids ? .title3.weight(.heavy) : .body)
                    .foregroundStyle(isKids ? (isSelected ? KidsTheme.avatar : KidsTheme.words) : .primary)
                if isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.bold)
                        .foregroundStyle(isKids ? KidsTheme.avatar : .primary)
                        .accessibilityHidden(true)
                }
            }
            .padding(AppTheme.Space.s)
            .padding(.trailing, AppTheme.Space.s)
            .background(fill(isSelected), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.lobbyPill)
        .modifier(KeyChoice(focused: $focused, id: Self.none) { choose(nil) })
        .accessibilityLabel("No Picture")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("avatar.none")
    }

    private func fill(_ isSelected: Bool) -> Color {
        guard isSelected else { return .clear }
        return isKids ? KidsTheme.button : Color.lobbySelection(scheme)
    }

    private var mark: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(isKids ? .title : .title3)
            .symbolRenderingMode(.palette)
            .foregroundStyle(isKids ? Color.white : Color.lobbyProminentLabel(scheme), isKids ? KidsTheme.avatar : Color.lobbyProminentFill(scheme))
            .padding(2)
            .transition(motion.moves ? .scale.combined(with: .opacity) : .opacity)
            .accessibilityHidden(true)
    }
}

/// The Mac's buttons take the keyboard only with Keyboard Navigation on; these always do.
private struct KeyChoice: ViewModifier {
    let focused: FocusState<String?>.Binding
    let id: String
    let choose: () -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .focusable(interactions: .edit)
            .focused(focused, equals: id)
            .onKeyPress(.space) {
                choose()
                return .handled
            }
        #else
        content
            .focused(focused, equals: id)
        #endif
    }
}

/// The viewer as they look now, above the pictures.
struct AvatarPreview: View {
    let name: String
    let color: String
    let avatar: String?
    var size: CGFloat = 112
    @Environment(\.motion) private var motion

    var body: some View {
        ProfileAvatar(name: name, color: color, avatar: avatar, size: size)
            .id(avatar)
            .transition(motion.moves ? .scale(scale: 0.8).combined(with: .opacity) : .opacity)
            .animation(motion.animation(.change), value: avatar)
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityAddTraits(.isImage)
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityIdentifier("avatar.preview")
    }

    private var label: String {
        let picture = Avatar(id: avatar)?.name ?? String(localized: "No Picture")
        return name.isEmpty ? picture : "\(name): \(picture)"
    }
}

/// Why a picture could not be changed. Said aloud too.
struct AvatarProblem: View {
    let text: String?
    let tint: Color

    var body: some View {
        if let text {
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(tint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("avatar.problem")
                .onAppear { AccessibilityNotification.Announcement(text).post() }
        }
    }
}
