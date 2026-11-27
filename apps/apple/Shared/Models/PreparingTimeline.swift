// SPDX-License-Identifier: MPL-2.0
import Foundation

/// The bar of a film whose copy the server is still writing.
///
/// The system player cannot draw it: a stream without an end looks like a live broadcast to
/// it, with a LIVE badge and the time of day. The film's length is known from the catalogue
/// and the server says how far the copy reaches, so the app draws the bar itself until the
/// copy is complete.
struct PreparingTimeline: Hashable, Sendable {
    /// The film's length, from the catalogue.
    var durationMs: Int
    /// How far into the film the copy reaches. Playing and seeking stop there for now.
    var preparedMs: Int
    var positionMs: Int
    /// 0…1 of the copy is written.
    var progress: Double
    /// How fast the copy is written, as a multiple of playback speed.
    var speed: Double?
    /// The picture is being converted (an old AVI film), not just repackaged.
    var videoConverted: Bool
    /// What this device already holds, from where to where in the film. A jump in there plays at
    /// once; one beyond it waits for the network.
    var bufferedMs: [Range<Int>] = []

    /// A seek stays this far before the end of what is written. A player that sits at the very
    /// end of a growing stream runs dry and gives up; half a minute is a few segments of room.
    static let seekMarginMs = 30_000

    var positionFraction: Double { fraction(positionMs) }
    var preparedFraction: Double { fraction(preparedMs) }
    /// What this device holds, as parts of the bar, in order and none overlapping.
    var bufferedFractions: [Range<Double>] {
        var merged: [Range<Int>] = []
        for range in bufferedMs.sorted(by: { $0.lowerBound < $1.lowerBound }) where !range.isEmpty {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged.map { fraction($0.lowerBound)..<fraction($0.upperBound) }.filter { !$0.isEmpty }
    }

    private func fraction(_ ms: Int) -> Double {
        durationMs > 0 ? min(1, max(0, Double(ms) / Double(durationMs))) : 0
    }

    /// "12:34"
    var elapsedText: String { MediaFormat.clock(ms: positionMs) }

    /// "−1:26:26"
    var remainingText: String { "−" + MediaFormat.clock(ms: max(0, durationMs - positionMs)) }

    /// Where a seek to `fraction` of the film lands: there, or as far as the copy reaches.
    func seekTarget(fraction: Double) -> Int {
        clamped(Int((min(1, max(0, fraction)) * Double(durationMs)).rounded()))
    }

    /// Where ten seconds back or forward lands.
    func skipTarget(bySeconds seconds: Int) -> Int {
        clamped(positionMs + seconds * 1000)
    }

    private func clamped(_ ms: Int) -> Int {
        max(0, min(ms, max(0, preparedMs - Self.seekMarginMs)))
    }

    /// The viewer caught up with the copy: the film waits for the server.
    var hasCaughtUp: Bool { positionMs >= preparedMs - 1_000 }

    /// "Lobby Server is still preparing this film: 36 %. About 4 min to go."
    var statusText: String {
        let verb = videoConverted ? "converting" : "preparing"
        var text = "Lobby Server is still \(verb) this film: \(Int((progress * 100).rounded())) %."
        if let speed, speed > 0, durationMs > preparedMs,
            let left = MediaFormat.runtime(ms: Int(Double(durationMs - preparedMs) / speed))
        {
            text += " About \(left) to go."
        }
        if videoConverted, let speed, speed < 1 {
            text += " It converts more slowly than the film plays, so it will pause now and then."
        }
        return text
    }

    /// "12:34 of 1:39:00, prepared up to 35:55", for VoiceOver.
    var accessibilityValue: String {
        "\(elapsedText) of \(MediaFormat.clock(ms: durationMs)), prepared up to \(MediaFormat.clock(ms: preparedMs))"
    }
}
