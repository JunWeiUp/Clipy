import Foundation
import UserNotifications

/// Posts a system notification when a file transfer from a peer lands on
/// disk. Uses provisional authorization so no permission prompt interrupts
/// the user; if notifications are denied the post simply no-ops.
final class TransferNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TransferNotifier()

    private var authorizationRequested = false

    override private init() {
        super.init()
    }

    func activate() {
        UNUserNotificationCenter.current().delegate = self
        requestAuthorizationIfNeeded()
    }

    private func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.provisional, .alert, .sound]) { _, _ in }
    }

    func notifyFileReceived(name: String, sender: String) {
        activate()
        let content = UNMutableNotificationContent()
        content.title = L10n.t(.fileReceivedTitle)
        content.body = L10n.format(.fileReceivedBody, sender, name)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "clipy.file.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                appLog("Transfer notification failed: \(error)", level: .warning)
            }
        }
    }

    /// The app is a menu-bar (LSUIElement) process that is often active;
    /// without this delegate method macOS would suppress the banner.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
