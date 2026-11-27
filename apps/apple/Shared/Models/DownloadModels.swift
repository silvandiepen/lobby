// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// What the viewer can do with a download, by its state.
enum DownloadAction: Hashable, Sendable {
    case download
    case pause
    case resume
    /// Fetch the current file to replace a copy that is out of date.
    case update
    case remove
}

/// One download as the screens show it: a state in words, a symbol, and what can be done.
/// Never colour alone.
struct DownloadStatus: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case notDownloaded
        case queued
        case waitingForNetwork
        case preparing
        case downloading
        case paused
        case failed
        case downloaded
        case outOfDate
    }

    var kind: Kind
    /// "Downloading", "Downloaded", "Paused" …
    var label: String
    /// A sentence when the label is not enough: why it failed, why it waits.
    var detail: String?
    var symbol: String
    /// 0…1 while something is arriving or being prepared.
    var fraction: Double?
    /// The first one is what a single button does.
    var actions: [DownloadAction]

    static let notDownloaded = DownloadStatus(
        kind: .notDownloaded, label: "Download", detail: nil, symbol: "arrow.down.circle", fraction: nil,
        actions: [.download])

    init(kind: Kind, label: String, detail: String?, symbol: String, fraction: Double?, actions: [DownloadAction]) {
        self.kind = kind
        self.label = label
        self.detail = detail
        self.symbol = symbol
        self.fraction = fraction
        self.actions = actions
    }

    init(record: DownloadRecord?) {
        guard let record else {
            self = .notDownloaded
            return
        }
        let fraction = record.transfer?.fraction
        switch record.state {
        case .queued where record.isWaitingForNetwork:
            self.init(
                kind: .waitingForNetwork, label: "Waiting for Lobby Server",
                detail: "It starts by itself when Lobby Server can be reached again.",
                symbol: "wifi.exclamationmark", fraction: fraction, actions: [.pause, .remove])
        case .queued:
            self.init(kind: .queued, label: "Waiting to download", detail: nil, symbol: "clock", fraction: fraction, actions: [.pause, .remove])
        case .preparing(let progress):
            self.init(
                kind: .preparing, label: "Lobby Server is preparing the file",
                detail: "This file is repackaged once before it can be downloaded.",
                symbol: "gearshape.arrow.triangle.2.circlepath", fraction: progress, actions: [.pause, .remove])
        case .downloading where record.isWaitingForNetwork:
            self.init(
                kind: .waitingForNetwork,
                label: record.allowsCellular ? "Waiting for a connection" : "Waiting for Wi-Fi",
                detail: record.allowsCellular
                    ? "It continues by itself when there is a connection to Lobby Server."
                    : "Downloads do not use mobile data. Turn that on in Settings, or connect to Wi-Fi.",
                symbol: "wifi.exclamationmark", fraction: fraction, actions: [.pause, .remove])
        case .downloading:
            self.init(kind: .downloading, label: "Downloading", detail: nil, symbol: "arrow.down.circle.dotted", fraction: fraction ?? 0, actions: [.pause, .remove])
        case .paused:
            self.init(kind: .paused, label: "Paused", detail: nil, symbol: "pause.circle", fraction: fraction, actions: [.resume, .remove])
        case .failed(let failure):
            self.init(
                kind: .failed, label: "Download failed", detail: Self.sentence(for: failure),
                symbol: "exclamationmark.circle", fraction: nil, actions: [.resume, .remove])
        case .verified:
            switch record.staleness {
            case nil:
                self.init(kind: .downloaded, label: "Downloaded", detail: nil, symbol: "checkmark.circle.fill", fraction: nil, actions: [.remove])
            case .changedOnServer:
                self.init(
                    kind: .outOfDate, label: "Out of date",
                    detail: "The file on Lobby Server was replaced after this copy was made. This copy still plays.",
                    symbol: "exclamationmark.arrow.triangle.2.circlepath", fraction: nil, actions: [.update, .remove])
            case .removedFromServer:
                self.init(
                    kind: .outOfDate, label: "No longer on Lobby Server",
                    detail: "It was removed from the library. The copy on this device still plays until you remove it.",
                    symbol: "exclamationmark.arrow.triangle.2.circlepath", fraction: nil, actions: [.remove])
            }
        }
        // A file a manager keeps on this device: it waits for the server when that is what it
        // waits for, and the person on the device cannot take it off.
        if let wanted = record.wanted {
            actions.removeAll { $0 == .remove }
            if !record.isOwn, record.state == .queued, wanted.downloadPath == nil {
                kind = .preparing
                label = "Waiting for Lobby Server"
                symbol = "hourglass"
                detail = wanted.message ?? "Lobby Server is getting this file ready. It downloads by itself."
            }
            detail = [detail, "A manager keeps this on this device."].compactMap { $0 }.joined(separator: " ")
        }
        // A copy that is being replaced still plays: say so beside the transfer's own state.
        if record.local != nil, record.state != .verified {
            detail = [detail, "The copy on this device plays meanwhile."].compactMap { $0 }.joined(separator: " ")
        }
    }

    static func sentence(for failure: DownloadFailure) -> String {
        switch failure {
        case .notEnoughSpace(let needed, let available):
            "There is not enough room on this device: it needs \(MediaFormat.size(bytes: needed)) and \(MediaFormat.size(bytes: available)) is free for downloads."
        case .sizeMismatch:
            "What arrived was not the whole file. Try again."
        case .changedOnServer:
            "The file changed on Lobby Server while it was downloading. Try again."
        case .removedFromServer:
            "This is no longer on Lobby Server."
        case .interrupted(let message):
            "The download broke off. \(message)"
        case .server(let message):
            message
        }
    }

    /// "Downloading, 42 percent", for VoiceOver. The percentage is rounded to tens, so a
    /// running download is not read out at every step.
    var accessibilityText: String {
        guard let fraction, kind == .downloading || kind == .preparing || kind == .paused else { return label }
        return "\(label), \(Int((fraction * 10).rounded()) * 10) percent"
    }

    /// "42 %" while something arrives.
    var percentText: String? {
        fraction.map { "\(Int(($0 * 100).rounded())) %" }
    }
}

