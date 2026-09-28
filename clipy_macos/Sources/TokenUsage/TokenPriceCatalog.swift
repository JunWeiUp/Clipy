import Foundation

struct TokenPriceRate: Equatable {
    let input: Double       // USD per million tokens
    let output: Double
    let cacheRead: Double
    let cacheWrite: Double

    func estimate(_ counts: TokenCounts, agent: TokenAgent) -> Double {
        let outputCount = counts.output + (agent == .codex ? 0 : counts.reasoning)
        return (Double(counts.input) * input + Double(outputCount) * output
                + Double(counts.cacheRead) * cacheRead + Double(counts.cacheWrite) * cacheWrite) / 1_000_000
    }
}

/// Bundled prices work offline. Refresh is an explicit user action only.
final class TokenPriceCatalog {
    static let upstream = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

    private let cacheURL: URL
    private var rates: [String: TokenPriceRate] = [:]
    private var overrides: [String: TokenPriceRate] = [:]
    private(set) var source = "Bundled"
    private(set) var updatedAt: Date?

    init(seedURL: URL?, overridesURL: URL?, cacheURL: URL) {
        self.cacheURL = cacheURL
        if let seedURL, let data = try? Data(contentsOf: seedURL),
           let parsed = try? Self.parseLiteLLM(data, minimumEntries: 1) { rates = parsed }
        if let overridesURL, let data = try? Data(contentsOf: overridesURL) {
            overrides = Self.parseOverrides(data)
        }
        if let data = try? Data(contentsOf: cacheURL),
           let parsed = try? Self.parseLiteLLM(data, minimumEntries: 50) {
            rates = parsed
            source = "LiteLLM"
            updatedAt = (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    }

    func rate(agent: TokenAgent, model: String) -> TokenPriceRate? {
        let raw = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty, raw != "unknown" else { return nil }
        let normalized = Self.normalized(raw, agent: agent)
        for key in [raw, normalized] {
            if let value = overrides[key] { return value }
            if let value = rates[key] { return value }
        }
        // Provider-qualified keys are unambiguous for these four sources.
        let prefix: String
        switch agent {
        case .codex: prefix = "openai/"
        case .claude: prefix = "anthropic/"
        case .gemini: prefix = "gemini/"
        case .zcode: prefix = "zai/"
        }
        return rates[prefix + normalized]
    }

    /// Validate before replacing the last-good cache. A malformed response never changes displayed costs.
    func installDownloadedPrices(_ data: Data) throws {
        guard data.count <= 20_000_000 else { throw Self.error("Price data exceeds 20 MB") }
        let parsed = try Self.parseLiteLLM(data, minimumEntries: 50)
        let slim = parsed.mapValues { rate in
            ["input_cost_per_token": rate.input / 1_000_000,
             "output_cost_per_token": rate.output / 1_000_000,
             "cache_read_input_token_cost": rate.cacheRead / 1_000_000,
             "cache_creation_input_token_cost": rate.cacheWrite / 1_000_000]
        }
        let encoded = try JSONSerialization.data(withJSONObject: slim, options: [.sortedKeys])
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded.write(to: cacheURL, options: .atomic)
        rates = parsed
        source = "LiteLLM"
        updatedAt = Date()
    }

    static func parseLiteLLM(_ data: Data, minimumEntries: Int) throws -> [String: TokenPriceRate] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw error("Invalid price JSON")
        }
        var parsed: [String: TokenPriceRate] = [:]
        for (name, raw) in root where !name.hasPrefix("_") {
            let value = TokenUsageJSON.object(raw)
            guard let input = validNumber(value["input_cost_per_token"]),
                  let output = validNumber(value["output_cost_per_token"]) else { continue }
            let read = validNumber(value["cache_read_input_token_cost"]) ?? input
            let write = validNumber(value["cache_creation_input_token_cost"]) ?? input
            parsed[name.lowercased()] = TokenPriceRate(input: input * 1_000_000, output: output * 1_000_000,
                                                       cacheRead: read * 1_000_000, cacheWrite: write * 1_000_000)
        }
        guard parsed.count >= minimumEntries else { throw error("Price catalog has too few models") }
        return parsed
    }

    private static func parseOverrides(_ data: Data) -> [String: TokenPriceRate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let exact = TokenUsageJSON.object(root["exact"])
        var parsed: [String: TokenPriceRate] = [:]
        for (name, raw) in exact {
            let value = TokenUsageJSON.object(raw)
            guard let input = validPerMillion(value["input"]), let output = validPerMillion(value["output"]) else { continue }
            parsed[name.lowercased()] = TokenPriceRate(input: input, output: output,
                                                       cacheRead: validPerMillion(value["cache_read"]) ?? input,
                                                       cacheWrite: validPerMillion(value["cache_write"]) ?? input)
        }
        return parsed
    }

    private static func normalized(_ model: String, agent: TokenAgent) -> String {
        var value = model
        if let slash = value.lastIndex(of: "/") { value = String(value[value.index(after: slash)...]) }
        if agent == .claude || agent == .zcode {
            value = value.replacingOccurrences(of: #"(claude-(?:opus|sonnet|haiku)-\d+)\.(\d+)"#,
                                               with: "$1-$2", options: .regularExpression)
        }
        if agent == .codex {
            value = value.replacingOccurrences(of: #"-(?:xhigh|high|medium|low)(?:-fast)?$"#,
                                               with: "", options: .regularExpression)
        }
        return value
    }

    private static func validNumber(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber else { return nil }
        let number = value.doubleValue
        return number.isFinite && number >= 0 && number < 1 ? number : nil
    }

    private static func validPerMillion(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber else { return nil }
        let number = value.doubleValue
        return number.isFinite && number >= 0 && number < 1_000_000 ? number : nil
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "ClipyTokenPrice", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
