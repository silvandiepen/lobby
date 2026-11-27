// SPDX-License-Identifier: MPL-2.0
import Foundation

/// `GET /v1/categories/edit`: the setup with what a manager needs to change it.
public struct CategoriesEdit: Decodable, Hashable, Sendable {
    /// A library folder and the category it feeds.
    public struct Folder: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var hint: SourceHint?
        public var available: Bool
        public var categoryId: String?
    }

    public var setup: CategoryGroups
    public var folders: [Folder]
    /// The colour names the server accepts.
    public var colors: [String]
    /// Takes the last arrangement back while nothing else changed. nil: there is none, or an
    /// older server.
    public var undo: String?
    /// What the change that answered this meant for kids viewers. Empty from an older server.
    public var kidsChanges: [KidsChange]
    /// From an arrangement: the ids of the categories it made, by the request's keys.
    public var created: [String: String]
    /// From accepting a suggestion: the category that follows the studios now.
    public var categoryId: String?
    /// From accepting several suggestions: what was made or joined, in their order.
    public var categoryIds: [String]
    /// The answer to a dry run: nothing changed, this is how it would be.
    public var dryRun: Bool
    /// From a dry run: a kids viewer would see more, so the manager is asked first.
    public var needsConfirmation: Bool
    /// Names exactly what kids viewers would see by the change; sent with it, it holds only for that.
    public var kidsToken: String?

    public var revision: Int { setup.revision }

    private enum CodingKeys: String, CodingKey {
        case folders, colors, undo, kidsChanges, created, categoryId, categoryIds, dryRun, needsConfirmation, kidsToken
    }

    public init(from decoder: any Decoder) throws {
        setup = try CategoryGroups(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folders = try container.decode([Folder].self, forKey: .folders)
        colors = try container.decode([String].self, forKey: .colors)
        undo = try container.decodeIfPresent(String.self, forKey: .undo)
        kidsChanges = try container.decodeIfPresent([KidsChange].self, forKey: .kidsChanges) ?? []
        created = try container.decodeIfPresent([String: String].self, forKey: .created) ?? [:]
        categoryId = try container.decodeIfPresent(String.self, forKey: .categoryId)
        categoryIds = try container.decodeIfPresent([String].self, forKey: .categoryIds) ?? []
        dryRun = try container.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
        needsConfirmation = try container.decodeIfPresent(Bool.self, forKey: .needsConfirmation) ?? false
        kidsToken = try container.decodeIfPresent(String.self, forKey: .kidsToken)
    }
}

/// Several changes of the categories as one (`POST /v1/categories/arrange`): all of them, or
/// none. Only the result has to fit, so two can swap names.
public struct CategoryArrangement: Hashable, Sendable {
    /// A new category. Elsewhere in the same arrangement `"new:<key>"` stands for its id.
    public struct New: Hashable, Sendable {
        public var key: String
        public var groupID: String?
        /// `.some(nil)`: top-level.
        public var parentID: String??
        public var name: String
        public var icon: String??
        public var color: String??
        /// The category whose logo it takes, as that one has it before the arrangement.
        public var logoFrom: String?

        public init(
            key: String, groupID: String? = nil, parentID: String?? = nil, name: String, icon: String?? = nil,
            color: String?? = nil, logoFrom: String? = nil
        ) {
            self.key = key
            self.groupID = groupID
            self.parentID = parentID
            self.name = name
            self.icon = icon
            self.color = color
            self.logoFrom = logoFrom
        }
    }

    /// A change of an existing category; what is nil stays as it is.
    public struct Change: Hashable, Sendable {
        public var id: String
        public var name: String?
        public var groupID: String?
        /// `.some(nil)`: out of the category it is in, top-level.
        public var parentID: String??
        public var icon: String??
        public var color: String??
        public var logoFrom: String?

