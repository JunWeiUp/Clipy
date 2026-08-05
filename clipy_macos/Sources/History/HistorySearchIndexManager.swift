import Foundation
import SQLite3

/// Manages the `search_index` column of `history_entries`: updating indexes,
/// discovering rows that still need indexing, and clearing text-only indexes.
/// Isolating these operations keeps the repository focused on CRUD logic.
final class HistorySearchIndexManager {

    private let database: AppDatabase
    private let serializer: HistorySerializer

    init(database: AppDatabase, serializer: HistorySerializer) {
        self.database = database
        self.serializer = serializer
    }

    /// Writes the prebuilt search index text for the entry matching `contentHash`.
    @discardableResult
    func updateSearchIndex(contentHash: String, text: String) -> Bool {
        database.queue.sync {
            guard let db = database.db else { return false }
            let sql = "UPDATE history_entries SET search_index = ? WHERE content_hash = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqliteLogFailure(db, "search index update prepare")
                return false
            }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, text)
            bindText(stmt, 2, contentHash)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                sqliteLogFailure(db, "search index update")
                return false
            }
            return true
        }
    }

    /// Returns non-text entries whose search index is empty or missing, ordered
    /// by most recent first. Used by the background indexer.
    func entriesNeedingSearchIndex(limit: Int = 50) -> [HistoryEntry] {
        database.queue.sync {
            guard let db = database.db else { return [] }
            let sql = """
            SELECT * FROM history_entries
            WHERE item_type != 'text'
              AND (search_index IS NULL OR search_index = '')
            ORDER BY date DESC
            LIMIT ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqliteLogFailure(db, "entriesNeedingSearchIndex prepare")
                return []
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))

            var entries: [HistoryEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let entry = serializer.entryFromStatement(stmt, includeSearchIndex: false) {
                    entries.append(entry)
                }
            }
            return entries
        }
    }

    /// Nulls out the search index for all text entries, forcing them to be
    /// rebuilt from the on-disk text content.
    /// Text entries are searched through `text_preview`/`text_path`, so their
    /// `search_index` column is dead weight left over from older builds.
    ///
    /// The `IS NOT NULL` clause matters: without it this rewrote every text row
    /// on every launch, since nothing ever repopulates the column.
    func clearTextSearchIndexes() {
        database.queue.sync {
            guard let db = database.db else { return }
            let sql = "UPDATE history_entries SET search_index = NULL WHERE item_type = 'text' AND search_index IS NOT NULL"
            sqliteExec(db, sql, context: "clearTextSearchIndexes")
        }
    }
}
