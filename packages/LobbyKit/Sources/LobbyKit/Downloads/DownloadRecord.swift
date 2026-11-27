// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Where one download is. The Downloads screen tells every case apart, in words.
public enum DownloadState: Codable, Hashable, Sendable {
    /// Waiting for its turn, or for the server to be reachable.
    case queued
    /// The server is still writing the copy this device will fetch (an MKV, the first time).
    /// 0…1.
    case preparing(progress: Double)
    case downloading
    /// Stopped by the viewer. What arrived so far is kept.
    case paused
    case failed(DownloadFailure)
    /// On this device, complete, and checked against the length the server stated.
    case verified

    /// Something is on its way or waiting to be: not finished, not failed, not paused.
    public var isActive: Bool {
        switch self {
        case .queued, .preparing, .downloading: true
        case .paused, .failed, .verified: false
        }
    }
}

public enum DownloadFailure: Codable, Hashable, Sendable {
    /// The device has less room than the file needs.
    case notEnoughSpace(neededBytes: Int64, availableBytes: Int64)
    /// What arrived is not as long as the server said it would be.
    case sizeMismatch(expectedBytes: Int64, receivedBytes: Int64)
    /// The file changed on the server while it was being fetched, twice in a row.
    case changedOnServer
    /// The film or episode is no longer on the server.
    case removedFromServer
    /// The transfer broke off and one retry did not help. What arrived is kept for Try Again.
    case interrupted(String)
    /// The server said why it cannot hand this file over. Its sentence is for the viewer.
    case server(String)
}

/// Why a copy on this device is not the same as what the server has now.
public enum DownloadStaleness: String, Codable, Hashable, Sendable {
    /// The file on the server was replaced after this copy was made.
    case changedOnServer
    /// The film or episode is gone from the server's library.
    case removedFromServer
}

/// A subtitle stored beside a downloaded film, as WebVTT.
public struct LocalSubtitle: Codable, Hashable, Sendable, Identifiable {
    /// `SubtitleTrack.id`.
    public var id: String
    public var language: String?
    public var title: String?
    public var isForced: Bool
    /// The file's name inside the item's folder.
    public var fileName: String

    public init(id: String, language: String?, title: String?, isForced: Bool, fileName: String) {
        self.id = id
        self.language = language
        self.title = title
        self.isForced = isForced
        self.fileName = fileName
    }
}

/// A finished, verified copy on this device.
public struct LocalCopy: Codable, Hashable, Sendable {
    /// The revision of the server's file this copy was made from.
    public var revision: String
    /// The file's name inside the item's folder. Always `.mp4`.
    public var fileName: String
    public var sizeBytes: Int64
    public var completedAt: Date
    public var subtitles: [LocalSubtitle]

    public init(revision: String, fileName: String, sizeBytes: Int64, completedAt: Date, subtitles: [LocalSubtitle]) {
        self.revision = revision
        self.fileName = fileName
        self.sizeBytes = sizeBytes
        self.completedAt = completedAt
        self.subtitles = subtitles
    }
}

/// A transfer in progress, or one that stopped part-way.
public struct DownloadTransfer: Codable, Hashable, Sendable {
    /// The revision being fetched. Another revision on the server invalidates what arrived.
    public var revision: String
    /// The exact length the server stated (`Playback.downloadBytes`).
    public var expectedBytes: Int64
    public var receivedBytes: Int64
    /// Set when the transfer continued from bytes that had already arrived.
    public var resumedAtByte: Int64?
    /// The address the bytes come from. What the system keeps to continue a transfer names
    /// that address, so it is of no use once the server is reached at another one. nil in
    /// records written before addresses could change.
    public var server: URL?

    public init(revision: String, expectedBytes: Int64, receivedBytes: Int64, resumedAtByte: Int64?, server: URL? = nil) {
        self.revision = revision
        self.expectedBytes = expectedBytes
        self.receivedBytes = receivedBytes
        self.resumedAtByte = resumedAtByte
        self.server = server
    }

