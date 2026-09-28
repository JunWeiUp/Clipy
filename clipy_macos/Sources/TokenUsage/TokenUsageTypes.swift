import Foundation
import CryptoKit

enum TokenUsageIdentity {
    static func fileKey(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum TokenAgent: String, CaseIterable, Codable, Identifiable {
    case codex, claude, gemini, zcode

    var id: String { rawValue }
    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .gemini: return "Gemini CLI"
        case .zcode: return "ZCode"
        }
    }
}

struct TokenCounts: Codable, Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var reasoning = 0

    var total: Int { input + output + cacheRead + cacheWrite + reasoning }
    var isEmpty: Bool { total == 0 }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
             cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
             reasoning: lhs.reasoning + rhs.reasoning)
    }

    static func positiveDifference(_ current: Self, _ previous: Self?) -> Self? {
        guard let previous else { return current.isEmpty ? nil : current }
        // A newly reset cumulative stream starts a new baseline.
        if current.total < previous.total { return current.isEmpty ? nil : current }
        let delta = Self(input: max(0, current.input - previous.input),
                         output: max(0, current.output - previous.output),
                         cacheRead: max(0, current.cacheRead - previous.cacheRead),
                         cacheWrite: max(0, current.cacheWrite - previous.cacheWrite),
                         reasoning: max(0, current.reasoning - previous.reasoning))
        return delta.isEmpty ? nil : delta
    }
}

struct TokenUsageEvent: Equatable {
    let agent: TokenAgent
    let eventID: String
    let sourceFile: String
    let timestamp: Date
    let model: String
    let counts: TokenCounts
}

struct TokenFileCursor: Codable {
    var fileID = ""
    var fileSize: UInt64 = 0
    var modifiedAt: TimeInterval = 0
    var offset: UInt64 = 0
    var model = ""
    var sessionID = ""
    var cumulative: TokenCounts?
    var baselines: [TokenCounts] = []
    var sequence = 0
    var nativeWatermark: Double = 0
    var legacyWatermark: Double = 0
    var legacyImported = false
    var legacyRowID: Int64 = 0
    var legacyV2RowID: Int64 = 0
    var skippingOversizedLine = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case fileID, fileSize, modifiedAt, offset, model, sessionID, cumulative, baselines
        case sequence, nativeWatermark, legacyWatermark, legacyImported
        case legacyRowID, legacyV2RowID, skippingOversizedLine
    }

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fileID = try values.decodeIfPresent(String.self, forKey: .fileID) ?? ""
        fileSize = try values.decodeIfPresent(UInt64.self, forKey: .fileSize) ?? 0
        modifiedAt = try values.decodeIfPresent(TimeInterval.self, forKey: .modifiedAt) ?? 0
        offset = try values.decodeIfPresent(UInt64.self, forKey: .offset) ?? 0
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        sessionID = try values.decodeIfPresent(String.self, forKey: .sessionID) ?? ""
        cumulative = try values.decodeIfPresent(TokenCounts.self, forKey: .cumulative)
        baselines = try values.decodeIfPresent([TokenCounts].self, forKey: .baselines) ?? []
        sequence = try values.decodeIfPresent(Int.self, forKey: .sequence) ?? 0
        nativeWatermark = try values.decodeIfPresent(Double.self, forKey: .nativeWatermark) ?? 0
        legacyWatermark = try values.decodeIfPresent(Double.self, forKey: .legacyWatermark) ?? 0
        legacyImported = try values.decodeIfPresent(Bool.self, forKey: .legacyImported) ?? false
        legacyRowID = try values.decodeIfPresent(Int64.self, forKey: .legacyRowID) ?? 0
        legacyV2RowID = try values.decodeIfPresent(Int64.self, forKey: .legacyV2RowID) ?? 0
        skippingOversizedLine = try values.decodeIfPresent(Bool.self, forKey: .skippingOversizedLine) ?? false
    }
}

enum TokenSourceState: Equatable {
    case ready, missing, unreadable, unsupported, failed
}

struct TokenSourceStatus: Equatable {
    var state: TokenSourceState
    var detail: String = ""
}

struct TokenUsageLine: Identifiable {
    let id: String
    let day: String
    let agent: TokenAgent
    let model: String
    let counts: TokenCounts
    let estimatedUSD: Double?
    let unpricedEvents: Int
}

struct TokenUsageDay: Identifiable {
    var id: String { day }
    let day: String
    let counts: TokenCounts
    let estimatedUSD: Double
    let unpricedEvents: Int
}

struct TokenUsageReport {
    var lines: [TokenUsageLine] = []
    var days: [TokenUsageDay] = []
    var counts = TokenCounts()
    var estimatedUSD: Double = 0
    var unpricedEvents = 0
}
