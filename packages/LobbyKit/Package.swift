// swift-tools-version: 6.0
// SPDX-License-Identifier: MPL-2.0
// Lobby is licensed under the Mozilla Public License 2.0 (LICENSE at the repository root).
// The vendored libjuice in Sources/CLobbyIce/libjuice is MPL-2.0 too, unchanged (NOTICE.md).
import PackageDescription

let package = Package(
    name: "LobbyKit",
    platforms: [.iOS(.v18), .macOS(.v15), .tvOS(.v18)],
    products: [
        .library(name: "LobbyKit", targets: ["LobbyKit", "LobbyDirect", "LobbyPush"]),
        // For the notification service extension, which may use little memory: only this.
        .library(name: "LobbyPush", targets: ["LobbyPush"]),
    ],
    targets: [
        // libjuice v1.7.5 (MPL-2.0), unchanged, with a small bridge to a socket on this device.
        .target(
            name: "CLobbyIce",
            exclude: ["libjuice/LICENSE"],
            cSettings: [
                .define("JUICE_STATIC"), .define("USE_NETTLE", to: "0"),
                .headerSearchPath("libjuice/include"), .headerSearchPath("libjuice/include/juice"),
                .headerSearchPath("libjuice/src"),
            ]),
        // The direct connection (docs/api.md, Direct): what is said, the road, the local server.
        .target(name: "LobbyDirect", dependencies: ["CLobbyIce"]),
        // Opening what a server sealed for the lock screen (docs/decisions.md, "Push through a
        // relay"), and the keys for it.
        .target(name: "LobbyPush"),
        .target(name: "LobbyKit", dependencies: ["LobbyDirect", "LobbyPush"]),
        .testTarget(
            name: "LobbyKitTests",
            dependencies: ["LobbyKit"],
            // Responses captured from the real server (apps/server), for the decoding tests.
            resources: [.copy("Captured")]
        ),
        .testTarget(name: "LobbyDirectTests", dependencies: ["LobbyDirect", "LobbyKit"]),
        .testTarget(name: "LobbyPushTests", dependencies: ["LobbyPush", "LobbyKit"]),
    ],
    swiftLanguageModes: [.v6]
)
