import Foundation
import SQLite3
import AppKit
import SwiftUI

func runTokenUsageRegressionTests() {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError("Token usage regression: " + message) }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipy-token-tests-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try! TokenUsageStore(databaseURL: root.appendingPathComponent("usage.db"))
    let priorCursor = try! JSONDecoder().decode(TokenFileCursor.self,
        from: Data(#"{"fileSize":12,"offset":12,"model":"gpt-test"}"#.utf8))
    check(priorCursor.offset == 12 && priorCursor.baselines.isEmpty && !priorCursor.skippingOversizedLine,
          "older persisted cursor cannot migrate")
    let privacyURL = root.appendingPathComponent("privacy.db")
    let legacyPath = "/private/project-name/session.json"
    let hashedPath = TokenUsageIdentity.fileKey(legacyPath)
    do {
        let legacyStore = try! TokenUsageStore(databaseURL: privacyURL)
        let oldEvent = TokenUsageEvent(agent: .gemini, eventID: legacyPath + ":0", sourceFile: legacyPath,
                                       timestamp: Date(timeIntervalSince1970: 1_800_000_000), model: "fixture",
                                       counts: TokenCounts(input: 4))
        try! legacyStore.save(agent: .gemini, file: legacyPath, events: [oldEvent],
                              cursor: TokenFileCursor(), replacingFile: false)
    }
    let privateStore = try! TokenUsageStore(databaseURL: privacyURL)
    check((try! privateStore.cursor(agent: .gemini, file: hashedPath)) != nil,
          "plaintext file cursor did not migrate")
    let migrated = try! privateStore.events(from: Date(timeIntervalSince1970: 1_700_000_000),
                                            through: Date(timeIntervalSince1970: 1_900_000_000))
    check(migrated.first?.sourceFile == hashedPath && migrated.first?.eventID == hashedPath + ":0",
          "plaintext file path remained in usage event")
    let start = Date(timeIntervalSince1970: 1_500_000_000)
    let end = Date(timeIntervalSince1970: 2_000_000_000)
    func records(_ agent: TokenAgent) -> [TokenUsageEvent] {
        try! store.events(from: start, through: end).filter { $0.agent == agent }
    }
    func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)! + "\n"
    }

    let codexDir = root.appendingPathComponent("codex")
    try! FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
    let codexFile = codexDir.appendingPathComponent("rollout-test.jsonl")
    let codexMeta: [String: Any] = ["type": "session_meta", "payload": ["id": "session-1"]]
    let codexContext: [String: Any] = ["type": "turn_context", "payload": ["model": "gpt-5.6-sol"]]
    func codexEvent(_ at: String, input: Int, cached: Int, output: Int,
                    totalInput: Int, totalCached: Int, totalOutput: Int) -> [String: Any] {
        ["type": "event_msg", "timestamp": at,
         "payload": ["type": "token_count", "info": [
            "last_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output],
            "total_token_usage": ["input_tokens": totalInput, "cached_input_tokens": totalCached, "output_tokens": totalOutput]]]]
    }
    let first = codexEvent("2026-09-27T16:30:00Z", input: 100, cached: 20, output: 10,
                           totalInput: 100, totalCached: 20, totalOutput: 10)
    let second = codexEvent("2026-09-27T16:31:00Z", input: 50, cached: 10, output: 5,
                            totalInput: 150, totalCached: 30, totalOutput: 15)
    try! (line(codexMeta) + line(codexContext) + line(first) + line(second) + line(second)).write(to: codexFile, atomically: true, encoding: .utf8)
    let codexSource = JSONLTokenSource(agent: .codex, root: codexDir)
    try! codexSource.scan(into: store)
    check(records(.codex).count == 2, "Codex duplicate cumulative snapshot counted twice")
    check(records(.codex).reduce(0) { $0 + $1.counts.total } == 165, "Codex cache or delta split is wrong")
    try! codexSource.scan(into: store)
    check(records(.codex).count == 2, "Codex unchanged file scanned twice")
    let third = codexEvent("2026-09-28T16:30:00Z", input: 20, cached: 0, output: 2,
                           totalInput: 170, totalCached: 30, totalOutput: 17)
    let handle = try! FileHandle(forWritingTo: codexFile)
    try! handle.seekToEnd()
    try! handle.write(contentsOf: Data(line(third).utf8))
    try! handle.close()
    try! codexSource.scan(into: store)
    check(records(.codex).count == 3, "Codex appended record missing")
    try! Data((line(codexMeta) + line(codexContext) + line(first)).utf8).write(to: codexFile)
    try! codexSource.scan(into: store)
    check(records(.codex).count == 1, "Codex truncation kept stale events")
    let largeResponse = String(repeating: "x", count: 8_100_000) + "\n"
    try! Data((line(codexMeta) + line(codexContext) + line(first) + largeResponse + line(second)).utf8).write(to: codexFile)
    try! codexSource.scan(into: store)
    check(records(.codex).count == 2, "oversized response line blocked later Codex usage")

    let claudeDir = root.appendingPathComponent("claude")
    try! FileManager.default.createDirectory(at: claudeDir.appendingPathComponent("subagents"), withIntermediateDirectories: true)
    let claudeUsage: [String: Any] = ["input_tokens": 30, "output_tokens": 10,
                                      "cache_read_input_tokens": 5, "cache_creation_input_tokens": 2]
    let claudeLine = line(["type": "assistant", "timestamp": "2026-09-28T00:00:00Z",
                           "message": ["id": "message-one", "model": "claude-sonnet-5", "usage": claudeUsage]])
    try! claudeLine.write(to: claudeDir.appendingPathComponent("main.jsonl"), atomically: true, encoding: .utf8)
    try! claudeLine.write(to: claudeDir.appendingPathComponent("subagents/child.jsonl"), atomically: true, encoding: .utf8)
    try! JSONLTokenSource(agent: .claude, root: claudeDir).scan(into: store)
    check(records(.claude).count == 1, "Claude parent/subagent duplicate counted twice")
    check(records(.claude).first?.counts.total == 47, "Claude cache fields lost")

    let geminiRoot = root.appendingPathComponent("gemini/project/chats")
    try! FileManager.default.createDirectory(at: geminiRoot, withIntermediateDirectories: true)
    let geminiFile = geminiRoot.appendingPathComponent("session-test.json")
    func geminiSession(_ messages: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["messages": messages])
    }
    let geminiA: [String: Any] = ["timestamp": "2026-09-28T00:00:00Z", "model": "gemini-3-pro-preview",
                                  "tokens": ["input": 100, "output": 10, "cached": 5]]
    let geminiB: [String: Any] = ["timestamp": "2026-09-28T00:01:00Z",
                                  "tokens": ["input": 150, "output": 20, "cached": 10]]
    try! geminiSession([geminiA, geminiB]).write(to: geminiFile)
    let geminiSource = GeminiTokenSource(root: root.appendingPathComponent("gemini"))
    try! geminiSource.scan(into: store)
    check(records(.gemini).count == 2, "Gemini cumulative messages missing")
    check(records(.gemini).reduce(0) { $0 + $1.counts.total } == 180, "Gemini cumulative delta wrong")
    try! geminiSession([geminiA]).write(to: geminiFile)
    try! geminiSource.scan(into: store)
    check(records(.gemini).count == 1, "Gemini rewrite retained stale events")

    let zcodeFile = root.appendingPathComponent("zcode.sqlite")
    var db: OpaquePointer?
    check(sqlite3_open(zcodeFile.path, &db) == SQLITE_OK, "ZCode fixture DB open")
    defer { sqlite3_close(db) }
    let schema = """
        CREATE TABLE model_usage(id TEXT,provider_id TEXT,model_id TEXT,started_at INTEGER,status TEXT,
          input_tokens INTEGER,output_tokens INTEGER,reasoning_tokens INTEGER,
          cache_read_input_tokens INTEGER,cache_creation_input_tokens INTEGER);
        CREATE TABLE message(id TEXT,session_id TEXT,time_updated INTEGER,data TEXT);
        """
    check(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK, "ZCode fixture schema")
    let native = """
        INSERT INTO model_usage VALUES('own','builtin:zai','glm-5',1720000000000,'completed',100,20,5,10,2);
        INSERT INTO model_usage VALUES('delegated','anthropic','claude-sonnet-5',1720000001000,'completed',100,20,0,0,0);
        INSERT INTO message VALUES('legacy','s',1710000000000,'{"role":"assistant","providerID":"builtin:zai","modelID":"glm-5","tokens":{"input":10,"output":2}}');
        INSERT INTO message VALUES('late','s',1730000000000,'{"role":"assistant","providerID":"builtin:zai","modelID":"glm-5","tokens":{"input":10,"output":2}}');
        """
    check(sqlite3_exec(db, native, nil, nil, nil) == SQLITE_OK, "ZCode fixture rows")
    let zcodeSource = ZCodeTokenSource(database: zcodeFile)
    try! zcodeSource.scan(into: store)
    check(records(.zcode).count == 2, "ZCode native/legacy boundary or delegated exclusion wrong")
    try! zcodeSource.scan(into: store)
    check(records(.zcode).count == 2, "ZCode repeated scan duplicated rows")

    let seedURL = root.appendingPathComponent("seed.json")
    let seed = ["gpt-5.6-sol": ["input_cost_per_token": 0.000005,
                                 "output_cost_per_token": 0.00003]]
    try! JSONSerialization.data(withJSONObject: seed).write(to: seedURL)
    let catalog = TokenPriceCatalog(seedURL: seedURL, overridesURL: nil, cacheURL: root.appendingPathComponent("prices.json"))
    let oldRate = catalog.rate(agent: .codex, model: "gpt-5.6-sol")
    check(oldRate != nil && catalog.rate(agent: .codex, model: "unknown") == nil, "price/unknown model lookup")
    do {
        try catalog.installDownloadedPrices(Data("{}".utf8))
        fatalError("Invalid price download accepted")
    } catch {}
    check(catalog.rate(agent: .codex, model: "gpt-5.6-sol") == oldRate, "failed price update changed last-good rates")
    var fresh = [String: [String: Double]]()
    for number in 0..<50 { fresh["fixture-\(number)"] = seed["gpt-5.6-sol"] }
    fresh["gpt-5.6-sol"] = ["input_cost_per_token": 0.000006, "output_cost_per_token": 0.00003]
    try! catalog.installDownloadedPrices(JSONSerialization.data(withJSONObject: fresh))
    check(catalog.rate(agent: .codex, model: "gpt-5.6-sol")?.input == 6, "manual price update not applied")

    var shanghai = Calendar(identifier: .gregorian)
    shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let example = TokenUsageEvent(agent: .codex, eventID: "day", sourceFile: "fixture",
                                  timestamp: ISO8601DateFormatter().date(from: "2026-09-27T16:30:00Z")!,
                                  model: "gpt-5.6-sol", counts: TokenCounts(input: 1))
    let summary = TokenUsageAggregator.report(events: [example], catalog: catalog, calendar: shanghai)
    check(summary.days.first?.day == "2026-09-28", "local calendar day grouping is wrong")
    check(summary.estimatedUSD > 0 && summary.unpricedEvents == 0, "known model cost missing")
    let unknown = TokenUsageEvent(agent: .zcode, eventID: "unknown", sourceFile: "fixture",
                                  timestamp: example.timestamp, model: "unknown-preview-model",
                                  counts: TokenCounts(input: 100))
    let mixed = TokenUsageAggregator.report(events: [example, unknown], catalog: catalog, calendar: shanghai)
    check(mixed.unpricedEvents == 1 && mixed.estimatedUSD == summary.estimatedUSD && mixed.counts.total == 101,
          "unknown model was treated as zero-priced or its tokens disappeared")
    print("Token usage regressions passed (four sources, cursor/rewrite, dedup, timezone, pricing rollback).")
}

