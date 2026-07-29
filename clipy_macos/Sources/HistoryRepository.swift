import Foundation
import SQLite3

enum HistoryItemKind: String {
    case text
    case image
    case rtf
    case pdf
    case html
    case files
}

/// Central facade for clipboard history persistence.
///
/// This class coordinates database access for history entries and delegates
/// focused responsibilities to dedicated collaborators:
/// - ``HistoryQueryBuilder`` for SQL construction,
/// - ``HistorySerializer`` for row (de)serialization,
/// - ``HistorySearchIndexManager`` for search index maintenance,
/// - ``HistoryMigrationService`` for legacy JSON migration.
final class HistoryRepository {
    static let shared = HistoryRepository()

    private let serializer = HistorySerializer()
    private let queryBuilder = HistoryQueryBuilder()
    private let searchIndexManager: HistorySearchIndexManager
    private let migrationService: HistoryMigrationService

    private var db: OpaquePointer? { AppDatabase.shared.db }
    private var queue: DispatchQueue { AppDatabase.shared.queue }

    private init() {
        let database = AppDatabase.shared
        self.searchIndexManager = HistorySearchIndexManager(database: database, serializer: serializer)
        self.migrationService = HistoryMigrationService(database: database)
    }

    // MARK: - Public API

    func migrateFromLegacyJSONIfNeeded() {
        migrationService.migrateFromLegacyJSONIfNeeded { entry in
            self.insertOrReplaceLocked(entry, preserveExistingMetadata: true)
        }
    }

    func count() -> Int {
        queue.sync { countLocked() }
    }

    func fetch(limit: Int, includeSearchIndex: Bool = false) -> [HistoryEntry] {
        queue.sync {
            fetchLocked(limit: limit, includeSearchIndex: includeSearchIndex, filters: nil, textQuery: nil)
        }
    }

    func fetchSummaries(limit: Int) -> [HistorySummary] {
        queue.sync { fetchSummariesLocked(limit: limit) }
    }

    func fetchByRowid(_ rowid: Int64, includeSearchIndex: Bool = false) -> HistoryEntry? {
        queue.sync {
            let sql = "SELECT * FROM history_entries WHERE rowid = ? LIMIT 1"
            return queryEntries(sql: sql, bind: { stmt in
                sqlite3_bind_int64(stmt, 1, rowid)
            }, includeSearchIndex: includeSearchIndex).first
        }
    }

    func fetchRowid(contentHash: String?, item: HistoryItem) -> Int64? {
        queue.sync { fetchRowidLocked(contentHash: contentHash, item: item) }
    }

    func fetchAll(includeSearchIndex: Bool = true) -> [HistoryEntry] {
        queue.sync {
            fetchLocked(limit: Int.max, includeSearchIndex: includeSearchIndex, filters: nil, textQuery: nil)
        }
    }

    func fetchFiltered(
        filters: SearchHistoryFilters,
        textQuery: String? = nil,
        includeSearchIndex: Bool = false,
        limit: Int? = nil
    ) -> [HistoryEntry] {
        queue.sync {
            fetchLocked(
                limit: limit ?? Int.max,
                includeSearchIndex: includeSearchIndex,
                filters: filters,
                textQuery: textQuery
            )
        }
    }

    func findFileEntryMatchingPlainText(_ text: String, recentLimit: Int = 100) -> HistoryEntry? {
        queue.sync {
            let entries = fetchLocked(
                limit: recentLimit,
                includeSearchIndex: false,
                filters: SearchHistoryFilters(typeFilter: .file),
                textQuery: nil
            )
            return entries.first { entry in
                guard case .files(let urls) = entry.item else { return false }
                return urls.map(\.lastPathComponent).joined(separator: "\n") == text
            }
        }
    }

