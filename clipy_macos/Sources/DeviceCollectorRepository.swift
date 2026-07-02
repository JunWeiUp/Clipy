import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class DeviceCollectorRepository {
    static let shared = DeviceCollectorRepository()

    private let legacyJSONLURL: URL
    private var db: OpaquePointer? { AppDatabase.shared.db }
    private var queue: DispatchQueue { AppDatabase.shared.queue }

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipyClone", isDirectory: true)
        legacyJSONLURL = appSupport.appendingPathComponent("device_collector_events.jsonl")
        _ = AppDatabase.shared
        migrateFromLegacyJSONLIfNeeded()
    }

    func count() -> Int {
        queue.sync { countLocked() }
    }

    func insert(_ event: CollectorEvent) -> Bool {
        queue.sync { insertLocked(event) }
    }

    func deleteAll() -> Bool {
        queue.sync {
            guard let db else { return false }
            return sqlite3_exec(db, "DELETE FROM collector_events", nil, nil, nil) == SQLITE_OK
        }
    }

    func trimToLimit(_ maxItems: Int) {
        queue.sync {
            guard maxItems > 0, let db else { return }
            let sql = """
            DELETE FROM collector_events
            WHERE rowid NOT IN (
                SELECT rowid FROM collector_events
                ORDER BY timestamp DESC
                LIMIT ?
            )
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(maxItems))
            _ = sqlite3_step(stmt)
        }
    }

    func fetch(category: CollectorCategory? = nil, limit: Int? = nil, offset: Int = 0) -> [CollectorEvent] {
        queue.sync {
            fetchLocked(category: category, query: nil, offset: max(0, offset), limit: limit)
        }
    }

    func search(query: String, category: CollectorCategory?, offset: Int = 0, limit: Int = 200) -> [CollectorEvent] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return queue.sync {
            fetchLocked(category: category, query: trimmed.isEmpty ? nil : trimmed, offset: max(0, offset), limit: max(1, limit))
        }
    }

    func isDuplicate(_ incoming: CollectorEvent) -> Bool {
        queue.sync { isDuplicateLocked(incoming) }
    }

    private func migrateFromLegacyJSONLIfNeeded() {
        queue.sync {
            guard countLocked() == 0,
                  FileManager.default.fileExists(atPath: legacyJSONLURL.path),
                  let data = try? String(contentsOf: legacyJSONLURL, encoding: .utf8) else { return }

            let lines = data.split(separator: "\n", omittingEmptySubsequences: true)
            var migrated = 0
            for line in lines {
                guard let lineData = String(line).data(using: .utf8),
                      let event = try? JSONDecoder().decode(CollectorEvent.self, from: lineData) else { continue }
                if insertLocked(event) {
                    migrated += 1
                }
            }
            if migrated > 0 {
                let backupURL = legacyJSONLURL.deletingPathExtension().appendingPathExtension("jsonl.bak")
                try? FileManager.default.moveItem(at: legacyJSONLURL, to: backupURL)
                appLog("Collector migration complete: \(migrated) events", level: .info)
            }
        }
    }

    // MARK: - Locked operations

    private func countLocked() -> Int {
        guard let db else { return 0 }
        let sql = "SELECT COUNT(*) FROM collector_events"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    @discardableResult
    private func insertLocked(_ event: CollectorEvent) -> Bool {
        guard let db else { return false }
        let sql = """
        INSERT OR REPLACE INTO collector_events (id, category, timestamp, device_id, payload_json)
        VALUES (?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, event.id)
        bindText(stmt, 2, event.category)
        sqlite3_bind_double(stmt, 3, event.timestamp)
        bindText(stmt, 4, event.deviceId)
        bindText(stmt, 5, encodePayload(event.payload))
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func fetchLocked(category: CollectorCategory?, query: String?, offset: Int = 0, limit: Int? = nil) -> [CollectorEvent] {
        guard let db else { return [] }
        var sql = "SELECT id, category, timestamp, device_id, payload_json FROM collector_events"
        var conditions: [String] = []
        var bindValues: [(Int32, Any)] = []
        var bindIndex: Int32 = 1

        if let category {
            conditions.append("category = ?")
            bindValues.append((bindIndex, category.rawValue))
            bindIndex += 1
        }

        if let query, !query.isEmpty {
            let pattern = "%\(query.lowercased())%"
            conditions.append("""
            (LOWER(category) LIKE ?
             OR LOWER(device_id) LIKE ?
             OR LOWER(payload_json) LIKE ?)
            """)
            bindValues.append((bindIndex, pattern))
            bindIndex += 1
            bindValues.append((bindIndex, pattern))
            bindIndex += 1
            bindValues.append((bindIndex, pattern))
            bindIndex += 1
        }

        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY timestamp DESC"
        if let limit {
            sql += " LIMIT ?"
        }
        if offset > 0 {
            sql += " OFFSET ?"
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        for (index, value) in bindValues {
            if let stringValue = value as? String {
                bindText(stmt, index, stringValue)
            }
        }
        var nextBindIndex = bindIndex
        if let limit {
            sqlite3_bind_int(stmt, nextBindIndex, Int32(limit))
            nextBindIndex += 1
        }
        if offset > 0 {
            sqlite3_bind_int(stmt, nextBindIndex, Int32(offset))
        }

        var events: [CollectorEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let event = eventFromStatement(stmt) {
                events.append(event)
            }
        }
        return events
    }

    private func isDuplicateLocked(_ incoming: CollectorEvent) -> Bool {
        let recent = fetchLocked(
            category: CollectorCategory(rawValue: incoming.category),
            query: nil,
            offset: 0,
            limit: duplicateScanLimit(for: incoming.category)
        )
        switch incoming.category {
        case CollectorCategory.notification.rawValue:
            return recent.contains { existing in
                guard existing.category == incoming.category else { return false }
                guard abs(existing.timestamp - incoming.timestamp) <= 30_000 else { return false }
                if let key = incoming.payload["notificationKey"], !key.isEmpty {
                    return existing.payload["notificationKey"] == key
                }
                return existing.payload["title"] == incoming.payload["title"] &&
                    existing.payload["body"] == incoming.payload["body"] &&
                    existing.payload["packageName"] == incoming.payload["packageName"]
            }
        case CollectorCategory.sms.rawValue:
            return recent.contains { existing in
                guard existing.category == incoming.category else { return false }
                guard abs(existing.timestamp - incoming.timestamp) <= 5_000 else { return false }
                return existing.payload["address"] == incoming.payload["address"] &&
                    existing.payload["body"] == incoming.payload["body"]
            }
        case CollectorCategory.call.rawValue:
            return recent.contains { existing in
                guard existing.category == incoming.category else { return false }
                guard existing.payload["phoneNumber"] == incoming.payload["phoneNumber"] else { return false }
                guard existing.payload["state"] == incoming.payload["state"] else { return false }
                return abs(existing.timestamp - incoming.timestamp) <= 2_000
            }
        case CollectorCategory.callLog.rawValue:
            if let logId = incoming.payload["logId"], !logId.isEmpty {
                return recent.contains { $0.category == incoming.category && $0.payload["logId"] == logId }
            }
            return recent.contains { existing in
                guard existing.category == incoming.category else { return false }
                return existing.payload["phoneNumber"] == incoming.payload["phoneNumber"] &&
                    existing.payload["type"] == incoming.payload["type"] &&
                    existing.payload["date"] == incoming.payload["date"]
            }
        case CollectorCategory.clipboard.rawValue:
            if let hash = incoming.payload["hash"], !hash.isEmpty {
                return recent.contains { $0.category == incoming.category && $0.payload["hash"] == hash }
            }
            return false
        case CollectorCategory.location.rawValue:
            guard let lat = Double(incoming.payload["latitude"] ?? ""),
                  let lon = Double(incoming.payload["longitude"] ?? "") else { return false }
            return recent.contains { existing in
                guard existing.category == incoming.category else { return false }
                guard abs(existing.timestamp - incoming.timestamp) <= 60_000 else { return false }
                guard let existingLat = Double(existing.payload["latitude"] ?? ""),
                      let existingLon = Double(existing.payload["longitude"] ?? "") else { return false }
                return distanceMeters(lat1: lat, lon1: lon, lat2: existingLat, lon2: existingLon) < 50
            }
        case CollectorCategory.system.rawValue:
            return recent.contains { existing in
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

    private func duplicateScanLimit(for category: String) -> Int {
        switch category {
        case CollectorCategory.notification.rawValue: return 200
        case CollectorCategory.location.rawValue: return 100
        case CollectorCategory.system.rawValue: return 20
        default: return 50
        }
    }

    private func eventFromStatement(_ stmt: OpaquePointer?) -> CollectorEvent? {
        guard let stmt,
              let idCString = sqlite3_column_text(stmt, 0),
              let categoryCString = sqlite3_column_text(stmt, 1),
              let deviceCString = sqlite3_column_text(stmt, 3),
              let payloadCString = sqlite3_column_text(stmt, 4) else { return nil }
        let payload = decodePayload(String(cString: payloadCString))
        return CollectorEvent(
            id: String(cString: idCString),
            category: String(cString: categoryCString),
            timestamp: sqlite3_column_double(stmt, 2),
            deviceId: String(cString: deviceCString),
            payload: payload
        )
    }

    private func encodePayload(_ payload: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    private func decodePayload(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return payload
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
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
