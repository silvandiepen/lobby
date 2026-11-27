// SPDX-License-Identifier: MPL-2.0

import LobbyPush
import UserNotifications

/// Opens what a server sealed for the lock screen (docs/decisions.md, "Push through a relay"). The
/// push relay and Apple deliver a generic "A request is waiting"; this puts the server's own words
/// in its place, with Watch, Listen and No, using the key the app made for that server. What it
/// cannot open is shown as it came. Answers go from the app to the server directly, never through
/// the relay.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        // A Keychain read and a decryption: done long before the system's time is up.
        let keys = (try? KeychainPushKeyStore.shared().keysNow()) ?? []
        SealedPush.reveal(content, keys: keys)
        contentHandler(content)
    }
}
