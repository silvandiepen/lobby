// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// What a manager asks of a device: one title, or the next episodes of a series.
enum WantedRequest: Hashable, Sendable {
    /// A film, a whole series, a season or an episode.
    case item(String)
    /// The next `count` episodes `profileID` has not watched.
    case nextEpisodes(showID: String, profileID: String, count: Int)

    /// What the server accepts for a rule.
    static let countLimits = 1...50
    static let defaultCount = 10

    /// Whether `entry` is this request, whatever its count: the same rule with another count
    /// replaces it.
    func matches(_ entry: WantedEntry) -> Bool {
        switch self {
        case .item(let id): entry.kind == .item && entry.itemId == id
        case .nextEpisodes(let showID, let profileID, _):
            entry.kind == .nextUnwatched && entry.itemId == showID && entry.profileId == profileID
        }
    }
}

/// How a device is doing with its list, in words. Never colour alone.
struct DeviceProgress: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case nothing, complete, underway, problem
    }

    var kind: Kind
    var text: String

    init(_ summary: DeviceWantedSummary) {
        if summary.entries == 0 {
            kind = .nothing
            text = "Nothing sent to it"
        } else if summary.failed > 0 {
            kind = .problem
            text = "\(summary.downloaded) of \(summary.files) on it, \(summary.failed) cannot be done"
        } else if summary.downloaded >= summary.files {
            kind = .complete
            text = summary.files == 0 ? "Nothing to fetch now" : "All \(summary.files) on it"
        } else {
            kind = .underway
            text = "\(summary.downloaded) of \(summary.files) on it, \(MediaFormat.size(bytes: summary.bytesToFetch)) to go"
        }
    }

    /// "41 GB free of 128 GB", or nil when the device did not say.
    static func space(_ storage: DeviceWantedSummary.Storage?) -> String? {
        guard let free = storage?.freeBytes else { return nil }
        guard let total = storage?.totalBytes else { return "\(MediaFormat.size(bytes: free)) free" }
        return "\(MediaFormat.size(bytes: free)) free of \(MediaFormat.size(bytes: total))"
    }

    /// "Seen just now", "Seen 2 hours ago", "Not seen yet".
    static func seen(_ date: Date?, now: Date) -> String {
        guard let date else { return "Not seen yet" }
        // The server keeps it to the minute, and a device with Lobby open looks every minute.
        if now.timeIntervalSince(date) < 150 { return "Seen just now" }
        return "Seen \(date.formatted(.relative(presentation: .numeric, unitsStyle: .wide).locale(Locale(identifier: "en"))))"
    }
}

/// One file of a device's list, ready to draw: where it is, and why when it is not there.
struct WantedFileRow: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        case onDevice, moving, waiting, problem
    }

    var id: String
    var title: String
    var kind: Kind
    /// "Downloading", "Waits for its turn on Lobby Server" …
    var state: String
    /// The reason, as a sentence, when the state alone does not say it.
    var reason: String?
    /// 0…1 while something moves.
    var fraction: Double?
    var bytes: Int64

    init(asset: DeviceWantedDetail.Asset, catalogue: Catalogue) {
        id = asset.assetId
        title = Self.title(of: asset.itemId, in: catalogue)
        bytes = asset.bytes
        reason = nil
        fraction = nil

        if asset.isOnDevice {
            kind = .onDevice
            state = "On the device"
            return
        }
        // What the device says goes first: it is nearest to the truth. An older revision on
        // it says nothing about the file wanted now.
        if let device = asset.device, device.revision == asset.revision {
            let moved = (device.bytesTotal ?? asset.bytes) > 0
                ? min(1, Double(device.bytesDone) / Double(device.bytesTotal ?? asset.bytes)) : nil
            switch device.state {
            case .downloading:
                kind = .moving
                state = "Downloading"
                fraction = moved
                return
            case .paused:
                kind = .waiting
                state = "Paused on the device"
                fraction = moved
                return
            case .failed:
                kind = .problem
                state = "Not downloaded"
                reason = Self.sentence(for: device.error ?? .other)
                return
            case .waiting, .downloaded:
                break
            }
        }
        switch asset.state {
        case .ready:
            kind = .waiting
            state = "Ready on Lobby Server"
            reason = asset.device?.state == .waiting
                ? "The device fetches it after what comes before it, on Wi-Fi."
                : "The device fetches it the next time Lobby is open on it."
        case .waiting:
            kind = .waiting
            state = "Waits for its turn on Lobby Server"
            reason = asset.message
        case .preparing:
            kind = .moving
            state = "Lobby Server is preparing it"
            fraction = asset.prepareProgress
            reason = asset.message
        case .doesNotFit, .unsupported, .failed, .unavailable:
            kind = .problem
            state = "Not possible now"
            reason = asset.message
        case .unknown:
            kind = .waiting
            state = "Waiting"
            reason = asset.message
        }
    }

    var percent: String? { fraction.map { "\(Int(($0 * 100).rounded())) %" } }

    var accessibilityLabel: String {
        [title, state, percent, reason].compactMap { $0 }.joined(separator: ", ")
    }

    static func sentence(for failure: DownloadsReport.Entry.Failure) -> String {
        switch failure {
        case .noSpace: "There is not enough room on the device."
        case .network: "The connection broke off. The device tries again."
        case .notFound: "The device could not find the file on Lobby Server."
        case .unsupported: "The device cannot play this file."
        case .verificationFailed: "What arrived was not the whole file. The device tries again."
        case .cancelled: "It was stopped on the device."
        case .other: "Something went wrong on the device."
        }
    }

    /// "S1 E2 · Pilot" for an episode, the title otherwise.
    static func title(of itemID: String, in catalogue: Catalogue) -> String {
        guard let item = catalogue.item(itemID) else { return "No longer in the library" }
        guard item.kind == .episode else { return item.title }
        let code = MediaFormat.episodeCode(season: item.seasonNumber, episode: item.episodeNumber)
        return [code, item.title].compactMap { $0 }.joined(separator: " · ")
    }
}

