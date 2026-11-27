// SPDX-License-Identifier: MPL-2.0
import Foundation

// A manager's settings of the server, its first setup and its TMDB key (`/v1/settings…`,
// `/v1/setup…`), as `docs/api.md` describes them under "Server settings". At home or in the
// tailnet only.

extension LobbyClient {
    /// `GET /v1/settings`. Manager.
    public func serverSettings() async throws -> ServerSettings {
        var request = request("GET", ["settings"])
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return try decode(try await perform(request).0)
    }

    /// `PATCH /v1/settings`. Manager. With `dryRun` nothing changes: the answer says what would.
    ///
    /// - Parameter baseVersion: The version that was shown. A change made meanwhile is a `.conflict`.
    public func changeSettings(
        _ changes: [String: SettingValue], baseVersion: Int?, dryRun: Bool
    ) async throws -> SettingsChange {
        struct Body: Encodable {
            var changes: [String: SettingValue]
            var baseVersion: Int?
            var dryRun: Bool

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(changes, forKey: .changes)
                try container.encode(baseVersion, forKey: .baseVersion)
                try container.encode(dryRun, forKey: .dryRun)
            }

            enum CodingKeys: String, CodingKey { case changes, baseVersion, dryRun }
        }
        return try await send("PATCH", ["settings"], body: Body(changes: changes, baseVersion: baseVersion, dryRun: dryRun))
    }

    /// `GET /v1/settings/history`. Manager. Newest first.
    public func settingsHistory() async throws -> [SettingsVersion] {
        struct Answer: Decodable { var versions: [SettingsVersion] }
        let answer: Answer = try await get(["settings", "history"])
        return answer.versions
    }

    /// `POST /v1/settings/history/{version}/restore`. Manager.
    public func restoreSettings(version: Int, dryRun: Bool) async throws -> SettingsChange {
        struct Body: Encodable { var dryRun: Bool }
        return try await send("POST", ["settings", "history", String(version), "restore"], body: Body(dryRun: dryRun))
    }

    /// `GET /v1/settings/audit`. Manager. Newest first.
    public func settingsAudit(limit: Int = 50) async throws -> [SettingsAuditEntry] {
        struct Answer: Decodable { var entries: [SettingsAuditEntry] }
        let answer: Answer = try await get(["settings", "audit"], query: [URLQueryItem(name: "limit", value: String(limit))])
        return answer.entries
    }

    /// `GET /v1/settings/browse`. Manager. nil: the places to start from.
    public func browseFolders(at path: String?) async throws -> FolderListing {
        try await get(["settings", "browse"], query: path.map { [URLQueryItem(name: "path", value: $0)] } ?? [])
    }

    /// `PUT /v1/settings/tmdb`. Manager. The server checks the key with TMDB before it keeps it.
    public func setTMDBKey(_ key: String) async throws -> SecretStatus {
        struct Body: Encodable { var key: String }
        struct Answer: Decodable { var tmdbKey: SecretStatus }
        let answer: Answer = try await send("PUT", ["settings", "tmdb"], body: Body(key: key))
        return answer.tmdbKey
    }

    /// `DELETE /v1/settings/tmdb`. Manager.
    public func removeTMDBKey() async throws -> SecretStatus {
        struct Answer: Decodable { var tmdbKey: SecretStatus }
        let answer: Answer = try await send("DELETE", ["settings", "tmdb"])
        return answer.tmdbKey
    }

    /// `GET /v1/setup`. Manager.
    public func serverSetup() async throws -> ServerSetup {
        try await get(["setup"])
    }

    /// `POST /v1/setup/steps/{step}`: the name kept as it is, or no TMDB key for now.
    public func markSetupStep(_ step: String, skipped: Bool) async throws -> ServerSetup {
        struct Body: Encodable { var state: String }
        return try await send("POST", ["setup", "steps", step], body: Body(state: skipped ? "skipped" : "done"))
    }

    /// `POST /v1/setup/finish`: the server starts looking through its folders.
    public func finishSetup() async throws -> ServerSetup {
        try await send("POST", ["setup", "finish"])
    }
}

/// A value of a setting, as JSON has it.
public enum SettingValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([SettingValue])
    case object([String: SettingValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([SettingValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: SettingValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let bool): try container.encode(bool)
        case .number(let number):
            // A whole number goes as one: the server tells 30 from 30.5.
            if number.rounded() == number, abs(number) < 1e15 {
                try container.encode(Int64(number))
            } else {
                try container.encode(number)
            }
        case .string(let string): try container.encode(string)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }

    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var number: Double? { if case .number(let value) = self { value } else { nil } }
    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var array: [SettingValue]? { if case .array(let value) = self { value } else { nil } }
    public var isNull: Bool { self == .null }
}

/// `GET /v1/settings`.
public struct ServerSettings: Decodable, Hashable, Sendable {
    public struct Section: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
    }

    public struct Secrets: Codable, Hashable, Sendable {
        public var tmdbKey: SecretStatus
    }

    /// What only the server's own file sets, shown and not changed.
    public struct Fixed: Codable, Hashable, Sendable {
        public struct Outside: Codable, Hashable, Sendable {
            public var name: String
            public var relay: Bool
            public var direct: Bool
        }

        public var configFile: String
        public var dataDir: String
        public var host: String
        public var port: Int
        public var claim: String
        public var outside: Outside?
    }

    public var version: Int
    public var updatedAt: Date
    public var updatedBy: SettingsAuthor?
    /// Another one after every start: after a restart, wait until it changed.
    public var bootId: String
    public var restarting: Bool
    public var sections: [Section]
    public var settings: [SettingDescriptor]
    public var secrets: Secrets
    public var fixed: Fixed
    public var setup: ServerSetup

    public func setting(_ key: String) -> SettingDescriptor? {
        settings.first { $0.key == key }
    }
}

