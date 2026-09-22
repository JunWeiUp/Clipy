import Foundation

struct WordEntry: Codable, Equatable {
    struct Meaning: Codable, Equatable {
        let partOfSpeech: String
        let definition: String
    }
    struct Phrase: Codable, Equatable {
        let text: String
        let translation: String
    }
    struct Example: Codable, Equatable {
        let text: String
        let translation: String
        let source: String
    }
    struct Inflection: Codable, Equatable {
        let name: String
        let value: String
    }

    let word: String
    let americanIPA: String?
    let meanings: [Meaning]
    let phrases: [Phrase]
    let examples: [Example]
    let inflections: [Inflection]

    var sourceURL: URL {
        var components = URLComponents(string: "https://dict.youdao.com/result")!
        components.queryItems = [URLQueryItem(name: "word", value: word), URLQueryItem(name: "lang", value: "en")]
        return components.url!
    }
}

enum WordLookupError: Error, Equatable {
    case invalidQuery, notFound, unavailable, invalidResponse, responseTooLarge
}

enum WordQuery {
    /// Prefill only one complete English word, including contractions and
    /// hyphenated words. Sentences, URLs and multiple words require manual input.
    static func clipboardWord(_ input: String?) -> String? {
        guard let input, input.count <= 256 else { return nil }
        let word = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "’", with: "'")
        guard word.count <= 80,
              word.range(of: "^[A-Za-z]+(?:['-][A-Za-z]+)*$", options: .regularExpression) != nil else { return nil }
        return word
    }

    /// Explicitly submitted text may contain sentences, numbers and punctuation.
    /// Clipboard prefill and remote dictionary candidates retain stricter limits.
    static let maximumLength = 500

    static func normalize(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !value.isEmpty, value.count <= maximumLength,
              value.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }),
              value.range(of: "[A-Za-z\\p{Han}]", options: .regularExpression) != nil,
              value.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) == nil,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw WordLookupError.invalidQuery
        }
        return value
    }

    static func dictionaryTerm(_ input: String) -> String? {
        guard let value = try? normalize(input), value.count <= 80,
              value.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || " '.·-".unicodeScalars.contains($0) }),
              value.range(of: "^[A-Za-z\\p{Han}]+(?:[ '.·-][A-Za-z\\p{Han}]+)*$", options: .regularExpression) != nil else { return nil }
        return value
    }

}

/// The provider's web dictionary response is isolated here because it is not
/// a versioned public API. Missing optional sections must not hide definitions.
enum YoudaoWordParser {
    static func candidates(_ data: Data) throws -> [WordSuggestion] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WordLookupError.invalidResponse
        }
        var results: [WordSuggestion] = []
        for word in objects((root["ce"] as? [String: Any])?["word"]) {
            for row in objects(word["trs"]) {
                for translation in objects(row["tr"]) {
                    guard let line = translation["l"] as? [String: Any] else { continue }
                    // Chinese-to-English entries mix strings and link objects.
                    // Only the link's text is a lookup term, never its app URL.
                    // A single translation can span several links ("I", " ",
                    // "love", " ", "you"). Preserve the complete English phrase.
                    let text = (line["i"] as? [Any] ?? []).map { item in
                        (item as? [String: Any])?["#text"] as? String ?? item as? String ?? ""
                    }.joined()
                    if let term = WordQuery.dictionaryTerm(text) {
                        results.append(.init(word: term, detail: line["#tran"] as? String ?? ""))
                    }
                }
            }
        }
        for typo in objects((root["typos"] as? [String: Any])?["typo"]) {
            if let word = typo["word"] as? String, let term = WordQuery.dictionaryTerm(word) {
                results.append(.init(word: term, detail: typo["trans"] as? String ?? ""))
            }
        }
        return WordSuggestion.unique(results)
    }

    static func suggestions(_ data: Data) throws -> [WordSuggestion] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any], result["code"] as? Int == 200,
              let payload = root["data"] as? [String: Any] else { throw WordLookupError.invalidResponse }
        return WordSuggestion.unique(objects(payload["entries"]).compactMap { item in
            guard let word = item["entry"] as? String,
                  let term = WordQuery.dictionaryTerm(word) else { return nil }
            return .init(word: term, detail: item["explain"] as? String ?? "")
        })
    }

    static func parse(_ data: Data, query: String) throws -> WordEntry {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WordLookupError.invalidResponse
        }
        guard let ec = root["ec"] as? [String: Any],
              let words = ec["word"] as? [[String: Any]], let word = words.first else {
            // Only a recognizable empty dictionary response means "not found".
            if root["input"] is String, root["meta"] != nil { throw WordLookupError.notFound }
            throw WordLookupError.invalidResponse
        }
        let meanings = objects(word["trs"]).flatMap { row in
            objects(row["tr"]).flatMap { strings(($0["l"] as? [String: Any])?["i"]) }
        }.filter { !$0.isEmpty }.prefix(40).map(splitMeaning)
        guard !meanings.isEmpty else { throw WordLookupError.invalidResponse }
        let phrases = objects((root["phrs"] as? [String: Any])?["phrs"]).prefix(40).compactMap { row -> WordEntry.Phrase? in
            guard let phrase = row["phr"] as? [String: Any] else { return nil }
            let text = nestedText(phrase["headword"])
            guard !text.isEmpty else { return nil }
            let translation = objects(phrase["trs"]).map { nestedText($0["tr"]) }.filter { !$0.isEmpty }.joined(separator: "；")
            return .init(text: text, translation: translation)
        }
        let examples = objects((root["blng_sents_part"] as? [String: Any])?["sentence-pair"]).prefix(20).compactMap { row -> WordEntry.Example? in
            // Use the plain sentence; sentence-eng contains provider HTML.
            guard let text = row["sentence"] as? String, !text.isEmpty else { return nil }
            return .init(text: text, translation: row["sentence-translation"] as? String ?? "", source: row["source"] as? String ?? "")
        }
        let inflections = objects(word["wfs"]).prefix(20).compactMap { row -> WordEntry.Inflection? in
            guard let wf = row["wf"] as? [String: Any], let name = wf["name"] as? String,
                  let value = wf["value"] as? String else { return nil }
            return .init(name: name, value: value)
        }
        let headword = nestedText(word["return-phrase"])
        let ipa = (word["usphone"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return WordEntry(word: headword.isEmpty ? query : headword,
                         americanIPA: ipa?.isEmpty == false ? ipa : nil,
                         meanings: Array(meanings), phrases: phrases, examples: examples, inflections: inflections)
    }

    private static func objects(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
    private static func strings(_ value: Any?) -> [String] {
        if let text = value as? String { return [text] }
        return value as? [String] ?? []
    }
    private static func nestedText(_ value: Any?) -> String {
        let l = (value as? [String: Any])?["l"] as? [String: Any]
        return strings(l?["i"]).joined(separator: "；")
    }
    private static func splitMeaning(_ text: String) -> WordEntry.Meaning {
        let pattern = "^(?:(?:n|v|vt|vi|adj|adv|pron|prep|conj|interj|int|art|num|aux|det|abbr)\\.\\s*)+"
        guard let range = text.range(of: pattern, options: .regularExpression) else {
            return .init(partOfSpeech: "", definition: text)
        }
        return .init(partOfSpeech: String(text[range]).trimmingCharacters(in: .whitespaces),
                     definition: String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces))
    }
}
