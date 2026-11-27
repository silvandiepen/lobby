// SPDX-License-Identifier: MPL-2.0
import Foundation

/// What the player says while the picture stands still. Never only a spinner: the viewer reads
/// whether it is coming, that the connection is too slow for this film, or that nothing comes.
enum BufferNotice: Hashable, Sendable {
    /// More is arriving, fast enough.
    case buffering
    /// More is arriving more slowly than the film plays: 0.4 is four seconds in ten.
    case slow(rate: Double)
    /// Nothing has arrived for a while. The viewer can try again.
    case stalled

    var title: String {
        switch self {
        case .buffering: "Buffering"
        case .slow: "The connection is slow"
        case .stalled: "Nothing is arriving from Lobby Server"
        }
    }

    /// - Parameter filmBitrate: What the film needs, in bits per second.
    func explanation(filmBitrate: Double?) -> String? {
        switch self {
        case .buffering:
            return nil
        case .slow(let rate):
            let share = max(1, Int((rate * 100).rounded()))
            let need = filmBitrate.map { " (\(Self.megabits($0)))" } ?? ""
            return "It carries about \(share) % of what this film needs\(need), so the film will pause now and then. Pausing it for a few minutes lets more of it arrive."
        case .stalled:
            return "The connection may be gone, or very slow. Trying again goes on from here."
        }
    }

    static func megabits(_ bitsPerSecond: Double) -> String {
        String(format: "%.1f Mbit/s", locale: Locale(identifier: "en_US_POSIX"), bitsPerSecond / 1_000_000)
    }
}

/// Follows the player while it waits, one reading a second, and decides what to say. A value:
/// the same readings always give the same notice.
struct BufferWatch: Hashable, Sendable {
    struct Reading: Hashable, Sendable {
        /// Any clock that only goes forward, in seconds.
        var at: Double
        /// The film should be running and is not.
        var isWaiting: Bool
        /// How much of the film the player holds ahead of where it is, in seconds of film. Not
        /// all it holds: what lies behind, or elsewhere after a jump, plays nothing now.
        var loadedSeconds: Double
        /// The server is still writing the part that is needed: that the player gets nothing
        /// says little about the connection.
        var isForServer = false
    }

    /// Short waits (the start, a seek) are nobody's business.
    static let quietFor = 2.0
    /// Before this, an arrival rate means little.
    static let judgesAfter = 8.0
    static let stalledAfter = 20.0
    static let stalledForServerAfter = 90.0
    /// Held ahead, in seconds of film, past which a wait is not blamed on the connection.
    static let enoughAhead = 10.0

    private(set) var notice: BufferNotice?
    private var since: Double?
    private var loadedAtStart = 0.0
    private var lastLoaded = 0.0
    private var lastArrival = 0.0

    mutating func add(_ reading: Reading) {
        guard reading.isWaiting else {
            self = BufferWatch()
            return
        }
        guard let since, reading.loadedSeconds >= lastLoaded - 0.1 else {
            // The wait begins, or the player threw away what it had (a seek): from here on.
            self.since = reading.at
            loadedAtStart = reading.loadedSeconds
            lastLoaded = reading.loadedSeconds
            lastArrival = reading.at
            return
        }
        if reading.loadedSeconds > lastLoaded + 0.05 { lastArrival = reading.at }
        lastLoaded = max(lastLoaded, reading.loadedSeconds)

        let waited = reading.at - since
        let silent = reading.at - lastArrival
        if reading.loadedSeconds >= Self.enoughAhead {
            // It holds enough to play on, and waits for reasons of its own: not the connection's.
            notice = waited < Self.quietFor ? nil : .buffering
        } else if silent >= (reading.isForServer ? Self.stalledForServerAfter : Self.stalledAfter) {
            notice = .stalled
        } else if waited < Self.quietFor {
            notice = nil
        } else if waited < Self.judgesAfter || reading.isForServer {
            notice = .buffering
        } else {
            let rate = (lastLoaded - loadedAtStart) / waited
            notice = rate < 0.9 ? .slow(rate: rate) : .buffering
        }
    }

    /// Seconds held from `position` on: the part of `buffered` (milliseconds) it lies in, from
    /// there to its end. 0 where nothing is held.
    static func secondsAhead(of position: Double, in buffered: [Range<Int>]) -> Double {
        guard position.isFinite else { return 0 }
        let here = Int((position * 1000).rounded())
        // The player reports a range that starts a hair after where it stands.
        let found = buffered.first { $0.lowerBound - 500 <= here && here < $0.upperBound }
        return found.map { Double($0.upperBound - max(here, $0.lowerBound)) / 1000 } ?? 0
    }

    /// What a film needs on average, in bits per second, from its size and its length.
    static func bitrate(sizeBytes: Int64, durationMs: Int?) -> Double? {
        guard let durationMs, durationMs > 0, sizeBytes > 0 else { return nil }
        return Double(sizeBytes) * 8_000 / Double(durationMs)
    }
}

/// What is said while an answer is on its way: nothing at first, then that it is slow.
enum Patience {
    static let saysSlowAfter = 8.0

    /// - Parameter titles: How many films and shows arrived so far.
    static func fetchingLibrary(waited: Double, titles: Int) -> String {
        let sofar = titles == 0 ? "Fetching the library…" : "Fetching the library… \(titles) titles so far."
        return waited < saysSlowAfter ? sofar : sofar + " The connection to Lobby Server is slow."
    }

    static func askingToPlay(waited: Double) -> String {
        waited < saysSlowAfter
            ? "Asking Lobby Server" : "Still asking Lobby Server. The connection is slow."
    }

    /// Looking on the network ends in words, not in a spinner without end.
    static func discoveryFoundNothing(waited: Double) -> Bool { waited >= 10 }
}
