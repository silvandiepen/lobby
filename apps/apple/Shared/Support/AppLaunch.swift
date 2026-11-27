// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Builds the app's servers and the model of the one in use, once, from the launch arguments.
/// Each platform's entry point (and its app delegate) reads it from here.
@MainActor
struct AppLaunch {
    static let shared = AppLaunch()

    let result: Result<ServersModel, any Error>

    /// `-lobby-mute YES` plays films and music without sound. The UI tests launch with it, so a
    /// test run that plays something stays silent on the Mac it runs on.
    nonisolated static var isMuted: Bool { UserDefaults.standard.bool(forKey: "lobby-mute") }

    private init() {
        result = Result {
            let defaults = UserDefaults.standard
            // `-lobby-namespace <name>` keeps a test run away from the state of the copy a
            // person uses on the same device. `-lobby-reset YES` starts that namespace clean.
            // Without a namespace there is no reset: a person's own state has no switch that
            // wipes it.
            let namespace = defaults.string(forKey: "lobby-namespace")
            let store = try AppEnvironment.accountsStore(namespace: namespace)
            return try ServersModel(
                making: .live(store: store, device: .current),
                startsClean: namespace != nil && defaults.bool(forKey: "lobby-reset"))
        }
    }
}
