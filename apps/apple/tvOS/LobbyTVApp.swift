// SPDX-License-Identifier: MPL-2.0
import AVFoundation
import LobbyKit
import SwiftUI
import UIKit

@main
struct LobbyTVApp: App {
    init() {
        // Films keep their sound whatever else the TV is set to. Without the category the
        // session keeps its default, and playback still works.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            switch AppLaunch.shared.result {
            case .success(let servers):
                ServersRoot(servers: servers) { TVRootView() }
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

extension DeviceIdentity {
    /// This Apple TV. tvOS gives apps a generic name ("Apple TV"), which is what a manager
    /// then sees in the device list.
    @MainActor
    static var current: DeviceIdentity {
        DeviceIdentity(name: UIDevice.current.name, platform: .tvos)
    }
}
