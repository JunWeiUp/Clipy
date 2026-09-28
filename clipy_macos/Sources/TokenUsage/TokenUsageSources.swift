import Foundation
import SQLite3

struct TokenUsagePaths {
    var codex: URL
    var claude: URL
    var gemini: URL
    var zcode: URL

    static var standard: Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        return Self(codex: codexHome.appendingPathComponent("sessions"),
                    claude: home.appendingPathComponent(".claude/projects"),
                    gemini: home.appendingPathComponent(".gemini/tmp"),
                    zcode: home.appendingPathComponent(".zcode/cli/db/db.sqlite"))
    }
}

protocol TokenUsageSource {
    var agent: TokenAgent { get }
    func scan(into store: TokenUsageStore) throws -> TokenSourceStatus
}

enum TokenUsageJSON {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    static func object(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    static func text(_ value: Any?) -> String { value as? String ?? "" }
    static func number(_ value: Any?) -> Int {
        guard let value = value as? NSNumber, value.doubleValue.isFinite, value.doubleValue > 0 else { return 0 }
        return Int(min(value.doubleValue, Double(Int.max)))
    }
    static func date(_ value: Any?) -> Date? {
        if let seconds = value as? NSNumber {
            let raw = seconds.doubleValue
            guard raw.isFinite, raw > 0 else { return nil }
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }
        guard let text = value as? String else { return nil }
        return ISO8601DateFormatter.clipyFractional.date(from: text)
            ?? ISO8601DateFormatter.clipyPlain.date(from: text)
    }
}

private extension ISO8601DateFormatter {
    static let clipyFractional: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }()
    static let clipyPlain = ISO8601DateFormatter()
}

enum TokenUsageParser {
    static func codex(_ object: [String: Any], file: String, cursor: inout TokenFileCursor) -> TokenUsageEvent? {
        let payload = TokenUsageJSON.object(object["payload"])
        let kind = TokenUsageJSON.text(object["type"])
        if kind == "session_meta" {
            if cursor.sessionID.isEmpty { cursor.sessionID = TokenUsageJSON.text(payload["id"]) }
            return nil
        }
        if kind == "turn_context" {
            let model = TokenUsageJSON.text(payload["model"])
            if !model.isEmpty { cursor.model = model }
            return nil
        }
        guard kind == "event_msg" else { return nil }
        let tokenPayload = TokenUsageJSON.text(payload["type"]) == "token_count"
            ? payload : TokenUsageJSON.object(payload["msg"])
        guard TokenUsageJSON.text(tokenPayload["type"]) == "token_count" else { return nil }
        let info = TokenUsageJSON.object(tokenPayload["info"])
        let last = codexCounts(TokenUsageJSON.object(info["last_token_usage"]))
        let total = codexCounts(TokenUsageJSON.object(info["total_token_usage"]))
        guard let total, let timestamp = TokenUsageJSON.date(object["timestamp"]) else { return nil }
        if cursor.baselines.contains(total) { return nil }
        let delta: TokenCounts?
        if let last, !last.isEmpty {
            delta = last
        } else {
            delta = TokenCounts.positiveDifference(total, cursor.cumulative)
        }
        cursor.cumulative = total
        cursor.baselines.append(total)
        if cursor.baselines.count > 32 { cursor.baselines.removeFirst() }
        guard let delta, !delta.isEmpty else { return nil }
        // A rollout can be resumed into another file. Timestamp + cumulative
        // signature identifies the same token event across the copied prefix.
        let identity = cursor.sessionID.isEmpty ? file : cursor.sessionID
        let signature = [total.input, total.output, total.cacheRead, total.cacheWrite,
                         delta.input, delta.output, delta.cacheRead, delta.cacheWrite]
            .map(String.init).joined(separator: ":")
        return TokenUsageEvent(agent: .codex, eventID: "\(identity):\(timestamp.timeIntervalSince1970):\(signature)",
                               sourceFile: file, timestamp: timestamp,
                               model: cursor.model.isEmpty ? "unknown" : cursor.model, counts: delta)
    }

