import Foundation
import AppKit
import UserNotifications

extension Notification.Name {
    static let phoneNotificationsDidChange = Notification.Name("phoneNotificationsDidChange")
}

class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private let storageFile: String = "notifications.json"
    private let maxNotifications = 1000
    private let duplicateNotificationWindowMilliseconds: TimeInterval = 30_000

    var notifications: [NotificationEntry] = []
    var allowedPackages: Set<String> = []
    var notificationSyncEnabled: Bool = false
    var notificationSound: Bool = true

    var onNotificationsChanged: (([NotificationEntry]) -> Void)?

    private func notifyNotificationsChanged() {
        onNotificationsChanged?(notifications)
        NotificationCenter.default.post(name: .phoneNotificationsDidChange, object: nil)
    }

    private override init() {
        super.init()
        loadFromDisk()
        loadPreferences()
        setupNotificationCenter()
    }

    // MARK: - Models

    struct NotificationEntry: Codable, Identifiable {
        let id: String
        let notificationKey: String?
        let packageName: String
        let appName: String
        let title: String
        let subtitle: String?
        let body: String
        let postTime: TimeInterval
        let groupKey: String?
        let isClearable: Bool
        let extras: [String: String]?

        enum CodingKeys: String, CodingKey {
            case id, notificationKey, packageName, appName, title, subtitle, body, postTime, groupKey, isClearable, extras
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            notificationKey = try container.decodeIfPresent(String.self, forKey: .notificationKey)
            packageName = try container.decode(String.self, forKey: .packageName)
            appName = try container.decode(String.self, forKey: .appName)
            title = try container.decode(String.self, forKey: .title)
            subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
            body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
            postTime = try container.decode(TimeInterval.self, forKey: .postTime)
            groupKey = try container.decodeIfPresent(String.self, forKey: .groupKey)
            isClearable = try container.decodeIfPresent(Bool.self, forKey: .isClearable) ?? true
            extras = try container.decodeIfPresent([String: String].self, forKey: .extras)
        }
    }

    struct NotificationDismissRequest: Codable {
        let packageName: String
        let groupKey: String?
        let notificationKey: String?
    }

    // MARK: - UNUserNotificationCenter Setup

    private func setupNotificationCenter() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let dismissAction = UNNotificationAction(
            identifier: "DISMISS_ON_PHONE",
            title: L10n.t(.dismissOnPhone),
            options: []
        )
        let clearAllAction = UNNotificationAction(
            identifier: "CLEAR_ALL_ON_PHONE",
            title: L10n.t(.clearAllOnPhone),
            options: [.destructive]
        )
        let copyAction = UNNotificationAction(
            identifier: "COPY_NOTIFICATION_CONTENT",
            title: L10n.t(.copyContent),
            options: []
        )

        let category = UNNotificationCategory(
            identifier: "NOTIFICATION_SYNC",
            actions: [copyAction, dismissAction, clearAllAction],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])

        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                appLog("Notification permission error: \(error)", level: .warning)
            }
        }
    }

    // MARK: - Handle Remote Notifications

    func handleRemoteNotification(_ decrypted: String, from senderDevice: String) {
        guard notificationSyncEnabled else { return }

        guard let data = decrypted.data(using: .utf8),
              let entry = try? JSONDecoder().decode(NotificationEntry.self, from: data) else {
            appLog("NotificationManager: failed to decode remote notification", level: .error)
            return
        }

        if isEmptyNotification(entry) {
            return
        }

        if !allowedPackages.isEmpty && !allowedPackages.contains(entry.packageName) {
            return
        }

        let accepted = upsertNotification(entry)
        if accepted {
            showSystemNotification(entry)
        }
        appLog("NotificationManager: received from \(senderDevice): \(entry.title)")
    }

    func handleRemoteDismiss(_ decrypted: String) {
        guard let data = decrypted.data(using: .utf8),
              let request = try? JSONDecoder().decode(NotificationDismissRequest.self, from: data) else {
            return
        }

        notifications.removeAll { entry in
            entry.packageName == request.packageName &&
            (request.notificationKey == nil || entry.notificationKey == request.notificationKey)
        }
        saveToDisk()
        notifyNotificationsChanged()
    }

    func handleRemoteClearAll() {
        notifications.removeAll()
        saveToDisk()
        notifyNotificationsChanged()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    // MARK: - Notification Management

    @discardableResult
    private func upsertNotification(_ entry: NotificationEntry) -> Bool {
        guard !isEmptyNotification(entry) else { return false }

        if let index = notifications.firstIndex(where: { $0.id == entry.id }) {
            notifications[index] = entry
            let updated = notifications.remove(at: index)
            notifications.insert(updated, at: 0)
            saveToDisk()
            notifyNotificationsChanged()
            return true
        } else if let duplicateIndex = notifications.firstIndex(where: { isDuplicateNotification($0, entry) }) {
            let duplicate = notifications.remove(at: duplicateIndex)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [duplicate.id])
            notifications.insert(entry, at: 0)
            saveToDisk()
            notifyNotificationsChanged()
            return true
        } else {
            notifications.insert(entry, at: 0)
            if notifications.count > maxNotifications {
                notifications.removeLast()
            }
        }
        saveToDisk()
        notifyNotificationsChanged()
        return true
    }

    private func isEmptyNotification(_ entry: NotificationEntry) -> Bool {
        entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (entry.subtitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (entry.extras ?? [:]).values.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func isDuplicateNotification(_ existing: NotificationEntry, _ incoming: NotificationEntry) -> Bool {
        guard existing.packageName == incoming.packageName else { return false }
        guard abs(existing.postTime - incoming.postTime) <= duplicateNotificationWindowMilliseconds else { return false }

        if let existingKey = existing.notificationKey,
           let incomingKey = incoming.notificationKey,
           existingKey == incomingKey {
            return true
        }

        return existing.title.trimmingCharacters(in: .whitespacesAndNewlines) == incoming.title.trimmingCharacters(in: .whitespacesAndNewlines) &&
        (existing.subtitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == (incoming.subtitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines) &&
        existing.body.trimmingCharacters(in: .whitespacesAndNewlines) == incoming.body.trimmingCharacters(in: .whitespacesAndNewlines) &&
        existing.groupKey == incoming.groupKey
    }

    func showSystemNotification(_ entry: NotificationEntry) {
        let content = UNMutableNotificationContent()
        content.title = entry.appName
        content.subtitle = entry.title
        if !entry.body.isEmpty {
            content.body = entry.body
        }
        content.categoryIdentifier = "NOTIFICATION_SYNC"
        content.sound = notificationSound ? .default : nil
        content.userInfo = [
            "notificationId": entry.id,
            "packageName": entry.packageName,
        ]

        let request = UNNotificationRequest(
            identifier: entry.id,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                appLog("Failed to show notification: \(error)", level: .error)
            }
        }
    }

    // MARK: - Actions

    func dismissOnRemote(_ entry: NotificationEntry) {
        let request = NotificationDismissRequest(
            packageName: entry.packageName,
            groupKey: entry.groupKey,
            notificationKey: entry.notificationKey
        )
        guard let content = try? JSONEncoder().encode(request),
              let json = String(data: content, encoding: .utf8) else { return }

        SyncManager.shared.broadcastNotificationMessage(type: "notification/dismiss", content: json, hash: "")
    }

    func clearAllOnRemote() {
        SyncManager.shared.broadcastNotificationMessage(type: "notification/clear_all", content: "{}", hash: "")
    }

    func removeNotification(_ id: String) {
        notifications.removeAll { $0.id == id }
        saveToDisk()
        notifyNotificationsChanged()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    func clearAllLocal() {
        notifications.removeAll()
        saveToDisk()
        notifyNotificationsChanged()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    // MARK: - Sync Config

    func syncAllowedPackagesToRemote() {
        let config: [String: Any] = ["allowedPackages": Array(allowedPackages)]
        guard let content = try? JSONSerialization.data(withJSONObject: config),
              let json = String(data: content, encoding: .utf8) else { return }
        SyncManager.shared.broadcastNotificationMessage(type: "notification/config", content: json, hash: "")
    }

    // MARK: - Persistence

    func saveToDisk() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("ClipyClone")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(storageFile)

        do {
            let data = try JSONEncoder().encode(notifications)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            appLog("NotificationManager: failed to save: \(error)", level: .error)
        }
    }

    func loadFromDisk() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let fileURL = appSupport.appendingPathComponent("ClipyClone/\(storageFile)")

        guard let data = try? Data(contentsOf: fileURL) else { return }
        let loaded = (try? JSONDecoder().decode([NotificationEntry].self, from: data)) ?? []
        notifications = []
        for entry in loaded.reversed() {
            upsertNotification(entry)
        }
        if notifications.count != loaded.count {
            saveToDisk()
        }
    }

    private func loadPreferences() {
        notificationSyncEnabled = UserDefaults.standard.bool(forKey: "notificationSyncEnabled")
        notificationSound = UserDefaults.standard.bool(forKey: "notificationSound")
        if let packages = UserDefaults.standard.stringArray(forKey: "notificationAllowedPackages") {
            allowedPackages = Set(packages)
        }
    }

    func savePreferences() {
        UserDefaults.standard.set(notificationSyncEnabled, forKey: "notificationSyncEnabled")
        UserDefaults.standard.set(notificationSound, forKey: "notificationSound")
        UserDefaults.standard.set(Array(allowedPackages), forKey: "notificationAllowedPackages")
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let notificationId = userInfo["notificationId"] as? String

        switch response.actionIdentifier {
        case "DISMISS_ON_PHONE":
            if let id = notificationId {
                let entry = notifications.first { $0.id == id }
                if let entry = entry {
                    dismissOnRemote(entry)
                }
            }
        case "CLEAR_ALL_ON_PHONE":
            clearAllOnRemote()
        case "COPY_NOTIFICATION_CONTENT":
            if let id = notificationId, let entry = notifications.first(where: { $0.id == id }) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(entry.body, forType: .string)
            }
        default:
            break
        }

        completionHandler()
    }
}
