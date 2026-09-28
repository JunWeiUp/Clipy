import Foundation
import SQLite3

/// A separate, metadata-only database. No transcript text or credentials enter it.
final class TokenUsageStore {
    private var db: OpaquePointer?

    init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard sqlite3_open_v2(databaseURL.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw failure("open")
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("""
            CREATE TABLE IF NOT EXISTS token_usage_events (
                agent TEXT NOT NULL, event_id TEXT NOT NULL, source_file TEXT NOT NULL,
                timestamp REAL NOT NULL, model TEXT NOT NULL,
                input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
                cache_read_tokens INTEGER NOT NULL, cache_write_tokens INTEGER NOT NULL,
                reasoning_tokens INTEGER NOT NULL,
                PRIMARY KEY(agent, event_id)
            );
            CREATE INDEX IF NOT EXISTS token_usage_by_time ON token_usage_events(timestamp);
            CREATE INDEX IF NOT EXISTS token_usage_by_file ON token_usage_events(agent, source_file);
            CREATE TABLE IF NOT EXISTS token_usage_cursors (
                agent TEXT NOT NULL, source_file TEXT NOT NULL, state_json BLOB NOT NULL,
                PRIMARY KEY(agent, source_file)
            );
            """)
        try migratePlaintextFileKeys()
    }

    deinit { sqlite3_close(db) }

