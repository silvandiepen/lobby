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
                .presentationSizing(.page)
        }
        .sheet(isPresented: $showsStats) {
            if let profile = app.activeProfile { StatsSheet(profileID: profile.id) }
        }
        .sheet(item: $picking) { AvatarPickerSheet(app: app, profileID: $0.id) }
    }
}

/// Settings, as the system's Settings app has them: a short list in groups, each row one page
/// about one subject. A narrow window pushes the pages; a wide one (iPad, Mac) shows the list
/// beside the page. Only what the person in front may change is listed (docs/decisions.md,
/// "Settings, one page per subject").
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: SettingsPage?
    @State private var isWide = false
    @State private var showsSetup = false

    /// `page`: the page shown first beside the list, on a wide window.
    init(page: SettingsPage? = nil) {
        _selection = State(initialValue: page)
    }

    private var audience: SettingsAudience { app.settingsAudience }

    var body: some View {
        Group {
            if isWide {
                NavigationSplitView {
                    SettingsRoot(audience: audience, query: $query, selection: $selection, isWide: true) { showsSetup = true }
                        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
                        .toolbar { doneButton }
                } detail: {
                    NavigationStack {
                        if let page = selection ?? SettingsMap.pages(for: audience).first {
                            SettingsPageView(page: page)
                                .lobbyDestinations()
                        }
                    }
                    .id(selection)
                }
                #if os(macOS)
                .toolbar(removing: .sidebarToggle)
                #endif
            } else {
                NavigationStack {
                    SettingsRoot(audience: audience, query: $query, selection: $selection, isWide: false) { showsSetup = true }
                        .lobbyDestinations()
                        .toolbar { doneButton }
                }
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 700 } action: { isWide = $0 }
        .sheet(isPresented: $showsSetup) { ServerSetupView(app: app) }
        .onChange(of: audience) { _, now in
            // A page that is no longer this person's (a new viewer, a changed role) closes.
            if let page = selection, !page.isVisible(to: now) { selection = nil }
        }
    }

    @ToolbarContentBuilder
    private var doneButton: some ToolbarContent {
        #if !os(macOS)
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
                .accessibilityIdentifier("settings.done")
        }
        #endif
    }
}

/// The list of Settings: its groups, or what a search found.
private struct SettingsRoot: View {
    @Environment(AppModel.self) private var app
    @Environment(ServersModel.self) private var servers
    @Environment(\.colorScheme) private var scheme
    let audience: SettingsAudience
    @Binding var query: String
    @Binding var selection: SettingsPage?
    let isWide: Bool
    let finishSetup: () -> Void

