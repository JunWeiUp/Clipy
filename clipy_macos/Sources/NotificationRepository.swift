import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class NotificationRepository {
    static let shared = NotificationRepository()

    enum UpsertResult {
        case inserted
        case updated
        case replacedDuplicate(removedId: String)
    }

    private let legacyJSONURL: URL
    private var db: OpaquePointer? { AppDatabase.shared.db }
    private var queue: DispatchQueue { AppDatabase.shared.queue }
    private let duplicateWindowMilliseconds: TimeInterval = 30_000

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipyClone", isDirectory: true)
        legacyJSONURL = appSupport.appendingPathComponent("notifications.json")
        _ = AppDatabase.shared
        migrateFromLegacyJSONIfNeeded()
    }

    func count() -> Int {
        queue.sync { countLocked() }
    }

    func fetch(offset: Int, limit: Int) -> [NotificationManager.NotificationEntry] {
        queue.sync { fetchLocked(offset: offset, limit: limit) }
    }

    func fetchById(_ id: String) -> NotificationManager.NotificationEntry? {
        queue.sync { fetchByIdLocked(id) }
    }

    @discardableResult
    func upsert(_ entry: NotificationManager.NotificationEntry) -> UpsertResult {
        queue.sync { upsertLocked(entry) }
    }

    func delete(id: String) -> Bool {
        queue.sync { deleteByIdLocked(id) }
    }

    func delete(matching request: NotificationManager.NotificationDismissRequest) -> Bool {
        queue.sync { deleteMatchingLocked(request) }
    }

    func deleteAll() -> Bool {
        queue.sync {
            guard let db else { return false }
            return sqlite3_exec(db, "DELETE FROM phone_notifications", nil, nil, nil) == SQLITE_OK
        }
    }

    private func migrateFromLegacyJSONIfNeeded() {
        queue.sync {
            guard countLocked() == 0,
                  FileManager.default.fileExists(atPath: legacyJSONURL.path),
                  let data = try? Data(contentsOf: legacyJSONURL),
                  let loaded = try? JSONDecoder().decode([NotificationManager.NotificationEntry].self, from: data) else { return }

            var migrated = 0
            for entry in loaded.reversed() {
                if insertLocked(entry) {
                    migrated += 1
                }
            }
            if migrated > 0 {
                let backupURL = legacyJSONURL.deletingPathExtension().appendingPathExtension("json.bak")
                try? FileManager.default.moveItem(at: legacyJSONURL, to: backupURL)
                appLog("Notification migration complete: \(migrated) entries", level: .info)
            }
        }
    }

    // MARK: - Locked operations

    private func countLocked() -> Int {
        guard let db else { return 0 }
        let sql = "SELECT COUNT(*) FROM phone_notifications"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func fetchLocked(offset: Int, limit: Int) -> [NotificationManager.NotificationEntry] {
        guard let db, limit > 0, offset >= 0 else { return [] }
        let sql = """
        SELECT id, notification_key, package_name, app_name, title, subtitle, body,
               post_time, group_key, is_clearable, extras_json
        FROM phone_notifications
        ORDER BY post_time DESC
        LIMIT ? OFFSET ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        sqlite3_bind_int(stmt, 2, Int32(offset))

        var entries: [NotificationManager.NotificationEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let entry = entryFromStatement(stmt) {
                entries.append(entry)
            }
        }
        return entries
    }

    private func fetchByIdLocked(_ id: String) -> NotificationManager.NotificationEntry? {
        guard let db else { return nil }
        let sql = """
        SELECT id, notification_key, package_name, app_name, title, subtitle, body,
               post_time, group_key, is_clearable, extras_json
        FROM phone_notifications
        WHERE id = ?
        LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return entryFromStatement(stmt)
    }

    private func upsertLocked(_ entry: NotificationManager.NotificationEntry) -> UpsertResult {
        if fetchByIdLocked(entry.id) != nil {
            _ = updateLocked(entry)
            return .updated
        }

        if let duplicateId = findDuplicateIdLocked(for: entry) {
            _ = deleteByIdLocked(duplicateId)
            _ = insertLocked(entry)
            return .replacedDuplicate(removedId: duplicateId)
        }

        _ = insertLocked(entry)
        return .inserted
    }

    @discardableResult
    private func insertLocked(_ entry: NotificationManager.NotificationEntry) -> Bool {
        guard let db else { return false }
        let sql = """
        INSERT OR REPLACE INTO phone_notifications (
            id, notification_key, package_name, app_name, title, subtitle, body,
            post_time, group_key, is_clearable, extras_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindEntry(stmt, entry)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    @discardableResult
    private func updateLocked(_ entry: NotificationManager.NotificationEntry) -> Bool {
        guard let db else { return false }
        let sql = """
        UPDATE phone_notifications SET
            notification_key = ?, package_name = ?, app_name = ?, title = ?, subtitle = ?,
            body = ?, post_time = ?, group_key = ?, is_clearable = ?, extras_json = ?
        WHERE id = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, entry.notificationKey)
        bindText(stmt, 2, entry.packageName)
        bindText(stmt, 3, entry.appName)
        bindText(stmt, 4, entry.title)
        bindText(stmt, 5, entry.subtitle)
        bindText(stmt, 6, entry.body)
        sqlite3_bind_double(stmt, 7, entry.postTime)
        bindText(stmt, 8, entry.groupKey)
        sqlite3_bind_int(stmt, 9, entry.isClearable ? 1 : 0)
        bindText(stmt, 10, encodeExtras(entry.extras))
        bindText(stmt, 11, entry.id)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func deleteByIdLocked(_ id: String) -> Bool {
        guard let db else { return false }
        let sql = "DELETE FROM phone_notifications WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func deleteMatchingLocked(_ request: NotificationManager.NotificationDismissRequest) -> Bool {
        guard let db else { return false }
        let sql: String
        if let notificationKey = request.notificationKey, !notificationKey.isEmpty {
            sql = "DELETE FROM phone_notifications WHERE package_name = ? AND notification_key = ?"
        } else {
            sql = "DELETE FROM phone_notifications WHERE package_name = ?"
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, request.packageName)
        if let notificationKey = request.notificationKey, !notificationKey.isEmpty {
            bindText(stmt, 2, notificationKey)
        }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func findDuplicateIdLocked(for incoming: NotificationManager.NotificationEntry) -> String? {
        guard let db else { return nil }
        let sql = """
        SELECT id, notification_key, title, subtitle, body, group_key, post_time
        FROM phone_notifications
        WHERE package_name = ?
        ORDER BY post_time DESC
        LIMIT 50
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, incoming.packageName)

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idCString = sqlite3_column_text(stmt, 0) else { continue }
            let existingId = String(cString: idCString)
            let existingKey = optionalString(stmt, 1)
            let existingTitle = optionalString(stmt, 2) ?? ""
            let existingSubtitle = optionalString(stmt, 3) ?? ""
            let existingBody = optionalString(stmt, 4) ?? ""
            let existingGroupKey = optionalString(stmt, 5)
            let existingPostTime = sqlite3_column_double(stmt, 6)

            guard abs(existingPostTime - incoming.postTime) <= duplicateWindowMilliseconds else { continue }

            if let existingKey, let incomingKey = incoming.notificationKey,
               !existingKey.isEmpty, existingKey == incomingKey {
                return existingId
            }

            let incomingTitle = incoming.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let incomingSubtitle = (incoming.subtitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let incomingBody = incoming.body.trimmingCharacters(in: .whitespacesAndNewlines)

            if existingTitle.trimmingCharacters(in: .whitespacesAndNewlines) == incomingTitle &&
                existingSubtitle.trimmingCharacters(in: .whitespacesAndNewlines) == incomingSubtitle &&
                existingBody.trimmingCharacters(in: .whitespacesAndNewlines) == incomingBody &&
                existingGroupKey == incoming.groupKey {
                return existingId
            }
        }
        return nil
    }

    private func entryFromStatement(_ stmt: OpaquePointer?) -> NotificationManager.NotificationEntry? {
        guard let stmt,
              let idCString = sqlite3_column_text(stmt, 0),
              let packageCString = sqlite3_column_text(stmt, 2),
              let appCString = sqlite3_column_text(stmt, 3),
              let titleCString = sqlite3_column_text(stmt, 4) else { return nil }

        let body = optionalString(stmt, 6) ?? ""
        return NotificationManager.NotificationEntry(
            id: String(cString: idCString),
            notificationKey: optionalString(stmt, 1),
            packageName: String(cString: packageCString),
            appName: String(cString: appCString),
            title: String(cString: titleCString),
            subtitle: optionalString(stmt, 5),
            body: body,
            postTime: sqlite3_column_double(stmt, 7),
            groupKey: optionalString(stmt, 8),
            isClearable: sqlite3_column_int(stmt, 9) != 0,
            extras: decodeExtras(optionalString(stmt, 10))
        )
    }

    private func bindEntry(_ stmt: OpaquePointer?, _ entry: NotificationManager.NotificationEntry) {
        bindText(stmt, 1, entry.id)
        bindText(stmt, 2, entry.notificationKey)
        bindText(stmt, 3, entry.packageName)
        bindText(stmt, 4, entry.appName)
        bindText(stmt, 5, entry.title)
        bindText(stmt, 6, entry.subtitle)
        bindText(stmt, 7, entry.body)
        sqlite3_bind_double(stmt, 8, entry.postTime)
        bindText(stmt, 9, entry.groupKey)
        sqlite3_bind_int(stmt, 10, entry.isClearable ? 1 : 0)
        bindText(stmt, 11, encodeExtras(entry.extras))
    }

    private func encodeExtras(_ extras: [String: String]?) -> String? {
        guard let extras, !extras.isEmpty,
              let data = try? JSONEncoder().encode(extras),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    private func decodeExtras(_ json: String?) -> [String: String]? {
        guard let json, let data = json.data(using: .utf8),
              let extras = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return extras
    }

    private func optionalString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
