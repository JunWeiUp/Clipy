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
    var translation: WordTranslation? = nil
}

/// Machine translation is transient and never treated as a dictionary entry.
struct WordTranslation: Equatable {
    enum Direction: String {
        case englishToChinese = "en2zh-CHS"
        case chineseToEnglish = "zh-CHS2en"
    }
    let original: String
    let text: String
    let direction: Direction
    var englishText: String { direction == .chineseToEnglish ? text : original }

    var sourceURL: URL {
        var components = URLComponents(string: "https://dict.youdao.com/result")!
        components.queryItems = [URLQueryItem(name: "word", value: original), URLQueryItem(name: "lang", value: "en")]
        return components.url!
    }

    static func parse(_ data: Data, query: String) throws -> WordTranslation? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WordLookupError.invalidResponse
        }
        guard let value = root["fanyi"] else { return nil }
        guard let payload = value as? [String: Any],
              let original = payload["input"] as? String,
              (try? WordQuery.normalize(original)) == query,
              let rawText = payload["tran"] as? String,
              let type = payload["type"] as? String,
              let direction = Direction(rawValue: type) else { throw WordLookupError.invalidResponse }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        // The unversioned endpoint occasionally returns corrupted, watermarked
        // output. Reject it rather than showing a damaged sentence as a translation.
        guard !text.isEmpty, text.count <= 10_000,
              !text.localizedCaseInsensitiveContains("these data are stolen from youdao") else {
            throw WordLookupError.invalidResponse
        }
        return .init(original: query, text: text, direction: direction)
    }
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