/// What Download Season would fetch, shown before it starts.
struct SeasonDownloadPlan: Hashable, Sendable {
    /// Episodes that can be played and are not on the device or on their way yet.
    var episodes: [Item]
    /// Episodes of the season that cannot be played on Apple devices, and are left out.
    var skipped: Int
    var alreadyHere: Int
    var neededBytes: Int64
    /// Room for downloads on this device, or nil when the system does not say.
    var availableBytes: Int64?

    var fits: Bool { availableBytes.map { neededBytes <= $0 } ?? true }

    var title: String {
        episodes.isEmpty ? "Nothing to download" : "Download \(Self.count(episodes.count))?"
    }

    var message: String {
        var sentences: [String] = []
        if episodes.isEmpty {
            sentences.append(alreadyHere > 0 ? "Every episode of this season is on this device or on its way." : "No episode of this season can be downloaded.")
        } else {
            sentences.append("This needs about \(MediaFormat.size(bytes: neededBytes)).")
            if let availableBytes {
                sentences.append(fits
                    ? "\(MediaFormat.size(bytes: availableBytes)) is free for downloads on this device."
                    : "Only \(MediaFormat.size(bytes: availableBytes)) is free for downloads on this device, so it does not fit.")
            }
        }
        if skipped > 0 {
            sentences.append("\(Self.count(skipped)) cannot be played on Apple devices and \(skipped == 1 ? "is" : "are") left out.")
        }
        return sentences.joined(separator: " ")
    }

    static func count(_ episodes: Int) -> String {
        episodes == 1 ? "1 episode" : "\(episodes) episodes"
    }
}

/// The Downloads screen, worked out from the records.
struct DownloadsOverview: Hashable, Sendable {
    struct Row: Hashable, Sendable, Identifiable {
        var id: String
        /// The film, or "2. Coastal Worlds" for an episode.
        var title: String
        /// "S1 E2" for an episode, the year for a film.
        var caption: String?
        var status: DownloadStatus
        /// "1.8 GB", or "300 MB of 1.8 GB" while it arrives.
        var sizeText: String?
        var isPlayable: Bool
        /// The item as stored with the download, so it plays when the catalogue lost it.
        var item: Item

        var accessibilityLabel: String {
            [title, caption, status.accessibilityText, sizeText, status.detail].compactMap { $0 }.joined(separator: ", ")
        }
    }