    private static func codexCounts(_ raw: [String: Any]) -> TokenCounts? {
        guard !raw.isEmpty else { return nil }
        let input = TokenUsageJSON.number(raw["input_tokens"])
        let cached = TokenUsageJSON.number(raw["cached_input_tokens"])
        // Codex includes reasoning in output_tokens; don't count it twice.
        return TokenCounts(input: max(0, input - cached),
                           output: TokenUsageJSON.number(raw["output_tokens"]),
                           cacheRead: cached, cacheWrite: 0, reasoning: 0)
    }

    static func claude(_ object: [String: Any], file: String) -> TokenUsageEvent? {
        guard TokenUsageJSON.text(object["type"]) == "assistant" else { return nil }
        let message = TokenUsageJSON.object(object["message"])
        let usage = TokenUsageJSON.object(message["usage"])
        guard let timestamp = TokenUsageJSON.date(object["timestamp"]),
              !usage.isEmpty else { return nil }
        let counts = TokenCounts(input: TokenUsageJSON.number(usage["input_tokens"]),
                                 output: TokenUsageJSON.number(usage["output_tokens"]),
                                 cacheRead: TokenUsageJSON.number(usage["cache_read_input_tokens"]),
                                 cacheWrite: TokenUsageJSON.number(usage["cache_creation_input_tokens"]),
                                 reasoning: 0)
        guard !counts.isEmpty else { return nil }
        let nativeID = TokenUsageJSON.text(message["id"])
        let fallbackID = TokenUsageJSON.text(object["uuid"])
        guard !nativeID.isEmpty || !fallbackID.isEmpty else { return nil }
        let model = TokenUsageJSON.text(message["model"])
        return TokenUsageEvent(agent: .claude, eventID: nativeID.isEmpty ? fallbackID : nativeID,
                               sourceFile: file, timestamp: timestamp,
                               model: model.isEmpty ? "unknown" : model, counts: counts)
    }

    static func gemini(_ data: Data, file: String) -> [TokenUsageEvent]? {
        guard let root = TokenUsageJSON.object(data), let messages = root["messages"] as? [[String: Any]] else { return nil }
        var previous: TokenCounts?
        var model = "unknown"
        var result: [TokenUsageEvent] = []
        for (index, message) in messages.enumerated() {
            let namedModel = TokenUsageJSON.text(message["model"])
            if !namedModel.isEmpty { model = namedModel }
            let raw = TokenUsageJSON.object(message["tokens"])
            guard !raw.isEmpty, let timestamp = TokenUsageJSON.date(message["timestamp"]) else { continue }
            let current = TokenCounts(input: TokenUsageJSON.number(raw["input"]),
                                      output: TokenUsageJSON.number(raw["output"]) + TokenUsageJSON.number(raw["tool"]),
                                      cacheRead: TokenUsageJSON.number(raw["cached"]), cacheWrite: 0,
                                      reasoning: TokenUsageJSON.number(raw["thoughts"]))
            let delta = TokenCounts.positiveDifference(current, previous)
            previous = current
            guard let delta else { continue }
            result.append(TokenUsageEvent(agent: .gemini, eventID: "\(file):\(index)", sourceFile: file,
                                          timestamp: timestamp, model: model, counts: delta))
        }
        return result
    }

    static func zcodeNative(id: String, provider: String, model: String, timestamp: Date,
                            input: Int, output: Int, reasoning: Int, cacheRead: Int,
                            cacheWrite: Int, file: String) -> TokenUsageEvent? {
        guard !id.isEmpty, !model.isEmpty, zcodeOwnProvider(provider) else { return nil }
        let counts = TokenCounts(input: max(0, input - cacheRead - cacheWrite),
                                 output: max(0, output - reasoning), cacheRead: cacheRead,
                                 cacheWrite: cacheWrite, reasoning: reasoning)
        guard !counts.isEmpty else { return nil }
        return TokenUsageEvent(agent: .zcode, eventID: "native:\(id)", sourceFile: file,
                               timestamp: timestamp, model: model, counts: counts)
    }

