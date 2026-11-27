// SPDX-License-Identifier: MPL-2.0
@preconcurrency import AVFoundation
import AppKit
import LobbyKit
@preconcurrency import ScreenCaptureKit
import SwiftUI
import XCTest

@testable import Lobby

/// Scrolls and opens pages in the running Mac app against a local server, counts late frames,
/// and records the app's own window. Like `LookWalkthrough` it skips unless it was asked for:
///
///     LOBBY_MOTION_SERVER=http://127.0.0.1:18774   a local server, best with a large library
///     LOBBY_MOTION_TOKEN=…                         a manager's token on it, to approve this Mac
///
/// The recording is `<temporary directory>/lobby-motion.mp4` inside the app's container.
@MainActor
final class MotionWalkthrough: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    func testFramesAndRecording() async throws {
        guard let address = environment["LOBBY_MOTION_SERVER"], let token = environment["LOBBY_MOTION_TOKEN"] else {
            throw XCTSkip("No LOBBY_MOTION_SERVER and LOBBY_MOTION_TOKEN: the motion walkthrough was not asked for.")
        }
        let app = try AppLaunch.shared.result.get().active
        try await pair(app, at: address, token: token)
        let window = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.canBecomeMain })
        window.setContentSize(CGSize(width: 1280, height: 800))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        print("MOTION: \(app.shelves.movies.count) films, \(app.shelves.series.count) series")

        app.sidebarSelection = .movies
        try await Task.sleep(for: .seconds(3))
        let grid = try XCTUnwrap(scrollView(in: window, vertical: true))
        try await measure("grid, 600 points a second", window, seconds: 5) { self.scroll(grid, to: 600 * $0) }
        try await measure("grid, 4000 points a second", window, seconds: 5) { self.scroll(grid, to: 3_000 + 4_000 * $0) }
        try await measure("grid, back up over what was drawn", window, seconds: 5) { self.scroll(grid, to: 23_000 - 4_000 * $0) }
        app.sidebarSelection = .library
        try await Task.sleep(for: .seconds(2))
        let shelf = try XCTUnwrap(scrollView(in: window, vertical: false))
        try await measure("shelf, 800 points a second", window, seconds: 4) {
            shelf.contentView.scroll(to: CGPoint(x: 800 * $0, y: shelf.contentView.bounds.minY))
            shelf.reflectScrolledClipView(shelf.contentView)
        }

        // The recording.
        shelf.contentView.scroll(to: .zero)
        let recorder = try await WindowRecorder(
            window: window, to: FileManager.default.temporaryDirectory.appending(path: "lobby-motion.mp4"))
        try await Task.sleep(for: .seconds(1))
        try await move(2) { shelf.contentView.scroll(to: CGPoint(x: 900 * $0 * $0, y: shelf.contentView.bounds.minY)) }
        // A library with few shelves has nothing to scroll.
        if let library = scrollView(in: window, vertical: true) { try await move(2) { self.scroll(library, to: 400 * $0) } }
        for section in [SidebarItem.movies, .series, .downloads, .movies] {
            app.sidebarSelection = section
            try await Task.sleep(for: .seconds(0.9))
        }
        if let movies = scrollView(in: window, vertical: true) { try await move(2.5) { self.scroll(movies, to: 900 * $0) } }
        if let film = app.shelves.movies.first {
            app.libraryPath = [.item(film.id)]
            try await Task.sleep(for: .seconds(1.5))
            if let page = scrollView(in: window, vertical: true) { try await move(1) { self.scroll(page, to: 160 * $0) } }
            app.libraryPath = []
            try await Task.sleep(for: .seconds(1))
            app.libraryPath = [.item(film.id)]
            try await Task.sleep(for: .seconds(1))
        }
        app.isSearching = true
        try await Task.sleep(for: .seconds(1))
        try await recorder.finish()

        // Nothing is left half way: the film's page is in full sight.
        app.isSearching = false
        await app.signOut()
        try await app.environment.forgetEverything()
    }

    // MARK: Frames

    private func measure(
        _ name: String, _ window: NSWindow, seconds: Double, _ step: @escaping @MainActor (Double) -> Void
    ) async throws {
        let meter = FrameMeter(length: seconds, step: step)
        let view = try XCTUnwrap(window.contentView)
        await meter.run(in: view)
        let intervals = meter.intervals
        let expected = meter.expected
        let late = intervals.filter { $0 > expected * 1.5 }
        let dropped = late.reduce(0) { $0 + Int(($1 / expected).rounded()) - 1 }
        print(String(
            format: "MOTION: %@: %d frames of %.1f ms, %d late, %d dropped, longest %.1f ms", name, intervals.count, expected * 1_000,
            late.count, dropped, (intervals.max() ?? 0) * 1_000))
    }

    private func move(_ length: Double, _ step: @escaping @MainActor (Double) -> Void) async throws {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(length) {
            step((ContinuousClock.now - start) / .seconds(1))
            try await Task.sleep(for: .milliseconds(8))
        }
    }

    private func scroll(_ view: NSScrollView, to y: Double) {
        let room = (view.documentView?.frame.height ?? 0) - view.contentView.bounds.height
        view.contentView.scroll(to: CGPoint(x: view.contentView.bounds.minX, y: min(max(0, y), max(0, room))))
        view.reflectScrolledClipView(view.contentView)
    }

    /// The page's own, or the first shelf in it. Not the sidebar's.
    private func scrollView(in window: NSWindow, vertical: Bool) -> NSScrollView? {
        func all(in view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(all(in:))
        }
        let found = all(in: window.contentView ?? NSView()).filter {
            guard let document = $0.documentView, !(document is NSTableView), $0.frame.width > 500 else { return false }
            return vertical
                ? document.frame.height > $0.contentView.bounds.height + 1 && $0.frame.height > 400
                : document.frame.width > $0.contentView.bounds.width + 1 && $0.frame.height < 400
        }
        return vertical ? found.last : found.first
    }

    private func pair(_ app: AppModel, at address: String, token: String) async throws {
        try await app.environment.forgetEverything()
        await app.signOut()
        let connect = ConnectModel(app: app)
        connect.addressText = address
        await connect.findServer()
        await connect.requestCode()
        guard case .code(let request, _) = connect.step else {
            return XCTFail("No pairing code: \(String(describing: connect.problem))")
        }
        var approval = URLRequest(url: try XCTUnwrap(URL(string: address)).appending(path: "v1/pairing/approve"))
        approval.httpMethod = "POST"
        approval.setValue("application/json", forHTTPHeaderField: "Content-Type")
        approval.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        approval.httpBody = try JSONSerialization.data(withJSONObject: ["code": request.code, "role": "manager"])
        _ = try await URLSession.shared.data(for: approval)
        await connect.waitUntilPaired()
        await app.selectProfile(try XCTUnwrap(app.profiles.first))
    }
}

