// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// The app's one window: Connect, the viewer picker or the library, by the model's phase.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.motion) private var motion

    var body: some View {
        @Bindable var app = app
        ZStack {
            Color.lobbyBackground(scheme).ignoresSafeArea()
            switch app.phase {
            case .launching:
                ProgressView()
            case .connect:
                ConnectView(app: app)
            case .chooseProfile:
                ProfilePickerView()
            case .library where app.showsKidsScreens:
                KidsRootView()
            case .library:
                if sizeClass == .compact {
                    CompactTabs()
                } else {
                    SidebarLayout()
                }
            }
        }
        .offersServerSetup()
        .offersUpdates()
        .answersKidsQuestions()
        .animation(motion.animation(.section), value: app.phase)
        .animation(motion.animation(.section), value: app.showsKidsScreens)
        // Felt when a film starts.
        .sensoryFeedback(.impact(weight: .medium), trigger: app.player == nil) { wasClosed, isClosed in wasClosed && !isClosed }
        .background(PlayerPresenter(
            model: app.player, isFinished: app.player?.isFinished ?? false,
            usesOwnTransport: app.player?.preparing != nil, showsEnding: app.player?.ending != nil))
        .musicPlayerSheet()
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { app.problem != nil }, set: { if !$0 { app.problem = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.problem ?? "")
        }
        .task { await app.start() }
        .task { await app.watchNetwork() }
        // Uploads left from before go on once the device is known to be a manager's.
        .task(id: app.isManager) { await app.uploads().connect() }
        .task { await app.watchRoad() }
        .task { await app.watchDownloads() }
        .task { await app.watchWanted() }
        .task { await app.remote.run() }
        .onChange(of: scenePhase) { _, phase in
            // In the background without a film: others cannot start one here.
            app.remote.isForeground = phase == .active || (phase == .inactive && app.remote.isForeground)
            Task {
                switch phase {
                case .active: await app.becameActive()
                case .background: await app.enteredBackground()
                default: break
                }
            }
        }
    }
}

/// The iPhone: Home and Downloads as tabs, search beside them.
struct CompactTabs: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""

    var body: some View {
        @Bindable var app = app
        TabView {
            Tab("Home", systemImage: AppSymbol.library) {
                NavigationStack {
                    // The viewer's menu is at the top of Home.
                    LibraryHomeView()
                        .lobbyDestinations()
                }
                .nowPlayingBar()
                .opensFromTiles()
                .musicMiniPlayer()
            }
            .accessibilityIdentifier("tab.library")

            if app.music.isAvailable {
                Tab("Music", systemImage: AppSymbol.music) {
                    NavigationStack {
                        MusicHomeView()
                            .lobbyDestinations()
                    }
                    .opensFromTiles()
                    .musicMiniPlayer()
                }
                .accessibilityIdentifier("tab.music")
            }

            Tab("Downloads", systemImage: AppSymbol.downloads) {
                NavigationStack {
                    DownloadsView()
                        .lobbyDestinations()
                }
                .nowPlayingBar()
                .musicMiniPlayer()
            }
            .accessibilityIdentifier("tab.downloads")

            Tab("Search", systemImage: AppSymbol.search, role: .search) {
                NavigationStack {
                    SearchResultsView(query: $query)
                        .navigationTitle("Search")
                        .lobbyDestinations()
                }
                .nowPlayingBar()
                .opensFromTiles()
                .musicMiniPlayer()
                // The model ends the search when a film starts: a search field that kept the
                // keyboard would bring it back over the player.
                .searchable(text: $query, isPresented: $app.isSearching, prompt: app.music.isAvailable ? "Films, series and music" : "Films and series")
            }
            .accessibilityIdentifier("tab.search")
        }
        // Three posters fill the width: the tiles need to know it.
        .measuresLobbyContentWidth()
    }
}