    static func zcodeLegacy(id: String, data: [String: Any], updated: Date, file: String) -> TokenUsageEvent? {
        guard TokenUsageJSON.text(data["role"]) == "assistant" else { return nil }
        let nestedModel = TokenUsageJSON.object(data["model"])
        let provider = TokenUsageJSON.text(data["providerID"]).isEmpty
            ? TokenUsageJSON.text(nestedModel["providerID"]) : TokenUsageJSON.text(data["providerID"])
        guard zcodeOwnProvider(provider) else { return nil }
        let model = TokenUsageJSON.text(data["modelID"]).isEmpty
            ? TokenUsageJSON.text(nestedModel["modelID"]) : TokenUsageJSON.text(data["modelID"])
        guard !id.isEmpty, !model.isEmpty else { return nil }
        let tokens = TokenUsageJSON.object(data["tokens"])
        let cache = TokenUsageJSON.object(tokens["cache"])
        let counts = TokenCounts(input: TokenUsageJSON.number(tokens["input"]),
                                 output: TokenUsageJSON.number(tokens["output"]),
                                 cacheRead: TokenUsageJSON.number(cache["read"]),
                                 cacheWrite: TokenUsageJSON.number(cache["write"]),
                                 reasoning: TokenUsageJSON.number(tokens["reasoning"]))
        guard !counts.isEmpty else { return nil }
        let time = TokenUsageJSON.date(TokenUsageJSON.object(data["time"])["completed"]) ?? updated
        return TokenUsageEvent(agent: .zcode, eventID: "legacy:\(id)", sourceFile: file,
                               timestamp: time, model: model, counts: counts)
    }

    private static func zcodeOwnProvider(_ provider: String) -> Bool {
        let value = provider.lowercased()
        return !value.isEmpty && !["anthropic", "openai", "google"].contains(where: value.contains)
    }
}

struct JSONLTokenSource: TokenUsageSource {
    let agent: TokenAgent
    let root: URL

    func scan(into store: TokenUsageStore) throws -> TokenSourceStatus {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return TokenSourceStatus(state: .missing)
        }
        guard isDirectory.boolValue else { return TokenSourceStatus(state: .unsupported) }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                               options: [.skipsPackageDescendants]) else {
            return TokenSourceStatus(state: .unreadable)
        }
        var matched = 0
        for case let file as URL in enumerator {
            guard file.pathExtension == "jsonl" else { continue }
            if agent == .codex && !file.lastPathComponent.hasPrefix("rollout-") { continue }
            matched += 1
            try scanFile(file, into: store)
        }
        return TokenSourceStatus(state: .ready, detail: matched == 0 ? "empty" : "")
    }

    private func scanFile(_ file: URL, into store: TokenUsageStore) throws {
        let fileKey = TokenUsageIdentity.fileKey(file.path)
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let fileID = (attrs[.systemFileNumber] as? NSNumber)?.stringValue ?? ""
        let old = try store.cursor(agent: agent, file: fileKey)
        let replaced = old != nil && (old!.fileID != fileID || size < old!.offset ||
                                       (size == old!.fileSize && mtime != old!.modifiedAt))
        if let old, !replaced, size == old.fileSize, mtime == old.modifiedAt { return }
        var cursor = replaced ? TokenFileCursor() : (old ?? TokenFileCursor())
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: cursor.offset)
        var buffer = Data()
        var events: [TokenUsageEvent] = []
        var completeBytes: UInt64 = 0
        let codexMarkers = [Data("\"token_count\"".utf8), Data("\"turn_context\"".utf8),
                            Data("\"session_meta\"".utf8)]
        let claudeMarker = Data("\"usage\"".utf8)
        var skippingOversizedLine = cursor.skippingOversizedLine
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            var remaining = chunk
            if skippingOversizedLine {
                if let newline = remaining.firstIndex(of: 10) {
                    completeBytes += UInt64(newline + 1)
                    remaining.removeSubrange(...newline)
                    skippingOversizedLine = false
                } else {
                    completeBytes += UInt64(remaining.count)
                    continue
                }
            }
            buffer.append(remaining)
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                let candidate = Data(line)
                let hasUsage = agent == .codex
                    ? codexMarkers.contains { candidate.range(of: $0) != nil }
                    : candidate.range(of: claudeMarker) != nil
                if hasUsage, candidate.count <= 4_000_000, let object = TokenUsageJSON.object(candidate) {
                    if agent == .codex {
                        if let event = TokenUsageParser.codex(object, file: fileKey, cursor: &cursor) { events.append(event) }
                    } else if let event = TokenUsageParser.claude(object, file: fileKey) {
                        events.append(event)
                    }
                }
                completeBytes += UInt64(newline + 1)
                buffer.removeSubrange(...newline)
            }
            if buffer.count > 8_000_000 {
                // Large response bodies can occupy a single JSONL line; usage
                // metadata lines are tiny. Skip the body without retaining it.
                completeBytes += UInt64(buffer.count)
                buffer.removeAll(keepingCapacity: false)
                skippingOversizedLine = true
            }
        }
        cursor.offset += completeBytes
        cursor.skippingOversizedLine = skippingOversizedLine
        cursor.fileSize = size
        cursor.modifiedAt = mtime
        cursor.fileID = fileID
        try store.save(agent: agent, file: fileKey, events: events, cursor: cursor, replacingFile: replaced)
    }
}

