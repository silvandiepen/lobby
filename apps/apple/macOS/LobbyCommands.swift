// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// What the menu bar depends on, read from the app model by the `App`'s own body. That body is
/// evaluated again when any of it changes, and the menus with it. (Menu content that reads an
/// observable model by itself is not rebuilt when the model changes.)
struct MenuState: Equatable {
    var showsLibrary: Bool
    var isManager: Bool
    /// A manager of the server itself, not of a guest household.
    var isOwnerManager: Bool
    /// The kids screens: nothing in the menus leads anywhere else.
    var isKids: Bool
    var isRefreshing: Bool
    var profiles: [Profile]
    var activeProfileID: String?
    var hasPlayer: Bool
    var isPlaying: Bool
    var hasNextEpisode: Bool

    @MainActor
    init(_ app: AppModel) {
        showsLibrary = app.phase == .library
        isManager = app.isManager && !app.showsKidsScreens
        isOwnerManager = app.isOwnerManager && !app.showsKidsScreens
        isKids = app.showsKidsScreens
        isRefreshing = app.isRefreshing
        profiles = app.profiles
        activeProfileID = app.activeProfile?.id
        hasPlayer = app.player != nil
        isPlaying = app.player?.isPlaying == true
        hasNextEpisode = app.player?.upNext != nil
    }
}

/// The menu bar: every section of the sidebar, search, refresh, the viewers and playback have
/// a menu item and a key.
struct LobbyCommands: Commands {
    let app: AppModel
    let state: MenuState

    var body: some Commands {
        // One window, one library: there is nothing to make new.
        CommandGroup(replacing: .newItem) {}

        CommandGroup(after: .newItem) {
            Button("Upload…") { app.showsUploads = true }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(!state.isManager || !state.showsLibrary)
        }

        CommandGroup(after: .sidebar) {
            SectionCommands(app: app, state: state)
        }

        CommandGroup(after: .textEditing) {
            FindCommand(app: app, state: state)
        }

        CommandMenu("Viewer") {
            ViewerCommands(app: app, state: state)
        }

        CommandMenu("Playback") {
            PlaybackCommands(app: app, state: state)
        }
    }
}

private struct SectionCommands: View {
    let app: AppModel
    let state: MenuState

    var body: some View {
        Divider()
        if state.isKids {
            ForEach(Array(app.kidsSections.enumerated()), id: \.element) { index, place in
                Button(place.name) {
                    app.kidsPath = []
                    app.kidsSection = place
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                .disabled(!state.showsLibrary || state.hasPlayer)
            }
        } else {
            section("Home", .library, "1")
            section("Movies", .movies, "2")
            section("Series", .series, "3")
            section("Downloads", .downloads, "4")
        }
        if state.isManager {
            section("Devices and Viewers", .manage, "5")
        }
        if state.isOwnerManager {
            section("Categories", .categories, "6")
        }
        Divider()
        Button("Refresh") {
            Task { await app.refresh() }
        }
        .keyboardShortcut("r")
        .disabled(!state.showsLibrary || state.isRefreshing)
    }

    private func section(_ title: String, _ item: SidebarItem, _ key: KeyEquivalent) -> some View {
        Button(title) {
            app.sidebarSelection = item
        }
        .keyboardShortcut(key)
        .disabled(!state.showsLibrary || state.hasPlayer)
    }
}

private struct FindCommand: View {
    let app: AppModel
    let state: MenuState

    var body: some View {
        Button("Find in Library") {
            app.isSearching = true
        }
        .keyboardShortcut("f")
        .disabled(!state.showsLibrary || state.hasPlayer || state.isKids)
    }
}

private struct ViewerCommands: View {
    let app: AppModel
    let state: MenuState

    var body: some View {
        // In kids mode the way out is only in the child's own menu, behind its picture.
        if !state.isKids {
            ForEach(state.profiles) { profile in
                Toggle(isOn: Binding(
                    get: { state.activeProfileID == profile.id },
                    set: { chosen in
                        if chosen { Task { await app.selectProfile(profile) } }
                    })
                ) {
                    Label {
                        Text(profile.name)
                    } icon: {
                        ProfileAvatar.menuImage(profile)
                    }
                }
            }
            Divider()
            Button("All Viewers…") {
                app.chooseAnotherProfile()
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(!state.showsLibrary)
        }
    }
}

private struct PlaybackCommands: View {
    let app: AppModel
    let state: MenuState

    var body: some View {
        Button(state.isPlaying ? "Pause" : "Play") {
            app.player?.togglePlayback()
        }
        .keyboardShortcut("p")
        .disabled(!state.hasPlayer)
        Button("Play Next Episode") {
            app.player?.playNext()
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(!state.hasNextEpisode)
        Divider()
        Button("Close Player") {
            Task { await app.player?.close() }
        }
        .keyboardShortcut("w", modifiers: [.command, .shift])
        .disabled(!state.hasPlayer)
    }
}
