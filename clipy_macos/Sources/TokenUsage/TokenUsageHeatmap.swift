import Foundation

enum TokenUsageCalendar {
    /// Stable Gregorian date keys, with day boundaries in the user's local time zone.
    static var local: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    static func yearRange(endingAt date: Date, calendar: Calendar = local) -> DateInterval {
        let today = calendar.startOfDay(for: date)
        return DateInterval(start: calendar.date(byAdding: .day, value: -364, to: today)!,
                            end: calendar.date(byAdding: .day, value: 1, to: today)!)
    }

    static func dayFormatter(calendar: Calendar = local) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

/// A bounded presentation model: 365 local days, padded to Sunday–Saturday columns.
/// Missing records remain zero; cells outside the range are absent, not zero-use days.
struct TokenUsageHeatmap {
    struct Day: Identifiable {
        let date: Date
        let usage: TokenUsageDay
        var id: String { usage.day }
    }

    struct Month: Identifiable {
        let column: Int
        let date: Date
        var id: Int { column }
    }

    let days: [Day]
    let weeks: [[Day?]]
    let months: [Month]
    let calendar: Calendar
    let totalTokens: Int
    let activeDays: Int
    private let maximum: Int

    init(lines: [TokenUsageLine], agent: TokenAgent? = nil, endingAt date: Date = Date(),
         calendar: Calendar = TokenUsageCalendar.local) {
        self.calendar = calendar
        let range = TokenUsageCalendar.yearRange(endingAt: date, calendar: calendar)
        let formatter = TokenUsageCalendar.dayFormatter(calendar: calendar)
        let startKey = formatter.string(from: range.start)
        let endKey = formatter.string(from: range.end)
        var grouped: [String: (TokenCounts, Double, Int)] = [:]
        for line in lines where line.day >= startKey && line.day < endKey && (agent == nil || line.agent == agent) {
            var value = grouped[line.day] ?? (TokenCounts(), 0, 0)
            value.0 = value.0 + line.counts
            value.1 += line.estimatedUSD ?? 0
            value.2 += line.unpricedEvents
            grouped[line.day] = value
        }
        days = (0..<365).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: range.start)!
            let key = formatter.string(from: date)
            let value = grouped[key] ?? (TokenCounts(), 0, 0)
            return Day(date: date, usage: TokenUsageDay(day: key, counts: value.0,
                                                       estimatedUSD: value.1, unpricedEvents: value.2))
        }
        let padding = calendar.component(.weekday, from: range.start) - 1
        var cells = Array<Day?>(repeating: nil, count: padding) + days.map(Optional.some)
        cells += Array<Day?>(repeating: nil, count: (7 - cells.count % 7) % 7)
        weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<($0 + 7)]) }
        months = days.enumerated().compactMap { offset, day in
            guard offset == 0 || calendar.component(.day, from: day.date) == 1 else { return nil }
            return Month(column: (padding + offset) / 7, date: day.date)
        }
        totalTokens = days.reduce(0) { $0 + $1.usage.counts.total }
        activeDays = days.filter { $0.usage.counts.total > 0 }.count
        maximum = days.map { $0.usage.counts.total }.max() ?? 0
    }

    func intensity(for day: Day) -> Int {
        guard day.usage.counts.total > 0, maximum > 0 else { return 0 }
        return min(4, max(1, Int(ceil(Double(day.usage.counts.total) / Double(maximum) * 4))))
    }
}
