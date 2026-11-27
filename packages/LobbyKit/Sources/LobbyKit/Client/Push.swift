// SPDX-License-Identifier: MPL-2.0

import CryptoKit
import Foundation

// Pushes through the relay (docs/api.md, "Push notifications"; docs/decisions.md, "Push through a
// relay"): the server says how this device registers, the device registers its token with the relay
// itself, and gives the server only the relay's handle and a key of its own for what the server
// seals.

/// How a server pushes, from `GET /v1/me/push`.
public enum PushRoute: Hashable, Sendable {
    /// Through the relay: register there with this ticket the server's box signed.
    case relay(url: URL, ticket: String)
    /// With a key of the server's own: it is given the token.
    case direct
    case off
}

extension LobbyClient {
    /// `GET /v1/me/push`. A server from before the relay answers `404`: that one takes a token.
    public func pushRoute() async throws -> PushRoute {
        struct Answer: Decodable {
            struct Relay: Decodable {
                var url: URL
                var ticket: String
            }
            var mode: String
            var relay: Relay?
        }
        let answer: Answer = try await get(["me", "push"])
        switch answer.mode {
        case "relay":
            guard let relay = answer.relay else { throw LobbyError.invalidResponse("push relay without address") }
            return .relay(url: relay.url, ticket: relay.ticket)
        case "direct": return .direct
        default: return .off
        }
    }

    /// `PUT /v1/me/push` in relay mode: the relay's handle, never the token, and the key the
    /// server seals with for this device.
    public func registerPush(handle: String, key: Data, environment: PushEnvironment) async throws {
        let body: [String: JSONValue] = [
            "handle": .string(handle),
            "key": .string(key.base64URLString),
            "environment": .string(environment.rawValue),
        ]
        var request = request("PUT", ["me", "push"])
        request.httpBody = try LobbyJSON.encoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await perform(request)
    }
}

/// The push relay, as the app speaks to it: no credential, nothing of Lobby but a ticket.
public struct PushRelayClient: Sendable {
    public let url: URL
    private let session: URLSession

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    /// The box that signed a ticket (`<box key>.<until>.<signature>`): the hash of its key, as
    /// the relay and the introducer name it. Nil for what is no ticket.
    public static func box(ofTicket ticket: String) -> String? {
        let parts = ticket.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let key = Data(base64URLText: String(parts[0])), key.count == 32 else { return nil }
        return Data(SHA256.hash(data: key)).base64URLString
    }

    /// `POST /v1/tokens`: this device's token, for the box that signed the ticket.
    ///
    /// - Returns: The handle the server sends to.
    public func register(ticket: String, token: Data, environment: PushEnvironment) async throws -> String {
        struct Answer: Decodable { var handle: String }
        let body: [String: String] = [
            "ticket": ticket,
            "token": token.map { String(format: "%02x", $0) }.joined(),
            "environment": environment.rawValue,
        ]
        let data = try await post("v1/tokens", body)
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            throw LobbyError.invalidResponse("no handle from the push relay")
        }
        return answer.handle
    }

    /// `POST /v1/tokens/forget`: signed out, or removed. The relay says the same whether it knew it.
    public func forget(box: String, handle: String) async throws {
        _ = try await post("v1/tokens/forget", ["box": box, "handle": handle])
    }

    private func post(_ path: String, _ body: [String: String]) async throws -> Data {
        var request = URLRequest(url: url.appending(path: path))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw LobbyError.unreachable(error.code)
        }
        guard let http = response as? HTTPURLResponse else { throw LobbyError.invalidResponse("not HTTP") }
        guard (200..<300).contains(http.statusCode) else {
            throw LobbyError.server(status: http.statusCode, code: nil, message: "The push relay refused.")
        }
        return data
    }
}

extension Data {
    var base64URLString: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLText text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        self = data
    }
}
