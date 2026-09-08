import Foundation

protocol WordLookingUp {
    func lookup(_ query: String) async throws -> WordEntry
    func americanAudio(_ word: String) async throws -> Data
}

final class WordLookupService: WordLookingUp {
    private let session: URLSession

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = session ?? URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    func lookup(_ query: String) async throws -> WordEntry {
        let query = try WordQuery.normalize(query)
        var components = URLComponents(string: "https://dict.youdao.com/jsonapi")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "dicts", value: #"{"count":30,"dicts":[["ec","phrs","blng_sents_part"]]}"#)
        ]
        let data = try await fetch(components.url!, limit: 1024 * 1024)
        do { return try YoudaoWordParser.parse(data, query: query) }
        catch let error as WordLookupError { throw error }
        catch { throw WordLookupError.invalidResponse }
    }

    func americanAudio(_ word: String) async throws -> Data {
        var components = URLComponents(string: "https://dict.youdao.com/dictvoice")!
        components.queryItems = [URLQueryItem(name: "audio", value: word), URLQueryItem(name: "type", value: "2")]
        return try await fetch(components.url!, limit: 2 * 1024 * 1024)
    }

    private func fetch(_ url: URL, limit: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            bytes.task.cancel()
            throw WordLookupError.unavailable
        }
        // Bound memory even when a server omits or lies about Content-Length.
        defer { bytes.task.cancel() }
        guard response.expectedContentLength <= limit else { throw WordLookupError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw WordLookupError.responseTooLarge }
            data.append(byte)
        }
        return data
    }
}
