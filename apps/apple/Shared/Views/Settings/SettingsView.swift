// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// The viewer button in the toolbar: switch viewer, or open Settings.
struct ProfileMenu: View {
    @Environment(AppModel.self) private var app
    @State private var showsSettings = false
    @State private var showsStats = false
    @State private var picking: Profile?
    /// The avatar's size: larger beside the Library's title on a phone than in a toolbar.
    var size: CGFloat = 30

    var body: some View {
        Menu {
            Section("Who is watching?") {
                ForEach(app.profiles) { profile in
                    Toggle(isOn: Binding(
                        get: { profile.id == app.activeProfile?.id },
                        set: { _ in Task { await app.selectProfile(profile) } })
                    ) {
                        Label {
                            Text(profile.name)
                        } icon: {
                            ProfileAvatar.menuImage(profile)
                        }
                    }
                }
            }
            if let profile = app.activeProfile, app.offersAvatars {
                Button("Choose a Picture…", systemImage: AppSymbol.picture) { picking = profile }
                    .accessibilityIdentifier("profile.picture")
            }
            // None in kids mode (docs/decisions.md, "Who sees which statistics").
            if app.activeProfile != nil, app.statsAccess.showsOwn {
                Button(StatsSummary.headline(.month) + "…", systemImage: "chart.bar.xaxis") { showsStats = true }
                    .accessibilityIdentifier("profile.stats")
            }
            Button("All Viewers…", systemImage: "person.2") {
                app.chooseAnotherProfile()
            }
            ServerChoices()
            #if os(macOS)
            // On the Mac, Settings is its own window (⌘,).
            SettingsLink {
                Label("Settings…", systemImage: "gearshape")
            }
            #else
            Button("Settings…", systemImage: "gearshape") {
                showsSettings = true
            }
            #endif
        } label: {
            if let profile = app.activeProfile {
                ProfileAvatar(profile: profile, size: size)
            } else {
                Image(systemName: "person.crop.circle")
            }
        }
        #if os(macOS)
        // The Mac's own menu button keeps only the letter of the avatar, white on any window.
        .menuStyle(.button)
        .buttonStyle(.lobbyIcon)
        #endif
        .accessibilityLabel(app.activeProfile.map { "Viewer: \($0.name)" } ?? "Viewer")
        .accessibilityIdentifier("profile.menu")
        .sheet(isPresented: $showsSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showsStats) {
            if let profile = app.activeProfile { StatsSheet(profileID: profile.id) }
        }
        .sheet(item: $picking) { AvatarPickerSheet(app: app, profileID: $0.id) }
    }
}

