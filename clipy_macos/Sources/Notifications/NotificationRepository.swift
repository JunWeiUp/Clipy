import Foundation
import SQLite3

final class NotificationRepository {
    static let shared = NotificationRepository()

    struct AppIdentity: Equatable {
        let packageName: String
        let appName: String
    }

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

    /// Full table scan, ordered by post_time DESC. Used by the notification
    /// window which loads everything at once (no pagination).
    func fetchAll() -> [NotificationManager.NotificationEntry] {
        queue.sync { fetchAllLocked() }
    }

    private func fetchAllLocked() -> [NotificationManager.NotificationEntry] {
        guard let db else { return [] }
        let sql = """
        SELECT id, notification_key, package_name, app_name, title, subtitle, body,
               post_time, group_key, is_clearable, extras_json
        FROM phone_notifications
        ORDER BY post_time DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var entries: [NotificationManager.NotificationEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let entry = entryFromStatement(stmt) {
                entries.append(entry)
            }
        }
        return entries
    }

    func fetchById(_ id: String) -> NotificationManager.NotificationEntry? {
        queue.sync { fetchByIdLocked(id) }
    }

    /// Distinct (packageName, appName) of all received notifications, ordered by
    /// most recent arrival. Used by Settings to render the app picker.
    func fetchUniqueApps() -> [AppIdentity] {
        queue.sync {
            guard let db else { return [] }
            let sql = """
            SELECT package_name, app_name FROM phone_notifications
            GROUP BY package_name
            ORDER BY MAX(post_time) DESC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var apps: [AppIdentity] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let pkg = optionalString(stmt, 0), let name = optionalString(stmt, 1) {
                    apps.append(AppIdentity(packageName: pkg, appName: name))
                }
            }
            return apps
        }
    }

    @discardableResult
    func upsert(_ entry: NotificationManager.NotificationEntry) -> UpsertResult {
        queue.sync { upsertLocked(entry) }
    }

    /// Returns the number of rows actually deleted (via `sqlite3_changes`),
    /// so callers can adjust the in-memory count without re-running COUNT(*).
    @discardableResult
    func delete(id: String) -> Int {
        queue.sync { deleteByIdLocked(id) }
    }

    @discardableResult
    func delete(matching request: NotificationManager.NotificationDismissRequest) -> Int {
        queue.sync { deleteMatchingLocked(request) }
    }

    @discardableResult
    func deleteAll() -> Int {
        queue.sync {
            guard let db else { return 0 }
            guard sqliteExec(db, "DELETE FROM phone_notifications", context: "notification deleteAll") else {
                return 0
            }
            return Int(sqlite3_changes(db))
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

        // WeChat reuses the same StatusBarNotification key for each new message
        // in a conversation. Archive the previous snapshot instead of deleting it.
        if entry.packageName == "com.tencent.mm",
           let key = entry.notificationKey, !key.isEmpty,
           let existing = fetchByNotificationKeyLocked(key) {
            if isContentDuplicate(existing, incoming: entry) {
                return .replacedDuplicate(removedId: existing.id)
            }
            _ = archiveInPlaceLocked(existing)
            _ = insertLocked(entry)
            return .inserted
        }

        if let duplicateId = findDuplicateIdLocked(for: entry) {
            _ = deleteByIdLocked(duplicateId)
            _ = insertLocked(entry)
            return .replacedDuplicate(removedId: duplicateId)
        }

        _ = insertLocked(entry)
        return .inserted
    }

    private func fetchByNotificationKeyLocked(_ key: String) -> NotificationManager.NotificationEntry? {
        guard let db else { return nil }
        let sql = """
        SELECT id, notification_key, package_name, app_name, title, subtitle, body,
               post_time, group_key, is_clearable, extras_json
        FROM phone_notifications
        WHERE notification_key = ?
        LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return entryFromStatement(stmt)
    }

    @discardableResult
    private func archiveInPlaceLocked(_ existing: NotificationManager.NotificationEntry) -> Bool {
        var extras = existing.extras ?? [:]
        extras["clipyArchived"] = "true"
        let archived = NotificationManager.NotificationEntry(
            id: existing.id,
            notificationKey: "clipy-archived:\(existing.id)",
            packageName: existing.packageName,
            appName: existing.appName,
            title: existing.title,
            subtitle: existing.subtitle,
            body: existing.body,
            postTime: existing.postTime,
            groupKey: existing.groupKey,
            isClearable: existing.isClearable,
            isArchived: true,
            extras: extras
        )
        return updateLocked(archived)
    }

    private func isContentDuplicate(
        _ existing: NotificationManager.NotificationEntry,
        incoming: NotificationManager.NotificationEntry
    ) -> Bool {
        existing.title.trimmingCharacters(in: .whitespacesAndNewlines) ==
            incoming.title.trimmingCharacters(in: .whitespacesAndNewlines) &&
            (existing.subtitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines) ==
            (incoming.subtitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines) &&
            existing.body.trimmingCharacters(in: .whitespacesAndNewlines) ==
            incoming.body.trimmingCharacters(in: .whitespacesAndNewlines) &&
            existing.groupKey == incoming.groupKey
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
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqliteLogFailure(db, "notification insert prepare")
            return false
        }
        defer { sqlite3_finalize(stmt) }
        bindEntry(stmt, entry)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqliteLogFailure(db, "notification insert")
            return false
        }
        return true
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
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqliteLogFailure(db, "notification update prepare")
            return false
        }
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
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqliteLogFailure(db, "notification update")
            return false
        }
        return true
    }

    private func deleteByIdLocked(_ id: String) -> Int {
        guard let db else { return 0 }
        let sql = "DELETE FROM phone_notifications WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqliteLogFailure(db, "notification delete prepare")
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqliteLogFailure(db, "notification delete")
            return 0
        }
        return Int(sqlite3_changes(db))
    }

    /// Deletes the notifications a remote dismiss refers to.
    ///
    /// A dismiss must identify *which* notification: with neither a
    /// notificationKey nor a groupKey this used to delete every mirrored
    /// notification for the app, so one stray dismiss wiped a whole app's
    /// history. Such a request is now rejected.
    private func deleteMatchingLocked(_ request: NotificationManager.NotificationDismissRequest) -> Int {
        guard let db else { return 0 }
        let notificationKey = request.notificationKey.flatMap { $0.isEmpty ? nil : $0 }
        let groupKey = request.groupKey.flatMap { $0.isEmpty ? nil : $0 }

        let sql: String
        if notificationKey != nil {
            sql = "DELETE FROM phone_notifications WHERE package_name = ? AND notification_key = ?"
        } else if groupKey != nil {
            sql = "DELETE FROM phone_notifications WHERE package_name = ? AND group_key = ?"
        } else {
            appLog(
                "NotificationRepository: ignoring dismiss for \(request.packageName) with no notificationKey/groupKey",
                level: .warning
            )
            return 0
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqliteLogFailure(db, "notification delete-matching prepare")
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, request.packageName)
        bindText(stmt, 2, notificationKey ?? groupKey)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqliteLogFailure(db, "notification delete-matching")
            return 0
        }
        return Int(sqlite3_changes(db))
    }

    private func findDuplicateIdLocked(for incoming: NotificationManager.NotificationEntry) -> String? {
        guard let db else { return nil }
        let sql = """
        SELECT id, notification_key, title, subtitle, body, group_key, post_time
        FROM phone_notifications
        WHERE package_name = ?
        ORDER BY post_time DESC
        LIMIT 200
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

            _ = existingPostTime // 时间窗口已移除：内容相同即视为重复

            if let existingKey, let incomingKey = incoming.notificationKey,
               !existingKey.isEmpty, existingKey == incomingKey {
                return existingId
            }

            // Keep archived WeChat history rows; never treat them as replaceable dups.
            if let existingKey, existingKey.hasPrefix("clipy-archived:") {
                continue
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
            isArchived: decodeExtras(optionalString(stmt, 10))?["clipyArchived"] == "true",
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

}