/// One setting, with what the app needs to show and check it.
public struct SettingDescriptor: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var section: String
    public var title: String
    public var help: String
    /// `text`, `toggle`, `integer`, `number`, `hours`, `folder`, `folders`, `addresses`, `language`.
    public var type: String
    /// `live` or `restart`.
    public var apply: String
    public var `default`: SettingValue
    public var nullable: Bool
    public var min: Double?
    public var max: Double?
    public var value: SettingValue
    public var available: Bool
    public var unavailableReason: String?

    public var id: String { key }
    public var restarts: Bool { apply == "restart" }
}

public struct SecretStatus: Codable, Hashable, Sendable {
    public var set: Bool
    /// `settings`, `environment` (the app cannot change it), or nil.
    public var source: String?

    public init(set: Bool, source: String?) {
        self.set = set
        self.source = source
    }
}

public struct SettingsAuthor: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
}

/// The answer to a change, a dry run or a restore.
public struct SettingsChange: Codable, Hashable, Sendable {
    public var dryRun: Bool
    public var version: Int
    public var changed: [String]
    public var effects: [SettingEffect]
    public var restart: Bool
    public var restarting: Bool
    public var rescanFolders: Int
    public var bootId: String
}

public struct SettingEffect: Codable, Hashable, Sendable {
    public var key: String
    public var title: String
    public var apply: String
    public var message: String
}

public struct SettingsVersion: Codable, Hashable, Sendable, Identifiable {
    public var version: Int
    public var at: Date
    public var by: SettingsAuthor?
    public var reason: String
    public var changed: [String]
    public var current: Bool

    public var id: Int { version }
}

public struct SettingsAuditEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var at: Date
    public var by: SettingsAuthor?
    /// `change`, `restore`, `refused`, `tmdb_set`, `tmdb_removed`, `setup`.
    public var action: String
    public var version: Int?
    public var keys: [String]
    public var note: String?
}

/// `GET /v1/settings/browse`.
public struct FolderListing: Codable, Hashable, Sendable {
    /// nil for the places to start from.
    public var path: String?
    public var parent: String?
    public var folders: [FolderEntry]
    public var videoFiles: Int
    public var truncated: Bool
}

public struct FolderEntry: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var path: String
    public var videoFiles: Int
    public var audioFiles: Int
    /// The count stopped at its limit.
    public var more: Bool

    public var id: String { path }

    public init(name: String, path: String, videoFiles: Int, audioFiles: Int, more: Bool) {
        self.name = name
        self.path = path
        self.videoFiles = videoFiles
        self.audioFiles = audioFiles
        self.more = more
    }
}

/// Whether the first setup is still to do, and how far it is.
public struct ServerSetup: Codable, Hashable, Sendable {
    public struct Step: Codable, Hashable, Sendable, Identifiable {
        /// `name`, `folders`, `tmdb`, `scan`.
        public var id: String
        public var done: Bool
        public var skipped: Bool

        public init(id: String, done: Bool, skipped: Bool) {
            self.id = id
            self.done = done
            self.skipped = skipped
        }
    }

    public var needed: Bool
    public var steps: [Step]

    public init(needed: Bool, steps: [Step]) {
        self.needed = needed
        self.steps = steps
    }

    public func isDone(_ step: String) -> Bool {
        steps.first { $0.id == step }?.done ?? false
    }
}

/// One library folder of the setting `roots`.
public struct LibraryFolder: Hashable, Sendable, Identifiable {
    /// `movies`, `series`, `personal`, `mixed`, `music`, `audiobooks`.
    public var hint: String
    public var path: String
    public var name: String?
    public var group: String?
    /// A studio logo's TMDB path; kept as the server has it.
    public var logo: String?

    public var id: String { path }

    public init(path: String, hint: String, name: String? = nil, group: String? = nil, logo: String? = nil) {
        self.path = path
        self.hint = hint
        self.name = name
        self.group = group
        self.logo = logo
    }

    /// The part of the library for children, as the categories name it.
    public static let kidsGroup = "Kids"

    public var isForKids: Bool { group?.caseInsensitiveCompare(Self.kidsGroup) == .orderedSame }

    /// The name shown: the one given, or the folder's own.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return (path as NSString).lastPathComponent
    }

    public init?(_ value: SettingValue) {
        guard case .object(let fields) = value, let path = fields["path"]?.string, let hint = fields["hint"]?.string else {
            return nil
        }
        self.init(
            path: path, hint: hint, name: fields["name"]?.string, group: fields["group"]?.string, logo: fields["logo"]?.string)
    }

    public var value: SettingValue {
        var fields: [String: SettingValue] = ["path": .string(path), "hint": .string(hint)]
        if let name, !name.isEmpty { fields["name"] = .string(name) }
        if let group, !group.isEmpty { fields["group"] = .string(group) }
        if let logo { fields["logo"] = .string(logo) }
        return .object(fields)
    }

    public static func list(_ value: SettingValue) -> [LibraryFolder] {
        value.array?.compactMap(LibraryFolder.init) ?? []
    }
}
