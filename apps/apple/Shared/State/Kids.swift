// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// What came of asking for a grown-up.
enum GrownUpCheck: Hashable, Sendable {
    case confirmed
    /// Cancelled, or not recognised.
    case refused
    /// The device has no passcode, so there is nothing to ask for. Nobody passes.
    case unavailable
}

/// What a grown-up reads instead of leaving kids mode.
enum GrownUpNotice: String, Hashable, Identifiable, Sendable {
    /// A manager bound this device to the viewer.
    case bound
    /// The device has no passcode.
    case noPasscode

    var id: String { rawValue }
}

/// What came of the grown-ups' code.
enum KidsCodeCheck: Hashable, Sendable {
    case confirmed
    case wrong
    /// Too many wrong ones: not before that many seconds.
    case locked(seconds: Int)
    /// The household has none, or its server is from before codes.
    case noCode
    /// A manager bound this device to the viewer.
    case bound
    /// The server did not answer. Nobody passes without it.
    case unreachable
}

/// The server does not know kids viewers: it took the change and left the kids part out.
struct KidsUnsupported: LocalizedError {
    var errorDescription: String? { "This Lobby Server does not know kids viewers yet. Update it first." }
}
