import Foundation

final class HistorySearchCancellation {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// A search retains only a page of candidates and the best visible results.
/// SQL applies structural filters only: LIKE cannot safely prefilter fuzzy or
/// regex matches, or text held in external files. Never change stored history.
enum HistorySearchService {
    static func search(options: SearchHistoryOptions, repository: HistoryRepository,
                       defaultLimit: Int, cancellation: HistorySearchCancellation?) -> [HistorySearchResult] {
        search(options: options, defaultLimit: defaultLimit, cancellation: cancellation,
               fetchPage: { repository.searchPage(filters: $0, beforeRowid: $1, limit: $2) },
               fetchBrowse: { repository.fetchFiltered(filters: $0, limit: $1) })
    }

    static func search(options: SearchHistoryOptions, defaultLimit: Int,
                       cancellation: HistorySearchCancellation?,
                       fetchPage: (SearchHistoryFilters, Int64, Int) -> (entries: [HistoryEntry], cursor: Int64?),
                       fetchBrowse: (SearchHistoryFilters, Int) -> [HistoryEntry]) -> [HistorySearchResult] {
        let parsed = options.useRegex ? ParsedSearchQuery() : HistorySearchQueryParser.parse(options.query)
        let query = (options.useRegex ? options.query : parsed.textTerms.joined(separator: " "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let regex = options.useRegex && !query.isEmpty
            ? try? NSRegularExpression(pattern: query, options: [.caseInsensitive]) : nil
        if options.useRegex && !query.isEmpty && regex == nil { return [] }
        let urlOnly = parsed.urlOnly || options.urlOnly
        let filters = SearchHistoryFilters(
            typeFilter: parsed.typeFilter ?? options.typeFilter,
            sourceApp: parsed.sourceApp ?? options.sourceApp,
            dateFilter: options.dateFilter,
            pinnedOnly: parsed.pinnedOnly || options.pinnedOnly,
            pathContains: parsed.pathContains ?? options.pathContains,
            urlOnly: false // Full text may contain URLs beyond its stored preview.
        )
        let limit = max(1, options.browseLimit ?? defaultLimit)
        if cancellation?.isCancelled == true { return [] }
        if query.isEmpty && options.contentCategory == nil && !urlOnly {
            return fetchBrowse(filters, limit).map { HistorySearchResult(entry: $0, highlightRanges: []) }
        }
        var best: [HistorySearchResult] = []
        var cursor = Int64.max
        while cancellation?.isCancelled != true {
            let next: Int64? = autoreleasepool {
                let page = fetchPage(filters, cursor, 128)
                for entry in page.entries {
                    if cancellation?.isCancelled == true { return nil }
                    autoreleasepool {
                        if let category = options.contentCategory, !category.matches(entry) { return }
                        if urlOnly && !(entry.resolvedText ?? entry.item.title).contains("://") { return }
                        guard let result = HistorySearchRanker.rank(entries: [entry], query: query,
                            useRegex: options.useRegex, loadFullTextIfNeeded: true, compiledRegex: regex).first else { return }
                        func precedes(_ lhs: HistorySearchResult, _ rhs: HistorySearchResult) -> Bool {
                            if !query.isEmpty, lhs.score != rhs.score { return (lhs.score ?? 0) > (rhs.score ?? 0) }
                            if lhs.entry.isPinned != rhs.entry.isPinned { return lhs.entry.isPinned }
                            let left = query.isEmpty ? lhs.entry.date : lhs.entry.lastUsedAt ?? lhs.entry.date
                            let right = query.isEmpty ? rhs.entry.date : rhs.entry.lastUsedAt ?? rhs.entry.date
                            return left > right
                        }
                        var low = 0, high = best.count
                        while low < high {
                            let mid = (low + high) / 2
                            if precedes(result, best[mid]) { high = mid } else { low = mid + 1 }
                        }
                        if low < limit {
                            best.insert(result, at: low)
                            if best.count > limit { best.removeLast() }
                        }
                    }
                }
                return page.cursor
            }
            guard let next else { break }
            cursor = next
        }
        if cancellation?.isCancelled == true { return [] }
        return best.map { result in
            var entry = result.entry
            entry.searchIndex = nil
            return HistorySearchResult(entry: entry, highlightRanges: result.highlightRanges, score: result.score)
        }
    }
}