/// One thing a manager put on a device, ready to draw, with the files it stands for.
struct WantedRow: Hashable, Sendable, Identifiable {
    var entry: WantedEntry
    /// The film, or the series for anything that is part of one.
    var title: String
    /// "Film", "Season 2", "Next 10 episodes Alex has not watched".
    var what: String
    /// "7 of 10 on the device".
    var summary: String
    var files: [WantedFileRow]
    var artwork: Artwork?

    var id: String { entry.id }
    var isComplete: Bool { !files.isEmpty && files.allSatisfy { $0.kind == .onDevice } }
    var problems: Int { files.filter { $0.kind == .problem }.count }

    /// 0…1 over the files, counting what is moving for as far as it is.
    var fraction: Double {
        guard !files.isEmpty else { return 0 }
        return files.reduce(0) { $0 + ($1.kind == .onDevice ? 1 : $1.kind == .moving ? ($1.fraction ?? 0) : 0) } / Double(files.count)
    }

    static func rows(of detail: DeviceWantedDetail, catalogue: Catalogue, profiles: [Profile]) -> [WantedRow] {
        detail.wanted.map { entry in
            let item = catalogue.item(entry.itemId)
            let show = item.flatMap { catalogue.show(of: $0) }
            let files = detail.assets
                .filter { asset in asset.why.contains { $0.wantedId == entry.id } }
                .map { WantedFileRow(asset: $0, catalogue: catalogue) }
            let done = files.filter { $0.kind == .onDevice }.count
            return WantedRow(
                entry: entry,
                title: show?.title ?? item?.title ?? "No longer in the library",
                what: what(entry, item: item, profiles: profiles),
                summary: files.isEmpty
                    ? (entry.kind == .nextUnwatched ? "Nothing left to watch" : "Nothing to fetch")
                    : "\(done) of \(files.count) on the device",
                files: files,
                artwork: item?.artwork.poster ?? show?.artwork.poster)
        }
    }

    static func what(_ entry: WantedEntry, item: Item?, profiles: [Profile]) -> String {
        if entry.kind == .nextUnwatched {
            let viewer = profiles.first { $0.id == entry.profileId }?.name ?? "A removed viewer"
            return "\(nextEpisodes(entry.count ?? 1)) \(viewer) has not watched"
        }
        switch entry.itemKind {
        case .movie: return "Film"
        case .show: return "The whole series"
        case .season: return item.map { MediaFormat.seasonName($0.seasonNumber, fallback: $0.title) } ?? "Season"
        case .episode: return item.map { WantedFileRow.title(of: $0.id, in: Catalogue(items: [$0])) } ?? "Episode"
        default: return "Video"
        }
    }

    static func nextEpisodes(_ count: Int) -> String {
        count == 1 ? "The next episode" : "The next \(count) episodes"
    }
}
