import Foundation
import UserNotifications

/// Posts a system notification when a file transfer from a peer lands on
/// disk. Requests normal alert authorization so receipts can show banners;
/// if notifications are denied the post simply no-ops. Banner taps
/// are handled by SystemNotificationRouter, which reveals the file in Finder.
final class TransferNotifier {
    static let shared = TransferNotifier()

    private init() {}

    func notifyFileReceived(name: String, sender: String, destination: URL) {
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
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            guard granted else {
                if let error { appLog("Transfer notification authorization failed: \(error)", level: .warning) }
                return
            }
            center.add(request) { error in
                if let error { appLog("Transfer notification failed: \(error)", level: .warning) }
            }
        }
    }
}
