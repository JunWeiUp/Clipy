import AppKit
import Foundation

private let wordFixture = Data(#"""
{"input":"take","meta":{},"ec":{"word":[{"return-phrase":{"l":{"i":"take"}},"usphone":"teɪk","ukphone":"BRITISH-ONLY","trs":[{"tr":[{"l":{"i":["v. 拿；取","n. 镜头"]}}]}],"wfs":[{"wf":{"name":"过去式","value":"took"}}]}]},"phrs":{"phrs":[{"phr":{"headword":{"l":{"i":"take off"}},"trs":[{"tr":{"l":{"i":"起飞；脱下"}}}]}}]},"blng_sents_part":{"sentence-pair":[{"sentence":"Take this book.","sentence-eng":"<b>Take</b> this book.","sentence-translation":"拿这本书。","source":"Test fixture"}]}}
"""#.utf8)

private let chineseWordFixture = Data(#"""
{"input":"学习","meta":{},"ce":{"word":[{"trs":[{"tr":[{"l":{"i":["",{"#text":"study","@action":"link","@href":"app:ds:study"}],"#tran":"学习；研究"}}]},{"tr":[{"l":{"i":["",{"#text":"learn"}],"#tran":"学习；学会"}}]}]}]}}
"""#.utf8)

private let suggestionFixture = Data(#"""
{"result":{"code":200},"data":{"entries":[{"entry":"学习","explain":"study; learn"},{"entry":"学习方法","explain":"learning method"},{"entry":"STUDY","explain":"学习"},{"entry":"https://invalid.example","explain":"invalid term"}]}}
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

private final class ControlledWordSearchService: WordLookingUp {
    var pending: [String: CheckedContinuation<WordSearchResult, Error>] = [:]
    func search(_ query: String) async throws -> WordSearchResult {
        try await withCheckedThrowingContinuation { pending[query] = $0 }
    }
    func lookup(_ query: String) async throws -> WordEntry { throw WordLookupError.notFound }
    func americanAudio(_ word: String) async throws -> Data { throw WordLookupError.unavailable }
}

private final class WordHTTPStub: URLProtocol {
    static var status = 200
    static var body = wordFixture
    static var declaredSize: Int?
    static var lastURL: URL?
    static var suggestionBody: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastURL = request.url
        let headers = Self.declaredSize.map { ["Content-Length": String($0)] } ?? [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = request.url?.path == "/suggest" ? Self.suggestionBody ?? Self.body : Self.body
        client?.urlProtocol(self, didLoad: body)
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
    for query in ["", "https://example.com", "hello&token=secret", String(repeating: "a", count: 81)] {
        wordCheck((try? WordQuery.normalize(query)) == nil, "Invalid query accepted")
    }
    wordCheck((try? WordQuery.normalize(" 学习 方法 ")) == "学习 方法", "Chinese input rejected")
    wordCheck((try? WordQuery.normalize("学习 study")) == "学习 study", "Mixed-language input rejected")
    let translations = try! YoudaoWordParser.candidates(chineseWordFixture)
    wordCheck(translations.map(\.word) == ["study", "learn"] && translations[0].detail == "学习；研究",
              "Chinese translation links were lost or parsed as URLs")
    let remoteSuggestions = try! YoudaoWordParser.suggestions(suggestionFixture)
    wordCheck(remoteSuggestions.count == 3 && remoteSuggestions[1].word == "学习方法", "Bilingual suggestions lost or invalid term accepted")
    let typoFixture = Data(#"{"typos":{"typo":[{"word":"receive","trans":"收到"}]}}"#.utf8)
    wordCheck(try! YoudaoWordParser.candidates(typoFixture).first?.word == "receive", "Spelling correction lost")
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
    WordHTTPStub.body = chineseWordFixture
    WordHTTPStub.suggestionBody = suggestionFixture
    var chineseResult: WordSearchResult?
    var searchFinished = false
    Task { @MainActor in
        chineseResult = try? await service.search("学习")
        searchFinished = true
    }
    wordWait { searchFinished }
    wordCheck(chineseResult?.entry == nil && chineseResult?.suggestions.map(\.word) == ["study", "learn", "学习方法"],
              "Chinese search did not return deduplicated English translations and related Chinese words")
    WordHTTPStub.body = wordFixture
    WordHTTPStub.suggestionBody = Data("invalid suggestions".utf8)
    var degradedResult: WordSearchResult?
    searchFinished = false
    Task { @MainActor in
        degradedResult = try? await service.search("take")
        searchFinished = true
    }
    wordWait { searchFinished }
    wordCheck(degradedResult?.entry == entry, "Suggestion failure hid a valid dictionary entry")
    WordHTTPStub.suggestionBody = nil
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

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bookURL = directory.appendingPathComponent("word-book.json")
    let book = WordBookStore(fileURL: bookURL)
    wordCheck(book.words.isEmpty && book.errorKey == nil, "New book failed to initialize")
    book.record(entry)
    wordCheck(book.words.count == 1 && !book.words[0].isFamiliar, "First lookup should be unfamiliar")
    let study = WordEntry(word: "study", americanIPA: nil, meanings: [.init(partOfSpeech: "v.", definition: "学习方法；研究")],
                          phrases: [], examples: [], inflections: [])
    let receive = WordEntry(word: "receive", americanIPA: nil, meanings: [.init(partOfSpeech: "v.", definition: "收到")],
                            phrases: [], examples: [], inflections: [])
    let matchFixtures = [entry, study, receive].map {
        SavedWord(entry: $0, isFamiliar: false, firstLookedUpAt: Date(), lastLookedUpAt: Date(), lookupCount: 1)
    }
    for term in ["STU", "tud", "std", "studdy", "学习", "学法", "stu 学习", "ｓｔｕ"] {
        wordCheck(WordSearchMatcher.ranked(matchFixtures, query: term).first?.entry.word == "study", "Fuzzy bilingual match failed: \(term)")
    }
    wordCheck(WordSearchMatcher.ranked(matchFixtures, query: "recieve").first?.entry.word == "receive", "Transposed spelling failed")
    wordCheck(WordSearchMatcher.ranked(matchFixtures, query: "起飞").first?.entry.word == "take", "Phrase translation not searchable")
    wordCheck(WordSearchMatcher.ranked(matchFixtures, query: "took").first?.entry.word == "take", "Inflection not searchable")
    wordCheck(WordSearchMatcher.ranked(matchFixtures, query: "完全不存在").isEmpty, "Unrelated Chinese query matched")
    wordCheck(WordSearchMatcher.ranked(matchFixtures, query: " \n ") == matchFixtures, "Empty query changed recency order")
    book.setFamiliar(true, id: "take")
    let capitalized = WordEntry(word: "TAKE", americanIPA: entry.americanIPA, meanings: entry.meanings,
                               phrases: entry.phrases, examples: entry.examples, inflections: entry.inflections)
    book.record(capitalized)
    let reopened = WordBookStore(fileURL: bookURL)
    wordCheck(reopened.words.count == 1 && reopened.words[0].isFamiliar && reopened.words[0].lookupCount == 2,
              "Repeat lookup duplicated word or reset persisted familiarity")
    wordCheck(reopened.words[0].entry == capitalized, "Dictionary details did not round-trip")
    reopened.setFamiliar(false, id: "take")
    wordCheck(WordBookStore(fileURL: bookURL).words[0].isFamiliar == false, "Unfamiliar state did not persist")
    let corruptURL = directory.appendingPathComponent("corrupt.json")
    let corruptData = Data("invalid json".utf8)
    try! corruptData.write(to: corruptURL)
    let corrupt = WordBookStore(fileURL: corruptURL)
    corrupt.record(entry)
    wordCheck(corrupt.errorKey == .wordBookReadError && (try! Data(contentsOf: corruptURL)) == corruptData,
              "Unreadable library was overwritten")
    let blockedParent = directory.appendingPathComponent("blocked")
    let invalidDestination = WordBookStore(fileURL: blockedParent.appendingPathComponent("child.json"))
    try! Data().write(to: blockedParent)
    invalidDestination.record(entry)
    wordCheck(invalidDestination.errorKey == .wordBookWriteError && invalidDestination.words.isEmpty,
              "Failed save was presented as persisted")

    let controlled = ControlledWordService()
    let lookupBook = WordBookStore(fileURL: directory.appendingPathComponent("lookup.json"))
    let model = WordLookupViewModel(service: controlled, wordBook: lookupBook)
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
    wordCheck(lookupBook.words.count == 1 && lookupBook.words[0].lookupCount == 1, "Successful lookup not saved exactly once")
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
    wordCheck(lookupBook.words.count == 1 && lookupBook.words[0].lookupCount == 1,
              "Cancelled, failed or prefilled lookup was saved")
    model.showSaved(entry)
    wordCheck(model.entry == entry && controlled.pending.isEmpty && lookupBook.words[0].lookupCount == 1,
              "Offline review performed a lookup or changed lookup count")
    model.query = "拿"
    model.search()
    wordWait { controlled.pending["拿"] != nil }
    wordCheck(model.suggestions.first?.word == "take", "Chinese query did not expose local candidates")
    controlled.pending.removeValue(forKey: "拿")!.resume(throwing: WordLookupError.unavailable)
    wordWait { !model.isLoading }
    wordCheck(model.suggestions.first?.word == "take", "Network failure erased offline candidates")
    model.selectSuggestion(model.suggestions[0])
    wordCheck(model.entry == entry && controlled.pending.isEmpty && model.errorKey == nil,
              "Selecting a saved fuzzy match did not open offline")
    model.prepareForClose()
    wordCheck(model.suggestions.isEmpty, "Closed window retained candidates")
    let controlledSearch = ControlledWordSearchService()
    let candidateBook = WordBookStore(fileURL: directory.appendingPathComponent("candidates.json"))
    let candidateModel = WordLookupViewModel(service: controlledSearch, wordBook: candidateBook)
    candidateModel.query = "学"
    candidateModel.search()
    wordWait { controlledSearch.pending["学"] != nil }
    candidateModel.query = "学习"
    candidateModel.search()
    wordWait { controlledSearch.pending["学习"] != nil }
    controlledSearch.pending.removeValue(forKey: "学习")!.resume(returning: WordSearchResult(entry: nil, suggestions: translations))
    wordWait { !candidateModel.isLoading }
    controlledSearch.pending.removeValue(forKey: "学")!.resume(returning: WordSearchResult(entry: entry, suggestions: []))
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    wordCheck(candidateModel.entry == nil && candidateModel.suggestions == translations && candidateBook.words.isEmpty,
              "Stale result overwrote Chinese candidates or unselected candidates entered vocabulary")
    candidateModel.selectSuggestion(translations[0])
    wordWait { controlledSearch.pending["study"] != nil }
    candidateModel.prepareForClose()
    controlledSearch.pending.removeValue(forKey: "study")!.resume(returning: WordSearchResult(entry: study, suggestions: translations))
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    wordCheck(candidateModel.entry == nil && candidateModel.suggestions.isEmpty && candidateBook.words.isEmpty,
              "Closed lookup repopulated candidates or saved a cancelled selection")
    print("Bilingual fuzzy search regressions passed (Chinese translation links, suggestions, spelling, offline matching and cancellation).")
    print("Word book regressions passed (persistence, familiarity, deduplication, complete details, write failures and offline review).")
    print("Word lookup regressions passed (US IPA, meanings, phrases, examples, input, HTTP errors, bounded responses, stale results and close cancellation).")
}