        public init(
            id: String, name: String? = nil, groupID: String? = nil, parentID: String?? = nil, icon: String?? = nil,
            color: String?? = nil, logoFrom: String? = nil
        ) {
            self.id = id
            self.name = name
            self.groupID = groupID
            self.parentID = parentID
            self.icon = icon
            self.color = color
            self.logoFrom = logoFrom
        }
    }

    /// The order of the top-level categories of a group (`parentID` nil), or of those inside one.
    public struct Order: Hashable, Sendable {
        public var groupID: String
        public var parentID: String?
        public var ids: [String]

        public init(groupID: String, parentID: String?, ids: [String]) {
            self.groupID = groupID
            self.parentID = parentID
            self.ids = ids
        }
    }

    public var create: [New]
    public var categories: [Change]
    public var order: [Order]

    public init(create: [New] = [], categories: [Change] = [], order: [Order] = []) {
        self.create = create
        self.categories = categories
        self.order = order
    }

    /// The id that stands for a new category within the same arrangement.
    public static func newID(_ key: String) -> String { "new:\(key)" }

    public var isEmpty: Bool { create.isEmpty && categories.isEmpty && order.isEmpty }

    var body: [String: EditValue] {
        func optional(_ value: String??) -> EditValue? { value.map { EditValue($0) } }
        var body: [String: EditValue] = [:]
        if !create.isEmpty {
            body["create"] = .objects(create.map { new in
                var one: [String: EditValue] = ["key": .text(new.key), "name": .text(new.name)]
                one["groupId"] = new.groupID.map(EditValue.text)
                one["parentId"] = optional(new.parentID)
                one["icon"] = optional(new.icon)
                one["color"] = optional(new.color)
                one["logoFrom"] = new.logoFrom.map(EditValue.text)
                return one
            })
        }
        if !categories.isEmpty {
            body["categories"] = .objects(categories.map { change in
                var one: [String: EditValue] = ["id": .text(change.id)]
                one["name"] = change.name.map(EditValue.text)
                one["groupId"] = change.groupID.map(EditValue.text)
                one["parentId"] = optional(change.parentID)
                one["icon"] = optional(change.icon)
                one["color"] = optional(change.color)
                one["logoFrom"] = change.logoFrom.map(EditValue.text)
                return one
            })
        }
        if !order.isEmpty {
            body["order"] = .objects(order.map {
                ["groupId": .text($0.groupID), "parentId": EditValue($0.parentID), "ids": .texts($0.ids)]
            })
        }
        return body
    }
}

/// Studios with enough titles in the household and no category yet
/// (`GET /v1/categories/suggestions`). Nothing is made by itself.
public struct CategorySuggestions: Decodable, Hashable, Sendable {
    public struct Suggestion: Decodable, Hashable, Sendable, Identifiable {
        public struct Studio: Decodable, Hashable, Sendable, Identifiable {
            public var id: String
            public var name: String
            public var logoPath: String?
            public var titles: Int
        }

        public struct Title: Decodable, Hashable, Sendable, Identifiable {
            public var id: String
            public var title: String
        }

        /// Stays the same while the same studios are in it.
        public var id: String
        public var name: String
        public var studios: [Studio]
        public var count: Int
        /// The first six by title.
        public var titles: [Title]
        /// TMDB's path of a logo, for the preview.
        public var logoPath: String?
        /// A category of the same name, which could take the rule instead.
        public var categoryId: String?

        /// The small version of its logo on this server, like `LogoSearchResult.previewUrl`.
        public var logoPreviewPath: String? {
            logoPath.flatMap { $0.addingPercentEncoding(withAllowedCharacters: .lobbyPathSegment) }
                .map { "/v1/categories/logo-search/preview?path=\($0)" }
        }
    }

    /// The least number of titles a studio needs.
    public var min: Int
    public var suggestions: [Suggestion]
}

/// A studio's logo as the search found it.
public struct LogoSearchResult: Decodable, Hashable, Sendable, Identifiable {
    /// What to send back to choose it.
    public var path: String
    public var name: String
    /// Tells studios of the same name apart.
    public var country: String?
    /// A small version, on this server.
    public var previewUrl: String

