// SPDX-License-Identifier: MPL-2.0
import Foundation

/// One file over the direct road. The system's background transfers cannot use that road, because it
/// is inside the app: this one runs while the app does, in pieces, and what arrived stays for the
/// next time the app is open.
struct CarriedTransfer: Sendable {
    struct Outcome: Sendable {
        /// nil when the server did not give the file.
        var staged: URL?
        var status: Int
        var etag: String?
    }

    var request: URLRequest
    var revision: String
    var expectedBytes: Int64
    var partial: URL
    var staged: URL
    var session: URLSession
    /// A pause or a broken road costs at most one.
    var pieceBytes: Int64 = 4 << 20

    var receivedBytes: Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        return size <= expectedBytes ? size : 0
    }

    func run(progress: @Sendable (Int64) async -> Void) async throws -> Outcome {
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        var received = receivedBytes
        if received == 0 {
            // Nothing, or more than there can be.
            try Data().write(to: partial)
        }
        let file = try FileHandle(forWritingTo: partial)
        defer { try? file.close() }
        try file.truncate(atOffset: UInt64(received))
        var etag: String?
        while received < expectedBytes {
            try Task.checkCancellation()
            let end = min(received + pieceBytes, expectedBytes) - 1
            var request = request
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("bytes=\(received)-\(end)", forHTTPHeaderField: "Range")
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if let pause = LobbyError.busyPause(of: http) {
                try await Task.sleep(for: pause)
                continue
            }
            let tag = http.value(forHTTPHeaderField: "ETag")
            guard http.statusCode == 206, tag?.contains(revision) == true, Int64(data.count) == end - received + 1 else {
                // Gone, another file now, or an answer that does not fit.
                return Outcome(staged: nil, status: http.statusCode == 206 ? 404 : http.statusCode, etag: tag)
            }
            try file.write(contentsOf: data)
            etag = tag
            received = end + 1
            await progress(received)
        }
        try file.synchronize()
        if FileManager.default.fileExists(atPath: staged.path) { try FileManager.default.removeItem(at: staged) }
        try FileManager.default.moveItem(at: partial, to: staged)
        return Outcome(staged: staged, status: 206, etag: etag)
    }
}

extension LobbyError {
    static func busyPause(of http: HTTPURLResponse) -> Duration? {
        guard http.statusCode == 429 else { return nil }
        let asked = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 5
        return .seconds(min(60, max(1, asked)))
    }
}