    struct ShowGroup: Hashable, Sendable, Identifiable {
        var id: String
        var title: String
        /// "3 of 5 episodes downloaded · 1.2 GB": counts, so progress reads without percentages.
        var summary: String
        var rows: [Row]
    }

    var films: [Row] = []
    var shows: [ShowGroup] = []
    /// "4 items · 3.1 GB on this device".
    var total: String?

    var isEmpty: Bool { films.isEmpty && shows.isEmpty }

    static let empty = DownloadsOverview()

    init() {}

    init(records: [DownloadRecord]) {
        var films: [Row] = []
        var byShow: [String: (title: String, records: [DownloadRecord])] = [:]
        for record in records {
            if record.item.kind == .episode, let showID = record.showID {
                byShow[showID, default: (record.showTitle ?? "Series", [])].records.append(record)
            } else {
                films.append(Self.row(record, show: nil))
            }
        }
        self.films = films.sorted { $0.item.sortTitle.localizedStandardCompare($1.item.sortTitle) == .orderedAscending }
        shows = byShow.map { showID, group in
            let ordered = group.records.sorted {
                (($0.item.seasonNumber ?? .max), ($0.item.episodeNumber ?? .max), $0.itemID)
                    < (($1.item.seasonNumber ?? .max), ($1.item.episodeNumber ?? .max), $1.itemID)
            }
            let done = ordered.filter { $0.state == .verified }.count
            let bytes = ordered.reduce(0) { $0 + $1.bytesOnDevice }
            let counts = done == ordered.count
                ? "\(SeasonDownloadPlan.count(done)) downloaded"
                : "\(done) of \(SeasonDownloadPlan.count(ordered.count)) downloaded"
            return ShowGroup(
                id: showID, title: group.title,
                summary: bytes > 0 ? "\(counts) · \(MediaFormat.size(bytes: bytes))" : counts,
                rows: ordered.map { Self.row($0, show: group.title) })
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        let bytes = records.reduce(0) { $0 + $1.bytesOnDevice }
        total = records.isEmpty
            ? nil
            : "\(records.count == 1 ? "1 item" : "\(records.count) items") · \(MediaFormat.size(bytes: bytes)) on this device"
    }

    private static func row(_ record: DownloadRecord, show: String?) -> Row {
        let item = record.item
        let isEpisode = item.kind == .episode
        let showItem = show.map { Item(id: record.showID ?? "", kind: .show, title: $0, addedAt: item.addedAt) }
        var sizeText: String?
        if let transfer = record.transfer, record.state != .verified {
            sizeText = "\(MediaFormat.size(bytes: transfer.receivedBytes)) of \(MediaFormat.size(bytes: transfer.expectedBytes))"
        } else if let local = record.local {
            sizeText = MediaFormat.size(bytes: local.sizeBytes)
        }
        return Row(
            id: record.itemID,
            title: isEpisode ? ItemText.episodeTitle(item, show: showItem) : item.title,
            caption: isEpisode
                ? MediaFormat.episodeCode(season: item.seasonNumber, episode: item.episodeNumber)
                : item.year.map(String.init),
            status: DownloadStatus(record: record),
            sizeText: sizeText,
            isPlayable: record.isPlayable,
            item: item)
    }
}

/// The pictures that are kept on the device with what is downloaded.
enum DownloadArtwork {
    /// Everything a downloaded film or episode is shown with: its own poster, backdrop, still
    /// and logo, and those of its season and show.
    static func wanted(for itemIDs: Set<String>, in catalogue: Catalogue) -> [Artwork] {
        var seen: Set<String> = []
        return catalogue.limited(to: itemIDs).items
            .sorted { $0.id < $1.id }
            .flatMap { [$0.artwork.poster, $0.artwork.backdrop, $0.artwork.still, $0.artwork.logo].compactMap { $0 } }
            .filter { seen.insert($0.id).inserted }
    }

    /// The ones of those that fill a banner, and are kept larger.
    static func banners(for itemIDs: Set<String>, in catalogue: Catalogue) -> Set<String> {
        Set(catalogue.limited(to: itemIDs).items.compactMap(\.artwork.backdrop?.id))
    }
}
