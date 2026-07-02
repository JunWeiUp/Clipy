import Foundation
import UserNotifications

final class DeviceCollectorManager {
    static let shared = DeviceCollectorManager()

    private let storageFileName = "device_collector_events.jsonl"
    private let maxEvents = 5000
    private let duplicateNotificationWindowMs: TimeInterval = 30_000
    private let duplicateSmsWindowMs: TimeInterval = 5_000
    private let duplicateLocationDistanceMeters = 50.0
    private let duplicateLocationWindowMs: TimeInterval = 60_000

    private(set) var events: [CollectorEvent] = []
    var onEventsChanged: (([CollectorEvent]) -> Void)?

    private var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ClipyClone", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(storageFileName)
    }

    private init() {
        loadFromDisk()
    }

    func handleRemoteEvent(_ json: String, from deviceId: String) {
        guard PreferencesManager.shared.isCollectorSyncEnabled else { return }
        guard let data = json.data(using: .utf8),
              var event = try? JSONDecoder().decode(CollectorEvent.self, from: data) else {
            appLog("DeviceCollectorManager: failed to decode collector event", level: .error)
            return
        }

        if !isCategoryEnabled(event.category) { return }
        if isDuplicate(event) { return }

        if event.deviceId.isEmpty {
            event = CollectorEvent(
                id: event.id,
                category: event.category,
                timestamp: event.timestamp,
                deviceId: deviceId,
                payload: event.payload
            )
        }

        events.insert(event, at: 0)
        if events.count > maxEvents {
            events = Array(events.prefix(maxEvents))
            rewriteStorage()
        } else {
            appendToStorage(event)
        }

        notifyChanged()
        bridgeToSpecializedManagers(event)
        appLog("DeviceCollectorManager: received \(event.category) from \(deviceId)")
    }

    func events(matching category: CollectorCategory?) -> [CollectorEvent] {
        guard let category else { return events }
        return events.filter { $0.category == category.rawValue }
    }

    func searchEvents(query: String, category: CollectorCategory?) -> [CollectorEvent] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = events(matching: category)
        guard !trimmed.isEmpty else { return base }
        return base.filter { event in
            if event.category.lowercased().contains(trimmed) { return true }
            if event.deviceId.lowercased().contains(trimmed) { return true }
            return event.payload.values.contains { $0.lowercased().contains(trimmed) }
        }
    }

    func clearAll() {
        events.removeAll()
        try? FileManager.default.removeItem(at: storageURL)
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

    private func isDuplicate(_ incoming: CollectorEvent) -> Bool {
        switch incoming.category {
        case CollectorCategory.notification.rawValue:
            return events.contains { existing in
                guard existing.category == incoming.category else { return false }
                guard abs(existing.timestamp - incoming.timestamp) <= duplicateNotificationWindowMs else { return false }
                if let key = incoming.payload["notificationKey"], !key.isEmpty {
                    return existing.payload["notificationKey"] == key
                }
                return existing.payload["title"] == incoming.payload["title"] &&
                    existing.payload["body"] == incoming.payload["body"] &&
                    existing.payload["packageName"] == incoming.payload["packageName"]
            }
        case CollectorCategory.sms.rawValue:
            return events.contains { existing in
                guard existing.category == incoming.category else { return false }
                guard abs(existing.timestamp - incoming.timestamp) <= duplicateSmsWindowMs else { return false }
                return existing.payload["address"] == incoming.payload["address"] &&
                    existing.payload["body"] == incoming.payload["body"]
            }
        case CollectorCategory.call.rawValue:
            return events.contains { existing in
                guard existing.category == incoming.category else { return false }
                guard existing.payload["phoneNumber"] == incoming.payload["phoneNumber"] else { return false }
                guard existing.payload["state"] == incoming.payload["state"] else { return false }
                return abs(existing.timestamp - incoming.timestamp) <= 2_000
            }
        case CollectorCategory.callLog.rawValue:
            if let logId = incoming.payload["logId"], !logId.isEmpty {
                return events.contains { $0.category == incoming.category && $0.payload["logId"] == logId }
            }
            return events.contains { existing in
                guard existing.category == incoming.category else { return false }
                return existing.payload["phoneNumber"] == incoming.payload["phoneNumber"] &&
                    existing.payload["type"] == incoming.payload["type"] &&
                    existing.payload["date"] == incoming.payload["date"]
            }
        case CollectorCategory.clipboard.rawValue:
            if let hash = incoming.payload["hash"], !hash.isEmpty {
                return events.contains { $0.category == incoming.category && $0.payload["hash"] == hash }
            }
            return false
        case CollectorCategory.location.rawValue:
            guard let lat = Double(incoming.payload["latitude"] ?? ""),
                  let lon = Double(incoming.payload["longitude"] ?? "") else { return false }
            return events.contains { existing in
                guard existing.category == incoming.category else { return false }
                guard abs(existing.timestamp - incoming.timestamp) <= duplicateLocationWindowMs else { return false }
                guard let existingLat = Double(existing.payload["latitude"] ?? ""),
                      let existingLon = Double(existing.payload["longitude"] ?? "") else { return false }
                return distanceMeters(lat1: lat, lon1: lon, lat2: existingLat, lon2: existingLon) < duplicateLocationDistanceMeters
            }
        case CollectorCategory.system.rawValue:
            return events.contains { existing in
                guard existing.category == incoming.category else { return false }
                return existing.payload["batteryLevel"] == incoming.payload["batteryLevel"] &&
                    existing.payload["isCharging"] == incoming.payload["isCharging"] &&
                    existing.payload["networkType"] == incoming.payload["networkType"] &&
                    existing.payload["ssid"] == incoming.payload["ssid"]
            }
        default:
            return false
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
        onEventsChanged?(events)
        NotificationCenter.default.post(name: .deviceCollectorEventsDidChange, object: nil)
    }

    private func loadFromDisk() {
        guard let data = try? String(contentsOf: storageURL, encoding: .utf8) else { return }
        let loaded = data
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> CollectorEvent? in
                guard let lineData = String(line).data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(CollectorEvent.self, from: lineData)
            }
        events = loaded.reversed()
    }

    private func appendToStorage(_ event: CollectorEvent) {
        guard let data = try? JSONEncoder().encode(event),
              let line = String(data: data, encoding: .utf8) else { return }
        let url = storageURL
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                if let bytes = "\(line)\n".data(using: .utf8) {
                    handle.write(bytes)
                }
                try? handle.close()
            }
        } else {
            try? "\(line)\n".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func rewriteStorage() {
        let lines = events.reversed().compactMap { event -> String? in
            guard let data = try? JSONEncoder().encode(event) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        try? lines.joined(separator: "\n").appending("\n").write(to: storageURL, atomically: true, encoding: .utf8)
    }

    private func distanceMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let earthRadius = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) +
            cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadius * c
    }
}
