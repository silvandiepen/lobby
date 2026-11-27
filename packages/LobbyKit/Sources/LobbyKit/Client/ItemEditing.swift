// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum ArtworkKind: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case poster, backdrop, still
    /// The title as a word mark, with transparency.
    case logo

    public var id: String { rawValue }
}

/// A title as a manager edits it (`GET /v1/items/{id}/edit`): what Lobby found by itself, what
/// was changed, and what there is to choose from.
public struct ItemEdit: Decodable, Hashable, Sendable {
    /// One field: the automatic value under the manager's.
    public struct Field<Value: Decodable & Hashable & Sendable>: Decodable, Hashable, Sendable {
        public var automatic: Value?
        public var overridden: Bool
        public var effective: Value?
    }

    /// Only the fields this kind of item has.
    public struct Fields: Decodable, Hashable, Sendable {
        public var title: Field<String>?
        public var sortTitle: Field<String>?
        public var year: Field<Int>?
        public var overview: Field<String>?
        public var genres: Field<[String]>?
    }

    public struct Category: Decodable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
    }

    public struct CategoryChoice: Decodable, Hashable, Sendable {
        public var automatic: [String]
        public var overridden: Bool
        public var effective: [String]
    }

    public struct Match: Decodable, Hashable, Sendable {
        public struct Candidate: Decodable, Hashable, Sendable {
            public var type: String
            public var id: Int
            public var title: String
            public var year: Int?
            public var overview: String?
        }

        public var status: MatchStatus
        /// A manager decided: this match, or none.
        public var chosen: Bool
        public var tmdb: TMDBReference?
        /// Only films and shows.
        public var canChange: Bool
        /// False when the server has no TMDB key.
        public var available: Bool
        /// Why it was not matched.
        public var reason: String?
        /// What it might be.
        public var candidates: [Candidate]
        /// What was read from the file names.
        public var evidence: [String]
    }

    public var item: Item
    /// Counts edits to this item only.
    public var revision: Int
    public var fields: Fields
    /// The categories to choose from. Empty when the item has none of its own.
    public var categories: [Category]
    public var categoryIds: CategoryChoice
    /// The pictures on the server, the selected one first, for the kinds this item has.
    public var artwork: [String: [ArtworkOption]]
    /// A manager chose that there is no logo: the title is written. nil from an older server.
    public var withoutLogo: Bool?
    public var match: Match

    public var artworkKinds: [ArtworkKind] { ArtworkKind.allCases.filter { artwork[$0.rawValue] != nil } }
    public func options(for kind: ArtworkKind) -> [ArtworkOption] { artwork[kind.rawValue] ?? [] }
}

/// A picture to choose for a title.
public struct ArtworkOption: Decodable, Hashable, Sendable, Identifiable {
    public enum Source: String, Decodable, Hashable, Sendable {
        case tmdb, frame, upload
        /// A source this version does not know: it can be shown and chosen all the same.
        case unknown

