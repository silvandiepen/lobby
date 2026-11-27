// SPDX-License-Identifier: MPL-2.0

#if os(iOS) || os(macOS)
import Foundation
import LobbyKit
import LobbyPush

/// Tells a server where this device gets pushes, the way that server sends them
/// (docs/api.md, Push notifications; docs/decisions.md, "Push through a relay"):
///
/// - Through the relay: the device registers its token with the relay itself, with a ticket the
///   server's box signed, and gives the server only the relay's handle and a key of its own. The
///   key goes into the Keychain group the notification service extension reads, so that it can
///   show what the server sealed.
/// - Directly: the server gets the token, as before the relay. Also what a server from before
///   the relay is told.
struct PushRegistrar: Sendable {
    var keys: any PushKeyStore
    /// For the relay. Not the server's: the relay is somewhere else.
    var session: URLSession = .shared

    enum Outcome: Hashable, Sendable {
        case relay(handle: String)
        case direct
        case off
    }

    func register(
        token: Data, environment: PushEnvironment, serverID: String, client: LobbyClient
    ) async throws -> Outcome {
        let route: PushRoute
        do {
            route = try await client.pushRoute()
        } catch let error as LobbyError {
            // A server from before the relay takes the token.
            guard case .notFound = error else { throw error }
            route = .direct
        }
        switch route {
        case .off:
            return .off
        case .direct:
            try await client.registerPush(token: token, environment: environment)
            return .direct
        case .relay(let url, let ticket):
            let box = PushRelayClient.box(ofTicket: ticket)
            var saved = try await keys.registration(forServer: serverID) ?? PushRegistration(key: SealedPush.newKey())
            // The server got a new box (its keys were reset), or uses another relay: the old
            // handle goes, and so does the key it had.
            if let old = saved.handle, let oldBox = saved.box, oldBox != box || saved.relay != url {
                try? await PushRelayClient(url: saved.relay ?? url, session: session).forget(box: oldBox, handle: old)
                saved = PushRegistration(key: SealedPush.newKey())
            }
            let handle = try await PushRelayClient(url: url, session: session)
                .register(ticket: ticket, token: token, environment: environment)
            saved.handle = handle
            saved.box = box
            saved.relay = url
            saved.token = token.map { String(format: "%02x", $0) }.joined()
            // Kept before the server is told, so the first notification already opens.
            try await keys.setRegistration(saved, forServer: serverID)
            try await client.registerPush(handle: handle, key: saved.key, environment: environment)
            return .relay(handle: handle)
        }
    }

    /// Signed out, or removed: the relay forgets the handle, and this device the key.
    func forget(serverID: String) async {
        guard let saved = try? await keys.registration(forServer: serverID) else { return }
        if let handle = saved.handle, let box = saved.box, let relay = saved.relay {
            try? await PushRelayClient(url: relay, session: session).forget(box: box, handle: handle)
        }
        try? await keys.removeRegistration(forServer: serverID)
    }
}
#endif