/// Settings: which server, what this device is to it, and Sign Out.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(ServersModel.self) private var servers
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsSignOut = false
    @State private var picking: Profile?
    @State private var showsSetup = false
    @AppStorage(KidsIconRule.settingKey) private var kidsIconIsOn = true

    var body: some View {
        NavigationStack {
            LobbyForm {
                if servers.canChangeServers {
                    Section {
                        NavigationLink(value: Route.servers) {
                            HStack(spacing: AppTheme.Space.m) {
                                if let account = servers.activeAccount { ServerBadge(account: account, size: 26) }
                                VStack(alignment: .leading) {
                                    Text("Servers")
                                    Text(servers.activeAccount?.displayName ?? "")
                                        .font(.footnote)
                                        .foregroundStyle(.lobbySecondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("settings.servers")
                    } footer: {
                        Text("Your own Lobby Server and others you were invited to. Each keeps its own viewers, downloads and settings.")
                    }
                }
                if let connection = app.connection {
                    Section {
                        LabeledContent("Name", value: connection.serverName)
                        if app.isGuest, let household = app.household {
                            // Someone else's server: whose household this device is in.
                            LabeledContent("Your Household", value: household.name)
                                .accessibilityIdentifier("settings.household")
                        }
                        if connection.serverAddress.host != AppModel.noAddress {
                            LabeledContent("Address", value: ServerAddress.display(connection.serverAddress))
                        }
                        LabeledContent("Status", value: Self.status(app.connectivity))
                        if let version = app.serverInfo?.version {
                            LabeledContent("Version", value: version)
                                .accessibilityIdentifier("settings.serverVersion")
                        }
                        if let road = app.roadText {
                            LabeledContent("Road", value: road)
                                .accessibilityIdentifier("settings.road")
                        }
                        if let problem = app.roadProblem {
                            Text(problem)
                                .font(.footnote)
                                .foregroundStyle(.lobbySecondary)
                        }
                    } header: {
                        Label("Lobby Server", systemImage: AppSymbol.server)
                    }
                }
                if app.statsAccess.showsHouseholdOverview {
                    Section {
                        NavigationLink(value: Route.householdStats) {
                            Label("Household Statistics", systemImage: "chart.bar.xaxis")
                        }
                        .accessibilityIdentifier("settings.householdStatistics")
                    } footer: {
                        Text("What your household watches, and each of its viewers.")
                    }
                }
                if app.isOwnerManager, app.serverCompatibility != .compatible {
                    Section {
                        Label(app.serverCompatibility.title, systemImage: AppSymbol.problem)
                            .foregroundStyle(Color.lobbyFailure)
                        Text(app.serverCompatibility.advice)
                            .font(.footnote)
                            .foregroundStyle(.lobbySecondary)
                    }
                    .accessibilityIdentifier("settings.mismatch")
                }
                if app.isOwnerManager {
                    Section {
                        NavigationLink(value: Route.households) {
                            Label("Households", systemImage: AppSymbol.households)
                        }
                        .accessibilityIdentifier("settings.households")
                        NavigationLink(value: Route.serverSettings) {
                            Label("Server Settings", systemImage: AppSymbol.settings)
                        }
                        .accessibilityIdentifier("settings.server")
                        if app.statsAccess.showsServerPage {
                            NavigationLink(value: Route.serverStats) {
                                Label("Statistics", systemImage: "chart.bar.xaxis")
                            }
                            .accessibilityIdentifier("settings.statistics")
                        }
                        if app.serverSetup?.needed == true {
                            Button("Finish Setting Up the Server…") { showsSetup = true }
                                .accessibilityIdentifier("settings.finishSetup")
                        }
                    } footer: {
                        Text("Who you share it with, its name, library folders, the TMDB key, converting, access from away and backups, and what is watched. At home or over Tailscale.")
                    }
                }
                if app.hasDirect {
                    Section {
                        Toggle(
                            "Use the Direct Connection",
                            isOn: Binding(get: { app.usesDirect }, set: { uses in Task { await app.setUsesDirect(uses) } }))
                            .accessibilityIdentifier("settings.usesDirect")
                    } footer: {
                        Text("When Lobby Server is neither on this network nor on Tailscale, Lobby connects to it directly, encrypted. Playing then uses mobile data when that is what this device is on. AirPlay to another screen does not work over it.")
                    }
                }
                Section {
                    LabeledContent("Name", value: app.device?.name ?? app.environment.device.name)
                    LabeledContent("Role", value: Self.role(app.device?.role))
                    if let profile = app.activeProfile {
                        Button {
                            picking = profile
                        } label: {
                            LabeledContent("Viewer") {
                                HStack(spacing: AppTheme.Space.s) {
                                    ProfileAvatar(profile: profile, size: 24)
                                    Text(profile.name)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.lobbyRow)
                        .disabled(!app.offersAvatars)
                        .accessibilityHint("Choose a picture")
                        .accessibilityIdentifier("settings.picture")
                        if app.offersSubtitlePreferences {
                            NavigationLink {
                                SubtitleSettingsView(profileID: profile.id)
                            } label: {
                                LabeledContent("Subtitles", value: SubtitleLanguages.summary(profile.subtitlePreferences))
                            }
                            .accessibilityIdentifier("settings.subtitles")
                        }
                        // A kids viewer's is the grown-ups' to set, on the viewer's page.
                        if app.offersPlaybackPreferences, profile.kids == nil {
                            NavigationLink {
                                PlaybackSettingsView(profileID: profile.id)
                            } label: {
                                LabeledContent("Playback", value: PlaybackWords.summary(profile.playbackPreferences))
                            }
                            .accessibilityIdentifier("settings.playback")
                        }
                        // A grown-up chooses this for a kids viewer, on the viewer's page.
                        if app.offersSkipPreferences, !app.isBoundToKids, profile.kids == nil {
                            NavigationLink {
                                SkipSettingsView(profileID: profile.id)
                            } label: {
                                LabeledContent("Intros and Credits", value: SkipWords.summary(profile.skipPreferences))
                            }
                            .accessibilityIdentifier("settings.skipping")
                        }
                    }
                    if let profile = app.activeProfile, app.statsAccess.showsOwn {
                        NavigationLink(value: Route.viewerStats(profile.id)) {
                            Label(StatsSummary.headline(.month), systemImage: "chart.bar.xaxis")
                        }
                        .accessibilityIdentifier("settings.viewerStats")
                    }
                    if !app.isBoundToKids {
                        Toggle(
                            "Others Can Play on This Device",
                            isOn: Binding(get: { app.isTarget }, set: { on in Task { await app.setIsTarget(on) } }))
                            .accessibilityIdentifier("settings.isTarget")
                    }
                    // The sparkle door while a kid is the viewer: on the Home Screen, or in the Dock on a Mac.
                    Toggle("Kids Icon in Kids Mode", isOn: $kidsIconIsOn)
                        .accessibilityIdentifier("settings.kidsIcon")
                } header: {
                    Label("This Device", systemImage: AppSymbol.thisDevice)
                } footer: {
                    Text(app.isManager
                        ? "A manager can add viewers, approve new devices and choose what is downloaded on each."
                        : "A viewer can watch and keeps their own place. Managing the library needs a manager device.")
                }
                #if !os(macOS)
                // On a phone there is no sidebar: the manager's pages are here.
                if app.isManager {
                    Section {
                        NavigationLink(value: Route.manage) {
                            Label("Devices and Viewers", systemImage: AppSymbol.devices)
                        }
                        .accessibilityIdentifier("settings.manage")
                        if app.isOwnerManager {
                            NavigationLink(value: Route.categories) {
                                Label("Categories", systemImage: AppSymbol.categories)
                            }
                            .accessibilityIdentifier("settings.categories")
                        }
                    } header: {
                        Label("Household", systemImage: AppSymbol.library)
                    }
                }
                #endif
                Section {
                    Toggle(
                        "Download over Mobile Data",
                        isOn: Binding(
                            get: { app.downloadsUseMobileData },
                            set: { allowed in Task { await app.setDownloadsUseMobileData(allowed) } }))
                        .accessibilityIdentifier("settings.mobileData")
                    if let total = app.downloadsOverview.total {
                        LabeledContent("On This Device", value: total)
                    }
                } header: {
                    Label("Downloads", systemImage: AppSymbol.downloads)
                } footer: {
                    Text(app.hasDirect
                        ? "When this is off, a download waits for Wi-Fi. Away from home, downloads over the direct connection run while Lobby is open and go on when you open it again. At home and on Tailscale they also run in the background."
                        : "When this is off, a download waits for Wi-Fi.")
                }
                Section {
                    Toggle(
                        "Downloaded Only",
                        isOn: Binding(
                            get: { app.downloadedOnly },
                            set: { only in Task { await app.setDownloadedOnly(only) } }))
                        .accessibilityIdentifier("settings.downloadedOnly")
                } footer: {
                    Text("Shows only what is on this device, as when Lobby Server is out of reach. For a slow or costly connection.")
                }
                Section {
                    Toggle(
                        "Trailers in Kids Mode",
                        isOn: Binding(get: { app.kidsTrailers }, set: { app.kidsTrailers = $0 }))
                        .accessibilityIdentifier("settings.kidsTrailers")
                } header: {
                    Label { Text("Kids Mode") } icon: { KidsDoorMark(size: 18) }
                } footer: {
                    Text("A kids viewer sees the trailer of a title they may watch, played inside Lobby. Off: no trailers in kids mode on this device.")
                }
                Section {
                    Button("Sign Out", systemImage: AppSymbol.signOut, role: .destructive) { confirmsSignOut = true }
                        .accessibilityIdentifier("settings.signOut")
                } footer: {
                    Text(servers.hasSeveral
                        ? "Removes this device's access to this server, its copy of the library and its downloads. Your other servers stay. To come back, pair again."
                        : "Removes this device's access, its copy of the library and its downloads. To come back, pair again.")
                }
                AppVersionSection()
                Section {
                    NavigationLink(value: Route.acknowledgements) {
                        Label("Acknowledgements", systemImage: AppSymbol.acknowledgements)
                    }
                    .accessibilityIdentifier("settings.acknowledgements")
                } footer: {
                    // TMDB asks for this sentence, in these words, where its data is used.
                    Text("Posters, summaries and genres come from TMDB. This product uses the TMDB API but is not endorsed or certified by TMDB.")
                        .accessibilityIdentifier("settings.tmdb")
                }
            }
            .lobbyDestinations()
            .sheet(item: $picking) { AvatarPickerSheet(app: app, profileID: $0.id) }
            .sheet(isPresented: $showsSetup) { ServerSetupView(app: app) }
            .navigationTitle("Settings")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if !os(macOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
            .confirmationDialog("Sign out of Lobby Server?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    Task {
                        await app.signOut()
                        dismiss()
                    }
                }
                .accessibilityIdentifier("settings.confirmSignOut")
            } message: {
                Text("Downloads on this device are deleted, and what was watched and not yet sent to the server is lost.")
            }
        }
    }

    private static func status(_ connectivity: AppModel.Connectivity) -> String {
        switch connectivity {
        case .unknown: "Checking…"
        case .online: "Connected"
        case .offline: "Cannot be reached"
        }
    }

    private static func role(_ role: DeviceRole?) -> String {
        switch role {
        case .manager?: "Manager"
        case .viewer?: "Viewer"
        case .unknown(let raw)?: raw.capitalized
        case nil: "Unknown"
        }
    }
}

/// This app's version, and asking the App Store for a newer one.
struct AppVersionSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL

    var body: some View {
        let updates = app.updates
        Section {
            LabeledContent("Lobby", value: updates.versionText)
                .accessibilityIdentifier("settings.appVersion")
            Toggle("Suggest Updates", isOn: Binding(get: { updates.suggestsUpdates }, set: { updates.suggestsUpdates = $0 }))
                .accessibilityIdentifier("settings.suggestsUpdates")
            Button {
                Task { await updates.checkNow() }
            } label: {
                HStack {
                    Text("Check for Updates")
                    Spacer()
                    if updates.state == .checking { ProgressView().controlSize(.small) }
                }
                .contentShape(Rectangle())
            }
            .disabled(updates.state == .checking)
            .accessibilityIdentifier("settings.checkForUpdates")
            if let page = updates.storePage {
                Button("Update in the App Store") { openURL(page) }
                    .accessibilityIdentifier("settings.update")
            }
        } header: {
            Label("This App", systemImage: AppSymbol.info)
        } footer: {
            VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                Text("Lobby looks in the App Store once a day and says when a new version is there. Never on the kids screens or while something plays.")
                if let status = updates.statusText { Text(status).accessibilityIdentifier("settings.updateStatus") }
            }
        }
    }
}