    public var id: String { path }
}

/// Where studio suggestions go (`POST /v1/categories/suggestions/accept`). Never nowhere: the
/// manager chooses.
public enum SuggestionPlacement: Hashable, Sendable {
    /// Their studios join the rule of a category there is.
    case join(categoryID: String)
    /// New categories inside a top-level one: one per suggestion, or with `together` one for all.
    case inside(parentID: String, together: Bool, name: String?)
    /// New top-level categories of a group.
    case newCategory(groupID: String, together: Bool, name: String?)

    var body: [String: EditValue] {
        switch self {
        case .join(let id):
            return ["categoryId": .text(id)]
        case .inside(let parent, let together, let name):
            var body: [String: EditValue] = ["parentId": .text(parent), "together": .bool(together)]
            body["name"] = name.map(EditValue.text)
            return body
        case .newCategory(let group, let together, let name):
            var body: [String: EditValue] = ["groupId": .text(group), "together": .bool(together)]
            body["name"] = name.map(EditValue.text)
            return body
        }
    }
}

/// Whose name, icon, colour or logo is changed.
public enum CategoryOwner: Hashable, Sendable {
    case category(String)
    case group(String)

    var segments: [String] {
        switch self {
        case .category(let id): ["categories", id]
        case .group(let id): ["categories", "groups", id]
        }
    }
}

/// Where the titles of a deleted category's folders go.
public enum FoldersTarget: Hashable, Sendable {
    case category(String)
    /// The folders feed no category.
    case none
}

/// Changing the categories. Manager only. Every change names the revision it is based on and
/// answers with the new setup; `EditConflict<CategoriesEdit>` when someone else was first.
extension LobbyClient {
    public func categoriesEdit() async throws -> CategoriesEdit {
        try await get(["categories", "edit"])
    }

    /// Adds a group, last.
    public func createGroup(
        name: String, icon: String?, color: String?, revision: Int, kidsToken: String? = nil
    ) async throws -> CategoriesEdit {
        try await edit("POST", ["categories", "groups"], body: Self.asked([
            "revision": .number(revision), "name": .text(name), "icon": EditValue(icon), "color": EditValue(color),
        ], kidsToken))
    }

    /// Adds a category, last in its group, or with `parentID` last inside that one.
    public func createCategory(
        groupID: String, parentID: String? = nil, name: String, icon: String?, color: String?, revision: Int,
        kidsToken: String? = nil
    ) async throws -> CategoriesEdit {
        var body: [String: EditValue] = [
            "revision": .number(revision), "groupId": .text(groupID), "name": .text(name), "icon": EditValue(icon),
            "color": EditValue(color),
        ]
        if let parentID { body["parentId"] = .text(parentID) }
        return try await edit("POST", ["categories"], body: Self.asked(body, kidsToken))
    }

    /// Changes how something is called and looks.
    ///
    /// - Parameter name: nil leaves it: the main part has no name to change.
    public func updateLook(
        of owner: CategoryOwner, name: String?, icon: String?, color: String?, revision: Int, kidsToken: String? = nil
    ) async throws -> CategoriesEdit {
        var body: [String: EditValue] = ["revision": .number(revision), "icon": EditValue(icon), "color": EditValue(color)]
        if let name { body["name"] = .text(name) }
        return try await edit("PATCH", owner.segments, body: Self.asked(body, kidsToken))
    }

    /// Moves a category to the end of another group.
    public func moveCategory(
        id: String, toGroup groupID: String, revision: Int, kidsToken: String? = nil
    ) async throws -> CategoriesEdit {
        try await edit("PATCH", ["categories", id], body: Self.asked(
            ["revision": .number(revision), "groupId": .text(groupID)], kidsToken))
    }

