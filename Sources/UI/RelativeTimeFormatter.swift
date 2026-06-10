import Foundation

enum RelativeTimeFormatter {
    static func string(from date: Date) -> String {
        let interval = -date.timeIntervalSinceNow
        if interval < 60 {
            return L10n.t(.relativeTimeJustNow)
        }
        if interval < 3600 {
            return L10n.format(.relativeTimeMinutes, Int(interval / 60))
        }
        if interval < 86400 {
            return L10n.format(.relativeTimeHours, Int(interval / 3600))
        }
        if interval < 604_800 {
            return L10n.format(.relativeTimeDays, Int(interval / 86400))
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
