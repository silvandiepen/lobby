// SPDX-License-Identifier: MPL-2.0
#if os(iOS) || os(macOS)
import Foundation
import LobbyKit
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A child's question, and a device that waits to be let in, on a grown-up's lock screen: the
/// server's push (docs/operations.md, Push), and a notice of this app's own for what the live
/// channel says while the app is in the background. Watch, Listen and No answer from there.
@MainActor
final class PushCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushCenter()

    nonisolated static let kidsCategory = "LOBBY_KIDS_QUESTION"
    nonisolated static let watch = "LOBBY_KIDS_WATCH"
    nonisolated static let listen = "LOBBY_KIDS_LISTEN"
    nonisolated static let no = "LOBBY_KIDS_NO"

    /// The device token Apple handed over, once it did.
    private(set) var token: Data?
    private weak var servers: ServersModel?
    private var started = false

    #if DEBUG
    nonisolated static let environment = PushEnvironment.development
    #else
    nonisolated static let environment = PushEnvironment.production
    #endif

    /// The answer an action of a notification stands for.
    nonisolated static func answer(for action: String) -> KidsAnswer? {
        switch action {
        case watch: .watch
        case listen: .listen
        case no: .no
        default: nil
        }
    }

    /// Watch, Listen and No under a child's question. Watch and Listen let the child in, so they
    /// ask for the device to be unlocked first: a locked phone in the child's hands must not
    /// answer yes. No only keeps things as they are, so it works from the lock screen.
    nonisolated static func kidsQuestionCategory() -> UNNotificationCategory {
        let actions = [
            UNNotificationAction(identifier: watch, title: "Watch", options: [.authenticationRequired]),
            UNNotificationAction(identifier: listen, title: "Listen", options: [.authenticationRequired]),
            UNNotificationAction(identifier: no, title: "No", options: [.destructive]),
        ]
        return UNNotificationCategory(identifier: kidsCategory, actions: actions, intentIdentifiers: [])
    }

    func start(servers: ServersModel) {
        self.servers = servers
        guard !started else { return }
        started = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([Self.kidsQuestionCategory()])
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else {
                // Notifications are off for Lobby: the server forgets where it pushed to.
                await servers.active.environment.unregisterPush()
                return
            }
            #if os(iOS)
            UIApplication.shared.registerForRemoteNotifications()
            #else
            NSApplication.shared.registerForRemoteNotifications()
            #endif
        }
    }

    /// Apple gave this device a token: the server in use hears it.
    func registered(_ token: Data) {
        self.token = token
        Task { await servers?.active.registerPushIfNeeded() }
    }

    /// A question the live channel brought while the app is behind another one.
    func notify(_ request: KidsRequest) {
        let content = UNMutableNotificationContent()
        let name = request.viewer?.name ?? "A child"
        content.title = request.title.map { "\(name) wants to watch \($0.title)" } ?? "\(name) wants to open Lobby"
        content.body = "Watch, Listen or No"
        content.categoryIdentifier = Self.kidsCategory
        content.threadIdentifier = "kids-\(request.profileId)"
        content.sound = .default
        content.userInfo = ["lobby": ["kind": "kidsRequest", "requestId": request.id]]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: request.id, content: content, trigger: nil))
    }

    /// A question that was answered, here or elsewhere, leaves the lock screen.
    func forget(_ requestID: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [requestID])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo["lobby"] as? [String: Any]
        guard let requestID = info?["requestId"] as? String, let answer = Self.answer(for: response.actionIdentifier) else { return }
        let serverID = info?["serverId"] as? String
        await MainActor.run { [weak self] in
            guard let app = self?.servers?.active else { return }
            // Only the server the question came from can take its answer.
            if let serverID, let known = app.serverInfo?.id, known != serverID { return }
            Task { await app.answerKids(requestID, answer) }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // In front, the app shows the question itself; also one that came sealed through the
        // relay and that nothing on this device opened (the Mac has no notification service).
        let content = notification.request.content
        let unopened = (content.userInfo["lobby"] as? [String: Any])?["s"] != nil
        return content.categoryIdentifier == Self.kidsCategory || unopened ? [] : [.banner, .sound]
    }
}
#endif