    /// 0…1.
    public var fraction: Double {
        expectedBytes > 0 ? min(1, Double(receivedBytes) / Double(expectedBytes)) : 0
    }
}

/// One film or episode the viewer asked to keep on this device.
public struct DownloadRecord: Codable, Hashable, Sendable, Identifiable {
    public var itemID: String
    /// The file that is fetched (`MediaFile.assetId`).
    public var assetID: String
    /// The item as the catalogue described it, so the Downloads screen can name it when the
    /// catalogue no longer has it.
    public var item: Item
    /// The episode's show and season, for grouping.
    public var showID: String?
    public var showTitle: String?
    public var state: DownloadState
    public var transfer: DownloadTransfer?
    /// The copy that can be played. During a replacement this is still the older one.
    public var local: LocalCopy?
    /// Set when `local` no longer matches the server. Never shown as verified then.
    public var staleness: DownloadStaleness?
    public var requestedAt: Date
    /// Whether the transfer may use mobile data.
    public var allowsCellular: Bool
    /// The one automatic retry was used.
    public var retried: Bool
    /// The system is holding the transfer until there is a network it may use.
    public var isWaitingForNetwork: Bool
    /// false: nobody on this device asked for it; it is here because a manager wants it here.
    /// nil in records written before managers could: those are the person's own.
    public var own: Bool?
    /// Set while a manager wants this file on this device.
    public var wanted: WantedFile?

    public init(
        itemID: String, assetID: String, item: Item, showID: String?, showTitle: String?, state: DownloadState,
        transfer: DownloadTransfer?, local: LocalCopy?, staleness: DownloadStaleness?, requestedAt: Date,
        allowsCellular: Bool, retried: Bool, isWaitingForNetwork: Bool
    ) {
        self.itemID = itemID
        self.assetID = assetID
        self.item = item
        self.showID = showID
        self.showTitle = showTitle
        self.state = state
        self.transfer = transfer
        self.local = local
        self.staleness = staleness
        self.requestedAt = requestedAt
        self.allowsCellular = allowsCellular
        self.retried = retried
        self.isWaitingForNetwork = isWaitingForNetwork
    }

    public var id: String { itemID }

    /// The person on this device asked for it themselves.
    public var isOwn: Bool { own ?? true }

    /// There is a copy on this device that can be played, current or not.
    public var isPlayable: Bool { local != nil }

    /// A complete copy of what the server has now.
    public var isVerifiedAndCurrent: Bool { state == .verified && local != nil && staleness == nil }

    /// What this record takes on the device: the finished copy plus what arrived of a transfer.
    public var bytesOnDevice: Int64 {
        (local?.sizeBytes ?? 0) + (state == .verified ? 0 : (transfer?.receivedBytes ?? 0))
    }
}

extension DownloadRecord {
    /// Compares the copy on this device with the catalogue as last fetched from the server.
    ///
    /// - Parameter catalogue: A catalogue that was synced successfully. Never a cached one from
    ///   before the copy was made: absence there would not mean removal.
    func staleness(in catalogue: Catalogue) -> DownloadStaleness? {
        guard let local else { return nil }
        guard let current = catalogue.item(itemID) else { return .removedFromServer }
        guard let file = current.files.first(where: { $0.assetId == assetID }) else { return .changedOnServer }
        return file.revision == local.revision ? nil : .changedOnServer
    }
}

/// What the server said about a file a manager wants on this device.
public struct WantedFile: Codable, Hashable, Sendable {
    public var revision: String
    public var bytes: Int64
    public var state: WantedAsset.State
    /// The path to fetch, once the server has the file ready.
    public var downloadPath: String?
    /// The server's sentence when the file cannot be fetched now.
    public var message: String?
    /// Its place in the order the manager's list is fetched in.
    public var order: Int
}
