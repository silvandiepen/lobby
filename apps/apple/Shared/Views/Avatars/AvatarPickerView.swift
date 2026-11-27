// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// A viewer's picture, in a sheet. Each choice is sent at once.
struct AvatarPickerSheet: View {
    @State private var model: AvatarModel

    init(app: AppModel, profileID: String) {
        _model = State(initialValue: AvatarModel(app: app, profileID: profileID))
    }

    var body: some View {
        LobbySheet(title: "Picture", width: 560, height: 560) {
            if let profile = model.profile {
                AvatarPage(
                    name: profile.name, color: profile.color, selection: model.choice, problem: model.problem
                ) { id in
                    Task { await model.choose(id) }
                }
            } else {
                ContentUnavailableView("This viewer was removed", systemImage: AppSymbol.viewers)
            }
        }
        #if os(iOS)
        .presentationSizing(.page)
        #endif
    }
}

/// A picture for a viewer who is being added: nothing is sent yet.
struct NewViewerAvatarSheet: View {
    let name: String
    let color: String
    @Binding var avatar: String?

    var body: some View {
        LobbySheet(title: "Picture", width: 560, height: 560) {
            AvatarPage(name: name, color: color, selection: avatar, problem: nil) { avatar = $0 }
        }
    }
}

/// The viewer as they look, and the pictures under it.
private struct AvatarPage: View {
    let name: String
    let color: String
    let selection: String?
    let problem: String?
    let choose: (String?) -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.motion) private var motion
    #if !os(macOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    /// A phone on its side has no room for a picture that stays.
    private var staysInSight: Bool {
        #if os(macOS)
        true
        #else
        verticalSizeClass != .compact
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(spacing: AppTheme.Space.l) {
                if !staysInSight { top }
                AvatarGrid(name: name, color: color, selection: selection, choose: choose)
            }
            .padding(AppTheme.Space.page)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if staysInSight {
                top
                    .padding(.vertical, AppTheme.Space.m)
                    .frame(maxWidth: .infinity)
                    .background(Color.lobbyBackground(scheme))
            }
        }
        .animation(motion.animation(.change), value: problem)
    }

    private var top: some View {
        VStack(spacing: AppTheme.Space.s) {
            AvatarPreview(name: name, color: color, avatar: selection)
            AvatarProblem(text: problem, tint: .lobbyFailure)
                .padding(.horizontal, AppTheme.Space.page)
        }
    }
}

/// A child's own picture: the only thing of a viewer it changes, so nobody is asked. The way out
/// for grown-ups is here too, and that does ask.
struct KidsAvatarPicker: View {
    @State private var model: AvatarModel
    let askGrownUp: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.motion) private var motion
    @Environment(\.dynamicTypeSize) private var typeSize

    #if os(macOS)
    private static let hint = "Asks for Touch ID or the password"
    #else
    private static let hint = "Asks for Face ID or the passcode"
    #endif

    init(app: AppModel, profileID: String, askGrownUp: @escaping () -> Void) {
        _model = State(initialValue: AvatarModel(app: app, profileID: profileID))
        self.askGrownUp = askGrownUp
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: AppTheme.Space.l) {
                    AvatarGrid(
                        name: model.profile?.name ?? "", color: model.profile?.color ?? "pink",
                        selection: model.choice, isKids: true
                    ) { id in
                        Task { await model.choose(id) }
                    }
                }
                .padding(KidsTheme.margin)
            }
            .scrollIndicators(.hidden)
            // Below the choices and always in sight: under them, a phone has to scroll past
            // forty pictures before a grown-up finds the way out.
            grownUps
        }
        .background { KidsTheme.page(contrast).ignoresSafeArea() }
        .presentationBackground { KidsTheme.page(contrast) }
        .animation(motion.animation(.change), value: model.problem)
        .preferredColorScheme(.dark)
        .environment(\.lobbyIsPlayful, true)
        #if os(macOS)
        .frame(width: 560, height: 620)
        #else
        .presentationSizing(.page)
        #endif
    }

    /// The picture as it is now and the way back stay in sight above the choices.
    private var header: some View {
        VStack(spacing: AppTheme.Space.m) {
            HStack(spacing: AppTheme.Space.m) {
                AvatarPreview(
                    name: model.profile?.name ?? "", color: model.profile?.color ?? "pink", avatar: model.choice, size: 92)
                    .shadow(color: KidsTheme.shadow, radius: 8, y: 4)
                Text("Your picture")
                    .kidsHeading(typeSize.isAccessibilitySize ? 24 : 32)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .kidsWords()
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                done
            }
            if model.problem != nil {
                AvatarProblem(text: model.problem, tint: .primary)
                    .padding(AppTheme.Space.m)
                    .background(KidsTheme.play, in: RoundedRectangle(cornerRadius: KidsTheme.posterRadius, style: .continuous))
                    // The bar is light in the dark too: dark words on it.
                    .environment(\.colorScheme, .light)
            }
        }
        .padding(.horizontal, KidsTheme.margin)
        .padding(.vertical, AppTheme.Space.m)
    }

    private var done: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "checkmark")
                .font(.system(size: 26, weight: .heavy))
                .foregroundStyle(KidsTheme.onPlay)
                .frame(width: 60, height: 60)
                .background(KidsTheme.button, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.lobbyPill)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Done")
        .accessibilityIdentifier("kids.avatars.done")
    }

    private var grownUps: some View {
        Button {
            askGrownUp()
        } label: {
            Text("For grown-ups")
                .font(.title3.weight(.bold))
                .foregroundStyle(KidsTheme.words)
                .padding(.horizontal, AppTheme.Space.l)
                .padding(.vertical, AppTheme.Space.m)
                .frame(minHeight: 44)
                .background(KidsTheme.quiet, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.lobbyPill)
        .padding(.horizontal, KidsTheme.margin)
        .padding(.vertical, AppTheme.Space.m)
        .accessibilityHint(Self.hint)
        .accessibilityIdentifier("kids.grownUps")
    }
}
