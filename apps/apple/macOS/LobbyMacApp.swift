// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

@main
struct LobbyMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    /// nil when the app's own folder could not be made: nothing else can work then.
    private var servers: ServersModel? { try? AppLaunch.shared.result.get() }

    var body: some Scene {
        // One window: the library is one place, like the TV app. Not a document app.
        Window("Lobby", id: "main") {
            switch AppLaunch.shared.result {
            case .success(let servers):
                ServersRoot(servers: servers) { MacRootView() }
                    .task { PushCenter.shared.start(servers: servers) }
                    .lobbyMotion()
                    .tint(Color("AccentColor"))
                    .frame(minWidth: 860, minHeight: 560)
                    .background(SolidWindow())
            case .failure(let error):
                ContentUnavailableView(
                    "Lobby cannot start", systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(error.localizedDescription))
                .frame(minWidth: 480, minHeight: 320)
            }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            if let servers {
                // Reading the model here is what makes the menus follow it, and the server in use.
                LobbyCommands(app: servers.active, state: MenuState(servers.active))
            }
        }

        Settings {
            if let servers {
                MacSettingsView()
                    .id(ObjectIdentifier(servers.active))
                    .environment(servers.active)
                    .environment(servers)
                    .tint(Color("AccentColor"))
                    // A sidebar of the subjects beside one page, as the system's own Settings.
                    .frame(width: 780, height: 560)
                    .background(SolidWindow())
            }
        }
    }
}

/// Settings, or on the kids screens a word that they are a grown-up's.
struct MacSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.showsKidsScreens {
            ContentUnavailableView(
                "Settings are for grown-ups", systemImage: AppSymbol.secret,
                description: Text(app.isBoundToKids
                    ? "This Mac belongs to a kids viewer. A manager changes that from their own device."
                    : "Choose another viewer first: click the round button at the top of the Lobby window."))
            .frame(height: 280)
            .accessibilityIdentifier("settings.grownUps")
        } else {
            SettingsView()
        }
    }
}

extension DeviceIdentity {
    /// This Mac, by the name it has in Sharing.
    @MainActor
    static var current: DeviceIdentity {
        DeviceIdentity(name: Host.current().localizedName ?? "Mac", platform: .macos)
    }
}

/// Receives what only an application delegate is told: the push token.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        MainActor.assumeIsolated { PushCenter.shared.registered(token) }
    }
}