/// Moves something once a frame, and writes down when the frames came.
@MainActor
private final class FrameMeter: NSObject {
    private(set) var intervals: [Double] = []
    private(set) var expected = 1.0 / 60
    private let length: Double
    private let step: @MainActor (Double) -> Void
    private var start: Double?
    private var last: Double?
    private var finished: CheckedContinuation<Void, Never>?

    init(length: Double, step: @escaping @MainActor (Double) -> Void) {
        self.length = length
        self.step = step
    }

    func run(in view: NSView) async {
        let link = view.displayLink(target: self, selector: #selector(frame))
        link.add(to: .main, forMode: .common)
        await withCheckedContinuation { finished = $0 }
        link.invalidate()
    }

    @objc private func frame(_ link: CADisplayLink) {
        // When the frame was really drawn: the main thread is what is late.
        let now = CACurrentMediaTime()
        expected = link.duration
        if let last { intervals.append(now - last) }
        last = now
        if start == nil { start = now }
        let elapsed = now - (start ?? now)
        step(elapsed)
        if elapsed > length {
            finished?.resume()
            finished = nil
        }
    }
}

/// Records one window of this app. An app may look at its own windows without permission.
/// Everything on the main queue: a late frame there is a late frame in the recording too, and
/// nothing is measured while it runs.
@MainActor
private final class WindowRecorder: NSObject, @MainActor SCStreamOutput {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var stream: SCStream?
    private var hasStarted = false

    init(window: NSWindow, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let size = window.frame.size
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_500_000],
        ])
        super.init()
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        let id = CGWindowID(window.windowNumber)
        let content = try await SCShareableContent.currentProcess
        let found = try XCTUnwrap(content.windows.first { $0.windowID == id })
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: found), configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        self.stream = stream
        try await stream.startCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid, buffer.imageBuffer != nil else { return }
        if !hasStarted {
            hasStarted = true
            writer.startWriting()
            writer.startSession(atSourceTime: buffer.presentationTimeStamp)
        }
        if input.isReadyForMoreMediaData { input.append(buffer) }
    }

    func finish() async throws {
        try await stream?.stopCapture()
        guard hasStarted else { return }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
    }
}
