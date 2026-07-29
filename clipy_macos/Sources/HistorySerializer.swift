import Foundation
import SQLite3

/// Handles serialization and deserialization between SQLite statement rows and
/// the in-memory `HistoryEntry`/`HistorySummary` model objects. Isolating this
/// logic keeps the repository focused on persistence orchestration and makes
/// the (de)serialization paths independently testable.
final class HistorySerializer {

    // MARK: - Row decoding

    /// Decodes a full `HistoryEntry` from the current row of a prepared statement.
    /// - Parameters:
    ///   - stmt: The prepared statement positioned on a `SQLITE_ROW`.
    ///   - includeSearchIndex: When `false` the search index column is not read.
    func entryFromStatement(_ stmt: OpaquePointer?, includeSearchIndex: Bool) -> HistoryEntry? {
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

    /// Decodes a lightweight `HistorySummary` from the current row of a prepared
    /// statement. Used by summary-only fetches that omit the search index column.
    func summaryFromStatement(_ stmt: OpaquePointer?) -> HistorySummary? {
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

    // MARK: - Item encoding / decoding

    /// Reconstructs a `HistoryItem` from its persisted column values.
    func decodeItem(
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

    /// Encodes a `[URL]` list of file references into the JSON string persisted
    /// in the `files_json` column.
    func encodeFiles(_ urls: [URL]) -> String {
        let paths = urls.map(\.path)
        guard let data = try? JSONEncoder().encode(paths) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Decodes the `files_json` column back into a `[URL]` list.
    func decodeFiles(_ json: String?) -> [URL] {
        guard let json, let data = json.data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    /// Convenience wrapper returning the encoded files JSON for an item, or nil
    /// when the item is not a files item.
    func encodeFilesJSON(_ item: HistoryItem) -> String? {
        guard case .files(let urls) = item else { return nil }
        return encodeFiles(urls)
    }

    // MARK: - Item metadata accessors

    /// Returns the persisted kind for a given item.
    func itemKind(for item: HistoryItem) -> HistoryItemKind {
        switch item {
        case .text: return .text
        case .image: return .image
        case .rtf: return .rtf
        case .pdf: return .pdf
        case .html: return .html
        case .files: return .files
        }
    }

    /// Returns the on-disk media path for media-backed items, otherwise nil.
    func mediaPath(for item: HistoryItem) -> String? {
        switch item {
        case .image(let path), .rtf(let path), .pdf(let path), .html(let path):
            return path
        default:
            return nil
        }
    }

    /// Returns the text preview for a text item, otherwise nil.
    func textPreview(for entry: HistoryEntry) -> String? {
        if case .text(let preview) = entry.item {
            return preview
        }
        return nil
    }
}
