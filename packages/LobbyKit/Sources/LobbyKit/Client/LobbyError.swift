// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Everything a call to Lobby Server can fail with.
///
/// The cases the apps must tell apart on the Connect screen are separate on purpose:
/// `.unreachable` (the Pi is off or the network is not there: keep working from the cache),
/// `.deviceRevoked` (a manager removed this device: pair again) and `.unauthorized` (the server
/// does not know this credential at all).
public enum LobbyError: Error, Hashable, Sendable {
    /// The address given is not an http(s) URL with a host.
    case invalidServerAddress
    /// No answer from the server: offline, wrong network, timed out, TLS failed.
    case unreachable(URLError.Code)
    /// 400 `invalid_request`.
    case invalidRequest(message: String)
    /// 401 `unauthorized`: no credential, or one the server does not know.
    case unauthorized(message: String)
    /// 401 `device_revoked`: the credential was valid and a manager revoked it.
    case deviceRevoked(message: String)
    /// 403 `forbidden`: the device's role does not allow this (or a wrong setup secret).
    case forbidden(message: String)
    /// 404 `not_found`.
    case notFound(message: String)
    /// 409 `conflict`. For a progress update it carries the progress the server holds.
    case conflict(message: String, progress: PlaybackProgress?)
    /// 410 `gone`: a pairing request expired or was already collected.
    case gone(message: String)
    /// 416 `range_not_satisfiable`.
    case rangeNotSatisfiable(message: String)
    /// 429 `rate_limited`, with `Retry-After` in seconds when the server sent it.
    case rateLimited(message: String, retryAfter: TimeInterval?)
    /// 503 `unavailable`: the file's drive is not mounted.
    case unavailable(message: String)
    /// An error status this build has no case for (a newer server, or a proxy in between).
    case server(status: Int, code: String?, message: String)
    /// The server answered with something that is not the documented shape.
    case invalidResponse(String)

    /// The server could not be reached, as opposed to having refused.
    public var isUnreachable: Bool {
        if case .unreachable = self { return true }
        return false
    }

    /// The stored credential no longer works and the device has to pair again.
    public var requiresPairing: Bool {
        switch self {
        case .unauthorized, .deviceRevoked: true
        default: false
        }
    }

    /// Worth sending the same request again later, unchanged.
    public var isTransient: Bool {
        switch self {
        case .unreachable, .rateLimited, .unavailable: true
        case .server(let status, _, _): status >= 500
        default: false
        }
    }
}

extension LobbyError {
    /// How long to wait before asking again, when the server is busy with others
    /// (`rate_limited`). nil for anything else. What the server asked for, within reason: a
    /// person may be waiting.
    public var pauseWhenBusy: Duration? {
        guard case .rateLimited(_, let retryAfter) = self else { return nil }
        return .seconds(min(30, max(1, retryAfter ?? 2)))
    }

    /// A call that waits its turn: while the server is busy it is made again later, instead of
    /// failing. After `tries` the refusal is thrown.
    public static func waitingItsTurn<Answer: Sendable>(
        tries: Int = 8, sleep: @Sendable (Duration) async throws -> Void, _ call: () async throws -> Answer
    ) async throws -> Answer {
        for _ in 1..<max(1, tries) {
            do {
                return try await call()
            } catch let error as LobbyError {
                guard let pause = error.pauseWhenBusy else { throw error }
                try await sleep(pause)
            }
        }
        return try await call()
    }
}

extension LobbyError: LocalizedError {
    /// The server's `message` is written for a person and may be shown as it is.
    public var errorDescription: String? {
        switch self {
        case .invalidServerAddress:
            "That is not a server address."
        case .unreachable:
            "Lobby Server cannot be reached."
        case .invalidRequest(let message), .unauthorized(let message), .deviceRevoked(let message),
            .forbidden(let message), .notFound(let message), .gone(let message),
            .rangeNotSatisfiable(let message), .unavailable(let message):
            message
        case .conflict(let message, _), .rateLimited(let message, _), .server(_, _, let message):
            message
        case .invalidResponse(let detail):
            "Lobby Server sent an answer this app does not understand. \(detail)"
        }
    }
}

/// `{ "error": { "code": …, "message": … } }`, plus `progress` on a progress conflict.
struct ErrorEnvelope: Decodable {
    struct Body: Decodable {
        var code: String
        var message: String
    }

    var error: Body
    var progress: PlaybackProgress?
}

extension LobbyError {
    /// Maps an error response. The body's `code` decides; the status is the fallback for an
    /// answer that did not come from Lobby Server itself.
    static func from(status: Int, data: Data, headers: HTTPURLResponse) -> LobbyError {
        let envelope = try? LobbyJSON.decoder().decode(ErrorEnvelope.self, from: data)
        let message = envelope?.error.message ?? HTTPURLResponse.localizedString(forStatusCode: status)
        let code = envelope?.error.code ?? fallbackCode(for: status)

        switch code {
        case "invalid_request": return .invalidRequest(message: message)
        case "unauthorized": return .unauthorized(message: message)
        case "device_revoked": return .deviceRevoked(message: message)
        case "forbidden": return .forbidden(message: message)
        case "not_found": return .notFound(message: message)
        case "conflict": return .conflict(message: message, progress: envelope?.progress)
        case "gone": return .gone(message: message)
        case "range_not_satisfiable": return .rangeNotSatisfiable(message: message)
        case "rate_limited":
            let retryAfter = headers.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return .rateLimited(message: message, retryAfter: retryAfter)
        case "unavailable": return .unavailable(message: message)
        default: return .server(status: status, code: code, message: message)
        }
    }

    private static func fallbackCode(for status: Int) -> String? {
        switch status {
        case 400: "invalid_request"
        case 401: "unauthorized"
        case 403: "forbidden"
        case 404: "not_found"
        case 409: "conflict"
        case 410: "gone"
        case 416: "range_not_satisfiable"
        case 429: "rate_limited"
        default: nil
        }
    }
}