    func cursor(agent: TokenAgent, file: String) throws -> TokenFileCursor? {
        let stmt = try prepare("SELECT state_json FROM token_usage_cursors WHERE agent=? AND source_file=?")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, agent.rawValue)
        bindText(stmt, 2, file)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let size = Int(sqlite3_column_bytes(stmt, 0))
        guard let bytes = sqlite3_column_blob(stmt, 0), size > 0 else { return nil }
        return try JSONDecoder().decode(TokenFileCursor.self, from: Data(bytes: bytes, count: size))
    }

    /// Commit the parsed rows and cursor together; a failed scan can safely be retried.
    func save(agent: TokenAgent, file: String, events: [TokenUsageEvent],
              cursor: TokenFileCursor, replacingFile: Bool) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            if replacingFile {
                let delete = try prepare("DELETE FROM token_usage_events WHERE agent=? AND source_file=?")
                bindText(delete, 1, agent.rawValue)
                bindText(delete, 2, file)
                let code = sqlite3_step(delete)
                sqlite3_finalize(delete)
                guard code == SQLITE_DONE else { throw failure("delete old file events") }
            }
            let insert = try prepare("""
                INSERT INTO token_usage_events
                (agent,event_id,source_file,timestamp,model,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(agent,event_id) DO UPDATE SET
                  timestamp=excluded.timestamp, model=excluded.model,
                  input_tokens=excluded.input_tokens, output_tokens=excluded.output_tokens,
                  cache_read_tokens=excluded.cache_read_tokens,
                  cache_write_tokens=excluded.cache_write_tokens,
                  reasoning_tokens=excluded.reasoning_tokens
                """)
            for event in events {
                sqlite3_reset(insert)
                sqlite3_clear_bindings(insert)
                bindText(insert, 1, event.agent.rawValue)
                bindText(insert, 2, event.eventID)
                bindText(insert, 3, event.sourceFile)
                sqlite3_bind_double(insert, 4, event.timestamp.timeIntervalSince1970)
                bindText(insert, 5, event.model)
                sqlite3_bind_int64(insert, 6, sqlite3_int64(event.counts.input))
                sqlite3_bind_int64(insert, 7, sqlite3_int64(event.counts.output))
                sqlite3_bind_int64(insert, 8, sqlite3_int64(event.counts.cacheRead))
                sqlite3_bind_int64(insert, 9, sqlite3_int64(event.counts.cacheWrite))
                sqlite3_bind_int64(insert, 10, sqlite3_int64(event.counts.reasoning))
                guard sqlite3_step(insert) == SQLITE_DONE else {
                    sqlite3_finalize(insert)
                    throw failure("insert event")
                }
            }
            sqlite3_finalize(insert)
            let state = try JSONEncoder().encode(cursor)
            let update = try prepare("INSERT OR REPLACE INTO token_usage_cursors(agent,source_file,state_json) VALUES (?,?,?)")
            bindText(update, 1, agent.rawValue)
            bindText(update, 2, file)
            _ = state.withUnsafeBytes { bytes in
                sqlite3_bind_blob(update, 3, bytes.baseAddress, Int32(state.count), sqliteTransient)
            }
            let code = sqlite3_step(update)
            sqlite3_finalize(update)
            guard code == SQLITE_DONE else { throw failure("save cursor") }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func events(from start: Date, through end: Date) throws -> [TokenUsageEvent] {
        let stmt = try prepare("""
            SELECT agent,event_id,source_file,timestamp,model,input_tokens,output_tokens,
                   cache_read_tokens,cache_write_tokens,reasoning_tokens
            FROM token_usage_events WHERE timestamp>=? AND timestamp<? ORDER BY timestamp DESC
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 2, end.timeIntervalSince1970)
        var result: [TokenUsageEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let name = optionalString(stmt, 0), let agent = TokenAgent(rawValue: name),
                  let eventID = optionalString(stmt, 1), let file = optionalString(stmt, 2),
                  let model = optionalString(stmt, 4) else { continue }
            let counts = TokenCounts(input: Int(sqlite3_column_int64(stmt, 5)),
                                     output: Int(sqlite3_column_int64(stmt, 6)),
                                     cacheRead: Int(sqlite3_column_int64(stmt, 7)),
                                     cacheWrite: Int(sqlite3_column_int64(stmt, 8)),
                                     reasoning: Int(sqlite3_column_int64(stmt, 9)))
            result.append(TokenUsageEvent(agent: agent, eventID: eventID, sourceFile: file,
                                          timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                                          model: model, counts: counts))
        }
        return result
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw failure("prepare") }
        return stmt
    }

    /// Older local builds stored the scan path. Migrate in one transaction so
    /// a restart never mixes path keys with hashed keys or reimports history.
    private func migratePlaintextFileKeys() throws {
        let select = try prepare("""
            SELECT agent,source_file FROM token_usage_cursors WHERE substr(source_file,1,1)='/'
            UNION SELECT agent,source_file FROM token_usage_events WHERE substr(source_file,1,1)='/'
            """)
        var legacy: [(String, String)] = []
        while sqlite3_step(select) == SQLITE_ROW {
            if let agent = optionalString(select, 0), let path = optionalString(select, 1) {
                legacy.append((agent, path))
            }
        }
        sqlite3_finalize(select)
        guard !legacy.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            for (agent, path) in legacy {
                let key = TokenUsageIdentity.fileKey(path)
                let rewriteID = try prepare("""
                    UPDATE token_usage_events SET event_id=? || substr(event_id,length(?) + 1)
                    WHERE agent=? AND source_file=? AND substr(event_id,1,length(?))=?
                    """)
                bindText(rewriteID, 1, key)
                bindText(rewriteID, 2, path)
                bindText(rewriteID, 3, agent)
                bindText(rewriteID, 4, path)
                bindText(rewriteID, 5, path)
                bindText(rewriteID, 6, path)
                let idCode = sqlite3_step(rewriteID)
                sqlite3_finalize(rewriteID)
                guard idCode == SQLITE_DONE else { throw failure("migrate event IDs") }

                let events = try prepare("UPDATE token_usage_events SET source_file=? WHERE agent=? AND source_file=?")
                bindText(events, 1, key)
                bindText(events, 2, agent)
                bindText(events, 3, path)
                let eventCode = sqlite3_step(events)
                sqlite3_finalize(events)
                guard eventCode == SQLITE_DONE else { throw failure("migrate event file") }

                let cursors = try prepare("UPDATE token_usage_cursors SET source_file=? WHERE agent=? AND source_file=?")
                bindText(cursors, 1, key)
                bindText(cursors, 2, agent)
                bindText(cursors, 3, path)
                let cursorCode = sqlite3_step(cursors)
                sqlite3_finalize(cursors)
                guard cursorCode == SQLITE_DONE else { throw failure("migrate cursor file") }
            }
            try execute("COMMIT")
            // Rebuild pages and truncate WAL so deleted path strings do not
            // remain in free SQLite pages after the one-time migration.
            try? execute("PRAGMA wal_checkpoint(TRUNCATE)")
            try? execute("VACUUM")
            try? execute("PRAGMA wal_checkpoint(TRUNCATE)")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure("execute") }
    }

    private func failure(_ operation: String) -> NSError {
        NSError(domain: "ClipyTokenUsage", code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: "Token usage \(operation): \(sqliteErrorMessage(db))"])
    }
}
