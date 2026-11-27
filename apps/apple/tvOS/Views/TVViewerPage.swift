// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// Who is watching, when Lobby asks, and what this Apple TV is connected to.
struct TVViewerPage: View {
    @Environment(AppModel.self) private var app
    @Environment(ServersModel.self) private var servers
    @State private var removing: ServerAccount?
    @Environment(\.openURL) private var openURL
    @State private var confirmsSignOut = false
    @State private var picking: Profile?
    @State private var question = ViewerQuestion.eachTime
    @AppStorage(KidsIconRule.settingKey) private var kidsIconIsOn = true
    @FocusState private var switchIsFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVMetrics.shelfGap) {
                if let profile = app.activeProfile {
                    HStack(spacing: TVMetrics.gap) {
                        ProfileAvatar(profile: profile, size: 180)
                        Text(profile.name).font(.system(size: 64, weight: .bold))
                    }
                }
                row {
                    Button("Switch Viewer", systemImage: AppSymbol.viewers) { app.chooseAnotherProfile() }
                        .focused($switchIsFocused)
                        .accessibilityIdentifier("viewer.switch")
                    if let profile = app.activeProfile, app.offersAvatars {
                        Button("Change Picture", systemImage: AppSymbol.picture) { picking = profile }
                            .accessibilityIdentifier("viewer.picture")
                    }
                    if let profile = app.activeProfile, app.statsAccess.showsOwn {
                        NavigationLink(value: Route.viewerStats(profile.id)) {
                            Label(StatsSummary.headline(.month), systemImage: "chart.bar.xaxis")
                        }
                        .accessibilityIdentifier("viewer.stats")
                    }
                }

                row {
                    Menu {
                        Picker("Ask who is watching", selection: $question) {
                            ForEach(ViewerQuestion.allCases, id: \.self) { Text($0.name).tag($0) }
                        }
                    } label: {
                        Label("Ask who is watching: \(question.name)", systemImage: "person.fill.questionmark")
                    }
                    .accessibilityIdentifier("viewer.question")
                }

                // What happens at the end, for this viewer on every device. A kids viewer's is the
                // grown-ups' to set, from a manager's phone or Mac.
                if let profile = app.activeProfile, app.offersPlaybackPreferences, profile.kids == nil {
                    row { TVPlaybackMenu(profile: profile) }
                }

                if servers.canChangeServers {
                    row {
                        Menu {
                            ServerChoices()
                        } label: {
                            Label("Server: \(servers.activeAccount?.displayName ?? "")", systemImage: servers.activeAccount?.symbol ?? AppSymbol.server)
                        }
                        .accessibilityIdentifier("viewer.server")
                        if servers.accounts.count > 1 {
                            Menu {
                                ForEach(servers.accounts) { account in
                                    Menu(account.displayName) {
                                        Button("Move Up", systemImage: "arrow.up") { servers.move(account.id, by: -1) }
                                            .disabled(servers.accounts.first?.id == account.id)
                                        Button("Move Down", systemImage: "arrow.down") { servers.move(account.id, by: 1) }
                                            .disabled(servers.accounts.last?.id == account.id)
                                        Button("Remove…", systemImage: AppSymbol.remove, role: .destructive) { removing = account }
                                    }
                                }
                            } label: {
                                Label("Arrange Servers", systemImage: "list.bullet")
                            }
                            .accessibilityIdentifier("viewer.arrangeServers")
                        }
                        if servers.libraries.count > 1 {
                            Toggle(
                                "Ask Which Library at Start",
                                isOn: Binding(get: { !servers.remembersLibrary }, set: { servers.setRemembersLibrary(!$0) }))
                                .accessibilityIdentifier("viewer.asksLibrary")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                    Text("Lobby Server").font(.headline).accessibilityAddTraits(.isHeader)
                    if let connection = app.connection {
                        Text(connection.serverName)
                        if connection.serverAddress.host != AppModel.noAddress {
                            Text(ServerAddress.display(connection.serverAddress)).foregroundStyle(.secondary)
                        }
                    }
                    if app.isGuest, let household = app.household {
                        // Someone else's server: whose household this TV is in.
                        Text("Shared with \(household.name)").foregroundStyle(.secondary)
                            .accessibilityIdentifier("viewer.household")
                    }
                    Text(status).foregroundStyle(.secondary)
                    if let version = app.serverInfo?.version {
                        Text("Version \(version)").foregroundStyle(.secondary)
                    }
                    if app.isOwnerManager, app.serverCompatibility != .compatible {
                        Text(app.serverCompatibility.advice).foregroundStyle(Color.lobbyFailure)
                            .frame(maxWidth: TVMetrics.readable, alignment: .leading)
                    }
                    if let road = app.roadText {
                        Text("Road: \(road)").foregroundStyle(.secondary)
                            .accessibilityIdentifier("viewer.road")
                    }
                    if let problem = app.roadProblem {
                        Text(problem).foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                if app.hasDirect {
                    Toggle(
                        "Use the Direct Connection",
                        isOn: Binding(get: { app.usesDirect }, set: { uses in Task { await app.setUsesDirect(uses) } }))
                }
                // The sparkle door on the Home Screen while a kid is the viewer. The grown-ups' to set.
                if !app.isKidsMode {
                    Toggle("Kids Icon in Kids Mode", isOn: $kidsIconIsOn)
                        .accessibilityIdentifier("viewer.kidsIcon")
                }

                row {
                    Button {
                        Task { await app.refresh() }
                    } label: {
                        TVWorkingLabel(title: "Look for Changes", symbol: AppSymbol.refresh, isWorking: app.isRefreshing)
                    }
                    Button("Sign Out", systemImage: AppSymbol.signOut, role: .destructive) { confirmsSignOut = true }
                        .accessibilityIdentifier("viewer.signOut")
                }

                VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                    Text("Lobby").font(.headline).accessibilityAddTraits(.isHeader)
                    Text(app.updates.versionText).foregroundStyle(.secondary)
                        .accessibilityIdentifier("viewer.appVersion")
                    if let status = app.updates.statusText {
                        Text(status).foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                row {
                    Button {
                        Task { await app.updates.checkNow() }
                    } label: {
                        TVWorkingLabel(title: "Check for Updates", symbol: AppSymbol.update, isWorking: app.updates.state == .checking)
                    }
                    .accessibilityIdentifier("viewer.checkForUpdates")
                    Toggle("Suggest Updates", isOn: Binding(get: { app.updates.suggestsUpdates }, set: { app.updates.suggestsUpdates = $0 }))
                        .accessibilityIdentifier("viewer.suggestsUpdates")
                    if let page = app.updates.storePage {
                        Button("Update in the App Store", systemImage: AppSymbol.update) { openURL(page) }
                    }
                }

                Text(Acknowledgements.libjuice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                // TMDB asks for this sentence, in these words, where its data is used.
                Text("Posters, summaries and genres come from TMDB. This product uses the TMDB API but is not endorsed or certified by TMDB.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: TVMetrics.readable, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, AppTheme.Space.xl)
        }
        .scrollClipDisabled()
        .defaultFocus($switchIsFocused, true)
        .fullScreenCover(item: $picking) { TVAvatarPicker(app: app, profileID: $0.id) }
        .onAppear { question = app.environment.settings.viewerQuestion }
        .onChange(of: question) { _, chosen in app.environment.settings.viewerQuestion = chosen }
        .confirmationDialog(
            "Remove “\(removing?.displayName ?? "")” from this Apple TV?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let removing { Task { await servers.remove(removing.id) } }
                removing = nil
            }
        } message: {
            Text("Its access and its copy of the library on this Apple TV are deleted. The other servers stay.")
        }
        .confirmationDialog("Sign out of Lobby Server?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await app.signOut() } }
        } message: {
            Text("To come back, a manager has to approve this Apple TV again.")
        }
    }

    /// Buttons beside each other. As wide as the page for the remote: up and down find them from
    /// anywhere.
    private func row(@ViewBuilder _ buttons: () -> some View) -> some View {
        HStack(spacing: TVMetrics.gap) { buttons() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
    }

    private var status: String {
        switch app.connectivity {
        case .unknown: "Checking…"
        case .online: "Connected"
        case .offline: "Cannot be reached. Lobby keeps looking."
        }
    }
}

/// The viewer's playback preferences, as one menu: Up Next, suggestions, "Still watching?".
private struct TVPlaybackMenu: View {
    let profile: Profile
    @Environment(AppModel.self) private var app
    @State private var problem: String?

    private var preferences: PlaybackPreferences { profile.playbackPreferences }

    var body: some View {
        Menu {
            Toggle("Next Episode Automatically", isOn: binding(\.episodeAutoplay))
            Picker("Countdown", selection: binding(\.countdownSeconds)) {
                ForEach(PlaybackPreferences.countdownChoices, id: \.self) { Text(PlaybackWords.countdown($0)).tag($0) }
            }
            .pickerStyle(.menu)
            Toggle("Suggestions After a Film", isOn: binding(\.filmSuggestions))
            Toggle("Play a Suggestion Automatically", isOn: binding(\.filmAutoplay))
            Picker("Still Watching? After Episodes", selection: binding(\.stillWatchingEpisodes)) {
                ForEach(PlaybackPreferences.stillWatchingEpisodeChoices, id: \.self) { Text(PlaybackWords.episodes($0)).tag($0) }
            }
            .pickerStyle(.menu)
            Picker("Still Watching? After Hours", selection: binding(\.stillWatchingHours)) {
                ForEach(PlaybackPreferences.stillWatchingHourChoices, id: \.self) { Text(PlaybackWords.hours($0)).tag($0) }
            }
            .pickerStyle(.menu)
        } label: {
            Label("Playback: \(problem ?? PlaybackWords.summary(preferences))", systemImage: "play.square.stack")
        }
        .accessibilityIdentifier("viewer.playback")
    }

    private func binding<Value>(_ path: WritableKeyPath<PlaybackPreferences, Value>) -> Binding<Value> {
        Binding(get: { preferences[keyPath: path] }, set: { value in
            var changed = preferences
            changed[keyPath: path] = value
            guard changed != preferences else { return }
            Task {
                do {
                    try await app.setPlaybackPreferences(changed, profileID: profile.id)
                    problem = nil
                } catch {
                    problem = "That did not work"
                }
            }
        })
    }
}
