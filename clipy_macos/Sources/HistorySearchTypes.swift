import Foundation

enum HistoryDateFilter: String, CaseIterable, Identifiable {
    case all
    case today
    case week
    case month

    var id: String { rawValue }

    var labelKey: L10nKey {
        switch self {
        case .all: return .historyDateFilterAll
        case .today: return .historyDateFilterToday
        case .week: return .historyDateFilterWeek
        case .month: return .historyDateFilterMonth
        }
    }

    func matches(_ date: Date) -> Bool {
        let now = Date()
        switch self {
        case .all:
            return true
        case .today:
            return Calendar.current.isDateInToday(date)
        case .week:
            guard let start = Calendar.current.date(byAdding: .day, value: -7, to: now) else { return true }
            return date >= start
        case .month:
            guard let start = Calendar.current.date(byAdding: .day, value: -30, to: now) else { return true }
            return date >= start
        }
    }
}

enum HistorySelectAction {
    case pasteAndClose
    case copyOnly
    case pastePlainAndClose
    case pasteKeepOpen
    case pastePlainKeepOpen
}

struct SearchHistoryOptions {
    var query: String = ""
    var typeFilter: HistoryTypeFilter = .all
    var sourceApp: String? = nil
    var dateFilter: HistoryDateFilter = .all
    var contentCategory: HistoryContentCategory? = nil
    var pinnedOnly: Bool = false
    var useRegex: Bool = false
    var pathContains: String? = nil
    var urlOnly: Bool = false
}

struct HistorySearchResult: Identifiable {
    let entry: HistoryEntry
    let highlightRanges: [Range<String.Index>]
    var score: Int?

    var id: String { entry.id }
}

enum HistoryContentCategory: String, CaseIterable, Identifiable {
    case url
    case email
    case code
    case json

    var id: String { rawValue }

    var labelKey: L10nKey {
        switch self {
        case .url: return .historyCategoryURL
        case .email: return .historyCategoryEmail
        case .code: return .historyCategoryCode
        case .json: return .historyCategoryJSON
        }
    }

    func matches(_ entry: HistoryEntry) -> Bool {
        switch self {
        case .url:
            return text(of: entry)?.range(of: #"https?://"#, options: .regularExpression) != nil
        case .email:
            return text(of: entry)?.range(
                of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        case .code:
            guard let text = text(of: entry) else { return false }
            return text.contains("{") || text.contains("def ") || text.contains("function ") || text.contains("class ")
        case .json:
            guard let text = text(of: entry) else { return false }
            return HistoryPreviewSupport.resolvedTextKind(for: text) == .json
        }
    }

    private func text(of entry: HistoryEntry) -> String? {
        if let index = entry.searchIndex, !index.isEmpty { return index }
        return entry.resolvedText
    }
}

struct ParsedSearchQuery {
    var textTerms: [String] = []
    var typeFilter: HistoryTypeFilter?
    var sourceApp: String?
    var pinnedOnly = false
    var pathContains: String?
    var urlOnly = false
}

enum HistorySearchQueryParser {
    private static let typePrefixes = ["type", "kind"]
    private static let appPrefixes = ["app", "source"]
    private static let pathPrefixes = ["path", "file"]

    static func parse(_ query: String) -> ParsedSearchQuery {
        var result = ParsedSearchQuery()
        var freeText: [String] = []

        for token in query.split(whereSeparator: \.isWhitespace).map(String.init) {
            if let parsed = parseToken(token) {
                apply(parsed, to: &result)
            } else {
                freeText.append(token)
            }
        }

        result.textTerms = freeText
        return result
    }

    private static func parseToken(_ token: String) -> (key: String, value: String)? {
        guard let colon = token.firstIndex(of: ":") else { return nil }
        let key = String(token[..<colon]).lowercased()
        let value = String(token[token.index(after: colon)...])
        return (key, value)
    }

    private static func apply(_ parsed: (key: String, value: String), to result: inout ParsedSearchQuery) {
        let key = parsed.key
        let value = parsed.value

        if typePrefixes.contains(key) {
            result.typeFilter = typeFilter(from: value)
        } else if appPrefixes.contains(key) {
            result.sourceApp = value.isEmpty ? nil : value
        } else if key == "pin" {
            result.pinnedOnly = true
        } else if pathPrefixes.contains(key) {
            result.pathContains = value.isEmpty ? nil : value
        } else if key == "url" {
            result.urlOnly = true
        }
    }

    private static func typeFilter(from value: String) -> HistoryTypeFilter? {
        switch value.lowercased() {
        case "text", "txt": return .text
        case "image", "img", "photo": return .image
        case "file", "files": return .file
        case "rtf", "rich", "richtext", "html", "pdf": return .richText
        default: return nil
        }
    }
}
