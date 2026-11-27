// SPDX-License-Identifier: MPL-2.0
import Foundation

/// One file a manager wants on this device (`GET /v1/me/wanted`).
public struct WantedAsset: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Hashable, Sendable {
        case ready, waiting, preparing, unsupported, failed, unavailable
        case doesNotFit = "does_not_fit"
        /// A state this version does not know: treated as "wait".
        case unknown

        public init(from decoder: any Decoder) throws {
            self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var assetId: String
    public var itemId: String
    /// The file's revision. A new one means: fetch again.
    public var revision: String
    /// 1 is fetched first.
    public var order: Int
    /// Exact once `state` is `.ready`; an estimate before.
    public var bytes: Int64
    public var bytesExact: Bool
    public var state: State
    /// A path on the server to fetch, once `state` is `.ready`.
    public var downloadUrl: String?
    /// A sentence when the file cannot be fetched now.
    public var message: String?

    public var id: String { assetId }

    public init(
        assetId: String, itemId: String, revision: String, order: Int, bytes: Int64, bytesExact: Bool, state: State,
        downloadUrl: String?, message: String? = nil
    ) {
        self.assetId = assetId
        self.itemId = itemId
        self.revision = revision
        self.order = order
        self.bytes = bytes
        self.bytesExact = bytesExact
        self.state = state
        self.downloadUrl = downloadUrl
        self.message = message
    }
}

/// A device's own list of what a manager wants on it.
public struct DeviceWantedList: Codable, Hashable, Sendable {
    /// Changes when anything below does.
    public var revision: String
    public var assets: [WantedAsset]
    /// Files beyond what a device is told about.
    public var leftOut: Int

    public init(revision: String, assets: [WantedAsset], leftOut: Int = 0) {
        self.revision = revision
        self.assets = assets
        self.leftOut = leftOut
    }
}

/// What a device says it has (`POST /v1/me/downloads`). The whole truth each time.
public struct DownloadsReport: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public enum State: String, Codable, Hashable, Sendable {
            case waiting, downloading, paused, downloaded, failed
        }

        public enum Failure: String, Codable, Hashable, Sendable {
            case network, unsupported, cancelled, other
            case noSpace = "no_space"
            case notFound = "not_found"
            case verificationFailed = "verification_failed"
        }

        public var assetId: String
        public var revision: String
        public var state: State
        public var bytesDone: Int64
        public var bytesTotal: Int64?
        public var error: Failure?
        /// The person on the device downloaded this themselves.
        public var own: Bool
    }

    public var freeBytes: Int64?
    public var totalBytes: Int64?
    public var downloads: [Entry]

    public init(freeBytes: Int64?, totalBytes: Int64?, downloads: [Entry]) {
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
        self.downloads = downloads
    }
}

// MARK: The manager's side

/// One thing a manager wants on a device: a title, or the next episodes of a series.
public struct WantedEntry: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case item
        case nextUnwatched = "next_unwatched"
    }

    public var id: String
    public var kind: Kind
    /// The film, episode, season or show. For a rule: the show.
    public var itemId: String
    public var itemKind: ItemKind
    /// For a rule: whose watching decides what "next" is.
    public var profileId: String?
    /// For a rule: how many episodes ahead.
    public var count: Int?
    public var addedAt: Date
}

/// One line per paired device (`GET /v1/devices/wanted`).
public struct DeviceWantedSummary: Codable, Hashable, Sendable, Identifiable {
    public struct Storage: Codable, Hashable, Sendable {
        public var freeBytes: Int64?
        public var totalBytes: Int64?
        public var reportedAt: Date
    }

    public var id: String
    public var name: String
    public var platform: DevicePlatform
    public var role: DeviceRole
    /// When the device last talked to the server.
    public var lastSeenAt: Date?
    /// Wanted entries, the files they stand for, and how many of those are on the device.
    public var entries: Int
    public var files: Int
    public var downloaded: Int
    public var failed: Int
    public var bytesToFetch: Int64
    public var ownDownloads: Int
    public var storage: Storage?
}

/// Everything about one device's list (`GET /v1/devices/{id}/wanted`).
public struct DeviceWantedDetail: Codable, Hashable, Sendable {
    public struct Device: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var platform: DevicePlatform
        public var role: DeviceRole
        public var lastSeenAt: Date?
    }

    /// A file the device holds that is on no list: what the person downloaded themselves
    /// (`own`), or a leftover it has not removed yet.
    public struct Other: Codable, Hashable, Sendable, Identifiable {
        public var assetId: String
        public var state: DownloadsReport.Entry.State
        public var bytesDone: Int64
        public var bytesTotal: Int64?
        public var error: DownloadsReport.Entry.Failure?
        public var own: Bool
        /// nil when the title left the library.
        public var itemId: String?

        public var id: String { assetId }
    }

    public struct Asset: Codable, Hashable, Sendable, Identifiable {
        /// An entry of the list that asks for this file.
        public struct Why: Codable, Hashable, Sendable {
            public var wantedId: String
        }

        public struct Reported: Codable, Hashable, Sendable {
            public var revision: String
            public var state: DownloadsReport.Entry.State
            public var bytesDone: Int64
            public var bytesTotal: Int64?
            public var error: DownloadsReport.Entry.Failure?
        }

        public var assetId: String
        public var itemId: String
        public var revision: String
        public var bytes: Int64
        public var state: WantedAsset.State
        public var message: String?
        /// 0…1: how far the server is with the copy.
        public var prepareProgress: Double
        /// What the device last said about this file.
        public var device: Reported?
        public var why: [Why]

        public var id: String { assetId }

        /// The file is on the device, in the revision the server has now.
        public var isOnDevice: Bool { device?.state == .downloaded && device?.revision == revision }
    }

    public var device: Device
    public var wanted: [WantedEntry]
    /// In the order the device fetches them.
    public var assets: [Asset]
    public var leftOut: Int
    public var storage: DeviceWantedSummary.Storage?
    public var bytesToFetch: Int64
    /// Whether that fits in the free space the device reported. nil when it reported none.
    public var fits: Bool?
    public var other: [Other]
}
