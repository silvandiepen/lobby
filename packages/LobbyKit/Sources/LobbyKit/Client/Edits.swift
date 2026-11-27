// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A change was based on an older state: someone else was first. Carries what there is now,
/// so the editor can show it and the person decide again.
public struct EditConflict<Current: Sendable>: Error, Sendable {
    /// Written for a person by the server.
    public var message: String
    public var current: Current
}

extension EditConflict: LocalizedError {
    public var errorDescription: String? { message }
}

/// A change of the categories would let a kids viewer see more than now
/// (`409 kids_confirmation`). Nothing was changed. Show `changes` to the manager, and send the
/// same change again with `token` when they allow it.
public struct KidsConfirmationNeeded<Current: Sendable>: Error, Sendable {
    /// Written for a person by the server.
    public var message: String
    public var changes: [KidsChange]
    /// Names exactly what would appear.
    public var token: String
    /// The setup as it is, unchanged.
    public var current: Current
}

extension KidsConfirmationNeeded: LocalizedError {
    public var errorDescription: String? { message }
}

/// What a change means for one kids viewer.
public struct KidsChange: Codable, Hashable, Sendable, Identifiable {
    /// Some of the titles, with how many there are in all.
    public struct Titles: Codable, Hashable, Sendable {
        public struct Title: Codable, Hashable, Sendable, Identifiable {
            public var id: String
            public var title: String

            public init(id: String, title: String) {
                self.id = id
                self.title = title
            }
        }

        public var count: Int
        /// The first by title; at most 50.
        public var titles: [Title]

        public init(count: Int, titles: [Title]) {
            self.count = count
            self.titles = titles
        }
    }

    public var profileId: String
    public var name: String
    /// Films, shows and videos with something in them the viewer did not see before.
    public var appearing: Titles
    public var disappearing: Titles

    public var id: String { profileId }

    public init(profileId: String, name: String, appearing: Titles, disappearing: Titles) {
        self.profileId = profileId
        self.name = name
        self.appearing = appearing
        self.disappearing = disappearing
    }
}

/// What a `kids_confirmation` refusal carries beside the setup.
struct KidsQuestionBody: Decodable {
    var kidsChanges: [KidsChange]
    var kidsToken: String
}

/// A value in the body of a change. An explicit null means "nothing", which is not the same
/// as leaving a field out.
enum EditValue: Encodable, Sendable {
    case text(String)
    case number(Int)
    case texts([String])
    case object([String: EditValue])
    case objects([[String: EditValue]])
    case bool(Bool)
    case null

    init(_ text: String?) { self = text.map(EditValue.text) ?? .null }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .texts(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .objects(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension LobbyClient {
    /// Sends one change and reads the new state. A 409 that carries the current state throws
    /// `EditConflict`.
    func edit<Current: Decodable & Sendable>(
        _ method: String, _ segments: [String], query: [URLQueryItem] = [], body: [String: EditValue]? = nil
    ) async throws -> Current {
        var request = request(method, segments, query: query)
        if let body {
            request.httpBody = try LobbyJSON.encoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await performEdit(request)
    }

    /// The same with a picture as the body.
    func edit<Current: Decodable & Sendable>(
        uploading picture: Data, contentType: String, to segments: [String], query: [URLQueryItem]
    ) async throws -> Current {
        var request = request("POST", segments, query: query)
        request.httpBody = picture
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        // A large picture over a slow uplink.
        request.timeoutInterval = 180
        return try await performEdit(request)
    }

    private func performEdit<Current: Decodable & Sendable>(_ request: URLRequest) async throws -> Current {
        let (data, http) = try await performAnyStatus(request)
        if (200..<300).contains(http.statusCode) {
            return try decode(data)
        }
        let error = LobbyError.from(status: http.statusCode, data: data, headers: http)
        if case .server(409, "kids_confirmation", let message) = error {
            if let question: KidsQuestionBody = try? decode(data), let current: Current = try? decode(data) {
                throw KidsConfirmationNeeded(
                    message: message, changes: question.kidsChanges, token: question.kidsToken, current: current)
            }
        }
        if case .conflict(let message, _) = error, let current: Current = try? decode(data) {
            throw EditConflict(message: message, current: current)
        }
        throw error
    }

    static func revision(_ revision: Int) -> URLQueryItem {
        URLQueryItem(name: "revision", value: String(revision))
    }

    /// The picture at a path the server gave (a preview), with the device's credential.
    public func picture(atServerPath path: String) async throws -> Data {
        guard let url = resolve(serverPath: path), url.host == baseURL.host, url.port == baseURL.port else {
            throw LobbyError.invalidResponse("\(path) is not on this server.")
        }
        return try await data(at: url)
    }
}
