// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI
import UIKit

@main
struct LobbyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            switch AppLaunch.shared.result {
            case .success(let servers):
                ServersRoot(servers: servers) { RootView() }
                    .task { PushCenter.shared.start(servers: servers) }
                    .lobbyMotion()
                    .tint(Color("AccentColor"))
            case .failure(let error):
                // The app's own folder could not be made: nothing else can work.
                ContentUnavailableView(
                    "Lobby cannot start", systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(error.localizedDescription))
            }
        }
    }
}

/// Receives what only an app delegate is told: that the system started the app, perhaps in
/// the background, because a download finished while it was not running.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        PushCenter.shared.registered(token)
    }

    /// What the system wants called once the download events were handled, by session.
    private var backgroundCompletions: [String: () -> Void] = [:]

    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard case .success(let servers) = AppLaunch.shared.result else { return completionHandler() }
        backgroundCompletions[identifier] = completionHandler
        let done: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                self?.backgroundCompletions.removeValue(forKey: identifier)?()
            }
        }
        Task {
            // Each server's downloads have a session of their own: its account takes the events.
            // An upload's pieces have a session of their own too, beside the downloads'.
            if await servers.handleUploadEvents(identifier: identifier, completion: done) { return }
            await servers.handleBackgroundEvents(identifier: identifier, completion: done)
        }
    }
}

extension DeviceIdentity {
    /// This iPhone or iPad. iOS gives apps a generic device name ("iPhone"), which is what a
    /// manager then sees in the device list.
    @MainActor
    static var current: DeviceIdentity {
        DeviceIdentity(
            name: UIDevice.current.name,
            platform: UIDevice.current.userInterfaceIdiom == .pad ? .ipados : .ios)
    }
}
