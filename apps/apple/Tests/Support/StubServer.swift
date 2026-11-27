// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Synchronization

/// A request as the stub saw it.
struct RecordedRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    func json() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }
}

struct StubResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func json(_ status: Int = 200, _ text: String) -> StubResponse {
        StubResponse(status: status, body: Data(text.utf8))
    }

    /// A model from LobbyKit, written the way the server writes it.
    static func encoded(_ value: some Encodable, status: Int = 200) throws -> StubResponse {
        StubResponse(status: status, body: try LobbyJSON.encoder().encode(value))
    }

    static func error(_ status: Int, _ code: String, _ message: String) -> StubResponse {
        .json(status, #"{ "error": { "code": "\#(code)", "message": "\#(message)" } }"#)
    }
}

/// The network under test: a `URLProtocol` that answers for one made-up host, the same way
/// LobbyKit's own tests do. The client, the stores and the queue above it are the real ones.
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

    func setHandler(_ handler: @escaping Handler) {
        let record: Handler = { [weak self] request in
            self?.requests.withLock { $0.append(request) }
            return try handler(request)
        }
        StubURLProtocol.handlers.withLock { $0[host] = record }
    }

    var recorded: [RecordedRequest] { requests.withLock { $0 } }

    func requests(_ method: String, _ path: String) -> [RecordedRequest] {
        recorded.filter { $0.method == method && $0.path == path }
    }

    var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    var session: URLSession {
        URLSession(configuration: configuration)
    }

    func client(token: String? = "test-token") throws -> LobbyClient {
        try LobbyClient(baseURL: baseURL, token: token, session: session)
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
            .appending(path: "LobbyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
