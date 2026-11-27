// SPDX-License-Identifier: MPL-2.0
import Observation

/// Which tile of a page of shelves has the remote. A tile tells it and listens to it by itself:
/// the page is not evaluated again when the remote moves.
@MainActor @Observable
final class FocusKeeper {
    /// The tile that should take the remote now. Changes only when the player closed.
    private(set) var wanted: TVFocusID?
    /// The tile that has it.
    @ObservationIgnored private(set) var current: TVFocusID?
    /// What is on the page, in its order.
    @ObservationIgnored var rows: [FocusMemory.Row] = []
    @ObservationIgnored private var memory = FocusMemory()

    func took(_ id: TVFocusID) {
        current = id
        wanted = nil
        memory.remember(id, in: rows)
    }

    func left(_ id: TVFocusID) {
        if current == id { current = nil }
    }

    /// What opened the player is not on a shelf: nothing is to be found again.
    func forget() {
        memory = FocusMemory()
    }

    /// - Returns: The tile that is asked to take the remote.
    func restore() -> TVFocusID? {
        guard current == nil, let target = memory.target(in: rows) else { return nil }
        // Also when it was asked before and could not yet.
        wanted = nil
        wanted = target
        return target
    }
}