    /// - Parameter ids: All named groups, each once. The main part stays first.
    public func orderGroups(_ ids: [String], revision: Int, kidsToken: String? = nil) async throws -> CategoriesEdit {
        try await edit("PUT", ["categories", "groups", "order"], body: Self.asked(
            ["revision": .number(revision), "ids": .texts(ids)], kidsToken))
    }

    /// - Parameter ids: All categories of the group, each once.
    public func orderCategories(
        groupID: String, ids: [String], revision: Int, kidsToken: String? = nil
    ) async throws -> CategoriesEdit {
        try await edit("PUT", ["categories", "order"], body: Self.asked([
            "revision": .number(revision), "groupId": .text(groupID), "ids": .texts(ids),
        ], kidsToken))
    }

    /// - Parameter target: The group its categories go to. Required while it holds any.
    public func deleteGroup(
        id: String, movingCategoriesTo target: String?, revision: Int, kidsToken: String? = nil
    ) async throws -> CategoriesEdit {
        try await edit("DELETE", ["categories", "groups", id], query: [Self.revision(revision)]
            + (target.map { [URLQueryItem(name: "moveTo", value: $0)] } ?? []) + Self.asked(kidsToken))
    }

    /// - Parameter target: Where its folders go. Required while folders feed it.
    public func deleteCategory(
        id: String, foldersTo target: FoldersTarget?, revision: Int, kidsToken: String? = nil
    ) async throws -> CategoriesEdit {
        var query = [Self.revision(revision)] + Self.asked(kidsToken)
        switch target {
        case .category(let id)?: query.append(URLQueryItem(name: "foldersTo", value: id))
        case FoldersTarget.none?: query.append(URLQueryItem(name: "foldersTo", value: "none"))
        case nil: break
        }
        return try await edit("DELETE", ["categories", id], query: query)
    }

    /// The category a library folder feeds, or nil for none.
    public func assignFolder(
        id: String, to categoryID: String?, revision: Int, kidsToken: String? = nil
    ) async throws -> CategoriesEdit {
        try await edit("PUT", ["categories", "folders", id], body: Self.asked([
            "revision": .number(revision), "categoryId": EditValue(categoryID),
        ], kidsToken))
    }

    /// Several changes as one; see `CategoryArrangement`. The answer's `undo` takes it back.
    ///
    /// - Parameter dryRun: Changes nothing; the answer is the setup as it would be, with what it
    ///   means for kids viewers and the token to send with it.
    public func arrange(
        _ arrangement: CategoryArrangement, revision: Int, dryRun: Bool = false, kidsToken: String? = nil
    ) async throws -> CategoriesEdit {
        var body = arrangement.body
        body["revision"] = .number(revision)
        if dryRun { body["dryRun"] = .bool(true) }
        return try await edit("POST", ["categories", "arrange"], body: Self.asked(body, kidsToken))
    }

    /// Several categories become `target`: their folders, chosen titles, studios and those
    /// inside them go to it, and they are removed. No title is.
    public func mergeCategories(
        _ ids: [String], into target: String, revision: Int, dryRun: Bool = false, kidsToken: String? = nil
    ) async throws -> CategoriesEdit {
        var body: [String: EditValue] = ["revision": .number(revision), "into": .text(target), "ids": .texts(ids)]
        if dryRun { body["dryRun"] = .bool(true) }
        return try await edit("POST", ["categories", "merge"], body: Self.asked(body, kidsToken))
    }

    /// Several suggestions in one place, as one change.
    public func acceptSuggestions(
        _ ids: [String], placement: SuggestionPlacement, revision: Int, dryRun: Bool = false, kidsToken: String? = nil
    ) async throws -> CategoriesEdit {
        var body = placement.body
        body["revision"] = .number(revision)
        body["ids"] = .texts(ids)
        if dryRun { body["dryRun"] = .bool(true) }
        return try await edit("POST", ["categories", "suggestions", "accept"], body: Self.asked(body, kidsToken))
    }

