// SPDX-License-Identifier: MPL-2.0
import Foundation

/// `GET /v1/server`: what the Connect screen shows before pairing.
public struct ServerInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    public var apiVersion: Int
    /// The oldest app version this server works with. nil from a server that does not say: it
    /// works with every app.
    public var minAppVersion: String?
    /// False until the first manager has claimed the server.
    public var claimed: Bool
    /// How a server nobody has claimed yet is claimed. Means nothing once `claimed` is true.
    public var claim: ClaimMode
    /// Where the server can be reached, at home and from elsewhere. Only in `GET /v1/me`, for
    /// a paired device; nil from a server that does not say.
    public var addresses: ServerAddresses?
    /// Whether the first setup is still to do. Only in `GET /v1/me`, for a manager at home.
    public var setup: ServerSetup?

    public init(
        id: String, name: String, version: String, apiVersion: Int, minAppVersion: String? = nil, claimed: Bool,
        claim: ClaimMode = .secret, addresses: ServerAddresses? = nil, setup: ServerSetup? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.apiVersion = apiVersion
        self.minAppVersion = minAppVersion
        self.claimed = claimed
        self.claim = claim
        self.addresses = addresses
        self.setup = setup
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        apiVersion = try container.decode(Int.self, forKey: .apiVersion)
        minAppVersion = try container.decodeIfPresent(String.self, forKey: .minAppVersion)
        claimed = try container.decode(Bool.self, forKey: .claimed)
        // A server that does not say, or says something this version does not know, is
        // treated as the careful kind: it is asked for its setup secret.
        claim = (try container.decodeIfPresent(String.self, forKey: .claim)).flatMap(ClaimMode.init(rawValue:)) ?? .secret
        addresses = try container.decodeIfPresent(ServerAddresses.self, forKey: .addresses)
        setup = try container.decodeIfPresent(ServerSetup.self, forKey: .setup)
    }
}

/// `ServerInfo.claim`.
public enum ClaimMode: String, Codable, Hashable, Sendable {
    /// The first device that asks becomes the manager, without a secret.
    case open
    /// The first manager needs the setup secret the server printed when it first started.
    case secret
}

/// `GET /v1/me`.
public struct Me: Codable, Hashable, Sendable {
    public var device: Device
    public var server: ServerInfo
    /// Whose household the device is in. nil from a server from before households: the owner's.
    public var household: HouseholdSummary?

    public init(device: Device, server: ServerInfo, household: HouseholdSummary? = nil) {
        self.device = device
        self.server = server
        self.household = household
    }
}

/// `GET /v1/status` (manager).
public struct ServerStatus: Codable, Hashable, Sendable {
    public struct Source: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var hint: SourceHint?
        public var available: Bool
        public var lastScanStartedAt: Date?
        public var lastScanFinishedAt: Date?
        public var files: Int
    }

    public struct Files: Codable, Hashable, Sendable {
        public var total: Int
        public var waiting: Int
        public var failed: Int
        public var missing: Int
    }

    public struct PlayabilityCounts: Codable, Hashable, Sendable {
        public var direct: Int
        public var remux: Int
        public var transcode: Int
        public var unsupported: Int
    }

    public struct Items: Codable, Hashable, Sendable {
        public var movies: Int
        public var shows: Int
        public var episodes: Int
        public var extras: Int
        public var personal: Int
        public var needsReview: Int
        public var unmatched: Int
    }

    public var scanning: Bool
    public var sources: [Source]
    public var files: Files
    public var playability: PlayabilityCounts
    public var items: Items
}

public enum SourceHint: OpenStringEnum {
    case movies, series, personal, mixed
    case unknown(String)

    public static let knownCases: [SourceHint] = [.movies, .series, .personal, .mixed]

    public var rawValue: String {
        switch self {
        case .movies: "movies"
        case .series: "series"
        case .personal: "personal"
        case .mixed: "mixed"
        case .unknown(let raw): raw
        }
    }
}
