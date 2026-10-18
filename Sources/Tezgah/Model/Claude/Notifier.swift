import AppKit
import UserNotifications

/// macOS notifications for Claude sessions. Clicking one brings the session's tab to the front.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Called with the tab id of a clicked notification.
    var onOpen: ((UUID) -> Void)?
    /// "İzin Ver" / "Bir Daha Sorma" / "Reddet" on a permission notification: the tab, the
    /// request it was shown for, and the answer. Returns false when the request is gone.
    var onAnswer: ((UUID, Int, Answer) -> Bool)?

    enum Answer: String {
        case allow, always, deny
    }

    enum Category: String {
        /// Yes / No.
        case permission
        /// Yes / Yes, don't ask again / No.
        case permissionWithAlways
    }

    /// Notifications need a real .app bundle; a bare executable (swift run, tests) has none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
    }

    func setUp() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let allow = UNNotificationAction(identifier: Answer.allow.rawValue, title: "İzin Ver")
        let always = UNNotificationAction(identifier: Answer.always.rawValue, title: "Bir Daha Sorma")
        let deny = UNNotificationAction(identifier: Answer.deny.rawValue, title: "Reddet", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.permission.rawValue, actions: [allow, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.permissionWithAlways.rawValue, actions: [allow, always, deny], intentIdentifiers: []),
        ])
    }

    /// Posts or replaces the notification for a tab, so each session shows at most one.
    func post(title: String, body: String, tabID: UUID, category: Category? = nil, request: Int = 0) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["tab": tabID.uuidString, "request": request]
        if let category { content.categoryIdentifier = category.rawValue }
        center.add(UNNotificationRequest(identifier: tabID.uuidString, content: content, trigger: nil))
    }

    func clear(tabID: UUID) {
        center?.removeDeliveredNotifications(withIdentifiers: [tabID.uuidString])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let tab = (userInfo["tab"] as? String).flatMap(UUID.init)
        let request = (userInfo["request"] as? NSNumber)?.intValue ?? 0
        let answer = Answer(rawValue: response.actionIdentifier)
        Task { @MainActor in
            // Answered from the notification: stay where the user is, unless the dialog moved on.
            if let tab, let answer, Notifier.shared.onAnswer?(tab, request, answer) == true { return }
            NSApp.activate(ignoringOtherApps: true)
            if let tab { Notifier.shared.onOpen?(tab) }
        }
        completionHandler()
    }

    /// Tezgah decides itself when a notification is worth showing, so show it even when active.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
