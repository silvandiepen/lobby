// SPDX-License-Identifier: MPL-2.0
import Foundation

// Import folders, the Inbox and uploads (`/v1/imports…`, `/v1/uploads…`), as `docs/api.md`
// describes them under "Imports and uploads". For managers at home or over Tailscale.

/// One file of an import folder, or an upload, and what became of it.
public struct ImportItem: Codable, Hashable, Sendable, Identifiable {
    public struct Candidate: Codable, Hashable, Sendable {
        public var title: String
        public var year: Int?
        public var tmdbId: Int
    }

    public struct Leftovers: Codable, Hashable, Sendable {
        public var dir: String
        public var files: [String]
    }

    public var id: String
    /// `folder` or `upload`.
    public var origin: String
    public var folder: String?
    public var name: String
    public var relPath: String
    public var sizeBytes: Int64
    /// `waiting`, `inbox`, `moving`, `imported`, `listed`, `ignored`, `failed`, `dismissed`.
    public var state: String
    public var reason: String?
    /// `movie`, `episode`, or nil when it is not known.
    public var kind: String?
    public var title: String?
    public var year: Int?
    public var season: Int?
    public var episode: Int?
    public var episodeTitle: String?
    public var tmdbId: Int?
    public var candidates: [Candidate]
    public var destination: String?
    public var targetPath: String?
    public var subtitles: [String]
    public var leftovers: Leftovers?
    public var uploadId: String?
    public var convertible: Bool
    /// `move`, `list`, `dismiss`, `cleanUp`, `convert`: what can be done with it now.
    public var actions: [String]
    public var firstSeenAt: Date
    public var updatedAt: Date
    public var doneAt: Date?

    public func can(_ action: String) -> Bool { actions.contains(action) }
}

/// The import folders and what is in them, for Server Settings and the Inbox.
public struct ImportsStatus: Codable, Hashable, Sendable {
    public struct Folder: Codable, Hashable, Sendable, Identifiable {
        public var path: String
        public var name: String
        /// `move` or `index`.
        public var mode: String
        public var looksLikeDownloads: Bool
        public var connected: Bool
        public var counts: [String: Int]
        public var lastLookAt: Date?
        public var problem: String?
        public var id: String { path }
    }

    public struct Destination: Codable, Hashable, Sendable, Identifiable {
        public var path: String
        public var name: String
        public var hint: String
        public var id: String { path }
    }

    public struct Settings: Codable, Hashable, Sendable {
        public var waitMinutes: Double
        public var copyAcrossDrives: Bool
        public var maxFileGb: Double
        public var quotaGb: Double
    }

    public var folders: [Folder]
    public var counts: [String: Int]
    /// False without Lobby's folder: files wait in the Inbox and uploads are refused.
    public var moving: Bool
    public var driveConnected: Bool
    public var destinations: [Destination]
    public var settings: Settings
}

/// One line of what happened to imports.
public struct ImportActivity: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var at: Date
    public var itemId: String?
    public var deviceId: String?
    public var action: String
    public var message: String
}

/// What a manager decided about a file in the Inbox.
public struct ImportDecision: Encodable, Hashable, Sendable {
    /// `move` or `list`.
    public var action: String
    /// `movie` or `episode`.
    public var kind: String?
    public var title: String?
    public var year: Int?
    public var season: Int?
    public var episode: Int?
    public var episodeTitle: String?
    public var destination: String?

    public init(
        action: String = "move", kind: String? = nil, title: String? = nil, year: Int? = nil, season: Int? = nil,
        episode: Int? = nil, episodeTitle: String? = nil, destination: String? = nil
    ) {
        self.action = action
        self.kind = kind
        self.title = title
        self.year = year
        self.season = season
        self.episode = episode
        self.episodeTitle = episodeTitle
        self.destination = destination
    }
}

/// Where an upload goes: the films' folder, the series' folder, or one library folder (a category).
public enum UploadDestination: Codable, Hashable, Sendable {
    case movies
    case series
    case folder(path: String)

    private enum CodingKeys: String, CodingKey { case kind, path }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "series": self = .series
        case "folder": self = .folder(path: try container.decode(String.self, forKey: .path))
        default: self = .movies
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .movies: try container.encode("movies", forKey: .kind)
        case .series: try container.encode("series", forKey: .kind)
        case .folder(let path):
            try container.encode("folder", forKey: .kind)
            try container.encode(path, forKey: .path)
        }
    }
}

/// An upload as the server has it.
public struct ServerUpload: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var batch: String?
    public var relPath: String
    public var name: String
    public var sizeBytes: Int64
    public var receivedBytes: Int64
    /// `receiving`, `verifying`, `done`, `failed`, `cancelled`.
    public var state: String
    public var reason: String?
    public var destination: UploadDestination
    public var itemId: String?
    public var createdAt: Date
    public var updatedAt: Date
}

/// How a piece of an upload went.
public enum UploadPieceOutcome: Hashable, Sendable {
    /// Taken: the upload is at this offset now.
    case accepted(offset: Int64)
    /// Refused because the upload is elsewhere, the piece was cut off or damaged: go on from here.
    case elsewhere(offset: Int64, message: String)
}

extension LobbyClient {
    /// `GET /v1/imports`. Manager.
    public func imports() async throws -> ImportsStatus {
        try await get(["imports"])
    }