struct GeminiTokenSource: TokenUsageSource {
    let agent: TokenAgent = .gemini
    let root: URL

    func scan(into store: TokenUsageStore) throws -> TokenSourceStatus {
        guard FileManager.default.fileExists(atPath: root.path) else { return TokenSourceStatus(state: .missing) }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                               options: [.skipsPackageDescendants]) else {
            return TokenSourceStatus(state: .unreadable)
        }
        var matched = 0
        for case let file as URL in enumerator where file.lastPathComponent.hasPrefix("session-") && file.pathExtension == "json" {
            guard file.deletingLastPathComponent().lastPathComponent == "chats" else { continue }
            matched += 1
            let fileKey = TokenUsageIdentity.fileKey(file.path)
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let old = try store.cursor(agent: .gemini, file: fileKey)
            if let old, old.fileSize == size, old.modifiedAt == mtime { continue }
            let data = try Data(contentsOf: file)
            guard let events = TokenUsageParser.gemini(data, file: fileKey) else { continue }
            var cursor = TokenFileCursor()
            cursor.fileSize = size
            cursor.modifiedAt = mtime
            try store.save(agent: .gemini, file: fileKey, events: events, cursor: cursor, replacingFile: true)
        }
        return TokenSourceStatus(state: .ready, detail: matched == 0 ? "empty" : "")
    }
}

struct ZCodeTokenSource: TokenUsageSource {
    let agent: TokenAgent = .zcode
    let database: URL

