// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import MediaPlayer

/// What the lock screen, Control Center, the Mac's Now Playing and a car or watch show of the
/// music that plays: one dictionary for `MPNowPlayingInfoCenter`, made from values so that it
/// can be tested.
struct NowPlayingDescription: Equatable {
    var title: String
    var artist: String
    /// The album, or the book.
    var collection: String?
    var durationSeconds: Double?
    var elapsedSeconds: Double
    /// 0 while paused.
    var rate: Double
    /// The rate it plays at when it plays: a book read faster.
    var defaultRate: Double = 1
    var queueIndex: Int?
    var queueCount: Int
    var isBook = false
    /// In a book: the chapter now, and how many there are.
    var chapter: (index: Int, count: Int)? = nil

    static func == (a: Self, b: Self) -> Bool {
        a.title == b.title && a.artist == b.artist && a.collection == b.collection && a.durationSeconds == b.durationSeconds
            && a.elapsedSeconds == b.elapsedSeconds && a.rate == b.rate && a.defaultRate == b.defaultRate
            && a.queueIndex == b.queueIndex && a.queueCount == b.queueCount && a.isBook == b.isBook
            && a.chapter?.index == b.chapter?.index && a.chapter?.count == b.chapter?.count
    }

    var info: [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: defaultRate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queueCount,
        ]
        if let collection { info[MPMediaItemPropertyAlbumTitle] = collection }
        if let durationSeconds, durationSeconds > 0 { info[MPMediaItemPropertyPlaybackDuration] = durationSeconds }
        if let queueIndex { info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queueIndex }
        if let chapter {
            info[MPNowPlayingInfoPropertyChapterNumber] = chapter.index
            info[MPNowPlayingInfoPropertyChapterCount] = chapter.count
        }
        return info
    }
}

/// How much quieter a track plays so that loud and quiet ones sound alike, from its ReplayGain:
/// the album's gain inside an album played in order, the track's otherwise. Never louder than
/// the file (a player's volume cannot go above one), and never so loud that a peak clips.
enum VolumeMatching {
    static func volume(for gain: ReplayGain?, preferAlbum: Bool) -> Float {
        guard let gain else { return 1 }
        let decibels = (preferAlbum ? gain.albumGainDb ?? gain.trackGainDb : gain.trackGainDb ?? gain.albumGainDb) ?? 0
        let peak = (preferAlbum ? gain.albumPeak ?? gain.trackPeak : gain.trackPeak ?? gain.albumPeak) ?? 0
        var factor = pow(10, decibels / 20)
        if peak > 0 { factor = min(factor, 1 / peak) }
        return Float(min(1, max(0.05, factor)))
    }
}

/// Lengths as a player writes them.
enum MusicTime {
    /// "3:07", "1:02:45".
    static func short(_ milliseconds: Int) -> String {
        clock(Double(milliseconds) / 1000)
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    /// "42 min", "3 h 5 min".
    static func long(_ milliseconds: Int) -> String {
        let minutes = Int((Double(milliseconds) / 60_000).rounded())
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(max(1, minutes)) min"
    }
}
