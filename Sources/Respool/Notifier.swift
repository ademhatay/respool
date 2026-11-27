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
        // An Open button on the banner, which opens the chat where it belongs.
        let open = UNNotificationAction(identifier: Self.openAction, title: L10n.open, options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.sessionCategory, actions: [open], intentIdentifiers: [])
        ])
    }

    private static let sessionCategory = "session"
    private static let openAction = "open"

    func post(sessionID: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["sessionID": sessionID]
        content.categoryIdentifier = Self.sessionCategory
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
        // A click on the banner and its Open button both open the chat; dismissing it does not.
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier,
              let sessionID = response.notification.request.content.userInfo["sessionID"] as? String else { return }
        await MainActor.run { onOpen(sessionID) }
    }
}