    /// `GET /v1/imports/items?view=…`. Manager. `inbox`, `waiting`, `ignored`, `done` or `all`.
    public func importItems(view: String, limit: Int = 200) async throws -> [ImportItem] {
        struct Answer: Decodable { var items: [ImportItem] }
        let answer: Answer = try await get(
            ["imports", "items"],
            query: [URLQueryItem(name: "view", value: view), URLQueryItem(name: "limit", value: String(limit))])
        return answer.items
    }

    /// `POST /v1/imports/items/{id}/confirm`. Manager.
    public func confirmImport(_ id: String, _ decision: ImportDecision) async throws -> ImportItem {
        struct Answer: Decodable { var item: ImportItem }
        let answer: Answer = try await send("POST", ["imports", "items", id, "confirm"], body: decision)
        return answer.item
    }

    /// `POST /v1/imports/items/{id}/dismiss`. Manager.
    public func dismissImport(_ id: String) async throws -> ImportItem {
        struct Answer: Decodable { var item: ImportItem }
        let answer: Answer = try await send("POST", ["imports", "items", id, "dismiss"])
        return answer.item
    }

    /// `POST /v1/imports/items/{id}/clean-up`. Manager. Deletes what was left of its folder.
    public func cleanUpImport(_ id: String) async throws -> ImportItem {
        struct Body: Encodable { var confirm = "delete leftovers" }
        struct Answer: Decodable { var item: ImportItem }
        let answer: Answer = try await send("POST", ["imports", "items", id, "clean-up"], body: Body())
        return answer.item
    }

    /// `POST /v1/imports/items/{id}/convert`. Manager. Puts an old format in the conversion queue.
    public func convertImport(_ id: String) async throws {
        struct Answer: Decodable { var queued: Int }
        let _: Answer = try await send("POST", ["imports", "items", id, "convert"])
    }

    /// `GET /v1/imports/activity`. Manager. Newest first.
    public func importActivity(limit: Int = 100) async throws -> [ImportActivity] {
        struct Answer: Decodable { var entries: [ImportActivity] }
        let answer: Answer = try await get(["imports", "activity"], query: [URLQueryItem(name: "limit", value: String(limit))])
        return answer.entries
    }

    /// `POST /v1/imports/scan`. Manager. Looks through the folders now.
    public func scanImports() async throws {
        try await sendDiscardingAnswer("POST", ["imports", "scan"])
    }

    // MARK: Uploads

    /// `POST /v1/uploads`. Manager. The same request again gives the same unfinished upload.
    public func createUpload(
        relPath: String, sizeBytes: Int64, destination: UploadDestination, batch: String?, sha256: String? = nil
    ) async throws -> ServerUpload {
        struct Body: Encodable {
            var relPath: String
            var sizeBytes: Int64
            var destination: UploadDestination
            var batch: String?
            var sha256: String?
        }
        struct Answer: Decodable { var upload: ServerUpload }
        let answer: Answer = try await send(
            "POST", ["uploads"],
            body: Body(relPath: relPath, sizeBytes: sizeBytes, destination: destination, batch: batch, sha256: sha256))
        return answer.upload
    }

    /// `GET /v1/uploads/{id}`: the upload, and the offset to go on from.
    public func uploadState(_ id: String) async throws -> (upload: ServerUpload, offset: Int64) {
        struct Answer: Decodable {
            var upload: ServerUpload
            var offset: Int64
        }
        let answer: Answer = try await get(["uploads", id])
        return (answer.upload, answer.offset)
    }

    /// The request for one piece, to send with the piece's bytes as the body (from a file, so a
    /// background `URLSession` can send it while the app is not running).
    ///
    /// - Parameter checksum: The piece's SHA-256, base64.
    public func uploadPieceRequest(_ id: String, offset: Int64, length: Int64, checksum: String) -> URLRequest {
        var request = request("PATCH", ["uploads", id])
        request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        request.setValue(String(length), forHTTPHeaderField: "Content-Length")
        request.setValue("sha256 \(checksum)", forHTTPHeaderField: "Upload-Checksum")
        request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// What the answer to a piece says.
    public static func uploadPieceOutcome(status: Int, headers: HTTPURLResponse, data: Data) throws -> UploadPieceOutcome {
        if (200..<300).contains(status) {
            guard let offset = headers.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int64.init) else {
                throw LobbyError.invalidResponse("The answer to a piece did not say where the upload is.")
            }
            return .accepted(offset: offset)
        }
        if status == 409 {
            struct Answer: Decodable {
                struct Problem: Decodable { var message: String }
                var error: Problem
                var offset: Int64?
            }
            if let answer = try? LobbyJSON.decoder().decode(Answer.self, from: data), let offset = answer.offset {
                return .elsewhere(offset: offset, message: answer.error.message)
            }
        }
        throw LobbyError.from(status: status, data: data, headers: headers)
    }

    /// `POST /v1/uploads/{id}/complete`, with the whole file's SHA-256 in hex.
    public func completeUpload(_ id: String, sha256: String) async throws -> ServerUpload {
        struct Body: Encodable { var sha256: String }
        struct Answer: Decodable { var upload: ServerUpload }
        let answer: Answer = try await send("POST", ["uploads", id, "complete"], body: Body(sha256: sha256))
        return answer.upload
    }

    /// `DELETE /v1/uploads/{id}`: stops it, and the server removes what arrived.
    @discardableResult
    public func cancelUpload(_ id: String) async throws -> ServerUpload {
        struct Answer: Decodable { var upload: ServerUpload }
        let answer: Answer = try await send("DELETE", ["uploads", id])
        return answer.upload
    }
}
