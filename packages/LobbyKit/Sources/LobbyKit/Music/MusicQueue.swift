// SPDX-License-Identifier: MPL-2.0
import Foundation

/// What plays now and what comes after: the order, shuffle and repeat. A value without
/// sound, so that every rule can be tested; the player follows it.
///
/// Every entry has its own id, so the same track can be in the queue twice and each can be
/// moved or removed by itself.
public struct MusicQueue: Codable, Hashable, Sendable {
    public enum Repeat: String, Codable, CaseIterable, Sendable {
        case off, all, one

        /// What a tap on the repeat button makes of it.
        public var next: Repeat {
            switch self {
            case .off: .all
            case .all: .one
            case .one: .off
            }
        }
    }

    public struct Entry: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var trackID: String

        public init(id: String = UUID().uuidString, trackID: String) {
            self.id = id
            self.trackID = trackID
        }
    }

    /// In the order they play.
    public private(set) var entries: [Entry] = []
    /// The order before shuffle, to go back to.
    private var unshuffled: [Entry] = []
    /// The one playing, in `entries`. nil: nothing (the end was reached, or it is empty).
    public private(set) var index: Int?
    public private(set) var isShuffled = false
    public var repeatMode: Repeat = .off
    /// For the shuffles: the same seed gives the same order, in tests.
    private var seed: UInt64

    public init(trackIDs: [String] = [], startAt start: Int = 0, shuffled: Bool = false, seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        self.seed = seed
        entries = trackIDs.map { Entry(trackID: $0) }
        unshuffled = entries
        index = entries.isEmpty ? nil : min(max(start, 0), entries.count - 1)
        if shuffled { setShuffled(true) }
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var current: Entry? { index.map { entries[$0] } }
    /// What comes after the one playing, in order. Repeat all does not wrap here.
    public var upNext: ArraySlice<Entry> { index.map { entries[($0 + 1)...] } ?? entries[...] }
    /// What played before it.
    public var history: ArraySlice<Entry> { index.map { entries[..<$0] } ?? [] }

    // MARK: Moving on

    /// What plays after the current one when it ends by itself: the same one again with repeat
    /// one, the first again at the end with repeat all, or nothing. Does not move.
    public func following(automatic: Bool = true) -> Entry? {
        guard let index else { return nil }
        if automatic, repeatMode == .one { return entries[index] }
        if index + 1 < entries.count { return entries[index + 1] }
        return repeatMode == .all ? entries.first : nil
    }

    /// The current one ended by itself. Returns what plays now, or nil at the end.
    @discardableResult
    public mutating func advance() -> Entry? {
        move(automatic: true)
    }

    /// Next, by the listener: also with repeat one it goes on.
    @discardableResult
    public mutating func skipForward() -> Entry? {
        move(automatic: false)
    }

    private mutating func move(automatic: Bool) -> Entry? {
        guard let current = index else { return nil }
        if automatic, repeatMode == .one { return entries[current] }
        if current + 1 < entries.count {
            index = current + 1
        } else if repeatMode == .all, !entries.isEmpty {
            // Round again; a shuffled queue in another order, but not starting with the last one.
            if isShuffled, entries.count > 1 {
                let last = entries[current]
                Self.shuffle(&entries, seed: &seed)
                if entries[0].id == last.id { entries.swapAt(0, entries.count - 1) }
            }
            index = 0
        } else {
            index = nil
        }
        return self.current
    }

    /// Back, by the listener: to the one before, or with repeat all from the first to the last.
    /// (Whether to start the current one again instead is the player's choice: it knows the time.)
    @discardableResult
    public mutating func skipBack() -> Entry? {
        guard let current = index else {
            // After the end: the last one again.
            index = entries.isEmpty ? nil : entries.count - 1
            return self.current
        }
        if current > 0 {
            index = current - 1
        } else if repeatMode == .all {
            index = entries.count - 1
        }
        return self.current
    }

    /// Plays this entry now, wherever it is in the queue.
    @discardableResult
    public mutating func jump(to entryID: String) -> Entry? {
        guard let found = entries.firstIndex(where: { $0.id == entryID }) else { return current }
        index = found
        return current
    }

    // MARK: Shuffle

    /// On: the one playing stays and goes first; the rest in a random order. Off: the order
    /// they came in, from where the one playing is.
    public mutating func setShuffled(_ on: Bool) {
        guard on != isShuffled else { return }
        isShuffled = on
        let playing = current
        if on {
            var rest = entries
            if let index { rest.remove(at: index) }
            Self.shuffle(&rest, seed: &seed)
            entries = (playing.map { [$0] } ?? []) + rest
            index = playing == nil ? (entries.isEmpty ? nil : 0) : 0
        } else {
            // What was added meanwhile stays, after what was there.
            let known = Set(unshuffled.map(\.id))
            let present = Set(entries.map(\.id))
            entries = unshuffled.filter { present.contains($0.id) } + entries.filter { !known.contains($0.id) }
            index = playing.flatMap { entry in entries.firstIndex { $0.id == entry.id } }
        }
    }

    // MARK: Changing the queue

    /// After the one playing.
    public mutating func playNext(_ trackIDs: [String]) {
        let added = trackIDs.map { Entry(trackID: $0) }
        let wasEmpty = entries.isEmpty
        let at = index.map { $0 + 1 } ?? entries.count
        entries.insert(contentsOf: added, at: at)
        if let playing = current, let place = unshuffled.firstIndex(where: { $0.id == playing.id }) {
            unshuffled.insert(contentsOf: added, at: place + 1)
        } else {
            unshuffled.append(contentsOf: added)
        }
        if wasEmpty, !added.isEmpty { index = 0 }
    }

    /// At the end.
    public mutating func add(_ trackIDs: [String]) {
        let added = trackIDs.map { Entry(trackID: $0) }
        let wasEmpty = entries.isEmpty
        entries.append(contentsOf: added)
        unshuffled.append(contentsOf: added)
        if wasEmpty, !added.isEmpty { index = 0 }
    }

    /// Moves entries of Up Next, by their offsets in `upNext`, as a list's move gives them.
    public mutating func moveUpNext(fromOffsets source: IndexSet, toOffset destination: Int) {
        let base = index.map { $0 + 1 } ?? 0
        var next = Array(entries[base...])
        let moving = source.sorted().map { next[$0] }
        let before = source.filter { $0 < destination }.count
        for offset in source.sorted(by: >) { next.remove(at: offset) }
        next.insert(contentsOf: moving, at: max(0, min(next.count, destination - before)))
        entries.replaceSubrange(base..., with: next)
        if !isShuffled { unshuffled = entries }
    }

    /// Takes an entry out. Removing the one playing makes the next one current.
    public mutating func remove(entryID: String) {
        guard let found = entries.firstIndex(where: { $0.id == entryID }) else { return }
        entries.remove(at: found)
        unshuffled.removeAll { $0.id == entryID }
        guard let current = index else { return }
        if found < current {
            index = current - 1
        } else if found == current, current >= entries.count {
            index = nil
        }
        if entries.isEmpty { index = nil }
    }

    /// Empties Up Next, keeping what plays.
    public mutating func clearUpNext() {
        guard let index else {
            entries = []
            unshuffled = []
            return
        }
        let kept = Set(entries[...index].map(\.id))
        entries = Array(entries[...index])
        unshuffled.removeAll { !kept.contains($0.id) }
    }

    // MARK: Shuffling

    /// Fisher–Yates with SplitMix64: the same seed, the same order.
    private static func shuffle(_ array: inout [Entry], seed: inout UInt64) {
        guard array.count > 1 else { return }
        for i in stride(from: array.count - 1, to: 0, by: -1) {
            seed &+= 0x9E37_79B9_7F4A_7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            let j = Int(z % UInt64(i + 1))
            array.swapAt(i, j)
        }
    }
}
