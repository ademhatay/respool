import AppKit
import UserNotifications

/// Posts a system notification when a session needs you, and reports which one was clicked.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let onOpen: (String) -> Void

    init(onOpen: @escaping (String) -> Void) {
        self.onOpen = onOpen
        super.init()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(sessionID: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["sessionID": sessionID]
        // One notification per session: a newer state replaces the older one.
        let request = UNNotificationRequest(identifier: sessionID, content: content, trigger: nil)
        center.add(request)
    }

    func clear(sessionID: String) {
        center.removeDeliveredNotifications(withIdentifiers: [sessionID])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let sessionID = response.notification.request.content.userInfo["sessionID"] as? String else { return }
        await MainActor.run { onOpen(sessionID) }
    }
}
