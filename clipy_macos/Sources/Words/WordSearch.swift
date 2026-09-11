import Foundation

struct WordSuggestion: Equatable, Identifiable {
    let word: String
    let detail: String
    var id: String { word.lowercased() }

    static func unique(_ values: [WordSuggestion]) -> [WordSuggestion] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }
    }
}

struct WordSearchResult {
    let entry: WordEntry?
    let suggestions: [WordSuggestion]
}

/// Shared offline matching for lookup candidates and both vocabulary lists.
enum WordSearchMatcher {
    static func ranked(_ words: [SavedWord], query: String) -> [SavedWord] {
        let terms = folded(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return words }
        return words.enumerated().compactMap { index, word -> (Int, Int, SavedWord)? in
            let entry = word.entry
            let fields = [(entry.word, 0)]
                + entry.meanings.map { ($0.definition, 10) }
                + entry.inflections.map { ($0.value, 5) }
                + entry.phrases.flatMap { [($0.text, 15), ($0.translation, 15)] }
                + entry.examples.flatMap { [($0.text, 20), ($0.translation, 20)] }
            let normalized = fields.map { (folded($0.0), $0.1) }
            var total = 0
            for term in terms {
                guard let best = normalized.compactMap({ field -> Int? in
                    score(term, in: field.0).map { $0 + field.1 }
                }).min() else { return nil }
                total += best
            }
            return (total, index, word)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.map { $0.2 }
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func score(_ term: String, in text: String) -> Int? {
        if text == term { return 0 }
        if text.hasPrefix(term) { return 10 }
        if text.contains(term) { return 20 }
        let needle = Array(term)
        let latin = term.allSatisfy { $0.isASCII && $0.isLetter }
        if needle.count >= 2 {
            let haystack = Array(text)
            let maxSpan = latin ? needle.count * 3 : needle.count + 2
            for start in haystack.indices where haystack[start] == needle[0] {
                var matched = 0
                for index in start..<min(haystack.count, start + maxSpan) {
                    if haystack[index] == needle[matched] { matched += 1 }
                    if matched == needle.count { return 40 }
                }
            }
        }
        // English typo tolerance, including adjacent transpositions. Avoid
        // fuzzy one-letter matches and comparing against whole paragraphs.
        if latin, needle.count >= 3 {
            let limit = needle.count <= 5 ? 1 : 2
            for token in text.split(whereSeparator: { !($0.isASCII && $0.isLetter) }) {
                guard abs(token.count - needle.count) <= limit else { continue }
                let distance = editDistance(needle, Array(token))
                if distance <= limit { return 50 + distance }
            }
        }
        return nil
    }

    private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        var previous = Array(0...rhs.count)
        var beforePrevious = previous
        for i in 1...lhs.count {
            var row = [i] + Array(repeating: 0, count: rhs.count)
            for j in 1...rhs.count {
                row[j] = min(row[j - 1] + 1, previous[j] + 1,
                             previous[j - 1] + (lhs[i - 1] == rhs[j - 1] ? 0 : 1))
                if i > 1, j > 1, lhs[i - 1] == rhs[j - 2], lhs[i - 2] == rhs[j - 1] {
                    row[j] = min(row[j], beforePrevious[j - 2] + 1)
                }
            }
            beforePrevious = previous
            previous = row
        }
        return previous[rhs.count]
    }
}
