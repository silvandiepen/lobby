// swift-tools-version: 6.0
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

let package = Package(
    name: "playback-experiments",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "avprobe", path: "Sources/avprobe")
    ]
)
