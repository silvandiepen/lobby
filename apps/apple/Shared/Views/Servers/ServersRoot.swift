// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// Puts the server in use into the environment, and makes its screens anew when another server
/// is chosen: nothing of one server stays on screen with the other, and the screens' loops (the
/// network, the live channel, the downloads) end with their server and start with the next.
struct ServersRoot<Content: View>: View {
    let servers: ServersModel
    @ViewBuilder var content: () -> Content
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(KidsIconRule.settingKey) private var kidsIconIsOn = true
    /// The app's icon follows kids mode, whichever server is in use.
    @State private var kidsIcon = KidsIconSwitcher.live()

    var body: some View {
        Group {
            if servers.showsLibraryChoice {
                #if os(tvOS)
                TVLibraryChoice()
                #else
                LibraryChoiceView()
                #endif
            } else {
                content()
            }
        }
            .id(ObjectIdentifier(servers.active))
            .environment(servers.active)
            .environment(servers)
            .onOpenURL { servers.open($0) }
            .task { await servers.start() }
            .onChange(of: kidsIconState, initial: true) { kidsIcon.update(kidsIconState) }
            .alert(
                "Servers",
                isPresented: Binding(get: { servers.problem != nil }, set: { if !$0 { servers.problem = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(servers.problem ?? "")
            }
    }

    private var kidsIconState: KidsIconSwitcher.State {
        #if os(macOS)
        // The Dock changes without asking, whether the app is in front or not.
        let isActive = true
        #else
        let isActive = scenePhase == .active
        #endif
        return KidsIconSwitcher.State(
            isKidsMode: servers.active.isKidsMode, isOn: kidsIconIsOn, isActive: isActive,
            isPlaying: servers.active.player != nil)
    }
}
