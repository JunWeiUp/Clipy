import AppKit
import Foundation
import UserNotifications

/// Sole owner of the UNUserNotificationCenter delegate. TransferNotifier and
/// NotificationManager used to assign themselves in turn, so whichever ran
/// last silently disabled the other's tap handling; both now route through
/// here (file-transfer banners reveal in Finder, mirrored phone notification
/// actions are forwarded to NotificationManager).
final class SystemNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SystemNotificationRouter()

    private static let fileNotificationIdentifierPrefix = "clipy.file."

    override private init() {
        super.init()
    }

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        if request.identifier.hasPrefix(Self.fileNotificationIdentifierPrefix) {
            revealFile(from: request.content.userInfo)
        } else {
            NotificationManager.shared.handleUserResponse(response)
        }
        completionHandler()
    }

    private func revealFile(from userInfo: [AnyHashable: Any]) {
        guard let path = userInfo["filePath"] as? String else { return }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            FilePathDisplay.revealInFinder(urls: [url])
        } else {
            // The file was moved or deleted after landing; still take the
            // user to the receive folder.
            NSWorkspace.shared.open(SyncManager.fileReceiveDirectory())
        }
    }
}
