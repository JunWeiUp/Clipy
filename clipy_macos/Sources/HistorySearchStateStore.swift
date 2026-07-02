import Foundation

enum HistorySearchStateStore {
    private static let queryKey = "historySearch.query"
    private static let typeFilterKey = "historySearch.typeFilter"
    private static let sourceAppKey = "historySearch.sourceApp"
    private static let dateFilterKey = "historySearch.dateFilter"
    private static let useRegexKey = "historySearch.useRegex"

    struct Snapshot {
        var query: String
        var typeFilter: HistoryTypeFilter
        var sourceAppFilter: String
        var dateFilter: HistoryDateFilter
        var useRegex: Bool
    }

    static func load() -> Snapshot {
        let defaults = UserDefaults.standard
        let typeRaw = defaults.string(forKey: typeFilterKey) ?? HistoryTypeFilter.all.rawValue
        let dateRaw = defaults.string(forKey: dateFilterKey) ?? HistoryDateFilter.all.rawValue
        return Snapshot(
            query: defaults.string(forKey: queryKey) ?? "",
            typeFilter: HistoryTypeFilter(rawValue: typeRaw) ?? .all,
            sourceAppFilter: defaults.string(forKey: sourceAppKey) ?? "",
            dateFilter: HistoryDateFilter(rawValue: dateRaw) ?? .all,
            useRegex: defaults.bool(forKey: useRegexKey)
        )
    }

    static func save(_ snapshot: Snapshot) {
        let defaults = UserDefaults.standard
        defaults.set(snapshot.query, forKey: queryKey)
        defaults.set(snapshot.typeFilter.rawValue, forKey: typeFilterKey)
        defaults.set(snapshot.sourceAppFilter, forKey: sourceAppKey)
        defaults.set(snapshot.dateFilter.rawValue, forKey: dateFilterKey)
        defaults.set(snapshot.useRegex, forKey: useRegexKey)
    }
}
