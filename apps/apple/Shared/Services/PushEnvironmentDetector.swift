// SPDX-License-Identifier: MPL-2.0
#if os(iOS) || os(macOS)
import Foundation
import LobbyKit

/// Which Apple push service this build's tokens belong to: sandbox or production.
///
/// A debug configuration is not the same as a development signature: builds from the Dev Shelf
/// are Release but development-signed, and get sandbox tokens. So the answer comes from what
/// the build is signed with: the `aps-environment` of its provisioning profile. A build without
/// a profile (App Store, TestFlight) is production.
enum PushEnvironmentDetector {
    /// The environment of this app.
    static func current(bundle: Bundle = .main) -> PushEnvironment {
        #if targetEnvironment(simulator)
        // Simulators have no profile, and hand out sandbox tokens.
        return .development
        #else
        let profile = profileURL(in: bundle).flatMap { try? Data(contentsOf: $0) }
        return environment(profile: profile)
        #endif
    }

    /// `profile` is the content of the embedded profile, nil when there is none.
    static func environment(profile: Data?) -> PushEnvironment {
        if let profile, let value = apsEnvironment(inProfile: profile) {
            return value == "development" ? .development : .production
        }
        // No profile, or one without push: nothing says development, so the store's.
        #if DEBUG
        return profile == nil ? .development : .production
        #else
        return .production
        #endif
    }

    /// The `aps-environment` entitlement from a provisioning profile: a signed (CMS) blob that
    /// carries a plain property list, which is read from between its markers.
    static func apsEnvironment(inProfile data: Data) -> String? {
        guard
            let start = data.range(of: Data("<?xml".utf8)),
            let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let plist = data[start.lowerBound..<end.upperBound]
        guard
            let root = try? PropertyListSerialization.propertyList(from: Data(plist), format: nil) as? [String: Any],
            let entitlements = root["Entitlements"] as? [String: Any]
        else { return nil }
        return (entitlements["aps-environment"] ?? entitlements["com.apple.developer.aps-environment"]) as? String
    }

    private static func profileURL(in bundle: Bundle) -> URL? {
        #if os(macOS)
        let url = bundle.bundleURL.appending(path: "Contents/embedded.provisionprofile")
        #else
        let url = bundle.bundleURL.appending(path: "embedded.mobileprovision")
        #endif
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
#endif
