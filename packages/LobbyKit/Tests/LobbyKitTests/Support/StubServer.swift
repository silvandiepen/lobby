// SPDX-License-Identifier: MPL-2.0
import Foundation
import Synchronization

@testable import LobbyKit

/// A request as the stub saw it.
struct RecordedRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    func json() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
    }
}

struct StubResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func json(_ status: Int = 200, _ text: String, headers: [String: String] = [:]) -> StubResponse {
        StubResponse(status: status, headers: headers, body: Data(text.utf8))
    }

    static func error(_ status: Int, _ code: String, _ message: String = "No.", extra: String = "") -> StubResponse {
        .json(status, #"{ "error": { "code": "\#(code)", "message": "\#(message)" }\#(extra) }"#)
    }
}

/// The network under test: a `URLProtocol` that answers for one made-up host with JSON written
/// to match `docs/api.md`. The client, cache and queue above it are the real ones.
///
/// Each `StubServer` has its own host, so tests can run in parallel.
final class StubServer: Sendable {
    typealias Handler = @Sendable (RecordedRequest) throws -> StubResponse

    let host = "\(UUID().uuidString.lowercased()).lobby.test"
    private let requests = Mutex<[RecordedRequest]>([])

    var baseURL: URL { URL(string: "http://\(host)")! }

    init(_ handler: @escaping Handler) {
        setHandler(handler)
    }

    deinit {
        StubURLProtocol.handlers.withLock { $0[host] = nil }
    }

    /// Replaces the behaviour, e.g. to take the server offline half-way through a test.
    func setHandler(_ handler: @escaping Handler) {
        let record: Handler = { [weak self] request in
            self?.requests.withLock { $0.append(request) }
            return try handler(request)
        }
        StubURLProtocol.handlers.withLock { $0[host] = record }
    }

    func goOffline() {
        setHandler { _ in throw URLError(.cannotConnectToHost) }
    }

    var recorded: [RecordedRequest] { requests.withLock { $0 } }

    func client(token: String? = "test-token") throws -> LobbyClient {
        try LobbyClient(baseURL: baseURL, token: token, session: session)
    }

    /// A session that reaches every stub server, this one and the others.
    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

final class StubURLProtocol: URLProtocol {
    static let handlers = Mutex<[String: StubServer.Handler]>([:])

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".lobby.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
            let handler = Self.handlers.withLock({ $0[host] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(
            (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET",
            // The path as sent, so a test can see that an id was percent-encoded.
            path: components?.percentEncodedPath ?? url.path,
            query: query,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.body(of: request))

        do {
            let stub = try handler(recorded)
            let response = HTTPURLResponse(
                url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// A folder for one test's files, removed when the test ends.
final class TemporaryDirectory: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "LobbyKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL {
        url.appending(path: name, directoryHint: .notDirectory)
    }
}

/// A clock a test moves by hand.
final class TestClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date = Date(millisecondsSince1970: 1_795_530_000_000)) {
        current = Mutex(start)
    }

    var now: Date { current.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 += seconds }
    }
}

/// Operation ids a test can predict: op-1, op-2, …
final class OperationIDs: Sendable {
    private let count = Mutex(0)

    func next() -> String {
        count.withLock {
            $0 += 1
            return "op-\($0)"
        }
    }
}