/// Uses fictional metadata and an isolated price catalog; never scans user logs.
func runTokenUsageSnapshot() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard let directory = ProcessInfo.processInfo.environment["CLIPY_TOKEN_SNAPSHOT_DIR"] else { exit(2) }
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("clipy-token-preview-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let emptyPaths = TokenUsagePaths(codex: temporary, claude: temporary, gemini: temporary,
                                     zcode: temporary.appendingPathComponent("none.db"))
    let manager = TokenUsageManager(paths: emptyPaths, directory: temporary, seedURL: nil, overridesURL: nil)
    var entries: [TokenUsageLine] = []
    for offset in 0..<24 {
        let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
        let day = TokenUsageFormat.day(date)
        let agent = TokenAgent.allCases[offset % TokenAgent.allCases.count]
        entries.append(TokenUsageLine(id: "fixture-\(offset)", day: day, agent: agent,
                                      model: offset % 6 == 0 ? "preview-unknown-model" : "sample-model-\(offset % 4)",
                                      counts: TokenCounts(input: 300_000 + offset * 2000,
                                                          output: 25_000, cacheRead: 70_000,
                                                          cacheWrite: 0, reasoning: 3000),
                                      estimatedUSD: offset % 6 == 0 ? nil : 2.75 + Double(offset) * 0.18,
                                      unpricedEvents: offset % 6 == 0 ? 1 : 0))
    }
    let days = entries.map { TokenUsageDay(day: $0.day, counts: $0.counts,
                                           estimatedUSD: $0.estimatedUSD ?? 0, unpricedEvents: $0.unpricedEvents) }
    let sample = TokenUsageReport(lines: entries, days: days)
    let statuses: [TokenAgent: TokenSourceStatus] = Dictionary(uniqueKeysWithValues: TokenAgent.allCases.map {
        ($0, TokenSourceStatus(state: $0 == .gemini ? .missing : .ready))
    })
    manager.setPreview(report: sample, statuses: statuses)
    let root = TokenUsageView(manager: manager).environmentObject(AppLanguageObserver.shared)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 860, height: 700),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.contentViewController = NSHostingController(rootView: root)
    window.center(); window.orderFrontRegardless()
    let names = ["light-populated", "dark-populated", "light-empty", "dark-narrow", "light-populated-en"]
    var step = 0
    func prepare() {
        UserDefaults.standard.setVolatileDomain(["appLanguage": step == 4 ? "en" : "zh"], forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
        window.appearance = NSAppearance(named: step % 2 == 0 ? .aqua : .darkAqua)
        window.setContentSize(CGSize(width: step == 3 ? 600 : 860, height: step == 3 ? 480 : 700))
        manager.setPreview(report: step == 2 ? TokenUsageReport() : sample, statuses: statuses)
    }
    prepare()
    let timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { timer in
        window.contentView?.layoutSubtreeIfNeeded()
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(3) }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(4) }
        try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(names[step] + ".png"))
        step += 1
        if step == names.count {
            timer.invalidate(); window.orderOut(nil)
            try? FileManager.default.removeItem(at: temporary)
            print("Token usage snapshots saved.")
            exit(0)
        }
        prepare()
    }
    withExtendedLifetime((window, manager, timer)) { app.run() }
    exit(0)
}