    var body: some View {
        List(selection: isWide ? $selection : nil) {
            if audience.isServerAdmin, app.serverCompatibility != .compatible {
                Section {
                    Label(app.serverCompatibility.title, systemImage: AppSymbol.problem)
                        .foregroundStyle(Color.lobbyFailure)
                    Text(app.serverCompatibility.advice)
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                }
                .accessibilityIdentifier("settings.mismatch")
            }
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                groups
            } else {
                found
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(isWide ? .automatic : .hidden)
        .background(Color.lobbyBackground(scheme).ignoresSafeArea())
        .navigationTitle("Settings")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(isWide ? .automatic : .inline)
        #endif
        #if os(macOS)
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
        #else
        // At the top, as in the system's Settings: at the foot it would cover the last rows.
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Settings")
        #endif
    }

    @ViewBuilder
    private var groups: some View {
        ForEach(SettingsMap.groups(for: audience), id: \.group) { entry in
            Section {
                ForEach(entry.pages) { page in
                    row(page)
                }
                if entry.group == .server, audience.needsSetup {
                    Button("Finish Setting Up the Server…", systemImage: AppSymbol.setUp) { finishSetup() }
                        .accessibilityIdentifier("settings.finishSetup")
                        .settingsRowBackground(isWide: isWide, scheme: scheme)
                }
            } header: {
                // The viewer's own row says who it is: no heading above it.
                if entry.group != .you { Text(entry.group.title) }
            }
        }
    }

    @ViewBuilder
    private var found: some View {
        let model = app.serverSettings()
        let pages = SettingsMap.search(query, for: audience) { page in
            guard let settings = model.settings else { return [] }
            return page.rowKeys(among: settings.settings.map(\.key)).compactMap { settings.setting($0)?.title }
        }
        if pages.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            Section {
                ForEach(pages) { page in
                    row(page, showsSummary: true)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ page: SettingsPage, showsSummary: Bool = false) -> some View {
        let label = SettingsRowLabel(page: page, value: value(of: page), showsSummary: showsSummary)
        Group {
            if isWide {
                NavigationLink(value: page) { label }
            } else {
                NavigationLink(value: Route.settings(page)) { label }
            }
        }
        .accessibilityIdentifier(page.accessibilityID)
        .settingsRowBackground(isWide: isWide, scheme: scheme)
    }

    /// What a row says on its right: the choice made, where that is short.
    private func value(of page: SettingsPage) -> String? {
        let profile = app.activeProfile
        switch page {
        case .playback: return profile.map { PlaybackWords.summary($0.playbackPreferences) }
        case .subtitles: return profile.map { SubtitleLanguages.summary($0.subtitlePreferences) }
        case .skipping: return profile.map { SkipWords.summary($0.skipPreferences) }
        case .servers: return servers.activeAccount?.displayName
        case .connection: return ConnectionPage.status(app.connectivity)
        default: return nil
        }
    }
}

private extension View {
    /// The rows take the app's surface in a pushed list; in a sidebar the system's, which shows
    /// the selection.
    @ViewBuilder
    func settingsRowBackground(isWide: Bool, scheme: ColorScheme) -> some View {
        if isWide {
            self
        } else {
            listRowBackground(Color.lobbySurface(scheme))
        }
    }
}

/// A row of the Settings list: a small coloured symbol, the page's name, and what it is set to.
private struct SettingsRowLabel: View {
    @Environment(AppModel.self) private var app
    let page: SettingsPage
    let value: String?
    let showsSummary: Bool

    var body: some View {
        if page == .you, !showsSummary, let profile = app.activeProfile {
            // The viewer's own row, as the system's Settings shows the account.
            HStack(spacing: AppTheme.Space.m) {
                ProfileAvatar(profile: profile, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).font(.headline)
                    Text("Picture and your month in Lobby")
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                }
            }
            .padding(.vertical, AppTheme.Space.xs)
        } else {
            HStack(spacing: AppTheme.Space.m) {
                SettingsSymbol(page: page)
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.title)
                    if showsSummary {
                        Text(page.summary)
                            .font(.footnote)
                            .foregroundStyle(.lobbySecondary)
                    }
                }
                if let value, !showsSummary {
                    Spacer(minLength: AppTheme.Space.s)
                    Text(value)
                        .foregroundStyle(.lobbySecondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// A page's symbol, white on the colour of its group.
struct SettingsSymbol: View {
    let page: SettingsPage
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 28

    var body: some View {
        if page == .kidsMode || page == .kids {
            // The kids' side has its own mark wherever it shows (docs/kids.md).
            KidsDoorMark(size: size)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            tile
        }
    }

    private var tile: some View {
        Image(systemName: page.symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(page.group.tint, in: .rect(cornerRadius: size * 0.24))
            .accessibilityHidden(true)
    }
}

extension SettingsGroup {
    /// One colour per group, so the groups read apart at a glance.
    var tint: Color {
        switch self {
        case .you: Color("AccentColor")
        case .device: .blue
        case .household: .green
        case .server: .indigo
        case .about: .gray
        }
    }
}

extension SettingsPage {
    var symbol: String {
        switch self {
        case .you: AppSymbol.picture
        case .playback: AppSymbol.play
        case .subtitles: "captions.bubble.fill"
        case .skipping: "forward.end.fill"
        case .connection: AppSymbol.server
        case .servers: "rectangle.stack.fill"
        case .device: AppSymbol.thisDevice
        case .downloads: AppSymbol.downloads
        case .kidsMode: AppSymbol.kids
        case .devices: AppSymbol.devices
        case .viewers: AppSymbol.viewers
        case .kids: AppSymbol.kids
        case .categories: AppSymbol.categories
        case .householdStats: "chart.bar.xaxis"
        case .serverGeneral: AppSymbol.settings
        case .libraryFolders: AppSymbol.folder
        case .imports: AppSymbol.inbox
        case .matching: "photo.on.rectangle.angled"
        case .converting: "arrow.triangle.2.circlepath"
        case .appleTVs: AppSymbol.television
        case .speakers: "homepod.and.homepodmini.fill"
        case .away: AppSymbol.outside
        case .households: AppSymbol.households
        case .statistics: "chart.bar.xaxis"
        case .backups: "clock.arrow.circlepath"
        case .advanced: "wrench.and.screwdriver.fill"
        case .about: AppSymbol.info
        }
    }

    /// The row's identifier. The pages that were rows before keep the identifiers the UI tests
    /// know them by.
    var accessibilityID: String {
        switch self {
        case .devices: "settings.manage"
        case .serverGeneral: "settings.server"
        case .householdStats: "settings.householdStatistics"
        default: "settings.\(rawValue)"
        }
    }
}

/// One page of Settings.
struct SettingsPageView: View {
    let page: SettingsPage
    @Environment(AppModel.self) private var app

    var body: some View {
        switch page {
        case .you: YouPage()
        case .playback: viewerPage { PlaybackSettingsView(profileID: $0) }
        case .subtitles: viewerPage { SubtitleSettingsView(profileID: $0) }
        case .skipping: viewerPage { SkipSettingsView(profileID: $0) }
        case .connection: ConnectionPage()
        case .servers: ServersView()
        case .device: ThisDevicePage()
        case .downloads: DownloadsSettingsPage()
        case .kidsMode: KidsModePage()
        case .devices: ManagerView(model: app.manager(), part: .devices)
        case .viewers: ManagerView(model: app.manager(), part: .viewers)
        case .kids: ManagerView(model: app.manager(), part: .kids)
        case .categories: CategoriesView(app: app)
        case .householdStats: ServerStatsView(app: app, scope: .household)
        case .appleTVs:
            let model = app.serverSettings()
            AppleTVsView(app: app, more: AnyView(ServerSettingsExtra(model: model, page: page)))
                .serverSettingsChanges(model: model, page: page, waits: false)
        case .speakers: SpeakersView(app: app)
        case .households: HouseholdsView(app: app)
        case .about: AboutPage()
        case .serverGeneral, .libraryFolders, .imports, .matching, .converting, .away, .statistics, .backups, .advanced:
            ServerSettingsPage(app: app, page: page)
        }
    }

    @ViewBuilder
    private func viewerPage(@ViewBuilder _ content: (String) -> some View) -> some View {
        if let profile = app.activeProfile {
            content(profile.id)
        } else {
            ContentUnavailableView("Choose a viewer first", systemImage: AppSymbol.viewers)
        }
    }
}

// MARK: You

/// The viewer in front: their picture and what they watched.
private struct YouPage: View {
    @Environment(AppModel.self) private var app
    @State private var picking: Profile?

    var body: some View {
        LobbyForm {
            if let profile = app.activeProfile {
                Section {
                    Button {
                        picking = profile
                    } label: {
                        HStack(spacing: AppTheme.Space.m) {
                            ProfileAvatar(profile: profile, size: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name).font(.headline)
                                if app.offersAvatars {
                                    Text("Choose a Picture").font(.footnote).foregroundStyle(.tint)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.lobbyRow)
                    .disabled(!app.offersAvatars)
                    .accessibilityHint("Choose a picture")
                    .accessibilityIdentifier("settings.picture")
                }
                if app.statsAccess.showsOwn {
                    Section {
                        NavigationLink(value: Route.viewerStats(profile.id)) {
                            Label(StatsSummary.headline(.month), systemImage: "chart.bar.xaxis")
                        }
                        .accessibilityIdentifier("settings.viewerStats")
                    }
                }
                SettingsPageNote(page: .you)
            }
        }
        .navigationTitle(SettingsPage.you.title)
        .sheet(item: $picking) { AvatarPickerSheet(app: app, profileID: $0.id) }
    }
}

// MARK: This device

/// How this device reaches the server, and signing out of it.
struct ConnectionPage: View {
    @Environment(AppModel.self) private var app
    @Environment(ServersModel.self) private var servers
    @State private var confirmsSignOut = false

    var body: some View {
        LobbyForm {
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
                    Text("Lobby Server")
                }
            }
            if app.hasDirect {
                Section {
                    Toggle(
                        "Use the Direct Connection",
                        isOn: Binding(get: { app.usesDirect }, set: { uses in Task { await app.setUsesDirect(uses) } }))
                        .accessibilityIdentifier("settings.usesDirect")
                } footer: {
                    Text("Away from home and off Tailscale, Lobby connects to the server directly, encrypted, also over mobile data. AirPlay does not work over it.")
                }
            }
            Section {
                Button("Sign Out", systemImage: AppSymbol.signOut, role: .destructive) { confirmsSignOut = true }
                    .accessibilityIdentifier("settings.signOut")
            } footer: {
                Text(servers.hasSeveral
                    ? "Removes this device's access to this server, its copy of the library and its downloads. Your other servers stay."
                    : "Removes this device's access, its copy of the library and its downloads. To come back, pair again.")
            }
            SettingsPageNote(page: .connection)
        }
        .navigationTitle(SettingsPage.connection.title)
        .confirmationDialog("Sign out of Lobby Server?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                Task { await app.signOut() }
            }
            .accessibilityIdentifier("settings.confirmSignOut")
        } message: {
            Text("Downloads on this device are deleted, and what was watched and not yet sent to the server is lost.")
        }
    }

    static func status(_ connectivity: AppModel.Connectivity) -> String {
        switch connectivity {
        case .unknown: "Checking…"
        case .online: "Connected"
        case .offline: "Cannot be reached"
        }
    }
}

/// What this device is to the server.
private struct ThisDevicePage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        LobbyForm {
            Section {
                LabeledContent("Name", value: app.device?.name ?? app.environment.device.name)
                LabeledContent("Role", value: Self.role(app.device?.role))
            } footer: {
                Text(app.isManager
                    ? "A manager adds viewers, lets in new devices and chooses what each downloads."
                    : "A viewer watches and keeps their own place. Managing needs a manager's device.")
            }
            if !app.isBoundToKids {
                Section {
                    Toggle(
                        "Others Can Play on This Device",
                        isOn: Binding(get: { app.isTarget }, set: { on in Task { await app.setIsTarget(on) } }))
                        .accessibilityIdentifier("settings.isTarget")
                } footer: {
                    Text("Other devices of the household can start something here with Play On.")
                }
            }
            SettingsPageNote(page: .device)
        }
        .navigationTitle(SettingsPage.device.title)
    }

    static func role(_ role: DeviceRole?) -> String {
        switch role {
        case .manager?: "Manager"
        case .viewer?: "Viewer"
        case .unknown(let raw)?: raw.capitalized
        case nil: "Unknown"
        }
    }
}

/// When this device downloads.
private struct DownloadsSettingsPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        LobbyForm {
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
            } footer: {
                Text("When this is off, a download waits for Wi-Fi.")
            }
            Section {
                Toggle(
                    "Downloaded Only",
                    isOn: Binding(
                        get: { app.downloadedOnly },
                        set: { only in Task { await app.setDownloadedOnly(only) } }))
                    .accessibilityIdentifier("settings.downloadedOnly")
            } footer: {
                Text("Shows only what is on this device, as when the server is out of reach.")
            }
            SettingsPageNote(page: .downloads)
        }
        .navigationTitle(SettingsPage.downloads.title)
    }
}

/// What this device does for a kids viewer.
private struct KidsModePage: View {
    @Environment(AppModel.self) private var app
    @AppStorage(KidsIconRule.settingKey) private var kidsIconIsOn = true

    var body: some View {
        LobbyForm {
            Section {
                // The sparkle door while a kid is the viewer: on the Home Screen, or in the Dock on a Mac.
                Toggle("Kids Icon in Kids Mode", isOn: $kidsIconIsOn)
                    .accessibilityIdentifier("settings.kidsIcon")
                Toggle(
                    "Trailers in Kids Mode",
                    isOn: Binding(get: { app.kidsTrailers }, set: { app.kidsTrailers = $0 }))
                    .accessibilityIdentifier("settings.kidsTrailers")
            } footer: {
                Text("Trailers are those of titles the child may watch, played inside Lobby.")
            }
            SettingsPageNote(page: .kidsMode)
        }
        .navigationTitle(SettingsPage.kidsMode.title)
    }
}

// MARK: About

private struct AboutPage: View {
    var body: some View {
        LobbyForm {
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
        .navigationTitle(SettingsPage.about.title)
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

