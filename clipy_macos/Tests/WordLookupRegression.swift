import AppKit
import Foundation

private let wordFixture = Data(#"""
{"input":"take","meta":{},"ec":{"word":[{"return-phrase":{"l":{"i":"take"}},"usphone":"teɪk","ukphone":"BRITISH-ONLY","trs":[{"tr":[{"l":{"i":["v. 拿；取","n. 镜头"]}}]}],"wfs":[{"wf":{"name":"过去式","value":"took"}}]}]},"phrs":{"phrs":[{"phr":{"headword":{"l":{"i":"take off"}},"trs":[{"tr":{"l":{"i":"起飞；脱下"}}}]}}]},"blng_sents_part":{"sentence-pair":[{"sentence":"Take this book.","sentence-eng":"<b>Take</b> this book.","sentence-translation":"拿这本书。","source":"Test fixture"}]}}
"""#.utf8)

private func wordCheck(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}

private func wordWait(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    wordCheck(condition(), "Word lookup asynchronous operation timed out")
}

private final class ControlledWordService: WordLookingUp {
    var pending: [String: CheckedContinuation<WordEntry, Error>] = [:]
    var pendingAudio: CheckedContinuation<Data, Error>?
    func lookup(_ query: String) async throws -> WordEntry {
        try await withCheckedThrowingContinuation { pending[query] = $0 }
    }
    func americanAudio(_ word: String) async throws -> Data {
        try await withCheckedThrowingContinuation { pendingAudio = $0 }
    }
}

private final class WordHTTPStub: URLProtocol {
    static var status = 200
    static var body = wordFixture
    static var declaredSize: Int?
    static var lastURL: URL?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastURL = request.url
        let headers = Self.declaredSize.map { ["Content-Length": String($0)] } ?? [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func runWordLookupRegressionTests() {
    let entry = try! YoudaoWordParser.parse(wordFixture, query: "take")
    wordCheck(entry.americanIPA == "teɪk", "Wrong regional IPA")
    wordCheck(entry.meanings.count == 2 && entry.meanings[0].partOfSpeech == "v.", "Part of speech lost")
    wordCheck(entry.meanings[0].definition == "拿；取", "Chinese definition lost")
    wordCheck(entry.phrases.first?.text == "take off" && entry.phrases.first?.translation == "起飞；脱下", "Phrase lost")
    wordCheck(entry.examples.first?.text == "Take this book." && entry.examples.first?.translation == "拿这本书。", "Bilingual example lost")
    wordCheck(entry.inflections.first?.value == "took", "Inflection lost")
    let minimal = Data(#"{"ec":{"word":[{"ukphone":"UK","trs":[{"tr":[{"l":{"i":"adj. test"}}]}]}]}}"#.utf8)
    let sparse = try! YoudaoWordParser.parse(minimal, query: "test")
    wordCheck(sparse.americanIPA == nil && sparse.phrases.isEmpty && sparse.examples.isEmpty, "Missing US IPA mislabeled / optional section broke entry")
    wordCheck((try? WordQuery.normalize("  take   off  ")) == "take off", "Whitespace normalization")
    wordCheck((try? WordQuery.normalize("John’s")) == "John's", "Apostrophe normalization")
    wordCheck(WordQuery.clipboardWord(" \nHello\t") == "Hello", "Clipboard word whitespace")
    wordCheck(WordQuery.clipboardWord("don't") == "don't" && WordQuery.clipboardWord("well-known") == "well-known", "Single-word punctuation")
    for value in [nil, "", "take off", "hello\nworld", "hello.", "https://example.com", "你好", "word123", String(repeating: "a", count: 81)] as [String?] {
        wordCheck(WordQuery.clipboardWord(value) == nil, "Non-word clipboard content was prefilled")
    }
    for query in ["", "你好", "https://example.com", "hello&token=secret", String(repeating: "a", count: 81)] {
        wordCheck((try? WordQuery.normalize(query)) == nil, "Invalid query accepted")
    }
    do {
        _ = try YoudaoWordParser.parse(Data(#"{"input":"x","meta":{}}"#.utf8), query: "x")
        preconditionFailure("Missing entry accepted")
    } catch { wordCheck(error as? WordLookupError == .notFound, "Unknown word not identified") }
    do {
        _ = try YoudaoWordParser.parse(Data(#"{"error":"changed format"}"#.utf8), query: "x")
        preconditionFailure("Schema failure accepted")
    } catch { wordCheck(error as? WordLookupError == .invalidResponse, "Schema error reported as absent word") }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [WordHTTPStub.self]
    let service = WordLookupService(session: URLSession(configuration: configuration))
    func requestError() -> WordLookupError? {
        var finished = false
        var result: WordLookupError?
        Task { @MainActor in
            do { _ = try await service.lookup("take off") }
            catch { result = error as? WordLookupError }
            finished = true
        }
        wordWait { finished }
        return result
    }
    wordCheck(requestError() == nil, "HTTP decoding failed")
    let items = URLComponents(url: WordHTTPStub.lastURL!, resolvingAgainstBaseURL: false)!.queryItems!
    wordCheck(items.first(where: { $0.name == "q" })?.value == "take off", "Query was not URL encoded")
    WordHTTPStub.status = 429
    wordCheck(requestError() == .unavailable, "HTTP failure ignored")
    WordHTTPStub.status = 200
    WordHTTPStub.body = Data("<html>unavailable</html>".utf8)
    wordCheck(requestError() == .invalidResponse, "Non-JSON response accepted")
    WordHTTPStub.declaredSize = 2 * 1024 * 1024
    wordCheck(requestError() == .responseTooLarge, "Content-Length bound ignored")
    WordHTTPStub.declaredSize = nil
    WordHTTPStub.body = Data(repeating: 32, count: 1024 * 1024 + 1)
    wordCheck(requestError() == .responseTooLarge, "Streaming response bound ignored")

    let controlled = ControlledWordService()
    let model = WordLookupViewModel(service: controlled)
    model.query = "old"
    model.search()
    wordWait { controlled.pending["old"] != nil }
    model.query = "new"
    model.search()
    wordWait { controlled.pending["new"] != nil }
    controlled.pending.removeValue(forKey: "new")!.resume(returning: entry)
    wordWait { model.entry != nil }
    controlled.pending.removeValue(forKey: "old")!.resume(throwing: WordLookupError.notFound)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    wordCheck(model.entry == entry && model.errorKey == nil, "Old request replaced the new result")
    model.pronounce()
    wordWait { controlled.pendingAudio != nil }
    model.stopSpeaking()
    controlled.pendingAudio!.resume(throwing: WordLookupError.unavailable)
    controlled.pendingAudio = nil
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    wordCheck(!model.isSpeaking && model.audioStatus == nil, "Cancelled audio started fallback speech")
    model.query = "closed"
    model.search()
    wordWait { controlled.pending["closed"] != nil }
    model.prepareForClose()
    controlled.pending.removeValue(forKey: "closed")!.resume(returning: entry)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    wordCheck(model.entry == nil && model.query.isEmpty && !model.isLoading, "Closed window retained or repopulated results")
    model.query = "missing"
    model.search()
    wordWait { controlled.pending["missing"] != nil }
    controlled.pending.removeValue(forKey: "missing")!.resume(throwing: WordLookupError.notFound)
    wordWait { model.errorKey != nil }
    wordCheck(model.errorKey == .wordNotFound, "Unknown-word UI state lost")
    model.prepareForClose()
    model.prepareForPresentation(clipboardText: " hello ")
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    wordCheck(model.query == "hello" && !model.isLoading && controlled.pending.isEmpty, "Prefill started a request without Return")
    model.prepareForPresentation(clipboardText: "two words")
    wordCheck(model.query == "hello", "Non-word clipboard overwrote current input")
    model.search()
    wordWait { controlled.pending["hello"] != nil }
    model.prepareForPresentation(clipboardText: "world")
    controlled.pending.removeValue(forKey: "hello")!.resume(returning: entry)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    wordCheck(model.query == "world" && model.entry == nil && !model.isLoading, "Previous lookup appeared under newly prefilled word")
    model.prepareForClose()
    model.prepareForPresentation(clipboardText: "reopened")
    wordCheck(model.query == "reopened" && controlled.pending.isEmpty, "Cached window did not prefill on reopen")
    model.prepareForClose()
    print("Word lookup regressions passed (US IPA, meanings, phrases, examples, input, HTTP errors, bounded responses, stale results and close cancellation).")
}
