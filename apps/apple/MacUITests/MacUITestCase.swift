// SPDX-License-Identifier: MPL-2.0
import XCTest

/// What the Mac UI tests share: launching the app with state of its own, and finding things.
@MainActor
class MacUITestCase: XCTestCase {
    let app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func launch(namespace: String = "mac-ui-tests", clean: Bool = true) {
        app.launchArguments = ["-lobby-mute", "YES", "-lobby-namespace", namespace] + (clean ? ["-lobby-reset", "YES"] : [])
        app.launch()
        app.activate()
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @discardableResult
    func waitFor(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(what) did not appear.", file: file, line: line)
        return element
    }

    func waitForGone(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: timeout), .completed, "\(what) did not go away.", file: file, line: line)
    }

    func type(_ text: String, into field: XCUIElement) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    /// Stops when this build has no Keychain (an unsigned build): pairing cannot be stored.
    func skipWithoutAKeychain(unless expected: String) throws {
        let either = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", [expected, "connect.problem"])).firstMatch
        waitFor(either, "The next step, or an explanation")
        let problem = element("connect.problem")
        if problem.exists, problem.label.contains("Keychain") || (problem.value as? String ?? "").contains("Keychain") {
            throw XCTSkip("This build has no Keychain (CODE_SIGNING_ALLOWED=NO). Run the Mac UI tests from a signed build.")
        }
    }

    /// Saves a picture of the app's window (never of the whole screen) for a person to look at.
    func save(_ name: String, file: StaticString = #filePath) throws {
        let folder = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/mac-screenshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try app.windows.firstMatch.screenshot().pngRepresentation.write(to: folder.appending(path: "\(name).png"))
    }

    /// A new device asks to join, as an iPhone's Connect screen does. Returns its code, and
    /// what it collects its credential with once a manager approved it.
    func requestPairing(at server: URL, deviceName: String) async throws -> (code: String, collect: @Sendable () async throws -> Void) {
        var request = URLRequest(url: server.appending(path: "v1/pairing/requests"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["deviceName": deviceName, "platform": "ios"])
        let (data, _) = try await URLSession.shared.data(for: request)
        let answer = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let id = try XCTUnwrap(answer["id"] as? String)
        let secret = try XCTUnwrap(answer["pollSecret"] as? String)
        return (try XCTUnwrap(answer["code"] as? String), {
            var collect = URLRequest(url: server.appending(path: "v1/pairing/requests/\(id)/collect"))
            collect.httpMethod = "POST"
            collect.setValue("application/json", forHTTPHeaderField: "Content-Type")
            collect.httpBody = try JSONSerialization.data(withJSONObject: ["pollSecret": secret])
            _ = try await URLSession.shared.data(for: collect)
        })
    }
}
