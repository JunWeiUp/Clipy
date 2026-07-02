import Foundation
import UserNotifications

final class DeviceCollectorManager {
    static let shared = DeviceCollectorManager()

    private let maxEvents = 5000
    private let repository = DeviceCollectorRepository.shared

    var onEventsChanged: (() -> Void)?

    private init() {}

    var eventCount: Int {
        repository.count()
    }

    func handleRemoteEvent(_ json: String, from deviceId: String) {
        guard PreferencesManager.shared.isCollectorSyncEnabled else { return }
        guard let data = json.data(using: .utf8),
              var event = try? JSONDecoder().decode(CollectorEvent.self, from: data) else {
            appLog("DeviceCollectorManager: failed to decode collector event", level: .error)
            return
        }

        if !isCategoryEnabled(event.category) { return }
        if repository.isDuplicate(event) { return }

        if event.deviceId.isEmpty {
            event = CollectorEvent(
                id: event.id,
                category: event.category,
                timestamp: event.timestamp,
                deviceId: deviceId,
                payload: event.payload
            )
        }

        guard repository.insert(event) else { return }
        repository.trimToLimit(maxEvents)

        notifyChanged()
        bridgeToSpecializedManagers(event)
        appLog("DeviceCollectorManager: received \(event.category) from \(deviceId)")
    }

    func fetchEvents(matching category: CollectorCategory? = nil) -> [CollectorEvent] {
        repository.fetch(category: category)
    }

    func searchEvents(query: String, category: CollectorCategory?, offset: Int = 0, limit: Int = 200) -> [CollectorEvent] {
        repository.search(query: query, category: category, offset: offset, limit: limit)
    }

    func clearAll() {
        _ = repository.deleteAll()
        notifyChanged()
    }

    // MARK: - Private

    private func isCategoryEnabled(_ category: String) -> Bool {
        switch category {
        case CollectorCategory.notification.rawValue:
            return PreferencesManager.shared.isCollectorNotificationEnabled
        case CollectorCategory.sms.rawValue:
            return PreferencesManager.shared.isCollectorSmsEnabled
        case CollectorCategory.call.rawValue:
            return PreferencesManager.shared.isCollectorCallEnabled
        case CollectorCategory.callLog.rawValue:
            return PreferencesManager.shared.isCollectorCallLogEnabled
        case CollectorCategory.clipboard.rawValue:
            return PreferencesManager.shared.isCollectorClipboardEnabled
        case CollectorCategory.location.rawValue:
            return PreferencesManager.shared.isCollectorLocationEnabled
        case CollectorCategory.system.rawValue:
            return PreferencesManager.shared.isCollectorSystemEnabled
        default:
            return true
        }
    }

    private func bridgeToSpecializedManagers(_ event: CollectorEvent) {
        guard event.category == CollectorCategory.notification.rawValue else {
            maybeShowAlert(for: event)
            return
        }

        let notificationJSON: [String: Any] = [
            "id": event.id,
            "notificationKey": event.payload["notificationKey"] as Any,
            "packageName": event.payload["packageName"] ?? "",
            "appName": event.payload["appName"] ?? "",
            "title": event.payload["title"] ?? "",
            "subtitle": event.payload["subtitle"] as Any,
            "body": event.payload["body"] ?? "",
            "postTime": event.timestamp,
            "groupKey": event.payload["groupKey"] as Any,
            "isClearable": (event.payload["isClearable"] ?? "true") == "true",
        ]

        if let data = try? JSONSerialization.data(withJSONObject: notificationJSON),
           let json = String(data: data, encoding: .utf8) {
            NotificationManager.shared.handleRemoteNotification(json, from: event.deviceId)
        }
    }

    private func maybeShowAlert(for event: CollectorEvent) {
        guard PreferencesManager.shared.isCollectorAlertEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        switch event.collectorCategory {
        case .sms:
            content.title = L10n.t(.collectorCategorySms)
            content.body = "\(event.payload["address"] ?? ""): \(event.payload["body"] ?? "")"
        case .call:
            content.title = L10n.t(.collectorCategoryCall)
            content.body = "\(event.payload["phoneNumber"] ?? "") - \(event.payload["state"] ?? "")"
        default:
            return
        }
        let request = UNNotificationRequest(identifier: event.id, content: content, trigger: nil)
        center.add(request)
    }

    private func notifyChanged() {
        onEventsChanged?()
        NotificationCenter.default.post(name: .deviceCollectorEventsDidChange, object: nil)
    }
}
