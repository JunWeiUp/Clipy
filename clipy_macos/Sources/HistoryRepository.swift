import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum HistoryItemKind: String {
    case text
    case image
    case rtf
    case pdf
    case html
    case files
}

final class HistoryRepository {
    static let shared = HistoryRepository()

    private let legacyJSONURL: URL
    private var db: OpaquePointer? { AppDatabase.shared.db }
    private var queue: DispatchQueue { AppDatabase.shared.queue }

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipyClone", isDirectory: true)
        legacyJSONURL = appSupport.appendingPathComponent("history_v2.json")
        _ = AppDatabase.shared
    }

    // MARK: - Public API

    func migrateFromLegacyJSONIfNeeded() {
        queue.sync {
            guard FileManager.default.fileExists(atPath: legacyJSONURL.path) else { return }
            guard let entries = decodeLegacyJSON(from: legacyJSONURL), !entries.isEmpty else { return }

            appLog("Migrating clipboard history from JSON to SQLite...", level: .info)
            for entry in entries {
                _ = insertOrReplaceLocked(entry, preserveExistingMetadata: true)
            }
            let backupURL = legacyJSONURL.deletingPathExtension().appendingPathExtension("json.bak")
            try? FileManager.default.moveItem(at: legacyJSONURL, to: backupURL)
            appLog("History migration complete: \(entries.count) entries", level: .info)
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

    func updateSearchIndex(contentHash: String, text: String) -> Bool {
        queue.sync {
            guard let db else { return false }
            let sql = "UPDATE history_entries SET search_index = ? WHERE content_hash = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, text)
            bindText(stmt, 2, contentHash)
            return sqlite3_step(stmt) == SQLITE_DONE
        }
    }

    func entriesNeedingSearchIndex(limit: Int = 50) -> [HistoryEntry] {
        queue.sync {
            guard db != nil else { return [] }
            let sql = """
            SELECT * FROM history_entries
            WHERE item_type != 'text'
              AND (search_index IS NULL OR search_index = '')
            ORDER BY date DESC
            LIMIT ?
            """
            return queryEntries(sql: sql, bind: { stmt in
                sqlite3_bind_int(stmt, 1, Int32(limit))
            }, includeSearchIndex: false)
        }
    }

    func findMatching(item: HistoryItem, contentHash: String?) -> HistoryEntry? {
        queue.sync { findMatchingLocked(item: item, contentHash: contentHash) }
    }

    func clearTextSearchIndexes() {
        queue.sync {
            guard let db else { return }
            sqlite3_exec(db, "UPDATE history_entries SET search_index = NULL WHERE item_type = 'text'", nil, nil, nil)
        }
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
            if let summary = summaryFromStatement(stmt) {
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

        let kind = itemKind(for: item)
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
                bindText(stmt, 1, encodeFiles(urls))
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

    private func summaryFromStatement(_ stmt: OpaquePointer?) -> HistorySummary? {
        guard let stmt,
              let typeCString = sqlite3_column_text(stmt, 2) else { return nil }
        let itemType = String(cString: typeCString)
        let textPreview = optionalString(stmt, 4)
        let mediaPath = optionalString(stmt, 5)
        let filesJSON = optionalString(stmt, 6)
        guard let item = decodeItem(
            type: itemType,
            textPreview: textPreview,
            mediaPath: mediaPath,
            filesJSON: filesJSON
        ) else { return nil }

        return HistorySummary(
            rowid: sqlite3_column_int64(stmt, 0),
            item: item,
            date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
            sourceApp: optionalString(stmt, 8),
            sourceBundleId: optionalString(stmt, 9),
            contentHash: optionalString(stmt, 1),
            isPinned: sqlite3_column_int(stmt, 10) != 0,
            textPath: optionalString(stmt, 3)
        )
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

        let kind = itemKind(for: finalEntry.item)
        bindText(stmt, 1, finalEntry.contentHash)
        bindText(stmt, 2, kind.rawValue)
        bindText(stmt, 3, finalEntry.textPath)
        bindText(stmt, 4, textPreview(for: finalEntry))
        bindText(stmt, 5, mediaPath(for: finalEntry.item))
        bindText(stmt, 6, encodeFilesJSON(finalEntry.item))
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

        let kind = itemKind(for: item)
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
            bindText(stmt, 1, encodeFiles(urls))
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

        let kind = itemKind(for: item)
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
                bindText(stmt, 1, encodeFiles(urls))
            }
        }, includeSearchIndex: true).first
    }

    private func fetchLocked(
        limit: Int,
        includeSearchIndex: Bool,
        filters: SearchHistoryFilters?,
        textQuery: String?
    ) -> [HistoryEntry] {
        var sql = "SELECT * FROM history_entries"
        var conditions: [String] = []
        var bindValues: [(Int32, Any?)] = []
        var bindIndex: Int32 = 1

        if let filters {
            if filters.typeFilter != .all {
                conditions.append("item_type IN (\(sqlTypeList(for: filters.typeFilter)))")
            }
            if let sourceApp = filters.sourceApp, !sourceApp.isEmpty {
                conditions.append("source_app LIKE ? COLLATE NOCASE")
                bindValues.append((bindIndex, "%\(sourceApp)%"))
                bindIndex += 1
            }
            if filters.pinnedOnly {
                conditions.append("is_pinned = 1")
            }
            if filters.urlOnly {
                conditions.append("item_type = 'text' AND text_preview LIKE '%://%'")
            }
            if let pathContains = filters.pathContains, !pathContains.isEmpty {
                conditions.append("(files_json LIKE ? OR media_path LIKE ?)")
                bindValues.append((bindIndex, "%\(pathContains)%"))
                bindIndex += 1
                bindValues.append((bindIndex, "%\(pathContains)%"))
                bindIndex += 1
            }
            if filters.dateFilter != .all {
                if let start = filters.dateFilter.startDate {
                    conditions.append("date >= ?")
                    bindValues.append((bindIndex, start.timeIntervalSince1970))
                    bindIndex += 1
                }
            }
        }

        if let textQuery, !textQuery.isEmpty {
            conditions.append("""
            (text_preview LIKE ? COLLATE NOCASE
             OR search_index LIKE ? COLLATE NOCASE
             OR source_app LIKE ? COLLATE NOCASE
             OR files_json LIKE ? COLLATE NOCASE)
            """)
            let pattern = "%\(textQuery)%"
            bindValues.append((bindIndex, pattern))
            bindIndex += 1
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
        sql += " ORDER BY is_pinned DESC, date DESC"
        if limit != Int.max {
            sql += " LIMIT ?"
        }

        return queryEntries(sql: sql, bind: { stmt in
            for (index, value) in bindValues {
                if let stringValue = value as? String {
                    bindText(stmt, index, stringValue)
                } else if let doubleValue = value as? TimeInterval {
                    sqlite3_bind_double(stmt, index, doubleValue)
                }
            }
            if limit != Int.max {
                sqlite3_bind_int(stmt, bindIndex, Int32(limit))
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
            if let entry = entryFromStatement(stmt, includeSearchIndex: includeSearchIndex) {
                entries.append(entry)
            }
        }
        return entries
    }

    private func entryFromStatement(_ stmt: OpaquePointer?, includeSearchIndex: Bool) -> HistoryEntry? {
        guard let stmt else { return nil }
        guard let typeCString = sqlite3_column_text(stmt, 2) else { return nil }
        let itemType = String(cString: typeCString)
        let textPath = optionalString(stmt, 3)
        let textPreview = optionalString(stmt, 4)
        let mediaPath = optionalString(stmt, 5)
        let filesJSON = optionalString(stmt, 6)
        let date = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
        let sourceApp = optionalString(stmt, 8)
        let sourceBundleId = optionalString(stmt, 9)
        let isPinned = sqlite3_column_int(stmt, 10) != 0
        let searchIndex = includeSearchIndex ? optionalString(stmt, 11) : nil
        let lastUsedAt = sqlite3_column_type(stmt, 12) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12))
        let useCount = Int(sqlite3_column_int(stmt, 13))
        let contentHash = optionalString(stmt, 1)

        guard let item = decodeItem(
            type: itemType,
            textPreview: textPreview,
            mediaPath: mediaPath,
            filesJSON: filesJSON
        ) else { return nil }

        return HistoryEntry(
            item: item,
            date: date,
            sourceApp: sourceApp,
            sourceBundleId: sourceBundleId,
            contentHash: contentHash,
            isPinned: isPinned,
            searchIndex: searchIndex,
            lastUsedAt: lastUsedAt,
            useCount: useCount,
            textPath: textPath
        )
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

    private func decodeItem(
        type: String,
        textPreview: String?,
        mediaPath: String?,
        filesJSON: String?
    ) -> HistoryItem? {
        switch type {
        case HistoryItemKind.text.rawValue:
            return .text(textPreview ?? "")
        case HistoryItemKind.image.rawValue:
            guard let mediaPath else { return nil }
            return .image(mediaPath)
        case HistoryItemKind.rtf.rawValue:
            guard let mediaPath else { return nil }
            return .rtf(mediaPath)
        case HistoryItemKind.pdf.rawValue:
            guard let mediaPath else { return nil }
            return .pdf(mediaPath)
        case HistoryItemKind.html.rawValue:
            guard let mediaPath else { return nil }
            return .html(mediaPath)
        case HistoryItemKind.files.rawValue:
            return .files(decodeFiles(filesJSON))
        default:
            return nil
        }
    }

    private func itemKind(for item: HistoryItem) -> HistoryItemKind {
        switch item {
        case .text: return .text
        case .image: return .image
        case .rtf: return .rtf
        case .pdf: return .pdf
        case .html: return .html
        case .files: return .files
        }
    }

    private func mediaPath(for item: HistoryItem) -> String? {
        switch item {
        case .image(let path), .rtf(let path), .pdf(let path), .html(let path):
            return path
        default:
            return nil
        }
    }

    private func textPreview(for entry: HistoryEntry) -> String? {
        if case .text(let preview) = entry.item {
            return preview
        }
        return nil
    }

    private func encodeFilesJSON(_ item: HistoryItem) -> String? {
        guard case .files(let urls) = item else { return nil }
        return encodeFiles(urls)
    }

    private func encodeFiles(_ urls: [URL]) -> String {
        let paths = urls.map(\.path)
        guard let data = try? JSONEncoder().encode(paths) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func decodeFiles(_ json: String?) -> [URL] {
        guard let json, let data = json.data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    private func sqlTypeList(for filter: HistoryTypeFilter) -> String {
        switch filter {
        case .all:
            return "'text','image','rtf','pdf','html','files'"
        case .text:
            return "'text'"
        case .image:
            return "'image'"
        case .file:
            return "'files'"
        case .richText:
            return "'rtf','html','pdf'"
        }
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func optionalString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    // MARK: - Legacy JSON migration

    private struct LegacyHistoryStorageEnvelope: Codable {
        let version: Int
        let encrypted: Bool
        let payload: String
    }

    private func decodeLegacyJSON(from url: URL) -> [HistoryEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let envelope = try? decoder.decode(LegacyHistoryStorageEnvelope.self, from: data), envelope.encrypted {
            guard let encryptedData = Data(base64Encoded: envelope.payload),
                  let key = HistoryKeychain.loadKey(),
                  let decrypted = try? SecureStorageCrypto.decrypt(encryptedData, using: key),
                  let entries = try? decoder.decode([HistoryEntry].self, from: decrypted) else {
                return nil
            }
            return entries
        }
        return try? decoder.decode([HistoryEntry].self, from: data)
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

private extension HistoryDateFilter {
    var startDate: Date? {
        let now = Date()
        switch self {
        case .all:
            return nil
        case .today:
            return Calendar.current.startOfDay(for: now)
        case .week:
            return Calendar.current.date(byAdding: .day, value: -7, to: now)
        case .month:
            return Calendar.current.date(byAdding: .day, value: -30, to: now)
        }
    }
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
