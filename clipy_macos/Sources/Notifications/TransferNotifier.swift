import Foundation
import UserNotifications

/// Posts a system notification when a file transfer from a peer lands on
/// disk. Uses provisional authorization so no permission prompt interrupts
/// the user; if notifications are denied the post simply no-ops. Banner taps
/// are handled by SystemNotificationRouter, which reveals the file in Finder.
final class TransferNotifier {
    static let shared = TransferNotifier()

    private var authorizationRequested = false

    private init() {}

    func activate() {
        requestAuthorizationIfNeeded()
    }

    private func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.provisional, .alert, .sound]) { _, _ in }
    }

    func notifyFileReceived(name: String, sender: String, destination: URL) {
        activate()
        let content = UNMutableNotificationContent()
        content.title = L10n.t(.fileReceivedTitle)
        content.body = L10n.format(.fileReceivedBody, sender, name)
        content.sound = .default
        // The final path (post-dedupe rename), not the original file name.
        content.userInfo = ["filePath": destination.path]
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
}