    func scan(into store: TokenUsageStore) throws -> TokenSourceStatus {
        guard FileManager.default.fileExists(atPath: database.path) else { return TokenSourceStatus(state: .missing) }
        let fileKey = TokenUsageIdentity.fileKey(database.path)
        var source: OpaquePointer?
        guard sqlite3_open_v2(database.path, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(source)
            return TokenSourceStatus(state: .unreadable)
        }
        defer { sqlite3_close(source) }
        sqlite3_busy_timeout(source, 1500)
        let hasNative = tableExists("model_usage", source)
        let hasLegacy = tableExists("message", source) || tableExists("session_message", source)
        guard hasNative || hasLegacy else { return TokenSourceStatus(state: .unsupported) }
        let attrs = try FileManager.default.attributesOfItem(atPath: database.path)
        let fileID = (attrs[.systemFileNumber] as? NSNumber)?.stringValue ?? ""
        let old = try store.cursor(agent: .zcode, file: fileKey)
        let replaced = old != nil && old!.fileID != fileID
        var cursor = replaced ? TokenFileCursor() : (old ?? TokenFileCursor())
        cursor.fileID = fileID
        var events: [TokenUsageEvent] = []
        var firstNative = Double.infinity
        if hasNative, let stmt = prepare("SELECT MIN(started_at) FROM model_usage WHERE status='completed'", source) {
            if sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                firstNative = sqlite3_column_double(stmt, 0)
            }
            sqlite3_finalize(stmt)
        }
        if hasNative {
            guard let stmt = prepare("""
                SELECT id,provider_id,model_id,started_at,input_tokens,output_tokens,reasoning_tokens,
                       cache_read_input_tokens,cache_creation_input_tokens
                FROM model_usage WHERE status='completed' AND started_at>=? ORDER BY started_at,id
                """, source) else { return TokenSourceStatus(state: .unsupported) }
            defer { sqlite3_finalize(stmt) }
            let overlap = cursor.nativeWatermark > 0 ? max(0, cursor.nativeWatermark - 7 * 86_400_000) : 0
            sqlite3_bind_double(stmt, 1, overlap)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let rawTime = sqlite3_column_double(stmt, 3)
                cursor.nativeWatermark = max(cursor.nativeWatermark, rawTime)
                if let event = TokenUsageParser.zcodeNative(
                    id: optionalString(stmt, 0) ?? "", provider: optionalString(stmt, 1) ?? "",
                    model: optionalString(stmt, 2) ?? "", timestamp: Date(timeIntervalSince1970: rawTime / 1000),
                    input: Int(sqlite3_column_int64(stmt, 4)), output: Int(sqlite3_column_int64(stmt, 5)),
                    reasoning: Int(sqlite3_column_int64(stmt, 6)), cacheRead: Int(sqlite3_column_int64(stmt, 7)),
                    cacheWrite: Int(sqlite3_column_int64(stmt, 8)), file: fileKey) { events.append(event) }
            }
        }
        // Once model_usage exists, legacy messages are only a one-time historical
        // backfill. Avoid revisiting the potentially very large message table on
        // each panel open. Older installations without model_usage use rowid.
        if !cursor.legacyImported {
          for table in ["message", "session_message"] where tableExists(table, source) {
            let roleFilter = table == "message" ? "json_extract(data,'$.role')='assistant'" : "type='assistant'"
            let watermark = table == "message" ? cursor.legacyRowID : cursor.legacyV2RowID
            let sql = "SELECT rowid,id,time_updated,data FROM \(table) WHERE rowid>? AND \(roleFilter) AND time_updated<? ORDER BY rowid"
            guard let stmt = prepare(sql, source) else { continue }
            sqlite3_bind_int64(stmt, 1, max(0, watermark - 100))
            sqlite3_bind_double(stmt, 2, firstNative)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let rowID = sqlite3_column_int64(stmt, 0)
                if table == "message" { cursor.legacyRowID = max(cursor.legacyRowID, rowID) }
                else { cursor.legacyV2RowID = max(cursor.legacyV2RowID, rowID) }
                let time = sqlite3_column_double(stmt, 2)
                guard let text = optionalString(stmt, 3),
                      let data = TokenUsageJSON.object(text.data(using: .utf8) ?? Data()) else { continue }
                if let event = TokenUsageParser.zcodeLegacy(id: optionalString(stmt, 1) ?? "", data: data,
                    updated: Date(timeIntervalSince1970: time / 1000), file: fileKey) { events.append(event) }
            }
            sqlite3_finalize(stmt)
          }
          if hasNative && firstNative.isFinite { cursor.legacyImported = true }
        }
        try store.save(agent: .zcode, file: fileKey, events: events, cursor: cursor, replacingFile: replaced)
        return TokenSourceStatus(state: .ready)
    }

    private func tableExists(_ name: String, _ db: OpaquePointer?) -> Bool {
        guard let stmt = prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", db) else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, name)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func prepare(_ sql: String, _ db: OpaquePointer?) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }
}
