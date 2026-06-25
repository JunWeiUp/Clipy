import Foundation

enum HistorySearchRanker {
    private static let maxSearchableLength = 10_000
    private static let pinnedBonus = 200
    private static let exactPhraseBonus = 50
    private static let prefixBonus = 30
    private static let occurrenceBonus = 5
    private static let useCountMultiplier = 10

    static func rank(entries: [HistoryEntry], query: String, useRegex: Bool = false) -> [HistorySearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return entries.map { HistorySearchResult(entry: $0, highlightRanges: []) }
        }

        let terms = trimmed
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else {
            return entries.map { HistorySearchResult(entry: $0, highlightRanges: []) }
        }

        let ranked = entries.compactMap { entry -> HistorySearchResult? in
            let displayText = entry.item.title
            if useRegex {
                return regexResult(entry: entry, pattern: trimmed, displayText: displayText)
            }
            guard let score = score(entry: entry, terms: terms) else { return nil }
            let ranges = highlightRanges(for: displayText, terms: terms)
            return HistorySearchResult(entry: entry, highlightRanges: ranges, score: score)
        }

        return ranked.sorted { lhs, rhs in
            let ls = lhs.score ?? 0
            let rs = rhs.score ?? 0
            if ls != rs { return ls > rs }
            if lhs.entry.isPinned != rhs.entry.isPinned { return lhs.entry.isPinned }
            let ll = lhs.entry.lastUsedAt ?? lhs.entry.date
            let rl = rhs.entry.lastUsedAt ?? rhs.entry.date
            return ll > rl
        }
    }

    private static func regexResult(entry: HistoryEntry, pattern: String, displayText: String) -> HistorySearchResult? {
        let fields = searchableTexts(for: entry)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        for field in fields {
            let normalized = normalizeSearchText(field)
            let range = NSRange(normalized.startIndex..., in: normalized)
            if regex.firstMatch(in: normalized, options: [], range: range) != nil {
                let ranges = regexRanges(in: displayText, pattern: pattern)
                return HistorySearchResult(entry: entry, highlightRanges: ranges, score: 100)
            }
        }
        return nil
    }

    private static func score(entry: HistoryEntry, terms: [String]) -> Int? {
        let fields = searchableTexts(for: entry)
        let haystack = fields.joined(separator: "\n").lowercased()

        var total = 0
        for term in terms {
            guard let termScore = bestFuzzyScore(query: term, in: fields) else { return nil }
            total += termScore

            let occurrences = haystack.components(separatedBy: term).count - 1
            if occurrences > 1 {
                total += (occurrences - 1) * occurrenceBonus
            }
        }

        let phrase = terms.joined(separator: " ")
        if haystack.contains(phrase) {
            total += exactPhraseBonus
        }

        if fields.contains(where: { $0.lowercased().hasPrefix(terms[0]) }) {
            total += prefixBonus
        }

        if entry.isPinned {
            total += pinnedBonus
        }

        total += recencyBonus(for: entry.lastUsedAt ?? entry.date)
        total += min(entry.useCount * useCountMultiplier, 200)
        return total
    }

    private static func recencyBonus(for date: Date) -> Int {
        let ageHours = Date().timeIntervalSince(date) / 3600
        return max(0, 100 - Int(ageHours))
    }

    private static func bestFuzzyScore(query: String, in fields: [String]) -> Int? {
        var best: Int?
        for field in fields {
            let normalized = normalizeSearchText(field)
            if let score = fuzzyScore(query: query, text: normalized) {
                best = max(best ?? Int.min, score)
            }
        }
        return best
    }

    static func searchableTexts(for entry: HistoryEntry) -> [String] {
        var texts: [String] = []
        if let source = entry.sourceApp {
            texts.append(source)
        }
        if let bundleId = entry.sourceBundleId {
            texts.append(bundleId)
        }
        if let index = entry.searchIndex, !index.isEmpty {
            texts.append(index)
        }

        switch entry.item {
        case .text(let str):
            texts.append(str)
        case .image:
            texts.append("image")
        case .rtf:
            texts.append("rich text")
        case .pdf:
            texts.append("pdf")
        case .html:
            texts.append("html")
        case .files(let urls):
            for url in urls {
                texts.append(url.lastPathComponent)
                texts.append(url.path)
                texts.append(FilePathDisplay.string(for: url))
            }
        }
        return texts
    }

    static func highlightRanges(for text: String, terms: [String]) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        let lower = text.lowercased()
        for term in terms where !term.isEmpty {
            var searchStart = lower.startIndex
            while searchStart < lower.endIndex,
                  let found = lower.range(of: term, range: searchStart..<lower.endIndex) {
                let start = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: found.lowerBound))
                let end = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: found.upperBound))
                ranges.append(start..<end)
                searchStart = found.upperBound
            }
        }
        return mergeRanges(ranges)
    }

    private static func regexRanges(in text: String, pattern: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        return matches.compactMap { Range($0.range, in: text) }
    }

    private static func mergeRanges(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        var current = sorted[0]
        for range in sorted.dropFirst() {
            if range.lowerBound <= current.upperBound {
                current = current.lowerBound..<max(current.upperBound, range.upperBound)
            } else {
                merged.append(current)
                current = range
            }
        }
        merged.append(current)
        return merged
    }

    private static func normalizeSearchText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxSearchableLength {
            return trimmed.lowercased()
        }
        return String(trimmed.prefix(maxSearchableLength)).lowercased()
    }

    static func fuzzyScore(query: String, text: String) -> Int? {
        let queryChars = Array(query.lowercased())
        let textChars = Array(text.lowercased())
        guard !queryChars.isEmpty else { return 0 }
        guard !textChars.isEmpty else { return nil }

        var score = 0
        var queryIndex = 0
        var previousMatch = -1
        var consecutive = 0

        for (index, char) in textChars.enumerated() {
            guard queryIndex < queryChars.count else { break }
            guard char == queryChars[queryIndex] else { continue }

            var matchScore = 100

            if previousMatch == index - 1 {
                consecutive += 1
                matchScore += consecutive * 10
            } else {
                if previousMatch >= 0 {
                    matchScore -= (index - previousMatch - 1) * 2
                }
                consecutive = 0
            }

            if index == 0 || isWordBoundary(textChars, at: index) {
                matchScore += 15
            }

            matchScore += max(0, 15 - index / 5)
            score += matchScore

            previousMatch = index
            queryIndex += 1
        }

        guard queryIndex == queryChars.count else { return nil }
        return score
    }

    private static func isWordBoundary(_ chars: [Character], at index: Int) -> Bool {
        guard index > 0 else { return true }
        switch chars[index - 1] {
        case " ", "\t", "\n", "/", "\\", "-", "_", ".", ":", "(", "[", "{", "@":
            return true
        default:
            return false
        }
    }
}
