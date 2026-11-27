// SPDX-License-Identifier: MPL-2.0
import Foundation

/// How durations, positions and sizes are written. One place, so the iPad and the Mac agree.
enum MediaFormat {
    /// A running time: "1 h 42 min", "58 min", "1 min". nil for an unknown or empty duration.
    static func runtime(ms: Int?) -> String? {
        guard let ms, ms > 0 else { return nil }
        let minutes = max(1, Int((Double(ms) / 60_000).rounded()))
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(minutes) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// A position in a film: "34:17", "1:42:08".
    static func clock(ms: Int) -> String {
        let seconds = max(0, ms) / 1000
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return h > 0
            ? "\(h):\(String(format: "%02d", m)):\(String(format: "%02d", s))"
            : "\(m):\(String(format: "%02d", s))"
    }

    /// What is left of something part-watched: "28 min left". nil when the duration is unknown.
    static func remaining(positionMs: Int, durationMs: Int?) -> String? {
        guard let durationMs, durationMs > positionMs else { return nil }
        guard let runtime = runtime(ms: durationMs - positionMs) else { return nil }
        return "\(runtime) left"
    }

    /// 0…1 of something part-watched, or nil when the duration is unknown.
    static func fraction(positionMs: Int, durationMs: Int?) -> Double? {
        guard let durationMs, durationMs > 0 else { return nil }
        return min(1, max(0, Double(positionMs) / Double(durationMs)))
    }

    /// "S1 E2", "Episode 2", "Specials E3", or nil when neither number is known.
    static func episodeCode(season: Int?, episode: Int?) -> String? {
        switch (season, episode) {
        case (0?, let episode?): "Specials E\(episode)"
        case (let season?, let episode?): "S\(season) E\(episode)"
        case (nil, let episode?): "Episode \(episode)"
        default: nil
        }
    }

    /// "Season 2", "Specials", or the season's own title when it has no number.
    static func seasonName(_ season: Int?, fallback: String) -> String {
        switch season {
        case 0?: "Specials"
        case let number?: "Season \(number)"
        case nil: fallback
        }
    }

    /// A file size: "2.1 GB".
    static func size(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "1080p", "4K", or nil when the height is unknown.
    static func resolution(height: Int?, width: Int?) -> String? {
        guard let height else { return nil }
        if (width ?? 0) >= 3800 || height >= 2000 { return "4K" }
        if height >= 1000 || (width ?? 0) >= 1900 { return "1080p" }
        if height >= 700 || (width ?? 0) >= 1270 { return "720p" }
        return "SD"
    }
}
