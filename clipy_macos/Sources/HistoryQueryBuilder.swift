import Foundation

/// A typed representation of a value to bind into a prepared statement.
enum QueryBindValue {
    case text(String)
    case double(TimeInterval)
    case int(Int32)
}

/// The result of building a history query: the SQL string and the ordered bind values.
struct BuiltQuery {
    let sql: String
    let bindValues: [(index: Int32, value: QueryBindValue)]
}

/// Responsible for building SQL statements and bind parameters for filtered
/// history queries. Keeping this logic isolated makes query construction
/// testable without a database connection.
final class HistoryQueryBuilder {

    /// Builds a `SELECT * FROM history_entries` query honoring optional filters,
    /// a full-text query, ordering and an optional row limit.
    func buildQuery(
        limit: Int,
        filters: SearchHistoryFilters?,
        textQuery: String?
    ) -> BuiltQuery {
        var sql = "SELECT * FROM history_entries"
        var conditions: [String] = []
        var bindValues: [(index: Int32, value: QueryBindValue)] = []
        var bindIndex: Int32 = 1

        if let filters {
            if filters.typeFilter != .all {
                conditions.append("item_type IN (\(sqlTypeList(for: filters.typeFilter)))")
            }
            if let sourceApp = filters.sourceApp, !sourceApp.isEmpty {
                conditions.append("source_app LIKE ? COLLATE NOCASE")
                bindValues.append((bindIndex, .text("%\(sourceApp)%")))
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
                bindValues.append((bindIndex, .text("%\(pathContains)%")))
                bindIndex += 1
                bindValues.append((bindIndex, .text("%\(pathContains)%")))
                bindIndex += 1
            }
            if filters.dateFilter != .all {
                if let start = filters.dateFilter.startDate {
                    conditions.append("date >= ?")
                    bindValues.append((bindIndex, .double(start.timeIntervalSince1970)))
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
            for _ in 0..<4 {
                bindValues.append((bindIndex, .text(pattern)))
                bindIndex += 1
            }
        }

        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY is_pinned DESC, date DESC"
        if limit != Int.max {
            sql += " LIMIT ?"
            bindValues.append((bindIndex, .int(Int32(limit))))
        }

        return BuiltQuery(sql: sql, bindValues: bindValues)
    }

    /// Maps a content type filter to the corresponding SQL `IN (...)` literal list.
    func sqlTypeList(for filter: HistoryTypeFilter) -> String {
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
}

extension HistoryDateFilter {
    /// The inclusive start date used when filtering entries for this date range.
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
