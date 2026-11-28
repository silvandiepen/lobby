// SPDX-License-Identifier: MPL-2.0
import AppKit
import LobbyKit
import SwiftUI
import XCTest

@testable import Lobby

/// Pictures of the Mac's Settings window, its list beside each page, for looking at by eye.
/// Like `LookWalkthrough` it skips unless asked for, with the same variables
/// (`LOBBY_LOOK_SERVER`, `LOBBY_LOOK_TOKEN`) and the same script outside that takes each picture
/// with `screencapture -l` when the test writes `<window number> <name>` to
/// `<temporary directory>/lobby-look/request`.
@MainActor
final class SettingsLook: XCTestCase {
    private var request: URL {
        FileManager.default.temporaryDirectory.appending(path: "lobby-look/request")
    }

    private func photograph(_ window: NSWindow, _ name: String) async throws {
        try await Task.sleep(for: .seconds(2))
        CATransaction.flush()
        try FileManager.default.createDirectory(at: request.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "\(window.windowNumber) \(name)".write(to: request, atomically: true, encoding: .utf8)
        for _ in 0..<150 where FileManager.default.fileExists(atPath: request.path) {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.path), "Nobody took the picture “\(name)”.")
    }

    func testSettingsWindow() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["LOBBY_LOOK_SERVER"], let token = environment["LOBBY_LOOK_TOKEN"] else {
            throw XCTSkip("No LOBBY_LOOK_SERVER and LOBBY_LOOK_TOKEN: pictures of Settings were not asked for.")
        }
        let servers = try AppLaunch.shared.result.get()
        let app = servers.active
        try await app.environment.forgetEverything()
        await app.signOut()
        let connect = ConnectModel(app: app)
        connect.addressText = address
        await connect.findServer()
        await connect.requestCode()
        guard case .code(let pairing, _) = connect.step else {
            return XCTFail("No pairing code: \(String(describing: connect.problem))")
        }
        var approval = URLRequest(url: try XCTUnwrap(URL(string: address)).appending(path: "v1/pairing/approve"))
        approval.httpMethod = "POST"
        approval.setValue("application/json", forHTTPHeaderField: "Content-Type")
        approval.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        approval.httpBody = try JSONSerialization.data(withJSONObject: ["code": pairing.code, "role": "manager"])
        _ = try await URLSession.shared.data(for: approval)
        await connect.waitUntilPaired()
        await app.selectProfile(try XCTUnwrap(app.profiles.first))

        for page in [SettingsPage.you, .connection, .devices, .libraryFolders, .converting, .appleTVs, .advanced, .about] {
            let host = NSHostingView(rootView: SettingsView(page: page)
                .environment(app).environment(servers).tint(Color("AccentColor"))
                .frame(width: 780, height: 560))
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 780, height: 560), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await photograph(window, "mac-admin-\(page.rawValue)")
            window.close()
        }
    }
}
