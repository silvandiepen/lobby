// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Why there is no direct connection, or no pairing over one.
public enum DirectError: Error, Hashable, Sendable {
    /// The introducer cannot be reached.
    case introducerUnreachable
    /// It does not know this box, or there is no such pairing room.
    case unknownRoom
    /// A manager has to allow this device, or it was removed.
    case notAllowed
    /// The box is not signed in at the introducer.
    case boxOffline
    case tooOften
    /// Something answered that is not the box, or said nothing in time.
    case notFromTheBox
    case noAnswer
    /// The box has its hands full.
    case busy
    /// The two networks let nothing through.
    case noPath
    /// What is at the other end does not have the box's certificate.
    case wrongCertificate
    /// The box did not take this device's proof.
    case proofRefused
    case closed
    case badIdentity
    /// The manager said no, or it is over.
    case pairingRefused
    case pairingExpired
}

extension DirectError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .introducerUnreachable: "The internet, or the service that introduces Lobby's devices, cannot be reached."
        case .unknownRoom: "Nothing waits for this code. It may be wrong, used or over."
        case .notAllowed: "This device is not let in from outside. A manager can allow it, at home."
        case .boxOffline: "Lobby Server at home cannot be reached. Is it on, and is access from outside on?"
        case .tooOften: "Too many tries. Wait a minute and try again."
        case .notFromTheBox, .wrongCertificate: "What answered is not your Lobby Server. Nothing was sent to it."
        case .noAnswer: "Lobby Server did not answer in time."
        case .busy: "Lobby Server has as many connections from outside as it takes. Try again later."
        case .noPath: "The network here and the one at home let no connection through."
        case .proofRefused: "Lobby Server did not recognise this device."
        case .closed: "The connection was closed."
        case .badIdentity: "What this device kept for connecting from outside cannot be read."
        case .pairingRefused: "The manager said no."
        case .pairingExpired: "The code is over. Ask for a new one."
        }
    }
}