    func distinctSourceApps() -> [String] {
        queue.sync {
            guard let db else { return [] }
            let sql = "SELECT DISTINCT source_app FROM history_entries WHERE source_app IS NOT NULL ORDER BY source_app COLLATE NOCASE"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            var apps: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cString = sqlite3_column_text(stmt, 0) {
                    apps.append(String(cString: cString))
                }
            }
            return apps
        }
    }

    @discardableResult
    func insertOrReplace(_ entry: HistoryEntry) -> Bool {
        // Externalize large text to disk BEFORE taking the DB lock so file IO
        // never serializes other readers behind the queue.
        let prepared = prepareForStorage(entry).entry
        return queue.sync { insertOrReplaceLocked(prepared, preserveExistingMetadata: false) }
    }

    func update(
        contentHash: String?,
        item: HistoryItem,
        transform: (inout HistoryEntry) -> Void
    ) -> HistoryEntry? {
        queue.sync {
            guard var existing = findMatchingLocked(item: item, contentHash: contentHash) else { return nil }
            transform(&existing)
            _ = insertOrReplaceLocked(existing, preserveExistingMetadata: false)
            return existing
        }
    }

    func delete(contentHash: String?, item: HistoryItem) -> Bool {
        queue.sync {
            deleteMatchingLocked(item: item, contentHash: contentHash)
        }
    }

    func deleteAll() -> Bool {
        queue.sync {
            guard let db else { return false }
            guard sqlite3_exec(db, "DELETE FROM history_entries", nil, nil, nil) == SQLITE_OK else { return false }
            return true
        }
    }

    func trimToLimit(_ maxItems: Int) {
        queue.sync {
            guard maxItems > 0 else { return }
            let total = countLocked()
            guard total > maxItems else { return }
            let overflow = total - maxItems

            // Delete the oldest unpinned rows in one statement instead of row-by-row.
            let deleteUnpinned = """
            DELETE FROM history_entries
            WHERE rowid IN (
                SELECT rowid FROM history_entries
                WHERE is_pinned = 0
                ORDER BY date ASC
                LIMIT ?
            )
            """
            if let db {
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, deleteUnpinned, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_int(stmt, 1, Int32(overflow))
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            }

            // If everything left is pinned we may still be over the limit.
            var remaining = countLocked()
            while remaining > maxItems {
                if deleteOldestLocked() {
                    remaining -= 1
                    continue
                }
                break
            }
        }
    }

    func findMatching(item: HistoryItem, contentHash: String?) -> HistoryEntry? {
        queue.sync { findMatchingLocked(item: item, contentHash: contentHash) }
    }

    func referencedStoragePaths() -> Set<String> {
        queue.sync {
            guard let db else { return [] }
            let sql = "SELECT text_path, media_path FROM history_entries"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            var paths = Set<String>()
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cString = sqlite3_column_text(stmt, 0) {
                    paths.insert(String(cString: cString))
                }
                if let cString = sqlite3_column_text(stmt, 1) {
                    paths.insert(String(cString: cString))
                }
            }
            return paths
        }
    }

    // MARK: - Search index (delegated)

    @discardableResult
    func updateSearchIndex(contentHash: String, text: String) -> Bool {
        searchIndexManager.updateSearchIndex(contentHash: contentHash, text: text)
    }

    func entriesNeedingSearchIndex(limit: Int = 50) -> [HistoryEntry] {
        searchIndexManager.entriesNeedingSearchIndex(limit: limit)
    }

    func clearTextSearchIndexes() {
        searchIndexManager.clearTextSearchIndexes()
    }

    // MARK: - Locked operations

    private func countLocked() -> Int {
        guard let db else { return 0 }
        let sql = "SELECT COUNT(*) FROM history_entries"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func fetchSummariesLocked(limit: Int) -> [HistorySummary] {
        guard let db, limit > 0 else { return [] }
        let sql = """
        SELECT rowid, content_hash, item_type, text_path, text_preview, media_path, files_json,
               date, source_app, source_bundle_id, is_pinned
        FROM history_entries
        ORDER BY is_pinned DESC, date DESC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var summaries: [HistorySummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let summary = serializer.summaryFromStatement(stmt) {
                summaries.append(summary)
            }
        }
        return summaries
    }

    private func fetchRowidLocked(contentHash: String?, item: HistoryItem) -> Int64? {
        guard let db else { return nil }
        if let contentHash {
            let sql = "SELECT rowid FROM history_entries WHERE content_hash = ? LIMIT 1"
            return queryRowid(sql: sql) { bindText($0, 1, contentHash) }
        }

        let kind = serializer.itemKind(for: item)
        let sql: String
        switch item {
        case .text:
            sql = "SELECT rowid FROM history_entries WHERE item_type = 'text' AND text_preview = ? LIMIT 1"
        case .image, .rtf, .pdf, .html:
            sql = "SELECT rowid FROM history_entries WHERE item_type = ? AND media_path = ? LIMIT 1"
        case .files:
            sql = "SELECT rowid FROM history_entries WHERE item_type = 'files' AND files_json = ? LIMIT 1"
        }

        return queryRowid(sql: sql) { stmt in
            switch item {
            case .text(let preview):
                bindText(stmt, 1, preview)
            case .image(let path), .rtf(let path), .pdf(let path), .html(let path):
                bindText(stmt, 1, kind.rawValue)
                bindText(stmt, 2, path)
            case .files(let urls):
                bindText(stmt, 1, serializer.encodeFiles(urls))
            }
        }
    }

    private func queryRowid(sql: String, bind: (OpaquePointer?) -> Void) -> Int64? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    @discardableResult
    private func insertOrReplaceLocked(_ entry: HistoryEntry, preserveExistingMetadata: Bool) -> Bool {
        guard let db else { return false }

        let prepared = prepareForStorage(entry)
        var finalEntry = prepared.entry

        if let existing = findMatchingLocked(item: entry.item, contentHash: entry.contentHash) {
            if preserveExistingMetadata {
                finalEntry.isPinned = existing.isPinned
                finalEntry.useCount = existing.useCount
                finalEntry.lastUsedAt = existing.lastUsedAt
                if finalEntry.searchIndex == nil {
                    finalEntry.searchIndex = existing.searchIndex
                }
            }
            deleteMatchingLocked(item: existing.item, contentHash: existing.contentHash)
        }

        let sql = """
        INSERT INTO history_entries (
            content_hash, item_type, text_path, text_preview, media_path, files_json,
            date, source_app, source_bundle_id, is_pinned, search_index, last_used_at, use_count
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        let kind = serializer.itemKind(for: finalEntry.item)
        bindText(stmt, 1, finalEntry.contentHash)
        bindText(stmt, 2, kind.rawValue)
        bindText(stmt, 3, finalEntry.textPath)
        bindText(stmt, 4, serializer.textPreview(for: finalEntry))
        bindText(stmt, 5, serializer.mediaPath(for: finalEntry.item))
        bindText(stmt, 6, serializer.encodeFilesJSON(finalEntry.item))
        sqlite3_bind_double(stmt, 7, finalEntry.date.timeIntervalSince1970)
        bindText(stmt, 8, finalEntry.sourceApp)
        bindText(stmt, 9, finalEntry.sourceBundleId)
        sqlite3_bind_int(stmt, 10, finalEntry.isPinned ? 1 : 0)
        bindText(stmt, 11, finalEntry.searchIndex)
        if let lastUsedAt = finalEntry.lastUsedAt {
            sqlite3_bind_double(stmt, 12, lastUsedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 12)
        }
        sqlite3_bind_int(stmt, 13, Int32(finalEntry.useCount))

        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func deleteMatchingLocked(item: HistoryItem, contentHash: String?) -> Bool {
        guard let db else { return false }
        if let contentHash {
            let sql = "DELETE FROM history_entries WHERE content_hash = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, contentHash)
            return sqlite3_step(stmt) == SQLITE_DONE
        }

        let kind = serializer.itemKind(for: item)
        let sql: String
        switch item {
        case .text:
            sql = "DELETE FROM history_entries WHERE item_type = 'text' AND (text_preview = ? OR text_path = ?)"
        case .image, .rtf, .pdf, .html:
            sql = "DELETE FROM history_entries WHERE item_type = ? AND media_path = ?"
        case .files:
            sql = "DELETE FROM history_entries WHERE item_type = 'files' AND files_json = ?"
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        switch item {
        case .text(let preview):
            bindText(stmt, 1, preview)
            bindText(stmt, 2, preview)
        case .image(let path), .rtf(let path), .pdf(let path), .html(let path):
            bindText(stmt, 1, kind.rawValue)
            bindText(stmt, 2, path)
        case .files(let urls):
            bindText(stmt, 1, serializer.encodeFiles(urls))
        }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func findMatchingLocked(item: HistoryItem, contentHash: String?) -> HistoryEntry? {
        guard let db else { return nil }
        if let contentHash {
            let sql = "SELECT * FROM history_entries WHERE content_hash = ? LIMIT 1"
            let rows = queryEntries(sql: sql, bind: { bindText($0, 1, contentHash) }, includeSearchIndex: true)
            return rows.first
        }

        let kind = serializer.itemKind(for: item)
        let sql: String
        switch item {
        case .text:
            sql = "SELECT * FROM history_entries WHERE item_type = 'text' AND text_preview = ? LIMIT 1"
        case .image, .rtf, .pdf, .html:
            sql = "SELECT * FROM history_entries WHERE item_type = ? AND media_path = ? LIMIT 1"
        case .files:
            sql = "SELECT * FROM history_entries WHERE item_type = 'files' AND files_json = ? LIMIT 1"
        }

        return queryEntries(sql: sql, bind: { stmt in
            switch item {
            case .text(let preview):
                bindText(stmt, 1, preview)
            case .image(let path), .rtf(let path), .pdf(let path), .html(let path):
                bindText(stmt, 1, kind.rawValue)
                bindText(stmt, 2, path)
            case .files(let urls):
                bindText(stmt, 1, serializer.encodeFiles(urls))
            }
        }, includeSearchIndex: true).first
    }

    private func fetchLocked(
        limit: Int,
        includeSearchIndex: Bool,
        filters: SearchHistoryFilters?,
        textQuery: String?
    ) -> [HistoryEntry] {
        let built = queryBuilder.buildQuery(limit: limit, filters: filters, textQuery: textQuery)
        return queryEntries(sql: built.sql, bind: { stmt in
            for (index, value) in built.bindValues {
                switch value {
                case .text(let stringValue):
                    bindText(stmt, index, stringValue)
                case .double(let doubleValue):
                    sqlite3_bind_double(stmt, index, doubleValue)
                case .int(let intValue):
                    sqlite3_bind_int(stmt, index, intValue)
                }
            }
        }, includeSearchIndex: includeSearchIndex)
    }

    private func queryEntries(
        sql: String,
        bind: (OpaquePointer?) -> Void,
        includeSearchIndex: Bool
    ) -> [HistoryEntry] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var entries: [HistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let entry = serializer.entryFromStatement(stmt, includeSearchIndex: includeSearchIndex) {
                entries.append(entry)
            }
        }
        return entries
    }

    private func deleteOldestUnpinnedLocked() -> Bool {
        guard let db else { return false }
        let sql = """
        DELETE FROM history_entries
        WHERE rowid = (
            SELECT rowid FROM history_entries
            WHERE is_pinned = 0
            ORDER BY date ASC
            LIMIT 1
        )
        """
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK && sqlite3_changes(db) > 0
    }

    private func deleteOldestLocked() -> Bool {
        guard let db else { return false }
        let sql = """
        DELETE FROM history_entries
        WHERE rowid = (
            SELECT rowid FROM history_entries
            ORDER BY date ASC
            LIMIT 1
        )
        """
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK && sqlite3_changes(db) > 0
    }

    // MARK: - Storage helpers

    private func prepareForStorage(_ entry: HistoryEntry) -> (entry: HistoryEntry, didExternalizeText: Bool) {
        var stored = entry
        if case .text(let fullText) = entry.item, entry.textPath == nil {
            let hash = entry.contentHash
            let storedText = HistoryMediaStore.shared.storeText(fullText, preferredHash: hash)
            stored.item = .text(storedText.preview)
            stored.textPath = storedText.path
            return (stored, true)
        }
        return (stored, false)
    }
}

struct SearchHistoryFilters {
    var typeFilter: HistoryTypeFilter = .all
    var sourceApp: String?
    var dateFilter: HistoryDateFilter = .all
    var pinnedOnly: Bool = false
    var pathContains: String?
    var urlOnly: Bool = false
}

extension HistoryEntry {
    var resolvedText: String? {
        if let textPath {
            return HistoryMediaStore.shared.text(at: textPath)
        }
        if case .text(let value) = item {
            return value
        }
        return nil
    }
}
