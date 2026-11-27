// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// The app's one screen: Connect, the viewer picker or the library, by the model's phase.
struct TVRootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.motion) private var motion
    /// The player on screen. Apart from `app.player`, so that closing it with the remote is
    /// the screen's own doing and the model follows.
    @State private var onScreen: PlayerModel?
    /// Where the library was: Back from Who is watching returns there.
    @State private var tab = TVTab.home

    var body: some View {
        ZStack {
            Color.lobbyBackground(scheme).ignoresSafeArea()
            switch app.phase {
            case .launching:
                ProgressView()
            case .connect:
                TVConnectView(app: app)
            case .chooseProfile where app.awaitsRemotePlay:
                // Woken for a play from another device: it says who watches.
                VStack(spacing: 24) {
                    ProgressView()
                    Text("Starting…")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("tv.startingRemotePlay")
            case .chooseProfile:
                TVProfilePicker()
            case .library where app.showsKidsScreens:
                TVKidsRootView()
                    .onAppear { tab = .home }
            case .library:
                TVLibraryView(selection: $tab)
            }
        }
        .animation(motion.animation(.section), value: app.phase)
        .offersUpdates()
        .fullScreenCover(item: $onScreen) { player in
            TVPlayerScreen(model: player) { onScreen = nil }
                // Also when the cover was closed with the remote.
                .onDisappear { Task { await player.close() } }
        }
        .onChange(of: app.player.map(ObjectIdentifier.init)) {
            onScreen = app.player
        }
        .onChange(of: app.player?.isFinished) { _, finished in
            // The film, or the last episode, played to its end.
            if finished == true { onScreen = nil }
        }
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
        .task { await app.watchRoad() }
        .task { await app.watchServer() }
        .task { await app.remote.run() }
        .overlay(alignment: .topTrailing) {
            // Over the library; the player shows its own.
            if onScreen == nil { RemoteToastView() }
        }
        .onChange(of: scenePhase) { _, phase in
            app.remote.isForeground = phase == .active
            Task {
                switch phase {
                case .active:
                    app.cameBack()
                    await app.becameActive()
                case .background: await app.enteredBackground()
                default: break
                }
            }
        }
    }
}
