// SPDX-License-Identifier: MPL-2.0
import Foundation

extension LobbyClient {
    /// `GET /v1/live?session=…&last=…`: the request for the channel, with the credential.
    public func liveRequest(session: String, last: String?) -> URLRequest {
        var query = [URLQueryItem(name: "session", value: session)]
        if let last { query.append(URLQueryItem(name: "last", value: last)) }
        var request = authorizedRequest(for: url(["live"], query: query))
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let last { request.setValue(last, forHTTPHeaderField: "Last-Event-ID") }
        return request
    }

    /// `POST /v1/live/{session}`: what this device does.
    ///
    /// Throws `RemoteRefusal` when the server will not take it (`needsChannel`: open it first).
    public func announce(_ announcement: Announcement, session: String) async throws -> AnnounceReply {
        try decode(try await remote("POST", ["live", session], body: announcement))
    }

    /// `POST /v1/live/{session}/results`: how a command for this device went.
    public func sendResult(_ outcome: CommandOutcome, session: String) async throws {
        _ = try await remote("POST", ["live", session, "results"], body: outcome)
    }

    /// `POST /v1/remote/commands`. Throws `RemoteRefusal` with the server's reason.
    public func sendCommand(_ request: CommandRequest) async throws -> CommandReply {
        try decode(try await remote("POST", ["remote", "commands"], body: request))
    }

    /// `POST /v1/remote/wake`: Lobby Server turns that Apple TV on and opens Lobby on it. Returns
    /// once the TV took it. Throws `RemoteRefusal`.
    ///
    /// With `play`, the server keeps the play and sends it the moment Lobby is open on the TV
    /// (`WakeReply.play`), also when this app is gone by then; how it went comes as a `result` of
    /// the channel with the play's id. Without, wait for the TV on the channel and send it then.
    ///
    /// - Parameter session: this device's channel, so that the server knows who asks: the kids
    ///   screens may wake a TV only when the household lets kids turn on the TV. Needed with `play`.
    @discardableResult
    public func wake(deviceID: String, session: String? = nil, play: HeldPlayRequest? = nil) async throws -> WakeReply {
        struct Body: Encodable {
            var deviceId: String
            var session: String?
            var play: HeldPlayRequest?
        }
        let data = try await remote("POST", ["remote", "wake"], body: Body(deviceId: deviceID, session: session, play: play))
        // An older server answers with less; that it was woken is all that counts then.
        return (try? decode(data)) ?? WakeReply(deviceId: deviceID)
    }

    /// `DELETE /v1/remote/wake/{deviceId}/plays/{id}`: the play that waits for that TV is not
    /// wanted any more. False when it was not waiting any more (sent, replaced or over).
    public func cancelWakePlay(deviceID: String, id: String) async throws -> Bool {
        var request = request("DELETE", ["remote", "wake", deviceID, "plays", id])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, http) = try await performAnyStatus(request)
        if http.statusCode == 404 { return false }
        guard (200..<300).contains(http.statusCode) else {
            throw LobbyError.from(status: http.statusCode, data: data, headers: http)
        }
        return true
    }

    /// `PATCH /v1/me`: whether others may play on this device. nil: as the platform has it.
    public func setIsTarget(_ isTarget: Bool?) async throws -> Device {
        struct Body: Encodable {
            var isTarget: Bool?
            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: Key.self)
                try container.encode(isTarget, forKey: .isTarget)
            }
            enum Key: String, CodingKey { case isTarget }
        }
        return try await send("PATCH", ["me"], body: Body(isTarget: isTarget))
    }

    /// `POST /v1/assets/{id}/airplay`: a path an AirPlay receiver can fetch this file under by
    /// itself, without the credential, for a while. Only at home.
    public func airPlayPass(assetID: String) async throws -> AirPlayPass {
        struct Body: Encodable {}
        return try await send("POST", ["assets", assetID, "airplay"], body: Body())
    }

    /// The same URL of this server under an AirPlay pass: `/v1/assets/…` becomes
    /// `<prefix>/assets/…`. nil for a URL that is not one of the file's.
    public func url(_ url: URL, under pass: AirPlayPass) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        let path = components.percentEncodedPath
        let own = base.percentEncodedPath + "/v1/"
        guard path.hasPrefix(own + "assets/"), pass.prefix.hasPrefix("/v1/") else { return nil }
        components.percentEncodedPath = base.percentEncodedPath + pass.prefix + "/" + path.dropFirst(own.count)
        return components.url
    }

    /// A post of the remote's: a refusal is a `RemoteRefusal` with the server's reason.
    func remote<Body: Encodable>(_ method: String, _ segments: [String], body: Body) async throws -> Data {
        var request = request(method, segments)
        request.httpBody = try LobbyJSON.encoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, http) = try await performAnyStatus(request)
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw LobbyError.from(status: http.statusCode, data: data, headers: http) }
            let envelope = try? JSONDecoder().decode(RefusalEnvelope.self, from: data)
            throw RemoteRefusal(
                status: http.statusCode, code: envelope?.error?.code, reason: envelope?.reason,
                message: envelope?.error?.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        return data
    }
}

/// `{ "error": { "code", "message" }, "reason" }`.
private struct RefusalEnvelope: Decodable {
    struct Body: Decodable {
        var code: String
        var message: String
    }

    var error: Body?
    var reason: String?
}

/// `POST /v1/assets/{id}/airplay`.
public struct AirPlayPass: Codable, Hashable, Sendable {
    /// Replaces `/v1` in the file's paths, e.g. `/v1/airplay/<pass>`.
    public var prefix: String
    public var expiresAt: Int64
    public var assetId: String

    public init(prefix: String, expiresAt: Int64, assetId: String) {
        self.prefix = prefix
        self.expiresAt = expiresAt
        self.assetId = assetId
    }
}