        public init(from decoder: any Decoder) throws {
            self = Source(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var source: Source
    /// nil for a picture that is still only at TMDB.
    public var artworkId: String?
    public var path: String?
    /// A small version, on this server.
    public var previewUrl: String
    public var width: Int?
    public var height: Int?
    public var language: String?
    public var selected: Bool
    /// Selected by a manager, so no refresh replaces it.
    public var chosen: Bool

    public var id: String { artworkId ?? path ?? previewUrl }
}

/// What can be chosen for one picture of a title, TMDB's among it.
public struct ArtworkOptions: Decodable, Hashable, Sendable {
    public var revision: Int
    public var tmdbAvailable: Bool
    public var options: [ArtworkOption]
}

/// A film or series TMDB knows.
public struct MatchResult: Decodable, Hashable, Sendable, Identifiable {
    public var tmdb: TMDBReference
    public var title: String
    public var originalTitle: String?
    public var year: Int?
    public var overview: String?
    public var previewUrl: String?

    public var id: Int { tmdb.id }
}

/// What a manager changed about a title. Only what is set here is sent.
public struct ItemChanges: Hashable, Sendable {
    /// Fields that can be put back to automatic.
    public enum Field: String, Hashable, Sendable, CaseIterable {
        case title, sortTitle, year, overview, genres, categories
    }

    public var title: String?
    public var sortTitle: String?
    /// `.some(nil)`: it has no year.
    public var year: Int??
    /// `.some(nil)`: it has no summary.
    public var overview: String??
    public var genres: [String]?
    public var categoryIds: [String]?
    public var reset: Set<Field>

    public init(
        title: String? = nil, sortTitle: String? = nil, year: Int?? = nil, overview: String?? = nil,
        genres: [String]? = nil, categoryIds: [String]? = nil, reset: Set<Field> = []
    ) {
        self.title = title
        self.sortTitle = sortTitle
        self.year = year
        self.overview = overview
        self.genres = genres
        self.categoryIds = categoryIds
        self.reset = reset
    }

    public var isEmpty: Bool { values.isEmpty && reset.isEmpty }

    /// The new values, as the server reads them.
    var values: [String: EditValue] {
        var set: [String: EditValue] = [:]
        if let title { set["title"] = .text(title) }
        if let sortTitle { set["sortTitle"] = .text(sortTitle) }
        if let year { set["year"] = year.map(EditValue.number) ?? .null }
        if let overview { set["overview"] = EditValue(overview) }
        if let genres { set["genres"] = .texts(genres) }
        if let categoryIds { set["categoryIds"] = .texts(categoryIds) }
        return set
    }
}

/// Changing a title. Manager only. Every change names the revision it is based on and answers
/// with the new state; `EditConflict<ItemEdit>` when someone else was first.
extension LobbyClient {
    public func itemEdit(id: String) async throws -> ItemEdit {
        try await get(["items", id, "edit"])
    }

    public func updateItem(id: String, changes: ItemChanges, revision: Int) async throws -> ItemEdit {
        var body: [String: EditValue] = ["revision": .number(revision)]
        if !changes.values.isEmpty { body["set"] = .object(changes.values) }
        if !changes.reset.isEmpty { body["reset"] = .texts(changes.reset.map(\.rawValue).sorted()) }
        return try await edit("PATCH", ["items", id], body: body)
    }

    /// What is on the server, then pictures from TMDB.
    public func artworkOptions(itemID: String, kind: ArtworkKind) async throws -> ArtworkOptions {
        try await get(["items", itemID, "artwork-options"], query: [Self.kind(kind)])
    }

    /// Chooses a picture: it stays until it is put back.
    public func chooseArtwork(itemID: String, kind: ArtworkKind, option: ArtworkOption, revision: Int) async throws -> ItemEdit {
        var body: [String: EditValue] = ["revision": .number(revision), "kind": .text(kind.rawValue)]
        if let artworkID = option.artworkId {
            body["source"] = .text("existing")
            body["artworkId"] = .text(artworkID)
        } else {
            body["source"] = .text("tmdb")
            body["path"] = EditValue(option.path)
        }
        return try await edit("POST", ["items", itemID, "artwork"], body: body)
    }

    /// A picture from the film itself.
    public func chooseFrame(itemID: String, kind: ArtworkKind, positionMs: Int, revision: Int) async throws -> ItemEdit {
        try await edit("POST", ["items", itemID, "artwork"], body: [
            "revision": .number(revision), "kind": .text(kind.rawValue), "source": .text("frame"),
            "positionMs": .number(positionMs),
        ])
    }

    /// No logo: the title is written.
    public func chooseNoLogo(itemID: String, revision: Int) async throws -> ItemEdit {
        try await edit("POST", ["items", itemID, "artwork"], body: [
            "revision": .number(revision), "kind": .text(ArtworkKind.logo.rawValue), "source": .text("none"),
        ])
    }

    /// - Parameter picture: A JPEG, or for a logo a PNG. At most 20 MB.
    public func uploadArtwork(itemID: String, kind: ArtworkKind, picture: Data, revision: Int) async throws -> ItemEdit {
        try await edit(
            uploading: picture, contentType: kind == .logo ? "image/png" : "image/jpeg", to: ["items", itemID, "artwork", "upload"],
            query: [Self.kind(kind), Self.revision(revision)])
    }

    /// Back to the picture Lobby chooses.
    public func resetArtwork(itemID: String, kind: ArtworkKind, revision: Int) async throws -> ItemEdit {
        try await edit("DELETE", ["items", itemID, "artwork"], query: [Self.kind(kind), Self.revision(revision)])
    }

    /// Searches TMDB for a film or show.
    public func searchMatch(itemID: String, query: String, year: Int?) async throws -> [MatchResult] {
        struct Answer: Decodable {
            var results: [MatchResult]
        }
        let answer: Answer = try await get(["items", itemID, "match"], query: [URLQueryItem(name: "query", value: query)]
            + (year.map { [URLQueryItem(name: "year", value: String($0))] } ?? []))
        return answer.results
    }

    public func setMatch(itemID: String, to tmdb: TMDBReference, revision: Int) async throws -> ItemEdit {
        try await edit("PUT", ["items", itemID, "match"], body: [
            "revision": .number(revision), "tmdbType": .text(tmdb.type.rawValue), "tmdbId": .number(tmdb.id),
        ])
    }

    /// There is no match: the title shows what its files say.
    public func removeMatch(itemID: String, revision: Int) async throws -> ItemEdit {
        try await edit("DELETE", ["items", itemID, "match"], query: [Self.revision(revision)])
    }

    /// Lobby looks it up by itself again.
    public func automaticMatch(itemID: String, revision: Int) async throws -> ItemEdit {
        try await edit("POST", ["items", itemID, "match", "automatic"], body: ["revision": .number(revision)])
    }

    private static func kind(_ kind: ArtworkKind) -> URLQueryItem {
        URLQueryItem(name: "kind", value: kind.rawValue)
    }
}
