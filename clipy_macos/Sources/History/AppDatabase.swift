import Foundation
import SQLite3

final class AppDatabase {
    static let shared = AppDatabase()

    private(set) var db: OpaquePointer?
    let queue = DispatchQueue(label: "com.clipy.database")

    private let appSupport: URL
    private let dbURL: URL

    private init() {
        appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipyClone", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        dbURL = appSupport.appendingPathComponent("clipy.db")
        openDatabase()
        queue.sync {
            createAllSchemas()
            migrateLegacyDatabaseFilesIfNeeded()
        }
    }

    // MARK: - Setup

    private func openDatabase() {
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            appLog("Failed to open app database", level: .error)
            db = nil
        }
    }

    private func createAllSchemas() {
        guard let db else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS history_entries (
            rowid INTEGER PRIMARY KEY AUTOINCREMENT,
            content_hash TEXT,
            item_type TEXT NOT NULL,
            text_path TEXT,
            text_preview TEXT,
            media_path TEXT,
            files_json TEXT,
            date REAL NOT NULL,
            source_app TEXT,
            source_bundle_id TEXT,
            is_pinned INTEGER NOT NULL DEFAULT 0,
            search_index TEXT,
            last_used_at REAL,
            use_count INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_history_order ON history_entries(is_pinned DESC, date DESC);
        CREATE INDEX IF NOT EXISTS idx_history_hash ON history_entries(content_hash);
        CREATE INDEX IF NOT EXISTS idx_history_source_app ON history_entries(source_app);

        CREATE TABLE IF NOT EXISTS phone_notifications (
            rowid INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT NOT NULL UNIQUE,
            notification_key TEXT,
            package_name TEXT NOT NULL,
            app_name TEXT NOT NULL,
            title TEXT NOT NULL,
            subtitle TEXT,
            body TEXT NOT NULL,
            post_time REAL NOT NULL,
            group_key TEXT,
            is_clearable INTEGER NOT NULL DEFAULT 1,
            extras_json TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_phone_notifications_order ON phone_notifications(post_time DESC);
        CREATE INDEX IF NOT EXISTS idx_phone_notifications_package_time ON phone_notifications(package_name, post_time DESC);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func migrateLegacyDatabaseFilesIfNeeded() {
        migrateLegacyTableIfEmpty(
            table: "history_entries",
            legacyFileName: "history_v3.db",
            legacyTable: "history_entries"
        )
        migrateLegacyTableIfEmpty(
            table: "phone_notifications",
            legacyFileName: "notifications.db",
            legacyTable: "phone_notifications"
        )
    }

    private func migrateLegacyTableIfEmpty(table: String, legacyFileName: String, legacyTable: String) {
        guard let db, tableCount(table) == 0 else { return }

        let legacyURL = appSupport.appendingPathComponent(legacyFileName)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }

        let escapedPath = legacyURL.path.replacingOccurrences(of: "'", with: "''")
        let attachSQL = "ATTACH DATABASE '\(escapedPath)' AS legacy_db"
        guard sqlite3_exec(db, attachSQL, nil, nil, nil) == SQLITE_OK else {
            appLog("Failed to attach legacy database \(legacyFileName)", level: .error)
            return
        }

        let copySQL = "INSERT INTO main.\(table) SELECT * FROM legacy_db.\(legacyTable)"
        let copied = sqlite3_exec(db, copySQL, nil, nil, nil) == SQLITE_OK
        sqlite3_exec(db, "DETACH DATABASE legacy_db", nil, nil, nil)

        guard copied else {
            appLog("Failed to migrate \(table) from \(legacyFileName)", level: .error)
            return
        }

        let migrated = tableCount(table)
        guard migrated > 0 else { return }

        let backupURL = legacyURL.deletingPathExtension().appendingPathExtension("db.bak")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: legacyURL, to: backupURL)
        appLog("Migrated \(migrated) rows for \(table) from \(legacyFileName)", level: .info)
    }

    private func tableCount(_ table: String) -> Int {
        guard let db else { return 0 }
        let sql = "SELECT COUNT(*) FROM \(table)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }
}