    /// Takes the last arrangement back. `EditConflict` once anything else changed the categories.
    public func undoArrangement(token: String, revision: Int, kidsToken: String? = nil) async throws -> CategoriesEdit {
        try await edit("POST", ["categories", "arrange", "undo"], body: Self.asked(
            ["revision": .number(revision), "token": .text(token)], kidsToken))
    }

    /// Studios that could be a category: at least `min` titles, and no category follows them yet.
    public func categorySuggestions(min: Int? = nil) async throws -> CategorySuggestions {
        try await get(["categories", "suggestions"], query: min.map { [URLQueryItem(name: "min", value: String($0))] } ?? [])
    }

    /// A new category that follows the suggestion's studios, named as suggested unless `name`
    /// is given, with TMDB's logo when there is one.
    public func acceptSuggestion(
        id: String, groupID: String?, parentID: String? = nil, name: String? = nil, revision: Int, kidsToken: String? = nil
    ) async throws -> CategoriesEdit {
        var body: [String: EditValue] = ["revision": .number(revision)]
        body["groupId"] = groupID.map(EditValue.text)
        body["parentId"] = parentID.map(EditValue.text)
        body["name"] = name.map(EditValue.text)
        return try await edit("POST", ["categories", "suggestions", id, "accept"], body: Self.asked(body, kidsToken))
    }

    /// The suggestion's studios join the rule of a category there is.
    public func acceptSuggestion(
        id: String, existing categoryID: String, revision: Int, kidsToken: String? = nil
    ) async throws -> CategoriesEdit {
        try await edit("POST", ["categories", "suggestions", id, "accept"], body: Self.asked(
            ["revision": .number(revision), "categoryId": .text(categoryID)], kidsToken))
    }

    /// Its studios are not suggested again. Answers what is suggested then.
    public func dismissSuggestion(id: String, min: Int? = nil) async throws -> CategorySuggestions {
        var request = request(
            "POST", ["categories", "suggestions", id, "dismiss"],
            query: min.map { [URLQueryItem(name: "min", value: String($0))] } ?? [])
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await perform(request)
        return try decode(data)
    }

    /// The manager allowed what the change shows a kids viewer: the token of that question.
    static func asked(_ body: [String: EditValue], _ kidsToken: String?) -> [String: EditValue] {
        var body = body
        if let kidsToken { body["kidsToken"] = .text(kidsToken) }
        return body
    }

    static func asked(_ kidsToken: String?) -> [URLQueryItem] {
        kidsToken.map { [URLQueryItem(name: "kidsToken", value: $0)] } ?? []
    }

    /// Searches TMDB for a studio's logos.
    public func searchLogos(_ query: String) async throws -> [LogoSearchResult] {
        struct Answer: Decodable {
            var results: [LogoSearchResult]
        }
        let answer: Answer = try await get(["categories", "logo-search"], query: [URLQueryItem(name: "query", value: query)])
        return answer.results
    }

    public func setLogo(of owner: CategoryOwner, path: String, revision: Int, kidsToken: String? = nil) async throws -> CategoriesEdit {
        try await edit("PUT", owner.segments + ["logo"], body: Self.asked(
            ["revision": .number(revision), "path": .text(path)], kidsToken))
    }

    /// - Parameter picture: A JPEG or PNG. A PNG keeps its transparency.
    public func uploadLogo(
        of owner: CategoryOwner, picture: Data, contentType: String, revision: Int, kidsToken: String? = nil
    ) async throws -> CategoriesEdit {
        try await edit(
            uploading: picture, contentType: contentType, to: owner.segments + ["logo", "upload"],
            query: [Self.revision(revision)] + Self.asked(kidsToken))
    }

    public func removeLogo(of owner: CategoryOwner, revision: Int, kidsToken: String? = nil) async throws -> CategoriesEdit {
        try await edit("DELETE", owner.segments + ["logo"], query: [Self.revision(revision)] + Self.asked(kidsToken))
    }
}
