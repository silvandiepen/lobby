// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// Who is watching? Large pictures in the middle of the screen, with the remote on whoever
/// watched last. Back leaves everything as it was.
struct TVProfilePicker: View {
    @Environment(AppModel.self) private var app
    @FocusState private var focused: String?
    @State private var picking: Profile?

    private static let columns = 5

    var body: some View {
        VStack(spacing: AppTheme.Space.xl * 2) {
            VStack(spacing: AppTheme.Space.m) {
                Text("Who is watching?")
                    .font(.system(size: 64, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                if app.serverIsOutOfReach, !app.profiles.isEmpty {
                    Label("Lobby Server cannot be reached. Lobby keeps looking.", systemImage: "wifi.slash")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if app.profiles.isEmpty {
                empty
            } else {
                viewers
                if app.offersAvatars {
                    Menu {
                        ForEach(app.profiles) { profile in
                            Button(profile.name) { picking = profile }
                        }
                    } label: {
                        Label("Change Picture", systemImage: AppSymbol.picture)
                    }
                    .accessibilityIdentifier("profile.pictures")
                    .frame(maxWidth: .infinity)
                    .focusSection()
                }
            }
            // The viewers are of one server: another one is a choice away.
            ServerSwitcherButton()
                .frame(maxWidth: .infinity)
                .focusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fullScreenCover(item: $picking) { TVAvatarPicker(app: app, profileID: $0.id) }
        .task { await app.watchProfiles() }
        .defaultFocus($focused, preferred, priority: .userInitiated)
        // Somebody was watching: Back is back to that. Nobody yet: Back leaves the app.
        .onExitCommand(perform: app.activeProfile == nil ? nil : { app.returnToLibrary() })
    }

    private var preferred: String? {
        let active = app.activeProfile?.id
        return app.profiles.contains { $0.id == active } ? active : app.profiles.first?.id
    }

    /// Up to five beside each other, in the middle; more make rows, and many rows scroll.
    private var viewers: some View {
        let rows = stride(from: 0, to: app.profiles.count, by: Self.columns).map {
            Array(app.profiles[$0..<min($0 + Self.columns, app.profiles.count)])
        }
        let grid = VStack(spacing: AppTheme.Space.xl) {
            ForEach(rows, id: \.first?.id) { row in
                HStack(alignment: .top, spacing: TVMetrics.gap) {
                    ForEach(row) { viewer($0) }
                }
                .frame(maxWidth: .infinity)
                .focusSection()
            }
        }
        .padding(.vertical, AppTheme.Space.xl)
        return ViewThatFits(in: .vertical) {
            grid
            ScrollView { grid }.scrollClipDisabled()
        }
    }

    private func viewer(_ profile: Profile) -> some View {
        Button {
            Task { await app.selectProfile(profile) }
        } label: {
            Color.clear.frame(width: TVMetrics.viewer + 60, height: TVMetrics.viewer + 130)
        }
        .buttonStyle(TVViewerStyle(profile: profile))
        .focused($focused, equals: profile.id)
        .accessibilityLabel(profile.kids == nil ? profile.name : "\(profile.name), kids")
        .accessibilityIdentifier("profile.\(profile.name)")
    }

    @ViewBuilder
    private var empty: some View {
        if app.connectivity == .offline {
            TVNotice(
                symbol: "wifi.slash", tint: Color.lobbyWarning, title: "Lobby Server cannot be reached",
                text: "The viewers could not be fetched. Lobby keeps trying. Away from home, check that Tailscale is connected.")
            Button("Try Again", systemImage: AppSymbol.refresh) { Task { await app.refresh() } }
        } else if !app.hasFetchedProfiles {
            ProgressView("Fetching the viewers…")
        } else {
            TVNotice(
                symbol: AppSymbol.viewers, tint: NavigationTint.series, title: "There are no viewers yet",
                text: "A manager adds them on an iPhone, iPad or Mac, one for each person who watches. They appear here by themselves.")
        }
    }
}

/// A viewer: a round picture that grows and glows when it has the remote, and the name.
private struct TVViewerStyle: ButtonStyle {
    let profile: Profile

    func makeBody(configuration: Configuration) -> some View {
        Face(profile: profile, isPressed: configuration.isPressed)
    }

    private struct Face: View {
        let profile: Profile
        let isPressed: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.motion) private var motion

        var body: some View {
            VStack(spacing: AppTheme.Space.xl) {
                ProfileAvatar(profile: profile, size: TVMetrics.viewer)
                    .overlay(alignment: .bottomTrailing) {
                        if profile.kids != nil { KidsDoorMark(size: TVMetrics.viewer * 0.3) }
                    }
                    .background {
                        if isFocused {
                            // Soft from its own gradient: no blur to be drawn for it.
                            Circle()
                                .fill(RadialGradient(
                                    colors: [Color.lobbyProfile(profile.color).opacity(0.75), Color.lobbyProfile(profile.color).opacity(0)],
                                    center: .center, startRadius: TVMetrics.viewer * 0.42, endRadius: TVMetrics.viewer * 0.66))
                                .scaleEffect(1.32)
                                .transition(.opacity)
                        }
                    }
                    .overlay { Circle().strokeBorder(Color.white.opacity(isFocused ? 0.95 : 0), lineWidth: 6) }
                    .overlay(alignment: .bottomTrailing) {
                        if profile.kids != nil {
                            Text("Kids")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.lobbyOnArtwork)
                                .padding(.horizontal, AppTheme.Space.m)
                                .padding(.vertical, AppTheme.Space.xs)
                                .background(Color.black.opacity(0.72), in: Capsule())
                        }
                    }
                    .scaleEffect(isPressed ? 1.02 : isFocused && motion.moves ? 1.12 : 1)
                Text(profile.name)
                    .font(.headline.weight(isFocused ? .bold : .regular))
                    .foregroundStyle(isFocused ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(width: TVMetrics.viewer + 60, height: TVMetrics.viewer + 130)
            .contentShape(Rectangle())
            .animation(motion.animation(.hover), value: isFocused)
        }
    }
}
