// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// The Mac's window: Connect, the viewer picker or the library, and the player over it.
struct MacRootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
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
                SidebarLayout()
            }
            if let player = app.player {
                MacPlayerScreen(model: player)
                    // Out of the card that was pressed, where one was.
                    .modifier(GrowsIn(origin: PressPoint.recent))
                    .transition(.asymmetric(
                        insertion: .identity, removal: .scale(scale: motion.openScale).combined(with: .opacity)))
            }
        }
        // A manager drops films, episodes and folders of them on the window to upload them.
        .dropDestination(for: URL.self) { urls, _ in
            guard app.phase == .library, app.uploads().isAvailable else { return false }
            app.uploads().pick(urls)
            app.showsUploads = true
            return true
        }
        .sheet(isPresented: $app.showsUploads) {
            NavigationStack {
                UploadsView(app: app)
                    .lobbyDestinations()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { app.showsUploads = false }
                        }
                    }
            }
            .frame(minWidth: 560, minHeight: 520)
        }
        .task(id: app.isManager) { await app.uploads().connect() }
        .offersServerSetup()
        .offersUpdates()
        .answersKidsQuestions()
        .musicPlayerSheet()
        .animation(motion.animation(.section), value: app.phase)
        .animation(motion.animation(.section), value: app.showsKidsScreens)
        .animation(motion.animation(.open), value: app.player == nil)
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
        .task { await app.watchWanted() }
        .task { await app.watchDownloads() }
        .task { await app.remote.run() }
        .onChange(of: scenePhase) { _, phase in
            // A Mac app behind another window is still there to play on; only hidden it is not.
            app.remote.isForeground = phase != .background
            Task {
                switch phase {
                case .active: await app.becameActive()
                case .background: await app.enteredBackground()
                // Another app is in front: whoever left the picker open has gone.
                case .inactive: app.closeOpenPicker()
                default: break
                }
            }
        }
    }
}
